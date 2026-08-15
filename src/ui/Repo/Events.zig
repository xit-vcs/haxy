const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const page_size = 20;

pub const Item = struct {
    id: []const u8,
    kind: evt.EventKind,
    deleted: bool,
    author: ui.Author,
    view_url: ?[]const u8 = null,
};

pub const Cursor = struct {
    id: []const u8,
    kind: evt.EventKind,
};

identity: []const u8,
events: []const Item,
next: ?Cursor,
header: Header,

const Self = @This();

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    selected_kind: ?evt.EventKind,
    selected: []const u8,
    local: bool,
    failure: ?[]const u8,
) !Self {
    const aa = arena.allocator();
    var result = try empty(aa, identity, local, failure);
    var local_header: ?Header = null;
    if (local) {
        const header = try Header.local(repo_kind, repo_opts, aa, repo, io, failure);
        local_header = header;
        result.header = try header.withCount(aa, 0);
    }
    const strict = selected_kind != null or selected.len != 0;
    if ((selected_kind == null) != (selected.len == 0)) return error.NotFound;

    const DB = evt.EventDB(repo_opts.hash);
    const gpa = arena.child_allocator;
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return result
    else
        evt.currentMoment(repo_opts, repo)) catch {
        if (strict) return error.NotFound;
        return result;
    };

    const kind_map_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse {
        if (strict) return error.NotFound;
        return result;
    };
    const kind_map = try DB.HashMap(.read_only).init(kind_map_cursor);
    const id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_id_set_key)) orelse {
        if (strict) return error.NotFound;
        return result;
    };
    const id_set = try DB.SortedSet(.read_only).init(id_set_cursor);
    const count: usize = @intCast(try id_set.count());
    if (local_header) |header|
        result.header = try header.withCount(aa, count)
    else
        result.header = try Header.remote(aa, count);

    var root_key: ?[@sizeOf(u64) + evt.event_id_size]u8 = null;
    if (selected.len != 0) {
        var id: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, selected) catch return error.NotFound;
        if (!std.mem.eql(u8, selected, &std.fmt.bytesToHex(id, .lower))) return error.NotFound;
        const kind = selected_kind orelse return error.NotFound;
        const stored_kind = (try readKind(repo_opts.hash, kind_map, &id)) orelse return error.NotFound;
        if (stored_kind != kind) return error.NotFound;
        const created_ts = try readCreatedTs(repo_opts.hash, arena, haxy_moment, kind, &id);
        const key = evt.orderKeyDesc(created_ts, &id);
        if (!try id_set.contains(&key)) return error.NotFound;
        root_key = key;
    }
    var iter = if (root_key) |*key| try id_set.iteratorFrom(key) else try id_set.iteratorFromIndex(0);

    var events: std.ArrayList(Item) = .empty;
    while (try iter.next()) |cursor_value| {
        const id = try evt.readOrderKeyId(DB, cursor_value);
        const kind = (try readKind(repo_opts.hash, kind_map, &id)) orelse continue;
        if (events.items.len == page_size) {
            result.next = .{ .id = try formatId(aa, &id), .kind = kind };
            break;
        }
        const item = (try readItem(repo_opts.hash, arena, haxy_moment, kind_map, admin_moment, identity, kind, &id)) orelse continue;
        try events.append(aa, item);
    }
    result.events = events.items;
    return result;
}

fn readKind(
    comptime hash_kind: hash.HashKind,
    kind_map: evt.EventDB(hash_kind).HashMap(.read_only),
    id: *const [evt.event_id_size]u8,
) !?evt.EventKind {
    const cursor = try kind_map.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    var buffer: [64]u8 = undefined;
    return std.meta.stringToEnum(evt.EventKind, try cursor.readBytes(&buffer)) orelse error.InvalidEventKind;
}

pub fn empty(aa: std.mem.Allocator, identity: []const u8, local: bool, failure: ?[]const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .events = &.{},
        .next = null,
        .header = if (local) try (try Header.empty(aa, failure)).withCount(aa, 0) else try Header.remote(aa, 0),
    };
}

fn formatId(aa: std.mem.Allocator, id: *const [evt.event_id_size]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(id.*, .lower);
    return try aa.dupe(u8, &hex);
}

fn readRecord(
    comptime T: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id: *const [evt.event_id_size]u8,
) !?T.Record {
    const DB = evt.EventDB(hash_kind);
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, T.record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    const record = try DB.HashMap(.read_only).init(record_cursor);
    return try evt.read(T.Record, DB, hash_kind, arena, record);
}

fn readCreatedTs(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !u64 {
    return switch (kind) {
        .user => (try readRecord(evt.User, hash_kind, arena, haxy_moment, id) orelse return error.NotFound).created_ts,
        .repo => (try readRecord(evt.Repo, hash_kind, arena, haxy_moment, id) orelse return error.NotFound).created_ts,
        .issue => (try readRecord(evt.Issue, hash_kind, arena, haxy_moment, id) orelse return error.NotFound).created_ts,
        .comment => (try readRecord(evt.Comment, hash_kind, arena, haxy_moment, id) orelse return error.NotFound).created_ts,
        .attach => (try readRecord(evt.Attachment, hash_kind, arena, haxy_moment, id) orelse return error.NotFound).created_ts,
    };
}

fn readItem(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind_map: evt.EventDB(hash_kind).HashMap(.read_only),
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !?Item {
    var item: Item = .{
        .id = try formatId(arena.allocator(), id),
        .kind = kind,
        .deleted = false,
        .author = .unknown,
    };
    switch (kind) {
        .user => {
            const record = (try readRecord(evt.User, hash_kind, arena, haxy_moment, id)) orelse return null;
            item.deleted = record.deleted;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.event.email);
        },
        .repo => {
            const record = (try readRecord(evt.Repo, hash_kind, arena, haxy_moment, id)) orelse return null;
            item.deleted = record.deleted;
            if (admin_moment) |moment| {
                if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, record.event.user_id)) |user|
                    item.author = .{ .user_name = user.event.name };
            }
        },
        .issue => {
            const record = (try readRecord(evt.Issue, hash_kind, arena, haxy_moment, id)) orelse return null;
            item.deleted = record.deleted;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            const route = ui.RoutablePage.repoIssueCommentsRoute(identity, item.id, 0) orelse return error.RouteTooLong;
            item.view_url = try route.toUrl(arena);
        },
        .comment => {
            const record = (try readRecord(evt.Comment, hash_kind, arena, haxy_moment, id)) orelse return null;
            item.deleted = record.deleted;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            var thread_id: [evt.event_id_size]u8 = undefined;
            _ = std.fmt.hexToBytes(&thread_id, &record.event.thread_id) catch return error.InvalidEventId;
            const thread_kind = (try readKind(hash_kind, kind_map, &thread_id)) orelse return item;
            const route = switch (thread_kind) {
                .issue => ui.RoutablePage.repoCommentsRoute(identity, &record.event.thread_id, item.id, 0),
                else => null,
            } orelse return item;
            item.view_url = try route.toUrl(arena);
        },
        .attach => {
            const record = (try readRecord(evt.Attachment, hash_kind, arena, haxy_moment, id)) orelse return null;
            item.deleted = record.deleted;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            var parent_id: [evt.event_id_size]u8 = undefined;
            _ = std.fmt.hexToBytes(&parent_id, &record.event.parent_id) catch return error.InvalidEventId;
            const parent_kind = (try readKind(hash_kind, kind_map, &parent_id)) orelse return item;
            const route = switch (parent_kind) {
                .issue => ui.RoutablePage.repoIssueCommentsRoute(identity, &record.event.parent_id, 0),
                else => null,
            } orelse return item;
            item.view_url = try route.toUrl(arena);
        },
    }
    return item;
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: ?usize,

    const header_index = 0;
    const content_index = 1;
    const list_index = 0;
    const detail_index = 1;
    const list_max_width = 20;
    const detail_min_width = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        var header_view = try Header.View.init(allocator, &data.header, session);
        errdefer header_view.deinit(allocator);
        try outer.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .repo_events_header = header_view }, .rect = null, .min_size = .{ .width = null, .height = 3 } });

        var content_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer content_box.deinit(allocator);

        var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
        errdefer list_box.deinit(allocator);
        for (data.events) |event| {
            const route = ui.RoutablePage.repoEventsRoute(data.identity, event.kind, event.id) orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(session.page_arena.allocator(), "ai:{s}", .{try route.toUrl(session.page_arena)});
            try addRow(allocator, &list_box, @tagName(event.kind), link);
        }
        if (data.next) |next| {
            const route = ui.RoutablePage.repoEventsRoute(data.identity, next.kind, next.id) orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)});
            try addRow(allocator, &list_box, "next →", link);
        }
        if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
        var list_scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
        errdefer list_scroll.deinit(allocator);
        try content_box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });

        var detail_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer detail_box.deinit(allocator);
        var detail_scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = detail_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
        errdefer detail_scroll.deinit(allocator);
        try content_box.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });

        content_box.getFocus().child_id = content_box.children.keys()[list_index];
        try outer.children.put(allocator, content_box.getFocus().id, .{ .widget = .{ .box = content_box }, .rect = null, .min_size = null });
        outer.getFocus().child_id = outer.children.keys()[if (data.header.is_local) header_index else content_index];
        return .{ .box = outer, .data = data, .session = session, .detailed_index = null };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    fn addField(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, label: []const u8) !void {
        var field = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = label });
        errdefer field.deinit(allocator);
        field.getFocus().focusable = true;
        try box.children.put(allocator, field.getFocus().id, .{ .widget = .{ .text_box = field }, .rect = null, .min_size = null });
    }

    fn addAuthor(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), value: ui.Author) !void {
        var author = try ui.authorBox(allocator, self.session.page_arena, value);
        errdefer author.deinit(allocator);
        try box.children.put(allocator, author.getFocus().id, .{ .widget = .{ .text_box = author }, .rect = null, .min_size = null });
    }

    fn addViewEvent(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), item: Item) !void {
        const url = item.view_url orelse return;

        var link = try wgt.TextBox(ui.Widget).init(allocator, "view event", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer link.deinit(allocator);
        link.getFocus().focusable = true;
        link.getFocus().kind = .{ .custom = try std.fmt.allocPrint(self.session.page_arena.allocator(), "a:{s}", .{url}) };
        try box.children.put(allocator, link.getFocus().id, .{ .widget = .{ .text_box = link }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn header(self: *View) *Header.View {
        return &self.box.children.values()[header_index].widget.repo_events_header;
    }

    fn content(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[content_index].widget.box;
    }

    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.content().children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.listScroll().child.box;
    }

    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.content().children.values()[detail_index].widget.scroll;
    }

    fn detailBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailScroll().child.box;
    }

    fn detailActive(self: *View) bool {
        return self.content().getFocus().child_id == self.detailScroll().getFocus().id;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.header().getFocus().id;
    }

    fn selectedEventIndex(self: *View) ?usize {
        const id = self.listBox().getFocus().child_id orelse return null;
        const index = self.listBox().children.getIndex(id) orelse return null;
        return if (index < self.data.events.len) index else null;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.refreshDetail(allocator);

        if (root_focus.grandchild_id) |id| if (self.box.getFocus().children.contains(id)) {
            if (self.selectedEventIndex()) |index| {
                const event = self.data.events[index];
                if (ui.RoutablePage.repoEventsRoute(self.data.identity, event.kind, event.id)) |route|
                    self.session.data.current_page = route;
            }
        };

        const list = self.listBox();
        for (list.children.keys(), list.children.values()) |id, *child| switch (child.widget) {
            .text_box => |*text_box| text_box.options.border_style = if (list.getFocus().child_id == id) .single else .hidden,
            else => {},
        };

        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        self.content().children.values()[list_index].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const detail_width = if (constraint.max_size.width) |width| if (both_fit) width - list_max_width else width else detail_min_width;
        self.content().children.values()[detail_index].min_size = .{ .width = detail_width, .height = null };
        for (self.detailBox().children.values()) |*child| child.max_size = .{ .width = detail_width -| 2, .height = null };

        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const index = self.selectedEventIndex() orelse return;
        if (self.detailed_index) |old| if (old == index) return;
        const box = self.detailBox();
        for (box.children.values()) |*child| child.widget.deinit(allocator);
        box.children.clearAndFree(allocator);
        box.getFocus().child_id = null;

        const item = self.data.events[index];
        try self.addViewEvent(allocator, box, item);
        try addField(allocator, box, @tagName(item.kind), " kind ");
        try self.addAuthor(allocator, box, item.author);
        if (item.deleted) try addField(allocator, box, "(deleted)", " data ");

        if (box.children.count() > 0) box.getFocus().child_id = box.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        self.detailed_index = index;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (self.headerActive()) {
            if (key == .arrow_down) root_focus.setFocus(self.content().getFocus().id) else try self.header().input(allocator, key, root_focus);
            return;
        }
        if (key == .arrow_up and self.contentAtTop() and self.header().focusButton(root_focus)) return;
        if (self.detailActive()) {
            if (key == .arrow_left) {
                root_focus.setFocus(self.listScroll().getFocus().id);
            } else if (inp.rowDelta(key, @intCast(self.detailBox().children.count()))) |delta| {
                ui.moveRowFocus(self.detailBox(), self.detailScroll(), root_focus, delta);
            }
        } else if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
        } else switch (key) {
            .arrow_right => if (self.detailBox().children.count() > 0) root_focus.setFocus(self.detailScroll().getFocus().id),
            .enter => if (self.selectedEventIndex() != null)
                root_focus.setFocus(self.detailScroll().getFocus().id)
            else if (self.data.next) |next| if (ui.RoutablePage.repoEventsRoute(self.data.identity, next.kind, next.id)) |route| try self.session.navigate(route),
            else => {},
        }
    }

    fn contentAtTop(self: *View) bool {
        const box = if (self.detailActive()) self.detailBox() else self.listBox();
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const id = box.getFocus().child_id orelse return true;
        return box.children.getIndex(id) == 0 and scroll.y == 0;
    }

    pub fn getSelectedIndex(self: *View) ?usize {
        if (self.headerActive()) return 0;
        return if (self.header().isFocusable() or !self.contentAtTop()) 1 else 0;
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }
};

pub const Header = struct {
    status: []const u8,
    is_local: bool,

    const nothing = "nothing to sync";
    const unsynced = "sync needed!";

    const Progress = struct {
        message: *std.Io.Writer.Allocating,

        pub fn run(self: @This(), _: std.Io, event: rp.ProgressEvent) !void {
            switch (event) {
                .text => |value| {
                    self.message.clearRetainingCapacity();
                    try self.message.writer.writeAll(value);
                },
                else => {},
            }
        }
    };

    pub fn local(
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        aa: std.mem.Allocator,
        repo: *rp.Repo(repo_kind, repo_opts),
        io: std.Io,
        failure: ?[]const u8,
    ) !Header {
        if (failure != null) return Header.empty(aa, failure);
        const remote_name = (try remoteName(repo_kind, repo_opts, repo, io, aa)) orelse return .{ .status = nothing, .is_local = true };
        const remote_ref: rf.Ref = .{ .kind = .{ .remote = remote_name }, .name = evt.events_ref.name };
        const local_oid = (try repo.readRef(io, evt.events_ref)) orelse return .{ .status = nothing, .is_local = true };
        const remote_oid = (try repo.readRef(io, remote_ref)) orelse return .{ .status = nothing, .is_local = true };
        return .{ .status = if (std.mem.eql(u8, &local_oid, &remote_oid)) nothing else unsynced, .is_local = true };
    }

    pub fn empty(aa: std.mem.Allocator, failure: ?[]const u8) !Header {
        return .{ .status = if (failure) |name| try std.fmt.allocPrint(aa, "error: {s}", .{name}) else nothing, .is_local = true };
    }

    pub fn remote(aa: std.mem.Allocator, count: usize) !Header {
        return .{ .status = try std.fmt.allocPrint(aa, "{d} events found", .{count}), .is_local = false };
    }

    fn withCount(self: Header, aa: std.mem.Allocator, count: usize) !Header {
        return .{ .status = try std.fmt.allocPrint(aa, "{d} events found - {s}", .{ count, self.status }), .is_local = self.is_local };
    }

    pub const View = struct {
        box: wgt.Box(ui.Widget),
        session: *ui.Session,
        button_id: ?usize,

        pub fn init(allocator: std.mem.Allocator, data: *const Header, session: *ui.Session) !Header.View {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer box.deinit(allocator);
            var button_id: ?usize = null;
            if (data.is_local) {
                box.getFocus().kind = .{ .custom = "form:/sync" };
                var button = try wgt.TextBox(ui.Widget).init(allocator, "sync", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().focusable = true;
                button.getFocus().kind = .{ .custom = "submit" };
                button_id = button.getFocus().id;
                box.getFocus().child_id = button_id;
                try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
            }

            var status = try wgt.TextBox(ui.Widget).init(allocator, data.status, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer status.deinit(allocator);
            try box.children.put(allocator, status.getFocus().id, .{ .widget = .{ .text_box = status }, .rect = null, .min_size = null, .shrink = true });
            return .{ .box = box, .session = session, .button_id = button_id };
        }

        pub fn deinit(self: *Header.View, allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        pub fn build(self: *Header.View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Header.View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const button_id = self.button_id orelse return;
            if (!self.session.is_terminal) return;
            if (self.session.host_request != null) return;
            switch (key) {
                .enter => self.requestSync(),
                .mouse => |mouse| if (inp.leftClickOn(root_focus, button_id, mouse)) self.requestSync(),
                else => {},
            }
            _ = allocator;
        }

        fn requestSync(self: *Header.View) void {
            self.session.host_request = .sync_events;
            const button_id = self.button_id orelse return;
            const child = self.box.children.getPtr(button_id) orelse return;
            const button = switch (child.widget) {
                .text_box => |*button| button,
                else => return,
            };
            button.content = "syncing...";
            for (button.box.children.values()) |*line| switch (line.widget) {
                .text => |*text| text.content = "syncing...",
                else => {},
            };
        }

        pub fn focusButton(self: *Header.View, root_focus: *Focus) bool {
            const button_id = self.button_id orelse return false;
            root_focus.setFocus(button_id);
            return true;
        }

        pub fn isFocusable(self: *Header.View) bool {
            return self.button_id != null;
        }

        pub fn clearGrid(self: *Header.View) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: Header.View) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *Header.View) *Focus {
            return self.box.getFocus();
        }
    };
};

pub fn performSync(allocator: std.mem.Allocator, session: *ui.Session) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const io = session.io orelse return;
    const source = session.local orelse return;
    defer session.refresh_requested = true;
    const failure = sync(io, allocator, source) catch |err| {
        session.data.sync_failure = @errorName(err);
        return;
    };
    if (failure) |message| {
        defer allocator.free(message);
        session.data.sync_failure = try session.arena.allocator().dupe(u8, message);
        return;
    }
    session.data.sync_failure = null;
    switch (session.data.current_page) {
        .repo_events => |route| {
            if (ui.RoutablePage.repoEventsRoute(route.name.slice(), null, "")) |first|
                session.data.current_page = first;
        },
        else => {},
    }
}

fn remoteName(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var remotes = try repo.listRemotes(io, allocator);
    defer remotes.deinit();
    const names = remotes.sections.keys();
    if (names.len == 0) return null;
    for (names) |name| {
        const remote_ref: rf.Ref = .{ .kind = .{ .remote = name }, .name = evt.events_ref.name };
        if (try repo.readRef(io, remote_ref) != null) return try allocator.dupe(u8, name);
    }
    return try allocator.dupe(u8, names[0]);
}

fn isLoopbackSshUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = switch (uri.host orelse return false) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn sync(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !?[]u8 {
    var message: std.Io.Writer.Allocating = .init(allocator);
    defer message.deinit();

    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{ .ProgressCtx = Header.Progress }).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    const remote_name = (try remoteName(repo_kind, repo_opts, repo, io, allocator)) orelse return error.RemoteNotFound;
                    defer allocator.free(remote_name);

                    var config = try repo.listConfig(io, allocator);
                    defer config.deinit();
                    const configured_ssh = if (config.sections.get("core")) |core| core.get("sshcommand") else null;
                    const ssh = if (configured_ssh) |command| if (command.len > 0) command else "ssh" else "ssh";
                    const remote_section = try std.fmt.allocPrint(allocator, "remote.{s}", .{remote_name});
                    defer allocator.free(remote_section);
                    const remote_config = config.sections.get(remote_section) orelse return error.RemoteNotFound;
                    const fetch_url = remote_config.get("url") orelse return error.UrlNotFound;
                    const push_url = remote_config.get("pushurl") orelse fetch_url;
                    const loopback_opts = " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
                    const fetch_ssh_command = try std.fmt.allocPrint(allocator, "{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(fetch_url)) loopback_opts else "" });
                    defer allocator.free(fetch_ssh_command);
                    const push_ssh_command = try std.fmt.allocPrint(allocator, "{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(push_url)) loopback_opts else "" });
                    defer allocator.free(push_ssh_command);
                    const fetch_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = .{ .message = &message }, .wire = .{ .ssh = .{ .command = fetch_ssh_command } } };
                    const push_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = .{ .message = &message }, .wire = .{ .ssh = .{ .command = push_ssh_command } } };

                    const fetch_refspec = try std.fmt.allocPrint(allocator, "+refs/heads/{s}:refs/remotes/{s}/{s}", .{ evt.events_ref.name, remote_name, evt.events_ref.name });
                    defer allocator.free(fetch_refspec);
                    var fetch_opts = fetch_transport_opts;
                    fetch_opts.refspecs = &.{fetch_refspec};
                    message.clearRetainingCapacity();
                    repo.fetch(io, allocator, remote_name, fetch_opts) catch |err| {
                        if (err == error.ServerReportedError and message.written().len != 0) return try allocator.dupe(u8, message.written());
                        return err;
                    };

                    const remote_ref: rf.Ref = .{ .kind = .{ .remote = remote_name }, .name = evt.events_ref.name };
                    const local_oid = try repo.readRef(io, evt.events_ref);
                    const remote_oid = try repo.readRef(io, remote_ref);
                    if (local_oid == null and remote_oid == null) {
                        try evt.consume(repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{});
                        return null;
                    }
                    if (remote_oid != null) try evt.mergeEvents(repo_kind, repo_opts, io, allocator, repo, remote_ref);
                    try evt.consume(repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{});

                    const push_refspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ evt.events_ref.name, evt.events_ref.name });
                    defer allocator.free(push_refspec);
                    message.clearRetainingCapacity();
                    repo.push(io, allocator, remote_name, push_refspec, false, push_transport_opts) catch |err| {
                        if (err == error.ServerReportedError and message.written().len != 0) return try allocator.dupe(u8, message.written());
                        return err;
                    };
                    message.clearRetainingCapacity();
                    repo.fetch(io, allocator, remote_name, fetch_opts) catch |err| {
                        if (err == error.ServerReportedError and message.written().len != 0) return try allocator.dupe(u8, message.written());
                        return err;
                    };
                },
            }
        },
    }
    return null;
}

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("../../ui.zig");
const evt = @import("../../event.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;
const Self = @This();

pub const page_size = 20;

// replaces the description for a transaction that wrote events
pub const EventsLink = struct {
    label: []const u8,
    link: []const u8,
};

pub const Item = struct {
    index: u64,
    action: []const u8,
    description: []const u8,
    timestamp: []const u8,
    link: []const u8,
    form: []const u8,
    events: ?EventsLink = null,
};

identity: []const u8,
count: u64 = 0,
items: []const Item = &.{},
next: ?u64 = null,
failure: ?[]const u8 = null,
can_undo: bool = false,
// the clear-history confirmation stands in for the list
clear: bool = false,

pub fn init(comptime opts: rp.RepoOpts(.xit), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(.xit, opts), identity: []const u8, selected: ?u64) !Self {
    const aa = arena.allocator();
    const DB = rp.Repo(.xit, opts).DB;
    const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());
    const count = try history.count();
    if (selected) |index| if (index >= count) return error.NotFound;
    var items: std.ArrayList(Item) = .empty;
    var remaining = if (selected) |index| index + 1 else count;
    var buffer: [opts.max_read_size]u8 = undefined;
    while (remaining > 0 and items.items.len < page_size) {
        remaining -= 1;
        const cursor = try history.getCursor(remaining) orelse return error.TransactionNotFound;
        const moment = try DB.HashMap(.read_only).init(cursor);
        const record = try xit.undo.read(opts, moment, &buffer);
        var description: std.Io.Writer.Allocating = .init(aa);
        const detail = if (record) |value| try eventDetail(opts, arena, identity, value, moment) else null;
        if (detail) |value| {
            try description.writer.writeAll(value.description);
        } else if (record) |value| {
            try xit.undo.format(opts, &repo.core.db, arena.child_allocator, value, &description.writer);
        } else {
            try description.writer.writeAll("no undo record");
        }
        const route = ui.RoutablePage.repoUndoRoute(identity, remaining) orelse return error.RouteTooLong;
        const url = try route.toUrl(arena);
        try items.append(aa, .{
            .index = remaining,
            .action = if (detail) |value| value.action else if (record) |value| try aa.dupe(u8, value.action) else "unknown",
            .description = description.written(),
            .events = if (detail) |value| value.events else null,
            .timestamp = if (record) |value| try formatTimestamp(aa, value.timestamp) else "timestamp unavailable",
            .link = try std.fmt.allocPrint(aa, "ai:{s}", .{url}),
            .form = try std.fmt.allocPrint(aa, "form:{s}/undo", .{url}),
        });
    }
    return .{ .identity = try aa.dupe(u8, identity), .count = count, .items = items.items, .next = if (remaining > 0) remaining - 1 else null };
}

const Detail = struct {
    action: []const u8,
    description: []const u8,
    events: ?EventsLink = null,
};

// every haxy event transaction shares one action, and the events it wrote are
// named by the moment's index rather than by the record
fn eventDetail(
    comptime opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    identity: []const u8,
    record: xit.undo.UndoRecord,
    moment: rp.Repo(.xit, opts).DB.HashMap(.read_only),
) !?Detail {
    if (std.mem.eql(u8, record.action, evt.merge_undo_action)) return .{ .action = "merge events", .description = "merged the events ref from a remote" };
    if (!std.mem.eql(u8, record.action, evt.undo_action)) return null;

    const description = "updated the event database";
    const batch = try momentBatch(opts, moment) orelse return .{ .action = "events", .description = description };

    const aa = arena.allocator();
    const route = ui.RoutablePage.repoEventsRoute(identity, .active, null, "", batch.index) orelse return error.RouteTooLong;
    return .{
        .action = try std.fmt.allocPrint(aa, "events ({d})", .{batch.count}),
        .description = description,
        .events = .{
            .label = try std.fmt.allocPrint(aa, "view events ({d})", .{batch.count}),
            .link = try std.fmt.allocPrint(aa, "a:{s}", .{try route.toUrl(arena)}),
        },
    };
}

const Batch = struct { index: u64, count: u64 };

// the events the transaction's moment wrote, or null when it wrote none
fn momentBatch(comptime opts: rp.RepoOpts(.xit), moment: rp.Repo(.xit, opts).DB.HashMap(.read_only)) !?Batch {
    const DB = rp.Repo(.xit, opts).DB;
    const haxy_moment = evt.currentMomentFromRepoMoment(opts.hash, moment) catch return null;
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(opts.hash, evt.moment_index_key)) orelse return null;
    const moment_index = try index_cursor.readUint();
    const ids = try evt.momentEventIds(DB, opts.hash, haxy_moment, moment_index) orelse return null;
    return .{ .index = moment_index, .count = try ids.count() };
}

pub fn formatTimestamp(aa: std.mem.Allocator, timestamp: i64) ![]const u8 {
    if (timestamp < 0) return aa.dupe(u8, "timestamp unavailable");
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(aa, "{s} {d}, {d}, {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ months[month.month.numeric() - 1], month.day_index + 1, year.year, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, index: u64) !void {
    if (source.repo_kind != .xit) return error.NotFound;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| try repo.undo(io, index),
    }
}

// discard every earlier transaction by compacting the database. the patch
// revisions events point at are unreachable from the refs, so they are named
// as extra roots to survive the collection.
pub fn clearHistory(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !void {
    if (source.repo_kind != .xit) return error.NotFound;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| {
            const opts = repo.self_repo_opts;
            // a repo that has consumed no events has no revisions to protect
            const roots = if (evt.currentMoment(opts, repo)) |moment|
                try evt.PatchRev.gcRoots(rp.Repo(.xit, opts).DB, opts.hash, allocator, moment)
            else |_|
                &.{};
            defer allocator.free(roots);
            _ = try repo.garbageCollect(io, allocator, .{ .extra_roots = roots });
        },
    }
}

// keep action failures on the current tab without rebuilding a stale route.
pub fn handleRequest(allocator: std.mem.Allocator, session: *ui.Session, target: ui.RoutablePage.RepoUndoRoute) void {
    perform(allocator, session, target) catch |err| {
        session.data.undo_failure = @errorName(err);
        return;
    };
    session.data.undo_failure = null;
}

// both terminal hosts resolve and authorize the request afresh before opening
// the repository; the web handler uses its matching http authorization path.
pub fn perform(allocator: std.mem.Allocator, session: *ui.Session, target: ui.RoutablePage.RepoUndoRoute) !void {
    const identity = target.name.slice();
    const source = try authorizedSource(session, identity) orelse return error.Forbidden;
    const io = session.io orelse return error.NotFound;
    if (target.clear)
        try clearHistory(io, allocator, source)
    else
        try execute(io, allocator, source, target.index orelse return error.InvalidHistoryIndex);
    try session.navigate(ui.RoutablePage.repoUndoRoute(identity, null) orelse return error.RouteTooLong);
}

// the repo an owner may act on, or null when they may not
fn authorizedSource(session: *ui.Session, identity: []const u8) !?ui.RepoSource {
    if (try session.authorize(identity, .owner) == null) return null;
    if (session.local) |local| return local;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const pair = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const found = try evt.Repo.readByOwnerAndName(evt.AdminDB, evt.admin_repo_opts.hash, moment, session.page_arena, pair.owner, pair.name) orelse return error.NotFound;
    const hex = std.fmt.bytesToHex(found.event_id, .lower);
    return .{ .path = try std.fs.path.join(session.page_arena.allocator(), &.{ session.repos_dir orelse return error.NotFound, &hex }), .repo_kind = .xit };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: ?usize = null,
    failure_id: ?usize = null,
    shown_failure: ?[]const u8 = null,

    const list_max_width = 20;
    const detail_min_width = 40;
    const header_index = 0;
    const content_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the sub header carries the tab's only action
        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            const route = ui.RoutablePage.repoUndoClearRoute(data.identity) orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)});
            try addText(allocator, &header, "clear undo history", link, .single);
            header.getFocus().child_id = header.children.keys()[0];
            try outer.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        if (data.clear) {
            var center = try initClearForm(allocator, data, session);
            errdefer center.deinit(allocator);
            try outer.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
            outer.getFocus().child_id = outer.children.keys()[content_index];
            return .{ .box = outer, .data = data, .session = session };
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        {
            var scroll = blk: {
                var rows = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
                errdefer rows.deinit(allocator);
                for (data.items) |item| try addText(allocator, &rows, item.action, item.link, .hidden);
                if (data.next) |next| {
                    const route = ui.RoutablePage.repoUndoRoute(data.identity, next) orelse return error.RouteTooLong;
                    try addText(allocator, &rows, "next →", try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}), .hidden);
                }
                if (data.items.len == 0) try addText(allocator, &rows, "no undo history", null, .hidden);
                if (rows.children.count() > 0) rows.getFocus().child_id = rows.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }
        {
            var scroll = blk: {
                var details = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer details.deinit(allocator);
                if (data.items.len > 0) {
                    try addText(allocator, &details, "", null, .single);
                    try addText(allocator, &details, "", null, .single);
                    details.children.values()[1].widget.text_box.options.label = " timestamp ";
                    try addText(allocator, &details, "", null, .single);
                    details.children.values()[2].widget.text_box.options.label = " description ";
                    details.getFocus().child_id = details.children.keys()[0];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = details }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            scroll.getFocus().mode = .mouse;
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }
        box.getFocus().child_id = box.children.keys()[0];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });
        outer.getFocus().child_id = outer.children.keys()[content_index];
        return .{ .box = outer, .data = data, .session = session };
    }

    // the same shape the thread views use to confirm a removal
    fn initClearForm(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !ui.widget.Center {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoUndoClearRoute(data.identity) orelse return error.RouteTooLong;
        box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "form:{s}", .{try route.toUrl(session.page_arena)}) };

        var prompt = try wgt.Text.init(allocator, "are you sure?");
        errdefer prompt.deinit(allocator);
        try box.children.put(allocator, prompt.getFocus().id, .{ .widget = .{ .text = prompt }, .rect = null, .min_size = null });

        var button = try wgt.TextBox.init(allocator, "clear undo history", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer button.deinit(allocator);
        button.getFocus().mode = .all;
        button.getFocus().kind = if (data.can_undo) .{ .custom = "submit" } else .text_box;
        try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
        box.getFocus().child_id = button.getFocus().id;

        return ui.widget.Center.init(allocator, .{ .box = box });
    }

    fn addText(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: ?[]const u8, border: wgt.BorderStyle) !void {
        var row = try wgt.TextBox.init(allocator, text, .{ .border_style = border, .rounded_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link) |value| row.getFocus().kind = .{ .custom = value };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    fn headerBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[header_index].widget.box;
    }
    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.headerBox().getFocus().id;
    }
    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[content_index].widget.box;
    }
    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[0].widget.scroll;
    }
    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[1].widget.scroll;
    }
    fn selected(self: *View) ?usize {
        const rows = &self.listScroll().child.box;
        const index = rows.children.getIndex(rows.getFocus().child_id orelse return null) orelse return null;
        return if (index < self.data.items.len) index else null;
    }
    fn detailActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.detailScroll().getFocus().id;
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const index = self.selected() orelse return;
        const failure = self.session.data.undo_failure orelse self.data.failure;
        if (self.detailed_index == index and std.meta.eql(self.shown_failure, failure)) return;
        const details = &self.detailScroll().child.box;
        if (self.failure_id) |id| {
            if (details.children.getPtr(id)) |child| child.widget.deinit(allocator);
            _ = details.children.orderedRemove(id);
            self.failure_id = null;
        }
        const item = self.data.items[index];
        const button = &details.children.values()[0].widget.text_box;
        const description = &details.children.values()[2].widget.text_box;
        try button.setContent(allocator, if (item.index == 0) "initial state cannot be undone" else if (item.index == self.data.count - 1) "undo this" else "undo this and all above it");
        // a transaction that wrote events links to them instead of describing itself
        if (item.events) |events| {
            try description.setContent(allocator, events.label);
            description.options.label = " events ";
            description.getFocus().kind = .{ .custom = events.link };
        } else {
            try description.setContent(allocator, item.description);
            description.options.label = " description ";
            description.getFocus().kind = .text_box;
        }
        const enabled = self.data.can_undo and item.index > 0;
        button.getFocus().kind = if (enabled) .{ .custom = "submit" } else .text_box;
        try details.children.values()[1].widget.text_box.setContent(allocator, item.timestamp);
        if (failure) |message| {
            try addText(allocator, details, try std.fmt.allocPrint(self.session.page_arena.allocator(), "error: {s}", .{message}), null, .single);
            self.failure_id = details.children.keys()[details.children.count() - 1];
        }
        self.shown_failure = failure;
        details.getFocus().kind = if (enabled) .{ .custom = item.form } else .container;
        details.getFocus().child_id = details.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        self.detailed_index = index;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        if (self.data.clear) return try self.box.build(allocator, constraint, root_focus);
        try self.refreshDetail(allocator);
        const rows = &self.listScroll().child.box;
        if (self.data.items.len == 0) {
            const failure = self.session.data.undo_failure orelse self.data.failure;
            if (!std.meta.eql(self.shown_failure, failure)) {
                const message = if (failure) |name| try std.fmt.allocPrint(self.session.page_arena.allocator(), "error: {s}", .{name}) else "no undo history";
                try rows.children.values()[0].widget.text_box.setContent(allocator, message);
                self.shown_failure = failure;
            }
        }
        for (rows.children.keys(), rows.children.values()) |id, *child| child.widget.text_box.options.border_style = if (rows.getFocus().child_id == id) .single else .hidden;
        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        self.contentBox().children.values()[0].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const width = if (constraint.max_size.width) |value| if (both_fit) value - list_max_width else value else detail_min_width;
        self.contentBox().children.values()[1].min_size = .{ .width = width, .height = null };
        for (self.detailScroll().child.box.children.values()) |*child| child.max_size = .{ .width = width -| 2, .height = null };
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the sub header sits above whichever content the route selects
        if (self.headerActive()) {
            if (key == .arrow_down) root_focus.setFocus(self.box.children.values()[content_index].widget.getFocus().id);
            return;
        }
        if (self.data.clear) {
            if (key == .arrow_up) root_focus.setFocus(self.headerBox().getFocus().id) else try self.clearInput(key, root_focus);
            return;
        }
        if (key == .arrow_up and self.contentAtTop()) {
            root_focus.setFocus(self.headerBox().getFocus().id);
            return;
        }
        try self.refreshDetail(allocator);
        if (self.detailActive()) {
            const details = &self.detailScroll().child.box;
            if (self.selected()) |index| {
                const button_id = details.children.keys()[0];
                const activated = switch (key) {
                    .enter => root_focus.grandchild_id == button_id,
                    .mouse => |mouse| inp.leftClickOn(root_focus, button_id, mouse),
                    else => false,
                };
                if (activated and self.data.can_undo and self.data.items[index].index > 0) {
                    if (builtin.target.cpu.arch != .wasm32 and self.session.is_terminal and self.session.host_request == null) {
                        const route = ui.RoutablePage.repoUndoRoute(self.data.identity, self.data.items[index].index) orelse return error.RouteTooLong;
                        self.session.host_request = .{ .undo = route.repo_undo };
                    }
                    return;
                }
            }
            if (key == .arrow_left) root_focus.setFocus(self.listScroll().getFocus().id) else if (inp.rowDelta(key, @intCast(details.children.count()))) |delta| ui.widget.moveRowFocus(details, self.detailScroll(), root_focus, delta);
        } else if (inp.rowDelta(key, @intCast(self.listScroll().child.box.children.count()))) |delta| {
            ui.widget.moveRowFocus(&self.listScroll().child.box, self.listScroll(), root_focus, delta);
        } else switch (key) {
            .arrow_right, .enter => if (self.selected() != null) {
                root_focus.setFocus(self.detailScroll().getFocus().id);
            },
            else => {},
        }
    }

    // the confirm button submits the form the web renderer posts
    fn clearInput(self: *View, key: Key, root_focus: *Focus) !void {
        const center = &self.box.children.values()[content_index].widget.center;
        const button_id = center.child.box.getFocus().child_id orelse return;
        const activated = switch (key) {
            .enter => root_focus.grandchild_id == button_id,
            .mouse => |mouse| inp.leftClickOn(root_focus, button_id, mouse),
            else => false,
        };
        if (!activated or !self.data.can_undo) return;
        if (builtin.target.cpu.arch != .wasm32 and self.session.is_terminal and self.session.host_request == null) {
            const route = ui.RoutablePage.repoUndoClearRoute(self.data.identity) orelse return error.RouteTooLong;
            self.session.host_request = .{ .undo = route.repo_undo };
        }
    }

    fn contentAtTop(self: *View) bool {
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const rows = &scroll.child.box;
        const id = rows.getFocus().child_id orelse return true;
        return rows.children.getIndex(id) == 0 and scroll.y == 0;
    }

    // moving up from the sub header returns to the page's tabs
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        root_focus.setFocus(self.headerBox().getFocus().id);
        return true;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
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

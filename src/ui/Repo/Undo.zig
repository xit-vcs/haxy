const std = @import("std");
const builtin = @import("builtin");
const ui = @import("../../ui.zig");
const evt = @import("../../event.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;
const Self = @This();

pub const page_size = 20;
pub const Item = struct {
    index: u64,
    action: []const u8,
    description: []const u8,
    link: []const u8,
    form: []const u8,
};

identity: []const u8,
count: u64,
items: []const Item,
next: ?u64,

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
        var record = try xit.undo.read(opts, moment, &buffer);
        if (record) |*value| {
            if (std.mem.eql(u8, value.action, "update_branch_patch")) value.action = "update_patch";
        }
        var description: std.Io.Writer.Allocating = .init(aa);
        if (record) |value| {
            try xit.undo.format(opts, &repo.core.db, arena.child_allocator, value, &description.writer);
            try description.writer.print("\n\n{s}", .{try formatTimestamp(aa, value.timestamp)});
        } else {
            try description.writer.writeAll("(empty description)\n\ntimestamp unavailable");
        }
        const route = ui.RoutablePage.repoUndoRoute(identity, remaining) orelse return error.RouteTooLong;
        const url = try route.toUrl(arena);
        try items.append(aa, .{
            .index = remaining,
            .action = if (record) |value| try aa.dupe(u8, value.action) else "(empty description)",
            .description = description.written(),
            .link = try std.fmt.allocPrint(aa, "ai:{s}", .{url}),
            .form = try std.fmt.allocPrint(aa, "form:{s}/undo", .{url}),
        });
    }
    return .{ .identity = try aa.dupe(u8, identity), .count = count, .items = items.items, .next = if (remaining > 0) remaining - 1 else null };
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

// both terminal hosts resolve and authorize the request afresh before opening
// the repository; the web handler uses its matching http authorization path.
pub fn perform(allocator: std.mem.Allocator, session: *ui.Session, target: ui.RoutablePage.RepoUndoRoute) !void {
    const index = target.index orelse return error.InvalidHistoryIndex;
    const identity = target.name.slice();
    if (try session.authorize(identity, .write) == null) return error.Forbidden;
    const io = session.io orelse return error.NotFound;
    const source = session.local orelse blk: {
        const admin_repo = session.admin_repo orelse return error.NotFound;
        const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        const pair = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
        const found = try evt.Repo.readByOwnerAndName(evt.AdminDB, evt.admin_repo_opts.hash, moment, session.page_arena, pair.owner, pair.name) orelse return error.NotFound;
        const hex = std.fmt.bytesToHex(found.event_id, .lower);
        break :blk ui.RepoSource{ .path = try std.fs.path.join(session.page_arena.allocator(), &.{ session.repos_dir orelse return error.NotFound, &hex }), .repo_kind = .xit };
    };
    try execute(io, allocator, source, index);
    try session.navigate(ui.RoutablePage.repoUndoRoute(identity, null) orelse return error.RouteTooLong);
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: ?usize = null,

    const list_max_width = 20;
    const detail_min_width = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
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
                    details.getFocus().child_id = details.children.keys()[0];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = details }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            scroll.getFocus().mode = .mouse;
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }
        box.getFocus().child_id = box.children.keys()[0];
        return .{ .box = box, .data = data, .session = session };
    }

    fn addText(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: ?[]const u8, border: wgt.BorderStyle) !void {
        var row = try wgt.TextBox.init(allocator, text, .{ .border_style = border, .rounded_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link) |value| row.getFocus().kind = .{ .custom = value };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.box.children.values()[0].widget.scroll;
    }
    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.box.children.values()[1].widget.scroll;
    }
    fn selected(self: *View) ?usize {
        const rows = &self.listScroll().child.box;
        const index = rows.children.getIndex(rows.getFocus().child_id orelse return null) orelse return null;
        return if (index < self.data.items.len) index else null;
    }
    fn detailActive(self: *View) bool {
        return self.box.getFocus().child_id == self.detailScroll().getFocus().id;
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const index = self.selected() orelse return;
        if (self.detailed_index == index) return;
        const details = &self.detailScroll().child.box;
        const item = self.data.items[index];
        const button = &details.children.values()[0].widget.text_box;
        const description = &details.children.values()[1].widget.text_box;
        try button.setContent(allocator, if (item.index == 0) "initial state cannot be undone" else if (item.index == self.data.count - 1) "undo this" else "undo this and all above it");
        try description.setContent(allocator, item.description);
        details.getFocus().kind = if (item.index > 0) .{ .custom = item.form } else .container;
        button.getFocus().kind = if (item.index > 0) .{ .custom = "submit" } else .text_box;
        details.getFocus().child_id = details.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        self.detailed_index = index;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.refreshDetail(allocator);
        const rows = &self.listScroll().child.box;
        for (rows.children.keys(), rows.children.values()) |id, *child| child.widget.text_box.options.border_style = if (rows.getFocus().child_id == id) .single else .hidden;
        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        self.box.children.values()[0].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const width = if (constraint.max_size.width) |value| if (both_fit) value - list_max_width else value else detail_min_width;
        self.box.children.values()[1].min_size = .{ .width = width, .height = null };
        for (self.detailScroll().child.box.children.values()) |*child| child.max_size = .{ .width = width -| 2, .height = null };
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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
                if (activated and self.data.items[index].index > 0) {
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

    pub fn atTop(self: *View) bool {
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const rows = &scroll.child.box;
        const id = rows.getFocus().child_id orelse return true;
        return rows.children.getIndex(id) == 0 and scroll.y == 0;
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

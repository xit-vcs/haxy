const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

pub const page_size = 20; // how many users one window shows

users: []const evt.User.Public,
start: usize, // the window start this page was built with, mirrored into the url
next_start: ?usize, // the `start` for the "next" row, or null when this is the last window
search: ?[]const u8, // the name prefix the list is narrowed to (decoded; null = no search)

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    route: ui.RoutablePage.HomeUsersRoute,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;
    const aa = arena.allocator();

    var result: Self = .{
        .users = &.{},
        .start = route.start,
        .next_start = null,
        .search = if (route.search.len == 0) null else std.Uri.percentDecodeInPlace(try aa.dupe(u8, route.search.slice())),
    };
    const prefix = result.search orelse "";

    // the active users sorted by name; absent until the first user exists
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.User.name_index_key)) orelse return result;
    const index = try DB.SortedMap(.read_only).init(index_cursor);

    // the names with the prefix are contiguous from its rank, so the window
    // is one seek then a walk that stops at the first name without it
    var users: std.ArrayList(evt.User.Public) = .empty;
    var iter = try index.iteratorFromIndex(try index.rank(prefix) +| route.start);
    while (try iter.next()) |cursor| {
        const pair = try cursor.readKeyValuePair();
        const name = try pair.key_cursor.readBytesAlloc(aa, null);
        if (!std.mem.startsWith(u8, name, prefix)) break;
        if (users.items.len == page_size) {
            result.next_start = route.start + page_size;
            break;
        }
        try users.append(aa, .{ .name = name });
    }
    result.users = users.items;
    return result;
}

// a first window without users, which shows the empty message
fn isEmpty(self: *const Self) bool {
    return self.users.len == 0 and self.start == 0;
}

pub const View = struct {
    // a vertical box: the search sub-header above the scrolling list. focus
    // points at the header's box or the list's selected row.
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index = 0;
    const list_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var header_scroll = try ui.widget.HeaderScroll.init(allocator, session);
            errdefer header_scroll.deinit(allocator);
            const header = header_scroll.row();
            {
                var search_box = try ui.widget.SearchBox.init(allocator, session, " search ", data.search, .{ .home_users = .{} });
                errdefer search_box.deinit(allocator);
                header.getFocus().child_id = search_box.getFocus().id;
                try header.children.put(allocator, search_box.getFocus().id, .{ .widget = .{ .search_box = search_box }, .rect = null, .min_size = ui.widget.SearchBox.min_size });
            }
            // the spacer keeps the box at its own width
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try header.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
            try box.children.put(allocator, header_scroll.getFocus().id, .{ .widget = .{ .header_scroll = header_scroll }, .rect = null, .min_size = .{ .width = null, .height = ui.widget.SearchBox.min_size.height } });
        }

        // an empty first window has no rows, not even paging ones
        if (data.isEmpty()) {
            var center = try ui.widget.initEmpty(allocator);
            errdefer center.deinit(allocator);
            try box.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
        } else {
            var list = try ui.widget.FlowBox.Scroll.init(allocator, .{ .cell_height = 1 }, !session.is_terminal);
            errdefer list.deinit(allocator);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            const route = (ui.RoutablePage{ .home_users = .{} }).withSearch(data.search orelse "") orelse return error.RouteTooLong;

            // a leading "previous" row off the first window, one row per user, then
            // a trailing "next" row when more remain. each window row navigates to the
            // adjacent window (full reload on web, Nav rebuild on the TUI).
            var items: std.ArrayList(ui.widget.FlowBox.Item) = .empty;
            if (data.start > 0) {
                var prev = route;
                prev.home_users.start = data.start -| page_size;
                try items.append(aa, .{ .text = "← previous", .link = try aa.print("a:{s}", .{try prev.toUrl(&arena)}) });
            }
            for (data.users) |user|
                // clicking a user opens their page; the "a:" prefix makes the web
                // renderer emit an <a href="/foo"> anchor.
                try items.append(aa, .{
                    .text = user.name,
                    .link = try aa.print("a:/{s}", .{user.name}),
                });
            if (data.next_start) |next_start| {
                var next = route;
                next.home_users.start = next_start;
                try items.append(aa, .{ .text = "next →", .link = try aa.print("a:{s}", .{try next.toUrl(&arena)}) });
            }
            try list.setItems(allocator, items.items);

            try box.children.put(allocator, list.getFocus().id, .{ .widget = .{ .flow_box_scroll = list }, .rect = null, .min_size = null });
        }

        // search results start in the box so the term can be refined right away
        box.getFocus().child_id = box.children.keys()[if (data.search != null) header_index else list_index];
        return .{ .box = box, .data = data, .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // clear the incoming min height so the list scrolls within what's left
        try self.box.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            const search_box = self.searchBox();
            if (direction == .down) {
                // the empty message has nothing to focus
                if (!self.data.isEmpty()) root_focus.setFocus(self.listScroll().getFocus().id);
                return;
            }
            if (key == .enter) {
                const text = try search_box.text(allocator);
                defer allocator.free(text);
                return self.submit(text);
            }
            return search_box.input(allocator, key, root_focus);
        }
        // up from the first row reaches the search box
        if (direction == .up and self.listScroll().atTop()) return self.focusHeader(root_focus);
        try self.listScroll().input(allocator, key, root_focus);
    }

    // the users narrowed to `text` from the first window. an empty box on an
    // unsearched page has nothing to clear.
    fn submit(self: *View, text: []const u8) !void {
        if (text.len == 0 and self.data.search == null) return;
        try self.session.navigate((ui.RoutablePage{ .home_users = .{} }).withSearch(text) orelse return);
    }

    fn searchBox(self: *View) *ui.widget.SearchBox {
        return &self.box.children.values()[header_index].widget.header_scroll.row().children.values()[0].widget.search_box;
    }

    fn listScroll(self: *View) *ui.widget.FlowBox.Scroll {
        return &self.box.children.values()[list_index].widget.flow_box_scroll;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
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

    // up leaves the tab from the search box
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    pub fn focusHeader(self: *View, root_focus: *Focus) void {
        root_focus.setFocus(self.searchBox().getFocus().id);
    }
};

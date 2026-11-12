const std = @import("std");
const evt = @import("../event.zig");
const notify = @import("../notify.zig");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const page_size = 20; // how many notifs one window shows

// a notif as the list shows it
pub const Row = struct {
    title: []const u8,
    // the thread's url
    url: []const u8,
    // the thread's repo, as "owner:name"
    identity: []const u8,
    unread: bool,
};

// the logged-in user's notifications window, empty when logged out
rows: []const Row,
start: usize, // the window start this page was built with, mirrored into the url
next_start: ?usize, // the `start` for the "next" row, or null when this is the last window
// the sub tab the route names
view: ui.RoutablePage.UserView,
ssh_keys: ui.UserKeys = .{},

const Self = @This();

// also refreshes the session's unread count
pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session, tab: ui.RoutablePage.UserTab) !Self {
    var result: Self = .{ .rows = &.{}, .start = tab.start, .next_start = null, .view = tab.view };
    // zero until read, so a logout leaves no stale count
    session.data.unread_notifs = 0;
    // local mode has no users
    if (session.data.host_kind != .server) return result;
    const user_id = session.userId() orelse return result;
    result.ssh_keys = try ui.UserKeys.init(arena, session, &user_id, tab);
    const io = session.io orelse return error.NoMoment;
    const users_path = session.users_path orelse return error.NoMoment;
    const gpa = arena.child_allocator;
    const aa = arena.allocator();

    var user_repo = (try evt.openUserRepo(io, gpa, users_path, &user_id)) orelse return result;
    defer user_repo.deinit(io, gpa);
    const moment = (try notify.latestMoment(&user_repo)) orelse return result;
    session.data.unread_notifs = try notify.unreadCount(moment);

    const items = try notify.readRecent(moment, arena, tab.start, page_size + 1);
    if (items.len > page_size) result.next_start = tab.start + page_size;
    const rows = try aa.alloc(Row, @min(items.len, page_size));
    for (rows, items[0..rows.len]) |*row, item| {
        const identity = try aa.print("{s}:{s}", .{ item.notif.owner_name, item.notif.repo_name });
        const route = ui.RoutablePage.repoThreadCommentsRoute(item.notif.thread_kind, identity, &std.fmt.bytesToHex(item.notif.thread_id, .lower), 0) orelse return error.RouteTooLong;
        row.* = .{ .title = item.notif.title, .url = try route.toUrl(arena), .identity = identity, .unread = item.unread };
    }
    result.rows = rows;
    return result;
}

// a first window without notifs, which shows the empty message
fn isEmpty(self: *const Self) bool {
    return self.rows.len == 0 and self.start == 0;
}

// leave the user tab for the page it belongs to, where the web's logout redirect also lands
pub fn logOut(session: *ui.Session) !void {
    try session.forgetSshKey();
    session.logOut();
    try session.navigate(session.data.current_page.pageRoot());
}

const repos_label = "view repos";
const logout_label = "logout";

// the notifications, user settings, ssh keys and delete sub tabs over their content, with the logout button across from them
pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    // the sub tabs' ids then the repos and logout buttons', in header order
    control_ids: [6]usize,
    // the sub tab whose content shows
    view_index: usize,

    const header_index = 0;
    const content_index = 1;
    // the sub tabs come first in `control_ids`
    const tab_count = 4;
    const repos_index = 4;
    const logout_index = 5;

    // `user_route` is the page's user tab route
    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, user_route: ui.RoutablePage) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        var control_ids: [6]usize = undefined;
        const settings_route = user_route.withUserTab(.{ .view = .settings });
        const keys_route = user_route.withUserTab(.{ .view = .keys });
        const delete_route = user_route.withUserTab(.{ .view = .delete });
        {
            var header_scroll = try ui.widget.HeaderScroll.init(allocator, session);
            errdefer header_scroll.deinit(allocator);
            const header = header_scroll.row();
            const on_tab = std.meta.activeTag(session.data.current_page) == std.meta.activeTag(user_route);
            const routes = [_]ui.RoutablePage{ user_route.withUserTab(.{}), settings_route, keys_route, delete_route };
            for ([_]ui.RoutablePage.UserView{ .notifications, .settings, .keys, .delete }, [_][]const u8{ "notifications", "user settings", "ssh keys", "delete user" }, routes, 0..) |view, label, route, index| {
                const count_label = if (view == .notifications) try ui.UserSettings.notifCountLabel(session) else "";
                var tab = try wgt.TextBox.init(allocator, label, .{ .border = .hidden, .round_corners = true, .wrap_kind = .none, .bottom_label = .{ .text = count_label } });
                errdefer tab.deinit(allocator);
                tab.getFocus().mode = .all;
                tab.getFocus().kind = .{ .custom = try ui.inPageTabLink(session, route, on_tab and data.view == view) };
                control_ids[index] = tab.getFocus().id;
                try header.children.put(allocator, tab.getFocus().id, .{ .widget = .{ .text_box = tab }, .rect = null, .min_size = .{ .width = @max(label.len, count_label.len) + 2, .height = null } });
            }
            // the spacer pushes the buttons to the right edge
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try header.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
            {
                var button = try wgt.TextBox.init(allocator, repos_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().mode = .all;
                button.getFocus().kind = .{ .custom = try ui.userLink(session.page_arena, session.data.user_name orelse unreachable) };
                control_ids[repos_index] = button.getFocus().id;
                try header.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = repos_label.len + 2, .height = 3 } });
            }
            {
                // the form kind makes the web renderer post the button to the logout route
                header.getFocus().kind = .{ .custom = try session.page_arena.allocator().print("form:{s}/logout", .{try settings_route.toUrl(session.page_arena)}) };
                var button = try wgt.TextBox.init(allocator, logout_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().mode = .all;
                button.getFocus().kind = .{ .custom = "submit" };
                control_ids[logout_index] = button.getFocus().id;
                try header.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = logout_label.len + 2, .height = 3 } });
            }
            header.getFocus().child_id = control_ids[@backingInt(data.view)];
            // a row taller than the button, leaving a blank line beneath it
            try box.children.put(allocator, header_scroll.getFocus().id, .{ .widget = .{ .header_scroll = header_scroll }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);
            // an empty first window has no rows, not even paging ones
            if (data.isEmpty()) {
                var center = try ui.widget.initEmpty(allocator);
                errdefer center.deinit(allocator);
                try stack.children.put(allocator, center.getFocus().id, .{ .center = center });
            } else {
                var list = try ui.widget.FlowBox.Scroll.init(allocator, .{}, !session.is_terminal);
                errdefer list.deinit(allocator);

                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const aa = arena.allocator();

                // a leading "previous" row off the first window, one row per
                // notif, then a trailing "next" row when more remain
                var items: std.ArrayList(ui.widget.FlowBox.Item) = .empty;
                if (data.start > 0) {
                    const prev = user_route.withUserTab(.{ .start = data.start -| page_size });
                    try items.append(aa, .{ .text = "← previous", .link = try aa.print("a:{s}", .{try prev.toUrl(&arena)}) });
                }
                for (data.rows) |row| try items.append(aa, .{
                    .text = row.title,
                    .link = try aa.print("a:{s}", .{row.url}),
                    .bottom_label = try aa.print("{s} {s}", .{ if (row.unread) "☐" else "☑", row.identity }),
                    .bold = row.unread,
                });
                if (data.next_start) |next_start| {
                    const next = user_route.withUserTab(.{ .start = next_start });
                    try items.append(aa, .{ .text = "next →", .link = try aa.print("a:{s}", .{try next.toUrl(&arena)}) });
                }
                try list.setItems(allocator, items.items);
                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }
            {
                var settings = try ui.UserSettings.View.init(allocator, session, settings_route);
                errdefer settings.deinit(allocator);
                try stack.children.put(allocator, settings.getFocus().id, .{ .user_settings = settings });
            }
            {
                var keys = try ui.UserKeys.View.init(allocator, &data.ssh_keys, session, keys_route);
                errdefer keys.deinit(allocator);
                try stack.children.put(allocator, keys.getFocus().id, .{ .user_keys = keys });
            }
            {
                var delete = try ui.Delete.View.init(allocator, .{ .target = .{ .user = session.data.user_name orelse unreachable } }, session, delete_route);
                errdefer delete.deinit(allocator);
                try stack.children.put(allocator, delete.getFocus().id, .{ .delete_form = delete });
            }
            stack.getFocus().child_id = stack.children.keys()[@backingInt(data.view)];
            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }
        box.getFocus().child_id = box.children.keys()[content_index];
        return .{ .box = box, .data = data, .session = session, .control_ids = control_ids, .view_index = @backingInt(data.view) };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn headerBox(self: *View) *wgt.Box(ui.Widget) {
        return self.box.children.values()[header_index].widget.header_scroll.row();
    }

    fn contentStack(self: *View) *wgt.Stack(ui.Widget) {
        return &self.box.children.values()[content_index].widget.stack;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = self.headerBox();
        // focusing a sub tab shows its content, while the logout button leaves it
        if (header.getFocus().child_id) |child_id| if (std.mem.indexOfScalar(usize, self.control_ids[0..tab_count], child_id)) |index| {
            self.view_index = index;
        };
        for (self.control_ids[0..tab_count], 0..) |id, index| {
            const tab = header.children.getPtr(id) orelse unreachable;
            ui.widget.markSelected(&tab.widget.text_box, index == self.view_index);
        }
        self.contentStack().getFocus().child_id = self.contentStack().children.keys()[self.view_index];
        // clear the incoming min height so the list scrolls within what's left
        try self.box.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const logout_id = self.control_ids[logout_index];
        if (key == .mouse and inp.leftClickOn(root_focus, logout_id, key.mouse)) return logOut(self.session);
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            const focused = root_focus.grandchild_id orelse return;
            if (key == .enter and focused == logout_id) return logOut(self.session);
            if (direction == .down) {
                // the empty message has nothing to focus
                if (self.view_index == @backingInt(ui.RoutablePage.UserView.notifications) and self.data.isEmpty()) return;
                root_focus.setFocus(self.contentStack().getFocus().id);
            } else if (std.mem.indexOfScalar(usize, &self.control_ids, focused)) |current| {
                if (inp.moveTab(key, current, self.control_ids.len)) |next| root_focus.setFocus(self.control_ids[next]);
            }
            return;
        }
        if (direction == .up) if (self.contentStack().getSelected()) |selected| if (selected.atTop(root_focus)) {
            root_focus.setFocus(self.control_ids[self.view_index]);
            return;
        };
        try self.contentStack().input(allocator, key, root_focus);
    }

    // moving up from the sub header returns to the page's tabs
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        root_focus.setFocus(self.control_ids[self.view_index]);
        return true;
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

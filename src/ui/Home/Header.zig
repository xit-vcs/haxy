const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const AuthTab = @import("./AuthTab.zig");

auth_tab: AuthTab,

const Self = @This();

pub fn init() Self {
    return .{ .auth_tab = AuthTab.init() };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    tab_ids: [3]usize,

    const auth_tab_index: usize = 2;
    // the auth slot must fit either "login" or "logout"
    const auth_tab_min_width: usize = @as(usize, "logout".len) + 2;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .horiz });
        errdefer box.deinit(allocator);

        var tab_ids: [3]usize = undefined;

        // fixed tabs: users, repos
        const fixed_tab_names = [_][]const u8{ "users", "repos" };
        for (fixed_tab_names, 0..) |name, i| {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, name, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            tab_ids[i] = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = name.len + 2, .height = null },
            });
        }

        // spacer pushes the auth tab to the right
        {
            var spacer = ui.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try box.children.put(allocator, spacer.getFocus().id, .{
                .widget = .{ .spacer = spacer },
                .rect = null,
                .min_size = .{ .width = 1, .height = null },
            });
        }

        // auth tab — knows how to swap its own label based on session
        {
            var auth_tab = try AuthTab.View.init(allocator, &data.auth_tab, session);
            errdefer auth_tab.deinit(allocator);
            tab_ids[auth_tab_index] = auth_tab.getFocus().id;
            try box.children.put(allocator, auth_tab.getFocus().id, .{
                .widget = .{ .home_auth_tab = auth_tab },
                .rect = null,
                .min_size = .{ .width = auth_tab_min_width, .height = null },
            });
        }

        var self = View{ .box = box, .data = data, .tab_ids = tab_ids };
        // initial selected tab follows session.data.current_page — the web
        // layer decides this from the request URL, the TTY uses whatever
        // the session arrives with — so we don't bake a default here.
        self.getFocus().child_id = tab_ids[switch (session.data.current_page) {
            .home_users => 0,
            .home_repos => 1,
            .home_auth => 2,
        }];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            const tb: ?*wgt.TextBox(ui.Widget) = switch (child.widget) {
                .text_box => |*x| x,
                .home_auth_tab => |*at| &at.text_box,
                else => null,
            };
            if (tb) |t| {
                t.options.border_style = if (self.getFocus().child_id == id) .single else .hidden;
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        var new_tab = current_tab;
        switch (key) {
            .arrow_left => new_tab -|= 1,
            .arrow_right => if (new_tab + 1 < self.tab_ids.len) {
                new_tab += 1;
            },
            else => {},
        }
        if (new_tab != current_tab) {
            try root_focus.setFocus(self.tab_ids[new_tab]);
        }
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

    pub fn getSelectedIndex(self: View) ?usize {
        return self.currentTabIndex();
    }

    fn currentTabIndex(self: View) ?usize {
        const child_id = self.box.focus.child_id orelse return null;
        for (self.tab_ids, 0..) |id, i| {
            if (id == child_id) return i;
        }
        return null;
    }
};

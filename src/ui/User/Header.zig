const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const AuthTab = @import("./../AuthTab.zig");

name: []const u8,
title: ui.Title,
auth_tab: AuthTab,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, name: []const u8) !Self {
    return .{
        .name = name,
        .title = try ui.Title.init(arena, name),
        .auth_tab = AuthTab.init(),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .rounded_corners = true, .direction = .horiz });
        errdefer box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        // title sits to the left of the tabs
        {
            var title_view = try ui.Title.View.init(allocator, &data.title);
            errdefer title_view.deinit(allocator);
            title_view.getFocus().focusable = true;
            title_view.getFocus().kind = .{ .custom = "a:/" };
            // shrink the title when there is not enough space
            try box.children.put(allocator, title_view.getFocus().id, .{
                .widget = .{ .title = title_view },
                .rect = null,
                .min_size = null,
                .shrink = true,
            });
        }

        // spacer
        {
            var text = try wgt.Text(ui.Widget).init(allocator, " ");
            errdefer text.deinit(allocator);
            try box.children.put(allocator, text.getFocus().id, .{
                .widget = .{ .text = text },
                .rect = null,
                .min_size = .{ .width = 1, .height = null },
            });
        }

        // every tab link is user-scoped so selecting one stays on this page —
        // switching its stack and updating the url — instead of navigating to
        // the global settings or auth pages. the "ai:" prefix makes each an
        // in-page anchor: crossPageLink ignores it so a wasm click just switches
        // tabs (the page already holds every tab's content), while the href is
        // still followed with js off. allocated in the page arena so the focus
        // kinds that borrow them live as long as this page's widget tree.
        const aa = session.page_arena.allocator();
        const repos_link = try std.fmt.allocPrint(aa, "ai:/user/{s}", .{data.name});
        const settings_link = try std.fmt.allocPrint(aa, "ai:/user/{s}/settings", .{data.name});
        const auth_link = try std.fmt.allocPrint(aa, "ai:/user/{s}/auth", .{data.name});

        // the tab matching the current page is focused initially; matching by
        // link (rather than position) keeps this robust to tab changes.
        const current_link: []const u8 = switch (session.data.current_page) {
            .user_settings => settings_link,
            .user_auth => auth_link,
            else => repos_link,
        };
        var selected_tab: ?usize = null;

        // repos tab
        {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "repos", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = repos_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, repos_link, current_link)) selected_tab = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "repos".len + 2, .height = null },
            });
        }

        // spacer pushes settings + auth to the right
        {
            var spacer = try ui.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try box.children.put(allocator, spacer.getFocus().id, .{
                .widget = .{ .spacer = spacer },
                .rect = null,
                .min_size = null,
            });
        }

        // settings tab
        {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "settings", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = settings_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, settings_link, current_link)) selected_tab = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "settings".len + 2, .height = null },
            });
        }

        // auth tab (login / logout). AuthTab defaults to the global ai:/auth
        // link; repoint its instance at this user's auth route so it stays local.
        {
            var auth_tab = try AuthTab.View.init(allocator, &data.auth_tab, session);
            errdefer auth_tab.deinit(allocator);
            auth_tab.text_box.getFocus().kind = .{ .custom = auth_link };
            try tab_ids.put(allocator, auth_tab.getFocus().id, {});
            if (std.mem.eql(u8, auth_link, current_link)) selected_tab = auth_tab.getFocus().id;
            try box.children.put(allocator, auth_tab.getFocus().id, .{
                .widget = .{ .auth_tab = auth_tab },
                .rect = null,
                .min_size = .{ .width = AuthTab.min_width, .height = null },
            });
        }

        // quit tab
        if (session.is_terminal) {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, ui.Quit.tab_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = ui.Quit.tab_kind };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                // the label is a single column; +2 for the border
                .min_size = .{ .width = 1 + 2, .height = null },
            });
        }

        var self = View{ .box = box, .data = data, .tab_ids = tab_ids };
        self.getFocus().child_id = selected_tab orelse self.tab_ids.keys()[0];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        self.tab_ids.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // only the selected tab shows its border
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            const tb: ?*wgt.TextBox(ui.Widget) = switch (child.widget) {
                .text_box => |*x| x,
                .auth_tab => |*at| &at.text_box,
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
            .arrow_right => if (new_tab + 1 < self.tab_ids.count()) {
                new_tab += 1;
            },
            else => {},
        }
        if (new_tab != current_tab) {
            root_focus.setFocus(self.tab_ids.keys()[new_tab]);
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
        return self.tab_ids.getIndex(child_id);
    }
};

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

const RefOrOid = ui.RoutablePage.RefOrOid;

name: []const u8,
owner_name: []const u8,
title: ui.Title,
auth_tab: AuthTab,
// the ref/oid this page is viewing, so the files and commits tabs both link to
// it (switching tabs keeps the same ref). the value is url-encoded.
ref_or_oid: RefOrOid,
ref_or_oid_value: []const u8,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, name: []const u8, owner_name: []const u8, ref_or_oid: RefOrOid, ref_or_oid_value: []const u8) !Self {
    return .{
        .name = name,
        .owner_name = owner_name,
        .title = try ui.Title.init(arena, name),
        .auth_tab = AuthTab.init(),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = ref_or_oid_value,
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

        const aa = session.page_arena.allocator();

        // the user's name
        {
            const text = try std.fmt.allocPrint(aa, "{s}/", .{data.owner_name});
            const link = try std.fmt.allocPrint(aa, "a:/user/{s}", .{data.owner_name});

            var text_box = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = link };
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = null,
                .shrink = true,
            });
        }

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

        // every tab link is repo-scoped so selecting one stays on this page —
        // switching its stack and updating the url — instead of navigating to
        // the global settings or auth pages. the "ai:" prefix makes each an
        // in-page anchor: crossPageLink ignores it so a wasm click just switches
        // tabs (the page already holds every tab's content), while the href is
        // still followed with js off. the files tab routes through the shared
        // helper so the /repo/.../files url format lives in one place.
        const identity = try std.fmt.allocPrint(aa, "{s}/{s}", .{ data.owner_name, data.name });
        // both tabs link to the ref/oid this page is viewing, so switching tabs
        // keeps the same ref (the files tab opens at its root directory).
        const files_route = ui.RoutablePage.repoFilesRoute(identity, data.ref_or_oid, data.ref_or_oid_value, "", 0) orelse return error.RouteTooLong;
        const files_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try files_route.urlAlloc(session.page_arena)});
        const commits_route = ui.RoutablePage.repoCommitsRoute(identity, data.ref_or_oid, data.ref_or_oid_value, 0) orelse return error.RouteTooLong;
        const commits_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try commits_route.urlAlloc(session.page_arena)});
        const refs_link = try std.fmt.allocPrint(aa, "ai:/repo/{s}/{s}/refs", .{ data.owner_name, data.name });
        const settings_link = try std.fmt.allocPrint(aa, "ai:/repo/{s}/{s}/settings", .{ data.owner_name, data.name });
        const auth_link = try std.fmt.allocPrint(aa, "ai:/repo/{s}/{s}/auth", .{ data.owner_name, data.name });

        // the tab matching the current page is focused initially; matching by
        // link (rather than position) keeps this robust to tab changes.
        const current_link: []const u8 = switch (session.data.current_page) {
            .repo_commits => commits_link,
            .repo_refs => refs_link,
            .repo_settings => settings_link,
            .repo_auth => auth_link,
            else => files_link,
        };
        var selected_tab: ?usize = null;

        // files tab
        {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "files", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = files_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, files_link, current_link)) selected_tab = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "files".len + 2, .height = null },
            });
        }

        // commits tab
        {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "commits", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = commits_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, commits_link, current_link)) selected_tab = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "commits".len + 2, .height = null },
            });
        }

        // refs tab
        {
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "refs", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = refs_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, refs_link, current_link)) selected_tab = text_box.getFocus().id;
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "refs".len + 2, .height = null },
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
        // link; repoint its instance at this repo's auth route so it stays local.
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

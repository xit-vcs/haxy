const std = @import("std");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const repos_tab_label = "repos";
const forks_tab_label = "forks";
const settings_tab_label = "settings";

pub const AuthTab = @import("./../AuthTab.zig");

name: []const u8,
title: ui.Title,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, name: []const u8) !Self {
    return .{
        .name = name,
        .title = try ui.Title.init(arena, name, .scanlines),
    };
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),
    tabs_id: usize,
    gap_id: usize,
    first_group_width: usize,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .rounded_corners = true, .direction = .horiz });
        errdefer box.deinit(allocator);

        var title_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        var title_box_owned = false;
        errdefer if (!title_box_owned) title_box.deinit(allocator);

        var tabs_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        var tabs_box_owned = false;
        errdefer if (!tabs_box_owned) tabs_box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        // the leading space plus the title
        const first_group_width = 1 + try data.title.width();

        try ui.widget.addBackButton(allocator, &title_box, session);

        {
            var text = try wgt.Text.init(allocator, " ");
            errdefer text.deinit(allocator);
            try title_box.children.put(allocator, text.getFocus().id, .{
                .widget = .{ .text = text },
                .rect = null,
                .min_size = .{ .width = 1, .height = null },
            });
        }

        // title sits to the left of the tabs
        {
            var title_view = try ui.Title.View.init(allocator, &data.title);
            errdefer title_view.deinit(allocator);
            title_view.getFocus().mode = .all;
            title_view.getFocus().kind = .{ .custom = "a:/" };
            try title_box.children.put(allocator, title_view.getFocus().id, .{
                .widget = .{ .title = title_view },
                .rect = null,
                .min_size = null,
            });
        }

        // spacer
        {
            var text = try wgt.Text.init(allocator, " ");
            errdefer text.deinit(allocator);
            try tabs_box.children.put(allocator, text.getFocus().id, .{
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
        const current_page = session.data.current_page;
        const current_tag = std.meta.activeTag(current_page);
        const current_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try current_page.toUrl(session.page_arena)});
        const repos_link = if (current_tag == .user_repos) current_link else try std.fmt.allocPrint(aa, "ai:/user/{s}", .{data.name});
        const forks_link = if (current_tag == .user_forks) current_link else try std.fmt.allocPrint(aa, "ai:/user/{s}/forks", .{data.name});
        const settings_link = if (current_tag == .user_settings) current_link else try std.fmt.allocPrint(aa, "ai:/user/{s}/settings", .{data.name});
        const auth_link = if (current_tag == .user_auth) current_link else try std.fmt.allocPrint(aa, "ai:/user/{s}/auth", .{data.name});

        // the tab matching the current page is focused initially; matching by
        // link (rather than position) keeps this robust to tab changes.
        const selected_link: []const u8 = switch (current_page) {
            .user_settings => settings_link,
            .user_auth => auth_link,
            .user_forks => forks_link,
            else => repos_link,
        };
        var selected_tab: ?usize = null;

        // repos tab
        {
            var text_box = try wgt.TextBox.init(allocator, repos_tab_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().mode = .all;
            text_box.getFocus().kind = .{ .custom = repos_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, repos_link, selected_link)) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = repos_tab_label.len + 2, .height = null },
            });
        }

        // forks tab
        {
            var text_box = try wgt.TextBox.init(allocator, forks_tab_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().mode = .all;
            text_box.getFocus().kind = .{ .custom = forks_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, forks_link, selected_link)) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = forks_tab_label.len + 2, .height = null },
            });
        }

        // spacer pushes settings + auth to the right
        {
            var spacer = try ui.widget.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try tabs_box.children.put(allocator, spacer.getFocus().id, .{
                .widget = .{ .spacer = spacer },
                .rect = null,
                .min_size = null,
                .flex = .grow,
            });
        }

        // settings tab. settings are account preferences, so it needs a login.
        if (session.data.user_id != null) {
            var text_box = try wgt.TextBox.init(allocator, settings_tab_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().mode = .all;
            text_box.getFocus().kind = .{ .custom = settings_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (std.mem.eql(u8, settings_link, selected_link)) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = settings_tab_label.len + 2, .height = null },
            });
        }

        // auth tab (login / logout). AuthTab defaults to the global ai:/auth
        // link; repoint its instance at this user's auth route so it stays local.
        {
            var auth_tab = try AuthTab.View.init(allocator, session);
            errdefer auth_tab.deinit(allocator);
            auth_tab.text_box.getFocus().kind = .{ .custom = auth_link };
            try tab_ids.put(allocator, auth_tab.getFocus().id, {});
            if (std.mem.eql(u8, auth_link, selected_link)) selected_tab = auth_tab.getFocus().id;
            try tabs_box.children.put(allocator, auth_tab.getFocus().id, .{
                .widget = .{ .auth_tab = auth_tab },
                .rect = null,
                .min_size = .{ .width = auth_tab.minWidth(), .height = null },
            });
        }

        // quit tab
        if (session.is_terminal) {
            var text_box = try wgt.TextBox.init(allocator, ui.Quit.tab_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().mode = .all;
            text_box.getFocus().kind = .{ .custom = ui.Quit.tab_kind };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                // the label is a single column; +2 for the border
                .min_size = .{ .width = 1 + 2, .height = null },
            });
        }

        tabs_box.getFocus().child_id = selected_tab orelse tab_ids.keys()[0];
        const title_id = title_box.getFocus().id;
        const tabs_id = tabs_box.getFocus().id;
        try box.children.put(allocator, title_id, .{ .widget = .{ .box = title_box }, .rect = null, .min_size = null });
        title_box_owned = true;
        // a blank row between the title and the tabs, shown only when they wrap
        const gap_id = blk: {
            var gap = try wgt.Text.init(allocator, " ");
            errdefer gap.deinit(allocator);
            const id = gap.getFocus().id;
            try box.children.put(allocator, id, .{ .widget = .{ .text = gap }, .rect = null, .min_size = null, .hidden = true });
            break :blk id;
        };
        try box.children.put(allocator, tabs_id, .{ .widget = .{ .box = tabs_box }, .rect = null, .min_size = null });
        tabs_box_owned = true;
        box.getFocus().child_id = tabs_id;

        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .horiz, .show_bar = false, .web_native = !session.is_terminal }),
            .tab_ids = tab_ids,
            .tabs_id = tabs_id,
            .gap_id = gap_id,
            .first_group_width = first_group_width,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
        self.tab_ids.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const box = &self.scroll.child.box;
        const back_visible = self.session.back == .available;
        ui.widget.setBackButtonVisible(box, back_visible);
        const tabs_child = self.tabsChild();
        const tabs_box = &tabs_child.widget.box;

        // only the selected tab shows its border
        const selected_tab = if (box.getFocus().child_id == self.tabs_id) tabs_box.getFocus().child_id else null;
        var tabs_width: usize = 0;
        for (tabs_box.children.keys(), tabs_box.children.values()) |id, *child| {
            const tb: ?*wgt.TextBox = switch (child.widget) {
                .text_box => |*x| x,
                .auth_tab => |*at| blk: {
                    // the label tracks login state per frame, so the width must too
                    child.min_size = .{ .width = at.minWidth(), .height = null };
                    break :blk &at.text_box;
                },
                else => null,
            };
            if (tb) |t| ui.widget.markSelected(t, selected_tab == id);
            tabs_width += if (child.min_size) |min_size| min_size.width orelse 0 else 0;
        }

        // the outer box's hidden border occupies two columns. keep the title
        // and tabs together if they fit; otherwise tab strip on its own row.
        const viewport_width = constraint.max_size.width orelse constraint.min_size.width;
        const content_width = if (viewport_width) |width| width -| 2 else null;
        const back_width: usize = if (back_visible) ui.widget.back_button_width else 0;
        const wrap = if (content_width) |width| self.first_group_width + back_width + tabs_width > width else false;
        box.options.direction = if (wrap) .vert else .horiz;
        tabs_child.min_size = if (wrap) .{ .width = content_width, .height = null } else null;
        (box.children.getPtr(self.gap_id) orelse unreachable).hidden = !wrap;

        var scroll_constraint = constraint;
        scroll_constraint.min_size.width = viewport_width;
        try self.scroll.build(allocator, scroll_constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        if (inp.moveTab(key, current_tab, self.tab_ids.count())) |new_tab| {
            const tab_id = self.tab_ids.keys()[new_tab];
            root_focus.setFocus(tab_id);
            const tabs_child = self.tabsChild();
            const tabs_rect = tabs_child.rect orelse return;
            const tab = tabs_child.widget.box.children.get(tab_id) orelse return;
            var rect = tab.rect orelse return;
            rect.x += tabs_rect.x;
            rect.y += tabs_rect.y;
            self.scroll.scrollToRect(rect);
        }
    }

    pub fn clearGrid(self: *View) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.scroll.getFocus();
    }

    pub fn getSelectedIndex(self: View) ?usize {
        return self.currentTabIndex();
    }

    fn currentTabIndex(self: View) ?usize {
        if (self.scroll.child.box.focus.child_id != self.tabs_id) return null;
        const child_id = self.tabsChild().widget.box.focus.child_id orelse return null;
        return self.tab_ids.getIndex(child_id);
    }

    fn tabsChild(self: *const View) *wgt.Box(ui.Widget).Child {
        return self.scroll.child.box.children.getPtr(self.tabs_id) orelse unreachable;
    }
};

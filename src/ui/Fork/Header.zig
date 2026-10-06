const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const commits_tab_label = "commits";
const patch_tab_label = "patch";
const diff_tab_label = "diff";
const files_tab_label = "files";
const new_tab_label = "new";
const new_repo_tab_bottom_label = "repo";
const new_user_tab_bottom_label = "user";

name: []const u8,
forker_name: []const u8,
title: ui.Title,
id: []const u8,
oid: []const u8,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, name: []const u8, forker_name: []const u8, id: []const u8, oid: []const u8) !Self {
    return .{
        .name = name,
        // the name can borrow from a temporary route; retain it for the snapshot.
        .forker_name = try arena.allocator().dupe(u8, forker_name),
        .title = try ui.Title.init(arena, name, .scanlines),
        .id = try arena.allocator().dupe(u8, id),
        .oid = try arena.allocator().dupe(u8, oid),
    };
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),
    tabs_id: usize,
    gap_id: usize,
    first_group_width: usize,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, commit_count: ?u64, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = .hidden, .round_corners = true, .direction = .horiz });
        errdefer box.deinit(allocator);

        var title_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        var title_box_owned = false;
        errdefer if (!title_box_owned) title_box.deinit(allocator);

        var tabs_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        var tabs_box_owned = false;
        errdefer if (!tabs_box_owned) tabs_box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        const aa = session.page_arena.allocator();
        const fork_identity = try aa.print("{s}:{s}", .{ data.forker_name, data.name });
        const commits_label = if (commit_count) |count| try aa.print(commits_tab_label ++ " ({d})", .{count}) else commits_tab_label;
        var first_group_width = try data.title.width();

        try ui.widget.addBackButton(allocator, &title_box, session);

        // the forker's name links to their page.
        {
            var text_buf: [evt.User.name_max_len + 1]u8 = undefined;
            const text = try std.fmt.bufPrint(&text_buf, "{s}/", .{data.forker_name});
            var forker = try wgt.TextBox.init(allocator, text, .{ .border = .hidden, .wrap_kind = .none });
            errdefer forker.deinit(allocator);
            forker.getFocus().mode = .all;
            forker.getFocus().kind = .{ .custom = try aa.print("a:/{s}", .{data.forker_name}) };
            first_group_width += try xitui.width.displayWidth(text) + 2;
            try title_box.children.put(allocator, forker.getFocus().id, .{ .widget = .{ .text_box = forker }, .rect = null, .min_size = null });
        }

        // the title links to the fork's default tab.
        {
            const route = ui.RoutablePage.forkPatchRoute(fork_identity, data.id) orelse return error.RouteTooLong;
            var title = try ui.Title.View.init(allocator, &data.title);
            errdefer title.deinit(allocator);
            title.getFocus().mode = .all;
            title.getFocus().kind = .{ .custom = try aa.print("a:{s}", .{try route.toUrl(session.page_arena)}) };
            try title_box.children.put(allocator, title.getFocus().id, .{ .widget = .{ .title = title }, .rect = null, .min_size = null });
        }

        // separate the title from the tabs.
        {
            var spacer = try wgt.Text.init(allocator, " ");
            errdefer spacer.deinit(allocator);
            try tabs_box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .text = spacer }, .rect = null, .min_size = .{ .width = 1, .height = null } });
        }

        const current_tag = std.meta.activeTag(session.data.current_page);
        const routes = [_]ui.RoutablePage{
            ui.RoutablePage.forkPatchRoute(fork_identity, data.id) orelse return error.RouteTooLong,
            ui.RoutablePage.forkDiffRoute(fork_identity, data.id, "", "", 0, "") orelse return error.RouteTooLong,
            ui.RoutablePage.forkFilesRoute(fork_identity, data.id, data.oid, "", 0) orelse return error.RouteTooLong,
            ui.RoutablePage.forkCommitsRoute(fork_identity, data.id, data.oid) orelse return error.RouteTooLong,
        };
        const tags = [_]std.meta.Tag(ui.RoutablePage){ .fork_patch, .fork_diff, .fork_files, .fork_commits };
        const labels = [_][]const u8{ patch_tab_label, diff_tab_label, files_tab_label, commits_label };
        // a single commit's diff names the commit under its tab
        const bottom_labels = [_][]const u8{ "", switch (session.data.current_page) {
            .fork_diff => |*d| if (d.oid.len == 0) "" else try ui.clippedBottomLabel(try aa.alloc(u8, ui.clipped_bottom_label_max_len), d.oid.slice()),
            else => "",
        }, "", "" };
        var selected_tab: ?usize = null;

        for (routes, tags, labels, bottom_labels) |route, tag, label, bottom_label| {
            const selected = current_tag == tag;
            var tab = try wgt.TextBox.init(allocator, label, .{ .border = .single, .round_corners = true, .wrap_kind = .none, .bottom_label = .{ .text = bottom_label } });
            errdefer tab.deinit(allocator);
            tab.getFocus().mode = .all;
            tab.getFocus().kind = .{ .custom = try ui.inPageTabLink(session, route, selected) };
            try tab_ids.put(allocator, tab.getFocus().id, {});
            if (selected) selected_tab = tab.getFocus().id;
            try tabs_box.children.put(allocator, tab.getFocus().id, .{
                .widget = .{ .text_box = tab },
                .rect = null,
                .min_size = .{ .width = label.len + 2, .height = null },
            });
        }

        // spacer pushes new repo, new user, and user to the right.
        {
            var spacer = try ui.widget.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try tabs_box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null, .flex = .grow });
        }

        const new_repo_route = ui.RoutablePage.forkRepoNewRoute(fork_identity, data.id) orelse return error.RouteTooLong;
        const new_repo_link = try ui.inPageTabLink(session, new_repo_route, current_tag == .fork_repo_new);
        const new_user_route = ui.RoutablePage.forkUserNewRoute(fork_identity, data.id) orelse return error.RouteTooLong;
        const new_user_link = try ui.inPageTabLink(session, new_user_route, current_tag == .fork_user_new);
        const user_route = ui.RoutablePage.forkUserRoute(fork_identity, data.id) orelse return error.RouteTooLong;
        const user_link = try ui.inPageTabLink(session, user_route, current_tag == .fork_user);

        // new repo tab with a login, new user tab without one outside local mode
        if (session.data.user_id != null) {
            var new_repo = try wgt.TextBox.init(allocator, new_tab_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none, .bottom_label = .{ .text = new_repo_tab_bottom_label } });
            errdefer new_repo.deinit(allocator);
            new_repo.getFocus().mode = .all;
            new_repo.getFocus().kind = .{ .custom = new_repo_link };
            try tab_ids.put(allocator, new_repo.getFocus().id, {});
            if (current_tag == .fork_repo_new) selected_tab = new_repo.getFocus().id;
            try tabs_box.children.put(allocator, new_repo.getFocus().id, .{ .widget = .{ .text_box = new_repo }, .rect = null, .min_size = .{ .width = @max(new_tab_label.len, new_repo_tab_bottom_label.len) + 2, .height = null } });
        } else if (session.data.host_kind == .server) {
            var new_user = try wgt.TextBox.init(allocator, new_tab_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none, .bottom_label = .{ .text = new_user_tab_bottom_label } });
            errdefer new_user.deinit(allocator);
            new_user.getFocus().mode = .all;
            new_user.getFocus().kind = .{ .custom = new_user_link };
            try tab_ids.put(allocator, new_user.getFocus().id, {});
            if (current_tag == .fork_user_new) selected_tab = new_user.getFocus().id;
            try tabs_box.children.put(allocator, new_user.getFocus().id, .{ .widget = .{ .text_box = new_user }, .rect = null, .min_size = .{ .width = @max(new_tab_label.len, new_user_tab_bottom_label.len) + 2, .height = null } });
        }

        if (session.data.host_kind == .server) {
            const label = ui.UserSettings.tabLabel(session);
            var user_tab = try wgt.TextBox.init(allocator, label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
            errdefer user_tab.deinit(allocator);
            user_tab.getFocus().mode = .all;
            user_tab.getFocus().kind = .{ .custom = user_link };
            try tab_ids.put(allocator, user_tab.getFocus().id, {});
            if (current_tag == .fork_user) selected_tab = user_tab.getFocus().id;
            try tabs_box.children.put(allocator, user_tab.getFocus().id, .{ .widget = .{ .text_box = user_tab }, .rect = null, .min_size = .{ .width = label.len + 2, .height = null } });
        }

        if (session.is_terminal) {
            var quit = try wgt.TextBox.init(allocator, ui.Quit.tab_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
            errdefer quit.deinit(allocator);
            quit.getFocus().mode = .all;
            quit.getFocus().kind = .{ .custom = ui.Quit.tab_kind };
            try tab_ids.put(allocator, quit.getFocus().id, {});
            try tabs_box.children.put(allocator, quit.getFocus().id, .{ .widget = .{ .text_box = quit }, .rect = null, .min_size = .{ .width = 3, .height = null } });
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

        const selected_tab = tabs_box.getFocus().child_id;
        var tabs_width: usize = 0;
        for (tabs_box.children.keys(), tabs_box.children.values()) |id, *child| {
            const text_box: ?*wgt.TextBox = switch (child.widget) {
                .text_box => |*value| value,
                else => null,
            };
            if (text_box) |tab| ui.widget.markSelected(tab, selected_tab == id);
            tabs_width += if (child.min_size) |min_size| min_size.width orelse 0 else 0;
        }

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

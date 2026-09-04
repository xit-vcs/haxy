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

pub const AuthTab = @import("./../AuthTab.zig");

const RefOrOid = ui.RoutablePage.RefOrOid;
const Array = ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len);

name: []const u8,
owner_name: []const u8,
title: ui.Title,
// the ref/oid this page is viewing, so the files and commits tabs both link to
// it (switching tabs keeps the same ref). the value is url-encoded.
ref_or_oid: RefOrOid,
ref_or_oid_value: []const u8,
// the issues tab's tag filter, url-encoded ("" = unfiltered), so the tab links
// back to the filtered list.
issues_tag: []const u8,
patches_tag: []const u8,
discussions_tag: []const u8,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, name: []const u8, owner_name: []const u8, ref_or_oid: RefOrOid, ref_or_oid_value: []const u8, issues_tag: []const u8, patches_tag: []const u8, discussions_tag: []const u8) !Self {
    return .{
        .name = name,
        .owner_name = owner_name,
        .title = try ui.Title.init(arena, name),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = ref_or_oid_value,
        .issues_tag = issues_tag,
        .patches_tag = patches_tag,
        .discussions_tag = discussions_tag,
    };
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),
    tabs_id: usize,
    first_group_width: usize,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, commit_count: ?u64, session: *ui.Session) !View {
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

        const aa = session.page_arena.allocator();
        const ref_name = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.ref_or_oid_value));
        const bottom_label = try ui.clippedBottomLabel(try aa.alloc(u8, ui.clipped_bottom_label_max_len), ref_name);
        const bottom_label_width = try xitui.width.displayWidth(bottom_label);
        const commits_label = if (commit_count) |count| try std.fmt.allocPrint(aa, "commits ({d})", .{count}) else "commits";
        const commits_label_width = try xitui.width.displayWidth(commits_label);
        var first_group_width = try data.title.width();

        try ui.widget.addBackButton(allocator, &title_box, session);

        // the user's name (local mode has no user pages to link to)
        if (!session.data.is_local) {
            var text_buf: [evt.User.name_max_len + 1]u8 = undefined;
            const text = try std.fmt.bufPrint(&text_buf, "{s}/", .{data.owner_name});
            const link = try std.fmt.allocPrint(aa, "a:/user/{s}", .{data.owner_name});

            var text_box = try wgt.TextBox.init(allocator, text, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = link };
            first_group_width += try xitui.width.displayWidth(text) + 2;
            try title_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = null,
            });
        }

        // local routes carry no identity, so their urls come out elided
        const identity = if (session.data.is_local) "" else try std.fmt.allocPrint(aa, "{s}/{s}", .{ data.owner_name, data.name });

        // title links to the repo's files root (the bare route, so it resolves
        // to the default branch).
        {
            const files_root_route = ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0) orelse return error.RouteTooLong;
            const title_link = try std.fmt.allocPrint(aa, "a:{s}", .{try files_root_route.toUrl(session.page_arena)});
            var title_view = try ui.Title.View.init(allocator, &data.title);
            errdefer title_view.deinit(allocator);
            title_view.getFocus().focusable = true;
            title_view.getFocus().kind = .{ .custom = title_link };
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

        // every tab link is repo-scoped so selecting one stays on this page —
        // switching its stack and updating the url — instead of navigating to
        // the global settings or auth pages. the "ai:" prefix makes each an
        // in-page anchor: crossPageLink ignores it so a wasm click just switches
        // tabs (the page already holds every tab's content), while the href is
        // still followed with js off. the files tab routes through the shared
        // helper so the /repo/.../files url format lives in one place.
        // both tabs link to the ref/oid this page is viewing, so switching tabs
        // keeps the same ref (the files tab opens at its root directory).
        const current_page = session.data.current_page;
        const current_tag = std.meta.activeTag(current_page);
        const files_route = ui.RoutablePage.repoFilesRoute(identity, data.ref_or_oid, data.ref_or_oid_value, "", 0) orelse return error.RouteTooLong;
        const files_link = try ui.inPageTabLink(session, files_route, current_tag == .repo_files);
        const commits_route = ui.RoutablePage.repoCommitsRoute(identity, data.ref_or_oid, data.ref_or_oid_value, 0, "") orelse return error.RouteTooLong;
        const commits_link = try ui.inPageTabLink(session, commits_route, current_tag == .repo_commits);
        const refs_route = ui.RoutablePage.repoRefsRoute(identity, .branch, "") orelse return error.RouteTooLong;
        const refs_link = try ui.inPageTabLink(session, refs_route, current_tag == .repo_refs);
        const issues_route = ui.RoutablePage.repoIssuesRoute(identity, .open, data.issues_tag, "") orelse return error.RouteTooLong;
        const issues_link = try ui.inPageTabLink(session, issues_route, current_tag == .repo_issues);
        const patches_route = ui.RoutablePage.repoPatchesRoute(identity, .open, data.patches_tag, "") orelse return error.RouteTooLong;
        const patches_link = try ui.inPageTabLink(session, patches_route, current_tag == .repo_patches);
        const discussions_route = ui.RoutablePage.repoDiscussionsRoute(identity, data.discussions_tag, "") orelse return error.RouteTooLong;
        const discussions_link = try ui.inPageTabLink(session, discussions_route, current_tag == .repo_discussions);
        const events_route = ui.RoutablePage.repoEventsRoute(identity, .active, null, "") orelse return error.RouteTooLong;
        const events_link = try ui.inPageTabLink(session, events_route, current_tag == .repo_events);
        const settings_route = ui.RoutablePage{ .repo_settings = Array.from(identity) orelse return error.RouteTooLong };
        const settings_link = try ui.inPageTabLink(session, settings_route, current_tag == .repo_settings);
        const auth_route = ui.RoutablePage{ .repo_auth = Array.from(identity) orelse return error.RouteTooLong };
        const auth_link = try ui.inPageTabLink(session, auth_route, current_tag == .repo_auth);

        // the tab matching the current page is focused initially; matching by
        // link (rather than position) keeps this robust to tab changes.
        var selected_tab: ?usize = null;

        // files tab
        {
            var text_box = try wgt.TextBox.init(allocator, "files", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none, .bottom_label = bottom_label });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = files_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_files) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = @max("files".len, bottom_label_width) + 2, .height = null },
            });
        }

        // commits tab
        {
            var text_box = try wgt.TextBox.init(allocator, commits_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none, .bottom_label = bottom_label });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = commits_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_commits) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = @max(commits_label_width, bottom_label_width) + 2, .height = null },
            });
        }

        // refs tab
        {
            var text_box = try wgt.TextBox.init(allocator, "refs", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = refs_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_refs) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "refs".len + 2, .height = null },
            });
        }

        // issues tab
        {
            var text_box = try wgt.TextBox.init(allocator, "issues", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = issues_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_issues) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "issues".len + 2, .height = null },
            });
        }

        // patches tab
        {
            var text_box = try wgt.TextBox.init(allocator, "patches", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = patches_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_patches) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "patches".len + 2, .height = null },
            });
        }

        // discussions tab
        {
            var text_box = try wgt.TextBox.init(allocator, "discussions", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = discussions_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_discussions) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "discussions".len + 2, .height = null },
            });
        }

        // events
        {
            var text_box = try wgt.TextBox.init(allocator, "events", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = events_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_events) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "events".len + 2, .height = null },
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

        // settings tab. settings are account preferences, so it needs a login
        // (which also rules out local mode, which has no accounts).
        if (session.data.user_id != null) {
            var text_box = try wgt.TextBox.init(allocator, "settings", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = settings_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            if (current_tag == .repo_settings) selected_tab = text_box.getFocus().id;
            try tabs_box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "settings".len + 2, .height = null },
            });
        }

        // auth tab (login / logout). AuthTab defaults to the global ai:/auth
        // link; repoint its instance at this repo's auth route so it stays on
        // this page. local mode has no accounts, so it has no auth tab.
        if (!session.data.is_local) {
            var auth_tab = try AuthTab.View.init(allocator, session);
            errdefer auth_tab.deinit(allocator);
            auth_tab.text_box.getFocus().kind = .{ .custom = auth_link };
            try tab_ids.put(allocator, auth_tab.getFocus().id, {});
            if (current_tag == .repo_auth) selected_tab = auth_tab.getFocus().id;
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
            text_box.getFocus().focusable = true;
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
        try box.children.put(allocator, title_id, .{
            .widget = .{ .box = title_box },
            .rect = null,
            .min_size = null,
        });
        title_box_owned = true;
        try box.children.put(allocator, tabs_id, .{
            .widget = .{ .box = tabs_box },
            .rect = null,
            .min_size = null,
        });
        tabs_box_owned = true;
        box.getFocus().child_id = tabs_id;

        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .horiz, .show_bar = false, .web_native = !session.is_terminal }),
            .tab_ids = tab_ids,
            .tabs_id = tabs_id,
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
            if (tb) |t| {
                t.options.border_style = if (selected_tab == id) .single else .hidden;
            }
            tabs_width += if (child.min_size) |min_size| min_size.width orelse 0 else 0;
        }

        const viewport_width = constraint.max_size.width orelse constraint.min_size.width;
        // the outer box's hidden border occupies two columns. keep the title
        // and tabs together if they fit; otherwise tab strip on its own row.
        const content_width = if (viewport_width) |width| width -| 2 else null;
        const back_width: usize = if (back_visible) ui.widget.back_button_width else 0;
        const wrap = if (content_width) |width| self.first_group_width + back_width + tabs_width > width else false;
        box.options.direction = if (wrap) .vert else .horiz;
        tabs_child.min_size = if (wrap) .{ .width = content_width, .height = null } else null;

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

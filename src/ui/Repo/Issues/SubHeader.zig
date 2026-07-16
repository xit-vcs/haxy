const std = @import("std");
const ui = @import("../../../ui.zig");
const inp = @import("../../input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// tabs switching between the issues page's views.

pub const View = struct {
    box: wgt.Box(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    // `tag` is the url-encoded tag filter ("" = unfiltered).
    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8, count: usize, tag: []const u8) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .rounded_corners = true, .direction = .horiz });
        errdefer box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        const aa = session.page_arena.allocator();

        const results_route = ui.RoutablePage.repoIssuesRoute(identity, tag, "") orelse return error.RouteTooLong;
        const results_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try results_route.urlAlloc(session.page_arena)});
        const tags_route = ui.RoutablePage.repoIssuesTagsRoute(identity) orelse return error.RouteTooLong;
        const tags_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try tags_route.urlAlloc(session.page_arena)});

        // results tab, labeled with the listing's issue count
        {
            const label = try std.fmt.allocPrint(aa, "results ({d})", .{count});
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = results_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = label.len + 2, .height = null },
            });
        }

        // tags tab, labeled with the active tag filter
        {
            const label = if (tag.len == 0) "tags" else blk: {
                const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, tag));
                break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
            };
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = tags_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = label.len + 2, .height = null },
            });
        }

        var self = View{ .box = box, .tab_ids = tab_ids };
        // the tab matching the incoming route's view is selected initially.
        const selected_index: usize = switch (session.data.current_page) {
            .repo_issues => |i| switch (i.view) {
                .results => 0,
                .tags => 1,
            },
            else => 0,
        };
        self.getFocus().child_id = self.tab_ids.keys()[selected_index];
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
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (self.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        if (inp.moveTab(key, current_tab, self.tab_ids.count())) |new_tab| {
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

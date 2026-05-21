const std = @import("std");
const xit = @import("xit");
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const evt = @import("./event.zig");
const pg = @import("./page.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, page: *const pg.Page) !void {
    var root = try initRoot(allocator, page);
    defer root.deinit();

    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    while (!term.quit.load(.monotonic)) {
        const grid_changed = try terminal.render(&root, &last_grid, &last_size);

        // process any inputs.
        //
        // if the grid didn't change, then first do a blocking
        // read, so the thread will sleep until further input.
        // after that, all remaining reads are non-blocking so
        // we can process the rest of the queued inputs.
        //
        // if the grid *did* change, then only do non-blocking
        // reads. we do not want to sleep the thread because
        // there may be an animation that requires more looping.
        var blocking = !grid_changed;
        while (try terminal.readKey(io, blocking)) |key| {
            switch (key) {
                .codepoint => |cp| if (cp == 'q') return else try root.input(key, root.getFocus()),
                .mouse => |mouse| {
                    if (mouse.action == .press and mouse.action.press == .left) {
                        const root_focus = root.getFocus();
                        var iter = root_focus.children.iterator();
                        while (iter.next()) |entry| {
                            const child = entry.value_ptr.*;
                            if (!child.focus.focusable) continue;
                            const r = child.rect;
                            if (mouse.x >= r.x and mouse.y >= r.y and
                                mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                            {
                                try root_focus.setFocus(entry.key_ptr.*);
                                break;
                            }
                        }
                    } else {
                        try root.input(key, root.getFocus());
                    }
                },
                else => try root.input(key, root.getFocus()),
            }
            blocking = false;
        }

        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());
    }
}

pub fn initRoot(allocator: std.mem.Allocator, page: *const pg.Page) !Widget {
    var root: Widget = switch (page.*) {
        .user_repo => |*p| .{ .user_repo_view = try UserRepoView.init(allocator, p) },
    };
    errdefer root.deinit();

    try root.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 80, .height = null },
    }, root.getFocus());
    if (root.getFocus().child_id) |child_id| {
        try root.getFocus().setFocus(child_id);
    }

    return root;
}

pub fn generateHtml(allocator: std.mem.Allocator, root: *Widget) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..grid.size.height) |y| {
        // wrap runs of cells belonging to a focusable widget in a span tagged
        // with that widget's focus id. CSS paints them with a pointer cursor;
        // JS reads the id on click and dispatches focus directly.
        var current_id: ?usize = null;
        for (0..grid.size.width) |x| {
            const cell_id = cellFocusId(root_focus, x, y);
            if (cell_id != current_id) {
                if (current_id != null) try out.appendSlice(allocator, "</span>");
                if (cell_id) |id| {
                    var buf: [64]u8 = undefined;
                    const tag = try std.fmt.bufPrint(&buf, "<span class=\"clickable\" data-focus-id=\"{}\">", .{id});
                    try out.appendSlice(allocator, tag);
                }
                current_id = cell_id;
            }
            const rune = grid.cells.items[try grid.cells.at(.{ y, x })].rune orelse " ";
            try appendEscapedHtml(allocator, &out, rune);
        }
        if (current_id != null) try out.appendSlice(allocator, "</span>");
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn cellFocusId(focus: *Focus, x: usize, y: usize) ?usize {
    var iter = focus.children.iterator();
    while (iter.next()) |entry| {
        const child = entry.value_ptr.*;
        if (!child.focus.focusable) continue;
        const r = child.rect;
        if (x >= r.x and y >= r.y and x < r.x + r.size.width and y < r.y + r.size.height) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn appendEscapedHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
}

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    selectable_list: SelectableList,
    user_repo_view: UserRepoView,

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn build(self: *Widget, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

// a scrollable list of selectable single-line items. content is replaced
// via setItems, which dupes the strings into the widget's own allocation.
const SelectableList = struct {
    allocator: std.mem.Allocator,
    scroll: wgt.Scroll(Widget),
    lines: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !SelectableList {
        var self = blk: {
            var inner_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
            errdefer inner_box.deinit();

            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit();

            break :blk SelectableList{
                .allocator = allocator,
                .scroll = scroll,
                .lines = .empty,
            };
        };
        errdefer self.deinit();
        return self;
    }

    pub fn deinit(self: *SelectableList) void {
        self.scroll.deinit();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    pub fn setItems(self: *SelectableList, items: []const []const u8) !void {
        const inner_box = &self.scroll.child.box;

        for (inner_box.children.values()) |*child| {
            child.widget.deinit();
        }
        inner_box.children.clearAndFree(self.allocator);

        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearAndFree(self.allocator);

        self.scroll.x = 0;
        self.scroll.y = 0;
        self.scroll.getFocus().child_id = null;

        for (items) |item| {
            const line = try self.allocator.dupe(u8, item);
            {
                errdefer self.allocator.free(line);
                try self.lines.append(self.allocator, line);
            }

            var text_box = try wgt.TextBox(Widget).init(self.allocator, line, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit();
            text_box.getFocus().focusable = true;
            try inner_box.children.put(self.allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        if (inner_box.children.count() > 0) {
            self.scroll.getFocus().child_id = inner_box.children.keys()[0];
        }
    }

    pub fn build(self: *SelectableList, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const pane_has_focus = root_focus.grandchild_id == self.getFocus().id;
        const children = &self.scroll.child.box.children;
        for (children.keys(), children.values()) |id, *item| {
            item.widget.text_box.options.border_style = if (self.getFocus().child_id == id)
                // pane_has_focus will be true if the widgets weren't yet in
                // the focus tree, and so setFocus stopped at the pane itself.
                // in this case, it should be treated as if it's selected.
                (if (root_focus.grandchild_id == id or pane_has_focus) .double else .single)
            else
                .hidden;
        }
        try self.scroll.build(constraint, root_focus);
    }

    pub fn input(self: *SelectableList, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            const children = &self.scroll.child.box.children;
            if (children.getIndex(child_id)) |current_index| {
                var index = current_index;

                switch (key) {
                    .arrow_up => {
                        index -|= 1;
                    },
                    .arrow_down => {
                        if (index + 1 < children.count()) {
                            index += 1;
                        }
                    },
                    .home => {
                        index = 0;
                    },
                    .end => {
                        if (children.count() > 0) {
                            index = children.count() - 1;
                        }
                    },
                    .page_up => {
                        if (self.getGrid()) |grid| {
                            const half_count = (grid.size.height / 3) / 2;
                            index -|= half_count;
                        }
                    },
                    .page_down => {
                        if (self.getGrid()) |grid| {
                            if (children.count() > 0) {
                                const half_count = (grid.size.height / 3) / 2;
                                index = @min(index + half_count, children.count() - 1);
                            }
                        }
                    },
                    .mouse => |mouse| switch (mouse.action) {
                        .scroll => |dir| switch (dir) {
                            .up => index -|= 1,
                            .down => if (index + 1 < children.count()) {
                                index += 1;
                            },
                        },
                        else => {},
                    },
                    else => {},
                }

                if (index != current_index) {
                    try root_focus.setFocus(children.keys()[index]);
                    self.updateScroll(index);
                }
            }
        }
    }

    pub fn clearGrid(self: *SelectableList) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: SelectableList) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *SelectableList) *Focus {
        return self.scroll.getFocus();
    }

    pub fn getSelectedIndex(self: SelectableList) ?usize {
        if (self.scroll.child.box.focus.child_id) |child_id| {
            const children = &self.scroll.child.box.children;
            return children.getIndex(child_id);
        } else {
            return null;
        }
    }

    fn updateScroll(self: *SelectableList, index: usize) void {
        const inner_box = &self.scroll.child.box;
        if (inner_box.children.values()[index].rect) |rect| {
            self.scroll.scrollToRect(rect);
        }
    }
};

// horizontal two-pane view: users on the left, the selected user's
// repos on the right. selecting a user repopulates the repo pane.
const UserRepoView = struct {
    allocator: std.mem.Allocator,
    box: wgt.Box(Widget),
    page: *const pg.UserRepoPage,
    last_user_index: ?usize,

    const user_list_index: usize = 0;
    const repo_list_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, page: *const pg.UserRepoPage) !UserRepoView {
        var self = blk: {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .horiz });
            errdefer box.deinit();

            {
                var user_list = try SelectableList.init(allocator);
                errdefer user_list.deinit();
                try box.children.put(allocator, user_list.getFocus().id, .{ .widget = .{ .selectable_list = user_list }, .rect = null, .min_size = .{ .width = 30, .height = null } });
            }

            {
                var repo_list = try SelectableList.init(allocator);
                errdefer repo_list.deinit();
                try box.children.put(allocator, repo_list.getFocus().id, .{ .widget = .{ .selectable_list = repo_list }, .rect = null, .min_size = .{ .width = 40, .height = null } });
            }

            break :blk UserRepoView{
                .allocator = allocator,
                .box = box,
                .page = page,
                .last_user_index = null,
            };
        };
        errdefer self.deinit();

        // populate the user list once at init using a temporary arena
        // for the formatted lines (setItems dupes them).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const user_lines = try aa.alloc([]const u8, page.users.len);
        for (page.users, 0..) |uwr, i| {
            user_lines[i] = try std.fmt.allocPrint(aa, "{s} ({s})", .{ uwr.user.name, uwr.user.display_name });
        }
        const user_list = &self.box.children.values()[user_list_index].widget.selectable_list;
        try user_list.setItems(user_lines);

        self.getFocus().child_id = self.box.children.keys()[user_list_index];
        try self.updateRepos();

        return self;
    }

    pub fn deinit(self: *UserRepoView) void {
        self.box.deinit();
    }

    pub fn build(self: *UserRepoView, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // refresh the repo list here (rather than in input) so it stays in
        // sync regardless of how the user selection changed — including
        // clicks that go straight through setFocus without touching input.
        // updateRepos is a no-op when the selected user hasn't changed.
        try self.updateRepos();
        try self.box.build(constraint, root_focus);
    }

    pub fn input(self: *UserRepoView, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;

                const index = blk: {
                    switch (key) {
                        .arrow_left => {
                            if (current_index == repo_list_index) {
                                break :blk user_list_index;
                            }
                        },
                        .arrow_right => {
                            if (current_index == user_list_index) {
                                break :blk repo_list_index;
                            }
                        },
                        .codepoint => {
                            switch (key.codepoint) {
                                13 => {
                                    if (current_index == user_list_index) {
                                        break :blk repo_list_index;
                                    }
                                },
                                127, '\x1B' => {
                                    if (current_index == repo_list_index) {
                                        break :blk user_list_index;
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                    try child.input(key, root_focus);
                    break :blk current_index;
                };

                if (index != current_index) {
                    try root_focus.setFocus(self.box.children.keys()[index]);
                }
            }
        }
    }

    pub fn clearGrid(self: *UserRepoView) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: UserRepoView) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *UserRepoView) *Focus {
        return self.box.getFocus();
    }

    fn updateRepos(self: *UserRepoView) !void {
        const user_list = &self.box.children.values()[user_list_index].widget.selectable_list;
        const repo_list = &self.box.children.values()[repo_list_index].widget.selectable_list;

        const user_index = user_list.getSelectedIndex();
        if (user_index == self.last_user_index) return;
        self.last_user_index = user_index;

        const repos = if (user_index) |i| self.page.users[i].repos else &.{};

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const repo_lines = try aa.alloc([]const u8, repos.len);
        for (repos, 0..) |repo_event, i| {
            repo_lines[i] = try std.fmt.allocPrint(aa, "{s} - {s}", .{ repo_event.name, repo_event.description });
        }
        try repo_list.setItems(repo_lines);
    }
};

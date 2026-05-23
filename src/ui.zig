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

pub const UsersAndRepos = @import("./ui/UsersAndRepos.zig");

pub const Page = union(enum) {
    users_and_repos: UsersAndRepos,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, page: *const Page) !void {
    var root = try initRoot(allocator, page);
    defer root.deinit();

    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    while (!terminal.shouldQuit()) {
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
            try inputKey(&root, key, &terminal);
            blocking = false;
        }

        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());
    }
}

// route a single decoded key into the widget tree, handling 'q'-to-quit and
// mouse-click focus traversal along the way. shared between the tty event
// loop (ui.run) and the SSH session event loop in serve_ssh.zig.
// `terminal` is whatever terminal type the caller is driving — it must
// expose requestQuit().
pub fn inputKey(root: *Widget, key: inp.Key, terminal: anytype) !void {
    switch (key) {
        .codepoint => |cp| if (cp == 'q') terminal.requestQuit() else try root.input(key, root.getFocus()),
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
}

pub fn initRoot(allocator: std.mem.Allocator, page: *const Page) !Widget {
    var root: Widget = switch (page.*) {
        .users_and_repos => |*p| .{ .users_and_repos = try UsersAndRepos.View.init(allocator, p) },
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

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    selectable_list: SelectableList,
    users_and_repos: UsersAndRepos.View,

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
pub const SelectableList = struct {
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
        // keep the focus tree in sync with the widget tree so setFocus can
        // descend even when the pane isn't laid out this build (e.g. narrow
        // terminal where only the focused pane fits). build's clear+addChild
        // would do this otherwise, but it gets skipped for unbuilt panes.
        inner_box.getFocus().clear();
        inner_box.getFocus().child_id = null;

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
            try inner_box.getFocus().addChild(text_box.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
        }

        if (inner_box.children.count() > 0) {
            inner_box.getFocus().child_id = inner_box.children.keys()[0];
        }
    }

    pub fn build(self: *SelectableList, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const children = &self.scroll.child.box.children;
        for (children.keys(), children.values()) |id, *item| {
            item.widget.text_box.options.border_style = if (self.getFocus().child_id == id)
                (if (root_focus.grandchild_id == id) .double else .single)
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

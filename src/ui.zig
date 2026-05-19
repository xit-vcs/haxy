const std = @import("std");
const xit = @import("xit");
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var root = try initRoot(allocator);
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

pub fn initRoot(allocator: std.mem.Allocator) !Widget {
    var root = Widget{ .widget_list = try WidgetList.init(allocator) };
    errdefer root.deinit();

    try root.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 80, .height = 24 },
    }, root.getFocus());
    if (root.getFocus().child_id) |child_id| {
        try root.getFocus().setFocus(child_id);
    }

    return root;
}

pub fn generateHtml(allocator: std.mem.Allocator, root: *Widget) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..grid.size.height) |y| {
        for (0..grid.size.width) |x| {
            const rune = grid.cells.items[try grid.cells.at(.{ y, x })].rune orelse " ";
            try appendEscapedHtml(allocator, &out, rune);
        }
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
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

const WidgetList = struct {
    allocator: std.mem.Allocator,
    scroll: wgt.Scroll(Widget),

    pub fn init(allocator: std.mem.Allocator) !WidgetList {
        var self = blk: {
            var inner_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer inner_box.deinit();

            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit();

            break :blk WidgetList{
                .allocator = allocator,
                .scroll = scroll,
            };
        };
        errdefer self.deinit();

        const inner_box = &self.scroll.child.box;

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "this is a TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit();
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "this is a\nmulti-line TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit();
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        if (inner_box.children.count() > 0) {
            self.scroll.getFocus().child_id = inner_box.children.keys()[0];
        }

        return self;
    }

    pub fn deinit(self: *WidgetList) void {
        self.scroll.deinit();
    }

    pub fn build(self: *WidgetList, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const children = &self.scroll.child.box.children;
        for (children.keys(), children.values()) |id, *commit| {
            commit.widget.text_box.options.border_style = if (self.getFocus().child_id == id)
                (if (root_focus.grandchild_id == id) .double else .single)
            else
                .hidden;
        }
        try self.scroll.build(constraint, root_focus);
    }

    pub fn input(self: *WidgetList, key: inp.Key, root_focus: *Focus) !void {
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
                    else => {},
                }

                if (index != current_index) {
                    try root_focus.setFocus(children.keys()[index]);
                    self.updateScroll(index);
                }
            }
        }
    }

    pub fn clearGrid(self: *WidgetList) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: WidgetList) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *WidgetList) *Focus {
        return self.scroll.getFocus();
    }

    pub fn getSelectedIndex(self: WidgetList) ?usize {
        if (self.scroll.child.box.focus.child_id) |child_id| {
            const children = &self.scroll.child.box.children;
            return children.getIndex(child_id);
        } else {
            return null;
        }
    }

    fn updateScroll(self: *WidgetList, index: usize) void {
        const left_box = &self.scroll.child.box;
        if (left_box.children.values()[index].rect) |rect| {
            self.scroll.scrollToRect(rect);
        }
    }
};

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    widget_list: WidgetList,

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

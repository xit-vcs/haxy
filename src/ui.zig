const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const evt = @import("./event.zig");

pub const canonical_repo_opts: rp.RepoOpts(.xit) = .{};
pub const DB = rp.Repo(.xit, canonical_repo_opts).DB;

pub const Home = @import("./ui/Home.zig");

pub const Page = union(enum) {
    home: Home,
};

// a top-level "page" the user can navigate to
pub const RoutablePage = enum {
    home_users,
    home_repos,
    home_auth,

    pub fn url(self: RoutablePage) []const u8 {
        return switch (self) {
            .home_users => "/users",
            .home_repos => "/repos",
            .home_auth => "/auth",
        };
    }

    pub fn fromUrl(path: []const u8) ?RoutablePage {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/users")) return .home_users;
        if (std.mem.eql(u8, path, "/repos")) return .home_repos;
        if (std.mem.eql(u8, path, "/auth")) return .home_auth;
        return null;
    }
};

// per-connection mutable state. each SSH session / web session / local TUI
// run gets its own. `data` is the subset that round-trips between server
// and wasm; the other fields are runtime context only and stay local.
pub const Session = struct {
    data: SessionData = .{},
    arena: ?*std.heap.ArenaAllocator = null,
    haxy_moment: ?DB.HashMap(.read_only) = null,
};

// the serializable part of session
pub const SessionData = struct {
    user_id: ?[]const u8 = null,
    // a transient outcome to surface from the last /login POST attempt
    login_failure: ?Home.Auth.Login.Failure = null,
    current_page: RoutablePage = .home_users,
};

// what the server hands to the client (and what main_wasm parses on _start).
// keeps Page free of any per-request session state.
pub const Snapshot = struct {
    page: Page,
    session: SessionData = .{},
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, page: *const Page, session: *Session) !void {
    var root = try initRoot(allocator, page, session);
    defer root.deinit(allocator);

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
            try inputKey(allocator, &root, key, &terminal);
            blocking = false;
        }

        try root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());
    }
}

pub fn inputKey(allocator: std.mem.Allocator, root: *Widget, key: inp.Key, terminal: anytype) !void {
    switch (key) {
        .codepoint => |cp| if (cp == 'q') terminal.requestQuit() else try root.input(allocator, key, root.getFocus()),
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
                // forward the press into the widget tree so buttons (and any
                // future click-aware widgets) can react. widgets that don't
                // care about presses ignore it.
                try root.input(allocator, key, root.getFocus());
            } else {
                try root.input(allocator, key, root.getFocus());
            }
        },
        else => try root.input(allocator, key, root.getFocus()),
    }
}

pub fn initRoot(allocator: std.mem.Allocator, page: *const Page, session: *Session) !Widget {
    var root: Widget = switch (page.*) {
        .home => |*p| .{ .home = try Home.View.init(allocator, p, session) },
    };
    errdefer root.deinit(allocator);

    try root.build(allocator, .{
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
    text_input: wgt.TextInput(Widget),
    scroll: wgt.Scroll(Widget),
    stack: wgt.Stack(Widget),
    selectable_list: SelectableList,
    spacer: Spacer,
    center: Center,
    home: Home.View,
    home_header: Home.Header.View,
    home_users: Home.Users.View,
    home_repos: Home.Repos.View,
    home_auth_tab: Home.Header.AuthTab.View,
    home_auth: Home.Auth.View,

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }

    pub fn build(self: *Widget, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(allocator, constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(allocator, key, root_focus),
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
    scroll: wgt.Scroll(Widget),
    lines: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !SelectableList {
        var self = blk: {
            var inner_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
            errdefer inner_box.deinit(allocator);

            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit(allocator);

            break :blk SelectableList{
                .scroll = scroll,
                .lines = .empty,
            };
        };
        errdefer self.deinit(allocator);
        return self;
    }

    pub fn deinit(self: *SelectableList, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit(allocator);
    }

    pub fn setItems(self: *SelectableList, allocator: std.mem.Allocator, items: []const []const u8) !void {
        const inner_box = &self.scroll.child.box;

        for (inner_box.children.values()) |*child| {
            child.widget.deinit(allocator);
        }
        inner_box.children.clearAndFree(allocator);

        for (self.lines.items) |line| allocator.free(line);
        self.lines.clearAndFree(allocator);

        self.scroll.x = 0;
        self.scroll.y = 0;
        // keep the focus tree in sync with the widget tree so setFocus can
        // descend even when the pane isn't laid out this build (e.g. narrow
        // terminal where only the focused pane fits). build's clear+addChild
        // would do this otherwise, but it gets skipped for unbuilt panes.
        inner_box.getFocus().clear();
        inner_box.getFocus().child_id = null;

        for (items) |item| {
            const line = try allocator.dupe(u8, item);
            {
                errdefer allocator.free(line);
                try self.lines.append(allocator, line);
            }

            var text_box = try wgt.TextBox(Widget).init(allocator, line, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
            try inner_box.getFocus().addChild(text_box.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
        }

        if (inner_box.children.count() > 0) {
            inner_box.getFocus().child_id = inner_box.children.keys()[0];
        }
    }

    pub fn build(self: *SelectableList, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const children = &self.scroll.child.box.children;
        for (children.keys(), children.values()) |id, *item| {
            item.widget.text_box.options.border_style = if (self.getFocus().child_id == id)
                (if (root_focus.grandchild_id == id) .double else .single)
            else
                .hidden;
        }
        try self.scroll.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *SelectableList, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
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

// an invisible widget that fills the horizontal space granted by its parent.
// used inside Box(horiz) with a min_size so the box reserves space for the
// children that follow, pushing them to the right.
pub const Spacer = struct {
    focus: Focus,
    grid: ?Grid,

    pub fn init(allocator: std.mem.Allocator) Spacer {
        return .{
            .focus = Focus.init(allocator, .container),
            .grid = null,
        };
    }

    pub fn deinit(self: *Spacer, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.focus.deinit();
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn build(self: *Spacer, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();
        const width = constraint.max_size.width orelse return;
        if (width == 0) return;
        self.grid = try Grid.init(allocator, .{ .width = width, .height = 1 });
    }

    pub fn input(self: *Spacer, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *Spacer) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: Spacer) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Spacer) *Focus {
        return &self.focus;
    }
};

// a single-child wrapper that builds the child at its natural size and
// positions its grid in the middle of the area granted by the parent
pub const Center = struct {
    focus: Focus,
    grid: ?Grid,
    child: *Widget,
    direction: Direction,

    pub const Direction = enum { both, horiz, vert };

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget, direction: Direction) !Center {
        const child = try allocator.create(Widget);
        errdefer allocator.destroy(child);
        child.* = child_widget;
        return .{
            .focus = Focus.init(allocator, .container),
            .grid = null,
            .child = child,
            .direction = direction,
        };
    }

    pub fn deinit(self: *Center, allocator: std.mem.Allocator) void {
        self.focus.deinit();
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.deinit(allocator);
        allocator.destroy(self.child);
    }

    pub fn build(self: *Center, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.getFocus().clear();

        // build the child without forcing it to fill min_size; it sizes
        // itself to its content within the available max.
        try self.child.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);

        const child_grid = self.child.getGrid() orelse return;

        // prefer max when given; otherwise grow to max(min, child) so that
        // when only a min is set (e.g. the wasm path passes viewport rows
        // as min_height with no max), we can still vertically center while
        // letting taller content extend past the min.
        const width = if (constraint.max_size.width) |w| w else if (constraint.min_size.width) |min_w| @max(min_w, child_grid.size.width) else child_grid.size.width;
        const height = if (constraint.max_size.height) |h| h else if (constraint.min_size.height) |min_h| @max(min_h, child_grid.size.height) else child_grid.size.height;
        if (width == 0 or height == 0) return;

        const offset_x: usize = if (self.direction == .horiz or self.direction == .both)
            (width -| child_grid.size.width) / 2
        else
            0;
        const offset_y: usize = if (self.direction == .vert or self.direction == .both)
            (height -| child_grid.size.height) / 2
        else
            0;

        var grid = try Grid.init(allocator, .{ .width = width, .height = height });
        errdefer grid.deinit();
        try grid.drawGrid(child_grid, offset_x, offset_y);
        try self.getFocus().addChild(self.child.getFocus(), child_grid.size, offset_x, offset_y);
        self.getFocus().child_id = self.child.getFocus().id;

        self.grid = grid;
    }

    pub fn input(self: *Center, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        try self.child.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *Center) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.clearGrid();
    }

    pub fn getGrid(self: Center) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Center) *Focus {
        return &self.focus;
    }
};

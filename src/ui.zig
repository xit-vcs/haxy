const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
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
pub const Title = @import("./ui/Title.zig");

pub const Page = union(enum) {
    home: Home,
};

// a top-level "page" the user can navigate to
pub const RoutablePage = enum {
    home_users,
    home_repos,
    home_auth,

    pub const default: RoutablePage = .home_users;

    pub fn url(self: RoutablePage) []const u8 {
        return switch (self) {
            .home_users => "/users",
            .home_repos => "/repos",
            .home_auth => "/auth",
        };
    }

    pub fn fromUrl(path: []const u8) ?RoutablePage {
        if (std.mem.eql(u8, path, "/")) return default;
        if (std.mem.eql(u8, path, "/users")) return .home_users;
        if (std.mem.eql(u8, path, "/repos")) return .home_repos;
        if (std.mem.eql(u8, path, "/auth")) return .home_auth;
        return null;
    }
};

// per-connection mutable state. each SSH session / web session / local TUI
// run gets its own
pub const Session = struct {
    data: Data = .{}, // serializable data sent down to web client
    arena: *std.heap.ArenaAllocator,
    haxy_moment: ?DB.HashMap(.read_only) = null, // db cursor (null on the wasm side)

    pub const Data = struct {
        user_id: ?[]const u8 = null,
        // a transient outcome to surface from the last /login POST attempt
        login_failure: ?Home.Auth.Login.Failure = null,
        current_page: RoutablePage = .default,
    };

    pub fn init(
        comptime repo_opts: rp.RepoOpts(.xit),
        arena: *std.heap.ArenaAllocator,
        repo: *rp.Repo(.xit, repo_opts),
        data: Data,
    ) !Session {
        const RepoDB = rp.Repo(.xit, repo_opts).DB;

        const history = try RepoDB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try RepoDB.HashMap(.read_only).init(moment_cursor);

        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try RepoDB.ArrayList(.read_only).init(haxy_cursor);

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try RepoDB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try RepoDB.HashMap(.read_only).init(haxy_moment_cursor);

        return .{
            .data = data,
            .arena = arena,
            .haxy_moment = haxy_moment,
        };
    }
};

// what the server hands to the client (and what main_wasm parses on _start).
// keeps Page free of any per-request session state.
pub const Snapshot = struct {
    page: Page,
    session: Session.Data = .{},
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
        .escape => terminal.requestQuit(),
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
    const page_widget: Widget = switch (page.*) {
        .home => |*p| .{ .home = try .init(allocator, p, session) },
    };

    const demon_art = @embedFile("embed/demon.ans");

    var root = Widget{ .background = try AnsiBackground.init(allocator, page_widget, demon_art) };
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
    flow_box: FlowBox,
    spacer: Spacer,
    center: Center,
    ansi_art: AnsiArt,
    background: AnsiBackground,
    home: Home.View,
    title: Title.View,
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

pub const FlowBox = struct {
    focus: Focus,
    grid: ?Grid,
    text_boxes: std.ArrayList(wgt.TextBox(Widget)),
    lines: std.ArrayList([]const u8),
    // column count from the last build — FlowBox.Scroll.input uses it so arrow
    // up/down can step by a row's worth of items.
    last_cols: usize,
    options: Options,

    const border_rows: usize = 2;

    pub const Options = struct {
        cell_width: usize = 40,
        cell_height: usize = 3,
    };

    pub fn init(options: Options) FlowBox {
        return .{
            .focus = Focus.init(.container),
            .grid = null,
            .text_boxes = .empty,
            .lines = .empty,
            .last_cols = 1,
            .options = options,
        };
    }

    pub fn deinit(self: *FlowBox, allocator: std.mem.Allocator) void {
        self.focus.deinit(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.deinit(allocator);
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit(allocator);
    }

    pub fn setItems(self: *FlowBox, allocator: std.mem.Allocator, items: []const []const u8) !void {
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.clearAndFree(allocator);

        for (self.lines.items) |line| allocator.free(line);
        self.lines.clearAndFree(allocator);

        self.focus.clear();
        self.focus.child_id = null;

        for (items) |item| {
            const line = try allocator.dupe(u8, item);
            {
                errdefer allocator.free(line);
                try self.lines.append(allocator, line);
            }

            var text_box = try wgt.TextBox(Widget).init(allocator, line, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try self.text_boxes.append(allocator, text_box);
        }

        if (self.text_boxes.items.len > 0) {
            self.focus.child_id = self.text_boxes.items[0].getFocus().id;
        }
    }

    pub fn build(self: *FlowBox, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();

        const cell_width = self.options.cell_width;
        const max_width = constraint.max_size.width orelse cell_width;
        const cols = if (cell_width == 0) 1 else @max(1, max_width / cell_width);
        self.last_cols = cols;

        const count = self.text_boxes.items.len;
        if (count == 0) return;
        const slot_height = self.options.cell_height + border_rows;
        if (slot_height == 0) return;

        // build at the slot size so every text box fits a single grid cell
        for (self.text_boxes.items) |*tb| {
            tb.options.border_style = if (self.focus.child_id == tb.getFocus().id) .single else .hidden;
            try tb.build(allocator, .{
                .min_size = .{ .width = cell_width, .height = null },
                .max_size = .{ .width = cell_width, .height = slot_height },
            }, root_focus);
        }

        const rows = (count + cols - 1) / cols;
        const content_height = rows * slot_height;
        const total_width = cols * cell_width;
        if (total_width == 0 or content_height == 0) return;

        var grid = try Grid.init(allocator, .{ .width = total_width, .height = content_height });
        errdefer grid.deinit();

        for (self.text_boxes.items, 0..) |*tb, i| {
            const tb_grid = tb.getGrid() orelse continue;
            const col = i % cols;
            const row = i / cols;
            const cell_x = col * cell_width;
            const cell_y = row * slot_height;
            try self.focus.addChild(allocator, tb.getFocus(), tb_grid.size, cell_x, cell_y);
            try grid.drawGrid(tb_grid, cell_x, cell_y);
        }

        self.grid = grid;
    }

    pub fn input(self: *FlowBox, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *FlowBox) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.clearGrid();
    }

    pub fn getGrid(self: FlowBox) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *FlowBox) *Focus {
        return &self.focus;
    }

    pub fn cellRect(self: FlowBox, index: usize) ?layout.IRect {
        if (self.last_cols == 0 or index >= self.text_boxes.items.len) return null;
        const slot_height = self.options.cell_height + border_rows;
        const col = index % self.last_cols;
        const row = index / self.last_cols;
        return .{
            .x = @intCast(col * self.options.cell_width),
            .y = @intCast(row * slot_height),
            .size = .{ .width = self.options.cell_width, .height = slot_height },
        };
    }

    pub fn indexOfFocusId(self: FlowBox, focus_id: usize) ?usize {
        for (self.text_boxes.items, 0..) |tb, i| {
            if (tb.box.focus.id == focus_id) return i;
        }
        return null;
    }

    pub const Scroll = struct {
        scroll: wgt.Scroll(Widget),

        pub fn init(allocator: std.mem.Allocator, options: FlowBox.Options) !Scroll {
            var layout_inner = FlowBox.init(options);
            errdefer layout_inner.deinit(allocator);
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .flow_box = layout_inner }, .vert);
            errdefer scroll.deinit(allocator);
            return .{ .scroll = scroll };
        }

        pub fn deinit(self: *Scroll, allocator: std.mem.Allocator) void {
            self.scroll.deinit(allocator);
        }

        pub fn setItems(self: *Scroll, allocator: std.mem.Allocator, items: []const []const u8) !void {
            self.scroll.x = 0;
            self.scroll.y = 0;
            try self.inner().setItems(allocator, items);
        }

        pub fn build(self: *Scroll, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            try self.scroll.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Scroll, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = allocator;
            const in = self.inner();
            const child_id = in.focus.child_id orelse return;
            const current_index = in.indexOfFocusId(child_id) orelse return;
            const count = in.text_boxes.items.len;
            if (count == 0) return;
            const cols = in.last_cols;
            const slot_height = in.options.cell_height + FlowBox.border_rows;

            var index = current_index;
            switch (key) {
                .arrow_up => index -|= cols,
                .arrow_down => if (index + cols < count) {
                    index += cols;
                },
                .arrow_left => index -|= 1,
                .arrow_right => if (index + 1 < count) {
                    index += 1;
                },
                .home => index = 0,
                .end => index = count - 1,
                .page_up => {
                    if (self.scroll.grid) |grid| if (slot_height > 0) {
                        const rows_per_page = grid.size.height / slot_height;
                        index -|= rows_per_page * cols;
                    };
                },
                .page_down => {
                    if (self.scroll.grid) |grid| if (slot_height > 0) {
                        const rows_per_page = grid.size.height / slot_height;
                        index = @min(index + rows_per_page * cols, count - 1);
                    };
                },
                // scroll wheel moves the focused cell by a full row so the
                // viewport (via scrollToRect) follows in row-sized steps,
                // matching how a scroll wheel feels in a grid view.
                .mouse => |mouse| switch (mouse.action) {
                    .scroll => |dir| switch (dir) {
                        .up => index -|= cols,
                        .down => if (index + cols < count) {
                            index += cols;
                        },
                    },
                    else => {},
                },
                else => {},
            }

            if (index != current_index) {
                try root_focus.setFocus(in.text_boxes.items[index].getFocus().id);
                if (in.cellRect(index)) |rect| {
                    self.scroll.scrollToRect(rect);
                }
            }
        }

        pub fn clearGrid(self: *Scroll) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: Scroll) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *Scroll) *Focus {
            return self.scroll.getFocus();
        }

        pub fn getSelectedIndex(self: Scroll) ?usize {
            const in = self.scroll.child.flow_box;
            const child_id = in.focus.child_id orelse return null;
            return in.indexOfFocusId(child_id);
        }

        fn inner(self: *Scroll) *FlowBox {
            return &self.scroll.child.flow_box;
        }
    };
};

// an invisible widget that fills the horizontal space granted by its parent.
// used inside Box(horiz) with a min_size so the box reserves space for the
// children that follow, pushing them to the right.
pub const Spacer = struct {
    focus: Focus,
    grid: ?Grid,

    pub fn init() Spacer {
        return .{
            .focus = Focus.init(.container),
            .grid = null,
        };
    }

    pub fn deinit(self: *Spacer, allocator: std.mem.Allocator) void {
        self.focus.deinit(allocator);
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
            .focus = Focus.init(.container),
            .grid = null,
            .child = child,
            .direction = direction,
        };
    }

    pub fn deinit(self: *Center, allocator: std.mem.Allocator) void {
        self.focus.deinit(allocator);
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
        try self.getFocus().addChild(allocator, self.child.getFocus(), child_grid.size, offset_x, offset_y);
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

// renders truecolor ANSI art
pub const AnsiArt = struct {
    focus: Focus,
    grid: ?Grid,
    content: []const u8,

    pub fn init(content: []const u8) AnsiArt {
        return .{
            .focus = Focus.init(.container),
            .grid = null,
            .content = content,
        };
    }

    pub fn deinit(self: *AnsiArt, allocator: std.mem.Allocator) void {
        self.focus.deinit(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn build(self: *AnsiArt, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();

        // parse into rows of cells, then copy into a rectangular grid
        var rows: std.ArrayList(std.ArrayList(Grid.Cell)) = .empty;
        defer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }
        var row: std.ArrayList(Grid.Cell) = .empty;
        errdefer row.deinit(allocator);

        var style: Grid.Style = .{};
        var width: usize = 0;
        const content = self.content;
        var i: usize = 0;
        while (i < content.len) {
            const byte = content[i];
            if (byte == '\n') {
                width = @max(width, row.items.len);
                try rows.append(allocator, row);
                row = .empty;
                i += 1;
            } else if (byte == 0x1B and i + 1 < content.len and content[i + 1] == '[') {
                // CSI: scan to the final byte (0x40..0x7E); apply it if it's 'm'
                var j = i + 2;
                while (j < content.len and !(content[j] >= 0x40 and content[j] <= 0x7E)) j += 1;
                if (j >= content.len) {
                    i = content.len; // malformed trailing escape; stop
                } else {
                    if (content[j] == 'm') applySgr(&style, content[i + 2 .. j]);
                    i = j + 1;
                }
            } else {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                const end = @min(content.len, i + len);
                const rune = content[i..end];
                const transparent = end - i == 1 and rune[0] == ' ' and
                    style.fg == null and style.bg == null and !style.inverted;
                try row.append(allocator, .{
                    .rune = if (transparent) null else rune,
                    .style = style,
                });
                i = end;
            }
        }
        // a trailing row with content but no closing newline
        if (row.items.len > 0) {
            width = @max(width, row.items.len);
            try rows.append(allocator, row);
        } else {
            row.deinit(allocator);
        }
        row = .empty; // ownership moved into rows (or freed); keep errdefer safe

        const height = rows.items.len;
        if (width == 0 or height == 0) return;

        const clamped_w = @min(width, constraint.max_size.width orelse width);
        const clamped_h = @min(height, constraint.max_size.height orelse height);

        var grid = try Grid.init(allocator, .{ .width = clamped_w, .height = clamped_h });
        errdefer grid.deinit();
        for (rows.items[0..clamped_h], 0..) |r, y| {
            const n = @min(r.items.len, clamped_w);
            for (r.items[0..n], 0..) |cell, x| {
                grid.cells.items[try grid.cells.at(.{ y, x })] = cell;
            }
        }
        self.grid = grid;
    }

    pub fn input(self: *AnsiArt, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *AnsiArt) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: AnsiArt) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *AnsiArt) *Focus {
        return &self.focus;
    }

    fn applySgr(style: *Grid.Style, params: []const u8) void {
        var nums: [16]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            if (n >= nums.len) break;
            // an empty parameter (e.g. bare "\x1b[m") means 0
            nums[n] = std.fmt.parseInt(u32, tok, 10) catch 0;
            n += 1;
        }
        if (n == 0) {
            style.* = .{};
            return;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            switch (nums[i]) {
                0 => style.* = .{},
                7 => style.inverted = true,
                27 => style.inverted = false,
                39 => style.fg = null,
                49 => style.bg = null,
                38, 48 => {
                    // truecolor form: 38;2;r;g;b — anything else is ignored
                    if (i + 4 < n and nums[i + 1] == 2) {
                        const c = Grid.Color{
                            .r = @truncate(nums[i + 2]),
                            .g = @truncate(nums[i + 3]),
                            .b = @truncate(nums[i + 4]),
                        };
                        if (nums[i] == 38) style.fg = c else style.bg = c;
                        i += 4;
                    }
                },
                else => {},
            }
        }
    }
};

// a full-screen wrapper that renders ANSI art behind whatever page it wraps
pub const AnsiBackground = struct {
    grid: ?Grid,
    child: *Widget,
    art: AnsiArt,

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget, art_content: []const u8) !AnsiBackground {
        var cw = child_widget;
        const child = allocator.create(Widget) catch |e| {
            cw.deinit(allocator);
            return e;
        };
        child.* = cw;
        return .{ .grid = null, .child = child, .art = AnsiArt.init(art_content) };
    }

    pub fn deinit(self: *AnsiBackground, allocator: std.mem.Allocator) void {
        if (self.grid) |*grid| grid.deinit();
        self.art.deinit(allocator);
        self.child.deinit(allocator);
        allocator.destroy(self.child);
    }

    pub fn build(self: *AnsiBackground, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // make the wrapped page fill the whole available area
        try self.child.build(allocator, .{
            .min_size = .{
                .width = constraint.max_size.width orelse constraint.min_size.width,
                .height = constraint.max_size.height orelse constraint.min_size.height,
            },
            .max_size = constraint.max_size,
        }, root_focus);

        if (self.child.getGrid()) |fg| {
            self.grid = try artBehind(allocator, fg, &self.art, .top_right, root_focus);
        }
    }

    pub fn input(self: *AnsiBackground, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        try self.child.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *AnsiBackground) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.clearGrid();
        self.art.clearGrid();
    }

    pub fn getGrid(self: AnsiBackground) ?Grid {
        return self.grid orelse self.child.getGrid();
    }

    pub fn getFocus(self: *AnsiBackground) *Focus {
        return self.child.getFocus();
    }

    // which top corner the art hugs.
    const ArtAnchor = enum { top_left, top_right };

    // a foreground cell counts as blank if it's empty or a bare space without styling
    fn cellIsBlank(cell: Grid.Cell) bool {
        if (cell.rune) |rune| {
            return std.mem.eql(u8, rune, " ") and
                cell.style.fg == null and cell.style.bg == null and !cell.style.inverted;
        }
        return true;
    }

    // a single representative color for an art cell
    fn artCellColor(style: Grid.Style) ?Grid.Color {
        const f = style.fg orelse return style.bg;
        const b = style.bg orelse return f;
        return .{
            .r = @intCast((@as(u16, f.r) + b.r) / 2),
            .g = @intCast((@as(u16, f.g) + b.g) / 2),
            .b = @intCast((@as(u16, f.b) + b.b) / 2),
        };
    }

    // behind a visible glyph the art color is dimmed to this fraction of its
    // brightness so light terminal text stays legible on top of it
    const glyph_bg_brightness = 45; // percent

    // a glyph sitting over the art also gets its foreground pinned to this color
    // (unless it set its own), so the text stays legible
    const glyph_fg_over_art = Grid.Color{ .r = 235, .g = 235, .b = 235 };

    fn dimColor(color: ?Grid.Color) ?Grid.Color {
        const c = color orelse return null;
        return .{
            .r = @intCast(@as(u16, c.r) * glyph_bg_brightness / 100),
            .g = @intCast(@as(u16, c.g) * glyph_bg_brightness / 100),
            .b = @intCast(@as(u16, c.b) * glyph_bg_brightness / 100),
        };
    }

    // terminals that don't support truecolor misparse a "38;2;r;g;b"/"48;2;…"
    // SGR as a list of plain SGR codes, so any channel value in 1..9 turns on
    // a text attribute (5/6 = blink, 7 = inverse, 8 = conceal, …).
    // snap such channels clear of that range so the backdrop doesn't blink or
    // hide text there; the ≤9/255 shift is imperceptible on terminals that
    // actually render truecolor.
    fn sgrSafe(color: ?Grid.Color) ?Grid.Color {
        const c = color orelse return null;
        const snap = struct {
            fn f(v: u8) u8 {
                return if (v >= 1 and v <= 9) 10 else v;
            }
        }.f;
        return .{ .r = snap(c.r), .g = snap(c.g), .b = snap(c.b) };
    }

    // composites ANSI art behind a foreground grid
    fn artBehind(allocator: std.mem.Allocator, foreground: Grid, art: *AnsiArt, anchor: ArtAnchor, root_focus: *Focus) !Grid {
        art.clearGrid();
        try art.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = foreground.size.width, .height = foreground.size.height },
        }, root_focus);

        var out = try Grid.initFromGrid(allocator, foreground, foreground.size, 0, 0);
        errdefer out.deinit();

        if (art.getGrid()) |art_grid| {
            const anchor_x = switch (anchor) {
                .top_left => 0,
                .top_right => foreground.size.width -| art_grid.size.width,
            };
            for (0..art_grid.size.height) |y| {
                for (0..art_grid.size.width) |x| {
                    const src = art_grid.cells.items[try art_grid.cells.at(.{ y, x })];
                    if (src.rune == null) continue;
                    const idx = out.cells.at(.{ y, anchor_x + x }) catch continue;
                    const dst = &out.cells.items[idx];
                    if (cellIsBlank(dst.*)) {
                        dst.* = src;
                        dst.style.fg = sgrSafe(dst.style.fg);
                        dst.style.bg = sgrSafe(dst.style.bg);
                    } else if (dst.style.bg == null) {
                        dst.style.bg = sgrSafe(dimColor(artCellColor(src.style)));
                        if (dst.style.fg == null) dst.style.fg = glyph_fg_over_art;
                    }
                }
            }
        }
        return out;
    }
};

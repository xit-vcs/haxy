const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("input.zig");

pub const thread = @import("widget/thread.zig");

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    text_input: wgt.TextInput(Widget),
    scroll: wgt.Scroll(Widget),
    stack: wgt.Stack(Widget),
    flow_box: FlowBox,
    flow_box_scroll: FlowBox.Scroll,
    tag_flow: TagFlow,
    spacer: Spacer,
    center: Center,
    section_label: SectionLabel,
    submit_button: SubmitButton,
    background: AnsiBackground,
    home: ui.Home.View,
    user: ui.User.View,
    repo: ui.Repo.View,
    quit: ui.Quit.View,
    unauthorized: ui.Unauthorized.View,
    title: ui.Title.View,
    sub_title: ui.SubTitle.View,
    home_header: ui.Home.Header.View,
    user_header: ui.User.Header.View,
    repo_header: ui.Repo.Header.View,
    repo_files_header: ui.Repo.Files.Header.View,
    repo_commits_header: ui.Repo.Commits.Header.View,
    repo_issues_header: ui.Repo.Issues.Header,
    repo_patches_header: ui.Repo.Patches.Header,
    repo_discussions_header: ui.Repo.Discussions.Header,
    repo_files: ui.Repo.Files.View,
    repo_commits: ui.Repo.Commits.View,
    repo_refs: ui.Repo.Refs.View,
    repo_issues: ui.Repo.Issues.View,
    repo_patches: ui.Repo.Patches.View,
    repo_discussions: ui.Repo.Discussions.View,
    repo_events_header: ui.Repo.Events.Header.View,
    repo_events: ui.Repo.Events.View,
    repo_comment: ui.Repo.Comment.Item,
    copyable_text: CopyableText,
    home_users: ui.Home.Users.View,
    home_repos: ui.Home.Repos.View,
    auth_tab: ui.Home.Header.AuthTab.View,
    home_settings: ui.Home.Settings.View,
    home_auth: ui.Home.Auth.View,
    footer: Footer,

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

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) anyerror!void {
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

// move the focused row in `box` by `delta`, clamped to the ends, scrolling
// `scroll` to keep it visible.
pub fn moveRowFocus(box: *wgt.Box(Widget), scroll: *wgt.Scroll(Widget), root_focus: *Focus, delta: isize) void {
    const keys = box.children.keys();
    if (keys.len == 0) return;
    const cur_id = box.getFocus().child_id orelse return;
    const cur: isize = @intCast(box.children.getIndex(cur_id) orelse return);
    const last: isize = @intCast(keys.len - 1);
    const next: usize = @intCast(std.math.clamp(cur + delta, 0, last));
    if (next == @as(usize, @intCast(cur))) return;
    root_focus.setFocus(keys[next]);
    if (box.children.values()[next].rect) |rect| scroll.scrollToRect(rect);
}

pub const FlowBox = struct {
    focus: *Focus,
    grid: ?Grid,
    text_boxes: std.ArrayList(wgt.TextBox(Widget)),
    // backs each link item's `.custom` focus kind (e.g. "a:/user/foo"). reset
    // wholesale on each setItems so there's no per-string ownership to track.
    arena: std.heap.ArenaAllocator,
    // column count from the last build — FlowBox.Scroll.input uses it so arrow
    // up/down can step by a row's worth of items.
    last_cols: usize,
    options: Options,

    const border_rows: usize = 2;

    pub const Options = struct {
        cell_width: usize = 40,
        cell_height: usize = 3,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !FlowBox {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .text_boxes = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .last_cols = 1,
            .options = options,
        };
    }

    pub fn deinit(self: *FlowBox, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.deinit(allocator);
        self.arena.deinit();
    }

    // one flow item: its display text plus an optional link. a non-empty `link`
    // sets the item's focus kind such as `.{ .custom = "a:/user/foo" }`, which
    // the web renderer turns into an anchor.
    pub const Item = struct { text: []const u8, link: []const u8 = "" };

    // the text box copies the item text; links are copied into the arena, so the
    // caller's slices needn't outlive this call.
    pub fn setItems(self: *FlowBox, allocator: std.mem.Allocator, items: []const Item) !void {
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.clearAndFree(allocator);

        // the old text boxes and their borrowed links are gone now, so the link
        // arena can be reclaimed.
        _ = self.arena.reset(.retain_capacity);
        const aa = self.arena.allocator();

        self.focus.clear();
        self.focus.child_id = null;

        for (items) |item| {
            var text_box = try wgt.TextBox(Widget).init(allocator, item.text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;

            if (item.link.len > 0) {
                text_box.getFocus().kind = .{ .custom = try aa.dupe(u8, item.link) };
            }

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

    pub fn input(self: *FlowBox, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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
        return self.focus;
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

        pub fn init(allocator: std.mem.Allocator, options: FlowBox.Options, web_native: bool) !Scroll {
            var layout_inner = try FlowBox.init(allocator, options);
            errdefer layout_inner.deinit(allocator);
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .flow_box = layout_inner }, .{ .direction = .vert, .web_native = web_native });
            errdefer scroll.deinit(allocator);
            return .{ .scroll = scroll };
        }

        pub fn deinit(self: *Scroll, allocator: std.mem.Allocator) void {
            self.scroll.deinit(allocator);
        }

        pub fn setItems(self: *Scroll, allocator: std.mem.Allocator, items: []const Item) !void {
            self.scroll.x = 0;
            self.scroll.y = 0;
            try self.inner().setItems(allocator, items);
        }

        pub fn build(self: *Scroll, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            try self.scroll.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Scroll, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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
                root_focus.setFocus(in.text_boxes.items[index].getFocus().id);
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

// a left-to-right flow of variable-width focusable items that wraps at the
// available width, like words in a paragraph. unlike FlowBox there is no cell
// grid: each item is as wide as its text. selection movement is driven by the
// owning view via indexOfFocusId/verticalNeighbor.
pub const TagFlow = struct {
    focus: *Focus,
    grid: ?Grid,
    text_boxes: std.ArrayList(wgt.TextBox(Widget)),
    // last build's item rects (content space), for vertical navigation and
    // scroll-into-view.
    rects: std.ArrayList(layout.IRect),
    // backs each link item's `.custom` focus kind.
    arena: std.heap.ArenaAllocator,

    pub const Item = struct { text: []const u8, link: []const u8 = "" };

    pub fn init(allocator: std.mem.Allocator) !TagFlow {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .text_boxes = .empty,
            .rects = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *TagFlow, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.deinit(allocator);
        self.rects.deinit(allocator);
        self.arena.deinit();
    }

    // the text box copies the item text; links are copied into the arena, so the
    // caller's slices needn't outlive this call.
    pub fn setItems(self: *TagFlow, allocator: std.mem.Allocator, items: []const Item) !void {
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.clearAndFree(allocator);

        _ = self.arena.reset(.retain_capacity);
        const aa = self.arena.allocator();

        self.focus.clear();
        self.focus.child_id = null;

        for (items) |item| {
            var text_box = try wgt.TextBox(Widget).init(allocator, item.text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;

            if (item.link.len > 0) {
                text_box.getFocus().kind = .{ .custom = try aa.dupe(u8, item.link) };
            }

            try self.text_boxes.append(allocator, text_box);
        }

        if (self.text_boxes.items.len > 0) {
            self.focus.child_id = self.text_boxes.items[0].getFocus().id;
        }
    }

    pub fn build(self: *TagFlow, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();

        if (self.text_boxes.items.len == 0) return;
        const max_width = constraint.max_size.width orelse 80;
        if (max_width == 0) return;

        // lay the items out left to right, wrapping to a new row when the next
        // one wouldn't fit.
        self.rects.clearRetainingCapacity();
        var x: usize = 0;
        var y: usize = 0;
        var row_height: usize = 0;
        var total_width: usize = 0;
        for (self.text_boxes.items) |*tb| {
            try tb.build(allocator, .{
                .min_size = .{ .width = null, .height = null },
                .max_size = .{ .width = max_width, .height = null },
            }, root_focus);
            const tb_grid_maybe = tb.getGrid();
            const w: usize = if (tb_grid_maybe) |g| g.size.width else 0;
            const h: usize = if (tb_grid_maybe) |g| g.size.height else 0;
            if (x > 0 and x + w > max_width) {
                x = 0;
                y += row_height;
                row_height = 0;
            }
            try self.rects.append(allocator, .{ .x = @intCast(x), .y = @intCast(y), .size = .{ .width = w, .height = h } });
            if (h > row_height) row_height = h;
            x += w;
            if (x > total_width) total_width = x;
        }

        const total_height = y + row_height;
        if (total_width == 0 or total_height == 0) return;

        var grid = try Grid.init(allocator, .{ .width = total_width, .height = total_height });
        errdefer grid.deinit();

        for (self.text_boxes.items, self.rects.items) |*tb, rect| {
            const tb_grid = tb.getGrid() orelse continue;
            try self.focus.addChild(allocator, tb.getFocus(), tb_grid.size, @intCast(rect.x), @intCast(rect.y));
            try grid.drawGrid(tb_grid, @intCast(rect.x), @intCast(rect.y));
        }

        self.grid = grid;
    }

    pub fn input(self: *TagFlow, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *TagFlow) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.clearGrid();
    }

    pub fn getGrid(self: TagFlow) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *TagFlow) *Focus {
        return self.focus;
    }

    pub fn indexOfFocusId(self: TagFlow, focus_id: usize) ?usize {
        for (self.text_boxes.items, 0..) |tb, i| {
            if (tb.box.focus.id == focus_id) return i;
        }
        return null;
    }

    // the first item of the row below (when `downward`) or above, or null at
    // the flow's edge. items are laid out in order, so y is nondecreasing.
    pub fn rowStep(self: TagFlow, index: usize, downward: bool) ?usize {
        const rects = self.rects.items;
        if (index >= rects.len) return null;
        const cur_y = rects[index].y;
        if (downward) {
            for (rects[index + 1 ..], index + 1..) |r, i| {
                if (r.y > cur_y) return i;
            }
            return null;
        }
        // walk the earlier rows; the last one visited is the row above.
        var prev_first: ?usize = null;
        var i: usize = 0;
        while (i < rects.len and rects[i].y < cur_y) {
            prev_first = i;
            const y = rects[i].y;
            while (i < rects.len and rects[i].y == y) i += 1;
        }
        return prev_first;
    }
};

// an invisible widget that fills the horizontal space granted by its parent.
// used inside Box(horiz) with a min_size so the box reserves space for the
// children that follow, pushing them to the right.
pub const Spacer = struct {
    focus: *Focus,
    grid: ?Grid,

    pub fn init(allocator: std.mem.Allocator) !Spacer {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
        };
    }

    pub fn deinit(self: *Spacer, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
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

    pub fn input(self: *Spacer, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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
        return self.focus;
    }
};

// a one-row, non-focusable status bar showing the current page's url
pub const Footer = struct {
    focus: *Focus,
    grid: ?Grid,
    session: *ui.Session,
    arena: std.heap.ArenaAllocator,
    url: []const u8 = "",
    url_width: usize = 0,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !Footer {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .session = session,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Footer, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| grid.deinit();
        self.arena.deinit();
    }

    pub fn build(self: *Footer, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();
        const width = constraint.max_size.width orelse return;
        if (width == 0) return;

        _ = self.arena.reset(.retain_capacity);
        self.url = "";
        self.url_width = 0;
        const aa = self.arena.allocator();
        const path = self.session.data.current_page.toUrl(&self.arena) catch return;
        const text = ui.terminalWebUrl(aa, self.session, path) catch return;
        self.url = text;

        var grid = try Grid.init(allocator, .{ .width = width, .height = 1 });
        errdefer grid.deinit();
        var utf8 = (std.unicode.Utf8View.init(text) catch return).iterator();
        var i: usize = 0;
        while (utf8.nextCodepointSlice()) |ch| {
            if (i == width) break;
            grid.cells.items[try grid.cells.at(.{ 0, i })].rune = ch;
            i += 1;
        }
        self.url_width = i;
        self.grid = grid;
    }

    pub fn input(self: *Footer, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        switch (key) {
            .mouse => |mouse| {
                if (mouse.ctrl or !inp.leftClickOn(root_focus, self.getFocus().id, mouse)) return;
                const rect = (root_focus.children.get(self.getFocus().id) orelse return).rect;
                if (mouse.x < rect.x + self.url_width) self.session.host_request = .{ .show_copyable_text = self.url };
            },
            else => {},
        }
    }

    pub fn clearGrid(self: *Footer) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: Footer) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Footer) *Focus {
        return self.focus;
    }
};

// a single-child wrapper that builds the child at its natural size and
// positions its grid in the middle of the area granted by the parent
// a bordered label, indented past the content it precedes
pub const SectionLabel = struct {
    box: wgt.Box(Widget),

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !SectionLabel {
        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        {
            var gap = try wgt.Text(Widget).init(allocator, "  ");
            errdefer gap.deinit(allocator);
            try box.children.put(allocator, gap.getFocus().id, .{ .widget = .{ .text = gap }, .rect = null, .min_size = null });
        }

        {
            var tb = try wgt.TextBox(Widget).init(allocator, content, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        }

        box.getFocus().child_id = box.children.keys()[1];
        return .{ .box = box };
    }

    pub fn deinit(self: *SectionLabel, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *SectionLabel, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *SectionLabel, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *SectionLabel) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: SectionLabel) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *SectionLabel) *Focus {
        return self.box.getFocus();
    }
};

// a submit button, indented past its form's content. the web overlay POSTs
// the button's form; terminal hosts detect presses through `buttonId`.
pub const SubmitButton = struct {
    box: wgt.Box(Widget),

    pub fn init(allocator: std.mem.Allocator) !SubmitButton {
        return initLabeled(allocator, "submit");
    }

    pub fn initLabeled(allocator: std.mem.Allocator, label: []const u8) !SubmitButton {
        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        {
            var gap = try wgt.Text(Widget).init(allocator, "  ");
            errdefer gap.deinit(allocator);
            try box.children.put(allocator, gap.getFocus().id, .{ .widget = .{ .text = gap }, .rect = null, .min_size = null });
        }

        {
            var button = try wgt.TextBox(Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            // the renderer distinguishes plain clickables from buttons that
            // should POST to a server route by this kind.
            button.getFocus().kind = .{ .custom = "submit" };
            try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = label.len + 2, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[1];
        return .{ .box = box };
    }

    pub fn deinit(self: *SubmitButton, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *SubmitButton, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *SubmitButton, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *SubmitButton) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: SubmitButton) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *SubmitButton) *Focus {
        return self.box.getFocus();
    }

    // the button's focus id, for click hit-testing
    pub fn buttonId(self: *const SubmitButton) usize {
        return self.box.children.keys()[1];
    }
};

pub const Center = struct {
    focus: *Focus,
    grid: ?Grid,
    child: *Widget,

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget) !Center {
        const child = try allocator.create(Widget);
        errdefer allocator.destroy(child);
        child.* = child_widget;
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .child = child,
        };
    }

    pub fn deinit(self: *Center, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
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

        const offset_x: usize = (width -| child_grid.size.width) / 2;
        const offset_y: usize = (height -| child_grid.size.height) / 2;

        var grid = try Grid.init(allocator, .{ .width = width, .height = height });
        errdefer grid.deinit();
        try grid.drawGrid(child_grid, offset_x, offset_y);
        try self.getFocus().addChild(allocator, self.child.getFocus(), child_grid.size, offset_x, offset_y);
        self.getFocus().child_id = self.child.getFocus().id;

        self.grid = grid;
    }

    pub fn input(self: *Center, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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
        return self.focus;
    }
};

// renders truecolor ANSI art
pub const AnsiArt = struct {
    focus: *Focus,
    grid: ?Grid,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !AnsiArt {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .content = content,
        };
    }

    pub fn deinit(self: *AnsiArt, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
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
                // a foreground color does not make a space visible. only an
                // effective background makes it opaque; foreground state often
                // remains active through the padding at the end of a row.
                const effective_background = if (style.inverted) style.fg else style.bg;
                const transparent = end - i == 1 and rune[0] == ' ' and effective_background == null;
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
        return self.focus;
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
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget, session: *ui.Session) !AnsiBackground {
        var cw = child_widget;
        const child = allocator.create(Widget) catch |e| {
            cw.deinit(allocator);
            return e;
        };
        child.* = cw;
        errdefer {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        return .{ .grid = null, .child = child, .art = try AnsiArt.init(allocator, session.data.ansi_art), .session = session };
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

        if (!self.session.data.enable_ansi) return;
        const foreground = self.child.getGrid() orelse return;
        self.art.content = self.session.data.ansi_art;
        try self.buildArt(allocator, foreground.size, root_focus);
        if (!self.session.is_terminal) return;
        const art_grid = self.art.getGrid() orelse return;
        self.grid = try artBehind(allocator, foreground, art_grid);
    }

    pub fn input(self: *AnsiBackground, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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

    // a foreground cell counts as blank if it's empty or a bare space without styling
    fn cellIsBlank(cell: Grid.Cell) bool {
        if (cell.rune) |rune| {
            return std.mem.eql(u8, rune, " ") and
                cell.style.fg == null and cell.style.bg == null and !cell.style.inverted;
        }
        return true;
    }

    // the art is dimmed to this fraction of its brightness so foreground text
    // stays legible over it
    const art_brightness = 35; // percent

    fn dimColor(color: ?Grid.Color) ?Grid.Color {
        const c = color orelse return null;
        return .{
            .r = @intCast(@as(u16, c.r) * art_brightness / 100),
            .g = @intCast(@as(u16, c.g) * art_brightness / 100),
            .b = @intCast(@as(u16, c.b) * art_brightness / 100),
        };
    }

    fn buildArt(self: *AnsiBackground, allocator: std.mem.Allocator, size: layout.Size, root_focus: *Focus) !void {
        try self.art.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = size.width, .height = size.height },
        }, root_focus);
        if (self.art.grid) |*grid| {
            for (grid.cells.items) |*cell| {
                cell.style.fg = dimColor(cell.style.fg);
                cell.style.bg = dimColor(cell.style.bg);
            }
        }
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
    fn artBehind(allocator: std.mem.Allocator, foreground: Grid, art_grid: Grid) !Grid {
        var out = try Grid.initFromGrid(allocator, foreground, foreground.size, 0, 0);
        errdefer out.deinit();

        const anchor_x = foreground.size.width -| art_grid.size.width;
        for (0..art_grid.size.height) |y| {
            for (0..art_grid.size.width) |x| {
                const src = art_grid.cells.items[try art_grid.cells.at(.{ y, x })];
                if (src.rune == null) continue;
                const idx = try out.cells.at(.{ y, anchor_x + x });
                const dst = &out.cells.items[idx];
                // blank cells take the art; occupied cells take its background
                if (cellIsBlank(dst.*)) {
                    dst.* = src;
                    dst.style.fg = sgrSafe(dst.style.fg);
                    dst.style.bg = sgrSafe(dst.style.bg);
                } else {
                    const background_maybe = sgrSafe(src.style.bg orelse src.style.fg);
                    dst.style.bg = background_maybe;
                    // change unstyled text to contrast with the art behind it
                    if (dst.style.fg == null) {
                        if (background_maybe) |background| {
                            // use near-black and near-white, which is easier on the eyes
                            // while retaining high contrast
                            const luminance = (@as(u32, background.r) * 299 +
                                @as(u32, background.g) * 587 +
                                @as(u32, background.b) * 114) / 1000;
                            dst.style.fg = if (luminance >= 128)
                                .{ .r = 16, .g = 16, .b = 16 }
                            else
                                .{ .r = 240, .g = 240, .b = 240 };
                        }
                    }
                }
            }
        }
        return out;
    }
};

pub const CopyableText = struct {
    pub const Choice = struct {
        selector: []const u8 = "",
        text: []const u8,
        copyable_text: ?[]const u8 = null,
        label: []const u8 = "",
        bottom_label: []const u8 = "",
    };

    box: wgt.Box(Widget),
    session: *ui.Session,
    choices: []Choice,
    selected: usize = 0,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, choices: []const Choice) !CopyableText {
        if (choices.len == 0) return error.MissingCopyableText;

        const owned_choices = try allocator.dupe(Choice, choices);
        errdefer allocator.free(owned_choices);

        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        if (choices.len > 1) for (choices) |choice| {
            var selector_box = try wgt.TextBox(Widget).init(allocator, choice.selector, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer selector_box.deinit(allocator);
            selector_box.getFocus().focusable = true;
            try box.children.put(allocator, selector_box.getFocus().id, .{ .widget = .{ .text_box = selector_box }, .rect = null, .min_size = .{ .width = choice.selector.len + 2, .height = 3 } });
        };

        var text_input = try wgt.TextInput(Widget).init(allocator, .{
            .border_style = .single,
            .label = choices[0].label,
            .bottom_label = choices[0].bottom_label,
            .read_only = true,
            .render_content = session.is_terminal,
            .visible_width = null,
        });
        errdefer text_input.deinit(allocator);
        text_input.getFocus().focusable = true;
        try text_input.setContent(allocator, choices[0].text);
        box.getFocus().child_id = text_input.getFocus().id;
        try box.children.put(allocator, text_input.getFocus().id, .{ .widget = .{ .text_input = text_input }, .rect = null, .min_size = null, .flex = .shrink });

        return .{ .box = box, .session = session, .choices = owned_choices };
    }

    pub fn initClone(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8) !CopyableText {
        const aa = session.page_arena.allocator();
        var choices: [2]Choice = undefined;
        var count: usize = 0;
        if (session.data.git_http_port) |port| {
            const url = try std.fmt.allocPrint(aa, "http://localhost:{d}/repo/{s}", .{ port, identity });
            choices[count] = .{
                .selector = "http",
                .text = url,
                .copyable_text = try std.fmt.allocPrint(aa, "git clone {s}", .{url}),
                .label = " clone ",
            };
            count += 1;
        }
        if (session.data.git_ssh_port) |port| {
            const url = try std.fmt.allocPrint(aa, "ssh://localhost:{d}/repo/{s}", .{ port, identity });
            choices[count] = .{
                .selector = "ssh",
                .text = url,
                .copyable_text = try std.fmt.allocPrint(aa, "{s}git clone {s}", .{ session.data.git_ssh_prefix, url }),
                .label = " clone ",
            };
            count += 1;
        }
        if (count == 0) return error.MissingGitPort;
        return init(allocator, session, choices[0..count]);
    }

    pub fn minWidth(self: *const CopyableText) usize {
        var width = maxWidth(self.choices) + 2;
        if (self.choices.len > 1) {
            for (self.choices) |choice| width += choice.selector.len + 2;
        }
        return width;
    }

    pub fn deinit(self: *CopyableText, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        allocator.free(self.choices);
    }

    pub fn build(self: *CopyableText, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        if (self.choices.len > 1) {
            if (root_focus.grandchild_id) |id| {
                for (0..self.choices.len) |i| {
                    if (id != self.selector(i).getFocus().id) continue;
                    if (i != self.selected) try self.select(allocator, i);
                    root_focus.setFocus(self.textInput().getFocus().id);
                    break;
                }
            }

            const focused = root_focus.grandchild_id == self.textInput().getFocus().id;
            for (0..self.choices.len) |i| {
                self.selector(i).options.border_style = if (i == self.selected)
                    (if (focused) .double else .single)
                else
                    .hidden;
            }
        }
        self.textInput().options.border_style = .single;
        self.textInput().cursor = 0;
        self.textInput().scroll_offset = 0;
        try self.box.build(allocator, constraint, root_focus);

        if (!self.session.is_terminal) {
            const aa = self.session.arena.allocator();
            const id = self.textInput().getFocus().id;
            try self.session.text_inputs.put(aa, id, self.textInput());
            try self.session.input_values.put(aa, id, self.choices[self.selected].text);
        }
    }

    pub fn input(self: *CopyableText, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        switch (key) {
            .arrow_left => if (self.selected > 0) try self.select(allocator, self.selected - 1),
            .arrow_right => if (self.selected + 1 < self.choices.len) try self.select(allocator, self.selected + 1),
            .enter => if (self.session.is_terminal) self.show(),
            .mouse => |mouse| {
                if (self.choices.len > 1) for (0..self.choices.len) |i| {
                    if (!inp.leftClickOn(root_focus, self.selector(i).getFocus().id, mouse)) continue;
                    try self.select(allocator, i);
                    root_focus.setFocus(self.textInput().getFocus().id);
                    return;
                };
                if (self.session.is_terminal and !mouse.ctrl and inp.leftClickOn(root_focus, self.textInput().getFocus().id, mouse)) self.show();
            },
            else => {},
        }
    }

    fn select(self: *CopyableText, allocator: std.mem.Allocator, selected: usize) !void {
        self.selected = selected;
        const choice = self.choices[selected];
        const text_input = self.textInput();
        text_input.options.label = choice.label;
        text_input.options.bottom_label = choice.bottom_label;
        try text_input.setContent(allocator, choice.text);
    }

    fn show(self: *CopyableText) void {
        const choice = self.choices[self.selected];
        self.session.host_request = .{ .show_copyable_text = choice.copyable_text orelse choice.text };
    }

    fn textInput(self: *CopyableText) *wgt.TextInput(Widget) {
        return &self.box.children.values()[if (self.choices.len > 1) self.choices.len else 0].widget.text_input;
    }

    fn selector(self: *CopyableText, index: usize) *wgt.TextBox(Widget) {
        return &self.box.children.values()[index].widget.text_box;
    }

    fn maxWidth(choices: []const Choice) usize {
        var width: usize = 0;
        for (choices) |choice| width = @max(width, choice.text.len, choice.label.len, choice.bottom_label.len);
        return width;
    }

    pub fn clearGrid(self: *CopyableText) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: CopyableText) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *CopyableText) *Focus {
        return self.box.getFocus();
    }
};

const std = @import("std");
const ui = @import("../../ui.zig");
const md = @import("../../markdown.zig");
const Files = @import("Files.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const RichText = ui.widget.RichText;

// a rendered markdown file: one child per block, word-wrapped to the width.
// without `data` (a file outside any repo), repo-relative links aren't clickable.
pub const View = struct {
    box: wgt.Box(ui.Widget),
    // where focus rests off the links, covering the whole document; it's
    // registered after the links so they win hit-testing
    body: *Focus,

    pub fn init(allocator: std.mem.Allocator, doc: md.Document, data: ?*const Files, file_path: []const u8, page_arena: *std.heap.ArenaAllocator) !View {
        const builder: Builder = .{
            .allocator = allocator,
            .data = data,
            .dir = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| file_path[0..slash] else "",
            .page_arena = page_arena,
            .fonts = !hasNonAsciiHeading(doc.blocks),
        };
        var box = try builder.blocksBox(doc.blocks, true);
        errdefer box.deinit(allocator);
        const body = try Focus.create(allocator, .container);
        body.mode = .all;
        box.getFocus().child_id = body.id;
        return .{ .box = box, .body = body };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        self.body.destroy(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.box.build(allocator, constraint, root_focus);
        const grid = self.box.getGrid() orelse return;
        try self.box.getFocus().addChild(allocator, self.body, grid.size, 0, 0);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
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

    // whether `id` is the body or one of the links
    pub fn owns(self: *View, id: usize) bool {
        return self.box.getFocus().children.contains(id);
    }

    // focus the next or previous link in document order, scrolling it into
    // view; from the body, start at the first link in view. stepping past
    // either end returns to the body.
    pub fn stepLink(self: *View, allocator: std.mem.Allocator, root_focus: *Focus, scroll: *wgt.Scroll(ui.Widget), forward: bool) !void {
        var stops: std.ArrayList(usize) = .empty;
        defer stops.deinit(allocator);
        try collectStops(allocator, &self.box, self.box.getFocus(), &stops);
        const children = self.box.getFocus().children;

        const current = if (root_focus.grandchild_id) |id| std.mem.indexOfScalar(usize, stops.items, id) else null;
        const target: ?usize = if (current) |c|
            (if (forward) (if (c + 1 < stops.items.len) c + 1 else null) else (if (c > 0) c - 1 else null))
        else entry: {
            const top: usize = @intCast(@max(scroll.y, 0));
            if (forward) {
                for (stops.items, 0..) |id, i| {
                    if ((children.get(id) orelse unreachable).rect.y >= top) break :entry i;
                }
                break :entry null;
            }
            const bottom: usize = if (scroll.grid) |g| top + g.size.height - scroll.bar_h else std.math.maxInt(usize);
            var i = stops.items.len;
            while (i > 0) {
                i -= 1;
                if ((children.get(stops.items[i]) orelse unreachable).rect.y < bottom) break :entry i;
            }
            break :entry null;
        };

        const id = stops.items[target orelse return root_focus.setFocus(self.body.id)];
        root_focus.setFocus(id);
        const rect = (children.get(id) orelse unreachable).rect;
        scroll.scrollToRect(.{ .x = @intCast(rect.x), .y = @intCast(rect.y), .size = rect.size });
    }
};

// the focus ids of the laid-out links under `box`, in document order
fn collectStops(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), view_focus: *Focus, stops: *std.ArrayList(usize)) !void {
    for (box.children.values()) |*child| switch (child.widget) {
        .rich_text => |*rich_text| try addStops(allocator, rich_text, view_focus, stops),
        .markdown_heading => |*heading| try addStops(allocator, &heading.text, view_focus, stops),
        .markdown_gutter => |*gutter| try collectStops(allocator, &gutter.child, view_focus, stops),
        .box => |*inner| try collectStops(allocator, inner, view_focus, stops),
        else => {},
    };
}

// each link's first piece is its stop
fn addStops(allocator: std.mem.Allocator, rich_text: *RichText, view_focus: *Focus, stops: *std.ArrayList(usize)) !void {
    for (rich_text.link_focuses) |focuses| {
        if (focuses.items.len > 0 and view_focus.children.contains(focuses.items[0].id)) try stops.append(allocator, focuses.items[0].id);
    }
}

// turns blocks into widgets, resolving links against the viewed file.
const Builder = struct {
    allocator: std.mem.Allocator,
    data: ?*const Files,
    // the viewed file's directory, which relative links resolve against
    dir: []const u8,
    page_arena: *std.heap.ArenaAllocator,
    // whether headings may use the title fonts
    fonts: bool,

    // a vertical box of `blocks`, with a blank row between them when `gap`
    fn blocksBox(b: Builder, blocks: []const md.Block, gap: bool) anyerror!wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(b.allocator, .{ .border_style = null, .direction = .vert, .gap = @intFromBool(gap) });
        errdefer box.deinit(b.allocator);
        for (blocks) |block| try b.addBlock(&box, block);
        return box;
    }

    fn addBlock(b: Builder, box: *wgt.Box(ui.Widget), block: md.Block) !void {
        const allocator = b.allocator;
        switch (block) {
            .heading => |heading| {
                const spans = try b.runSpans(heading.inlines, .{ .bold = true });
                try put(allocator, box, .{ .markdown_heading = try Heading.init(allocator, b.page_arena, heading.level, spans, b.fonts) });
            },
            .paragraph => |inlines| try put(allocator, box, .{ .rich_text = try RichText.init(allocator, try b.runSpans(inlines, .{})) }),
            .code => |lines| {
                const text = try std.mem.join(b.page_arena.allocator(), "\n", lines);
                try put(allocator, box, .{ .text_box = try wgt.TextBox.init(allocator, text, .{ .border_style = .single, .round_corners = true, .wrap_kind = .char }) });
            },
            .quote => |blocks| {
                const gutter = gutter: {
                    var inner = try b.blocksBox(blocks, true);
                    errdefer inner.deinit(allocator);
                    break :gutter try Gutter.init(allocator, "│ ", true, .{ .dim = true }, inner);
                };
                try put(allocator, box, .{ .markdown_gutter = gutter });
            },
            .list => |list| {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                // ordered markers are right-aligned to the widest number
                const number_width = std.fmt.count("{d}", .{list.start + list.items.len -| 1});
                for (list.items, 0..) |item, i| {
                    const marker = if (item.task) |checked|
                        (if (checked) "☑ " else "☐ ")
                    else if (list.ordered)
                        try std.fmt.allocPrint(b.page_arena.allocator(), "{[n]d:>[w]}. ", .{ .n = list.start + i, .w = number_width })
                    else
                        "• ";
                    const gutter = gutter: {
                        var inner = try b.blocksBox(item.blocks, false);
                        errdefer inner.deinit(allocator);
                        break :gutter try Gutter.init(allocator, marker, false, .{}, inner);
                    };
                    try put(allocator, &list_box, .{ .markdown_gutter = gutter });
                }
                try put(allocator, box, .{ .box = list_box });
            },
            // wider than any pane, and clipped to the width
            .rule => try put(allocator, box, .{ .text_box = try wgt.TextBox.init(allocator, "─" ** 512, .{ .border_style = null, .wrap_kind = .none, .style = .{ .dim = true } }) }),
            .raw => |lines| {
                const text = try std.mem.join(b.page_arena.allocator(), "\n", lines);
                try put(allocator, box, .{ .text_box = try wgt.TextBox.init(allocator, text, .{ .border_style = null, .wrap_kind = .none }) });
            },
        }
    }

    // styled spans for `inlines` over `base`, with each link resolved
    fn runSpans(b: Builder, inlines: []const md.Inline, base: Grid.Style) ![]const RichText.Span {
        const out = try b.page_arena.allocator().alloc(RichText.Span, inlines.len);
        for (inlines, out) |run, *span| {
            const link = if (run.link) |dest| try b.resolveLink(dest) else "";
            var style = base;
            style.bold = style.bold or run.style.bold;
            style.italic = run.style.italic;
            style.strikethrough = run.style.strike;
            if (run.style.code) style.fg = .{ .ansi = .yellow };
            if (link.len > 0) {
                style.fg = .{ .ansi = .cyan };
                style.underline = true;
            }
            span.* = .{ .text = run.text, .style = style, .link = link };
        }
        return out;
    }

    // the focus kind a link follows, or "" when it isn't clickable: web links
    // are raw links, and a repo path is a files route relative to this file
    fn resolveLink(b: Builder, dest: []const u8) ![]const u8 {
        const aa = b.page_arena.allocator();
        for ([_][]const u8{ "http:", "https:", "mailto:" }) |scheme| {
            if (std.ascii.startsWithIgnoreCase(dest, scheme)) return std.fmt.allocPrint(aa, "{s}{s}", .{ ui.raw_link_prefix, dest });
        }
        if (hasScheme(dest) or std.mem.startsWith(u8, dest, "//")) return "";
        const data = b.data orelse return "";
        const end = std.mem.indexOfAny(u8, dest, "?#") orelse dest.len;
        if (end == 0) return "";
        const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, dest[0..end]));

        var segments: std.ArrayList([]const u8) = .empty;
        if (decoded[0] != '/') {
            var base = std.mem.tokenizeScalar(u8, b.dir, '/');
            while (base.next()) |segment| try segments.append(aa, segment);
        }
        var parts = std.mem.tokenizeScalar(u8, decoded, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                // climbing above the root isn't a repo path
                if (segments.pop() == null) return "";
                continue;
            }
            try segments.append(aa, part);
        }
        const path = try std.mem.join(aa, "/", segments.items);
        const route = data.filesRoute(path, 0) orelse return "";
        return std.fmt.allocPrint(aa, "a:{s}", .{try route.toUrl(b.page_arena)});
    }
};

// whether any heading, however nested, has non-ascii text, in which case
// none use the title fonts so they all look alike
fn hasNonAsciiHeading(blocks: []const md.Block) bool {
    for (blocks) |block| switch (block) {
        .heading => |heading| for (heading.inlines) |run| {
            for (run.text) |c| if (!std.ascii.isAscii(c)) return true;
        },
        .quote => |inner| if (hasNonAsciiHeading(inner)) return true,
        .list => |list| for (list.items) |item| {
            if (hasNonAsciiHeading(item.blocks)) return true;
        },
        else => {},
    };
    return false;
}

// whether `dest` starts with a url scheme
fn hasScheme(dest: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, dest, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(dest[0])) return false;
    for (dest[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return false;
    }
    return true;
}

fn put(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), widget: ui.Widget) !void {
    var owned = widget;
    errdefer owned.deinit(allocator);
    try box.children.put(allocator, owned.getFocus().id, .{ .widget = owned, .rect = null, .min_size = null });
}

// a heading in the title font when it fits, else the subtitle font, else
// bold text. the fonts only cover plain text of their own glyphs.
pub const Heading = struct {
    focus: *Focus,
    text: RichText,
    title: ?ui.Title.View = null,
    title_width: usize = 0,
    sub_title: ?ui.SubTitle.View = null,
    sub_title_width: usize = 0,
    shown: enum { title, sub_title, text } = .text,

    fn init(allocator: std.mem.Allocator, page_arena: *std.heap.ArenaAllocator, level: u3, spans: []const RichText.Span, fonts: bool) !Heading {
        var self: Heading = .{
            .focus = try Focus.create(allocator, .container),
            .text = undefined,
        };
        errdefer self.focus.destroy(allocator);
        self.text = try RichText.init(allocator, spans);
        errdefer self.text.deinit(allocator);

        var plain: std.ArrayList(u8) = .empty;
        var has_links = false;
        for (spans) |span| {
            try plain.appendSlice(page_arena.allocator(), span.text);
            has_links = has_links or span.link.len > 0;
        }
        const text = std.mem.trim(u8, plain.items, " ");
        if (!fonts or level > 2 or has_links or text.len == 0 or !ui.Title.covers(text) or !ui.SubTitle.covers(text)) return self;

        if (level == 1) {
            const title = try ui.Title.init(page_arena, text, .solid);
            self.title_width = try title.width();
            self.title = try ui.Title.View.init(allocator, &title);
        }
        errdefer if (self.title) |*title| title.deinit(allocator);
        const sub_title = try ui.SubTitle.init(page_arena, text);
        self.sub_title_width = try sub_title.width();
        self.sub_title = try ui.SubTitle.View.init(allocator, &sub_title);
        return self;
    }

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        self.text.deinit(allocator);
        if (self.title) |*title| title.deinit(allocator);
        if (self.sub_title) |*sub_title| sub_title.deinit(allocator);
    }

    pub fn build(self: *Heading, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();
        const max_width = constraint.max_size.width orelse std.math.maxInt(usize);
        self.shown = if (self.title != null and self.title_width <= max_width)
            .title
        else if (self.sub_title != null and self.sub_title_width <= max_width)
            .sub_title
        else
            .text;
        switch (self.shown) {
            .title => try self.buildShown(allocator, constraint, root_focus, if (self.title) |*title| title else unreachable),
            .sub_title => try self.buildShown(allocator, constraint, root_focus, if (self.sub_title) |*sub_title| sub_title else unreachable),
            .text => try self.buildShown(allocator, constraint, root_focus, &self.text),
        }
    }

    fn buildShown(self: *Heading, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus, widget: anytype) !void {
        try widget.build(allocator, constraint, root_focus);
        const grid = widget.getGrid() orelse return;
        try self.focus.addChild(allocator, widget.getFocus(), grid.size, 0, 0);
    }

    pub fn input(self: *Heading, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *Heading) void {
        self.text.clearGrid();
        if (self.title) |*title| title.clearGrid();
        if (self.sub_title) |*sub_title| sub_title.clearGrid();
    }

    pub fn getGrid(self: Heading) ?Grid {
        return switch (self.shown) {
            .title => if (self.title) |title| title.getGrid() else null,
            .sub_title => if (self.sub_title) |sub_title| sub_title.getGrid() else null,
            .text => self.text.getGrid(),
        };
    }

    pub fn getFocus(self: *Heading) *Focus {
        return self.focus;
    }
};

// a marker column beside a child, so wrapped lines hang under the child's
// first line: a list item's bullet, or a quote's bar on every row.
pub const Gutter = struct {
    focus: *Focus,
    grid: ?Grid,
    child: wgt.Box(ui.Widget),
    marker: []const u8,
    // draw the marker on every row rather than only the first
    repeat: bool,
    style: Grid.Style,

    // takes ownership of `child` on success
    fn init(allocator: std.mem.Allocator, marker: []const u8, repeat: bool, style: Grid.Style, child: wgt.Box(ui.Widget)) !Gutter {
        return .{ .focus = try Focus.create(allocator, .container), .grid = null, .child = child, .marker = marker, .repeat = repeat, .style = style };
    }

    pub fn deinit(self: *Gutter, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        self.clearGrid();
        self.child.deinit(allocator);
    }

    pub fn build(self: *Gutter, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();
        const marker_width = try xitui.width.displayWidth(self.marker);
        if (constraint.max_size.width) |w| if (w <= marker_width) return;
        if (constraint.max_size.height == 0) return;

        try self.child.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = if (constraint.max_size.width) |w| w - marker_width else null, .height = constraint.max_size.height },
        }, root_focus);
        const child_grid = self.child.getGrid();
        const child_size: layout.Size = if (child_grid) |g| g.size else .{ .width = 0, .height = 0 };

        var grid = try Grid.init(allocator, .{ .width = marker_width + child_size.width, .height = @max(1, child_size.height) });
        errdefer grid.deinit();
        for (0..if (self.repeat) grid.size.height else 1) |y| {
            var x: usize = 0;
            var utf8 = (try std.unicode.Utf8View.init(self.marker)).iterator();
            while (utf8.nextCodepoint()) |rune| {
                (try grid.cell(x, y)).style = self.style;
                try grid.setRune(x, y, rune);
                x += xitui.width.cellWidth(rune);
            }
        }
        if (child_grid) |g| {
            try grid.drawGrid(g, marker_width, 0);
            try self.focus.addChild(allocator, self.child.getFocus(), g.size, marker_width, 0);
        }
        self.grid = grid;
    }

    pub fn input(self: *Gutter, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *Gutter) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.clearGrid();
    }

    pub fn getGrid(self: Gutter) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Gutter) *Focus {
        return self.focus;
    }
};

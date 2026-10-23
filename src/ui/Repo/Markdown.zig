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
const CopyableText = ui.widget.CopyableText;

// a rendered markdown file: one child per block, word-wrapped to the width.
// without `data` (a file outside any repo), repo-relative links aren't clickable.
pub const View = struct {
    box: wgt.Box(ui.Widget),
    // where focus rests off the links, covering the whole document; it's
    // registered after the links so they win hit-testing
    body: *Focus,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, doc: md.Document, data: ?*const Files, file_path: []const u8) !View {
        const builder: Builder = .{
            .allocator = allocator,
            .session = session,
            .data = data,
            .dir = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| file_path[0..slash] else "",
            .page_arena = session.page_arena,
            .fonts = !hasUncoveredHeading(doc.blocks),
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
        // natural height, since the box would stretch its last block to a min height
        try self.box.build(allocator, .{ .min_size = .{ .width = constraint.min_size.width, .height = null }, .max_size = constraint.max_size }, root_focus);
        const grid = self.box.getGrid() orelse return;
        try self.box.getFocus().addChild(allocator, self.body, grid.size, 0, 0);
    }

    // a focused code block takes enter and clicks
    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try codeInput(allocator, &self.box, key, root_focus);
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
    // either end returns to the body. `x` and `y` place the view in `scroll`'s
    // content.
    pub fn stepLink(self: *View, allocator: std.mem.Allocator, root_focus: *Focus, scroll: *wgt.Scroll(ui.Widget), x: isize, y: isize, forward: bool) !void {
        var stops: std.ArrayList(usize) = .empty;
        defer stops.deinit(allocator);
        try collectStops(allocator, &self.box, self.box.getFocus(), &stops);
        const children = self.box.getFocus().children;

        const current = if (root_focus.grandchild_id) |id| std.mem.indexOfScalar(usize, stops.items, id) else null;
        const target: ?usize = if (current) |c|
            (if (forward) (if (c + 1 < stops.items.len) c + 1 else null) else (if (c > 0) c - 1 else null))
        else entry: {
            // the visible rows, in the view's coordinates
            const top = @max(scroll.y, 0) - y;
            const bottom = if (scroll.viewport) |viewport| top + @as(isize, @intCast(viewport.height)) else std.math.maxInt(isize);
            if (forward) {
                for (stops.items, 0..) |id, i| {
                    if ((children.get(id) orelse unreachable).rect.y >= top) break :entry i;
                }
                break :entry null;
            }
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
        scroll.scrollToRect(.{ .x = x + @as(isize, @intCast(rect.x)), .y = y + @as(isize, @intCast(rect.y)), .size = rect.size });
    }
};

// word-wrapped markdown in a rounded border that turns double while focus is inside
pub const Frame = struct {
    box: wgt.Box(ui.Widget),

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, text: []const u8, label: []const u8, bottom_label: []const u8) !Frame {
        const doc = try md.parseText(session.page_arena.allocator(), text);

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = .single, .round_corners = true, .direction = .vert, .top_label = .{ .text = label }, .bottom_label = .{ .text = bottom_label } });
        errdefer box.deinit(allocator);
        var markdown = try View.init(allocator, session, doc, null, "");
        errdefer markdown.deinit(allocator);
        try box.children.put(allocator, markdown.getFocus().id, .{ .widget = .{ .markdown = markdown }, .rect = null, .min_size = null });
        box.getFocus().child_id = markdown.getFocus().id;
        return .{ .box = box };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *Frame, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const focused = if (root_focus.grandchild_id) |id| self.markdownView().owns(id) else false;
        self.box.options.border = if (focused) .double else .single;
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *Frame, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try self.markdownView().input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *Frame) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Frame) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Frame) *Focus {
        return self.box.getFocus();
    }

    // step between the links, `x` and `y` placing the frame in `scroll`'s content
    pub fn stepLink(self: *Frame, allocator: std.mem.Allocator, root_focus: *Focus, scroll: *wgt.Scroll(ui.Widget), x: isize, y: isize, forward: bool) !void {
        // the view sits inside the border
        try self.markdownView().stepLink(allocator, root_focus, scroll, x + 1, y + 1, forward);
    }

    // where focus rests off the links
    pub fn body(self: *Frame) *Focus {
        return self.markdownView().body;
    }

    fn markdownView(self: *Frame) *View {
        return &self.box.children.values()[0].widget.markdown;
    }
};

// the focus ids of the laid-out links and code blocks under `box`, in document order
fn collectStops(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), view_focus: *Focus, stops: *std.ArrayList(usize)) !void {
    for (box.children.values()) |*child| switch (child.widget) {
        .copyable_text => |*code| {
            const id = code.textInput().getFocus().id;
            if (view_focus.children.contains(id)) try stops.append(allocator, id);
        },
        .rich_text => |*rich_text| try addStops(allocator, rich_text, view_focus, stops),
        .markdown_heading => |*heading| try addStops(allocator, &heading.text, view_focus, stops),
        .markdown_gutter => |*gutter| try collectStops(allocator, &gutter.child, view_focus, stops),
        .box => |*inner| try collectStops(allocator, inner, view_focus, stops),
        else => {},
    };
}

// pass the key to the focused code block under `box`, which a click focuses first
fn codeInput(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), key: Key, root_focus: *Focus) !void {
    for (box.children.values()) |*child| switch (child.widget) {
        .copyable_text => |*code| if (root_focus.grandchild_id == code.textInput().getFocus().id) {
            try code.input(allocator, key, root_focus);
        },
        .markdown_gutter => |*gutter| try codeInput(allocator, &gutter.child, key, root_focus),
        .box => |*inner| try codeInput(allocator, inner, key, root_focus),
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
    session: *ui.Session,
    data: ?*const Files,
    // the viewed file's directory, which relative links resolve against
    dir: []const u8,
    page_arena: *std.heap.ArenaAllocator,
    // whether headings may use the title fonts
    fonts: bool,

    // a vertical box of `blocks`, with a blank row between them when `gap`
    fn blocksBox(b: Builder, blocks: []const md.Block, gap: bool) anyerror!wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(b.allocator, .{ .border = null, .direction = .vert, .gap = @intFromBool(gap) });
        errdefer box.deinit(b.allocator);
        for (blocks) |block| try b.addBlock(&box, block);
        return box;
    }

    fn addBlock(b: Builder, box: *wgt.Box(ui.Widget), block: md.Block) !void {
        const allocator = b.allocator;
        switch (block) {
            .heading => |heading| {
                const spans = try b.runSpans(heading.inlines, .{ .bold = true });
                try put(allocator, box, .{ .markdown_heading = try Heading.init(allocator, b.page_arena, heading.level, spans, b.fonts, heading.center) });
            },
            .paragraph => |paragraph| {
                var text = try RichText.init(allocator, try b.runSpans(paragraph.inlines, .{}));
                text.center = paragraph.center;
                text.pre = paragraph.pre;
                try put(allocator, box, .{ .rich_text = text });
            },
            .code => |lines| {
                const text = try std.mem.join(b.page_arena.allocator(), "\n", lines);
                try put(allocator, box, .{ .copyable_text = try CopyableText.init(allocator, b.session, &.{.{ .text = text }}, 0) });
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
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                // ordered markers are right-aligned to the widest number
                const number_width = std.fmt.count("{d}", .{list.start + list.items.len -| 1});
                for (list.items, 0..) |item, i| {
                    const marker = if (item.task) |checked|
                        (if (checked) "☑ " else "☐ ")
                    else if (list.ordered)
                        try b.page_arena.allocator().print("{[n]d:>[w]}. ", .{ .n = list.start + i, .w = number_width })
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
            .rule => try put(allocator, box, .{ .text_box = try wgt.TextBox.init(allocator, std.mem.asBytes(&@as([512]["─".len]u8, @splat("─".*))), .{ .border = null, .wrap_kind = .none, .style = .{ .dim = true } }) }),
            .raw => |lines| {
                const text = try std.mem.join(b.page_arena.allocator(), "\n", lines);
                try put(allocator, box, .{ .text_box = try wgt.TextBox.init(allocator, text, .{ .border = null, .wrap_kind = .none }) });
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
            if (run.style.code) style.fg = .ansi(.yellow);
            if (link.len > 0) {
                style.fg = .ansi(.cyan);
                style.underline = true;
            }
            span.* = .{ .text = run.text, .style = style, .link = link };
        }
        return out;
    }

    // the focus kind a link follows, or "" when it isn't clickable: web links
    // are raw links, a repo path is a files route relative to this file, and
    // outside a repo a leading `/` is a page on this site
    fn resolveLink(b: Builder, dest: []const u8) ![]const u8 {
        const aa = b.page_arena.allocator();
        for ([_][]const u8{ "http:", "https:", "mailto:" }) |scheme| {
            if (std.ascii.startsWithIgnoreCase(dest, scheme)) return aa.print("{s}{s}", .{ ui.raw_link_prefix, dest });
        }
        if (hasScheme(dest) or std.mem.startsWith(u8, dest, "//")) return "";
        const end = std.mem.indexOfAny(u8, dest, "?#") orelse dest.len;
        if (end == 0) return "";
        const data = b.data orelse {
            if (dest[0] != '/') return "";
            const route = ui.RoutablePage.fromUrl(dest[0..end]) orelse return "";
            return aa.print("a:{s}", .{try route.toUrl(b.page_arena)});
        };
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
        return aa.print("a:{s}", .{try route.toUrl(b.page_arena)});
    }
};

// whether any heading the title fonts would draw, however nested, has a char
// they lack, in which case none use them so they all look alike
fn hasUncoveredHeading(blocks: []const md.Block) bool {
    for (blocks) |block| switch (block) {
        .heading => |heading| if (heading.level <= 2) for (heading.inlines) |run| {
            if (!ui.Title.covers(run.text) or !ui.SubTitle.covers(run.text)) return true;
        },
        .quote => |inner| if (hasUncoveredHeading(inner)) return true,
        .list => |list| for (list.items) |item| {
            if (hasUncoveredHeading(item.blocks)) return true;
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

// a heading in its level's title font, word-wrapped to the width, or bold
// text when there's no font for it.
pub const Heading = struct {
    focus: *Focus,
    text: RichText,
    // the font this heading draws in, if any, and the text it draws
    font: ?enum { title, sub_title } = null,
    plain: []const u8 = "",
    font_box: wgt.TextBox,

    fn init(allocator: std.mem.Allocator, page_arena: *std.heap.ArenaAllocator, level: u3, spans: []const RichText.Span, fonts: bool, center: bool) !Heading {
        const focus = try Focus.create(allocator, .container);
        errdefer focus.destroy(allocator);

        // the bold fallback leads with the level's #s, so levels stay apart
        const marked = try page_arena.allocator().alloc(RichText.Span, spans.len + 1);
        marked[0] = .{ .text = try page_arena.allocator().print("{s} ", .{"######"[0..level]}), .style = .{ .bold = true } };
        @memcpy(marked[1..], spans);
        var text = try RichText.init(allocator, marked);
        errdefer text.deinit(allocator);
        text.center = center;

        var font_box = try wgt.TextBox.init(allocator, "", .{ .border = null, .wrap_kind = .none });
        errdefer font_box.deinit(allocator);
        var self: Heading = .{ .focus = focus, .text = text, .font_box = font_box };

        var plain: std.ArrayList(u8) = .empty;
        var has_links = false;
        for (spans) |span| {
            try plain.appendSlice(page_arena.allocator(), span.text);
            has_links = has_links or span.link.len > 0;
        }
        self.plain = std.mem.trim(u8, plain.items, " ");
        if (fonts and level <= 2 and !has_links and self.plain.len > 0) self.font = if (level == 1) .title else .sub_title;
        return self;
    }

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        self.text.deinit(allocator);
        self.font_box.deinit(allocator);
    }

    pub fn build(self: *Heading, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();
        if (try self.wrapFont(allocator, constraint.max_size.width)) {
            try self.buildShown(allocator, constraint, root_focus, &self.font_box);
        } else {
            try self.buildShown(allocator, constraint, root_focus, &self.text);
        }
    }

    // fill the font box with the heading wrapped at `max_width`, or return
    // false when there's no font
    fn wrapFont(self: *Heading, allocator: std.mem.Allocator, max_width: ?usize) !bool {
        const font = self.font orelse return false;
        // a glyph and the gap after it, so n glyphs take n * char_width - 1 columns
        const char_width: usize = if (font == .title) 4 else 3;
        const max_chars = if (max_width) |w| (w + 1) / char_width else null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        // the fonts only cover ascii, so each byte is one char
        const chars = try aa.alloc(u21, self.plain.len);
        for (self.plain, chars) |c, *char| char.* = c;
        var lines: std.ArrayList(wgt.Line) = .empty;
        try wgt.wrapLines(aa, &lines, chars, .word, max_chars);

        // a blank row between lines keeps the glyphs from touching
        var out: std.ArrayList(u8) = .empty;
        for (lines.items, 0..) |line, i| {
            if (i > 0) try out.appendSlice(aa, "\n\n");
            const text = std.mem.trimEnd(u8, self.plain[line.start..line.end], " ");
            const content = switch (font) {
                .title => (try ui.Title.init(&arena, text, .solid)).content,
                .sub_title => (try ui.SubTitle.init(&arena, text)).content,
            };
            // centering pads each row of the glyphs
            const pad = if (self.text.center) ((max_width orelse 0) -| (text.len * char_width -| 1)) / 2 else 0;
            try out.appendNTimes(aa, ' ', pad);
            for (content) |c| {
                try out.append(aa, c);
                if (c == '\n') try out.appendNTimes(aa, ' ', pad);
            }
        }
        try self.font_box.setContent(allocator, out.items);
        return true;
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
        self.font_box.clearGrid();
    }

    pub fn getGrid(self: Heading) ?Grid {
        // only the one last built has a grid
        return self.font_box.getGrid() orelse self.text.getGrid();
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

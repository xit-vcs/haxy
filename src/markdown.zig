const std = @import("std");

// a GFM subset: html and tables are shown verbatim as raw blocks.

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,
};

// a flat styled run of text; a hard break is a '\n' inside the text.
pub const Inline = struct {
    text: []const u8,
    style: Style = .{},
    // the destination as written, or null outside a link
    link: ?[]const u8 = null,
};

pub const Item = struct {
    // null for a plain item, else whether its task box is checked
    task: ?bool,
    blocks: []const Block,
};

pub const Block = union(enum) {
    heading: struct { level: u3, inlines: []const Inline },
    paragraph: []const Inline,
    // fenced or indented
    code: []const []const u8,
    quote: []const Block,
    list: struct { ordered: bool, start: usize, items: []const Item },
    rule,
    // table lines and html blocks, shown verbatim
    raw: []const []const u8,
};

pub const Document = struct {
    blocks: []const Block,
};

// parse `lines` (each without its newline) into blocks allocated in `arena`.
pub fn parse(arena: std.mem.Allocator, lines: []const []const u8) !Document {
    const expanded = try arena.alloc([]const u8, lines.len);
    for (lines, expanded) |line, *out| out.* = try expandTabs(arena, line);
    var parser: Parser = .{ .arena = arena };
    return .{ .blocks = try parser.parseBlocks(expanded) };
}

// how deeply quotes and lists nest
const max_depth = 16;
// how deeply parens nest in an inline link's destination
const max_paren_depth = 32;

const Parser = struct {
    arena: std.mem.Allocator,
    // how many quotes and lists enclose the blocks being parsed
    depth: usize = 0,

    fn parseBlocks(p: *Parser, lines: []const []const u8) anyerror![]const Block {
        var blocks: std.ArrayList(Block) = .empty;
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            if (isBlank(line)) {
                i += 1;
                continue;
            }
            if (indentOf(line) >= 4) {
                var end = i;
                var j = i;
                while (j < lines.len and (isBlank(lines[j]) or indentOf(lines[j]) >= 4)) : (j += 1) {
                    if (!isBlank(lines[j])) end = j + 1;
                }
                const code = try p.arena.alloc([]const u8, end - i);
                for (lines[i..end], code) |l, *c| c.* = dropIndent(l, 4);
                try blocks.append(p.arena, .{ .code = code });
                i = end;
                continue;
            }
            if (fenceStart(line)) |fence| {
                var code: std.ArrayList([]const u8) = .empty;
                var j = i + 1;
                while (j < lines.len and !isFenceClose(lines[j], fence)) : (j += 1) {
                    try code.append(p.arena, dropIndent(lines[j], fence.indent));
                }
                try blocks.append(p.arena, .{ .code = code.items });
                i = @min(j + 1, lines.len);
                continue;
            }
            if (atxHeading(line)) |heading| {
                try blocks.append(p.arena, .{ .heading = .{ .level = heading.level, .inlines = try parseInlines(p.arena, heading.text) } });
                i += 1;
                continue;
            }
            if (isThematicBreak(line)) {
                try blocks.append(p.arena, .rule);
                i += 1;
                continue;
            }
            // deeper nesting reads as paragraph text, bounding the recursion
            const can_nest = p.depth < max_depth;
            if (can_nest and quoteContent(line) != null) {
                i = try p.parseQuote(lines, i, &blocks);
                continue;
            }
            if (can_nest and listMarker(line) != null) {
                i = try p.parseList(lines, i, &blocks);
                continue;
            }
            if (isTableStart(lines, i)) {
                var j = i;
                while (j < lines.len and !isBlank(lines[j]) and std.mem.indexOfScalar(u8, lines[j], '|') != null) : (j += 1) {}
                try blocks.append(p.arena, .{ .raw = lines[i..j] });
                i = j;
                continue;
            }
            if (isHtmlStart(line)) {
                var j = i;
                while (j < lines.len and !isBlank(lines[j])) : (j += 1) {}
                try blocks.append(p.arena, .{ .raw = lines[i..j] });
                i = j;
                continue;
            }
            i = try p.parseParagraph(lines, i, &blocks);
        }
        return blocks.items;
    }

    fn parseQuote(p: *Parser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        var content: std.ArrayList([]const u8) = .empty;
        var fence: ?Fence = null;
        var j = start;
        while (j < lines.len) : (j += 1) {
            const line = lines[j];
            const c = quoteContent(line) orelse lazy: {
                // lazy continuation of a paragraph inside the quote
                if (fence != null or isBlank(content.items[content.items.len - 1]) or interruptsParagraph(line)) break;
                break :lazy line;
            };
            fence = trackFence(fence, c);
            try content.append(p.arena, c);
        }
        try blocks.append(p.arena, .{ .quote = try p.nested(content.items) });
        return j;
    }

    fn parseList(p: *Parser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        const first = listMarker(lines[start]) orelse unreachable;
        var items: std.ArrayList(Item) = .empty;
        var i = start;
        while (i < lines.len) {
            if (isThematicBreak(lines[i])) break;
            const marker = listMarker(lines[i]) orelse break;
            if (marker.ordered != first.ordered or marker.char != first.char) break;

            var content: std.ArrayList([]const u8) = .empty;
            try content.append(p.arena, lines[i][marker.content_start..]);
            var fence = trackFence(null, content.items[0]);
            var j = i + 1;
            while (j < lines.len) : (j += 1) {
                const line = lines[j];
                if (isBlank(line)) {
                    // an item may begin with at most one blank line
                    if (marker.empty and content.items.len == 1) break;
                    try content.append(p.arena, "");
                    continue;
                }
                if (indentOf(line) >= marker.indent) {
                    const c = dropIndent(line, marker.indent);
                    fence = trackFence(fence, c);
                    try content.append(p.arena, c);
                    continue;
                }
                // a less indented line ends the item unless it lazily
                // continues a paragraph
                if (listMarker(line) != null or fence != null or isBlank(content.items[content.items.len - 1]) or interruptsParagraph(line)) break;
                try content.append(p.arena, std.mem.trimStart(u8, line, " "));
            }

            // trailing blank lines sit between items
            var len = content.items.len;
            while (len > 0 and isBlank(content.items[len - 1])) len -= 1;
            const item_lines = content.items[0..len];
            var task: ?bool = null;
            if (item_lines.len > 0) {
                if (taskMarker(item_lines[0])) |t| {
                    task = t.checked;
                    item_lines[0] = t.rest;
                }
            }
            try items.append(p.arena, .{ .task = task, .blocks = try p.nested(item_lines) });
            i = j;
        }
        try blocks.append(p.arena, .{ .list = .{ .ordered = first.ordered, .start = first.start, .items = items.items } });
        return i;
    }

    fn nested(p: *Parser, lines: []const []const u8) ![]const Block {
        p.depth += 1;
        defer p.depth -= 1;
        return p.parseBlocks(lines);
    }

    fn parseParagraph(p: *Parser, lines: []const []const u8, start: usize, blocks: *std.ArrayList(Block)) !usize {
        const i = start;
        var j = i + 1;
        var setext: ?u3 = null;
        while (j < lines.len) : (j += 1) {
            const line = lines[j];
            if (isBlank(line)) break;
            if (setextLevel(line)) |level| {
                setext = level;
                break;
            }
            if (interruptsParagraph(line)) break;
        }
        const inlines_ = try parseInlines(p.arena, try joinLines(p.arena, lines[i..j]));
        if (setext) |level| {
            try blocks.append(p.arena, .{ .heading = .{ .level = level, .inlines = inlines_ } });
            return j + 1;
        }
        try blocks.append(p.arena, .{ .paragraph = inlines_ });
        return j;
    }
};

fn parseInlines(arena: std.mem.Allocator, src: []const u8) ![]const Inline {
    var scanner: InlineScanner = .{ .arena = arena, .src = src };
    return scanner.run();
}

// one piece of inline content; a delimiter run keeps its matching state
// until emphasis is resolved, after which any unmatched chars are text.
const Node = struct {
    text: []const u8,
    style: Style = .{},
    link: ?[]const u8 = null,
    // '*', '_' or '~' for a delimiter run, else 0
    delim: u8 = 0,
    // the run's unmatched length, then its original length
    count: usize = 0,
    orig: usize = 0,
    can_open: bool = false,
    can_close: bool = false,

    // drop the delimiter state, keeping its unmatched chars as text
    fn literal(self: *Node) void {
        if (self.delim == 0) return;
        self.text = self.text[0..self.count];
        self.delim = 0;
    }
};

const Bracket = struct {
    node: usize,
    image: bool,
};

const InlineScanner = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,
    // the start of the plain text not yet pushed as a node
    text_start: usize = 0,
    // brackets below this stack index can't open links, being inside one
    no_links_below: usize = 0,
    // backtick run lengths with no closer left in the source
    unclosed_runs: std.AutoHashMapUnmanaged(usize, void) = .empty,
    // the index of a `)` for link titles to end at, see inlineLink
    next_close: usize = 0,

    fn run(s: *InlineScanner) ![]const Inline {
        const src = s.src;
        var i: usize = 0;
        while (i < src.len) {
            const next = try s.special(i);
            if (next) |n| {
                s.text_start = n;
                i = n;
            } else i += 1;
        }
        try s.flush(src.len);
        processEmphasis(s.nodes.items, 0);
        return merge(s.arena, s.nodes.items);
    }

    fn flush(s: *InlineScanner, end: usize) !void {
        if (end > s.text_start) try s.nodes.append(s.arena, .{ .text = s.src[s.text_start..end] });
        s.text_start = end;
    }

    fn push(s: *InlineScanner, at: usize, node: Node) !void {
        try s.flush(at);
        try s.nodes.append(s.arena, node);
    }

    // handle the construct starting at `i`, returning where scanning resumes,
    // or null when the char is plain text.
    fn special(s: *InlineScanner, i: usize) !?usize {
        const src = s.src;
        const arena = s.arena;
        switch (src[i]) {
            '\\' => if (i + 1 < src.len and isPunct(src[i + 1])) {
                try s.push(i, .{ .text = src[i + 1 .. i + 2] });
                return i + 2;
            },
            '`' => {
                const n = runLength(src, i, '`');
                // a run with no closer is literal text
                const close = (if (s.unclosed_runs.contains(n)) null else findBacktickRun(src, i + n, n)) orelse {
                    try s.unclosed_runs.put(arena, n, {});
                    try s.push(i, .{ .text = src[i .. i + n] });
                    return i + n;
                };
                try s.push(i, .{ .text = try codeContent(arena, src[i + n .. close]), .style = .{ .code = true } });
                return close + n;
            },
            '*', '_', '~' => {
                const c = src[i];
                const n = runLength(src, i, c);
                if (c == '~' and n > 2) {
                    try s.push(i, .{ .text = src[i .. i + n] });
                    return i + n;
                }
                const before: u8 = if (i == 0) ' ' else src[i - 1];
                const after: u8 = if (i + n >= src.len) ' ' else src[i + n];
                const left = !isSpace(after) and (!isPunct(after) or isSpace(before) or isPunct(before));
                const right = !isSpace(before) and (!isPunct(before) or isSpace(after) or isPunct(after));
                var node: Node = .{ .text = src[i .. i + n], .delim = c, .count = n, .orig = n, .can_open = left, .can_close = right };
                if (c == '_') {
                    node.can_open = left and (!right or isPunct(before));
                    node.can_close = right and (!left or isPunct(after));
                }
                try s.push(i, node);
                return i + n;
            },
            '!' => if (i + 1 < src.len and src[i + 1] == '[') {
                try s.push(i, .{ .text = src[i .. i + 2] });
                try s.pushBracket(true);
                return i + 2;
            },
            '[' => {
                try s.push(i, .{ .text = src[i .. i + 1] });
                try s.pushBracket(false);
                return i + 1;
            },
            ']' => {
                try s.flush(i);
                if (try s.closeBracket(i)) |end| return end;
                try s.push(i, .{ .text = src[i .. i + 1] });
                return i + 1;
            },
            '<' => if (autolink(src[i..])) |url| {
                try s.push(i, .{ .text = url, .link = url });
                return i + url.len + 2;
            },
            'h', 'H' => if (i == 0 or isAutolinkBoundary(src[i - 1])) {
                if (bareAutolink(src[i..])) |len| {
                    try s.push(i, .{ .text = src[i .. i + len], .link = src[i .. i + len] });
                    return i + len;
                }
            },
            else => {},
        }
        return null;
    }

    fn pushBracket(s: *InlineScanner, image: bool) !void {
        s.no_links_below = @min(s.no_links_below, s.brackets.items.len);
        try s.brackets.append(s.arena, .{ .node = s.nodes.items.len - 1, .image = image });
    }

    // resolve the `]` at `i` against the innermost bracket, returning where
    // scanning resumes when it closes a link.
    fn closeBracket(s: *InlineScanner, i: usize) !?usize {
        const src = s.src;
        const bracket = s.brackets.pop() orelse return null;
        if (!bracket.image and s.brackets.items.len < s.no_links_below) return null;
        if (i + 1 >= src.len or src[i + 1] != '(') return null;
        const link = (try inlineLink(s.arena, src, i + 1, &s.next_close)) orelse return null;

        const nodes = s.nodes.items;
        processEmphasis(nodes, bracket.node + 1);
        for (nodes[bracket.node + 1 ..]) |*node| {
            node.link = link.dest;
            // an image shows its alt text as an italic link
            if (bracket.image) node.style.italic = true;
        }
        nodes[bracket.node].text = "";
        // links can't contain links
        if (!bracket.image) s.no_links_below = s.brackets.items.len;
        return link.end;
    }
};

// resolve `*`, `_` and `~` runs from `bottom` on with the CommonMark
// delimiter algorithm, styling the nodes between each matched pair.
fn processEmphasis(nodes: []Node, bottom: usize) void {
    // per closer kind, the lowest index an opener may still be found at
    var openers_bottom: [3][2][3]usize = @splat(@splat(@splat(bottom)));

    var ci = bottom;
    while (ci < nodes.len) {
        const closer = &nodes[ci];
        if (closer.delim == 0 or !closer.can_close or closer.count == 0) {
            ci += 1;
            continue;
        }
        const kind: usize = switch (closer.delim) {
            '*' => 0,
            '_' => 1,
            else => 2,
        };
        const lowest = &openers_bottom[kind][@intFromBool(closer.can_open)][closer.orig % 3];

        var found: ?usize = null;
        var oi = ci;
        while (oi > lowest.*) {
            oi -= 1;
            const opener = nodes[oi];
            if (opener.delim != closer.delim or !opener.can_open or opener.count == 0) continue;
            if (closer.delim == '~') {
                if (opener.count != closer.count) continue;
            } else if ((opener.can_close or closer.can_open) and (opener.orig + closer.orig) % 3 == 0 and
                !(opener.orig % 3 == 0 and closer.orig % 3 == 0))
            {
                // the rule of 3
                continue;
            }
            found = oi;
            break;
        }

        const oi_found = found orelse {
            lowest.* = ci;
            if (!closer.can_open) closer.literal();
            ci += 1;
            continue;
        };
        const opener = &nodes[oi_found];
        const use: usize = if (closer.delim == '~') closer.count else if (opener.count >= 2 and closer.count >= 2) 2 else 1;
        for (nodes[oi_found + 1 .. ci]) |*node| {
            // delimiters between the pair can no longer match
            node.literal();
            if (closer.delim == '~') {
                node.style.strike = true;
            } else if (use == 2) {
                node.style.bold = true;
            } else {
                node.style.italic = true;
            }
        }
        opener.count -= use;
        closer.count -= use;
        if (closer.count == 0) ci += 1;
    }

    for (nodes[bottom..]) |*node| node.literal();
}

// join adjacent nodes that share a style and link into runs.
fn merge(arena: std.mem.Allocator, nodes: []const Node) ![]const Inline {
    var runs: std.ArrayList(Inline) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var style: Style = .{};
    var link: ?[]const u8 = null;
    for (nodes) |node| {
        if (node.text.len == 0) continue;
        const same_link = if (link) |l| (if (node.link) |nl| std.mem.eql(u8, l, nl) else false) else node.link == null;
        if (text.items.len > 0 and (!std.meta.eql(style, node.style) or !same_link)) {
            try runs.append(arena, .{ .text = try text.toOwnedSlice(arena), .style = style, .link = link });
        }
        style = node.style;
        link = node.link;
        try text.appendSlice(arena, node.text);
    }
    if (text.items.len > 0) try runs.append(arena, .{ .text = try text.toOwnedSlice(arena), .style = style, .link = link });
    return runs.items;
}

// join a paragraph's lines: a soft break becomes a space and a hard break
// (two trailing spaces or a trailing backslash) becomes '\n'.
fn joinLines(arena: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, i| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const content = std.mem.trimEnd(u8, trimmed, " ");
        const last = i + 1 == lines.len;
        if (!last and content.len > 0 and content[content.len - 1] == '\\' and runLengthBack(content, content.len, '\\') % 2 == 1) {
            try out.appendSlice(arena, content[0 .. content.len - 1]);
            try out.append(arena, '\n');
        } else {
            try out.appendSlice(arena, content);
            if (!last) try out.append(arena, if (trimmed.len - content.len >= 2) '\n' else ' ');
        }
    }
    return out.items;
}

fn expandTabs(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (std.mem.indexOfScalar(u8, trimmed, '\t') == null) return trimmed;
    var out: std.ArrayList(u8) = .empty;
    for (trimmed) |c| {
        if (c == '\t') {
            try out.appendNTimes(arena, ' ', 4 - out.items.len % 4);
        } else try out.append(arena, c);
    }
    return out.items;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trimStart(u8, line, " ").len == 0;
}

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimStart(u8, line, " ").len;
}

// `line` without up to `n` leading spaces
fn dropIndent(line: []const u8, n: usize) []const u8 {
    return line[@min(indentOf(line), n)..];
}

fn runLength(s: []const u8, start: usize, c: u8) usize {
    var n: usize = 0;
    while (start + n < s.len and s[start + n] == c) n += 1;
    return n;
}

// how many `c` end at `end`
fn runLengthBack(s: []const u8, end: usize, c: u8) usize {
    var n: usize = 0;
    while (n < end and s[end - n - 1] == c) n += 1;
    return n;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n';
}

fn isPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

fn interruptsParagraph(line: []const u8) bool {
    if (isBlank(line)) return true;
    if (indentOf(line) >= 4) return false;
    if (atxHeading(line) != null or fenceStart(line) != null or quoteContent(line) != null or isThematicBreak(line)) return true;
    const marker = listMarker(line) orelse return false;
    return !marker.empty and (!marker.ordered or marker.start == 1);
}

const Fence = struct {
    char: u8,
    len: usize,
    indent: usize,
};

fn fenceStart(line: []const u8) ?Fence {
    const indent = indentOf(line);
    if (indent >= 4 or indent >= line.len) return null;
    const c = line[indent];
    if (c != '`' and c != '~') return null;
    const n = runLength(line, indent, c);
    if (n < 3) return null;
    if (c == '`' and std.mem.indexOfScalar(u8, line[indent + n ..], '`') != null) return null;
    return .{ .char = c, .len = n, .indent = indent };
}

fn isFenceClose(line: []const u8, fence: Fence) bool {
    const indent = indentOf(line);
    if (indent >= 4) return false;
    const n = runLength(line, indent, fence.char);
    return n >= fence.len and isBlank(line[indent + n ..]);
}

// the fence still open after `line`, given the one open before it
fn trackFence(open: ?Fence, line: []const u8) ?Fence {
    if (open) |fence| return if (isFenceClose(line, fence)) null else fence;
    return fenceStart(line);
}

fn atxHeading(line: []const u8) ?struct { level: u3, text: []const u8 } {
    const indent = indentOf(line);
    if (indent >= 4) return null;
    const n = runLength(line, indent, '#');
    if (n == 0 or n > 6) return null;
    const after = line[indent + n ..];
    if (after.len > 0 and after[0] != ' ') return null;
    var text = std.mem.trim(u8, after, " ");
    // an optional closing sequence of #s
    const closing = runLengthBack(text, text.len, '#');
    if (closing == text.len) {
        text = "";
    } else if (closing > 0 and text[text.len - closing - 1] == ' ') {
        text = std.mem.trimEnd(u8, text[0 .. text.len - closing], " ");
    }
    return .{ .level = @intCast(n), .text = text };
}

fn isThematicBreak(line: []const u8) bool {
    const indent = indentOf(line);
    if (indent >= 4 or indent >= line.len) return false;
    const c = line[indent];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (line[indent..]) |x| {
        if (x == c) {
            count += 1;
        } else if (x != ' ') return false;
    }
    return count >= 3;
}

fn setextLevel(line: []const u8) ?u3 {
    const indent = indentOf(line);
    if (indent >= 4 or indent >= line.len) return null;
    const c = line[indent];
    if (c != '=' and c != '-') return null;
    const n = runLength(line, indent, c);
    if (!isBlank(line[indent + n ..])) return null;
    return if (c == '=') 1 else 2;
}

// the content after a block quote marker and its optional space
fn quoteContent(line: []const u8) ?[]const u8 {
    const indent = indentOf(line);
    if (indent >= 4 or indent >= line.len or line[indent] != '>') return null;
    const rest = line[indent + 1 ..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

const Marker = struct {
    ordered: bool,
    // the bullet char or the ordered delimiter
    char: u8,
    start: usize,
    // where the first line's content begins
    content_start: usize,
    // the column continuation lines must reach to belong to the item
    indent: usize,
    empty: bool,
};

fn listMarker(line: []const u8) ?Marker {
    const indent = indentOf(line);
    if (indent >= 4 or indent >= line.len) return null;
    var pos = indent;
    var marker: Marker = .{ .ordered = false, .char = line[pos], .start = 0, .content_start = 0, .indent = 0, .empty = false };
    switch (line[pos]) {
        '-', '+', '*' => pos += 1,
        else => {
            const digits = runDigits(line, pos);
            if (digits == 0 or digits > 9) return null;
            pos += digits;
            if (pos >= line.len or (line[pos] != '.' and line[pos] != ')')) return null;
            marker.ordered = true;
            marker.char = line[pos];
            marker.start = std.fmt.parseInt(usize, line[indent..pos], 10) catch unreachable;
            pos += 1;
        },
    }
    if (isBlank(line[pos..])) {
        marker.empty = true;
        marker.content_start = line.len;
        marker.indent = pos + 1;
        return marker;
    }
    if (line[pos] != ' ') return null;
    var spaces = runLength(line, pos, ' ');
    // five or more spaces start indented code after a single space
    if (spaces > 4) spaces = 1;
    marker.content_start = pos + spaces;
    marker.indent = pos + spaces;
    return marker;
}

fn runDigits(s: []const u8, start: usize) usize {
    var n: usize = 0;
    while (start + n < s.len and std.ascii.isDigit(s[start + n])) n += 1;
    return n;
}

fn taskMarker(line: []const u8) ?struct { checked: bool, rest: []const u8 } {
    if (line.len < 3 or line[0] != '[' or line[2] != ']') return null;
    const checked = switch (line[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (line.len > 3 and line[3] != ' ') return null;
    return .{ .checked = checked, .rest = line[@min(4, line.len)..] };
}

fn isTableStart(lines: []const []const u8, i: usize) bool {
    if (i + 1 >= lines.len) return false;
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, lines[i], " "), "|")) return false;
    const row = std.mem.trim(u8, lines[i + 1], " ");
    if (std.mem.indexOfScalar(u8, row, '-') == null or std.mem.indexOfScalar(u8, row, '|') == null) return false;
    for (row) |c| switch (c) {
        '|', ':', '-', ' ' => {},
        else => return false,
    };
    return true;
}

fn isHtmlStart(line: []const u8) bool {
    const indent = indentOf(line);
    if (indent >= 4 or indent + 1 >= line.len or line[indent] != '<') return false;
    const c = line[indent + 1];
    if (!std.ascii.isAlphabetic(c) and c != '/' and c != '!' and c != '?') return false;
    return autolink(line[indent..]) == null;
}

// `s` with its backslash escapes resolved
fn unescape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and isPunct(s[i + 1])) i += 1;
        try out.append(arena, s[i]);
    }
    return out.items;
}

// the index of the next run of exactly `n` backticks at or after `start`
fn findBacktickRun(s: []const u8, start: usize, n: usize) ?usize {
    var i = start;
    while (i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        const len = runLength(s, i, '`');
        if (len == n) return i;
        i += len;
    }
    return null;
}

fn codeContent(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var content = raw;
    if (std.mem.indexOfScalar(u8, content, '\n') != null) {
        const copy = try arena.dupe(u8, content);
        std.mem.replaceScalar(u8, copy, '\n', ' ');
        content = copy;
    }
    // one space is stripped from each side of content that isn't all spaces
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and !isBlank(content)) {
        content = content[1 .. content.len - 1];
    }
    return content;
}

// parse the `(dest "title")` of an inline link starting at the `(` at `open`,
// ignoring the title. `next_close` caches the index of the next `)` (or
// src.len for none), so links scanned left to right never rescan for it.
fn inlineLink(arena: std.mem.Allocator, src: []const u8, open: usize, next_close: *usize) !?struct { dest: []const u8, end: usize } {
    var j = open + 1;
    while (j < src.len and isSpace(src[j])) j += 1;
    const start = j;
    var depth: usize = 0;
    while (j < src.len) {
        const c = src[j];
        if (c == ' ' or c < 0x20) break;
        if (c == '\\' and j + 1 < src.len and isPunct(src[j + 1])) {
            j += 2;
            continue;
        }
        if (c == '(') {
            // deeper nesting fails, which bounds the rescanning
            if (depth == max_paren_depth) return null;
            depth += 1;
        }
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        j += 1;
    }
    if (depth != 0) return null;
    const dest = src[start..j];
    const before_title = j;
    while (j < src.len and isSpace(src[j])) j += 1;
    // a title follows the destination after a space and runs to the `)`
    if (j < src.len and src[j] != ')' and j > before_title) {
        if (next_close.* < j) next_close.* = std.mem.indexOfScalarPos(u8, src, j, ')') orelse src.len;
        j = next_close.*;
    }
    if (j >= src.len or src[j] != ')') return null;
    return .{ .dest = try unescape(arena, dest), .end = j + 1 };
}

// an autolink `<scheme:...>` or `<user@host>` at the start of `s`
fn autolink(s: []const u8) ?[]const u8 {
    if (s.len < 3 or s[0] != '<') return null;
    var close: usize = 1;
    while (close < s.len and s[close] > ' ' and s[close] != '<' and s[close] != '>') close += 1;
    if (close >= s.len or s[close] != '>') return null;
    const body = s[1..close];

    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return null;
    const scheme = body[0..colon];
    if (scheme.len < 2 or scheme.len > 32 or !std.ascii.isAlphabetic(scheme[0])) return null;
    for (scheme) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return null;
    }
    return body;
}

fn isAutolinkBoundary(c: u8) bool {
    return switch (c) {
        ' ', '\n', '*', '_', '~', '(' => true,
        else => false,
    };
}

// the length of a bare `http://` or `https://` link at the start of `s`
fn bareAutolink(s: []const u8) ?usize {
    const prefix_len: usize = if (std.ascii.startsWithIgnoreCase(s, "https://")) 8 else if (std.ascii.startsWithIgnoreCase(s, "http://")) 7 else return null;
    var end = prefix_len;
    while (end < s.len and !isSpace(s[end]) and s[end] != '<') end += 1;
    var unmatched_closes = @as(isize, @intCast(std.mem.count(u8, s[0..end], ")"))) - @as(isize, @intCast(std.mem.count(u8, s[0..end], "(")));
    // trailing punctuation is left out, as is an unbalanced closing paren
    while (end > prefix_len) : (end -= 1) {
        const c = s[end - 1];
        if (c == ')' and unmatched_closes > 0) {
            unmatched_closes -= 1;
        } else if (std.mem.indexOfScalar(u8, "?!.,:;*_~'\"", c) == null) break;
    }
    return if (end > prefix_len) end else null;
}

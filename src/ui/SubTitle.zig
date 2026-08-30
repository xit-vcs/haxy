const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

content: []const u8,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, orig_content: []const u8) !Self {
    return .{
        .content = try renderSubTitle(arena.allocator(), orig_content),
    };
}

pub const View = struct {
    text_box: wgt.TextBox,

    pub fn init(allocator: std.mem.Allocator, data: *const Self) !View {
        var text_box = try wgt.TextBox.init(allocator, data.content, .{ .border_style = null, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        return .{ .text_box = text_box };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.text_box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *View) void {
        self.text_box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.text_box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.text_box.getFocus();
    }
};

// 2-row sextant subtitle font, a half-height companion to Title.
//
// each glyph is a 4x6 sub-pixel bitmap that renders as a 2x2 grid of
// sextant-block characters (U+1FB00-1FB3B), the same character set as Title so
// the two share a look. (the glyphs are 4 sub-pixels wide rather than 6, which
// is one sextant cell narrower per character.) the four 2x3 patterns that
// aren't sextants (empty, left column, right column, full) fall back to
// U+0020, U+258C, U+2590, U+2588 respectively. unlike Title there is no dither:
// at this height every sub-pixel renders, which keeps the shorter glyphs
// legible.

const Glyph = [6][]const u8;

fn glyphFor(c: u8) ?Glyph {
    return switch (std.ascii.toUpper(c)) {
        ' ' => .{
            "....",
            "....",
            "....",
            "....",
            "....",
            "....",
        },
        'A' => .{
            ".##.",
            "#..#",
            "####",
            "#..#",
            "#..#",
            "#..#",
        },
        'B' => .{
            "###.",
            "#..#",
            "###.",
            "#..#",
            "#..#",
            "###.",
        },
        'C' => .{
            ".###",
            "#...",
            "#...",
            "#...",
            "#...",
            ".###",
        },
        'D' => .{
            "###.",
            "#..#",
            "#..#",
            "#..#",
            "#..#",
            "###.",
        },
        'E' => .{
            "####",
            "#...",
            "###.",
            "#...",
            "#...",
            "####",
        },
        'F' => .{
            "####",
            "#...",
            "###.",
            "#...",
            "#...",
            "#...",
        },
        'G' => .{
            ".###",
            "#...",
            "#.##",
            "#..#",
            "#..#",
            ".###",
        },
        'H' => .{
            "#..#",
            "#..#",
            "####",
            "#..#",
            "#..#",
            "#..#",
        },
        'I' => .{
            "####",
            ".##.",
            ".##.",
            ".##.",
            ".##.",
            "####",
        },
        'J' => .{
            "..##",
            "...#",
            "...#",
            "...#",
            "#..#",
            ".##.",
        },
        'K' => .{
            "#..#",
            "#.#.",
            "##..",
            "##..",
            "#.#.",
            "#..#",
        },
        'L' => .{
            "#...",
            "#...",
            "#...",
            "#...",
            "#...",
            "####",
        },
        'M' => .{
            "#..#",
            "####",
            "####",
            "#..#",
            "#..#",
            "#..#",
        },
        'N' => .{
            "#..#",
            "##.#",
            "##.#",
            "#.##",
            "#.##",
            "#..#",
        },
        'O' => .{
            ".##.",
            "#..#",
            "#..#",
            "#..#",
            "#..#",
            ".##.",
        },
        'P' => .{
            "###.",
            "#..#",
            "###.",
            "#...",
            "#...",
            "#...",
        },
        'Q' => .{
            ".##.",
            "#..#",
            "#..#",
            "#.##",
            ".##.",
            "...#",
        },
        'R' => .{
            "###.",
            "#..#",
            "###.",
            "##..",
            "#.#.",
            "#..#",
        },
        'S' => .{
            ".###",
            "#...",
            ".##.",
            "...#",
            "#..#",
            "###.",
        },
        'T' => .{
            "####",
            ".##.",
            ".##.",
            ".##.",
            ".##.",
            ".##.",
        },
        'U' => .{
            "#..#",
            "#..#",
            "#..#",
            "#..#",
            "#..#",
            ".##.",
        },
        'V' => .{
            "#..#",
            "#..#",
            "#..#",
            "#..#",
            ".##.",
            ".##.",
        },
        'W' => .{
            "#..#",
            "#..#",
            "#..#",
            "####",
            "####",
            ".##.",
        },
        'X' => .{
            "#..#",
            "#..#",
            ".##.",
            ".##.",
            "#..#",
            "#..#",
        },
        'Y' => .{
            "#..#",
            "#..#",
            ".##.",
            ".##.",
            ".##.",
            ".##.",
        },
        'Z' => .{
            "####",
            "...#",
            "..#.",
            ".#..",
            "#...",
            "####",
        },
        '0' => .{
            ".##.",
            "#.##",
            "#.##",
            "##.#",
            "##.#",
            ".##.",
        },
        '1' => .{
            ".##.",
            "###.",
            ".##.",
            ".##.",
            ".##.",
            "####",
        },
        '2' => .{
            ".##.",
            "#..#",
            "..#.",
            ".#..",
            "#...",
            "####",
        },
        '3' => .{
            "###.",
            "...#",
            ".##.",
            "...#",
            "#..#",
            "###.",
        },
        '4' => .{
            "..#.",
            ".##.",
            "#.#.",
            "####",
            "..#.",
            "..#.",
        },
        '5' => .{
            "####",
            "#...",
            "###.",
            "...#",
            "#..#",
            "###.",
        },
        '6' => .{
            ".##.",
            "#...",
            "###.",
            "#..#",
            "#..#",
            ".##.",
        },
        '7' => .{
            "####",
            "...#",
            "..#.",
            "..#.",
            ".#..",
            ".#..",
        },
        '8' => .{
            ".##.",
            "#..#",
            ".##.",
            "#..#",
            "#..#",
            ".##.",
        },
        '9' => .{
            ".##.",
            "#..#",
            "#..#",
            ".###",
            "...#",
            ".##.",
        },
        '-' => .{
            "....",
            "....",
            ".##.",
            ".##.",
            "....",
            "....",
        },
        '.' => .{
            "....",
            "....",
            "....",
            "....",
            ".##.",
            ".##.",
        },
        else => null,
    };
}

// map a 2x3 sub-pixel pattern to its corresponding sextant codepoint
fn sextantCodepoint(pattern: u6) u21 {
    return switch (pattern) {
        0b000000 => ' ',
        0b010101 => 0x258C, // ▌ left half block
        0b101010 => 0x2590, // ▐ right half block
        0b111111 => 0x2588, // █ full block
        else => blk: {
            var offset: u21 = @as(u21, pattern) - 1;
            if (pattern > 0b010101) offset -= 1;
            if (pattern > 0b101010) offset -= 1;
            break :blk 0x1FB00 + offset;
        },
    };
}

fn renderSubTitle(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var rows: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&rows) |*r| r.deinit(allocator);

    var first = true;
    for (input) |c| {
        const glyph = glyphFor(c) orelse continue;

        var on: [6][4]bool = std.mem.zeroes([6][4]bool);
        for (0..6) |r| {
            for (0..4) |col| {
                on[r][col] = glyph[r][col] == '#';
            }
        }

        if (!first) {
            for (&rows) |*r| try r.append(allocator, ' ');
        }
        first = false;

        for (0..2) |text_row| {
            for (0..2) |text_col| {
                var pattern: u6 = 0;
                for (0..3) |sub_row| {
                    for (0..2) |sub_col| {
                        const row_idx = text_row * 3 + sub_row;
                        const col_idx = text_col * 2 + sub_col;
                        if (on[row_idx][col_idx]) {
                            pattern |= @as(u6, 1) << @intCast(sub_row * 2 + sub_col);
                        }
                    }
                }
                const cp = sextantCodepoint(pattern);
                var utf8_buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &utf8_buf);
                try rows[text_row].appendSlice(allocator, utf8_buf[0..len]);
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, rows[0].items);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, rows[1].items);
    return out.toOwnedSlice(allocator);
}

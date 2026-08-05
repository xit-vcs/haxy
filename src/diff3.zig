//! three-way line merge of issue text fields, built on xit's Diff3Iterator.
//! the conflict view renders the chunks and the submit paths reassemble them.

const std = @import("std");
const evt = @import("./event.zig");
const xit = @import("xit");
const rp = xit.repo;
const df = xit.diff;

// any kind works for buffer-backed iterators; the line size cap must admit a
// description that is one long line
const repo_kind: rp.RepoKind = .git;
const repo_opts: rp.RepoOpts(repo_kind) = .{ .max_line_size = evt.max_event_size };

const LineIterator = df.LineIterator(repo_kind, repo_opts);

pub const Chunk = union(enum) {
    // both sides agree on this text
    same: []const u8,
    // only one side changed it, so its version stands; null means it removed
    // the lines
    auto: struct { text: ?[]const u8, theirs: bool },
    // both sides changed it differently; null means that side removed the lines
    conflict: struct { ours: ?[]const u8, theirs: ?[]const u8 },
};

// split base/ours/theirs into a chunk sequence. chunk texts are allocated in
// `arena` and hold whole lines joined with newlines.
pub fn chunks(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
) ![]Chunk {
    const aa = arena.allocator();

    var base_iter = try LineIterator.initFromTestBuffer(io, gpa, base);
    defer base_iter.deinit();
    var ours_iter = try LineIterator.initFromTestBuffer(io, gpa, ours);
    defer ours_iter.deinit();
    var theirs_iter = try LineIterator.initFromTestBuffer(io, gpa, theirs);
    defer theirs_iter.deinit();

    // invalid utf-8 degrades an iterator to .binary with no lines, which would
    // read as an empty side; treat the whole text as one conflict instead
    if (base_iter.source == .binary or ours_iter.source == .binary or theirs_iter.source == .binary) {
        const list = try aa.alloc(Chunk, 1);
        list[0] = .{ .conflict = .{
            .ours = if (ours.len > 0) try aa.dupe(u8, ours) else null,
            .theirs = if (theirs.len > 0) try aa.dupe(u8, theirs) else null,
        } };
        return list;
    }

    var diff3_iter = try df.Diff3Iterator(repo_kind, repo_opts).init(gpa, &base_iter, &ours_iter, &theirs_iter);
    defer diff3_iter.deinit();

    var list: std.ArrayList(Chunk) = .empty;
    while (try diff3_iter.next()) |chunk| {
        switch (chunk) {
            .clean => |range| try list.append(aa, .{ .same = (try joinRange(aa, &base_iter, range)) orelse unreachable }),
            .conflict => |ranges| {
                // the iterator marks every non-identical chunk a conflict, so
                // one-sided changes are classified here, like xit's merge does
                const base_text = try joinRange(aa, &base_iter, ranges.o_range);
                const ours_text = try joinRange(aa, &ours_iter, ranges.a_range);
                const theirs_text = try joinRange(aa, &theirs_iter, ranges.b_range);
                if (textEqual(ours_text, theirs_text)) {
                    // the same change on both sides; nothing left = no chunk
                    if (ours_text) |text| try list.append(aa, .{ .same = text });
                } else if (textEqual(base_text, ours_text)) {
                    try list.append(aa, .{ .auto = .{ .text = theirs_text, .theirs = true } });
                } else if (textEqual(base_text, theirs_text)) {
                    try list.append(aa, .{ .auto = .{ .text = ours_text, .theirs = false } });
                } else {
                    try list.append(aa, .{ .conflict = .{ .ours = ours_text, .theirs = theirs_text } });
                }
            },
        }
    }
    return try list.toOwnedSlice(aa);
}

// join the chunks back into one document. `resolutions` holds the final text
// of each conflict chunk in order; an empty resolution drops the hunk's lines.
pub fn assemble(
    allocator: std.mem.Allocator,
    chunk_list: []const Chunk,
    resolutions: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var resolution_index: usize = 0;
    for (chunk_list) |chunk| {
        const piece: ?[]const u8 = switch (chunk) {
            .same => |text| text,
            .auto => |auto| auto.text,
            .conflict => blk: {
                const resolution = resolutions[resolution_index];
                resolution_index += 1;
                break :blk if (resolution.len > 0) resolution else null;
            },
        };
        if (piece) |text| {
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, text);
        }
    }
    return try out.toOwnedSlice(allocator);
}

// a range's lines joined with newlines, or null when it spans no lines
fn joinRange(
    aa: std.mem.Allocator,
    iter: *LineIterator,
    range_maybe: ?df.Diff3Iterator(repo_kind, repo_opts).Range,
) !?[]const u8 {
    const range = range_maybe orelse return null;
    if (range.end <= range.begin) return null;
    var out: std.ArrayList(u8) = .empty;
    for (range.begin..range.end) |line_num| {
        // buffer-backed lines are borrowed, so no free is needed
        const line = try iter.get(line_num);
        if (line_num > range.begin) try out.append(aa, '\n');
        try out.appendSlice(aa, line);
    }
    return try out.toOwnedSlice(aa);
}

fn textEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const a_text = a orelse return b == null;
    const b_text = b orelse return false;
    return std.mem.eql(u8, a_text, b_text);
}

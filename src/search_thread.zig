const std = @import("std");
const evt = @import("event.zig");
const srch = @import("search.zig");
const xit = @import("xit");
const hash = xit.hash;

// the thread search indexes: one per kind, inside the haxy moment, so events
// carry them and every host that consumes events builds them. a doc key is the
// thread's creation order key, which never changes. issues and patches list in
// that order too, so their list sets filter a query by intersection.

// one indexed thread: its doc key and the fields the index covers
pub const Doc = struct {
    key: []const u8,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
};

pub fn indexKey(comptime kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "word->issue-id-set",
        .patch => "word->patch-id-set",
        .discuss => "word->discussion-id-set",
        else => @compileError("no thread index for " ++ @tagName(kind)),
    };
}

// `record`'s indexed side under `key`, or null when it is removed and so has
// no postings
pub fn doc(key: []const u8, record: anytype) ?Doc {
    if (record.removed) return null;
    return .{
        .key = key,
        .title = record.event.title,
        .tags = record.event.tags,
        .description = record.event.description,
    };
}

// replace `old`'s postings with `new`'s. an unchanged doc costs nothing: a
// status change or an edit that leaves the indexed fields alone returns here.
pub fn update(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_write),
    allocator: std.mem.Allocator,
    old: ?Doc,
    new: ?Doc,
) !void {
    if (old == null and new == null) return;
    if (old) |before| if (new) |after| {
        if (std.mem.eql(u8, before.key, after.key) and
            std.mem.eql(u8, before.title, after.title) and
            std.mem.eql(u8, before.tags, after.tags) and
            std.mem.eql(u8, before.description, after.description)) return;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const index = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, indexKey(kind))));
    if (old) |before| try srch.remove(DB, index, allocator, before.key, try text(arena.allocator(), before));
    if (new) |after| try srch.add(DB, index, allocator, after.key, try text(arena.allocator(), after));
}

// the doc keys matching `query_text`, in key order, narrowed to `filter` when
// it is keyed the same way
pub fn query(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_only),
    aa: std.mem.Allocator,
    query_text: []const u8,
    filter: ?DB.SortedSet(.read_only),
) !srch.Query(DB) {
    const cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, indexKey(kind))) orelse return .{ .terms = &.{} };
    const index = try DB.SortedMap(.read_only).init(cursor);
    var results = try srch.Query(DB).init(index, aa, query_text);
    if (filter) |set| try results.require(aa, set);
    return results;
}

// the text a thread is indexed under: the title and tags first, so the
// tokenizer's caps can only drop the tail of a long description.
fn text(aa: std.mem.Allocator, value: Doc) ![]const u8 {
    return std.mem.concat(aa, u8, &.{ value.title, " ", value.tags, " ", value.description });
}

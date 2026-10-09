const std = @import("std");
const evt = @import("event.zig");
const srch = @import("search.zig");
const xit = @import("xit");
const hash = xit.hash;

// the thread search indexes: one per kind, inside the haxy moment, so events
// carry them and every host that consumes events builds them. a doc key is the
// thread's creation order key, which never changes. issues and patches list in
// that order too, so their list sets filter a query by intersection.

pub fn indexKey(comptime kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "word->issue-id-set",
        .patch => "word->patch-id-set",
        .discuss => "word->discussion-id-set",
        else => @compileError("no thread index for " ++ @tagName(kind)),
    };
}

// reindex the thread `key` names after `old_maybe` became `new`. an unchanged
// doc costs nothing: a status change or an edit that leaves the indexed fields
// alone returns here.
pub fn update(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_write),
    allocator: std.mem.Allocator,
    key: []const u8,
    old_maybe: anytype,
    new: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const old_text = if (old_maybe) |old| try text(aa, old) else "";
    const new_text = try text(aa, new);
    if (std.mem.eql(u8, old_text, new_text)) return;
    const index = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, indexKey(kind))));
    try srch.replace(DB, index, allocator, key, old_text, new_text);
}

// the doc keys matching `query_text`, in key order, narrowed to each non-null
// set in `filters`, which must be keyed the same way
pub fn query(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_only),
    aa: std.mem.Allocator,
    query_text: []const u8,
    filters: []const ?DB.SortedSet(.read_only),
) !srch.Query(DB) {
    // no index means no words match, which one empty term expresses
    var results: srch.Query(DB) = .{ .terms = .empty };
    if (try haxy_moment.getCursor(hash.hashInt(hash_kind, indexKey(kind)))) |cursor| {
        results = try srch.Query(DB).init(try DB.SortedMap(.read_only).init(cursor), aa, query_text);
    } else {
        try results.terms.append(aa, .{ .postings = &.{} });
    }
    for (filters) |filter| if (filter) |set| try results.require(aa, set);
    return results;
}

// the text a thread is indexed under, none once it is removed: the title and
// labels first, so the tokenizer's caps can only drop the tail of a long
// description.
fn text(aa: std.mem.Allocator, record: anytype) ![]const u8 {
    if (record.removed) return "";
    return std.mem.concat(aa, u8, &.{ record.event.title, " ", record.event.labels, " ", record.event.description });
}

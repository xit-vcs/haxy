const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;
const obj = xit.object;
const rp = xit.repo;

base_oid: []const u8,
source_oid: []const u8,
message: []const u8,

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
    event_oid: []const u8,
    base_tree_oid: []const u8,
    head_tree_oid: []const u8,
    patch_oid: []const u8,
};

const Self = @This();

pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->patchrev";
pub const id_set_key = "patchrev-id-set";

// create the mergeable squash commit represented by this patch revision
pub fn writeSquashCommit(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    event: Self,
    head_tree_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    author: []const u8,
    committer: []const u8,
    timestamp: u64,
) ![hash.hexLen(repo_opts.hash)]u8 {
    var base_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    if (event.base_oid.len != base_oid.len) return error.InvalidPatch;
    @memcpy(&base_oid, event.base_oid);
    try validateOid(repo_opts.hash, &base_oid);
    const parent_oids = [_][hash.hexLen(repo_opts.hash)]u8{base_oid};
    return try obj.writeCommitWithoutRef(repo_kind, repo_opts, state, io, allocator, .{
        .author = author,
        .committer = committer,
        .message = event.message,
        .parent_oids = &parent_oids,
        .timestamp = timestamp,
    }, head_tree_oid);
}

pub fn readTrees(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    tree_oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !struct {
    base: [hash.hexLen(repo_opts.hash)]u8,
    head: [hash.hexLen(repo_opts.hash)]u8,
} {
    var tree_object = try obj.Object(repo_kind, repo_opts).init(state, io, allocator, tree_oid);
    defer tree_object.deinit();

    const entries = switch (tree_object.content) {
        .tree => |tree| tree.entries,
        else => return error.InvalidPatch,
    };
    if (entries.count() != 2) return error.InvalidPatch;
    const base = entries.get("base") orelse return error.InvalidPatch;
    const head = entries.get("head") orelse return error.InvalidPatch;
    if (!base.isTree() or !head.isTree()) return error.InvalidPatch;

    const base_oid = std.fmt.bytesToHex(base.oid, .lower);
    const head_oid = std.fmt.bytesToHex(head.oid, .lower);
    var base_reader = try obj.ObjectReader(repo_kind, repo_opts).init(state, io, allocator, &base_oid);
    defer base_reader.deinit();
    var head_reader = try obj.ObjectReader(repo_kind, repo_opts).init(state, io, allocator, &head_oid);
    defer head_reader.deinit();
    if (base_reader.header().kind != .tree or head_reader.header().kind != .tree) return error.InvalidPatch;

    return .{ .base = base_oid, .head = head_oid };
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    _: ?[]const u8,
) !void {
    const record_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(record_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = if (record_maybe) |value|
        value
    else blk: {
        var value = existing_maybe orelse return error.EventNotFound;
        value.removed = true;
        break :blk value;
    };

    try validateOid(hash_kind, record.event.base_oid);
    try validateOid(hash_kind, record.event.source_oid);
    try validateOid(hash_kind, record.event_oid);
    try validateOid(hash_kind, record.base_tree_oid);
    try validateOid(hash_kind, record.head_tree_oid);
    try validateOid(hash_kind, record.patch_oid);

    if (existing_maybe) |existing| {
        if (!std.mem.eql(u8, existing.event.base_oid, record.event.base_oid) or
            !std.mem.eql(u8, existing.event.source_oid, record.event.source_oid) or
            !std.mem.eql(u8, existing.event.message, record.event.message) or
            !std.mem.eql(u8, existing.base_tree_oid, record.base_tree_oid) or
            !std.mem.eql(u8, existing.head_tree_oid, record.head_tree_oid) or
            !std.mem.eql(u8, existing.patch_oid, record.patch_oid))
        {
            return error.PatchRevChanged;
        }
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
        record.event_oid = existing.event_oid;
    }

    const cursor = try records.putCursor(record_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .patchrev, record.created_order, record.removed);

    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key)));
        try ids.put(&evt.orderKeyDesc(record.created_order, event_id));
    }
}

pub fn validateOid(comptime hash_kind: hash.HashKind, oid: []const u8) !void {
    var bytes: [hash.byteLen(hash_kind)]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, oid);
    if (!std.mem.eql(u8, oid, &std.fmt.bytesToHex(bytes, .lower))) return error.InvalidOid;
}

pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
}

pub const WithId = struct {
    id: [evt.event_id_size]u8,
    record: Record,
};

pub fn readNewest(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
) !?WithId {
    const ids_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, id_set_key)) orelse return null;
    const ids = try DB.SortedSet(.read_only).init(ids_cursor);
    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(DB, cursor);
        const record = (try readById(DB, hash_kind, haxy_moment, arena, &id)) orelse continue;
        if (!record.removed) return .{ .id = id, .record = record };
    }
    return null;
}

// squash commits referenced only by patch revision records
pub fn gcRoots(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    allocator: std.mem.Allocator,
    haxy_moment: DB.HashMap(.read_only),
) ![][hash.hexLen(hash_kind)]u8 {
    var roots: std.ArrayList([hash.hexLen(hash_kind)]u8) = .empty;
    errdefer roots.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ids_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, id_set_key)) orelse return try roots.toOwnedSlice(allocator);
    const ids = try DB.SortedSet(.read_only).init(ids_cursor);
    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |cursor| {
        _ = arena.reset(.retain_capacity);
        const id = try evt.readOrderKeyId(DB, cursor);
        const record = (try readById(DB, hash_kind, haxy_moment, &arena, &id)) orelse continue;
        var oid: [hash.hexLen(hash_kind)]u8 = undefined;
        if (record.patch_oid.len != oid.len) return error.InvalidOid;
        @memcpy(&oid, record.patch_oid);
        try roots.append(allocator, oid);
    }

    return try roots.toOwnedSlice(allocator);
}

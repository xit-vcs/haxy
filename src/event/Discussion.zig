const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8, // space-separated

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_ts: u64 = 0,
};

const Self = @This();

pub const tag_max_len = 64;

pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->discussion";
pub const id_set_key = "discussion-id-set";
pub const active_id_set_key = "active-discussion-id-set";
pub const tag_to_id_set_key = "tag->discussion-id-set";

pub fn tagIterator(tags: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, tags, ' ');
}

pub fn fieldsValid(title: []const u8, tags: []const u8) bool {
    if (title.len == 0) return false;
    var tag_iter = tagIterator(tags);
    while (tag_iter.next()) |tag| {
        if (tag.len > tag_max_len) return false;
    }
    return true;
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
    const discussion_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const active = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, active_id_set_key)));
    const tags = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, tag_to_id_set_key)));

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(discussion_key);
    if (existing_cursor_maybe) |existing_cursor| {
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(existing_cursor));
    }

    var record_to_write = if (record_maybe) |record|
        record
    else blk: {
        var record = existing_record_maybe orelse return error.EventNotFound;
        record.removed = true;
        break :blk record;
    };

    if (existing_record_maybe) |existing| {
        record_to_write.created_ts = existing.created_ts;
        record_to_write.author_email = existing.author_email;
        if (!existing.removed) {
            const order_key = evt.orderKeyDesc(existing.created_ts, event_id);
            _ = try active.remove(&order_key);
            try removeFromTagSets(DB, tags, existing.event.tags, &order_key);
        }
    }

    const record = try DB.HashMap(.read_write).init(try records.putCursor(discussion_key));
    try evt.upsert(Record, DB, hash_kind, record, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .discussion, record_to_write.created_ts, record_to_write.removed);

    const order_key = evt.orderKeyDesc(record_to_write.created_ts, event_id);
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key)));
        try ids.put(&order_key);
    }

    if (!record_to_write.removed) {
        try active.put(&order_key);
        var tag_iter = tagIterator(record_to_write.event.tags);
        while (tag_iter.next()) |tag| {
            if (tag.len == 0 or tag.len > tag_max_len) continue;
            const set = try DB.SortedSet(.read_write).init(try tags.putCursor(tag));
            try set.put(&order_key);
        }
    }
}

pub fn update(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
    author: evt.CommitAuthor,
) !void {
    if (!fieldsValid(title, tags)) return error.InvalidFields;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const discussion = (try readById(repo_kind, repo_opts, io, allocator, &arena, repo, id)) orelse return error.NotFound;
    if (discussion.removed) return error.NotFound;

    try evt.consume(repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .discussion = .{
            .title = title,
            .tags = tags,
            .description = description,
        } },
    }});
}

fn removeFromTagSets(comptime DB: type, tags: DB.SortedMap(.read_write), names: []const u8, order_key: []const u8) !void {
    var tag_iter = tagIterator(names);
    while (tag_iter.next()) |tag| {
        if (tag.len == 0 or tag.len > tag_max_len) continue;
        const cursor = try tags.putCursor(tag);
        const set = try DB.SortedSet(.read_write).init(cursor);
        _ = try set.remove(order_key);
        if (0 == try set.count()) _ = try tags.remove(tag);
    }
}

pub fn readById(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !?Record {
    const DB = evt.EventDB(repo_opts.hash);
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return null
    else
        evt.currentMoment(repo_opts, repo)) catch return null;
    const records_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(repo_opts.hash, id)) orelse return null;
    return try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(record_cursor));
}

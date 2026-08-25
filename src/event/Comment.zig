const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

thread_id: [evt.event_id_size * 2]u8,
parent_id: [evt.event_id_size * 2]u8,
body: []const u8,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->comment";
pub const id_set_key = "comment-id-set";

// the indexes the thread reads
pub const thread_id_to_comment_id_set_key = "thread-id->comment-id-set";
pub const parent_id_to_comment_id_set_key = "parent-id->comment-id-set";

pub fn fieldsValid(body: []const u8) bool {
    return body.len != 0;
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
    const comment_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_comment_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key));
    const event_id_to_comment = try DB.HashMap(.read_write).init(event_id_to_comment_cursor);

    const thread_id_to_comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, thread_id_to_comment_id_set_key));
    const thread_id_to_comment_id_set = try DB.HashMap(.read_write).init(thread_id_to_comment_id_set_cursor);

    const parent_id_to_comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, parent_id_to_comment_id_set_key));
    const parent_id_to_comment_id_set = try DB.HashMap(.read_write).init(parent_id_to_comment_id_set_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_comment.getCursor(comment_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_comment = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_comment);
    }

    var record_to_write = if (record_maybe) |record|
        record
    else blk: {
        var record = existing_record_maybe orelse return error.EventNotFound;
        record.removed = true;
        break :blk record;
    };

    const thread_id = try evt.parseEventId(&record_to_write.event.thread_id);
    _ = try evt.parseEventId(&record_to_write.event.parent_id);

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation order and author
        record_to_write.created_order = existing_record.created_order;
        record_to_write.author_email = existing_record.author_email;

        // a comment cannot move between threads or positions in the thread
        if (!std.mem.eql(u8, &existing_record.event.thread_id, &record_to_write.event.thread_id)) return error.ThreadChanged;
        if (!std.mem.eql(u8, &existing_record.event.parent_id, &record_to_write.event.parent_id)) return error.ParentChanged;
    }

    const comment_cursor = try event_id_to_comment.putCursor(comment_key);
    const comment = try DB.HashMap(.read_write).init(comment_cursor);
    try evt.upsert(Record, DB, hash_kind, comment, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .comment, record_to_write.created_order, record_to_write.removed);

    if (existing_cursor_maybe == null) {
        const comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key));
        const comment_id_set = try DB.SortedSet(.read_write).init(comment_id_set_cursor);
        try comment_id_set.put(&evt.orderKeyDesc(record_to_write.created_order, event_id));
        try evt.touchThread(DB, hash_kind, haxy_moment, &thread_id, record_to_write.created_order, arena);
    }

    // removed comments stay in the thread so their replies remain connected
    const thread_order_key = evt.orderKey(record_to_write.created_order, event_id);
    const thread_comments_cursor = try thread_id_to_comment_id_set.putCursor(hash.hashInt(hash_kind, &record_to_write.event.thread_id));
    const thread_comments = try DB.SortedSet(.read_write).init(thread_comments_cursor);
    try thread_comments.put(&thread_order_key);

    const replies_cursor = try parent_id_to_comment_id_set.putCursor(hash.hashInt(hash_kind, &record_to_write.event.parent_id));
    const replies = try DB.SortedSet(.read_write).init(replies_cursor);
    try replies.put(&thread_order_key);
}

// create a comment and return its event id. `repo` must be writable.
pub fn create(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    thread_id: *const [evt.event_id_size * 2]u8,
    parent_id: *const [evt.event_id_size * 2]u8,
    body: []const u8,
    author: evt.CommitAuthor,
) ![evt.event_id_size * 2]u8 {
    if (!fieldsValid(body)) return error.InvalidFields;

    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id = std.fmt.bytesToHex(id_bytes, .lower);
    try evt.consume(.repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = event_id,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .comment = .{
            .thread_id = thread_id.*,
            .parent_id = parent_id.*,
            .body = body,
        } },
    }});
    return event_id;
}

// replace a comment's body while preserving its thread and parent. `repo` must
// be writable.
pub fn update(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    thread_id: *const [evt.event_id_size * 2]u8,
    comment_id: *const [evt.event_id_size]u8,
    body: []const u8,
    author: evt.CommitAuthor,
) !void {
    if (!fieldsValid(body)) return error.InvalidFields;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const DB = evt.EventDB(repo_opts.hash);
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return error.NotFound
    else
        evt.currentMoment(repo_opts, repo)) catch return error.NotFound;
    const comment = (try readById(DB, repo_opts.hash, moment, &arena, comment_id)) orelse return error.NotFound;
    if (!std.mem.eql(u8, &comment.event.thread_id, thread_id)) return error.NotFound;
    if (comment.removed) return error.NotFound;

    var updated = comment.event;
    updated.body = body;
    try evt.consume(.repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(comment_id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .comment = updated },
    }});
}

// read a comment by event id, or null if the id isn't a known comment. field
// byte slices are allocated in `arena`.
pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    comment_id: []const u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, comment_id)) orelse return null;
    const record_map = try DB.HashMap(.read_only).init(record_cursor);
    return try evt.read(Record, DB, hash_kind, arena, record_map);
}

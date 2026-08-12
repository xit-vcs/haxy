const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

thread_id: [evt.event_id_size * 2]u8,
parent_id: [evt.event_id_size * 2]u8,
body: []const u8,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    deleted: bool = false,
    author_email: ?[]const u8 = null,
    created_ts: u64 = 0, // the commit timestamp of the event that first created this comment
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const record_map_key = "event-id->comment";
pub const id_set_key = "comment-id-set";
pub const conflicts_key = "conflicted-comment-id->conflict";
pub const id_to_field_to_oid_key = "comment-id->field->oid";

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
    // the commit this event came from, recorded against every field it
    // changes. null from `merge`, which sets oids and conflicts itself.
    event_oid: ?[]const u8,
) !void {
    const comment_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_comment_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key));
    const event_id_to_comment = try DB.HashMap(.read_write).init(event_id_to_comment_cursor);

    const thread_id_to_comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, thread_id_to_comment_id_set_key));
    const thread_id_to_comment_id_set = try DB.HashMap(.read_write).init(thread_id_to_comment_id_set_cursor);

    const parent_id_to_comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, parent_id_to_comment_id_set_key));
    const parent_id_to_comment_id_set = try DB.HashMap(.read_write).init(parent_id_to_comment_id_set_cursor);

    const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key));
    const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);

    const comment_id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key));
    const comment_id_to_field_to_oid = try DB.HashMap(.read_write).init(comment_id_to_field_to_oid_cursor);

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
        record.deleted = true;
        break :blk record;
    };

    // references use the same lower-case hex form as event ids in json
    var id_bytes: [evt.event_id_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id_bytes, &record_to_write.event.thread_id);
    if (!std.mem.eql(u8, &record_to_write.event.thread_id, &std.fmt.bytesToHex(id_bytes, .lower))) return error.InvalidEventId;
    _ = try std.fmt.hexToBytes(&id_bytes, &record_to_write.event.parent_id);
    if (!std.mem.eql(u8, &record_to_write.event.parent_id, &std.fmt.bytesToHex(id_bytes, .lower))) return error.InvalidEventId;

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation timestamp and author
        record_to_write.created_ts = existing_record.created_ts;
        record_to_write.author_email = existing_record.author_email;

        // a comment cannot move between threads or positions in the thread
        if (!std.mem.eql(u8, &existing_record.event.thread_id, &record_to_write.event.thread_id)) return error.ThreadChanged;
        if (!std.mem.eql(u8, &existing_record.event.parent_id, &record_to_write.event.parent_id)) return error.ParentChanged;

        // any event settles the conflict, since resolving in the ui may
        // keep our own values and so change nothing to detect
        if (event_oid != null or record_to_write.deleted) {
            _ = try conflicts.remove(&evt.orderKeyDesc(existing_record.created_ts, event_id));
        }
    }

    try evt.writeOid(Self, DB, hash_kind, comment_id_to_field_to_oid, comment_key, if (existing_record_maybe) |existing| existing.event else null, record_to_write.event, event_oid);

    const comment_cursor = try event_id_to_comment.putCursor(comment_key);
    const comment = try DB.HashMap(.read_write).init(comment_cursor);
    try evt.upsert(Record, DB, hash_kind, comment, record_to_write);

    if (existing_cursor_maybe == null) {
        const comment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key));
        const comment_id_set = try DB.SortedSet(.read_write).init(comment_id_set_cursor);
        try comment_id_set.put(&evt.orderKeyDesc(record_to_write.created_ts, event_id));
    }

    // tombstones stay in the thread so their replies remain connected
    const thread_order_key = evt.orderKey(record_to_write.created_ts, event_id);
    const thread_comments_cursor = try thread_id_to_comment_id_set.putCursor(hash.hashInt(hash_kind, &record_to_write.event.thread_id));
    const thread_comments = try DB.SortedSet(.read_write).init(thread_comments_cursor);
    try thread_comments.put(&thread_order_key);

    const replies_cursor = try parent_id_to_comment_id_set.putCursor(hash.hashInt(hash_kind, &record_to_write.event.parent_id));
    const replies = try DB.SortedSet(.read_write).init(replies_cursor);
    try replies.put(&thread_order_key);
}

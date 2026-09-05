const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
repo_id: []const u8,
stage: Stage = .draft,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

pub const Stage = enum {
    draft,
    publish,
};

pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->fork";
pub const all_id_set_key = "fork-id-set";
pub const user_id_to_fork_id_set_key = "user-id->fork-id-set";
pub const repo_user_to_draft_id_set_key = "repo+user->draft-id-set";
pub const DraftKey = [evt.event_id_size * 2]u8;

pub fn draftKey(repo_id: []const u8, user_id: []const u8) DraftKey {
    var key: DraftKey = undefined;
    @memcpy(key[0..evt.event_id_size], repo_id);
    @memcpy(key[evt.event_id_size..], user_id);
    return key;
}

fn validate(record: Record) !void {
    if (record.event.user_id.len != evt.event_id_size) return error.InvalidUserId;
    if (record.event.repo_id.len != evt.event_id_size) return error.InvalidRepoId;
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
    const fork_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const user_forks = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, user_id_to_fork_id_set_key)));
    const drafts = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, repo_user_to_draft_id_set_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(fork_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!record.removed) try validate(record);

    if (existing_maybe) |existing| {
        if (!std.mem.eql(u8, existing.event.user_id, record.event.user_id) or
            !std.mem.eql(u8, existing.event.repo_id, record.event.repo_id)) return error.ForkChanged;
        if (existing.event.stage == .publish and record.event.stage != .publish) return error.ForkAlreadyPublished;
        record.created_order = existing.created_order;
        if (!existing.removed) {
            const order_key = evt.orderKeyDesc(existing.created_order, event_id);
            try removeFromParentSet(DB, hash_kind, user_forks, existing.event.user_id, &order_key);
            if (existing.event.stage == .draft) {
                const key = draftKey(existing.event.repo_id, existing.event.user_id);
                try removeFromParentSet(DB, hash_kind, drafts, &key, &order_key);
            }
        }
    }

    const fork_cursor = try records.putCursor(fork_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(fork_cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .fork, existing_maybe, record);

    const order_key = evt.orderKeyDesc(record.created_order, event_id);
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&order_key);
    }

    if (!record.removed) {
        const by_user = try DB.SortedSet(.read_write).init(try user_forks.putCursor(hash.hashInt(hash_kind, record.event.user_id)));
        try by_user.put(&order_key);
        if (record.event.stage == .draft) {
            const key = draftKey(record.event.repo_id, record.event.user_id);
            const by_repo_user = try DB.SortedSet(.read_write).init(try drafts.putCursor(hash.hashInt(hash_kind, &key)));
            try by_repo_user.put(&order_key);
        }
    }
}

fn removeFromParentSet(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    index: DB.HashMap(.read_write),
    parent_id: []const u8,
    order_key: *const [@sizeOf(u64) + evt.event_id_size]u8,
) !void {
    const cursor = try index.putCursor(hash.hashInt(hash_kind, parent_id));
    const ids = try DB.SortedSet(.read_write).init(cursor);
    _ = try ids.remove(order_key);
}

pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    fork_id: []const u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const fork_cursor = try records.getCursor(hash.hashInt(hash_kind, fork_id)) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(fork_cursor));
}

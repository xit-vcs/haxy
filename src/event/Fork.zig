const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
repo_id: []const u8,
target: []const u8,
source_oid: ?[]const u8 = null,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
};

const Self = @This();

pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->fork";
pub const id_set_key = "fork-id-set";
pub const user_id_to_fork_id_set_key = "user-id->fork-id-set";
pub const repo_id_to_fork_id_set_key = "repo-id->fork-id-set";

fn validate(record: Record) !void {
    if (record.event.user_id.len != evt.event_id_size) return error.InvalidUserId;
    if (record.event.repo_id.len != evt.event_id_size) return error.InvalidRepoId;
    if (!xit.ref.validateName(record.event.target)) return error.InvalidTarget;
    if (record.event.source_oid) |oid| {
        if (oid.len == 0 or oid.len % 2 != 0) return error.InvalidSourceOid;
        for (oid) |c| {
            if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidSourceOid;
        }
    }
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
    const repo_forks = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, repo_id_to_fork_id_set_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(fork_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = if (record_maybe) |value|
        value
    else blk: {
        var existing = existing_maybe orelse return error.EventNotFound;
        existing.removed = true;
        break :blk existing;
    };

    if (!record.removed) try validate(record);

    if (existing_maybe) |existing| {
        record.created_order = existing.created_order;
        if (!existing.removed) {
            const order_key = evt.orderKeyDesc(existing.created_order, event_id);
            try removeFromParentSet(DB, hash_kind, user_forks, existing.event.user_id, &order_key);
            try removeFromParentSet(DB, hash_kind, repo_forks, existing.event.repo_id, &order_key);
        }
    }

    const fork_cursor = try records.putCursor(fork_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(fork_cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .fork, record.created_order, record.removed);

    const order_key = evt.orderKeyDesc(record.created_order, event_id);
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key)));
        try ids.put(&order_key);
    }

    if (!record.removed) {
        const by_user = try DB.SortedSet(.read_write).init(try user_forks.putCursor(hash.hashInt(hash_kind, record.event.user_id)));
        try by_user.put(&order_key);
        const by_repo = try DB.SortedSet(.read_write).init(try repo_forks.putCursor(hash.hashInt(hash_kind, record.event.repo_id)));
        try by_repo.put(&order_key);
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

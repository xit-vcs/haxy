const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
name: []const u8,
description: []const u8,
read_access: Access = .private,
write_access: Access = .private,
read_user_ids: []const u8 = "",
write_user_ids: []const u8 = "",

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
    updated_order: u64 = 0,

    // a repo's key in the name index. it's unique per owner, so the read side
    // resolves the url's username to its user id first.
    pub fn indexKey(self: Record, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.event.user_id, self.event.name });
    }
};

const Self = @This();

pub const Access = enum {
    private,
    public,
};

pub const name_max_len = 32;

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->repo";
pub const all_id_set_key = "repo-id-set";
pub const active_id_set_key = "active-repo-id-set";
pub const name_index_key = "name->repo-id";

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.NameEmpty;
    if (name.len > name_max_len) return error.NameTooLong;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
            return error.InvalidName;
    }
}

fn validateUserIds(user_ids: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, user_ids, '\n');
    while (lines.next()) |id| _ = try evt.parseEventId(id);
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
    const repo_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_repo_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->repo"));
    const event_id_to_repo = try DB.HashMap(.read_write).init(event_id_to_repo_cursor);

    const name_to_repo_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "name->repo-id"));
    const name_to_repo_id = try DB.HashMap(.read_write).init(name_to_repo_id_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_repo.getCursor(repo_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_repo = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_repo);
    }

    var record_to_write = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_record_maybe);

    if (!record_to_write.removed) {
        try validateName(record_to_write.event.name);
        try validateUserIds(record_to_write.event.read_user_ids);
        try validateUserIds(record_to_write.event.write_user_ids);
    }

    const user_id_to_repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"));
    const user_id_to_repo_id_set = try DB.HashMap(.read_write).init(user_id_to_repo_id_set_cursor);

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation metadata
        record_to_write.created_order = existing_record.created_order;
        const order_key = evt.orderKeyDesc(existing_record.created_order, event_id);

        // drop the old active indexes; active values are re-added below
        if (!existing_record.removed) {
            const existing_path = try existing_record.indexKey(arena.allocator());
            _ = try name_to_repo_id.remove(hash.hashInt(hash_kind, existing_path));

            const old_user_repos_cursor = try user_id_to_repo_id_set.putCursor(hash.hashInt(hash_kind, existing_record.event.user_id));
            const old_user_repos = try DB.SortedSet(.read_write).init(old_user_repos_cursor);
            _ = try old_user_repos.remove(&order_key);
        }
    }

    const repo_cursor = try event_id_to_repo.putCursor(repo_key);
    const repo = try DB.HashMap(.read_write).init(repo_cursor);
    try evt.upsert(Record, DB, hash_kind, repo, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .repo, existing_record_maybe, record_to_write);

    const order_key = evt.orderKeyDesc(record_to_write.created_order, event_id);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key));
        const repo_id_set = try DB.SortedSet(.read_write).init(repo_id_set_cursor);
        try repo_id_set.put(&order_key);
    }

    const active = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, active_id_set_key)));
    if (record_to_write.removed) {
        _ = try active.remove(&order_key);
    } else {
        try active.put(&order_key);
        const repo_path = try record_to_write.indexKey(arena.allocator());
        try name_to_repo_id.put(hash.hashInt(hash_kind, repo_path), .{ .bytes = event_id });

        // each user's repos are ordered by creation time, newest first
        const user_repos_cursor = try user_id_to_repo_id_set.putCursor(hash.hashInt(hash_kind, record_to_write.event.user_id));
        const user_repos = try DB.SortedSet(.read_write).init(user_repos_cursor);
        try user_repos.put(&order_key);
    }
}

// a repo plus its event id (the id is the on-disk repo directory name, so the
// caller can locate the working repo under <server>/repos/<hex event id>).
pub const RepoWithId = struct {
    repo: Record,
    event_id: [evt.event_id_size]u8,
};

// read a repo by its owner's name and repo name. the owner name is resolved to
// a user id via name->user-id (the repo index is keyed by "user-id/repo-name"),
// matching the /repo/username/reponame url.
pub fn readByOwnerAndName(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    owner_name: []const u8,
    repo_name: []const u8,
) !?RepoWithId {
    // owner name -> user id
    const name_to_user_id_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "name->user-id")) orelse return null;
    const name_to_user_id = try DB.HashMap(.read_only).init(name_to_user_id_cursor);
    const user_id_cursor = try name_to_user_id.getCursor(hash.hashInt(hash_kind, owner_name)) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);

    // "user-id/repo-name" -> repo event id
    const repo_path = try (Record{ .event = .{ .user_id = user_id[0..], .name = repo_name, .description = "" } }).indexKey(arena.allocator());
    const name_to_repo_id_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "name->repo-id")) orelse return null;
    const name_to_repo_id = try DB.HashMap(.read_only).init(name_to_repo_id_cursor);
    const repo_id_cursor = try name_to_repo_id.getCursor(hash.hashInt(hash_kind, repo_path)) orelse return null;
    var repo_id: [evt.event_id_size]u8 = undefined;
    _ = try repo_id_cursor.readBytes(&repo_id);

    const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->repo")) orelse return null;
    const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);
    const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(hash_kind, &repo_id)) orelse return null;
    const repo_map = try DB.HashMap(.read_only).init(repo_cursor);
    return .{ .repo = try evt.read(Record, DB, hash_kind, arena, repo_map), .event_id = repo_id };
}

pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: []const u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
}

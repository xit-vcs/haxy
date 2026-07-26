const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
name: []const u8,
description: []const u8,
created_ts: u64 = 0, // the commit timestamp of the event that first created this repo

const Self = @This();

pub const name_max_len = 32;

// the moment keys `evt.merge` reads and writes for this kind
pub const record_map_key = "event-id->repo";
pub const id_set_key = "repo-id-set";
pub const name_index_key = "name->repo-id";
pub const conflicts_key = "conflicted-repo-id->conflict";
pub const id_to_field_to_oid_key = "repo-id->field->oid";

// a repo's key in the name index. it's unique per owner, so the read side
// resolves the url's username to its user id first.
pub fn indexKey(self: Self, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.user_id, self.name });
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.NameEmpty;
    if (name.len > name_max_len) return error.NameTooLong;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
            return error.InvalidName;
    }
}

// `created_ts` comes from the commit timestamp, not the event
// payload, so it must not appear in the JSON we output
pub fn jsonStringify(self: @This(), jw: anytype) !void {
    try jw.beginObject();
    inline for (std.meta.fields(@This())) |field| {
        if (comptime std.mem.eql(u8, field.name, "created_ts")) continue;
        try jw.objectField(field.name);
        try jw.write(@field(self, field.name));
    }
    try jw.endObject();
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
    arena: *std.heap.ArenaAllocator,
    created_ts: u64,
    // the commit this event came from, recorded against every field it
    // changes. null from `merge`, which sets oids and conflicts itself.
    event_oid: ?[]const u8,
) !void {
    const repo_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_repo_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->repo"));
    const event_id_to_repo = try DB.HashMap(.read_write).init(event_id_to_repo_cursor);

    const name_to_repo_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "name->repo-id"));
    const name_to_repo_id = try DB.HashMap(.read_write).init(name_to_repo_id_cursor);

    const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key));
    const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);

    const repo_id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key));
    const repo_id_to_field_to_oid = try DB.HashMap(.read_write).init(repo_id_to_field_to_oid_cursor);

    if (event_maybe) |event| {
        try validateName(event.name);

        var event_to_write = event;

        const repo_path = try event.indexKey(arena.allocator());

        const user_id_to_repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"));
        const user_id_to_repo_id_set = try DB.HashMap(.read_write).init(user_id_to_repo_id_set_cursor);

        // if this event_id already maps to a repo under a different key (its
        // name or owner changed), drop the stale index entries first
        var existing_event_maybe: ?@This() = null;
        const existing_cursor_maybe = try event_id_to_repo.getCursor(repo_key);
        if (existing_cursor_maybe) |existing_cursor| {
            const existing_repo = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_repo);
            existing_event_maybe = existing_event;
            // updates preserve the original creation timestamp
            event_to_write.created_ts = existing_event.created_ts;

            // any event settles the conflict, since resolving in the ui may
            // keep our own values and so change nothing to detect
            if (event_oid != null) {
                _ = try conflicts.remove(&evt.orderKeyDesc(existing_event.created_ts, event_id));
            }
            const existing_path = try existing_event.indexKey(arena.allocator());
            if (!std.mem.eql(u8, existing_path, repo_path)) {
                _ = try name_to_repo_id.remove(hash.hashInt(hash_kind, existing_path));
            }
            if (!std.mem.eql(u8, existing_event.user_id, event.user_id)) {
                const old_user_repos_cursor = try user_id_to_repo_id_set.putCursor(hash.hashInt(hash_kind, existing_event.user_id));
                const old_user_repos = try DB.SortedSet(.read_write).init(old_user_repos_cursor);
                const order_key = evt.orderKeyDesc(existing_event.created_ts, event_id);
                _ = try old_user_repos.remove(&order_key);
            }
        } else {
            // first time we've seen this repo: stamp it with the commit timestamp
            event_to_write.created_ts = created_ts;
        }

        try evt.writeOid(@This(), DB, hash_kind, repo_id_to_field_to_oid, repo_key, existing_event_maybe, event, event_oid);

        const repo_cursor = try event_id_to_repo.putCursor(repo_key);
        const repo = try DB.HashMap(.read_write).init(repo_cursor);
        try evt.upsert(@This(), DB, hash_kind, repo, event_to_write);

        try name_to_repo_id.put(hash.hashInt(hash_kind, repo_path), .{ .bytes = event_id });

        // first time we've seen this repo: add it to the ordered set the repos
        // view paginates through. the key embeds the event id, so the set needs
        // no value.
        if (existing_cursor_maybe == null) {
            const repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "repo-id-set"));
            const repo_id_set = try DB.SortedSet(.read_write).init(repo_id_set_cursor);
            const order_key = evt.orderKeyDesc(event_to_write.created_ts, event_id);
            try repo_id_set.put(&order_key);
        }

        // each user's repos are a set ordered by creation time (newest first), so
        // the user page paginates them the same way the home repos list does.
        const user_repos_cursor = try user_id_to_repo_id_set.putCursor(hash.hashInt(hash_kind, event.user_id));
        const user_repos = try DB.SortedSet(.read_write).init(user_repos_cursor);
        const user_repo_order_key = evt.orderKeyDesc(event_to_write.created_ts, event_id);
        try user_repos.put(&user_repo_order_key);
    } else {
        if (try event_id_to_repo.getCursor(repo_key)) |existing_repo_cursor| {
            const existing_repo = try DB.HashMap(.read_only).init(existing_repo_cursor);
            const existing_repo_event = try evt.read(@This(), DB, hash_kind, arena, existing_repo);

            const existing_path = try existing_repo_event.indexKey(arena.allocator());
            _ = try name_to_repo_id.remove(hash.hashInt(hash_kind, existing_path));

            // drop it from the ordered set using its recorded creation timestamp
            const repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "repo-id-set"));
            const repo_id_set = try DB.SortedSet(.read_write).init(repo_id_set_cursor);
            const order_key = evt.orderKeyDesc(existing_repo_event.created_ts, event_id);
            _ = try repo_id_set.remove(&order_key);

            const user_id_to_repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"));
            const user_id_to_repo_id_set = try DB.HashMap(.read_write).init(user_id_to_repo_id_set_cursor);

            const user_key = hash.hashInt(hash_kind, existing_repo_event.user_id);
            const user_repos_cursor = try user_id_to_repo_id_set.putCursor(user_key);
            const user_repos = try DB.SortedSet(.read_write).init(user_repos_cursor);
            _ = try user_repos.remove(&order_key);

            _ = try conflicts.remove(&order_key);
            _ = try repo_id_to_field_to_oid.remove(repo_key);
        }
        if (!try event_id_to_repo.remove(repo_key)) return error.EventNotFound;
    }
}

// a repo plus its event id (the id is the on-disk repo directory name, so the
// caller can locate the working repo under <server>/repos/<hex event id>).
pub const RepoWithId = struct {
    repo: Self,
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
    const repo_path = try (Self{ .user_id = user_id[0..], .name = repo_name, .description = "" }).indexKey(arena.allocator());
    const name_to_repo_id_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "name->repo-id")) orelse return null;
    const name_to_repo_id = try DB.HashMap(.read_only).init(name_to_repo_id_cursor);
    const repo_id_cursor = try name_to_repo_id.getCursor(hash.hashInt(hash_kind, repo_path)) orelse return null;
    var repo_id: [evt.event_id_size]u8 = undefined;
    _ = try repo_id_cursor.readBytes(&repo_id);

    const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->repo")) orelse return null;
    const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);
    const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(hash_kind, &repo_id)) orelse return null;
    const repo_map = try DB.HashMap(.read_only).init(repo_cursor);
    return .{ .repo = try evt.read(@This(), DB, hash_kind, arena, repo_map), .event_id = repo_id };
}

const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

user_id: []const u8,
name: []const u8,
enable_issue: bool,

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
    arena: *std.heap.ArenaAllocator,
) !void {
    const repo_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_repo_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->repo"));
    const event_id_to_repo = try DB.HashMap(.read_write).init(event_id_to_repo_cursor);

    if (event_maybe) |event| {
        const repo_cursor = try event_id_to_repo.putCursor(repo_key);
        const repo = try DB.HashMap(.read_write).init(repo_cursor);
        try evt.upsert(@This(), DB, hash_kind, repo, event);

        const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repos"));
        const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);

        const user_repos_cursor = try user_id_to_repos.putCursor(hash.hashInt(hash_kind, event.user_id));
        const user_repos = try DB.CountedHashSet(.read_write).init(user_repos_cursor);
        try user_repos.put(repo_key, .{ .bytes = event_id });
    } else {
        if (try event_id_to_repo.getCursor(repo_key)) |existing_repo_cursor| {
            const existing_repo = try DB.HashMap(.read_only).init(existing_repo_cursor);
            const existing_repo_event = try evt.read(@This(), DB, hash_kind, arena, existing_repo);

            const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repos"));
            const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);

            const user_key = hash.hashInt(hash_kind, existing_repo_event.user_id);
            const user_repos_cursor = try user_id_to_repos.putCursor(user_key);
            const user_repos = try DB.CountedHashSet(.read_write).init(user_repos_cursor);
            _ = try user_repos.remove(repo_key);
        }
        if (!try event_id_to_repo.remove(repo_key)) return error.EventNotFound;
    }
}

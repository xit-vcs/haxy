const std = @import("std");
const evt = @import("./event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

pub const Page = union(enum) {
    user_repo: UserRepoPage,
};

pub const UserRepoPage = struct {
    users: []UserWithRepos,

    pub const UserWithRepos = struct {
        user: evt.User,
        repos: []const evt.Repo,
    };

    pub fn empty() UserRepoPage {
        return .{
            .users = &.{},
        };
    }

    pub fn init(
        comptime repo_opts: rp.RepoOpts(.xit),
        arena: *std.heap.ArenaAllocator,
        repo: *rp.Repo(.xit, repo_opts),
    ) !UserRepoPage {
        const DB = rp.Repo(.xit, repo_opts).DB;

        const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try DB.HashMap(.read_only).init(haxy_moment_cursor);

        // collect users, keyed by hash(user_event_id) so we can match repos to them
        var hash_to_index: std.AutoArrayHashMapUnmanaged(hash.HashInt(repo_opts.hash), usize) = .empty;

        var user_events: std.ArrayList(evt.User) = .empty;

        var repos_lists: std.ArrayList(std.ArrayList(evt.Repo)) = .empty;

        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

        var users_iter = try event_id_to_user.iterator();
        while (try users_iter.next()) |kv_cursor| {
            const kv = try kv_cursor.readKeyValuePair();
            const user_map = try DB.HashMap(.read_only).init(kv.value_cursor);
            const user_event = try evt.read(evt.User, DB, repo_opts.hash, arena, user_map);

            try hash_to_index.put(arena.allocator(), kv.hash, user_events.items.len);
            try user_events.append(arena.allocator(), user_event);
            try repos_lists.append(arena.allocator(), .empty);
        }

        // collect repos, bucketed by their user_id
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        var repos_iter = try event_id_to_repo.iterator();
        while (try repos_iter.next()) |kv_cursor| {
            const kv = try kv_cursor.readKeyValuePair();
            const repo_map = try DB.HashMap(.read_only).init(kv.value_cursor);
            const repo_event = try evt.read(evt.Repo, DB, repo_opts.hash, arena, repo_map);

            const user_hash = hash.hashInt(repo_opts.hash, repo_event.user_id);
            if (hash_to_index.get(user_hash)) |user_index| {
                try repos_lists.items[user_index].append(arena.allocator(), repo_event);
            }
        }

        var user_repos: std.ArrayList(UserWithRepos) = .empty;

        for (user_events.items, repos_lists.items) |user_event, *repos| {
            try user_repos.append(arena.allocator(), .{
                .user = user_event,
                .repos = repos.items,
            });
        }

        return .{
            .users = user_repos.items,
        };
    }
};

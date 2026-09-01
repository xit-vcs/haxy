const std = @import("std");
const evt = @import("../../event.zig");
const fork = @import("../../fork.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

const fork_repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
const author = evt.CommitAuthor{ .name = "haxy", .email = "user@haxy" };

test "user and repo" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-event-user-and-repo";

    // create the temp dir
    const cwd = std.Io.Dir.cwd();
    var temp_dir_or_err = cwd.openDir(io, temp_dir_name, .{});
    if (temp_dir_or_err) |*temp_dir| {
        temp_dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const work_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(work_path);

    const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
    const Repo = rp.Repo(.xit, repo_opts);
    var repo = try Repo.init(io, allocator, .{ .path = work_path });
    defer repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    //
    // define test events
    //

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_event_id = evt.EventWithId.randomId(prng.random());
    const repo_event_id = evt.EventWithId.randomId(prng.random());

    var first_password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
    const first_password_hash = try evt.User.hashPassword("correct horse battery staple", &first_password_hash_buf, io);

    var second_password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
    const second_password_hash = try evt.User.hashPassword("Tr0ub4dor&3", &second_password_hash_buf, io);

    const events_to_consume = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(user_event_id, .lower),
            .author = author,
            .event = .{
                .user = .{
                    .name = "alice",
                    .email = "alice@example.test",
                    .password_hash = first_password_hash,
                },
            },
        },
        // this event edits the previous one because it has the same id
        .{
            .id = std.fmt.bytesToHex(user_event_id, .lower),
            .author = author,
            .event = .{
                .user = .{
                    .name = "alice",
                    .email = "alice@example.test",
                    .password_hash = second_password_hash,
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(repo_event_id, .lower),
            .author = author,
            .event = .{
                .repo = .{
                    .user_id = &user_event_id,
                    .name = "ziglings",
                    .description = "Learn the Zig programming language by fixing tiny broken programs",
                },
            },
        },
    };

    // commit and consume the seed events
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of users
        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try Repo.DB.HashMap(.read_only).init(event_id_to_user_cursor);

        // get the user out of the map that was edited
        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_map = try Repo.DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User.Record, Repo.DB, repo_opts.hash, &arena, user_map);

        // the password was correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].event.user.?.password_hash, user_event.event.password_hash);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        // get the repo out of the map
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_event = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);

        try std.testing.expectEqualSlices(u8, &user_event_id, repo_event.event.user_id);
        try std.testing.expectEqualStrings("ziglings", repo_event.event.name);

        // get the repos created by the user
        const user_id_to_repo_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id->repo-id-set")) orelse return error.NotFound;
        const user_id_to_repo_id_set = try Repo.DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);

        const user_repos_cursor = try user_id_to_repo_id_set.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_repos = try Repo.DB.SortedSet(.read_only).init(user_repos_cursor);

        try std.testing.expectEqual(1, try user_repos.count());

        // the set is keyed by orderKeyDesc([created-order][event-id])
        const order_key = evt.orderKeyDesc(repo_event.created_order, &repo_event_id);
        try std.testing.expect(try user_repos.contains(&order_key));
    }

    //
    // remove the repo
    //

    const events_to_consume2 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(repo_event_id, .lower),
            .author = author,
            .event = .{ .repo = null },
        },
    };

    // commit and consume the removal
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume2);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_event = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);
        try std.testing.expect(repo_event.removed);

        // get the repos created by the user
        const user_id_to_repo_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id->repo-id-set")) orelse return error.NotFound;
        const user_id_to_repo_id_set = try Repo.DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);

        const user_repos_cursor = try user_id_to_repo_id_set.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_repos = try Repo.DB.SortedSet(.read_only).init(user_repos_cursor);

        // removing the repo emptied the user's set
        try std.testing.expectEqual(0, try user_repos.count());
    }

    // a non-null payload restores the repo and its indexes
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(repo_event_id, .lower),
        .author = author,
        .event = events_to_consume[2].event,
    }});

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_event = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);
        try std.testing.expect(!repo_event.removed);

        const user_id_to_repo_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id->repo-id-set")) orelse return error.NotFound;
        const user_id_to_repo_id_set = try Repo.DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);
        const user_repos_cursor = try user_id_to_repo_id_set.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_repos = try Repo.DB.SortedSet(.read_only).init(user_repos_cursor);
        try std.testing.expectEqual(1, try user_repos.count());
    }

    //
    // remove the user
    //

    const events_to_consume3 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(user_event_id, .lower),
            .author = author,
            .event = .{ .user = null },
        },
    };

    // commit and consume the removal
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume3);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of users
        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try Repo.DB.HashMap(.read_only).init(event_id_to_user_cursor);

        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_map = try Repo.DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User.Record, Repo.DB, repo_opts.hash, &arena, user_map);
        try std.testing.expect(user_event.removed);

        // removing the user removes their active repos too
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_event = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);
        try std.testing.expect(repo_event.removed);
    }
}

test "repos and users paginate newest first" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-event-order";

    const cwd = std.Io.Dir.cwd();
    var temp_dir_or_err = cwd.openDir(io, temp_dir_name, .{});
    if (temp_dir_or_err) |*temp_dir| {
        temp_dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const work_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(work_path);

    const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
    const Repo = rp.Repo(.xit, repo_opts);
    var repo = try Repo.init(io, allocator, .{ .path = work_path });
    defer repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_id = evt.EventWithId.randomId(prng.random());
    var repo_ids: [4][evt.event_id_size]u8 = undefined;
    for (&repo_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

    var pw_buf: [evt.User.password_hash_max_len]u8 = undefined;
    const pw = try evt.User.hashPassword("pw", &pw_buf, io);

    // asserts the repo-id-set holds exactly `expected` ids in that order
    const Check = struct {
        fn order(
            comptime DB: type,
            comptime hash_kind: hash.HashKind,
            moment: DB.HashMap(.read_only),
            expected: []const *const [evt.event_id_size]u8,
        ) !void {
            const cursor = try moment.getCursor(hash.hashInt(hash_kind, "repo-id-set")) orelse return error.NotFound;
            const set = try DB.SortedSet(.read_only).init(cursor);
            try std.testing.expectEqual(expected.len, try set.count());
            for (expected, 0..) |id, i| {
                const kv = (try set.getIndexKeyValuePair(@intCast(i))) orelse return error.NotFound;
                // the key is orderKeyDesc ([created-order][event-id]); its trailing bytes are the id
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try kv.key_cursor.readBytes(&order_key);
                try std.testing.expectEqualSlices(u8, id, order_key[@sizeOf(u64)..]);
            }
        }
    };

    // one user, then four repos in creation order with deliberately skewed
    // timestamps
    const events = [_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(user_id, .lower), .author = author, .timestamp = 100, .event = .{ .user = .{ .name = "alice", .email = "alice@example.test", .password_hash = pw } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .author = author, .timestamp = 10_000, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo0", .description = "d0" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .author = author, .timestamp = 10, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo1", .description = "d1" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[2], .lower), .author = author, .timestamp = 5_000, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo2", .description = "d2" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[3], .lower), .author = author, .timestamp = 20, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo3", .description = "d3" } } },
    };
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events);

    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[3], &repo_ids[2], &repo_ids[1], &repo_ids[0] });

        // the single user shows up in its own ordered set
        const ucur = try moment.getCursor(hash.hashInt(repo_opts.hash, "user-id-set")) orelse return error.NotFound;
        const uset = try Repo.DB.SortedSet(.read_only).init(ucur);
        try std.testing.expectEqual(1, try uset.count());
    }

    // removing repo1 retains its place in the canonical order
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .author = author, .timestamp = 200, .event = .{ .repo = null } },
    });
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[3], &repo_ids[2], &repo_ids[1], &repo_ids[0] });
    }

    // update repo0 at a later timestamp -> keeps its original place
    try evt.consume(.admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .author = author, .timestamp = 300, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo0", .description = "updated" } } },
    });
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[3], &repo_ids[2], &repo_ids[1], &repo_ids[0] });

        // the value really was updated
        const e2r_cur = try moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const e2r = try Repo.DB.HashMap(.read_only).init(e2r_cur);
        const rc = try e2r.getCursor(hash.hashInt(repo_opts.hash, &repo_ids[0])) orelse return error.NotFound;
        const rm = try Repo.DB.HashMap(.read_only).init(rc);
        const re = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, rm);
        try std.testing.expectEqualStrings("updated", re.event.description);
    }
}

test "fork query and removal lifecycle" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-fork-event";
    const cwd = std.Io.Dir.cwd();

    if (cwd.openDir(io, temp_dir_name, .{})) |dir_value| {
        var dir = dir_value;
        dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const root = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(root);
    const repos_dir = try std.fs.path.join(allocator, &.{ root, "repos" });
    defer allocator.free(repos_dir);
    const admin_path = try std.fs.path.join(allocator, &.{ root, "admin" });
    defer allocator.free(admin_path);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_id = evt.EventWithId.randomId(prng.random());
    const repo_id = evt.EventWithId.randomId(prng.random());
    const repo_id_hex = std.fmt.bytesToHex(repo_id, .lower);
    const fork_id = evt.EventWithId.randomId(prng.random());
    const fork_id_hex = std.fmt.bytesToHex(fork_id, .lower);

    var admin = try rp.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);
    try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &.{
        .{
            .id = std.fmt.bytesToHex(user_id, .lower),
            .timestamp = 1,
            .author = author,
            .event = .{ .user = .{
                .name = author.name,
                .email = author.email,
                .password_hash = "",
            } },
        },
        .{
            .id = std.fmt.bytesToHex(repo_id, .lower),
            .timestamp = 1,
            .author = author,
            .event = .{ .repo = .{
                .user_id = &user_id,
                .name = "repo",
                .description = "",
            } },
        },
    });

    const target_path = try std.fs.path.join(allocator, &.{ repos_dir, &repo_id_hex });
    defer allocator.free(target_path);
    var target = try rp.Repo(.xit, fork_repo_opts).init(io, allocator, .{ .path = target_path });
    defer target.deinit(io, allocator);
    {
        const file = try target.core.work_dir.createFile(io, "README", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "repo\n");
    }
    try target.add(io, allocator, &.{"README"});
    _ = try target.commit(io, allocator, .{ .message = "initial" });

    const draft_path = try fork.create(fork_repo_opts, io, allocator, repos_dir, &admin, .{
        .target_branch = "master",
        .id = fork_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = "add a feature",
        .description = "a draft patch",
        .tags = "enhancement",
        .author = author,
        .timestamp = 2,
    });
    defer allocator.free(draft_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    var record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expectEqualSlices(u8, &user_id, record.event.user_id);
    try std.testing.expectEqualSlices(u8, &repo_id, record.event.repo_id);
    try std.testing.expectEqual(.draft, record.event.stage);
    try std.testing.expectEqual(1, try indexedForkCount(moment, evt.Fork.user_id_to_fork_id_set_key, &user_id));
    const draft_key = evt.Fork.draftKey(&repo_id, &user_id);
    try std.testing.expectEqual(1, try indexedForkCount(moment, evt.Fork.repo_user_to_draft_id_set_key, &draft_key));

    var draft_repo = try rp.Repo(.xit, fork_repo_opts).open(io, allocator, .{ .path = draft_path });
    defer draft_repo.deinit(io, allocator);
    const draft_moment = try evt.currentMoment(fork_repo_opts, &draft_repo);
    const draft = (try evt.Patch.readById(evt.EventDB(fork_repo_opts.hash), fork_repo_opts.hash, draft_moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("add a feature", draft.event.title);
    try std.testing.expectEqual(null, draft.event.revision);

    var wrong_user_id = user_id;
    wrong_user_id[0] ^= 1;
    try std.testing.expectError(error.InvalidPatchDraft, fork.remove(io, allocator, repos_dir, &admin, &fork_id_hex, &wrong_user_id, author));
    try std.Io.Dir.accessAbsolute(io, draft_path, .{});

    try fork.remove(io, allocator, repos_dir, &admin, &fork_id_hex, &user_id, author);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, draft_path, .{}));
    _ = arena.reset(.retain_capacity);
    moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expect(record.removed);
    try std.testing.expectEqual(0, try indexedForkCount(moment, evt.Fork.user_id_to_fork_id_set_key, &user_id));
    try std.testing.expectEqual(0, try indexedForkCount(moment, evt.Fork.repo_user_to_draft_id_set_key, &draft_key));

    try fork.remove(io, allocator, repos_dir, &admin, &fork_id_hex, &user_id, author);
}

fn indexedForkCount(
    moment: evt.AdminDB.HashMap(.read_only),
    index_key: []const u8,
    parent_id: []const u8,
) !u64 {
    const index_cursor = try moment.getCursor(hash.hashInt(evt.admin_repo_opts.hash, index_key)) orelse return 0;
    const index = try evt.AdminDB.HashMap(.read_only).init(index_cursor);
    const ids_cursor = try index.getCursor(hash.hashInt(evt.admin_repo_opts.hash, parent_id)) orelse return 0;
    const ids = try evt.AdminDB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

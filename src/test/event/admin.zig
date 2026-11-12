const std = @import("std");
const evt = @import("../../event.zig");
const fork = @import("../../fork.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

const fork_repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
const author = evt.CommitAuthor{ .name = "haxyuser", .email = "user@haxy" };

test "user and repo" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // create the temp dir
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);

    const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
    const Repo = rp.Repo(.xit, repo_opts);
    const admin_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "admin" });
    defer allocator.free(admin_path);
    var repo = try Repo.init(io, allocator, .{ .path = admin_path });
    defer repo.deinit(io, allocator);
    const user_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "user" });
    defer allocator.free(user_path);
    var user_repo = try Repo.init(io, allocator, .{ .path = user_path });
    defer user_repo.deinit(io, allocator);

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
    };
    const repo_event = evt.EventWithId{
        .id = std.fmt.bytesToHex(repo_event_id, .lower),
        .author = author,
        .event = .{
            .repo = .{
                .user_id = std.fmt.bytesToHex(user_event_id, .lower),
                .name = "ziglings",
                .description = "Learn the Zig programming language by fixing tiny broken programs",
            },
        },
    };

    // commit and consume the seed events. users go in the admin repo, repos in
    // their owner's user repo.
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume);
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &user_repo, evt.events_ref, &.{repo_event});

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
    }

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &user_repo);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        // get the repo out of the map
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_record = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);

        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(user_event_id, .lower), &repo_record.event.user_id);
        try std.testing.expectEqualStrings("ziglings", repo_record.event.name);

        // the repo resolves by its name alone
        const found = (try evt.Repo.readByName(Repo.DB, repo_opts.hash, haxy_moment, &arena, "ziglings")) orelse return error.NotFound;
        try std.testing.expectEqualSlices(u8, &repo_event_id, &found.event_id);
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
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &user_repo, evt.events_ref, &events_to_consume2);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &user_repo);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_record = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);
        try std.testing.expect(repo_record.removed);

        // removing the repo dropped it from the name index
        try std.testing.expectEqual(null, try evt.Repo.readByName(Repo.DB, repo_opts.hash, haxy_moment, &arena, "ziglings"));
    }

    // a non-null payload restores the repo and its indexes
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &user_repo, evt.events_ref, &.{repo_event});

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &user_repo);
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_record = try evt.read(evt.Repo.Record, Repo.DB, repo_opts.hash, &arena, repo_map);
        try std.testing.expect(!repo_record.removed);

        try std.testing.expect(try evt.Repo.readByName(Repo.DB, repo_opts.hash, haxy_moment, &arena, "ziglings") != null);
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
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .admin, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume3);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of users
        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try Repo.DB.HashMap(.read_only).init(event_id_to_user_cursor);

        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_map = try Repo.DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User.Record, Repo.DB, repo_opts.hash, &arena, user_map);
        try std.testing.expect(user_event.removed);
    }
}

test "repos and users paginate newest first" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);

    const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
    const Repo = rp.Repo(.xit, repo_opts);
    const admin_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "admin" });
    defer allocator.free(admin_path);
    var admin = try Repo.init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);
    const user_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "user" });
    defer allocator.free(user_path);
    var repo = try Repo.init(io, allocator, .{ .path = user_path });
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

    // one user in the admin repo, then four repos in creation order with
    // deliberately skewed timestamps in the user's repo
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .admin, .xit, repo_opts, io, allocator, &admin, evt.events_ref, &.{
        .{ .id = std.fmt.bytesToHex(user_id, .lower), .author = author, .timestamp = 100, .event = .{ .user = .{ .name = "alice", .email = "alice@example.test", .password_hash = pw } } },
    });
    const events = [_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .author = author, .timestamp = 10_000, .event = .{ .repo = .{ .user_id = std.fmt.bytesToHex(user_id, .lower), .name = "repo0", .description = "d0" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .author = author, .timestamp = 10, .event = .{ .repo = .{ .user_id = std.fmt.bytesToHex(user_id, .lower), .name = "repo1", .description = "d1" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[2], .lower), .author = author, .timestamp = 5_000, .event = .{ .repo = .{ .user_id = std.fmt.bytesToHex(user_id, .lower), .name = "repo2", .description = "d2" } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[3], .lower), .author = author, .timestamp = 20, .event = .{ .repo = .{ .user_id = std.fmt.bytesToHex(user_id, .lower), .name = "repo3", .description = "d3" } } },
    };
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &events);

    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[3], &repo_ids[2], &repo_ids[1], &repo_ids[0] });

        // the single user shows up in its own ordered set
        const admin_moment = try evt.currentMoment(repo_opts, &admin);
        const ucur = try admin_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id-set")) orelse return error.NotFound;
        const uset = try Repo.DB.SortedSet(.read_only).init(ucur);
        try std.testing.expectEqual(1, try uset.count());
    }

    // removing repo1 retains its place in the canonical order
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .author = author, .timestamp = 200, .event = .{ .repo = null } },
    });
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[3], &repo_ids[2], &repo_ids[1], &repo_ids[0] });
    }

    // update repo0 at a later timestamp -> keeps its original place
    try evt.consume(.{ .server = .{ .users_path = temp_path } }, .user, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .author = author, .timestamp = 300, .event = .{ .repo = .{ .user_id = std.fmt.bytesToHex(user_id, .lower), .name = "repo0", .description = "updated" } } },
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

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);

    const users_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "users" });
    defer allocator.free(users_path);
    const admin_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "admin" });
    defer allocator.free(admin_path);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_id = evt.EventWithId.randomId(prng.random());
    const repo_id = evt.EventWithId.randomId(prng.random());
    const fork_id = evt.EventWithId.randomId(prng.random());
    const fork_id_hex = std.fmt.bytesToHex(fork_id, .lower);

    var admin = try rp.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);
    try evt.consume(.{ .server = .{ .users_path = users_path } }, .admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &.{
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
    });
    const user_repo_path = try evt.userRepoPath(allocator, users_path, &user_id);
    defer allocator.free(user_repo_path);
    var user_repo = try evt.initUserRepo(io, allocator, user_repo_path);
    defer user_repo.deinit(io, allocator);
    try evt.consume(.{ .server = .{ .users_path = users_path } }, .user, .xit, evt.user_repo_opts, io, allocator, &user_repo, evt.events_ref, &.{
        .{
            .id = std.fmt.bytesToHex(repo_id, .lower),
            .timestamp = 1,
            .author = author,
            .event = .{ .repo = .{
                .user_id = std.fmt.bytesToHex(user_id, .lower),
                .name = "repo",
                .description = "",
            } },
        },
    });

    const target_path = try evt.repoPath(allocator, users_path, &user_id, &repo_id);
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

    const draft_path = try fork.create(.{ .is_test = true }, io, allocator, users_path, .{
        .target_branch = "master",
        .id = fork_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .repo_user_id = user_id,
        .repo_name = "target",
        .title = "add a feature",
        .description = "a draft patch",
        .labels = "enhancement",
        .author = author,
        .timestamp = 2,
    });
    defer allocator.free(draft_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var moment = try evt.currentMoment(evt.user_repo_opts, &user_repo);
    var record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(repo_id, .lower), &record.event.repo_id);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(user_id, .lower), &record.event.repo_user_id);
    try std.testing.expectEqual(.draft, record.event.stage);
    try std.testing.expectEqual(1, try activeForkCount(moment));
    try std.testing.expectEqual(1, try draftForkCount(moment, &repo_id));

    var draft_repo = try rp.Repo(.xit, fork_repo_opts).open(io, allocator, .{ .path = draft_path });
    defer draft_repo.deinit(io, allocator);
    const draft_moment = try evt.currentMoment(fork_repo_opts, &draft_repo);
    const draft = (try evt.Patch.readById(evt.EventDB(fork_repo_opts.hash), fork_repo_opts.hash, draft_moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("add a feature", draft.event.title);
    try std.testing.expectEqual(null, draft.event.revision);

    try fork.remove(io, allocator, users_path, &user_id, &fork_id_hex, author);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, draft_path, .{}));
    _ = arena.reset(.retain_capacity);
    moment = try evt.currentMoment(evt.user_repo_opts, &user_repo);
    record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.NotFound;
    try std.testing.expect(record.removed);
    try std.testing.expectEqual(0, try activeForkCount(moment));
    try std.testing.expectEqual(0, try draftForkCount(moment, &repo_id));

    try fork.remove(io, allocator, users_path, &user_id, &fork_id_hex, author);
}

fn draftForkCount(moment: evt.UserDB.HashMap(.read_only), repo_id: []const u8) !u64 {
    const index_cursor = try moment.getCursor(hash.hashInt(evt.user_repo_opts.hash, evt.Fork.repo_to_draft_id_set_key)) orelse return 0;
    const index = try evt.UserDB.HashMap(.read_only).init(index_cursor);
    const ids_cursor = try index.getCursor(hash.hashInt(evt.user_repo_opts.hash, repo_id)) orelse return 0;
    const ids = try evt.UserDB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

fn activeForkCount(moment: evt.UserDB.HashMap(.read_only)) !u64 {
    const ids_cursor = try moment.getCursor(hash.hashInt(evt.user_repo_opts.hash, evt.Fork.active_id_set_key)) orelse return 0;
    const ids = try evt.UserDB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

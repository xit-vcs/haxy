const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;

test "rebase" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-event-rebase";

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

    const first_event_id = evt.EventWithId.randomId(prng.random());

    const events_to_consume = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(first_event_id, .lower),
            .event = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug priority-high ui",
                },
            },
        },
        // this event edits the previous one because it has the same id
        .{
            .id = std.fmt.bytesToHex(first_event_id, .lower),
            .event = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field and removes typed input. Preserve the field value and show an inline validation message.",
                    .tags = "bug priority-low ui",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Search results ignore archived project filter",
                    .description = "Filtering search results to active projects still returns issues from archived projects. Apply the archived flag before ranking results.",
                    .tags = "bug search backend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Issue list does not persist selected sort order",
                    .description = "Changing the issue list sort order is lost after refresh. Store the selected sort field and direction with the user's view preferences.",
                    .tags = "enhancement frontend preferences",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    var first_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            const oid = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, evt.events_ref);
            if (i == 0) {
                _ = try std.fmt.hexToBytes(&first_oid, &oid);
            }
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map that was edited
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_event_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.read(evt.Issue, Repo.DB, repo_opts.hash, &arena, first_issue_map);

        // the description was correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].event.issue.?.description, first_issue.description);

        // the tags were correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].event.issue.?.tags, first_issue.tags);
    }

    //
    // add another event
    //

    const events_to_consume2 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Double clicking causes the form to submit twice",
                    .description = "When I double click the post button I see duplicate posts.",
                    .tags = "bug priority-high ui",
                },
            },
        },
    };

    // commit and consume the new event
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume2, false);

    //
    // rebase the branch so it no longer includes the edit event
    //

    const events_to_consume3 = [_]evt.EventWithId{
        events_to_consume[2],
        events_to_consume[3],
    };

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume3, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                .{
                    .message = json.written(),
                    // the first event should have the first oid as its parent,
                    // because we want to keep the very first commit.
                    // and the rest will have null which causes them
                    // to have the previous commit as their parent
                    .parent_oids = if (i == 0) &.{std.fmt.bytesToHex(first_oid, .lower)} else null,
                },
                null,
                evt.events_ref,
            );
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map that was edited
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_event_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.read(evt.Issue, Repo.DB, repo_opts.hash, &arena, first_issue_map);

        // the description is no longer edited
        try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.description, first_issue.description);

        // the tags are no longer edited
        try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.tags, first_issue.tags);

        // an event added by the second push is no longer there because it was wiped out by the rebase
        try std.testing.expect(null == try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &events_to_consume2[0].id)));
    }

    //
    // rebase the branch so it no longer includes the original issue
    //

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume3, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                .{
                    .message = json.written(),
                    // the first event should have no parents,
                    // because we want to drop the very first commit.
                    // and the rest will have null which causes them
                    // to have the previous commit as their parent
                    .parent_oids = if (i == 0) &.{} else null,
                },
                null,
                evt.events_ref,
            );
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // the first issue no longer exists
        try std.testing.expect(null == try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_event_id)));
    }
}

test "merge" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-event-merge";

    const other_events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/other" };

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

    const events_to_consume = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug priority-high ui",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Search results ignore archived project filter",
                    .description = "Filtering search results to active projects still returns issues from archived projects. Apply the archived flag before ranking results.",
                    .tags = "bug search backend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Issue list does not persist selected sort order",
                    .description = "Changing the issue list sort order is lost after refresh. Store the selected sort field and direction with the user's view preferences.",
                    .tags = "enhancement frontend preferences",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    var first_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            const oid = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, evt.events_ref);
            if (i == 0) {
                _ = try std.fmt.hexToBytes(&first_oid, &oid);
            }
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map
        var first_issue_id: [evt.event_id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&first_issue_id, &events_to_consume[0].id);
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.read(evt.Issue, Repo.DB, repo_opts.hash, &arena, first_issue_map);

        try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.description, first_issue.description);
        try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.tags, first_issue.tags);
    }

    //
    // define more test events
    //

    const events_to_consume2 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Kanban card status badge falls behind after drag",
                    .description = "Moving an issue between columns updates the card position immediately, but the status badge keeps showing the previous state until refresh.",
                    .tags = "bug kanban frontend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Assignee autocomplete omits recently invited users",
                    .description = "Users invited during the current session do not appear in the assignee picker until the project page is reloaded.",
                    .tags = "bug assignees api",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
            .event = .{
                .issue = .{
                    .title = "Add due date warning for issues blocked by dependencies",
                    .description = "Show a warning when an issue's due date is earlier than an unresolved blocking issue so planners can adjust the schedule.",
                    .tags = "enhancement planning dependencies",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume2, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                // make the first commit a child of the first commit on the events branch
                .{ .parent_oids = if (i == 0) &.{std.fmt.bytesToHex(first_oid, .lower)} else null, .message = json.written() },
                null,
                other_events_ref,
            );
        }
    }

    //
    // check out the events branch and merge the other events branch into it
    //

    const merge_oid = blk: {
        var result = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer result.deinit();

        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_events_ref }} } } }, null);
        defer merge.deinit();

        try std.testing.expect(.success == merge.result);

        break :blk merge.result.success.oid;
    };

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // make sure one of the original issues is still there
        {
            // get the issue out of the map
            var first_issue_id: [evt.event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_issue_id, &events_to_consume[0].id);
            const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id)) orelse return error.NotFound;
            const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
            const first_issue = try evt.read(evt.Issue, Repo.DB, repo_opts.hash, &arena, first_issue_map);

            try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.description, first_issue.description);
            try std.testing.expectEqualStrings(events_to_consume[0].event.issue.?.tags, first_issue.tags);
        }

        // make sure one of the new issues is there
        {
            // get the issue out of the map
            var first_issue_id: [evt.event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_issue_id, &events_to_consume2[0].id);
            const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id)) orelse return error.NotFound;
            const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
            const first_issue = try evt.read(evt.Issue, Repo.DB, repo_opts.hash, &arena, first_issue_map);

            try std.testing.expectEqualStrings(events_to_consume2[0].event.issue.?.description, first_issue.description);
            try std.testing.expectEqualStrings(events_to_consume2[0].event.issue.?.tags, first_issue.tags);
        }

        // the ordered issue set unions both branches' additions
        {
            const status_to_issues_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "status->issue-id-set")) orelse return error.NotFound;
            const status_to_issues = try Repo.DB.SortedMap(.read_only).init(status_to_issues_cursor);
            const issue_id_set_cursor = try status_to_issues.getCursor("open") orelse return error.NotFound;
            const issue_id_set = try Repo.DB.SortedSet(.read_only).init(issue_id_set_cursor);
            try std.testing.expectEqual(6, try issue_id_set.count());

            var found = [_]bool{false} ** 6;
            var iter = try issue_id_set.iteratorFromIndex(0);
            while (try iter.next()) |id_cursor_val| {
                var id_cursor = id_cursor_val;
                const id_kv = try id_cursor.readKeyValuePair();
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try id_kv.key_cursor.readBytes(&order_key);
                const id_hex = std.fmt.bytesToHex(order_key[@sizeOf(u64)..].*, .lower);
                for (events_to_consume, 0..) |event, i| {
                    if (std.mem.eql(u8, &id_hex, &event.id)) found[i] = true;
                }
                for (events_to_consume2, 0..) |event, i| {
                    if (std.mem.eql(u8, &id_hex, &event.id)) found[events_to_consume.len + i] = true;
                }
            }
            for (found) |f| try std.testing.expect(f);
        }
    }

    //
    // insert issues as commits in the repo
    //

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                // make the first event have no parents so we completely rebase the branch,
                // undoing the merge that we did above
                .{ .parent_oids = if (i == 0) &.{} else null, .message = json.written() },
                null,
                evt.events_ref,
            );
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, evt.events_ref);

        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // make sure the new issue is not there
        {
            // get the issue out of the map
            var first_issue_id: [evt.event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_issue_id, &events_to_consume2[0].id);
            const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id));
            try std.testing.expect(null == first_issue_cursor);
        }
    }

    //
    // define test events that modify the same issue in conflicting ways
    //

    const events_to_consume3 = [_]evt.EventWithId{
        .{
            .id = events_to_consume[0].id,
            .event = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug priority-low ui",
                },
            },
        },
        .{
            .id = events_to_consume[0].id,
            .event = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug priority-medium ui",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo on different branches
    //

    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();

        for (events_to_consume3, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                .{ .parent_oids = &.{merge_oid}, .message = json.written() },
                null,
                switch (i) {
                    0 => evt.events_ref,
                    1 => other_events_ref,
                    else => unreachable,
                },
            );
        }
    }

    //
    // check out the events branch and merge the other events branch into it
    //

    {
        var result = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer result.deinit();

        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_events_ref }} } } }, null);
        defer merge.deinit();

        try std.testing.expect(.success == merge.result);
    }

    //
    // consume events into the database
    //

    try std.testing.expectError(error.MergeConflict, evt.consume(repo_opts, io, allocator, &repo, evt.events_ref));
}

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
            .event = .{
                .user = .{
                    .name = "alice",
                    .display_name = "Alice Example",
                    .email = "alice@example.test",
                    .password_hash = first_password_hash,
                },
            },
        },
        // this event edits the previous one because it has the same id
        .{
            .id = std.fmt.bytesToHex(user_event_id, .lower),
            .event = .{
                .user = .{
                    .name = "alice",
                    .display_name = "Alice Example",
                    .email = "alice@example.test",
                    .password_hash = second_password_hash,
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(repo_event_id, .lower),
            .event = .{
                .repo = .{
                    .user_id = &user_event_id,
                    .name = "ziglings",
                    .description = "Learn the Zig programming language by fixing tiny broken programs",
                    .enable_issue = true,
                },
            },
        },
    };

    // commit and consume the seed events
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume, false);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of users
        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try Repo.DB.HashMap(.read_only).init(event_id_to_user_cursor);

        // get the user out of the map that was edited
        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_map = try Repo.DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User, Repo.DB, repo_opts.hash, &arena, user_map);

        // the password was correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].event.user.?.password_hash, user_event.password_hash);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        // get the repo out of the map
        const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)) orelse return error.NotFound;
        const repo_map = try Repo.DB.HashMap(.read_only).init(repo_cursor);
        const repo_event = try evt.read(evt.Repo, Repo.DB, repo_opts.hash, &arena, repo_map);

        try std.testing.expectEqualSlices(u8, &user_event_id, repo_event.user_id);
        try std.testing.expectEqualStrings("ziglings", repo_event.name);

        // get the repos created by the user
        const user_id_to_repo_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id->repo-id-set")) orelse return error.NotFound;
        const user_id_to_repo_id_set = try Repo.DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);

        const user_repos_cursor = try user_id_to_repo_id_set.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_repos = try Repo.DB.SortedSet(.read_only).init(user_repos_cursor);

        try std.testing.expectEqual(1, try user_repos.count());

        // the set is keyed by orderKey([created-ts][event-id])
        const order_key = evt.orderKey(repo_event.created_ts, &repo_event_id);
        try std.testing.expect(try user_repos.contains(&order_key));
    }

    //
    // remove the repo
    //

    const events_to_consume2 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(repo_event_id, .lower),
            .event = .{ .repo = null },
        },
    };

    // commit and consume the removal
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume2, false);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of repos
        const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const event_id_to_repo = try Repo.DB.HashMap(.read_only).init(event_id_to_repo_cursor);

        try std.testing.expect(null == try event_id_to_repo.getCursor(hash.hashInt(repo_opts.hash, &repo_event_id)));

        // get the repos created by the user
        const user_id_to_repo_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "user-id->repo-id-set")) orelse return error.NotFound;
        const user_id_to_repo_id_set = try Repo.DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);

        const user_repos_cursor = try user_id_to_repo_id_set.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)) orelse return error.NotFound;
        const user_repos = try Repo.DB.SortedSet(.read_only).init(user_repos_cursor);

        // removing the repo emptied the user's set
        try std.testing.expectEqual(0, try user_repos.count());
    }

    //
    // remove the user
    //

    const events_to_consume3 = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(user_event_id, .lower),
            .event = .{ .user = null },
        },
    };

    // commit and consume the removal
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume3, false);

    {
        const haxy_moment = try evt.currentMoment(repo_opts, &repo);

        // get the map of users
        const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
        const event_id_to_user = try Repo.DB.HashMap(.read_only).init(event_id_to_user_cursor);

        try std.testing.expect(null == try event_id_to_user.getCursor(hash.hashInt(repo_opts.hash, &user_event_id)));
    }
}

test "repos and users paginate in creation order" {
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
                // the key is orderKey ([timestamp][event-id]); its trailing bytes are the id
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try kv.key_cursor.readBytes(&order_key);
                try std.testing.expectEqualSlices(u8, id, order_key[@sizeOf(u64)..]);
            }
        }
    };

    // one user, then four repos, each with its own creation timestamp (user@100,
    // repos@101..104)
    const events = [_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(user_id, .lower), .timestamp = 100, .event = .{ .user = .{ .name = "alice", .display_name = "Alice", .email = "alice@example.test", .password_hash = pw } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .timestamp = 101, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo0", .description = "d0", .enable_issue = true } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .timestamp = 102, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo1", .description = "d1", .enable_issue = true } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[2], .lower), .timestamp = 103, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo2", .description = "d2", .enable_issue = true } } },
        .{ .id = std.fmt.bytesToHex(repo_ids[3], .lower), .timestamp = 104, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo3", .description = "d3", .enable_issue = true } } },
    };
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &events, false);

    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[0], &repo_ids[1], &repo_ids[2], &repo_ids[3] });

        // the single user shows up in its own ordered set
        const ucur = try moment.getCursor(hash.hashInt(repo_opts.hash, "user-id-set")) orelse return error.NotFound;
        const uset = try Repo.DB.SortedSet(.read_only).init(ucur);
        try std.testing.expectEqual(1, try uset.count());
    }

    // delete repo1 -> dense order (no tombstone)
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[1], .lower), .timestamp = 200, .event = .{ .repo = null } },
    }, false);
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[0], &repo_ids[2], &repo_ids[3] });
    }

    // update repo0 at a later timestamp -> keeps its original slot
    try evt.commitAndConsume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(repo_ids[0], .lower), .timestamp = 300, .event = .{ .repo = .{ .user_id = &user_id, .name = "repo0", .description = "updated", .enable_issue = true } } },
    }, false);
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try Check.order(Repo.DB, repo_opts.hash, moment, &.{ &repo_ids[0], &repo_ids[2], &repo_ids[3] });

        // the value really was updated
        const e2r_cur = try moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
        const e2r = try Repo.DB.HashMap(.read_only).init(e2r_cur);
        const rc = try e2r.getCursor(hash.hashInt(repo_opts.hash, &repo_ids[0])) orelse return error.NotFound;
        const rm = try Repo.DB.HashMap(.read_only).init(rc);
        const re = try evt.read(evt.Repo, Repo.DB, repo_opts.hash, &arena, rm);
        try std.testing.expectEqualStrings("updated", re.description);
    }
}

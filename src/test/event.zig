const std = @import("std");
const hx = @import("haxy");
const evt = hx.event;
const xit = hx.xit;
const rp = xit.repo;
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

    //
    // define test events
    //

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);

    const first_event_id = evt.randomId(prng.random());

    const events_to_consume = [_]evt.Event{
        .{
            .id = std.fmt.bytesToHex(first_event_id, .lower),
            .data = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug\x00priority-high\x00ui",
                },
            },
        },
        // this event edits the previous one because it has the same id
        .{
            .id = std.fmt.bytesToHex(first_event_id, .lower),
            .data = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field and removes typed input. Preserve the field value and show an inline validation message.",
                    .tags = "bug\x00priority-low\x00ui",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Search results ignore archived project filter",
                    .description = "Filtering search results to active projects still returns issues from archived projects. Apply the archived flag before ranking results.",
                    .tags = "bug\x00search\x00backend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Issue list does not persist selected sort order",
                    .description = "Changing the issue list sort order is lost after refresh. Store the selected sort field and direction with the user's view preferences.",
                    .tags = "enhancement\x00frontend\x00preferences",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var first_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;

    {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();

        for (events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            const oid = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, .{ .kind = .head, .name = "haxy/meta" });
            if (i == 0) {
                _ = try std.fmt.hexToBytes(&first_oid, &oid);
            }
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        const history = try Repo.DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        // read the moment we just created
        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try Repo.DB.HashMap(.read_only).init(moment_cursor);

        // get the last object id
        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try Repo.DB.ArrayList(.read_only).init(haxy_cursor);

        try std.testing.expectEqual(1, try haxy.count());

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try Repo.DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try Repo.DB.HashMap(.read_only).init(haxy_moment_cursor);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map that was edited
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_event_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.EventData.read(Repo.DB, repo_opts.hash, arena.allocator(), first_issue_map, .issue);

        // the description was correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].data.issue.description, first_issue.issue.description);

        // the tags were correctly edited
        try std.testing.expectEqualStrings(events_to_consume[1].data.issue.tags, first_issue.issue.tags);
    }

    //
    // rebase the branch so it no longer includes the edit event
    //

    const rebased_events_to_consume = [_]evt.Event{
        events_to_consume[2],
        events_to_consume[3],
    };

    {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();

        for (rebased_events_to_consume, 0..) |event, i| {
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
                .{ .kind = .head, .name = "haxy/meta" },
            );
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        const history = try Repo.DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        // read the moment we just created
        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try Repo.DB.HashMap(.read_only).init(moment_cursor);

        // get the last object id
        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try Repo.DB.ArrayList(.read_only).init(haxy_cursor);

        try std.testing.expectEqual(2, try haxy.count());

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try Repo.DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try Repo.DB.HashMap(.read_only).init(haxy_moment_cursor);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map that was edited
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_event_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.EventData.read(Repo.DB, repo_opts.hash, arena.allocator(), first_issue_map, .issue);

        // the description is no longer edited
        try std.testing.expectEqualStrings(events_to_consume[0].data.issue.description, first_issue.issue.description);

        // the tags are no longer edited
        try std.testing.expectEqualStrings(events_to_consume[0].data.issue.tags, first_issue.issue.tags);
    }

    //
    // rebase the branch so it no longer includes the original issue
    //

    {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();

        for (rebased_events_to_consume, 0..) |event, i| {
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
                .{ .kind = .head, .name = "haxy/meta" },
            );
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        const history = try Repo.DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        // read the moment we just created
        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try Repo.DB.HashMap(.read_only).init(moment_cursor);

        // get the last object id
        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try Repo.DB.ArrayList(.read_only).init(haxy_cursor);

        try std.testing.expectEqual(1, try haxy.count());

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try Repo.DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try Repo.DB.HashMap(.read_only).init(haxy_moment_cursor);

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

    //
    // define test events
    //

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);

    const events_to_consume = [_]evt.Event{
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Login form clears password on validation error",
                    .description = "Submitting an invalid email address resets the password field. Preserve the field value and show an inline validation message.",
                    .tags = "bug\x00priority-high\x00ui",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Search results ignore archived project filter",
                    .description = "Filtering search results to active projects still returns issues from archived projects. Apply the archived flag before ranking results.",
                    .tags = "bug\x00search\x00backend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Issue list does not persist selected sort order",
                    .description = "Changing the issue list sort order is lost after refresh. Store the selected sort field and direction with the user's view preferences.",
                    .tags = "enhancement\x00frontend\x00preferences",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var first_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;

    {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();

        for (events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            const oid = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, .{ .kind = .head, .name = "haxy/meta" });
            if (i == 0) {
                _ = try std.fmt.hexToBytes(&first_oid, &oid);
            }
        }
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        const history = try Repo.DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        // read the moment we just created
        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try Repo.DB.HashMap(.read_only).init(moment_cursor);

        // get the last object id
        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try Repo.DB.ArrayList(.read_only).init(haxy_cursor);

        try std.testing.expectEqual(1, try haxy.count());

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try Repo.DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try Repo.DB.HashMap(.read_only).init(haxy_moment_cursor);

        // get the map of issues
        const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse return error.NotFound;
        const event_id_to_issue = try Repo.DB.HashMap(.read_only).init(event_id_to_issue_cursor);

        // get the issue out of the map
        var first_issue_id: [evt.event_id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&first_issue_id, &events_to_consume[0].id);
        const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id)) orelse return error.NotFound;
        const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
        const first_issue = try evt.EventData.read(Repo.DB, repo_opts.hash, arena.allocator(), first_issue_map, .issue);

        try std.testing.expectEqualStrings(events_to_consume[0].data.issue.description, first_issue.issue.description);
        try std.testing.expectEqualStrings(events_to_consume[0].data.issue.tags, first_issue.issue.tags);
    }

    //
    // define more test events
    //

    const other_events_to_consume = [_]evt.Event{
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Kanban card status badge falls behind after drag",
                    .description = "Moving an issue between columns updates the card position immediately, but the status badge keeps showing the previous state until refresh.",
                    .tags = "bug\x00kanban\x00frontend",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Assignee autocomplete omits recently invited users",
                    .description = "Users invited during the current session do not appear in the assignee picker until the project page is reloaded.",
                    .tags = "bug\x00assignees\x00api",
                },
            },
        },
        .{
            .id = std.fmt.bytesToHex(evt.randomId(prng.random()), .lower),
            .data = .{
                .issue = .{
                    .title = "Add due date warning for issues blocked by dependencies",
                    .description = "Show a warning when an issue's due date is earlier than an unresolved blocking issue so planners can adjust the schedule.",
                    .tags = "enhancement\x00planning\x00dependencies",
                },
            },
        },
    };

    //
    // insert issues as commits in the repo
    //

    {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();

        for (other_events_to_consume, 0..) |event, i| {
            json.clearRetainingCapacity();

            try std.json.Stringify.value(event, .{}, &json.writer);

            // commit the event into a special branch
            _ = try repo.commitAtRef(
                io,
                allocator,
                // make the first commit a child of the first commit on the haxy/meta branch
                .{ .parent_oids = if (i == 0) &.{std.fmt.bytesToHex(first_oid, .lower)} else null, .message = json.written() },
                null,
                .{ .kind = .head, .name = "haxy/other" },
            );
        }
    }

    //
    // check out the haxy/meta branch and merge the haxy/other branch into it
    //

    {
        var result = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "haxy/meta" } } });
        defer result.deinit();

        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = .{ .kind = .head, .name = "haxy/other" } }} } } }, null);
        defer merge.deinit();

        try std.testing.expect(.success == merge.result);
    }

    //
    // consume events into the database
    //

    {
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        const history = try Repo.DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

        // read the moment we just created
        const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
        const moment = try Repo.DB.HashMap(.read_only).init(moment_cursor);

        // get the last object id
        const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
        var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id);

        const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
        const haxy = try Repo.DB.ArrayList(.read_only).init(haxy_cursor);

        try std.testing.expectEqual(2, try haxy.count());

        const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
        const haxy_moments = try Repo.DB.HashMap(.read_only).init(haxy_moments_cursor);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
        const haxy_moment = try Repo.DB.HashMap(.read_only).init(haxy_moment_cursor);

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
            const first_issue = try evt.EventData.read(Repo.DB, repo_opts.hash, arena.allocator(), first_issue_map, .issue);

            try std.testing.expectEqualStrings(events_to_consume[0].data.issue.description, first_issue.issue.description);
            try std.testing.expectEqualStrings(events_to_consume[0].data.issue.tags, first_issue.issue.tags);
        }

        // make sure one of the new issues is there
        {
            // get the issue out of the map
            var first_issue_id: [evt.event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_issue_id, &other_events_to_consume[0].id);
            const first_issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &first_issue_id)) orelse return error.NotFound;
            const first_issue_map = try Repo.DB.HashMap(.read_only).init(first_issue_cursor);
            const first_issue = try evt.EventData.read(Repo.DB, repo_opts.hash, arena.allocator(), first_issue_map, .issue);

            try std.testing.expectEqualStrings(other_events_to_consume[0].data.issue.description, first_issue.issue.description);
            try std.testing.expectEqualStrings(other_events_to_consume[0].data.issue.tags, first_issue.issue.tags);
        }
    }
}

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;
const obj = xit.object;
const rf = xit.ref;

pub const user = @import("event/user.zig");

pub const event_id_size: usize = 32;

pub const EventKind = enum {
    user,
    repo,
    issue,
};

pub const EventData = union(EventKind) {
    user: User,
    repo: Repo,
    issue: Issue,

    pub const User = struct {
        name: []const u8,
        email: []const u8,
        password_hash: []const u8,
    };

    pub const Repo = struct {
        user_id: []const u8,
        name: []const u8,
        enable_issue: bool,
    };

    pub const Issue = struct {
        title: []const u8,
        description: []const u8,
        tags: []const u8,
    };

    pub fn read(
        comptime DB: type,
        comptime hash_kind: hash.HashKind,
        allocator: std.mem.Allocator,
        map: DB.HashMap(.read_only),
        kind: EventKind,
    ) !EventData {
        return switch (kind) {
            .user => .{
                .user = .{
                    .name = try readBytes(DB, hash_kind, allocator, map, "name"),
                    .email = try readBytes(DB, hash_kind, allocator, map, "email"),
                    .password_hash = try readBytes(DB, hash_kind, allocator, map, "password_hash"),
                },
            },
            .repo => .{
                .repo = .{
                    .user_id = try readBytes(DB, hash_kind, allocator, map, "user_id"),
                    .name = try readBytes(DB, hash_kind, allocator, map, "name"),
                    .enable_issue = try readBool(DB, hash_kind, map, "enable_issue"),
                },
            },
            .issue => .{
                .issue = .{
                    .title = try readBytes(DB, hash_kind, allocator, map, "title"),
                    .description = try readBytes(DB, hash_kind, allocator, map, "description"),
                    .tags = try readBytes(DB, hash_kind, allocator, map, "tags"),
                },
            },
        };
    }

    fn readBytes(
        comptime DB: type,
        comptime hash_kind: hash.HashKind,
        allocator: std.mem.Allocator,
        map: DB.HashMap(.read_only),
        field_name: []const u8,
    ) ![]const u8 {
        const cursor = try map.getCursor(hash.hashInt(hash_kind, field_name)) orelse return error.NotFound;
        return try cursor.readBytesAlloc(allocator, null);
    }

    fn readBool(
        comptime DB: type,
        comptime hash_kind: hash.HashKind,
        map: DB.HashMap(.read_only),
        field_name: []const u8,
    ) !bool {
        const cursor = try map.getCursor(hash.hashInt(hash_kind, field_name)) orelse return error.NotFound;
        var buffer: [5]u8 = undefined;
        const bytes = try cursor.readBytesObject(&buffer);
        const format_tag = bytes.format_tag orelse return error.InvalidFormatTag;
        if (!std.mem.eql(u8, &format_tag, "bl")) return error.InvalidFormatTag;
        if (std.mem.eql(u8, bytes.value, "true")) return true;
        if (std.mem.eql(u8, bytes.value, "false")) return false;
        return error.InvalidBool;
    }
};

pub const Event = struct {
    id: [event_id_size * 2]u8,
    data: MaybeEventData,

    pub const MaybeEventData = union(EventKind) {
        user: ?EventData.User,
        repo: ?EventData.Repo,
        issue: ?EventData.Issue,

        fn fromJson(
            allocator: std.mem.Allocator,
            kind: EventKind,
            value_maybe: ?std.json.Value,
        ) !MaybeEventData {
            return switch (kind) {
                .user => .{
                    .user = if (value_maybe) |value| try std.json.parseFromValueLeaky(EventData.User, allocator, value, .{}) else null,
                },
                .repo => .{
                    .repo = if (value_maybe) |value| try std.json.parseFromValueLeaky(EventData.Repo, allocator, value, .{}) else null,
                },
                .issue => .{
                    .issue = if (value_maybe) |value| try std.json.parseFromValueLeaky(EventData.Issue, allocator, value, .{}) else null,
                },
            };
        }
    };

    pub fn jsonStringify(self: Event, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("kind");
        try jw.write(@tagName(self.data));
        try jw.objectField("data");
        switch (self.data) {
            inline else => |data_maybe| try jw.write(data_maybe),
        }
        try jw.endObject();
    }

    fn fromString(allocator: std.mem.Allocator, message: []const u8) !Event {
        const JsonEvent = struct {
            id: [event_id_size * 2]u8,
            kind: EventKind,
            data: ?std.json.Value = null,
        };
        const json_event = try std.json.parseFromSliceLeaky(JsonEvent, allocator, message, .{});
        return .{
            .id = json_event.id,
            .data = try MaybeEventData.fromJson(allocator, json_event.kind, json_event.data),
        };
    }
};

pub fn randomId(random: std.Random) [event_id_size]u8 {
    var id_bytes: [event_id_size]u8 = undefined;
    random.bytes(&id_bytes);
    return id_bytes;
}

pub fn consume(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    ref: rf.Ref,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const State = rp.Repo(.xit, repo_opts).State;

    const Ctx = struct {
        core: *rp.Repo(.xit, repo_opts).Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        ref: rf.Ref,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            try consumeInTransaction(repo_opts, state, ctx.io, ctx.allocator, ctx.ref);
        }
    };

    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
        .core = &repo.core,
        .io = io,
        .allocator = allocator,
        .ref = ref,
    });
}

pub fn consumeInTransaction(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    ref: rf.Ref,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;

    // the last_object_id represents the object id that was last consumed
    var last_object_id_maybe: ?[hash.byteLen(repo_opts.hash)]u8 = null;
    if (try state.extra.moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id"))) |last_object_id_cursor| {
        var last_object_id_buffer: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id_buffer);
        last_object_id_maybe = last_object_id_buffer;
    }

    // the list with all of haxy's state, including materialized views.
    // the reason it is a list is so we can keep every previous haxy
    // state, making it easy to revert to an older state if the user
    // rebases some of the past commits.
    const haxy_cursor = try state.extra.moment.putCursor(hash.hashInt(repo_opts.hash, "haxy"));
    const haxy = try DB.ArrayList(.read_write).init(haxy_cursor);

    // add a new item to the haxy list created above.
    // we call the item haxy_moments. it is a map of object id to haxy moment.
    // in other words, it maps each object id to a hash map containing the
    // state that the database was in when that object id was consumed.
    var haxy_moments_cursor = try haxy.appendCursor();
    // use the previous haxy_moments as the basis for this one if it exists
    if (try haxy.getCursor(-2)) |last_haxy_moments_cursor| {
        try haxy_moments_cursor.write(.{ .slot = last_haxy_moments_cursor.slot() });
    }
    var haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // compute a list of events that haven't been consumed yet
    const RepoEvent = struct {
        parent_oids: []const [hash.hexLen(repo_opts.hash)]u8,
        oid: [hash.byteLen(repo_opts.hash)]u8,
    };
    var repo_events: std.ArrayList(RepoEvent) = .empty;
    defer repo_events.deinit(allocator);
    {
        var commit_iter = try obj.ObjectIterator(.xit, repo_opts, .full).init(state.readOnly(), io, allocator, .{ .kind = .commit });
        defer commit_iter.deinit();

        const head_oid = (try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = ref })) orelse return error.OidNotFound;
        try commit_iter.include(&head_oid);

        // walk the commits and add all new events we haven't consumed yet.
        // the `next` call is using the arena because we need the parent_oids
        // slice to live beyond this scope.
        // TODO: `repo_events` could in theory contain an unbounded number
        // of events, so there is an OOM risk here. we definitely need to
        // guard against this.
        while (try commit_iter.next(arena.allocator())) |commit_object| {
            var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&oid, &commit_object.oid);

            // if this object id has already been consumed, prune its ancestry from
            // the iterator. other queued paths, such as the second parent of a
            // merge commit, can still be walked until they hit a consumed commit
            // or run out of history.
            if (null != try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &oid))) {
                try commit_iter.exclude(&commit_object.oid);
                continue;
            }

            const parent_oids = commit_object.content.commit.metadata.parent_oids orelse return error.ParentOidsNotFound;
            try repo_events.append(allocator, .{ .parent_oids = parent_oids, .oid = oid });
        }
    }

    // if there are no events to process, look at the oid at HEAD and update
    // the last_object_id to point to it. this is important in situations
    // where we do a merge and then force-push to remove the merge. see the
    // merge test for an example.
    if (repo_events.items.len == 0) {
        const head_oid_hex = (try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = ref })) orelse return error.OidNotFound;
        var head_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try std.fmt.hexToBytes(&head_oid, &head_oid_hex);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &head_oid)) orelse return error.CursorNotFound;
        const haxy_moment = try DB.HashMap(.read_only).init(haxy_moment_cursor);

        const moment_index_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "moment-index")) orelse return error.CursorNotFound;
        const moment_index = try moment_index_cursor.readUint();

        try haxy.slice(moment_index + 1);
        try state.extra.moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = &head_oid });
        return;
    }

    // if this branch was rebased and force pushed, we need to detect that and
    // properly revert the haxy state to the last valid state. we detect this
    // by simply asking if the last event is a descendent of the last event
    // we consumed. if it isn't, then we know the haxy state needs to be reverted.
    if (last_object_id_maybe) |*last_object_id| {
        var is_rebased = false;

        _ = mrg.getDescendent(
            .xit,
            repo_opts,
            state.readOnly(),
            io,
            allocator,
            &std.fmt.bytesToHex(last_object_id, .lower),
            &std.fmt.bytesToHex(repo_events.items[0].oid, .lower),
        ) catch |err| switch (err) {
            error.DescendentNotFound => is_rebased = true,
            else => |e| return e,
        };

        if (is_rebased) {
            const parent_oids = repo_events.items[repo_events.items.len - 1].parent_oids;
            switch (parent_oids.len) {
                0 => {
                    // the branch was rebased all the way to the very beginning.
                    // we have a repo event with no parent, which means it is now
                    // the very first event. all we need to do is set the haxy list
                    // to be empty and make a new haxy_moments map to work with.

                    try haxy.slice(0);
                    haxy_moments_cursor = try haxy.appendCursor();
                    haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

                    last_object_id_maybe = null;
                },
                1 => {
                    var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&oid, &parent_oids[0]);

                    const old_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &oid)) orelse return error.CursorNotFound;
                    const old_moment = try DB.HashMap(.read_only).init(old_moment_cursor);

                    const old_moment_index_cursor = try old_moment.getCursor(hash.hashInt(repo_opts.hash, "moment-index")) orelse return error.CursorNotFound;
                    const old_moment_index = try old_moment_index_cursor.readUint();

                    // resize the haxy list so we truncate all the moments that were
                    // created after the parent_oid was consumed
                    try haxy.slice(old_moment_index + 1);

                    // make a new haxy moment and set its initial value to the last haxy moment
                    haxy_moments_cursor = try haxy.appendCursor();
                    const old_haxy_moments_cursor = try haxy.getCursor(old_moment_index) orelse return error.CursorNotFound;
                    try haxy_moments_cursor.write(.{ .slot = old_haxy_moments_cursor.slot() });
                    haxy_moments = try DB.HashMap(.read_write).init(haxy_moments_cursor);

                    last_object_id_maybe = oid;
                },
                else => return error.UnexpectedParentCount,
            }
        }
    } else {
        if (repo_events.items[repo_events.items.len - 1].parent_oids.len != 0) {
            // there is no last_object_id, but this event has a parent.
            // this is an invalid state. if the event has a parent, that
            // implies that an event has already been processed, but
            // if that's true then there would be a last_object_id.
            return error.UnexpectedParent;
        }
    }

    // iterate over the events in reverse order
    // (they are sorted by most recent events first)
    for (0..repo_events.items.len) |i| {
        const repo_event = repo_events.items[repo_events.items.len - i - 1];

        // create a moment for this object id
        var haxy_moment_cursor = try haxy_moments.putCursor(hash.bytesToInt(repo_opts.hash, &repo_event.oid));

        // if there was a previous object id, set this haxy moment's initial value to it.
        // this efficiently "clones" the map so we make further modifications based on it.
        if (repo_event.parent_oids.len > 0) {
            var first_parent_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_parent_oid, &repo_event.parent_oids[0]);

            const first_parent_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &first_parent_oid)) orelse return error.CursorNotFound;
            try haxy_moment_cursor.write(.{ .slot = first_parent_haxy_moment_cursor.slot() });
        }

        const haxy_moment = try DB.HashMap(.read_write).init(haxy_moment_cursor);

        // merge changes from every parent after the first parent. the common
        // ancestor is the baseline, so a later parent only contributes values
        // it changed relative to the merge base.
        if (repo_event.parent_oids.len > 1) {
            for (repo_event.parent_oids[1..]) |*parent_oid| {
                var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try std.fmt.hexToBytes(&oid, parent_oid);

                const parent_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &oid)) orelse return error.CursorNotFound;
                const parent_haxy_moment = try DB.HashMap(.read_only).init(parent_haxy_moment_cursor);

                const baseline_oid_hex = try mrg.commonAncestor(.xit, repo_opts, state.readOnly(), io, allocator, &repo_event.parent_oids[0], parent_oid);
                var baseline_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try std.fmt.hexToBytes(&baseline_oid, &baseline_oid_hex);
                const baseline_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &baseline_oid)) orelse return error.CursorNotFound;
                const baseline_haxy_moment = try DB.HashMap(.read_only).init(baseline_haxy_moment_cursor);

                try mergeChangedMapEntries(DB, haxy_moment, parent_haxy_moment, baseline_haxy_moment, true);
            }
        }

        // associate this moment with the index it will first appear at in the haxy list.
        // this will be important later so we can truncate that list if the user ever
        // rebases starting at this object id.
        try haxy_moment.put(hash.hashInt(repo_opts.hash, "moment-index"), .{ .uint = try haxy.count() - 1 });

        // consume the event unless it's a merge commit
        if (repo_event.parent_oids.len <= 1) {
            var commit_object = try obj.Object(.xit, repo_opts, .full).init(state.readOnly(), io, allocator, &std.fmt.bytesToHex(repo_event.oid, .lower));
            defer commit_object.deinit();

            // read the message from the commit
            try commit_object.object_reader.seekTo(commit_object.content.commit.message_position);
            const message = try commit_object.object_reader.interface.allocRemaining(arena.allocator(), .unlimited);

            const event = try Event.fromString(arena.allocator(), message);

            // get the id of the current event as bytes
            var current_event_id: [event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&current_event_id, &event.id);

            switch (event.data) {
                .user => |user_data_maybe| {
                    const user_key = hash.hashInt(repo_opts.hash, &current_event_id);

                    const event_id_to_user_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "event-id->user"));
                    const event_id_to_user = try DB.HashMap(.read_write).init(event_id_to_user_cursor);

                    if (user_data_maybe) |user_data| {
                        const user_cursor = try event_id_to_user.putCursor(user_key);
                        const user_map = try DB.HashMap(.read_write).init(user_cursor);
                        try upsert(DB, repo_opts.hash, user_map, EventData.User, user_data);
                    } else {
                        if (!try event_id_to_user.remove(user_key)) return error.EventNotFound;

                        const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "user-id->repos"));
                        const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);
                        _ = try user_id_to_repos.remove(user_key);
                    }
                },
                .repo => |repo_data_maybe| {
                    const repo_key = hash.hashInt(repo_opts.hash, &current_event_id);

                    const event_id_to_repo_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "event-id->repo"));
                    const event_id_to_repo = try DB.HashMap(.read_write).init(event_id_to_repo_cursor);

                    if (repo_data_maybe) |repo_data| {
                        const repo_cursor = try event_id_to_repo.putCursor(repo_key);
                        const repo_map = try DB.HashMap(.read_write).init(repo_cursor);
                        try upsert(DB, repo_opts.hash, repo_map, EventData.Repo, repo_data);

                        const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "user-id->repos"));
                        const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);

                        const user_repos_cursor = try user_id_to_repos.putCursor(hash.hashInt(repo_opts.hash, repo_data.user_id));
                        const user_repos = try DB.CountedHashSet(.read_write).init(user_repos_cursor);
                        try user_repos.put(repo_key, .{ .bytes = &current_event_id });
                    } else {
                        if (try event_id_to_repo.getCursor(repo_key)) |existing_repo_cursor| {
                            const existing_repo_map = try DB.HashMap(.read_only).init(existing_repo_cursor);
                            const existing_repo = try EventData.read(DB, repo_opts.hash, arena.allocator(), existing_repo_map, .repo);
                            const data = existing_repo.repo;

                            const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "user-id->repos"));
                            const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);

                            const user_key = hash.hashInt(repo_opts.hash, data.user_id);
                            const user_repos_cursor = try user_id_to_repos.putCursor(user_key);
                            const user_repos = try DB.CountedHashSet(.read_write).init(user_repos_cursor);
                            _ = try user_repos.remove(repo_key);
                        }
                        if (!try event_id_to_repo.remove(repo_key)) return error.EventNotFound;
                    }
                },
                .issue => |issue_data_maybe| {
                    const issue_key = hash.hashInt(repo_opts.hash, &current_event_id);

                    const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, "event-id->issue"));
                    const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

                    if (issue_data_maybe) |issue_data| {
                        const issue_cursor = try event_id_to_issue.putCursor(issue_key);
                        const issue = try DB.HashMap(.read_write).init(issue_cursor);
                        try upsert(DB, repo_opts.hash, issue, EventData.Issue, issue_data);
                    } else {
                        if (!try event_id_to_issue.remove(issue_key)) return error.EventNotFound;
                    }
                },
            }
        }

        // the current object id is now the last one
        last_object_id_maybe = repo_event.oid;

        // prevent any of the data created above from being mutated by future iterations of this loop
        try state.core.db.freeze();
    }

    if (last_object_id_maybe) |*last_object_id| {
        try state.extra.moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = last_object_id });
    }
}

fn upsert(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    comptime Data: type,
    data: Data,
) !void {
    switch (@typeInfo(Data)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try upsertField(DB, hash_kind, map, field.name, field.type, @field(data, field.name));
            }
        },
        else => @compileError("upsert expects a struct"),
    }
}

fn mergeChangedMapEntries(
    comptime DB: type,
    target: DB.HashMap(.read_write),
    parent: DB.HashMap(.read_only),
    baseline: DB.HashMap(.read_only),
    comptime is_top_level: bool,
) !void {
    var parent_iter = try parent.iterator();
    while (try parent_iter.next()) |kv_pair_cursor| {
        const kv_pair = try kv_pair_cursor.readKeyValuePair();

        const baseline_value_cursor = try baseline.getCursor(kv_pair.hash) orelse {
            if ((try target.getCursor(kv_pair.hash)) != null) {
                return error.MergeConflict;
            }

            try target.put(kv_pair.hash, .{ .slot = kv_pair.value_cursor.slot() });
            continue;
        };

        const tag = kv_pair.value_cursor.slot().tag;

        if (tag != baseline_value_cursor.slot().tag) {
            return error.UnexpectedTag;
        }

        if (kv_pair.value_cursor.slot().value == baseline_value_cursor.slot().value) {
            continue;
        }

        if (tag == .hash_map) {
            const target_existing_cursor = try target.getCursor(kv_pair.hash) orelse return error.MergeConflict;
            if (target_existing_cursor.slot().tag != .hash_map) {
                return error.MergeConflict;
            }

            const target_child_cursor = try target.putCursor(kv_pair.hash);
            const target_child = try DB.HashMap(.read_write).init(target_child_cursor);
            const parent_child = try DB.HashMap(.read_only).init(kv_pair.value_cursor);
            const baseline_child = try DB.HashMap(.read_only).init(baseline_value_cursor);
            try mergeChangedMapEntries(DB, target_child, parent_child, baseline_child, false);
        } else if (is_top_level) {
            // the moment-index is a top-level key in the haxy moment
            // and is not a map. we don't want to do any merge of this.
            continue;
        } else {
            const target_value_cursor = try target.getCursor(kv_pair.hash) orelse return error.MergeConflict;
            if (target_value_cursor.slot().value != baseline_value_cursor.slot().value) {
                return error.MergeConflict;
            }

            try target.put(kv_pair.hash, .{ .slot = kv_pair.value_cursor.slot() });
        }
    }
}

fn upsertField(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    comptime field_name: []const u8,
    comptime Field: type,
    value: Field,
) !void {
    const key = hash.hashInt(hash_kind, field_name);

    switch (@typeInfo(Field)) {
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try upsertBytes(DB, hash_kind, map, key, value);
            } else {
                @compileError("unsupported upsert field type: " ++ @typeName(Field));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try upsertBytes(DB, hash_kind, map, key, &value);
            } else {
                @compileError("unsupported upsert field type: " ++ @typeName(Field));
            }
        },
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => {
                if (try map.getCursor(key)) |value_cursor| {
                    if (try value_cursor.readUint() == value) {
                        return;
                    }
                }

                try map.put(key, .{ .uint = value });
            },
            .signed => {
                if (try map.getCursor(key)) |value_cursor| {
                    if (try value_cursor.readInt() == value) {
                        return;
                    }
                }

                try map.put(key, .{ .int = value });
            },
        },
        .bool => {
            const bytes = if (value) "true" else "false";
            if (try map.getCursor(key)) |value_cursor| {
                var buffer: [5]u8 = undefined;
                const existing = try value_cursor.readBytesObject(&buffer);
                if (existing.format_tag) |format_tag| {
                    if (std.mem.eql(u8, &format_tag, "bl") and std.mem.eql(u8, existing.value, bytes)) {
                        return;
                    }
                }
            }

            try map.put(key, .{ .bytes_object = .{ .value = bytes, .format_tag = "bl".* } });
        },
        else => @compileError("unsupported upsert field type: " ++ @typeName(Field)),
    }
}

fn upsertBytes(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    key: hash.HashInt(hash_kind),
    value: []const u8,
) !void {
    var existing_cursor_maybe = try map.getCursor(key);
    if (existing_cursor_maybe) |*existing_cursor| {
        if (try bytesEqual(DB, existing_cursor, value)) {
            return;
        }
    }

    var value_cursor = try map.putCursor(key);
    var write_buffer: [1024]u8 = undefined;
    var writer = try value_cursor.writer(&write_buffer);
    try writer.interface.writeAll(value);
    try writer.finish();
}

fn bytesEqual(
    comptime DB: type,
    cursor: *DB.Cursor(.read_only),
    value: []const u8,
) !bool {
    var read_buffer: [1024]u8 = undefined;
    var reader = try cursor.reader(&read_buffer);
    if (reader.size != value.len) {
        return false;
    }

    var chunk_buffer: [1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < value.len) {
        const chunk_len = @min(chunk_buffer.len, value.len - offset);
        try reader.interface.readSliceAll(chunk_buffer[0..chunk_len]);
        if (!std.mem.eql(u8, chunk_buffer[0..chunk_len], value[offset .. offset + chunk_len])) {
            return false;
        }
        offset += chunk_len;
    }

    return true;
}

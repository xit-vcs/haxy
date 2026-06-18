const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;
const obj = xit.object;
const rf = xit.ref;

pub const User = @import("event/User.zig");
pub const Repo = @import("event/Repo.zig");
pub const Issue = @import("event/Issue.zig");

pub const event_id_size: usize = 32;

// the branch haxy events are committed to before being consumed
pub const events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/meta" };

// options + db type for *the admin repo* — the single event store that holds
// users, repos, issues, etc. the functions below stay parameterized over
// repo_opts because they also operate on individual repos in the repos dir,
// which may use different options
pub const admin_repo_opts: rp.RepoOpts(.xit) = .{};
pub const AdminDB = rp.Repo(.xit, admin_repo_opts).DB;

pub const EventKind = enum {
    user,
    repo,
    issue,
};

pub const EventWithId = struct {
    id: [event_id_size * 2]u8,
    event: union(EventKind) {
        user: ?User,
        repo: ?Repo,
        issue: ?Issue,
    },
    timestamp: u64 = 0, // not serialized, because it comes from the commit timestamp

    pub fn jsonStringify(self: EventWithId, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("kind");
        try jw.write(@tagName(self.event));
        try jw.objectField("data");
        switch (self.event) {
            inline else => |event_maybe| try jw.write(event_maybe),
        }
        try jw.endObject();
    }

    fn fromString(arena: *std.heap.ArenaAllocator, message: []const u8) !EventWithId {
        const JsonEvent = struct {
            id: [event_id_size * 2]u8,
            kind: EventKind,
            data: ?std.json.Value = null,
        };
        const json_event = try std.json.parseFromSliceLeaky(JsonEvent, arena.allocator(), message, .{});
        return .{
            .id = json_event.id,
            .event = switch (json_event.kind) {
                .user => .{
                    .user = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(User, arena.allocator(), value, .{})
                    else
                        null,
                },
                .repo => .{
                    .repo = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Repo, arena.allocator(), value, .{})
                    else
                        null,
                },
                .issue => .{
                    .issue = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Issue, arena.allocator(), value, .{})
                    else
                        null,
                },
            },
        };
    }

    pub fn randomId(random: std.Random) [event_id_size]u8 {
        var id_bytes: [event_id_size]u8 = undefined;
        random.bytes(&id_bytes);
        return id_bytes;
    }
};

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

    var commit_iter = try CommitIterator(repo_opts).init(state.readOnly(), io, allocator, haxy_moments.readOnly(), ref);
    defer commit_iter.deinit(io, allocator);

    // if there are no events to process, look at the oid at HEAD and update
    // the last_object_id to point to it. this is important in situations
    // where we do a merge and then force-push to remove the merge. see the
    // merge test for an example.
    if (commit_iter.newest_object_id == null) {
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
        const newest_object_id = commit_iter.newest_object_id orelse return error.OidNotFound;

        _ = mrg.getDescendent(
            .xit,
            repo_opts,
            state.readOnly(),
            io,
            allocator,
            &std.fmt.bytesToHex(last_object_id, .lower),
            &std.fmt.bytesToHex(&newest_object_id, .lower),
        ) catch |err| switch (err) {
            error.DescendentNotFound => is_rebased = true,
            else => |e| return e,
        };

        if (is_rebased) {
            const oldest_object_id = commit_iter.oldest_object_id orelse return error.OidNotFound;
            var oldest_object = try obj.Object(.xit, repo_opts, .full).init(state.readOnly(), io, allocator, &std.fmt.bytesToHex(oldest_object_id, .lower));
            defer oldest_object.deinit();

            const parent_oids = oldest_object.content.commit.metadata.parent_oids orelse return error.ParentOidsNotFound;
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
    }

    while (try commit_iter.next()) |repo_event_oid| {
        var commit_object = try obj.Object(.xit, repo_opts, .full).init(state.readOnly(), io, allocator, &std.fmt.bytesToHex(repo_event_oid, .lower));
        defer commit_object.deinit();

        const parent_oids = commit_object.content.commit.metadata.parent_oids orelse return error.ParentOidsNotFound;

        // create a moment for this object id
        var haxy_moment_cursor = try haxy_moments.putCursor(hash.bytesToInt(repo_opts.hash, &repo_event_oid));

        // if there was a previous object id, set this haxy moment's initial value to it.
        // this efficiently "clones" the map so we make further modifications based on it.
        if (parent_oids.len > 0) {
            var first_parent_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&first_parent_oid, &parent_oids[0]);

            const first_parent_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &first_parent_oid)) orelse return error.CursorNotFound;
            try haxy_moment_cursor.write(.{ .slot = first_parent_haxy_moment_cursor.slot() });
        }

        const haxy_moment = try DB.HashMap(.read_write).init(haxy_moment_cursor);

        // merge changes from every parent after the first parent. the common
        // ancestor is the baseline, so a later parent only contributes values
        // it changed relative to the merge base.
        if (parent_oids.len > 1) {
            for (parent_oids[1..]) |*parent_oid| {
                var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try std.fmt.hexToBytes(&oid, parent_oid);

                const parent_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &oid)) orelse return error.CursorNotFound;
                const parent_haxy_moment = try DB.HashMap(.read_only).init(parent_haxy_moment_cursor);

                const baseline_oid_hex = try mrg.commonAncestor(.xit, repo_opts, state.readOnly(), io, allocator, &parent_oids[0], parent_oid);
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
        if (parent_oids.len <= 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            // read the message from the commit
            try commit_object.object_reader.seekTo(commit_object.content.commit.message_position);
            const message = try commit_object.object_reader.interface.allocRemaining(arena.allocator(), .unlimited);

            const event_with_id = try EventWithId.fromString(&arena, message);

            // get the id of the current event as bytes
            var current_event_id: [event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&current_event_id, &event_with_id.id);

            const created_ts = commit_object.content.commit.metadata.timestamp;

            switch (event_with_id.event) {
                .user => |event_maybe| try User.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, event_maybe, &arena, created_ts),
                .repo => |event_maybe| try Repo.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, event_maybe, &arena, created_ts),
                .issue => |event_maybe| try Issue.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, event_maybe),
            }
        }

        // the current object id is now the last one
        last_object_id_maybe = repo_event_oid;

        // prevent any of the data created above from being mutated by future iterations of this loop
        try state.core.db.freeze();
    }

    if (last_object_id_maybe) |*last_object_id| {
        try state.extra.moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = last_object_id });
    }
}

pub fn currentMoment(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
) !rp.Repo(.xit, repo_opts).DB.HashMap(.read_only) {
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
    return try DB.HashMap(.read_only).init(haxy_moment_cursor);
}

pub fn commitAndConsume(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    ref: rf.Ref,
    events: []const EventWithId,
) !void {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();

    for (events) |event| {
        json.clearRetainingCapacity();
        try std.json.Stringify.value(event, .{}, &json.writer);
        _ = try repo.commitAtRef(io, allocator, .{ .message = json.written(), .timestamp = event.timestamp }, null, ref);
    }

    try consume(repo_opts, io, allocator, repo, ref);
}

// build the key for SortedMaps sorted by timestamp. the big-endian timestamp
// makes byte order match creation order; the event id breaks ties and keeps
// keys unique within the same timestamp.
pub fn orderKey(timestamp: u64, event_id: *const [event_id_size]u8) [@sizeOf(u64) + event_id_size]u8 {
    var key: [@sizeOf(u64) + event_id_size]u8 = undefined;
    std.mem.writeInt(u64, key[0..@sizeOf(u64)], timestamp, .big);
    @memcpy(key[@sizeOf(u64)..], event_id);
    return key;
}

// split a pushed "<owner>/<repo>" path into its two components, or null if it
// isn't exactly two non-empty segments.
pub fn parseOwnerRepoPath(path: []const u8) ?struct { owner: []const u8, name: []const u8 } {
    var it = std.mem.splitScalar(u8, path, '/');
    const owner = it.next() orelse return null;
    const name = it.next() orelse return null;
    if (it.next() != null) return null;
    if (owner.len == 0 or name.len == 0) return null;

    return .{ .owner = owner, .name = name };
}

// resolve a pushed `<owner>/<repo>` to the hex event id that names its on-disk
// directory under the repos dir
pub fn resolveOrCreateRepo(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    owner_name: []const u8,
    repo_name: []const u8,
    create_if_missing: bool,
) !?[event_id_size * 2]u8 {
    var repo = rp.Repo(.xit, admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return null,
        else => |e| return e,
    };
    defer repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const moment = try currentMoment(admin_repo_opts, &repo);

    // an already-registered repo reuses its event id, so a re-push (or a clone)
    // lands in the same repo
    if (try Repo.readByOwnerAndName(AdminDB, admin_repo_opts.hash, moment, &arena, owner_name, repo_name)) |found| {
        return std.fmt.bytesToHex(found.event_id, .lower);
    }

    if (!create_if_missing) return null;

    // the new repo is owned by the named user, read from the name index; an
    // unknown owner can't own a repo, so the push is rejected
    const name_to_user_id_cursor = try moment.getCursor(hash.hashInt(admin_repo_opts.hash, "name->user-id")) orelse return null;
    const name_to_user_id = try AdminDB.HashMap(.read_only).init(name_to_user_id_cursor);
    const owner_id_cursor = try name_to_user_id.getCursor(hash.hashInt(admin_repo_opts.hash, owner_name)) orelse return null;
    var owner_user_id: [event_id_size]u8 = undefined;
    _ = try owner_id_cursor.readBytes(&owner_user_id);

    var id_bytes: [event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    try commitAndConsume(admin_repo_opts, io, allocator, &repo, events_ref, &[_]EventWithId{.{
        .id = event_id_hex,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .event = .{ .repo = .{
            .user_id = &owner_user_id,
            .name = repo_name,
            .description = "",
            .enable_issue = true,
        } },
    }});

    return event_id_hex;
}

//
// reading from xitdb
//

pub fn read(
    comptime T: type,
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    map: DB.HashMap(.read_only),
) !T {
    var event: T = undefined;

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                switch (@typeInfo(field.type)) {
                    .pointer => |pointer_info| {
                        if (pointer_info.size == .slice and pointer_info.child == u8 and pointer_info.is_const) {
                            @field(event, field.name) = try readBytes(DB, hash_kind, arena.allocator(), map, field.name);
                        } else {
                            @compileError("unsupported read field type: " ++ @typeName(field.type));
                        }
                    },
                    .array => |array_info| {
                        if (array_info.child == u8) {
                            const bytes = try readBytes(DB, hash_kind, arena.allocator(), map, field.name);
                            if (bytes.len != array_info.len) return error.InvalidByteArrayLength;
                            @memcpy(@field(event, field.name)[0..], bytes);
                        } else {
                            @compileError("unsupported read field type: " ++ @typeName(field.type));
                        }
                    },
                    .bool => @field(event, field.name) = try readBool(DB, hash_kind, map, field.name),
                    .int => |int_info| switch (int_info.signedness) {
                        .unsigned => @field(event, field.name) = @intCast(try readUint(DB, hash_kind, map, field.name)),
                        .signed => @field(event, field.name) = @intCast(try readInt(DB, hash_kind, map, field.name)),
                    },
                    else => @compileError("unsupported read field type: " ++ @typeName(field.type)),
                }
            }
        },
        else => @compileError("read expects a struct"),
    }

    return event;
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

fn readUint(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_only),
    field_name: []const u8,
) !u64 {
    const cursor = try map.getCursor(hash.hashInt(hash_kind, field_name)) orelse return error.NotFound;
    return try cursor.readUint();
}

fn readInt(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_only),
    field_name: []const u8,
) !i64 {
    const cursor = try map.getCursor(hash.hashInt(hash_kind, field_name)) orelse return error.NotFound;
    return try cursor.readInt();
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

//
// writing to xitdb
//

pub fn upsert(
    comptime T: type,
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    map: DB.HashMap(.read_write),
    event: T,
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try upsertField(DB, hash_kind, map, field.name, field.type, @field(event, field.name));
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

//
// CommitIterator
//
// differs from xit's ObjectIterator in a few ways:
//
// 1. iterates parents first, rather than children first
// 2. `next` only returns the object id, not the full Object
// 3. stores its temporary state in a file on disk to avoid OOMs
//

pub fn CommitIterator(comptime repo_opts: rp.RepoOpts(.xit)) type {
    return struct {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const db_name = "haxy-repo-events.db";

        repo_dir: std.Io.Dir,
        db_file: std.Io.File,
        db: *DB,
        // map of each object id to its children
        parent_to_children: DB.HashMap(.read_write),
        // tracking pending parents is necessary because a child can only
        // be returned after all of its unconsumed parents have been returned
        child_to_pending_parents: DB.HashMap(.read_write),
        // queue of object ids that are ready to be returned from `next`
        ready_queue: DB.ArrayList(.read_write),
        ready_queue_index: u64,
        // the object id at the tip of this branch
        newest_object_id: ?[hash.byteLen(repo_opts.hash)]u8,
        // the object id furthest back in the history that hasn't been consumed
        oldest_object_id: ?[hash.byteLen(repo_opts.hash)]u8,

        pub fn init(
            state: rp.Repo(.xit, repo_opts).State(.read_only),
            io: std.Io,
            allocator: std.mem.Allocator,
            consumed_object_ids: DB.HashMap(.read_only),
            ref: rf.Ref,
        ) !CommitIterator(repo_opts) {
            const db_file = try state.core.repo_dir.createFile(io, db_name, .{ .truncate = true, .lock = .exclusive, .read = true });
            errdefer {
                db_file.close(io);
                state.core.repo_dir.deleteFile(io, db_name) catch {};
            }

            const buffer_ptr = try allocator.create(std.Io.Writer.Allocating);
            errdefer allocator.destroy(buffer_ptr);

            buffer_ptr.* = std.Io.Writer.Allocating.init(allocator);
            errdefer buffer_ptr.deinit();

            const db_ptr = try allocator.create(DB);
            errdefer allocator.destroy(db_ptr);
            db_ptr.* = try DB.init(.{ .io = io, .file = db_file, .buffer = buffer_ptr });

            const map = try DB.HashMap(.read_write).init(db_ptr.rootCursor());

            const parent_to_children_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "parent->children"));
            const parent_to_children = try DB.HashMap(.read_write).init(parent_to_children_cursor);

            const child_to_pending_parents_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "child->pending-parents"));
            const child_to_pending_parents = try DB.HashMap(.read_write).init(child_to_pending_parents_cursor);

            const ready_queue_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "ready-queue"));
            const ready_queue = try DB.ArrayList(.read_write).init(ready_queue_cursor);

            var self = CommitIterator(repo_opts){
                .repo_dir = state.core.repo_dir,
                .db_file = db_file,
                .db = db_ptr,
                .parent_to_children = parent_to_children,
                .child_to_pending_parents = child_to_pending_parents,
                .ready_queue = ready_queue,
                .ready_queue_index = 0,
                .newest_object_id = null,
                .oldest_object_id = null,
            };
            errdefer self.deinit(io, allocator);

            try self.collect(state, io, allocator, consumed_object_ids, ref);

            return self;
        }

        pub fn deinit(self: *CommitIterator(repo_opts), io: std.Io, allocator: std.mem.Allocator) void {
            self.db_file.close(io);
            self.db.core.memory.buffer.deinit();
            allocator.destroy(self.db.core.memory.buffer);
            self.repo_dir.deleteFile(io, db_name) catch {};
            allocator.destroy(self.db);
        }

        pub fn next(self: *CommitIterator(repo_opts)) !?[hash.byteLen(repo_opts.hash)]u8 {
            if (self.ready_queue_index >= try self.ready_queue.count()) return null;

            const oid = try readOidFromList(self.ready_queue.readOnly(), self.ready_queue_index);
            self.ready_queue_index += 1;

            try self.enqueueChildren(&oid);
            return oid;
        }

        fn collect(
            self: *CommitIterator(repo_opts),
            state: rp.Repo(.xit, repo_opts).State(.read_only),
            io: std.Io,
            allocator: std.mem.Allocator,
            consumed_object_ids: DB.HashMap(.read_only),
            ref: rf.Ref,
        ) !void {
            const map = try DB.HashMap(.read_write).init(self.db.rootCursor());

            const walk_queue_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "walk-queue"));
            const walk_queue = try DB.ArrayList(.read_write).init(walk_queue_cursor);
            var walk_queue_index: u64 = 0;

            const seen_object_ids_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "seen-object-ids"));
            const seen_object_ids = try DB.HashSet(.read_write).init(seen_object_ids_cursor);

            const head_oid_hex = (try rf.readRecur(.xit, repo_opts, state, io, .{ .ref = ref })) orelse return error.OidNotFound;
            var head_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&head_oid, &head_oid_hex);
            try walk_queue.append(.{ .bytes = &head_oid });

            while (walk_queue_index < try walk_queue.count()) {
                const oid = try readOidFromList(walk_queue.readOnly(), walk_queue_index);
                const oid_int = hash.bytesToInt(repo_opts.hash, &oid);

                walk_queue_index += 1;

                // if we've seen this object id, skip it
                if (null != try seen_object_ids.getCursor(oid_int)) {
                    continue;
                }

                try seen_object_ids.put(oid_int, .{ .bytes = &oid });

                var commit_object = try obj.Object(.xit, repo_opts, .full).init(state, io, allocator, &std.fmt.bytesToHex(oid, .lower));
                defer commit_object.deinit();

                // if this object id has already been consumed, skip it
                if (null != try consumed_object_ids.getCursor(oid_int)) {
                    continue;
                }

                if (self.newest_object_id == null) self.newest_object_id = oid;
                self.oldest_object_id = oid;

                const parent_oids = commit_object.content.commit.metadata.parent_oids orelse return error.ParentOidsNotFound;
                var pending_parent_count: u64 = 0;
                for (parent_oids) |*parent_oid| {
                    var parent_oid_bytes: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&parent_oid_bytes, parent_oid);
                    const parent_oid_int = hash.bytesToInt(repo_opts.hash, &parent_oid_bytes);

                    // if this object id has already been consumed, skip it
                    if (null != try consumed_object_ids.getCursor(parent_oid_int)) {
                        continue;
                    }

                    // if this object id hasn't already been seen, add it to the walk queue
                    if (null == try seen_object_ids.getCursor(parent_oid_int)) {
                        try walk_queue.append(.{ .bytes = &parent_oid_bytes });
                    }

                    const children_cursor = try self.parent_to_children.putCursor(parent_oid_int);
                    const children = try DB.HashSet(.read_write).init(children_cursor);
                    try children.put(oid_int, .{ .bytes = &oid });
                    pending_parent_count += 1;
                }

                if (pending_parent_count == 0) {
                    try self.ready_queue.append(.{ .bytes = &oid });
                } else {
                    try self.child_to_pending_parents.put(oid_int, .{ .uint = pending_parent_count });
                }
            }
        }

        fn enqueueChildren(self: *CommitIterator(repo_opts), oid: *const [hash.byteLen(repo_opts.hash)]u8) !void {
            const oid_int = hash.bytesToInt(repo_opts.hash, oid);
            const children_cursor = try self.parent_to_children.getCursor(oid_int) orelse return;
            const children = try DB.HashSet(.read_only).init(children_cursor);
            var children_iter = try children.iterator();

            while (try children_iter.next()) |*child_cursor| {
                const kv_pair = try child_cursor.readKeyValuePair();
                const child_oid_int = kv_pair.hash;
                const pending_parent_cursor = try self.child_to_pending_parents.getCursor(child_oid_int) orelse return error.CursorNotFound;
                const pending_parent_count = try pending_parent_cursor.readUint();

                if (pending_parent_count <= 1) {
                    _ = try self.child_to_pending_parents.remove(child_oid_int);
                    const child_oid = hash.intToBytes(hash.HashInt(repo_opts.hash), child_oid_int);
                    try self.ready_queue.append(.{ .bytes = &child_oid });
                } else {
                    try self.child_to_pending_parents.put(child_oid_int, .{ .uint = pending_parent_count - 1 });
                }
            }
        }

        fn readOidFromList(list: DB.ArrayList(.read_only), index: u64) ![hash.byteLen(repo_opts.hash)]u8 {
            const oid_cursor = try list.getCursor(index) orelse return error.CursorNotFound;
            var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try oid_cursor.readBytes(&oid);
            return oid;
        }
    };
}

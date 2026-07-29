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

pub const event_id_size: usize = 16;

// the most bytes an event's serialized form may hold
pub const max_event_size: usize = 100 * 1024;

// the branch haxy events are committed to before being consumed
pub const events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/events" };

// options + db type for *the admin repo* — the single event store that holds
// users, repos, issues, etc. the functions below stay parameterized over
// repo_opts because they also operate on individual repos in the repos dir,
// which may use different options
pub const admin_repo_opts: rp.RepoOpts(.xit) = .{};
pub const AdminDB = rp.Repo(.xit, admin_repo_opts).DB;

// the xitdb type events are stored in. it only depends on the hash kind, so
// this matches the db of any xit repo using that hash kind.
pub fn EventDB(comptime hash_kind: hash.HashKind) type {
    return rp.Repo(.xit, .{ .hash = hash_kind }).DB;
}

// the email between a commit author line's angle brackets, or null
pub fn authorEmail(author_line: []const u8) ?[]const u8 {
    const open_bracket = std.mem.indexOfScalar(u8, author_line, '<') orelse return null;
    const close_bracket = std.mem.indexOfScalarPos(u8, author_line, open_bracket + 1, '>') orelse return null;
    return author_line[open_bracket + 1 .. close_bracket];
}

// build a `T` by copying its fields, by name, out of `source`
pub fn project(comptime T: type, source: anytype) T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(result, field.name) = @field(source, field.name);
    }
    return result;
}

pub const EventKind = enum {
    user,
    repo,
    issue,
};

// a null payload deletes the record
pub const Event = union(EventKind) {
    user: ?User,
    repo: ?Repo,
    issue: ?Issue,
};

pub const EventWithId = struct {
    id: [event_id_size * 2]u8,
    event: Event,
    timestamp: u64 = 0, // not serialized, because it comes from the commit timestamp
    author_email: []const u8, // not serialized, because it goes in the commit author

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
        const json_event = try std.json.parseFromSliceLeaky(JsonEvent, arena.allocator(), message, .{ .ignore_unknown_fields = true });
        return .{
            .id = json_event.id,
            // unused when reading; the author lives in the commit
            .author_email = "",
            .event = switch (json_event.kind) {
                .user => .{
                    .user = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(User, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .repo => .{
                    .repo = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Repo, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .issue => .{
                    .issue = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Issue, arena.allocator(), value, .{ .ignore_unknown_fields = true })
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

// commit `events` (if any) as JSON commit messages on `ref`, then consume the
// events on `ref` into the db the repo's views read: the repo's own db for a
// xit repo, or the standalone event db next to a git repo. for a xit repo the
// commits and the consume run in one transaction.
pub fn consume(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    ref: rf.Ref,
    events: []const EventWithId,
) !void {
    // a branch that only exists on a remote is consumed from its remote-tracking
    // ref, while commits go on the local branch, continuing from the remote tip
    // so a cloned repo's local branch stays connected to the server history
    const resolved_ref: rf.Ref, const first_parent_oids: ?[1][hash.hexLen(repo_opts.hash)]u8 = blk: {
        if (null != try repo.readRef(io, ref)) break :blk .{ ref, null };
        var remotes = try repo.listRemotes(io, allocator);
        defer remotes.deinit();
        for (remotes.sections.keys()) |remote_name| {
            const remote_ref: rf.Ref = .{ .kind = .{ .remote = remote_name }, .name = ref.name };
            if (try repo.readRef(io, remote_ref)) |oid| {
                if (events.len > 0) break :blk .{ ref, .{oid} };
                break :blk .{ remote_ref, null };
            }
        }
        if (events.len > 0) break :blk .{ ref, null };
        // the branch is gone (or never existed): drop any db from a previous
        // sync rather than serving its issues indefinitely
        if (repo_kind == .git) try LocalEventDB(repo_opts.hash).delete(io, repo.core.repo_dir);
        return;
    };

    switch (repo_kind) {
        .git => {
            try commitEvents(.git, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, allocator, ref, events, first_parent_oids);

            var event_db = try LocalEventDB(repo_opts.hash).open(io, allocator, repo.core.repo_dir);
            defer event_db.deinit(io, allocator);

            try event_db.consume(repo_kind, repo_opts, io, allocator, repo, resolved_ref);
        },
        .xit => {
            const DB = rp.Repo(.xit, repo_opts).DB;
            const State = rp.Repo(.xit, repo_opts).State;

            const Ctx = struct {
                core: *rp.Repo(.xit, repo_opts).Core,
                io: std.Io,
                allocator: std.mem.Allocator,
                ref: rf.Ref,
                events: []const EventWithId,
                first_parent_oids: ?[1][hash.hexLen(repo_opts.hash)]u8,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

                    try commitEvents(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.ref, ctx.events, ctx.first_parent_oids);
                    if (!try consumeInTransaction(.xit, repo_opts, state.readOnly(), &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.ref)) return error.CancelTransaction;
                    try xit.undo.writeMessage(repo_opts, state, .{ .custom = "event" });

                    // fsync the chunk store, so any chunks written by the
                    // commits are durable before the transaction commits
                    try ctx.core.chunk_store_file.sync(ctx.io);
                }
            };

            try repo.core.db_file.lock(io, .exclusive);
            defer repo.core.db_file.unlock(io);

            const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
            history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
                .core = &repo.core,
                .io = io,
                .allocator = allocator,
                .ref = resolved_ref,
                .events = events,
                .first_parent_oids = first_parent_oids,
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => |e| return e,
            };
        },
    }
}

// commit each event as a JSON commit message on `ref` through `state`, so a
// xit repo can write them inside an already-open transaction
fn commitEvents(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    ref: rf.Ref,
    events: []const EventWithId,
    first_parent_oids: ?[1][hash.hexLen(repo_opts.hash)]u8,
) !void {
    var parent_oids: ?[]const [hash.hexLen(repo_opts.hash)]u8 = if (first_parent_oids) |*oids| oids else null;

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();

    for (events) |event| {
        json.clearRetainingCapacity();
        try std.json.Stringify.value(event, .{ .whitespace = .indent_2 }, &json.writer);
        if (json.written().len > max_event_size) return error.EventTooLarge;
        const author = try std.fmt.allocPrint(allocator, "haxy <{s}>", .{event.author_email});
        defer allocator.free(author);
        _ = try obj.writeCommit(repo_kind, repo_opts, state, io, allocator, .{ .author = author, .message = json.written(), .timestamp = event.timestamp, .parent_oids = parent_oids }, null, ref);
        // later events parent on the ref's new tip
        parent_oids = null;
    }
}

// serve a receive-pack and consume any events it pushed to the events branch,
// all in one transaction: the push and the views derived from it commit
// atomically, and a failed consume cancels the push
pub fn receivePackAndConsume(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: xit.net_server_receive_pack.Options,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const State = rp.Repo(.xit, repo_opts).State;

    const Ctx = struct {
        core: *rp.Repo(.xit, repo_opts).Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        options: xit.net_server_receive_pack.Options,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, ctx.options);
            try xit.undo.writeMessage(repo_opts, state, .push);

            // a repo without an events branch has no events to consume. a
            // no-op consume must not cancel here, since the push shares the
            // transaction and must commit regardless.
            if (null == try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = events_ref })) return;
            _ = try consumeInTransaction(.xit, repo_opts, state.readOnly(), &ctx.core.db, &moment, ctx.io, ctx.allocator, events_ref);
        }
    };

    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    history.appendContext(
        .{ .slot = try history.getSlot(-1) },
        Ctx{ .core = &repo.core, .io = io, .allocator = allocator, .reader = reader, .writer = writer, .options = options },
    ) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => |e| return e,
    };

    // pkt-line writes are buffered until the transaction settles, so the
    // report-status reaches the client only after the push truly committed
    try writer.flush();
}

// a standalone event db holding events consumed from a local repo's events
// branch. it lives inside the repo dir but is not part of the repo's own data,
// so viewing a repo never mutates it.
pub fn LocalEventDB(comptime hash_kind: hash.HashKind) type {
    return struct {
        file: std.Io.File,
        buffer: *std.Io.Writer.Allocating,
        db: *EventDB(hash_kind),

        const db_name = "haxy";
        const Self = @This();

        // open the db in `repo_dir` for writing, creating it if it doesn't exist
        pub fn open(io: std.Io, allocator: std.mem.Allocator, repo_dir: std.Io.Dir) !Self {
            const file = try repo_dir.createFile(io, db_name, .{ .truncate = false, .read = true, .lock = .exclusive });
            return fromFile(io, allocator, file);
        }

        // open the db in `repo_dir` for reading, or null if it doesn't exist
        pub fn openReadOnly(io: std.Io, allocator: std.mem.Allocator, repo_dir: std.Io.Dir) !?Self {
            const file = repo_dir.openFile(io, db_name, .{ .mode = .read_write, .lock = .shared }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            return try fromFile(io, allocator, file);
        }

        // remove the db from `repo_dir`, so a repo whose events branch
        // disappeared doesn't keep showing stale issues
        pub fn delete(io: std.Io, repo_dir: std.Io.Dir) !void {
            repo_dir.deleteFile(io, db_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        fn fromFile(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Self {
            errdefer file.close(io);

            const buffer = try allocator.create(std.Io.Writer.Allocating);
            errdefer allocator.destroy(buffer);
            buffer.* = std.Io.Writer.Allocating.init(allocator);
            errdefer buffer.deinit();

            const db = try allocator.create(EventDB(hash_kind));
            errdefer allocator.destroy(db);
            db.* = try EventDB(hash_kind).init(.{ .io = io, .file = file, .buffer = buffer });

            return .{ .file = file, .buffer = buffer, .db = db };
        }

        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            self.file.close(io);
            self.buffer.deinit();
            allocator.destroy(self.buffer);
            allocator.destroy(self.db);
        }

        // consume the events on `repo`'s `ref` into this db. the db must come
        // from `open`, whose handle holds the exclusive lock guarding the
        // transaction.
        pub fn consume(
            self: *Self,
            comptime repo_kind: rp.RepoKind,
            comptime repo_opts: rp.RepoOpts(repo_kind),
            io: std.Io,
            allocator: std.mem.Allocator,
            repo: *rp.Repo(repo_kind, repo_opts),
            ref: rf.Ref,
        ) !void {
            comptime if (repo_opts.hash != hash_kind) @compileError("the repo must use the db's hash kind");
            const DB = EventDB(hash_kind);

            const Ctx = struct {
                repo: *rp.Repo(repo_kind, repo_opts),
                db: *DB,
                io: std.Io,
                allocator: std.mem.Allocator,
                ref: rf.Ref,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    var repo_moment = try ctx.repo.core.latestMoment();
                    const read_state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &ctx.repo.core, .extra = .{ .moment = &repo_moment } };
                    if (!try consumeInTransaction(repo_kind, repo_opts, read_state, ctx.db, &moment, ctx.io, ctx.allocator, ctx.ref)) return error.CancelTransaction;
                }
            };

            const history = try DB.ArrayList(.read_write).init(self.db.rootCursor());
            history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
                .repo = repo,
                .db = self.db,
                .io = io,
                .allocator = allocator,
                .ref = ref,
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => |e| return e,
            };
        }
    };
}

// consume the events on `ref` into the db `moment` writes to, returning false
// if there was nothing to do. events are read from `read_state`'s repo, which
// needn't be the repo backing the db — that's how a local (possibly
// git-backed) repo's events land in a standalone db.
pub fn consumeInTransaction(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    read_state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    db: *EventDB(repo_opts.hash),
    moment: *EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    ref: rf.Ref,
) !bool {
    const DB = EventDB(repo_opts.hash);

    // the last_object_id represents the object id that was last consumed
    var last_object_id_maybe: ?[hash.byteLen(repo_opts.hash)]u8 = null;
    if (try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id"))) |last_object_id_cursor| {
        var last_object_id_buffer: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try last_object_id_cursor.readBytes(&last_object_id_buffer);
        last_object_id_maybe = last_object_id_buffer;
    }

    // the tip was already consumed, so there is nothing to do
    if (last_object_id_maybe) |*last_object_id| {
        const tip_hex = (try rf.readRecur(repo_kind, repo_opts, read_state, io, .{ .ref = ref })) orelse return error.OidNotFound;
        var tip: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try std.fmt.hexToBytes(&tip, &tip_hex);
        if (std.mem.eql(u8, last_object_id, &tip)) return false;
    }

    // the list with all of haxy's state, including materialized views.
    // the reason it is a list is so we can keep every previous haxy
    // state, making it easy to revert to an older state if the user
    // rebases some of the past commits.
    const haxy_cursor = try moment.putCursor(hash.hashInt(repo_opts.hash, "haxy"));
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

    var commit_iter = try CommitIterator(repo_kind, repo_opts).init(read_state, io, allocator, haxy_moments.readOnly(), ref);
    defer commit_iter.deinit(io, allocator);

    // if there are no events to process, look at the oid at HEAD and update
    // the last_object_id to point to it. this is important in situations
    // where we do a merge and then force-push to remove the merge. see the
    // merge test for an example.
    if (commit_iter.newest_object_id == null) {
        const head_oid_hex = (try rf.readRecur(repo_kind, repo_opts, read_state, io, .{ .ref = ref })) orelse return error.OidNotFound;
        var head_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
        _ = try std.fmt.hexToBytes(&head_oid, &head_oid_hex);

        const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &head_oid)) orelse return error.CursorNotFound;
        const haxy_moment = try DB.HashMap(.read_only).init(haxy_moment_cursor);

        const moment_index_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "moment-index")) orelse return error.CursorNotFound;
        const moment_index = try moment_index_cursor.readUint();

        try haxy.slice(moment_index + 1);
        try moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = &head_oid });
        return true;
    }

    // if this branch was rebased and force pushed, we need to detect that and
    // properly revert the haxy state to the last valid state. we detect this
    // by simply asking if the last event is a descendent of the last event
    // we consumed. if it isn't, then we know the haxy state needs to be reverted.
    if (last_object_id_maybe) |*last_object_id| {
        var is_rebased = false;
        const newest_object_id = commit_iter.newest_object_id orelse return error.OidNotFound;

        _ = mrg.getDescendent(
            repo_kind,
            repo_opts,
            read_state,
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
            var oldest_object = try obj.Object(repo_kind, repo_opts).init(read_state, io, allocator, &std.fmt.bytesToHex(oldest_object_id, .lower));
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
        var commit_object = try obj.Object(repo_kind, repo_opts).init(read_state, io, allocator, &std.fmt.bytesToHex(repo_event_oid, .lower));
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
        // ancestor is the baseline, so a later parent only contributes records
        // it changed relative to the merge base. only the record maps are
        // merged; every other view is derived from them, and each kind's
        // `consume` re-derives its own as the winning records are written.
        if (parent_oids.len > 1) {
            for (parent_oids[1..]) |*parent_oid| {
                var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try std.fmt.hexToBytes(&oid, parent_oid);

                const parent_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &oid)) orelse return error.CursorNotFound;
                const parent_haxy_moment = try DB.HashMap(.read_only).init(parent_haxy_moment_cursor);

                const baseline_oid_hex = try mrg.commonAncestor(repo_kind, repo_opts, read_state, io, allocator, &parent_oids[0], parent_oid);
                var baseline_oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                _ = try std.fmt.hexToBytes(&baseline_oid, &baseline_oid_hex);
                const baseline_haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &baseline_oid)) orelse return error.CursorNotFound;
                const baseline_haxy_moment = try DB.HashMap(.read_only).init(baseline_haxy_moment_cursor);

                inline for (std.meta.fields(Event)) |field| {
                    const T = @typeInfo(field.type).optional.child;
                    try merge(T, DB, repo_opts.hash, allocator, haxy_moment, parent_haxy_moment, baseline_haxy_moment);
                }
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
            var message: std.ArrayList(u8) = .empty;
            try commit_object.readMessage(arena.allocator(), &message, .limited(max_event_size));

            const event_with_id = try EventWithId.fromString(&arena, message.items);

            // get the id of the current event as bytes
            var current_event_id: [event_id_size]u8 = undefined;
            _ = try std.fmt.hexToBytes(&current_event_id, &event_with_id.id);

            // wrap the payload into the record `consume` stores, with its
            // commit-derived fields; on update, `consume` preserves the
            // existing record's
            const created_ts = commit_object.content.commit.metadata.timestamp;
            switch (event_with_id.event) {
                .user => |event_maybe| {
                    const record_maybe: ?User.Record = if (event_maybe) |event| .{ .event = event, .created_ts = created_ts } else null;
                    try User.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .repo => |event_maybe| {
                    const record_maybe: ?Repo.Record = if (event_maybe) |event| .{ .event = event, .created_ts = created_ts } else null;
                    try Repo.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .issue => |event_maybe| {
                    const record_maybe: ?Issue.Record = if (event_maybe) |event| .{
                        .event = event,
                        .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                        .created_ts = created_ts,
                    } else null;
                    try Issue.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
            }
        }

        // the current object id is now the last one
        last_object_id_maybe = repo_event_oid;

        // prevent any of the data created above from being mutated by future iterations of this loop
        try db.freeze();
    }

    if (last_object_id_maybe) |*last_object_id| {
        try moment.put(hash.hashInt(repo_opts.hash, "haxy-last-object-id"), .{ .bytes = last_object_id });
    }

    return true;
}

// the conflicted records of one kind, keyed by the same order key its id set
// uses, so this doubles as the index the conflicts view lists and counts. every
// value under an entry is a slot reference to a structure that already exists:
//
//   <order key> -> conflict entry
//     conflicted-fields        the conflicting field names, space separated
//     base-record              the merge base's whole record
//     their-record             the merged-in side's whole record
//     their-field->oid         that side's field name to commit map
//
// our own value is the live record and our commit is in the kind's oid map, so
// neither is repeated here.
pub const conflicted_fields_key = "conflicted-fields";
pub const base_record_key = "base-record";
pub const their_record_key = "their-record";
pub const their_field_to_oid_key = "their-field->oid";

// record the commit against every field this event changes. a merge passes no
// oid, since each field's winner may come from a different side.
pub fn writeOid(
    comptime T: type,
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    id_to_field_to_oid: DB.HashMap(.read_write),
    record_key: hash.HashInt(hash_kind),
    existing_maybe: ?T,
    event: T,
    event_oid: ?[]const u8,
) !void {
    const oid = event_oid orelse return;

    // created only once a field actually changes
    var field_oids: ?DB.SortedMap(.read_write) = null;

    inline for (std.meta.fields(T)) |field| {
        const changed = if (existing_maybe) |existing|
            !fieldEqual(field.type, @field(existing, field.name), @field(event, field.name))
        else
            true;
        if (changed) {
            if (field_oids == null) {
                field_oids = try DB.SortedMap(.read_write).init(try id_to_field_to_oid.putCursor(record_key));
            }
            if (field_oids) |map| try map.put(field.name, .{ .bytes = oid });
        }
    }
}

// the whole field list, space separated, is the longest it can get
fn conflictedFieldsMaxLen(comptime T: type) usize {
    var len: usize = 0;
    for (std.meta.fields(T)) |field| len += field.name.len + 1;
    return len;
}

// what a three-way merge did with a field
const FieldMerge = enum {
    // the target's value stands, because neither side changed it, both made the
    // same change, or only the target changed it
    kept,
    parent,
    conflicted,
};

// three-way merge each field. one only the parent changed takes the parent's
// value; one both sides changed differently keeps the target's. a missing
// baseline makes every differing field a conflict.
fn mergeFields(
    comptime T: type,
    baseline_maybe: ?T,
    target: T,
    parent: T,
    outcome: *[std.meta.fields(T).len]FieldMerge,
) T {
    var merged = target;

    inline for (std.meta.fields(T), 0..) |field, i| {
        const target_value = @field(target, field.name);
        const parent_value = @field(parent, field.name);

        if (!fieldEqual(field.type, target_value, parent_value)) {
            outcome[i] = if (baseline_maybe) |baseline| blk: {
                const baseline_value = @field(baseline, field.name);
                if (fieldEqual(field.type, target_value, baseline_value)) {
                    @field(merged, field.name) = parent_value;
                    break :blk .parent;
                }
                // only the target changed it
                if (fieldEqual(field.type, parent_value, baseline_value)) break :blk .kept;
                break :blk .conflicted;
            } else .conflicted;
        }
    }

    return merged;
}

// three-way merge of one kind's records from a merge parent, field by field, so
// sides editing different fields combine cleanly. the result goes through the
// kind's `consume`, which re-derives the indexes from it. a field both sides
// changed differently keeps the target's value and records a conflict entry. a
// deletion carries over unless the other side changed the record, so a merge
// never fails.
pub fn merge(
    comptime T: type,
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    allocator: std.mem.Allocator,
    haxy_moment: DB.HashMap(.read_write),
    parent_moment: DB.HashMap(.read_only),
    baseline_moment: DB.HashMap(.read_only),
) !void {
    const parent_set_cursor = try parent_moment.getCursor(hash.hashInt(hash_kind, T.id_set_key)) orelse return;
    const parent_set = try DB.SortedSet(.read_only).init(parent_set_cursor);

    const parent_records_cursor = try parent_moment.getCursor(hash.hashInt(hash_kind, T.record_map_key)) orelse return;
    const parent_records = try DB.HashMap(.read_only).init(parent_records_cursor);

    var baseline_records: ?DB.HashMap(.read_only) = null;
    if (try baseline_moment.getCursor(hash.hashInt(hash_kind, T.record_map_key))) |cursor| {
        baseline_records = try DB.HashMap(.read_only).init(cursor);
    }

    var parent_conflicts: ?DB.SortedMap(.read_only) = null;
    if (try parent_moment.getCursor(hash.hashInt(hash_kind, T.conflicts_key))) |cursor| {
        parent_conflicts = try DB.SortedMap(.read_only).init(cursor);
    }

    var baseline_conflicts: ?DB.SortedMap(.read_only) = null;
    if (try baseline_moment.getCursor(hash.hashInt(hash_kind, T.conflicts_key))) |cursor| {
        baseline_conflicts = try DB.SortedMap(.read_only).init(cursor);
    }

    var parent_id_to_field_to_oid: ?DB.HashMap(.read_only) = null;
    if (try parent_moment.getCursor(hash.hashInt(hash_kind, T.id_to_field_to_oid_key))) |cursor| {
        parent_id_to_field_to_oid = try DB.HashMap(.read_only).init(cursor);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a record the parent deleted is deleted here too, unless the target
    // changed it. runs first so a delete and recreate is applied in that order.
    deletions: {
        const baseline_map = baseline_records orelse break :deletions;
        const baseline_set_cursor = try baseline_moment.getCursor(hash.hashInt(hash_kind, T.id_set_key)) orelse break :deletions;
        const baseline_set = try DB.SortedSet(.read_only).init(baseline_set_cursor);

        var baseline_iter = try baseline_set.iteratorFromIndex(0);
        while (try baseline_iter.next()) |kv_pair_cursor| {
            const event_id = try readOrderKeyId(DB, kv_pair_cursor);
            const record_key = hash.hashInt(hash_kind, &event_id);

            if (null != try parent_records.getSlot(record_key)) continue;
            const baseline_record_cursor = try baseline_map.getCursor(record_key) orelse continue;

            _ = arena.reset(.retain_capacity);

            // re-derived every iteration, since `consume` writes through its
            // own handles
            const target_records_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.record_map_key));
            const target_records = try DB.HashMap(.read_write).init(target_records_cursor);
            const target_record_cursor = try target_records.getCursor(record_key) orelse continue;

            if (!target_record_cursor.slot().eql(baseline_record_cursor.slot())) {
                // every write copies the record's block, so only a content
                // change means the target kept it
                const target_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(target_record_cursor));
                const baseline_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(baseline_record_cursor));
                if (!fieldsEqual(T, target_record.event, baseline_record.event)) continue;
            }

            try T.consume(DB, hash_kind, haxy_moment, &event_id, null, &arena, null);
        }
    }

    var iter = try parent_set.iteratorFromIndex(0);
    while (try iter.next()) |kv_pair_cursor| {
        const event_id = try readOrderKeyId(DB, kv_pair_cursor);
        const record_key = hash.hashInt(hash_kind, &event_id);

        _ = arena.reset(.retain_capacity);

        const parent_record_cursor = try parent_records.getCursor(record_key) orelse continue;
        const parent_slot = parent_record_cursor.slot();
        const baseline_slot = if (baseline_records) |map| try map.getSlot(record_key) else null;

        // the parent left this record alone
        if (baseline_slot) |slot| {
            if (slot.eql(parent_slot)) continue;
        }

        const parent_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(parent_record_cursor));

        // re-derived every iteration, since `consume` writes through its own
        // handles
        const target_records_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.record_map_key));
        const target_records = try DB.HashMap(.read_write).init(target_records_cursor);

        // a record the target doesn't have, or deleted, arrives wholesale from
        // the parent
        var outcome: [std.meta.fields(T).len]FieldMerge = @splat(.parent);
        var merged = parent_record;

        if (try target_records.getCursor(record_key)) |target_record_cursor| {
            // both sides share the change
            if (target_record_cursor.slot().eql(parent_slot)) continue;

            const target_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(target_record_cursor));

            var baseline_event: ?T = null;
            if (baseline_records) |map| {
                if (try map.getCursor(record_key)) |baseline_record_cursor| {
                    baseline_event = (try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(baseline_record_cursor))).event;
                }
            }

            outcome = @splat(.kept);
            merged = target_record;
            merged.event = mergeFields(T, baseline_event, target_record.event, parent_record.event, &outcome);
        }

        // the index is unique, so a key the target gave to a different record
        // leaves this one out rather than stranding that one behind a name it
        // no longer owns
        if (@hasDecl(T, "name_index_key")) {
            const index_key = try merged.indexKey(arena.allocator());
            const name_index_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.name_index_key));
            const name_index = try DB.HashMap(.read_write).init(name_index_cursor);
            if (try name_index.getCursor(hash.hashInt(hash_kind, index_key))) |owner_cursor| {
                var owner_id: [event_id_size]u8 = undefined;
                _ = try owner_cursor.readBytes(&owner_id);
                if (!std.mem.eql(u8, &owner_id, &event_id)) continue;
            }
        }

        // `consume` sets no oids, since each field's winner may come from
        // a different side
        try T.consume(DB, hash_kind, haxy_moment, &event_id, merged, &arena, null);

        const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.conflicts_key));
        const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);
        const id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.id_to_field_to_oid_key));
        const id_to_field_to_oid = try DB.HashMap(.read_write).init(id_to_field_to_oid_cursor);
        const merged_key = orderKeyDesc(merged.created_ts, &event_id);

        // both created only once a field actually comes from the parent
        var parent_field_oids: ?DB.SortedMap(.read_only) = null;
        if (parent_id_to_field_to_oid) |map| {
            if (try map.getCursor(record_key)) |field_oids_cursor| {
                parent_field_oids = try DB.SortedMap(.read_only).init(field_oids_cursor);
            }
        }
        var field_oids: ?DB.SortedMap(.read_write) = null;

        // the fields both sides changed differently, space separated
        var conflicted_fields: [conflictedFieldsMaxLen(T)]u8 = undefined;
        var conflicted_len: usize = 0;

        inline for (std.meta.fields(T), 0..) |field, i| {
            switch (outcome[i]) {
                // the target's value stands, so its oid does too
                .kept => {},
                .parent => if (parent_field_oids) |parent_map| {
                    if (try parent_map.getCursor(field.name)) |oid_cursor| {
                        if (field_oids == null) {
                            field_oids = try DB.SortedMap(.read_write).init(try id_to_field_to_oid.putCursor(record_key));
                        }
                        if (field_oids) |map| try map.put(field.name, .{ .slot = oid_cursor.slot() });
                    }
                },
                .conflicted => {
                    if (conflicted_len > 0) {
                        conflicted_fields[conflicted_len] = ' ';
                        conflicted_len += 1;
                    }
                    @memcpy(conflicted_fields[conflicted_len..][0..field.name.len], field.name);
                    conflicted_len += field.name.len;
                },
            }
        }

        if (conflicted_len > 0) {
            // each side's whole record is stored by reference, so the view can
            // show any of them or take theirs wholesale
            _ = try conflicts.remove(&merged_key);
            const conflict = try DB.HashMap(.read_write).init(try conflicts.putCursor(&merged_key));
            try conflict.put(hash.hashInt(hash_kind, conflicted_fields_key), .{ .bytes = conflicted_fields[0..conflicted_len] });
            try conflict.put(hash.hashInt(hash_kind, base_record_key), .{ .slot = baseline_slot });
            try conflict.put(hash.hashInt(hash_kind, their_record_key), .{ .slot = parent_slot });
            if (parent_field_oids) |map| {
                try conflict.put(hash.hashInt(hash_kind, their_field_to_oid_key), .{ .slot = map.slot() });
            }
            continue;
        }

        // created_ts never changes, so the parent keys this record's conflict
        // identically, and it carries over when the target has none, unless the
        // parent's entry is unchanged from the baseline, meaning the target
        // inherited it too and resolving it removed it here.
        if (parent_conflicts) |map| {
            if (null == try conflicts.getCursor(&merged_key)) {
                if (try map.getSlot(&merged_key)) |conflict_slot| {
                    const baseline_conflict_slot = if (baseline_conflicts) |baseline_map| try baseline_map.getSlot(&merged_key) else null;
                    const resolved = if (baseline_conflict_slot) |slot| slot.eql(conflict_slot) else false;
                    if (!resolved) try conflicts.put(&merged_key, .{ .slot = conflict_slot });
                }
            }
        }
    }
}

pub fn currentMoment(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
) !rp.Repo(.xit, repo_opts).DB.HashMap(.read_only) {
    return currentMomentFromDb(repo_opts.hash, &repo.core.db);
}

// the oid of the last event commit consumed into `db`, or null before any
// consume completed
fn lastConsumedOid(
    comptime hash_kind: hash.HashKind,
    db: *EventDB(hash_kind),
) !?[hash.byteLen(hash_kind)]u8 {
    const DB = EventDB(hash_kind);
    const history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
    const moment_cursor = try history.getCursor(-1) orelse return null;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);
    const last_object_id_cursor = try moment.getCursor(hash.hashInt(hash_kind, "haxy-last-object-id")) orelse return null;
    var last_object_id: [hash.byteLen(hash_kind)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);
    return last_object_id;
}

pub fn currentMomentFromDb(
    comptime hash_kind: hash.HashKind,
    db: *EventDB(hash_kind),
) !EventDB(hash_kind).HashMap(.read_only) {
    const DB = EventDB(hash_kind);
    const last_object_id = (try lastConsumedOid(hash_kind, db)) orelse return error.NotFound;
    const history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
    const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);
    const haxy_cursor = try moment.getCursor(hash.hashInt(hash_kind, "haxy")) orelse return error.NotFound;
    const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);
    const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
    const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);
    const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(hash_kind, &last_object_id)) orelse return error.NotFound;
    return try DB.HashMap(.read_only).init(haxy_moment_cursor);
}

// build the key for SortedSets sorted by timestamp. the big-endian timestamp
// makes byte order match creation order; the event id breaks ties and keeps
// keys unique within the same timestamp.
pub fn orderKey(timestamp: u64, event_id: *const [event_id_size]u8) [@sizeOf(u64) + event_id_size]u8 {
    var key: [@sizeOf(u64) + event_id_size]u8 = undefined;
    std.mem.writeInt(u64, key[0..@sizeOf(u64)], timestamp, .big);
    @memcpy(key[@sizeOf(u64)..], event_id);
    return key;
}

pub fn orderKeyDesc(timestamp: u64, event_id: *const [event_id_size]u8) [@sizeOf(u64) + event_id_size]u8 {
    return orderKey(std.math.maxInt(u64) - timestamp, event_id);
}

// the event id embedded in a set entry's order key
pub fn readOrderKeyId(comptime DB: type, kv_pair_cursor: DB.Cursor(.read_only)) ![event_id_size]u8 {
    var cursor = kv_pair_cursor;
    const kv_pair = try cursor.readKeyValuePair();
    var order_key: [@sizeOf(u64) + event_id_size]u8 = undefined;
    _ = try kv_pair.key_cursor.readBytes(&order_key);
    return order_key[@sizeOf(u64)..][0..event_id_size].*;
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

    const owner = (try User.readById(AdminDB, admin_repo_opts.hash, moment, &arena, &owner_user_id)) orelse unreachable;

    var id_bytes: [event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    try consume(.xit, admin_repo_opts, io, allocator, &repo, events_ref, &[_]EventWithId{.{
        .id = event_id_hex,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author_email = owner.event.email,
        .event = .{ .repo = .{
            .user_id = &owner_user_id,
            .name = repo_name,
            .description = "",
        } },
    }});

    return event_id_hex;
}

//
// reading from xitdb
//

// a struct field's fields share its container's map, so their names must not
// collide with the container's or two fields would silently share a key
fn validateFlattenedFields(comptime T: type) void {
    comptime {
        for (std.meta.fields(T)) |field| {
            if (@typeInfo(field.type) != .@"struct") continue;
            for (std.meta.fields(field.type)) |nested| {
                if (@hasField(T, nested.name))
                    @compileError("flattened field name collision in " ++ @typeName(T) ++ ": " ++ nested.name);
            }
        }
    }
}

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
            comptime validateFlattenedFields(T);
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
                    .@"enum" => {
                        const bytes = try readBytes(DB, hash_kind, arena.allocator(), map, field.name);
                        @field(event, field.name) = std.meta.stringToEnum(field.type, bytes) orelse return error.InvalidEnumTag;
                    },
                    .optional => |optional_info| {
                        if (optional_info.child != []const u8) @compileError("unsupported read field type: " ++ @typeName(field.type));
                        // a missing key is null
                        @field(event, field.name) = if (try map.getCursor(hash.hashInt(hash_kind, field.name))) |cursor|
                            try cursor.readBytesAlloc(arena.allocator(), null)
                        else
                            null;
                    },
                    // a struct field's own fields are read from the same map
                    .@"struct" => @field(event, field.name) = try read(field.type, DB, hash_kind, arena, map),
                    else => @compileError("unsupported read field type: " ++ @typeName(field.type)),
                }
            }
        },
        else => @compileError("read expects a struct"),
    }

    return event;
}

// whether two events carry the same data
fn fieldsEqual(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (!fieldEqual(field.type, @field(a, field.name), @field(b, field.name))) return false;
            }
        },
        else => @compileError("fieldsEqual expects a struct"),
    }

    return true;
}

pub fn fieldEqual(comptime Field: type, a: Field, b: Field) bool {
    switch (@typeInfo(Field)) {
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                return std.mem.eql(u8, a, b);
            } else {
                @compileError("unsupported field type: " ++ @typeName(Field));
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                return std.mem.eql(u8, &a, &b);
            } else {
                @compileError("unsupported field type: " ++ @typeName(Field));
            }
        },
        .bool, .int, .@"enum" => return a == b,
        else => @compileError("unsupported field type: " ++ @typeName(Field)),
    }
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
            comptime validateFlattenedFields(T);
            inline for (struct_info.fields) |field| {
                try upsertField(DB, hash_kind, map, field.name, field.type, @field(event, field.name));
            }
        },
        else => @compileError("upsert expects a struct"),
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
        .@"enum" => try upsertBytes(DB, hash_kind, map, key, @tagName(value)),
        .optional => |optional_info| {
            if (optional_info.child != []const u8) @compileError("unsupported upsert field type: " ++ @typeName(Field));
            // a missing key is null
            if (value) |bytes| {
                try upsertBytes(DB, hash_kind, map, key, bytes);
            } else {
                _ = try map.remove(key);
            }
        },
        // a struct field's own fields are stored in the same map
        .@"struct" => try upsert(Field, DB, hash_kind, map, value),
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

pub fn CommitIterator(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind)) type {
    return struct {
        const DB = EventDB(repo_opts.hash);
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
            state: rp.Repo(repo_kind, repo_opts).State(.read_only),
            io: std.Io,
            allocator: std.mem.Allocator,
            consumed_object_ids: DB.HashMap(.read_only),
            ref: rf.Ref,
        ) !CommitIterator(repo_kind, repo_opts) {
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
            // the db is scratch state that gets deleted after iteration, so
            // there is nothing worth fsyncing
            db_ptr.* = try DB.init(.{ .io = io, .file = db_file, .buffer = buffer_ptr, .fsync = false });

            const map = try DB.HashMap(.read_write).init(db_ptr.rootCursor());

            const parent_to_children_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "parent->children"));
            const parent_to_children = try DB.HashMap(.read_write).init(parent_to_children_cursor);

            const child_to_pending_parents_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "child->pending-parents"));
            const child_to_pending_parents = try DB.HashMap(.read_write).init(child_to_pending_parents_cursor);

            const ready_queue_cursor = try map.putCursor(hash.hashInt(repo_opts.hash, "ready-queue"));
            const ready_queue = try DB.ArrayList(.read_write).init(ready_queue_cursor);

            var self = CommitIterator(repo_kind, repo_opts){
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

        pub fn deinit(self: *CommitIterator(repo_kind, repo_opts), io: std.Io, allocator: std.mem.Allocator) void {
            self.db_file.close(io);
            self.db.core.memory.buffer.deinit();
            allocator.destroy(self.db.core.memory.buffer);
            self.repo_dir.deleteFile(io, db_name) catch {};
            allocator.destroy(self.db);
        }

        pub fn next(self: *CommitIterator(repo_kind, repo_opts)) !?[hash.byteLen(repo_opts.hash)]u8 {
            if (self.ready_queue_index >= try self.ready_queue.count()) return null;

            const oid = try readOidFromList(self.ready_queue.readOnly(), self.ready_queue_index);
            self.ready_queue_index += 1;

            try self.enqueueChildren(&oid);
            return oid;
        }

        fn collect(
            self: *CommitIterator(repo_kind, repo_opts),
            state: rp.Repo(repo_kind, repo_opts).State(.read_only),
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

            const head_oid_hex = (try rf.readRecur(repo_kind, repo_opts, state, io, .{ .ref = ref })) orelse return error.OidNotFound;
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

                var commit_object = try obj.Object(repo_kind, repo_opts).init(state, io, allocator, &std.fmt.bytesToHex(oid, .lower));
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

        fn enqueueChildren(self: *CommitIterator(repo_kind, repo_opts), oid: *const [hash.byteLen(repo_opts.hash)]u8) !void {
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

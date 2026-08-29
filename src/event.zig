const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;
const obj = xit.object;
const rf = xit.ref;
const pch = @import("patch.zig");

pub const User = @import("event/User.zig");
pub const Repo = @import("event/Repo.zig");
pub const Fork = @import("event/Fork.zig");
pub const Issue = @import("event/Issue.zig");
pub const Discussion = @import("event/Discussion.zig");
pub const Comment = @import("event/Comment.zig");
pub const Attachment = @import("event/Attachment.zig");
pub const Patch = @import("event/Patch.zig");
pub const PatchRev = @import("event/PatchRev.zig");

// the most bytes an event's serialized form may hold
pub const max_event_size: usize = 100 * 1024;

// the branch haxy events are committed to before being consumed
pub const events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/events" };

pub const materialized_key = "haxy";
pub const last_object_id_key = "haxy-last-object-id";

// options + db type for the admin repo
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
    fork,
    issue,
    discuss,
    comment,
    attach,
    patchrev,
    patch,
};

pub const RepoRole = enum {
    admin,
    repo,
    fork,

    fn allows(self: RepoRole, kind: EventKind) bool {
        return switch (self) {
            .admin => switch (kind) {
                .user, .repo, .fork => true,
                else => false,
            },
            .repo => switch (kind) {
                .issue, .discuss, .comment, .attach, .patchrev, .patch => true,
                else => false,
            },
            .fork => switch (kind) {
                .patchrev, .patch => true,
                else => false,
            },
        };
    }
};

// every logical event's kind and creation-ordered active/removed id sets
pub const event_index_key = "event-id->kind";
pub const active_event_id_set_key = "active-event-id-set";
pub const removed_event_id_set_key = "removed-event-id-set";
const event_order_key = "event-order";

// a null payload removes the record
pub const Event = union(EventKind) {
    user: ?User,
    repo: ?Repo,
    fork: ?Fork,
    issue: ?Issue,
    discuss: ?Discussion,
    comment: ?Comment,
    attach: ?Attachment,
    patchrev: ?PatchRev,
    patch: ?Patch,
};

// a file committed alongside its event
pub const Blob = struct {
    name: []const u8,
    size: u64,
    reader: *std.Io.Reader,
};

// an entry in the fresh tree carried by one event commit
pub const EventTreeEntry = union(enum) {
    blob: Blob,
    tree: struct {
        name: []const u8,
        oid: []const u8,
    },
};

// who a commit is attributed to
pub const CommitAuthor = struct {
    name: []const u8,
    email: []const u8,
};

pub const event_id_size: usize = 16;

pub fn parseEventId(id: []const u8) ![event_id_size]u8 {
    var bytes: [event_id_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, id);
    if (!std.mem.eql(u8, id, &std.fmt.bytesToHex(bytes, .lower))) return error.InvalidEventId;
    return bytes;
}

pub const EventWithId = struct {
    id: [event_id_size * 2]u8,
    event: Event,
    timestamp: u64 = 0, // not serialized, because it comes from the commit timestamp
    author: CommitAuthor, // not serialized, because it goes in the commit author line
    tree_entries: []const EventTreeEntry = &.{}, // not serialized, because they go in the commit tree

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
            .author = .{ .name = "", .email = "" },
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
                .fork => .{
                    .fork = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Fork, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .issue => .{
                    .issue = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Issue, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .discuss => .{
                    .discuss = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Discussion, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .comment => .{
                    .comment = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Comment, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .attach => .{
                    .attach = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Attachment, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .patch => .{
                    .patch = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(Patch, arena.allocator(), value, .{ .ignore_unknown_fields = true })
                    else
                        null,
                },
                .patchrev => .{
                    .patchrev = if (json_event.data) |value|
                        try std.json.parseFromValueLeaky(PatchRev, arena.allocator(), value, .{ .ignore_unknown_fields = true })
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

// remove an event by emitting a null payload
pub fn remove(
    comptime role: RepoRole,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [event_id_size]u8,
    kind: EventKind,
    author: CommitAuthor,
) !void {
    const DB = EventDB(repo_opts.hash);
    var event_db_maybe: ?LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return error.EventNotFound
    else
        currentMoment(repo_opts, repo)) catch return error.EventNotFound;
    const kind_map_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, event_index_key)) orelse return error.EventNotFound;
    const kind_map = try DB.HashMap(.read_only).init(kind_map_cursor);
    const stored_kind = (try readEventKind(repo_opts.hash, kind_map, id)) orelse return error.EventNotFound;
    if (stored_kind != kind) return error.EventNotFound;
    if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    event_db_maybe = null;

    const event: Event = switch (kind) {
        .user => .{ .user = null },
        .repo => .{ .repo = null },
        .fork => .{ .fork = null },
        .issue => .{ .issue = null },
        .discuss => .{ .discuss = null },
        .comment => .{ .comment = null },
        .attach => .{ .attach = null },
        .patchrev => .{ .patchrev = null },
        .patch => .{ .patch = null },
    };
    try consume(role, repo_kind, repo_opts, io, allocator, repo, events_ref, &.{.{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = event,
    }});
}

// commit `events` (if any) as JSON commit messages on `ref`, then consume the
// events on `ref` into the db the repo's views read: the repo's own db for a
// xit repo, or the standalone event db next to a git repo. for a xit repo the
// commits and the consume run in one transaction.
pub fn consume(
    comptime role: RepoRole,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    ref: rf.Ref,
    events: []const EventWithId,
) !void {
    for (events) |event| {
        if (!role.allows(std.meta.activeTag(event.event))) return error.EventKindNotAllowed;
    }

    var resolved_remote_name: ?[]u8 = null;
    defer if (resolved_remote_name) |name| allocator.free(name);

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
                const name = try allocator.dupe(u8, remote_name);
                resolved_remote_name = name;
                break :blk .{ rf.Ref{ .kind = .{ .remote = name }, .name = ref.name }, null };
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
                    if (!try consumeInTransaction(role, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.ref)) return error.CancelTransaction;
                    try xit.undo.writeMessage(repo_opts, state, .{ .custom = "event" });
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

// merge the remote events ref into the local events ref without touching head,
// the index, or the worktree
pub fn mergeEvents(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    remote_ref: rf.Ref,
) !void {
    switch (repo_kind) {
        .git => _ = try mergeEventsInTransaction(.git, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, allocator, remote_ref),
        .xit => {
            const DB = rp.Repo(.xit, repo_opts).DB;
            const State = rp.Repo(.xit, repo_opts).State;

            const Ctx = struct {
                core: *rp.Repo(.xit, repo_opts).Core,
                io: std.Io,
                allocator: std.mem.Allocator,
                remote_ref: rf.Ref,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                    if (!try mergeEventsInTransaction(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.remote_ref)) return error.CancelTransaction;
                    try xit.undo.writeMessage(repo_opts, state, .{ .custom = "event" });
                }
            };

            try repo.core.db_file.lock(io, .exclusive);
            defer repo.core.db_file.unlock(io);

            const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
            history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
                .core = &repo.core,
                .io = io,
                .allocator = allocator,
                .remote_ref = remote_ref,
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => |e| return e,
            };
        },
    }
}

fn mergeEventsInTransaction(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    remote_ref: rf.Ref,
) !bool {
    const remote_oid = (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = remote_ref })) orelse return false;
    const local_oid_maybe = try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = events_ref });

    var ref_path_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const ref_path = try events_ref.toPath(&ref_path_buffer);
    const local_oid = local_oid_maybe orelse {
        try rf.write(repo_kind, repo_opts, state, io, ref_path, .{ .oid = &remote_oid });
        return true;
    };
    if (std.mem.eql(u8, &local_oid, &remote_oid)) return false;

    const ancestor_maybe: ?[hash.hexLen(repo_opts.hash)]u8 = mrg.commonAncestor(repo_kind, repo_opts, state.readOnly(), io, allocator, &local_oid, &remote_oid) catch |err| switch (err) {
        error.NoCommonAncestor => null,
        else => return err,
    };
    if (ancestor_maybe) |ancestor| {
        if (std.mem.eql(u8, &ancestor, &remote_oid)) return false;
        if (std.mem.eql(u8, &ancestor, &local_oid)) {
            try rf.write(repo_kind, repo_opts, state, io, ref_path, .{ .oid = &remote_oid });
            return true;
        }
    }

    const parent_oids = [_][hash.hexLen(repo_opts.hash)]u8{ local_oid, remote_oid };
    var tree = try obj.Tree.init(allocator);
    defer tree.deinit();
    _ = try obj.writeCommit(repo_kind, repo_opts, state, io, allocator, .{
        .message = "merge events",
        .parent_oids = &parent_oids,
    }, &tree, events_ref);
    return true;
}

// the file an attach event carries: the one entry in its commit's tree. the
// name and oid are allocated in `arena`.
fn attachedFile(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    tree_oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !struct { name: []const u8, oid: []const u8 } {
    var tree_object = try obj.Object(repo_kind, repo_opts).init(state, io, allocator, tree_oid);
    defer tree_object.deinit();

    const entries = switch (tree_object.content) {
        .tree => |tree| tree.entries,
        else => return error.InvalidAttachment,
    };
    if (entries.count() != 1) return error.InvalidAttachment;
    const entry = entries.values()[0];
    if (entry.isTree()) return error.InvalidAttachment;
    const name = entries.keys()[0];
    if (!Attachment.nameValid(name)) return error.InvalidAttachment;

    const oid = std.fmt.bytesToHex(entry.oid, .lower);
    var object_reader = try obj.ObjectReader(repo_kind, repo_opts).init(state, io, allocator, &oid);
    defer object_reader.deinit();
    if (object_reader.header().kind != .blob) return error.InvalidAttachment;

    return .{
        .name = try arena.allocator().dupe(u8, name),
        .oid = try arena.allocator().dupe(u8, &oid),
    };
}

fn commitIdentity(line: []const u8) ![]const u8 {
    const close = std.mem.indexOfScalar(u8, line, '>') orelse return error.AuthorNotFound;
    return line[0 .. close + 1];
}

// commit each event as a JSON commit message on `ref` through `state`, so a
// xit repo can write them inside an already-open transaction
pub fn commitEvents(
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
        try std.json.Stringify.value(event, .{}, &json.writer);
        if (json.written().len > max_event_size) return error.EventTooLarge;
        const author = try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ event.author.name, event.author.email });
        defer allocator.free(author);

        // every event gets a fresh tree
        var tree = try obj.Tree.init(allocator);
        defer tree.deinit();
        for (event.tree_entries) |entry| {
            switch (entry) {
                .blob => |blob| {
                    var oid_bytes = [_]u8{0} ** hash.byteLen(repo_opts.hash);
                    try obj.writeObject(repo_kind, repo_opts, state, io, blob.reader, .{ .kind = .blob, .size = blob.size }, &oid_bytes);
                    try tree.addBlobEntry(.{ .content = .{ .unix_permission = 0o644, .object_type = .regular_file } }, blob.name, &oid_bytes);
                },
                .tree => |nested| {
                    var oid_bytes: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&oid_bytes, nested.oid);
                    if (!std.mem.eql(u8, nested.oid, &std.fmt.bytesToHex(oid_bytes, .lower))) return error.InvalidTreeObject;
                    try tree.addTreeEntry(nested.name, &oid_bytes);
                },
            }
        }

        _ = try obj.writeCommit(repo_kind, repo_opts, state, io, allocator, .{
            .author = author,
            .message = json.written(),
            .timestamp = event.timestamp,
            .parent_oids = parent_oids,
            .allow_empty = true,
        }, &tree, ref);
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
    repo_root_path: []const u8,
    error_writer: *std.Io.Writer,
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
        repo_root_path: []const u8,
        error_writer: *std.Io.Writer,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            var updates = xit.net_server_receive_pack.AppliedRefUpdates.init(ctx.allocator);
            defer updates.deinit();
            var receive_options = ctx.options;
            receive_options.applied_ref_updates = &updates;
            try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, receive_options);

            // a repo without an events branch has no events to consume. a
            // no-op consume must not cancel here, since the push shares the
            // transaction and must commit regardless.
            if (null != try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = events_ref })) {
                _ = try consumeInTransaction(.repo, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, events_ref);
                try pch.detectMerged(repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.repo_root_path, updates.items.items, ctx.error_writer);
            }
            try xit.undo.writeMessage(repo_opts, state, .push);
        }
    };

    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    history.appendContext(
        .{ .slot = try history.getSlot(-1) },
        Ctx{
            .core = &repo.core,
            .io = io,
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .options = options,
            .repo_root_path = repo_root_path,
            .error_writer = error_writer,
        },
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
                    const state = rp.Repo(repo_kind, repo_opts).State(.read_write){ .core = &ctx.repo.core, .extra = .{} };
                    if (!try consumeInTransaction(.repo, repo_kind, repo_opts, state, ctx.db, &moment, ctx.io, ctx.allocator, ctx.ref)) return error.CancelTransaction;
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
// if there was nothing to do. events are read from `state`'s repo, which
// needn't be the repo backing the db — that's how a local (possibly
// git-backed) repo's events land in a standalone db.
pub fn consumeInTransaction(
    comptime role: RepoRole,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_write),
    db: *EventDB(repo_opts.hash),
    moment: *EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    ref: rf.Ref,
) !bool {
    const DB = EventDB(repo_opts.hash);
    const read_state = state.readOnly();

    // the last_object_id represents the object id that was last consumed
    var last_object_id_maybe: ?[hash.byteLen(repo_opts.hash)]u8 = null;
    if (try moment.getCursor(hash.hashInt(repo_opts.hash, last_object_id_key))) |last_object_id_cursor| {
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
    const haxy_cursor = try moment.putCursor(hash.hashInt(repo_opts.hash, materialized_key));
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
        try moment.put(hash.hashInt(repo_opts.hash, last_object_id_key), .{ .bytes = &head_oid });
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

        // graph generation gives every event a causal order independent of
        // commit timestamps. concurrent events tie-break by id in their index.
        var event_order: u64 = 1;
        for (parent_oids) |*parent_oid| {
            var parent_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&parent_id, parent_oid);
            const parent_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &parent_id)) orelse return error.CursorNotFound;
            const parent = try DB.HashMap(.read_only).init(parent_cursor);
            const parent_order_cursor = try parent.getCursor(hash.hashInt(repo_opts.hash, event_order_key)) orelse return error.CursorNotFound;
            const parent_order = try parent_order_cursor.readUint();
            event_order = @max(event_order, parent_order +| 1);
        }
        try haxy_moment.put(hash.hashInt(repo_opts.hash, event_order_key), .{ .uint = event_order });

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
            if (!role.allows(std.meta.activeTag(event_with_id.event))) return error.EventKindNotAllowed;

            const current_event_id = try parseEventId(&event_with_id.id);

            // wrap the payload into the record `consume` stores, with its
            // commit-derived fields; on update, `consume` preserves the
            // existing record's
            switch (event_with_id.event) {
                .user => |event_maybe| {
                    const record_maybe: ?User.Record = if (event_maybe) |event| .{ .event = event, .created_order = event_order } else null;
                    try User.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .repo => |event_maybe| {
                    const record_maybe: ?Repo.Record = if (event_maybe) |event| .{ .event = event, .created_order = event_order } else null;
                    try Repo.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .fork => |event_maybe| {
                    const record_maybe: ?Fork.Record = if (event_maybe) |event| .{ .event = event, .created_order = event_order } else null;
                    try Fork.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .issue => |event_maybe| {
                    const record_maybe: ?Issue.Record = if (event_maybe) |event| .{
                        .event = event,
                        .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                        .created_order = event_order,
                    } else null;
                    try Issue.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .discuss => |event_maybe| {
                    const record_maybe: ?Discussion.Record = if (event_maybe) |event| .{
                        .event = event,
                        .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                        .created_order = event_order,
                    } else null;
                    try Discussion.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .comment => |event_maybe| {
                    const record_maybe: ?Comment.Record = if (event_maybe) |event| .{
                        .event = event,
                        .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                        .created_order = event_order,
                    } else null;
                    try Comment.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .attach => |event_maybe| {
                    const record_maybe: ?Attachment.Record = if (event_maybe) |event| blk: {
                        const entry = try attachedFile(repo_kind, repo_opts, read_state, io, allocator, &arena, &commit_object.content.commit.tree);
                        break :blk .{
                            .event = event,
                            .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                            .created_order = event_order,
                            .name = entry.name,
                            .blob_oid = entry.oid,
                        };
                    } else null;
                    try Attachment.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .patchrev => |event_maybe| {
                    const record_maybe: ?PatchRev.Record = if (event_maybe) |event| blk: {
                        const trees = try PatchRev.readTrees(repo_kind, repo_opts, read_state, io, allocator, &commit_object.content.commit.tree);
                        const existing_maybe = try PatchRev.readById(DB, repo_opts.hash, haxy_moment.readOnly(), &arena, &current_event_id);
                        const event_oid = std.fmt.bytesToHex(repo_event_oid, .lower);

                        var patch_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
                        if (existing_maybe) |existing| {
                            if (existing.patch_oid.len != patch_oid.len) return error.InvalidPatch;
                            @memcpy(&patch_oid, existing.patch_oid);
                        } else {
                            const author = try commitIdentity(commit_object.content.commit.metadata.author orelse return error.AuthorNotFound);
                            const committer = try commitIdentity(commit_object.content.commit.metadata.committer orelse author);
                            patch_oid = try PatchRev.writeSquashCommit(
                                repo_kind,
                                repo_opts,
                                state,
                                io,
                                allocator,
                                event,
                                &trees.head,
                                author,
                                committer,
                                commit_object.content.commit.metadata.timestamp,
                            );
                        }

                        break :blk .{
                            .event = event,
                            .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                            .created_order = event_order,
                            .event_oid = &event_oid,
                            .base_tree_oid = &trees.base,
                            .head_tree_oid = &trees.head,
                            .patch_oid = &patch_oid,
                        };
                    } else null;
                    try PatchRev.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
                .patch => |event_maybe| {
                    const record_maybe: ?Patch.Record = if (event_maybe) |event| .{
                        .event = event,
                        .author_email = authorEmail(commit_object.content.commit.metadata.author orelse ""),
                        .created_order = event_order,
                    } else null;
                    try Patch.consume(DB, repo_opts.hash, haxy_moment, &current_event_id, record_maybe, &arena, &repo_event_oid);
                },
            }
        }

        // the current object id is now the last one
        last_object_id_maybe = repo_event_oid;

        // prevent any of the data created above from being mutated by future iterations of this loop
        try db.freeze();
    }

    if (last_object_id_maybe) |*last_object_id| {
        try moment.put(hash.hashInt(repo_opts.hash, last_object_id_key), .{ .bytes = last_object_id });
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

pub const MergePolicy = enum {
    field_conflicts,
    target_wins,
};

// what a three-way merge did with a field
pub const FieldMerge = enum {
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

// three-way merge of one kind's records from a merge parent. kinds that expose
// conflicts merge field by field; the others take one whole record. the result
// goes through the kind's `consume`, which re-derives the indexes from it. a
// removal carries over unless the other side changed the record, so a merge
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
    var baseline_conflicts: ?DB.SortedMap(.read_only) = null;
    var parent_id_to_field_to_oid: ?DB.HashMap(.read_only) = null;
    switch (comptime T.merge_policy) {
        .field_conflicts => {
            if (try parent_moment.getCursor(hash.hashInt(hash_kind, T.conflicts_key))) |cursor| {
                parent_conflicts = try DB.SortedMap(.read_only).init(cursor);
            }
            if (try baseline_moment.getCursor(hash.hashInt(hash_kind, T.conflicts_key))) |cursor| {
                baseline_conflicts = try DB.SortedMap(.read_only).init(cursor);
            }
            if (try parent_moment.getCursor(hash.hashInt(hash_kind, T.id_to_field_to_oid_key))) |cursor| {
                parent_id_to_field_to_oid = try DB.HashMap(.read_only).init(cursor);
            }
        },
        .target_wins => {},
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

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

        // a record the target doesn't have arrives wholesale from the parent
        var outcome: [std.meta.fields(T).len]FieldMerge = @splat(.parent);
        var merged = parent_record;

        if (try target_records.getCursor(record_key)) |target_record_cursor| {
            // both sides share the change
            if (target_record_cursor.slot().eql(parent_slot)) continue;

            const target_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(target_record_cursor));

            var baseline_record: ?T.Record = null;
            if (baseline_records) |map| {
                if (try map.getCursor(record_key)) |baseline_record_cursor| {
                    baseline_record = try read(T.Record, DB, hash_kind, &arena, try DB.HashMap(.read_only).init(baseline_record_cursor));
                }
            }

            switch (comptime T.merge_policy) {
                .field_conflicts => {
                    outcome = @splat(.kept);
                    merged = target_record;
                    merged.event = mergeFields(T, if (baseline_record) |baseline| baseline.event else null, target_record.event, parent_record.event, &outcome);
                    if (comptime @hasDecl(T, "resolveMerge")) {
                        T.resolveMerge(target_record.event, parent_record.event, &merged.event, &outcome);
                    }

                    // merge the removed state separately from serialized fields. removal
                    // carries over an unchanged record, while an edit or restoration
                    // keeps it active.
                    merged.removed = if (target_record.removed == parent_record.removed)
                        target_record.removed
                    else if (baseline_record) |baseline| blk: {
                        const active = if (!target_record.removed) target_record else parent_record;
                        if (active.removed != baseline.removed) break :blk false;
                        if (!fieldsEqual(T, active.event, baseline.event)) break :blk false;
                        break :blk true;
                    } else false;
                },
                .target_wins => {
                    // an uncontested parent change carries over. if both sides
                    // changed the record, the target wins as a whole, except that
                    // an edit or restoration wins over a removal.
                    const target_changed = if (baseline_slot) |slot|
                        !target_record_cursor.slot().eql(slot)
                    else
                        true;
                    merged = if (!target_changed)
                        parent_record
                    else if (target_record.removed != parent_record.removed)
                        if (target_record.removed) parent_record else target_record
                    else
                        target_record;
                },
            }
        }

        // the index is unique, so a key the target gave to a different record
        // leaves this one out rather than stranding that one behind a name it
        // no longer owns
        if (!merged.removed and @hasDecl(T, "name_index_key")) {
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

        switch (comptime T.merge_policy) {
            .field_conflicts => {},
            .target_wins => continue,
        }

        // removed records do not carry field conflicts
        if (merged.removed) continue;

        const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.conflicts_key));
        const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);
        const id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, T.id_to_field_to_oid_key));
        const id_to_field_to_oid = try DB.HashMap(.read_write).init(id_to_field_to_oid_cursor);
        const merged_key = orderKeyDesc(merged.created_order, &event_id);

        var parent_field_oids: ?DB.SortedMap(.read_only) = null;
        if (parent_id_to_field_to_oid) |map| {
            if (try map.getCursor(record_key)) |field_oids_cursor| {
                parent_field_oids = try DB.SortedMap(.read_only).init(field_oids_cursor);
            }
        }
        // created only once a field actually comes from the parent
        var field_oids: ?DB.SortedMap(.read_write) = null;

        // the fields both sides changed differently, space separated
        var conflicted_fields: [conflictedFieldsMaxLen(T)]u8 = undefined;
        var conflicted_len: usize = 0;

        inline for (std.meta.fields(T), 0..) |field, i| {
            switch (outcome[i]) {
                // the target's value stands, so its oid does too
                .kept => {},
                // the parent set this value, so its commit takes the field. a
                // parent with no oid took its own value from a merge, leaving
                // the field unattributed rather than crediting the target's
                // commit for a value it no longer holds.
                .parent => {
                    if (field_oids == null) {
                        field_oids = try DB.SortedMap(.read_write).init(try id_to_field_to_oid.putCursor(record_key));
                    }
                    const map = field_oids orelse unreachable;
                    const parent_oid = if (parent_field_oids) |parent_map| try parent_map.getCursor(field.name) else null;
                    if (parent_oid) |oid_cursor| {
                        try map.put(field.name, .{ .slot = oid_cursor.slot() });
                    } else {
                        _ = try map.remove(field.name);
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

        // created_order never changes, so the parent keys this record's conflict
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

pub fn currentMomentFromDb(
    comptime hash_kind: hash.HashKind,
    db: *EventDB(hash_kind),
) !EventDB(hash_kind).HashMap(.read_only) {
    const DB = EventDB(hash_kind);
    const history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
    const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);
    return try currentMomentFromRepoMoment(hash_kind, moment);
}

pub fn currentMomentFromRepoMoment(
    comptime hash_kind: hash.HashKind,
    moment: EventDB(hash_kind).HashMap(.read_only),
) !EventDB(hash_kind).HashMap(.read_only) {
    const DB = EventDB(hash_kind);
    const last_object_id_cursor = try moment.getCursor(hash.hashInt(hash_kind, last_object_id_key)) orelse return error.NotFound;
    var last_object_id: [hash.byteLen(hash_kind)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);
    const haxy_cursor = try moment.getCursor(hash.hashInt(hash_kind, materialized_key)) orelse return error.NotFound;
    const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);
    const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
    const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);
    const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(hash_kind, &last_object_id)) orelse return error.NotFound;
    return try DB.HashMap(.read_only).init(haxy_moment_cursor);
}

// build a sorted-set key from an order and event id. big-endian order makes
// byte order match numeric order; the event id breaks ties.
pub fn orderKey(order: u64, event_id: *const [event_id_size]u8) [@sizeOf(u64) + event_id_size]u8 {
    var key: [@sizeOf(u64) + event_id_size]u8 = undefined;
    std.mem.writeInt(u64, key[0..@sizeOf(u64)], order, .big);
    @memcpy(key[@sizeOf(u64)..], event_id);
    return key;
}

pub fn orderKeyDesc(order: u64, event_id: *const [event_id_size]u8) [@sizeOf(u64) + event_id_size]u8 {
    return orderKey(std.math.maxInt(u64) - order, event_id);
}

// add or refresh one entry in the global logical-event index. updates and
// removed records preserve created_order, so the key never moves.
pub fn indexEvent(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [event_id_size]u8,
    kind: EventKind,
    created_order: u64,
    removed: bool,
) !void {
    const kind_map_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, event_index_key));
    const kind_map = try DB.HashMap(.read_write).init(kind_map_cursor);
    try kind_map.put(hash.hashInt(hash_kind, event_id), .{ .bytes = @tagName(kind) });

    const active_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, active_event_id_set_key));
    const active = try DB.SortedSet(.read_write).init(active_cursor);
    const removed_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, removed_event_id_set_key));
    const removed_set = try DB.SortedSet(.read_write).init(removed_cursor);
    const order_key = orderKeyDesc(created_order, event_id);
    if (removed) {
        _ = try active.remove(&order_key);
        try removed_set.put(&order_key);
    } else {
        _ = try removed_set.remove(&order_key);
        try active.put(&order_key);
    }
}

pub fn touchThread(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    thread_id: *const [event_id_size]u8,
    order: u64,
    arena: *std.heap.ArenaAllocator,
) !void {
    const kind_map_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, event_index_key)) orelse return;
    const kind_map = try DB.HashMap(.read_only).init(kind_map_cursor);
    const kind = (try readEventKind(hash_kind, kind_map, thread_id)) orelse return;
    switch (kind) {
        .discuss => try Discussion.touch(DB, hash_kind, haxy_moment, thread_id, order, arena),
        else => {},
    }
}

pub fn readEventKind(
    comptime hash_kind: hash.HashKind,
    kind_map: anytype,
    id: *const [event_id_size]u8,
) !?EventKind {
    const cursor = try kind_map.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    var buffer: [64]u8 = undefined;
    return std.meta.stringToEnum(EventKind, try cursor.readBytes(&buffer)) orelse error.InvalidEventKind;
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

pub const CreateRepoOptions = struct {
    read_access: Repo.Access = .private,
};

// resolve a pushed `<owner>/<repo>` to the hex event id that names its on-disk
// directory under the repos dir
pub fn resolveOrCreateRepo(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    owner_name: []const u8,
    repo_name: []const u8,
    create_options_maybe: ?CreateRepoOptions,
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

    const create_options = create_options_maybe orelse return null;

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

    try consume(.admin, .xit, admin_repo_opts, io, allocator, &repo, events_ref, &[_]EventWithId{.{
        .id = event_id_hex,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = .{ .name = owner.event.name, .email = owner.event.email },
        .event = .{ .repo = .{
            .user_id = &owner_user_id,
            .name = repo_name,
            .description = "",
            .read_access = create_options.read_access,
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
                    .@"enum" => {
                        const bytes = try readBytes(DB, hash_kind, arena.allocator(), map, field.name);
                        @field(event, field.name) = std.meta.stringToEnum(field.type, bytes) orelse return error.InvalidEnumTag;
                    },
                    .optional => |optional_info| {
                        // a missing key is null
                        if (try map.getCursor(hash.hashInt(hash_kind, field.name))) |cursor| {
                            if (optional_info.child == []const u8) {
                                @field(event, field.name) = try cursor.readBytesAlloc(arena.allocator(), null);
                            } else switch (@typeInfo(optional_info.child)) {
                                .array => |array_info| {
                                    if (array_info.child != u8) @compileError("unsupported read field type: " ++ @typeName(field.type));
                                    var bytes: optional_info.child = undefined;
                                    const value = try cursor.readBytes(&bytes);
                                    if (value.len != bytes.len) return error.InvalidByteArrayLength;
                                    @field(event, field.name) = bytes;
                                },
                                .@"struct" => @field(event, field.name) = try read(
                                    optional_info.child,
                                    DB,
                                    hash_kind,
                                    arena,
                                    try DB.HashMap(.read_only).init(cursor),
                                ),
                                else => @compileError("unsupported read field type: " ++ @typeName(field.type)),
                            }
                        } else {
                            @field(event, field.name) = null;
                        }
                    },
                    .@"struct" => {
                        const cursor = try map.getCursor(hash.hashInt(hash_kind, field.name)) orelse return error.NotFound;
                        @field(event, field.name) = try read(
                            field.type,
                            DB,
                            hash_kind,
                            arena,
                            try DB.HashMap(.read_only).init(cursor),
                        );
                    },
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
        .@"struct" => return fieldsEqual(Field, a, b),
        .optional => |optional_info| {
            if (a) |a_value| {
                if (b) |b_value| return fieldEqual(optional_info.child, a_value, b_value);
                return false;
            }
            return b == null;
        },
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
            // a missing key is null
            if (value) |child| {
                if (optional_info.child == []const u8) {
                    try upsertBytes(DB, hash_kind, map, key, child);
                } else switch (@typeInfo(optional_info.child)) {
                    .array => |array_info| {
                        if (array_info.child != u8) @compileError("unsupported upsert field type: " ++ @typeName(Field));
                        try upsertBytes(DB, hash_kind, map, key, &child);
                    },
                    .@"struct" => try upsert(
                        optional_info.child,
                        DB,
                        hash_kind,
                        try DB.HashMap(.read_write).init(try map.putCursor(key)),
                        child,
                    ),
                    else => @compileError("unsupported upsert field type: " ++ @typeName(Field)),
                }
            } else {
                _ = try map.remove(key);
            }
        },
        .@"struct" => try upsert(
            Field,
            DB,
            hash_kind,
            try DB.HashMap(.read_write).init(try map.putCursor(key)),
            value,
        ),
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

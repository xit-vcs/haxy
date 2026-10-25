const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const rf = xit.ref;
const mrg = xit.merge;
const find = @import("find.zig");
const srch_cmmt = @import("search_commit.zig");
const fork = @import("fork.zig");
const serve_common = @import("serve_common.zig");
const progress = @import("./progress.zig");
const notify = @import("notify.zig");

// the action a patch merge records
pub const merge_undo_action = "haxy/merge";

// the action a mergeability recheck records
pub const mergeability_undo_action = "haxy/mergeability";

// whether a push moved this branch
fn branchUpdated(updates: []const xit.net_server_receive_pack.AppliedRefUpdate, branch: []const u8) bool {
    const prefix = "refs/heads/";
    for (updates) |update| {
        if (std.mem.startsWith(u8, update.ref_name, prefix) and std.mem.eql(u8, update.ref_name[prefix.len..], branch)) return true;
    }
    return false;
}

// capture an existing branch without creating a fork
pub fn writeBranchPatch(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: [evt.event_id_size * 2]u8,
    patch: evt.Patch,
    expected_patch: ?evt.Patch,
    author: evt.CommitAuthor,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // write git events through the local event database
    if (repo_kind == .git) {
        // reject edits based on an outdated patch
        if (expected_patch) |expected| {
            const current = (try evt.readFromRepo(evt.Patch, repo_kind, repo_opts, io, allocator, &arena, repo, &try evt.parseEventId(&id))) orelse return error.PatchOutOfDate;
            if (current.removed or !evt.fieldEqual(evt.Patch, current.event, expected)) return error.PatchOutOfDate;
        }

        // capture the branch revision and consume its events
        const events = try branchEvents(repo_kind, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, &arena, id, patch, author);
        try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events);
    } else {
        const DB = evt.EventDB(repo_opts.hash);

        const first_parent = try eventsFirstParent(repo_kind, repo_opts, io, allocator, repo);

        // commit the patch, mergeability, and undo record together
        {
            const Ctx = struct {
                repo: *rp.Repo(repo_kind, repo_opts),
                io: std.Io,
                arena: *std.heap.ArenaAllocator,
                id: [evt.event_id_size * 2]u8,
                patch: evt.Patch,
                expected_patch: ?evt.Patch,
                author: evt.CommitAuthor,
                host: evt.Host,
                first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    const state = rp.Repo(repo_kind, repo_opts).State(.read_write){ .core = &ctx.repo.core, .extra = .{ .moment = &moment } };

                    try writeBranchPatchInTransaction(ctx.host, repo_opts, state, &moment, ctx.io, ctx.arena, ctx.id, ctx.patch, ctx.expected_patch, ctx.author, ctx.first_parent);

                    // record the user action for undo
                    try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = evt.undo_action } });
                }
            };

            try repo.core.db_file.lock(io, .exclusive);
            defer repo.core.db_file.unlock(io);

            const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .repo = repo, .io = io, .arena = &arena, .id = id, .patch = patch, .expected_patch = expected_patch, .author = author, .host = host, .first_parent = first_parent });
        }
        if (host == .server) {
            notify.subscribeParticipants(io, allocator, host.server, repo.core.work_path, &.{.{ .id = id, .author = author, .event = .{ .patch = patch } }});
            evt.bumpRepoActivityAt(io, allocator, host.server, repo.core.work_path);
        }
    }
}

// write one branch patch's revision into a transaction the caller owns. the
// undo record is the caller's to write, since the transaction may be theirs.
// git repos never reach here: they write through the local event database
pub fn writeBranchPatchInTransaction(
    host: evt.Host,
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    id: [evt.event_id_size * 2]u8,
    patch: evt.Patch,
    expected_patch: ?evt.Patch,
    author: evt.CommitAuthor,
    first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,
) !void {
    const DB = evt.EventDB(repo_opts.hash);

    // recheck the expected patch under the repository lock
    if (expected_patch) |expected| {
        const events_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
        const current = (try evt.Patch.readById(DB, repo_opts.hash, events_moment, arena, &try evt.parseEventId(&id))) orelse return error.PatchOutOfDate;
        if (current.removed or !evt.fieldEqual(evt.Patch, current.event, expected)) return error.PatchOutOfDate;
    }

    // capture and consume the branch revision
    const events = try branchEvents(.xit, repo_opts, state, io, arena, id, patch, author);
    {
        const parent = if (try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = evt.events_ref }) == null) first_parent else null;
        try evt.commitEvents(.xit, repo_opts, state, io, arena.child_allocator, evt.events_ref, &events, parent);
        _ = try evt.consumeInTransaction(.repo, .xit, repo_opts, state, &state.core.db, moment, io, arena.child_allocator, evt.events_ref);
    }

    // save mergeability before finishing the patch transaction
    if (host == .server) _ = try updateMergeChecks(repo_opts, state, io, arena.child_allocator, host.server.users_dir, &.{try evt.parseEventId(&id)}, null);
}

// continue from a remote event history when the local ref is absent, so a
// fresh clone's first event does not start a history of its own
fn eventsFirstParent(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
) !?[1][hash.hexLen(repo_opts.hash)]u8 {
    if (try repo.readRef(io, evt.events_ref) != null) return null;
    var remotes = try repo.listRemotes(io, allocator);
    defer remotes.deinit();
    for (remotes.sections.keys()) |name| {
        if (try repo.readRef(io, .{ .kind = .{ .remote = name }, .name = evt.events_ref.name })) |oid| return .{oid};
    }
    return null;
}

fn branchEvents(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_write),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    id: [evt.event_id_size * 2]u8,
    patch: evt.Patch,
    author: evt.CommitAuthor,
) ![2]evt.EventWithId {
    // validate the patch fields and branch names
    const branch = patch.source_branch orelse return error.InvalidSourceBranch;
    if (!evt.Patch.fieldsValid(patch.title, patch.labels)) return error.InvalidFields;
    if (!evt.Patch.branchValid(branch)) return error.InvalidSourceBranch;
    if (!evt.Patch.branchValid(patch.target_branch)) return error.InvalidTargetBranch;

    // resolve both tips and their common ancestor
    const source = (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = branch } })) orelse return error.InvalidSourceBranch;
    const target = (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = patch.target_branch } })) orelse return error.InvalidTargetBranch;
    if (std.mem.eql(u8, branch, patch.target_branch)) return error.SameBranch;
    const base = mrg.commonAncestor(repo_kind, repo_opts, state.readOnly(), io, arena.allocator(), &target, &source) catch |err| switch (err) {
        error.NoCommonAncestor => return error.UnrelatedBranches,
        else => return err,
    };

    // prepare the revision and attach it to the patch event
    const timestamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const prepared = try evt.PatchRev.prepare(repo_kind, repo_opts, state, io, arena, &base, &source, patch.title, author, timestamp);
    var updated = patch;
    updated.revision = prepared.revision;
    return .{
        prepared.event,
        .{ .id = id, .author = author, .timestamp = timestamp, .event = .{ .patch = updated } },
    };
}

// the open patches whose source branch has moved past the revision they
// stored, mapped to the record the refresh rewrites. `updates` limits the
// search to the branches one push changed
fn collectOutdatedBranchPatches(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
    host: evt.Host,
    patches: *std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, evt.Patch.Record),
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    // find tracked source branches and skip conflicting patches
    const source_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.source_to_id_set_key)) orelse return;
    const sources = try DB.SortedMap(.read_only).init(source_cursor);
    const conflicts = if (try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key))) |cursor| try DB.SortedMap(.read_only).init(cursor) else null;
    var iter = try sources.iterator();
    while (try iter.next()) |cursor| {
        const pair = try cursor.readKeyValuePair();
        const branch = try pair.key_cursor.readBytesAlloc(arena.allocator(), null);

        // limit source refreshes to branches changed by this push
        if (updates) |changed| if (!branchUpdated(changed, branch)) continue;

        // read the source tip before comparing stored revisions
        const source = (try rf.readRecur(repo_kind, repo_opts, state, io, .{ .ref = .{ .kind = .head, .name = branch } })) orelse {
            if (host == .server) std.log.warn("patch source branch missing: {s}", .{branch});
            continue;
        };

        // collect open patches whose stored source tip is outdated
        const ids = try DB.CountedHashSet(.read_only).init(pair.value_cursor);
        var ids_iter = try ids.iterator();
        while (try ids_iter.next()) |id_cursor| {
            const id_pair = try id_cursor.readKeyValuePair();
            var id: [evt.event_id_size]u8 = undefined;
            if ((try id_pair.key_cursor.readBytes(&id)).len != id.len) return error.InvalidPatch;
            const record = (try evt.Patch.readById(DB, repo_opts.hash, moment, arena, &id)) orelse continue;
            if (record.removed or record.event.status.kind() != .open) continue;
            if (conflicts) |map| if (try map.getCursor(&evt.orderKeyDesc(record.created_order, &id)) != null) continue;
            if (record.event.revision) |revision| if (std.mem.eql(u8, revision.source_oid, &source)) continue;
            try patches.put(allocator, id, record);
        }
    }
}

// refresh the patches their source branch has outrun, inside the caller's
// transaction, so a push and the revisions it causes land together. reports
// whether any revision was written, so a caller that owns an otherwise empty
// transaction can cancel it
pub fn refreshBranchesInTransaction(
    host: evt.Host,
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
    first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var patches: std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, evt.Patch.Record) = .empty;
    defer patches.deinit(allocator);

    const events_moment = evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly()) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    try collectOutdatedBranchPatches(.xit, repo_opts, io, allocator, &arena, state.readOnly(), events_moment, updates, host, &patches);

    const total = patches.count();
    if (total > 0) {
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Updating patches" });
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = total } });
    }

    var refreshed = false;
    for (patches.keys(), patches.values()) |id, record| {
        defer progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });

        const author = evt.CommitAuthor{ .name = "haxy", .email = record.author_email orelse "user@haxy" };
        writeBranchPatchInTransaction(host, repo_opts, state, moment, io, &arena, std.fmt.bytesToHex(id, .lower), record.event, record.event, author, first_parent) catch |err| {
            std.log.warn("failed to refresh branch patch: {s}", .{@errorName(err)});
            continue;
        };
        refreshed = true;
    }
    if (total > 0) progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
    return refreshed;
}

// refresh open patches' tracked branches and, on the server, their
// mergeability. this runs after the caller's transaction, and on xit writes
// every revision in one transaction of its own
pub fn refreshBranches(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    if (repo_kind == .xit) {
        const DB = evt.EventDB(repo_opts.hash);

        // every revision shares one transaction, so the refresh is a single
        // undo entry. the transaction collects the patches itself, and is
        // cancelled when none of them moved
        {
            const Ctx = struct {
                core: *rp.Repo(.xit, repo_opts).Core,
                io: std.Io,
                allocator: std.mem.Allocator,
                host: evt.Host,
                first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,
                progress_ctx_maybe: ?repo_opts.ProgressCtx,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    const state = rp.Repo(.xit, repo_opts).State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                    if (!try refreshBranchesInTransaction(ctx.host, repo_opts, state, &moment, ctx.io, ctx.allocator, null, ctx.first_parent, ctx.progress_ctx_maybe)) return error.CancelTransaction;

                    // record the user action for undo
                    try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = evt.undo_action } });
                }
            };

            const first_parent = try eventsFirstParent(repo_kind, repo_opts, io, allocator, repo);

            try repo.core.db_file.lock(io, .exclusive);
            defer repo.core.db_file.unlock(io);

            const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
            history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
                .core = &repo.core,
                .io = io,
                .allocator = allocator,
                .host = host,
                .first_parent = first_parent,
                .progress_ctx_maybe = progress_ctx_maybe,
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => return err,
            };
        }

        // then the open patches whose checks went stale
        if (host == .server) refreshOpenMergeability(repo_opts, io, allocator, repo, host.server.users_dir, progress_ctx_maybe);
        return;
    }

    // git repos have no transaction to share, so each revision is written on
    // its own through the local event database. they report no progress,
    // since only a push has a progress context to report to
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var patches: std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, evt.Patch.Record) = .empty;
    defer patches.deinit(allocator);

    collect: {
        var local_db = (try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir)) orelse break :collect;
        defer local_db.deinit(io, allocator);
        const moment = evt.currentMomentFromDb(repo_opts.hash, local_db.db) catch |err| switch (err) {
            error.NotFound => break :collect,
            else => return err,
        };
        try collectOutdatedBranchPatches(repo_kind, repo_opts, io, allocator, &arena, .{ .core = &repo.core, .extra = .{} }, moment, null, host, &patches);
    }

    for (patches.keys(), patches.values()) |id, record| {
        const author = evt.CommitAuthor{ .name = "haxy", .email = record.author_email orelse "user@haxy" };
        writeBranchPatch(host, repo_kind, repo_opts, io, allocator, repo, std.fmt.bytesToHex(id, .lower), record.event, record.event, author) catch |err| {
            if (host == .server) std.log.warn("failed to refresh branch patch: {s}", .{@errorName(err)});
        };
    }
}

pub const PublishInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub const EditDraftInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    target_branch: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub const Mergeability = struct {
    pub const Status = enum { clean, conflict, unknown };

    source: Status = .unknown,
    squash: Status = .unknown,

    pub fn get(self: Mergeability, revision: evt.Patch.MergeRevision) Status {
        return switch (revision) {
            .source => self.source,
            .squash => self.squash,
        };
    }

    pub fn status(self: Mergeability) Status {
        if (self.source == .clean or self.squash == .clean) return .clean;
        if (self.source == .conflict and self.squash == .conflict) return .conflict;
        return .unknown;
    }
};

const MergeCheck = struct {
    revision: evt.Patch.Revision,
    target_branch: []const u8,
    target_oid: []const u8,
    result: Mergeability = .{},

    fn matches(self: MergeCheck, patch: evt.Patch, target_oid: []const u8) bool {
        return evt.fieldEqual(?evt.Patch.Revision, self.revision, patch.revision) and
            std.mem.eql(u8, self.target_branch, patch.target_branch) and
            std.mem.eql(u8, self.target_oid, target_oid);
    }

    // a matching check with both results resolved, which needs no rerun
    fn settled(self: MergeCheck, patch: evt.Patch, target_oid: []const u8) bool {
        return self.matches(patch, target_oid) and self.result.source != .unknown and self.result.squash != .unknown;
    }
};

fn readMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
) !?MergeCheck {
    const DB = evt.EventDB(repo_opts.hash);

    // find the cached check for this patch
    const map_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.patch_id_to_mergeability_key)) orelse return null;
    const map = try DB.HashMap(.read_only).init(map_cursor);
    const cursor = try map.getCursor(hash.hashInt(repo_opts.hash, id)) orelse return null;

    // treat unrecognized cached statuses as a cache miss
    return evt.read(MergeCheck, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(cursor)) catch |err| switch (err) {
        error.InvalidEnumTag => return null,
        else => return err,
    };
}

// reads never run a merge or refresh the cache
pub fn readMergeability(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
    patch: evt.Patch,
) !Mergeability {
    // reject checks for an outdated source revision
    if (patch.source_branch != null and !try branchCurrent(repo_opts, state, io, arena, patch)) return .{};

    // use the cached result only when the target still matches
    const target_oid = try rf.readRecur(.xit, repo_opts, state, io, .{ .ref = .{ .kind = .head, .name = patch.target_branch } }) orelse return .{};
    const haxy_moment = evt.currentMomentFromRepoMoment(repo_opts.hash, state.extra.moment.*) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    const cached = try readMergeCheck(repo_opts, haxy_moment, arena, id) orelse return .{};
    return if (cached.matches(patch, &target_oid)) cached.result else .{};
}

// refresh after the caller's transaction and locks have finished. a check
// failure must not turn an accepted push or event into a failed operation.
pub fn refreshMergeability(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    users_dir: []const u8,
    id: [evt.event_id_size]u8,
) void {
    saveMergeChecks(repo_opts, io, allocator, target_repo, users_dir, &.{id}, null) catch |err| {
        std.log.warn("failed to refresh mergeability: {s}", .{@errorName(err)});
    };
}

// check every open patch whose saved result is stale, in one transaction
// after the caller's transaction and locks have finished
pub fn refreshOpenMergeability(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    users_dir: []const u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) void {
    saveMergeChecks(repo_opts, io, allocator, target_repo, users_dir, null, progress_ctx_maybe) catch |err| {
        std.log.warn("failed to refresh mergeability: {s}", .{@errorName(err)});
    };
}

// one transaction checking `ids`, or the stale open patches when null,
// cancelled when no result changed
fn saveMergeChecks(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    users_dir: []const u8,
    ids: ?[]const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const Ctx = struct {
        core: *Repo.Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        users_dir: []const u8,
        ids: ?[]const [evt.event_id_size]u8,
        progress_ctx_maybe: ?repo_opts.ProgressCtx,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = Repo.State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            const changed = if (ctx.ids) |value|
                try updateMergeChecks(repo_opts, state, ctx.io, ctx.allocator, ctx.users_dir, value, ctx.progress_ctx_maybe)
            else
                try updateStaleMergeChecks(repo_opts, state, ctx.io, ctx.allocator, ctx.users_dir, ctx.progress_ctx_maybe);
            if (!changed) return error.CancelTransaction;

            // name the transaction, which no user action owns
            try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = mergeability_undo_action } });
        }
    };

    try target_repo.core.db_file.lock(io, .exclusive);
    defer target_repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
    history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
        .core = &target_repo.core,
        .io = io,
        .allocator = allocator,
        .users_dir = users_dir,
        .ids = ids,
        .progress_ctx_maybe = progress_ctx_maybe,
    }) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => return err,
    };
}

// check `ids` inside the caller's transaction. a failed restoration aborts
// it so trial writes can't be committed, while other failures only skip their
// patch. reports whether any saved result changed
pub fn updateMergeChecks(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    ids: []const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (ids.len > 0) {
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Checking mergeability" });
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = ids.len } });
    }
    defer if (ids.len > 0) progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
    var changed = false;
    for (ids) |*id| {
        defer progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
        const saved = updateMergeCheck(repo_opts, state, io, &arena, users_dir, id) catch |err| switch (err) {
            error.MergeCheckRestoreFailed => return err,
            else => {
                std.log.warn("failed to refresh mergeability: {s}", .{@errorName(err)});
                continue;
            },
        };
        if (saved) changed = true;
    }
    return changed;
}

// check the open patches whose saved result is unresolved or no longer
// matches their revision and target tip, inside the caller's transaction. a
// fork moving on is left to the paths that move it
pub fn updateStaleMergeChecks(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const target_events = evt.currentMomentFromRepoMoment(repo_opts.hash, state.extra.moment.readOnly()) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    const statuses_cursor = try target_events.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key)) orelse return false;
    const statuses = try DB.SortedMap(.read_only).init(statuses_cursor);
    const open_cursor = try statuses.getCursor("open") orelse return false;
    const open = try DB.SortedSet(.read_only).init(open_cursor);

    var stale: std.ArrayList([evt.event_id_size]u8) = .empty;
    var iter = try open.iteratorFromIndex(0);
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(DB, cursor);
        const record = (try evt.Patch.readById(DB, repo_opts.hash, target_events, &arena, &id)) orelse continue;
        if (record.event.revision == null) continue;
        const target_oid = try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = record.event.target_branch } });
        if (try readMergeCheck(repo_opts, target_events, &arena, &id)) |cached| {
            if (cached.settled(record.event, if (target_oid) |*oid| oid else "")) continue;
        }
        try stale.append(arena.allocator(), id);
    }
    return updateMergeChecks(repo_opts, state, io, allocator, users_dir, stale.items, progress_ctx_maybe);
}

// a fork patch's fork, found through the forker in the target's config, or
// null when it has none. it is read without a lock, since a committed moment
// never changes
fn openFork(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    id: *const [evt.event_id_size]u8,
) !?rp.Repo(.xit, repo_opts) {
    var config = try xit.config.Config(.xit, repo_opts).init(state, io, allocator);
    defer config.deinit();
    const forker_id = (try fork.readForkerId(&config.sections, id)) orelse return null;
    const path = try fork.forkPath(allocator, users_dir, &forker_id, id);
    defer allocator.free(path);
    return rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = path, .require_repo_root = true }) catch |err| {
        std.log.warn("mergeability fork unavailable: {s}", .{@errorName(err)});
        return null;
    };
}

// the caller holds the target's exclusive lock. this only saves the cache; it
// never creates a top-level history transaction.
fn updateMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    id: *const [evt.event_id_size]u8,
) !bool {
    const DB = rp.Repo(.xit, repo_opts).DB;

    // read the patch from the current transaction
    const target_events = evt.currentMomentFromRepoMoment(repo_opts.hash, state.extra.moment.readOnly()) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    const patch_record = (try evt.Patch.readById(DB, repo_opts.hash, target_events, arena, id)) orelse return false;
    if (patch_record.removed or patch_record.event.status.kind() != .open) return false;
    const patch = patch_record.event;
    const revision = patch.revision orelse return false;

    // find the newest fork revision when the patch uses a fork
    var fork_repo_maybe = if (patch.source_branch != null) null else try openFork(repo_opts, state.readOnly(), io, arena.child_allocator, users_dir, id);
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, arena.child_allocator);
    const fork_repo = if (fork_repo_maybe) |*repo| repo else null;
    var newest: ?evt.PatchRev.WithId = null;
    if (fork_repo) |repo| {
        if (evt.currentMoment(repo_opts, repo)) |events| {
            newest = evt.PatchRev.readNewest(DB, repo_opts.hash, events, arena) catch |err| blk: {
                std.log.warn("mergeability revision unavailable: {s}", .{@errorName(err)});
                break :blk null;
            };
        } else |err| std.log.warn("mergeability revision unavailable: {s}", .{@errorName(err)});
    }

    // compare the selected revision and target against the cache
    const target_oid = try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = patch.target_branch } });
    var check = MergeCheck{ .revision = revision, .target_branch = patch.target_branch, .target_oid = if (target_oid) |*oid| oid else "" };
    const cached = try readMergeCheck(repo_opts, target_events, arena, id);
    const current = if (patch.source_branch != null)
        try branchCurrent(repo_opts, state.readOnly(), io, arena, patch)
    else if (newest) |latest|
        std.mem.eql(u8, &std.fmt.bytesToHex(latest.id, .lower), &revision.id) and revision.matches(latest.record)
    else
        false;

    // run trial merges only for a current revision with an unresolved check
    if (current and target_oid != null) {
        if (cached) |value| if (value.settled(patch, check.target_oid)) return false;
        check.result = try trialMergeCheck(repo_opts, state, io, arena.child_allocator, &check, fork_repo);
    }

    // persist the result only when it differs from the cache
    if (cached) |value| if (evt.fieldEqual(MergeCheck, value, check)) return false;
    try saveMergeCheck(repo_opts, state.extra.moment.*, id, check);
    return true;
}

fn trialMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    check: *const MergeCheck,
    fork_repo: ?*rp.Repo(.xit, repo_opts),
) !Mergeability {
    // freeze the parent state so trial writes copy its nodes
    const moment = state.extra.moment;
    const snapshot = try moment.slot();
    // TODO: use an xitdb savepoint to also reclaim trial bytes on rollback.
    // restoring the root leaves the appended data unused until gc.
    try state.core.db.freeze();
    moment.* = rp.Repo(.xit, repo_opts).DB.HashMap(.read_write).init(moment.cursor) catch return error.MergeCheckRestoreFailed;

    // keep the trial result in memory while discarding its state changes
    const result = calculateMergeCheck(repo_opts, state, io, allocator, check, fork_repo);

    // restore the parent state before handling any trial error
    moment.cursor.write(.{ .slot = snapshot }) catch return error.MergeCheckRestoreFailed;
    moment.* = rp.Repo(.xit, repo_opts).DB.HashMap(.read_write).init(moment.cursor) catch return error.MergeCheckRestoreFailed;

    // report failed trials as unknown after the parent state is restored
    return result catch |err| {
        std.log.warn("mergeability check failed: {s}", .{@errorName(err)});
        return .{};
    };
}

// queue `oid` and its history on `objects`, which reads from `source`, minus
// what `holder` already has. a repo and its forks start as copies of each other,
// so walking back to the newest commit `holder` has usually skips nearly all of it.
pub fn includeMissing(
    comptime repo_opts: rp.RepoOpts(.xit),
    objects: *obj.ObjectIterator(.xit, repo_opts),
    holder: rp.Repo(.xit, repo_opts).State(.read_only),
    source: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !void {
    var held_oid = oid.*;
    while (true) {
        var reader_or_err = obj.ObjectReader(.xit, repo_opts).init(holder, io, allocator, &held_oid);
        if (reader_or_err) |*reader| {
            reader.deinit();
            break;
        } else |err| switch (err) {
            error.ObjectNotFound => {},
            else => |e| return e,
        }
        var commit = try obj.Object(.xit, repo_opts).init(source, io, allocator, &held_oid);
        defer commit.deinit();
        const parent_oids = commit.content.commit.metadata.parent_oids orelse return objects.include(oid);
        if (parent_oids.len == 0) return objects.include(oid);
        held_oid = parent_oids[0];
    }
    if (std.mem.eql(u8, &held_oid, oid)) return;
    try objects.include(oid);
    try objects.exclude(&held_oid);
}

fn calculateMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    check: *const MergeCheck,
    fork_repo: ?*rp.Repo(.xit, repo_opts),
) !Mergeability {
    const source = try oidArray(repo_opts.hash, check.revision.source_oid);
    const squash = try oidArray(repo_opts.hash, check.revision.squash_oid);

    // import fork objects into the temporary trial state
    if (fork_repo) |repo| {
        var fork_moment = try repo.core.latestMoment();
        const fork_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &fork_moment } };
        var objects = try obj.ObjectIterator(.xit, repo_opts).init(fork_state, io, allocator, .{ .kind = .all });
        defer objects.deinit();
        try includeMissing(repo_opts, &objects, state.readOnly(), fork_state, io, allocator, &source);
        try includeMissing(repo_opts, &objects, state.readOnly(), fork_state, io, allocator, &squash);
        try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, io, null);
    }

    // check source and squash merges against the same target
    const target = rf.Ref{ .kind = .head, .name = check.target_branch };
    return .{
        .source = checkCommit(repo_opts, state, io, allocator, &source, target),
        .squash = checkCommit(repo_opts, state, io, allocator, &squash, target),
    };
}

fn saveMergeCheck(comptime repo_opts: rp.RepoOpts(.xit), moment: rp.Repo(.xit, repo_opts).DB.HashMap(.read_write), id: *const [evt.event_id_size]u8, check: MergeCheck) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;

    // store the check under the current event history moment
    const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.last_object_id_key)) orelse return error.NotFound;
    var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);
    const haxy_history = try DB.ArrayList(.read_write).init(try moment.putCursor(hash.hashInt(repo_opts.hash, evt.history_key)));
    const haxy_moments = try DB.HashMap(.read_write).init(try haxy_history.putCursor(-1));
    const haxy_moment = try DB.HashMap(.read_write).init(try haxy_moments.putCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)));
    const map = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, evt.Patch.patch_id_to_mergeability_key)));
    const entry = try DB.HashMap(.read_write).init(try map.putCursor(hash.hashInt(repo_opts.hash, id)));
    try evt.upsert(MergeCheck, DB, repo_opts.hash, entry, check);
}

fn branchCurrent(comptime repo_opts: rp.RepoOpts(.xit), state: rp.Repo(.xit, repo_opts).State(.read_only), io: std.Io, arena: *std.heap.ArenaAllocator, patch: evt.Patch) !bool {
    // check that the source branch still points to the selected commit
    const branch = patch.source_branch orelse return false;
    const selected = patch.revision orelse return false;
    const oid = (try rf.readRecur(.xit, repo_opts, state, io, .{ .ref = .{ .kind = .head, .name = branch } })) orelse return false;
    if (!std.mem.eql(u8, &oid, selected.source_oid)) return false;

    // verify that the stored revision metadata also matches
    const events = try evt.currentMomentFromRepoMoment(repo_opts.hash, state.extra.moment.*);
    const revision = (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, events, arena, &try evt.parseEventId(&selected.id))) orelse return false;
    return selected.matches(revision);
}

fn oidArray(comptime hash_kind: hash.HashKind, oid: []const u8) ![hash.hexLen(hash_kind)]u8 {
    try evt.PatchRev.validateOid(hash_kind, oid);
    var result: [hash.hexLen(hash_kind)]u8 = undefined;
    @memcpy(&result, oid);
    return result;
}

fn checkCommit(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
    target: rf.Ref,
) Mergeability.Status {
    var result = mrg.Merge(.xit, repo_opts).init(state, io, allocator, .{
        .kind = .full,
        .action = .{ .new = .{ .source = &.{.{ .oid = oid }}, .algo = .patch } },
        .dry_run = true,
    }, target, null) catch |err| {
        std.log.warn("mergeability check failed: {s}", .{@errorName(err)});
        return .unknown;
    };
    defer result.deinit();

    // translate the dry-run outcome into a cached status
    return switch (result.result) {
        .conflict => .conflict,
        .clean, .success, .nothing, .fast_forward => .clean,
    };
}

pub const MergeInput = struct {
    id: [evt.event_id_size * 2]u8,
    revision: evt.Patch.MergeRevision,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn publish(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    input: PublishInput,
) !void {
    const patch_id = try evt.parseEventId(&input.id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // validate the fork ownership and publishing identity
    var user_repo = (try evt.openUserRepo(io, allocator, server.users_dir, &input.user_id)) orelse return error.InvalidPatchDraft;
    defer user_repo.deinit(io, allocator);
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const user_moment = (try evt.userMoment(&user_repo)) orelse return error.InvalidPatchDraft;
    const fork_record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, user_moment, &arena, &patch_id)) orelse return error.InvalidPatchDraft;
    if (fork_record.removed or !std.mem.eql(u8, &fork_record.event.repo_id, &std.fmt.bytesToHex(input.repo_id, .lower))) return error.InvalidPatchDraft;
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &input.user_id)) orelse return error.InvalidPatchDraft;
    if (user.removed or
        !std.mem.eql(u8, user.event.name, input.author.name) or
        !std.mem.eql(u8, user.event.email, input.author.email)) return error.InvalidPatchDraft;

    // read the patch staged in the fork
    const fork_path = try fork.forkPath(arena.allocator(), server.users_dir, &input.user_id, &patch_id);
    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path }) catch return error.PatchDataUnavailable;
    defer fork_repo.deinit(io, allocator);
    const fork_moment = evt.currentMoment(repo_opts, &fork_repo) catch return error.PatchDataUnavailable;
    const local_patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &patch_id)) orelse return error.PatchDataUnavailable;

    // check whether this patch has already been published
    const target_moment = evt.currentMoment(repo_opts, target_repo) catch |err| switch (err) {
        error.NotFound => null,
        else => |other| return other,
    };
    const existing = if (target_moment) |moment|
        try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, &arena, &patch_id)
    else
        null;
    if (existing) |record| {
        if (record.removed or !std.mem.eql(u8, record.author_email orelse "", input.author.email)) return error.InvalidPatch;
    }

    // publish the selected revision unless the draft was already consumed
    if (local_patch.removed) {
        if (existing == null) return error.PatchDataUnavailable;
    } else {
        var patch = (existing orelse local_patch).event;
        if (local_patch.event.revision) |selected| {
            const revision_id = try evt.parseEventId(&selected.id);
            const revision = (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &revision_id)) orelse return error.PatchNotPushed;
            if (!selected.matches(revision)) return error.PatchNotPushed;
            patch.revision = selected;
        }
        if (existing == null) patch.status = .open;

        // write the published patch and its forker to the target repository
        const events = &[_]evt.EventWithId{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = patch },
        }};
        {
            const first_parent = try eventsFirstParent(.xit, repo_opts, io, allocator, target_repo);

            const DB = rp.Repo(.xit, repo_opts).DB;
            const State = rp.Repo(.xit, repo_opts).State;
            const Ctx = struct {
                core: *rp.Repo(.xit, repo_opts).Core,
                io: std.Io,
                allocator: std.mem.Allocator,
                events: []const evt.EventWithId,
                patch_id: [evt.event_id_size]u8,
                forker_id: [evt.event_id_size * 2]u8,
                users_dir: []const u8,
                first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,

                pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    var moment = try DB.HashMap(.read_write).init(cursor.*);
                    const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

                    // code that starts from the target finds the fork through this entry
                    var config = try xit.config.Config(.xit, repo_opts).init(state.readOnly(), ctx.io, ctx.allocator);
                    defer config.deinit();
                    try config.add(state, ctx.io, .{ .name = &fork.forkerConfigName(&ctx.patch_id), .value = &ctx.forker_id });

                    const parent = if (try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = evt.events_ref }) == null) ctx.first_parent else null;
                    try evt.commitEvents(.xit, repo_opts, state, ctx.io, ctx.allocator, evt.events_ref, ctx.events, parent);
                    _ = try evt.consumeInTransaction(.repo, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, evt.events_ref);
                    _ = try updateMergeChecks(repo_opts, state, ctx.io, ctx.allocator, ctx.users_dir, &.{ctx.patch_id}, null);
                    try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = evt.undo_action } });
                }
            };

            try target_repo.core.db_file.lock(io, .exclusive);
            defer target_repo.core.db_file.unlock(io);

            const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
            history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
                .core = &target_repo.core,
                .io = io,
                .allocator = allocator,
                .events = events,
                .patch_id = patch_id,
                .forker_id = std.fmt.bytesToHex(input.user_id, .lower),
                .users_dir = server.users_dir,
                .first_parent = first_parent,
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => |e| return e,
            };
        }
        notify.subscribeParticipants(io, allocator, server, target_repo.core.work_path, events);
        evt.bumpRepoActivityAt(io, allocator, server, target_repo.core.work_path);

        // remove the consumed draft from the fork
        try evt.consume(.{ .server = server }, .fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = null },
        }});
    }

    // mark the fork as published in the forker's user repo
    if (fork_record.event.stage == .draft) {
        var published = fork_record.event;
        published.stage = .publish;
        try evt.consume(.{ .server = server }, .user, .xit, evt.user_repo_opts, io, allocator, &user_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .fork = published },
        }});
    }
}

pub fn editDraft(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    input: EditDraftInput,
) !bool {
    // validate the submitted fields before opening repositories
    if (!evt.Patch.fieldsValid(input.title, input.labels)) return error.InvalidFields;
    if (!evt.Patch.branchValid(input.target_branch)) return error.InvalidTargetBranch;
    const patch_id = try evt.parseEventId(&input.id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // validate the draft ownership and editing identity
    {
        var user_repo = (try evt.openUserRepo(io, allocator, users_dir, &input.user_id)) orelse return false;
        defer user_repo.deinit(io, allocator);
        const admin_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        const user_moment = (try evt.userMoment(&user_repo)) orelse return false;
        const fork_record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, user_moment, &arena, &patch_id)) orelse return false;
        if (fork_record.event.stage != .draft) return false;
        if (fork_record.removed or !std.mem.eql(u8, &fork_record.event.repo_id, &std.fmt.bytesToHex(input.repo_id, .lower))) return error.InvalidPatchDraft;
        const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &input.user_id)) orelse return error.InvalidPatchDraft;
        if (user.removed or
            !std.mem.eql(u8, user.event.name, input.author.name) or
            !std.mem.eql(u8, user.event.email, input.author.email)) return error.InvalidPatchDraft;
    }

    // read the draft patch from its fork
    const fork_path = try fork.forkPath(arena.allocator(), users_dir, &input.user_id, &patch_id);
    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return error.PatchDataUnavailable;
    defer fork_repo.deinit(io, allocator);
    const fork_moment = evt.currentMoment(repo_opts, &fork_repo) catch return error.PatchDataUnavailable;
    const record = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &patch_id)) orelse return error.PatchDataUnavailable;
    if (record.removed) return error.PatchDataUnavailable;

    // apply the edits and invalidate a revision targeting another branch
    var patch = record.event;
    patch.title = input.title;
    patch.labels = input.labels;
    patch.description = input.description;
    if (!std.mem.eql(u8, patch.target_branch, input.target_branch)) patch.revision = null;
    patch.target_branch = input.target_branch;

    // commit the updated draft metadata
    try evt.consume(.{ .server = .{ .users_dir = users_dir } }, .fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = patch },
    }});
    return true;
}

// merge the selected patch revision into its target branch
pub fn merge(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    target_repo: *rp.Repo(.xit, repo_opts),
    input: MergeInput,
) !void {
    const patch_id = try evt.parseEventId(&input.id);
    mergeInner(repo_opts, io, allocator, server, target_repo, input, patch_id) catch |err| {
        if (err == error.PatchDataUnavailable or err == error.PatchOutOfDate) {
            refreshMergeability(repo_opts, io, allocator, target_repo, server.users_dir, patch_id);
        }
        return err;
    };
}

fn mergeInner(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    target_repo: *rp.Repo(.xit, repo_opts),
    input: MergeInput,
    patch_id: [evt.event_id_size]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // validate the target patch
    const target_moment = try evt.currentMoment(repo_opts, target_repo);
    const patch_record = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, target_moment, &arena, &patch_id)) orelse return error.InvalidPatch;
    if (patch_record.removed) return error.InvalidPatch;
    switch (patch_record.event.status) {
        .open => {},
        .closed => return error.PatchClosed,
        .merged => return error.PatchAlreadyMerged,
    }
    const selected = patch_record.event.revision orelse return error.PatchNotPushed;
    const target_ref = rf.Ref{ .kind = .head, .name = patch_record.event.target_branch };

    // open the fork
    var fork_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (patch_record.event.source_branch != null) null else blk: {
        var config = try target_repo.listConfig(io, allocator);
        defer config.deinit();
        const forker_id = (try fork.readForkerId(&config.sections, &patch_id)) orelse return error.PatchDataUnavailable;
        const fork_path = try fork.forkPath(arena.allocator(), server.users_dir, &forker_id, &patch_id);
        break :blk rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return error.PatchDataUnavailable;
    };
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, allocator);

    // select the commit and merge identity
    const selected_oid = oidArray(repo_opts.hash, switch (input.revision) {
        .squash => selected.squash_oid,
        .source => selected.source_oid,
    }) catch return error.InvalidPatch;
    const identity = try arena.allocator().print("{s} <{s}>", .{ input.author.name, input.author.email });

    // merge the code and events in one target transaction
    {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            fork_repo: ?*rp.Repo(.xit, repo_opts),
            io: std.Io,
            allocator: std.mem.Allocator,
            patch_id: [evt.event_id_size]u8,
            expected_patch: evt.Patch,
            target_ref: rf.Ref,
            selected_oid: [hash.hexLen(repo_opts.hash)]u8,
            revision: evt.Patch.MergeRevision,
            identity: []const u8,
            author: evt.CommitAuthor,
            timestamp: u64,
            users_dir: []const u8,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

                var check_arena = std.heap.ArenaAllocator.init(ctx.allocator);
                defer check_arena.deinit();

                // require the fork's newest revision, read without a lock
                const selected_revision = ctx.expected_patch.revision orelse unreachable;
                const revision_id = try evt.parseEventId(&selected_revision.id);
                if (ctx.fork_repo) |repo| {
                    const fork_moment = try evt.currentMoment(repo_opts, repo);
                    const newest = (try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &check_arena)) orelse return error.PatchDataUnavailable;
                    if (!std.mem.eql(u8, &newest.id, &revision_id) or !selected_revision.matches(newest.record)) return error.PatchOutOfDate;
                } else if (!try branchCurrent(repo_opts, state.readOnly(), ctx.io, &check_arena, ctx.expected_patch)) return error.PatchOutOfDate;

                // require a clean cached result for the selected merge style.
                {
                    const availability = try readMergeability(repo_opts, state.readOnly(), ctx.io, &check_arena, &ctx.patch_id, ctx.expected_patch);
                    switch (availability.get(ctx.revision)) {
                        .clean => {},
                        .conflict => return error.MergeConflict,
                        .unknown => return error.MergeCheckUnavailable,
                    }
                }

                // copy the selected commit and its dependencies
                if (ctx.fork_repo) |repo| {
                    var fork_repo_moment = try repo.core.latestMoment();
                    const fork_state = State(.read_only){ .core = &repo.core, .extra = .{ .moment = &fork_repo_moment } };
                    var objects = try obj.ObjectIterator(.xit, repo_opts).init(fork_state, ctx.io, ctx.allocator, .{ .kind = .all });
                    defer objects.deinit();
                    try includeMissing(repo_opts, &objects, state.readOnly(), fork_state, ctx.io, ctx.allocator, &ctx.selected_oid);
                    try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, ctx.io, null);
                }

                // merge the selected commit
                const before_oid = (try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = ctx.target_ref })) orelse return error.InvalidTargetBranch;
                {
                    var merge_result = try mrg.Merge(.xit, repo_opts).init(state, ctx.io, ctx.allocator, .{
                        .kind = .full,
                        .action = .{ .new = .{ .source = &.{.{ .oid = &ctx.selected_oid }}, .algo = .patch } },
                        .commit_metadata = .{
                            .author = ctx.identity,
                            .committer = ctx.identity,
                            .message = ctx.expected_patch.title,
                            .timestamp = ctx.timestamp,
                        },
                    }, ctx.target_ref, null);
                    defer merge_result.deinit();
                    switch (merge_result.result) {
                        .conflict => return error.MergeConflict,
                        .success, .fast_forward, .nothing => {},
                        .clean => unreachable,
                    }
                }
                const after_oid = (try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = ctx.target_ref })) orelse return error.InvalidTargetBranch;

                // retain the submitted revision and snapshot the merge result
                if (!try importMergedRevision(repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.fork_repo, &ctx.patch_id, .{ .revision = ctx.revision, .before_oid = &before_oid, .after_oid = &after_oid }, ctx.expected_patch, ctx.author, ctx.timestamp)) return error.PatchOutOfDate;
                // the merge moved the target branch, so the other open patches'
                // checks are redone with it
                _ = try updateStaleMergeChecks(repo_opts, state, ctx.io, ctx.allocator, ctx.users_dir, null);

                // the merge moved the target branch, so its indexes follow,
                // the commit index deriving from the old tip's version
                _ = try find.refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, null);
                _ = try srch_cmmt.refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, &.{.{ .old_oid = &before_oid, .new_oid = &after_oid }}, null);

                // record the merge as one undoable action.
                try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = merge_undo_action } });
            }
        };

        try target_repo.core.db_file.lock(io, .exclusive);
        defer target_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
            .core = &target_repo.core,
            .fork_repo = if (fork_repo_maybe) |*repo| repo else null,
            .io = io,
            .allocator = allocator,
            .patch_id = patch_id,
            .expected_patch = patch_record.event,
            .target_ref = target_ref,
            .selected_oid = selected_oid,
            .revision = input.revision,
            .identity = identity,
            .author = input.author,
            .timestamp = input.timestamp,
            .users_dir = server.users_dir,
        });
    }
    evt.bumpRepoActivityAt(io, allocator, server, target_repo.core.work_path);
}

// merge a published patch and remove its fork
pub fn mergeAndRemoveFork(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    target_repo: *rp.Repo(.xit, repo_opts),
    input: MergeInput,
) !void {
    try merge(repo_opts, io, allocator, server, target_repo, input);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // remove fork data only for patches backed by a fork
    const patch_id = try evt.parseEventId(&input.id);
    const record = (try evt.readFromRepo(evt.Patch, .xit, repo_opts, io, allocator, &arena, target_repo, &patch_id)) orelse return error.InvalidPatch;
    if (record.event.source_branch != null) return;
    // a patch from another instance has no fork here
    const forker_id = blk: {
        var config = try target_repo.listConfig(io, allocator);
        defer config.deinit();
        break :blk (try fork.readForkerId(&config.sections, &patch_id)) orelse return;
    };
    try fork.remove(io, allocator, server.users_dir, &forker_id, &input.id, input.author);
}

fn commitAuthor(line: []const u8) !evt.CommitAuthor {
    const open = std.mem.lastIndexOfScalar(u8, line, '<') orelse return error.AuthorNotFound;
    const close = std.mem.indexOfScalarPos(u8, line, open + 1, '>') orelse return error.AuthorNotFound;
    const name = std.mem.trimEnd(u8, line[0..open], " ");
    if (name.len == 0 or close == open + 1) return error.AuthorNotFound;
    return .{ .name = name, .email = line[open + 1 .. close] };
}

// import a revision after detecting a client-side merge
fn importMerged(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    db: *evt.EventDB(repo_opts.hash),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    patch_id: *const [evt.event_id_size]u8,
    matched_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    before_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    after_oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // identify which selected revision was merged by the client.
    const events = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const record = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, events, &arena, patch_id)) orelse return;
    const selected = record.event.revision orelse return;
    const revision: evt.Patch.MergeRevision = if (std.mem.eql(u8, matched_oid, selected.source_oid)) .source else if (std.mem.eql(u8, matched_oid, selected.squash_oid)) .squash else return;

    // open the fork when the revision is not stored in the target repository.
    var fork_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (record.event.source_branch != null) null else blk: {
        var config = try xit.config.Config(.xit, repo_opts).init(state.readOnly(), io, allocator);
        defer config.deinit();
        const forker_id = (try fork.readForkerId(&config.sections, patch_id)) orelse return error.PatchDataUnavailable;
        const fork_path = try fork.forkPath(arena.allocator(), users_dir, &forker_id, patch_id);
        break :blk try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    };
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, allocator);

    // import the revision and record the client-side merge.
    _ = try importMergedRevision(repo_opts, state, db, moment, io, allocator, if (fork_repo_maybe) |*repo| repo else null, patch_id, .{ .revision = revision, .before_oid = before_oid, .after_oid = after_oid }, null, null, 0);
}

// import the revision and mark its patch merged in the current transaction
fn importMergedRevision(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    db: *evt.EventDB(repo_opts.hash),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    fork_repo: ?*rp.Repo(.xit, repo_opts),
    patch_id: *const [evt.event_id_size]u8,
    merged: struct {
        revision: evt.Patch.MergeRevision,
        before_oid: *const [hash.hexLen(repo_opts.hash)]u8,
        after_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    },
    expected_patch: ?evt.Patch,
    merged_author: ?evt.CommitAuthor,
    merged_timestamp: u64,
) !bool {
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // read the patch and reject outdated or conflicting merge requests.
    const haxy_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const patch_record = (try evt.Patch.readById(DB, repo_opts.hash, haxy_moment, &arena, patch_id)) orelse return false;
    const selected = patch_record.event.revision orelse return false;
    if (patch_record.removed or patch_record.event.status.kind() == .merged) return false;
    if (expected_patch) |expected| {
        if (!evt.fieldEqual(evt.Patch, expected, patch_record.event)) return false;
        if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key))) |cursor| {
            const conflicts = try DB.SortedMap(.read_only).init(cursor);
            if (try conflicts.getCursor(&evt.orderKeyDesc(patch_record.created_order, patch_id)) != null) return false;
        }
    }
    const revision_id = try evt.parseEventId(&selected.id);

    // resolve the selected revision from the target or its fork.
    const current_revision = try evt.PatchRev.readById(DB, repo_opts.hash, haxy_moment, &arena, &revision_id);
    const revision = (if (fork_repo) |repo|
        try evt.PatchRev.readById(DB, repo_opts.hash, try evt.currentMoment(repo_opts, repo), &arena, &revision_id)
    else
        current_revision) orelse return false;
    if (!selected.matches(revision)) return false;

    // read the original revision commit and author.
    var fork_repo_moment = if (fork_repo) |repo| try repo.core.latestMoment() else moment.readOnly();
    const fork_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = if (fork_repo) |repo| &repo.core else state.core, .extra = .{ .moment = &fork_repo_moment } };
    var event_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    if (revision.event_oid.len != event_oid.len) return false;
    @memcpy(&event_oid, revision.event_oid);
    var event_object = try obj.Object(.xit, repo_opts).initCommit(fork_state, io, allocator, &event_oid);
    defer event_object.deinit();
    const original_author = try commitAuthor(event_object.content.commit.metadata.author orelse return false);

    // retain the submitted revision if the target has not imported it yet.
    var events_buffer: [3]evt.EventWithId = undefined;
    var events: std.ArrayList(evt.EventWithId) = .initBuffer(&events_buffer);
    var tree_entries: [2]evt.EventTreeEntry = undefined;
    const needs_import = if (current_revision) |existing| existing.removed else true;
    if (needs_import) {
        tree_entries = .{
            .{ .tree = .{ .name = "base", .oid = revision.base_tree_oid } },
            .{ .tree = .{ .name = "head", .oid = revision.head_tree_oid } },
        };
        events.appendAssumeCapacity(.{
            .id = selected.id,
            .timestamp = event_object.content.commit.metadata.timestamp,
            .author = original_author,
            .tree_entries = &tree_entries,
            .event = .{ .patchrev = revision.event },
        });
    } else {
        const existing = current_revision orelse unreachable;
        if (!selected.matches(existing)) return error.InvalidPatch;
    }

    // snapshot the merge result and mark the patch as merged.
    {
        const author = merged_author orelse original_author;
        const timestamp = if (merged_author != null) merged_timestamp else @as(u64, @intCast(std.Io.Timestamp.now(io, .real).toSeconds()));
        var patch = patch_record.event;
        const result = try evt.PatchRev.prepare(.xit, repo_opts, state, io, &arena, merged.before_oid, merged.after_oid, patch.title, author, timestamp);
        events.appendAssumeCapacity(result.event);
        patch.status = .{ .merged = .{ .revision = merged.revision, .patchrev_id = result.event.id } };
        events.appendAssumeCapacity(.{
            .id = std.fmt.bytesToHex(patch_id.*, .lower),
            .timestamp = timestamp,
            .author = author,
            .event = .{ .patch = patch },
        });
    }

    // commit and consume the revision and patch events together.
    try evt.commitEvents(.xit, repo_opts, state, io, allocator, evt.events_ref, events.items, null);
    _ = try evt.consumeInTransaction(.repo, .xit, repo_opts, state, db, moment, io, allocator, evt.events_ref);
    return true;
}

// find patches merged by commits received in a push
pub fn detectMerged(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    db: *evt.EventDB(repo_opts.hash),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    updates: []const xit.net_server_receive_pack.AppliedRefUpdate,
    error_writer: *std.Io.Writer,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // read the revision index used to identify merged patches.
    const haxy_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const revisions_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.revision_to_id_set_key)) orelse return;
    const revisions = try DB.HashMap(.read_only).init(revisions_cursor);

    // ignore event refs and inspect only changed branch tips.
    var events_ref_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const events_ref_path = try evt.events_ref.toPath(&events_ref_buffer);
    const heads_prefix = "refs/heads/";
    for (updates) |update| {
        if (!std.mem.startsWith(u8, update.ref_name, heads_prefix) or
            std.mem.eql(u8, update.ref_name, events_ref_path) or
            std.mem.eql(u8, update.old_oid, update.new_oid)) continue;

        // validate the ref tips and skip branch deletions.
        if (update.old_oid.len != hash.hexLen(repo_opts.hash) or
            update.new_oid.len != hash.hexLen(repo_opts.hash)) return error.InvalidOid;
        var old_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        var new_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        @memcpy(&old_oid, update.old_oid);
        @memcpy(&new_oid, update.new_oid);
        if (std.mem.allEqual(u8, &new_oid, '0')) continue;

        // traverse commits introduced by this branch update.
        var commits = try obj.ObjectIterator(.xit, repo_opts).init(state.readOnly(), io, arena.allocator(), .{ .kind = .commit });
        defer commits.deinit();
        if (!std.mem.allEqual(u8, &old_oid, '0')) try commits.exclude(&old_oid);
        var targets: std.ArrayList(struct {
            before_oid: [hash.hexLen(repo_opts.hash)]u8,
            after_oid: [hash.hexLen(repo_opts.hash)]u8,
        }) = .empty;

        // collect merge boundaries along the target's first-parent history.
        {
            var first_parents = try obj.ObjectIterator(.xit, repo_opts).init(state.readOnly(), io, arena.allocator(), .{ .kind = .commit, .first_parent = true });
            defer first_parents.deinit();
            if (!std.mem.allEqual(u8, &old_oid, '0')) try first_parents.exclude(&old_oid);
            try first_parents.include(&new_oid);
            while (try first_parents.next(arena.allocator())) |commit| {
                defer commit.deinit();
                try targets.append(arena.allocator(), .{
                    .before_oid = (commit.content.commit.metadata.firstParent() orelse &old_oid).*,
                    .after_oid = commit.oid,
                });
            }
        }

        // visit target commits oldest first, attributing each revision to the
        // commit that introduced it; the shared iterator visits each ancestor once
        var revision_key_buffer: [rf.MAX_REF_CONTENT_SIZE + 1 + hash.hexLen(repo_opts.hash)]u8 = undefined;
        while (targets.pop()) |target| {
            try commits.include(&target.after_oid);
            while (try commits.next(arena.allocator())) |commit| {
                defer commit.deinit();

                // find patches whose selected revision matches this commit.
                const key = try std.fmt.bufPrint(&revision_key_buffer, "{s}\x00{s}", .{ update.ref_name[heads_prefix.len..], &commit.oid });
                const ids_cursor = try revisions.getCursor(hash.hashInt(repo_opts.hash, key)) orelse continue;
                const ids = try DB.CountedHashSet(.read_only).init(ids_cursor);
                var ids_iter = try ids.iterator();
                while (try ids_iter.next()) |cursor| {
                    const pair = try cursor.readKeyValuePair();
                    var patch_id: [evt.event_id_size]u8 = undefined;
                    if ((try pair.key_cursor.readBytes(&patch_id)).len != patch_id.len) return error.InvalidPatch;
                    const patch_hex = std.fmt.bytesToHex(patch_id, .lower);

                    // a fast-forward has no recorded merge boundary; use the old ref tip
                    const before_oid = if (std.mem.eql(u8, &commit.oid, &target.after_oid)) &old_oid else &target.before_oid;
                    importMerged(repo_opts, state, db, moment, io, allocator, users_dir, &patch_id, &commit.oid, before_oid, &target.after_oid) catch |err| {
                        serve_common.logError(io, error_writer, "failed to mark patch {s} as merged: {s}\n", .{ &patch_hex, @errorName(err) });
                        continue;
                    };
                }
            }
        }
    }
}

const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const rf = xit.ref;
const mrg = xit.merge;
const find = @import("find.zig");
const cms = @import("search_commit.zig");
const fork = @import("fork.zig");
const serve_common = @import("serve_common.zig");

// capture an existing branch without creating a fork
pub fn writeBranchPatch(
    host_kind: evt.HostKind,
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
    if (repo_kind == .git) {
        if (expected_patch) |expected| {
            const current = (try evt.readFromRepo(evt.Patch, repo_kind, repo_opts, io, allocator, &arena, repo, &try evt.parseEventId(&id))) orelse return error.PatchOutOfDate;
            if (current.removed or !evt.fieldEqual(evt.Patch, current.event, expected)) return error.PatchOutOfDate;
        }
        const events = try branchEvents(repo_kind, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, &arena, id, patch, author);
        try evt.consume(host_kind, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events);
    } else {
        const DB = evt.EventDB(repo_opts.hash);
        var first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8 = null;
        if (try repo.readRef(io, evt.events_ref) == null) {
            var remotes = try repo.listRemotes(io, allocator);
            defer remotes.deinit();
            for (remotes.sections.keys()) |name| {
                if (try repo.readRef(io, .{ .kind = .{ .remote = name }, .name = evt.events_ref.name })) |oid| {
                    first_parent = .{oid};
                    break;
                }
            }
        }
        const Ctx = struct {
            repo: *rp.Repo(repo_kind, repo_opts),
            io: std.Io,
            arena: *std.heap.ArenaAllocator,
            id: [evt.event_id_size * 2]u8,
            patch: evt.Patch,
            expected_patch: ?evt.Patch,
            author: evt.CommitAuthor,
            first_parent: ?[1][hash.hexLen(repo_opts.hash)]u8,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = rp.Repo(repo_kind, repo_opts).State(.read_write){ .core = &ctx.repo.core, .extra = .{ .moment = &moment } };
                if (ctx.expected_patch) |expected| {
                    const events_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
                    const current = (try evt.Patch.readById(DB, repo_opts.hash, events_moment, ctx.arena, &try evt.parseEventId(&ctx.id))) orelse return error.PatchOutOfDate;
                    if (current.removed or !evt.fieldEqual(evt.Patch, current.event, expected)) return error.PatchOutOfDate;
                }
                const events = try branchEvents(repo_kind, repo_opts, state, ctx.io, ctx.arena, ctx.id, ctx.patch, ctx.author);
                const parent = if (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), ctx.io, .{ .ref = evt.events_ref }) == null) ctx.first_parent else null;
                try evt.commitEvents(repo_kind, repo_opts, state, ctx.io, ctx.arena.child_allocator, evt.events_ref, &events, parent);
                if (!try evt.consumeInTransaction(.repo, repo_kind, repo_opts, state, &ctx.repo.core.db, &moment, ctx.io, ctx.arena.child_allocator, evt.events_ref)) return error.CancelTransaction;
                try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action = "update_patch" } });
            }
        };
        {
            try repo.core.db_file.lock(io, .exclusive);
            defer repo.core.db_file.unlock(io);
            const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .repo = repo, .io = io, .arena = &arena, .id = id, .patch = patch, .expected_patch = expected_patch, .author = author, .first_parent = first_parent });
        }
        if (host_kind == .server) refreshMergeability(repo_opts, io, allocator, repo, try evt.parseEventId(&id));
    }
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
    const branch = patch.source_branch orelse return error.InvalidSourceBranch;
    if (!evt.Patch.fieldsValid(patch.title, patch.tags)) return error.InvalidFields;
    if (!evt.Patch.branchValid(branch)) return error.InvalidSourceBranch;
    if (!evt.Patch.branchValid(patch.target_branch)) return error.InvalidTargetBranch;
    const source = (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = branch } })) orelse return error.InvalidSourceBranch;
    const target = (try rf.readRecur(repo_kind, repo_opts, state.readOnly(), io, .{ .ref = .{ .kind = .head, .name = patch.target_branch } })) orelse return error.InvalidTargetBranch;
    if (std.mem.eql(u8, branch, patch.target_branch)) return error.SameBranch;
    const base = mrg.commonAncestor(repo_kind, repo_opts, state.readOnly(), io, arena.allocator(), &target, &source) catch |err| switch (err) {
        error.NoCommonAncestor => return error.UnrelatedBranches,
        else => return err,
    };
    const timestamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const prepared = try evt.PatchRev.prepare(repo_kind, repo_opts, state, io, arena, &base, &source, patch.title, author, timestamp);
    var updated = patch;
    updated.revision = prepared.revision;
    return .{
        prepared.event,
        .{ .id = id, .author = author, .timestamp = timestamp, .event = .{ .patch = updated } },
    };
}

// refresh open patches' tracked branches and, on the server, their mergeability.
// this runs outside the caller's transaction.
pub fn refreshBranches(
    host_kind: evt.HostKind,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var patches: std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, ?evt.Patch.Record) = .empty;
    defer patches.deinit(allocator);
    collect: {
        var local_db: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
        defer if (local_db) |*db| db.deinit(io, allocator);
        const moment = (if (local_db) |*db| evt.currentMomentFromDb(repo_opts.hash, db.db) else if (repo_kind == .git) break :collect else evt.currentMoment(repo_opts, repo)) catch |err| switch (err) {
            error.NotFound => break :collect,
            else => return err,
        };
        if (repo_kind == .xit and host_kind == .server) open: {
            const statuses_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key)) orelse break :open;
            const statuses = try DB.SortedMap(.read_only).init(statuses_cursor);
            const open_cursor = try statuses.getCursor("open") orelse break :open;
            const open_patches = try DB.SortedSet(.read_only).init(open_cursor);
            var iter = try open_patches.iteratorFromIndex(0);
            while (try iter.next()) |cursor| try patches.put(allocator, try evt.readOrderKeyId(DB, cursor), null);
        }
        const source_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.source_to_id_set_key)) orelse break :collect;
        const sources = try DB.SortedMap(.read_only).init(source_cursor);
        const conflicts = if (try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key))) |cursor| try DB.SortedMap(.read_only).init(cursor) else null;
        var iter = try sources.iterator();
        while (try iter.next()) |cursor| {
            const pair = try cursor.readKeyValuePair();
            const branch = try pair.key_cursor.readBytesAlloc(arena.allocator(), null);
            if (updates) |changed| {
                var found = false;
                for (changed) |update| {
                    if (std.mem.startsWith(u8, update.ref_name, "refs/heads/") and std.mem.eql(u8, update.ref_name["refs/heads/".len..], branch)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }
            const source = (try repo.readRef(io, .{ .kind = .head, .name = branch })) orelse {
                if (host_kind == .server) std.log.warn("patch source branch missing: {s}", .{branch});
                continue;
            };
            const ids = try DB.CountedHashSet(.read_only).init(pair.value_cursor);
            var ids_iter = try ids.iterator();
            while (try ids_iter.next()) |id_cursor| {
                const id_pair = try id_cursor.readKeyValuePair();
                var id: [evt.event_id_size]u8 = undefined;
                if ((try id_pair.key_cursor.readBytes(&id)).len != id.len) return error.InvalidPatch;
                const record = (try evt.Patch.readById(DB, repo_opts.hash, moment, &arena, &id)) orelse continue;
                if (record.removed or record.event.status.kind() != .open) continue;
                if (conflicts) |map| if (try map.getCursor(&evt.orderKeyDesc(record.created_order, &id)) != null) continue;
                if (record.event.revision) |revision| if (std.mem.eql(u8, revision.source_oid, &source)) continue;
                try patches.put(allocator, id, record);
            }
        }
    }
    if (repo_opts.ProgressCtx != void) {
        if (progress_ctx_maybe) |progress_ctx| progress_ctx.run(io, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = patches.count() } }) catch {};
    }
    for (patches.keys(), patches.values()) |id, record_maybe| {
        if (record_maybe) |record| {
            const author = evt.CommitAuthor{ .name = "haxy", .email = record.author_email orelse "user@haxy" };
            writeBranchPatch(host_kind, repo_kind, repo_opts, io, allocator, repo, std.fmt.bytesToHex(id, .lower), record.event, record.event, author) catch |err| {
                if (host_kind == .server) std.log.warn("failed to refresh branch patch: {s}", .{@errorName(err)});
            };
        }
        if (repo_kind == .xit and host_kind == .server) refreshMergeability(repo_opts, io, allocator, repo, id);
        if (repo_opts.ProgressCtx != void) {
            if (progress_ctx_maybe) |progress_ctx| progress_ctx.run(io, .{ .complete_one = .writing_patch }) catch {};
        }
    }
    if (repo_opts.ProgressCtx != void) {
        if (progress_ctx_maybe) |progress_ctx| progress_ctx.run(io, .{ .end = .writing_patch }) catch {};
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
    tags: []const u8,
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
};

fn readMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
) !?MergeCheck {
    const DB = evt.EventDB(repo_opts.hash);
    const map_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.patch_id_to_mergeability_key)) orelse return null;
    const map = try DB.HashMap(.read_only).init(map_cursor);
    const cursor = try map.getCursor(hash.hashInt(repo_opts.hash, id)) orelse return null;
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
    if (patch.source_branch != null and !try branchCurrent(repo_opts, state, io, arena, patch)) return .{};
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
    id_maybe: ?[evt.event_id_size]u8,
) void {
    refreshMergeChecks(repo_opts, io, allocator, target_repo, id_maybe) catch |err| {
        std.log.warn("failed to refresh mergeability: {s}", .{@errorName(err)});
    };
}

fn refreshMergeChecks(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    id_maybe: ?[evt.event_id_size]u8,
) !void {
    if (id_maybe) |id| return refreshMergeCheck(repo_opts, io, allocator, target_repo, &id);
    const DB = evt.EventDB(repo_opts.hash);
    const moment = evt.currentMoment(repo_opts, target_repo) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    const statuses_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key)) orelse return;
    const statuses = try DB.SortedMap(.read_only).init(statuses_cursor);
    const open_cursor = try statuses.getCursor("open") orelse return;
    const open = try DB.SortedSet(.read_only).init(open_cursor);
    var ids: std.ArrayList([evt.event_id_size]u8) = .empty;
    defer ids.deinit(allocator);
    var iter = try open.iteratorFromIndex(0);
    while (try iter.next()) |cursor| try ids.append(allocator, try evt.readOrderKeyId(DB, cursor));
    for (ids.items) |id| refreshMergeability(repo_opts, io, allocator, target_repo, id);
}

fn refreshMergeCheck(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    id: *const [evt.event_id_size]u8,
) !void {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const initial = (try evt.readFromRepo(evt.Patch, .xit, repo_opts, io, allocator, &arena, target_repo, id)) orelse return;
    if (initial.removed or initial.event.status.kind() != .open) return;
    const repo_root_path = std.fs.path.dirname(target_repo.core.work_path) orelse ".";
    const path = try fork.forkPath(arena.allocator(), repo_root_path, &std.fmt.bytesToHex(id.*, .lower));
    const branch_backed = initial.event.source_branch != null;
    var fork_repo_maybe: ?Repo = if (branch_backed) null else Repo.open(io, allocator, .{ .path = path, .require_repo_root = true }) catch |err| blk: {
        std.log.warn("mergeability fork unavailable: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, allocator);
    if (fork_repo_maybe) |*repo| try repo.core.db_file.lock(io, .shared);
    defer if (fork_repo_maybe) |*repo| repo.core.db_file.unlock(io);
    try target_repo.core.db_file.lock(io, .exclusive);
    defer target_repo.core.db_file.unlock(io);

    var target_moment = try target_repo.core.latestMoment();
    const target_state = Repo.State(.read_only){ .core = &target_repo.core, .extra = .{ .moment = &target_moment } };
    const target_events = evt.currentMomentFromRepoMoment(repo_opts.hash, target_moment) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    const patch_record = (try evt.Patch.readById(DB, repo_opts.hash, target_events, &arena, id)) orelse return;
    if (patch_record.removed or patch_record.event.status.kind() != .open) return;
    var newest: ?evt.PatchRev.WithId = null;
    if (fork_repo_maybe) |*repo| {
        if (evt.currentMoment(repo_opts, repo)) |events| {
            newest = evt.PatchRev.readNewest(DB, repo_opts.hash, events, &arena) catch |err| blk: {
                std.log.warn("mergeability revision unavailable: {s}", .{@errorName(err)});
                break :blk null;
            };
        } else |err| std.log.warn("mergeability revision unavailable: {s}", .{@errorName(err)});
    }
    const patch = patch_record.event;
    const revision = patch.revision orelse return;
    const target_oid = try rf.readRecur(.xit, repo_opts, target_state, io, .{ .ref = .{ .kind = .head, .name = patch.target_branch } });
    var check = MergeCheck{ .revision = revision, .target_branch = patch.target_branch, .target_oid = if (target_oid) |*oid| oid else "" };
    const cached = try readMergeCheck(repo_opts, target_events, &arena, id);
    const current = if (patch.source_branch != null) try branchCurrent(repo_opts, target_state, io, &arena, patch) else if (newest) |latest| std.mem.eql(u8, &std.fmt.bytesToHex(latest.id, .lower), &revision.id) and revision.matches(latest.record) else false;
    if (current and target_oid != null) {
        if (cached) |value| if (value.matches(patch, check.target_oid) and value.result.source != .unknown and value.result.squash != .unknown) return;
        const Ctx = struct {
            repo: *Repo,
            fork_repo: ?*Repo,
            io: std.Io,
            allocator: std.mem.Allocator,
            check: *MergeCheck,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = Repo.State(.read_write){ .core = &ctx.repo.core, .extra = .{ .moment = &moment } };
                const source = try oidArray(repo_opts.hash, ctx.check.revision.source_oid);
                const squash = try oidArray(repo_opts.hash, ctx.check.revision.squash_oid);
                if (ctx.fork_repo) |repo| {
                    var fork_moment = try repo.core.latestMoment();
                    const fork_state = Repo.State(.read_only){ .core = &repo.core, .extra = .{ .moment = &fork_moment } };
                    var objects = try obj.ObjectIterator(.xit, repo_opts).init(fork_state, ctx.io, ctx.allocator, .{ .kind = .all });
                    defer objects.deinit();
                    try objects.include(&source);
                    try objects.include(&squash);
                    try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, ctx.io, null);
                }
                const target = rf.Ref{ .kind = .head, .name = ctx.check.target_branch };
                ctx.check.result.source = checkCommit(repo_opts, state, ctx.io, ctx.allocator, &source, target);
                ctx.check.result.squash = checkCommit(repo_opts, state, ctx.io, ctx.allocator, &squash, target);
                return error.CancelTransaction;
            }
        };
        const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
        history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
            .repo = target_repo,
            .fork_repo = if (fork_repo_maybe) |*repo| repo else null,
            .io = io,
            .allocator = allocator,
            .check = &check,
        }) catch |err| switch (err) {
            error.CancelTransaction => {},
            else => std.log.warn("mergeability check failed: {s}", .{@errorName(err)}),
        };
    }
    if (cached) |value| if (evt.fieldEqual(MergeCheck, value, check)) return;
    const Save = struct {
        id: [evt.event_id_size]u8,
        check: MergeCheck,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const moment = try DB.HashMap(.read_write).init(cursor.*);
            const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.last_object_id_key)) orelse return error.NotFound;
            var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try last_object_id_cursor.readBytes(&last_object_id);
            const haxy_history = try DB.ArrayList(.read_write).init(try moment.putCursor(hash.hashInt(repo_opts.hash, evt.history_key)));
            const haxy_moments = try DB.HashMap(.read_write).init(try haxy_history.putCursor(-1));
            const haxy_moment = try DB.HashMap(.read_write).init(try haxy_moments.putCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)));
            const map = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(repo_opts.hash, evt.Patch.patch_id_to_mergeability_key)));
            const entry = try DB.HashMap(.read_write).init(try map.putCursor(hash.hashInt(repo_opts.hash, &ctx.id)));
            try evt.upsert(MergeCheck, DB, repo_opts.hash, entry, ctx.check);
            // discard the old repo-level cache as results are rebuilt here
            _ = try moment.remove(hash.hashInt(repo_opts.hash, evt.Patch.patch_id_to_mergeability_key));
        }
    };
    const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Save{ .id = id.*, .check = check });
}

fn branchCurrent(comptime repo_opts: rp.RepoOpts(.xit), state: rp.Repo(.xit, repo_opts).State(.read_only), io: std.Io, arena: *std.heap.ArenaAllocator, patch: evt.Patch) !bool {
    const branch = patch.source_branch orelse return false;
    const selected = patch.revision orelse return false;
    const oid = (try rf.readRecur(.xit, repo_opts, state, io, .{ .ref = .{ .kind = .head, .name = branch } })) orelse return false;
    if (!std.mem.eql(u8, &oid, selected.source_oid)) return false;
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
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    fork_path: []const u8,
    input: PublishInput,
) !void {
    const patch_id = try evt.parseEventId(&input.id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const fork_record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &patch_id)) orelse return error.InvalidPatchDraft;
    if (fork_record.removed or
        !std.mem.eql(u8, fork_record.event.user_id, &input.user_id) or
        !std.mem.eql(u8, fork_record.event.repo_id, &input.repo_id)) return error.InvalidPatchDraft;
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &input.user_id)) orelse return error.InvalidPatchDraft;
    if (user.removed or
        !std.mem.eql(u8, user.event.name, input.author.name) or
        !std.mem.eql(u8, user.event.email, input.author.email)) return error.InvalidPatchDraft;

    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path }) catch return error.PatchDataUnavailable;
    defer fork_repo.deinit(io, allocator);
    const fork_moment = evt.currentMoment(repo_opts, &fork_repo) catch return error.PatchDataUnavailable;
    const local_patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &patch_id)) orelse return error.PatchDataUnavailable;

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

        try evt.consume(.server, .repo, .xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = patch },
        }});

        try evt.consume(.server, .fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = null },
        }});
    }

    if (fork_record.event.stage == .draft) {
        var published = fork_record.event;
        published.stage = .publish;
        try evt.consume(.server, .admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, evt.events_ref, &.{.{
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
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    fork_path: []const u8,
    input: EditDraftInput,
) !bool {
    if (!evt.Patch.fieldsValid(input.title, input.tags)) return error.InvalidFields;
    if (!evt.Patch.branchValid(input.target_branch)) return error.InvalidTargetBranch;
    const patch_id = try evt.parseEventId(&input.id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const fork_record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &patch_id)) orelse return false;
    if (fork_record.event.stage != .draft) return false;
    if (fork_record.removed or
        !std.mem.eql(u8, fork_record.event.user_id, &input.user_id) or
        !std.mem.eql(u8, fork_record.event.repo_id, &input.repo_id)) return error.InvalidPatchDraft;
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &input.user_id)) orelse return error.InvalidPatchDraft;
    if (user.removed or
        !std.mem.eql(u8, user.event.name, input.author.name) or
        !std.mem.eql(u8, user.event.email, input.author.email)) return error.InvalidPatchDraft;

    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return error.PatchDataUnavailable;
    defer fork_repo.deinit(io, allocator);
    const fork_moment = evt.currentMoment(repo_opts, &fork_repo) catch return error.PatchDataUnavailable;
    const record = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &patch_id)) orelse return error.PatchDataUnavailable;
    if (record.removed) return error.PatchDataUnavailable;

    var patch = record.event;
    patch.title = input.title;
    patch.tags = input.tags;
    patch.description = input.description;
    if (!std.mem.eql(u8, patch.target_branch, input.target_branch)) patch.revision = null;
    patch.target_branch = input.target_branch;
    try evt.consume(.server, .fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
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
    repo_root_path: []const u8,
    target_repo: *rp.Repo(.xit, repo_opts),
    input: MergeInput,
) !void {
    const patch_id = try evt.parseEventId(&input.id);
    errdefer |err| {
        if (err == error.PatchDataUnavailable or err == error.PatchOutOfDate) {
            refreshMergeability(repo_opts, io, allocator, target_repo, patch_id);
        }
    }
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
    const fork_path = try fork.forkPath(arena.allocator(), repo_root_path, &input.id);
    var fork_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (patch_record.event.source_branch != null) null else rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return error.PatchDataUnavailable;
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, allocator);
    // select the commit and merge identity
    const selected_oid = oidArray(repo_opts.hash, switch (input.revision) {
        .squash => selected.squash_oid,
        .source => selected.source_oid,
    }) catch return error.InvalidPatch;
    const identity = try std.fmt.allocPrint(arena.allocator(), "{s} <{s}>", .{ input.author.name, input.author.email });

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

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

                var check_arena = std.heap.ArenaAllocator.init(ctx.allocator);
                defer check_arena.deinit();

                // require the fork's newest revision while both repos are locked
                const selected_revision = ctx.expected_patch.revision orelse unreachable;
                const revision_id = try evt.parseEventId(&selected_revision.id);
                if (ctx.fork_repo) |repo| {
                    const fork_moment = try evt.currentMoment(repo_opts, repo);
                    const newest = (try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &check_arena)) orelse return error.PatchDataUnavailable;
                    if (!std.mem.eql(u8, &newest.id, &revision_id) or !selected_revision.matches(newest.record)) return error.PatchOutOfDate;
                } else if (!try branchCurrent(repo_opts, state.readOnly(), ctx.io, &check_arena, ctx.expected_patch)) return error.PatchOutOfDate;

                const availability = try readMergeability(repo_opts, state.readOnly(), ctx.io, &check_arena, &ctx.patch_id, ctx.expected_patch);
                switch (availability.get(ctx.revision)) {
                    .clean => {},
                    .conflict => return error.MergeConflict,
                    .unknown => return error.MergeCheckUnavailable,
                }

                // copy the selected commit and its dependencies
                if (ctx.fork_repo) |repo| {
                    var fork_repo_moment = try repo.core.latestMoment();
                    const fork_state = State(.read_only){ .core = &repo.core, .extra = .{ .moment = &fork_repo_moment } };
                    var objects = try obj.ObjectIterator(.xit, repo_opts).init(fork_state, ctx.io, ctx.allocator, .{ .kind = .all });
                    defer objects.deinit();
                    try objects.include(&ctx.selected_oid);
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

                try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action = "merge_patch" } });
            }
        };

        if (fork_repo_maybe) |*repo| try repo.core.db_file.lock(io, .shared);
        defer if (fork_repo_maybe) |*repo| repo.core.db_file.unlock(io);
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
        });
    }
    refreshMergeability(repo_opts, io, allocator, target_repo, null);
    // the merge moved the target branch, so its indexes follow
    find.refresh(repo_opts, io, allocator, target_repo) catch |err| {
        std.log.warn("failed to refresh file index: {s}", .{@errorName(err)});
    };
    cms.refresh(repo_opts, io, allocator, target_repo, null) catch |err| {
        std.log.warn("failed to refresh commit index: {s}", .{@errorName(err)});
    };
}

// merge a published patch and remove its fork
pub fn mergeAndRemoveFork(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    input: MergeInput,
) !void {
    try merge(repo_opts, io, allocator, repo_root_path, target_repo, input);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const record = (try evt.readFromRepo(evt.Patch, .xit, repo_opts, io, allocator, &arena, target_repo, &try evt.parseEventId(&input.id))) orelse return error.InvalidPatch;
    if (record.event.source_branch == null) try fork.remove(io, allocator, repo_root_path, admin_repo, &input.id, null, input.author);
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
    repo_root_path: []const u8,
    patch_id: *const [evt.event_id_size]u8,
    matched_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    before_oid: *const [hash.hexLen(repo_opts.hash)]u8,
    after_oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const patch_hex = std.fmt.bytesToHex(patch_id.*, .lower);
    const fork_path = try fork.forkPath(arena.allocator(), repo_root_path, &patch_hex);
    const events = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const record = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, events, &arena, patch_id)) orelse return;
    const selected = record.event.revision orelse return;
    const revision: evt.Patch.MergeRevision = if (std.mem.eql(u8, matched_oid, selected.source_oid)) .source else if (std.mem.eql(u8, matched_oid, selected.squash_oid)) .squash else return;
    var fork_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (record.event.source_branch != null) null else try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer if (fork_repo_maybe) |*repo| repo.deinit(io, allocator);

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

    const current_revision = try evt.PatchRev.readById(DB, repo_opts.hash, haxy_moment, &arena, &revision_id);
    const revision = (if (fork_repo) |repo|
        try evt.PatchRev.readById(DB, repo_opts.hash, try evt.currentMoment(repo_opts, repo), &arena, &revision_id)
    else
        current_revision) orelse return false;
    if (!selected.matches(revision)) return false;

    var fork_repo_moment = if (fork_repo) |repo| try repo.core.latestMoment() else moment.readOnly();
    const fork_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = if (fork_repo) |repo| &repo.core else state.core, .extra = .{ .moment = &fork_repo_moment } };
    var event_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    if (revision.event_oid.len != event_oid.len) return false;
    @memcpy(&event_oid, revision.event_oid);
    var event_object = try obj.Object(.xit, repo_opts).initCommit(fork_state, io, allocator, &event_oid);
    defer event_object.deinit();
    const original_author = try commitAuthor(event_object.content.commit.metadata.author orelse return false);

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

    try evt.commitEvents(.xit, repo_opts, state, io, allocator, evt.events_ref, events.items, null);
    if (!try evt.consumeInTransaction(.repo, .xit, repo_opts, state, db, moment, io, allocator, evt.events_ref)) return error.CancelTransaction;
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
    repo_root_path: []const u8,
    updates: []const xit.net_server_receive_pack.AppliedRefUpdate,
    error_writer: *std.Io.Writer,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const haxy_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const revisions_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.revision_to_id_set_key)) orelse return;
    const revisions = try DB.HashMap(.read_only).init(revisions_cursor);
    var events_ref_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const events_ref_path = try evt.events_ref.toPath(&events_ref_buffer);
    const heads_prefix = "refs/heads/";
    for (updates) |update| {
        if (!std.mem.startsWith(u8, update.ref_name, heads_prefix) or
            std.mem.eql(u8, update.ref_name, events_ref_path) or
            std.mem.eql(u8, update.old_oid, update.new_oid)) continue;
        if (update.old_oid.len != hash.hexLen(repo_opts.hash) or
            update.new_oid.len != hash.hexLen(repo_opts.hash)) return error.InvalidOid;
        var old_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        var new_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        @memcpy(&old_oid, update.old_oid);
        @memcpy(&new_oid, update.new_oid);
        if (std.mem.allEqual(u8, &new_oid, '0')) continue;

        var commits = try obj.ObjectIterator(.xit, repo_opts).init(state.readOnly(), io, arena.allocator(), .{ .kind = .commit });
        defer commits.deinit();
        if (!std.mem.allEqual(u8, &old_oid, '0')) try commits.exclude(&old_oid);
        var targets: std.ArrayList(struct {
            before_oid: [hash.hexLen(repo_opts.hash)]u8,
            after_oid: [hash.hexLen(repo_opts.hash)]u8,
        }) = .empty;
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
                    importMerged(repo_opts, state, db, moment, io, allocator, repo_root_path, &patch_id, &commit.oid, before_oid, &target.after_oid) catch |err| {
                        serve_common.logError(io, error_writer, "failed to mark patch {s} as merged: {s}\n", .{ &patch_hex, @errorName(err) });
                        continue;
                    };
                }
            }
        }
    }
}

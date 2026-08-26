const std = @import("std");
const evt = @import("event.zig");
const serve_common = @import("serve_common.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const mrg = xit.merge;
const bch = xit.branch;
const rf = xit.ref;

pub const ref = rf.Ref{ .kind = .head, .name = "patch" };
const ref_path = "refs/heads/patch";

pub const Route = struct {
    identity: []const u8,
    id: [evt.event_id_size * 2]u8,
    target: []const u8,
};

pub fn parseRoute(route_path: []const u8) ?Route {
    const patch_segment = "/patch:";
    const branch_segment = "/branch:";
    const patch_start = std.mem.indexOf(u8, route_path, patch_segment) orelse return null;
    const branch_start = std.mem.indexOfPos(u8, route_path, patch_start + patch_segment.len, branch_segment) orelse return null;
    const identity = route_path[0..patch_start];
    const id_text = route_path[patch_start + patch_segment.len .. branch_start];
    const target = route_path[branch_start + branch_segment.len ..];
    if (identity.len == 0 or target.len == 0 or id_text.len != evt.event_id_size * 2) return null;
    const id_bytes = evt.parseEventId(id_text) catch return null;
    return .{ .identity = identity, .id = std.fmt.bytesToHex(id_bytes, .lower), .target = target };
}

pub fn forkPath(allocator: std.mem.Allocator, repo_root_path: []const u8, id: []const u8) ![]u8 {
    _ = try evt.parseEventId(id);
    return try std.fs.path.join(allocator, &.{ std.fs.path.dirname(repo_root_path) orelse ".", "forks", id });
}

pub const CreateInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    title: []const u8,
    description: []const u8,
    tags: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn create(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    input: CreateInput,
) ![]u8 {
    if (!evt.Patch.fieldsValid(input.title, input.tags)) return error.InvalidPatch;

    // get the fork id and path
    const fork_id = try evt.parseEventId(&input.id);
    const fork_path = try forkPath(allocator, repo_root_path, &input.id);
    errdefer allocator.free(fork_path);

    // make sure the fork id doesn't already exist
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const existing = if (evt.currentMoment(evt.admin_repo_opts, admin_repo)) |moment|
        try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)
    else |err| switch (err) {
        error.NotFound => null,
        else => |other| return other,
    };
    if (existing != null) return error.InvalidPatchDraft;

    // get the target repo
    const target_id = std.fmt.bytesToHex(input.repo_id, .lower);
    const target_path = try std.fs.path.join(allocator, &.{ repo_root_path, &target_id });
    defer allocator.free(target_path);
    var target_repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = target_path, .require_repo_root = true });
    defer target_repo.deinit(io, allocator);

    // create the fork repo dir
    const forks_path = std.fs.path.dirname(fork_path) orelse return error.InvalidPatchDraft;
    var forks_dir = try std.Io.Dir.cwd().createDirPathOpen(io, forks_path, .{});
    defer forks_dir.close(io);
    const fork_name = std.fs.path.basename(fork_path);
    forks_dir.createDir(io, fork_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.InvalidPatchDraft,
        else => |other| return other,
    };
    errdefer forks_dir.deleteTree(io, fork_name) catch {};
    var fork_dir = try forks_dir.openDir(io, fork_name, .{});
    defer fork_dir.close(io);
    var fork_repo_dir = try fork_dir.createDirPathOpen(io, ".xit", .{});
    defer fork_repo_dir.close(io);

    // copy the target repo into the fork repo dir
    {
        try target_repo.core.db_file.lock(io, .shared);
        defer target_repo.core.db_file.unlock(io);
        try target_repo.core.chunk_store_file.lock(io, .shared);
        defer target_repo.core.chunk_store_file.unlock(io);

        // TODO: use reflinks here when the filesystem supports them
        for ([_]struct { file: std.Io.File, name: []const u8 }{
            .{ .file = target_repo.core.db_file, .name = "db" },
            .{ .file = target_repo.core.chunk_store_file, .name = "chunks" },
        }) |source| {
            const destination = try fork_repo_dir.createFile(io, source.name, .{ .exclusive = true, .read = true });
            defer destination.close(io);
            var read_buffer: [64 * 1024]u8 = undefined;
            var write_buffer: [64 * 1024]u8 = undefined;
            var reader = source.file.reader(io, &read_buffer);
            var writer = destination.writer(io, &write_buffer);
            _ = try reader.interface.streamRemaining(&writer.interface);
            try writer.interface.flush();
            try destination.sync(io);
        }
    }

    var fork_repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer fork_repo.deinit(io, allocator);

    // clear the haxy state in the fork repo and create the patch branch
    {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            io: std.Io,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                const head_oid_maybe = try rf.readHeadRecurMaybe(.xit, repo_opts, state.readOnly(), ctx.io);

                var path_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
                const events_path = try evt.events_ref.toPath(&path_buffer);
                rf.remove(.xit, repo_opts, state, ctx.io, events_path) catch |err| switch (err) {
                    error.RefNotFound => {},
                    else => |other| return other,
                };
                const patch_path = try ref.toPath(&path_buffer);
                rf.remove(.xit, repo_opts, state, ctx.io, patch_path) catch |err| switch (err) {
                    error.RefNotFound => {},
                    else => |other| return other,
                };

                _ = try moment.remove(hash.hashInt(repo_opts.hash, evt.materialized_key));
                _ = try moment.remove(hash.hashInt(repo_opts.hash, evt.last_object_id_key));

                if (head_oid_maybe) |*head_oid| {
                    try rf.write(.xit, repo_opts, state, ctx.io, patch_path, .{ .oid = head_oid });
                } else {
                    try bch.add(.xit, repo_opts, state, ctx.io, .{ .name = ref.name, .target = .none });
                }
                try rf.replaceHead(.xit, repo_opts, state, ctx.io, .{ .ref = ref });
                try xit.undo.writeMessage(repo_opts, state, .{ .custom = "create fork" });
            }
        };

        try fork_repo.core.db_file.lock(io, .exclusive);
        defer fork_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(fork_repo.core.db.rootCursor());
        try history.appendContext(
            .{ .slot = try history.getSlot(-1) },
            Ctx{ .core = &fork_repo.core, .io = io },
        );
    }

    try fork_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
    try fork_repo.addConfig(io, allocator, .{ .name = "receive.denydeletes", .value = "true" });

    // create the patch event
    try evt.consume(.fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = .{
            .title = input.title,
            .description = input.description,
            .tags = input.tags,
        } },
    }});

    // create the fork event
    try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .fork = .{
            .user_id = &input.user_id,
            .repo_id = &input.repo_id,
        } },
    }});

    return fork_path;
}

pub fn receivePack(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    id: *const [evt.event_id_size * 2]u8,
    target_branch: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    error_writer: *std.Io.Writer,
) !void {
    if (!rf.validateName(target_branch)) return error.InvalidTarget;
    const patch_id = try evt.parseEventId(id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // load the fork and target patch state
    const fork_moment = evt.currentMoment(repo_opts, fork_repo) catch return error.PatchDataUnavailable;
    const fork_patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &patch_id)) orelse return error.PatchDataUnavailable;
    const target_moment = evt.currentMoment(repo_opts, target_repo) catch |err| switch (err) {
        error.NotFound => null,
        else => |other| return other,
    };
    const target_patch = if (target_moment) |moment|
        try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, &arena, &patch_id)
    else
        null;
    if (fork_patch.removed and target_patch == null) return error.PatchDataUnavailable;
    if (target_patch) |patch| {
        if (!std.mem.eql(u8, patch.author_email orelse "", author.email)) return error.PatchDataUnavailable;
        if (patch.event.status == .merged) return error.PatchAlreadyMerged;
    }
    const posted = target_patch != null;
    const title = if (target_patch) |patch| patch.event.title else fork_patch.event.title;

    // resolve the target and the newest fork revision
    const target_oid = (try target_repo.readRef(io, .{ .kind = .head, .name = target_branch })) orelse return error.TargetNotFound;
    const newest = try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena);
    const target_ref = try std.fmt.allocPrint(arena.allocator(), "refs/heads/{s}", .{target_branch});
    var revision_id_maybe: ?[evt.event_id_size]u8 = null;

    // execute a transaction that receives the push and materializes its revision
    {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            target_core: *rp.Repo(.xit, repo_opts).Core,
            io: std.Io,
            allocator: std.mem.Allocator,
            reader: *std.Io.Reader,
            writer: *std.Io.Writer,
            patch_id: [evt.event_id_size * 2]u8,
            patch: evt.Patch.Record,
            posted: bool,
            target_oid: [hash.hexLen(repo_opts.hash)]u8,
            target_ref: []const u8,
            title: []const u8,
            author: evt.CommitAuthor,
            timestamp: u64,
            newest: ?evt.PatchRev.WithId,
            revision_id_maybe: *?[evt.event_id_size]u8,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                // receive the branch update
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, .{ .allowed_ref = ref_path });

                // copy the target history needed to preserve the merge base
                const source_oid = (try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = ref })) orelse return error.CancelTransaction;
                var target_repo_moment = try ctx.target_core.latestMoment();
                const target_state = State(.read_only){ .core = ctx.target_core, .extra = .{ .moment = &target_repo_moment } };
                var objects = try obj.ObjectIterator(.xit, repo_opts).init(target_state, ctx.io, ctx.allocator, .{ .kind = .all });
                defer objects.deinit();
                try objects.include(&ctx.target_oid);
                try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, ctx.io, null);

                const base_oid = try mrg.commonAncestor(.xit, repo_opts, state.readOnly(), ctx.io, ctx.allocator, &ctx.target_oid, &source_oid);
                const existing_revision = if (ctx.newest) |latest|
                    if (std.mem.eql(u8, latest.record.event.base_oid, &base_oid) and
                        std.mem.eql(u8, latest.record.event.source_oid, &source_oid) and
                        std.mem.eql(u8, latest.record.event.target_ref, ctx.target_ref)) latest else null
                else
                    null;

                // reuse an identical revision or record a new one
                var events: [2]evt.EventWithId = undefined;
                var event_count: usize = 0;
                var base_tree_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
                var head_tree_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
                var tree_entries: [2]evt.EventTreeEntry = undefined;
                if (existing_revision) |latest| {
                    if (ctx.posted) ctx.revision_id_maybe.* = latest.id;
                } else {
                    var base_object = try obj.Object(.xit, repo_opts).initCommit(state.readOnly(), ctx.io, ctx.allocator, &base_oid);
                    defer base_object.deinit();
                    var source_object = try obj.Object(.xit, repo_opts).initCommit(state.readOnly(), ctx.io, ctx.allocator, &source_oid);
                    defer source_object.deinit();
                    base_tree_oid = base_object.content.commit.tree;
                    head_tree_oid = source_object.content.commit.tree;

                    var revision_id: [evt.event_id_size]u8 = undefined;
                    ctx.io.random(&revision_id);
                    const revision_hex = std.fmt.bytesToHex(revision_id, .lower);
                    const revision_event: evt.PatchRev = .{
                        .base_oid = &base_oid,
                        .source_oid = &source_oid,
                        .target_ref = ctx.target_ref,
                        .message = ctx.title,
                    };
                    const identity = try std.fmt.allocPrint(ctx.allocator, "{s} <{s}>", .{ ctx.author.name, ctx.author.email });
                    defer ctx.allocator.free(identity);
                    const patch_oid = try evt.PatchRev.writeSquashCommit(
                        .xit,
                        repo_opts,
                        state,
                        ctx.io,
                        ctx.allocator,
                        revision_event,
                        &head_tree_oid,
                        identity,
                        identity,
                        ctx.timestamp,
                    );
                    tree_entries = .{
                        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
                        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
                    };
                    events[event_count] = .{
                        .id = revision_hex,
                        .timestamp = ctx.timestamp,
                        .author = ctx.author,
                        .tree_entries = &tree_entries,
                        .event = .{ .patchrev = revision_event },
                    };
                    event_count += 1;
                    ctx.revision_id_maybe.* = revision_id;

                    if (!ctx.posted) {
                        var patch = ctx.patch.event;
                        patch.revision = .{
                            .id = revision_hex,
                            .squash_oid = &patch_oid,
                            .source_oid = &source_oid,
                            .target_ref = ctx.target_ref,
                        };
                        events[event_count] = .{
                            .id = ctx.patch_id,
                            .timestamp = ctx.timestamp,
                            .author = ctx.author,
                            .event = .{ .patch = patch },
                        };
                        event_count += 1;
                    }
                }

                // posted patches keep only revisions in the fork
                if (ctx.posted and !ctx.patch.removed) {
                    events[event_count] = .{
                        .id = ctx.patch_id,
                        .timestamp = ctx.timestamp,
                        .author = ctx.author,
                        .event = .{ .patch = null },
                    };
                    event_count += 1;
                }

                // commit and index any new events
                if (event_count > 0) {
                    try evt.commitEvents(.xit, repo_opts, state, ctx.io, ctx.allocator, evt.events_ref, events[0..event_count], null);
                    if (!try evt.consumeInTransaction(.fork, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, evt.events_ref)) return error.CancelTransaction;
                }
                try xit.undo.writeMessage(repo_opts, state, .push);
                try ctx.core.chunk_store_file.sync(ctx.io);
            }
        };

        try fork_repo.core.db_file.lock(io, .exclusive);
        defer fork_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(fork_repo.core.db.rootCursor());
        history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
            .core = &fork_repo.core,
            .target_core = &target_repo.core,
            .io = io,
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .patch_id = id.*,
            .patch = fork_patch,
            .posted = posted,
            .target_oid = target_oid,
            .target_ref = target_ref,
            .title = title,
            .author = author,
            .timestamp = timestamp,
            .newest = newest,
            .revision_id_maybe = &revision_id_maybe,
        }) catch |err| switch (err) {
            error.CancelTransaction => {},
            else => |other| return other,
        };
        try writer.flush();
    }

    // best-effort update the posted patch so it has the new revision
    {
        const revision_id = revision_id_maybe orelse return;
        if (!posted) return;
        var update_arena = std.heap.ArenaAllocator.init(allocator);
        defer update_arena.deinit();
        const target_update_moment = evt.currentMoment(repo_opts, target_repo) catch return;
        const posted_patch = (evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, target_update_moment, &update_arena, &patch_id) catch return) orelse return;
        if (posted_patch.removed) return;
        const fork_update_moment = evt.currentMoment(repo_opts, fork_repo) catch return;
        const revision = (evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_update_moment, &update_arena, &revision_id) catch return) orelse return;
        if (revision.removed) return;
        const selected = evt.Patch.Revision.fromRecord(revision_id, revision);
        if (posted_patch.event.revision) |current| {
            if (evt.fieldEqual(evt.Patch.Revision, current, selected)) return;
        }
        var patch = posted_patch.event;
        patch.revision = selected;
        evt.consume(.repo, .xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
            .id = id.*,
            .timestamp = timestamp,
            .author = author,
            .event = .{ .patch = patch },
        }}) catch |update_err| {
            serve_common.logError(io, error_writer, "failed to update posted patch {s}: {s}\n", .{ id, @errorName(update_err) });
        };
    }
}

// delete first so a failed tombstone can be retried safely
pub fn remove(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    id: *const [evt.event_id_size * 2]u8,
    user_id: *const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !void {
    const fork_id = try evt.parseEventId(id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.InvalidPatchDraft;
    if (!std.mem.eql(u8, record.event.user_id, user_id)) return error.InvalidPatchDraft;

    const path = try forkPath(allocator, repo_root_path, id);
    defer allocator.free(path);
    try std.Io.Dir.cwd().deleteTree(io, path);
    if (!record.removed) try evt.remove(.admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, &fork_id, .fork, author);
}

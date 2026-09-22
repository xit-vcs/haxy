const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;
const obj = xit.object;
const rf = xit.ref;
const evt = @import("event.zig");
const pch = @import("patch.zig");
const find = @import("find.zig");
const srch_cmmt = @import("search_commit.zig");
const fork = @import("fork.zig");
const serve_common = @import("serve_common.zig");
const ssh = @import("serve_ssh_protocol.zig");

// prepare all reachable commits, including history received before patch
// generation was enabled. this shares the receive-pack transaction.
pub fn writeReceivedPatches(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    response: *xit.net_server_receive_pack.Response,
    writer: *std.Io.Writer,
) !void {
    var config = try xit.config.Config(.xit, repo_opts).init(state.readOnly(), io, allocator);
    defer config.deinit();
    try config.add(state, io, .{ .name = "merge.algorithm", .value = "patch" });

    var iter = try obj.ObjectIterator(.xit, repo_opts).init(state.readOnly(), io, allocator, .{ .kind = .commit });
    defer iter.deinit();
    var refs = try rf.AllRefIterator(.xit, repo_opts).init(state.readOnly(), allocator);
    defer refs.deinit();
    while (try refs.next()) |ref| {
        if (try rf.readRecur(.xit, repo_opts, state.readOnly(), io, .{ .ref = ref })) |oid| {
            try iter.include(&oid);
        }
    }
    var progress = serve_common.PushProgress{ .response = response, .writer = writer };
    try xit.patch.writePatches(repo_opts, state, io, allocator, &iter, &progress);
}

// the action a received push records
pub const undo_action = "haxy/push";

// the fixture records a stand-in push with this too, so both write one shape
pub fn writeUndo(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    author: ?evt.CommitAuthor,
    updates: []const xit.net_server_receive_pack.AppliedRefUpdate,
) !void {
    // what the payload may take up: the record holds a timestamp and the
    // action kind in the same fixed buffer
    const payload_max_len = repo_opts.max_read_size - @sizeOf(i64) - undo_action.len - 1;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const author_json: std.json.ObjectMap = if (author) |user|
        try .init(aa, &.{ "username", "email" }, &.{ .{ .string = user.name }, .{ .string = user.email } })
    else
        .empty;
    var payload: std.json.ObjectMap = try .init(aa, &.{"author"}, &.{if (author != null) .{ .object = author_json } else .null});

    // where each ref landed, so the undo tab can say what the push did to it.
    // an oid of all zeros means the ref has no side there, which is how a
    // create and a remove are told apart
    var refs: std.json.Array = .init(aa);
    for (updates) |update| {
        const entry: std.json.ObjectMap = try .init(aa, &.{ "name", "old", "new" }, &.{
            .{ .string = update.ref_name },
            .{ .string = if (zeroOid(update.old_oid)) "" else update.old_oid },
            .{ .string = if (zeroOid(update.new_oid)) "" else update.new_oid },
        });
        try refs.append(.{ .object = entry });
        try payload.put(aa, "refs", .{ .array = refs });

        // the record is written into one fixed buffer, so a ref that no
        // longer fits is left out rather than failing the push
        if (try payloadLen(payload) > payload_max_len) {
            _ = refs.pop();
            break;
        }
    }

    // the array is stored by value, so the one the payload holds still counts
    // the entry that was popped until it is replaced here
    try payload.put(aa, "refs", .{ .array = refs });

    try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(io, .real).toSeconds(), .{ .custom = .{ .action_kind = undo_action, .payload = payload } });
}

// the oid a ref update sends when it has no side: all zeros
fn zeroOid(oid: []const u8) bool {
    for (oid) |char| if (char != '0') return false;
    return true;
}

// how long the record's payload would be, to keep it within the buffer
fn payloadLen(payload: std.json.ObjectMap) !u64 {
    var discarding = std.Io.Writer.Discarding.init(&.{});
    try std.json.Stringify.value(std.json.Value{ .object = payload }, .{}, &discarding.writer);
    return discarding.fullCount();
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
    author: ?evt.CommitAuthor,
    repo_root_path: []const u8,
    error_writer: *std.Io.Writer,
    sess: ?*ssh.SessionCtx,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const State = rp.Repo(.xit, repo_opts).State;

    var response = xit.net_server_receive_pack.Response.init(allocator);
    defer response.deinit();

    var updates = xit.net_server_receive_pack.AppliedRefUpdates.init(allocator);
    defer updates.deinit();

    var progress = serve_common.PushProgress{ .response = &response, .writer = writer, .sess = sess };
    const Ctx = struct {
        updates: *xit.net_server_receive_pack.AppliedRefUpdates,
        core: *rp.Repo(.xit, repo_opts).Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        options: xit.net_server_receive_pack.Options,
        author: ?evt.CommitAuthor,
        response: *xit.net_server_receive_pack.Response,
        repo_root_path: []const u8,
        error_writer: *std.Io.Writer,
        progress: *serve_common.PushProgress,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

            var receive_options = ctx.options;
            receive_options.applied_ref_updates = ctx.updates;
            receive_options.deferred_response = ctx.response;
            try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, receive_options, ctx.progress);
            try writeReceivedPatches(repo_opts, state, ctx.io, ctx.allocator, ctx.response, ctx.writer);
            if (ctx.progress.gone) return error.ClientGone;

            // a repo without an events branch has no events to consume. a
            // no-op consume must not cancel here, since the push shares the
            // transaction and must commit regardless.
            if (null != try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = evt.events_ref })) {
                _ = try evt.consumeInTransaction(.repo, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, evt.events_ref);
                try pch.detectMerged(repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.repo_root_path, ctx.updates.items.items, ctx.error_writer);

                // the revisions the pushed branches cause belong to the push
                _ = try pch.refreshBranchesInTransaction(.server, repo_opts, state, &moment, ctx.io, ctx.allocator, ctx.updates.items.items, null, ctx.progress);
            }

            if (ctx.progress.gone) return error.ClientGone;

            // the indexes the pushed refs invalidate belong to the push too
            _ = try find.refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, ctx.progress);
            _ = try srch_cmmt.refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, ctx.updates.items.items, ctx.progress);

            try writeUndo(repo_opts, state, ctx.io, ctx.allocator, ctx.author, ctx.updates.items.items);
        }
    };

    const result = blk: {
        try repo.core.db_file.lock(io, .exclusive);
        defer repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
        break :blk history.appendContext(
            .{ .slot = try history.getSlot(-1) },
            Ctx{
                .updates = &updates,
                .core = &repo.core,
                .io = io,
                .allocator = allocator,
                .reader = reader,
                .writer = writer,
                .options = options,
                .author = author,
                .response = &response,
                .repo_root_path = repo_root_path,
                .error_writer = error_writer,
                .progress = &progress,
            },
        );
    };
    result catch |err| {
        response.finish(writer, @errorName(err)) catch {};
        if (err == error.CancelTransaction) return;
        return err;
    };

    pch.refreshBranches(.server, .xit, repo_opts, io, allocator, repo, updates.items.items, &progress) catch |err| {
        serve_common.logError(io, error_writer, "failed to refresh branch patches: {s}\n", .{@errorName(err)});
        pch.refreshOpenMergeability(repo_opts, io, allocator, repo, null, &progress);
    };
    try response.finish(writer, null);
}

pub fn receiveFork(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    id: *const [evt.event_id_size * 2]u8,
    author: evt.CommitAuthor,
    timestamp: u64,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    error_writer: *std.Io.Writer,
    sess: ?*ssh.SessionCtx,
) !void {
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
        if (patch.event.status.kind() == .merged) return error.PatchAlreadyMerged;
    }
    const published = target_patch != null;
    const active_patch = target_patch orelse fork_patch;
    const title = active_patch.event.title;

    // resolve the target and the newest fork revision
    const target_branch = active_patch.event.target_branch;
    const target_oid = (try target_repo.readRef(io, .{ .kind = .head, .name = target_branch })) orelse return error.TargetNotFound;
    const newest = try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena);
    var revision_id_maybe: ?[evt.event_id_size]u8 = null;
    var response = xit.net_server_receive_pack.Response.init(allocator);
    defer response.deinit();
    var progress = serve_common.PushProgress{ .response = &response, .writer = writer, .sess = sess };

    // execute a transaction that receives the push and materializes its revision
    const result = blk: {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            target_core: *rp.Repo(.xit, repo_opts).Core,
            io: std.Io,
            allocator: std.mem.Allocator,
            reader: *std.Io.Reader,
            writer: *std.Io.Writer,
            response: *xit.net_server_receive_pack.Response,
            patch_id: [evt.event_id_size * 2]u8,
            patch: evt.Patch.Record,
            published: bool,
            target_oid: [hash.hexLen(repo_opts.hash)]u8,
            title: []const u8,
            author: evt.CommitAuthor,
            timestamp: u64,
            newest: ?evt.PatchRev.WithId,
            revision_id_maybe: *?[evt.event_id_size]u8,
            progress: *serve_common.PushProgress,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                // receive the branch update
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, .{ .allowed_ref = "refs/heads/" ++ fork.ref.name, .deferred_response = ctx.response }, ctx.progress);
                try writeReceivedPatches(repo_opts, state, ctx.io, ctx.allocator, ctx.response, ctx.writer);
                if (ctx.progress.gone) return error.ClientGone;

                // copy the target history needed to preserve the merge base
                const source_oid = (try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = fork.ref })) orelse return error.CancelTransaction;
                var target_repo_moment = try ctx.target_core.latestMoment();
                const target_state = State(.read_only){ .core = ctx.target_core, .extra = .{ .moment = &target_repo_moment } };
                var objects = try obj.ObjectIterator(.xit, repo_opts).init(target_state, ctx.io, ctx.allocator, .{ .kind = .all });
                defer objects.deinit();
                try objects.include(&ctx.target_oid);
                try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, ctx.io, null);

                const base_oid = try mrg.commonAncestor(.xit, repo_opts, state.readOnly(), ctx.io, ctx.allocator, &ctx.target_oid, &source_oid);
                const existing_revision = if (ctx.newest) |latest|
                    if (std.mem.eql(u8, latest.record.event.base_oid, &base_oid) and
                        std.mem.eql(u8, latest.record.event.source_oid, &source_oid)) latest else null
                else
                    null;

                // reuse an identical revision or record a new one
                var revision_arena = std.heap.ArenaAllocator.init(ctx.allocator);
                defer revision_arena.deinit();
                var events: [2]evt.EventWithId = undefined;
                var event_count: usize = 0;
                if (existing_revision) |latest| {
                    if (ctx.published) ctx.revision_id_maybe.* = latest.id;
                } else {
                    const prepared = try evt.PatchRev.prepare(.xit, repo_opts, state, ctx.io, &revision_arena, &base_oid, &source_oid, ctx.title, ctx.author, ctx.timestamp);
                    events[event_count] = prepared.event;
                    event_count += 1;
                    ctx.revision_id_maybe.* = try evt.parseEventId(&prepared.event.id);

                    if (!ctx.published) {
                        var patch = ctx.patch.event;
                        patch.revision = prepared.revision;
                        events[event_count] = .{
                            .id = ctx.patch_id,
                            .timestamp = ctx.timestamp,
                            .author = ctx.author,
                            .event = .{ .patch = patch },
                        };
                        event_count += 1;
                    }
                }

                // published patches keep only revisions in the fork
                if (ctx.published and !ctx.patch.removed) {
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
                // a fork push tracks no ref updates, so it records no ranges
                try writeUndo(repo_opts, state, ctx.io, ctx.allocator, ctx.author, &.{});
            }
        };

        try fork_repo.core.db_file.lock(io, .exclusive);
        defer fork_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(fork_repo.core.db.rootCursor());
        break :blk history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
            .core = &fork_repo.core,
            .target_core = &target_repo.core,
            .io = io,
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .response = &response,
            .patch_id = id.*,
            .patch = fork_patch,
            .published = published,
            .target_oid = target_oid,
            .title = title,
            .author = author,
            .timestamp = timestamp,
            .newest = newest,
            .revision_id_maybe = &revision_id_maybe,
            .progress = &progress,
        });
    };
    result catch |err| {
        response.finish(writer, @errorName(err)) catch {};
        if (err == error.CancelTransaction) return;
        return err;
    };

    find.refresh(repo_opts, io, allocator, fork_repo) catch |err| {
        serve_common.logError(io, error_writer, "failed to refresh file index: {s}\n", .{@errorName(err)});
    };
    if (!published) return response.finish(writer, null);

    progress.run(io, .{ .text = "Updating patches" }) catch {};
    progress.run(io, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = 1 } }) catch {};

    // best-effort update the published patch so it has the new revision
    var refreshed = false;
    update: {
        const revision_id = revision_id_maybe orelse break :update;
        var update_arena = std.heap.ArenaAllocator.init(allocator);
        defer update_arena.deinit();
        const target_update_moment = evt.currentMoment(repo_opts, target_repo) catch break :update;
        const published_patch = (evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, target_update_moment, &update_arena, &patch_id) catch break :update) orelse break :update;
        if (published_patch.removed) break :update;
        const fork_update_moment = evt.currentMoment(repo_opts, fork_repo) catch break :update;
        const revision = (evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_update_moment, &update_arena, &revision_id) catch break :update) orelse break :update;
        if (revision.removed) break :update;
        const selected = evt.Patch.Revision.fromRecord(revision_id, revision);
        if (published_patch.event.revision) |current| {
            if (evt.fieldEqual(evt.Patch.Revision, current, selected)) break :update;
        }
        var patch = published_patch.event;
        patch.revision = selected;
        evt.consume(.server, .repo, .xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
            .id = id.*,
            .timestamp = timestamp,
            .author = author,
            .event = .{ .patch = patch },
        }}) catch |update_err| {
            serve_common.logError(io, error_writer, "failed to update published patch {s}: {s}\n", .{ id, @errorName(update_err) });
            break :update;
        };
        // consume also refreshed mergeability
        refreshed = true;
    }

    if (!refreshed) pch.refreshMergeability(repo_opts, io, allocator, target_repo, patch_id);
    progress.run(io, .{ .complete_one = .writing_patch }) catch {};
    progress.run(io, .{ .end = .writing_patch }) catch {};

    // the client may read either repo as soon as it gets the final response.
    try response.finish(writer, null);
}

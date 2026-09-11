const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const mrg = xit.merge;
const obj = xit.object;
const rf = xit.ref;
const evt = @import("event.zig");
const pch = @import("patch.zig");
const fork = @import("fork.zig");
const serve_common = @import("serve_common.zig");

pub const PushProgress = struct {
    response: *xit.net_server_receive_pack.Response,
    writer: *std.Io.Writer,
    count: usize = 0,
    total: usize = 0,

    pub fn run(self: *PushProgress, _: std.Io, event: rp.ProgressEvent) !void {
        switch (event) {
            .start => |start| {
                if (start.kind != .writing_patch) return;
                self.total = start.estimated_total_items;
                self.count = 0;
            },
            .complete_one => |kind| {
                if (kind != .writing_patch) return;
                self.count += 1;
            },
            .end => |kind| {
                if (kind != .writing_patch) return;
            },
            else => return,
        }
        var buffer: [128]u8 = undefined;
        const percent = if (self.total == 0) 100 else @as(u128, self.count) * 100 / self.total;
        const text = try std.fmt.bufPrint(&buffer, "Processing commits: {d}% ({d}/{d}){s}", .{ percent, self.count, self.total, if (event == .end) "\n" else "\r" });
        try self.response.progress(self.writer, text);
    }
};

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
    try response.progress(writer, "Processing commits...\n");
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
    var progress = PushProgress{ .response = response, .writer = writer };
    try xit.patch.writePatches(repo_opts, state, io, allocator, &iter, &progress);
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

    var response = xit.net_server_receive_pack.Response.init(allocator);
    defer response.deinit();

    const Ctx = struct {
        core: *rp.Repo(.xit, repo_opts).Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        options: xit.net_server_receive_pack.Options,
        response: *xit.net_server_receive_pack.Response,
        repo_root_path: []const u8,
        error_writer: *std.Io.Writer,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            var updates = xit.net_server_receive_pack.AppliedRefUpdates.init(ctx.allocator);
            defer updates.deinit();
            var receive_options = ctx.options;
            receive_options.applied_ref_updates = &updates;
            receive_options.deferred_response = ctx.response;
            try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, receive_options);
            try writeReceivedPatches(repo_opts, state, ctx.io, ctx.allocator, ctx.response, ctx.writer);

            // a repo without an events branch has no events to consume. a
            // no-op consume must not cancel here, since the push shares the
            // transaction and must commit regardless.
            if (null != try rf.readRecur(.xit, repo_opts, state.readOnly(), ctx.io, .{ .ref = evt.events_ref })) {
                _ = try evt.consumeInTransaction(.repo, .xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, evt.events_ref);
                try pch.detectMerged(repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.repo_root_path, updates.items.items, ctx.error_writer);
            }
            try xit.undo.writeMessage(repo_opts, state, .push);
        }
    };

    const result = blk: {
        try repo.core.db_file.lock(io, .exclusive);
        defer repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
        break :blk history.appendContext(
            .{ .slot = try history.getSlot(-1) },
            Ctx{
                .core = &repo.core,
                .io = io,
                .allocator = allocator,
                .reader = reader,
                .writer = writer,
                .options = options,
                .response = &response,
                .repo_root_path = repo_root_path,
                .error_writer = error_writer,
            },
        );
    };
    result catch |err| {
        response.finish(writer, @errorName(err)) catch {};
        if (err == error.CancelTransaction) return;
        return err;
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

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                // receive the branch update
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, .{ .allowed_ref = "refs/heads/" ++ fork.ref.name, .deferred_response = ctx.response });
                try writeReceivedPatches(repo_opts, state, ctx.io, ctx.allocator, ctx.response, ctx.writer);

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
                var events: [2]evt.EventWithId = undefined;
                var event_count: usize = 0;
                var base_tree_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
                var head_tree_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
                var tree_entries: [2]evt.EventTreeEntry = undefined;
                if (existing_revision) |latest| {
                    if (ctx.published) ctx.revision_id_maybe.* = latest.id;
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

                    if (!ctx.published) {
                        var patch = ctx.patch.event;
                        patch.revision = .{
                            .id = revision_hex,
                            .squash_oid = &patch_oid,
                            .source_oid = &source_oid,
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
                try xit.undo.writeMessage(repo_opts, state, .push);
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
        });
    };
    result catch |err| {
        response.finish(writer, @errorName(err)) catch {};
        if (err == error.CancelTransaction) return;
        return err;
    };

    // best-effort update the published patch so it has the new revision
    update: {
        const revision_id = revision_id_maybe orelse break :update;
        if (!published) break :update;
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
        evt.consume(.repo, .xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
            .id = id.*,
            .timestamp = timestamp,
            .author = author,
            .event = .{ .patch = patch },
        }}) catch |update_err| {
            serve_common.logError(io, error_writer, "failed to update published patch {s}: {s}\n", .{ id, @errorName(update_err) });
        };
    }

    // the client may read either repo as soon as it gets the final response.
    try response.finish(writer, null);
}

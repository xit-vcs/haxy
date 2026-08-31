const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const rf = xit.ref;
const mrg = xit.merge;
const fork = @import("fork.zig");
const serve_common = @import("serve_common.zig");

pub const PublishInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub const MergeRevision = enum { squash, source };

pub const MergeInput = struct {
    id: [evt.event_id_size * 2]u8,
    revision: MergeRevision,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn publish(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    path: []const u8,
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

    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = path }) catch return error.PatchDataUnavailable;
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
        const selected = local_patch.event.revision orelse return error.PatchNotPushed;
        const revision_id = try evt.parseEventId(&selected.id);
        const revision = (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &revision_id)) orelse return error.PatchNotPushed;
        if (!selected.matches(revision)) return error.PatchNotPushed;
        var patch = (existing orelse local_patch).event;
        patch.revision = selected;
        if (existing == null) patch.status = .open;

        try evt.consume(.repo, .xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = patch },
        }});

        try evt.consume(.fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .patch = null },
        }});
    }

    if (fork_record.event.stage == .draft) {
        var published = fork_record.event;
        published.stage = .publish;
        try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .fork = published },
        }});
    }
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
    const revision_id = try evt.parseEventId(&selected.id);
    const target_ref = rf.Ref.initFromPath(selected.target_ref, null) orelse return error.InvalidPatch;
    switch (target_ref.kind) {
        .head => {},
        else => return error.InvalidPatch,
    }

    // open and lock the fork
    const fork_path = try fork.forkPath(arena.allocator(), repo_root_path, &input.id);
    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return error.PatchDataUnavailable;
    defer fork_repo.deinit(io, allocator);
    try fork_repo.core.db_file.lock(io, .shared);
    defer fork_repo.core.db_file.unlock(io);

    // require the fork's newest revision
    {
        const fork_moment = try evt.currentMoment(repo_opts, &fork_repo);
        const newest = (try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena)) orelse return error.PatchDataUnavailable;
        if (!std.mem.eql(u8, &newest.id, &revision_id) or
            !selected.matches(newest.record)) return error.PatchOutOfDate;
    }

    // select the commit and merge identity
    const merge_oid = blk: {
        const selected_oid = switch (input.revision) {
            .squash => selected.squash_oid,
            .source => selected.source_oid,
        };
        var oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        if (selected_oid.len != oid.len) return error.InvalidPatch;
        @memcpy(&oid, selected_oid);
        break :blk oid;
    };
    const identity = try std.fmt.allocPrint(arena.allocator(), "{s} <{s}>", .{ input.author.name, input.author.email });

    // merge the code and events in one target transaction
    {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            fork_repo: *rp.Repo(.xit, repo_opts),
            io: std.Io,
            allocator: std.mem.Allocator,
            patch_id: [evt.event_id_size]u8,
            expected_patch: evt.Patch,
            target_ref: rf.Ref,
            merge_oid: [hash.hexLen(repo_opts.hash)]u8,
            identity: []const u8,
            author: evt.CommitAuthor,
            timestamp: u64,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };

                // copy the selected commit and its dependencies
                {
                    var fork_repo_moment = try ctx.fork_repo.core.latestMoment();
                    const fork_state = State(.read_only){ .core = &ctx.fork_repo.core, .extra = .{ .moment = &fork_repo_moment } };
                    var objects = try obj.ObjectIterator(.xit, repo_opts).init(fork_state, ctx.io, ctx.allocator, .{ .kind = .all });
                    defer objects.deinit();
                    try objects.include(&ctx.merge_oid);
                    try obj.copyFromObjectIterator(.xit, repo_opts, state, .xit, repo_opts, &objects, ctx.io, null);
                }

                // import the revision and mark the patch merged
                if (!try importMergedFromFork(repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, ctx.fork_repo, &ctx.patch_id, ctx.expected_patch, ctx.author, ctx.timestamp)) return error.PatchOutOfDate;

                // merge the selected commit
                {
                    var merge_result = try mrg.Merge(.xit, repo_opts).init(state, ctx.io, ctx.allocator, .{
                        .kind = .full,
                        .action = .{ .new = .{ .source = &.{.{ .oid = &ctx.merge_oid }}, .algo = .diff3 } },
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
                        .success, .nothing, .fast_forward => {},
                    }
                }

                try xit.undo.writeMessage(repo_opts, state, .{ .custom = "merge patch" });
            }
        };

        try target_repo.core.db_file.lock(io, .exclusive);
        defer target_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(target_repo.core.db.rootCursor());
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{
            .core = &target_repo.core,
            .fork_repo = &fork_repo,
            .io = io,
            .allocator = allocator,
            .patch_id = patch_id,
            .expected_patch = patch_record.event,
            .target_ref = target_ref,
            .merge_oid = merge_oid,
            .identity = identity,
            .author = input.author,
            .timestamp = input.timestamp,
        });
    }
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
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const patch_hex = std.fmt.bytesToHex(patch_id.*, .lower);
    const fork_path = try fork.forkPath(arena.allocator(), repo_root_path, &patch_hex);
    var fork_repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer fork_repo.deinit(io, allocator);

    _ = try importMergedFromFork(repo_opts, state, db, moment, io, allocator, &fork_repo, patch_id, null, null, 0);
}

// import the revision and mark its patch merged in the current transaction
fn importMergedFromFork(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    db: *evt.EventDB(repo_opts.hash),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    patch_id: *const [evt.event_id_size]u8,
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
    if (patch_record.removed or patch_record.event.status == .merged) return false;
    if (expected_patch) |expected| {
        if (!evt.fieldEqual(evt.Patch, expected, patch_record.event)) return false;
    }
    const revision_id = try evt.parseEventId(&selected.id);

    const fork_moment = try evt.currentMoment(repo_opts, fork_repo);
    const revision = (try evt.PatchRev.readById(DB, repo_opts.hash, fork_moment, &arena, &revision_id)) orelse return false;
    if (!selected.matches(revision)) return false;

    var fork_repo_moment = try fork_repo.core.latestMoment();
    const fork_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &fork_repo.core, .extra = .{ .moment = &fork_repo_moment } };
    var event_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    if (revision.event_oid.len != event_oid.len) return false;
    @memcpy(&event_oid, revision.event_oid);
    var event_object = try obj.Object(.xit, repo_opts).initCommit(fork_state, io, allocator, &event_oid);
    defer event_object.deinit();
    const original_author = try commitAuthor(event_object.content.commit.metadata.author orelse return false);

    var events: [2]evt.EventWithId = undefined;
    var event_count: usize = 0;
    const current_revision = try evt.PatchRev.readById(DB, repo_opts.hash, haxy_moment, &arena, &revision_id);
    var tree_entries: [2]evt.EventTreeEntry = undefined;
    const needs_import = if (current_revision) |existing| existing.removed else true;
    if (needs_import) {
        tree_entries = .{
            .{ .tree = .{ .name = "base", .oid = revision.base_tree_oid } },
            .{ .tree = .{ .name = "head", .oid = revision.head_tree_oid } },
        };
        events[event_count] = .{
            .id = selected.id,
            .timestamp = event_object.content.commit.metadata.timestamp,
            .author = original_author,
            .tree_entries = &tree_entries,
            .event = .{ .patchrev = revision.event },
        };
        event_count += 1;
    } else {
        const existing = current_revision orelse unreachable;
        if (!selected.matches(existing)) return error.InvalidPatch;
    }

    var patch = patch_record.event;
    patch.status = .merged;
    events[event_count] = .{
        .id = std.fmt.bytesToHex(patch_id.*, .lower),
        .timestamp = if (merged_author != null) merged_timestamp else @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = merged_author orelse original_author,
        .event = .{ .patch = patch },
    };
    event_count += 1;

    try evt.commitEvents(.xit, repo_opts, state, io, allocator, evt.events_ref, events[0..event_count], null);
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
    for (updates) |update| {
        if (!std.mem.startsWith(u8, update.ref_name, "refs/heads/") or
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
        try commits.include(&new_oid);
        var revision_key_buffer: [rf.MAX_REF_CONTENT_SIZE + 1 + hash.hexLen(repo_opts.hash)]u8 = undefined;
        while (try commits.next(arena.allocator())) |commit| {
            defer commit.deinit();
            const key = try std.fmt.bufPrint(&revision_key_buffer, "{s}\x00{s}", .{ update.ref_name, &commit.oid });
            const ids_cursor = try revisions.getCursor(hash.hashInt(repo_opts.hash, key)) orelse continue;
            const ids = try DB.CountedHashSet(.read_only).init(ids_cursor);
            var ids_iter = try ids.iterator();
            while (try ids_iter.next()) |cursor| {
                const pair = try cursor.readKeyValuePair();
                var patch_id: [evt.event_id_size]u8 = undefined;
                if ((try pair.key_cursor.readBytes(&patch_id)).len != patch_id.len) return error.InvalidPatch;
                const patch_hex = std.fmt.bytesToHex(patch_id, .lower);
                importMerged(repo_opts, state, db, moment, io, allocator, repo_root_path, &patch_id) catch |err| {
                    serve_common.logError(io, error_writer, "failed to mark patch {s} as merged: {s}\n", .{ &patch_hex, @errorName(err) });
                    continue;
                };
            }
        }
    }
}

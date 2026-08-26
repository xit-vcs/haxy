const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const rf = xit.ref;

pub const PostInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn post(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, repo_opts),
    path: []const u8,
    input: PostInput,
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
        var posted = fork_record.event;
        posted.stage = .posted;
        try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, evt.events_ref, &.{.{
            .id = input.id,
            .timestamp = input.timestamp,
            .author = input.author,
            .event = .{ .fork = posted },
        }});
    }
}

fn commitAuthor(line: []const u8) !evt.CommitAuthor {
    const open = std.mem.lastIndexOfScalar(u8, line, '<') orelse return error.AuthorNotFound;
    const close = std.mem.indexOfScalarPos(u8, line, open + 1, '>') orelse return error.AuthorNotFound;
    const name = std.mem.trimEnd(u8, line[0..open], " ");
    if (name.len == 0 or close == open + 1) return error.AuthorNotFound;
    return .{ .name = name, .email = line[open + 1 .. close] };
}

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
    const DB = evt.EventDB(repo_opts.hash);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const haxy_moment = try evt.currentMomentFromRepoMoment(repo_opts.hash, moment.readOnly());
    const patch_record = (try evt.Patch.readById(DB, repo_opts.hash, haxy_moment, &arena, patch_id)) orelse return;
    const selected = patch_record.event.revision orelse return;
    if (patch_record.removed or patch_record.event.status == .merged) return;
    const revision_id = try evt.parseEventId(&selected.id);

    const patch_hex = std.fmt.bytesToHex(patch_id.*, .lower);
    const data_path = std.fs.path.dirname(repo_root_path) orelse ".";
    const fork_path = try std.fs.path.join(arena.allocator(), &.{ data_path, "forks", &patch_hex });
    var fork_repo = rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true }) catch return;
    defer fork_repo.deinit(io, allocator);

    const fork_moment = evt.currentMoment(repo_opts, &fork_repo) catch return;
    const revision = (evt.PatchRev.readById(DB, repo_opts.hash, fork_moment, &arena, &revision_id) catch return) orelse return;
    if (!selected.matches(revision)) return;

    var fork_repo_moment = try fork_repo.core.latestMoment();
    const fork_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &fork_repo.core, .extra = .{ .moment = &fork_repo_moment } };
    var event_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    if (revision.event_oid.len != event_oid.len) return;
    @memcpy(&event_oid, revision.event_oid);
    var event_object = obj.Object(.xit, repo_opts).initCommit(fork_state, io, allocator, &event_oid) catch return;
    defer event_object.deinit();
    const original_author = commitAuthor(event_object.content.commit.metadata.author orelse return) catch return;

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
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = original_author,
        .event = .{ .patch = patch },
    };
    event_count += 1;

    try evt.commitEvents(.xit, repo_opts, state, io, allocator, evt.events_ref, events[0..event_count], null);
    if (!try evt.consumeInTransaction(.repo, .xit, repo_opts, state, db, moment, io, allocator, evt.events_ref)) return error.CancelTransaction;
}

pub fn detectMerged(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    db: *evt.EventDB(repo_opts.hash),
    moment: *evt.EventDB(repo_opts.hash).HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    updates: []const xit.net_server_receive_pack.AppliedRefUpdate,
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
                try importMerged(repo_opts, state, db, moment, io, allocator, repo_root_path, &patch_id);
            }
        }
    }
}

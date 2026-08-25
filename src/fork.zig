const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const mrg = xit.merge;
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
    const fork_id = try evt.parseEventId(&input.id);
    const path = try forkPath(allocator, repo_root_path, &input.id);
    errdefer allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const existing = if (evt.currentMoment(evt.admin_repo_opts, admin_repo)) |moment|
        try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)
    else |err| switch (err) {
        error.NotFound => null,
        else => |other| return other,
    };
    if (existing) |record| {
        if (record.removed or
            !std.mem.eql(u8, record.event.user_id, &input.user_id) or
            !std.mem.eql(u8, record.event.repo_id, &input.repo_id)) return error.InvalidPatchDraft;
    }

    const path_exists = if (std.Io.Dir.accessAbsolute(io, path, .{}))
        true
    else |err| switch (err) {
        error.FileNotFound => false,
        else => |other| return other,
    };
    if (existing != null and !path_exists) return error.PatchDataUnavailable;
    if (existing == null and path_exists) return error.InvalidPatchDraft;

    if (path_exists) {
        var repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
        const moment = try evt.currentMoment(repo_opts, &repo);
        const patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, &arena, &fork_id)) orelse return error.InvalidPatchDraft;
        if (patch.removed or
            !std.mem.eql(u8, patch.event.title, input.title) or
            !std.mem.eql(u8, patch.event.description, input.description) or
            !std.mem.eql(u8, patch.event.tags, input.tags)) return error.InvalidPatchDraft;
        return path;
    }

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.InvalidPatchDraft);
    errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var repo = try rp.Repo(.xit, repo_opts).init(io, allocator, .{ .path = path, .create_default_branch = ref.name });
    defer repo.deinit(io, allocator);
    try repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
    try repo.addConfig(io, allocator, .{ .name = "receive.denydeletes", .value = "true" });

    try evt.consume(.xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = .{
            .title = input.title,
            .description = input.description,
            .tags = input.tags,
        } },
    }});
    try evt.consume(.xit, evt.admin_repo_opts, io, allocator, admin_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .fork = .{
            .user_id = &input.user_id,
            .repo_id = &input.repo_id,
        } },
    }});
    return path;
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
) !void {
    if (!rf.validateName(target_branch)) return error.InvalidTarget;
    const patch_id = try evt.parseEventId(id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

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
    }
    const published = target_patch != null;
    const title = if (target_patch) |patch| patch.event.title else fork_patch.event.title;

    const target_oid = (try target_repo.readRef(io, .{ .kind = .head, .name = target_branch })) orelse return error.TargetNotFound;
    const newest = try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena);
    const target_ref = try std.fmt.allocPrint(arena.allocator(), "refs/heads/{s}", .{target_branch});
    var revision_id_maybe: ?[evt.event_id_size]u8 = null;

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
        published: bool,
        target_oid: [hash.hexLen(repo_opts.hash)]u8,
        target_ref: []const u8,
        title: []const u8,
        author: evt.CommitAuthor,
        timestamp: u64,
        newest: ?evt.PatchRev.WithId,
        revision_id_maybe: *?[evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            try xit.net_server_receive_pack.run(.xit, repo_opts, state, ctx.io, ctx.allocator, ctx.reader, ctx.writer, .{ .allowed_ref = ref_path });

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
                tree_entries = .{
                    .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
                    .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
                };
                events[event_count] = .{
                    .id = revision_hex,
                    .timestamp = ctx.timestamp,
                    .author = ctx.author,
                    .tree_entries = &tree_entries,
                    .event = .{ .patchrev = .{
                        .base_oid = &base_oid,
                        .source_oid = &source_oid,
                        .target_ref = ctx.target_ref,
                        .message = ctx.title,
                    } },
                };
                event_count += 1;
                ctx.revision_id_maybe.* = revision_id;

                if (!ctx.published) {
                    events[event_count] = .{
                        .id = ctx.patch_id,
                        .timestamp = ctx.timestamp,
                        .author = ctx.author,
                        .event = .{ .patch = .{
                            .title = ctx.patch.event.title,
                            .description = ctx.patch.event.description,
                            .tags = ctx.patch.event.tags,
                            .target_patch_id = ctx.patch.event.target_patch_id,
                            .patchrev_id = revision_hex,
                        } },
                    };
                    event_count += 1;
                }
            }

            if (ctx.published and !ctx.patch.removed) {
                events[event_count] = .{
                    .id = ctx.patch_id,
                    .timestamp = ctx.timestamp,
                    .author = ctx.author,
                    .event = .{ .patch = null },
                };
                event_count += 1;
            }
            if (event_count > 0) {
                try evt.commitEvents(.xit, repo_opts, state, ctx.io, ctx.allocator, evt.events_ref, events[0..event_count], null);
                if (!try evt.consumeInTransaction(.xit, repo_opts, state, &ctx.core.db, &moment, ctx.io, ctx.allocator, evt.events_ref)) return error.CancelTransaction;
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
        .published = published,
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

    const revision_id = revision_id_maybe orelse return;
    if (!published) return;
    var update_arena = std.heap.ArenaAllocator.init(allocator);
    defer update_arena.deinit();
    const update_moment = evt.currentMoment(repo_opts, target_repo) catch return;
    const published_patch = (evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, update_moment, &update_arena, &patch_id) catch return) orelse return;
    if (published_patch.removed) return;
    const revision_hex = std.fmt.bytesToHex(revision_id, .lower);
    if (published_patch.event.patchrev_id) |*published_revision| {
        if (std.mem.eql(u8, published_revision, &revision_hex)) return;
    }
    evt.consume(.xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
        .id = id.*,
        .timestamp = timestamp,
        .author = author,
        .event = .{ .patch = .{
            .title = published_patch.event.title,
            .description = published_patch.event.description,
            .tags = published_patch.event.tags,
            .target_patch_id = published_patch.event.target_patch_id,
            .patchrev_id = revision_hex,
        } },
    }}) catch {};
}

pub const PublishInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
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
        return;
    }

    const revision_hex = local_patch.event.patchrev_id orelse return error.PatchNotPushed;
    const revision_id = try evt.parseEventId(&revision_hex);
    const revision = (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, &arena, &revision_id)) orelse return error.PatchNotPushed;
    if (revision.removed) return error.PatchNotPushed;
    const metadata = existing orelse local_patch;

    try evt.consume(.xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = .{
            .title = metadata.event.title,
            .description = metadata.event.description,
            .tags = metadata.event.tags,
            .target_patch_id = metadata.event.target_patch_id,
            .patchrev_id = revision_hex,
        } },
    }});

    try evt.consume(.xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = null },
    }});
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
    if (!record.removed) try evt.remove(.xit, evt.admin_repo_opts, io, allocator, admin_repo, &fork_id, .fork, author);
}

const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const bch = xit.branch;
const rf = xit.ref;

pub const ref = rf.Ref{ .kind = .head, .name = "patch" };

pub const Route = struct {
    identity: []const u8,
    id: [evt.event_id_size * 2]u8,
};

pub fn parseRoute(route_path: []const u8) ?Route {
    const patch_segment = "/patch:";
    const patch_start = std.mem.indexOf(u8, route_path, patch_segment) orelse return null;
    const identity = route_path[0..patch_start];
    const id_text = route_path[patch_start + patch_segment.len ..];
    if (identity.len == 0 or id_text.len != evt.event_id_size * 2) return null;
    const id_bytes = evt.parseEventId(id_text) catch return null;
    return .{ .identity = identity, .id = std.fmt.bytesToHex(id_bytes, .lower) };
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
    target_branch: []const u8,
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
    if (!rf.validateName(input.target_branch)) return error.InvalidTarget;
    if ((try target_repo.readRef(io, .{ .kind = .head, .name = input.target_branch })) == null) return error.TargetNotFound;

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

        // TODO: use reflink here when the filesystem supports it
        const destination = try fork_repo_dir.createFile(io, "db", .{ .exclusive = true, .read = true });
        defer destination.close(io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = target_repo.core.db_file.reader(io, &read_buffer);
        var writer = destination.writer(io, &write_buffer);
        _ = try reader.interface.streamRemaining(&writer.interface);
        try writer.interface.flush();
        try destination.sync(io);
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

    try fork_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "true" });
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
            .target_branch = input.target_branch,
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

// tombstone first so a missing fork never remains visible
pub fn remove(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    id: *const [evt.event_id_size * 2]u8,
    expected_user_id: ?*const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !void {
    const fork_id = try evt.parseEventId(id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.InvalidPatchDraft;
    if (expected_user_id) |user_id| {
        if (!std.mem.eql(u8, record.event.user_id, user_id)) return error.InvalidPatchDraft;
    }
    if (!record.removed) try evt.remove(.admin, .xit, evt.admin_repo_opts, io, allocator, admin_repo, &fork_id, .fork, author);

    const path = try forkPath(allocator, repo_root_path, id);
    defer allocator.free(path);
    try std.Io.Dir.cwd().deleteTree(io, path);
}

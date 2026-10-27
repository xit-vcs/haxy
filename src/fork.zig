const std = @import("std");
const evt = @import("event.zig");
const copy = @import("copy.zig");
const find = @import("find.zig");
const srch_cmmt = @import("search_commit.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const bch = xit.branch;
const rf = xit.ref;

pub const ref = rf.Ref{ .kind = .head, .name = "patch" };

// the action creating a fork records
pub const undo_action = "haxy/fork";

pub const Route = struct {
    identity: []const u8,
    id: [evt.event_id_size * 2]u8,
};

// parse a "<forker>:<repo>+<patch id>" fork path
pub fn parseRoute(route_path: []const u8) ?Route {
    const plus = std.mem.indexOfScalar(u8, route_path, '+') orelse return null;
    const identity = route_path[0..plus];
    const id_text = route_path[plus + 1 ..];
    if (identity.len == 0 or id_text.len != evt.event_id_size * 2) return null;
    const id_bytes = evt.parseEventId(id_text) catch return null;
    return .{ .identity = identity, .id = std.fmt.bytesToHex(id_bytes, .lower) };
}

// a fork's path, inside its forker's dir
pub fn forkPath(allocator: std.mem.Allocator, users_dir: []const u8, forker_id: *const [evt.event_id_size]u8, fork_id: *const [evt.event_id_size]u8) ![]u8 {
    return try std.Io.Dir.path.join(allocator, &.{ users_dir, &std.fmt.bytesToHex(forker_id.*, .lower), "forks", &std.fmt.bytesToHex(fork_id.*, .lower) });
}

const forker_section = "haxy";
const forker_prefix = "fork-";

// the target repo config name recording who forked a published patch
pub fn forkerConfigName(patch_id: *const [evt.event_id_size]u8) [forker_section.len + 1 + forker_prefix.len + evt.event_id_size * 2]u8 {
    return (forker_section ++ "." ++ forker_prefix).* ++ std.fmt.bytesToHex(patch_id.*, .lower);
}

// the forker of a published patch from the target repo's config, or null when it has no fork
pub fn readForkerId(sections: *const xit.config.Sections, patch_id: *const [evt.event_id_size]u8) !?[evt.event_id_size]u8 {
    const section = sections.get(forker_section) orelse return null;
    const name = forkerConfigName(patch_id);
    return try evt.parseEventId(section.get(name[forker_section.len + 1 ..]) orelse return null);
}

// remove the forker entries a copied db carries from the target's config
pub fn clearForkers(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *xit.config.Config(.xit, repo_opts),
) !void {
    const section = config.local_sections.get(forker_section) orelse return;
    var names_arena = std.heap.ArenaAllocator.init(allocator);
    defer names_arena.deinit();
    const na = names_arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (section.keys()) |key| {
        if (std.mem.startsWith(u8, key, forker_prefix)) try names.append(na, try na.print(forker_section ++ ".{s}", .{key}));
    }
    for (names.items) |name| try config.remove(state, io, .{ .name = name });
}

pub const CreateInput = struct {
    id: [evt.event_id_size * 2]u8,
    user_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    repo_user_id: [evt.event_id_size]u8,
    repo_name: []const u8,
    title: []const u8,
    description: []const u8,
    labels: []const u8,
    target_branch: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn create(
    comptime any_opts: rp.AnyRepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    input: CreateInput,
) ![]u8 {
    if (!evt.Patch.fieldsValid(input.title, input.labels)) return error.InvalidPatch;
    if (!evt.Patch.branchValid(input.target_branch)) return error.InvalidTargetBranch;

    // get the fork id and path
    const fork_id = try evt.parseEventId(&input.id);
    const fork_path = try forkPath(allocator, users_dir, &input.user_id, &fork_id);
    errdefer allocator.free(fork_path);

    // make sure the fork id doesn't already exist
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, &input.user_id)) orelse return error.InvalidPatchDraft;
    defer user_repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const existing = if (try evt.userMoment(&user_repo)) |moment|
        try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, &fork_id)
    else
        null;
    if (existing != null) return error.InvalidPatchDraft;

    // the fork copies the target's db, so it takes the target's hash kind
    const target_path = try evt.repoPath(allocator, users_dir, &input.repo_user_id, &input.repo_id);
    defer allocator.free(target_path);
    var any_target = try rp.AnyRepo(.xit, any_opts).open(io, allocator, .{ .path = target_path, .require_repo_root = true });
    defer any_target.deinit(io, allocator);
    switch (any_target) {
        inline else => |*target_repo| try copyTarget(target_repo.self_repo_opts, io, allocator, users_dir, target_repo, &user_repo, fork_path, input),
    }
    return fork_path;
}

// copy the target into a new fork at `fork_path` and record its patch and fork events
fn copyTarget(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    target_repo: *rp.Repo(.xit, repo_opts),
    user_repo: *rp.Repo(.xit, evt.user_repo_opts),
    fork_path: []const u8,
    input: CreateInput,
) !void {
    if ((try target_repo.readRef(io, .{ .kind = .head, .name = input.target_branch })) == null) return error.TargetNotFound;

    // create the fork repo dir
    const forks_path = std.Io.Dir.path.dirname(fork_path) orelse return error.InvalidPatchDraft;
    var forks_dir = try std.Io.Dir.cwd().createDirPathOpen(io, forks_path, .{});
    defer forks_dir.close(io);
    const fork_name = std.Io.Dir.path.basename(fork_path);
    forks_dir.createDir(io, fork_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.InvalidPatchDraft,
        else => |other| return other,
    };
    errdefer forks_dir.deleteTree(io, fork_name) catch {};
    var fork_dir = try forks_dir.openDir(io, fork_name, .{});
    defer fork_dir.close(io);
    var fork_repo_dir = try fork_dir.createDirPathOpen(io, ".xit", .{});
    defer fork_repo_dir.close(io);

    try copy.copyDb(io, target_repo.core.db_file, fork_repo_dir);

    var fork_repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer fork_repo.deinit(io, allocator);

    // clear the haxy state in the fork repo and create the patch branch
    {
        const DB = rp.Repo(.xit, repo_opts).DB;
        const State = rp.Repo(.xit, repo_opts).State;
        const Ctx = struct {
            core: *rp.Repo(.xit, repo_opts).Core,
            io: std.Io,
            allocator: std.mem.Allocator,

            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                var moment = try DB.HashMap(.read_write).init(cursor.*);
                const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                const head_oid_maybe = try rf.readHeadRecurMaybe(.xit, repo_opts, state.readOnly(), ctx.io);

                try copy.clearEvents(repo_opts, state, ctx.io);
                var path_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
                const patch_path = try ref.toPath(&path_buffer);
                rf.remove(.xit, repo_opts, state, ctx.io, patch_path) catch |err| switch (err) {
                    error.RefNotFound => {},
                    else => |other| return other,
                };

                // forks aren't searched, so the copied versions would linger
                // with nothing to prune them
                _ = try moment.remove(hash.hashInt(repo_opts.hash, srch_cmmt.index_key));

                if (head_oid_maybe) |*head_oid| {
                    try rf.write(.xit, repo_opts, state, ctx.io, patch_path, .{ .oid = head_oid });
                } else {
                    try bch.add(.xit, repo_opts, state, ctx.io, .{ .name = ref.name, .target = .none });
                }
                try rf.replaceHead(.xit, repo_opts, state, ctx.io, .{ .ref = ref });

                var config = try xit.config.Config(.xit, repo_opts).init(state.readOnly(), ctx.io, ctx.allocator);
                defer config.deinit();
                try config.add(state, ctx.io, .{ .name = "receive.denydeletes", .value = "true" });

                try clearForkers(repo_opts, state, ctx.io, ctx.allocator, &config);

                // the copied db carries the target's file index, so the patch
                // branch's entry starts from one of those rather than walking
                // the tree
                _ = try find.refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, null);

                try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = undo_action } });
            }
        };

        try fork_repo.core.db_file.lock(io, .exclusive);
        defer fork_repo.core.db_file.unlock(io);

        const history = try DB.ArrayList(.read_write).init(fork_repo.core.db.rootCursor());
        try history.appendContext(
            .{ .slot = try history.getSlot(-1) },
            Ctx{ .core = &fork_repo.core, .io = io, .allocator = allocator },
        );
    }

    // create the patch event
    try evt.consume(.{ .server = .{ .users_dir = users_dir } }, .fork, .xit, repo_opts, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = .{
            .title = input.title,
            .description = input.description,
            .labels = input.labels,
            .target_branch = input.target_branch,
        } },
    }});

    // create the fork event
    try evt.consume(.{ .server = .{ .users_dir = users_dir } }, .user, .xit, evt.user_repo_opts, io, allocator, user_repo, evt.events_ref, &.{.{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .fork = .{
            .repo_id = std.fmt.bytesToHex(input.repo_id, .lower),
            .repo_user_id = std.fmt.bytesToHex(input.repo_user_id, .lower),
            .repo_name = input.repo_name,
        } },
    }});
}

// tombstone first so a missing fork never remains visible
pub fn remove(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    forker_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size * 2]u8,
    author: evt.CommitAuthor,
) !void {
    const fork_id = try evt.parseEventId(id);
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, forker_id)) orelse return error.InvalidPatchDraft;
    defer user_repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = (try evt.userMoment(&user_repo)) orelse return error.InvalidPatchDraft;
    const record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, &fork_id)) orelse return error.InvalidPatchDraft;
    if (!record.removed) try evt.remove(.{ .server = .{ .users_dir = users_dir } }, .user, .xit, evt.user_repo_opts, io, allocator, &user_repo, &fork_id, .fork, author);

    const path = try forkPath(allocator, users_dir, forker_id, &fork_id);
    defer allocator.free(path);
    try std.Io.Dir.cwd().deleteTree(io, path);
}

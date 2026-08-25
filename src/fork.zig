const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const mrg = xit.merge;

pub const ref = xit.ref.Ref{ .kind = .head, .name = "patch" };

const author_config = "haxy.author";
const target_config = "haxy.target";

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

pub fn create(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    id: []const u8,
    author_name: []const u8,
) ![]u8 {
    const draft_path = try forkPath(allocator, repo_root_path, id);
    errdefer allocator.free(draft_path);

    if (std.Io.Dir.accessAbsolute(io, draft_path, .{})) {
        var repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = draft_path });
        defer repo.deinit(io, allocator);
        const stored = try draftAuthor(repo_opts, &repo, io, allocator);
        defer if (stored) |value| allocator.free(value);
        const stored_author = stored orelse return error.InvalidPatchDraft;
        if (!std.mem.eql(u8, stored_author, author_name)) return error.InvalidPatchDraft;
        return draft_path;
    } else |_| {}

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(draft_path) orelse return error.InvalidPatchDraft);
    var repo = try rp.Repo(.xit, repo_opts).init(io, allocator, .{ .path = draft_path, .create_default_branch = ref.name });
    defer repo.deinit(io, allocator);
    try repo.addConfig(io, allocator, .{ .name = author_config, .value = author_name });
    try repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
    return draft_path;
}

pub fn draftAuthor(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]u8 {
    return configValue(repo_opts, repo, io, allocator, author_config);
}

pub fn draftTarget(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]u8 {
    return configValue(repo_opts, repo, io, allocator, target_config);
}

pub fn setTarget(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    try repo.addConfig(io, allocator, .{ .name = target_config, .value = value });
}

fn configValue(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.InvalidConfigName;
    var config = try repo.listConfig(io, allocator);
    defer config.deinit();
    const variables = config.sections.get(name[0..dot]) orelse return null;
    const value = variables.get(name[dot + 1 ..]) orelse return null;
    return try allocator.dupe(u8, value);
}

pub const PublishInput = struct {
    id: [evt.event_id_size * 2]u8,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
};

pub fn publish(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    target_repo: *rp.Repo(.xit, repo_opts),
    draft_path: []const u8,
    input: PublishInput,
) !void {
    if (!evt.Patch.fieldsValid(input.title, input.tags)) return error.InvalidPatch;
    const patch_id = try evt.parseEventId(&input.id);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment_maybe = evt.currentMoment(repo_opts, target_repo) catch |err| switch (err) {
        error.NotFound => null,
        else => |other| return other,
    };
    const existing = if (moment_maybe) |moment| try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, &arena, &patch_id) else null;
    if (existing) |record| {
        if (record.removed or !std.mem.eql(u8, record.author_email orelse "", input.author.email)) return error.InvalidPatch;
    }

    var stage = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = draft_path });
    defer stage.deinit(io, allocator);
    const stored_author_maybe = try draftAuthor(repo_opts, &stage, io, allocator);
    defer if (stored_author_maybe) |value| allocator.free(value);
    const stored_author = stored_author_maybe orelse return error.InvalidPatchDraft;
    if (!std.mem.eql(u8, stored_author, input.author.name)) return error.InvalidPatchDraft;
    const target_name = (try draftTarget(repo_opts, &stage, io, allocator)) orelse return error.PatchNotPushed;
    defer allocator.free(target_name);
    if (!xit.ref.validateName(target_name)) return error.InvalidPatchDraft;
    const source_oid = (try stage.readRef(io, ref)) orelse return error.PatchNotPushed;

    const target_oid = (try target_repo.readRef(io, .{ .kind = .head, .name = target_name })) orelse return error.TargetNotFound;
    var stage_moment = try stage.core.latestMoment();
    const stage_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &stage.core, .extra = .{ .moment = &stage_moment } };
    var objects = try obj.ObjectIterator(.xit, repo_opts).init(stage_state, io, allocator, .{ .kind = .all });
    defer objects.deinit();
    try objects.include(&source_oid);
    try target_repo.copyObjects(.xit, repo_opts, &objects, io, null);

    var target_moment = try target_repo.core.latestMoment();
    const target_state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &target_repo.core, .extra = .{ .moment = &target_moment } };
    const base_oid = try mrg.commonAncestor(.xit, repo_opts, target_state, io, allocator, &target_oid, &source_oid);
    var base_object = try obj.Object(.xit, repo_opts).initCommit(target_state, io, allocator, &base_oid);
    defer base_object.deinit();
    var source_object = try obj.Object(.xit, repo_opts).initCommit(target_state, io, allocator, &source_oid);
    defer source_object.deinit();
    const base_tree_oid = base_object.content.commit.tree;
    const head_tree_oid = source_object.content.commit.tree;

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try source_object.readMessage(allocator, &message, .limited(10_000));

    const target_ref = try std.fmt.allocPrint(arena.allocator(), "refs/heads/{s}", .{target_name});
    var revision_changed = true;
    var patchrev_id: [evt.event_id_size]u8 = undefined;
    if (existing) |record| {
        patchrev_id = try evt.parseEventId(&record.event.patchrev_id);
        if (std.mem.eql(u8, record.event.target_ref, target_ref)) {
            const moment = moment_maybe orelse return error.PatchNotFound;
            if (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, &arena, &patchrev_id)) |revision| {
                revision_changed = !std.mem.eql(u8, revision.event.base_oid, &base_oid) or !std.mem.eql(u8, revision.event.source_oid, &source_oid);
            }
        }
    }
    if (revision_changed) io.random(&patchrev_id);
    const patchrev_hex = std.fmt.bytesToHex(patchrev_id, .lower);

    const tree_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
    };
    const patch_event = evt.EventWithId{
        .id = input.id,
        .timestamp = input.timestamp,
        .author = input.author,
        .event = .{ .patch = .{
            .title = input.title,
            .description = input.description,
            .tags = input.tags,
            .target_ref = target_ref,
            .target_patch_id = if (existing) |record| record.event.target_patch_id else null,
            .patchrev_id = patchrev_hex,
        } },
    };
    if (revision_changed) {
        try evt.consume(.xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{
            .{
                .id = patchrev_hex,
                .timestamp = input.timestamp,
                .author = input.author,
                .tree_entries = &tree_entries,
                .event = .{ .patchrev = .{ .base_oid = &base_oid, .source_oid = &source_oid, .message = message.items } },
            },
            patch_event,
        });
    } else {
        try evt.consume(.xit, repo_opts, io, allocator, target_repo, evt.events_ref, &.{patch_event});
    }
}

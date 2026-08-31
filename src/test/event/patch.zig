const std = @import("std");
const evt = @import("../../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const hash = xit.hash;
const rf = xit.ref;
const fork = @import("../../fork.zig");
const pch = @import("../../patch.zig");

const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
const Repo = rp.Repo(.xit, repo_opts);
const author = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };

fn commitTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *Repo,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
) ![hash.hexLen(repo_opts.hash)]u8 {
    var moment = try repo.core.latestMoment();
    const state = Repo.State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object = try obj.Object(.xit, repo_opts).init(state, io, allocator, oid);
    defer object.deinit();
    return switch (object.content) {
        .commit => |commit| commit.tree,
        else => error.InvalidObject,
    };
}

fn consumePatchWithRevision(
    comptime role: evt.RepoRole,
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *Repo,
    ref: rf.Ref,
    revision_id: [evt.event_id_size]u8,
    revision: evt.PatchRev,
    tree_entries: []const evt.EventTreeEntry,
    revision_timestamp: u64,
    patch_id: [evt.event_id_size]u8,
    patch_value: evt.Patch,
    patch_timestamp: u64,
) !void {
    try evt.consume(role, .xit, repo_opts, io, allocator, repo, ref, &.{.{
        .id = std.fmt.bytesToHex(revision_id, .lower),
        .timestamp = revision_timestamp,
        .author = author,
        .tree_entries = tree_entries,
        .event = .{ .patchrev = revision },
    }});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(repo_opts, repo);
    const record = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, moment, &arena, &revision_id)) orelse return error.NotFound;
    var patch = patch_value;
    patch.revision = evt.Patch.Revision.fromRecord(revision_id, record);
    try evt.consume(role, .xit, repo_opts, io, allocator, repo, ref, &.{.{
        .id = std.fmt.bytesToHex(patch_id, .lower),
        .timestamp = patch_timestamp,
        .author = author,
        .event = .{ .patch = patch },
    }});
}

test "patch event conflicts, stacking, and gc" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const temp_dir_name = "temp-event-patch";
    const cwd = std.Io.Dir.cwd();

    // create the temp dir
    if (cwd.openDir(io, temp_dir_name, .{})) |dir_value| {
        var dir = dir_value;
        dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const upstream_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "upstream" });
    defer allocator.free(upstream_path);
    const target_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "target" });
    defer allocator.free(target_path);
    const source_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "source" });
    defer allocator.free(source_path);

    //
    // create the upstream repo and its base commit
    //

    const base_oid = blk: {
        var upstream = try rp.Repo(.git, .{ .is_test = true }).init(io, allocator, .{ .path = upstream_path });
        defer upstream.deinit(io, allocator);
        const file = try upstream.core.work_dir.createFile(io, "main.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub fn main() void {}\n");
        try upstream.add(io, allocator, &.{"main.zig"});
        break :blk try upstream.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "initial code", .timestamp = 1 });
    };

    var target = try Repo.clone(io, allocator, upstream_path, target_path, target_path, null, .{});
    defer target.deinit(io, allocator);
    const base_tree_oid = try commitTree(io, allocator, &target, &base_oid);

    //
    // fork the target and commit the proposed change
    //

    var source = try Repo.clone(io, allocator, upstream_path, source_path, source_path, null, .{});
    defer source.deinit(io, allocator);

    const source_oid = blk: {
        const file = try source.core.work_dir.createFile(io, "feature.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub const answer = 42;\n");
        try source.add(io, allocator, &.{"feature.zig"});
        break :blk try source.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "add feature", .timestamp = 2 });
    };
    const head_tree_oid = try commitTree(io, allocator, &source, &source_oid);

    //
    // copy the proposed objects without creating a target ref
    //

    {
        var source_moment = try source.core.latestMoment();
        const source_state = Repo.State(.read_only){ .core = &source.core, .extra = .{ .moment = &source_moment } };
        var objects = try obj.ObjectIterator(.xit, repo_opts).init(source_state, io, allocator, .{ .kind = .all });
        defer objects.deinit();
        try objects.include(&source_oid);
        try target.copyObjects(.xit, repo_opts, &objects, io, null);
    }

    //
    // define the patch revision and patch
    //

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const patchrev_id = evt.EventWithId.randomId(prng.random());
    const patch_id = evt.EventWithId.randomId(prng.random());
    const patch = evt.Patch{
        .title = "add the answer",
        .description = "adds a reusable answer constant",
        .tags = "enhancement",
    };
    const tree_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
    };

    //
    // consume the patch revision and patch
    //

    {
        try consumePatchWithRevision(
            .repo,
            io,
            allocator,
            &target,
            evt.events_ref,
            patchrev_id,
            .{ .base_oid = &base_oid, .source_oid = &source_oid, .target_ref = "refs/heads/master", .message = patch.title },
            &tree_entries,
            3,
            patch_id,
            patch,
            4,
        );
    }

    //
    // check the records and squash commit
    //

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(repo_opts, &target);
    const patch_record = (try evt.Patch.readById(Repo.DB, repo_opts.hash, moment, &arena, &patch_id)) orelse return error.NotFound;
    const patchrev_record = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, moment, &arena, &patchrev_id)) orelse return error.NotFound;
    const records_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.record_map_key)) orelse return error.NotFound;
    const records = try Repo.DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(repo_opts.hash, &patch_id)) orelse return error.NotFound;
    const record_map = try Repo.DB.HashMap(.read_only).init(record_cursor);
    const event_cursor = try record_map.getCursor(hash.hashInt(repo_opts.hash, "event")) orelse return error.NotFound;
    const event_map = try Repo.DB.HashMap(.read_only).init(event_cursor);
    const revision_cursor = try event_map.getCursor(hash.hashInt(repo_opts.hash, "revision")) orelse return error.NotFound;
    const revision_map = try Repo.DB.HashMap(.read_only).init(revision_cursor);
    try std.testing.expect(null != try revision_map.getCursor(hash.hashInt(repo_opts.hash, "id")));
    try std.testing.expectEqual(null, try record_map.getCursor(hash.hashInt(repo_opts.hash, "title")));
    try std.testing.expectEqualStrings(&base_tree_oid, patchrev_record.base_tree_oid);
    try std.testing.expectEqualStrings(&head_tree_oid, patchrev_record.head_tree_oid);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_id, .lower), &(patch_record.event.revision orelse return error.NotFound).id);

    var initial_patch_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    @memcpy(&initial_patch_oid, patchrev_record.patch_oid);
    {
        var repo_moment = try target.core.latestMoment();
        const state = Repo.State(.read_only){ .core = &target.core, .extra = .{ .moment = &repo_moment } };
        var patch_object = try obj.Object(.xit, repo_opts).init(state, io, allocator, &initial_patch_oid);
        defer patch_object.deinit();
        switch (patch_object.content) {
            .commit => |commit| {
                try std.testing.expectEqualStrings(&head_tree_oid, &commit.tree);
                const parents = commit.metadata.parent_oids orelse return error.ParentOidsNotFound;
                try std.testing.expectEqual(1, parents.len);
                try std.testing.expectEqualStrings(&base_oid, &parents[0]);
            },
            else => return error.InvalidObject,
        }
    }

    //
    // update metadata without creating another patch revision
    //

    var updated_patch = patch;
    updated_patch.revision = .{
        .id = std.fmt.bytesToHex(patchrev_id, .lower),
        .squash_oid = &initial_patch_oid,
        .source_oid = &source_oid,
        .target_ref = "refs/heads/master",
    };
    updated_patch.title = "add a reusable answer";
    {
        try evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(patch_id, .lower),
            .timestamp = 5,
            .author = author,
            .event = .{ .patch = updated_patch },
        }});
    }

    _ = arena.reset(.retain_capacity);
    const updated_moment = try evt.currentMoment(repo_opts, &target);
    const updated = (try evt.Patch.readById(Repo.DB, repo_opts.hash, updated_moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("add a reusable answer", updated.event.title);

    //
    // branch the events history before creating competing revisions
    //

    const side_events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/patch-side" };
    {
        var result = try target.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer result.deinit();
        try target.addBranch(io, .{ .name = side_events_ref.name });
    }

    //
    // create two competing code revisions
    //

    const source_a_oid = blk: {
        const file = try source.core.work_dir.createFile(io, "feature.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub const answer = 43;\n");
        try source.add(io, allocator, &.{"feature.zig"});
        break :blk try source.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "revise feature one way", .timestamp = 6 });
    };
    const source_a_tree = try commitTree(io, allocator, &source, &source_a_oid);
    const source_b_oid = blk: {
        const file = try source.core.work_dir.createFile(io, "feature.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub const answer = 44;\n");
        try source.add(io, allocator, &.{"feature.zig"});
        break :blk try source.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "revise feature another way", .timestamp = 7 });
    };
    const source_b_tree = try commitTree(io, allocator, &source, &source_b_oid);
    {
        var source_moment = try source.core.latestMoment();
        const source_state = Repo.State(.read_only){ .core = &source.core, .extra = .{ .moment = &source_moment } };
        var objects = try obj.ObjectIterator(.xit, repo_opts).init(source_state, io, allocator, .{ .kind = .all });
        defer objects.deinit();
        try objects.include(&source_b_oid);
        try target.copyObjects(.xit, repo_opts, &objects, io, null);
    }

    //
    // select the first revision on the events branch
    //

    const patchrev_a_id = evt.EventWithId.randomId(prng.random());
    const target_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &source_a_tree } },
    };
    var target_patch = updated_patch;
    target_patch.status = .closed;
    {
        try consumePatchWithRevision(.repo, io, allocator, &target, evt.events_ref, patchrev_a_id, .{
            .base_oid = &base_oid,
            .source_oid = &source_a_oid,
            .target_ref = "refs/heads/master",
            .message = updated_patch.title,
        }, &target_entries, 8, patch_id, target_patch, 9);
    }

    //
    // select the second revision on the side branch
    //

    const patchrev_b_id = evt.EventWithId.randomId(prng.random());
    const parent_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &source_b_tree } },
    };
    var parent_patch = updated_patch;
    parent_patch.status = .merged;
    {
        try consumePatchWithRevision(.repo, io, allocator, &target, side_events_ref, patchrev_b_id, .{
            .base_oid = &base_oid,
            .source_oid = &source_b_oid,
            .target_ref = "refs/heads/master",
            .message = updated_patch.title,
        }, &parent_entries, 10, patch_id, parent_patch, 11);
    }

    //
    // merge the competing patch revisions
    //

    {
        try evt.mergeEvents(.xit, repo_opts, io, allocator, &target, side_events_ref);
        try evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{});
    }

    //
    // check the selected revision and conflict
    //

    _ = arena.reset(.retain_capacity);
    const merged_moment = try evt.currentMoment(repo_opts, &target);
    const merged = (try evt.Patch.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_a_id, .lower), &(merged.event.revision orelse return error.NotFound).id);
    const merged_patchrev = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &patchrev_a_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&source_a_oid, merged_patchrev.event.source_oid);
    try std.testing.expectEqualStrings(&source_a_tree, merged_patchrev.head_tree_oid);

    const conflicts_cursor = try merged_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key)) orelse return error.NotFound;
    const conflicts = try Repo.DB.SortedMap(.read_only).init(conflicts_cursor);
    const conflict_cursor = try conflicts.getCursor(&evt.orderKeyDesc(merged.created_order, &patch_id)) orelse return error.NotFound;
    const conflict = try Repo.DB.HashMap(.read_only).init(conflict_cursor);
    const fields_cursor = try conflict.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("revision status", try fields_cursor.readBytesAlloc(arena.allocator(), null));
    const their_cursor = try conflict.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key)) orelse return error.NotFound;
    const theirs = try evt.read(evt.Patch.Record, Repo.DB, repo_opts.hash, &arena, try Repo.DB.HashMap(.read_only).init(their_cursor));
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_b_id, .lower), &(theirs.event.revision orelse return error.NotFound).id);

    //
    // create a patch stacked on the selected revision
    //

    const child_patchrev_id = evt.EventWithId.randomId(prng.random());
    const child_id = evt.EventWithId.randomId(prng.random());
    const child_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = merged_patchrev.head_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &source_b_tree } },
    };
    {
        try consumePatchWithRevision(.repo, io, allocator, &target, evt.events_ref, child_patchrev_id, .{
            .base_oid = merged_patchrev.patch_oid,
            .source_oid = &source_b_oid,
            .target_ref = "refs/heads/master",
            .message = "stack another answer change",
        }, &child_entries, 12, child_id, .{
            .title = "stack another answer change",
            .description = "depends on the first patch",
            .tags = "enhancement",
            .target_patch_id = std.fmt.bytesToHex(patch_id, .lower),
        }, 13);
    }

    //
    // check the squash commit and reverse index
    //

    _ = arena.reset(.retain_capacity);
    const stacked_moment = try evt.currentMoment(repo_opts, &target);
    const child = (try evt.Patch.readById(Repo.DB, repo_opts.hash, stacked_moment, &arena, &child_id)) orelse return error.NotFound;
    var selected_patchrev_id: [evt.event_id_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&selected_patchrev_id, &(child.event.revision orelse return error.NotFound).id);
    const child_patchrev = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, stacked_moment, &arena, &selected_patchrev_id)) orelse return error.NotFound;
    var child_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    @memcpy(&child_oid, child_patchrev.patch_oid);
    {
        var child_repo_moment = try target.core.latestMoment();
        const child_state = Repo.State(.read_only){ .core = &target.core, .extra = .{ .moment = &child_repo_moment } };
        var child_object = try obj.Object(.xit, repo_opts).init(child_state, io, allocator, &child_oid);
        defer child_object.deinit();
        const child_commit = switch (child_object.content) {
            .commit => |commit| commit,
            else => return error.InvalidObject,
        };
        const child_parents = child_commit.metadata.parent_oids orelse return error.ParentOidsNotFound;
        try std.testing.expectEqualStrings(child_patchrev.event.base_oid, &child_parents[0]);
    }

    const targets_cursor = try stacked_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.target_patch_id_to_patch_id_set_key)) orelse return error.NotFound;
    const targets = try Repo.DB.HashMap(.read_only).init(targets_cursor);
    const children_cursor = try targets.getCursor(hash.hashInt(repo_opts.hash, &patch_id)) orelse return error.NotFound;
    const children = try Repo.DB.SortedSet(.read_only).init(children_cursor);
    try std.testing.expectEqual(1, try children.count());

    //
    // close and merge the same revision concurrently
    //

    const status_side_ref: rf.Ref = .{ .kind = .head, .name = "haxy/patch-status-side" };
    {
        var result = try target.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer result.deinit();
        try target.addBranch(io, .{ .name = status_side_ref.name });
    }
    var closed_child = child.event;
    closed_child.status = .closed;
    try evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(child_id, .lower),
        .timestamp = 14,
        .author = author,
        .event = .{ .patch = closed_child },
    }});
    var merged_child = child.event;
    merged_child.status = .merged;
    try evt.consume(.repo, .xit, repo_opts, io, allocator, &target, status_side_ref, &.{.{
        .id = std.fmt.bytesToHex(child_id, .lower),
        .timestamp = 15,
        .author = author,
        .event = .{ .patch = merged_child },
    }});
    try evt.mergeEvents(.xit, repo_opts, io, allocator, &target, status_side_ref);
    try evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{});

    _ = arena.reset(.retain_capacity);
    const status_moment = try evt.currentMoment(repo_opts, &target);
    const merged_child_record = (try evt.Patch.readById(Repo.DB, repo_opts.hash, status_moment, &arena, &child_id)) orelse return error.NotFound;
    try std.testing.expectEqual(.merged, merged_child_record.event.status);
    try std.testing.expectEqual(0, try patchStatusCount(status_moment, .open));
    try std.testing.expectEqual(1, try patchStatusCount(status_moment, .closed));
    try std.testing.expectEqual(1, try patchStatusCount(status_moment, .merged));
    try std.testing.expectEqual(1, try patchTagStatusCount(status_moment, "enhancement", .merged));
    const status_conflicts_cursor = try status_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key)) orelse return error.NotFound;
    const status_conflicts = try Repo.DB.SortedMap(.read_only).init(status_conflicts_cursor);
    const child_conflict = try status_conflicts.getCursor(&evt.orderKeyDesc(merged_child_record.created_order, &child_id));
    try std.testing.expectEqual(null, child_conflict);

    var reopened_child = merged_child_record.event;
    reopened_child.status = .open;
    try std.testing.expectError(error.PatchAlreadyMerged, evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(child_id, .lower),
        .timestamp = 16,
        .author = author,
        .event = .{ .patch = reopened_child },
    }}));

    const invalid_merged_id = evt.EventWithId.randomId(prng.random());
    try std.testing.expectError(error.InvalidPatch, evt.consume(.repo, .xit, repo_opts, io, allocator, &target, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(invalid_merged_id, .lower),
        .timestamp = 16,
        .author = author,
        .event = .{ .patch = .{
            .title = "invalid merged patch",
            .description = "has no revision",
            .tags = "enhancement",
            .status = .merged,
        } },
    }}));

    //
    // retain the ref-free commits during garbage collection
    //

    {
        const roots = try evt.PatchRev.gcRoots(Repo.DB, repo_opts.hash, allocator, stacked_moment);
        defer allocator.free(roots);
        try std.testing.expectEqual(4, roots.len);
        _ = try target.garbageCollect(io, allocator, roots);

        var after_gc_moment = try target.core.latestMoment();
        const after_gc_state = Repo.State(.read_only){ .core = &target.core, .extra = .{ .moment = &after_gc_moment } };
        var retained = try obj.Object(.xit, repo_opts).init(after_gc_state, io, allocator, &roots[0]);
        retained.deinit();
    }
}

test "patch lifecycle" {
    try patchLifecycle("temp-patch-lifecycle-squash", .squash);
    try patchLifecycle("temp-patch-lifecycle-source", .source);
}

fn patchLifecycle(temp_dir_name: []const u8, merge_revision: pch.MergeRevision) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    if (cwd.openDir(io, temp_dir_name, .{})) |dir_value| {
        var dir = dir_value;
        dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const root = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(root);
    const repos_dir = try std.fs.path.join(allocator, &.{ root, "repos" });
    defer allocator.free(repos_dir);
    const admin_path = try std.fs.path.join(allocator, &.{ root, "admin" });
    defer allocator.free(admin_path);
    const upstream_path = try std.fs.path.join(allocator, &.{ root, "upstream" });
    defer allocator.free(upstream_path);
    const source_path = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source_path);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_id = evt.EventWithId.randomId(prng.random());
    const repo_id = evt.EventWithId.randomId(prng.random());
    const repo_id_hex = std.fmt.bytesToHex(repo_id, .lower);
    const target_path = try std.fs.path.join(allocator, &.{ repos_dir, &repo_id_hex });
    defer allocator.free(target_path);

    var admin = try rp.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);
    try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &.{
        .{
            .id = std.fmt.bytesToHex(user_id, .lower),
            .timestamp = 1,
            .author = author,
            .event = .{ .user = .{
                .name = author.name,
                .email = author.email,
                .password_hash = "",
            } },
        },
        .{
            .id = repo_id_hex,
            .timestamp = 1,
            .author = author,
            .event = .{ .repo = .{
                .user_id = &user_id,
                .name = "repo",
                .description = "",
            } },
        },
    });

    //
    // create the target repo
    //

    {
        var upstream = try rp.Repo(.git, .{ .is_test = true }).init(io, allocator, .{ .path = upstream_path });
        defer upstream.deinit(io, allocator);
        const file = try upstream.core.work_dir.createFile(io, "main.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub fn main() void {}\n");
        try upstream.add(io, allocator, &.{"main.zig"});
        _ = try upstream.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "initial code", .timestamp = 1 });
    }
    var target = try Repo.clone(io, allocator, upstream_path, target_path, target_path, null, .{});
    defer target.deinit(io, allocator);

    //
    // create the patch draft in the fork
    //

    const patch_id = evt.EventWithId.randomId(prng.random());
    const patch_id_hex = std.fmt.bytesToHex(patch_id, .lower);
    const draft_path = try fork.create(repo_opts, io, allocator, repos_dir, &admin, .{
        .id = patch_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = "add the answer",
        .tags = "enhancement",
        .description = "adds a reusable answer constant",
        .author = author,
        .timestamp = 2,
    });
    defer allocator.free(draft_path);

    //
    // create and record the proposed revision in the fork
    //

    const base_oid = (try target.readRef(io, .{ .kind = .head, .name = "master" })) orelse return error.NotFound;
    const base_tree_oid = try commitTree(io, allocator, &target, &base_oid);
    var source = try Repo.clone(io, allocator, upstream_path, source_path, source_path, null, .{});
    defer source.deinit(io, allocator);
    const source_oid = blk: {
        const file = try source.core.work_dir.createFile(io, "feature.zig", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "pub const answer = 42;\n");
        try source.add(io, allocator, &.{"feature.zig"});
        break :blk try source.commit(io, allocator, .{ .author = "alice <alice@example.test>", .message = "add feature", .timestamp = 2 });
    };
    const head_tree_oid = try commitTree(io, allocator, &source, &source_oid);
    const first_patchrev_id = evt.EventWithId.randomId(prng.random());
    const first_patchrev_hex = std.fmt.bytesToHex(first_patchrev_id, .lower);
    const first_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
    };
    {
        var draft = try Repo.open(io, allocator, .{ .path = draft_path });
        defer draft.deinit(io, allocator);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const initial_moment = try evt.currentMoment(repo_opts, &draft);
        const initial_patch = (try evt.Patch.readById(Repo.DB, repo_opts.hash, initial_moment, &arena, &patch_id)) orelse return error.NotFound;
        try std.testing.expect(!initial_patch.removed);
        try std.testing.expectEqualStrings("add the answer", initial_patch.event.title);
        try std.testing.expectEqual(null, initial_patch.event.revision);
        try std.testing.expectEqual(null, try evt.PatchRev.readNewest(Repo.DB, repo_opts.hash, initial_moment, &arena));

        var source_moment = try source.core.latestMoment();
        const source_state = Repo.State(.read_only){ .core = &source.core, .extra = .{ .moment = &source_moment } };
        var objects = try obj.ObjectIterator(.xit, repo_opts).init(source_state, io, allocator, .{ .kind = .all });
        defer objects.deinit();
        try objects.include(&source_oid);
        try draft.copyObjects(.xit, repo_opts, &objects, io, null);
        try consumePatchWithRevision(.fork, io, allocator, &draft, evt.events_ref, first_patchrev_id, .{
            .base_oid = &base_oid,
            .source_oid = &source_oid,
            .target_ref = "refs/heads/master",
            .message = "add the answer",
        }, &first_entries, 3, patch_id, .{
            .title = "add the answer",
            .tags = "enhancement",
            .description = "adds a reusable answer constant",
        }, 3);

        _ = arena.reset(.retain_capacity);
        const moment = try evt.currentMoment(repo_opts, &draft);
        const patch = (try evt.Patch.readById(Repo.DB, repo_opts.hash, moment, &arena, &patch_id)) orelse return error.NotFound;
        try std.testing.expect(!patch.removed);
        try std.testing.expectEqualStrings(&first_patchrev_hex, &(patch.event.revision orelse return error.NotFound).id);
        try std.testing.expect(null != try evt.PatchRev.readById(Repo.DB, repo_opts.hash, moment, &arena, &first_patchrev_id));
    }
    try std.testing.expectError(error.NotFound, evt.currentMoment(repo_opts, &target));

    //
    // publish another draft before its first push
    //

    const unpushed_id = evt.EventWithId.randomId(prng.random());
    const unpushed_id_hex = std.fmt.bytesToHex(unpushed_id, .lower);
    const unpushed_path = try fork.create(repo_opts, io, allocator, repos_dir, &admin, .{
        .id = unpushed_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = "explain the answer",
        .tags = "documentation",
        .description = "describes the existing answer",
        .author = author,
        .timestamp = 3,
    });
    defer allocator.free(unpushed_path);
    try pch.publish(repo_opts, io, allocator, &admin, &target, unpushed_path, .{
        .id = unpushed_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = 4,
    });
    {
        var verify_arena = std.heap.ArenaAllocator.init(allocator);
        defer verify_arena.deinit();
        const target_moment = try evt.currentMoment(repo_opts, &target);
        const unpushed = (try evt.Patch.readById(Repo.DB, repo_opts.hash, target_moment, &verify_arena, &unpushed_id)) orelse return error.NotFound;
        try std.testing.expectEqual(null, unpushed.event.revision);

        var unpushed_repo = try Repo.open(io, allocator, .{ .path = unpushed_path });
        defer unpushed_repo.deinit(io, allocator);
        const fork_moment = try evt.currentMoment(repo_opts, &unpushed_repo);
        const removed = (try evt.Patch.readById(Repo.DB, repo_opts.hash, fork_moment, &verify_arena, &unpushed_id)) orelse return error.NotFound;
        try std.testing.expect(removed.removed);
    }

    //
    // edit the patch metadata in the fork
    //

    try std.testing.expect(try pch.editDraft(repo_opts, io, allocator, &admin, draft_path, .{
        .id = patch_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = "explain the answer",
        .tags = "enhancement documentation",
        .description = "adds and explains a reusable answer constant",
        .author = author,
        .timestamp = 4,
    }));

    //
    // publish the metadata and revision pointer
    //

    try pch.publish(repo_opts, io, allocator, &admin, &target, draft_path, .{
        .id = patch_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = 5,
    });
    try pch.publish(repo_opts, io, allocator, &admin, &target, draft_path, .{
        .id = patch_id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = 6,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(repo_opts, &target);
    const patch = (try evt.Patch.readById(Repo.DB, repo_opts.hash, moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("explain the answer", patch.event.title);
    try std.testing.expectEqualStrings(&first_patchrev_hex, &(patch.event.revision orelse return error.NotFound).id);
    try std.testing.expectEqual(.open, patch.event.status);
    try std.testing.expectEqual(null, try evt.PatchRev.readById(Repo.DB, repo_opts.hash, moment, &arena, &first_patchrev_id));

    _ = arena.reset(.retain_capacity);
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    const published_fork = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expect(!published_fork.removed);
    try std.testing.expectEqual(.publish, published_fork.event.stage);
    const draft_key = evt.Fork.draftKey(&repo_id, &user_id);
    try std.testing.expectEqual(0, try indexedForkCount(admin_moment, evt.Fork.repo_user_to_draft_id_set_key, &draft_key));
    try std.testing.expectEqual(2, try indexedForkCount(admin_moment, evt.Fork.user_id_to_fork_id_set_key, &user_id));
    var squash_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
    {
        var draft = try Repo.open(io, allocator, .{ .path = draft_path });
        defer draft.deinit(io, allocator);
        _ = arena.reset(.retain_capacity);
        const draft_moment = try evt.currentMoment(repo_opts, &draft);
        const removed = (try evt.Patch.readById(Repo.DB, repo_opts.hash, draft_moment, &arena, &patch_id)) orelse return error.NotFound;
        try std.testing.expect(removed.removed);
        const revision = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, draft_moment, &arena, &first_patchrev_id)) orelse return error.NotFound;
        @memcpy(&squash_oid, revision.patch_oid);
        try std.testing.expectEqualStrings("refs/heads/master", revision.event.target_ref);
        try std.testing.expectEqual(hash.hexLen(repo_opts.hash), revision.event_oid.len);
        var event_oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        @memcpy(&event_oid, revision.event_oid);
        var repo_moment = try draft.core.latestMoment();
        const state = Repo.State(.read_only){ .core = &draft.core, .extra = .{ .moment = &repo_moment } };
        var event_object = try obj.Object(.xit, repo_opts).initCommit(state, io, allocator, &event_oid);
        defer event_object.deinit();
        const trees = try evt.PatchRev.readTrees(.xit, repo_opts, state, io, allocator, &event_object.content.commit.tree);
        try std.testing.expectEqualStrings(revision.base_tree_oid, &trees.base);
        try std.testing.expectEqualStrings(revision.head_tree_oid, &trees.head);
    }

    //
    // merge the selected revision into the target
    //

    try evt.Patch.update(.xit, repo_opts, io, allocator, &target, &patch_id, .{ .status = .closed }, author);
    try std.testing.expectError(error.PatchClosed, pch.merge(repo_opts, io, allocator, repos_dir, &target, .{
        .id = patch_id_hex,
        .revision = merge_revision,
        .author = author,
        .timestamp = 5,
    }));
    try evt.Patch.update(.xit, repo_opts, io, allocator, &target, &patch_id, .{ .status = .open }, author);

    const selected_oid = switch (merge_revision) {
        .squash => squash_oid,
        .source => source_oid,
    };
    try pch.mergeAndRemoveFork(repo_opts, io, allocator, repos_dir, &admin, &target, .{
        .id = patch_id_hex,
        .revision = merge_revision,
        .author = author,
        .timestamp = 5,
    });
    const target_oid = (try target.readRef(io, .{ .kind = .head, .name = "master" })) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&selected_oid, &target_oid);

    _ = arena.reset(.retain_capacity);
    const merged_moment = try evt.currentMoment(repo_opts, &target);
    const merged = (try evt.Patch.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expectEqual(.merged, merged.event.status);
    try std.testing.expect(null != try evt.PatchRev.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &first_patchrev_id));

    _ = arena.reset(.retain_capacity);
    const removed_fork = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, try evt.currentMoment(evt.admin_repo_opts, &admin), &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expect(removed_fork.removed);
}

fn indexedForkCount(
    moment: evt.AdminDB.HashMap(.read_only),
    index_key: []const u8,
    parent_id: []const u8,
) !u64 {
    const index_cursor = try moment.getCursor(hash.hashInt(evt.admin_repo_opts.hash, index_key)) orelse return 0;
    const index = try evt.AdminDB.HashMap(.read_only).init(index_cursor);
    const ids_cursor = try index.getCursor(hash.hashInt(evt.admin_repo_opts.hash, parent_id)) orelse return 0;
    const ids = try evt.AdminDB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

fn patchStatusCount(moment: Repo.DB.HashMap(.read_only), status: evt.Patch.Status) !u64 {
    const statuses_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key)) orelse return 0;
    const statuses = try Repo.DB.SortedMap(.read_only).init(statuses_cursor);
    const ids_cursor = try statuses.getCursor(@tagName(status)) orelse return 0;
    const ids = try Repo.DB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

fn patchTagStatusCount(moment: Repo.DB.HashMap(.read_only), tag: []const u8, status: evt.Patch.Status) !u64 {
    const tags_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.tag_status_to_id_set_key)) orelse return 0;
    const tags = try Repo.DB.SortedMap(.read_only).init(tags_cursor);
    var key_buffer: evt.Patch.TagStatusKey = undefined;
    const ids_cursor = try tags.getCursor(try evt.Patch.tagStatusKey(&key_buffer, tag, status)) orelse return 0;
    const ids = try Repo.DB.SortedSet(.read_only).init(ids_cursor);
    return try ids.count();
}

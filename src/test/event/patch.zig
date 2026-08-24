const std = @import("std");
const evt = @import("../../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const hash = xit.hash;
const rf = xit.ref;

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

test "patch lifecycle" {
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
        .target_ref = "refs/heads/master",
        .source_url = source_path,
        .source_ref = "refs/heads/master",
        .patchrev_id = std.fmt.bytesToHex(patchrev_id, .lower),
    };
    const tree_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
    };

    //
    // consume the patch revision and patch
    //

    {
        try evt.consume(.xit, repo_opts, io, allocator, &target, evt.events_ref, &.{
            .{
                .id = std.fmt.bytesToHex(patchrev_id, .lower),
                .timestamp = 3,
                .author = author,
                .tree_entries = &tree_entries,
                .event = .{ .patchrev = .{ .base_oid = &base_oid, .source_oid = &source_oid, .message = patch.title } },
            },
            .{
                .id = std.fmt.bytesToHex(patch_id, .lower),
                .timestamp = 4,
                .author = author,
                .event = .{ .patch = patch },
            },
        });
    }

    //
    // check the records and derived commit
    //

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(repo_opts, &target);
    const patch_record = (try evt.Patch.readById(Repo.DB, repo_opts.hash, moment, &arena, &patch_id)) orelse return error.NotFound;
    const patchrev_record = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, moment, &arena, &patchrev_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&base_tree_oid, patchrev_record.base_tree_oid);
    try std.testing.expectEqualStrings(&head_tree_oid, patchrev_record.head_tree_oid);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_id, .lower), &patch_record.event.patchrev_id);

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
    updated_patch.title = "add a reusable answer";
    {
        try evt.consume(.xit, repo_opts, io, allocator, &target, evt.events_ref, &.{.{
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
    target_patch.patchrev_id = std.fmt.bytesToHex(patchrev_a_id, .lower);
    {
        try evt.consume(.xit, repo_opts, io, allocator, &target, evt.events_ref, &.{
            .{
                .id = std.fmt.bytesToHex(patchrev_a_id, .lower),
                .timestamp = 8,
                .author = author,
                .tree_entries = &target_entries,
                .event = .{ .patchrev = .{ .base_oid = &base_oid, .source_oid = &source_a_oid, .message = updated_patch.title } },
            },
            .{
                .id = std.fmt.bytesToHex(patch_id, .lower),
                .timestamp = 9,
                .author = author,
                .event = .{ .patch = target_patch },
            },
        });
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
    parent_patch.patchrev_id = std.fmt.bytesToHex(patchrev_b_id, .lower);
    {
        try evt.consume(.xit, repo_opts, io, allocator, &target, side_events_ref, &.{
            .{
                .id = std.fmt.bytesToHex(patchrev_b_id, .lower),
                .timestamp = 10,
                .author = author,
                .tree_entries = &parent_entries,
                .event = .{ .patchrev = .{ .base_oid = &base_oid, .source_oid = &source_b_oid, .message = updated_patch.title } },
            },
            .{
                .id = std.fmt.bytesToHex(patch_id, .lower),
                .timestamp = 11,
                .author = author,
                .event = .{ .patch = parent_patch },
            },
        });
    }

    //
    // merge the competing patch revisions
    //

    {
        try evt.mergeEvents(.xit, repo_opts, io, allocator, &target, side_events_ref);
        try evt.consume(.xit, repo_opts, io, allocator, &target, evt.events_ref, &.{});
    }

    //
    // check the selected revision and conflict
    //

    _ = arena.reset(.retain_capacity);
    const merged_moment = try evt.currentMoment(repo_opts, &target);
    const merged = (try evt.Patch.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &patch_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_a_id, .lower), &merged.event.patchrev_id);
    const merged_patchrev = (try evt.PatchRev.readById(Repo.DB, repo_opts.hash, merged_moment, &arena, &patchrev_a_id)) orelse return error.NotFound;
    try std.testing.expectEqualStrings(&source_a_oid, merged_patchrev.event.source_oid);
    try std.testing.expectEqualStrings(&source_a_tree, merged_patchrev.head_tree_oid);

    const conflicts_cursor = try merged_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key)) orelse return error.NotFound;
    const conflicts = try Repo.DB.SortedMap(.read_only).init(conflicts_cursor);
    const conflict_cursor = try conflicts.getCursor(&evt.orderKeyDesc(merged.created_order, &patch_id)) orelse return error.NotFound;
    const conflict = try Repo.DB.HashMap(.read_only).init(conflict_cursor);
    const fields_cursor = try conflict.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key)) orelse return error.NotFound;
    try std.testing.expectEqualStrings("patchrev_id", try fields_cursor.readBytesAlloc(arena.allocator(), null));
    const their_cursor = try conflict.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key)) orelse return error.NotFound;
    const theirs = try evt.read(evt.Patch.Record, Repo.DB, repo_opts.hash, &arena, try Repo.DB.HashMap(.read_only).init(their_cursor));
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(patchrev_b_id, .lower), &theirs.event.patchrev_id);

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
        try evt.consume(.xit, repo_opts, io, allocator, &target, evt.events_ref, &.{
            .{
                .id = std.fmt.bytesToHex(child_patchrev_id, .lower),
                .timestamp = 12,
                .author = author,
                .tree_entries = &child_entries,
                .event = .{ .patchrev = .{ .base_oid = merged_patchrev.patch_oid, .source_oid = &source_b_oid, .message = "stack another answer change" } },
            },
            .{
                .id = std.fmt.bytesToHex(child_id, .lower),
                .timestamp = 13,
                .author = author,
                .event = .{ .patch = .{
                    .title = "stack another answer change",
                    .description = "depends on the first patch",
                    .tags = "enhancement",
                    .target_ref = patch.target_ref,
                    .target_patch_id = std.fmt.bytesToHex(patch_id, .lower),
                    .source_url = patch.source_url,
                    .source_ref = patch.source_ref,
                    .patchrev_id = std.fmt.bytesToHex(child_patchrev_id, .lower),
                } },
            },
        });
    }

    //
    // check the derived commit and reverse index
    //

    _ = arena.reset(.retain_capacity);
    const stacked_moment = try evt.currentMoment(repo_opts, &target);
    const child = (try evt.Patch.readById(Repo.DB, repo_opts.hash, stacked_moment, &arena, &child_id)) orelse return error.NotFound;
    var selected_patchrev_id: [evt.event_id_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&selected_patchrev_id, &child.event.patchrev_id);
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

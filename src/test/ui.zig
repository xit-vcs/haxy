const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const Commits = @import("../ui/Repo/Commits.zig");
const Events = @import("../ui/Repo/Events.zig");
const xit = @import("xit");

// the "next" row at the bottom of the commits list must be recognized as a
// cross-page link (so a click navigates), exactly like the diff pane's "next".
test "commits list next row is a cross-page link" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const identity = "alice/ziglings";
    const oid0 = "1111111111111111111111111111111111111111";
    const next_oid = "2222222222222222222222222222222222222222";

    const data = Commits{
        .identity = identity,
        .ref_or_oid = .object,
        .ref_or_oid_value = oid0,
        .commits = &.{
            .{ .oid = oid0, .date = "2024-01-01", .message = "first", .hunks = &.{}, .window_start = 0, .has_prev = false, .has_more = false },
        },
        .next_start = next_oid,
        .header = try Commits.Header.init(arena.allocator(), .object, oid0),
    };

    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = true };
    session.data.current_page = ui.RoutablePage.repoCommitsRoute(identity, .object, oid0, 0, "").?;

    var view = try Commits.View.init(allocator, &data, &session);
    defer view.deinit(allocator);

    const root_focus = view.getFocus();
    try view.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 120, .height = 60 },
    }, root_focus);

    // the "next" row is the last child of the list box: the view's outer box
    // holds the sub-header then the list/diff split, whose first child is the
    // list scroll.
    const content = &view.box.children.values()[1].widget.box;
    const lb = &content.children.values()[0].widget.scroll.child.box;
    const next_id = lb.children.keys()[lb.children.count() - 1];

    const route = ui.crossPageLink(root_focus, next_id, session.data);
    try std.testing.expect(route != null);
}

// a ref name with a '/' is url-encoded in the route, so it survives the
// '/'-delimited url round-trip as a single segment (kind + value) rather than
// being mis-parsed as extra path.
test "encoded ref name survives the commits url round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const RP = ui.RoutablePage;

    // the route layer holds the value already url-encoded ("feature%2Ffoo").
    const route = RP.repoCommitsRoute("alice/ziglings", .branch, "feature%2Ffoo", 0, "").?;
    const url = try route.toUrl(&arena);
    try std.testing.expectEqualStrings("/repo/alice/ziglings/commits/branch:feature%2Ffoo", url);

    // parsing it back yields the same route, and the ref splits out intact.
    const parsed = RP.fromUrl(url);
    try std.testing.expect(parsed != null);
    const parsed_route = parsed.?.repo_commits;
    try std.testing.expectEqual(RP.RefOrOid.branch, parsed_route.ref_or_oid.?);
    try std.testing.expectEqualStrings("feature%2Ffoo", parsed_route.value.slice());
}

test "sync creates missing event branches and preserves head" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const temp_dir_name = "temp-ui-sync";

    cwd.deleteTree(io, temp_dir_name) catch {};
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const local_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "local" });
    defer allocator.free(local_path);
    const remote_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "remote" });
    defer allocator.free(remote_path);

    const Repo = xit.repo.Repo(.git, .{});
    const RemoteRepo = xit.repo.Repo(.git, .{});
    {
        var remote = try RemoteRepo.init(io, allocator, .{ .path = remote_path });
        remote.deinit(io, allocator);
    }
    {
        var local = try Repo.init(io, allocator, .{ .path = local_path });
        defer local.deinit(io, allocator);
        try local.addConfig(io, allocator, .{ .name = "user.name", .value = "user" });
        try local.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });
        {
            const file = try local.core.work_dir.createFile(io, "keep.txt", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "keep");
        }
        try local.add(io, allocator, &.{"keep.txt"});
        _ = try local.commit(io, allocator, .{ .message = "master" });
        try local.addRemote(io, allocator, .{ .name = "origin", .value = remote_path });

        const id = [_]u8{1} ** evt.event_id_size;
        try evt.consume(.repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = "sync", .description = "", .tags = "" } },
        }});
    }

    try std.testing.expectEqual(null, try Events.sync(io, allocator, .{ .path = local_path, .repo_kind = .git }));
    {
        var local = try Repo.open(io, allocator, .{ .path = local_path });
        defer local.deinit(io, allocator);
        const id = [_]u8{2} ** evt.event_id_size;
        try evt.consume(.repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = "local", .description = "", .tags = "" } },
        }});
    }
    {
        var remote = try RemoteRepo.open(io, allocator, .{ .path = remote_path });
        defer remote.deinit(io, allocator);
        const id = [_]u8{3} ** evt.event_id_size;
        try evt.consume(.repo, .git, .{}, io, allocator, &remote, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = "remote", .description = "", .tags = "" } },
        }});
    }
    try std.testing.expectEqual(null, try Events.sync(io, allocator, .{ .path = local_path, .repo_kind = .git }));
    {
        var local = try Repo.open(io, allocator, .{ .path = local_path });
        defer local.deinit(io, allocator);
        try local.removeBranch(io, .{ .name = evt.events_ref.name });
        try evt.consume(.repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{});
    }
    try std.testing.expectEqual(null, try Events.sync(io, allocator, .{ .path = local_path, .repo_kind = .git }));

    var local = try Repo.open(io, allocator, .{ .path = local_path });
    defer local.deinit(io, allocator);
    var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const head = try local.head(io, &head_buffer);
    switch (head) {
        .ref => |ref| try std.testing.expectEqualStrings("master", ref.name),
        .oid => return error.TestExpectedEqual,
    }
    const kept = try local.core.work_dir.openFile(io, "keep.txt", .{});
    kept.close(io);
    const local_tip = (try local.readRef(io, evt.events_ref)) orelse return error.TestExpectedEqual;

    var remote = try RemoteRepo.open(io, allocator, .{ .path = remote_path });
    defer remote.deinit(io, allocator);
    const remote_tip = (try remote.readRef(io, evt.events_ref)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&local_tip, &remote_tip);

    var start_oids = [_][local_tip.len]u8{local_tip};
    var commit_iter = try local.log(io, allocator, &start_oids);
    defer commit_iter.deinit();
    var merge_commit = (try commit_iter.next(allocator)) orelse return error.TestExpectedEqual;
    defer merge_commit.deinit();
    const parent_oids = merge_commit.content.commit.metadata.parent_oids orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(2, parent_oids.len);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try Events.Header.local(.git, .{}, arena.allocator(), &local, io, null);
    try std.testing.expectEqualStrings("nothing to sync", status.sync_status orelse return error.TestExpectedEqual);
}

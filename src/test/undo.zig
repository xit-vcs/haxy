const std = @import("std");
const ui = @import("../ui.zig");
const evt = @import("../event.zig");
const xit = @import("xit");
const Undo = ui.Repo.Undo;
const allocator = std.testing.allocator;
const io = std.testing.io;
const constraint: xit.xitui.layout.Constraint = .{ .min_size = .{ .width = null, .height = null }, .max_size = .{ .width = 100, .height = 40 } };

test "undo history paginates backwards and undo appends a restorable state" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const opts: xit.repo.RepoOpts(.xit) = .{ .is_test = true };
    var repo = try xit.repo.Repo(.xit, opts).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const initial = try Undo.init(opts, &arena, &repo, null, "", null);
    try std.testing.expectEqual(1, initial.count);
    for (0..25) |index| {
        const value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{index});
        try repo.addConfig(io, allocator, .{ .name = "undo.value", .value = value });
    }
    const first = try Undo.init(opts, &arena, &repo, null, "", null);
    try std.testing.expectEqual(20, first.items.len);
    try std.testing.expectEqual(25, first.items[0].index);
    const second = try Undo.init(opts, &arena, &repo, null, "", first.next);
    try std.testing.expectEqual(6, second.items.len);
    try std.testing.expectEqual(5, second.items[0].index);
    try std.testing.expectEqual(0, second.items[5].index);
    try std.testing.expectEqual(null, second.next);
    try std.testing.expectError(error.NotFound, Undo.init(opts, &arena, &repo, null, "", 26));
    try std.testing.expectError(error.InvalidHistoryIndex, repo.undo(io, 0));
    try std.testing.expectError(error.InvalidHistoryIndex, repo.undo(io, 26));

    // undo the newest change, then a range, then undo that undo.
    try repo.undo(io, 25);
    try expectConfig(&repo, "23");
    try repo.undo(io, 10);
    try expectConfig(&repo, "8");
    const undone = try Undo.init(opts, &arena, &repo, null, "", null);
    try std.testing.expectEqual(28, undone.count);
    try std.testing.expectEqualStrings("undo", undone.items[0].action);
    try repo.undo(io, undone.items[0].index);
    try expectConfig(&repo, "23");
}

fn expectConfig(repo: anytype, expected: []const u8) !void {
    var config = try repo.listConfig(io, allocator);
    defer config.deinit();
    const section = config.local_sections.get("undo") orelse return error.MissingSection;
    try std.testing.expectEqualStrings(expected, section.get("value") orelse return error.MissingValue);
}

test "repo undo visibility and fresh owner authorization" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const base = try temp.dir.realPathFileAlloc(io, ".", aa);
    const admin_path = try std.fs.path.join(aa, &.{ base, "admin" });
    const repos_dir = try std.fs.path.join(aa, &.{ base, "repos" });
    var admin = try xit.repo.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);
    const owner = [_]u8{1} ** evt.event_id_size;
    const writer = [_]u8{2} ** evt.event_id_size;
    const reader = [_]u8{3} ** evt.event_id_size;
    const repo_id = [_]u8{4} ** evt.event_id_size;
    const author: evt.CommitAuthor = .{ .name = "test", .email = "test@example.test" };
    const writer_hex = std.fmt.bytesToHex(writer, .lower);
    var repo_event: evt.Repo = .{ .user_id = &owner, .name = "demo", .description = "", .read_access = .public, .write_user_ids = &writer_hex };
    const seed = [_]evt.EventWithId{
        .{ .id = std.fmt.bytesToHex(owner, .lower), .author = author, .event = .{ .user = .{ .name = "alice", .email = "alice@example.test", .password_hash = "unused" } } },
        .{ .id = writer_hex, .author = author, .event = .{ .user = .{ .name = "writer", .email = "writer@example.test", .password_hash = "unused" } } },
        .{ .id = std.fmt.bytesToHex(reader, .lower), .author = author, .event = .{ .user = .{ .name = "reader", .email = "reader@example.test", .password_hash = "unused" } } },
        .{ .id = std.fmt.bytesToHex(repo_id, .lower), .author = author, .event = .{ .repo = repo_event } },
    };
    try evt.consume(.server, .admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &seed);
    const repo_hex = std.fmt.bytesToHex(repo_id, .lower);
    const path = try std.fs.path.join(aa, &.{ repos_dir, &repo_hex });
    {
        var repo = try xit.repo.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
        try repo.addConfig(io, allocator, .{ .name = "undo.value", .value = "first" });
        try repo.addConfig(io, allocator, .{ .name = "undo.value", .value = "second" });
    }
    for ([_]?[]const u8{ &owner, &writer, &reader, null }, [_]bool{ true, true, false, false }) |user, allowed| {
        var session = try ui.Session.init(&arena, &admin, .{ .user_id = user });
        session.io = io;
        session.repos_dir = repos_dir;
        const files = ui.RoutablePage.repoFilesRoute("alice/demo", null, "", "", 0).?;
        session.data.current_page = files;
        const page = try ui.Repo.init(&arena, &session, files);
        try std.testing.expectEqual(allowed, page.undo != null);
        if (page.undo) |undo| try std.testing.expectEqual(user != null and std.mem.eql(u8, user.?, &owner), undo.can_undo);
        var root = ui.Widget{ .repo = try ui.Repo.View.init(allocator, &page, &session) };
        defer root.deinit(allocator);
        try root.build(allocator, constraint, root.getFocus());
        const html = try @import("../web.zig").generateHtml(allocator, &root, &session);
        defer allocator.free(html);
        try std.testing.expectEqual(allowed, std.mem.indexOf(u8, html, "/repo/alice/demo/undo") != null);
        const route = ui.RoutablePage.repoUndoRoute("alice/demo", null).?;
        if (allowed) {
            _ = try ui.Repo.init(&arena, &session, route);
        } else {
            try std.testing.expectError(error.NotFound, ui.Repo.init(&arena, &session, route));
        }
        if (user == null or !std.mem.eql(u8, user.?, &owner)) {
            try std.testing.expectError(error.Forbidden, Undo.perform(allocator, &session, ui.RoutablePage.repoUndoRoute("alice/demo", 2).?.repo_undo));
        }
    }
    var session = try ui.Session.init(&arena, &admin, .{ .user_id = &owner });
    session.io = io;
    session.repos_dir = repos_dir;
    try Undo.perform(allocator, &session, ui.RoutablePage.repoUndoRoute("alice/demo", 2).?.repo_undo);
    try std.testing.expectEqual(null, session.next_page.?.repo_undo.index);
    {
        var repo = try xit.repo.Repo(.xit, .{}).open(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
        try expectConfig(&repo, "first");
        const data = try Undo.init(.{}, &arena, &repo, null, "alice/demo", null);
        try std.testing.expectEqualStrings("undo", data.items[0].action);
    }
    // keep the old session/page moment, but transfer ownership to the writer.
    repo_event.user_id = &writer;
    try evt.consume(.server, .admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(repo_id, .lower), .author = author, .event = .{ .repo = repo_event } }});
    session.next_page = null;
    Undo.handleRequest(allocator, &session, ui.RoutablePage.repoUndoRoute("alice/demo", 1).?.repo_undo);
    try std.testing.expectEqualStrings("Forbidden", session.data.undo_failure.?);
    try std.testing.expectEqual(null, session.next_page);

    // public-write repos still require login for history and undo.
    repo_event.user_id = &owner;
    repo_event.write_access = .public;
    try evt.consume(.server, .admin, .xit, evt.admin_repo_opts, io, allocator, &admin, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(repo_id, .lower), .author = author, .event = .{ .repo = repo_event } }});
    var anonymous = try ui.Session.init(&arena, &admin, .{});
    anonymous.io = io;
    anonymous.repos_dir = repos_dir;
    try std.testing.expectError(error.NotFound, ui.Repo.init(&arena, &anonymous, ui.RoutablePage.repoUndoRoute("alice/demo", null).?));
}

test "local git has no undo and local xit can undo and refresh" {
    inline for ([_]xit.repo.RepoKind{ .git, .xit }) |kind| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const path = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
        {
            var repo = try xit.repo.Repo(kind, .{}).init(io, allocator, .{ .path = path });
            defer repo.deinit(io, allocator);
            try repo.addConfig(io, allocator, .{ .name = "undo.value", .value = "first" });
        }
        var session = ui.Session{ .arena = &arena, .page_arena = &arena, .io = io, .local = .{ .path = path, .repo_kind = kind }, .data = .{ .host_kind = .local } };
        const files = ui.RoutablePage.repoFilesRoute("", null, "", "", 0).?;
        const data = try ui.Repo.init(&arena, &session, files);
        try std.testing.expectEqual(kind == .xit, data.undo != null);
        if (kind == .git) {
            try std.testing.expectError(error.NotFound, ui.Repo.init(&arena, &session, ui.RoutablePage.repoUndoRoute("", null).?));
            try std.testing.expectError(error.NotFound, Undo.execute(io, allocator, session.local.?, 1));
        } else {
            Undo.handleRequest(allocator, &session, ui.RoutablePage.repoUndoRoute("", 999).?.repo_undo);
            try std.testing.expectEqualStrings("InvalidHistoryIndex", session.data.undo_failure.?);
            try std.testing.expectEqual(null, session.next_page);
            Undo.handleRequest(allocator, &session, ui.RoutablePage.repoUndoRoute("", 1).?.repo_undo);
            try std.testing.expectEqual(null, session.data.undo_failure);
            const refreshed = try ui.Repo.init(&arena, &session, session.next_page.?);
            try std.testing.expectEqualStrings("undo", refreshed.undo.?.items[0].action);
        }
    }
}

test "commit undo records use the formatted description" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const path = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const opts: xit.repo.RepoOpts(.xit) = .{ .is_test = true };
    var repo = try xit.repo.Repo(.xit, opts).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    _ = try repo.commitAtRef(io, allocator, .{ .message = "example commit" }, null, .{ .kind = .head, .name = "master" });
    const data = try Undo.init(opts, &arena, &repo, null, "", null);
    try std.testing.expect(std.mem.startsWith(u8, data.items[0].description, "commit -m \"example commit\""));
}

test "malformed undo history is shown as an error" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const path = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const Repo = xit.repo.Repo(.xit, .{});
    var repo = try Repo.init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);

    // append an invalid undo record without damaging the repository data.
    const Corrupt = struct {
        pub fn run(_: @This(), cursor: *Repo.DB.Cursor(.read_write)) !void {
            const moment = try Repo.DB.HashMap(.read_write).init(cursor.*);
            try moment.put(xit.hash.hashInt(.sha1, "undo"), .{ .bytes = "bad" });
        }
    };
    const history = try Repo.DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Corrupt{});

    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .io = io, .local = .{ .path = path, .repo_kind = .xit }, .data = .{ .host_kind = .local } };
    // tabs switch in-page, so every tab carries the undo data and its failure
    const files = try ui.Repo.init(&arena, &session, ui.RoutablePage.repoFilesRoute("", null, "", "", 0).?);
    try std.testing.expectEqual(0, files.undo.?.items.len);
    try std.testing.expectEqualStrings("InvalidUndoRecord", files.undo.?.failure.?);
    const undo = try ui.Repo.init(&arena, &session, ui.RoutablePage.repoUndoRoute("", null).?);
    try std.testing.expectEqualStrings("InvalidUndoRecord", undo.undo.?.failure.?);

    var root = ui.Widget{ .repo_undo = try Undo.View.init(allocator, &undo.undo.?, &session) };
    defer root.deinit(allocator);
    try root.build(allocator, constraint, root.getFocus());
    const html = try @import("../web.zig").generateHtml(allocator, &root, &session);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "InvalidUndoRecord") != null);
}

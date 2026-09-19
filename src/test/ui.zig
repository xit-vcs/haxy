const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const Commits = @import("../ui/Repo/Commits.zig");
const Events = @import("../ui/Repo/Events.zig");
const xit = @import("xit");

test "preloaded thread forms receive typing after switching tabs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = true, .data = .{ .host_kind = .local } };
    session.data.current_page = ui.RoutablePage.repoIssuesRoute("", .open, "", "") orelse return error.BadRoute;
    const data = try ui.Repo.Issues.emptyResult(arena.allocator(), "", "", "", "", "", 0, "", .open);
    var root = ui.Widget{ .repo_issues = try ui.Repo.Issues.View.init(allocator, &data, &session) };
    defer root.deinit(allocator);
    const focus = root.getFocus();
    const constraint = xit.xitui.layout.Constraint{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 100, .height = 40 },
    };
    try root.build(allocator, constraint, focus);

    // switch to the preloaded new tab without recreating the page (the
    // sub-header starts on the search box, left of the tabs)
    for ([_]xit.xitui.input.Key{ .arrow_right, .arrow_right, .arrow_right, .arrow_right, .arrow_down }) |key| {
        try ui.inputKey(allocator, &root, key, &session);
        try root.build(allocator, constraint, focus);
    }
    for ([_][]const u8{ "title", "tags", "description" }) |name| {
        const input = session.text_inputs.get(focus.grandchild_id orelse return error.NoFocus) orelse return error.MissingInput;
        try std.testing.expectEqualStrings(name, input.options.name);
        try ui.inputKey(allocator, &root, .{ .codepoint = 'x' }, &session);
        try root.build(allocator, constraint, focus);
        const value = try input.text(allocator);
        defer allocator.free(value);
        try std.testing.expectEqualStrings("x", value);
        try ui.inputKey(allocator, &root, .tab, &session);
        try root.build(allocator, constraint, focus);
    }
}

test "web controls omit hidden inputs but retain off-screen inputs" {
    const wgt = xit.xitui.widget;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = false };
    var root = ui.Widget{ .box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert }) };
    defer root.deinit(allocator);
    var scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert }) }, .{ .web_native = true });
    for ([_][]const u8{ "visible", "hidden", "offscreen" }, 0..) |name, i| {
        var input = try wgt.TextInput.init(allocator, .{ .name = name, .render_content = false });
        input.getFocus().mode = .all;
        try scroll.child.box.children.put(allocator, input.getFocus().id, .{
            .widget = .{ .text_input = input },
            .rect = null,
            .min_size = .{ .width = 20, .height = 3 },
            .hidden = i == 1,
        });
    }
    for (scroll.child.box.children.values()) |*child| {
        const input = &child.widget.text_input;
        try session.text_inputs.put(allocator, input.getFocus().id, input);
    }
    try root.box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });
    const focus = root.getFocus();
    try root.build(allocator, .{ .min_size = .{ .width = null, .height = null }, .max_size = .{ .width = 30, .height = 3 } }, focus);

    const children = &root.box.children.values()[0].widget.scroll.child.box.children;
    const offscreen = children.values()[2].rect orelse return error.MissingRect;
    try std.testing.expect(offscreen.y >= 3);
    const html = try @import("../web.zig").generateHtml(allocator, &root, &session);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"hidden\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"offscreen\"") != null);
}

test "diff windows span the net changes across commits" {
    try testDiff(.git);
    try testDiff(.xit);
}

fn testDiff(comptime kind: xit.repo.RepoKind) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const Diff = ui.Repo.Diff;
    const opts: xit.repo.RepoOpts(kind) = .{ .is_test = true };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try xit.repo.Repo(kind, opts).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the shared base is absent from the diff
    {
        const file = try repo.core.work_dir.createFile(io, "shared.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "shared\n");
    }
    try repo.add(io, allocator, &.{"shared.txt"});
    const base = try repo.commit(io, allocator, .{ .message = "base" });

    // changes from earlier commits must survive into the combined diff
    var head = base;
    for (0..Diff.page_size + 1) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file-{d:0>2}.txt", .{i});
        {
            const file = try repo.core.work_dir.createFile(io, name, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "added\n");
        }
        try repo.add(io, allocator, &.{name});
        head = try repo.commit(io, allocator, .{ .message = "add file" });
    }
    const route = ui.RoutablePage.repoDiffRoute("alice/project", .object, &head, 0, "", &base) orelse return error.BadRoute;
    const diff = try Diff.init(kind, opts, &arena, &repo, io, allocator, route.repo_diff);
    const first = diff.window;
    try std.testing.expectEqual(Diff.page_size, first.hunks.len);
    try std.testing.expect(first.start == 0 and first.has_more);
    try std.testing.expectEqualStrings("file-00.txt", first.hunks[0].path orelse return error.MissingPath);
    const last = try Diff.render(kind, opts, io, allocator, arena.allocator(), &repo, &base, head, Diff.page_size, "");
    try std.testing.expectEqual(1, last.hunks.len);
    try std.testing.expect(last.start > 0 and !last.has_more);
    try std.testing.expectEqualStrings("file-10.txt", last.hunks[0].path orelse return error.MissingPath);
    const filtered = try Diff.render(kind, opts, io, allocator, arena.allocator(), &repo, &base, head, 0, "file-00.txt");
    try std.testing.expectEqual(1, filtered.hunks.len);
    try std.testing.expect(!filtered.has_more);

    // tags and branches compare the same trees as an explicit tip
    _ = try repo.addTag(io, allocator, .{ .name = "tip", .message = "annotated" });
    const sources = [_]struct { ref: ?ui.RoutablePage.RefOrOid, value: []const u8 }{
        .{ .ref = null, .value = "" },
        .{ .ref = .branch, .value = "master" },
        .{ .ref = .tag, .value = "tip" },
    };
    for (sources) |source| {
        const selected = ui.RoutablePage.repoDiffRoute("alice/project", source.ref, source.value, 0, "", &base) orelse return error.BadRoute;
        const data = try Diff.init(kind, opts, &arena, &repo, io, allocator, selected.repo_diff);
        try std.testing.expectEqualDeep(first, data.window);
    }
    const unchanged = ui.RoutablePage.repoDiffRoute("alice/project", .object, &head, 0, "", &head) orelse return error.BadRoute;
    try std.testing.expectEqual(0, (try Diff.init(kind, opts, &arena, &repo, io, allocator, unchanged.repo_diff)).window.hunks.len);

    // a zero base includes files that were already present in the first commit
    const zero = [_]u8{'0'} ** xit.hash.hexLen(opts.hash);
    const created = ui.RoutablePage.repoDiffRoute("alice/project", .object, &head, 0, "shared.txt", &zero) orelse return error.BadRoute;
    const created_diff = try Diff.init(kind, opts, &arena, &repo, io, allocator, created.repo_diff);
    try std.testing.expectEqual(1, created_diff.window.hunks.len);
    try std.testing.expectEqualStrings("shared.txt", created_diff.window.hunks[0].path orelse return error.MissingPath);

    // standalone panes keep their comparison when filtering or paginating
    const id = "11111111111111111111111111111111";
    const fork_diff = Diff{ .route = .{ .fork = .{ .identity = "alice/project", .id = id } }, .window = first };
    for ([_]Diff{ diff, fork_diff }) |data| {
        for ([_]bool{ true, false }) |terminal| {
            var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = terminal };
            session.data.current_page = if (data.route == .repo) route else ui.RoutablePage.forkDiffRoute("alice/project", id, 0, "") orelse return error.BadRoute;
            var view = try Diff.View.init(allocator, &data, &session);
            defer view.deinit(allocator);
            const focus = view.getFocus();
            try view.build(allocator, .{ .min_size = .{ .width = null, .height = null }, .max_size = .{ .width = 100, .height = 30 } }, focus);
            const box = &view.scroll.child.box;
            try std.testing.expectEqual(first.hunks.len * 2 + 1, box.children.count());
            const file = ui.crossPageLink(focus, box.children.keys()[0], session.data) orelse return error.MissingFileLink;
            const next = ui.crossPageLink(focus, box.children.keys()[box.children.count() - 1], session.data) orelse return error.MissingLink;
            if (data.route == .repo) {
                try std.testing.expectEqualStrings("file-00.txt", file.repo_diff.path.slice());
                try std.testing.expectEqualStrings(&base, file.repo_diff.base_oid.slice());
                try std.testing.expectEqualStrings(&base, next.repo_diff.base_oid.slice());
                try std.testing.expectEqualStrings(&head, next.repo_diff.value.slice());
                try std.testing.expectEqual(Diff.page_size, next.repo_diff.start);
            } else {
                try std.testing.expectEqualStrings("file-00.txt", file.fork_diff.path.slice());
                try std.testing.expectEqual(Diff.page_size, next.fork_diff.start);
            }
        }
    }
}

// the "next" row at the bottom of the commits list must be recognized as a
// cross-page link (so a click navigates), exactly like the diff pane's "next".
test "commits list next row is a cross-page link" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const identity = "alice/ziglings";
    const oid0 = "1111111111111111111111111111111111111111";
    const next_oid = "2222222222222222222222222222222222222222";
    const base_oid = "3333333333333333333333333333333333333333";

    const data = Commits{
        .location = .{ .repo = identity },
        .ref_or_oid = .object,
        .ref_or_oid_value = oid0,
        .base_oid = base_oid,
        .commits = &.{
            .{ .oid = oid0, .date = "2024-01-01", .message = "first", .window = .{} },
        },
        .next_start = next_oid,
    };

    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = true };
    session.data.current_page = ui.RoutablePage.repoCommitsRoute(identity, .object, oid0, 0, "", base_oid).?;

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
    try std.testing.expectEqualStrings(base_oid, route.?.repo_commits.base_oid.slice());
}

// a ref name with a '/' is url-encoded in the route, so it survives the
// '/'-delimited url round-trip as a single segment (kind + value) rather than
// being mis-parsed as extra path.
test "encoded ref name survives the commits url round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const RP = ui.RoutablePage;
    const base_oid = "3333333333333333333333333333333333333333";

    // the route layer holds the value already url-encoded ("feature%2Ffoo").
    const route = RP.repoCommitsRoute("alice/ziglings", .branch, "feature%2Ffoo", 0, "", base_oid).?;
    const url = try route.toUrl(&arena);
    try std.testing.expectEqualStrings("/repo/alice/ziglings/commits/branch:feature%2Ffoo/base:" ++ base_oid, url);

    // parsing it back yields the same route, and the ref splits out intact.
    const parsed = RP.fromUrl(url);
    try std.testing.expect(parsed != null);
    const parsed_route = parsed.?.repo_commits;
    try std.testing.expectEqual(RP.RefOrOid.branch, parsed_route.ref_or_oid.?);
    try std.testing.expectEqualStrings("feature%2Ffoo", parsed_route.value.slice());
    try std.testing.expectEqualStrings(base_oid, parsed_route.base_oid.slice());
    const unfiltered = RP.repoCommitsRoute("alice/ziglings", .branch, "feature%2Ffoo", 0, "", "").?;
    try std.testing.expect(!RP.eql(route, unfiltered));
}

test "commit pages stop at the base without excluding other ancestors" {
    try testCommitBase(.git);
    try testCommitBase(.xit);
}

fn testCommitBase(comptime kind: xit.repo.RepoKind) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const opts: xit.repo.RepoOpts(kind) = .{ .is_test = true };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try xit.repo.Repo(kind, opts).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const location = ui.RoutablePage.RepoLocation{ .repo = "" };
    const content = ui.RoutablePage.RepoCommitsRoute.Content{ .diff = .{} };
    const branch = xit.ref.Ref{ .kind = .head, .name = "master" };

    // one more commit than fits on the first page
    const base = try repo.commitAtRef(io, allocator, .{ .message = "base" }, null, branch);
    var tip = base;
    var previous = base;
    for (0..21) |_| {
        previous = tip;
        tip = try repo.commitAtRef(io, allocator, .{ .message = "next" }, null, branch);
    }
    const first = try Commits.init(kind, opts, &arena, &repo, io, allocator, null, location, .object, &tip, content, &base, "", "");
    try std.testing.expectEqual(20, first.commits.len);
    try std.testing.expectEqual(@as(?u64, if (kind == .xit) 21 else null), first.commit_count);
    const last = try Commits.init(kind, opts, &arena, &repo, io, allocator, null, location, .object, first.next_start orelse return error.MissingNext, content, &base, "", "");
    try std.testing.expectEqual(1, last.commits.len);
    try std.testing.expectEqual(null, last.next_start);

    // the base at a page boundary must not create an empty next page
    const full = try Commits.init(kind, opts, &arena, &repo, io, allocator, null, location, .object, &previous, content, &base, "", "");
    try std.testing.expectEqual(20, full.commits.len);
    try std.testing.expectEqual(null, full.next_start);
    _ = try repo.addTag(io, allocator, .{ .name = "tip", .message = "annotated" });
    const sources = [_]struct { ref: ui.RoutablePage.RefOrOid, value: []const u8 }{
        .{ .ref = .object, .value = &tip },
        .{ .ref = .branch, .value = branch.name },
        .{ .ref = .tag, .value = "tip" },
    };
    for (sources) |source| {
        const empty = try Commits.init(kind, opts, &arena, &repo, io, allocator, null, location, source.ref, source.value, content, &tip, "", "");
        try std.testing.expectEqual(0, empty.commits.len);
        try std.testing.expectEqual(@as(?u64, if (kind == .xit) 0 else null), empty.commit_count);
    }

    // an off-chain stopping point must not hide its parent on this chain
    const other = try repo.commitAtRef(io, allocator, .{ .message = "other", .parent_oids = &.{base} }, null, .{ .kind = .head, .name = "other" });
    const off_chain = try Commits.init(kind, opts, &arena, &repo, io, allocator, null, location, .object, last.commits[0].oid, content, &other, "", "");
    try std.testing.expectEqual(2, off_chain.commits.len);
    try std.testing.expectEqualStrings(&base, off_chain.commits[1].oid);
    try std.testing.expectEqual(null, off_chain.commit_count);
}

test "sync creates missing event branches and preserves head" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);

    const local_path = try std.fs.path.join(allocator, &.{ temp_path, "local" });
    defer allocator.free(local_path);
    const remote_path = try std.fs.path.join(allocator, &.{ temp_path, "remote" });
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
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{.{
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
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = "local", .description = "", .tags = "" } },
        }});
    }
    {
        var remote = try RemoteRepo.open(io, allocator, .{ .path = remote_path });
        defer remote.deinit(io, allocator);
        const id = [_]u8{3} ** evt.event_id_size;
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &remote, evt.events_ref, &.{.{
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
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{});
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
    var commit_iter = try local.log(io, allocator, .{ .start_oids = &start_oids });
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

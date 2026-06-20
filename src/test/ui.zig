const std = @import("std");
const ui = @import("../ui.zig");
const Commits = @import("../ui/Repo/Commits.zig");
const SubHeader = @import("../ui/Repo/SubHeader.zig");

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
        .sub_header = try SubHeader.init(arena.allocator(), .object, oid0),
    };

    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = true };
    session.data.current_page = ui.RoutablePage.repoCommitsRoute(identity, .object, oid0, 0).?;

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

    const route = ui.crossPageLink(root_focus, next_id, session.data.current_page);
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
    const route = RP.repoCommitsRoute("alice/ziglings", .branch, "feature%2Ffoo", 0).?;
    const url = try route.urlAlloc(&arena);
    try std.testing.expectEqualStrings("/repo/alice/ziglings/commits/branch/feature%2Ffoo", url);

    // parsing it back yields the same route, and the ref splits out intact.
    const parsed = RP.fromUrl(url, null);
    try std.testing.expect(parsed != null);
    const ref = RP.repoCommitsRef(parsed.?.repo_commits.name.slice());
    try std.testing.expectEqual(RP.RefOrOid.branch, ref.ref_or_oid.?);
    try std.testing.expectEqualStrings("feature%2Ffoo", ref.value);
}

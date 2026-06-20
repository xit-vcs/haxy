const std = @import("std");
const ui = @import("../ui.zig");
const Commits = @import("../ui/Repo/Commits.zig");

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
        .commits = &.{
            .{ .oid = oid0, .date = "2024-01-01", .message = "first", .hunks = &.{}, .window_start = 0, .has_prev = false, .has_more = false },
        },
        .next_start = next_oid,
    };

    var session = ui.Session{ .arena = &arena, .page_arena = &arena, .is_terminal = true };
    session.data.current_page = ui.RoutablePage.repoCommitsRoute(identity, oid0, 0).?;

    var view = try Commits.View.init(allocator, &data, &session);
    defer view.deinit(allocator);

    const root_focus = view.getFocus();
    try view.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 120, .height = 60 },
    }, root_focus);

    // the "next" row is the last child of the list box.
    const lb = &view.box.children.values()[0].widget.scroll.child.box;
    const next_id = lb.children.keys()[lb.children.count() - 1];

    const route = ui.crossPageLink(root_focus, next_id, session.data.current_page);
    try std.testing.expect(route != null);
}

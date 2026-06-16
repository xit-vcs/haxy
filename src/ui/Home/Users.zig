const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const page_size = 20; // how many users one window shows

users: []const evt.User.Safe,
after: usize, // the window start this page was built with, mirrored into the url
next_after: ?usize, // the `after` for the "next" row, or null when this is the last window

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    after: usize,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    var users: std.ArrayList(evt.User.Safe) = .empty;

    // the ordered user-list (oldest first); absent until the first user exists.
    const user_list_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "user-list")) orelse
        return .{ .users = &.{}, .after = after, .next_after = null };
    const user_list = try DB.ArrayList(.read_only).init(user_list_cursor);
    const count = try user_list.count();

    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse
        return .{ .users = &.{}, .after = after, .next_after = null };
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    // read the window [after, after+page_size) by index — a direct O(log n)
    // seek per entry, never scanning the whole table. ids whose user has been
    // deleted (tombstones) are skipped.
    const end = @min(after + page_size, count);
    var i = after;
    while (i < end) : (i += 1) {
        const id_cursor = try user_list.getCursor(@intCast(i)) orelse continue;
        var event_id: [evt.event_id_size]u8 = undefined;
        _ = try id_cursor.readBytes(&event_id);
        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(hash_kind, &event_id)) orelse continue;
        const user_map = try DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User, DB, hash_kind, arena, user_map);
        try users.append(arena.allocator(), evt.User.Safe.init(user_event));
    }

    return .{
        .users = users.items,
        .after = after,
        .next_after = if (end < count) end else null,
    };
}

pub const View = struct {
    list: ui.FlowBox.Scroll,
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, web_native: bool) !View {
        var self = blk: {
            var list = try ui.FlowBox.Scroll.init(allocator, .{ .cell_height = 1 }, web_native);
            errdefer list.deinit(allocator);

            break :blk View{
                .list = list,
                .data = data,
            };
        };
        errdefer self.deinit(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // a leading "previous" row off the first window, one row per user, then
        // a trailing "next" row when more remain. each window row navigates to the
        // adjacent window (full reload on web, Nav rebuild on the TUI).
        var items: std.ArrayList(ui.FlowBox.Item) = .empty;
        if (data.after > 0)
            try items.append(aa, .{ .text = "← previous", .link = try std.fmt.allocPrint(aa, "a:/users?after={d}", .{data.after -| page_size}) });
        for (data.users) |user|
            // clicking a user opens their page; the "a:" prefix makes the web
            // renderer emit an <a href="/user/foo"> anchor.
            try items.append(aa, .{
                .text = try std.fmt.allocPrint(aa, "{s} ({s})", .{ user.name, user.display_name }),
                .link = try std.fmt.allocPrint(aa, "a:/user/{s}", .{user.name}),
            });
        if (data.next_after) |next_after|
            try items.append(aa, .{ .text = "next →", .link = try std.fmt.allocPrint(aa, "a:/users?after={d}", .{next_after}) });
        try self.list.setItems(allocator, items.items);

        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.list.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        try self.list.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *View) void {
        self.list.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.list.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.list.getFocus();
    }

    pub fn getSelectedIndex(self: View) ?usize {
        return self.list.getSelectedIndex();
    }
};

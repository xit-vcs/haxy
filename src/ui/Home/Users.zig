const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const page_size = 20; // how many users one window shows

users: []const evt.User.Safe,
start: usize, // the window start this page was built with, mirrored into the url
next_start: ?usize, // the `start` for the "next" row, or null when this is the last window

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    start: usize,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    var users: std.ArrayList(evt.User.Safe) = .empty;

    // the users ordered by creation time (oldest first); absent until the first
    // user exists. keyed by orderKey ([timestamp][event-id]); the trailing bytes
    // of each key are the user event id.
    const user_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "user-id-set")) orelse
        return .{ .users = &.{}, .start = start, .next_start = null };
    const user_id_set = try DB.SortedSet(.read_only).init(user_id_set_cursor);
    const count = try user_id_set.count();

    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse
        return .{ .users = &.{}, .start = start, .next_start = null };
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    // read the window [start, start+page_size) with one seek to the start rank,
    // then a sequential walk
    const end = @min(start + page_size, count);
    var iter = try user_id_set.iteratorFromIndex(start);
    var i = start;
    while (i < end) : (i += 1) {
        var id_cursor = (try iter.next()) orelse break;
        const id_kv = try id_cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try id_kv.key_cursor.readBytes(&order_key);
        const event_id = order_key[@sizeOf(u64)..];
        const user_cursor = try event_id_to_user.getCursor(hash.hashInt(hash_kind, event_id)) orelse continue;
        const user_map = try DB.HashMap(.read_only).init(user_cursor);
        const user_event = try evt.read(evt.User, DB, hash_kind, arena, user_map);
        try users.append(arena.allocator(), evt.User.Safe.init(user_event));
    }

    return .{
        .users = users.items,
        .start = start,
        .next_start = if (end < count) end else null,
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
        if (data.start > 0)
            try items.append(aa, .{ .text = "← previous", .link = try std.fmt.allocPrint(aa, "a:/users/start:{d}", .{data.start -| page_size}) });
        for (data.users) |user|
            // clicking a user opens their page; the "a:" prefix makes the web
            // renderer emit an <a href="/user/foo"> anchor.
            try items.append(aa, .{
                .text = try std.fmt.allocPrint(aa, "{s} ({s})", .{ user.name, user.display_name }),
                .link = try std.fmt.allocPrint(aa, "a:/user/{s}", .{user.name}),
            });
        if (data.next_start) |next_start|
            try items.append(aa, .{ .text = "next →", .link = try std.fmt.allocPrint(aa, "a:/users/start:{d}", .{next_start}) });
        try self.list.setItems(allocator, items.items);

        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.list.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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

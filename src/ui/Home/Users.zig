const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

users: []const evt.User,

const Self = @This();

pub fn init(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    haxy_moment: rp.Repo(.xit, repo_opts).DB.HashMap(.read_only),
) !Self {
    const DB = rp.Repo(.xit, repo_opts).DB;

    var users: std.ArrayList(evt.User) = .empty;

    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    var users_iter = try event_id_to_user.iterator();
    while (try users_iter.next()) |kv_cursor| {
        const kv = try kv_cursor.readKeyValuePair();
        const user_map = try DB.HashMap(.read_only).init(kv.value_cursor);
        const user_event = try evt.read(evt.User, DB, repo_opts.hash, arena, user_map);
        try users.append(arena.allocator(), user_event);
    }

    return .{
        .users = users.items,
    };
}

pub const View = struct {
    list: ui.SelectableList,
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self) !View {
        var self = blk: {
            var list = try ui.SelectableList.init(allocator);
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

        const lines = try aa.alloc([]const u8, data.users.len);
        for (data.users, 0..) |user, i| {
            lines[i] = try std.fmt.allocPrint(aa, "{s} ({s})", .{ user.name, user.display_name });
        }
        try self.list.setItems(allocator, lines);

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

const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

users: []UserAndRepos,

const Self = @This();

pub const UserAndRepos = struct {
    user: evt.User,
    repos: []const evt.Repo,
};

pub fn empty() Self {
    return .{
        .users = &.{},
    };
}

pub fn init(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.xit, repo_opts),
) !Self {
    const DB = rp.Repo(.xit, repo_opts).DB;

    const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());

    const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);

    const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
    var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);

    const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
    const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);

    const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
    const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);

    const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
    const haxy_moment = try DB.HashMap(.read_only).init(haxy_moment_cursor);

    // collect users, keyed by hash(user_event_id) so we can match repos to them
    var hash_to_index: std.AutoArrayHashMapUnmanaged(hash.HashInt(repo_opts.hash), usize) = .empty;

    var user_events: std.ArrayList(evt.User) = .empty;

    var repos_lists: std.ArrayList(std.ArrayList(evt.Repo)) = .empty;

    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->user")) orelse return error.NotFound;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    var users_iter = try event_id_to_user.iterator();
    while (try users_iter.next()) |kv_cursor| {
        const kv = try kv_cursor.readKeyValuePair();
        const user_map = try DB.HashMap(.read_only).init(kv.value_cursor);
        const user_event = try evt.read(evt.User, DB, repo_opts.hash, arena, user_map);

        try hash_to_index.put(arena.allocator(), kv.hash, user_events.items.len);
        try user_events.append(arena.allocator(), user_event);
        try repos_lists.append(arena.allocator(), .empty);
    }

    // collect repos, bucketed by their user_id
    const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->repo")) orelse return error.NotFound;
    const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);

    var repos_iter = try event_id_to_repo.iterator();
    while (try repos_iter.next()) |kv_cursor| {
        const kv = try kv_cursor.readKeyValuePair();
        const repo_map = try DB.HashMap(.read_only).init(kv.value_cursor);
        const repo_event = try evt.read(evt.Repo, DB, repo_opts.hash, arena, repo_map);

        const user_hash = hash.hashInt(repo_opts.hash, repo_event.user_id);
        if (hash_to_index.get(user_hash)) |user_index| {
            try repos_lists.items[user_index].append(arena.allocator(), repo_event);
        }
    }

    var user_repos: std.ArrayList(UserAndRepos) = .empty;

    for (user_events.items, repos_lists.items) |user_event, *repos| {
        try user_repos.append(arena.allocator(), .{
            .user = user_event,
            .repos = repos.items,
        });
    }

    return .{
        .users = user_repos.items,
    };
}

pub const View = struct {
    allocator: std.mem.Allocator,
    box: wgt.Box(ui.Widget),
    data: *const Self,
    last_user_index: ?usize,

    const user_list_index: usize = 0;
    const repo_list_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self) !View {
        var self = blk: {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .horiz });
            errdefer box.deinit();

            {
                var user_list = try ui.SelectableList.init(allocator);
                errdefer user_list.deinit();
                try box.children.put(allocator, user_list.getFocus().id, .{ .widget = .{ .selectable_list = user_list }, .rect = null, .min_size = .{ .width = 30, .height = null } });
            }

            {
                var repo_list = try ui.SelectableList.init(allocator);
                errdefer repo_list.deinit();
                try box.children.put(allocator, repo_list.getFocus().id, .{ .widget = .{ .selectable_list = repo_list }, .rect = null, .min_size = .{ .width = 40, .height = null } });
            }

            break :blk View{
                .allocator = allocator,
                .box = box,
                .data = data,
                .last_user_index = null,
            };
        };
        errdefer self.deinit();

        // populate the user list once at init using a temporary arena
        // for the formatted lines (setItems dupes them).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const user_lines = try aa.alloc([]const u8, data.users.len);
        for (data.users, 0..) |uwr, i| {
            user_lines[i] = try std.fmt.allocPrint(aa, "{s} ({s})", .{ uwr.user.name, uwr.user.display_name });
        }
        const user_list = &self.box.children.values()[user_list_index].widget.selectable_list;
        try user_list.setItems(user_lines);

        self.getFocus().child_id = self.box.children.keys()[user_list_index];
        try self.updateRepos();

        return self;
    }

    pub fn deinit(self: *View) void {
        self.box.deinit();
    }

    pub fn build(self: *View, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // refresh the repo list here (rather than in input) so it stays in
        // sync regardless of how the user selection changed — including
        // clicks that go straight through setFocus without touching input.
        // updateRepos is a no-op when the selected user hasn't changed.
        try self.updateRepos();
        try self.box.build(constraint, root_focus);
    }

    pub fn input(self: *View, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;

                const index = blk: {
                    switch (key) {
                        .arrow_left => {
                            if (current_index == repo_list_index) {
                                break :blk user_list_index;
                            }
                        },
                        .arrow_right => {
                            if (current_index == user_list_index) {
                                break :blk repo_list_index;
                            }
                        },
                        .codepoint => {
                            switch (key.codepoint) {
                                13 => {
                                    if (current_index == user_list_index) {
                                        break :blk repo_list_index;
                                    }
                                },
                                127, '\x1B' => {
                                    if (current_index == repo_list_index) {
                                        break :blk user_list_index;
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                    try child.input(key, root_focus);
                    break :blk current_index;
                };

                if (index != current_index) {
                    try root_focus.setFocus(self.box.children.keys()[index]);
                }
            }
        }
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }

    fn updateRepos(self: *View) !void {
        const user_list = &self.box.children.values()[user_list_index].widget.selectable_list;
        const repo_list = &self.box.children.values()[repo_list_index].widget.selectable_list;

        const user_index = user_list.getSelectedIndex();
        if (user_index == self.last_user_index) return;
        self.last_user_index = user_index;

        const repos = if (user_index) |i| self.data.users[i].repos else &.{};

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const repo_lines = try aa.alloc([]const u8, repos.len);
        for (repos, 0..) |repo_event, i| {
            repo_lines[i] = try std.fmt.allocPrint(aa, "{s} - {s}", .{ repo_event.name, repo_event.description });
        }
        try repo_list.setItems(repo_lines);
    }
};

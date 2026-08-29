const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");
const fork = @import("../fork.zig");

pub const Header = @import("./User/Header.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

pub const page_size = 20; // how many repos one window of the repos tab shows

pub const ForkItem = struct {
    target: []const u8,
    title: []const u8,
};

header: Header,
user: evt.User.Public,
repos: []const evt.Repo.Record,
repos_start: usize, // the repos window this page was built with, mirrored into the url
repos_next_start: ?usize, // the `start` for the "next" row, or null on the last window
forks: []const ForkItem,
forks_start: usize,
forks_next_start: ?usize,
settings: Settings,
auth: Auth,
quit: Quit,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    name: ui.RoutablePage.Array(evt.User.name_max_len),
    repos_start: usize,
    forks_start: usize,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    // a route identifies a user by name; resolve it to the user's event id via
    // the name->user-id index, which everything below keys off of.
    const name_to_user_id_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "name->user-id")) orelse return error.NotFound;
    const name_to_user_id = try DB.HashMap(.read_only).init(name_to_user_id_cursor);
    const user_id_cursor = try name_to_user_id.getCursor(hash.hashInt(hash_kind, name.slice())) orelse return error.NotFound;
    var user_id_buf: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id_buf);
    const user_id: []const u8 = &user_id_buf;

    const user = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, user_id)) orelse return error.NotFound;

    var repos: std.ArrayList(evt.Repo.Record) = .empty;
    var repos_next_start: ?usize = null;

    // the user-id->repo-id-set index maps each user to a set of their repo event
    // ids ordered by creation (newest first); it only exists once a repo has
    // been consumed, so a user with no repos simply yields an empty list.
    if (try haxy_moment.getCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"))) |user_id_to_repo_id_set_cursor| {
        const user_id_to_repo_id_set = try DB.HashMap(.read_only).init(user_id_to_repo_id_set_cursor);
        if (try user_id_to_repo_id_set.getCursor(hash.hashInt(hash_kind, user_id))) |user_repos_cursor| {
            const user_repos = try DB.SortedSet(.read_only).init(user_repos_cursor);
            const count = try user_repos.count();

            const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->repo")) orelse return error.NotFound;
            const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);

            // read the window [start, start+page_size) with one seek to the start
            // rank, then a sequential walk.
            const end = @min(repos_start + page_size, count);
            var repos_iter = try user_repos.iteratorFromIndex(repos_start);
            var i = repos_start;
            while (i < end) : (i += 1) {
                var kv_cursor = (try repos_iter.next()) orelse break;
                const kv = try kv_cursor.readKeyValuePair();
                // the set key is orderKey = [created-order][event-id]; its trailing
                // bytes are the repo event id.
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try kv.key_cursor.readBytes(&order_key);
                const event_id = order_key[@sizeOf(u64)..];
                const repo_cursor = try event_id_to_repo.getCursor(hash.hashInt(hash_kind, event_id)) orelse continue;
                const repo_map = try DB.HashMap(.read_only).init(repo_cursor);
                const repo_event = try evt.read(evt.Repo.Record, DB, hash_kind, arena, repo_map);
                try repos.append(arena.allocator(), repo_event);
            }
            repos_next_start = if (end < count) end else null;
        }
    }

    var forks: std.ArrayList(ForkItem) = .empty;
    var forks_next_start: ?usize = null;
    if (try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Fork.user_id_to_fork_id_set_key))) |by_user_cursor| {
        const by_user = try DB.HashMap(.read_only).init(by_user_cursor);
        if (try by_user.getCursor(hash.hashInt(hash_kind, user_id))) |user_forks_cursor| {
            const user_forks = try DB.SortedSet(.read_only).init(user_forks_cursor);
            const repos_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Repo.record_map_key)) orelse return error.NotFound;
            const repo_records = try DB.HashMap(.read_only).init(repos_cursor);
            const count = try user_forks.count();
            const end = @min(forks_start + page_size, count);
            var iter = try user_forks.iteratorFromIndex(forks_start);
            var i = forks_start;
            while (i < end) : (i += 1) {
                const cursor = (try iter.next()) orelse break;
                var kv_cursor = cursor;
                const kv = try kv_cursor.readKeyValuePair();
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try kv.key_cursor.readBytes(&order_key);
                const fork_id = order_key[@sizeOf(u64)..];
                const record = (try evt.Fork.readById(DB, hash_kind, haxy_moment, arena, fork_id)) orelse continue;

                const repo_cursor = try repo_records.getCursor(hash.hashInt(hash_kind, record.event.repo_id)) orelse continue;
                const target_repo = try evt.read(evt.Repo.Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(repo_cursor));
                const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, target_repo.event.user_id)) orelse continue;
                const target = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ owner.event.name, target_repo.event.name });

                var title: []const u8 = "(unavailable)";
                if (session.io) |io| if (session.repos_dir) |repos_dir| {
                    const id_hex = std.fmt.bytesToHex(fork_id.*, .lower);
                    const path = try fork.forkPath(arena.allocator(), repos_dir, &id_hex);
                    if (rp.Repo(.xit, .{}).open(io, arena.child_allocator, .{ .path = path, .require_repo_root = true })) |opened| {
                        var fork_repo = opened;
                        defer fork_repo.deinit(io, arena.child_allocator);
                        if (evt.currentMoment(.{}, &fork_repo)) |moment| {
                            if (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, moment, arena, fork_id)) |patch| title = patch.event.title;
                        } else |_| {}
                    } else |_| {}
                };
                try forks.append(arena.allocator(), .{ .target = target, .title = title });
            }
            forks_next_start = if (end < count) end else null;
        }
    }

    return .{
        .header = try Header.init(arena, user.event.name),
        .user = evt.project(evt.User.Public, user.event),
        .repos = repos.items,
        .repos_start = repos_start,
        .repos_next_start = repos_next_start,
        .forks = forks.items,
        .forks_start = forks_start,
        .forks_next_start = forks_next_start,
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the repos-tab id for the auth
        // view (it focuses there after login).
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .user_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);

            // repos list — the default tab
            {
                var list = try ui.FlowBox.Scroll.init(allocator, .{}, !session.is_terminal);
                errdefer list.deinit(allocator);

                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const aa = arena.allocator();

                // a leading "previous" row off the first window, one row per repo,
                // then a trailing "next" row when more remain. each window row
                // navigates to the adjacent window of this user's repos.
                var items: std.ArrayList(ui.FlowBox.Item) = .empty;
                if (data.repos_start > 0)
                    try items.append(aa, .{ .text = "← previous", .link = try std.fmt.allocPrint(aa, "a:/user/{s}/repos/start:{d}", .{ data.user.name, data.repos_start -| page_size }) });
                for (data.repos) |repo|
                    // clicking a repo opens its page; the "a:" prefix makes the web
                    // renderer emit an <a href="/repo/alice/foo"> anchor.
                    try items.append(aa, .{
                        .text = try std.fmt.allocPrint(aa, "{s} - {s}", .{ repo.event.name, repo.event.description }),
                        .link = try std.fmt.allocPrint(aa, "a:/repo/{s}/{s}", .{ data.user.name, repo.event.name }),
                    });
                if (data.repos_next_start) |next_start|
                    try items.append(aa, .{ .text = "next →", .link = try std.fmt.allocPrint(aa, "a:/user/{s}/repos/start:{d}", .{ data.user.name, next_start }) });
                try list.setItems(allocator, items.items);

                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }

            // forks list
            {
                var list = try ui.FlowBox.Scroll.init(allocator, .{}, !session.is_terminal);
                errdefer list.deinit(allocator);

                var item_arena = std.heap.ArenaAllocator.init(allocator);
                defer item_arena.deinit();
                const aa = item_arena.allocator();
                var items: std.ArrayList(ui.FlowBox.Item) = .empty;
                if (data.forks_start > 0)
                    try items.append(aa, .{ .text = "← previous", .link = try std.fmt.allocPrint(aa, "a:/user/{s}/forks/start:{d}", .{ data.user.name, data.forks_start -| page_size }) });
                for (data.forks) |fork_item|
                    try items.append(aa, .{ .text = try std.fmt.allocPrint(aa, "{s}\n{s}", .{ fork_item.target, fork_item.title }), .link = "" });
                if (data.forks_next_start) |next_start|
                    try items.append(aa, .{ .text = "next →", .link = try std.fmt.allocPrint(aa, "a:/user/{s}/forks/start:{d}", .{ data.user.name, next_start }) });
                try list.setItems(allocator, items.items);
                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }

            // the header has no settings tab without a login, so keep the
            // stack's children 1:1 with the tabs by skipping the view too
            if (session.data.user_id != null) {
                var settings_view = try Settings.View.init(allocator, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            {
                var auth_view = try Auth.View.init(allocator, &data.auth, session);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, session);
                errdefer quit_view.deinit(allocator);
                try stack.children.put(allocator, quit_view.getFocus().id, .{ .quit = quit_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box };
        self.getFocus().child_id = box.children.keys()[header_index];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.user_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;

        // each header tab maps 1:1 to a stack child by position
        if (header.getSelectedIndex()) |index|
            stack.getFocus().child_id = stack.children.keys()[index];
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

                const direction = inp.vertDirection(key);

                switch (direction) {
                    .up => {
                        switch (child.*) {
                            .user_header => {
                                try child.input(allocator, key, root_focus);
                            },
                            .stack => {
                                if (child.stack.getSelected()) |selected_widget| {
                                    const at_top = switch (selected_widget.*) {
                                        .flow_box_scroll => |*v| v.getSelectedIndex() == 0,
                                        .home_settings => |*v| v.getSelectedIndex() == 0,
                                        .home_auth => |*v| v.getSelectedIndex() == 0,
                                        .quit => |*v| v.getSelectedIndex() == 0,
                                        else => false,
                                    };
                                    if (at_top) {
                                        index = header_index;
                                    } else {
                                        try child.input(allocator, key, root_focus);
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    .down => {
                        switch (child.*) {
                            .user_header => {
                                index = stack_index;
                            },
                            .stack => {
                                try child.input(allocator, key, root_focus);
                            },
                            else => {},
                        }
                    },
                    .none => {
                        try child.input(allocator, key, root_focus);
                    },
                }

                if (index != current_index) {
                    root_focus.setFocus(self.box.children.keys()[index]);
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
};

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
pub const Quit = @import("./Quit.zig");

pub const page_size = 20; // how many repos one window of the repos tab shows

pub const ForkItem = struct {
    id: []const u8,
    // the target repo, whose name and access the fork shares
    target: evt.Repo,
    title: []const u8,
};

header: Header,
user: evt.User.Public,
repos: []const evt.Repo.Record,
repos_start: usize, // the repos window this page was built with, mirrored into the url
repos_next_start: ?usize, // the `start` for the "next" row, or null on the last window
repos_search: ?[]const u8, // the name prefix the repos are narrowed to (decoded; null = no search)
forks: []const ForkItem,
forks_start: usize,
forks_next_start: ?usize,
quit: Quit,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    name: ui.RoutablePage.Array(evt.User.name_max_len),
    repos_start: usize,
    // the url-encoded repos search ("" = none)
    repos_search: []const u8,
    forks_start: usize,
) !Self {
    // admin and user repos share one db type
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    // a route identifies a user by name, which everything below keys off of
    const user_id = (try evt.User.readIdByName(DB, hash_kind, haxy_moment, name.slice())) orelse return error.NotFound;
    const user = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, &user_id)) orelse return error.NotFound;

    const io = session.io orelse return error.NoMoment;
    const users_dir = session.users_dir orelse return error.NoMoment;
    const gpa = arena.child_allocator;

    // a user with no user repo or no events has empty lists
    var user_repo_maybe = try evt.openUserRepo(io, gpa, users_dir, &user_id);
    defer if (user_repo_maybe) |*user_repo| user_repo.deinit(io, gpa);
    const user_moment = if (user_repo_maybe) |*user_repo| try evt.userMoment(user_repo) else null;

    const search: ?[]const u8 = if (repos_search.len == 0) null else std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, repos_search));

    var repos: std.ArrayList(evt.Repo.Record) = .empty;
    var repos_next_start: ?usize = null;
    if (user_moment) |moment| {
        if (search) |prefix| {
            if (try moment.getCursor(hash.hashInt(hash_kind, evt.Repo.name_index_key))) |index_cursor| {
                const index = try DB.SortedMap(.read_only).init(index_cursor);

                // the names with the prefix are contiguous from its rank, so the
                // window is one seek then a walk that stops at the first name without it
                var taken: usize = 0;
                var repos_iter = try index.iteratorFromIndex(try index.rank(prefix) +| repos_start);
                while (try repos_iter.next()) |cursor| {
                    const pair = try cursor.readKeyValuePair();
                    const repo_name = try pair.key_cursor.readBytesAlloc(arena.allocator(), null);
                    if (!std.mem.startsWith(u8, repo_name, prefix)) break;
                    if (taken == page_size) {
                        repos_next_start = repos_start + page_size;
                        break;
                    }
                    taken += 1;
                    var event_id: [evt.event_id_size]u8 = undefined;
                    _ = try pair.value_cursor.readBytes(&event_id);
                    const repo_event = (try evt.Repo.readById(DB, hash_kind, moment, arena, &event_id)) orelse continue;
                    // unreadable repos leave their window short rather than shifting the others
                    if (try evt.Repo.roleOf(DB, hash_kind, moment, arena, repo_event, &event_id, session.userId()) == null) continue;
                    try repos.append(arena.allocator(), repo_event);
                }
            }
        } else {
            // unsearched, the newest activity comes first. its index sits beside the events.
            const user_repo = if (user_repo_maybe) |*user_repo| user_repo else unreachable;
            if (try (try user_repo.core.latestMoment()).getCursor(hash.hashInt(hash_kind, evt.recent_repo_id_set_key))) |recent_cursor| {
                const recent = try DB.SortedSet(.read_only).init(recent_cursor);
                const count = try recent.count();
                const end = @min(repos_start +| page_size, count);
                var iter = try recent.iteratorFromIndex(repos_start);
                var i = repos_start;
                while (i < end) : (i += 1) {
                    const kv_cursor = (try iter.next()) orelse break;
                    const repo_id = try evt.readOrderKeyId(DB, kv_cursor);
                    const repo_event = (try evt.Repo.readById(DB, hash_kind, moment, arena, &repo_id)) orelse continue;
                    if (try evt.Repo.roleOf(DB, hash_kind, moment, arena, repo_event, &repo_id, session.userId()) == null) continue;
                    try repos.append(arena.allocator(), repo_event);
                }
                repos_next_start = if (end < count) end else null;
            }
        }
    }

    var forks: std.ArrayList(ForkItem) = .empty;
    var forks_next_start: ?usize = null;
    if (user_moment) |moment| {
        if (try moment.getCursor(hash.hashInt(hash_kind, evt.Fork.active_id_set_key))) |user_forks_cursor| {
            const user_forks = try DB.SortedSet(.read_only).init(user_forks_cursor);
            const count = try user_forks.count();
            const end = @min(forks_start +| page_size, count);
            var iter = try user_forks.iteratorFromIndex(forks_start);
            var i = forks_start;
            while (i < end) : (i += 1) {
                const kv_cursor = (try iter.next()) orelse break;
                const fork_id = try evt.readOrderKeyId(DB, kv_cursor);
                const fork_id_hex = std.fmt.bytesToHex(fork_id, .lower);
                const record = (try evt.Fork.readById(DB, hash_kind, moment, arena, &fork_id)) orelse continue;

                // the target lives in its owner's user repo
                const owner_id = record.event.repo_user_id[0..evt.event_id_size];
                const target = (try evt.readRepoById(io, gpa, arena, users_dir, owner_id, record.event.repo_id[0..evt.event_id_size], session.userId())) orelse continue;
                if (target.role == null) continue;
                // patches that are off take their drafts with them
                if (target.repo.event.patch_role == null) continue;
                const target_repo = target.repo;

                var title: []const u8 = "(unavailable)";
                const path = try fork.forkPath(arena.allocator(), users_dir, &user_id, &fork_id);
                if (rp.AnyRepo(.xit, .{}).open(io, gpa, .{ .path = path, .require_repo_root = true })) |opened| {
                    var any_fork = opened;
                    defer any_fork.deinit(io, gpa);
                    switch (any_fork) {
                        inline else => |*fork_repo| if (evt.currentMoment(fork_repo.self_repo_opts, fork_repo)) |fork_moment| {
                            const kind = fork_repo.self_repo_opts.hash;
                            if (try evt.Patch.readById(evt.EventDB(kind), kind, fork_moment, arena, &fork_id)) |patch| title = patch.event.title;
                        } else |_| {},
                    }
                } else |_| {}
                try forks.append(arena.allocator(), .{
                    .id = try arena.allocator().dupe(u8, &fork_id_hex),
                    .target = target_repo.event,
                    .title = title,
                });
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
        .repos_search = search,
        .forks = forks.items,
        .forks_start = forks_start,
        .forks_next_start = forks_next_start,
        .quit = Quit.init(),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .round_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the repos-tab id for the user
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
                var repos_view = try ReposView.init(allocator, data, session);
                errdefer repos_view.deinit(allocator);
                try stack.children.put(allocator, repos_view.getFocus().id, .{ .user_repos = repos_view });
            }

            // forks list
            {
                var list = try ui.widget.FlowBox.Scroll.init(allocator, .{}, !session.is_terminal);
                errdefer list.deinit(allocator);

                var item_arena = std.heap.ArenaAllocator.init(allocator);
                defer item_arena.deinit();
                const aa = item_arena.allocator();
                var items: std.ArrayList(ui.widget.FlowBox.Item) = .empty;
                if (data.forks_start > 0)
                    try items.append(aa, .{ .text = "← previous", .link = try aa.print("a:/{s}/forks/start:{d}", .{ data.user.name, data.forks_start -| page_size }) });
                for (data.forks) |fork_item| {
                    // the fork route names the forker
                    const identity = try aa.print("{s}:{s}", .{ data.user.name, fork_item.target.name });
                    const route = ui.RoutablePage.forkPatchRoute(identity, fork_item.id) orelse return error.RouteTooLong;
                    try items.append(aa, .{
                        .text = try aa.print("{s} - {s}", .{ fork_item.target.name, fork_item.title }),
                        .link = try aa.print("a:{s}", .{try route.toUrl(session.page_arena)}),
                        .bottom_label = if (fork_item.target.read_access == .private) "(private)" else "",
                    });
                }
                if (data.forks_next_start) |next_start|
                    try items.append(aa, .{ .text = "next →", .link = try aa.print("a:/{s}/forks/start:{d}", .{ data.user.name, next_start }) });
                try list.setItems(allocator, items.items);
                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }

            // the header shows new repo with a login and new user without
            // one, so keep the stack's children 1:1 with the tabs
            if (session.data.user_id != null) {
                const route = ui.RoutablePage{ .user_repo_new = ui.RoutablePage.Array(evt.User.name_max_len).from(data.user.name) orelse return error.RouteTooLong };
                var new_repo_view = try ui.NewRepo.View.init(allocator, session, route);
                errdefer new_repo_view.deinit(allocator);
                try stack.children.put(allocator, new_repo_view.getFocus().id, .{ .new_repo = new_repo_view });
            } else {
                const route = ui.RoutablePage{ .user_user_new = ui.RoutablePage.Array(evt.User.name_max_len).from(data.user.name) orelse return error.RouteTooLong };
                var new_user_view = try ui.NewUser.View.init(allocator, session, route);
                errdefer new_user_view.deinit(allocator);
                try stack.children.put(allocator, new_user_view.getFocus().id, .{ .new_user = new_user_view });
            }

            {
                var user_view = try ui.UserSettings.initView(allocator, session);
                errdefer user_view.deinit(allocator);
                try stack.children.put(allocator, user_view.getFocus().id, user_view);
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, session);
                errdefer quit_view.deinit(allocator);
                try stack.children.put(allocator, quit_view.getFocus().id, .{ .quit = quit_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box };
        // search results open in the tab's own search box
        self.getFocus().child_id = box.children.keys()[if (data.repos_search != null) stack_index else header_index];
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
        const stack = &self.box.children.values()[stack_index].widget.stack;
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
                                    if (selected_widget.atTop(root_focus)) {
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
                                if (stack.getSelected()) |selected_widget| switch (selected_widget.*) {
                                    .user_repos => |*v| return v.focusHeader(root_focus),
                                    // an empty list has nothing to focus
                                    .flow_box_scroll => |*v| if (v.isEmpty()) return,
                                    else => {},
                                };
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

pub const ReposView = struct {
    // a vertical box: the search sub-header above the scrolling list. focus
    // points at the header's box or the list's selected row.
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index = 0;
    const list_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !ReposView {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            {
                var search_box = try ui.widget.SearchBox.init(allocator, session, " search ", "search", data.repos_search);
                errdefer search_box.deinit(allocator);
                header.getFocus().child_id = search_box.getFocus().id;
                try header.children.put(allocator, search_box.getFocus().id, .{ .widget = .{ .search_box = search_box }, .rect = null, .min_size = ui.widget.SearchBox.min_size });
            }
            // the spacer keeps the box at its own width
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try header.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
            try box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = ui.widget.SearchBox.min_size.height } });
        }

        {
            var list = try ui.widget.FlowBox.Scroll.init(allocator, .{}, !session.is_terminal);
            errdefer list.deinit(allocator);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            const route = (reposRoute(data.user.name) orelse return error.RouteTooLong).withSearch(data.repos_search orelse "") orelse return error.RouteTooLong;

            // a leading "previous" row off the first window, one row per repo,
            // then a trailing "next" row when more remain. each window row
            // navigates to the adjacent window of this user's repos.
            var items: std.ArrayList(ui.widget.FlowBox.Item) = .empty;
            if (data.repos_start > 0) {
                var prev = route;
                prev.user_repos.start = data.repos_start -| page_size;
                try items.append(aa, .{ .text = "← previous", .link = try aa.print("a:{s}", .{try prev.toUrl(&arena)}) });
            }
            for (data.repos) |repo|
                // clicking a repo opens its page; the "a:" prefix makes the web
                // renderer emit an <a href="/alice:foo"> anchor.
                try items.append(aa, .{
                    .text = if (repo.event.description.len == 0) repo.event.name else try aa.print("{s} - {s}", .{ repo.event.name, repo.event.description }),
                    .link = try aa.print("a:/{s}:{s}", .{ data.user.name, repo.event.name }),
                    .bottom_label = if (repo.event.read_access == .private) "(private)" else "",
                });
            if (data.repos_next_start) |next_start| {
                var next = route;
                next.user_repos.start = next_start;
                try items.append(aa, .{ .text = "next →", .link = try aa.print("a:{s}", .{try next.toUrl(&arena)}) });
            }
            try list.setItems(allocator, items.items);

            try box.children.put(allocator, list.getFocus().id, .{ .widget = .{ .flow_box_scroll = list }, .rect = null, .min_size = null });
        }

        // search results start in the box so the term can be refined right away
        box.getFocus().child_id = box.children.keys()[if (data.repos_search != null) header_index else list_index];
        return .{ .box = box, .data = data, .session = session };
    }

    pub fn deinit(self: *ReposView, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *ReposView, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // clear the incoming min height so the list scrolls within what's left
        try self.box.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *ReposView, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            const search_box = self.searchBox();
            if (direction == .down) return root_focus.setFocus(self.listScroll().getFocus().id);
            if (key == .enter) {
                const text = try search_box.text(allocator);
                defer allocator.free(text);
                return self.submit(text);
            }
            return search_box.input(allocator, key, root_focus);
        }
        // up from the first row reaches the search box
        if (direction == .up and self.listScroll().atTop()) return self.focusHeader(root_focus);
        try self.listScroll().input(allocator, key, root_focus);
    }

    // the repos narrowed to `text` from the first window. an empty box on an
    // unsearched page has nothing to clear.
    fn submit(self: *ReposView, text: []const u8) !void {
        if (text.len == 0 and self.data.repos_search == null) return;
        const route = reposRoute(self.data.user.name) orelse return;
        try self.session.navigate(route.withSearch(text) orelse return);
    }

    fn searchBox(self: *ReposView) *ui.widget.SearchBox {
        return &self.box.children.values()[header_index].widget.box.children.values()[0].widget.search_box;
    }

    fn listScroll(self: *ReposView) *ui.widget.FlowBox.Scroll {
        return &self.box.children.values()[list_index].widget.flow_box_scroll;
    }

    fn headerActive(self: *ReposView) bool {
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
    }

    pub fn clearGrid(self: *ReposView) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: ReposView) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *ReposView) *Focus {
        return self.box.getFocus();
    }

    // up leaves the tab from the search box
    pub fn atTop(self: *ReposView) bool {
        return self.headerActive();
    }

    pub fn focusHeader(self: *ReposView, root_focus: *Focus) void {
        root_focus.setFocus(self.searchBox().getFocus().id);
    }
};

// the first window of `name`'s repos
fn reposRoute(name: []const u8) ?ui.RoutablePage {
    return .{ .user_repos = .{ .name = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return null } };
}

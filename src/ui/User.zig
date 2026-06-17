const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Header = @import("./User/Header.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
user: evt.User.Safe,
repos: []const evt.Repo,
settings: Settings,
auth: Auth,
quit: Quit,
route_name: ui.RoutablePage.Array(evt.User.name_max_len),

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    name: ui.RoutablePage.Array(evt.User.name_max_len),
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

    var repos: std.ArrayList(evt.Repo) = .empty;

    // the user-id->repos index maps each user to the set of repo event ids they
    // own; it only exists once a repo has been consumed, so a user with no repos
    // simply yields an empty list.
    if (try haxy_moment.getCursor(hash.hashInt(hash_kind, "user-id->repos"))) |user_id_to_repos_cursor| {
        const user_id_to_repos = try DB.HashMap(.read_only).init(user_id_to_repos_cursor);
        if (try user_id_to_repos.getCursor(hash.hashInt(hash_kind, user_id))) |user_repos_cursor| {
            const user_repos = try DB.CountedHashSet(.read_only).init(user_repos_cursor);

            const event_id_to_repo_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->repo")) orelse return error.NotFound;
            const event_id_to_repo = try DB.HashMap(.read_only).init(event_id_to_repo_cursor);

            var repos_iter = try user_repos.iterator();
            while (try repos_iter.next()) |kv_cursor| {
                const kv = try kv_cursor.readKeyValuePair();
                const repo_cursor = try event_id_to_repo.getCursor(kv.hash) orelse continue;
                const repo_map = try DB.HashMap(.read_only).init(repo_cursor);
                const repo_event = try evt.read(evt.Repo, DB, hash_kind, arena, repo_map);
                try repos.append(arena.allocator(), repo_event);
            }
        }
    }

    return .{
        .header = try Header.init(arena, user.name),
        .user = evt.User.Safe.init(user),
        .repos = repos.items,
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
        .route_name = name,
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the repos-tab id for the auth
        // view (it focuses there after login).
        var repos_tab_id: usize = undefined;
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            repos_tab_id = header_view.tab_ids.keys()[0];
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

                var items: std.ArrayList(ui.FlowBox.Item) = .empty;
                for (data.repos) |repo|
                    // clicking a repo opens its page; the "a:" prefix makes the web
                    // renderer emit an <a href="/repo/alice/foo"> anchor.
                    try items.append(aa, .{
                        .text = try std.fmt.allocPrint(aa, "{s} - {s}", .{ repo.name, repo.description }),
                        .link = try std.fmt.allocPrint(aa, "a:/repo/{s}/{s}", .{ data.user.name, repo.name }),
                    });
                try list.setItems(allocator, items.items);

                try stack.children.put(allocator, list.getFocus().id, .{ .flow_box_scroll = list });
            }

            {
                var settings_view = try Settings.View.init(allocator, &data.settings, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            {
                var auth_view = try Auth.View.init(allocator, &data.auth, session, repos_tab_id);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, &data.quit, session);
                errdefer quit_view.deinit(allocator);
                try stack.children.put(allocator, quit_view.getFocus().id, .{ .quit = quit_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box, .data = data, .session = session };
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

        // each header tab maps 1:1 to a stack child by position. mirror the
        // selection into current_page so the host can push the matching url;
        // all user tabs share the .user parent, so this stays on the page
        // rather than navigating.
        if (header.getSelectedIndex()) |index| {
            stack.getFocus().child_id = stack.children.keys()[index];
            const name = self.data.route_name;
            switch (std.meta.activeTag(stack.children.values()[index])) {
                .home_settings => self.session.data.current_page = .{ .user_settings = name },
                .home_auth => self.session.data.current_page = .{ .user_auth = name },
                // the quit tab is tty-only and not a route, so leave current_page
                // alone (nothing to mirror into the url).
                .quit => {},
                // the repos list (the default tab)
                else => self.session.data.current_page = .{ .user = name },
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

                const Direction = enum { up, down, none };
                const direction: Direction = switch (key) {
                    .arrow_up => .up,
                    .arrow_down => .down,
                    .mouse => |mouse| if (mouse.action == .scroll)
                        (if (mouse.action.scroll == .up) .up else .down)
                    else
                        .none,
                    else => .none,
                };

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
};

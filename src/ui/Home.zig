const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Users = @import("./Home/Users.zig");
pub const Repos = @import("./Home/Repos.zig");
pub const Header = @import("./Home/Header.zig");
pub const Auth = @import("./Home/Auth.zig");

header: Header,
users: Users,
repos: Repos,
auth: Auth,

const Self = @This();

pub fn init(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    haxy_moment: rp.Repo(.xit, repo_opts).DB.HashMap(.read_only),
) !Self {
    return .{
        .header = Header.init(),
        .users = try Users.init(repo_opts, arena, haxy_moment),
        .repos = try Repos.init(repo_opts, arena, haxy_moment),
        .auth = Auth.init(),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = wgt.Box(ui.Widget).init(.{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the users-tab focus id and
        // hand it to login/logout
        var users_tab_id: usize = undefined;
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            users_tab_id = header_view.tab_ids[0];
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .home_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = wgt.Stack(ui.Widget).init();
            errdefer stack.deinit(allocator);

            {
                var users_view = try Users.View.init(allocator, &data.users);
                errdefer users_view.deinit(allocator);
                try stack.children.put(allocator, users_view.getFocus().id, .{ .home_users = users_view });
            }

            {
                var repos_view = try Repos.View.init(allocator, &data.repos);
                errdefer repos_view.deinit(allocator);
                try stack.children.put(allocator, repos_view.getFocus().id, .{ .home_repos = repos_view });
            }

            {
                var auth_view = try Auth.View.init(allocator, &data.auth, session, users_tab_id);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{
            .box = box,
            .data = data,
            .session = session,
        };
        self.getFocus().child_id = box.children.keys()[header_index];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.home_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;

        // each header tab maps 1:1 to a stack child by position
        if (header.getSelectedIndex()) |index| {
            stack.getFocus().child_id = stack.children.keys()[index];
            self.session.data.current_page = switch (index) {
                0 => .home_users,
                1 => .home_repos,
                2 => .home_auth,
                else => .home_users,
            };
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
                            .home_header => {
                                try child.input(allocator, key, root_focus);
                            },
                            .stack => {
                                if (child.stack.getSelected()) |selected_widget| {
                                    const at_top = switch (selected_widget.*) {
                                        .home_users => |*v| v.getSelectedIndex() == 0,
                                        .home_repos => |*v| v.getSelectedIndex() == 0,
                                        .home_auth => |*v| v.getSelectedIndex() == 0,
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
                            .home_header => {
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

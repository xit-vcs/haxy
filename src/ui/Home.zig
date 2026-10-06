const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");
const evt = @import("../event.zig");

pub const About = @import("./Home/About.zig");
pub const Users = @import("./Home/Users.zig");
pub const Header = @import("./Home/Header.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
about: About,
users: Users,
quit: Quit,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    // the users tab's window and search
    users_route: ui.RoutablePage.HomeUsersRoute,
) !Self {
    const about = try About.init(arena, session);
    return .{
        .header = try Header.init(arena, about.title),
        .about = about,
        .users = try Users.init(arena, haxy_moment, users_route),
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

        // build the header first so we can grab the users-tab focus id and
        // hand it to login/logout
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .home_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);

            {
                var about_view = try About.View.init(allocator, &data.about, session);
                errdefer about_view.deinit(allocator);
                try stack.children.put(allocator, about_view.getFocus().id, .{ .home_about = about_view });
            }

            {
                var users_view = try Users.View.init(allocator, &data.users, session);
                errdefer users_view.deinit(allocator);
                try stack.children.put(allocator, users_view.getFocus().id, .{ .home_users = users_view });
            }

            // the header shows new repo with a login and new user without
            // one, so keep the stack's children 1:1 with the tabs
            if (session.data.user_id != null) {
                var new_repo_view = try ui.NewRepo.View.init(allocator, session, .home_repo_new);
                errdefer new_repo_view.deinit(allocator);
                try stack.children.put(allocator, new_repo_view.getFocus().id, .{ .new_repo = new_repo_view });
            } else {
                var new_user_view = try ui.NewUser.View.init(allocator, session, .home_user_new);
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

        var self = View{
            .box = box,
        };
        // search results open in the tab's own search box
        self.getFocus().child_id = box.children.keys()[if (data.users.search != null) stack_index else header_index];
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
                            .home_header => {
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
                            .home_header => {
                                if (stack.getSelected()) |selected_widget| switch (selected_widget.*) {
                                    .home_users => |*v| return v.focusHeader(root_focus),
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

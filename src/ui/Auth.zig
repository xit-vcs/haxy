const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Login = @import("./Auth/Login.zig");
pub const Logout = @import("./Auth/Logout.zig");

login: Login,
logout: Logout,

const Self = @This();

pub fn init() Self {
    return .{
        .login = Login.init(),
        .logout = Logout.init(),
    };
}

pub const View = struct {
    stack: wgt.Stack(ui.Widget),
    session: *ui.Session,

    const login_index = 0;
    const logout_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var stack = try wgt.Stack(ui.Widget).init(allocator);
        errdefer stack.deinit(allocator);
        {
            var login = try Login.View.init(allocator, &data.login, session);
            errdefer login.deinit(allocator);
            try stack.children.put(allocator, login.getFocus().id, .{ .auth_login = login });
        }
        {
            var logout = try Logout.View.init(allocator, &data.logout, session);
            errdefer logout.deinit(allocator);
            try stack.children.put(allocator, logout.getFocus().id, .{ .auth_logout = logout });
        }
        return .{
            .stack = stack,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const index: usize = if (self.session.data.user_id != null) logout_index else login_index;
        self.stack.getFocus().child_id = self.stack.children.keys()[index];
        try self.stack.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try self.stack.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *View) void {
        self.stack.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.stack.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.stack.getFocus();
    }

    pub fn atTop(self: View, root_focus: *Focus) bool {
        const selected = self.stack.getSelected() orelse return false;
        return selected.atTop(root_focus);
    }
};

const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const layout = xitui.layout;
const inp = xitui.input;
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
    // own container focus so callers (e.g. wgt.Stack) see a stable id. the
    // inner views' focus ids change as login/logout swap; if we exposed those
    // directly, anything keyed off our id at one moment would mismatch the
    // focus tree the next frame.
    focus: Focus,
    login: Login.View,
    logout: Logout.View,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, users_tab_id: usize) !View {
        var login_view = try Login.View.init(allocator, &data.login, session, users_tab_id);
        errdefer login_view.deinit(allocator);
        var logout_view = try Logout.View.init(allocator, &data.logout, session, users_tab_id);
        errdefer logout_view.deinit(allocator);
        return .{
            .focus = Focus.init(allocator, .container),
            .login = login_view,
            .logout = logout_view,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.focus.deinit();
        self.login.deinit(allocator);
        self.logout.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.focus.clear();
        if (self.session.user_id != null) {
            try self.logout.build(allocator, constraint, root_focus);
            if (self.logout.getGrid()) |inner_grid| {
                try self.focus.addChild(self.logout.getFocus(), inner_grid.size, 0, 0);
            }
            self.focus.child_id = self.logout.getFocus().id;
        } else {
            try self.login.build(allocator, constraint, root_focus);
            if (self.login.getGrid()) |inner_grid| {
                try self.focus.addChild(self.login.getFocus(), inner_grid.size, 0, 0);
            }
            self.focus.child_id = self.login.getFocus().id;
        }
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.session.user_id != null) {
            try self.logout.input(allocator, key, root_focus);
        } else {
            try self.login.input(allocator, key, root_focus);
        }
    }

    pub fn clearGrid(self: *View) void {
        self.login.clearGrid();
        self.logout.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        if (self.session.user_id != null) return self.logout.getGrid();
        return self.login.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return &self.focus;
    }

    pub fn getSelectedIndex(self: View) ?usize {
        if (self.session.user_id != null) return self.logout.getSelectedIndex();
        return self.login.getSelectedIndex();
    }
};

const std = @import("std");
const builtin = @import("builtin");
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
const bcrypt = std.crypto.pwhash.bcrypt;

const wasm = builtin.target.cpu.arch == .wasm32;

const Self = @This();

// classifies a failed /login attempt; null in session.data.login_failure means
// "no failure to surface".
pub const Failure = enum { wrong_password, unknown_user };

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.Center,
    data: *const Self,
    session: *ui.Session,
    nav_ids: [3]usize,
    // focus id of the header's "users" tab; on a successful submit we jump
    // focus there so the user isn't stranded on the login button.
    users_tab_id: usize,

    const username_index: usize = 0;
    const password_index: usize = 1;
    const button_index: usize = 2;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, users_tab_id: usize) !View {
        var box = wgt.Box(ui.Widget).init(.{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        // marks this subtree as an HTML form scope for the web overlay
        box.getFocus().kind = .{ .custom = "form:/login" };

        var nav_ids: [3]usize = undefined;

        {
            var username = wgt.TextInput(ui.Widget).init(.{ .label = " username ", .name = "username", .rounded_corners = true, .render_content = !wasm });
            errdefer username.deinit(allocator);
            username.getFocus().focusable = true;
            nav_ids[username_index] = username.getFocus().id;
            try box.children.put(allocator, username.getFocus().id, .{
                .widget = .{ .text_input = username },
                .rect = null,
                .min_size = null,
            });
        }

        {
            var password = wgt.TextInput(ui.Widget).init(.{ .label = " password ", .password = true, .name = "password", .rounded_corners = true, .render_content = !wasm });
            errdefer password.deinit(allocator);
            password.getFocus().focusable = true;
            nav_ids[password_index] = password.getFocus().id;
            try box.children.put(allocator, password.getFocus().id, .{
                .widget = .{ .text_input = password },
                .rect = null,
                .min_size = null,
            });
        }

        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, "login", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            // the renderer distinguishes plain clickables from buttons that
            // should POST to a server route by this kind.
            button.getFocus().kind = .{ .custom = "submit" };
            nav_ids[button_index] = button.getFocus().id;
            try box.children.put(allocator, button.getFocus().id, .{
                .widget = .{ .text_box = button },
                .rect = null,
                .min_size = null,
            });
        }

        box.getFocus().child_id = nav_ids[username_index];

        return .{
            .center = try ui.Center.init(allocator, .{ .box = box }, .both),
            .data = data,
            .session = session,
            .nav_ids = nav_ids,
            .users_tab_id = users_tab_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const box = &self.center.child.box;

        const failure = self.session.data.login_failure;

        const username_input = &box.children.values()[username_index].widget.text_input;
        username_input.options.label = if (failure == .unknown_user)
            " username (invalid) "
        else
            " username ";

        const password_input = &box.children.values()[password_index].widget.text_input;
        password_input.options.label = if (failure == .wrong_password)
            " password (invalid) "
        else
            " password ";

        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        const box = &self.center.child.box;
        const child_id = box.focus.child_id orelse return;
        const current = self.indexOf(child_id) orelse return;

        switch (key) {
            // Shift+Tab walks backward through the form, matching the
            // typical UX; arrow_up does the same.
            .arrow_up, .back_tab => if (current > 0) {
                try root_focus.setFocus(self.nav_ids[current - 1]);
                return;
            },
            // Tab moves to the next field, matching the form-style UX users
            // expect; arrow_down does the same.
            .arrow_down, .tab => if (current + 1 < self.nav_ids.len) {
                try root_focus.setFocus(self.nav_ids[current + 1]);
                return;
            },
            // submit on Enter from any nav field — typical "press Enter in
            // a form to submit" UX
            .enter => {
                try self.submit(allocator, root_focus);
                return;
            },
            else => {},
        }

        if (current == button_index) {
            switch (key) {
                .mouse => |mouse| {
                    if (mouse.action == .press and mouse.action.press == .left) {
                        if (root_focus.children.get(child_id)) |entry| {
                            const r = entry.rect;
                            if (mouse.x >= r.x and mouse.y >= r.y and
                                mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                            {
                                try self.submit(allocator, root_focus);
                                return;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const username_input = &box.children.values()[username_index].widget.text_input;
        const password_input = &box.children.values()[password_index].widget.text_input;
        const username_len_before = username_input.content.items.len;
        const password_len_before = password_input.content.items.len;

        if (box.children.getIndex(child_id)) |idx| {
            try box.children.values()[idx].widget.input(allocator, key, root_focus);
        }

        if (username_input.content.items.len != username_len_before or
            password_input.content.items.len != password_len_before)
        {
            // any edit clears the failure flag so the "(invalid)" label
            // doesn't linger after the user has typed a correction.
            self.session.data.login_failure = null;
        }
    }

    pub fn clearGrid(self: *View) void {
        self.center.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.center.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.center.getFocus();
    }

    pub fn getSelectedIndex(self: View) ?usize {
        const child_id = self.center.child.box.focus.child_id orelse return null;
        return self.indexOf(child_id);
    }

    fn indexOf(self: View, child_id: usize) ?usize {
        for (self.nav_ids, 0..) |id, i| {
            if (id == child_id) return i;
        }
        return null;
    }

    fn submit(self: *View, allocator: std.mem.Allocator, root_focus: *Focus) !void {
        if (comptime wasm) {
            // no DB cursor available on the wasm render path
            self.session.data.login_failure = .unknown_user;
            return;
        }

        const box = &self.center.child.box;
        const username_input = &box.children.values()[username_index].widget.text_input;
        const password_input = &box.children.values()[password_index].widget.text_input;

        const username = try username_input.text(allocator);
        defer allocator.free(username);

        const password = try password_input.text(allocator);
        defer allocator.free(password);

        const haxy_moment = self.session.haxy_moment orelse {
            // no DB context (e.g. wasm/web rendering path); treat as unknown.
            self.session.data.login_failure = .unknown_user;
            return;
        };

        const result = try evt.User.verifyCredentials(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, self.session.arena, username, password);
        switch (result) {
            .unknown_user => {
                self.session.data.login_failure = .unknown_user;
                return;
            },
            .wrong_password => {
                self.session.data.login_failure = .wrong_password;
                return;
            },
            .success => |user_id| {
                // dupe user_id into the arena so the session can hold a stable slice
                const user_id_stable = try self.session.arena.allocator().dupe(u8, &user_id);
                self.session.data.user_id = user_id_stable;
                self.session.data.login_failure = null;

                // adopt the user's persisted prefs
                try self.session.loadUserPrefs();

                // wipe the entered credentials so they don't linger if the
                // user returns to this page after logging out
                username_input.clear(allocator);
                password_input.clear(allocator);

                // jump focus back to the users tab — the login button we
                // just pressed is about to be hidden by the tab-label swap
                try root_focus.setFocus(self.users_tab_id);
            },
        }
    }
};

const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// the logged-in user's settings, or the login form when logged out
pub fn initView(allocator: std.mem.Allocator, session: *ui.Session) !ui.Widget {
    if (session.data.user_id != null) return .{ .user_settings = try View.init(allocator, session) };
    return .{ .user_login = try ui.UserLogin.View.init(allocator, session) };
}

// the user tab's label: the logged-in user's name, or "login"
pub fn tabLabel(session: *const ui.Session) []const u8 {
    if (session.data.user_id == null) return "login";
    return session.data.user_name orelse unreachable;
}

const logout_label = "logout";

pub const View = struct {
    // a vertical box: the logout sub-header above a centered form, scrolled
    // when it outgrows the window
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    logout_id: usize,
    // the form's controls in order: email, the passwords, then submit
    control_ids: [5]usize,

    const header_index = 0;
    const scroll_index = 1;
    // a row taller than the button, leaving a blank line above the form
    const header_height = 4;
    // the form's children: the email box, the bordered password box, submit
    const passwords_index = 1;
    const submit_index = 2;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        var logout_id: usize = undefined;
        {
            // the form kind makes the web renderer post the button to /logout
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            header.getFocus().kind = .{ .custom = "form:logout" };
            // the spacer pushes the logout button to the right edge
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try header.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
            {
                var button = try wgt.TextBox.init(allocator, logout_label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().mode = .all;
                // the renderer distinguishes plain clickables from buttons that
                // should POST to a server route by this kind.
                button.getFocus().kind = .{ .custom = "submit" };
                logout_id = button.getFocus().id;
                header.getFocus().child_id = logout_id;
                try header.children.put(allocator, logout_id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = logout_label.len + 2, .height = 3 } });
            }
            try outer.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = header_height } });
        }

        var control_ids: [5]usize = undefined;
        {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
            errdefer box.deinit(allocator);
            // the form posts to the page's own user tab
            box.getFocus().kind = .{ .custom = "form:user" };

            const saved_fields = if (session.formFeedback(.user_settings)) |saved| saved.fields else null;

            {
                var email = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " email " }, .name = "email", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
                errdefer email.deinit(allocator);
                email.getFocus().mode = .all;
                try email.setContent(allocator, if (saved_fields) |saved| saved.email else session.data.user_email orelse unreachable);
                // show the start of the prefilled text
                email.cursor = 0;
                control_ids[0] = email.getFocus().id;
                box.getFocus().child_id = email.getFocus().id;
                try box.children.put(allocator, email.getFocus().id, .{ .widget = .{ .text_input = email }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            // the password changes only when all three are filled in
            {
                var passwords = try wgt.Box(ui.Widget).init(allocator, .{ .border = .single, .round_corners = true, .direction = .vert, .top_label = .{ .text = " password " } });
                errdefer passwords.deinit(allocator);
                const fields = [_]struct { label: []const u8, name: []const u8 }{
                    .{ .label = " old ", .name = "current_password" },
                    .{ .label = " new ", .name = "new_password" },
                    .{ .label = " new again ", .name = "new_password_again" },
                };
                for (fields, 1..) |field, index| {
                    // narrower by the border, so the box lines up with the email box
                    var password = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = field.label }, .password = true, .name = field.name, .visible_width = 28, .round_corners = true, .render_content = session.is_terminal });
                    errdefer password.deinit(allocator);
                    password.getFocus().mode = .all;
                    control_ids[index] = password.getFocus().id;
                    try passwords.children.put(allocator, password.getFocus().id, .{ .widget = .{ .text_input = password }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
                }
                passwords.getFocus().child_id = control_ids[1];
                try box.children.put(allocator, passwords.getFocus().id, .{ .widget = .{ .box = passwords }, .rect = null, .min_size = null });
            }

            {
                var submit = try ui.widget.SubmitButton.initLabeled(allocator, "submit changes");
                errdefer submit.deinit(allocator);
                control_ids[4] = submit.buttonId();
                try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            var center = try ui.widget.Center.init(allocator, .{ .box = box });
            errdefer center.deinit(allocator);
            var scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            errdefer scroll.deinit(allocator);
            try outer.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });
        }

        outer.getFocus().child_id = outer.children.keys()[scroll_index];
        return .{ .box = outer, .session = session, .logout_id = logout_id, .control_ids = control_ids };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const failure = if (self.session.formFeedback(.user_settings)) |saved| saved.failure else null;
        (try self.formField("email")).options.top_label.text = if (failure) |value| switch (value) {
            .required_email => " email (required) ",
            .email_taken => " email (taken) ",
            else => " email ",
        } else " email ";
        (try self.formField("current_password")).options.top_label.text = if (failure == .wrong_password) " old (wrong) " else " old ";
        (try self.formField("new_password")).options.top_label.text = if (failure == .required_password) " new (required) " else " new ";
        (try self.formField("new_password_again")).options.top_label.text = if (failure == .password_mismatch) " new again (doesn't match) " else " new again ";
        // the web form handling finds the inputs by focus id
        const inputs_arena = self.session.arena.allocator();
        for (self.formBoxes()) |box| for (box.children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
            else => {},
        };
        // the window's height below the sub-header as a minimum centers a form that fits
        const viewport_height = constraint.max_size.height orelse constraint.min_size.height;
        self.box.children.values()[scroll_index].min_size = .{ .width = null, .height = if (viewport_height) |height| height -| header_height else null };
        try self.box.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (key == .mouse and inp.leftClickOn(root_focus, self.logout_id, key.mouse)) return self.logOut();
        if (self.headerActive()) {
            if (key == .tab or inp.vertDirection(key) == .down) return root_focus.setFocus(self.control_ids[0]);
            if (key == .enter) try self.logOut();
            return;
        }

        const focused = root_focus.grandchild_id orelse return;
        const cur = std.mem.indexOfScalar(usize, &self.control_ids, focused) orelse return;
        const submit_id = self.control_ids[self.control_ids.len - 1];
        const on_submit = focused == submit_id;
        const direction = inp.vertDirection(key);
        const up = direction == .up or key == .back_tab;
        if (up or direction == .down or key == .tab) {
            // up leaves the form from its first control for the logout button
            if (up and cur == 0) return root_focus.setFocus(self.logout_id);
            const next = if (up) cur - 1 else cur + 1;
            if (next == self.control_ids.len) return;
            root_focus.setFocus(self.control_ids[next]);
            if (self.session.is_terminal) if (self.controlRect(next)) |rect| ui.widget.scrollToCenteredRect(self.formScroll(), rect);
            return;
        }
        switch (key) {
            .enter => if (on_submit) return self.submitForm(allocator),
            .mouse => |mouse| if (inp.leftClickOn(root_focus, submit_id, mouse)) return self.submitForm(allocator),
            else => {},
        }
        if (!on_submit) try (try self.formInput(focused)).input(allocator, key, root_focus);
    }

    fn logOut(self: *View) !void {
        self.session.logOut();
        // leave the user tab for the page it belongs to, where the web's
        // /logout redirect also lands
        try self.session.navigate(self.session.data.current_page.pageRoot());
    }

    // the boxes holding the form's inputs: the form itself and the password box
    fn formBoxes(self: *View) [2]*wgt.Box(ui.Widget) {
        const form = self.formBox();
        return .{ form, &form.children.values()[passwords_index].widget.box };
    }

    fn formField(self: *View, name: []const u8) !*wgt.TextInput {
        for (self.formBoxes()) |box| for (box.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| if (std.mem.eql(u8, text_input.options.name, name)) return text_input,
            else => {},
        };
        return error.MissingFormField;
    }

    fn formInput(self: *View, id: usize) !*wgt.TextInput {
        for (self.formBoxes()) |box| if (box.children.getPtr(id)) |child| return &child.widget.text_input;
        return error.MissingFormField;
    }

    // the rect of the control at `index` in the form's space; a password's is
    // offset by its box
    fn controlRect(self: *View, index: usize) ?layout.IRect {
        const form, const passwords = self.formBoxes();
        return switch (index) {
            0 => form.children.values()[0].rect,
            self.control_ids.len - 1 => form.children.values()[submit_index].rect,
            else => {
                const outer = form.children.values()[passwords_index].rect orelse return null;
                const inner = passwords.children.values()[index - 1].rect orelse return null;
                return .{ .x = outer.x + inner.x, .y = outer.y + inner.y, .size = inner.size };
            },
        };
    }

    // update the user. this is the terminal path; the web posts the form to
    // the user route.
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const admin_repo = self.session.admin_repo orelse return;
        const user_id = self.session.userId() orelse return;

        const email = try (try self.formField("email")).text(allocator);
        defer allocator.free(email);
        const current_password = try (try self.formField("current_password")).text(allocator);
        defer allocator.free(current_password);
        const new_password = try (try self.formField("new_password")).text(allocator);
        defer allocator.free(new_password);
        const new_password_again = try (try self.formField("new_password_again")).text(allocator);
        defer allocator.free(new_password_again);

        evt.updateUser(io, allocator, users_dir, admin_repo, &user_id, email, current_password, new_password, new_password_again) catch |err| switch (err) {
            // the account was removed under them
            error.NotFound => return self.logOut(),
            else => {
                const failure = ui.Session.FormFeedback.UserFailure.fromError(err) orelse return err;
                const aa = self.session.arena.allocator();
                self.session.data.form_feedback = .{ .user_settings = .{ .failure = failure, .fields = .{ .email = try aa.dupe(u8, email) } } };
                return;
            },
        };

        // reload the page with the saved email and the password fields cleared
        self.session.haxy_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        try self.session.loadUser();
        try self.session.navigate(self.session.data.current_page);
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
    }

    fn formScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.box.children.values()[scroll_index].widget.scroll;
    }

    fn formBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.formScroll().child.center.child.box;
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

    // up leaves the view from the logout button
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }
};

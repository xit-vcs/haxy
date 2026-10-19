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

// the signup form every page's new user tab shows while logged out
pub const View = struct {
    center: ui.widget.Center,
    session: *ui.Session,

    // `route` is the page's own new-user route, which the web form posts to
    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, route: ui.RoutablePage) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = try session.page_arena.allocator().print("form:{s}", .{try route.toUrl(session.page_arena)}) };

        const saved_fields = if (session.formFeedback(.user)) |saved| saved.fields else null;

        {
            var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " name " }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            if (saved_fields) |saved| try name.setContent(allocator, saved.name);
            try box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            box.getFocus().child_id = name.getFocus().id;
        }

        {
            var email = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " email " }, .name = "email", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer email.deinit(allocator);
            email.getFocus().mode = .all;
            if (saved_fields) |saved| try email.setContent(allocator, saved.email);
            try box.children.put(allocator, email.getFocus().id, .{ .widget = .{ .text_input = email }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var password = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " password " }, .password = true, .name = "password", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer password.deinit(allocator);
            password.getFocus().mode = .all;
            try box.children.put(allocator, password.getFocus().id, .{ .widget = .{ .text_input = password }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var password_again = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " password again " }, .password = true, .name = "password_again", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer password_again.deinit(allocator);
            password_again.getFocus().mode = .all;
            try box.children.put(allocator, password_again.getFocus().id, .{ .widget = .{ .text_input = password_again }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var submit = try ui.widget.SubmitButton.initLabeled(allocator, "submit");
            errdefer submit.deinit(allocator);
            try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        return .{ .center = try ui.widget.Center.init(allocator, .{ .box = box }), .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const failure = if (self.session.formFeedback(.user)) |saved| saved.failure else null;
        (try formField(self.formBox(), "name")).options.top_label.text = if (failure) |value| switch (value) {
            .required_name => " name (required) ",
            .invalid_name => " name (invalid) ",
            .name_taken => " name (taken) ",
            else => " name ",
        } else " name ";
        (try formField(self.formBox(), "email")).options.top_label.text = if (failure) |value| switch (value) {
            .required_email => " email (required) ",
            .email_taken => " email (taken) ",
            else => " email ",
        } else " email ";
        (try formField(self.formBox(), "password")).options.top_label.text = if (failure == .required_password) " password (required) " else " password ";
        (try formField(self.formBox(), "password_again")).options.top_label.text = if (failure == .password_mismatch) " password again (doesn't match) " else " password again ";
        // the web form handling finds the inputs by focus id
        const inputs_arena = self.session.arena.allocator();
        for (self.formBox().children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
            else => {},
        };
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const cid = self.formBox().getFocus().child_id orelse return;
        const cur = self.formBox().children.getIndex(cid) orelse return;
        const child = &self.formBox().children.values()[cur];

        const on_submit = child.widget == .submit_button;
        const direction = inp.vertDirection(key);
        if (direction == .up or key == .back_tab) return if (cur > 0) root_focus.setFocus(self.formBox().children.keys()[cur - 1]);
        if (direction == .down or key == .tab) return if (cur + 1 < self.formBox().children.count()) root_focus.setFocus(self.formBox().children.keys()[cur + 1]);
        switch (key) {
            .enter => if (on_submit) return self.submitForm(allocator),
            .mouse => |mouse| if (on_submit) {
                if (inp.leftClickOn(root_focus, child.widget.submit_button.buttonId(), mouse)) return self.submitForm(allocator);
            },
            else => {},
        }
        try child.widget.input(allocator, key, root_focus);
    }

    fn formField(form: *wgt.Box(ui.Widget), name: []const u8) !*wgt.TextInput {
        for (form.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| if (std.mem.eql(u8, text_input.options.name, name)) return text_input,
            else => {},
        };
        return error.MissingFormField;
    }

    // create the user, log in, and navigate to their page. this is the
    // terminal path; the web posts the form to the new-user route.
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const admin_repo = self.session.admin_repo orelse return;

        const name_input = try formField(self.formBox(), "name");
        const email_input = try formField(self.formBox(), "email");
        const password_input = try formField(self.formBox(), "password");
        const password_again_input = try formField(self.formBox(), "password_again");
        const name = try name_input.text(allocator);
        defer allocator.free(name);
        const email = try email_input.text(allocator);
        defer allocator.free(email);
        const password = try password_input.text(allocator);
        defer allocator.free(password);
        const password_again = try password_again_input.text(allocator);
        defer allocator.free(password_again);

        const id = evt.createUser(io, allocator, users_dir, admin_repo, name, email, password, password_again) catch |err| {
            self.session.logServer("signup failed", "name=\"{f}\" error={s}", .{ std.zig.fmtString(name), @errorName(err) });
            const aa = self.session.arena.allocator();
            self.session.data.form_feedback = .{ .user = .{
                .failure = ui.Session.FormFeedback.UserFailure.fromError(err) orelse return err,
                .fields = .{ .name = try aa.dupe(u8, name), .email = try aa.dupe(u8, email) },
            } };
            return;
        };

        self.session.logServer("signup", "user={s}", .{name});

        // log in as the new user, reading them from a moment that has them
        self.session.data.user_id = try self.session.arena.allocator().dupe(u8, &id);
        try self.session.rememberSshKey();
        self.session.haxy_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        try self.session.loadUser();

        // wipe the form so a return visit starts fresh
        name_input.clear(allocator);
        email_input.clear(allocator);
        password_input.clear(allocator);
        password_again_input.clear(allocator);

        try self.session.navigate(.{ .user_repos = .{ .name = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong } });
    }

    fn formBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.center.child.box;
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

    // up leaves the form from its first control
    pub fn atTop(self: View) bool {
        const box = &self.center.child.box;
        return box.focus.child_id == box.children.keys()[0];
    }
};

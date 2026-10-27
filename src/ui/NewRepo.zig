const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// the new-repo form every page's new repo tab shows. the repo is created for
// the logged-in user.
pub const View = struct {
    center: ui.widget.Center,
    session: *ui.Session,

    // `route` is the page's own new-repo route, which the web form posts to
    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, route: ui.RoutablePage) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = try session.page_arena.allocator().print("form:{s}", .{try route.toUrl(session.page_arena)}) };

        const saved_fields = if (session.formFeedback(.repo)) |saved| saved.fields else null;

        {
            var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " name " }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            if (saved_fields) |saved| try name.setContent(allocator, saved.name);
            try box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            box.getFocus().child_id = name.getFocus().id;
        }

        {
            var description = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " description " }, .name = "description", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer description.deinit(allocator);
            description.getFocus().mode = .all;
            if (saved_fields) |saved| try description.setContent(allocator, saved.description);
            try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var access_radio = try ui.widget.Radio.init(allocator, session, "access", &.{ "private", "public" }, if (saved_fields) |saved| @tagName(saved.access) else "private", null);
            errdefer access_radio.deinit(allocator);
            try box.children.put(allocator, access_radio.getFocus().id, .{ .widget = .{ .radio = access_radio }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var hash_radio = try ui.widget.Radio.init(allocator, session, "hash", &.{ "sha1", "sha256" }, if (saved_fields) |saved| @tagName(saved.hash) else "sha1", null);
            errdefer hash_radio.deinit(allocator);
            try box.children.put(allocator, hash_radio.getFocus().id, .{ .widget = .{ .radio = hash_radio }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var copy = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " copy repo (optional) " }, .bottom_label = .{ .text = " put any `user:repo` here " }, .name = "copy", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer copy.deinit(allocator);
            copy.getFocus().mode = .all;
            if (saved_fields) |saved| try copy.setContent(allocator, saved.copy);
            try box.children.put(allocator, copy.getFocus().id, .{ .widget = .{ .text_input = copy }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
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
        const failure = if (self.session.formFeedback(.repo)) |saved| saved.failure else null;
        (try formField(self.formBox(), "name")).options.top_label.text = if (failure) |value| switch (value) {
            .required_name => " name (required) ",
            .invalid_name => " name (invalid) ",
            .name_taken => " name (taken) ",
            .invalid_copy => " name ",
        } else " name ";
        (try formField(self.formBox(), "copy")).options.top_label.text = if (failure == .invalid_copy) " copy repo (invalid) " else " copy repo (optional) ";
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

    fn formRadio(form: *wgt.Box(ui.Widget), name: []const u8) !*ui.widget.Radio {
        for (form.children.values()) |*child| switch (child.widget) {
            .radio => |*radio| if (std.mem.eql(u8, radio.name, name)) return radio,
            else => {},
        };
        return error.MissingFormField;
    }

    fn formField(form: *wgt.Box(ui.Widget), name: []const u8) !*wgt.TextInput {
        for (form.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| if (std.mem.eql(u8, text_input.options.name, name)) return text_input,
            else => {},
        };
        return error.MissingFormField;
    }

    // create the repo and navigate to it. this is the terminal path; the web
    // posts the form to the new-repo route.
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const admin_repo = self.session.admin_repo orelse return;
        const user_id = self.session.userId() orelse return;
        const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        const user = (try ui.activeUser(moment, self.session.page_arena, user_id)) orelse return;

        const name_input = try formField(self.formBox(), "name");
        const description_input = try formField(self.formBox(), "description");
        const copy_input = try formField(self.formBox(), "copy");
        const name = try name_input.text(allocator);
        defer allocator.free(name);
        const description = try description_input.text(allocator);
        defer allocator.free(description);
        const copy = try copy_input.text(allocator);
        defer allocator.free(copy);
        const hash_kind = std.meta.stringToEnum(hash.HashKind, (try formRadio(self.formBox(), "hash")).selected()) orelse unreachable;
        const access = std.meta.stringToEnum(evt.Repo.Access, (try formRadio(self.formBox(), "access")).selected()) orelse unreachable;

        _ = evt.createRepo(io, allocator, users_dir, &user_id, .{ .name = user.event.name, .email = user.event.email }, name, description, access, hash_kind, if (copy.len == 0) null else .{ .admin_moment = moment, .path = copy }) catch |err| {
            const failure = ui.Session.FormFeedback.RepoFailure.fromError(err) orelse return err;
            const aa = self.session.arena.allocator();
            self.session.data.form_feedback = .{ .repo = .{ .failure = failure, .fields = .{
                .name = try aa.dupe(u8, name),
                .description = try aa.dupe(u8, description),
                .hash = hash_kind,
                .access = access,
                .copy = try aa.dupe(u8, copy),
            } } };
            return;
        };

        // wipe the form so a return visit starts fresh
        name_input.clear(allocator);
        description_input.clear(allocator);
        copy_input.clear(allocator);

        const identity = try self.session.page_arena.allocator().print("{s}:{s}", .{ user.event.name, name });
        try self.session.navigate(ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0) orelse return);
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

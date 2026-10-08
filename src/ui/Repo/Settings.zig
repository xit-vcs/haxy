const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Roles = @import("./Roles.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

pub const tab_label = "☼";

// the repo's settings, which only its owner sees. the hash kind is fixed at
// creation, so it only shows.
identity: []const u8,
name: []const u8,
description: []const u8,
access: evt.Repo.Access,
discuss_role: ?evt.Repo.Role,
issue_role: ?evt.Repo.Role,
patch_role: ?evt.Repo.Role,
hash_kind: hash.HashKind,
// the sub tab the route names
view: enum { settings, roles },
roles: Roles,

const Self = @This();

// the tab role choices, in the order the form shows them
const role_choices = [_]?evt.Repo.Role{ null, .owner, .write, .read };

const role_labels = blk: {
    var labels: [role_choices.len][]const u8 = undefined;
    for (&labels, role_choices) |*label, role| label.* = roleLabel(role);
    break :blk labels;
};

pub fn roleLabel(role_maybe: ?evt.Repo.Role) []const u8 {
    const role = role_maybe orelse return "nobody";
    return switch (role) {
        .owner => "owners",
        .write => "collaborators",
        .read => "anybody",
    };
}

// the tab role a label names
pub fn labelRole(label: []const u8) error{InvalidRole}!?evt.Repo.Role {
    for (role_choices) |role| {
        if (std.mem.eql(u8, label, roleLabel(role))) return role;
    }
    return error.InvalidRole;
}

// the repo settings and user roles sub tabs over their content
pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index = 0;
    const content_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            const on_tab = switch (session.data.current_page) {
                .repo_settings, .repo_roles => true,
                else => false,
            };
            const routes = [_]?ui.RoutablePage{ ui.RoutablePage.repoSettingsRoute(data.identity), ui.RoutablePage.repoRolesRoute(data.identity, 0) };
            for ([_]@FieldType(Self, "view"){ .settings, .roles }, [_][]const u8{ "repo settings", "user roles" }, routes) |view, label, route| {
                var tab = try wgt.TextBox.init(allocator, label, .{ .border = .hidden, .round_corners = true, .wrap_kind = .none });
                errdefer tab.deinit(allocator);
                tab.getFocus().mode = .all;
                tab.getFocus().kind = .{ .custom = try ui.inPageTabLink(session, route orelse return error.RouteTooLong, on_tab and data.view == view) };
                try header.children.put(allocator, tab.getFocus().id, .{ .widget = .{ .text_box = tab }, .rect = null, .min_size = .{ .width = label.len + 2, .height = null } });
            }
            header.getFocus().child_id = header.children.keys()[@backingInt(data.view)];
            // a row taller than the header, leaving a blank line beneath it
            try box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);
            {
                var form = try Form.init(allocator, data, session);
                errdefer form.deinit(allocator);
                try stack.children.put(allocator, form.getFocus().id, .{ .repo_settings_form = form });
            }
            {
                var roles = try Roles.View.init(allocator, &data.roles, session);
                errdefer roles.deinit(allocator);
                try stack.children.put(allocator, roles.getFocus().id, .{ .repo_roles = roles });
            }
            stack.getFocus().child_id = stack.children.keys()[@backingInt(data.view)];
            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }
        box.getFocus().child_id = box.children.keys()[content_index];
        return .{ .box = box };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn headerBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[header_index].widget.box;
    }

    fn contentStack(self: *View) *wgt.Stack(ui.Widget) {
        return &self.box.children.values()[content_index].widget.stack;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.headerBox().getFocus().id;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = self.headerBox();
        if (header.getFocus().child_id) |selected_id| {
            for (header.children.keys(), header.children.values(), 0..) |id, *child, index| {
                ui.widget.markSelected(&child.widget.text_box, id == selected_id);
                if (id == selected_id) self.contentStack().getFocus().child_id = self.contentStack().children.keys()[index];
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            const header = self.headerBox();
            if (direction == .down) {
                root_focus.setFocus(self.contentStack().getFocus().id);
            } else if (header.children.getIndex(header.getFocus().child_id orelse return)) |current| {
                if (inp.moveTab(key, current, header.children.count())) |next| root_focus.setFocus(header.children.keys()[next]);
            }
            return;
        }
        if (direction == .up) if (self.contentStack().getSelected()) |selected| if (selected.atTop(root_focus)) {
            root_focus.setFocus(self.headerBox().getFocus().id);
            return;
        };
        try self.contentStack().input(allocator, key, root_focus);
    }

    // moving up from the sub header returns to the page's tabs
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        root_focus.setFocus(self.headerBox().getFocus().id);
        return true;
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

pub const Form = struct {
    // a centered form, scrolled when it outgrows the window
    scroll: wgt.Scroll(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !Form {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoSettingsRoute(data.identity) orelse return error.RouteTooLong;
        box.getFocus().kind = .{ .custom = try session.page_arena.allocator().print("form:{s}", .{try route.toUrl(session.page_arena)}) };

        const saved_fields = if (session.formFeedback(.repo_settings)) |saved| saved.fields else null;

        {
            var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " name " }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            try name.setContent(allocator, if (saved_fields) |saved| saved.name else data.name);
            // show the start of the prefilled text
            name.cursor = 0;
            try box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            box.getFocus().child_id = name.getFocus().id;
        }

        {
            var description = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " description " }, .name = "description", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer description.deinit(allocator);
            description.getFocus().mode = .all;
            try description.setContent(allocator, if (saved_fields) |saved| saved.description else data.description);
            // show the start of the prefilled text
            description.cursor = 0;
            try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            const access = if (saved_fields) |saved| saved.access else data.access;
            var access_radio = try ui.widget.Radio.init(allocator, session, "access", &.{ "private", "public" }, @tagName(access), null);
            errdefer access_radio.deinit(allocator);
            try box.children.put(allocator, access_radio.getFocus().id, .{ .widget = .{ .radio = access_radio }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var hash_box = try wgt.TextBox.init(allocator, @tagName(data.hash_kind), .{ .border = .single, .round_corners = true, .wrap_kind = .none, .top_label = .{ .text = " hash " } });
            errdefer hash_box.deinit(allocator);
            try box.children.put(allocator, hash_box.getFocus().id, .{ .widget = .{ .text_box = hash_box }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        const roles = [_]struct { name: []const u8, label: []const u8, role: ?evt.Repo.Role }{
            .{ .name = "discuss_role", .label = " new discussions can be made by ", .role = if (saved_fields) |saved| saved.discuss_role else data.discuss_role },
            .{ .name = "issue_role", .label = " new issues can be made by ", .role = if (saved_fields) |saved| saved.issue_role else data.issue_role },
            .{ .name = "patch_role", .label = " new patches can be made by ", .role = if (saved_fields) |saved| saved.patch_role else data.patch_role },
        };
        for (roles) |role| {
            var role_radio = try ui.widget.Radio.init(allocator, session, role.name, &role_labels, roleLabel(role.role), role.label);
            errdefer role_radio.deinit(allocator);
            try box.children.put(allocator, role_radio.getFocus().id, .{ .widget = .{ .radio = role_radio }, .rect = null, .min_size = null });
        }

        {
            var submit = try ui.widget.SubmitButton.initLabeled(allocator, "submit changes");
            errdefer submit.deinit(allocator);
            try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        var center = try ui.widget.Center.init(allocator, .{ .box = box });
        errdefer center.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
            .data = data,
            .session = session,
        };
    }

    pub fn deinit(self: *Form, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    pub fn build(self: *Form, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const failure = if (self.session.formFeedback(.repo_settings)) |saved| saved.failure else null;
        (try formField(self.formBox(), "name")).options.top_label.text = if (failure) |value| switch (value) {
            .required_name => " name (required) ",
            .invalid_name => " name (invalid) ",
            .name_taken => " name (taken) ",
        } else " name ";
        // the web form handling finds the inputs by focus id
        const inputs_arena = self.session.arena.allocator();
        for (self.formBox().children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
            else => {},
        };
        // the window's height as a minimum centers a form that fits
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *Form, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const cid = self.formBox().getFocus().child_id orelse return;
        const cur = self.formBox().children.getIndex(cid) orelse return;
        const child = &self.formBox().children.values()[cur];
        const keys = self.formBox().children.keys();

        const on_submit = child.widget == .submit_button;
        const direction = inp.vertDirection(key);
        const up = direction == .up or key == .back_tab;
        if (up or direction == .down or key == .tab) {
            var next = cur;
            while (true) {
                if (up) {
                    if (next == 0) return;
                    next -= 1;
                } else {
                    next += 1;
                    if (next == keys.len) return;
                }
                // the read-only hash row is stepped over
                if (self.formBox().children.values()[next].widget != .text_box) break;
            }
            root_focus.setFocus(keys[next]);
            if (self.session.is_terminal) if (self.formBox().children.values()[next].rect) |rect| ui.widget.scrollToCenteredRect(&self.scroll, rect);
            return;
        }
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

    // update the repo and navigate to its new url. this is the terminal path;
    // the web posts the form to the settings route.
    fn submitForm(self: *Form, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const actor = (try self.session.authorize(self.data.identity, .owner, null)) orelse return;

        const name = try (try formField(self.formBox(), "name")).text(allocator);
        defer allocator.free(name);
        const description = try (try formField(self.formBox(), "description")).text(allocator);
        defer allocator.free(description);
        const access = std.meta.stringToEnum(evt.Repo.Access, (try formRadio(self.formBox(), "access")).selected()) orelse unreachable;
        const discuss_role = labelRole((try formRadio(self.formBox(), "discuss_role")).selected()) catch unreachable;
        const issue_role = labelRole((try formRadio(self.formBox(), "issue_role")).selected()) catch unreachable;
        const patch_role = labelRole((try formRadio(self.formBox(), "patch_role")).selected()) catch unreachable;

        const route = update(io, allocator, users_dir, actor, self.data.identity, name, description, access, discuss_role, issue_role, patch_role) catch |err| {
            const failure = ui.Session.FormFeedback.RepoFailure.fromError(err) orelse return err;
            const aa = self.session.arena.allocator();
            self.session.data.form_feedback = .{ .repo_settings = .{ .failure = failure, .fields = .{
                .name = try aa.dupe(u8, name),
                .description = try aa.dupe(u8, description),
                .access = access,
                .discuss_role = discuss_role,
                .issue_role = issue_role,
                .patch_role = patch_role,
            } } };
            return;
        };
        try self.session.navigate(route);
    }

    fn formBox(self: *Form) *wgt.Box(ui.Widget) {
        return &self.scroll.child.center.child.box;
    }

    pub fn clearGrid(self: *Form) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: Form) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *Form) *Focus {
        return self.scroll.getFocus();
    }

    // up leaves the form from its first control
    pub fn atTop(self: Form) bool {
        const box = &self.scroll.child.center.child.box;
        return box.focus.child_id == box.children.keys()[0];
    }
};

// change the repo `identity` names as `actor`, its owner, returning its
// settings route under its new name
pub fn update(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    actor: ui.Actor,
    identity: []const u8,
    name: []const u8,
    description: []const u8,
    access: evt.Repo.Access,
    discuss_role: ?evt.Repo.Role,
    issue_role: ?evt.Repo.Role,
    patch_role: ?evt.Repo.Role,
) !ui.RoutablePage {
    const parsed = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const owner_id = actor.repo_user_id orelse return error.NotFound;
    try evt.updateRepo(io, allocator, users_dir, &owner_id, actor.author, parsed.name, name, description, access, discuss_role, issue_role, patch_role);
    var buf: [ui.RoutablePage.repo_route_max_len]u8 = undefined;
    const new_identity = std.fmt.bufPrint(&buf, "{s}:{s}", .{ parsed.owner, name }) catch return error.RouteTooLong;
    return ui.RoutablePage.repoSettingsRoute(new_identity) orelse error.RouteTooLong;
}

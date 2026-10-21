const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../event.zig");
const fork = @import("../fork.zig");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// what a delete tab permanently removes, shown only to its main owner
target: Target,

const Self = @This();

pub const Target = union(enum) {
    // "owner:name"
    repo: []const u8,
    fork: struct {
        // "forker:name", as the fork header shows it
        identity: []const u8,
        id: [evt.event_id_size * 2]u8,
    },
    // the user's name
    user: []const u8,

    // the text typed to confirm the delete
    pub fn confirmText(self: Target) []const u8 {
        return switch (self) {
            .repo, .user => |text| text,
            .fork => |f| f.identity,
        };
    }
};

// delete `target` as `user_id`, its main owner, when `typed` is its confirm
// text and `password` is theirs. returns why nothing was deleted, or null
// once deleted
pub fn perform(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    user_id: [evt.event_id_size]u8,
    target: Target,
    typed: []const u8,
    password: []const u8,
) !?ui.Session.FormFeedback.DeleteFailure {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user = (try ui.activeUser(try evt.currentMoment(evt.admin_repo_opts, admin_repo), &arena, user_id)) orelse return error.NotFound;

    // the typed text is checked before the slow password check
    if (!std.mem.eql(u8, typed, target.confirmText())) return .wrong_confirm;
    if (!evt.User.verifyPassword(user.event.password_hash, password)) return .wrong_password;

    // anyone but the main owner finds nothing to delete
    const author = evt.CommitAuthor{ .name = user.event.name, .email = user.event.email };
    switch (target) {
        .repo => |identity| {
            const parsed = evt.parseOwnerRepoPath(identity) orelse return error.NotFound;
            if (!std.mem.eql(u8, parsed.owner, user.event.name)) return error.NotFound;
            const repo_id = blk: {
                var user_repo = (try evt.openUserRepo(io, allocator, users_dir, &user_id)) orelse return error.NotFound;
                defer user_repo.deinit(io, allocator);
                const moment = (try evt.userMoment(&user_repo)) orelse return error.NotFound;
                const found = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, parsed.name)) orelse return error.NotFound;
                break :blk found.event_id;
            };
            try evt.deleteRepo(io, allocator, users_dir, &user_id, &repo_id, author);
        },
        .fork => |f| {
            const parsed = evt.parseOwnerRepoPath(f.identity) orelse return error.NotFound;
            if (!std.mem.eql(u8, parsed.owner, user.event.name)) return error.NotFound;
            const fork_id = evt.parseEventId(&f.id) catch return error.NotFound;
            const record = (try evt.readForkById(io, allocator, &arena, users_dir, &user_id, &fork_id)) orelse return error.NotFound;
            if (record.removed) return error.NotFound;
            try fork.remove(io, allocator, users_dir, &user_id, &f.id, author);
        },
        .user => |name| {
            if (!std.mem.eql(u8, name, user.event.name)) return error.NotFound;
            try evt.deleteUser(io, allocator, users_dir, admin_repo, &user_id, author);
        },
    }
    return null;
}

// the session's failed delete, when it was of `target`'s kind
fn savedFeedback(session: *const ui.Session, target: Target) ?@FieldType(ui.Session.FormFeedback, "delete") {
    const saved = session.formFeedback(.delete) orelse return null;
    return if (saved.target == std.meta.activeTag(target)) saved else null;
}

pub const View = struct {
    // the centered form, scrolled when it outgrows the window
    scroll: wgt.Scroll(ui.Widget),
    session: *ui.Session,
    target: Target,
    // the confirm input's label, plain and after a mismatch
    confirm_label: []const u8,
    mismatch_label: []const u8,
    // the form's controls in order: the confirm text, the password, then submit
    control_ids: [3]usize,

    // the form's children, in the same order as its controls
    const confirm_index = 0;
    const password_index = 1;
    const submit_index = 2;

    // `route` is the delete tab's route, which the form posts under
    pub fn init(allocator: std.mem.Allocator, data: Self, session: *ui.Session, route: ui.RoutablePage) !View {
        const aa = session.page_arena.allocator();
        const url = try route.toUrl(session.page_arena);
        const confirm_label = try aa.print(" type `{s}` here ", .{data.target.confirmText()});
        const mismatch_label = try aa.print(" type `{s}` here (doesn't match) ", .{data.target.confirmText()});
        // wide enough to show the whole label
        const visible_width = @max(30, mismatch_label.len);

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = try aa.print("form:{s}/delete", .{url}) };

        var control_ids: [3]usize = undefined;
        {
            var confirm = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = confirm_label }, .name = "confirm", .visible_width = visible_width, .round_corners = true, .render_content = session.is_terminal });
            errdefer confirm.deinit(allocator);
            confirm.getFocus().mode = .all;
            if (savedFeedback(session, data.target)) |saved| try confirm.setContent(allocator, saved.confirm);
            control_ids[confirm_index] = confirm.getFocus().id;
            try box.children.put(allocator, confirm.getFocus().id, .{ .widget = .{ .text_input = confirm }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }
        {
            var password = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " password " }, .password = true, .name = "password", .visible_width = visible_width, .round_corners = true, .render_content = session.is_terminal });
            errdefer password.deinit(allocator);
            password.getFocus().mode = .all;
            control_ids[password_index] = password.getFocus().id;
            try box.children.put(allocator, password.getFocus().id, .{ .widget = .{ .text_input = password }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }
        {
            var submit = try ui.widget.SubmitButton.initLabeled(allocator, try aa.print("permanently delete this {s}", .{@tagName(data.target)}));
            errdefer submit.deinit(allocator);
            submit.setBorder(.{ .kind = .single, .style = .{ .fg = .ansi(.red) } });
            control_ids[submit_index] = submit.buttonId();
            try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }
        box.getFocus().child_id = control_ids[confirm_index];

        var center = try ui.widget.Center.init(allocator, .{ .box = box });
        errdefer center.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
            .session = session,
            .target = data.target,
            .confirm_label = confirm_label,
            .mismatch_label = mismatch_label,
            .control_ids = control_ids,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    fn formBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.center.child.box;
    }

    fn textInput(self: *View, index: usize) *wgt.TextInput {
        return &self.formBox().children.values()[index].widget.text_input;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const failure = if (savedFeedback(self.session, self.target)) |saved| saved.failure else null;
        self.textInput(confirm_index).options.top_label.text = if (failure == .wrong_confirm) self.mismatch_label else self.confirm_label;
        self.textInput(password_index).options.top_label.text = if (failure == .wrong_password) " password (wrong) " else " password ";
        // the web form handling finds the inputs by focus id
        for ([_]usize{ confirm_index, password_index }) |index| {
            try self.session.text_inputs.put(self.session.arena.allocator(), self.control_ids[index], self.textInput(index));
        }
        // the window's height as a minimum centers a form that fits
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const focused = root_focus.grandchild_id orelse return;
        const cur = std.mem.indexOfScalar(usize, &self.control_ids, focused) orelse return;
        const submit_id = self.control_ids[submit_index];
        const on_submit = focused == submit_id;
        const direction = inp.vertDirection(key);
        const up = direction == .up or key == .back_tab;
        if (up or direction == .down or key == .tab) {
            // up from the first control is the sub header's, through `atTop`
            if (up and cur == 0) return;
            const next = if (up) cur - 1 else cur + 1;
            if (next == self.control_ids.len) return;
            root_focus.setFocus(self.control_ids[next]);
            if (self.session.is_terminal) if (self.formBox().children.values()[next].rect) |rect| ui.widget.scrollToCenteredRect(&self.scroll, rect);
            return;
        }
        switch (key) {
            .enter => if (on_submit) return self.submitForm(allocator),
            .mouse => |mouse| if (inp.leftClickOn(root_focus, submit_id, mouse)) return self.submitForm(allocator),
            else => {},
        }
        if (!on_submit) try self.textInput(cur).input(allocator, key, root_focus);
    }

    // delete the target. this is the terminal path; the web posts the form to
    // the delete route
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const admin_repo = self.session.admin_repo orelse return;
        const user_id = self.session.userId() orelse return;

        const confirm = try self.textInput(confirm_index).text(allocator);
        defer allocator.free(confirm);
        const password = try self.textInput(password_index).text(allocator);
        defer allocator.free(password);

        const failure = perform(io, allocator, users_dir, admin_repo, user_id, self.target, confirm, password) catch |err| switch (err) {
            // only the main owner is offered the form
            error.NotFound => return,
            else => return err,
        };
        if (failure) |value| {
            self.session.data.form_feedback = .{ .delete = .{ .failure = value, .target = std.meta.activeTag(self.target), .confirm = try self.session.arena.allocator().dupe(u8, confirm) } };
            return;
        }

        switch (self.target) {
            .repo, .fork => {
                const name = self.session.data.user_name orelse unreachable;
                try self.session.navigate(.{ .user_repos = .{ .name = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong } });
            },
            .user => {
                self.session.haxy_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
                try self.session.forgetSshKey();
                self.session.logOut();
                try self.session.navigate(.default);
            },
        }
    }

    pub fn clearGrid(self: *View) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.scroll.getFocus();
    }

    // up leaves the view from the first control
    pub fn atTop(self: *View, root_focus: *Focus) bool {
        return root_focus.grandchild_id == self.control_ids[confirm_index];
    }
};

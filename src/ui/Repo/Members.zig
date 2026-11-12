const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const Comment = @import("./Comment.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

pub const page_size = 20;

// the repo's members, which only its owners see
identity: []const u8,
start: usize,
next_start: ?usize = null,
rows: []const Row,
// the role change the route asks to confirm, which stands in for the list
confirm: ?Confirm = null,

const Self = @This();

pub const Confirm = struct { action: Action, name: []const u8 };

pub const Row = struct {
    name: []const u8,
    role: evt.Repo.Role,
};

pub const Action = enum { grant, revoke, promote, demote };

// one window of the repo's grants, newest first, without read grants, the
// creator or removed users
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    users_path: []const u8,
    identity: []const u8,
    owner_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    start: usize,
    confirm: ?Confirm,
) !Self {
    const aa = arena.allocator();
    const grants = try evt.readRepoGrants(io, allocator, arena, users_path, owner_id, repo_id);
    var rows: std.ArrayList(Row) = .empty;
    var skipped: usize = 0;
    var next_start: ?usize = null;
    for (grants) |grant| {
        // the creator owns the repo with or without a grant
        const user_id = try evt.parseEventId(&grant.user_id);
        if (grant.role == .read or std.mem.eql(u8, &user_id, owner_id)) continue;
        const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, arena, &user_id)) orelse continue;
        if (user.removed) continue;
        if (skipped < start) {
            skipped += 1;
            continue;
        }
        if (rows.items.len == page_size) {
            next_start = start + page_size;
            break;
        }
        try rows.append(aa, .{ .name = user.event.name, .role = grant.role });
    }
    return .{
        .identity = try aa.dupe(u8, identity),
        .start = start,
        .next_start = next_start,
        .rows = rows.items,
        .confirm = if (confirm) |value| .{ .action = value.action, .name = try aa.dupe(u8, value.name) } else null,
    };
}

// the confirmation of taking `name`'s role away
fn confirmRoute(identity: []const u8, start: usize, name: []const u8, action: Action) !ui.RoutablePage {
    var route = ui.RoutablePage.repoMembersRoute(identity, start) orelse return error.RouteTooLong;
    route.repo_members.user = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    route.repo_members.confirm = action;
    return route;
}

// act on `name`'s role in the repo `identity` names as `actor`, one of its
// owners. returns why an add wrote nothing, or null once written
pub fn perform(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    users_path: []const u8,
    actor: ui.Actor,
    identity: []const u8,
    action: Action,
    name: []const u8,
) !?ui.Session.FormFeedback.MembersFailure {
    const owner_id = actor.repo_user_id orelse return error.NotFound;
    const parsed = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const user_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, name)) orelse
        return if (action == .grant) .not_found else error.EventNotFound;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const repo_id, const role = blk: {
        var user_repo = (try evt.openUserRepo(io, allocator, users_path, &owner_id)) orelse return error.NotFound;
        defer user_repo.deinit(io, allocator);
        const moment = (try evt.userMoment(&user_repo)) orelse return error.NotFound;
        const found = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, parsed.name)) orelse return error.NotFound;
        break :blk .{ found.event_id, try evt.Grant.readRole(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, &found.event_id, &user_id) };
    };

    switch (action) {
        // a reader becomes a member; anyone else with a role, and the
        // creator, who holds no grant, is already added
        .grant => {
            const already_added = if (role) |held| held != .read else std.mem.eql(u8, &user_id, &owner_id);
            if (already_added) return .already_added;
            try evt.grantRole(io, allocator, users_path, &owner_id, &repo_id, &user_id, .write, actor.author);
        },
        .revoke => try evt.revokeRole(io, allocator, users_path, &owner_id, &repo_id, &user_id, actor.author),
        // only a listed grant changes role
        .promote, .demote => {
            if (role == null) return error.EventNotFound;
            try evt.grantRole(io, allocator, users_path, &owner_id, &repo_id, &user_id, if (action == .promote) .owner else .write, actor.author);
        },
    }
    return null;
}

// where an action lands: the same window of the list, or the files tab once
// the actor gave up their own owner role
pub fn landingRoute(identity: []const u8, start: usize, actor: ui.Actor, action: Action, name: []const u8) ?ui.RoutablePage {
    const lost_ownership = (action == .revoke or action == .demote) and std.mem.eql(u8, name, actor.author.name);
    if (lost_ownership) return ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0);
    return ui.RoutablePage.repoMembersRoute(identity, start);
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const about_index = 0;
    const add_index = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const aa = session.page_arena.allocator();
        if (data.confirm) |confirm| {
            const url = try (try confirmRoute(data.identity, data.start, confirm.name, confirm.action)).toUrl(session.page_arena);
            var center = try ui.widget.initConfirmationForm(allocator, try aa.print("form:{s}", .{url}), &.{.{
                .label = if (confirm.action == .demote) "demote to member" else "remove user",
                .bottom_label = try aa.print(" {s} ", .{confirm.name}),
            }});
            errdefer center.deinit(allocator);
            return .{
                .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
                .data = data,
                .session = session,
            };
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoMembersRoute(data.identity, data.start) orelse return error.RouteTooLong;
        const url = try route.toUrl(session.page_arena);

        {
            var about = try ui.widget.initAbout(allocator, &.{
                .{ .text = "members", .style = .{ .bold = true } },
                .{ .text = " can push to this repo.\n" },
                .{ .text = "owners", .style = .{ .bold = true } },
                .{ .text = " can add and remove members." },
            });
            errdefer about.deinit(allocator);
            try box.children.put(allocator, about.getFocus().id, .{ .widget = .{ .box = about }, .rect = null, .min_size = null });
        }
        {
            var add = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer add.deinit(allocator);
            add.getFocus().kind = .{ .custom = try aa.print("form:{s}/grant", .{url}) };
            var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " add a member " }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            if (session.formFeedback(.repo_members)) |saved| try name.setContent(allocator, saved.name);
            add.getFocus().child_id = name.getFocus().id;
            try add.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            try box.children.put(allocator, add.getFocus().id, .{ .widget = .{ .box = add }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        // the user rows follow the add row in the same box
        if (data.start > 0) {
            var previous = try Comment.linkBox(allocator, session, "← previous", ui.RoutablePage.repoMembersRoute(data.identity, data.start -| page_size) orelse return error.RouteTooLong);
            errdefer previous.deinit(allocator);
            try box.children.put(allocator, previous.getFocus().id, .{ .widget = .{ .text_box = previous }, .rect = null, .min_size = null });
        }
        for (data.rows) |row| {
            var row_route = route;
            row_route.repo_members.user = ui.RoutablePage.Array(evt.User.name_max_len).from(row.name) orelse return error.RouteTooLong;
            const row_url = try row_route.toUrl(session.page_arena);

            var row_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer row_box.deinit(allocator);
            row_box.getFocus().kind = .{ .custom = try aa.print("form:{s}", .{row_url}) };
            {
                const user_route = ui.RoutablePage{ .user_repos = .{ .name = ui.RoutablePage.Array(evt.User.name_max_len).from(row.name) orelse return error.RouteTooLong } };
                var name = try Comment.linkBox(allocator, session, row.name, user_route);
                errdefer name.deinit(allocator);
                name.options.bottom_label.text = if (row.role == .owner) " owner " else " member ";
                try row_box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_box = name }, .rect = null, .min_size = null });
            }
            // taking a role away asks first
            if (row.role == .owner) {
                const demote_route = try confirmRoute(data.identity, data.start, row.name, .demote);
                try addButton(allocator, &row_box, "demote to member", try aa.print("a:{s}", .{try demote_route.toUrl(session.page_arena)}));
            } else try addButton(allocator, &row_box, "promote to owner", try aa.print("submit:{s}/promote", .{row_url}));
            {
                const revoke_route = try confirmRoute(data.identity, data.start, row.name, .revoke);
                var remove = try wgt.TextBox.init(allocator, "✕", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer remove.deinit(allocator);
                remove.getFocus().mode = .all;
                remove.getFocus().kind = .{ .custom = try aa.print("a:{s}", .{try revoke_route.toUrl(session.page_arena)}) };
                try row_box.children.put(allocator, remove.getFocus().id, .{ .widget = .{ .text_box = remove }, .rect = null, .min_size = .{ .width = 3, .height = null } });
            }
            row_box.getFocus().child_id = row_box.children.keys()[0];
            try box.children.put(allocator, row_box.getFocus().id, .{ .widget = .{ .box = row_box }, .rect = null, .min_size = null });
        }
        if (data.next_start) |next_start| {
            var next = try Comment.linkBox(allocator, session, "next →", ui.RoutablePage.repoMembersRoute(data.identity, next_start) orelse return error.RouteTooLong);
            errdefer next.deinit(allocator);
            try box.children.put(allocator, next.getFocus().id, .{ .widget = .{ .text_box = next }, .rect = null, .min_size = null });
        }

        box.getFocus().child_id = box.children.keys()[about_index];
        var center = try ui.widget.Center.init(allocator, .{ .box = box });
        errdefer center.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
            .data = data,
            .session = session,
        };
    }

    fn addButton(allocator: std.mem.Allocator, row: *wgt.Box(ui.Widget), text: []const u8, kind: []const u8) !void {
        var button = try wgt.TextBox.init(allocator, text, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
        errdefer button.deinit(allocator);
        button.getFocus().mode = .all;
        button.getFocus().kind = .{ .custom = kind };
        try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.center.child.box;
    }

    fn addBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[add_index].widget.box;
    }

    fn nameInput(self: *View) *wgt.TextInput {
        return &self.addBox().children.values()[0].widget.text_input;
    }

    fn addActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.addBox().getFocus().id;
    }

    fn aboutBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[about_index].widget.box;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        if (self.data.confirm == null) {
            try self.labelAddInput(root_focus);
            ui.widget.markAboutFocused(self.aboutBox(), root_focus);
        }
        // the window's height as a minimum centers rows that fit
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    // label the add input for this frame and register it for the web form
    // handling
    fn labelAddInput(self: *View, root_focus: *Focus) !void {
        const name = self.nameInput();
        const failure = if (self.session.formFeedback(.repo_members)) |saved| saved.failure else null;
        name.options.top_label.text = if (failure) |value| switch (value) {
            .not_found => " add a member (not found) ",
            .already_added => " add a member (already added) ",
        } else " add a member ";
        name.options.bottom_label.text = if (root_focus.grandchild_id == name.getFocus().id) " press enter " else "";
        try self.session.text_inputs.put(self.session.arena.allocator(), name.getFocus().id, name);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (self.data.confirm) |confirm| {
            const button_id = self.contentBox().getFocus().child_id orelse return;
            if (inp.activated(root_focus, button_id, key)) try self.act(allocator, confirm.action, confirm.name);
            return;
        }
        // the add row keeps every key but the vertical ones, which move between rows
        if (self.addActive() and inp.vertDirection(key) == .none) {
            if (key == .enter) {
                const name = try self.nameInput().text(allocator);
                defer allocator.free(name);
                try self.act(allocator, .grant, name);
            } else try self.nameInput().input(allocator, key, root_focus);
            return;
        }

        const rows = self.contentBox();
        const current = rows.children.getIndex(rows.getFocus().child_id orelse return) orelse return;
        if (inp.rowDelta(key, @intCast(rows.children.count()))) |delta| {
            ui.widget.moveRowFocus(rows, &self.scroll, root_focus, delta);
            return;
        }
        switch (key) {
            .arrow_left, .arrow_right => _ = ui.widget.moveInSelectedRow(rows, root_focus, key == .arrow_right),
            else => {
                // the text, the add row and the previous link, when there is one, sit above the rows
                const offset: usize = add_index + 1 + @as(usize, @intFromBool(self.data.start > 0));
                if (current < offset or current - offset >= self.data.rows.len) return;
                const row = self.data.rows[current - offset];
                const row_box = &rows.children.values()[current].widget.box;
                // remove and demote are links to their confirmations, which the host follows
                if (row.role == .owner) return;
                const button_id = row_box.getFocus().child_id orelse return;
                if (row_box.children.getIndex(button_id) != 1 or !inp.activated(root_focus, button_id, key)) return;
                try self.act(allocator, .promote, row.name);
            },
        }
    }

    // the terminal performs the action itself; the web posts the form instead
    fn act(self: *View, allocator: std.mem.Allocator, action: Action, name: []const u8) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_path = self.session.users_path orelse return;
        const admin_repo = self.session.admin_repo orelse return;
        const actor = (try self.session.authorize(self.data.identity, .owner, null)) orelse return;
        const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        const failure = perform(io, allocator, moment, users_path, actor, self.data.identity, action, name) catch |err| switch (err) {
            // a stale row; the refresh below shows the list as it is
            error.EventNotFound => null,
            else => return err,
        };
        if (failure) |value| {
            self.session.data.form_feedback = .{ .repo_members = .{ .failure = value, .name = try self.session.arena.allocator().dupe(u8, name) } };
            return;
        }
        try self.session.navigate(landingRoute(self.data.identity, self.data.start, actor, action, name) orelse return error.RouteTooLong);
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

    // up leaves the view from the explanatory text or the confirmation
    pub fn atTop(self: *View) bool {
        return self.data.confirm != null or self.contentBox().getFocus().child_id == self.aboutBox().getFocus().id;
    }
};

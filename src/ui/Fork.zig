const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const fork = @import("../fork.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");

pub const Header = @import("./Fork/Header.zig");
pub const Files = @import("./Repo/Files.zig");
pub const Commits = @import("./Repo/Commits.zig");
pub const Patches = @import("./Repo/Patches.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
files: Files,
commits: Commits,
patch: Patches,
settings: Settings,
auth: Auth,
quit: Quit,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session, route: ui.RoutablePage) !Self {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;
    const route_fork = route.forkRoute() orelse return error.UnexpectedRoute;
    const identity = ui.RoutablePage.RepoIdentity.parse(route_fork.name.slice()) orelse return error.NotFound;
    const id = evt.parseEventId(route_fork.id.slice()) catch return error.NotFound;
    const fork_record = (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, arena, &id)) orelse return error.NotFound;
    if (fork_record.removed) return error.NotFound;
    if (fork_record.event.repo_id.len != evt.event_id_size) return error.NotFound;
    var target_id: [evt.event_id_size]u8 = undefined;
    @memcpy(&target_id, fork_record.event.repo_id);

    const target_record = (try evt.Repo.readById(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, arena, fork_record.event.repo_id)) orelse return error.NotFound;
    const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, arena, target_record.event.user_id)) orelse return error.NotFound;
    if (!std.mem.eql(u8, owner.event.name, identity.owner) or !std.mem.eql(u8, target_record.event.name, identity.name)) return error.NotFound;

    const aa = arena.allocator();
    const id_hex = std.fmt.bytesToHex(id, .lower);
    const fork_path = try fork.forkPath(aa, repos_dir, &id_hex);
    var fork_repo = try rp.Repo(.xit, .{}).open(io, arena.child_allocator, .{ .path = fork_path, .require_repo_root = true });
    defer fork_repo.deinit(io, arena.child_allocator);
    const fork_moment = try evt.currentMoment(.{}, &fork_repo);
    const retained_patch = (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, fork_moment, arena, &id)) orelse return error.NotFound;
    const fork_oid = (try fork_repo.readRef(io, fork.ref)) orelse return error.NotFound;
    var commits_base_oid = fork_oid;
    if (try evt.PatchRev.readNewest(evt.EventDB(.sha1), .sha1, fork_moment, arena)) |revision| {
        if (revision.record.event.base_oid.len != commits_base_oid.len) return error.NotFound;
        @memcpy(&commits_base_oid, revision.record.event.base_oid);
    }

    const target_id_hex = std.fmt.bytesToHex(target_id, .lower);
    const target_path = try std.fs.path.join(aa, &.{ repos_dir, &target_id_hex });
    const target_source = ui.RepoSource{ .path = target_path, .repo_kind = .xit };
    var target_repo_maybe: ?rp.Repo(.xit, .{}) = if (!target_record.removed)
        rp.Repo(.xit, .{}).open(io, arena.child_allocator, target_source.localInitOpts()) catch null
    else
        null;
    defer if (target_repo_maybe) |*target_repo| target_repo.deinit(io, arena.child_allocator);

    var target_branch = if (retained_patch.event.revision) |revision| revision.targetBranch() orelse "" else "";
    if (target_repo_maybe) |*target_repo| {
        if (target_branch.len == 0) {
            if (try ui.ResolvedRefOrOid(.xit, .{}).init(target_repo, io, aa, null, "")) |resolved|
                target_branch = resolved.value;
        }
    }

    const retained_entry = Patches.PatchWithId{
        .id = try aa.dupe(u8, &id_hex),
        .record = retained_patch,
        .author = try ui.Author.initFromEmail(haxy_moment, arena, retained_patch.author_email),
        .draft = fork_record.event.stage == .draft,
        .fork_oid = try aa.dupe(u8, &fork_oid),
        .target_branch = try aa.dupe(u8, target_branch),
        .fork_exists = true,
    };
    var patch_data = try Patches.detailResult(aa, identity.identity, retained_entry);

    if (target_repo_maybe) |*target_repo| switch (fork_record.event.stage) {
        .draft => if (try Patches.loadDraftEntry(.xit, .{}, arena, io, haxy_moment, &fork_repo, target_repo, id, target_branch)) |entry| {
            patch_data = try Patches.detailResult(aa, identity.identity, entry);
            patch_data.repo_source = target_source;
        },
        .publish => {
            patch_data = Patches.init(.xit, .{}, arena, target_repo, io, haxy_moment, session, target_id, identity.identity, target_branch, "", &id_hex, "", 0, "", .open) catch |err| switch (err) {
                error.NotFound => patch_data,
                else => |other| return other,
            };
            if (patch_data.selectedThread()) |entry| {
                patch_data.repo_source = target_source;
                if (entry.record.event.revision) |revision| {
                    if (revision.targetBranch()) |branch| target_branch = branch;
                }
            }
        },
    };
    patch_data.repo_id = target_id;

    const requested_ref: ?ui.RoutablePage.RefOrOid = switch (route) {
        .fork_files => |f| if (f.oid.len == 0) null else .object,
        .fork_commits => |c| if (c.oid.len == 0) null else .object,
        else => null,
    };
    const requested_value: []const u8 = switch (route) {
        .fork_files => |*f| f.oid.slice(),
        .fork_commits => |*c| c.oid.slice(),
        else => "",
    };
    const files_path: []const u8 = switch (route) {
        .fork_files => |*f| f.path.slice(),
        else => "",
    };
    const files_line: usize = switch (route) {
        .fork_files => |f| f.line,
        else => 0,
    };
    const commits_content: ui.RoutablePage.RepoCommitsRoute.Content = switch (route) {
        .fork_commits => |c| c.content,
        else => .{ .diff = .{} },
    };
    const location = ui.RoutablePage.RepoLocation{ .fork = .{
        .identity = identity.identity,
        .id = &id_hex,
        .target_branch = target_branch,
    } };
    const files = try Files.init(.xit, .{}, arena, &fork_repo, io, arena.child_allocator, location, requested_ref, requested_value, files_path, files_line);
    const commits = try Commits.init(.xit, .{}, arena, &fork_repo, io, arena.child_allocator, haxy_moment, location, requested_ref, requested_value, commits_content, commits_base_oid);

    return .{
        .header = try Header.init(arena, target_record.event.name, owner.event.name, &id_hex, requested_value),
        .files = files,
        .commits = commits,
        .patch = patch_data,
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        {
            var header = try Header.View.init(allocator, &data.header, session);
            errdefer header.deinit(allocator);
            try box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .fork_header = header }, .rect = null, .min_size = null });
        }
        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);
            const selected = data.patch.selectedThread() orelse return error.NotFound;
            var patch_detail = try Patches.Detail.init(allocator, &data.patch, session, selected.*, .{ .actions = data.patch.repo_source != null });
            errdefer patch_detail.deinit(allocator);
            try stack.children.put(allocator, patch_detail.getFocus().id, .{ .repo_patch_detail = patch_detail });
            {
                var files = try Files.View.init(allocator, &data.files, session);
                errdefer files.deinit(allocator);
                try stack.children.put(allocator, files.getFocus().id, .{ .repo_files = files });
            }
            {
                var commits = try Commits.View.init(allocator, &data.commits, session);
                errdefer commits.deinit(allocator);
                try stack.children.put(allocator, commits.getFocus().id, .{ .repo_commits = commits });
            }
            if (session.data.user_id != null) {
                var settings = try Settings.View.init(allocator, session);
                errdefer settings.deinit(allocator);
                try stack.children.put(allocator, settings.getFocus().id, .{ .home_settings = settings });
            }
            if (!session.data.is_local) {
                var auth = try Auth.View.init(allocator, &data.auth, session);
                errdefer auth.deinit(allocator);
                try stack.children.put(allocator, auth.getFocus().id, .{ .home_auth = auth });
            }
            if (session.is_terminal) {
                var quit = try Quit.View.init(allocator, session);
                errdefer quit.deinit(allocator);
                try stack.children.put(allocator, quit.getFocus().id, .{ .quit = quit });
            }
            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }
        box.getFocus().child_id = box.children.keys()[header_index];
        return .{ .box = box };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.fork_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;
        if (header.getSelectedIndex()) |index| stack.getFocus().child_id = stack.children.keys()[index];
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const stack = &self.box.children.values()[stack_index].widget.stack;
        const current_id = self.box.getFocus().child_id orelse return;
        const current_index = self.box.children.getIndex(current_id) orelse return;
        const child = &self.box.children.values()[current_index].widget;
        var next_index = current_index;
        switch (inp.vertDirection(key)) {
            .up => switch (child.*) {
                .fork_header => try child.input(allocator, key, root_focus),
                .stack => if (stack.getSelected()) |selected| {
                    const at_top = switch (selected.*) {
                        .repo_patch_detail => |*view| view.atTop(root_focus),
                        .repo_files => |*view| view.getSelectedIndex() == 0,
                        .repo_commits => |*view| view.getSelectedIndex() == 0,
                        .home_settings => |*view| view.getSelectedIndex() == 0,
                        .home_auth => |*view| view.getSelectedIndex() == 0,
                        .quit => |*view| view.getSelectedIndex() == 0,
                        else => false,
                    };
                    if (at_top) next_index = header_index else try child.input(allocator, key, root_focus);
                },
                else => {},
            },
            .down => switch (child.*) {
                .fork_header => {
                    if (stack.getSelected()) |selected| switch (selected.*) {
                        .repo_patch_detail => |*view| if (view.focusFirst(root_focus)) return,
                        .repo_files => |*view| if (view.focusCloneUrl(root_focus)) return,
                        .repo_commits => |*view| if (view.focusCloneUrl(root_focus)) return,
                        else => {},
                    };
                    next_index = stack_index;
                },
                .stack => try child.input(allocator, key, root_focus),
                else => {},
            },
            .none => try child.input(allocator, key, root_focus),
        }
        if (next_index != current_index) root_focus.setFocus(self.box.children.keys()[next_index]);
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

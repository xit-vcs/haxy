const std = @import("std");
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");

pub const Header = @import("./Repo/Header.zig");
pub const Files = @import("./Repo/Files.zig");
pub const Markdown = @import("./Repo/Markdown.zig");
pub const Commits = @import("./Repo/Commits.zig");
pub const Diff = @import("./Repo/Diff.zig");
pub const Refs = @import("./Repo/Refs.zig");
pub const Issues = @import("./Repo/Issues.zig");
pub const Patches = @import("./Repo/Patches.zig");
pub const Discussions = @import("./Repo/Discussions.zig");
pub const Comment = @import("./Repo/Comment.zig");
pub const Undo = @import("./Repo/Undo.zig");
pub const Events = @import("./Repo/Events.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
repo: evt.Repo.Record,
files: Files,
changes: Changes,
refs: Refs,
issues: Issues,
patches: Patches,
discussions: Discussions,
events: Events,
undo: ?Undo = null,
settings: Settings,
auth: Auth,
quit: Quit,

const Self = @This();

const Changes = union(enum) {
    commits: Commits,
    diff: Diff,
};

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    route: ui.RoutablePage,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    // every repo route stores its identity as "owner/name" (or elides it in local mode)
    const name_str = route.repoIdentity() orelse return error.UnexpectedRoute;
    const repo_identity = ui.RoutablePage.RepoIdentity.parse(name_str) orelse return error.NotFound;
    const location = ui.RoutablePage.RepoLocation{ .repo = repo_identity.identity };
    // files, commits and diff share the requested ref, or the default branch.
    // directories and hunk windows only apply to their own tab.
    const requested_ref_or_oid: ?ui.RoutablePage.RefOrOid = switch (route) {
        .repo_files => |f| f.ref_kind,
        .repo_commits => |c| c.ref_or_oid,
        .repo_diff => |d| d.ref_or_oid,
        else => null,
    };
    const requested_ref_value: []const u8 = switch (route) {
        .repo_files => |*f| f.ref_value.slice(),
        .repo_commits => |*c| c.value.slice(),
        .repo_diff => |*d| d.value.slice(),
        else => "",
    };
    const patchrev_id: []const u8 = switch (route) {
        .repo_files => |*f| f.patchrev_id.slice(),
        .repo_diff => |*d| d.patchrev_id.slice(),
        else => "",
    };
    const files_dir = switch (route) {
        .repo_files => |*f| f.path.slice(),
        else => "",
    };
    const files_line = switch (route) {
        .repo_files => |f| f.line,
        else => 0,
    };
    const files_find: []const u8 = switch (route) {
        .repo_files => |*f| f.find.slice(),
        else => "",
    };
    // what the commits view's pane shows for the commit it walks from: a diff
    // window (with the file it's filtered to) or that commit's message.
    const commits_content: ui.RoutablePage.RepoCommitsRoute.Content = switch (route) {
        .repo_commits => |c| c.content,
        else => .{ .diff = .{} },
    };
    const commits_base_oid: []const u8 = switch (route) {
        .repo_commits => |*c| c.base_oid.slice(),
        else => "",
    };
    const commits_search: []const u8 = switch (route) {
        .repo_commits => |*c| c.search.slice(),
        else => "",
    };
    const commits_from: []const u8 = switch (route) {
        .repo_commits => |*c| c.from.slice(),
        else => "",
    };
    const commits_merge: []const u8 = switch (route) {
        .repo_commits => |*c| c.merge.slice(),
        else => "",
    };
    // the refs tab windows one column at a time: `refs_from` (a url-encoded
    // ref name) roots `refs_kind`'s column, the other stays at its first window.
    const refs_kind: ui.RoutablePage.RefKind = switch (route) {
        .repo_refs => |r| r.kind,
        else => .branch,
    };
    const refs_from: []const u8 = switch (route) {
        .repo_refs => |*r| r.from.slice(),
        else => "",
    };
    const refs_search: []const u8 = switch (route) {
        .repo_refs => |*r| r.search.slice(),
        else => "",
    };
    // the issues tab's label filter, the issue its window is rooted at, and the
    // view it shows.
    const issues_label: []const u8 = switch (route) {
        .repo_issues => |*i| i.label.slice(),
        else => "",
    };
    const issues_search: []const u8 = switch (route) {
        .repo_issues => |*i| i.search.slice(),
        else => "",
    };
    const issues_selected: []const u8 = switch (route) {
        .repo_issues => |*i| i.selected.slice(),
        else => "",
    };
    const issues_comment: []const u8 = switch (route) {
        .repo_issues => |*i| i.comment.slice(),
        else => "",
    };
    const issues_theirs: []const u8 = switch (route) {
        .repo_issues => |*i| i.theirs.slice(),
        else => "",
    };
    const issues_view: ui.RoutablePage.IssuesView = switch (route) {
        .repo_issues => |i| i.view,
        else => .open,
    };
    const issues_comments_start: usize = switch (route) {
        .repo_issues => |i| i.comments_start,
        else => 0,
    };
    const patches_label: []const u8 = switch (route) {
        .repo_patches => |*p| p.label.slice(),
        else => "",
    };
    const patches_search: []const u8 = switch (route) {
        .repo_patches => |*p| p.search.slice(),
        else => "",
    };
    const patches_selected: []const u8 = switch (route) {
        .repo_patches => |*p| p.selected.slice(),
        else => "",
    };
    const patches_comment: []const u8 = switch (route) {
        .repo_patches => |*p| p.comment.slice(),
        else => "",
    };
    const patches_theirs: []const u8 = switch (route) {
        .repo_patches => |*p| p.theirs.slice(),
        else => "",
    };
    const patches_view: ui.RoutablePage.PatchesView = switch (route) {
        .repo_patches => |p| p.view,
        else => .open,
    };
    const patches_comments_start: usize = switch (route) {
        .repo_patches => |p| p.comments_start,
        else => 0,
    };
    const discussions_label: []const u8 = switch (route) {
        .repo_discussions => |*t| t.label.slice(),
        else => "",
    };
    const discussions_search: []const u8 = switch (route) {
        .repo_discussions => |*t| t.search.slice(),
        else => "",
    };
    const discussions_selected: []const u8 = switch (route) {
        .repo_discussions => |*t| t.selected.slice(),
        else => "",
    };
    const discussions_comment: []const u8 = switch (route) {
        .repo_discussions => |*t| t.comment.slice(),
        else => "",
    };
    const discussions_view: ui.RoutablePage.DiscussionsView = switch (route) {
        .repo_discussions => |t| t.view,
        else => .recent,
    };
    const discussions_comments_start: usize = switch (route) {
        .repo_discussions => |t| t.comments_start,
        else => 0,
    };
    const events_kind: ?evt.EventKind = switch (route) {
        .repo_events => |e| e.kind,
        else => null,
    };
    const events_view: ui.RoutablePage.EventsView = switch (route) {
        .repo_events => |e| e.view,
        else => .active,
    };
    const events_moment: ?u64 = switch (route) {
        .repo_events => |e| e.moment,
        else => null,
    };
    const events_selected: []const u8 = switch (route) {
        .repo_events => |*e| e.selected.slice(),
        else => "",
    };

    // where the on-disk repo lives (null keeps the views' empty fallback), plus
    // the repo and owner-name metadata the header shows. local mode already
    // knows all three; the server paths resolve them from the admin db.
    var source: ?ui.RepoSource = null;
    var repo_id_maybe: ?[evt.event_id_size]u8 = null;
    var repo: evt.Repo.Record = undefined;
    var owner_name: []const u8 = undefined;
    if (session.local) |local| {
        source = local;
        // local routes elide the identity, so the display name comes from the
        // repo's directory rather than the route.
        repo = .{ .event = .{
            .user_id = "",
            .name = try arena.allocator().dupe(u8, std.fs.path.basename(local.path)),
            .description = "",
        } };
        owner_name = "";
    } else {
        const haxy_moment = session.haxy_moment orelse return error.NoMoment;
        const found = (try evt.Repo.readByOwnerAndName(DB, hash_kind, haxy_moment, arena, repo_identity.owner, repo_identity.name)) orelse return error.NotFound;
        // a repo the session can't read doesn't exist to it
        if (evt.Repo.roleOf(found.repo, session.userId()) == .none) return error.NotFound;
        repo = found.repo;
        repo_id_maybe = found.event_id;

        // resolve the creating user so the header can show their name to the left
        // of the repo title.
        const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, repo.event.user_id)) orelse return error.NotFound;
        owner_name = owner.event.name;

        // the repo's working copy lives at <repos_dir>/<hex event id>.
        if (session.repos_dir) |repos_dir| {
            const hex = std.fmt.bytesToHex(found.event_id, .lower);
            source = .{
                .path = try std.fs.path.join(arena.allocator(), &.{ repos_dir, &hex }),
                .repo_kind = .xit,
            };
        }
    }

    // open the repo once for every tab. files and changes share a ref or revision.
    // no filesystem (wasm), nowhere to look, or a failed open: empty tabs.
    const undo_allowed = if (session.local) |local| local.repo_kind == .xit else session.userId() != null and evt.Repo.roleOf(repo, session.userId()).atLeast(.write);
    if (route == .repo_undo and !undo_allowed) return error.NotFound;
    // a server shows events to whoever it shows undo to, so the route follows
    if (route == .repo_events and session.data.host_kind != .local and !undo_allowed) return error.NotFound;
    const undo_index = if (route == .repo_undo) route.repo_undo.index else null;
    const undo_clear = route == .repo_undo and route.repo_undo.clear;
    // an unreadable repo still shows the tab, like every other tab
    var undo_data: ?Undo = if (undo_allowed) .{ .identity = repo_identity.identity } else null;
    const files, const changes, const refs, var issues, var patches, var discussions, const events = blk: {
        read: {
            const io = session.io orelse break :read;
            const src = source orelse break :read;
            const gpa = arena.child_allocator;
            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = rp.AnyRepo(repo_kind, .{}).open(io, gpa, src.localInitOpts()) catch break :read;
                    defer any_repo.deinit(io, gpa);
                    switch (any_repo) {
                        inline else => |*opened| {
                            // local mode: bring the event db up to date with the events branch
                            if (session.local != null) {
                                try evt.consume(.local, .repo, repo_kind, opened.self_repo_opts, io, gpa, opened, evt.events_ref, &.{});
                                try pch.refreshBranches(.local, repo_kind, opened.self_repo_opts, io, gpa, opened, null, null);
                            }
                            // tabs switch in-page, so every tab's data is read here
                            if (repo_kind == .xit and undo_allowed) {
                                undo_data = Undo.init(opened.self_repo_opts, arena, opened, session.haxy_moment, repo_identity.identity, undo_index) catch |err| switch (err) {
                                    error.OutOfMemory => return err,
                                    else => .{ .identity = repo_identity.identity, .failure = @errorName(err) },
                                };
                            }
                            // a merge: route stands for the log of what the merge brought in
                            const ref_or_oid: ?ui.RoutablePage.RefOrOid, const ref_value, const base_oid = if (commits_merge.len == 0)
                                .{ requested_ref_or_oid, requested_ref_value, commits_base_oid }
                            else merged: {
                                const merged = try Commits.resolveMerge(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, commits_merge);
                                break :merged .{ .object, merged.oid, merged.base_oid };
                            };
                            const files_data = if (patchrev_id.len != 0)
                                try Files.initPatchRev(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, location, patchrev_id, files_dir, files_line)
                            else
                                try Files.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, location, ref_or_oid, ref_value, files_dir, files_line, files_find);
                            const changes_data: Changes = if (route == .repo_diff)
                                .{ .diff = try Diff.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, route.repo_diff) }
                            else if (patchrev_id.len != 0) diff: {
                                const diff_route = ui.RoutablePage.repoPatchRevDiffRoute(repo_identity.identity, patchrev_id, 0, "") orelse return error.RouteTooLong;
                                break :diff .{ .diff = try Diff.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, diff_route.repo_diff) };
                            } else .{ .commits = try Commits.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, session.haxy_moment, location, ref_or_oid, ref_value, commits_content, base_oid, commits_search, commits_from) };
                            const target_branch = if (files_data.ref_or_oid == .branch) files_data.ref_or_oid_value else "";
                            break :blk .{
                                files_data,
                                changes_data,
                                try Refs.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, refs_kind, refs_from, refs_search),
                                try Issues.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, issues_label, issues_search, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view),
                                try Patches.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, session, repo_id_maybe, repo_identity.identity, target_branch, patches_label, patches_search, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view),
                                try Discussions.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, discussions_label, discussions_search, discussions_selected, discussions_comment, discussions_comments_start, discussions_view),
                                try Events.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, events_view, events_kind, events_selected, events_moment, session.local != null, session.data.sync_failure),
                            };
                        },
                    }
                },
            }
        }
        const aa = arena.allocator();
        break :blk .{
            try Files.emptyResult(aa, location, requested_ref_or_oid orelse .branch, requested_ref_value, files_dir),
            Changes{ .commits = try Commits.emptyResult(aa, location, requested_ref_or_oid orelse .branch, requested_ref_value, commits_content, commits_base_oid) },
            try Refs.emptyResult(arena, repo_identity.identity, refs_kind, refs_from, refs_search),
            try Issues.emptyResult(aa, repo_identity.identity, issues_label, issues_search, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view),
            try Patches.emptyResult(aa, repo_identity.identity, patches_label, patches_search, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view),
            try Discussions.emptyResult(aa, repo_identity.identity, discussions_label, discussions_search, discussions_selected, discussions_comment, discussions_comments_start, discussions_view),
            try Events.empty(aa, repo_identity.identity, events_view, session.local != null, session.data.sync_failure),
        };
    };
    if (undo_data) |*undo| {
        undo.can_undo = session.local != null or evt.Repo.roleOf(repo, session.userId()) == .owner;
        undo.clear = undo_clear;
    }
    if (route == .repo_undo and undo_data == null) return error.NotFound;
    issues.repo_source = source;
    patches.repo_source = source;
    patches.repo_id = repo_id_maybe;
    discussions.repo_source = source;

    return .{
        // use the files tab's resolved ref for the header
        .header = try Header.init(arena, repo.event.name, owner_name, files.ref_or_oid, files.ref_or_oid_value, issues.label, patches.label, discussions.label),
        .repo = repo,
        .files = files,
        .changes = changes,
        .refs = refs,
        .issues = issues,
        .patches = patches,
        .discussions = discussions,
        .events = events,
        .undo = undo_data,
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
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .round_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the files-tab id for the auth
        // view (it focuses there after login).
        {
            var header_view = try Header.View.init(allocator, data, session);
            errdefer header_view.deinit(allocator);
            try box.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .repo_header = header_view }, .rect = null, .min_size = null });
        }

        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);

            // files — the default tab: the current directory's listing.
            {
                var files_view = try Files.View.init(allocator, &data.files, session);
                errdefer files_view.deinit(allocator);
                try stack.children.put(allocator, files_view.getFocus().id, .{ .repo_files = files_view });
            }

            switch (data.changes) {
                .diff => |*diff| {
                    var diff_view = try Diff.View.init(allocator, diff, session);
                    errdefer diff_view.deinit(allocator);
                    try stack.children.put(allocator, diff_view.getFocus().id, .{ .diff_view = diff_view });
                },
                .commits => |*commits| {
                    var commits_view = try Commits.View.init(allocator, commits, session);
                    errdefer commits_view.deinit(allocator);
                    try stack.children.put(allocator, commits_view.getFocus().id, .{ .repo_commits = commits_view });
                },
            }

            // refs — the repo's branches and tags.
            {
                var refs_view = try Refs.View.init(allocator, &data.refs, session);
                errdefer refs_view.deinit(allocator);
                try stack.children.put(allocator, refs_view.getFocus().id, .{ .repo_refs = refs_view });
            }

            // issues — the repo's issue tracker and comment permalinks.
            {
                var issues_view = try Issues.View.init(allocator, &data.issues, session);
                errdefer issues_view.deinit(allocator);
                try stack.children.put(allocator, issues_view.getFocus().id, .{ .repo_issues = issues_view });
            }

            // patches and their comment permalinks.
            {
                var patches_view = try Patches.View.init(allocator, &data.patches, session);
                errdefer patches_view.deinit(allocator);
                try stack.children.put(allocator, patches_view.getFocus().id, .{ .repo_patches = patches_view });
            }

            // discussions and their comment permalinks.
            {
                var discussions_view = try Discussions.View.init(allocator, &data.discussions, session);
                errdefer discussions_view.deinit(allocator);
                try stack.children.put(allocator, discussions_view.getFocus().id, .{ .repo_discussions = discussions_view });
            }

            if (session.data.host_kind == .local or data.undo != null) {
                var events_view = try Events.View.init(allocator, &data.events, session);
                errdefer events_view.deinit(allocator);
                try stack.children.put(allocator, events_view.getFocus().id, .{ .repo_events = events_view });
            }

            if (data.undo) |*undo| {
                var undo_view = try Undo.View.init(allocator, undo, session);
                errdefer undo_view.deinit(allocator);
                try stack.children.put(allocator, undo_view.getFocus().id, .{ .repo_undo = undo_view });
            }

            // the header only shows the settings tab with a login and the auth
            // tab outside local mode, so keep the stack's children 1:1 with
            // the tabs by skipping the same views.
            if (session.data.user_id != null) {
                var settings_view = try Settings.View.init(allocator, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            if (session.data.host_kind == .server) {
                var auth_view = try Auth.View.init(allocator, &data.auth, session);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, session);
                errdefer quit_view.deinit(allocator);
                try stack.children.put(allocator, quit_view.getFocus().id, .{ .quit = quit_view });
            }

            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box };
        // a page opens on its tabs, except that search results open in the
        // tab's own search box.
        const results = data.files.find != null or
            (data.changes == .commits and data.changes.commits.search != null) or
            data.issues.search != null or data.patches.search != null or data.discussions.search != null;
        self.getFocus().child_id = box.children.keys()[if (results) stack_index else header_index];
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.repo_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;

        // each header tab maps 1:1 to a stack child by position
        if (header.getSelectedIndex()) |index|
            stack.getFocus().child_id = stack.children.keys()[index];
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const stack = &self.box.children.values()[stack_index].widget.stack;
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

                const direction = inp.vertDirection(key);

                switch (direction) {
                    .up => {
                        switch (child.*) {
                            .repo_header => {
                                try child.input(allocator, key, root_focus);
                            },
                            .stack => {
                                if (child.stack.getSelected()) |selected_widget| {
                                    if (selected_widget.atTop(root_focus)) {
                                        index = header_index;
                                    } else {
                                        try child.input(allocator, key, root_focus);
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    .down => {
                        switch (child.*) {
                            .repo_header => {
                                if (stack.getSelected()) |selected_widget| switch (selected_widget.*) {
                                    .repo_files => |*v| if (v.focusHeader(root_focus)) return,
                                    .repo_commits => |*v| if (v.focusHeader(root_focus)) return,
                                    .repo_refs => |*v| if (v.focusHeader(root_focus)) return,
                                    .repo_events => |*v| if (v.focusHeader(root_focus)) return,
                                    .repo_undo => |*v| if (v.focusHeader(root_focus)) return,
                                    else => {},
                                };
                                index = stack_index;
                            },
                            .stack => {
                                try child.input(allocator, key, root_focus);
                            },
                            else => {},
                        }
                    },
                    .none => {
                        try child.input(allocator, key, root_focus);
                    },
                }

                if (index != current_index) {
                    root_focus.setFocus(self.box.children.keys()[index]);
                }
            }
        }
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

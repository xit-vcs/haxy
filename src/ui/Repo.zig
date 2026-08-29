const std = @import("std");
const evt = @import("../event.zig");
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
pub const Commits = @import("./Repo/Commits.zig");
pub const Refs = @import("./Repo/Refs.zig");
pub const Issues = @import("./Repo/Issues.zig");
pub const Patches = @import("./Repo/Patches.zig");
pub const Discussions = @import("./Repo/Discussions.zig");
pub const Comment = @import("./Repo/Comment.zig");
pub const Events = @import("./Repo/Events.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
repo: evt.Repo.Record,
files: Files,
commits: Commits,
refs: Refs,
issues: Issues,
patches: Patches,
discussions: Discussions,
events: Events,
settings: Settings,
auth: Auth,
quit: Quit,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    route: ui.RoutablePage,
) !Self {
    const DB = evt.AdminDB;
    const hash_kind = evt.admin_repo_opts.hash;

    // every repo route stores its identity as "owner/name" (or elides it in
    // local mode); files and commits carry their remaining fields directly.
    const name_str = route.repoIdentity() orelse return error.UnexpectedRoute;
    const repo_identity = ui.RoutablePage.RepoIdentity.parse(name_str) orelse return error.NotFound;
    // the files and commits tabs share one ref/oid: whichever the incoming route
    // names (it rides on the route's target tab), or the default branch when
    // neither tab is targeted. building both views at it keeps switching tabs
    // (even by key, without a reload) on the same ref. a null ref means the
    // default branch (Files/Commits.init resolve it). the directory and the diff
    // window only apply to their own tab.
    const requested_ref_or_oid: ?ui.RoutablePage.RefOrOid = switch (route) {
        .repo_files => |f| f.ref_kind,
        .repo_commits => |c| c.ref_or_oid,
        else => null,
    };
    const requested_ref_value: []const u8 = switch (route) {
        .repo_files => |*f| f.ref_value.slice(),
        .repo_commits => |*c| c.value.slice(),
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
    // what the commits view's pane shows for the commit it walks from: a diff
    // window (with the file it's filtered to) or that commit's message.
    const commits_content: ui.RoutablePage.RepoCommitsRoute.Content = switch (route) {
        .repo_commits => |c| c.content,
        else => .{ .diff = .{} },
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
    // the issues tab's tag filter, the issue its window is rooted at, and the
    // view it shows.
    const issues_tag: []const u8 = switch (route) {
        .repo_issues => |*i| i.tag.slice(),
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
    const patches_tag: []const u8 = switch (route) {
        .repo_patches => |*p| p.tag.slice(),
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
    const discussions_tag: []const u8 = switch (route) {
        .repo_discussions => |*t| t.tag.slice(),
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

    // open the on-disk repo once and read every tab's data from it. files and
    // commits resolve the same requested ref (the default branch when the
    // route named none), so they end up viewing the same one. no filesystem
    // (wasm), nowhere to look, or a failed open: empty tabs.
    const files, const commits, const refs, var issues, var patches, var discussions, const events = blk: {
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
                            if (session.local != null) try evt.consume(.repo, repo_kind, opened.self_repo_opts, io, gpa, opened, evt.events_ref, &.{});
                            break :blk .{
                                try Files.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, requested_ref_or_oid, requested_ref_value, files_dir, files_line),
                                try Commits.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, session.haxy_moment, repo_identity.identity, requested_ref_or_oid, requested_ref_value, commits_content),
                                try Refs.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, refs_kind, refs_from),
                                try Issues.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, issues_tag, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view),
                                try Patches.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, session, repo_id_maybe, repo_identity.identity, patches_tag, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view),
                                try Discussions.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, discussions_tag, discussions_selected, discussions_comment, discussions_comments_start, discussions_view),
                                try Events.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, events_view, events_kind, events_selected, session.local != null, session.data.sync_failure),
                            };
                        },
                    }
                },
            }
        }
        const aa = arena.allocator();
        break :blk .{
            try Files.emptyResult(aa, repo_identity.identity, requested_ref_or_oid orelse .branch, requested_ref_value, files_dir),
            try Commits.emptyResult(aa, repo_identity.identity, requested_ref_or_oid orelse .branch, requested_ref_value, commits_content),
            try Refs.emptyResult(arena, repo_identity.identity, refs_kind, refs_from),
            try Issues.emptyResult(aa, repo_identity.identity, issues_tag, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view),
            try Patches.emptyResult(aa, repo_identity.identity, patches_tag, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view),
            try Discussions.emptyResult(aa, repo_identity.identity, discussions_tag, discussions_selected, discussions_comment, discussions_comments_start, discussions_view),
            try Events.empty(aa, repo_identity.identity, events_view, session.local != null, session.data.sync_failure),
        };
    };
    issues.repo_source = source;
    patches.repo_source = source;
    patches.repo_id = repo_id_maybe;
    patches.target_branch = if (files.ref_or_oid == .branch) files.ref_or_oid_value else "";
    discussions.repo_source = source;

    return .{
        // files and commits resolve the same ref, so either's serves the header,
        // which points both tabs at it.
        .header = try Header.init(arena, repo.event.name, owner_name, files.ref_or_oid, files.ref_or_oid_value, issues_tag, patches_tag, discussions_tag),
        .repo = repo,
        .files = files,
        .commits = commits,
        .refs = refs,
        .issues = issues,
        .patches = patches,
        .discussions = discussions,
        .events = events,
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
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the files-tab id for the auth
        // view (it focuses there after login).
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
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

            // commits — the current page of the commit log.
            {
                var commits_view = try Commits.View.init(allocator, &data.commits, session);
                errdefer commits_view.deinit(allocator);
                try stack.children.put(allocator, commits_view.getFocus().id, .{ .repo_commits = commits_view });
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

            {
                var events_view = try Events.View.init(allocator, &data.events, session);
                errdefer events_view.deinit(allocator);
                try stack.children.put(allocator, events_view.getFocus().id, .{ .repo_events = events_view });
            }

            // the header only shows the settings tab with a login and the auth
            // tab outside local mode, so keep the stack's children 1:1 with
            // the tabs by skipping the same views.
            if (session.data.user_id != null) {
                var settings_view = try Settings.View.init(allocator, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            if (!session.data.is_local) {
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
        self.getFocus().child_id = box.children.keys()[header_index];
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
                                    const at_top = switch (selected_widget.*) {
                                        .repo_files => |*v| v.getSelectedIndex() == 0,
                                        .repo_commits => |*v| v.getSelectedIndex() == 0,
                                        .repo_refs => |*v| v.getSelectedIndex() == 0,
                                        .repo_issues => |*v| v.getSelectedIndex() == 0,
                                        .repo_patches => |*v| v.getSelectedIndex() == 0,
                                        .repo_discussions => |*v| v.getSelectedIndex() == 0,
                                        .repo_events => |*v| v.getSelectedIndex() == 0,
                                        .home_settings => |*v| v.getSelectedIndex() == 0,
                                        .home_auth => |*v| v.getSelectedIndex() == 0,
                                        .quit => |*v| v.getSelectedIndex() == 0,
                                        else => false,
                                    };
                                    if (at_top) {
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
                                    .repo_files => |*v| if (v.focusGitRemote(root_focus)) return,
                                    .repo_commits => |*v| if (v.focusGitRemote(root_focus)) return,
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

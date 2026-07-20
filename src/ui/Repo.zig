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
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

const Array = ui.RoutablePage.Array(ui.RoutablePage.repo_identity_max_len);

header: Header,
repo: evt.Repo,
files: Files,
commits: Commits,
refs: Refs,
issues: Issues,
settings: Settings,
auth: Auth,
quit: Quit,
// the full files route this page renders, mirrored into current_page when
// the files tab is selected.
route_name: ui.RoutablePage.RepoFilesRoute,
// the commits route this page renders ("owner/name/commits[/<oid>]"), mirrored
// when the commits tab is selected.
commits_route_name: ui.RoutablePage.RepoCommitsRoute,
// "owner/name" alone, mirrored when the settings/auth tab is selected.
identity: Array,

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
    const name_str: []const u8 = switch (route) {
        .repo_files => |f| f.name.slice(),
        .repo_commits => |c| c.name.slice(),
        .repo_settings, .repo_auth => |n| n.slice(),
        .repo_refs => |r| r.name.slice(),
        .repo_issues => |i| i.name.slice(),
        else => return error.UnexpectedRoute,
    };
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
        .repo_files => |f| f.ref_value.slice(),
        .repo_commits => |c| c.value.slice(),
        else => "",
    };
    const files_dir = switch (route) {
        .repo_files => |f| f.path.slice(),
        else => "",
    };
    const files_line = switch (route) {
        .repo_files => |f| f.line,
        else => 0,
    };
    // the hunk the commits view's selected commit's diff window starts at.
    const commits_start = switch (route) {
        .repo_commits => |c| c.start,
        else => 0,
    };
    // the file the commits view's diff pane is filtered to ("" = every file).
    const commits_path = switch (route) {
        .repo_commits => |c| c.path.slice(),
        else => "",
    };
    // the refs tab windows one column at a time: `refs_from` (a url-encoded
    // ref name) roots `refs_kind`'s column, the other stays at its first window.
    const refs_kind: ui.RoutablePage.RefKind = switch (route) {
        .repo_refs => |r| r.kind,
        else => .branch,
    };
    const refs_from: []const u8 = switch (route) {
        .repo_refs => |r| r.from.slice(),
        else => "",
    };
    // the issues tab's tag filter, the issue its window is rooted at, and the
    // view it shows.
    const issues_tag: []const u8 = switch (route) {
        .repo_issues => |i| i.tag.slice(),
        else => "",
    };
    const issues_selected: []const u8 = switch (route) {
        .repo_issues => |i| i.selected.slice(),
        else => "",
    };
    const issues_view: ui.RoutablePage.IssuesView = switch (route) {
        .repo_issues => |i| i.view,
        else => .open,
    };

    // where the on-disk repo lives (null keeps the views' empty fallback), plus
    // the repo and owner-name metadata the header shows. local mode already
    // knows all three; the server paths resolve them from the admin db.
    var source: ?ui.RepoSource = null;
    var repo: evt.Repo = undefined;
    var owner_name: []const u8 = undefined;
    if (session.local) |local| {
        source = local;
        // local routes elide the identity, so the display name comes from the
        // repo's directory rather than the route.
        repo = .{
            .user_id = "",
            .name = try arena.allocator().dupe(u8, std.fs.path.basename(local.path)),
            .description = "",
            .enable_issue = true,
        };
        owner_name = "";
    } else {
        const haxy_moment = session.haxy_moment orelse return error.NoMoment;
        const found = (try evt.Repo.readByOwnerAndName(DB, hash_kind, haxy_moment, arena, repo_identity.owner, repo_identity.name)) orelse return error.NotFound;
        repo = found.repo;

        // resolve the creating user so the header can show their name to the left
        // of the repo title.
        const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, repo.user_id)) orelse return error.NotFound;
        owner_name = owner.name;

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
    // route named none), so they end up viewing the same one and either's
    // resolved ref can canonicalize the tab mirror urls below. no filesystem
    // (wasm), nowhere to look, or a failed open: empty tabs.
    const files, const commits, const refs, var issues = blk: {
        read: {
            const io = session.io orelse break :read;
            const src = source orelse break :read;
            const gpa = arena.child_allocator;
            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = rp.AnyRepo(repo_kind, .{}).open(io, gpa, .{ .path = src.path }) catch break :read;
                    defer any_repo.deinit(io, gpa);
                    switch (any_repo) {
                        inline else => |*opened| {
                            // local mode: bring the event db up to date with the events branch
                            const is_local = session.local != null;
                            if (is_local) try evt.syncLocalEvents(repo_kind, opened.self_repo_opts, io, gpa, opened);
                            break :blk .{
                                try Files.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, requested_ref_or_oid, requested_ref_value, files_dir, files_line),
                                try Commits.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, requested_ref_or_oid, requested_ref_value, commits_start, commits_path),
                                try Refs.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, refs_kind, refs_from),
                                try Issues.init(repo_kind, opened.self_repo_opts, arena, opened, io, is_local, repo_identity.identity, issues_tag, issues_selected, issues_view),
                            };
                        },
                    }
                },
            }
        }
        const aa = arena.allocator();
        break :blk .{
            try Files.emptyResult(aa, repo_identity.identity, requested_ref_or_oid orelse .branch, requested_ref_value, files_dir),
            try Commits.emptyResult(aa, repo_identity.identity, requested_ref_or_oid orelse .branch, requested_ref_value, commits_path),
            try Refs.emptyResult(arena, repo_identity.identity, refs_kind, refs_from),
            try Issues.emptyResult(aa, repo_identity.identity, issues_tag, issues_selected, issues_view),
        };
    };
    issues.repo_source = source;

    // each tab mirror carries this page's route for that tab; tabs not targeted
    // by the incoming route fall back to their root/first-page route. the files
    // mirror carries the selected file (when the route named one) so the url
    // keeps it before focus enters the view.
    const files_path = if (files.selected_file) |f| try Files.childDir(arena.allocator(), files.dir, f) else files.dir;
    // the content window only applies to a selected file, so the bare
    // directory route drops it.
    const files_route_line = if (files.selected_file != null) files_line else 0;
    const route_name = (ui.RoutablePage.repoFilesRoute(repo_identity.identity, files.ref_or_oid, files.ref_or_oid_value, files_path, files_route_line) orelse return error.NotFound).repo_files;
    const commits_route_name = (ui.RoutablePage.repoCommitsRoute(repo_identity.identity, commits.ref_or_oid, commits.ref_or_oid_value, commits_start, commits.path) orelse return error.NotFound).repo_commits;

    return .{
        // files and commits resolve the same ref, so either's serves the header,
        // which points both tabs at it.
        .header = try Header.init(arena, repo.name, owner_name, files.ref_or_oid, files.ref_or_oid_value, issues_tag),
        .repo = repo,
        .files = files,
        .commits = commits,
        .refs = refs,
        .issues = issues,
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
        .route_name = route_name,
        .commits_route_name = commits_route_name,
        .identity = Array.from(repo_identity.identity) orelse return error.NotFound,
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the files-tab id for the auth
        // view (it focuses there after login).
        var files_tab_id: usize = undefined;
        {
            var header_view = try Header.View.init(allocator, &data.header, session);
            errdefer header_view.deinit(allocator);
            files_tab_id = header_view.tab_ids.keys()[0];
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

            // issues — the repo's issue tracker.
            {
                var issues_view = try Issues.View.init(allocator, &data.issues, session);
                errdefer issues_view.deinit(allocator);
                try stack.children.put(allocator, issues_view.getFocus().id, .{ .repo_issues = issues_view });
            }

            {
                var settings_view = try Settings.View.init(allocator, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            // the header has no auth tab in local mode, so keep the stack's
            // children 1:1 with the tabs by skipping the auth view too.
            if (!session.data.is_local) {
                var auth_view = try Auth.View.init(allocator, &data.auth, session, files_tab_id);
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

        var self = View{ .box = box, .data = data, .session = session };
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

        // each header tab maps 1:1 to a stack child by position. mirror the
        // selection into current_page so the host can push the matching url;
        // all repo tabs share the .repo parent, so this stays on the page
        // rather than navigating.
        if (header.getSelectedIndex()) |index| {
            stack.getFocus().child_id = stack.children.keys()[index];
            switch (std.meta.activeTag(stack.children.values()[index])) {
                // files/commits carry this page's content route (directory / log
                // page); settings/auth carry only "owner/name".
                .repo_commits => self.session.data.current_page = .{ .repo_commits = self.data.commits_route_name },
                // the refs tab mirrors this page's windowed column.
                .repo_refs => self.session.data.current_page = ui.RoutablePage.repoRefsRoute(self.data.identity.slice(), self.data.refs.kind, self.data.refs.from) orelse self.session.data.current_page,
                // the issues tab mirrors this page's tag filter (issue urls
                // themselves never carry the tag).
                .repo_issues => self.session.data.current_page = ui.RoutablePage.repoIssuesRoute(self.data.identity.slice(), .open, self.data.issues.tag, "") orelse self.session.data.current_page,
                .home_settings => {
                    if (ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len).from(self.data.identity.slice())) |identity|
                        self.session.data.current_page = .{ .repo_settings = identity };
                },
                .home_auth => {
                    if (ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len).from(self.data.identity.slice())) |identity|
                        self.session.data.current_page = .{ .repo_auth = identity };
                },
                // the quit tab is tty-only and not a route, so leave current_page
                // alone (nothing to mirror into the url).
                .quit => {},
                // the files tab (this page's directory route)
                else => self.session.data.current_page = .{ .repo_files = self.data.route_name },
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
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

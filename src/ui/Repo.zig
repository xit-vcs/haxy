const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Header = @import("./Repo/Header.zig");
pub const SubHeader = @import("./Repo/SubHeader.zig");
pub const Files = @import("./Repo/Files.zig");
pub const Commits = @import("./Repo/Commits.zig");
pub const Refs = @import("./Repo/Refs.zig");
pub const Settings = @import("./Settings.zig");
pub const Auth = @import("./Auth.zig");
pub const Quit = @import("./Quit.zig");

const Array = ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len);

header: Header,
repo: evt.Repo,
files: Files,
commits: Commits,
refs: Refs,
settings: Settings,
auth: Auth,
quit: Quit,
// the full files route this page renders ("owner/name" or "owner/name/files/<dir>"),
// mirrored into current_page when the files tab is selected.
route_name: Array,
// the commits route this page renders ("owner/name/commits[/<oid>]"), mirrored
// when the commits tab is selected.
commits_route_name: Array,
// the diff window (?after=N) of that commits route; mirrored alongside the name
// so the url keeps the query param even when focus isn't in the commits view.
commits_after: usize,
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
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;

    // every repo route's stored string starts with "owner/name"; the files and
    // commits routes additionally encode a ref/oid (files also a directory).
    const name_str: []const u8 = switch (route) {
        .repo, .repo_settings, .repo_auth => |n| n.slice(),
        .repo_commits => |c| c.name.slice(),
        .repo_refs => |r| r.name.slice(),
        else => return error.UnexpectedRoute,
    };
    const rf = ui.RoutablePage.RepoFiles.parse(name_str) orelse return error.NotFound;
    const tag = std.meta.activeTag(route);

    // the files and commits tabs share one ref/oid: whichever the incoming route
    // names (it rides on the route's target tab), or the default branch when
    // neither tab is targeted. building both views at it keeps switching tabs
    // (even by key, without a reload) on the same ref. a null ref means the
    // default branch (Files/Commits.init resolve it). the directory and the diff
    // window only apply to their own tab.
    const commits_ref = if (tag == .repo_commits) ui.RoutablePage.repoCommitsRef(name_str) else ui.RoutablePage.CommitsRef{ .ref_or_oid = null, .value = "" };
    const requested_ref_or_oid: ?ui.RoutablePage.RefOrOid = switch (tag) {
        .repo => rf.ref_kind,
        .repo_commits => commits_ref.ref_or_oid,
        else => null,
    };
    const requested_ref_value: []const u8 = switch (tag) {
        .repo => rf.ref_value,
        .repo_commits => commits_ref.value,
        else => "",
    };
    const files_dir = if (tag == .repo) rf.dir else "";
    // how many diff hunks the commits view's selected commit shows ("load more").
    const commits_after: usize = switch (route) {
        .repo_commits => |c| c.after,
        else => 0,
    };
    // the refs tab paginates one column at a time: this offset applies to
    // `refs_kind`'s column, the other stays at its first window.
    const refs_kind: ui.RoutablePage.RefKind = switch (route) {
        .repo_refs => |r| r.kind,
        else => .branch,
    };
    const refs_after: usize = switch (route) {
        .repo_refs => |r| r.after,
        else => 0,
    };

    const found = (try evt.Repo.readByOwnerAndName(DB, hash_kind, haxy_moment, arena, rf.owner, rf.name)) orelse return error.NotFound;
    const repo = found.repo;

    // resolve the creating user so the header can show their name to the left
    // of the repo title.
    const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, repo.user_id)) orelse return error.NotFound;

    // build files and commits first so their resolved ref (the default branch
    // when the route named none) can canonicalize each tab's mirror url to the
    // explicit ref it's viewing rather than leaving it bare. both resolve the
    // same requested ref, so they end up viewing the same one.
    const files = try Files.init(arena, session, &found.event_id, rf.identity, requested_ref_or_oid, requested_ref_value, files_dir);
    const commits = try Commits.init(arena, session, &found.event_id, rf.identity, requested_ref_or_oid, requested_ref_value, commits_after);

    // each tab mirror carries this page's route for that tab; tabs not targeted
    // by the incoming route fall back to their root/first-page route.
    const route_name = (ui.RoutablePage.repoFilesRoute(rf.identity, files.ref_or_oid, files.ref_or_oid_value, files.dir) orelse return error.NotFound).repo;
    const commits_route_name = (ui.RoutablePage.repoCommitsRoute(rf.identity, commits.ref_or_oid, commits.ref_or_oid_value, commits_after) orelse return error.NotFound).repo_commits.name;

    return .{
        // files and commits resolve the same ref, so either's serves the header,
        // which points both tabs at it.
        .header = try Header.init(arena, repo.name, owner.name, files.ref_or_oid, files.ref_or_oid_value),
        .repo = repo,
        .files = files,
        .commits = commits,
        .refs = try Refs.init(arena, session, &found.event_id, rf.identity, refs_kind, refs_after),
        .settings = Settings.init(),
        .auth = Auth.init(),
        .quit = Quit.init(),
        .route_name = route_name,
        .commits_route_name = commits_route_name,
        .commits_after = commits_after,
        .identity = Array.from(rf.identity) orelse return error.NotFound,
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

            {
                var settings_view = try Settings.View.init(allocator, &data.settings, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .home_settings = settings_view });
            }

            {
                var auth_view = try Auth.View.init(allocator, &data.auth, session, files_tab_id);
                errdefer auth_view.deinit(allocator);
                try stack.children.put(allocator, auth_view.getFocus().id, .{ .home_auth = auth_view });
            }

            if (session.is_terminal) {
                var quit_view = try Quit.View.init(allocator, &data.quit, session);
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
                .repo_commits => self.session.data.current_page = .{ .repo_commits = .{ .name = self.data.commits_route_name, .after = self.data.commits_after } },
                // the refs tab mirrors this page's paginated column + offset.
                .repo_refs => self.session.data.current_page = .{ .repo_refs = .{ .name = self.data.identity, .kind = self.data.refs.kind, .after = self.data.refs.after } },
                .home_settings => self.session.data.current_page = .{ .repo_settings = self.data.identity },
                .home_auth => self.session.data.current_page = .{ .repo_auth = self.data.identity },
                // the quit tab is tty-only and not a route, so leave current_page
                // alone (nothing to mirror into the url).
                .quit => {},
                // the files tab (this page's directory route)
                else => self.session.data.current_page = .{ .repo = self.data.route_name },
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            if (self.box.children.getIndex(child_id)) |current_index| {
                const child = &self.box.children.values()[current_index].widget;
                var index = current_index;

                const Direction = enum { up, down, none };
                const direction: Direction = switch (key) {
                    .arrow_up => .up,
                    .arrow_down => .down,
                    .mouse => |mouse| if (mouse.action == .scroll)
                        (if (mouse.action.scroll == .up) .up else .down)
                    else
                        .none,
                    else => .none,
                };

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
                    try root_focus.setFocus(self.box.children.keys()[index]);
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

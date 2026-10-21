const std = @import("std");
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const notify = @import("../notify.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
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
pub const Discussions = @import("./Repo/Discussions.zig");
pub const Issues = @import("./Repo/Issues.zig");
pub const Patches = @import("./Repo/Patches.zig");
pub const Comment = @import("./Repo/Comment.zig");
pub const Undo = @import("./Repo/Undo.zig");
pub const Events = @import("./Repo/Events.zig");
pub const Settings = @import("./Repo/Settings.zig");
pub const Members = @import("./Repo/Members.zig");
pub const Branches = @import("./Repo/Branches.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
repo: evt.Repo.Record,
handle: ui.RepoHandle,
files: Files,
changes: Changes,
refs: Refs,
discussions: Discussions,
issues: Issues,
patches: Patches,
events: Events,
undo: ?Undo = null,
settings: ?Settings = null,
user_notifications: ui.UserNotifications,
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

    // every repo route stores its identity as "owner:name" (or elides it in local mode)
    const name_str = route.repoIdentity() orelse return error.UnexpectedRoute;
    const repo_identity = ui.RoutablePage.RepoIdentity.parse(name_str) orelse return error.NotFound;
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
    // the commits view's pane shows the whole message of the commit it walks from
    const commits_message = route == .repo_commits and route.repo_commits.message;
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
    // the issues tab's search, the issue its window is rooted at, and the view
    // it shows.
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
    const members_route: ui.RoutablePage.RepoMembersRoute = switch (route) {
        .repo_members => |r| r,
        else => .{ .name = .{} },
    };
    // the thread the route shows, whose notif viewing it reads
    const viewed_thread: []const u8 = switch (route) {
        .repo_issues => |*i| if (i.view == .conflicts) "" else i.selected.slice(),
        .repo_patches => |*p| if (p.view == .conflicts) "" else p.selected.slice(),
        .repo_discussions => |*t| t.selected.slice(),
        else => "",
    };

    // where the on-disk repo lives (null keeps the views' empty fallback), plus
    // the repo and owner-name metadata the header shows. local mode already
    // knows all three; the server paths resolve them from the admin db.
    var source: ?ui.RepoSource = null;
    var repo_id_maybe: ?[evt.event_id_size]u8 = null;
    // local mode has no owner
    var owner_id: [evt.event_id_size]u8 = @splat(0);
    var repo: evt.Repo.Record = undefined;
    // local mode owns its repo
    var role: evt.Repo.Role = .owner;
    var owner_name: []const u8 = undefined;
    if (session.local) |local| {
        source = local;
        // local routes elide the identity, so the display name comes from the
        // repo's directory rather than the route.
        repo = .{
            .event = .{
                .user_id = @splat('0'),
                .name = try arena.allocator().dupe(u8, std.Io.Dir.path.basename(local.path)),
                .description = "",
                // local mode shows every tab
                .discuss_role = .read,
                .issue_role = .read,
                .patch_role = .read,
            },
        };
        owner_name = "";
    } else {
        const haxy_moment = session.haxy_moment orelse return error.NoMoment;
        const io = session.io orelse return error.NoMoment;
        const users_dir = session.users_dir orelse return error.NoMoment;
        const found = (try evt.readRepoByOwnerAndName(io, arena.child_allocator, arena, haxy_moment, users_dir, repo_identity.owner, repo_identity.name, session.userId())) orelse return error.NotFound;
        // a repo the session can't read doesn't exist to it
        role = found.role orelse return error.NotFound;
        repo = found.repo;
        repo_id_maybe = found.event_id;

        // resolve the creating user so the header can show their name to the left
        // of the repo title.
        owner_id = try evt.parseEventId(&repo.event.user_id);
        const owner = (try evt.User.readById(DB, hash_kind, haxy_moment, arena, &owner_id)) orelse return error.NotFound;
        owner_name = owner.event.name;

        // the repo's working copy lives in its owner's dir.
        source = .{
            .path = try evt.repoPath(arena.allocator(), users_dir, &owner_id, &found.event_id),
            .repo_kind = .xit,
        };
    }

    const handle = ui.RepoHandle{
        .location = .{ .repo = try arena.allocator().dupe(u8, repo_identity.identity) },
        .viewer = try ui.Viewer.init(session, arena, role),
        .read_access = repo.event.read_access,
    };

    // open the repo once for every tab. files and changes share a ref or revision.
    // no filesystem (wasm), nowhere to look, or a failed open: empty tabs.
    // the events tab needs write access, like undo
    if (route == .repo_events and !handle.canWrite()) return error.NotFound;
    // a tab that is off doesn't exist
    const route_thread_kind: ?evt.EventKind = switch (route) {
        .repo_discussions => .discuss,
        .repo_issues => .issue,
        .repo_patches => .patch,
        else => null,
    };
    if (route_thread_kind) |kind| if (repo.event.threadRole(kind) == null) return error.NotFound;
    const undo_index = if (route == .repo_undo) route.repo_undo.index else null;
    // only xit repos have undo history, so it's read in their branch below.
    // local mode leaves undo to xit itself.
    var undo_data: ?Undo = null;
    // only the owner sees the settings, which show the repo's hash kind
    var settings: ?Settings = null;
    const files, const changes, const refs, var discussions, var issues, var patches, const events = blk: {
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
                                try pch.refreshBranches(.local, repo_kind, opened.self_repo_opts, io, gpa, opened, null);
                            }
                            if (session.data.host_kind == .server and handle.canUndo()) {
                                // a server page always resolved its repo id
                                const repo_id = repo_id_maybe orelse unreachable;
                                const identity = try arena.allocator().dupe(u8, repo_identity.identity);
                                // only the repo's creator may delete it, never a granted owner
                                const creator = if (session.userId()) |user_id| std.mem.eql(u8, &user_id, &owner_id) else false;
                                // the branch HEAD names, which the branches tab shows as the default
                                var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
                                const default_branch = if (opened.head(io, &head_buffer)) |head| switch (head) {
                                    .ref => |ref| ref.name,
                                    .oid => "",
                                } else |_| "";
                                settings = .{
                                    .identity = identity,
                                    .name = repo.event.name,
                                    .description = repo.event.description,
                                    .access = repo.event.read_access,
                                    .discuss_role = repo.event.discuss_role,
                                    .issue_role = repo.event.issue_role,
                                    .patch_role = repo.event.patch_role,
                                    .hash_kind = opened.self_repo_opts.hash,
                                    .view = switch (route) {
                                        .repo_members => .members,
                                        .repo_branches => .branches,
                                        .repo_delete => .delete,
                                        else => .settings,
                                    },
                                    .members = try Members.init(io, gpa, arena, session.haxy_moment orelse return error.NoMoment, session.users_dir orelse return error.NoMoment, repo_identity.identity, &owner_id, &repo_id, members_route.start, if (members_route.confirm) |action| .{ .action = action, .name = members_route.user.slice() } else null),
                                    .branches = try Branches.init(arena, repo_identity.identity, repo.event, default_branch),
                                    .delete = if (creator) .{ .target = .{ .repo = identity } } else null,
                                };
                            }
                            // tabs switch in-page, so every tab's data is read here
                            if (repo_kind == .xit and session.data.host_kind == .server and handle.canWrite()) {
                                undo_data = Undo.init(opened.self_repo_opts, arena, opened, session.haxy_moment, repo_identity.identity, undo_index, handle) catch |err| switch (err) {
                                    error.OutOfMemory => return err,
                                    else => .{ .identity = try arena.allocator().dupe(u8, repo_identity.identity), .handle = handle, .failure = @errorName(err) },
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
                                try Files.initPatchRev(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, handle, patchrev_id, files_dir, files_line)
                            else
                                try Files.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, handle, ref_or_oid, ref_value, files_dir, files_line, files_find);
                            const changes_data: Changes = if (route == .repo_diff)
                                .{ .diff = try Diff.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, route.repo_diff) }
                            else if (patchrev_id.len != 0) diff: {
                                const diff_route = ui.RoutablePage.repoPatchRevDiffRoute(repo_identity.identity, patchrev_id, 0, "") orelse return error.RouteTooLong;
                                break :diff .{ .diff = try Diff.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, diff_route.repo_diff) };
                            } else .{ .commits = try Commits.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, session.haxy_moment, handle, ref_or_oid, ref_value, commits_message, base_oid, commits_search, commits_from) };
                            const target_branch = if (files_data.ref_or_oid == .branch) files_data.ref_or_oid_value else "";
                            var discussions_data = try Discussions.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, discussions_search, discussions_selected, discussions_comment, discussions_comments_start, discussions_view, tabViewer(handle, repo, .discuss));
                            var issues_data = try Issues.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, issues_search, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view, tabViewer(handle, repo, .issue));
                            var patches_data = try Patches.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, session, repo_id_maybe, repo_identity.identity, target_branch, patches_search, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view, tabViewer(handle, repo, .patch));
                            if (repo_kind == .xit and session.data.host_kind == .server) {
                                // a server page always resolved its repo id
                                const repo_id = repo_id_maybe orelse unreachable;
                                readNotify(opened.self_repo_opts, session, arena, opened, &owner_id, &repo_id, viewed_thread, &discussions_data, &issues_data, &patches_data) catch |err| {
                                    std.log.warn("failed to read thread notifications: {s}", .{@errorName(err)});
                                };
                            }
                            break :blk .{
                                files_data,
                                changes_data,
                                try Refs.init(repo_kind, opened.self_repo_opts, arena, opened, io, gpa, repo_identity.identity, refs_kind, refs_from, refs_search),
                                discussions_data,
                                issues_data,
                                patches_data,
                                try Events.init(repo_kind, opened.self_repo_opts, arena, opened, io, session.haxy_moment, repo_identity.identity, repo.event, events_view, events_kind, events_selected, events_moment, session.local != null, session.data.sync_failure),
                            };
                        },
                    }
                },
            }
        }
        const aa = arena.allocator();
        break :blk .{
            try Files.emptyResult(aa, handle, requested_ref_or_oid orelse .branch, requested_ref_value, files_dir),
            Changes{ .commits = try Commits.emptyResult(aa, handle, requested_ref_or_oid orelse .branch, requested_ref_value, commits_base_oid) },
            try Refs.emptyResult(arena, repo_identity.identity, refs_kind, refs_from, refs_search),
            try Discussions.emptyResult(aa, repo_identity.identity, discussions_search, discussions_selected, discussions_comment, discussions_comments_start, discussions_view),
            try Issues.emptyResult(aa, repo_identity.identity, issues_search, issues_selected, issues_comment, issues_comments_start, issues_theirs, issues_view),
            try Patches.emptyResult(aa, repo_identity.identity, patches_search, patches_selected, patches_comment, patches_comments_start, patches_theirs, patches_view),
            try Events.empty(aa, repo_identity.identity, events_view, session.local != null, session.data.sync_failure),
        };
    };
    if (route == .repo_undo and undo_data == null) return error.NotFound;
    if ((route == .repo_settings or route == .repo_members or route == .repo_branches or route == .repo_delete) and settings == null) return error.NotFound;
    if (settings) |value| if (route == .repo_delete and value.delete == null) return error.NotFound;
    discussions.repo_source = source;
    issues.repo_source = source;
    patches.repo_source = source;
    patches.repo_id = repo_id_maybe;

    return .{
        // use the files tab's resolved ref for the header
        .header = try Header.init(arena, repo.event.name, owner_name, files.ref_or_oid, files.ref_or_oid_value, discussions.search, issues.search, patches.search),
        .repo = repo,
        .handle = handle,
        .files = files,
        .changes = changes,
        .refs = refs,
        .discussions = discussions,
        .issues = issues,
        .patches = patches,
        .events = events,
        .undo = undo_data,
        .settings = settings,
        // after the shown thread's notif is marked read
        .user_notifications = try ui.UserNotifications.init(arena, session, route.userTab()),
        .quit = Quit.init(),
    };
}

// set the viewer's notify button on every listed thread and mark the viewed thread's notif read
fn readNotify(
    comptime repo_opts: rp.RepoOpts(.xit),
    session: *ui.Session,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.xit, repo_opts),
    owner_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    viewed_thread: []const u8,
    discussions: *Discussions,
    issues: *Issues,
    patches: *Patches,
) !void {
    const user_id = session.userId() orelse return;
    const io = session.io orelse return error.NoMoment;
    const users_dir = session.users_dir orelse return error.NoMoment;
    const gpa = arena.child_allocator;

    {
        // the owner's plain data, which holds the tier index
        var owner_repo = (try evt.openUserRepo(io, gpa, users_dir, owner_id)) orelse return error.NotFound;
        defer owner_repo.deinit(io, gpa);
        const owner_moment = try notify.latestMoment(&owner_repo);

        try setNotifyActions(arena, &discussions.recent, owner_moment, repo_id, &user_id);
        for ([_]*Issues.Window{ &issues.open, &issues.closed, &issues.conflicts }) |window| try setNotifyActions(arena, window, owner_moment, repo_id, &user_id);
        for ([_]*Patches.Window{ &patches.open, &patches.closed, &patches.merged, &patches.conflicts }) |window| try setNotifyActions(arena, window, owner_moment, repo_id, &user_id);
    }

    if (viewed_thread.len == 0) return;
    var user_repo = (try evt.openUserRepo(io, gpa, users_dir, &user_id)) orelse return;
    defer user_repo.deinit(io, gpa);
    const latest = (try notify.latestMoment(&user_repo)) orelse return;
    const notif_id = notify.idOf(repo_id, &try evt.parseEventId(viewed_thread));
    const item = (try notify.readItem(latest, arena, &notif_id)) orelse return;
    if (!item.unread) return;
    // the page reads this moment or a newer one, so a child in it is shown
    const moment = try evt.currentMoment(repo_opts, repo);
    const kinds_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse return error.CursorNotFound;
    const kinds = try evt.EventDB(repo_opts.hash).HashMap(.read_only).init(kinds_cursor);
    // a child the page can't show leaves it unread
    if (try evt.readEventKind(repo_opts.hash, kinds, &item.notif.last_child_id) == null) return;
    try notify.markRead(io, gpa, users_dir, &user_id, &notif_id, &item.notif.last_child_id);
}

// set the viewer's notify button on each of a window's threads
fn setNotifyActions(
    arena: *std.heap.ArenaAllocator,
    window: anytype,
    owner_moment: ?evt.UserDB.HashMap(.read_only),
    repo_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
) !void {
    const items = try arena.allocator().dupe(std.meta.Elem(@TypeOf(window.items)), window.items);
    for (items) |*entry| {
        const notif_id = notify.idOf(repo_id, &try evt.parseEventId(entry.id));
        // muting drops the user from every tier, so membership alone decides
        const notified = if (owner_moment) |moment| try notify.isNotified(moment, &notif_id, user_id) else false;
        entry.notify_action = if (notified) .mute else .subscribe;
    }
    window.items = items;
}

// the viewer a tab's comment bar sees, which is none below the tab's role
fn tabViewer(handle: ui.RepoHandle, repo: evt.Repo.Record, kind: evt.EventKind) ?ui.Viewer {
    const viewer = handle.viewer orelse return null;
    const tab_role = repo.event.threadRole(kind) orelse return null;
    return if (viewer.role.atLeast(tab_role)) viewer else null;
}

pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .round_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        // build the header first so we can grab the files-tab id for the user
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

            // discussions and their comment permalinks.
            if (data.repo.event.discuss_role != null) {
                var discussions_view = try Discussions.View.init(allocator, &data.discussions, session);
                errdefer discussions_view.deinit(allocator);
                try stack.children.put(allocator, discussions_view.getFocus().id, .{ .repo_discussions = discussions_view });
            }

            // issues — the repo's issue tracker and comment permalinks.
            if (data.repo.event.issue_role != null) {
                var issues_view = try Issues.View.init(allocator, &data.issues, session);
                errdefer issues_view.deinit(allocator);
                try stack.children.put(allocator, issues_view.getFocus().id, .{ .repo_issues = issues_view });
            }

            // patches and their comment permalinks.
            if (data.repo.event.patch_role != null) {
                var patches_view = try Patches.View.init(allocator, &data.patches, session);
                errdefer patches_view.deinit(allocator);
                try stack.children.put(allocator, patches_view.getFocus().id, .{ .repo_patches = patches_view });
            }

            if (data.handle.canWrite()) {
                var events_view = try Events.View.init(allocator, &data.events, session);
                errdefer events_view.deinit(allocator);
                try stack.children.put(allocator, events_view.getFocus().id, .{ .repo_events = events_view });
            }

            if (data.undo) |*undo| {
                var undo_view = try Undo.View.init(allocator, undo, session);
                errdefer undo_view.deinit(allocator);
                try stack.children.put(allocator, undo_view.getFocus().id, .{ .repo_undo = undo_view });
            }

            if (data.settings) |*settings| {
                var settings_view = try Settings.View.init(allocator, settings, session);
                errdefer settings_view.deinit(allocator);
                try stack.children.put(allocator, settings_view.getFocus().id, .{ .repo_settings = settings_view });
            }

            // the header shows new repo with a login, and new user without one
            // and user only outside local mode, so keep the stack's children
            // 1:1 with the tabs by skipping the same views.
            const identity = try session.page_arena.allocator().print("{s}:{s}", .{ data.header.owner_name, data.header.name });
            if (session.data.user_id != null) {
                const route = ui.RoutablePage{ .repo_repo_new = ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len).from(identity) orelse return error.RouteTooLong };
                var new_repo_view = try ui.NewRepo.View.init(allocator, session, route);
                errdefer new_repo_view.deinit(allocator);
                try stack.children.put(allocator, new_repo_view.getFocus().id, .{ .new_repo = new_repo_view });
            } else if (session.data.host_kind == .server) {
                const route = ui.RoutablePage{ .repo_user_new = ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len).from(identity) orelse return error.RouteTooLong };
                var new_user_view = try ui.NewUser.View.init(allocator, session, route);
                errdefer new_user_view.deinit(allocator);
                try stack.children.put(allocator, new_user_view.getFocus().id, .{ .new_user = new_user_view });
            }

            if (session.data.host_kind == .server) {
                const route = ui.RoutablePage{ .repo_user = .{ .name = ui.RoutablePage.Array(ui.RoutablePage.repo_route_max_len).from(identity) orelse return error.RouteTooLong } };
                var user_view = try ui.UserSettings.initView(allocator, session, &data.user_notifications, route);
                errdefer user_view.deinit(allocator);
                try stack.children.put(allocator, user_view.getFocus().id, user_view);
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
            data.discussions.search != null or data.issues.search != null or data.patches.search != null;
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
                                    .repo_settings => |*v| if (v.focusHeader(root_focus)) return,
                                    .user_notifications => |*v| if (v.focusHeader(root_focus)) return,
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

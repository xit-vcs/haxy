const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const diff3 = @import("../../diff3.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const thread = ui.widget.thread;
const fork = @import("../../fork.zig");
const pch = @import("../../patch.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

pub const Source = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    selected: Kind,
    selectors: std.enums.EnumMap(Kind, usize),

    pub const Kind = enum { fork, branch };

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, initial: []const u8, initial_kind: Kind) !Source {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        const selected: Kind = if (session.data.host_kind == .local) .branch else initial_kind;
        var selectors: std.enums.EnumMap(Kind, usize) = .{};
        if (session.data.host_kind != .local) {
            for (std.enums.values(Kind)) |kind| {
                const label = switch (kind) {
                    .fork => "from a new fork",
                    .branch => "from an existing branch",
                };
                var selector = try wgt.TextBox.init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer selector.deinit(allocator);
                selector.getFocus().mode = .all;
                try box.children.put(allocator, selector.getFocus().id, .{ .widget = .{ .text_box = selector }, .rect = null, .min_size = .{ .width = label.len + 2, .height = 3 } });
                selectors.put(kind, selector.getFocus().id);
            }
        }
        var input_box = try wgt.TextInput.init(allocator, .{ .label = " source branch ", .name = "source_branch", .rounded_corners = true, .visible_width = null, .render_content = session.is_terminal });
        errdefer input_box.deinit(allocator);
        input_box.getFocus().mode = .all;
        try input_box.setContent(allocator, initial);
        try box.children.put(allocator, input_box.getFocus().id, .{ .widget = .{ .text_input = input_box }, .rect = null, .min_size = .{ .width = 15, .height = 3 } });
        box.getFocus().child_id = selectors.get(selected) orelse input_box.getFocus().id;
        return .{ .box = box, .session = session, .selected = selected, .selectors = selectors };
    }

    pub fn field(self: *Source) *wgt.TextInput {
        for (self.box.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| return text_input,
            else => {},
        };
        unreachable;
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn clearGrid(self: *Source) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Source) ?xitui.grid.Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Source) *xitui.focus.Focus {
        return self.box.getFocus();
    }

    pub fn build(self: *Source, allocator: std.mem.Allocator, constraint: xitui.layout.Constraint, root_focus: *xitui.focus.Focus) !void {
        self.clearGrid();
        for (self.box.children.keys(), self.box.children.values()) |id, *child| switch (child.widget) {
            .text_input => child.hidden = switch (self.selected) {
                .fork => true,
                .branch => false,
            },
            .text_box => |*selector| selector.options.border_style = if (id == self.selectors.get(self.selected)) .single else .hidden,
            else => {},
        };
        try self.box.build(allocator, constraint, root_focus);
        if (!self.session.is_terminal) {
            try self.session.text_inputs.put(self.session.arena.allocator(), self.field().getFocus().id, self.field());
        }
    }

    pub fn input(self: *Source, allocator: std.mem.Allocator, key: xitui.input.Key, root_focus: *xitui.focus.Focus) !void {
        if (key == .mouse) {
            var iter = self.selectors.iterator();
            while (iter.next()) |selector| {
                if (inp.leftClickOn(root_focus, selector.value.*, key.mouse)) {
                    self.selected = selector.key;
                    return;
                }
            }
        }
        const current = self.box.getFocus().child_id orelse return;
        const text_input = self.field();
        if (current == text_input.getFocus().id) {
            if (key == .arrow_left) {
                if (self.selectors.get(self.selected)) |id| {
                    root_focus.setFocus(id);
                    return;
                }
            }
            return text_input.input(allocator, key, root_focus);
        }

        var iter = self.selectors.iterator();
        var previous: ?Kind = null;
        while (iter.next()) |selector| {
            if (selector.value.* == current) {
                self.selected = selector.key;
                break;
            }
            previous = selector.key;
        } else return;
        switch (key) {
            .arrow_left => if (previous) |kind| {
                self.selected = kind;
                root_focus.setFocus(self.selectors.get(kind) orelse return);
            },
            .arrow_right => if (iter.next()) |next| {
                self.selected = next.key;
                root_focus.setFocus(next.value.*);
            } else if (self.selected == .branch) root_focus.setFocus(text_input.getFocus().id),
            .enter => if (self.selected == .branch) root_focus.setFocus(text_input.getFocus().id),
            else => {},
        }
    }
};

// how many patches one window shows before a "next" link appears.
pub const page_size = 20;

// how many tags the tags view shows at most.
pub const max_tags = 1000;

// one patch from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const PatchWithId = struct {
    id: []const u8,
    record: evt.Patch.Record,
    // the creation commit's author
    author: ui.Author = .unknown,
    // whether the patch has an unresolved merge conflict
    conflicted: bool = false,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
    draft: bool = false,
    revision_oid: []const u8 = "",
    base_oid: []const u8 = "",
    commit_count: ?u64 = null,
    no_changes: bool = false,
    fork_exists: bool = false,
    mergeability: pch.Mergeability = .{},
};

pub const Entry = PatchWithId;

// one side of a conflicted field: its value and who set it
pub const Side = struct {
    text: []const u8,
    author: ui.Author = .unknown,
};

pub const FieldConflict = struct {
    ours: Side,
    theirs: Side,
};

// the selected patch's conflict, read for the resolve view. ours is the live
// record; the chunks split the description against the merge base.
pub const Conflict = struct {
    title: ?FieldConflict = null,
    tags: ?FieldConflict = null,
    status: ?FieldConflict = null,
    revision: ?FieldConflict = null,
    target_branch: ?FieldConflict = null,
    description: ?struct {
        chunks: []const diff3.Chunk,
        ours_author: ui.Author = .unknown,
        theirs_author: ui.Author = .unknown,
    } = null,
};

// one status's windowed listing.
pub const Window = struct {
    items: []const PatchWithId,
    // the id of the previous window's first patch, or null when this window
    // is already the first.
    prev_id: ?[]const u8,
    // the id of the next window's first patch, or null when this is the last
    // window.
    next_id: ?[]const u8,
    // how many patches the listing holds across all windows.
    count: usize,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

// "owner/name", so the view can build /repo/owner/name/patches/... links.
identity: []const u8,
default_target_branch: []const u8 = "",
// the url-encoded tag the lists are filtered to ("" = unfiltered).
tag: []const u8,
// the hex event id of the patch its status's window is rooted at ("" = the
// first window), mirrored into the url.
selected_id: []const u8,
// the comment shown in the selected patch's detail pane.
comment_id: []const u8,
// the selected patch's comment window (0 = the first window).
comments_start: usize,
// the selected comment and its immediate replies.
comment_page: ?Comment.Permalink = null,
open: Window,
closed: Window,
merged: Window,
drafts: Window,
// the conflicted patches' listing; its count also gates the conflicts tab.
conflicts: Window,
// the selected patch's conflict, set when the page shows the resolve view.
conflict: ?Conflict = null,
// the resolve view's comma-separated fields prefilled from their side,
// mirrored from the url.
theirs_picks: []const u8 = "",
// the view the page shows initially (a selected patch's status overrides the route's)
view: ui.RoutablePage.PatchesView,
// the /description page: the detail pane shows the selected patch's whole
// description behind a back link.
description_page: bool = false,
// every tag in the repo, in sorted order, for the tags view.
tags: []const []const u8,
// the on-disk repo this page was read from, for the terminal submit path
// (the web posts the new-patch form to the patch route instead).
repo_source: ?ui.RepoSource = null,
repo_id: ?[evt.event_id_size]u8 = null,

const Self = @This();

pub const Event = evt.Patch;
pub const Status = evt.Patch.StatusKind;
pub const ViewKind = ui.RoutablePage.PatchesView;
pub const thread_name = "patch";
pub const header_widget_name = "repo_patches_header";

pub fn statusKind(event: Event) Status {
    return event.status.kind();
}

pub fn listRoute(identity: []const u8, status: Status, tag: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesRoute(identity, status, tag, selected);
}

pub fn commitsRoute(allocator: std.mem.Allocator, identity: []const u8, entry: PatchWithId) !?ui.RoutablePage {
    if (entry.fork_exists and entry.record.event.status.kind() != .merged)
        return ui.RoutablePage.forkCommitsRoute(identity, entry.id, "", 0, "") orelse error.RouteTooLong;
    if (entry.revision_oid.len == 0 or entry.base_oid.len == 0) return null;
    // open patches follow the source branch; closed and merged patches keep their recorded revision
    if (entry.record.event.status.kind() == .open) if (entry.record.event.source_branch) |branch| {
        const encoded = try ui.urlEncodeRef(allocator, branch);
        defer allocator.free(encoded);
        return ui.RoutablePage.repoCommitsRoute(identity, .branch, encoded, 0, "", entry.base_oid) orelse error.RouteTooLong;
    };
    return ui.RoutablePage.repoCommitsRoute(identity, .object, entry.revision_oid, 0, "", entry.base_oid) orelse error.RouteTooLong;
}

pub fn draftsRoute(identity: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesDraftsRoute(identity);
}

pub fn conflictsRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesConflictsRoute(identity, selected);
}

pub fn resolveRoute(identity: []const u8, selected: []const u8, picks: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesResolveRoute(identity, selected, picks);
}

pub fn publishRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchPublishRoute(identity, selected);
}

pub fn mergeRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchMergeRoute(identity, selected);
}

pub fn canMerge(entry: Entry, session: *const ui.Session) bool {
    return !entry.draft and
        (entry.fork_exists or entry.record.event.source_branch != null) and
        !entry.conflicted and
        entry.record.event.revision != null and
        entry.record.event.status.kind() == .open and
        session.data.host_kind == .server and
        session.data.user_id != null;
}

pub fn create(
    data: *const Self,
    session: *ui.Session,
    allocator: std.mem.Allocator,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
    target_branch: []const u8,
    source_branch: ?[]const u8,
) ![evt.event_id_size * 2]u8 {
    if (!evt.Patch.fieldsValid(title, tags)) return error.InvalidFields;
    const io = session.io orelse return error.NotFound;
    const repo_source = data.repo_source orelse return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;
    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    if (source_branch) |branch| {
        switch (repo_source.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, repo_source.localInitOpts());
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| try pch.writeBranchPatch(session.data.host_kind, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{
                        .title = title,
                        .tags = tags,
                        .description = description,
                        .target_branch = target_branch,
                        .source_branch = branch,
                    }, null, author),
                }
            },
        }
        return id;
    }
    if (session.data.host_kind == .local) return error.InvalidSourceBranch;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const user_id = session.userId() orelse return error.NotFound;
    const repo_id = data.repo_id orelse return error.NotFound;
    if (!evt.Patch.branchValid(target_branch) or !try repo_source.hasBranch(io, allocator, target_branch)) return error.InvalidTargetBranch;
    const fork_path = try fork.create(.{}, io, allocator, repos_dir, admin_repo, .{
        .id = id,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = title,
        .description = description,
        .tags = tags,
        .target_branch = target_branch,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
    allocator.free(fork_path);
    return id;
}

pub fn publishDraft(data: *const Self, session: *ui.Session, allocator: std.mem.Allocator, id: []const u8) !void {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const repo_source = data.repo_source orelse return error.NotFound;
    const repo_id = data.repo_id orelse return error.NotFound;
    const user_id = session.userId() orelse return error.NotFound;
    const patch_id = evt.parseEventId(id) catch return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;

    const id_hex = std.fmt.bytesToHex(patch_id, .lower);
    const fork_path = try fork.forkPath(allocator, repos_dir, &id_hex);
    defer allocator.free(fork_path);

    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, repo_source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    try pch.publish(.{}, io, allocator, admin_repo, &target_repo, fork_path, .{
        .id = id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
}

pub fn mergePatch(data: *const Self, session: *ui.Session, allocator: std.mem.Allocator, id: []const u8, revision: evt.Patch.MergeRevision) !void {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const repo_source = data.repo_source orelse return error.NotFound;
    if (repo_source.repo_kind != .xit) return error.NotFound;
    const patch_id = evt.parseEventId(id) catch return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;

    const id_hex = std.fmt.bytesToHex(patch_id, .lower);
    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, repo_source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    try pch.mergeAndRemoveFork(.{}, io, allocator, repos_dir, admin_repo, &target_repo, .{
        .id = id_hex,
        .revision = revision,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
}

pub fn editDraft(
    data: *const Self,
    session: *ui.Session,
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
    target_branch: []const u8,
) !void {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const repo_id = data.repo_id orelse return error.NotFound;
    const repo_source = data.repo_source orelse return error.NotFound;
    const user_id = session.userId() orelse return error.NotFound;
    const patch_id = evt.parseEventId(id) catch return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;
    if (!evt.Patch.branchValid(target_branch) or !try repo_source.hasBranch(io, allocator, target_branch)) return error.InvalidTargetBranch;

    const id_hex = std.fmt.bytesToHex(patch_id, .lower);
    const fork_path = try fork.forkPath(allocator, repos_dir, &id_hex);
    defer allocator.free(fork_path);
    if (!try pch.editDraft(.{}, io, allocator, admin_repo, fork_path, .{
        .id = id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = title,
        .tags = tags,
        .description = description,
        .target_branch = target_branch,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    })) return error.NotFound;
}

pub fn removeDraft(session: *ui.Session, allocator: std.mem.Allocator, id: *const [evt.event_id_size]u8) !void {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const user_id = session.userId() orelse return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;

    const id_hex = std.fmt.bytesToHex(id.*, .lower);
    try fork.remove(io, allocator, repos_dir, admin_repo, &id_hex, &user_id, author);
}

// `status`'s windowed listing.
pub fn window(self: *const Self, status: Status) *const Window {
    return switch (status) {
        .open => &self.open,
        .closed => &self.closed,
        .merged => &self.merged,
    };
}

// whether `field` (a field name or "d<n>" hunk name) is listed in the url's
// theirs: picks.
pub fn theirsPicked(self: *const Self, field: []const u8) bool {
    var it = std.mem.splitScalar(u8, self.theirs_picks, ',');
    while (it.next()) |pick| {
        if (std.mem.eql(u8, pick, field)) return true;
    }
    return false;
}

// the patch `selected_id` names, in whichever window holds it.
pub fn selectedThread(self: *const Self) ?*const PatchWithId {
    if (self.selected_id.len == 0) return null;
    for ([_]*const Window{ &self.open, &self.closed, &self.merged, &self.drafts }) |win| {
        for (win.items) |*entry| {
            if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
        }
    }
    return null;
}

// an empty listing, for the wasm / no-repo paths.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, tag: []const u8, selected_id: []const u8, comment_id: []const u8, comments_start: usize, theirs_picks: []const u8, view: ui.RoutablePage.PatchesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .default_target_branch = "",
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .open = .empty,
        .closed = .empty,
        .merged = .empty,
        .drafts = .empty,
        .conflicts = .empty,
        .theirs_picks = try aa.dupe(u8, theirs_picks),
        // a description url shows a status list, the patch's own status
        // picking it once the patch is read; conflicts and resolve urls also
        // start there, upgraded by init when the conflict data exists.
        .view = switch (view) {
            .description, .conflicts, .resolve => .open,
            else => view,
        },
        .description_page = view == .description,
        .tags = &.{},
    };
}

pub fn detailResult(aa: std.mem.Allocator, identity: []const u8, entry: PatchWithId) !Self {
    var result = try emptyResult(aa, identity, "", entry.id, "", 0, "", .open);
    const items = try aa.dupe(PatchWithId, &.{entry});
    const detail_window = Window{ .items = items, .prev_id = null, .next_id = null, .count = 1 };
    if (entry.draft) {
        result.drafts = detail_window;
        result.view = .drafts;
    } else switch (entry.record.event.status) {
        .open => result.open = detail_window,
        .closed => {
            result.closed = detail_window;
            result.view = .closed;
        },
        .merged => {
            result.merged = detail_window;
            result.view = .merged;
        },
    }
    return result;
}

// read one window per status of an opened repo's patches (filtered to `tag`
// when set), ordered by creation (newest first). the window of the patch
// `selected_id` names starts at it ("" = the beginning). a git repo reads the
// event db next to it (synced from the events branch on each page build); a
// xit repo reads its own db.
pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    // the admin db's moment, for resolving author emails to user names (null
    // in local mode, which has no users)
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    session: *ui.Session,
    repo_id_maybe: ?[evt.event_id_size]u8,
    identity: []const u8,
    target_branch: []const u8,
    tag: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    theirs_picks: []const u8,
    view: ui.RoutablePage.PatchesView,
) !Self {
    const allowed_view: ui.RoutablePage.PatchesView = if (session.local != null and view == .drafts) .open else view;
    var empty = try emptyResult(arena.allocator(), identity, tag, selected_id, comment_id, comments_start, theirs_picks, allowed_view);
    empty.default_target_branch = try arena.allocator().dupe(u8, target_branch);

    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const rooted = empty.selected_id.len != 0;
    const tagged = empty.tag.len != 0;
    const drafts_window = if (admin_moment) |admin|
        if (repo_id_maybe) |repo_id|
            if (session.data.user_id != null and session.repos_dir != null)
                try loadDraftWindow(repo_kind, repo_opts, arena, session, admin, &repo_id, empty.selected_id, repo)
            else
                Window.empty
        else
            Window.empty
    else
        Window.empty;
    var draft_selected = false;
    if (rooted) for (drafts_window.items) |item| {
        if (std.mem.eql(u8, item.id, empty.selected_id)) {
            draft_selected = true;
            break;
        }
    };
    empty.drafts = drafts_window;
    if (draft_selected and view != .edit and view != .publish and view != .remove) empty.view = .drafts;

    // an explicitly named published patch that doesn't exist is a bad url
    // (NotFound -> 404); drafts, tags, and bare routes can use the empty fallback.
    const strict = rooted and !draft_selected;

    // a repo with no consumed events has no moment yet.
    const gpa = arena.child_allocator;
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return empty
    else
        evt.currentMoment(repo_opts, repo)) catch {
        if (strict) return error.NotFound;
        return empty;
    };

    // the sorted sets to window, per status: the tag's sets when filtered,
    // else the top-level per-status sets. a missing set is an empty window.
    var open_set: ?DB.SortedSet(.read_only) = null;
    var closed_set: ?DB.SortedSet(.read_only) = null;
    var merged_set: ?DB.SortedSet(.read_only) = null;
    if (tagged) {
        if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.tag_status_to_id_set_key))) |tag_to_patches_cursor| {
            const tag_to_patches = try DB.SortedMap(.read_only).init(tag_to_patches_cursor);
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, empty.tag));
            open_set = try thread.tagStatusSet(Self, DB, tag_to_patches, decoded, .open);
            closed_set = try thread.tagStatusSet(Self, DB, tag_to_patches, decoded, .closed);
            merged_set = try thread.tagStatusSet(Self, DB, tag_to_patches, decoded, .merged);
        }
    } else if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key))) |status_to_patches_cursor| {
        const status_to_patches = try DB.SortedMap(.read_only).init(status_to_patches_cursor);
        open_set = try thread.statusSet(Self, DB, status_to_patches, .open);
        closed_set = try thread.statusSet(Self, DB, status_to_patches, .closed);
        merged_set = try thread.statusSet(Self, DB, status_to_patches, .merged);
    } else if (strict) return error.NotFound;

    const event_id_to_patch_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.record_map_key)) orelse {
        if (strict) return error.NotFound;
        return empty;
    };
    const event_id_to_patch = try DB.HashMap(.read_only).init(event_id_to_patch_cursor);

    // the conflicted patches' container: a set view for membership and
    // windowing, a map view for the resolve entry, over the same cursor.
    var conflict_set: ?DB.SortedSet(.read_only) = null;
    var conflicts_map: ?DB.SortedMap(.read_only) = null;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.conflicts_key))) |cursor| {
        conflict_set = try DB.SortedSet(.read_only).init(cursor);
        conflicts_map = try DB.SortedMap(.read_only).init(cursor);
    }

    // a named patch roots its own status's window at itself (the conflicts
    // view's window instead); the other windows start at the beginning.
    var resolved_view = empty.view;
    var open_root: ?[]const u8 = null;
    var closed_root: ?[]const u8 = null;
    var merged_root: ?[]const u8 = null;
    var conflicts_root: ?[]const u8 = null;
    var conflict_data: ?Conflict = null;
    if (rooted and !draft_selected) {
        const id_bytes = evt.parseEventId(empty.selected_id) catch return error.NotFound;
        const patch_cursor = try event_id_to_patch.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
        const patch_map = try DB.HashMap(.read_only).init(patch_cursor);
        const patch_event = try evt.read(evt.Patch.Record, DB, repo_opts.hash, arena, patch_map);
        const order_key = try aa.dupe(u8, &evt.orderKeyDesc(patch_event.created_order, &id_bytes));

        if (view == .conflicts) {
            // the id roots the conflicts window, so it must be conflicted
            const set = conflict_set orelse return error.NotFound;
            if (!try set.contains(order_key)) return error.NotFound;
            conflicts_root = order_key;
        } else {
            // the named patch must be in its windowed set (a tag url can name
            // an patch that doesn't carry the tag).
            const set = (switch (patch_event.event.status) {
                .open => open_set,
                .closed => closed_set,
                .merged => merged_set,
            }) orelse return error.NotFound;
            if (!try set.contains(order_key)) return error.NotFound;

            switch (patch_event.event.status) {
                .open => open_root = order_key,
                .closed => closed_root = order_key,
                .merged => merged_root = order_key,
            }
            // form urls keep their view; otherwise the patch's status picks it.
            if (view != .edit and view != .merge and view != .new_comment and view != .edit_comment and view != .remove) resolved_view = switch (patch_event.event.status) {
                .open => .open,
                .closed => .closed,
                .merged => .merged,
            };

            // a resolve url shows the resolve view only while the patch still
            // has a conflict entry; otherwise the status list stands. the
            // wasm client renders from the snapshot, so the diff machinery
            // this pulls in is gated out of its build.
            if (comptime !wasm) {
                if (view == .resolve) {
                    if (conflicts_map) |map| {
                        if (try map.getCursor(order_key)) |conflict_cursor| {
                            const conflict_entry = try DB.HashMap(.read_only).init(conflict_cursor);
                            conflict_data = try thread.readConflict(Self, repo_kind, repo_opts, arena, repo, io, admin_moment, haxy_moment, &id_bytes, patch_event, conflict_entry);
                            resolved_view = .resolve;
                        }
                    }
                }
            }
        }
    }
    const thread_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    var open_window = try thread.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, open_set, open_root, conflict_set, empty.selected_id, thread_comments_start);
    var closed_window = try thread.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, closed_set, closed_root, conflict_set, empty.selected_id, thread_comments_start);
    var merged_window = try thread.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, merged_set, merged_root, conflict_set, empty.selected_id, thread_comments_start);
    var conflicts_window = try thread.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, conflict_set, conflicts_root, conflict_set, empty.selected_id, thread_comments_start);
    try setPatchDetails(repo_kind, repo_opts, io, arena, admin_moment, haxy_moment, repo, &open_window);
    try setPatchDetails(repo_kind, repo_opts, io, arena, admin_moment, haxy_moment, repo, &closed_window);
    try setPatchDetails(repo_kind, repo_opts, io, arena, admin_moment, haxy_moment, repo, &merged_window);
    try setPatchDetails(repo_kind, repo_opts, io, arena, admin_moment, haxy_moment, repo, &conflicts_window);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start);

    const tags = try thread.loadTags(Self, repo_opts.hash, arena, haxy_moment);

    return .{
        .identity = empty.identity,
        .default_target_branch = empty.default_target_branch,
        .tag = empty.tag,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .open = open_window,
        .closed = closed_window,
        .merged = merged_window,
        .drafts = drafts_window,
        .conflicts = conflicts_window,
        .conflict = conflict_data,
        .theirs_picks = empty.theirs_picks,
        .view = resolved_view,
        .description_page = empty.description_page,
        .tags = tags,
    };
}

fn setPatchDetails(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    repo: *rp.Repo(repo_kind, repo_opts),
    target: *Window,
) !void {
    if (target.items.len == 0) return;
    const items = try arena.allocator().dupe(PatchWithId, target.items);
    for (items) |*item| {
        const id = try evt.parseEventId(item.id);
        const status = item.record.event.status.kind();
        if (admin_moment) |moment| {
            const record = try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &id);
            item.fork_exists = if (record) |value| !value.removed else false;
        }
        const target_branch = item.record.event.target_branch;
        const revision = item.record.event.revision orelse continue;
        item.commit_count = revision.commit_count;
        const merge_revision: evt.Patch.MergeRevision = switch (item.record.event.status) {
            .merged => |merged| merged.revision,
            else => .source,
        };
        item.revision_oid = switch (merge_revision) {
            .source => revision.source_oid,
            .squash => revision.squash_oid,
        };
        if (!item.fork_exists or status == .merged) {
            const revision_id = try evt.parseEventId(&revision.id);
            if (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, haxy_moment, arena, &revision_id)) |record| {
                item.base_oid = record.event.base_oid;
            }
        }
        if (status == .merged) {
            if (merge_revision == .squash) item.commit_count = 1;
            continue;
        }
        if (comptime repo_kind == .xit) {
            var moment = try repo.core.latestMoment();
            const state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
            item.mergeability = pch.readMergeability(repo_opts, state, io, arena, &id, item.record.event) catch .{};
        }
        const target_oid = try repo.readRef(io, .{ .kind = .head, .name = target_branch });
        item.no_changes = if (target_oid) |oid| std.mem.eql(u8, &oid, revision.source_oid) else false;
    }
    target.items = items;
}

fn loadDraftWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    repo_id: *const [evt.event_id_size]u8,
    selected_id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !Window {
    const user_id = session.data.user_id orelse return .empty;
    if (user_id.len != evt.event_id_size) return .empty;
    const repos_dir = session.repos_dir orelse return .empty;
    const io = session.io orelse return .empty;
    const key = evt.Fork.draftKey(repo_id, user_id);
    const drafts_cursor = try admin_moment.getCursor(hash.hashInt(evt.admin_repo_opts.hash, evt.Fork.repo_user_to_draft_id_set_key)) orelse return .empty;
    const drafts = try evt.AdminDB.HashMap(.read_only).init(drafts_cursor);
    const set_cursor = try drafts.getCursor(hash.hashInt(evt.admin_repo_opts.hash, &key)) orelse return .empty;
    const set = try evt.AdminDB.SortedSet(.read_only).init(set_cursor);
    const aa = arena.allocator();

    var root_key: ?[]const u8 = null;
    if (selected_id.len != 0) {
        const id = evt.parseEventId(selected_id) catch return error.NotFound;
        if (try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, arena, &id)) |record| {
            if (!record.removed and record.event.stage == .draft) {
                const order_key = try aa.dupe(u8, &evt.orderKeyDesc(record.created_order, &id));
                if (!try set.contains(order_key)) return error.NotFound;
                root_key = order_key;
            }
        }
    }

    var prev_id: ?[]const u8 = null;
    var iter = if (root_key) |root| blk: {
        const rank = try set.rank(root);
        if (rank > 0 and rank <= page_size) {
            prev_id = "";
        } else if (rank > page_size) {
            const pair = try set.getIndexKeyValuePair(@intCast(rank - page_size)) orelse return error.NotFound;
            var previous: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try pair.key_cursor.readBytes(&previous);
            const hex = std.fmt.bytesToHex(previous[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &hex);
        }
        break :blk try set.iteratorFrom(root);
    } else try set.iteratorFromIndex(0);

    var items: std.ArrayList(PatchWithId) = .empty;
    var next_id: ?[]const u8 = null;
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(evt.AdminDB, cursor);
        const id_hex = std.fmt.bytesToHex(id, .lower);
        if (items.items.len == page_size) {
            next_id = try aa.dupe(u8, &id_hex);
            break;
        }
        const path = try fork.forkPath(aa, repos_dir, &id_hex);
        var fork_repo = rp.Repo(.xit, .{}).open(io, arena.child_allocator, .{ .path = path, .require_repo_root = true }) catch continue;
        defer fork_repo.deinit(io, arena.child_allocator);
        const entry = (try loadDraftEntry(repo_kind, repo_opts, arena, io, admin_moment, &fork_repo, target_repo, id)) orelse continue;
        try items.append(aa, entry);
    }
    return .{
        .items = items.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

pub fn loadDraftEntry(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    fork_repo: *rp.Repo(.xit, .{}),
    target_repo: *rp.Repo(repo_kind, repo_opts),
    id: [evt.event_id_size]u8,
) !?PatchWithId {
    const aa = arena.allocator();
    const id_hex = std.fmt.bytesToHex(id, .lower);
    const fork_oid = (try fork_repo.readRef(io, fork.ref)) orelse return null;
    const moment = evt.currentMoment(.{}, fork_repo) catch return null;
    const patch = (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, moment, arena, &id)) orelse return null;
    const target_branch = patch.event.target_branch;
    const target_oid = try target_repo.readRef(io, .{ .kind = .head, .name = target_branch });
    const commit_count: ?u64 = blk: {
        const newest = evt.PatchRev.readNewest(evt.EventDB(.sha1), .sha1, moment, arena) catch break :blk null;
        break :blk if (newest) |revision| revision.record.commit_count else 0;
    };
    return .{
        .id = try aa.dupe(u8, &id_hex),
        .record = patch,
        .author = try ui.Author.initFromEmail(admin_moment, arena, patch.author_email),
        .draft = true,
        .revision_oid = try aa.dupe(u8, &fork_oid),
        .commit_count = commit_count,
        .no_changes = if (target_oid) |oid| std.mem.eql(u8, &oid, &fork_oid) else false,
        .fork_exists = true,
    };
}

pub const View = thread.View(.patch, Self);
pub const Detail = thread.Detail(.patch, Self);
pub const detail_widget_name = "repo_patch_detail";

pub const Header = thread.Header;

pub fn appendDetails(self: *const Self, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, entry: Entry) !void {
    const aa = session.page_arena.allocator();
    const status_kind = entry.record.event.status.kind();
    const target_branch = entry.record.event.target_branch;

    if (status_kind != .merged and entry.fork_exists) if (session.data.git_ssh_port) |port| {
        const url = try std.fmt.allocPrint(aa, "ssh://localhost:{d}/fork/{s}/patch:{s}", .{ port, self.identity, entry.id });
        const push_command = try std.fmt.allocPrint(aa, "git push {s} HEAD:patch", .{url});
        const clone_name = try cloneDirectoryName(aa, entry.record.event.title);
        const clone_command = if (clone_name.len == 0)
            try std.fmt.allocPrint(aa, "git clone {s}", .{url})
        else
            try std.fmt.allocPrint(aa, "git clone {s} {s}", .{ url, clone_name });
        const merge_command = try std.fmt.allocPrint(aa, "git fetch '{s}' refs/heads/patch && git merge FETCH_HEAD", .{url});
        const choices: [3]ui.widget.CopyableText.Choice = .{
            .{
                .selector = "push",
                .text = push_command,
                .copyable_text = try std.fmt.allocPrint(aa, "{s}{s}", .{ session.data.git_ssh_prefix, push_command }),
                .label = " push to this patch from existing repo ",
            },
            .{
                .selector = "clone",
                .text = clone_command,
                .copyable_text = try std.fmt.allocPrint(aa, "{s}{s}", .{ session.data.git_ssh_prefix, clone_command }),
                .label = " clone this patch ",
            },
            .{
                .selector = "merge",
                .text = merge_command,
                .copyable_text = try std.fmt.allocPrint(aa, "{s}{s}", .{ session.data.git_ssh_prefix, merge_command }),
                .label = " merge this patch locally ",
            },
        };
        var copyable_text = try ui.widget.CopyableText.init(allocator, session, &choices);
        errdefer copyable_text.deinit(allocator);
        try box.children.put(allocator, copyable_text.getFocus().id, .{ .widget = .{ .copyable_text = copyable_text }, .rect = null, .min_size = null });
    };
    if (entry.record.event.source_branch) |branch| {
        var source = try wgt.TextBox.init(allocator, branch, .{ .label = " source branch ", .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer source.deinit(allocator);
        source.getFocus().mode = .all;
        try box.children.put(allocator, source.getFocus().id, .{ .widget = .{ .text_box = source }, .rect = null, .min_size = null });
    }
    const fields = [_]ui.widget.CopyableText.Choice{
        .{
            .selector = "from",
            .text = entry.revision_oid,
            .label = if (entry.no_changes) " object id of this patch (no changes) " else " object id of this patch ",
        },
        .{
            .selector = "to",
            .text = target_branch,
            .label = if (status_kind == .merged) " target branch this patch was merged into " else " target branch this patch will go to ",
        },
    };
    var copyable_text = try ui.widget.CopyableText.init(allocator, session, fields[@intFromBool(entry.revision_oid.len == 0)..]);
    errdefer copyable_text.deinit(allocator);
    try box.children.put(allocator, copyable_text.getFocus().id, .{ .widget = .{ .copyable_text = copyable_text }, .rect = null, .min_size = null });
}

fn cloneDirectoryName(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    var name: [64]u8 = undefined;
    var len: usize = 0;
    var pending: ?u8 = null;

    for (title) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            const needed: usize = if (pending == null) 1 else 2;
            if (len + needed > name.len) break;
            if (pending) |value| {
                name[len] = value;
                len += 1;
            }
            name[len] = std.ascii.toLower(char);
            len += 1;
            pending = null;
        } else if (char == ' ') {
            if (len != 0) pending = '-';
        } else if (char == '.') {
            if (len != 0 and pending != '-') pending = '.';
        }
    }
    if (len == 0) return "";
    return allocator.dupe(u8, name[0..len]);
}

// tabs switching between the patches page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    var header = try Header.init(allocator);
    errdefer header.deinit(allocator);
    const aa = session.page_arena.allocator();
    const selected_index = View.viewIndex(data.view);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_patches;

    // a list tab per status, labeled with its listing's patch count
    for ([_]Status{ .open, .closed, .merged }, 0..) |status, index| {
        const route = ui.RoutablePage.repoPatchesRoute(data.identity, status, data.tag, "") orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == index);
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{s} ({d})", .{ @tagName(status), data.window(status).count });
        try header.addTab(allocator, label, link, index);
    }

    // tags tab, labeled with the active tag filter
    {
        const tags_route = ui.RoutablePage.repoThreadTagsRoute(.patch, data.identity, data.tag) orelse return error.RouteTooLong;
        const tags_link = try ui.inPageTabLink(session, tags_route, page_selected and selected_index == View.viewIndex(.tags));
        const label = if (data.tag.len == 0) "tags" else blk: {
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
            break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
        };
        try header.addTab(allocator, label, tags_link, View.viewIndex(.tags));
    }

    // new-patch tab; an edit or resolve url shows its tab in this place
    {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.patch, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .publish => ui.RoutablePage.repoPatchPublishRoute(data.identity, data.selected_id) orelse return error.RouteTooLong,
            .merge => ui.RoutablePage.repoPatchMergeRoute(data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .resolve => ui.RoutablePage.repoPatchesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.patch, data.identity) orelse return error.RouteTooLong,
        };
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.new));
        const label: []const u8 = switch (data.view) {
            .edit => "edit",
            .publish => "publish",
            .merge => "merge",
            .new_comment => "reply",
            .edit_comment => "edit",
            .remove => "remove",
            .resolve => "resolve",
            else => "new",
        };
        try header.addTab(allocator, label, link, View.viewIndex(.new));
    }

    // drafts belong to the logged-in user and are not available locally
    if (session.data.host_kind != .local) {
        const route = ui.RoutablePage.repoPatchesDraftsRoute(data.identity) orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.drafts));
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "drafts ({d})", .{data.drafts.count});
        try header.addTab(allocator, label, link, View.viewIndex(.drafts));
    }

    // conflicts tab, labeled with the conflict count
    if (data.conflicts.count > 0) {
        const route = ui.RoutablePage.repoPatchesConflictsRoute(data.identity, "") orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.conflicts));
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "conflicts ({d})", .{data.conflicts.count});
        try header.addTab(allocator, label, link, View.viewIndex(.conflicts));
    }

    header.select(View.viewIndex(data.view));
    return header;
}

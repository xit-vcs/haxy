const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const diff3 = @import("../../diff3.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const Threads = @import("Threads.zig");
const fork = @import("../../fork.zig");
const pch = @import("../../patch.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

// how much of a description the detail pane shows before linking to the
// /description page, the same limit commit messages use.
pub const max_description_size = 2 * 1024;

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
    revision_ready: bool = false,
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
target_branch: []const u8 = "",

const Self = @This();

pub const Event = evt.Patch;
pub const Status = evt.Patch.Status;
pub const ViewKind = ui.RoutablePage.PatchesView;

pub fn createDraft(
    data: *const Self,
    session: *ui.Session,
    allocator: std.mem.Allocator,
    title: []const u8,
    tags: []const u8,
    description: []const u8,
) ![evt.event_id_size * 2]u8 {
    if (!evt.Patch.fieldsValid(title, tags)) return error.InvalidFields;
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const user_id_slice = session.data.user_id orelse return error.NotFound;
    if (user_id_slice.len != evt.event_id_size) return error.NotFound;
    const repo_id = data.repo_id orelse return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;
    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    var user_id: [evt.event_id_size]u8 = undefined;
    @memcpy(&user_id, user_id_slice);
    const path = try fork.create(.{}, io, allocator, repos_dir, admin_repo, .{
        .id = id,
        .user_id = user_id,
        .repo_id = repo_id,
        .title = title,
        .description = description,
        .tags = tags,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
    allocator.free(path);
    return id;
}

pub fn postDraft(data: *const Self, session: *ui.Session, allocator: std.mem.Allocator, id: []const u8) !void {
    const io = session.io orelse return error.NotFound;
    const repos_dir = session.repos_dir orelse return error.NotFound;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const repo_source = data.repo_source orelse return error.NotFound;
    const repo_id = data.repo_id orelse return error.NotFound;
    const user_id_slice = session.data.user_id orelse return error.NotFound;
    if (user_id_slice.len != evt.event_id_size) return error.NotFound;
    const patch_id = evt.parseEventId(id) catch return error.NotFound;
    const author = (try session.eventAuthor()) orelse return error.NotFound;

    var user_id: [evt.event_id_size]u8 = undefined;
    @memcpy(&user_id, user_id_slice);
    const id_hex = std.fmt.bytesToHex(patch_id, .lower);
    const fork_path = try fork.forkPath(allocator, repos_dir, &id_hex);
    defer allocator.free(fork_path);

    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, repo_source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    try pch.post(.{}, io, allocator, admin_repo, &target_repo, fork_path, .{
        .id = id_hex,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
}

// `status`'s windowed listing.
pub fn window(self: *const Self, status: evt.Patch.Status) *const Window {
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
    tag: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    theirs_picks: []const u8,
    view: ui.RoutablePage.PatchesView,
) !Self {
    const allowed_view: ui.RoutablePage.PatchesView = if (session.local != null and (view == .new or view == .drafts)) .open else view;
    var empty = try emptyResult(arena.allocator(), identity, tag, selected_id, comment_id, comments_start, theirs_picks, allowed_view);

    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const rooted = empty.selected_id.len != 0;
    const tagged = empty.tag.len != 0;
    const drafts_window = if (admin_moment) |admin|
        if (repo_id_maybe) |repo_id|
            if (session.data.user_id != null and session.repos_dir != null)
                try loadDraftWindow(arena, session, admin, &repo_id, empty.selected_id)
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
    if (draft_selected) empty.view = .drafts;

    // an explicitly named posted patch or tag that doesn't exist is a bad url
    // (NotFound -> 404); drafts and bare routes can use the empty fallback.
    const strict = tagged or (rooted and !draft_selected);

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
        const tag_to_patches_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.tag_status_to_id_set_key)) orelse return error.NotFound;
        const tag_to_patches = try DB.SortedMap(.read_only).init(tag_to_patches_cursor);
        const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, empty.tag));
        open_set = try Threads.tagStatusSet(Self, DB, tag_to_patches, decoded, .open);
        closed_set = try Threads.tagStatusSet(Self, DB, tag_to_patches, decoded, .closed);
        merged_set = try Threads.tagStatusSet(Self, DB, tag_to_patches, decoded, .merged);
        // a tag no patch carries is a bad url
        if (open_set == null and closed_set == null and merged_set == null) return error.NotFound;
    } else if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Patch.status_to_id_set_key))) |status_to_patches_cursor| {
        const status_to_patches = try DB.SortedMap(.read_only).init(status_to_patches_cursor);
        open_set = try Threads.statusSet(Self, DB, status_to_patches, .open);
        closed_set = try Threads.statusSet(Self, DB, status_to_patches, .closed);
        merged_set = try Threads.statusSet(Self, DB, status_to_patches, .merged);
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
            if (view != .edit and view != .new_comment and view != .edit_comment and view != .remove) resolved_view = switch (patch_event.event.status) {
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
                            conflict_data = try Threads.readConflict(Self, repo_kind, repo_opts, arena, repo, io, admin_moment, haxy_moment, &id_bytes, patch_event, conflict_entry);
                            resolved_view = .resolve;
                        }
                    }
                }
            }
        }
    }
    const thread_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const open_window = try Threads.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, open_set, open_root, conflict_set, empty.selected_id, thread_comments_start);
    const closed_window = try Threads.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, closed_set, closed_root, conflict_set, empty.selected_id, thread_comments_start);
    const merged_window = try Threads.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, merged_set, merged_root, conflict_set, empty.selected_id, thread_comments_start);
    const conflicts_window = try Threads.loadWindow(Self, repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_patch, conflict_set, conflicts_root, conflict_set, empty.selected_id, thread_comments_start);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start);

    const tags = try Threads.loadTags(Self, repo_opts.hash, arena, haxy_moment);

    return .{
        .identity = empty.identity,
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

fn loadDraftWindow(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    repo_id: *const [evt.event_id_size]u8,
    selected_id: []const u8,
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
        const moment = evt.currentMoment(.{}, &fork_repo) catch continue;
        const patch = (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, moment, arena, &id)) orelse continue;
        var revision_ready = false;
        if (patch.event.revision) |revision| {
            const revision_id = evt.parseEventId(&revision.id) catch continue;
            if (try evt.PatchRev.readById(evt.EventDB(.sha1), .sha1, moment, arena, &revision_id)) |record|
                revision_ready = revision.matches(record);
        }
        try items.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .record = patch,
            .author = try ui.Author.initFromEmail(admin_moment, arena, patch.author_email),
            .draft = true,
            .revision_ready = revision_ready,
        });
    }
    return .{
        .items = items.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

pub const View = Threads.View(.patch, Self);

pub const Header = Threads.Header;

// tabs switching between the patches page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    var header = try Header.init(allocator);
    errdefer header.deinit(allocator);
    const aa = session.page_arena.allocator();

    // a list tab per status, labeled with its listing's patch count
    for ([_]evt.Patch.Status{ .open, .closed, .merged }, 0..) |status, index| {
        const route = ui.RoutablePage.repoPatchesRoute(data.identity, status, data.tag, "") orelse return error.RouteTooLong;
        const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{s} ({d})", .{ @tagName(status), data.window(status).count });
        try header.addTab(allocator, label, link, index);
    }

    // tags tab, labeled with the active tag filter
    {
        const tags_route = ui.RoutablePage.repoThreadTagsRoute(.patch, data.identity, data.tag) orelse return error.RouteTooLong;
        const tags_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try tags_route.toUrl(session.page_arena)});
        const label = if (data.tag.len == 0) "tags" else blk: {
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
            break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
        };
        try header.addTab(allocator, label, tags_link, View.viewIndex(.tags));
    }

    // new-patch tab; an edit or resolve url shows its tab in this place
    if (session.local == null) {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.patch, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .resolve => ui.RoutablePage.repoPatchesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.patch, data.identity) orelse return error.RouteTooLong,
        };
        const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
        const label: []const u8 = switch (data.view) {
            .edit => "edit",
            .new_comment => "reply",
            .edit_comment => "edit",
            .remove => "remove",
            .resolve => "resolve",
            else => "new",
        };
        try header.addTab(allocator, label, link, View.viewIndex(.new));
    }

    // drafts belong to the logged-in user and are not available locally
    if (session.local == null) {
        const route = ui.RoutablePage.repoPatchesDraftsRoute(data.identity) orelse return error.RouteTooLong;
        const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "drafts ({d})", .{data.drafts.count});
        try header.addTab(allocator, label, link, View.viewIndex(.drafts));
    }

    // conflicts tab, labeled with the conflict count
    if (data.conflicts.count > 0) {
        const route = ui.RoutablePage.repoPatchesConflictsRoute(data.identity, "") orelse return error.RouteTooLong;
        const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "conflicts ({d})", .{data.conflicts.count});
        try header.addTab(allocator, label, link, View.viewIndex(.conflicts));
    }

    header.select(View.viewIndex(data.view));
    return header;
}

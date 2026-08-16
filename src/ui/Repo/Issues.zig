const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");
const diff3 = @import("../../diff3.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const Threads = @import("Threads.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

// how much of a description the detail pane shows before linking to the
// /description page, the same limit commit messages use.
pub const max_description_size = 2 * 1024;

// how many issues one window shows before a "next" link appears.
pub const page_size = 20;

// how many tags the tags view shows at most.
pub const max_tags = 1000;

// one issue from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const IssueWithId = struct {
    id: []const u8,
    record: evt.Issue.Record,
    // the creation commit's author
    author: ui.Author = .unknown,
    // whether the issue has an unresolved merge conflict
    conflicted: bool = false,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
};

pub const Entry = IssueWithId;

// one side of a conflicted field: its value and who set it
pub const Side = struct {
    text: []const u8,
    author: ui.Author = .unknown,
};

pub const FieldConflict = struct {
    ours: Side,
    theirs: Side,
};

// the selected issue's conflict, read for the resolve view. ours is the live
// record; the chunks split the description against the merge base.
pub const Conflict = struct {
    title: ?FieldConflict = null,
    tags: ?FieldConflict = null,
    description: ?struct {
        chunks: []const diff3.Chunk,
        ours_author: ui.Author = .unknown,
        theirs_author: ui.Author = .unknown,
    } = null,
};

// one status's windowed listing.
pub const Window = struct {
    items: []const IssueWithId,
    // the id of the previous window's first issue, or null when this window
    // is already the first.
    prev_id: ?[]const u8,
    // the id of the next window's first issue, or null when this is the last
    // window.
    next_id: ?[]const u8,
    // how many issues the listing holds across all windows.
    count: usize,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

// "owner/name", so the view can build /repo/owner/name/issues/... links.
identity: []const u8,
// the url-encoded tag the lists are filtered to ("" = unfiltered).
tag: []const u8,
// the hex event id of the issue its status's window is rooted at ("" = the
// first window), mirrored into the url.
selected_id: []const u8,
// the comment shown in the selected issue's detail pane.
comment_id: []const u8,
// the selected issue's comment window (0 = the first window).
comments_start: usize,
// the selected comment and its immediate replies.
comment_page: ?Comment.Permalink = null,
open: Window,
closed: Window,
// the conflicted issues' listing; its count also gates the conflicts tab.
conflicts: Window,
// the selected issue's conflict, set when the page shows the resolve view.
conflict: ?Conflict = null,
// the resolve view's comma-separated fields prefilled from their side,
// mirrored from the url.
theirs_picks: []const u8 = "",
// the view the page shows initially (a selected issue's status overrides the route's)
view: ui.RoutablePage.IssuesView,
// the /description page: the detail pane shows the selected issue's whole
// description behind a back link.
description_page: bool = false,
// every tag in the repo, in sorted order, for the tags view.
tags: []const []const u8,
// the on-disk repo this page was read from, for the terminal submit path
// (the web posts the new-issue form to the issue route instead).
repo_source: ?ui.RepoSource = null,

const Self = @This();

pub const Event = evt.Issue;
pub const Status = evt.Issue.Status;
pub const ViewKind = ui.RoutablePage.IssuesView;

// `status`'s windowed listing.
pub fn window(self: *const Self, status: evt.Issue.Status) *const Window {
    return switch (status) {
        .open => &self.open,
        .closed => &self.closed,
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

// the issue `selected_id` names, in whichever window holds it.
pub fn selectedThread(self: *const Self) ?*const IssueWithId {
    if (self.selected_id.len == 0) return null;
    for ([_]*const Window{ &self.open, &self.closed }) |win| {
        for (win.items) |*entry| {
            if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
        }
    }
    return null;
}

// an empty listing, for the wasm / no-repo paths.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, tag: []const u8, selected_id: []const u8, comment_id: []const u8, comments_start: usize, theirs_picks: []const u8, view: ui.RoutablePage.IssuesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .open = .empty,
        .closed = .empty,
        .conflicts = .empty,
        .theirs_picks = try aa.dupe(u8, theirs_picks),
        // a description url shows a status list, the issue's own status
        // picking it once the issue is read; conflicts and resolve urls also
        // start there, upgraded by init when the conflict data exists.
        .view = switch (view) {
            .description, .conflicts, .resolve => .open,
            else => view,
        },
        .description_page = view == .description,
        .tags = &.{},
    };
}

// read one window per status of an opened repo's issues (filtered to `tag`
// when set), ordered by creation time (newest first). the window of the issue
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
    identity: []const u8,
    tag: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    theirs_picks: []const u8,
    view: ui.RoutablePage.IssuesView,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, selected_id, comment_id, comments_start, theirs_picks, view);

    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const rooted = empty.selected_id.len != 0;
    const tagged = empty.tag.len != 0;
    // an explicitly named issue or tag that doesn't exist is a bad url
    // (NotFound -> 404); the bare route falls through to an empty listing.
    const strict = rooted or tagged;

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
    if (tagged) {
        const tag_to_issues_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "tag+status->issue-id-set")) orelse return error.NotFound;
        const tag_to_issues = try DB.SortedMap(.read_only).init(tag_to_issues_cursor);
        const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, empty.tag));
        open_set = try tagStatusSet(DB, tag_to_issues, decoded, .open);
        closed_set = try tagStatusSet(DB, tag_to_issues, decoded, .closed);
        // a tag no issue carries is a bad url
        if (open_set == null and closed_set == null) return error.NotFound;
    } else if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "status->issue-id-set"))) |status_to_issues_cursor| {
        const status_to_issues = try DB.SortedMap(.read_only).init(status_to_issues_cursor);
        open_set = try statusSet(DB, status_to_issues, .open);
        closed_set = try statusSet(DB, status_to_issues, .closed);
    } else if (rooted) return error.NotFound;

    const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse {
        if (strict) return error.NotFound;
        return empty;
    };
    const event_id_to_issue = try DB.HashMap(.read_only).init(event_id_to_issue_cursor);

    // the conflicted issues' container: a set view for membership and
    // windowing, a map view for the resolve entry, over the same cursor.
    var conflict_set: ?DB.SortedSet(.read_only) = null;
    var conflicts_map: ?DB.SortedMap(.read_only) = null;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Issue.conflicts_key))) |cursor| {
        conflict_set = try DB.SortedSet(.read_only).init(cursor);
        conflicts_map = try DB.SortedMap(.read_only).init(cursor);
    }

    // a named issue roots its own status's window at itself (the conflicts
    // view's window instead); the other windows start at the beginning.
    var resolved_view = empty.view;
    var open_root: ?[]const u8 = null;
    var closed_root: ?[]const u8 = null;
    var conflicts_root: ?[]const u8 = null;
    var conflict_data: ?Conflict = null;
    if (rooted) {
        if (empty.selected_id.len != evt.event_id_size * 2) return error.NotFound;
        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id_bytes, empty.selected_id) catch return error.NotFound;
        const issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
        const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
        const issue_event = try evt.read(evt.Issue.Record, DB, repo_opts.hash, arena, issue_map);
        const order_key = try aa.dupe(u8, &evt.orderKeyDesc(issue_event.created_ts, &id_bytes));

        if (view == .conflicts) {
            // the id roots the conflicts window, so it must be conflicted
            const set = conflict_set orelse return error.NotFound;
            if (!try set.contains(order_key)) return error.NotFound;
            conflicts_root = order_key;
        } else {
            // the named issue must be in its windowed set (a tag url can name
            // an issue that doesn't carry the tag).
            const set = (switch (issue_event.event.status) {
                .open => open_set,
                .closed => closed_set,
            }) orelse return error.NotFound;
            if (!try set.contains(order_key)) return error.NotFound;

            switch (issue_event.event.status) {
                .open => open_root = order_key,
                .closed => closed_root = order_key,
            }
            // form urls keep their view; otherwise the issue's status picks it.
            if (view != .edit and view != .new_comment and view != .edit_comment and view != .remove) resolved_view = switch (issue_event.event.status) {
                .open => .open,
                .closed => .closed,
            };

            // a resolve url shows the resolve view only while the issue still
            // has a conflict entry; otherwise the status list stands. the
            // wasm client renders from the snapshot, so the diff machinery
            // this pulls in is gated out of its build.
            if (comptime !wasm) {
                if (view == .resolve) {
                    if (conflicts_map) |map| {
                        if (try map.getCursor(order_key)) |conflict_cursor| {
                            const conflict_entry = try DB.HashMap(.read_only).init(conflict_cursor);
                            conflict_data = try readConflict(repo_kind, repo_opts, arena, repo, io, admin_moment, haxy_moment, &id_bytes, issue_event, conflict_entry);
                            resolved_view = .resolve;
                        }
                    }
                }
            }
        }
    }

    const thread_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const open_window = try loadWindow(repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_issue, open_set, open_root, conflict_set, empty.selected_id, thread_comments_start);
    const closed_window = try loadWindow(repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_issue, closed_set, closed_root, conflict_set, empty.selected_id, thread_comments_start);
    const conflicts_window = try loadWindow(repo_opts.hash, arena, admin_moment, haxy_moment, event_id_to_issue, conflict_set, conflicts_root, conflict_set, empty.selected_id, thread_comments_start);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start);

    // every tag in the repo, in the tag map's sorted order. the keys are
    // "tag,status", so a tag's entries are adjacent and dedup by prefix.
    var tags: std.ArrayList([]const u8) = .empty;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "tag+status->issue-id-set"))) |tag_to_issues_cursor| {
        const tag_to_issues = try DB.SortedMap(.read_only).init(tag_to_issues_cursor);
        var tag_iter = try tag_to_issues.iterator();
        while (try tag_iter.next()) |kv_pair_cursor| {
            if (tags.items.len == max_tags) break;
            var kv_cursor = kv_pair_cursor;
            const kv_pair = try kv_cursor.readKeyValuePair();
            const key = try kv_pair.key_cursor.readBytesAlloc(aa, null);
            const space = std.mem.indexOfScalar(u8, key, ' ') orelse continue;
            const key_tag = key[0..space];
            if (tags.getLastOrNull()) |last| {
                if (std.mem.eql(u8, last, key_tag)) continue;
            }
            try tags.append(aa, key_tag);
        }
    }

    return .{
        .identity = empty.identity,
        .tag = empty.tag,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .open = open_window,
        .closed = closed_window,
        .conflicts = conflicts_window,
        .conflict = conflict_data,
        .theirs_picks = empty.theirs_picks,
        .view = resolved_view,
        .description_page = empty.description_page,
        .tags = tags.items,
    };
}

// `status`'s sorted set within `statuses` (null when the status has no issues)
fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_only),
    status: evt.Issue.Status,
) !?DB.SortedSet(.read_only) {
    const cursor = (try statuses.getCursor(@tagName(status))) orelse return null;
    return try DB.SortedSet(.read_only).init(cursor);
}

// the set at `tag_to_issues`'s "tag,status" key (null when no issue carries
// `tag` with `status`, or the tag is too long to exist)
fn tagStatusSet(
    comptime DB: type,
    tag_to_issues: DB.SortedMap(.read_only),
    tag: []const u8,
    status: evt.Issue.Status,
) !?DB.SortedSet(.read_only) {
    var key_buffer: evt.Issue.TagStatusKey = undefined;
    const key = evt.Issue.tagStatusKey(&key_buffer, tag, status) catch return null;
    const cursor = (try tag_to_issues.getCursor(key)) orelse return null;
    return try DB.SortedSet(.read_only).init(cursor);
}

// read one window of `set_maybe` (null = an empty listing) starting at
// `root_key` (null = the beginning)
fn loadWindow(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    event_id_to_issue: evt.EventDB(hash_kind).HashMap(.read_only),
    set_maybe: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    root_key: ?[]const u8,
    conflict_set: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    selected_id: []const u8,
    comments_start: usize,
) !Window {
    const set = set_maybe orelse return .empty;
    const DB = evt.EventDB(hash_kind);
    const aa = arena.allocator();

    // seek once to the window start: the root key, or the set's first entry.
    var prev_id: ?[]const u8 = null;
    var iter = if (root_key) |key| blk: {
        // the previous window starts page_size ranks back ("" = the first
        // window, linked as the bare list route).
        const rank = try set.rank(key);
        if (rank > 0 and rank <= page_size) {
            prev_id = "";
        } else if (rank > page_size) {
            const kv = try set.getIndexKeyValuePair(@intCast(rank - page_size)) orelse return error.NotFound;
            var prev_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try kv.key_cursor.readBytes(&prev_key);
            const prev_hex = std.fmt.bytesToHex(prev_key[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &prev_hex);
        }
        break :blk try set.iteratorFrom(key);
    } else try set.iteratorFromIndex(0);

    // collect this window's issues, plus a peek at the one after it (its id is
    // the next window's start). the trailing bytes of each set key are the
    // issue event id.
    var issues: std.ArrayList(IssueWithId) = .empty;
    var next_id: ?[]const u8 = null;
    while (try iter.next()) |id_cursor_val| {
        var id_cursor = id_cursor_val;
        const id_kv = try id_cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try id_kv.key_cursor.readBytes(&order_key);
        const id_hex = std.fmt.bytesToHex(order_key[@sizeOf(u64)..].*, .lower);
        if (issues.items.len == page_size) {
            next_id = try aa.dupe(u8, &id_hex);
            break;
        }
        const issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(hash_kind, order_key[@sizeOf(u64)..])) orelse continue;
        const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
        const issue_event = try evt.read(evt.Issue.Record, DB, hash_kind, arena, issue_map);
        try issues.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .record = issue_event,
            .author = try ui.Author.initFromEmail(admin_moment, arena, issue_event.author_email),
            .conflicted = if (conflict_set) |cs| try cs.contains(&order_key) else false,
            .comments = try Comment.loadWindow(
                hash_kind,
                arena,
                admin_moment,
                haxy_moment,
                evt.Comment.thread_id_to_comment_id_set_key,
                &id_hex,
                if (std.mem.eql(u8, &id_hex, selected_id)) comments_start else 0,
            ),
            .attachments = try Attachment.load(hash_kind, arena, haxy_moment, &id_hex),
        });
    }

    return .{
        .items = issues.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

// the selected issue's conflict entry, shaped for the resolve view. `ours` is
// the live record.
fn readConflict(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    id_bytes: *const [evt.event_id_size]u8,
    ours: evt.Issue.Record,
    conflict_entry: evt.EventDB(repo_opts.hash).HashMap(.read_only),
) !Conflict {
    const DB = evt.EventDB(repo_opts.hash);
    const aa = arena.allocator();
    const gpa = arena.child_allocator;

    const fields_cursor = (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key))) orelse return error.NotFound;
    const conflicted_fields = try fields_cursor.readBytesAlloc(aa, null);

    const their_cursor = (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key))) orelse return error.NotFound;
    const theirs = try evt.read(evt.Issue.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(their_cursor));

    // absent when both sides created the issue independently
    var base: ?evt.Issue.Record = null;
    if (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.base_record_key))) |base_cursor| {
        base = try evt.read(evt.Issue.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(base_cursor));
    }

    // each side's field->oid map, for attributing the versions; a field a
    // merge left unattributed reads as an unknown author
    var their_field_oids: ?DB.SortedMap(.read_only) = null;
    if (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_field_to_oid_key))) |cursor| {
        their_field_oids = try DB.SortedMap(.read_only).init(cursor);
    }
    var our_field_oids: ?DB.SortedMap(.read_only) = null;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Issue.id_to_field_to_oid_key))) |map_cursor| {
        const id_to_field_to_oid = try DB.HashMap(.read_only).init(map_cursor);
        if (try id_to_field_to_oid.getCursor(hash.hashInt(repo_opts.hash, id_bytes))) |cursor| {
            our_field_oids = try DB.SortedMap(.read_only).init(cursor);
        }
    }

    var conflict = Conflict{};
    var field_iter = std.mem.splitScalar(u8, conflicted_fields, ' ');
    while (field_iter.next()) |field| {
        // status can't conflict (two changes of a two-value field agree)
        const known = std.meta.stringToEnum(enum { title, tags, description }, field) orelse continue;
        const our_author = try oidAuthor(repo_kind, repo_opts, arena, repo, io, admin_moment, try readFieldOid(repo_opts.hash, our_field_oids, field));
        const their_author = try oidAuthor(repo_kind, repo_opts, arena, repo, io, admin_moment, try readFieldOid(repo_opts.hash, their_field_oids, field));
        switch (known) {
            .title => conflict.title = .{
                .ours = .{ .text = ours.event.title, .author = our_author },
                .theirs = .{ .text = theirs.event.title, .author = their_author },
            },
            .tags => conflict.tags = .{
                .ours = .{ .text = ours.event.tags, .author = our_author },
                .theirs = .{ .text = theirs.event.tags, .author = their_author },
            },
            .description => conflict.description = .{
                .chunks = try diff3.chunks(io, gpa, arena, if (base) |b| b.event.description else "", ours.event.description, theirs.event.description),
                .ours_author = our_author,
                .theirs_author = their_author,
            },
        }
    }
    return conflict;
}

// the oid `field` maps to in a field->oid map, or null
fn readFieldOid(
    comptime hash_kind: hash.HashKind,
    field_oids_maybe: ?evt.EventDB(hash_kind).SortedMap(.read_only),
    field: []const u8,
) !?[hash.byteLen(hash_kind)]u8 {
    const field_oids = field_oids_maybe orelse return null;
    const cursor = (try field_oids.getCursor(field)) orelse return null;
    var oid: [hash.byteLen(hash_kind)]u8 = undefined;
    _ = try cursor.readBytes(&oid);
    return oid;
}

// the author of the event commit `oid_maybe` names
fn oidAuthor(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    oid_maybe: ?[hash.byteLen(repo_opts.hash)]u8,
) !ui.Author {
    const oid = oid_maybe orelse return .unknown;
    const gpa = arena.child_allocator;
    var start_oids = [_][hash.hexLen(repo_opts.hash)]u8{std.fmt.bytesToHex(oid, .lower)};
    var commit_iter = repo.log(io, gpa, start_oids[0..1]) catch return .unknown;
    defer commit_iter.deinit();
    const commit_object = (commit_iter.next(gpa) catch return .unknown) orelse return .unknown;
    defer commit_object.deinit();
    return try ui.Author.init(admin_moment, arena, commit_object.content.commit.metadata.author orelse "");
}

pub const View = Threads.View(.issue, Self);

// tabs switching between the issues page's views.
pub const Header = struct {
    box: wgt.Box(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        const aa = session.page_arena.allocator();

        // a list tab per status, labeled with its listing's issue count
        for ([_]evt.Issue.Status{ .open, .closed }) |status| {
            const route = ui.RoutablePage.repoIssuesRoute(data.identity, status, data.tag, "") orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
            const label = try std.fmt.allocPrint(aa, "{s} ({d})", .{ @tagName(status), data.window(status).count });
            try addTab(allocator, &box, &tab_ids, label, link);
        }

        // tags tab, labeled with the active tag filter
        {
            const tags_route = ui.RoutablePage.repoThreadTagsRoute(.issue, data.identity, data.tag) orelse return error.RouteTooLong;
            const tags_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try tags_route.toUrl(session.page_arena)});
            const label = if (data.tag.len == 0) "tags" else blk: {
                const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
                break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
            };
            try addTab(allocator, &box, &tab_ids, label, tags_link);
        }

        // new-issue tab; an edit or resolve url shows its tab in this place
        {
            const route = switch (data.view) {
                .edit => ui.RoutablePage.repoThreadEditRoute(.issue, data.identity, data.selected_id) orelse return error.RouteTooLong,
                .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.issue, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.issue, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                .remove => ui.RoutablePage.repoThreadRemoveRoute(.issue, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                .resolve => ui.RoutablePage.repoIssuesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
                else => ui.RoutablePage.repoThreadNewRoute(.issue, data.identity) orelse return error.RouteTooLong,
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
            try addTab(allocator, &box, &tab_ids, label, link);
        }

        // conflicts tab, labeled with the conflict count
        if (data.conflicts.count > 0) {
            const route = ui.RoutablePage.repoIssuesConflictsRoute(data.identity, "") orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
            const label = try std.fmt.allocPrint(aa, "conflicts ({d})", .{data.conflicts.count});
            try addTab(allocator, &box, &tab_ids, label, link);
        }

        var self = Header{ .box = box, .tab_ids = tab_ids };
        // the tab matching the page's view is selected initially.
        self.getFocus().child_id = self.tab_ids.keys()[View.viewIndex(data.view)];
        return self;
    }

    fn addTab(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), tab_ids: *std.AutoArrayHashMapUnmanaged(usize, void), label: []const u8, link: []const u8) !void {
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = link };
        try tab_ids.put(allocator, text_box.getFocus().id, {});
        try box.children.put(allocator, text_box.getFocus().id, .{
            .widget = .{ .text_box = text_box },
            .rect = null,
            .min_size = .{ .width = label.len + 2, .height = null },
        });
    }

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        self.tab_ids.deinit(allocator);
    }

    pub fn build(self: *Header, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // only the selected tab shows its border
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (self.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *Header, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        if (inp.moveTab(key, current_tab, self.tab_ids.count())) |new_tab| {
            root_focus.setFocus(self.tab_ids.keys()[new_tab]);
        }
    }

    pub fn clearGrid(self: *Header) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Header) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Header) *Focus {
        return self.box.getFocus();
    }

    pub fn getSelectedIndex(self: Header) ?usize {
        return self.currentTabIndex();
    }

    fn currentTabIndex(self: Header) ?usize {
        const child_id = self.box.focus.child_id orelse return null;
        return self.tab_ids.getIndex(child_id);
    }
};

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
    issue: evt.Issue.Record,
    // the creation commit's author
    author: ui.Author = .unknown,
    // whether the issue has an unresolved merge conflict
    conflicted: bool = false,
};

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
    issues: []const IssueWithId,
    // the id of the previous window's first issue, or null when this window
    // is already the first.
    prev_id: ?[]const u8,
    // the id of the next window's first issue, or null when this is the last
    // window.
    next_id: ?[]const u8,
    // how many issues the listing holds across all windows.
    count: usize,

    pub const empty: Window = .{ .issues = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

// "owner/name", so the view can build /repo/owner/name/issues/... links.
identity: []const u8,
// the url-encoded tag the lists are filtered to ("" = unfiltered).
tag: []const u8,
// the hex event id of the issue its status's window is rooted at ("" = the
// first window), mirrored into the url.
selected_id: []const u8,
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
pub fn selectedIssue(self: *const Self) ?*const IssueWithId {
    if (self.selected_id.len == 0) return null;
    for ([_]*const Window{ &self.open, &self.closed }) |win| {
        for (win.issues) |*entry| {
            if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
        }
    }
    return null;
}

// an empty listing, for the wasm / no-repo paths.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, tag: []const u8, selected_id: []const u8, theirs_picks: []const u8, view: ui.RoutablePage.IssuesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
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
    theirs_picks: []const u8,
    view: ui.RoutablePage.IssuesView,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, selected_id, theirs_picks, view);

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
            // an edit url keeps its view; otherwise the issue's status picks it.
            if (view != .edit) resolved_view = switch (issue_event.event.status) {
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

    const open_window = try loadWindow(repo_opts.hash, arena, admin_moment, event_id_to_issue, open_set, open_root, conflict_set);
    const closed_window = try loadWindow(repo_opts.hash, arena, admin_moment, event_id_to_issue, closed_set, closed_root, conflict_set);
    const conflicts_window = try loadWindow(repo_opts.hash, arena, admin_moment, event_id_to_issue, conflict_set, conflicts_root, conflict_set);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

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
    event_id_to_issue: evt.EventDB(hash_kind).HashMap(.read_only),
    set_maybe: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    root_key: ?[]const u8,
    conflict_set: ?evt.EventDB(hash_kind).SortedSet(.read_only),
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
            .issue = issue_event,
            .author = try ui.Author.initFromEmail(admin_moment, arena, issue_event.author_email),
            .conflicted = if (conflict_set) |cs| try cs.contains(&order_key) else false,
        });
    }

    return .{
        .issues = issues.items,
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

pub const View = struct {
    // a vertical box: the header tabs on top, then a stack holding a
    // master-detail split (issue list + description pane) per status list,
    // plus the tags view.
    box: wgt.Box(ui.Widget), // vert: [header_index] = tabs, [stack_index] = stack
    data: *const Self,
    session: *ui.Session,
    // per-split state, indexed like the stack's split children: the issue the
    // pane shows, and its description and author text boxes' focus ids.
    detailed_index: [stack_child_max]?usize,
    description_id: [stack_child_max]?usize,
    author_id: [stack_child_max]?usize,

    const header_index: usize = 0;
    const stack_index: usize = 1;
    // indices within the stack, 1:1 with the header tabs.
    const open_view_index: usize = 0;
    const closed_view_index: usize = 1;
    const tags_view_index: usize = 2;
    // the new-issue form, or the edit or resolve form when the page was
    // loaded at one of their urls.
    const form_view_index: usize = 3;
    // the conflicts split; the tab and stack child exist only when the repo
    // has conflicted issues.
    const conflicts_view_index: usize = 4;
    const stack_child_max: usize = conflicts_view_index + 1;
    // the leading stack children that are status splits; the conflicts split
    // sits apart at conflicts_view_index.
    const split_count: usize = 2;
    // indices within a split (the horizontal box inside the stack).
    const list_index: usize = 0;
    const detail_index: usize = 1;
    const list_max_width: usize = 40;
    const detail_min_width: usize = 40;
    // indices within the new-issue form.
    const title_field_index: usize = 0;
    const tags_field_index: usize = 1;
    const description_field_index: usize = 2;
    const submit_field_index: usize = 3;

    fn viewIndex(view: ui.RoutablePage.IssuesView) usize {
        return switch (view) {
            .open => open_view_index,
            .closed => closed_view_index,
            .tags => tags_view_index,
            .new, .edit, .resolve => form_view_index,
            .conflicts => conflicts_view_index,
            // init resolves a description url to its issue's status list
            .description => unreachable,
        };
    }

    // the status a status split lists; the conflicts split has none (its
    // issues carry their own).
    fn splitStatus(index: usize) evt.Issue.Status {
        return if (index == open_view_index) .open else .closed;
    }

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the tabs at the top.
        {
            var hdr = try Header.init(allocator, session, data);
            errdefer hdr.deinit(allocator);
            try outer.children.put(allocator, hdr.getFocus().id, .{ .widget = .{ .repo_issues_header = hdr }, .rect = null, .min_size = null });
        }

        // the stack enters `outer` before its children enter it, so an error
        // frees each child exactly once.
        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);
            try outer.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }
        const stack = &outer.children.values()[stack_index].widget.stack;

        // a master-detail split per status list.
        for ([_]evt.Issue.Status{ .open, .closed }) |status| {
            var split = try initSplit(allocator, session, data, status);
            errdefer split.deinit(allocator);
            try stack.children.put(allocator, split.getFocus().id, .{ .box = split });
        }

        // the tags view
        {
            var tf = try ui.TagFlow.init(allocator);
            errdefer tf.deinit(allocator);
            var items: std.ArrayList(ui.TagFlow.Item) = .empty;
            defer items.deinit(allocator);
            // when filtered, the first item clears the filter
            if (data.tag.len != 0)
                try items.append(allocator, .{ .text = "✕", .link = try issuesLink(session.page_arena, data.identity, .open, "", "") });
            for (data.tags) |tag|
                try items.append(allocator, .{ .text = tag, .link = try tagLink(session.page_arena, data.identity, .open, tag) });
            try tf.setItems(allocator, items.items);
            try stack.children.put(allocator, tf.getFocus().id, .{ .tag_flow = tf });
        }

        // the new-issue form, or — on an edit or resolve url — that form in
        // its place, prefilled with the selected issue's content. a
        // logged-out session can't create events, so the unauthorized view
        // stands in.
        if (session.data.is_local or session.data.user_id != null) {
            if (data.view == .resolve) {
                // on the web the page grows to the form's height and the
                // browser scrolls it; the terminal scrolls the form itself
                var form_widget: ui.Widget = blk: {
                    var form = try initResolveForm(allocator, session, data);
                    errdefer form.deinit(allocator);
                    break :blk if (session.is_terminal)
                        .{ .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = form }, .{ .direction = .vert }) }
                    else
                        .{ .box = form };
                };
                errdefer form_widget.deinit(allocator);
                try stack.children.put(allocator, form_widget.getFocus().id, form_widget);
            } else {
                const aa = session.page_arena.allocator();
                const action = if (data.view == .edit)
                    (if (data.identity.len == 0)
                        try std.fmt.allocPrint(aa, "form:/issues/{s}/edit", .{data.selected_id})
                    else
                        try std.fmt.allocPrint(aa, "form:/repo/{s}/issues/{s}/edit", .{ data.identity, data.selected_id }))
                else if (data.identity.len == 0)
                    "form:/issue"
                else
                    try std.fmt.allocPrint(aa, "form:/repo/{s}/issue", .{data.identity});
                const issue = if (data.view == .edit)
                    (if (data.selectedIssue()) |entry| &entry.issue else null)
                else
                    null;
                var form = try initIssueForm(allocator, session, action, issue);
                errdefer form.deinit(allocator);
                try stack.children.put(allocator, form.getFocus().id, .{ .box = form });
            }
        } else {
            var message = try ui.Unauthorized.View.init(allocator);
            errdefer message.deinit(allocator);
            try stack.children.put(allocator, message.getFocus().id, .{ .unauthorized = message });
        }

        // the conflicts split; its tab exists only when the repo has
        // conflicts, so skip the child too to keep the stack 1:1 with the
        // tabs.
        if (data.conflicts.count > 0) {
            var split = try initSplit(allocator, session, data, null);
            errdefer split.deinit(allocator);
            try stack.children.put(allocator, split.getFocus().id, .{ .box = split });
        }

        // the stack starts on the page's view.
        stack.getFocus().child_id = stack.children.keys()[viewIndex(data.view)];

        // focus entering the view lands on the tabs first.
        outer.getFocus().child_id = outer.children.keys()[header_index];

        return .{
            .box = outer,
            .data = data,
            .session = session,
            .detailed_index = @splat(null),
            .description_id = @splat(null),
            .author_id = @splat(null),
        };
    }

    // the master-detail split showing `status`'s window, or the conflicts
    // window when null.
    fn initSplit(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self, status_maybe: ?evt.Issue.Status) !wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        const win = if (status_maybe) |status| data.window(status) else &data.conflicts;

        // the issue list (one focusable row per title), plus a "next" link that
        // reloads the page rooted at the following issue.
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
                errdefer list_box.deinit(allocator);
                if (win.prev_id) |prev|
                    try addRow(allocator, &list_box, "← previous", "", try windowLink(session.page_arena, data, status_maybe, prev));
                for (win.issues) |entry| {
                    // conflicted issues carry a marker in the status lists
                    const label: []const u8 = if (entry.conflicted and status_maybe != null) "[conflict]" else "";
                    try addRow(allocator, &list_box, entry.issue.event.title, label, try issueRowLink(session.page_arena, data.identity, entry.id));
                }
                if (win.next_id) |next|
                    try addRow(allocator, &list_box, "next →", "", try windowLink(session.page_arena, data, status_maybe, next));
                // select the window's first issue (past a leading "previous"
                // row) so its description shows on load.
                if (win.issues.len > 0)
                    list_box.getFocus().child_id = list_box.children.keys()[if (win.prev_id != null) 1 else 0]
                else if (list_box.children.count() > 0)
                    list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }

        // the detail pane — a frame around a scroll of the description
        {
            var detail_outer = blk: {
                var detail_scroll = blk2: {
                    var detail_inner = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                    errdefer detail_inner.deinit(allocator);
                    // fill the pane (content top-left, scroll bar pinned to the
                    // edge) rather than shrinking to the description.
                    break :blk2 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = detail_inner }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
                };
                errdefer detail_scroll.deinit(allocator);
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                // the tool row sits above the scroll (populateDetail fills
                // it per issue) so it can't scroll out from under the web
                // overlay <form>, whose position doesn't track pane scrolling.
                {
                    var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
                    errdefer row.deinit(allocator);
                    try frame.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
                }
                // the frame's selected child is its scroll, so the focus chain
                // reaches the description (populateDetail points the scroll's
                // inner box at it), letting focus recovery descend into the pane.
                frame.getFocus().child_id = detail_scroll.getFocus().id;
                try frame.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = null });
                break :blk frame;
            };
            errdefer detail_outer.deinit(allocator);
            try box.children.put(allocator, detail_outer.getFocus().id, .{ .widget = .{ .box = detail_outer }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[list_index];
        return box;
    }

    // an issue form: title/tags/description inputs and a submit button,
    // prefilled from `issue` when given. its form: subtree makes the web
    // overlay wrap them in a <form> POSTing to `action`'s route.
    fn initIssueForm(allocator: std.mem.Allocator, session: *ui.Session, action: []const u8, issue: ?*const evt.Issue.Record) !wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = action };

        {
            var title = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " title ", .name = "title", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
            errdefer title.deinit(allocator);
            title.getFocus().focusable = true;
            if (issue) |i| try title.setContent(allocator, i.event.title);
            try box.children.put(allocator, title.getFocus().id, .{ .widget = .{ .text_input = title }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var tags = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " tags (separate with spaces) ", .name = "tags", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
            errdefer tags.deinit(allocator);
            tags.getFocus().focusable = true;
            if (issue) |i| try tags.setContent(allocator, i.event.tags);
            try box.children.put(allocator, tags.getFocus().id, .{ .widget = .{ .text_input = tags }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var description = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " description ", .name = "description", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal, .multiline = true, .scroll = .{ .fill = true } });
            errdefer description.deinit(allocator);
            description.getFocus().focusable = true;
            if (issue) |i| try description.setContent(allocator, i.event.description);
            try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = null });
        }

        try addSubmitButton(allocator, &box);

        box.getFocus().child_id = box.children.keys()[title_field_index];
        return box;
    }

    // a form's submit button, then a spacer absorbing the leftover
    // min-height the box hands its last child, so the button keeps its
    // natural height
    fn addSubmitButton(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget)) !void {
        {
            var submit = try ui.SubmitButton.init(allocator);
            errdefer submit.deinit(allocator);
            try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }
        {
            var spacer = try ui.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
        }
    }

    // the conflict resolve form. the "use this" links are navigations that
    // flip the url's theirs: pick, reloading the prefills; one submit
    // settles every conflict. the form: subtree makes the web overlay POST
    // to the resolve route.
    fn initResolveForm(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !wgt.Box(ui.Widget) {
        const aa = session.page_arena.allocator();
        // init only picks the resolve view once it has read the conflict
        const conflict = if (data.conflict) |*c| c else unreachable;

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = if (data.identity.len == 0)
            try std.fmt.allocPrint(aa, "form:/issues/{s}/resolve", .{data.selected_id})
        else
            try std.fmt.allocPrint(aa, "form:/repo/{s}/issues/{s}/resolve", .{ data.identity, data.selected_id }) };

        if (conflict.title) |*fc| {
            try addLabel(allocator, &box, "title conflict:");
            try addFieldConflict(allocator, &box, session, data, "title", fc);
        }
        if (conflict.tags) |*fc| {
            try addLabel(allocator, &box, "tags conflict:");
            try addFieldConflict(allocator, &box, session, data, "tags", fc);
        }

        if (conflict.description) |*desc| {
            try addLabel(allocator, &box, "description conflict:");
            var hunk_index: usize = 0;
            for (desc.chunks, 0..) |*chunk, chunk_index| {
                switch (chunk.*) {
                    .same => |text| {
                        var tb = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word });
                        errdefer tb.deinit(allocator);
                        tb.getFocus().focusable = true;
                        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                    },
                    // an auto-resolved chunk: only one side changed it, so its
                    // version stands, shown distinctly with its author
                    .auto => |auto| {
                        const author = if (auto.theirs) desc.theirs_author else desc.ours_author;
                        const verb: []const u8 = if (auto.text == null) "removed" else "edited";
                        const label = switch (author) {
                            .user_name, .email => |name| try std.fmt.allocPrint(aa, " {s} by {s} ", .{ verb, name }),
                            .unknown => try std.fmt.allocPrint(aa, " {s} by {s} ", .{ verb, if (auto.theirs) @as([]const u8, "them") else "us" }),
                        };
                        var tb = try wgt.TextBox(ui.Widget).init(allocator, auto.text orelse "(removed)", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = label });
                        errdefer tb.deinit(allocator);
                        tb.getFocus().focusable = true;
                        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                    },
                    .conflict => |hunk| {
                        // a blank row on each side sets the group apart from
                        // the flowing shared and auto-resolved chunks
                        if (chunk_index > 0) try addGap(allocator, &box);
                        const name = try std.fmt.allocPrint(aa, "d{d}", .{hunk_index});
                        hunk_index += 1;
                        const picked_theirs = data.theirsPicked(name);
                        try addVersionRow(allocator, &box, try sideLabel(aa, desc.ours_author, true), hunk.ours orelse "", try useThisLink(session, data, name, false));
                        try addVersionRow(allocator, &box, try sideLabel(aa, desc.theirs_author, false), hunk.theirs orelse "", try useThisLink(session, data, name, true));
                        var resolution_input = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " resolution ", .name = name, .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal, .multiline = true });
                        errdefer resolution_input.deinit(allocator);
                        resolution_input.getFocus().focusable = true;
                        try resolution_input.setContent(allocator, (if (picked_theirs) hunk.theirs else hunk.ours) orelse "");
                        try box.children.put(allocator, resolution_input.getFocus().id, .{ .widget = .{ .text_input = resolution_input }, .rect = null, .min_size = null });
                        if (chunk_index + 1 < desc.chunks.len) try addGap(allocator, &box);
                    },
                }
            }
        }

        try addSubmitButton(allocator, &box);

        box.getFocus().child_id = box.children.keys()[0];
        return box;
    }

    // one conflicted scalar field: both sides' version rows, then the
    // resolution input prefilled from the picked side.
    fn addFieldConflict(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, data: *const Self, comptime name: []const u8, fc: *const FieldConflict) !void {
        const aa = session.page_arena.allocator();
        try addVersionRow(allocator, box, try sideLabel(aa, fc.ours.author, true), fc.ours.text, try useThisLink(session, data, name, false));
        try addVersionRow(allocator, box, try sideLabel(aa, fc.theirs.author, false), fc.theirs.text, try useThisLink(session, data, name, true));

        var resolution_input = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " resolution ", .name = name, .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
        errdefer resolution_input.deinit(allocator);
        resolution_input.getFocus().focusable = true;
        try resolution_input.setContent(allocator, if (data.theirsPicked(name)) fc.theirs.text else fc.ours.text);
        try box.children.put(allocator, resolution_input.getFocus().id, .{ .widget = .{ .text_input = resolution_input }, .rect = null, .min_size = null });
    }

    // a blank row setting a conflict group apart from its neighbors
    fn addGap(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget)) !void {
        var text = try wgt.Text(ui.Widget).init(allocator, " ");
        errdefer text.deinit(allocator);
        try box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
    }

    fn addLabel(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), content: []const u8) !void {
        var label = try ui.SectionLabel.init(allocator, content);
        errdefer label.deinit(allocator);
        try box.children.put(allocator, label.getFocus().id, .{ .widget = .{ .section_label = label }, .rect = null, .min_size = null });
    }

    // one side of a conflict: the "use this" link on the left, the version
    // itself as a labeled read-only box.
    fn addVersionRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, text: []const u8, link: []const u8) !void {
        var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer row.deinit(allocator);

        {
            const use_label = "use this";
            var use = try wgt.TextBox(ui.Widget).init(allocator, use_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer use.deinit(allocator);
            use.getFocus().focusable = true;
            use.getFocus().kind = .{ .custom = link };
            try row.children.put(allocator, use.getFocus().id, .{
                .widget = .{ .text_box = use },
                .rect = null,
                .min_size = .{ .width = use_label.len + 2, .height = null },
                .max_size = .{ .width = use_label.len + 2, .height = null },
            });
        }

        {
            var tb = try wgt.TextBox(ui.Widget).init(allocator, if (text.len > 0) text else "(removed)", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = label });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        }

        row.getFocus().child_id = row.children.keys()[0];
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
    }

    // the label of one side's version box, naming its author
    fn sideLabel(aa: std.mem.Allocator, author: ui.Author, ours: bool) ![]const u8 {
        return switch (author) {
            .user_name, .email => |name| try std.fmt.allocPrint(aa, " edited by {s} ", .{name}),
            .unknown => if (ours) " current version " else " their version ",
        };
    }

    // the a: link that reloads the resolve page with `name` picked from ours
    // or theirs, reprefilling its resolution input
    fn useThisLink(session: *ui.Session, data: *const Self, name: []const u8, theirs: bool) ![]const u8 {
        const aa = session.page_arena.allocator();
        var picks: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, data.theirs_picks, ',');
        while (it.next()) |pick| {
            if (pick.len == 0 or std.mem.eql(u8, pick, name)) continue;
            if (picks.items.len > 0) try picks.append(aa, ',');
            try picks.appendSlice(aa, pick);
        }
        if (theirs) {
            if (picks.items.len > 0) try picks.append(aa, ',');
            try picks.appendSlice(aa, name);
        }
        const route = ui.RoutablePage.repoIssuesResolveRoute(data.identity, data.selected_id, picks.items) orelse return error.RouteTooLong;
        return std.fmt.allocPrint(aa, "a:{s}", .{try route.toUrl(session.page_arena)});
    }

    // the resolve form's page-constant initial value for the input `name`:
    // the picked side of its conflicted field or hunk
    fn resolvePrefill(self: *View, name: []const u8) ?[]const u8 {
        const conflict = if (self.data.conflict) |*c| c else return null;
        const theirs = self.data.theirsPicked(name);
        if (std.mem.eql(u8, name, "title")) {
            const fc = if (conflict.title) |*f| f else return null;
            return if (theirs) fc.theirs.text else fc.ours.text;
        }
        if (std.mem.eql(u8, name, "tags")) {
            const fc = if (conflict.tags) |*f| f else return null;
            return if (theirs) fc.theirs.text else fc.ours.text;
        }
        if (std.mem.startsWith(u8, name, "d")) {
            const desc = if (conflict.description) |*d| d else return null;
            const hunk_index = std.fmt.parseInt(usize, name[1..], 10) catch return null;
            var seen: usize = 0;
            for (desc.chunks) |chunk| switch (chunk) {
                .conflict => |hunk| {
                    if (seen == hunk_index) return (if (theirs) hunk.theirs else hunk.ours) orelse "";
                    seen += 1;
                },
                else => {},
            };
        }
        return null;
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, bottom_label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word, .bottom_label = bottom_label });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null, .max_size = .{ .width = null, .height = 5 } });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn header(self: *View) *Header {
        return &self.box.children.values()[header_index].widget.repo_issues_header;
    }

    fn viewStack(self: *View) *wgt.Stack(ui.Widget) {
        return &self.box.children.values()[stack_index].widget.stack;
    }

    // `index`'s master-detail split inside the stack.
    fn resultsBox(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.viewStack().children.values()[index].box;
    }

    // the tags view's flow inside the stack.
    fn tagsView(self: *View) *ui.TagFlow {
        return &self.viewStack().children.values()[tags_view_index].tag_flow;
    }

    // the new-issue, edit, or resolve form inside the stack, or null when the
    // unauthorized view stands in for it.
    fn issueForm(self: *View) ?*wgt.Box(ui.Widget) {
        return switch (self.viewStack().children.values()[form_view_index]) {
            .box => |*box| box,
            // the resolve form sits inside a scroll on the terminal
            .scroll => |*scroll| &scroll.child.box,
            else => null,
        };
    }

    // the resolve form's scroll on the terminal (the web page scrolls itself)
    fn resolveScroll(self: *View) ?*wgt.Scroll(ui.Widget) {
        return switch (self.viewStack().children.values()[form_view_index]) {
            .scroll => |*scroll| scroll,
            else => null,
        };
    }

    fn listScroll(self: *View, index: usize) *wgt.Scroll(ui.Widget) {
        return &self.resultsBox(index).children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.listScroll(index).child.box;
    }

    // the detail frame's children: the tool row above the scroll pane.
    const tool_row_index: usize = 0;
    const detail_scroll_index: usize = 1;

    fn detailOuter(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.resultsBox(index).children.values()[detail_index].widget.box;
    }

    fn toolRow(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.detailOuter(index).children.values()[tool_row_index].widget.box;
    }

    fn detailScroll(self: *View, index: usize) *wgt.Scroll(ui.Widget) {
        return &self.detailOuter(index).children.values()[detail_scroll_index].widget.scroll;
    }

    fn detailInner(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.detailScroll(index).child.box;
    }

    fn window(self: *View, index: usize) *const Window {
        if (index == conflicts_view_index) return &self.data.conflicts;
        return self.data.window(splitStatus(index));
    }

    fn stackSelectedIndex(self: *View) ?usize {
        const stack = self.viewStack();
        const cid = stack.getFocus().child_id orelse return null;
        return stack.children.getIndex(cid);
    }

    // the stack's selected master-detail split (null when the tags view or the
    // new-issue form shows).
    fn selectedSplitIndex(self: *View) ?usize {
        const idx = self.stackSelectedIndex() orelse return null;
        return if (idx < split_count or idx == conflicts_view_index) idx else null;
    }

    fn detailActive(self: *View, index: usize) bool {
        const rb = self.resultsBox(index);
        const cid = rb.getFocus().child_id orelse return false;
        return rb.children.getIndex(cid) == detail_index;
    }

    fn headerActive(self: *View) bool {
        const cid = self.box.getFocus().child_id orelse return false;
        return self.box.children.getIndex(cid) == header_index;
    }

    fn tagsViewActive(self: *View) bool {
        if (self.headerActive()) return false;
        return self.stackSelectedIndex() == tags_view_index;
    }

    fn formViewActive(self: *View) bool {
        if (self.headerActive()) return false;
        return self.stackSelectedIndex() == form_view_index;
    }

    // the selected issue's index, or null when a window-navigation row is
    // selected (a leading "previous" row shifts the issue rows down by one).
    fn selectedIssueIndex(self: *View, index: usize) ?usize {
        const lb = self.listBox(index);
        const cid = lb.getFocus().child_id orelse return null;
        const idx = lb.children.getIndex(cid) orelse return null;
        const win = self.window(index);
        const lead: usize = if (win.prev_id != null) 1 else 0;
        if (idx < lead or idx - lead >= win.issues.len) return null;
        return idx - lead;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // each header tab maps 1:1 to a stack child by position. mirror the
        // selection into the url: the view the page's window is rooted at
        // keeps its rooted url, the others get their list route (keeping the
        // tag filter).
        if (self.header().getSelectedIndex()) |index| {
            const stack = self.viewStack();
            stack.getFocus().child_id = stack.children.keys()[index];
            self.session.data.current_page = (if (index == form_view_index)
                (switch (self.data.view) {
                    .edit => ui.RoutablePage.repoIssuesEditRoute(self.data.identity, self.data.selected_id),
                    .resolve => ui.RoutablePage.repoIssuesResolveRoute(self.data.identity, self.data.selected_id, self.data.theirs_picks),
                    else => ui.RoutablePage.repoIssuesNewRoute(self.data.identity),
                })
            else if (index == conflicts_view_index)
                ui.RoutablePage.repoIssuesConflictsRoute(self.data.identity, if (self.data.view == .conflicts) self.data.selected_id else "")
            else if (index == viewIndex(self.data.view) and self.data.selected_id.len != 0)
                (if (self.data.description_page)
                    ui.RoutablePage.repoIssuesDescriptionRoute(self.data.identity, self.data.selected_id)
                else
                    ui.RoutablePage.repoIssuesRoute(self.data.identity, .open, self.data.tag, self.data.selected_id))
            else if (index == tags_view_index)
                ui.RoutablePage.repoIssuesTagsRoute(self.data.identity, self.data.tag)
            else
                ui.RoutablePage.repoIssuesRoute(self.data.identity, splitStatus(index), self.data.tag, "")) orelse self.session.data.current_page;
        }

        if (self.selectedSplitIndex()) |i| {
            // swap the detail pane to the selected issue when it changes.
            try self.refreshDetail(allocator, i);

            // mirror the focused issue into the url, but only while focus is
            // inside the split. an issue's url is the same whether or not the
            // list is filtered, so the mirror drops the tag.
            if (root_focus.grandchild_id) |g| {
                if (self.resultsBox(i).getFocus().children.contains(g)) {
                    if (self.selectedIssueIndex(i)) |sel| {
                        // selecting another issue leaves the description page
                        // behind, like it leaves the tag filter behind.
                        const entry = &self.window(i).issues[sel];
                        const mirrored = if (self.data.description_page and std.mem.eql(u8, entry.id, self.data.selected_id))
                            ui.RoutablePage.repoIssuesDescriptionRoute(self.data.identity, entry.id)
                        else
                            ui.RoutablePage.repoIssuesRoute(self.data.identity, entry.issue.event.status, "", entry.id);
                        if (mirrored) |route| self.session.data.current_page = route;
                    }
                }
            }

            // the selected list row shows a border (the focused TextBox
            // upgrades it to a double border itself); the rest stay borderless.
            const lb = self.listBox(i);
            for (lb.children.keys(), lb.children.values()) |id, *child| {
                switch (child.widget) {
                    .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
                    else => {},
                }
            }

            // the pane's selected child shows the selection border: the
            // description directly, the tags via the flow's selected item.
            // cap the list at list_max_width only while the detail pane fits
            // beside it. the box drops the detail when the width can't hold
            // both minimums, so when it's that narrow we lift the cap and let
            // the list fill the whole width.
            const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
            self.resultsBox(i).children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

            // stretch the detail pane across the rest of the width so it fills
            // the area rather than shrinking to its content; its scroll fills
            // the pane.
            if (constraint.max_size.width) |w| {
                self.resultsBox(i).children.values()[detail_index].min_size = .{ .width = if (both_panes_fit) w - list_max_width else w, .height = null };
            } else {
                self.resultsBox(i).children.values()[detail_index].min_size = .{ .width = detail_min_width, .height = null };
            }
        }

        // refresh the form inputs' entries in the session's focus-id -> input
        // map with this frame's addresses, so the web/wasm form handling can
        // find them by focus id
        if (self.issueForm()) |form| {
            const inputs_arena = self.session.arena.allocator();
            for (form.children.values()) |*child| switch (child.widget) {
                .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
                else => {},
            };

            // on an edit page, register the issue's content as the inputs'
            // page-constant initial values, which the web overlay renders
            // into them.
            if (self.data.view == .edit) {
                if (self.data.selectedIssue()) |entry| {
                    const fields = form.children.values();
                    try self.session.input_values.put(inputs_arena, fields[title_field_index].widget.text_input.getFocus().id, entry.issue.event.title);
                    try self.session.input_values.put(inputs_arena, fields[tags_field_index].widget.text_input.getFocus().id, entry.issue.event.tags);
                    try self.session.input_values.put(inputs_arena, fields[description_field_index].widget.text_input.getFocus().id, entry.issue.event.description);
                }
            }

            // the resolve form's inputs prefill from the picked side, which
            // is url state and so page-constant like the edit values above
            if (self.data.view == .resolve) {
                for (form.children.values()) |*child| switch (child.widget) {
                    .text_input => |*ti| if (self.resolvePrefill(ti.options.name)) |value| {
                        try self.session.input_values.put(inputs_arena, ti.getFocus().id, value);
                    },
                    else => {},
                };
            }
        }

        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator, index: usize) !void {
        const sel = self.selectedIssueIndex(index) orelse return;
        if (self.detailed_index[index]) |d| if (d == sel) return;
        try self.populateDetail(allocator, index, sel);
        self.detailed_index[index] = sel;
    }

    fn populateDetail(self: *View, allocator: std.mem.Allocator, index: usize, sel: usize) !void {
        const entry = self.window(index).issues[sel];
        const inner = self.detailInner(index);
        // the /description page replaces its issue's detail with a back link
        // and the whole description; other issues keep their normal detail.
        const description_page = self.data.description_page and std.mem.eql(u8, entry.id, self.data.selected_id);

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;
        self.author_id[index] = null;

        // the tool row: the open/close and edit buttons; the description page
        // shows none.
        {
            const row = self.toolRow(index);
            for (row.children.values()) |*child| child.widget.deinit(allocator);
            row.children.clearAndFree(allocator);
            row.getFocus().child_id = null;
            row.getFocus().kind = .container;
        }
        if (!description_page) {
            const row = self.toolRow(index);
            const pa = self.session.page_arena.allocator();

            {
                var spacer = try ui.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try row.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }

            // a conflicted issue's only action is resolving it. the button
            // stays visible logged out; the resolve page shows the
            // unauthorized view then.
            if (entry.conflicted) {
                const label = "resolve conflict";
                var button = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().focusable = true;
                const route = ui.RoutablePage.repoIssuesResolveRoute(self.data.identity, entry.id, "") orelse return error.RouteTooLong;
                button.getFocus().kind = .{ .custom = try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}) };
                try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = label.len + 2, .height = null } });
            } else {
                // a logged-out session can't flip the status, so it gets no
                // open/close button (and no form action on the row)
                if (self.session.data.is_local or self.session.data.user_id != null) {
                    const action: []const u8 = switch (entry.issue.event.status) {
                        .open => "close",
                        .closed => "open",
                    };
                    row.getFocus().kind = .{ .custom = if (self.data.identity.len == 0)
                        try std.fmt.allocPrint(pa, "form:/issues/{s}/{s}", .{ entry.id, action })
                    else
                        try std.fmt.allocPrint(pa, "form:/repo/{s}/issues/{s}/{s}", .{ self.data.identity, entry.id, action }) };

                    var button = try wgt.TextBox(ui.Widget).init(allocator, action, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                    errdefer button.deinit(allocator);
                    button.getFocus().focusable = true;
                    // the renderer distinguishes plain clickables from buttons that
                    // should POST to a server route by this kind.
                    button.getFocus().kind = .{ .custom = "submit" };
                    try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = action.len + 2, .height = null } });
                }

                // the edit button links to the issue's edit page.
                {
                    var button = try wgt.TextBox(ui.Widget).init(allocator, "edit", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                    errdefer button.deinit(allocator);
                    button.getFocus().focusable = true;
                    const route = ui.RoutablePage.repoIssuesEditRoute(self.data.identity, entry.id) orelse return error.RouteTooLong;
                    button.getFocus().kind = .{ .custom = try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}) };
                    try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = "edit".len + 2, .height = null } });
                }
            }

            // the resolve button on a conflicted issue, else the open/close
            // button when present, the edit button otherwise
            row.getFocus().child_id = row.children.keys()[button_in_row_index];
        }

        if (description_page) {
            // the back link, in the title slot so the pane's input handling
            // applies to it unchanged.
            var tb = try wgt.TextBox(ui.Widget).init(allocator, "← back to issue", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            tb.getFocus().kind = .{ .custom = try issuesLink(self.session.page_arena, self.data.identity, entry.issue.event.status, "", entry.id) };
            try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        } else {
            // the issue's title as a focusable word-wrapped text box.
            {
                var tb = try wgt.TextBox(ui.Widget).init(allocator, entry.issue.event.title, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = " title " });
                errdefer tb.deinit(allocator);
                tb.getFocus().focusable = true;
                try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
            }

            self.author_id[index] = blk: {
                var tb = try ui.authorBox(allocator, self.session.page_arena, entry.author);
                errdefer tb.deinit(allocator);
                try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                break :blk tb.getFocus().id;
            };

            // the issue's tags, each linking to this status's list filtered to
            // that tag.
            {
                var items: std.ArrayList(ui.TagFlow.Item) = .empty;
                defer items.deinit(allocator);
                var tag_iter = evt.Issue.tagIterator(entry.issue.event.tags);
                while (tag_iter.next()) |tag| {
                    if (tag.len == 0) continue;
                    try items.append(allocator, .{ .text = tag, .link = try tagLink(self.session.page_arena, self.data.identity, entry.issue.event.status, tag) });
                }
                if (items.items.len > 0) {
                    var tf = try ui.TagFlow.init(allocator);
                    errdefer tf.deinit(allocator);
                    try tf.setItems(allocator, items.items);
                    try inner.children.put(allocator, tf.getFocus().id, .{ .widget = .{ .tag_flow = tf }, .rect = null, .min_size = null });
                }
            }
        }

        // the description as a focusable word-wrapped text box. past the limit
        // it's cut at the last whole line and links to the /description page,
        // which shows the whole thing.
        self.description_id[index] = blk: {
            const whole = entry.issue.event.description;
            const cut_short = !description_page and whole.len > max_description_size;
            const shown = if (cut_short)
                std.mem.trimEnd(u8, whole[0 .. std.mem.lastIndexOfScalar(u8, whole[0..max_description_size], '\n') orelse 0], " \t\r\n")
            else if (whole.len == 0)
                "(no description)"
            else
                whole;
            var tb = try wgt.TextBox(ui.Widget).init(allocator, shown, .{
                .border_style = .single,
                .rounded_corners = true,
                .wrap_kind = .word,
                .label = " description ",
                .bottom_label = if (cut_short) " click or press enter to see more " else "",
            });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            if (cut_short) tb.getFocus().kind = .{ .custom = try descriptionLink(self.session.page_arena, self.data.identity, entry.id) };
            try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
            break :blk tb.getFocus().id;
        };

        // select the title by default
        inner.getFocus().child_id = inner.children.keys()[title_child_index];

        // reset the scroll to the top for the newly-shown issue: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll(index);
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, raw_key: Key, root_focus: *Focus) !void {
        // wheel input moves focus like the arrows
        const key: Key = if (raw_key == .mouse and raw_key.mouse.action == .scroll)
            (if (raw_key.mouse.action.scroll == .up) .arrow_up else .arrow_down)
        else
            raw_key;

        if (self.headerActive()) {
            // down from the tabs re-enters the stack if the selected view has
            // something to focus; other keys move the tabs.
            if (inp.vertDirection(key) == .down) {
                const enterable = if (self.viewStack().getSelected()) |selected| switch (selected.*) {
                    .tag_flow => |*tf| tf.text_boxes.items.len > 0,
                    // nothing focusable in the unauthorized view
                    .unauthorized => false,
                    else => true,
                } else false;
                if (enterable) root_focus.setFocus(self.box.children.keys()[stack_index]);
            } else {
                try self.header().input(allocator, key, root_focus);
            }
            return;
        }
        if (self.tagsViewActive()) {
            self.tagsViewInput(key, root_focus);
            return;
        }
        if (self.formViewActive()) {
            if (self.data.view == .resolve) {
                try self.resolveInput(allocator, key, root_focus);
            } else {
                try self.formInput(allocator, key, root_focus);
            }
            return;
        }
        const i = self.selectedSplitIndex() orelse return;
        if (self.detailActive(i)) {
            try self.detailInput(allocator, i, key, root_focus);
        } else {
            try self.listInput(i, key, root_focus);
        }
    }

    // arrow keys move the tag selection; up from the top row crosses to the
    // header tabs.
    fn tagsViewInput(self: *View, key: Key, root_focus: *Focus) void {
        const tf = self.tagsView();
        const cid = tf.focus.child_id orelse return;
        const cur = tf.indexOfFocusId(cid) orelse return;
        const count = tf.text_boxes.items.len;
        switch (key) {
            .arrow_left => if (cur > 0) root_focus.setFocus(tf.text_boxes.items[cur - 1].getFocus().id),
            .arrow_right => if (cur + 1 < count) root_focus.setFocus(tf.text_boxes.items[cur + 1].getFocus().id),
            .arrow_up => if (tf.rowStep(cur, false)) |i| root_focus.setFocus(tf.text_boxes.items[i].getFocus().id) else self.focusHeader(root_focus),
            .arrow_down => if (tf.rowStep(cur, true)) |i| root_focus.setFocus(tf.text_boxes.items[i].getFocus().id),
            .home => root_focus.setFocus(tf.text_boxes.items[0].getFocus().id),
            .end => root_focus.setFocus(tf.text_boxes.items[count - 1].getFocus().id),
            else => {},
        }
    }

    fn listInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the detail pane. up from
        // the top row crosses into the header tabs.
        if (inp.rowDelta(key, @intCast(self.listBox(index).children.count()))) |delta| {
            const lb = self.listBox(index);
            const at_top = if (lb.getFocus().child_id) |cid| lb.children.getIndex(cid) == 0 else true;
            if (delta < 0 and at_top) return self.focusHeader(root_focus);
            ui.moveRowFocus(lb, self.listScroll(index), root_focus, delta);
            return;
        }
        switch (key) {
            .enter, .arrow_right => try self.focusDetail(index, root_focus),
            else => {},
        }
    }

    fn detailInput(self: *View, allocator: std.mem.Allocator, index: usize, key: Key, root_focus: *Focus) !void {
        if (self.toolRowFocused(index)) {
            try self.toolRowInput(allocator, index, key, root_focus);
        } else if (self.titleFocused(index)) {
            try self.titleInput(index, key, root_focus);
        } else if (self.authorFocused(index)) {
            try self.authorInput(index, key, root_focus);
        } else if (self.tagsFocused(index)) {
            try self.tagsInput(index, key, root_focus);
        } else {
            try self.descriptionInput(index, key, root_focus);
        }
    }

    // the tool row: enter or a click on the open/close button flips the
    // issue's status; the edit and resolve buttons are a: links the host
    // follows. arrows cross between the buttons and to the neighboring
    // widgets.
    fn toolRowInput(self: *View, allocator: std.mem.Allocator, index: usize, key: Key, root_focus: *Focus) !void {
        const row = self.toolRow(index);
        const cur = if (row.getFocus().child_id) |cid| row.children.getIndex(cid) orelse return else return;
        const on_status = cur == button_in_row_index and self.statusButton(index) != null;
        switch (key) {
            .arrow_left => if (cur > button_in_row_index) root_focus.setFocus(row.children.keys()[cur - 1]) else try self.focusList(index, root_focus),
            .arrow_right => if (cur + 1 < row.children.count()) root_focus.setFocus(row.children.keys()[cur + 1]),
            .arrow_up => self.focusHeader(root_focus),
            .arrow_down => self.focusTitle(index, root_focus),
            .enter => if (on_status) try self.toggleIssueStatus(allocator, index),
            .mouse => |mouse| if (self.statusButton(index)) |button| {
                if (inp.leftClickOn(root_focus, button.getFocus().id, mouse)) try self.toggleIssueStatus(allocator, index);
            },
            else => {},
        }
    }

    fn titleInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        switch (key) {
            .arrow_left => try self.focusList(index, root_focus),
            .arrow_up => self.focusToolRow(index, root_focus),
            .arrow_down => if (self.authorPresent(index)) self.focusAuthor(index, root_focus) else try self.focusDescription(index, root_focus),
            else => {},
        }
    }

    // the author box's a: link (when it has one) is followed by the host on
    // enter / a click; arrows cross to the neighboring widgets.
    fn authorInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        switch (key) {
            .arrow_left => try self.focusList(index, root_focus),
            .arrow_up => self.focusTitle(index, root_focus),
            .arrow_down => if (self.tagFlow(index) != null) try self.focusTags(index, root_focus) else try self.focusDescription(index, root_focus),
            else => {},
        }
    }

    fn descriptionInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        const sc = self.detailScroll(index);
        switch (key) {
            .arrow_left => return self.focusList(index, root_focus),
            // once the scroll can't move further, cross into the tags (or the
            // open/close button when the issue has none).
            .arrow_up => {
                const before = sc.y;
                sc.y -= 1;
                sc.clampToContent();
                if (sc.y == before) {
                    if (self.tagFlow(index) != null)
                        try self.focusTags(index, root_focus)
                    else if (self.authorPresent(index))
                        self.focusAuthor(index, root_focus)
                    else
                        self.focusTitle(index, root_focus);
                }
                return;
            },
            .arrow_down => sc.y += 1,
            .page_up => sc.y -= 10,
            .page_down => sc.y += 10,
            .home => sc.y = 0,
            .end => sc.y = std.math.maxInt(isize),
            else => return,
        }
        sc.clampToContent();
    }

    // up/down (and tab/shift+tab) move between a form's fields; up from the
    // title crosses into the header tabs. the multiline description keeps
    // enter and any up/down that has a row to move to.
    fn formInput(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const form = self.issueForm() orelse return;
        const cid = form.getFocus().child_id orelse return;
        const cur = form.children.getIndex(cid) orelse return;

        if (cur == description_field_index) {
            const child = &form.children.values()[cur];
            if (try multilineKeepsKey(&child.widget.text_input, allocator, key))
                return child.widget.input(allocator, key, root_focus);
        }

        switch (key) {
            .arrow_up, .back_tab => if (cur > 0)
                root_focus.setFocus(form.children.keys()[cur - 1])
            else
                self.focusHeader(root_focus),
            .arrow_down, .tab => if (cur < submit_field_index) {
                root_focus.setFocus(form.children.keys()[cur + 1]);
            },
            .enter => if (cur == submit_field_index) try self.submitForm(allocator),
            .mouse => |mouse| if (cur == submit_field_index) {
                const submit = &form.children.values()[cur].widget.submit_button;
                if (inp.leftClickOn(root_focus, submit.buttonId(), mouse)) try self.submitForm(allocator);
            },
            else => try form.children.values()[cur].widget.input(allocator, key, root_focus),
        }
    }

    // the multiline hunk inputs keep enter and any up/down that has a row to
    // move to; enter on a "use this" link is a navigation the host follows
    // before this runs.
    fn resolveInput(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const form = self.issueForm() orelse return;
        const cid = form.getFocus().child_id orelse return;
        const cur = form.children.getIndex(cid) orelse return;
        const child = &form.children.values()[cur];

        if (child.widget == .text_input) {
            const ti = &child.widget.text_input;
            if (ti.options.multiline and try multilineKeepsKey(ti, allocator, key))
                return child.widget.input(allocator, key, root_focus);
        }

        const on_submit = child.widget == .submit_button;

        switch (key) {
            .arrow_up, .back_tab => if (resolveStep(form, cur, false)) |i| self.focusResolveChild(form, i, root_focus) else self.focusHeader(root_focus),
            .arrow_down, .tab => if (resolveStep(form, cur, true)) |i| self.focusResolveChild(form, i, root_focus),
            .arrow_left, .arrow_right => switch (child.widget) {
                .box => |*row| {
                    const row_cid = row.getFocus().child_id orelse return;
                    const row_index = row.children.getIndex(row_cid) orelse return;
                    if (key == .arrow_left) {
                        if (row_index > 0) root_focus.setFocus(row.children.keys()[row_index - 1]);
                    } else if (row_index + 1 < row.children.count()) {
                        root_focus.setFocus(row.children.keys()[row_index + 1]);
                    }
                },
                else => try child.widget.input(allocator, key, root_focus),
            },
            .enter => if (on_submit) try self.submitResolution(allocator),
            .mouse => |mouse| if (on_submit) {
                if (inp.leftClickOn(root_focus, child.widget.submit_button.buttonId(), mouse)) try self.submitResolution(allocator);
            },
            else => try child.widget.input(allocator, key, root_focus),
        }
    }

    // a multiline input keeps enter and any up/down that has a row to move to
    fn multilineKeepsKey(text_input: *wgt.TextInput(ui.Widget), allocator: std.mem.Allocator, key: Key) !bool {
        return switch (key) {
            .enter => true,
            .arrow_up => !try text_input.cursorOnFirstRow(allocator),
            .arrow_down => !try text_input.cursorOnLastRow(allocator),
            else => false,
        };
    }

    // the neighboring focusable resolve-form child, skipping the spacer and
    // the blank gap rows
    fn resolveStep(form: *wgt.Box(ui.Widget), cur: usize, down: bool) ?usize {
        var i = cur;
        while (true) {
            if (down) {
                i += 1;
                if (i >= form.children.count()) return null;
            } else {
                if (i == 0) return null;
                i -= 1;
            }
            switch (form.children.values()[i].widget) {
                .spacer, .text => continue,
                else => return i,
            }
        }
    }

    // focus the resolve-form child at `i` (a version row focuses its selected
    // child) and keep it visible on the terminal
    fn focusResolveChild(self: *View, form: *wgt.Box(ui.Widget), i: usize, root_focus: *Focus) void {
        const child = &form.children.values()[i];
        switch (child.widget) {
            .box => |*row| root_focus.setFocus(row.getFocus().child_id orelse form.children.keys()[i]),
            else => root_focus.setFocus(form.children.keys()[i]),
        }
        if (self.session.is_terminal) {
            if (self.resolveScroll()) |sc| {
                if (child.rect) |rect| sc.scrollToRect(rect);
            }
        }
    }

    // re-emit the conflicted issue's event with the resolved content; any
    // event on the issue settles its conflict entry. this is the terminal
    // path; the web posts the form to the resolve route.
    fn submitResolution(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;
        const entry = self.data.selectedIssue() orelse return;
        const author_email = (try self.session.eventAuthorEmail()) orelse return;
        const form = self.issueForm() orelse return;

        // gather the inputs by name; the d<n> hunk inputs appear in chunk order
        var title: ?[]u8 = null;
        var tags: ?[]u8 = null;
        var hunks: std.ArrayList([]const u8) = .empty;
        defer {
            if (title) |t| allocator.free(t);
            if (tags) |t| allocator.free(t);
            for (hunks.items) |h| allocator.free(h);
            hunks.deinit(allocator);
        }
        for (form.children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| {
                const text = try ti.text(allocator);
                errdefer allocator.free(text);
                if (std.mem.eql(u8, ti.options.name, "title")) {
                    title = text;
                } else if (std.mem.eql(u8, ti.options.name, "tags")) {
                    tags = text;
                } else {
                    try hunks.append(allocator, text);
                }
            },
            else => {},
        };

        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id_bytes, entry.id[0 .. evt.event_id_size * 2]);

        switch (src.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| evt.Issue.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, .{ .resolve = .{
                        .title = title,
                        .tags = tags,
                        .hunks = hunks.items,
                    } }, author_email) catch |err| switch (err) {
                        // leave the form up for correction
                        error.InvalidFields => return,
                        else => |e| return e,
                    },
                }
            },
        }

        const route = ui.RoutablePage.repoIssuesRoute(self.data.identity, entry.issue.event.status, "", entry.id) orelse return;
        try self.session.navigate(route);
    }

    // the terminal submit paths: the new form commits a new-issue event, the
    // edit form re-emits the selected issue's event with the form's content.
    // the web posts the forms to their routes instead.
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (self.data.view == .edit) {
            try self.submitEditedIssue(allocator);
        } else {
            try self.submitNewIssue(allocator);
        }
    }

    // commit the new issue to the repo's events branch and navigate to it.
    // this is the terminal path; the web posts the form to the issue route,
    // so the wasm side never runs (or compiles) the repo access below.
    fn submitNewIssue(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;
        const author_email = (try self.session.eventAuthorEmail()) orelse return;

        const form = self.issueForm() orelse return;
        const title_input = &form.children.values()[title_field_index].widget.text_input;
        const tags_input = &form.children.values()[tags_field_index].widget.text_input;
        const description_input = &form.children.values()[description_field_index].widget.text_input;

        const title = try title_input.text(allocator);
        defer allocator.free(title);
        const tags = try tags_input.text(allocator);
        defer allocator.free(tags);
        const description = try description_input.text(allocator);
        defer allocator.free(description);

        if (!evt.Issue.fieldsValid(title, tags)) return;

        var id_bytes: [evt.event_id_size]u8 = undefined;
        io.random(&id_bytes);
        const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

        const event = evt.EventWithId{
            .id = event_id_hex,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
            .author_email = author_email,
            .event = .{ .issue = .{
                .title = title,
                .description = description,
                .tags = tags,
            } },
        };

        switch (src.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| try evt.consume(repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{event}),
                }
            },
        }

        // wipe the form so a return visit starts fresh
        title_input.clear(allocator);
        tags_input.clear(allocator);
        description_input.clear(allocator);

        const route = ui.RoutablePage.repoIssuesRoute(self.data.identity, .open, "", &event_id_hex) orelse return;
        try self.session.navigate(route);
    }

    // re-emit the selected issue's event with the form's content (status
    // preserved), then reload the issue's page. this is the terminal path;
    // the web posts the form to the edit route.
    fn submitEditedIssue(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;
        const entry = self.data.selectedIssue() orelse return;
        const author_email = (try self.session.eventAuthorEmail()) orelse return;

        const form = self.issueForm() orelse return;
        const title_input = &form.children.values()[title_field_index].widget.text_input;
        const tags_input = &form.children.values()[tags_field_index].widget.text_input;
        const description_input = &form.children.values()[description_field_index].widget.text_input;

        const title = try title_input.text(allocator);
        defer allocator.free(title);
        const tags = try tags_input.text(allocator);
        defer allocator.free(tags);
        const description = try description_input.text(allocator);
        defer allocator.free(description);

        if (!evt.Issue.fieldsValid(title, tags)) return;

        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id_bytes, entry.id[0 .. evt.event_id_size * 2]);

        switch (src.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| try evt.Issue.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, .{ .fields = .{
                        .title = title,
                        .tags = tags,
                        .description = description,
                    } }, author_email),
                }
            },
        }

        const route = ui.RoutablePage.repoIssuesRoute(self.data.identity, entry.issue.event.status, "", entry.id) orelse return;
        try self.session.navigate(route);
    }

    // flip the shown issue's status by re-emitting its event, then reload the
    // page rooted at the issue so the view reflects the change. this is the
    // terminal path; the web posts the button's form to the status route.
    fn toggleIssueStatus(self: *View, allocator: std.mem.Allocator, index: usize) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;
        const sel = self.detailed_index[index] orelse return;
        const entry = self.window(index).issues[sel];
        const author_email = (try self.session.eventAuthorEmail()) orelse return;

        const status: evt.Issue.Status = switch (entry.issue.event.status) {
            .open => .closed,
            .closed => .open,
        };

        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id_bytes, entry.id[0 .. evt.event_id_size * 2]);

        switch (src.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| try evt.Issue.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, .{ .status = status }, author_email),
                }
            },
        }

        const route = ui.RoutablePage.repoIssuesRoute(self.data.identity, status, "", entry.id) orelse return;
        try self.session.navigate(route);
    }

    // arrow keys move the tag selection; at the flow's edges focus crosses to
    // the neighboring widgets.
    fn tagsInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        const tf = self.tagFlow(index) orelse return;
        const cid = tf.focus.child_id orelse return;
        const cur = tf.indexOfFocusId(cid) orelse return;
        const count = tf.text_boxes.items.len;
        switch (key) {
            .arrow_left => if (cur > 0) self.focusTag(index, tf, root_focus, cur - 1) else try self.focusList(index, root_focus),
            .arrow_right => if (cur + 1 < count) self.focusTag(index, tf, root_focus, cur + 1),
            .arrow_up => if (tf.rowStep(cur, false)) |i| self.focusTag(index, tf, root_focus, i) else self.focusAuthor(index, root_focus),
            .arrow_down => if (tf.rowStep(cur, true)) |i| self.focusTag(index, tf, root_focus, i) else try self.focusDescription(index, root_focus),
            .home => self.focusTag(index, tf, root_focus, 0),
            .end => self.focusTag(index, tf, root_focus, count - 1),
            else => {},
        }
    }

    const button_in_row_index: usize = 1;
    const title_child_index: usize = 0;
    const tags_child_index: usize = 2;

    fn tagFlow(self: *View, index: usize) ?*ui.TagFlow {
        const inner = self.detailInner(index);
        if (inner.children.count() <= tags_child_index) return null;
        return switch (inner.children.values()[tags_child_index].widget) {
            .tag_flow => |*tf| tf,
            else => null,
        };
    }

    fn tagsFocused(self: *View, index: usize) bool {
        const inner = self.detailInner(index);
        const cid = inner.getFocus().child_id orelse return false;
        return inner.children.getIndex(cid) == tags_child_index and self.tagFlow(index) != null;
    }

    // the open/close button inside the detail frame's tool row, identified
    // by its posting kind; a logged-out session's or conflicted issue's row
    // has none.
    fn statusButton(self: *View, index: usize) ?*wgt.TextBox(ui.Widget) {
        const row = self.toolRow(index);
        if (row.children.count() <= button_in_row_index) return null;
        switch (row.children.values()[button_in_row_index].widget) {
            .text_box => |*tb| switch (tb.box.focus.kind) {
                .custom => |custom| if (std.mem.eql(u8, custom, "submit")) return tb,
                else => {},
            },
            else => {},
        }
        return null;
    }

    fn toolRowFocused(self: *View, index: usize) bool {
        const outer = self.detailOuter(index);
        const cid = outer.getFocus().child_id orelse return false;
        return outer.children.getIndex(cid) == tool_row_index;
    }

    fn focusTag(self: *View, index: usize, tf: *ui.TagFlow, root_focus: *Focus, item: usize) void {
        root_focus.setFocus(tf.text_boxes.items[item].getFocus().id);
        // keep the tag visible on the terminal: its rect offset by the flow's
        // position in the pane.
        if (self.session.is_terminal and item < tf.rects.items.len) {
            if (self.detailInner(index).children.values()[tags_child_index].rect) |flow_rect| {
                var rect = tf.rects.items[item];
                rect.x += flow_rect.x;
                rect.y += flow_rect.y;
                self.detailScroll(index).scrollToRect(rect);
            }
        }
    }

    fn titleFocused(self: *View, index: usize) bool {
        const inner = self.detailInner(index);
        const cid = inner.getFocus().child_id orelse return false;
        return inner.children.getIndex(cid) == title_child_index;
    }

    fn authorPresent(self: *View, index: usize) bool {
        return self.author_id[index] != null;
    }

    fn authorFocused(self: *View, index: usize) bool {
        const inner = self.detailInner(index);
        const cid = inner.getFocus().child_id orelse return false;
        return cid == self.author_id[index];
    }

    // the author sits right under the title at the top of the pane, so
    // focusing it scrolls there.
    fn focusAuthor(self: *View, index: usize, root_focus: *Focus) void {
        const id = self.author_id[index] orelse return;
        root_focus.setFocus(id);
        self.detailScroll(index).y = 0;
    }

    // the title sits at the top of the pane, so focusing it scrolls there.
    fn focusTitle(self: *View, index: usize, root_focus: *Focus) void {
        const inner = self.detailInner(index);
        if (inner.children.count() == 0) return;
        root_focus.setFocus(inner.children.keys()[title_child_index]);
        self.detailScroll(index).y = 0;
    }

    fn focusTags(self: *View, index: usize, root_focus: *Focus) !void {
        const tf = self.tagFlow(index) orelse return;
        if (tf.text_boxes.items.len == 0) return;
        const cid = tf.focus.child_id orelse tf.text_boxes.items[0].getFocus().id;
        const item = tf.indexOfFocusId(cid) orelse 0;
        self.focusTag(index, tf, root_focus, item);
    }

    fn focusDescription(self: *View, index: usize, root_focus: *Focus) !void {
        if (self.description_id[index]) |id| root_focus.setFocus(id);
    }

    // return to the tool row's last-focused button (the header when the
    // description page shows no row).
    fn focusToolRow(self: *View, index: usize, root_focus: *Focus) void {
        const cid = self.toolRow(index).getFocus().child_id orelse return self.focusHeader(root_focus);
        root_focus.setFocus(cid);
    }

    // enter the detail pane. an empty pane (no issues) can't be entered.
    fn focusDetail(self: *View, index: usize, root_focus: *Focus) !void {
        if (self.detailInner(index).children.count() == 0) return;
        root_focus.setFocus(self.detailOuter(index).getFocus().id);
    }

    // return to the list.
    fn focusList(self: *View, index: usize, root_focus: *Focus) !void {
        root_focus.setFocus(self.listScroll(index).getFocus().id);
    }

    // cross to the header tabs above the stack.
    fn focusHeader(self: *View, root_focus: *Focus) void {
        root_focus.setFocus(self.box.children.keys()[header_index]);
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

    // for the parent's "scroll up at the top jumps to the header" check: at the
    // top only while the header tabs hold focus, so up from the split
    // crosses into the tabs first.
    pub fn getSelectedIndex(self: *View) ?usize {
        return if (self.headerActive()) 0 else 1;
    }
};

// the "a:" navigation link for `status`'s issues page filtered to the
// url-encoded `tag` and rooted at issue `id` within `identity` ("owner/name").
// a rooted url ignores `status` (it derives its view from the issue's own);
// with an empty `id` this is the bare list link.
fn issuesLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: evt.Issue.Status, tag: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, status, tag, id) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting issue `id` in `identity`'s list; the
// href is only followed with js off.
fn issueRowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, .open, "", id) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

// the "a:" link to the window `status_maybe` names, keeping the tag filter,
// or the conflicts window when null, rooted at issue `id`.
fn windowLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, status_maybe: ?evt.Issue.Status, id: []const u8) ![]const u8 {
    if (status_maybe) |status| return issuesLink(page_arena, data.identity, status, data.tag, id);
    return conflictsLink(page_arena, data.identity, id);
}

// the "a:" link to the conflicts list rooted at issue `start` ("" = the
// first window).
fn conflictsLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, start: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesConflictsRoute(identity, start) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "a:" link to the whole-description page of issue `id` within `identity`.
fn descriptionLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesDescriptionRoute(identity, id) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "a:" link to `status`'s issues list filtered to `tag` (raw; encoded here).
fn tagLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: evt.Issue.Status, tag: []const u8) ![]const u8 {
    const encoded = try ui.urlEncodeRef(page_arena.allocator(), tag);
    const route = ui.RoutablePage.repoIssuesRoute(identity, status, encoded, "") orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

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
            const tags_route = ui.RoutablePage.repoIssuesTagsRoute(data.identity, data.tag) orelse return error.RouteTooLong;
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
                .edit => ui.RoutablePage.repoIssuesEditRoute(data.identity, data.selected_id) orelse return error.RouteTooLong,
                .resolve => ui.RoutablePage.repoIssuesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
                else => ui.RoutablePage.repoIssuesNewRoute(data.identity) orelse return error.RouteTooLong,
            };
            const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
            const label: []const u8 = switch (data.view) {
                .edit => "edit",
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

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

const wasm = builtin.target.cpu.arch == .wasm32;

// how many issues one window shows before a "next" link appears.
pub const page_size = 20;

// how many tags the tags view shows at most.
pub const max_tags = 1000;

// one issue from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const IssueWithId = struct {
    id: []const u8,
    issue: evt.Issue,
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
// the view the page shows initially (a selected issue's status overrides the route's)
view: ui.RoutablePage.IssuesView,
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

// an empty listing, for the wasm / no-repo paths.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, tag: []const u8, selected_id: []const u8, view: ui.RoutablePage.IssuesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
        .open = .empty,
        .closed = .empty,
        .view = view,
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
    identity: []const u8,
    tag: []const u8,
    selected_id: []const u8,
    view: ui.RoutablePage.IssuesView,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, selected_id, view);

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

    // a named issue roots its own status's window at itself; the other window
    // starts at the beginning.
    var resolved_view = empty.view;
    var open_root: ?[]const u8 = null;
    var closed_root: ?[]const u8 = null;
    if (rooted) {
        if (empty.selected_id.len != evt.event_id_size * 2) return error.NotFound;
        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id_bytes, empty.selected_id) catch return error.NotFound;
        const issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
        const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
        const issue_event = try evt.read(evt.Issue, DB, repo_opts.hash, arena, issue_map);
        const order_key = try aa.dupe(u8, &evt.orderKeyDesc(issue_event.created_ts, &id_bytes));

        // the named issue must be in its windowed set (a tag url can name an
        // issue that doesn't carry the tag).
        const set = (switch (issue_event.status) {
            .open => open_set,
            .closed => closed_set,
        }) orelse return error.NotFound;
        if (!try set.contains(order_key)) return error.NotFound;

        switch (issue_event.status) {
            .open => {
                open_root = order_key;
                resolved_view = .open;
            },
            .closed => {
                closed_root = order_key;
                resolved_view = .closed;
            },
        }
    }

    const open_window = try loadWindow(repo_opts.hash, arena, event_id_to_issue, open_set, open_root);
    const closed_window = try loadWindow(repo_opts.hash, arena, event_id_to_issue, closed_set, closed_root);

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
        .view = resolved_view,
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
    event_id_to_issue: evt.EventDB(hash_kind).HashMap(.read_only),
    set_maybe: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    root_key: ?[]const u8,
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
        try issues.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .issue = try evt.read(evt.Issue, DB, hash_kind, arena, issue_map),
        });
    }

    return .{
        .issues = issues.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

pub const View = struct {
    // a vertical box: the header tabs on top, then a stack holding a
    // master-detail split (issue list + description pane) per status list,
    // plus the tags view.
    box: wgt.Box(ui.Widget), // vert: [header_index] = tabs, [stack_index] = stack
    data: *const Self,
    session: *ui.Session,
    // per-split state, indexed like the stack's split children: the issue the
    // pane shows, and its description text box's focus id.
    detailed_index: [split_count]?usize,
    description_id: [split_count]?usize,

    const header_index: usize = 0;
    const stack_index: usize = 1;
    // indices within the stack, 1:1 with the header tabs.
    const open_view_index: usize = 0;
    const closed_view_index: usize = 1;
    const tags_view_index: usize = 2;
    const new_view_index: usize = 3;
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
            .new => new_view_index,
        };
    }

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
                try items.append(allocator, .{ .text = "╳", .link = try issuesLink(session.page_arena, data.identity, .open, "", "") });
            for (data.tags) |tag|
                try items.append(allocator, .{ .text = tag, .link = try tagLink(session.page_arena, data.identity, .open, tag) });
            try tf.setItems(allocator, items.items);
            try stack.children.put(allocator, tf.getFocus().id, .{ .tag_flow = tf });
        }

        // the new-issue form
        {
            var form = try initNewForm(allocator, session, data);
            errdefer form.deinit(allocator);
            try stack.children.put(allocator, form.getFocus().id, .{ .box = form });
        }

        // the stack starts on the page's view.
        stack.getFocus().child_id = stack.children.keys()[viewIndex(data.view)];

        // focus entering the view lands on the tabs first.
        outer.getFocus().child_id = outer.children.keys()[header_index];

        return .{
            .box = outer,
            .data = data,
            .session = session,
            .detailed_index = .{ null, null },
            .description_id = .{ null, null },
        };
    }

    // the master-detail split showing `status`'s window.
    fn initSplit(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self, status: evt.Issue.Status) !wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        const win = data.window(status);

        // the issue list (one focusable row per title), plus a "next" link that
        // reloads the page rooted at the following issue.
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                if (win.prev_id) |prev|
                    try addRow(allocator, &list_box, "← previous", try issuesLink(session.page_arena, data.identity, status, data.tag, prev));
                for (win.issues) |entry|
                    try addRow(allocator, &list_box, entry.issue.title, try issueRowLink(session.page_arena, data.identity, entry.id));
                if (win.next_id) |next|
                    try addRow(allocator, &list_box, "next →", try issuesLink(session.page_arena, data.identity, status, data.tag, next));
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

    // the new-issue form: title/tags/description inputs and a submit button.
    // its form: subtree makes the web overlay wrap them in a <form> POSTing to
    // the issue route.
    fn initNewForm(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !wgt.Box(ui.Widget) {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = if (data.identity.len == 0)
            "form:/issue"
        else
            try std.fmt.allocPrint(session.page_arena.allocator(), "form:/repo/{s}/issue", .{data.identity}) };

        {
            var title = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " title ", .name = "title", .visible_width = null, .rounded_corners = true, .render_content = !wasm });
            errdefer title.deinit(allocator);
            title.getFocus().focusable = true;
            try box.children.put(allocator, title.getFocus().id, .{ .widget = .{ .text_input = title }, .rect = null, .min_size = null });
        }

        {
            var tags = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " tags (separate with spaces) ", .name = "tags", .visible_width = null, .rounded_corners = true, .render_content = !wasm });
            errdefer tags.deinit(allocator);
            tags.getFocus().focusable = true;
            try box.children.put(allocator, tags.getFocus().id, .{ .widget = .{ .text_input = tags }, .rect = null, .min_size = null });
        }

        {
            var description = try wgt.TextInput(ui.Widget).init(allocator, .{ .label = " description ", .name = "description", .visible_width = null, .rounded_corners = true, .render_content = !wasm, .multiline = true, .visible_height = 5 });
            errdefer description.deinit(allocator);
            description.getFocus().focusable = true;
            try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = null });
        }

        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, "submit", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            // the renderer distinguishes plain clickables from buttons that
            // should POST to a server route by this kind.
            button.getFocus().kind = .{ .custom = "submit" };
            try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
        }

        // absorbs the leftover min-height the box hands its last child, so
        // the button keeps its natural height
        {
            var spacer = try ui.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
        }

        box.getFocus().child_id = box.children.keys()[title_field_index];
        return box;
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
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

    // the new-issue form inside the stack.
    fn newForm(self: *View) *wgt.Box(ui.Widget) {
        return &self.viewStack().children.values()[new_view_index].box;
    }

    fn listScroll(self: *View, index: usize) *wgt.Scroll(ui.Widget) {
        return &self.resultsBox(index).children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.listScroll(index).child.box;
    }

    fn detailOuter(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.resultsBox(index).children.values()[detail_index].widget.box;
    }

    fn detailScroll(self: *View, index: usize) *wgt.Scroll(ui.Widget) {
        return &self.detailOuter(index).children.values()[0].widget.scroll;
    }

    fn detailInner(self: *View, index: usize) *wgt.Box(ui.Widget) {
        return &self.detailScroll(index).child.box;
    }

    fn window(self: *View, index: usize) *const Window {
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
        return if (idx < split_count) idx else null;
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

    fn newViewActive(self: *View) bool {
        if (self.headerActive()) return false;
        return self.stackSelectedIndex() == new_view_index;
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
            self.session.data.current_page = (if (index == viewIndex(self.data.view) and self.data.selected_id.len != 0)
                ui.RoutablePage.repoIssuesRoute(self.data.identity, .open, self.data.tag, self.data.selected_id)
            else if (index == tags_view_index)
                ui.RoutablePage.repoIssuesTagsRoute(self.data.identity, self.data.tag)
            else if (index == new_view_index)
                ui.RoutablePage.repoIssuesNewRoute(self.data.identity)
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
                        if (ui.RoutablePage.repoIssuesRoute(self.data.identity, splitStatus(i), "", self.window(i).issues[sel].id)) |route|
                            self.session.data.current_page = route;
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
            const inner = self.detailInner(i);
            for (inner.children.keys(), inner.children.values()) |id, *child| {
                switch (child.widget) {
                    .text_box => |*tb| tb.options.border_style = if (inner.getFocus().child_id == id) .single else .hidden,
                    else => {},
                }
            }
            if (self.tagFlow(i)) |tf| tf.selected = self.tagsFocused(i);

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

        self.tagsView().selected = self.tagsViewActive();

        // refresh the form inputs' entries in the session's focus-id -> input
        // map with this frame's addresses, so the web/wasm form handling can
        // find them by focus id
        const form = self.newForm();
        const inputs_arena = self.session.arena.allocator();
        for (form.children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
            else => {},
        };

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

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        // the open/close button
        {
            const action: []const u8 = switch (entry.issue.status) {
                .open => "close",
                .closed => "open",
            };
            var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer row.deinit(allocator);
            const pa = self.session.page_arena.allocator();
            row.getFocus().kind = .{ .custom = if (self.data.identity.len == 0)
                try std.fmt.allocPrint(pa, "form:/issues/{s}/{s}", .{ entry.id, action })
            else
                try std.fmt.allocPrint(pa, "form:/repo/{s}/issues/{s}/{s}", .{ self.data.identity, entry.id, action }) };

            {
                var spacer = try ui.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try row.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }

            {
                var button = try wgt.TextBox(ui.Widget).init(allocator, action, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().focusable = true;
                // the renderer distinguishes plain clickables from buttons that
                // should POST to a server route by this kind.
                button.getFocus().kind = .{ .custom = "submit" };
                try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = action.len + 2, .height = null } });
            }

            row.getFocus().child_id = row.children.keys()[button_in_row_index];
            try inner.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
        }

        // the issue's tags, each linking to this status's list filtered to
        // that tag.
        {
            var items: std.ArrayList(ui.TagFlow.Item) = .empty;
            defer items.deinit(allocator);
            var tag_iter = evt.Issue.tagIterator(entry.issue.tags);
            while (tag_iter.next()) |tag| {
                if (tag.len == 0) continue;
                try items.append(allocator, .{ .text = tag, .link = try tagLink(self.session.page_arena, self.data.identity, splitStatus(index), tag) });
            }
            if (items.items.len > 0) {
                var tf = try ui.TagFlow.init(allocator);
                errdefer tf.deinit(allocator);
                try tf.setItems(allocator, items.items);
                try inner.children.put(allocator, tf.getFocus().id, .{ .widget = .{ .tag_flow = tf }, .rect = null, .min_size = null });
            }
        }

        // the description as a focusable word-wrapped text box. its hidden
        // border reserves the space the border occupies when focused, so
        // focusing doesn't shift layout.
        self.description_id[index] = blk: {
            const description = if (entry.issue.description.len == 0) "(no description)" else entry.issue.description;
            var tb = try wgt.TextBox(ui.Widget).init(allocator, description, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
            break :blk tb.getFocus().id;
        };

        // select the description by default
        inner.getFocus().child_id = self.description_id[index];

        // reset the scroll to the top for the newly-shown issue: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll(index);
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (self.headerActive()) {
            // down from the tabs re-enters the stack if the selected view has
            // something to focus; other keys move the tabs.
            if (inp.vertDirection(key) == .down) {
                const enterable = if (self.viewStack().getSelected()) |selected| switch (selected.*) {
                    .tag_flow => |*tf| tf.text_boxes.items.len > 0,
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
        if (self.newViewActive()) {
            try self.newViewInput(allocator, key, root_focus);
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
        if (self.statusButtonFocused(index)) {
            try self.statusButtonInput(allocator, index, key, root_focus);
        } else if (self.tagsFocused(index)) {
            try self.tagsInput(index, key, root_focus);
        } else {
            try self.descriptionInput(index, key, root_focus);
        }
    }

    // the open/close button: enter or a click flips the issue's status;
    // arrows cross to the neighboring widgets.
    fn statusButtonInput(self: *View, allocator: std.mem.Allocator, index: usize, key: Key, root_focus: *Focus) !void {
        switch (key) {
            .arrow_left => try self.focusList(index, root_focus),
            .arrow_up => self.focusHeader(root_focus),
            .arrow_down => if (self.tagFlow(index) != null) try self.focusTags(index, root_focus) else try self.focusDescription(index, root_focus),
            .enter => try self.toggleIssueStatus(allocator, index),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| {
                    const sc = self.detailScroll(index);
                    sc.y += if (dir == .up) @as(isize, -1) else 1;
                    sc.clampToContent();
                },
                else => if (self.statusButton(index)) |button| {
                    if (inp.leftClickOn(root_focus, button.getFocus().id, mouse)) try self.toggleIssueStatus(allocator, index);
                },
            },
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
                    if (self.tagFlow(index) != null) try self.focusTags(index, root_focus) else self.focusStatusButton(index, root_focus);
                }
                return;
            },
            .arrow_down => sc.y += 1,
            .page_up => sc.y -= 10,
            .page_down => sc.y += 10,
            .home => sc.y = 0,
            .end => sc.y = std.math.maxInt(isize),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| sc.y += if (dir == .up) @as(isize, -1) else 1,
                else => {},
            },
            else => return,
        }
        sc.clampToContent();
    }

    // up/down (and tab/shift+tab) move between the form's fields; up from the
    // title crosses into the header tabs. the multiline description keeps
    // enter and any up/down that has a row to move to.
    fn newViewInput(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const form = self.newForm();
        const cid = form.getFocus().child_id orelse return;
        const cur = form.children.getIndex(cid) orelse return;

        if (cur == description_field_index) {
            const child = &form.children.values()[cur];
            const description = &child.widget.text_input;
            switch (key) {
                .enter => return child.widget.input(allocator, key, root_focus),
                .arrow_up => if (!try description.cursorOnFirstRow(allocator))
                    return child.widget.input(allocator, key, root_focus),
                .arrow_down => if (!try description.cursorOnLastRow(allocator))
                    return child.widget.input(allocator, key, root_focus),
                else => {},
            }
        }

        switch (key) {
            .arrow_up, .back_tab => if (cur > 0)
                root_focus.setFocus(form.children.keys()[cur - 1])
            else
                self.focusHeader(root_focus),
            .arrow_down, .tab => if (cur < submit_field_index) {
                root_focus.setFocus(form.children.keys()[cur + 1]);
            },
            .enter => if (cur == submit_field_index) try self.submitNewIssue(allocator),
            .mouse => |mouse| if (cur == submit_field_index and inp.leftClickOn(root_focus, cid, mouse)) {
                try self.submitNewIssue(allocator);
            },
            else => try form.children.values()[cur].widget.input(allocator, key, root_focus),
        }
    }

    // commit the new issue to the repo's events branch and navigate to it.
    // this is the terminal path; the web posts the form to the issue route,
    // so the wasm side never runs (or compiles) the repo access below.
    fn submitNewIssue(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;

        const form = self.newForm();
        const title_input = &form.children.values()[title_field_index].widget.text_input;
        const tags_input = &form.children.values()[tags_field_index].widget.text_input;
        const description_input = &form.children.values()[description_field_index].widget.text_input;

        const title = try title_input.text(allocator);
        defer allocator.free(title);
        const tags = try tags_input.text(allocator);
        defer allocator.free(tags);
        const description = try description_input.text(allocator);
        defer allocator.free(description);

        // a title is required, and a too-long tag would fail consumption
        // after the event is already committed
        if (title.len == 0) return;
        var tag_iter = evt.Issue.tagIterator(tags);
        while (tag_iter.next()) |tag| {
            if (tag.len > evt.Issue.tag_max_len) return;
        }

        var id_bytes: [evt.event_id_size]u8 = undefined;
        io.random(&id_bytes);
        const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

        const event = evt.EventWithId{
            .id = event_id_hex,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
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
                    inline else => |*repo| try evt.commitAndConsume(repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{event}),
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

    // flip the shown issue's status by re-emitting its event, then reload the
    // page rooted at the issue so the view reflects the change. this is the
    // terminal path; the web posts the button's form to the status route.
    fn toggleIssueStatus(self: *View, allocator: std.mem.Allocator, index: usize) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const src = self.data.repo_source orelse return;
        const sel = self.detailed_index[index] orelse return;
        const entry = self.window(index).issues[sel];

        var updated = entry.issue;
        updated.status = switch (entry.issue.status) {
            .open => .closed,
            .closed => .open,
        };

        const event = evt.EventWithId{
            .id = entry.id[0 .. evt.event_id_size * 2].*,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
            .event = .{ .issue = updated },
        };

        switch (src.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| try evt.commitAndConsume(repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{event}),
                }
            },
        }

        const route = ui.RoutablePage.repoIssuesRoute(self.data.identity, updated.status, "", entry.id) orelse return;
        try self.session.navigate(route);
    }

    // arrow keys move the tag selection; at the flow's edges focus crosses to
    // the neighboring widgets.
    fn tagsInput(self: *View, index: usize, key: Key, root_focus: *Focus) !void {
        const tf = self.tagFlow(index) orelse return;
        const cid = tf.focus.child_id orelse return;
        const cur = tf.indexOfFocusId(cid) orelse return;
        const count = tf.text_boxes.items.len;
        const sc = self.detailScroll(index);
        switch (key) {
            .arrow_left => if (cur > 0) self.focusTag(index, tf, root_focus, cur - 1) else try self.focusList(index, root_focus),
            .arrow_right => if (cur + 1 < count) self.focusTag(index, tf, root_focus, cur + 1),
            .arrow_up => if (tf.rowStep(cur, false)) |i| self.focusTag(index, tf, root_focus, i) else self.focusStatusButton(index, root_focus),
            .arrow_down => if (tf.rowStep(cur, true)) |i| self.focusTag(index, tf, root_focus, i) else try self.focusDescription(index, root_focus),
            .home => self.focusTag(index, tf, root_focus, 0),
            .end => self.focusTag(index, tf, root_focus, count - 1),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| {
                    sc.y += if (dir == .up) @as(isize, -1) else 1;
                    sc.clampToContent();
                },
                else => {},
            },
            else => {},
        }
    }

    const button_row_index: usize = 0;
    const button_in_row_index: usize = 1;
    const tags_child_index: usize = 1;

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

    // the open/close button inside the detail pane's leading row.
    fn statusButton(self: *View, index: usize) ?*wgt.TextBox(ui.Widget) {
        const inner = self.detailInner(index);
        if (inner.children.count() == 0) return null;
        const row = &inner.children.values()[button_row_index].widget.box;
        return &row.children.values()[button_in_row_index].widget.text_box;
    }

    fn statusButtonFocused(self: *View, index: usize) bool {
        const inner = self.detailInner(index);
        const cid = inner.getFocus().child_id orelse return false;
        return inner.children.getIndex(cid) == button_row_index;
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

    fn focusStatusButton(self: *View, index: usize, root_focus: *Focus) void {
        if (self.statusButton(index)) |button| root_focus.setFocus(button.getFocus().id);
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

        // tags tab, labeled with the active tag filter
        {
            const tags_route = ui.RoutablePage.repoIssuesTagsRoute(data.identity, data.tag) orelse return error.RouteTooLong;
            const tags_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try tags_route.toUrl(session.page_arena)});
            const label = if (data.tag.len == 0) "tags" else blk: {
                const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
                break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
            };
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = tags_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = label.len + 2, .height = null },
            });
        }

        // new-issue tab
        {
            const new_route = ui.RoutablePage.repoIssuesNewRoute(data.identity) orelse return error.RouteTooLong;
            const new_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try new_route.toUrl(session.page_arena)});
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, "new", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            text_box.getFocus().kind = .{ .custom = new_link };
            try tab_ids.put(allocator, text_box.getFocus().id, {});
            try box.children.put(allocator, text_box.getFocus().id, .{
                .widget = .{ .text_box = text_box },
                .rect = null,
                .min_size = .{ .width = "new".len + 2, .height = null },
            });
        }

        var self = Header{ .box = box, .tab_ids = tab_ids };
        // the tab matching the page's view is selected initially.
        self.getFocus().child_id = self.tab_ids.keys()[View.viewIndex(data.view)];
        return self;
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

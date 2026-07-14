const std = @import("std");
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

// how many issues one window shows before a "next" link appears.
pub const page_size = 20;

// one issue from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const IssueWithId = struct {
    id: []const u8,
    issue: evt.Issue,
};

// "owner/name", so the view can build /repo/owner/name/issues/... links.
identity: []const u8,
// the url-encoded tag the list is filtered to ("" = unfiltered).
tag: []const u8,
// the hex event id of the issue this window is rooted at ("" = the first
// window), mirrored into the url.
selected_id: []const u8,
issues: []const IssueWithId,
// the id of the previous window's first issue, or null when this window is
// already the first.
prev_id: ?[]const u8,
// the id of the next window's first issue, or null when this is the last window.
next_id: ?[]const u8,

const Self = @This();

// an empty listing, for the wasm / no-repo paths.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, tag: []const u8, selected_id: []const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
        .issues = &.{},
        .prev_id = null,
        .next_id = null,
    };
}

// read one window of an opened repo's issues (filtered to `tag` when set),
// ordered by creation time (oldest first), starting at the issue
// `selected_id` names ("" = the beginning). a local session reads the event
// db next to the repo (synced from the events branch on each page build);
// a server repo reads its own db.
pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    is_local: bool,
    identity: []const u8,
    tag: []const u8,
    selected_id: []const u8,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, selected_id);

    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const rooted = empty.selected_id.len != 0;
    const tagged = empty.tag.len != 0;
    // an explicitly named issue or tag that doesn't exist is a bad url
    // (NotFound -> 404); the bare route falls through to an empty listing.
    const strict = rooted or tagged;

    // a repo with no consumed events has no moment yet.
    const gpa = arena.child_allocator;
    var event_db_maybe = if (is_local) try evt.LocalEventDB(repo_opts.hash).open(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return empty
    else if (is_local)
        return empty
    else
        evt.currentMoment(repo_opts, repo)) catch {
        if (strict) return error.NotFound;
        return empty;
    };

    // the ordered set to window: the tag's issue set when filtered, else the
    // full issue set.
    const issue_id_set_cursor = blk: {
        if (tagged) {
            const tag_to_issues_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "tag->issue-id-set")) orelse return error.NotFound;
            const tag_to_issues = try DB.SortedMap(.read_only).init(tag_to_issues_cursor);
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, empty.tag));
            break :blk (try tag_to_issues.getCursor(decoded)) orelse return error.NotFound;
        }
        break :blk (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "issue-id-set"))) orelse {
            if (strict) return error.NotFound;
            return empty;
        };
    };
    const issue_id_set = try DB.SortedSet(.read_only).init(issue_id_set_cursor);

    const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse {
        if (strict) return error.NotFound;
        return empty;
    };
    const event_id_to_issue = try DB.HashMap(.read_only).init(event_id_to_issue_cursor);

    // seek once to the window start: the named issue's order key (its recorded
    // creation timestamp plus its id, so the seek lands on it), or the set's
    // first entry.
    var prev_id: ?[]const u8 = null;
    var iter = if (!rooted)
        try issue_id_set.iteratorFromIndex(0)
    else blk: {
        if (empty.selected_id.len != evt.event_id_size * 2) return error.NotFound;
        var id_bytes: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id_bytes, empty.selected_id) catch return error.NotFound;
        const issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
        const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
        const issue_event = try evt.read(evt.Issue, DB, repo_opts.hash, arena, issue_map);
        const order_key = evt.orderKey(issue_event.created_ts, &id_bytes);

        // the named issue must be in the windowed set (a tag url can name an
        // issue that doesn't carry the tag).
        if (!try issue_id_set.contains(&order_key)) return error.NotFound;

        // the previous window starts page_size ranks back.
        const rank = try issue_id_set.rank(&order_key);
        if (rank > 0) {
            const prev_rank = rank -| page_size;
            const kv = try issue_id_set.getIndexKeyValuePair(@intCast(prev_rank)) orelse return error.NotFound;
            var prev_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try kv.key_cursor.readBytes(&prev_key);
            const prev_hex = std.fmt.bytesToHex(prev_key[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &prev_hex);
        }

        break :blk try issue_id_set.iteratorFrom(&order_key);
    };

    // collect this window's issues, plus a peek at the one after it (its id is
    // the next window's start). the set's keys are orderKey
    // ([timestamp][event-id]); the trailing bytes of each key are the issue
    // event id.
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
        const issue_cursor = try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, order_key[@sizeOf(u64)..])) orelse continue;
        const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
        try issues.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .issue = try evt.read(evt.Issue, DB, repo_opts.hash, arena, issue_map),
        });
    }

    return .{
        .identity = empty.identity,
        .tag = empty.tag,
        .selected_id = empty.selected_id,
        .issues = issues.items,
        .prev_id = prev_id,
        .next_id = next_id,
    };
}

pub const View = struct {
    // a horizontal split with the issue list on the left and a detail pane on
    // the right showing the selected issue's description.
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    // the issue whose description the pane currently shows (index into data.issues).
    detailed_index: ?usize,

    const list_index: usize = 0;
    const detail_index: usize = 1;
    const list_max_width: usize = 40;
    const detail_min_width: usize = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the issue list (one focusable row per title), plus a "next" link that
        // reloads the page rooted at the following issue.
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                if (data.prev_id) |prev|
                    try addRow(allocator, &list_box, "← previous", try issuesLink(session.page_arena, data.identity, data.tag, prev));
                for (data.issues) |entry|
                    try addRow(allocator, &list_box, entry.issue.title, try issueRowLink(session.page_arena, data.identity, entry.id));
                if (data.next_id) |next|
                    try addRow(allocator, &list_box, "next →", try issuesLink(session.page_arena, data.identity, data.tag, next));
                // select the window's first issue (past a leading "previous"
                // row) so its description shows on load.
                if (data.issues.len > 0)
                    list_box.getFocus().child_id = list_box.children.keys()[if (data.prev_id != null) 1 else 0]
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

        return .{
            .box = box,
            .data = data,
            .session = session,
            .detailed_index = null,
        };
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

    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.box.children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.listScroll().child.box;
    }

    fn detailOuter(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[detail_index].widget.box;
    }

    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.detailOuter().children.values()[0].widget.scroll;
    }

    fn detailInner(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailScroll().child.box;
    }

    fn detailActive(self: *View) bool {
        const cid = self.box.getFocus().child_id orelse return false;
        return self.box.children.getIndex(cid) == detail_index;
    }

    // the selected issue's index, or null when a window-navigation row is
    // selected (a leading "previous" row shifts the issue rows down by one).
    fn selectedIssueIndex(self: *View) ?usize {
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        const idx = lb.children.getIndex(cid) orelse return null;
        const lead: usize = if (self.data.prev_id != null) 1 else 0;
        if (idx < lead or idx - lead >= self.data.issues.len) return null;
        return idx - lead;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // swap the detail pane to the selected issue when it changes.
        try self.refreshDetail(allocator);

        // mirror the focused issue into the url so it updates as the selection
        // moves, but only while focus is inside this view (the list or detail).
        // when focus sits on the header tab, use the page's base /issues route.
        // an issue's url is the same whether or not the list is filtered, so
        // the mirror drops the tag.
        if (root_focus.grandchild_id) |g| {
            if (self.box.getFocus().children.contains(g)) {
                if (self.selectedIssueIndex()) |sel| {
                    if (ui.RoutablePage.repoIssuesRoute(self.data.identity, "", self.data.issues[sel].id)) |route|
                        self.session.data.current_page = route;
                }
            }
        }

        // the selected list row shows a border (the focused TextBox upgrades it
        // to a double border itself); the rest stay borderless.
        const lb = self.listBox();
        for (lb.children.keys(), lb.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        // the pane's selected child shows the selection border: the description
        // directly, the tags via the flow's selected item.
        const inner = self.detailInner();
        for (inner.children.keys(), inner.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (inner.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        if (self.tagFlow()) |tf| tf.selected = self.tagsFocused();

        // cap the list at list_max_width only while the detail pane fits beside
        // it. the box drops the detail when the width can't hold both minimums,
        // so when it's that narrow we lift the cap and let the list fill the
        // whole width.
        const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
        self.box.children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        // stretch the detail pane across the rest of the width so it fills the
        // area rather than shrinking to its content; its scroll fills the pane.
        if (constraint.max_size.width) |w| {
            self.box.children.values()[detail_index].min_size = .{ .width = if (both_panes_fit) w - list_max_width else w, .height = null };
        } else {
            self.box.children.values()[detail_index].min_size = .{ .width = detail_min_width, .height = null };
        }

        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const sel = self.selectedIssueIndex() orelse return;
        if (self.detailed_index) |d| if (d == sel) return;
        try self.populateDetail(allocator, sel);
        self.detailed_index = sel;
    }

    fn populateDetail(self: *View, allocator: std.mem.Allocator, sel: usize) !void {
        const entry = self.data.issues[sel];
        const inner = self.detailInner();

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        // the issue's tags, each linking to the list filtered to that tag.
        {
            var items: std.ArrayList(ui.TagFlow.Item) = .empty;
            defer items.deinit(allocator);
            var tag_iter = evt.Issue.tagIterator(entry.issue.tags);
            while (tag_iter.next()) |tag| {
                if (tag.len == 0) continue;
                try items.append(allocator, .{ .text = tag, .link = try tagLink(self.session.page_arena, self.data.identity, tag) });
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
        {
            var tb = try wgt.TextBox(ui.Widget).init(allocator, entry.issue.description, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        }

        // point the pane at its first row so focus recovery can land here.
        inner.getFocus().child_id = inner.children.keys()[0];

        // reset the scroll to the top for the newly-shown issue: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll();
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.detailActive()) {
            try self.detailInput(key, root_focus);
        } else {
            try self.listInput(key, root_focus);
        }
    }

    fn listInput(self: *View, key: Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the detail pane.
        if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
            return;
        }
        switch (key) {
            .enter, .arrow_right => try self.focusDetail(root_focus),
            else => {},
        }
    }

    fn detailInput(self: *View, key: Key, root_focus: *Focus) !void {
        if (self.tagsFocused()) {
            try self.tagsInput(key, root_focus);
        } else {
            try self.descriptionInput(key, root_focus);
        }
    }

    fn descriptionInput(self: *View, key: Key, root_focus: *Focus) !void {
        const sc = self.detailScroll();
        switch (key) {
            .arrow_left => return self.focusList(root_focus),
            // once the scroll can't move further, cross into the tags.
            .arrow_up => {
                const before = sc.y;
                sc.y -= 1;
                sc.clampToContent();
                if (sc.y == before) try self.focusTags(root_focus);
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

    // arrow keys move the tag selection; at the flow's edges focus crosses to
    // the neighboring widgets.
    fn tagsInput(self: *View, key: Key, root_focus: *Focus) !void {
        const tf = self.tagFlow() orelse return;
        const cid = tf.focus.child_id orelse return;
        const cur = tf.indexOfFocusId(cid) orelse return;
        const count = tf.text_boxes.items.len;
        const sc = self.detailScroll();
        switch (key) {
            .arrow_left => if (cur > 0) self.focusTag(tf, root_focus, cur - 1) else try self.focusList(root_focus),
            .arrow_right => if (cur + 1 < count) self.focusTag(tf, root_focus, cur + 1),
            .arrow_up => if (tf.rowStep(cur, false)) |i| self.focusTag(tf, root_focus, i),
            .arrow_down => if (tf.rowStep(cur, true)) |i| self.focusTag(tf, root_focus, i) else try self.focusDescription(root_focus),
            .home => self.focusTag(tf, root_focus, 0),
            .end => self.focusTag(tf, root_focus, count - 1),
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

    const tags_child_index: usize = 0;

    fn tagFlow(self: *View) ?*ui.TagFlow {
        const inner = self.detailInner();
        if (inner.children.count() == 0) return null;
        return switch (inner.children.values()[tags_child_index].widget) {
            .tag_flow => |*tf| tf,
            else => null,
        };
    }

    fn tagsFocused(self: *View) bool {
        const inner = self.detailInner();
        const cid = inner.getFocus().child_id orelse return false;
        return inner.children.getIndex(cid) == tags_child_index and self.tagFlow() != null;
    }

    fn focusTag(self: *View, tf: *ui.TagFlow, root_focus: *Focus, index: usize) void {
        root_focus.setFocus(tf.text_boxes.items[index].getFocus().id);
        // keep the tag visible on the terminal: its rect offset by the flow's
        // position in the pane.
        if (self.session.is_terminal and index < tf.rects.items.len) {
            if (self.detailInner().children.values()[tags_child_index].rect) |flow_rect| {
                var rect = tf.rects.items[index];
                rect.x += flow_rect.x;
                rect.y += flow_rect.y;
                self.detailScroll().scrollToRect(rect);
            }
        }
    }

    fn focusTags(self: *View, root_focus: *Focus) !void {
        const tf = self.tagFlow() orelse return;
        if (tf.text_boxes.items.len == 0) return;
        const cid = tf.focus.child_id orelse tf.text_boxes.items[0].getFocus().id;
        const index = tf.indexOfFocusId(cid) orelse 0;
        self.focusTag(tf, root_focus, index);
    }

    fn focusDescription(self: *View, root_focus: *Focus) !void {
        const inner = self.detailInner();
        const index: usize = if (self.tagFlow() != null) 1 else 0;
        if (inner.children.count() <= index) return;
        root_focus.setFocus(inner.children.keys()[index]);
    }

    // enter the detail pane. an empty pane (no issues) can't be entered.
    fn focusDetail(self: *View, root_focus: *Focus) !void {
        if (self.detailInner().children.count() == 0) return;
        root_focus.setFocus(self.detailOuter().getFocus().id);
    }

    // return to the list.
    fn focusList(self: *View, root_focus: *Focus) !void {
        root_focus.setFocus(self.listScroll().getFocus().id);
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

    // for the parent's "scroll up at the top jumps to the header" check. when
    // the list holds focus, report its selected row directly.
    pub fn getSelectedIndex(self: *View) ?usize {
        if (self.detailActive()) {
            return if (self.detailScroll().y == 0 and self.paneTopFocused()) 0 else 1;
        }
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        return lb.children.getIndex(cid);
    }

    // whether the focused element is the detail pane's topmost one, so up has
    // nowhere further to go within the pane.
    fn paneTopFocused(self: *View) bool {
        const tf = self.tagFlow() orelse return true;
        if (!self.tagsFocused()) return false;
        const cid = tf.focus.child_id orelse return true;
        const cur = tf.indexOfFocusId(cid) orelse return true;
        return tf.rowStep(cur, false) == null;
    }
};

// the "a:" navigation link for the issues page filtered to the url-encoded
// `tag` and rooted at issue `id` within `identity` ("owner/name").
fn issuesLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, tag: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, tag, id) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting issue `id` in `identity`'s list; the
// href is only followed with js off.
fn issueRowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, "", id) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

// the "a:" link to the issues list filtered to `tag` (raw; encoded here).
fn tagLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, tag: []const u8) ![]const u8 {
    const encoded = try ui.urlEncodeRef(page_arena.allocator(), tag);
    const route = ui.RoutablePage.repoIssuesRoute(identity, encoded, "") orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

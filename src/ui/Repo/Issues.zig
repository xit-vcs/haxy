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

// one issue from the repo's consumed event database.
pub const Issue = struct {
    id: []const u8, // hex event id
    title: []const u8,
    description: []const u8,
};

// "owner/name", so the view can build /repo/owner/name/issues/... links.
identity: []const u8,
// the hex event id of the issue this window is rooted at ("" = the first
// window), mirrored into the url.
selected_id: []const u8,
issues: []const Issue,
// the id of the previous window's first issue ("" = the bare first window), or
// null when this window is already the first.
prev_id: ?[]const u8,
// the id of the next window's first issue, or null when this is the last window.
next_id: ?[]const u8,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    selected_id: []const u8,
) !Self {
    const aa = arena.allocator();
    const empty: Self = .{
        .identity = try aa.dupe(u8, identity),
        .selected_id = try aa.dupe(u8, selected_id),
        .issues = &.{},
        .prev_id = null,
        .next_id = null,
    };

    // no filesystem (wasm) or nowhere to look: empty listing. the wasm path
    // never calls init anyway — it rebuilds from the serialized snapshot.
    const io = session.io orelse return empty;
    const repos_dir = session.repos_dir orelse return empty;

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // open with the arena's backing allocator (transient; the issue strings are
    // duped into the page arena so they outlive the repo handle).
    const gpa = arena.child_allocator;
    var any_repo = rp.AnyRepo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return empty;
    defer any_repo.deinit(io, gpa);

    return switch (any_repo) {
        inline else => |*repo| collect(repo.self_repo_opts, arena, repo, empty),
    };
}

// read one window of the repo's issues, ordered by creation time (oldest
// first), starting at the issue empty.selected_id names ("" = the beginning).
fn collect(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.xit, repo_opts),
    empty: Self,
) !Self {
    const aa = arena.allocator();
    const DB = rp.Repo(.xit, repo_opts).DB;
    // an explicitly named issue that doesn't exist is a bad url (NotFound ->
    // 404); the bare route falls through to an empty listing.
    const rooted = empty.selected_id.len != 0;

    // a repo with no consumed events has no moment yet.
    const haxy_moment = evt.currentMoment(repo_opts, repo) catch {
        if (rooted) return error.NotFound;
        return empty;
    };

    const issue_id_set_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "issue-id-set")) orelse {
        if (rooted) return error.NotFound;
        return empty;
    };
    const issue_id_set = try DB.SortedSet(.read_only).init(issue_id_set_cursor);

    const event_id_to_issue_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue")) orelse {
        if (rooted) return error.NotFound;
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

        // the previous window starts page_size ranks back.
        const rank = try issue_id_set.rank(&order_key);
        if (rank > 0) {
            const prev_rank = rank -| page_size;
            if (prev_rank == 0) {
                prev_id = "";
            } else {
                const kv = try issue_id_set.getIndexKeyValuePair(@intCast(prev_rank)) orelse return error.NotFound;
                var prev_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try kv.key_cursor.readBytes(&prev_key);
                const prev_hex = std.fmt.bytesToHex(prev_key[@sizeOf(u64)..].*, .lower);
                prev_id = try aa.dupe(u8, &prev_hex);
            }
        }

        break :blk try issue_id_set.iteratorFrom(&order_key);
    };

    // collect this window's issues, plus a peek at the one after it (its id is
    // the next window's start). the set's keys are orderKey
    // ([timestamp][event-id]); the trailing bytes of each key are the issue
    // event id.
    var issues: std.ArrayList(Issue) = .empty;
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
        const issue_event = try evt.read(evt.Issue, DB, repo_opts.hash, arena, issue_map);
        try issues.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .title = issue_event.title,
            .description = issue_event.description,
        });
    }

    return .{
        .identity = empty.identity,
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
                    try addRow(allocator, &list_box, "← previous", try issuesLink(session.page_arena, data.identity, prev));
                for (data.issues) |issue|
                    try addRow(allocator, &list_box, issue.title, try issueRowLink(session.page_arena, data.identity, issue.id));
                if (data.next_id) |next|
                    try addRow(allocator, &list_box, "next →", try issuesLink(session.page_arena, data.identity, next));
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
        if (root_focus.grandchild_id) |g| {
            if (self.box.getFocus().children.contains(g)) {
                if (self.selectedIssueIndex()) |sel| {
                    if (ui.RoutablePage.repoIssuesRoute(self.data.identity, self.data.issues[sel].id)) |route|
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

        // the description shows a single border while selected (the focused
        // TextBox upgrades it to a double border itself).
        const inner = self.detailInner();
        for (inner.children.keys(), inner.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (inner.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

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
        const issue = self.data.issues[sel];
        const inner = self.detailInner();

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        // the description as a focusable word-wrapped text box. its hidden
        // border reserves the space the border occupies when focused, so
        // focusing doesn't shift layout.
        {
            var tb = try wgt.TextBox(ui.Widget).init(allocator, issue.description, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer tb.deinit(allocator);
            tb.getFocus().focusable = true;
            try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        }

        // point the pane at its row so focus recovery can land here.
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
        const sc = self.detailScroll();
        switch (key) {
            .arrow_left => try self.focusList(root_focus),
            .arrow_up => sc.y -= 1,
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

    // for the parent's "scroll up at the top jumps to the header" check. in the
    // detail pane that means it can't scroll up any further; otherwise up-arrow
    // stays in the pane. when the list holds focus, report its selected row
    // directly (window-navigation rows included).
    pub fn getSelectedIndex(self: *View) ?usize {
        if (self.detailActive()) {
            return if (self.detailScroll().y == 0) 0 else 1;
        }
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        return lb.children.getIndex(cid);
    }
};

// the "a:" navigation link for the issues page rooted at issue `id` within
// `identity` ("owner/name").
fn issuesLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, id) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting issue `id` in `identity`'s list; the
// href is only followed with js off.
fn issueRowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoIssuesRoute(identity, id) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

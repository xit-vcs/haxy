const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const df = xit.diff;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// how many commits a page shows before a "next" link appears.
const page_size = 20;
// max diff lines rendered per chunk (the initial render and each "load more")
const diff_budget = 100;

pub const Hunk = struct {
    lines: []const []const u8,
};

// one commit on the current page, with its diff against its first parent
// pre-rendered up to the budget so the web client can show it without a repo.
pub const Commit = struct {
    oid: []const u8,
    date: []const u8, // "YYYY-MM-DD"
    message: []const u8, // first line only
    hunks: []const Hunk,
    // how many hunks `hunks` covers; the resume cursor for "load more".
    shown_hunks: usize,
    // true when the diff was truncated at the budget and more hunks remain.
    has_more: bool,
};

// "owner/name", so the view can build /repo/owner/name/commits/<oid> links.
identity: []const u8,
commits: []const Commit,
// the first oid of the next page, or null when this is the last page.
next_start: ?[]const u8,
// the on-disk repo directory name (hex event id), for reopening to render more
// diff hunks when "load more" is activated in the TUI.
repo_dir_hex: []const u8,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    start_oid: []const u8,
) !Self {
    const aa = arena.allocator();
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const empty: Self = .{
        .identity = try aa.dupe(u8, identity),
        .commits = &.{},
        .next_start = null,
        .repo_dir_hex = try aa.dupe(u8, &hex),
    };

    // no filesystem (wasm) or nowhere to look: empty listing. the wasm path
    // never calls init anyway — it rebuilds from the serialized snapshot.
    const io = session.io orelse return empty;
    const repos_dir = session.repos_dir orelse return empty;

    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // walk the log with the arena's backing allocator (transient; the commits
    // we keep are duped into the page arena so they outlive it).
    const gpa = arena.child_allocator;
    var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return empty;
    defer repo.deinit(io, gpa);

    // page 1 walks from HEAD (null); a later page starts at its first oid.
    var start_arr: [1][xit.hash.hexLen(.sha1)]u8 = undefined;
    const start_oids: ?[]const [xit.hash.hexLen(.sha1)]u8 = if (start_oid.len == 0) null else blk: {
        if (start_oid.len != start_arr[0].len) return empty; // malformed oid
        @memcpy(&start_arr[0], start_oid);
        break :blk start_arr[0..1];
    };

    // collect this page's commit metadata, plus a peek at the one after it (its
    // oid is the next page's start). the diff for each is rendered afterward, so
    // the log iterator is closed before opening per-commit diff iterators.
    var buf: [page_size]Commit = undefined;
    var oids: [page_size][xit.hash.hexLen(.sha1)]u8 = undefined;
    var count: usize = 0;
    var next_start: ?[]const u8 = null;
    {
        var iter = repo.log(io, gpa, start_oids) catch return empty;
        defer iter.deinit();
        while (try iter.next(gpa)) |commit_object| {
            defer commit_object.deinit();
            if (count == page_size) {
                next_start = try aa.dupe(u8, &commit_object.oid);
                break;
            }
            const md = commit_object.content.commit.metadata;
            @memcpy(&oids[count], &commit_object.oid);
            buf[count] = .{
                .oid = try aa.dupe(u8, &commit_object.oid),
                .date = try formatDate(aa, md.timestamp),
                .message = try aa.dupe(u8, firstLine(md.message orelse "")),
                .hunks = &.{},
                .shown_hunks = 0,
                .has_more = false,
            };
            count += 1;
        }
    }

    // render each commit's diff (best effort: a failed diff leaves it empty).
    // the diff machinery isn't wasm-clean and the wasm client never runs it (it
    // renders from the snapshot), so gate it out of the wasm build.
    if (!builtin.cpu.arch.isWasm()) {
        for (buf[0..count], oids[0..count]) |*commit, oid| {
            const rendered = renderCommitDiff(io, gpa, aa, &repo, oid, 0, diff_budget) catch
                RenderedDiff{ .hunks = &.{}, .shown_hunks = 0, .has_more = false };
            commit.hunks = rendered.hunks;
            commit.shown_hunks = rendered.shown_hunks;
            commit.has_more = rendered.has_more;
        }
    }

    return .{
        .identity = empty.identity,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
        .repo_dir_hex = empty.repo_dir_hex,
    };
}

const RenderedDiff = struct {
    hunks: []const Hunk,
    shown_hunks: usize,
    has_more: bool,
};

// render a commit's diff against its first parent into `arena`-owned hunks,
// skipping the first `skip_hunks` hunks and emitting at most `budget` lines
fn renderCommitDiff(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(.xit, .{}),
    oid: [xit.hash.hexLen(.sha1)]u8,
    skip_hunks: usize,
    budget: usize,
) !RenderedDiff {
    const empty = RenderedDiff{ .hunks = &.{}, .shown_hunks = 0, .has_more = false };

    // load the commit so we can diff it against its first parent.
    var start = [_][xit.hash.hexLen(.sha1)]u8{oid};
    var commit_iter = repo.log(io, gpa, start[0..1]) catch return empty;
    defer commit_iter.deinit();
    const commit_object = (commit_iter.next(gpa) catch return empty) orelse return empty;
    defer commit_object.deinit();

    const parent_maybe = commit_object.content.commit.metadata.firstParent();

    var tree_diff = repo.treeDiff(io, gpa, parent_maybe, &commit_object.oid) catch return empty;
    defer tree_diff.deinit();

    var file_iter = repo.filePairs(io, gpa, .{ .tree = .{ .tree_diff = &tree_diff } }) catch return empty;

    var hunks: std.ArrayList(Hunk) = .empty;
    var total_lines: usize = 0;
    var hunks_seen: usize = 0;
    var has_more = false;

    file_loop: while (file_iter.next() catch null) |pair_val| {
        var pair = pair_val;
        defer pair.deinit();

        var hunk_iter = df.HunkIterator(.xit, .{}).init(gpa, &pair.a, &pair.b) catch continue;
        defer hunk_iter.deinit(gpa);

        // the file header rides on the first of this file's hunks we actually show.
        var file_header_emitted = false;
        while (try hunk_iter.next(gpa)) |hunk_val| {
            var hunk = hunk_val;
            defer hunk.deinit(gpa);

            if (hunks_seen < skip_hunks) {
                hunks_seen += 1;
                continue;
            }
            if (total_lines >= budget) {
                has_more = true;
                break :file_loop;
            }
            var lines: std.ArrayList([]const u8) = .empty;
            if (!file_header_emitted) {
                for (hunk_iter.header_lines.items) |hl| {
                    try lines.append(arena, try arena.dupe(u8, hl));
                }
                file_header_emitted = true;
            }
            try appendHunkLines(arena, &lines, &hunk_iter, &hunk);
            total_lines += lines.items.len;
            try hunks.append(arena, .{ .lines = try lines.toOwnedSlice(arena) });
            hunks_seen += 1;
        }
    }

    return .{ .hunks = try hunks.toOwnedSlice(arena), .shown_hunks = hunks_seen, .has_more = has_more };
}

// append a hunk's header and its edit lines
fn appendHunkLines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    hunk_iter: *df.HunkIterator(.xit, .{}),
    hunk: *df.Hunk(.xit, .{}),
) !void {
    const o = hunk.offsets();
    try lines.append(arena, try std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@", .{
        o.del_start, o.del_count, o.ins_start, o.ins_count,
    }));
    for (hunk.edits.items) |edit| {
        const text = switch (edit) {
            .eql => |e| try hunk_iter.line_iter_b.get(e.new_line.num),
            .ins => |e| try hunk_iter.line_iter_b.get(e.new_line.num),
            .del => |e| try hunk_iter.line_iter_a.get(e.old_line.num),
        };
        defer switch (edit) {
            .eql, .ins => hunk_iter.line_iter_b.free(text),
            .del => hunk_iter.line_iter_a.free(text),
        };
        const prefix: u8 = switch (edit) {
            .eql => ' ',
            .ins => '+',
            .del => '-',
        };
        try lines.append(arena, try std.fmt.allocPrint(arena, "{c}{s}", .{ prefix, text }));
    }
}

// "YYYY-MM-DD" for a unix timestamp.
fn formatDate(arena: std.mem.Allocator, timestamp: u64) ![]const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

// the first line of a commit message, with surrounding whitespace trimmed.
fn firstLine(message: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    return if (nl) |i| trimmed[0..i] else trimmed;
}

pub const View = struct {
    // a horizontal split: the commit list on the left and a diff pane on the
    // right showing the selected commit's diff
    box: wgt.Box(ui.Widget), // horiz: [list_index] = list scroll, [diff_index] = diff pane
    data: *const Self,
    session: *ui.Session,
    // the commit whose diff the pane currently shows (index into data.commits).
    diffed_index: ?usize,
    // mutable diff state for the displayed commit (seeded from data, grown by
    // "load more").
    shown_hunks: usize,
    has_more: bool,
    // focus id of the "load more" row, when present.
    load_more_id: ?usize,

    const list_index: usize = 0;
    const diff_index: usize = 1;
    // min widths for the two panes
    const list_width: usize = 40;
    const diff_width: usize = 40;
    // how many rows a page up/down jumps, and the scroll-wheel step.
    const page_rows = 10;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const aa = session.page_arena.allocator();

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the commit list (one focusable row each), plus a "next" link
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                for (data.commits) |commit| {
                    const label = try std.fmt.allocPrint(aa, "{s}  {s}", .{ commit.date, commit.message });
                    try addRow(allocator, &list_box, label, "");
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next", try commitsPageLink(session.page_arena, data.identity, next));
                }
                if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_width, .height = null } });
        }

        // the diff pane — a frame around a scroll of the hunks
        {
            var diff_outer = blk: {
                var diff_scroll = blk2: {
                    var diff_inner = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                    errdefer diff_inner.deinit(allocator);
                    break :blk2 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = diff_inner }, .{ .direction = .both });
                };
                errdefer diff_scroll.deinit(allocator);
                var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer outer.deinit(allocator);
                try outer.children.put(allocator, diff_scroll.getFocus().id, .{ .widget = .{ .scroll = diff_scroll }, .rect = null, .min_size = null });
                break :blk outer;
            };
            errdefer diff_outer.deinit(allocator);
            try box.children.put(allocator, diff_outer.getFocus().id, .{ .widget = .{ .box = diff_outer }, .rect = null, .min_size = .{ .width = diff_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[list_index];

        return .{
            .box = box,
            .data = data,
            .session = session,
            .diffed_index = null,
            .shown_hunks = 0,
            .has_more = false,
            .load_more_id = null,
        };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    // one hunk as a focusable multi-line text box. its lines sit flush (the
    // inner Text rows have no border); the box's hidden border reserves the
    // space the double border occupies when focused, so focusing doesn't shift
    // layout. `lines` are joined into the page arena (text_box borrows it).
    fn addHunkBox(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), lines: []const []const u8) !void {
        if (lines.len == 0) return;
        const text = try std.mem.join(self.session.page_arena.allocator(), "\n", lines);
        var tb = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    // the focusable "load more" row; its kind carries the GET endpoint the web
    // client fetches (the TUI reopens the repo instead).
    fn addLoadMore(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), oid: []const u8, after_hunks: usize) !void {
        const link = try std.fmt.allocPrint(self.session.page_arena.allocator(), "fetch:/_diff/{s}/{s}?after={d}", .{ self.data.identity, oid, after_hunks });
        var tb = try wgt.TextBox(ui.Widget).init(allocator, "load more", .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
        self.load_more_id = tb.getFocus().id;
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

    fn diffOuter(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[diff_index].widget.box;
    }

    fn diffScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.diffOuter().children.values()[0].widget.scroll;
    }

    fn diffInner(self: *View) *wgt.Box(ui.Widget) {
        return &self.diffScroll().child.box;
    }

    fn diffActive(self: *View) bool {
        const cid = self.box.getFocus().child_id orelse return false;
        return self.box.children.getIndex(cid) == diff_index;
    }

    // the selected commit's index, or null when the "next" row is selected.
    fn selectedCommitIndex(self: *View) ?usize {
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        const idx = lb.children.getIndex(cid) orelse return null;
        if (idx >= self.data.commits.len) return null;
        return idx;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // swap the diff pane to the selected commit when it changes.
        try self.refreshDiff(allocator);

        // the selected list row shows a border (the focused TextBox upgrades it
        // to a double border itself); the rest stay borderless.
        const lb = self.listBox();
        for (lb.children.keys(), lb.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        // the selected hunk (or the "load more" row) shows a single border (the
        // focused TextBox upgrades it to a double border itself, so it stays
        // single when focus is on the commit list); the rest keep their
        // space-reserving hidden border.
        const inner = self.diffInner();
        for (inner.children.keys(), inner.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (inner.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDiff(self: *View, allocator: std.mem.Allocator) !void {
        const sel = self.selectedCommitIndex() orelse return;
        if (self.diffed_index) |d| if (d == sel) return;
        try self.populateDiff(allocator, sel);
        self.diffed_index = sel;
    }

    fn populateDiff(self: *View, allocator: std.mem.Allocator, sel: usize) !void {
        const commit = self.data.commits[sel];
        const inner = self.diffInner();

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;
        self.load_more_id = null;

        for (commit.hunks) |hunk| try self.addHunkBox(allocator, inner, hunk.lines);
        if (commit.has_more) try self.addLoadMore(allocator, inner, commit.oid, commit.shown_hunks);
        self.shown_hunks = commit.shown_hunks;
        self.has_more = commit.has_more;

        const sc = self.diffScroll();
        sc.x = 0;
        sc.y = 0;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.diffActive()) {
            try self.diffInput(allocator, key, root_focus);
        } else {
            try self.listInput(key, root_focus);
        }
    }

    fn listInput(self: *View, key: inp.Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the diff pane. Enter/clicks
        // on the "next" row become navigation in the host before reaching here.
        switch (key) {
            .arrow_right, .enter => try self.focusDiff(root_focus),
            .arrow_down => try self.moveSelection(root_focus, 1),
            .arrow_up => try self.moveSelection(root_focus, -1),
            .page_down => try self.moveSelection(root_focus, page_rows),
            .page_up => try self.moveSelection(root_focus, -page_rows),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveSelection(root_focus, if (dir == .up) -1 else 1),
                else => {},
            },
            else => {},
        }
    }

    fn diffInput(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        const sc = self.diffScroll();
        switch (key) {
            // left scrolls horizontally, then leaves for the list once flush left.
            .arrow_left => {
                if (sc.x > 0) {
                    sc.x -= 1;
                    self.clampDiffScroll();
                } else try self.focusList(root_focus);
            },
            .arrow_right => {
                sc.x += 1;
                self.clampDiffScroll();
            },
            .arrow_up => try self.moveDiff(root_focus, -1),
            .arrow_down => try self.moveDiff(root_focus, 1),
            .page_up => try self.pageDiff(root_focus, -page_rows),
            .page_down => try self.pageDiff(root_focus, page_rows),
            .enter => if (self.focusedIsLoadMore(root_focus)) try self.loadMore(allocator, root_focus),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveDiff(root_focus, if (dir == .up) -1 else 1),
                .press => |btn| if (btn == .left and self.focusedIsLoadMore(root_focus)) try self.loadMore(allocator, root_focus),
                else => {},
            },
            else => {},
        }
    }

    // move focus one hunk in `dir` (+1 down, -1 up). if the adjacent hunk is
    // already visible, just move focus to it — don't scroll. only when it isn't
    // visible yet do we scroll one line toward it (and focus it once it appears),
    // so scrolling never skips past an on-screen hunk. when nothing fits to
    // scroll (e.g. the web, where the browser scrolls the page), the clamp keeps
    // the offset put and focus simply steps to the adjacent hunk.
    fn moveDiff(self: *View, root_focus: *Focus, dir: isize) !void {
        const inner = self.diffInner();
        const keys = inner.children.keys();
        if (keys.len == 0) return;
        const cur: usize = if (root_focus.grandchild_id) |g| (inner.children.getIndex(g) orelse 0) else 0;
        const target = @as(isize, @intCast(cur)) + dir;
        const in_range = target >= 0 and target < @as(isize, @intCast(keys.len));

        if (in_range and self.hunkVisible(@intCast(target))) {
            try root_focus.setFocus(keys[@intCast(target)]);
            return;
        }

        const sc = self.diffScroll();
        sc.y += dir;
        self.clampDiffScroll();
        if (in_range and self.hunkVisible(@intCast(target)))
            try root_focus.setFocus(keys[@intCast(target)]);
    }

    // page a fixed number of lines, then focus the leading visible hunk
    // (bottom-most when paging down, top-most when paging up).
    fn pageDiff(self: *View, root_focus: *Focus, delta: isize) !void {
        const sc = self.diffScroll();
        sc.y += delta;
        self.clampDiffScroll();
        try self.focusVisible(root_focus, delta > 0);
    }

    // whether hunk `index` is at least partly within the diff viewport, per the
    // last build's layout rects (content space) and the current scroll offset.
    fn hunkVisible(self: *View, index: usize) bool {
        const inner = self.diffInner();
        const sc = self.diffScroll();
        const vp = sc.grid orelse return false;
        const r = inner.children.values()[index].rect orelse return false;
        const top = sc.y;
        const bottom = sc.y + @as(isize, @intCast(vp.size.height));
        return (r.y + @as(isize, @intCast(r.size.height))) > top and r.y < bottom;
    }

    // focus the visible hunk at the scroll's leading edge. `prefer_last` picks
    // the bottom-most visible (for downward motion), else the top-most.
    fn focusVisible(self: *View, root_focus: *Focus, prefer_last: bool) !void {
        const inner = self.diffInner();
        const sc = self.diffScroll();
        const vp = sc.grid orelse return;
        const top = sc.y;
        const bottom = sc.y + @as(isize, @intCast(vp.size.height));
        var chosen: ?usize = null;
        for (inner.children.keys(), inner.children.values()) |id, *child| {
            const r = child.rect orelse continue; // content-space layout rect
            const r_top = r.y;
            const r_bot = r.y + @as(isize, @intCast(r.size.height));
            if (r_bot <= top or r_top >= bottom) continue; // not visible
            chosen = id;
            if (!prefer_last) break; // first visible
        }
        if (chosen) |id| try root_focus.setFocus(id);
    }

    fn focusedIsLoadMore(self: *View, root_focus: *Focus) bool {
        const id = self.load_more_id orelse return false;
        return root_focus.grandchild_id == id;
    }

    // keep the diff scroll within its content, using the last build's grids.
    fn clampDiffScroll(self: *View) void {
        const sc = self.diffScroll();
        const vp = sc.grid orelse return;
        const content = sc.child.box.grid orelse return;
        const max_y: isize = if (content.size.height > vp.size.height) @intCast(content.size.height - vp.size.height) else 0;
        const max_x: isize = if (content.size.width > vp.size.width) @intCast(content.size.width - vp.size.width) else 0;
        sc.y = std.math.clamp(sc.y, 0, max_y);
        sc.x = std.math.clamp(sc.x, 0, max_x);
    }

    // enter the diff pane by focusing the hunk that was focused last (the box's
    // child_id remembers it across the trip to the commit list); fall back to the
    // first hunk on a fresh diff. the host arrives here on right-arrow or Enter
    // from the list. a diff with no hunks can't be entered.
    fn focusDiff(self: *View, root_focus: *Focus) !void {
        const inner = self.diffInner();
        if (inner.children.count() == 0) return;
        try root_focus.setFocus(inner.getFocus().child_id orelse inner.children.keys()[0]);
    }

    fn focusList(self: *View, root_focus: *Focus) !void {
        const lb = self.listBox();
        const id = lb.getFocus().child_id orelse (if (lb.children.count() > 0) lb.children.keys()[0] else return);
        try root_focus.setFocus(id);
    }

    fn moveSelection(self: *View, root_focus: *Focus, delta: isize) !void {
        const lb = self.listBox();
        const keys = lb.children.keys();
        if (keys.len == 0) return;
        const cur_id = lb.getFocus().child_id orelse return;
        const cur: isize = @intCast(lb.children.getIndex(cur_id) orelse return);
        const last: isize = @intCast(keys.len - 1);
        const next: usize = @intCast(std.math.clamp(cur + delta, 0, last));
        if (next == @as(usize, @intCast(cur))) return;
        try root_focus.setFocus(keys[next]);
        if (lb.children.values()[next].rect) |rect| self.listScroll().scrollToRect(rect);
    }

    // render the next budget of hunks for the displayed commit and append them.
    // the TUI reopens the repo here; the wasm path has no repo and the web host
    // drives "load more" via the GET endpoint instead, so the repo code is
    // comptime-elided from the wasm build.
    fn loadMore(self: *View, allocator: std.mem.Allocator, root_focus: *Focus) !void {
        // the wasm build has no repo; it drives "load more" via the GET endpoint.
        if (!builtin.cpu.arch.isWasm()) try self.loadMoreNative(allocator, root_focus);
    }

    fn loadMoreNative(self: *View, allocator: std.mem.Allocator, root_focus: *Focus) !void {
        const io = self.session.io orelse return;
        const repos_dir = self.session.repos_dir orelse return;
        const sel = self.diffed_index orelse return;
        const commit = self.data.commits[sel];
        if (commit.oid.len != xit.hash.hexLen(.sha1)) return;

        const aa = self.session.page_arena.allocator();
        const gpa = self.session.page_arena.child_allocator;
        const repo_path = try std.fs.path.join(aa, &.{ repos_dir, self.data.repo_dir_hex });
        var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return;
        defer repo.deinit(io, gpa);

        var oid: [xit.hash.hexLen(.sha1)]u8 = undefined;
        @memcpy(&oid, commit.oid);
        const rendered = renderCommitDiff(io, gpa, aa, &repo, oid, self.shown_hunks, diff_budget) catch return;

        const inner = self.diffInner();
        if (self.load_more_id) |id| {
            if (inner.children.fetchOrderedRemove(id)) |kv| {
                var w = kv.value.widget;
                w.deinit(allocator);
            }
            self.load_more_id = null;
        }
        // focus the last already-shown hunk (the one just above where "load
        // more" was). it's already in the focus tree from the last build, so the
        // focus lands; the freshly-appended hunks aren't in the tree until the
        // next build, so focusing one here would silently no-op. the user scrolls
        // down into the new hunks from here.
        const shown = inner.children.count(); // old hunk count ("load more" removed)
        for (rendered.hunks) |hunk| try self.addHunkBox(allocator, inner, hunk.lines);
        self.shown_hunks = rendered.shown_hunks;
        self.has_more = rendered.has_more;
        if (rendered.has_more) try self.addLoadMore(allocator, inner, commit.oid, rendered.shown_hunks);
        if (shown > 0) try root_focus.setFocus(inner.children.keys()[shown - 1]);
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
    // diff pane that means the first hunk is focused and the diff can't scroll up
    // any further; otherwise up-arrow stays in the pane (scrolling or moving
    // between hunks). when the list holds focus, report its selection directly.
    pub fn getSelectedIndex(self: *View) ?usize {
        if (self.diffActive()) {
            const inner = self.diffInner();
            const cid = inner.getFocus().child_id orelse return 1;
            const first_focused = inner.children.count() > 0 and cid == inner.children.keys()[0];
            return if (first_focused and self.diffScroll().y == 0) 0 else 1;
        }
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        return lb.children.getIndex(cid);
    }
};

// the "a:" link for the commits page starting at `start_oid` within `identity`.
fn commitsPageLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, start_oid: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoCommitsRoute(identity, start_oid) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

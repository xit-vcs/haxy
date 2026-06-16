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
// how many diff hunks a commit shows per page; "load more" reveals another page.
const diff_page = 10;

pub const Hunk = struct {
    path: ?[]const u8 = null, // the file this hunk belongs to
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

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    start_oid: []const u8,
    // how many hunks the selected commit (the first one, == start_oid) shows;
    // 0 means the default page. raised by "load more" via the url.
    after: usize,
) !Self {
    const aa = arena.allocator();
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const empty: Self = .{
        .identity = try aa.dupe(u8, identity),
        .commits = &.{},
        .next_start = null,
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
        for (buf[0..count], oids[0..count], 0..) |*commit, oid, i| {
            // the selected commit (the first, == start_oid) shows `after` hunks
            // when the url asks; the rest show one default page.
            const max_hunks = if (i == 0 and after > 0) after else diff_page;
            const rendered = renderCommitDiff(io, gpa, aa, &repo, oid, max_hunks) catch
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
    };
}

const RenderedDiff = struct {
    hunks: []const Hunk,
    shown_hunks: usize,
    has_more: bool,
};

// render a commit's diff against its first parent into `arena`-owned hunks,
// emitting at most `max_hunks` hunks (has_more is set when more remain)
fn renderCommitDiff(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(.xit, .{}),
    oid: [xit.hash.hexLen(.sha1)]u8,
    max_hunks: usize,
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
    var has_more = false;

    file_loop: while (file_iter.next() catch null) |pair_val| {
        var pair = pair_val;
        defer pair.deinit();

        var hunk_iter = df.HunkIterator(.xit, .{}).init(gpa, &pair.a, &pair.b) catch continue;
        defer hunk_iter.deinit(gpa);

        // the path label rides on the first of this file's hunks we actually show.
        var path_attached = false;
        while (try hunk_iter.next(gpa)) |hunk_val| {
            var hunk = hunk_val;
            defer hunk.deinit(gpa);

            if (hunks.items.len >= max_hunks) {
                has_more = true;
                break :file_loop;
            }
            var lines: std.ArrayList([]const u8) = .empty;
            try appendHunkLines(arena, &lines, &hunk_iter, &hunk);
            try hunks.append(arena, .{
                .path = if (path_attached) null else try arena.dupe(u8, pair.path),
                .lines = try lines.toOwnedSlice(arena),
            });
            path_attached = true;
        }
    }

    const shown = hunks.items.len;
    return .{ .hunks = try hunks.toOwnedSlice(arena), .shown_hunks = shown, .has_more = has_more };
}

// append a hunk's header and its edit lines, each prefixed with a right-aligned
// line number in a column wide enough for the hunk's largest number, then a space
fn appendHunkLines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    hunk_iter: *df.HunkIterator(.xit, .{}),
    hunk: *df.Hunk(.xit, .{}),
) !void {
    var max_num: usize = 1;
    for (hunk.edits.items) |edit| {
        const n = editLineNum(edit) + 1;
        if (n > max_num) max_num = n;
    }
    const width = std.fmt.count("{d}", .{max_num});
    // a run of spaces sliced to each line's leading pad.
    const indent = try arena.alloc(u8, width);
    @memset(indent, ' ');

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
        const num_str = try std.fmt.allocPrint(arena, "{d}", .{editLineNum(edit) + 1});
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s} {c}{s}", .{
            indent[0 .. width - num_str.len], num_str, prefix, text,
        }));
    }
}

// the line number to show for an edit: the new-side number for kept and inserted
// lines, the old-side number for deletions (0-based in the diff machinery).
fn editLineNum(edit: df.Edit) usize {
    return switch (edit) {
        .eql => |e| e.new_line.num,
        .ins => |e| e.new_line.num,
        .del => |e| e.old_line.num,
    };
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

    const list_index: usize = 0;
    const diff_index: usize = 1;
    const list_max_width: usize = 40;
    const diff_min_width: usize = 40;
    // how many rows a page up/down jumps, and the scroll-wheel step.
    const page_rows = 10;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the commit list (one focusable row each), plus a "next" link
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                for (data.commits) |commit| {
                    try addRow(allocator, &list_box, commit.message, "");
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next", try commitsLink(session.page_arena, data.identity, next, 0));
                }
                if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
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
            try box.children.put(allocator, diff_outer.getFocus().id, .{ .widget = .{ .box = diff_outer }, .rect = null, .min_size = .{ .width = diff_min_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[list_index];

        return .{
            .box = box,
            .data = data,
            .session = session,
            .diffed_index = null,
        };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null, .max_size = .{ .width = null, .height = 5 } });
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

    // a focusable file-path label shown above the first hunk of each file.
    fn addPathBox(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), path: []const u8) !void {
        _ = self;
        var tb = try wgt.TextBox(ui.Widget).init(allocator, path, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    // the focusable "load more" row. it's a navigation link to this commit's
    // route with a larger `after`, so activating it (the host follows the "a:"
    // link) reloads the page showing more hunks — the same on the TUI and web.
    fn addLoadMore(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), oid: []const u8, next_after: usize) !void {
        const link = try commitsLink(self.session.page_arena, self.data.identity, oid, next_after);
        var tb = try wgt.TextBox(ui.Widget).init(allocator, "load more", .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
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

        // mirror the focused commit into the url so it updates as the selection
        // moves, but only while focus is inside this view (the list or diff). when
        // focus sits on the header tab, use the page's base /commits route.
        if (root_focus.grandchild_id) |g| {
            if (self.box.getFocus().children.contains(g)) {
                if (self.selectedCommitIndex()) |sel| {
                    // selection moves reset the diff expansion (after = 0).
                    if (ui.RoutablePage.repoCommitsRoute(self.data.identity, self.data.commits[sel].oid, 0)) |route|
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

        // cap the list at list_max_width only while the diff pane fits beside it.
        // the box drops the diff when the width can't hold both minimums, so when
        // it's that narrow we lift the cap and let the list fill the whole width.
        const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + diff_min_width else true;
        self.box.children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        // web browsers provide scrolling, so let every widget grow to
        // its natural size instead of clipping inside the diff scroll
        const build_constraint = if (self.session.is_terminal) constraint else layout.Constraint{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = null, .height = null },
        };
        try self.box.build(allocator, build_constraint, root_focus);

        // if the diff pane is selected but focus is still elsewhere in this view,
        // the pane was too narrow to lay out when focus crossed over. it's laid
        // out now, so focus its hunk.
        if (self.diffActive() and inner.children.count() > 0) {
            if (root_focus.grandchild_id) |g| {
                const in_view = self.box.getFocus().children.contains(g);
                const in_diff = inner.children.contains(g);
                if (in_view and !in_diff)
                    try root_focus.setFocus(inner.getFocus().child_id orelse inner.children.keys()[0]);
            }
        }
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

        for (commit.hunks) |hunk| {
            if (hunk.path) |path| try self.addPathBox(allocator, inner, path);
            try self.addHunkBox(allocator, inner, hunk.lines);
        }
        // the load-more link reloads showing one more page of this commit's hunks.
        if (commit.has_more) try self.addLoadMore(allocator, inner, commit.oid, commit.shown_hunks + diff_page);

        const sc = self.diffScroll();
        sc.x = 0;
        sc.y = 0;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.diffActive()) {
            try self.diffInput(key, root_focus);
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

    fn diffInput(self: *View, key: inp.Key, root_focus: *Focus) !void {
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
            // Enter / a click on the "load more" row follow its "a:" link in the
            // host (it reloads the page with more hunks), so they don't reach here.
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveDiff(root_focus, if (dir == .up) -1 else 1),
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

    // keep the diff scroll within its content, using the last build's grids. the
    // scroll bar's reserved column/row isn't part of the content viewport, so
    // exclude it (as scrollToRect does) or the last column/row stays unreachable.
    fn clampDiffScroll(self: *View) void {
        const sc = self.diffScroll();
        const vp = sc.grid orelse return;
        const content = sc.child.box.grid orelse return;
        const view_w = vp.size.width - sc.bar_w;
        const view_h = vp.size.height - sc.bar_h;
        const max_y: isize = if (content.size.height > view_h) @intCast(content.size.height - view_h) else 0;
        const max_x: isize = if (content.size.width > view_w) @intCast(content.size.width - view_w) else 0;
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
        const target = inner.getFocus().child_id orelse inner.children.keys()[0];
        try root_focus.setFocus(target);
        if (root_focus.grandchild_id == target) return;
        // the diff pane wasn't laid out last build (too narrow to show beside
        // the list), so its hunks aren't in the focus tree yet. select the pane
        // at the box level, and the hunk will be focused after the next build.
        self.box.getFocus().child_id = self.diffOuter().getFocus().id;
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

// the "a:" navigation link for the commits page starting at `start_oid` within
// `identity`, showing the selected commit's first `after` hunks (0 = default).
fn commitsLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, start_oid: []const u8, after: usize) ![]const u8 {
    const route = ui.RoutablePage.repoCommitsRoute(identity, start_oid, after) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

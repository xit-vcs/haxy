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
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

const SubHeader = @import("SubHeader.zig");

// how many commits a page shows before a "next" link appears.
const page_size = 20;
// how many diff hunks one window of a commit's diff shows; "next"/"previous"
// move to the adjacent window.
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
    // the hunk index this window starts at (0 = the first window).
    window_start: usize,
    // whether hunks exist before this window / after it.
    has_prev: bool,
    has_more: bool,
};

// "owner/name", so the view can build /repo/owner/name/commits/... links.
identity: []const u8,
// the resolved ref/oid this log walks from (the default branch when the route
// didn't name one), so the page can canonicalize its url to it.
ref_or_oid: ui.RoutablePage.RefOrOid,
ref_or_oid_value: []const u8,
commits: []const Commit,
// the first oid of the next page, or null when this is the last page.
next_start: ?[]const u8,
// the "viewing <ref> <value>" banner shown above the log.
sub_header: SubHeader,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    source_maybe: ?ui.RepoSource,
    identity: []const u8,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    // the hunk index the selected commit's (the first one, the walk root) diff
    // window starts at; 0 is the first window. moved by "next"/"previous".
    after: usize,
) !Self {
    const aa = arena.allocator();

    // no filesystem (wasm) or nowhere to look: empty listing. the wasm path
    // never calls init anyway — it rebuilds from the serialized snapshot.
    const io = session.io orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value);
    const source = source_maybe orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value);

    // walk the log with the arena's backing allocator (transient; the commits
    // we keep are duped into the page arena so they outlive it). AnyRepo opens
    // both sha1 and sha256 repos.
    const gpa = arena.child_allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = rp.AnyRepo(repo_kind, .{}).open(io, gpa, .{ .path = source.path }) catch return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value);
            defer any_repo.deinit(io, gpa);

            return switch (any_repo) {
                inline else => |*repo| collect(repo_kind, repo.self_repo_opts, arena, repo, io, gpa, identity, requested_ref_or_oid, requested_value, after),
            };
        },
    }
}

// walk the log for an opened repo. generic over the repo's backend and hash
// kind so the oid buffers and diff types it threads through match the repo's
// opts.
fn collect(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    identity: []const u8,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    after: usize,
) !Self {
    const aa = arena.allocator();
    const hex_len = ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len;

    // resolve the requested ref (or the default branch) to the commit oid to
    // walk from. an explicitly named ref that doesn't resolve is a bad url
    // (NotFound -> 404); the default-branch path falls through to empty.
    const resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        return emptyResult(aa, identity, .branch, requested_value);
    };
    var start_arr = [1][hex_len]u8{resolved.oid};
    const start_oids: []const [hex_len]u8 = start_arr[0..1];

    // collect this page's commit metadata, plus a peek at the one after it (its
    // oid is the next page's start). the diff for each is rendered afterward, so
    // the log iterator is closed before opening per-commit diff iterators.
    var buf: [page_size]Commit = undefined;
    var oids: [page_size][hex_len]u8 = undefined;
    var count: usize = 0;
    var next_start: ?[]const u8 = null;
    {
        var iter = repo.log(io, gpa, start_oids) catch return emptyResult(aa, identity, resolved.ref_or_oid, resolved.value);
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
                .window_start = 0,
                .has_prev = false,
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
            // the selected commit (the first, == start_oid) shows the window the
            // url asks for; the rest show their first window.
            const start = if (i == 0) after else 0;
            const rendered = renderCommitDiff(repo_kind, repo_opts, io, gpa, aa, repo, oid, start, diff_page) catch
                RenderedDiff{ .hunks = &.{}, .has_prev = false, .has_more = false };
            commit.hunks = rendered.hunks;
            commit.window_start = start;
            commit.has_prev = rendered.has_prev;
            commit.has_more = rendered.has_more;
        }
    }

    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_or_oid = resolved.ref_or_oid,
        .ref_or_oid_value = resolved.value,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
        .sub_header = try SubHeader.init(aa, resolved.ref_or_oid, resolved.value),
    };
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
fn emptyResult(aa: std.mem.Allocator, identity: []const u8, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = try aa.dupe(u8, value),
        .commits = &.{},
        .next_start = null,
        .sub_header = try SubHeader.init(aa, ref_or_oid, value),
    };
}

const RenderedDiff = struct {
    hunks: []const Hunk,
    has_prev: bool,
    has_more: bool,
};

// render the window [start, start+len) of a commit's diff against its first
// parent into `arena`-owned hunks. has_prev/has_more flag adjacent windows.
fn renderCommitDiff(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    oid: [xit.hash.hexLen(repo_opts.hash)]u8,
    start: usize,
    len: usize,
) !RenderedDiff {
    const empty = RenderedDiff{ .hunks = &.{}, .has_prev = false, .has_more = false };

    // load the commit so we can diff it against its first parent.
    var start_oids = [_][xit.hash.hexLen(repo_opts.hash)]u8{oid};
    var commit_iter = repo.log(io, gpa, start_oids[0..1]) catch return empty;
    defer commit_iter.deinit();
    const commit_object = (commit_iter.next(gpa) catch return empty) orelse return empty;
    defer commit_object.deinit();

    const parent_maybe = commit_object.content.commit.metadata.firstParent();

    var tree_diff = repo.treeDiff(io, gpa, parent_maybe, &commit_object.oid) catch return empty;
    defer tree_diff.deinit();

    var file_iter = repo.filePairs(io, gpa, .{ .tree = .{ .tree_diff = &tree_diff } }) catch return empty;

    var hunks: std.ArrayList(Hunk) = .empty;
    var index: usize = 0; // running hunk index across all files
    var has_more = false;

    file_loop: while (file_iter.next() catch null) |pair_val| {
        var pair = pair_val;
        defer pair.deinit();

        var hunk_iter = df.HunkIterator(repo_kind, repo_opts).init(gpa, &pair.a, &pair.b) catch continue;
        defer hunk_iter.deinit(gpa);

        // the path label rides on the first of this file's hunks we actually show.
        var path_attached = false;
        while (try hunk_iter.next(gpa)) |hunk_val| {
            var hunk = hunk_val;
            defer hunk.deinit(gpa);

            const i = index;
            index += 1;
            if (i < start) continue; // before this window
            if (hunks.items.len >= len) {
                has_more = true;
                break :file_loop;
            }
            var lines: std.ArrayList([]const u8) = .empty;
            try appendHunkLines(repo_kind, repo_opts, arena, &lines, &hunk_iter, &hunk);
            try hunks.append(arena, .{
                .path = if (path_attached) null else try arena.dupe(u8, pair.path),
                .lines = try lines.toOwnedSlice(arena),
            });
            path_attached = true;
        }
    }

    return .{ .hunks = try hunks.toOwnedSlice(arena), .has_prev = start > 0, .has_more = has_more };
}

// append a hunk's header and its edit lines, each prefixed with a right-aligned
// line number in a column wide enough for the hunk's largest number, then a space
fn appendHunkLines(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    hunk_iter: *df.HunkIterator(repo_kind, repo_opts),
    hunk: *df.Hunk(repo_kind, repo_opts),
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
    // a vertical stack: the "viewing <ref>" banner on top, then a horizontal
    // split with the commit list on the left and a diff pane on the right
    // showing the selected commit's diff.
    box: wgt.Box(ui.Widget), // vert: [sub_header_index] = banner, [content_index] = split
    data: *const Self,
    session: *ui.Session,
    // the commit whose diff the pane currently shows (index into data.commits).
    diffed_index: ?usize,

    const sub_header_index: usize = 0;
    const content_index: usize = 1;
    // indices within the content box (the horizontal split).
    const list_index: usize = 0;
    const diff_index: usize = 1;
    const list_max_width: usize = 40;
    const diff_min_width: usize = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the ref banner at the top.
        {
            var sub_header = try SubHeader.View.init(allocator, &data.sub_header, session);
            errdefer sub_header.deinit(allocator);
            try outer.children.put(allocator, sub_header.getFocus().id, .{ .widget = .{ .repo_sub_header = sub_header }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the commit list (one focusable row each), plus a "next" link
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);
                for (data.commits) |commit| {
                    // an in-page "ai:" anchor so a commit row is clickable with
                    // js off (the browser follows it, rooting the list there);
                    // with wasm the click just selects it and swaps the diff pane.
                    try addRow(allocator, &list_box, commit.message, try commitRowLink(session.page_arena, data.identity, commit.oid));
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next →", try commitsLink(session.page_arena, data.identity, next, 0));
                }
                if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal });
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
                    // fill the pane (content top-left, scroll bars pinned to the
                    // edges) rather than shrinking to the diff content.
                    break :blk2 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = diff_inner }, .{ .direction = .both, .web_native = !session.is_terminal, .fill = true });
                };
                errdefer diff_scroll.deinit(allocator);
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                // the frame's selected child is its scroll, so the focus chain
                // reaches a hunk (populateDiff points the scroll's inner box at
                // one), letting focus recovery descend into the diff pane after
                // it's laid out beside a too-narrow list.
                frame.getFocus().child_id = diff_scroll.getFocus().id;
                try frame.children.put(allocator, diff_scroll.getFocus().id, .{ .widget = .{ .scroll = diff_scroll }, .rect = null, .min_size = null });
                break :blk frame;
            };
            errdefer diff_outer.deinit(allocator);
            try box.children.put(allocator, diff_outer.getFocus().id, .{ .widget = .{ .box = diff_outer }, .rect = null, .min_size = .{ .width = diff_min_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[list_index];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });

        // focus lives in the split; the banner isn't focusable.
        outer.getFocus().child_id = outer.children.keys()[content_index];

        return .{
            .box = outer,
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

    // a focusable window-navigation row ("previous"/"next"). it's a link to this
    // commit's route at `target_after`, so activating it (the host follows the
    // "a:" link) reloads the page on the adjacent window — same on TUI and web.
    fn addNavLink(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, oid: []const u8, target_after: usize) !void {
        const link = try commitsLink(self.session.page_arena, self.data.identity, oid, target_after);
        var tb = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    // a focusable row for the top of the diff pane linking to the files tab at
    // this commit's tree, so its files are always viewable as of this object.
    fn addViewFilesLink(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), oid: []const u8) !void {
        const link = try filesObjectLink(self.session.page_arena, self.data.identity, oid);
        var tb = try wgt.TextBox(ui.Widget).init(allocator, "view files at this commit", .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[content_index].widget.box;
    }

    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.listScroll().child.box;
    }

    fn diffOuter(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[diff_index].widget.box;
    }

    fn diffScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.diffOuter().children.values()[0].widget.scroll;
    }

    fn diffInner(self: *View) *wgt.Box(ui.Widget) {
        return &self.diffScroll().child.box;
    }

    fn diffActive(self: *View) bool {
        const content = self.contentBox();
        const cid = content.getFocus().child_id orelse return false;
        return content.children.getIndex(cid) == diff_index;
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
                    // mirror the commit's current diff window so the url stays
                    // linkable (0 for any commit but the windowed start one).
                    if (ui.RoutablePage.repoCommitsRoute(self.data.identity, .object, self.data.commits[sel].oid, self.data.commits[sel].window_start)) |route|
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
        self.contentBox().children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        // stretch the diff pane across the rest of the width so it fills the area
        // rather than shrinking to its content; its scroll fills the pane. when
        // too narrow for both, it fills the whole width.
        if (constraint.max_size.width) |w| {
            self.contentBox().children.values()[diff_index].min_size = .{ .width = if (both_panes_fit) w - list_max_width else w, .height = null };
        } else {
            self.contentBox().children.values()[diff_index].min_size = .{ .width = diff_min_width, .height = null };
        }

        // the web bounds the layout to the browser viewport like the terminal;
        // each Scroll's web-native mode hands its full content to a real
        // scrollable element, so we no longer build unbounded here.
        //
        // crossing panes only re-selects the content box's child (focusDiff /
        // focusList); when the window is too narrow to show both, the pane that
        // held focus is dropped here. the framework recovers focus after the
        // top-level build by re-deriving it down the selected-child chain, so
        // there's nothing to fix up afterward.
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

        // the first row always links to viewing the repo's files at this commit.
        try self.addViewFilesLink(allocator, inner, commit.oid);

        // a "previous" row and a "next" row at the bottom reload the page on the
        // adjacent diff window.
        if (commit.has_prev) try self.addNavLink(allocator, inner, "← previous", commit.oid, commit.window_start -| diff_page);
        for (commit.hunks) |hunk| {
            if (hunk.path) |path| try self.addPathBox(allocator, inner, path);
            try self.addHunkBox(allocator, inner, hunk.lines);
        }
        if (commit.has_more) try self.addNavLink(allocator, inner, "next →", commit.oid, commit.window_start + diff_page);

        // point the pane at its first row so focus recovery can land here.
        if (inner.children.count() > 0) inner.getFocus().child_id = inner.children.keys()[0];

        // reset the scroll to the top for the newly-shown commit: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.diffScroll();
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.diffActive()) {
            try self.diffInput(key, root_focus);
        } else {
            try self.listInput(key, root_focus);
        }
    }

    fn listInput(self: *View, key: Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the diff pane. Enter/clicks
        // on the "next" row become navigation in the host before reaching here.
        if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
            return;
        }
        switch (key) {
            .enter => if (self.selectedCommitIndex() != null)
                try self.focusDiff(root_focus)
            else if (self.data.next_start) |next| {
                if (ui.RoutablePage.repoCommitsRoute(self.data.identity, .object, next, 0)) |route|
                    try self.session.navigate(route);
            },
            .arrow_right => try self.focusDiff(root_focus),
            else => {},
        }
    }

    fn diffInput(self: *View, key: Key, root_focus: *Focus) !void {
        const sc = self.diffScroll();
        switch (key) {
            // left scrolls horizontally, then leaves for the list once flush left.
            .arrow_left => {
                if (sc.x > 0) {
                    sc.x -= 1;
                    self.diffScroll().clampToContent();
                } else try self.focusList(root_focus);
            },
            .arrow_right => {
                sc.x += 1;
                self.diffScroll().clampToContent();
            },
            .arrow_up => try self.moveDiff(root_focus, -1),
            .arrow_down => try self.moveDiff(root_focus, 1),
            .page_up => try self.pageDiff(root_focus, -10),
            .page_down => try self.pageDiff(root_focus, 10),
            .home => try self.jumpDiff(root_focus, false),
            .end => try self.jumpDiff(root_focus, true),
            // Enter / a click on a "previous"/"next" row follow its "a:" link in
            // the host (it reloads the adjacent window), so they don't reach here.
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveDiff(root_focus, if (dir == .up) -1 else 1),
                else => {},
            },
            else => {},
        }
    }

    // move one step in `delta` (+ down, - up). in the terminal, `delta` is a
    // line count unless there is a new hunk visible (in which case it is a
    // hunk count). on the web `delta` is always a hunk count.
    fn moveDiff(self: *View, root_focus: *Focus, delta: isize) !void {
        const inner = self.diffInner();
        const keys = inner.children.keys();
        if (keys.len == 0) return;
        const cur: usize = if (root_focus.grandchild_id) |g| (inner.children.getIndex(g) orelse 0) else 0;
        const target = @as(isize, @intCast(cur)) + delta;
        const in_range = target >= 0 and target < @as(isize, @intCast(keys.len));

        if (self.session.is_terminal) {
            if (in_range and self.hunkVisible(@intCast(target))) {
                root_focus.setFocus(keys[@intCast(target)]);
                return;
            }

            const sc = self.diffScroll();
            sc.y += delta * 5; // magnify because it's a line count
            self.diffScroll().clampToContent();
            if (in_range and self.hunkVisible(@intCast(target))) {
                root_focus.setFocus(keys[@intCast(target)]);
            }
        } else {
            if (in_range) {
                root_focus.setFocus(keys[@intCast(target)]);
            }
        }
    }

    // page a fixed number of lines, then focus the leading visible hunk
    // (bottom-most when paging down, top-most when paging up). in the
    // terminal, `delta` is a line count, and on the web it's a hunk count.
    fn pageDiff(self: *View, root_focus: *Focus, delta: isize) !void {
        if (self.session.is_terminal) {
            const sc = self.diffScroll();
            sc.y += delta * 5; // magnify because it's a line count
            self.diffScroll().clampToContent();
            try self.focusVisible(root_focus, delta > 0);
        } else {
            const inner = self.diffInner();
            const keys = inner.children.keys();
            if (keys.len == 0) return;
            const cur: isize = if (root_focus.grandchild_id) |g| @intCast(inner.children.getIndex(g) orelse 0) else 0;
            const target: usize = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(keys.len - 1))));
            root_focus.setFocus(keys[target]);
        }
    }

    // jump to the first or last hunk. on the web the browser scrolls to the
    // focused hunk; on the terminal pin the scroll to the top/bottom too.
    fn jumpDiff(self: *View, root_focus: *Focus, to_end: bool) !void {
        const inner = self.diffInner();
        const keys = inner.children.keys();
        if (keys.len == 0) return;
        if (self.session.is_terminal) {
            const sc = self.diffScroll();
            sc.y = if (to_end) std.math.maxInt(isize) else 0;
            self.diffScroll().clampToContent();
        }
        root_focus.setFocus(if (to_end) keys[keys.len - 1] else keys[0]);
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
        if (chosen) |id| root_focus.setFocus(id);
    }

    // enter the diff pane. the host arrives here on right-arrow or Enter from the
    // list. a diff with no rows can't be entered. setFocus handles the too-narrow
    // case where the pane isn't laid out yet (it gets selected, then focused after
    // the next build, landing on its remembered hunk).
    fn focusDiff(self: *View, root_focus: *Focus) !void {
        if (self.diffInner().children.count() == 0) return;
        root_focus.setFocus(self.diffOuter().getFocus().id);
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

// the "a:" navigation link for the commits page walking from commit `oid` within
// `identity`, showing the selected commit's first `after` hunks (0 = default).
fn commitsLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, oid: []const u8, after: usize) ![]const u8 {
    const route = ui.RoutablePage.repoCommitsRoute(identity, .object, oid, after) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "a:" link to the files tab at commit `oid` (an object ref), at its root
// directory, within `identity` ("owner/name").
fn filesObjectLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, oid: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoFilesRoute(identity, .object, oid, "", 0) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting `oid` in `identity`'s commit list. it
// points at the same route as commitsLink but the "ai:" prefix keeps wasm clicks
// in-page (crossPageLink ignores it); the href is only followed with js off.
fn commitRowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, oid: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoCommitsRoute(identity, .object, oid, 0) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const df = xit.diff;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;
const inp = @import("../input.zig");

pub const page_size = 10;
pub const Hunk = struct {
    path: ?[]const u8 = null,
    text: []const u8,
    // one byte per line of text: the edit's +/-/space prefix
    prefixes: []const u8,
    status: Status = .changed,
};
pub const Status = enum {
    added,
    removed,
    changed,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .added => " added ",
            .removed => " removed ",
            .changed => " changed ",
        };
    }

    fn border(self: Status) wgt.Border {
        const color: Grid.Color.Ansi = switch (self) {
            .added => .green,
            .removed => .red,
            .changed => return .single,
        };
        return .{ .kind = .single, .style = .{ .fg = .ansi(color) } };
    }
};
pub const Window = struct {
    hunks: []const Hunk = &.{},
    start: usize = 0,
    has_more: bool = false,
};

route: Route,
path: []const u8 = "",
window: Window,

const Self = @This();

pub const Route = union(enum) {
    repo: struct { identity: []const u8, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8, base_oid: []const u8 },
    // `base_oid` is the revision's base commit, which the url leaves out
    patchrev: struct { identity: []const u8, id: []const u8, base_oid: []const u8 },
    // `oid` names one commit's diff against `base_oid` ("" = the whole patch).
    // `patch_base_oid` is the whole patch's base commit, which the url leaves out
    fork: struct { identity: []const u8, id: []const u8, oid: []const u8 = "", base_oid: []const u8 = "", patch_base_oid: []const u8 = "" },

    pub fn page(self: Route, start: usize, path: []const u8) ?ui.RoutablePage {
        return switch (self) {
            .repo => |r| ui.RoutablePage.repoDiffRoute(r.identity, r.ref_or_oid, r.value, start, path, r.base_oid),
            .patchrev => |r| ui.RoutablePage.repoPatchRevDiffRoute(r.identity, r.id, start, path),
            .fork => |f| ui.RoutablePage.forkDiffRoute(f.identity, f.id, f.oid, f.base_oid, start, path),
        };
    }

    fn link(self: Route, arena: *std.heap.ArenaAllocator, start: usize, path: []const u8) ![]const u8 {
        const route = self.page(start, path) orelse return error.RouteTooLong;
        return arena.allocator().print("a:{s}", .{try route.toUrl(arena)});
    }

    // a link to the file's content in the files view, from the base commit for a removed file
    fn fileLink(self: Route, arena: *std.heap.ArenaAllocator, path: []const u8, status: Status) ![]const u8 {
        const route = (if (status == .removed) switch (self) {
            .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
            .patchrev => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
            .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, if (f.base_oid.len != 0) f.base_oid else f.patch_base_oid, path, 0),
        } else switch (self) {
            .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, path, 0),
            .patchrev => |r| ui.RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, path, 0),
            .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, f.oid, path, 0),
        }) orelse return error.RouteTooLong;
        return arena.allocator().print("a:{s}", .{try route.toUrl(arena)});
    }
};

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    route: ui.RoutablePage.RepoDiffRoute,
) !Self {
    const aa = arena.allocator();
    const oid_len = comptime xit.hash.hexLen(repo_opts.hash);
    const identity = try aa.dupe(u8, route.name.slice());
    const base_oid, const head_oid, const diff_route = if (route.patchrev_id.len != 0) blk: {
        const id = evt.parseEventId(route.patchrev_id.slice()) catch return error.NotFound;
        const record = (try evt.readFromRepo(evt.PatchRev, repo_kind, repo_opts, io, gpa, arena, repo, &id)) orelse return error.NotFound;
        if (record.removed) return error.NotFound;
        if (record.base_tree_oid.len != oid_len or record.head_tree_oid.len != oid_len) return error.NotFound;
        break :blk .{
            record.base_tree_oid[0..oid_len].*,
            record.head_tree_oid[0..oid_len].*,
            Route{ .patchrev = .{ .identity = identity, .id = try aa.dupe(u8, route.patchrev_id.slice()), .base_oid = try aa.dupe(u8, record.event.base_oid) } },
        };
    } else blk: {
        const resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, route.ref_or_oid, route.value.slice())) orelse return error.NotFound;
        evt.PatchRev.validateOid(repo_opts.hash, &resolved.oid) catch return error.NotFound;
        evt.PatchRev.validateOid(repo_opts.hash, route.base_oid.slice()) catch return error.NotFound;

        var moment = try repo.core.latestMoment();
        const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
        // peel annotated tags before comparing their trees
        var tip = try xit.object.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &resolved.oid);
        defer tip.deinit();
        break :blk .{
            route.base_oid.slice()[0..oid_len].*,
            tip.oid,
            Route{ .repo = .{
                .identity = identity,
                .ref_or_oid = resolved.ref_or_oid,
                .value = resolved.value,
                .base_oid = try aa.dupe(u8, route.base_oid.slice()),
            } },
        };
    };
    const path = try aa.dupe(u8, route.path.slice());
    return .{
        .route = diff_route,
        .path = path,
        .window = try render(repo_kind, repo_opts, io, gpa, aa, repo, if (std.mem.allEqual(u8, &base_oid, '0')) null else &base_oid, head_oid, route.start, path),
    };
}

// render a window of the net diff between two commits or trees
pub fn render(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    base_oid: ?*const [xit.hash.hexLen(repo_opts.hash)]u8,
    head_oid: [xit.hash.hexLen(repo_opts.hash)]u8,
    start: usize,
    path: []const u8,
) !Window {
    var tree_diff = try repo.treeDiff(io, gpa, base_oid, &head_oid);
    defer tree_diff.deinit();

    var file_iter = try repo.filePairs(io, gpa, .{ .tree = .{ .tree_diff = &tree_diff } });

    var hunks: std.ArrayList(Hunk) = .empty;
    var index: usize = 0; // running hunk index across all files
    var has_more = false;

    file_loop: while (try file_iter.next()) |pair_val| {
        var pair = pair_val;
        defer pair.deinit();

        if (path.len != 0 and !std.mem.eql(u8, pair.path, path)) continue;

        // an added or removed file shows only its path
        const status: Status = if (pair.a.source == .nothing) .added else if (pair.b.source == .nothing) .removed else .changed;
        if (status != .changed) {
            const i = index;
            index += 1;
            if (i < start) continue;
            if (hunks.items.len >= page_size) {
                has_more = true;
                break :file_loop;
            }
            try hunks.append(arena, .{ .path = try arena.dupe(u8, pair.path), .text = "", .prefixes = "", .status = status });
            continue;
        }

        var hunk_iter = try df.HunkIterator(repo_kind, repo_opts).init(gpa, &pair.a, &pair.b);
        defer hunk_iter.deinit(gpa);

        // the path label rides on the first of this file's hunks we actually show.
        var path_attached = false;
        while (try hunk_iter.next(gpa)) |hunk_val| {
            var hunk = hunk_val;
            defer hunk.deinit(gpa);

            const i = index;
            index += 1;
            if (i < start) continue; // before this window
            if (hunks.items.len >= page_size) {
                has_more = true;
                break :file_loop;
            }
            const rendered = try renderHunk(repo_kind, repo_opts, arena, &hunk_iter, &hunk);
            try hunks.append(arena, .{
                .path = if (path_attached) null else try arena.dupe(u8, pair.path),
                .text = rendered.text,
                .prefixes = rendered.prefixes,
            });
            path_attached = true;
        }
    }

    return .{ .hunks = try hunks.toOwnedSlice(arena), .start = start, .has_more = has_more };
}

// render edits with right-aligned line numbers, alongside each line's prefix
fn renderHunk(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: std.mem.Allocator,
    hunk_iter: *df.HunkIterator(repo_kind, repo_opts),
    hunk: *df.Hunk(repo_kind, repo_opts),
) !struct { text: []const u8, prefixes: []const u8 } {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var prefixes: std.ArrayList(u8) = .empty;
    var max_num: usize = 1;
    for (hunk.edits.items) |edit| {
        const n = editLineNum(edit) + 1;
        if (n > max_num) max_num = n;
    }
    const width = std.fmt.count("{d}", .{max_num});
    for (hunk.edits.items, 0..) |edit, i| {
        const text = switch (edit) {
            .eql => |e| try hunk_iter.line_iter_b.get(e.new_line.num),
            .ins => |e| try hunk_iter.line_iter_b.get(e.new_line.num),
            .del => |e| try hunk_iter.line_iter_a.get(e.old_line.num),
        };
        const prefix: u8 = switch (edit) {
            .eql => ' ',
            .ins => '+',
            .del => '-',
        };
        if (i != 0) try out.writer.writeByte('\n');
        const num = editLineNum(edit) + 1;
        try out.writer.splatByteAll(' ', width - std.fmt.count("{d}", .{num}));
        try out.writer.print("{d} {c}{s}", .{ num, prefix, text });
        try prefixes.append(arena, prefix);
    }
    return .{ .text = try out.toOwnedSlice(), .prefixes = try prefixes.toOwnedSlice(arena) };
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

fn appendWindow(data: @This(), allocator: std.mem.Allocator, session: *ui.Session, box: *wgt.Box(ui.Widget)) !void {
    if (data.path.len != 0) {
        const status = if (data.window.hunks.len > 0) data.window.hunks[0].status else .changed;
        try addSpans(allocator, box, &.{.{ .text = data.path }}, try data.route.fileLink(session.page_arena, data.path, status), status.label(), status.border());
        try addLink(allocator, box, "← all files", try data.route.link(session.page_arena, 0, ""));
    }
    if (data.window.start > 0) try addLink(allocator, box, "← previous", try data.route.link(session.page_arena, data.window.start -| page_size, data.path));
    for (data.window.hunks) |hunk| {
        if (data.path.len == 0) if (hunk.path) |path| {
            // a changed file's path narrows the diff to it, the others open the file
            const link = if (hunk.status == .changed) try data.route.link(session.page_arena, 0, path) else try data.route.fileLink(session.page_arena, path, hunk.status);
            try addSpans(allocator, box, &.{.{ .text = path }}, link, hunk.status.label(), hunk.status.border());
        };
        if (hunk.text.len != 0) try addHunk(allocator, box, hunk);
    }
    if (data.window.has_more) try addLink(allocator, box, "next →", try data.route.link(session.page_arena, data.window.start + page_size, data.path));
}

fn addLink(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: []const u8) !void {
    try addSpans(allocator, box, &.{.{ .text = text }}, link, "", .single);
}

// one span per line, inserted lines green and deleted lines red. the text
// box copies the text, so the spans only live until init.
fn addHunk(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), hunk: Hunk) !void {
    var spans: std.ArrayList(wgt.Span) = .empty;
    defer spans.deinit(allocator);
    var start: usize = 0;
    for (hunk.prefixes) |prefix| {
        // each span keeps its trailing newline so the text box still breaks there
        const end = if (std.mem.indexOfScalarPos(u8, hunk.text, start, '\n')) |nl| nl + 1 else hunk.text.len;
        const style: wgt.Style = switch (prefix) {
            '+' => .{ .fg = .ansi(.green) },
            '-' => .{ .fg = .ansi(.red) },
            else => .{},
        };
        try spans.append(allocator, .{ .text = hunk.text[start..end], .style = style });
        start = end;
    }
    try addSpans(allocator, box, spans.items, "", "", .single);
}

fn addSpans(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), spans: []const wgt.Span, link: []const u8, label: []const u8, border: wgt.Border) !void {
    var tb = try wgt.TextBox.initSpans(allocator, spans, .{ .border = border, .round_corners = true, .wrap_kind = .none, .top_label = .{ .text = label } });
    errdefer tb.deinit(allocator);
    tb.getFocus().mode = .all;
    if (link.len != 0) tb.getFocus().kind = .{ .custom = link };
    try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null, .flex = .shrink });
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var view: View = blk: {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
            errdefer box.deinit(allocator);
            break :blk .{ .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .both, .web_native = !session.is_terminal, .fill = true }) };
        };
        errdefer view.deinit(allocator);
        const box = view.inner();
        try data.appendWindow(allocator, session, box);
        if (box.children.count() == 0) try addLink(allocator, box, "no changes", "");
        box.getFocus().child_id = box.children.keys()[0];
        return view;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }
    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.scroll.build(allocator, constraint, root_focus);
    }
    pub fn clearGrid(self: *View) void {
        self.scroll.clearGrid();
    }
    pub fn getGrid(self: View) ?Grid {
        return self.scroll.getGrid();
    }
    pub fn getFocus(self: *View) *Focus {
        return self.scroll.getFocus();
    }
    pub fn atTop(self: *View) bool {
        const box = self.inner();
        return self.scroll.y == 0 and (box.children.count() == 0 or box.getFocus().child_id == box.children.keys()[0]);
    }
    fn inner(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.box;
    }
    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const sc = &self.scroll;
        const box = self.inner();
        if (inp.rowDelta(key, @intCast(box.children.count()))) |delta| return ui.widget.moveRowFocus(box, sc, root_focus, delta);
        switch (key) {
            // scroll horizontally within the diff
            .arrow_left => if (!ui.widget.moveInSelectedRow(box, root_focus, false) and sc.x > 0) {
                sc.x -= 1;
                sc.clampToContent();
            },
            .arrow_right => if (!ui.widget.moveInSelectedRow(box, root_focus, true)) {
                sc.x += 1;
                sc.clampToContent();
            },
            // Enter / a click on a "previous"/"next" row follow its "a:" link in
            // the host (it reloads the adjacent window), so they don't reach here.
            else => {},
        }
    }
};

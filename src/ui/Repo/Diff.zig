const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const df = xit.diff;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;

pub const page_size = 10;
pub const Hunk = struct {
    path: ?[]const u8 = null,
    text: []const u8,
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
    commit: struct { location: ui.RoutablePage.RepoLocation, oid: []const u8 },
    fork: struct { identity: []const u8, id: []const u8 },

    fn link(self: Route, arena: *std.heap.ArenaAllocator, start: usize, path: []const u8) ![]const u8 {
        const route = switch (self) {
            .commit => |c| c.location.commitsRoute(.object, c.oid, start, path),
            .fork => |f| ui.RoutablePage.forkDiffRoute(f.identity, f.id, start, path),
        } orelse return error.RouteTooLong;
        return std.fmt.allocPrint(arena.allocator(), "a:{s}", .{try route.toUrl(arena)});
    }
};

// render a window of the net diff between two commits
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
            try hunks.append(arena, .{
                .path = if (path_attached) null else try arena.dupe(u8, pair.path),
                .text = try renderHunk(repo_kind, repo_opts, arena, &hunk_iter, &hunk),
            });
            path_attached = true;
        }
    }

    return .{ .hunks = try hunks.toOwnedSlice(arena), .start = start, .has_more = has_more };
}

// render edits with right-aligned line numbers
fn renderHunk(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: std.mem.Allocator,
    hunk_iter: *df.HunkIterator(repo_kind, repo_opts),
    hunk: *df.Hunk(repo_kind, repo_opts),
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
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
        defer switch (edit) {
            .eql, .ins => hunk_iter.line_iter_b.free(text),
            .del => hunk_iter.line_iter_a.free(text),
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
    }
    return out.toOwnedSlice();
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

pub fn appendWindow(data: @This(), allocator: std.mem.Allocator, session: *ui.Session, box: *wgt.Box(ui.Widget)) !void {
    if (data.path.len != 0) {
        try addLink(allocator, box, data.path, "");
        try addLink(allocator, box, "← all files", try data.route.link(session.page_arena, 0, ""));
    }
    if (data.window.start > 0) try addLink(allocator, box, "← previous", try data.route.link(session.page_arena, data.window.start -| page_size, data.path));
    for (data.window.hunks) |hunk| {
        if (data.path.len == 0) if (hunk.path) |path| try addLink(allocator, box, path, try data.route.link(session.page_arena, 0, path));
        if (hunk.text.len != 0) try addLink(allocator, box, hunk.text, "");
    }
    if (data.window.has_more) try addLink(allocator, box, "next →", try data.route.link(session.page_arena, data.window.start + page_size, data.path));
}

fn addLink(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: []const u8) !void {
    var tb = try wgt.TextBox.init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
    errdefer tb.deinit(allocator);
    tb.getFocus().mode = .all;
    if (link.len != 0) tb.getFocus().kind = .{ .custom = link };
    try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null, .flex = .shrink });
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    session: *ui.Session,

    pub fn initEmpty(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .both, .web_native = !session.is_terminal, .fill = true }),
            .session = session,
        };
    }

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var view = try initEmpty(allocator, session);
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
        switch (key) {
            // scroll horizontally within the diff
            .arrow_left => {
                if (sc.x > 0) {
                    sc.x -= 1;
                    self.scroll.clampToContent();
                }
            },
            .arrow_right => {
                sc.x += 1;
                self.scroll.clampToContent();
            },
            .arrow_up => self.moveDiff(root_focus, -1),
            .arrow_down => self.moveDiff(root_focus, 1),
            .page_up => self.pageDiff(root_focus, -10),
            .page_down => self.pageDiff(root_focus, 10),
            .home => self.jumpDiff(root_focus, false),
            .end => self.jumpDiff(root_focus, true),
            // Enter / a click on a "previous"/"next" row follow its "a:" link in
            // the host (it reloads the adjacent window), so they don't reach here.
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| self.moveDiff(root_focus, if (dir == .up) -1 else 1),
                else => {},
            },
            else => {},
        }
    }

    // move one step in `delta` (+ down, - up). in the terminal, `delta` is a
    // line count unless there is a new hunk visible (in which case it is a
    // hunk count). on the web `delta` is always a hunk count.
    fn moveDiff(self: *View, root_focus: *Focus, delta: isize) void {
        const box = self.inner();
        const keys = box.children.keys();
        if (keys.len == 0) return;
        const cur: usize = if (root_focus.grandchild_id) |g| (box.children.getIndex(g) orelse 0) else 0;
        const target = @as(isize, @intCast(cur)) + delta;
        const in_range = target >= 0 and target < @as(isize, @intCast(keys.len));

        if (self.session.is_terminal) {
            if (in_range and self.hunkVisible(@intCast(target))) {
                root_focus.setFocus(keys[@intCast(target)]);
                return;
            }

            const sc = &self.scroll;
            sc.y += delta * 5; // magnify because it's a line count
            self.scroll.clampToContent();
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
    fn pageDiff(self: *View, root_focus: *Focus, delta: isize) void {
        if (self.session.is_terminal) {
            const sc = &self.scroll;
            sc.y += delta * 5; // magnify because it's a line count
            self.scroll.clampToContent();
            self.focusVisible(root_focus, delta > 0);
        } else {
            const box = self.inner();
            const keys = box.children.keys();
            if (keys.len == 0) return;
            const cur: isize = if (root_focus.grandchild_id) |g| @intCast(box.children.getIndex(g) orelse 0) else 0;
            const target: usize = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(keys.len - 1))));
            root_focus.setFocus(keys[target]);
        }
    }

    // jump to the first or last hunk. on the web the browser scrolls to the
    // focused hunk; on the terminal pin the scroll to the top/bottom too.
    fn jumpDiff(self: *View, root_focus: *Focus, to_end: bool) void {
        const box = self.inner();
        const keys = box.children.keys();
        if (keys.len == 0) return;
        if (self.session.is_terminal) {
            const sc = &self.scroll;
            sc.y = if (to_end) std.math.maxInt(isize) else 0;
            self.scroll.clampToContent();
        }
        root_focus.setFocus(if (to_end) keys[keys.len - 1] else keys[0]);
    }

    // whether hunk `index` is at least partly within the diff viewport, per the
    // last build's layout rects (content space) and the current scroll offset.
    fn hunkVisible(self: *View, index: usize) bool {
        const box = self.inner();
        const sc = &self.scroll;
        const vp = sc.grid orelse return false;
        const r = box.children.values()[index].rect orelse return false;
        const top = sc.y;
        const bottom = sc.y + @as(isize, @intCast(vp.size.height - sc.bar_h));
        return (r.y + @as(isize, @intCast(r.size.height))) > top and r.y < bottom;
    }

    // focus the visible hunk at the scroll's leading edge. `prefer_last` picks
    // the bottom-most visible (for downward motion), else the top-most.
    fn focusVisible(self: *View, root_focus: *Focus, prefer_last: bool) void {
        const box = self.inner();
        const sc = &self.scroll;
        const vp = sc.grid orelse return;
        const top = sc.y;
        const bottom = sc.y + @as(isize, @intCast(vp.size.height - sc.bar_h));
        var chosen: ?usize = null;
        for (box.children.keys(), box.children.values()) |id, *child| {
            const r = child.rect orelse continue; // content-space layout rect
            const r_top = r.y;
            const r_bot = r.y + @as(isize, @intCast(r.size.height));
            if (r_bot <= top or r_top >= bottom) continue; // not visible
            chosen = id;
            if (!prefer_last) break; // first visible
        }
        if (chosen) |id| root_focus.setFocus(id);
    }
};

const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

// how many refs one window of a column shows.
pub const page_size = 20;

// "owner/name", needed to build the columns' window-navigation links.
identity: []const u8,
// only one column windows at a time: `from` (a url-encoded ref name, "" = the
// first window) roots `kind`'s column; the other always shows its first window.
kind: ui.RoutablePage.RefKind,
from: []const u8,
branches: Column,
tags: Column,

const Self = @This();

// one ref column: the current window of names, the raw ref names its
// "← previous" / "next →" rows window from (null = no row; a "" prev means
// the first window), and the header label.
pub const Column = struct {
    names: []const []const u8 = &.{},
    prev: ?[]const u8 = null,
    next: ?[]const u8 = null,
    label: ui.SubTitle,
};

// empty columns, for the wasm / no-repo paths.
pub fn emptyResult(arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, from: []const u8) !Self {
    return .{
        .identity = try arena.allocator().dupe(u8, identity),
        .kind = kind,
        .from = try arena.allocator().dupe(u8, from),
        .branches = .{ .label = try ui.SubTitle.init(arena, "branches") },
        .tags = .{ .label = try ui.SubTitle.init(arena, "tags") },
    };
}

// read one window of each column from an opened repo. the ref names are duped
// into the page arena so they outlive the repo handle.
pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    identity: []const u8,
    kind: ui.RoutablePage.RefKind,
    from: []const u8,
) !Self {
    const aa = arena.allocator();
    var result = try emptyResult(arena, identity, kind, from);
    // the window root only applies to its own column; a ref name arrives
    // url-encoded, and the iterator seeks to the first name at or after it.
    const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, from));
    for (
        [_]ui.RoutablePage.RefKind{ .branch, .tag },
        [_]*Column{ &result.branches, &result.tags },
    ) |col_kind, column| {
        const col_from: []const u8 = if (kind == col_kind) decoded else "";
        // an unreadable listing leaves the column empty
        var iter = listRefs(repo_kind, repo_opts, repo, io, gpa, col_kind, iterStart(col_from)) catch continue;
        defer iter.deinit();
        var names = try std.ArrayListUnmanaged([]const u8).initCapacity(aa, page_size);
        while (names.items.len < page_size) {
            const ref = try iter.next() orelse break;
            names.appendAssumeCapacity(try aa.dupe(u8, ref.name));
        }
        column.names = names.items;
        column.next = if (try iter.next()) |ref| try aa.dupe(u8, ref.name) else null;
        if (col_from.len != 0) {
            var prev_iter = listRefs(repo_kind, repo_opts, repo, io, gpa, col_kind, .beginning) catch continue;
            defer prev_iter.deinit();
            column.prev = try prevRoot(aa, &prev_iter, col_from);
        }
    }
    return result;
}

fn listRefs(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    kind: ui.RoutablePage.RefKind,
    start: xit.ref.RefIteratorStart,
) !xit.ref.RefIterator(repo_kind, repo_opts) {
    return switch (kind) {
        .branch => repo.listBranches(io, gpa, start),
        .tag => repo.listTags(io, gpa, start),
    };
}

fn iterStart(from: []const u8) xit.ref.RefIteratorStart {
    return if (from.len == 0) .beginning else .{ .key = from };
}

// the root of the window before the one starting at `from` (decoded): the ref
// a page before it ("" = the first window), or null when nothing precedes it.
fn prevRoot(aa: std.mem.Allocator, iter: anytype, from: []const u8) !?[]const u8 {
    var ring: [page_size][]const u8 = undefined;
    var count: usize = 0;
    while (try iter.next()) |ref| {
        if (!std.mem.lessThan(u8, ref.name, from)) break;
        ring[count % page_size] = try aa.dupe(u8, ref.name);
        count += 1;
    }
    if (count == 0) return null;
    if (count <= page_size) return "";
    return ring[count % page_size];
}

pub const View = struct {
    // a horizontal box of two vertical columns. each column is a fixed,
    // centered, non-focusable label above a Scroll of focusable rows, so the
    // label stays visible while the rows scroll. focus tracks a single selected
    // row across both columns: the box's focus path points at the active column,
    // that column's at its scroll, and the scroll's (its rows') at the row.
    box: wgt.Box(ui.Widget),
    data: *const Self,

    const left_col = 0;
    const right_col = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        try addColumn(allocator, &box, session, data.identity, .branch, &data.branches);
        try addColumn(allocator, &box, session, data.identity, .tag, &data.tags);

        var self = View{ .box = box, .data = data };
        // select the first row of the first column that has one.
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            if (child.widget.box.getFocus().child_id != null) {
                self.box.getFocus().child_id = id;
                break;
            }
        }
        return self;
    }

    fn addColumn(
        allocator: std.mem.Allocator,
        box: *wgt.Box(ui.Widget),
        session: *ui.Session,
        identity: []const u8,
        kind: ui.RoutablePage.RefKind,
        data: *const Column,
    ) !void {
        var column = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer column.deinit(allocator);

        // a fixed, non-focusable header in the SubTitle font, nudged off the
        // left edge by a one-column space. it stays visible while the rows
        // scroll below, and declares its height (2 rows) as a min so the (fill)
        // scroll reserves room for it rather than consuming the whole column.
        {
            var header_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer header_box.deinit(allocator);
            {
                var space = try wgt.Text(ui.Widget).init(allocator, " ");
                errdefer space.deinit(allocator);
                try header_box.children.put(allocator, space.getFocus().id, .{ .widget = .{ .text = space }, .rect = null, .min_size = null });
            }
            {
                var header = try ui.SubTitle.View.init(allocator, &data.label);
                errdefer header.deinit(allocator);
                try header_box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .sub_title = header }, .rect = null, .min_size = null });
            }
            try column.children.put(allocator, header_box.getFocus().id, .{ .widget = .{ .box = header_box }, .rect = null, .min_size = .{ .width = null, .height = 2 } });
        }

        // a long ref list overflows the page height; the rows scroll on their
        // own (the label above stays put) so they lay out under a fixed height.
        {
            var scroll = blk: {
                var rows = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer rows.deinit(allocator);

                // window-navigation rows bracket the names: "← previous" off the
                // first window, "next →" when more remain. each is a full reload.
                if (data.prev) |p| try addRow(allocator, &rows, "← previous", try windowLink(session.page_arena, identity, kind, p));
                // each ref name links to the files tab at that ref's root.
                for (data.names) |name| try addRow(allocator, &rows, name, try refLink(session.page_arena, identity, kind, name));
                if (data.next) |n| try addRow(allocator, &rows, "next →", try windowLink(session.page_arena, identity, kind, n));

                if (rows.children.count() > 0) rows.getFocus().child_id = rows.children.keys()[0];

                // fill the column (rows top-aligned, scroll bar pinned to the
                // edge) rather than shrinking to the widest row.
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);

            // the column's focus path skips the label and points at the scroll.
            if (scroll.getFocus().child_id != null) column.getFocus().child_id = scroll.getFocus().id;
            try column.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });
        }

        try box.children.put(allocator, column.getFocus().id, .{ .widget = .{ .box = column }, .rect = null, .min_size = null });
    }

    // [0] = the fixed label, [1] = the scrollable rows.
    fn columnScroll(column: *wgt.Box(ui.Widget)) *wgt.Scroll(ui.Widget) {
        return &column.children.values()[1].widget.scroll;
    }

    // a focusable row in a column. `link`, when present, is the row's `a:`
    // navigation kind (the window-navigation rows); ref names pass null.
    fn addRow(allocator: std.mem.Allocator, col: *wgt.Box(ui.Widget), label: []const u8, link: ?[]const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link) |l| row.getFocus().kind = .{ .custom = l };
        try col.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // the selected row (in the active column) shows a single border; the
        // focused TextBox upgrades it to a double border itself.
        const active_col_id = self.box.getFocus().child_id;
        for (self.box.children.values()) |*child| {
            const column = &child.widget.box;
            const col = &columnScroll(column).child.box;
            const active = column.getFocus().id == active_col_id;
            for (col.children.keys(), col.children.values()) |id, *row| {
                switch (row.widget) {
                    .text_box => |*tb| tb.options.border_style = if (active and col.getFocus().child_id == id) .single else .hidden,
                    else => {},
                }
            }
        }

        // split the available width evenly between the two columns when it's
        // known; otherwise let them size to their content. each column's Scroll
        // has `fill = true`, so it stretches across the column (rows/scroll bar)
        // rather than hugging the widest row.
        if (constraint.max_size.width) |w| {
            const half = w / 2;
            for (self.box.children.values()) |*child| {
                child.min_size = .{ .width = half, .height = null };
                child.max_size = .{ .width = half, .height = null };
            }
        } else {
            for (self.box.children.values()) |*child| {
                child.min_size = null;
                child.max_size = null;
            }
        }

        // clear the incoming min height; each column's Scroll fills the viewport
        // height itself (via `fill`), keeping its bar pinned to the edge.
        try self.box.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        // up/down (and the scroll wheel) move within the active column a row;
        // page up/down and home/end jump; left/right switch columns, keeping the
        // same row offset. the parent (Repo) intercepts up at the top row to move
        // focus to the header.
        if (inp.rowDelta(key, self.columnRowCount())) |delta| {
            const scroll = self.activeScroll() orelse return;
            ui.moveRowFocus(&scroll.child.box, scroll, root_focus, delta);
            return;
        }
        switch (key) {
            .arrow_left => try self.switchColumn(root_focus, left_col),
            .arrow_right => try self.switchColumn(root_focus, right_col),
            else => {},
        }
    }

    // the active column's row count, used as a clamp-to-end delta for home/end.
    fn columnRowCount(self: *View) isize {
        const col = self.activeColumn() orelse return 0;
        return @intCast(col.children.count());
    }

    fn activeScroll(self: *View) ?*wgt.Scroll(ui.Widget) {
        const id = self.box.getFocus().child_id orelse return null;
        const index = self.box.children.getIndex(id) orelse return null;
        return columnScroll(&self.box.children.values()[index].widget.box);
    }

    fn activeColumn(self: *View) ?*wgt.Box(ui.Widget) {
        return &(self.activeScroll() orelse return null).child.box;
    }

    fn switchColumn(self: *View, root_focus: *Focus, target: usize) !void {
        if (target >= self.box.children.count()) return;
        const cur_col = self.activeColumn() orelse return;
        const target_scroll = columnScroll(&self.box.children.values()[target].widget.box);
        const target_col = &target_scroll.child.box;
        // an empty column has nothing to select; ignore.
        if (target_col.children.count() == 0) return;
        // keep the same row offset, clamped to the target column's last row.
        const cur_id = cur_col.getFocus().child_id orelse return;
        const cur = cur_col.children.getIndex(cur_id) orelse return;
        const last = target_col.children.count() - 1;
        const next = @min(cur, last);
        root_focus.setFocus(target_col.children.keys()[next]);
        if (target_col.children.values()[next].rect) |rect| target_scroll.scrollToRect(rect);
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

    // the selected row's offset within the active column (0 = first row), so the
    // parent knows when up should escape to the header.
    pub fn getSelectedIndex(self: View) ?usize {
        var copy = self;
        const col = copy.activeColumn() orelse return null;
        const cur_id = col.getFocus().child_id orelse return null;
        return col.children.getIndex(cur_id);
    }
};

// the "a:" link to `kind`'s column windowed from ref `name` (raw; "" = the
// first window) within `identity` ("owner/name"). the other column resets to
// its first window.
fn windowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, name: []const u8) ![]const u8 {
    const encoded = try ui.urlEncodeRef(page_arena.allocator(), name);
    const route = ui.RoutablePage.repoRefsRoute(identity, kind, encoded) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "a:" link to the files tab at ref `name` (a branch or tag) within
// `identity` ("owner/name"), at its root directory. the name is percent-encoded
// since it can contain a '/'.
fn refLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, name: []const u8) ![]const u8 {
    const aa = page_arena.allocator();
    const ref_or_oid: ui.RoutablePage.RefOrOid = switch (kind) {
        .branch => .branch,
        .tag => .tag,
    };
    const value = try ui.urlEncodeRef(aa, name);
    const route = ui.RoutablePage.repoFilesRoute(identity, ref_or_oid, value, "", 0) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(aa, "a:{s}", .{url});
}

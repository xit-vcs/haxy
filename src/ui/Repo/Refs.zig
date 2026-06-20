const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// how many refs one window of a column shows.
pub const page_size = 20;

// "owner/name", needed to build the columns' window-navigation links.
identity: []const u8,
// only one column paginates at a time: `after` is the window start of `kind`'s
// column; the other column always starts at 0.
kind: ui.RoutablePage.RefKind,
after: usize,
// the current window of each column, plus the next window's start (null at the
// end) so the view can decide whether to show a "next →" row.
branches: []const []const u8,
tags: []const []const u8,
branches_next_after: ?usize,
tags_next_after: ?usize,
// the columns' headers, in the half-height SubTitle font.
branches_label: ui.SubTitle,
tags_label: ui.SubTitle,

const Self = @This();

const Window = struct { names: []const []const u8, next_after: ?usize };

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    kind: ui.RoutablePage.RefKind,
    after: usize,
) !Self {
    const aa = arena.allocator();
    // the offset only applies to its own column; the other stays at 0.
    const branches_after: usize = if (kind == .branch) after else 0;
    const tags_after: usize = if (kind == .tag) after else 0;
    const branches_label = try ui.SubTitle.init(arena, "branches");
    const tags_label = try ui.SubTitle.init(arena, "tags");
    const empty: Self = .{
        .identity = try aa.dupe(u8, identity),
        .kind = kind,
        .after = after,
        .branches = &.{},
        .tags = &.{},
        .branches_next_after = null,
        .tags_next_after = null,
        .branches_label = branches_label,
        .tags_label = tags_label,
    };

    // no filesystem (wasm) or nowhere to look: empty lists. the wasm path never
    // calls init anyway — it rebuilds from the serialized snapshot.
    const io = session.io orelse return empty;
    const repos_dir = session.repos_dir orelse return empty;

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // open with the arena's backing allocator (transient; the ref names are
    // duped into the page arena so they outlive the repo handle).
    const gpa = arena.child_allocator;
    var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return empty;
    defer repo.deinit(io, gpa);

    var branch_iter = repo.listBranches(io, gpa, .{ .index = branches_after }) catch return empty;
    defer branch_iter.deinit(io);
    const branches = try collectWindow(io, aa, &branch_iter, branches_after);

    var tag_iter = repo.listTags(io, gpa, .{ .index = tags_after }) catch return empty;
    defer tag_iter.deinit(io);
    const tags = try collectWindow(io, aa, &tag_iter, tags_after);

    return .{
        .identity = empty.identity,
        .kind = kind,
        .after = after,
        .branches = branches.names,
        .tags = tags.names,
        .branches_next_after = branches.next_after,
        .tags_next_after = tags.next_after,
        .branches_label = branches_label,
        .tags_label = tags_label,
    };
}

// window a ref iterator without materializing the whole list
fn collectWindow(io: std.Io, aa: std.mem.Allocator, iter: anytype, after: usize) !Window {
    var names = try std.ArrayListUnmanaged([]const u8).initCapacity(aa, page_size);
    while (names.items.len < page_size) {
        const ref = try iter.next(io) orelse break;
        names.appendAssumeCapacity(try aa.dupe(u8, ref.name));
    }
    const has_more = (try iter.next(io)) != null;
    return .{ .names = names.items, .next_after = if (has_more) after + page_size else null };
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

        // the offset only applies to its own column; the other starts at 0.
        const branches_after: usize = if (data.kind == .branch) data.after else 0;
        const tags_after: usize = if (data.kind == .tag) data.after else 0;
        try addColumn(allocator, &box, session, data.identity, .branch, &data.branches_label, data.branches, branches_after, data.branches_next_after);
        try addColumn(allocator, &box, session, data.identity, .tag, &data.tags_label, data.tags, tags_after, data.tags_next_after);

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
        label: *const ui.SubTitle,
        names: []const []const u8,
        after: usize,
        next_after: ?usize,
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
                var header = try ui.SubTitle.View.init(allocator, label);
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
                if (after > 0) try addRow(allocator, &rows, "← previous", try windowLink(session.page_arena, identity, kind, after -| page_size));
                // each ref name links to the files tab at that ref's root.
                for (names) |name| try addRow(allocator, &rows, name, try refLink(session.page_arena, identity, kind, name));
                if (next_after) |na| try addRow(allocator, &rows, "next →", try windowLink(session.page_arena, identity, kind, na));

                if (rows.children.count() > 0) rows.getFocus().child_id = rows.children.keys()[0];

                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal });
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
        // known; otherwise let them size to their content. the scroll's own
        // min width stretches it (and its rows/scroll bar) across the column
        // rather than only the widest row; the Scroll passes that min down to
        // its rows. (index 1 in each column box is the scroll; 0 is the label.)
        if (constraint.max_size.width) |w| {
            const half = w / 2;
            for (self.box.children.values()) |*child| {
                child.min_size = .{ .width = half, .height = null };
                child.max_size = .{ .width = half, .height = null };
                child.widget.box.children.values()[1].min_size = .{ .width = half, .height = null };
            }
        } else {
            for (self.box.children.values()) |*child| {
                child.min_size = null;
                child.max_size = null;
                child.widget.box.children.values()[1].min_size = null;
            }
        }

        // clear the incoming min height so each column sizes to its content and
        // its Scroll clips to the viewport rather than stretching to fill.
        try self.box.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        // up/down (and the scroll wheel) move within the active column a row;
        // page up/down and home/end jump; left/right switch columns, keeping the
        // same row offset. the parent (Repo) intercepts up at the top row to move
        // focus to the header.
        switch (key) {
            .arrow_up => try self.moveRow(root_focus, -1),
            .arrow_down => try self.moveRow(root_focus, 1),
            .arrow_left => try self.switchColumn(root_focus, left_col),
            .arrow_right => try self.switchColumn(root_focus, right_col),
            .page_down => try self.moveRow(root_focus, 10),
            .page_up => try self.moveRow(root_focus, -10),
            .end => try self.moveRow(root_focus, self.columnRowCount()),
            .home => try self.moveRow(root_focus, -self.columnRowCount()),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveRow(root_focus, if (dir == .up) -1 else 1),
                else => {},
            },
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

    fn moveRow(self: *View, root_focus: *Focus, delta: isize) !void {
        const scroll = self.activeScroll() orelse return;
        const col = &scroll.child.box;
        const keys = col.children.keys();
        if (keys.len == 0) return;
        const cur_id = col.getFocus().child_id orelse return;
        const cur: isize = @intCast(col.children.getIndex(cur_id) orelse return);
        // clamp a delta past either end to the first/last row.
        const last: isize = @intCast(keys.len - 1);
        const next: usize = @intCast(std.math.clamp(cur + delta, 0, last));
        if (next == @as(usize, @intCast(cur))) return;
        try root_focus.setFocus(keys[next]);
        if (col.children.values()[next].rect) |rect| scroll.scrollToRect(rect);
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
        try root_focus.setFocus(target_col.children.keys()[next]);
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

// the "a:" link to `kind`'s column paginated to `after` within `identity`
// ("owner/name"). the other column resets to its first window.
fn windowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, after: usize) ![]const u8 {
    const route = ui.RoutablePage.repoRefsRoute(identity, kind, after) orelse return error.RouteTooLong;
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
    const value = try ui.ResolvedRefOrOid.urlEncode(aa, name);
    const route = ui.RoutablePage.repoFilesRoute(identity, ref_or_oid, value, "") orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(aa, "a:{s}", .{url});
}

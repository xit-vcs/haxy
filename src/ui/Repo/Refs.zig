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
pub const page_size = 50;

// "owner/name", needed to build the columns' window-navigation links.
identity: []const u8,
// only one column windows at a time: `from` (a url-encoded ref name, "" = the
// first window) roots `kind`'s column; the other always shows its first window.
kind: ui.RoutablePage.RefKind,
from: []const u8,
// the prefix both columns are narrowed to (decoded; null = no search)
search: ?[]const u8,
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
pub fn emptyResult(arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, from: []const u8, search: []const u8) !Self {
    const aa = arena.allocator();
    return .{
        .identity = try aa.dupe(u8, identity),
        .kind = kind,
        .from = try aa.dupe(u8, from),
        .search = if (search.len == 0) null else std.Uri.percentDecodeInPlace(try aa.dupe(u8, search)),
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
    search: []const u8,
) !Self {
    const aa = arena.allocator();
    var result = try emptyResult(arena, identity, kind, from, search);
    const prefix = result.search orelse "";
    // the window root only applies to its own column; a ref name arrives
    // url-encoded, and the iterator seeks to the first name at or after it.
    const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, from));
    for (
        [_]ui.RoutablePage.RefKind{ .branch, .tag },
        [_]*Column{ &result.branches, &result.tags },
    ) |col_kind, column| {
        const col_from: []const u8 = if (kind == col_kind) decoded else "";
        // an unreadable listing leaves the column empty. the names are sorted,
        // so those with the prefix are contiguous from the prefix itself.
        var iter = listRefs(repo_kind, repo_opts, repo, io, gpa, col_kind, iterStart(laterKey(prefix, col_from))) catch continue;
        defer iter.deinit();
        var names = try std.ArrayListUnmanaged([]const u8).initCapacity(aa, page_size);
        while (try iter.next()) |ref| {
            if (!std.mem.startsWith(u8, ref.name, prefix)) break;
            if (names.items.len == page_size) {
                column.next = try aa.dupe(u8, ref.name);
                break;
            }
            names.appendAssumeCapacity(try aa.dupe(u8, ref.name));
        }
        column.names = names.items;
        if (col_from.len != 0) {
            var prev_iter = listRefs(repo_kind, repo_opts, repo, io, gpa, col_kind, iterStart(prefix)) catch continue;
            defer prev_iter.deinit();
            column.prev = try prevRoot(aa, &prev_iter, prefix, col_from);
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

// the later of two ref names, so a window never starts before the prefix
fn laterKey(a: []const u8, b: []const u8) []const u8 {
    return if (std.mem.lessThan(u8, a, b)) b else a;
}

// the root of the window before the one starting at `from` (decoded) among the
// names with `prefix`: the ref a page before it ("" = the first window), or null
// when nothing precedes it. `iter` starts at the prefix.
fn prevRoot(aa: std.mem.Allocator, iter: anytype, prefix: []const u8, from: []const u8) !?[]const u8 {
    var ring: [page_size][]const u8 = undefined;
    var count: usize = 0;
    while (try iter.next()) |ref| {
        if (!std.mem.startsWith(u8, ref.name, prefix) or !std.mem.lessThan(u8, ref.name, from)) break;
        ring[count % page_size] = try aa.dupe(u8, ref.name);
        count += 1;
    }
    if (count == 0) return null;
    if (count <= page_size) return "";
    return ring[count % page_size];
}

pub const View = struct {
    // a vertical box: the search sub-header above a horizontal box of two
    // columns. each column is a fixed label above a
    // Scroll of a TagFlow, so the names wrap across the column and scroll
    // beneath the label. focus points at the header or the active column and,
    // in its flow, the selected name.
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const header_index = 0;
    const columns_index = 1;
    const left_col = 0;
    const right_col = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // both backends list refs in sorted order, so a prefix is just a seek
        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            {
                var search_box = try ui.widget.SearchBox.init(allocator, session, " search ", "search", data.search);
                errdefer search_box.deinit(allocator);
                header.getFocus().child_id = search_box.getFocus().id;
                try header.children.put(allocator, search_box.getFocus().id, .{ .widget = .{ .search_box = search_box }, .rect = null, .min_size = ui.widget.SearchBox.min_size });
            }
            // the spacer keeps the box at its own width
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try header.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
            // a row taller than the box, leaving a blank line above the columns
            try outer.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        {
            var split = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer split.deinit(allocator);

            const search = data.search orelse "";
            try addColumn(allocator, &split, session, data.identity, search, .branch, &data.branches);
            try addColumn(allocator, &split, session, data.identity, search, .tag, &data.tags);

            // select the first name of the first column that has one
            for (split.children.keys(), split.children.values()) |id, *child| {
                if (child.widget.box.getFocus().child_id != null) {
                    split.getFocus().child_id = id;
                    break;
                }
            }
            try outer.children.put(allocator, split.getFocus().id, .{ .widget = .{ .box = split }, .rect = null, .min_size = null });
        }

        // search results start in the box so the term can be refined right away
        outer.getFocus().child_id = outer.children.keys()[if (data.search != null) header_index else columns_index];
        return .{ .box = outer, .data = data, .session = session };
    }

    fn addColumn(
        allocator: std.mem.Allocator,
        box: *wgt.Box(ui.Widget),
        session: *ui.Session,
        identity: []const u8,
        search: []const u8,
        kind: ui.RoutablePage.RefKind,
        data: *const Column,
    ) !void {
        var column = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer column.deinit(allocator);

        // a fixed, non-focusable header in the SubTitle font, nudged off the
        // left edge by a one-column space. it declares its height (2 rows plus
        // a blank one beneath) as a min so the (fill) scroll reserves room for it.
        {
            var header_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer header_box.deinit(allocator);
            {
                var space = try wgt.Text.init(allocator, " ");
                errdefer space.deinit(allocator);
                try header_box.children.put(allocator, space.getFocus().id, .{ .widget = .{ .text = space }, .rect = null, .min_size = null });
            }
            {
                var header = try ui.SubTitle.View.init(allocator, &data.label);
                errdefer header.deinit(allocator);
                try header_box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .sub_title = header }, .rect = null, .min_size = null });
            }
            try column.children.put(allocator, header_box.getFocus().id, .{ .widget = .{ .box = header_box }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        // each name links to the files tab at that ref's root. window
        // navigation brackets them: "← previous" off the first window, "next →"
        // when more remain, each a full reload.
        {
            var items: std.ArrayList(ui.widget.TagFlow.Item) = .empty;
            defer items.deinit(allocator);
            if (data.prev) |p| try items.append(allocator, .{ .text = "← previous", .link = try windowLink(session.page_arena, identity, kind, p, search) });
            for (data.names) |name| try items.append(allocator, .{ .text = name, .link = try refLink(session.page_arena, identity, kind, name) });
            if (data.next) |n| try items.append(allocator, .{ .text = "next →", .link = try windowLink(session.page_arena, identity, kind, n, search) });

            var scroll = blk: {
                var flow = try ui.widget.TagFlow.init(allocator);
                errdefer flow.deinit(allocator);
                try flow.setItems(allocator, items.items);
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .tag_flow = flow }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);

            // the column's focus path skips the label and points at the flow
            if (scroll.getFocus().child_id != null) column.getFocus().child_id = scroll.getFocus().id;
            try column.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });
        }

        try box.children.put(allocator, column.getFocus().id, .{ .widget = .{ .box = column }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // split the available width evenly between the two columns when it's
        // known; otherwise let them size to their content.
        if (constraint.max_size.width) |w| {
            const half = w / 2;
            for (self.columns().children.values()) |*child| {
                child.min_size = .{ .width = half, .height = null };
                child.max_size = .{ .width = half, .height = null };
            }
        } else {
            for (self.columns().children.values()) |*child| {
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
        if (self.headerActive()) {
            const search_box = self.searchBox();
            if (inp.vertDirection(key) == .down) return root_focus.setFocus(self.columns().getFocus().id);
            if (key == .enter) {
                const text = try search_box.text(allocator);
                defer allocator.free(text);
                return self.submit(text);
            }
            return search_box.input(allocator, key, root_focus);
        }
        // arrows and the scroll wheel move the selection within the active
        // flow. left from a row's first name and right from its last cross to
        // the other column's same row. up from a first row reaches the search
        // box.
        const index = self.activeIndex() orelse return;
        const flow = self.flowAt(index);
        const cur = flow.indexOfFocusId(flow.focus.child_id orelse return) orelse return;
        // a flow last laid out at zero width has names without positions
        if (cur >= flow.rects.items.len) return;
        const count = flow.text_boxes.items.len;
        const cur_y = flow.rects.items[cur].y;
        switch (inp.vertDirection(key)) {
            .up => {
                if (flow.rowStep(cur, false)) |i| self.focusName(index, i, root_focus) else _ = self.focusHeader(root_focus);
                return;
            },
            .down => {
                if (flow.rowStep(cur, true)) |i| self.focusName(index, i, root_focus);
                return;
            },
            .none => {},
        }
        switch (key) {
            .arrow_left => if (index == right_col and rowStart(flow, cur)) {
                self.crossTo(left_col, cur_y, root_focus);
            } else if (cur > 0) self.focusName(index, cur - 1, root_focus),
            .arrow_right => if (index == left_col and rowEnd(flow, cur)) {
                self.crossTo(right_col, cur_y, root_focus);
            } else if (cur + 1 < count) self.focusName(index, cur + 1, root_focus),
            .home => self.focusName(index, 0, root_focus),
            .end => self.focusName(index, count - 1, root_focus),
            else => {},
        }
    }

    // both lists narrowed to `text`, each from its first window. an empty box
    // on an unsearched page has nothing to clear.
    fn submit(self: *View, text: []const u8) !void {
        if (text.len == 0 and self.data.search == null) return;
        const route = ui.RoutablePage.repoRefsRoute(self.data.identity, .branch, "") orelse return;
        try self.session.navigate(route.withSearch(text) orelse return);
    }

    fn searchBox(self: *View) *ui.widget.SearchBox {
        return &self.box.children.values()[header_index].widget.box.children.values()[0].widget.search_box;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
    }

    fn columns(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[columns_index].widget.box;
    }

    fn activeIndex(self: *View) ?usize {
        const cols = self.columns();
        const id = cols.getFocus().child_id orelse return null;
        return cols.children.getIndex(id);
    }

    // [0] = the fixed label, [1] = the scrolling flow
    fn scrollAt(self: *View, index: usize) *wgt.Scroll(ui.Widget) {
        return &self.columns().children.values()[index].widget.box.children.values()[1].widget.scroll;
    }

    fn flowAt(self: *View, index: usize) *ui.widget.TagFlow {
        return &self.scrollAt(index).child.tag_flow;
    }

    fn rowStart(flow: *ui.widget.TagFlow, item: usize) bool {
        const rects = flow.rects.items;
        return item == 0 or rects[item - 1].y != rects[item].y;
    }

    fn rowEnd(flow: *ui.widget.TagFlow, item: usize) bool {
        const rects = flow.rects.items;
        return item + 1 == rects.len or rects[item + 1].y != rects[item].y;
    }

    // land on the other column's row at or above the current one: its first
    // name when moving right, its last when moving left. names are laid out in
    // order, so that row ends at the last name no lower than the current one.
    fn crossTo(self: *View, target: usize, from_y: isize, root_focus: *Focus) void {
        // the other column may have no names at all
        const rects = self.flowAt(target).rects.items;
        if (rects.len == 0) return;
        var last: usize = 0;
        for (rects, 0..) |rect, i| {
            if (rect.y <= from_y) last = i;
        }
        var first = last;
        while (first > 0 and rects[first - 1].y == rects[last].y) first -= 1;
        self.focusName(target, if (target == right_col) first else last, root_focus);
    }

    fn focusName(self: *View, index: usize, item: usize, root_focus: *Focus) void {
        const flow = self.flowAt(index);
        root_focus.setFocus(flow.text_boxes.items[item].getFocus().id);
        // the browser scrolls natively; the terminal brings the name into view
        if (self.session.is_terminal and item < flow.rects.items.len) self.scrollAt(index).scrollToRect(flow.rects.items[item]);
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

    // up leaves the tab from the search box
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        root_focus.setFocus(self.searchBox().getFocus().id);
        return true;
    }
};

// the "a:" link to `kind`'s column windowed from ref `name` (raw; "" = the
// first window) within `identity` ("owner/name"). the other column resets to
// its first window.
fn windowLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, kind: ui.RoutablePage.RefKind, name: []const u8, search: []const u8) ![]const u8 {
    const encoded = try ui.urlEncodeRef(page_arena.allocator(), name);
    const window = ui.RoutablePage.repoRefsRoute(identity, kind, encoded) orelse return error.RouteTooLong;
    const route = window.withSearch(search) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
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
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(aa, "a:{s}", .{url});
}

const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const tr = xit.tree;
const df = xit.diff;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const SubHeader = @import("SubHeader.zig");

const RefOrOid = ui.RoutablePage.RefOrOid;

// one entry in the directory currently being viewed.
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    // a file's contents split into lines (each without its trailing newline);
    // empty for directories and for binary or empty files.
    lines: []const []const u8 = &.{},
    // true when xit's line iterator flagged the file as binary, so the detail
    // pane shows a placeholder rather than its bytes.
    is_binary: bool = false,
};

// "owner/name", so the view can build /repo/owner/name/files/... links.
identity: []const u8,
// the resolved ref this listing is read at (the default branch when the route
// didn't name one), so the view's directory links stay pinned to it.
ref_or_oid: RefOrOid,
ref_or_oid_value: []const u8,
// the directory being viewed, relative to the repo root ("" at the root).
dir: []const u8,
entries: []const Entry,
// the "viewing <ref> <value>" banner shown above the listing.
sub_header: SubHeader,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    requested_ref_or_oid: ?RefOrOid,
    requested_value: []const u8,
    dir: []const u8,
) !Self {
    const aa = arena.allocator();

    // no filesystem (wasm) or nowhere to look: empty listing pinned to whatever
    // ref the route asked for. the wasm path never calls init anyway — it
    // rebuilds from the serialized snapshot.
    const io = session.io orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, dir);
    const repos_dir = session.repos_dir orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, dir);

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // open + read the committed file list with the arena's backing allocator
    // (transient; freed before init returns); the listing is built into the
    // page arena so it outlives them.
    const gpa = arena.child_allocator;
    var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, dir);
    defer repo.deinit(io, gpa);

    // resolve the requested ref (or the default branch) to the commit oid whose
    // tree we list. a ref the route named explicitly that doesn't resolve is a
    // bad url (NotFound -> 404); the default-branch path falls through to empty.
    const resolved = (try ui.ResolvedRefOrOid.init(&repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        return emptyResult(aa, identity, .branch, requested_value, dir);
    };

    // read the tree at that commit. building the read-only state mirrors what
    // repo.status does internally, but for an arbitrary commit rather than HEAD.
    var moment = repo.core.latestMoment() catch return emptyResult(aa, identity, resolved.ref_or_oid, resolved.value, dir);
    const state = rp.Repo(.xit, .{}).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var tree = tr.Tree(.xit, .{}).init(state, io, gpa, &resolved.oid) catch return emptyResult(aa, identity, resolved.ref_or_oid, resolved.value, dir);
    defer tree.deinit();

    // collect the immediate children of `dir`. each committed path is a full
    // file path; a child is a directory when more path follows its first
    // segment under `dir`.
    var children: std.StringArrayHashMapUnmanaged(bool) = .empty; // name -> is_dir
    defer children.deinit(gpa);
    const prefix_len = if (dir.len == 0) 0 else dir.len + 1; // skip "dir/"
    for (tree.entries.keys()) |path| {
        if (dir.len != 0) {
            if (!std.mem.startsWith(u8, path, dir) or path.len <= dir.len or path[dir.len] != '/') continue;
        }
        const rel = path[prefix_len..];
        const slash = std.mem.indexOfScalar(u8, rel, '/');
        const name = if (slash) |s| rel[0..s] else rel;
        const is_dir = slash != null;
        const gop = try children.getOrPut(gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = is_dir else if (is_dir) gop.value_ptr.* = true;
    }

    // trees hold no empty directories, so a non-root `dir` with no children
    // doesn't exist in this ref — a bad url (404).
    if (dir.len != 0 and children.count() == 0) return error.NotFound;

    // committed paths come out sorted (tree objects are written in sorted
    // order), so the deduped children are already in name order. just group
    // directories before files, keeping that order within each group, and dupe
    // into the page arena. each file's contents are read here (into the page
    // arena) so the detail pane can show them without another lookup.
    const entries = try aa.alloc(Entry, children.count());
    var i: usize = 0;
    for ([_]bool{ true, false }) |want_dir| {
        for (children.keys(), children.values()) |name, is_dir| {
            if (is_dir != want_dir) continue;
            var entry: Entry = .{ .name = try aa.dupe(u8, name), .is_dir = is_dir };
            if (!is_dir) {
                const path = try childDir(aa, dir, name);
                if (tree.entries.get(path)) |tree_entry| {
                    const content = readFileContent(state, io, gpa, aa, path, tree_entry) catch
                        FileContent{ .lines = &.{}, .is_binary = false };
                    entry.lines = content.lines;
                    entry.is_binary = content.is_binary;
                }
            }
            entries[i] = entry;
            i += 1;
        }
    }

    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_or_oid = resolved.ref_or_oid,
        .ref_or_oid_value = resolved.value,
        .dir = try aa.dupe(u8, dir),
        .entries = entries,
        .sub_header = try SubHeader.init(aa, resolved.ref_or_oid, resolved.value),
    };
}

const FileContent = struct {
    lines: []const []const u8,
    is_binary: bool,
};

// read a committed file's contents at `tree_entry` into `arena`-owned lines.
// xit's line iterator flags binary files (its source becomes `.binary`), in
// which case we report no lines and let the view show a placeholder.
fn readFileContent(
    state: rp.Repo(.xit, .{}).State(.read_only),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    tree_entry: tr.TreeEntry((rp.RepoOpts(.xit){}).hash),
) !FileContent {
    var line_iter = try df.LineIterator(.xit, .{}).initFromTree(state, io, gpa, path, tree_entry);
    defer line_iter.deinit();
    if (line_iter.source == .binary) return .{ .lines = &.{}, .is_binary = true };

    // init reads through the file to validate it (and buffer it in memory),
    // leaving the cursor at the end, so rewind before reading the lines out.
    try line_iter.reset();

    var lines: std.ArrayList([]const u8) = .empty;
    while (try line_iter.next()) |line| {
        defer line_iter.free(line);
        try lines.append(arena, try arena.dupe(u8, line));
    }
    return .{ .lines = try lines.toOwnedSlice(arena), .is_binary = false };
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
fn emptyResult(aa: std.mem.Allocator, identity: []const u8, ref_or_oid: RefOrOid, ref_or_oid_value: []const u8, dir: []const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = try aa.dupe(u8, ref_or_oid_value),
        .dir = try aa.dupe(u8, dir),
        .entries = &.{},
        .sub_header = try SubHeader.init(aa, ref_or_oid, ref_or_oid_value),
    };
}

pub const View = struct {
    // a vertical stack: the "viewing <ref>" banner on top, then a horizontal
    // split with the file/directory list on the left and a detail pane on the
    // right showing the selected file's contents. each subdirectory row is an
    // `a:` link to its /repo/.../files/<path> route, so following it (click or
    // Enter) navigates through the host's link handling; a ".." row at the top
    // links to the parent. file rows aren't links — selecting one shows its
    // contents in the detail pane in-page, like the commits view's diff pane.
    box: wgt.Box(ui.Widget), // vert: [sub_header_index] = banner, [content_index] = split
    data: *const Self,
    session: *ui.Session,
    // the list row whose contents the detail pane currently shows.
    shown_index: ?usize,

    const sub_header_index: usize = 0;
    const content_index: usize = 1;
    // indices within the content box (the horizontal split).
    const list_index: usize = 0;
    const detail_index: usize = 1;
    const list_max_width: usize = 40;
    const detail_min_width: usize = 40;

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

        // the directory listing on the left (one focusable row each).
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer list_box.deinit(allocator);

                // labels and link kinds are borrowed by the rows, so they live in
                // the page arena (as long as this page's widget tree).
                const aa = session.page_arena.allocator();
                if (data.dir.len != 0) {
                    try addRow(allocator, &list_box, "..", try dirLink(session.page_arena, data, parentDir(data.dir)));
                }
                for (data.entries) |entry| {
                    const label = if (entry.is_dir) try std.fmt.allocPrint(aa, "{s}/", .{entry.name}) else entry.name;
                    const link = if (entry.is_dir) try dirLink(session.page_arena, data, try childDir(aa, data.dir, entry.name)) else "";
                    try addRow(allocator, &list_box, label, link);
                }
                // default the selection to the first row, but prefer a README in
                // this directory so its contents greet the visitor in the detail
                // pane. a non-root directory has a leading ".." row, so the entry
                // index is offset by one there.
                if (list_box.children.count() > 0) {
                    const base: usize = if (data.dir.len != 0) 1 else 0;
                    const sel = if (readmeIndex(data.entries)) |i| i + base else 0;
                    list_box.getFocus().child_id = list_box.children.keys()[sel];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }

        // the detail pane on the right — a frame around a scroll of the contents.
        {
            var detail_outer = blk: {
                var detail_scroll = blk2: {
                    var detail_inner = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                    errdefer detail_inner.deinit(allocator);
                    break :blk2 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = detail_inner }, .{ .direction = .both, .web_native = !session.is_terminal });
                };
                errdefer detail_scroll.deinit(allocator);
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                try frame.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = null });
                break :blk frame;
            };
            errdefer detail_outer.deinit(allocator);
            try box.children.put(allocator, detail_outer.getFocus().id, .{ .widget = .{ .box = detail_outer }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[list_index];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });

        // focus lives in the split; the banner isn't focusable.
        outer.getFocus().child_id = outer.children.keys()[content_index];
        return .{ .box = outer, .data = data, .session = session, .shown_index = null };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    // the selected file's contents as a single focusable multi-line text box.
    // its hidden border reserves the space the double border occupies when
    // focused, so focusing doesn't shift layout. `text` lives in the page arena.
    fn addContentBox(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8) !void {
        _ = self;
        var tb = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
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

    fn detailOuter(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[detail_index].widget.box;
    }

    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.detailOuter().children.values()[0].widget.scroll;
    }

    fn detailInner(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailScroll().child.box;
    }

    fn detailActive(self: *View) bool {
        const content = self.contentBox();
        const cid = content.getFocus().child_id orelse return false;
        return content.children.getIndex(cid) == detail_index;
    }

    // the selected list row's index, or null when nothing is focused.
    fn selectedRowIndex(self: *View) ?usize {
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        return lb.children.getIndex(cid);
    }

    // the entry the selected row points at, or null for the ".." row (which
    // isn't an entry). directory rows return their entry too, though they carry
    // no contents.
    fn selectedEntry(self: *View) ?Entry {
        const idx = self.selectedRowIndex() orelse return null;
        const base: usize = if (self.data.dir.len != 0) 1 else 0; // skip the ".." row
        if (idx < base) return null;
        const e = idx - base;
        if (e >= self.data.entries.len) return null;
        return self.data.entries[e];
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // swap the detail pane to the selected entry when the selection changes.
        try self.refreshDetail(allocator);

        // the selected list row shows a border (the focused TextBox upgrades it
        // to a double border itself); the rest stay borderless.
        const lb = self.listBox();
        for (lb.children.keys(), lb.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        // the focused content box shows a single border (the focused TextBox
        // upgrades it to a double border itself, so it stays single when focus is
        // on the list); the rest keep their space-reserving hidden border.
        const inner = self.detailInner();
        for (inner.children.keys(), inner.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (inner.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        // cap the list at list_max_width only while the detail pane fits beside
        // it. the box drops the detail pane when the width can't hold both
        // minimums, so when it's that narrow we lift the cap and let the list
        // fill the whole width.
        const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
        self.contentBox().children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        try self.box.build(allocator, constraint, root_focus);

        // if the detail pane is selected but focus is still elsewhere in this
        // view, the pane was too narrow to lay out when focus crossed over. it's
        // laid out now, so focus its content box.
        if (self.detailActive() and inner.children.count() > 0) {
            if (root_focus.grandchild_id) |g| {
                const in_view = self.box.getFocus().children.contains(g);
                const in_detail = inner.children.contains(g);
                if (in_view and !in_detail)
                    try root_focus.setFocus(inner.getFocus().child_id orelse inner.children.keys()[0]);
            }
        }
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const cur = self.selectedRowIndex();
        if (std.meta.eql(cur, self.shown_index)) return;
        try self.populateDetail(allocator);
        self.shown_index = cur;
    }

    fn populateDetail(self: *View, allocator: std.mem.Allocator) !void {
        const inner = self.detailInner();

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        // only files have contents to show; directories and the ".." row leave
        // the pane empty.
        if (self.selectedEntry()) |entry| {
            if (!entry.is_dir) {
                if (entry.is_binary) {
                    try self.addContentBox(allocator, inner, "(binary file)");
                } else {
                    const text = try std.mem.join(self.session.page_arena.allocator(), "\n", entry.lines);
                    try self.addContentBox(allocator, inner, text);
                }
            }
        }

        // reset the scroll to the top for the newly-shown file: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll();
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.detailActive()) {
            try self.detailInput(key, root_focus);
        } else {
            try self.listInput(key, root_focus);
        }
    }

    fn listInput(self: *View, key: inp.Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection; page up/down jump a
        // fixed amount. right/Enter cross into the detail pane. Enter/clicks on a
        // directory (or "..") row are turned into navigation by the host
        // (crossPageLink) before reaching here.
        switch (key) {
            .enter, .arrow_right => try self.focusDetail(root_focus),
            .arrow_down => try self.moveSelection(root_focus, 1),
            .arrow_up => try self.moveSelection(root_focus, -1),
            .page_down => try self.moveSelection(root_focus, 10),
            .page_up => try self.moveSelection(root_focus, -10),
            .end => try self.moveSelection(root_focus, @intCast(self.listBox().children.count())),
            .home => try self.moveSelection(root_focus, -@as(isize, @intCast(self.listBox().children.count()))),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| try self.moveSelection(root_focus, if (dir == .up) -1 else 1),
                else => {},
            },
            else => {},
        }
    }

    fn detailInput(self: *View, key: inp.Key, root_focus: *Focus) !void {
        const sc = self.detailScroll();
        // on the web each Scroll is a native scrollable element, so vertical
        // scrolling is handled by the browser; the terminal scrolls the content
        // by moving the offset. left scrolls horizontally, then returns to the
        // list once flush left.
        switch (key) {
            .arrow_left => {
                if (sc.x > 0) {
                    sc.x -= 1;
                    self.clampDetailScroll();
                } else try self.focusList(root_focus);
            },
            .arrow_right => {
                sc.x += 1;
                self.clampDetailScroll();
            },
            .arrow_up => if (self.session.is_terminal) {
                sc.y -= 1;
                self.clampDetailScroll();
            },
            .arrow_down => if (self.session.is_terminal) {
                sc.y += 1;
                self.clampDetailScroll();
            },
            .page_up => if (self.session.is_terminal) {
                sc.y -= 10;
                self.clampDetailScroll();
            },
            .page_down => if (self.session.is_terminal) {
                sc.y += 10;
                self.clampDetailScroll();
            },
            .home => if (self.session.is_terminal) {
                sc.y = 0;
                self.clampDetailScroll();
            },
            .end => if (self.session.is_terminal) {
                sc.y = std.math.maxInt(isize);
                self.clampDetailScroll();
            },
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| if (self.session.is_terminal) {
                    sc.y += if (dir == .up) -5 else 5;
                    self.clampDetailScroll();
                },
                else => {},
            },
            else => {},
        }
    }

    // keep the detail scroll within its content, using the last build's grids.
    // the scroll bar's reserved column/row isn't part of the content viewport,
    // so exclude it or the last column/row stays unreachable.
    fn clampDetailScroll(self: *View) void {
        const sc = self.detailScroll();
        const vp = sc.grid orelse return;
        const content = sc.child.box.grid orelse return;
        const view_w = vp.size.width - sc.bar_w;
        const view_h = vp.size.height - sc.bar_h;
        const max_y: isize = if (content.size.height > view_h) @intCast(content.size.height - view_h) else 0;
        const max_x: isize = if (content.size.width > view_w) @intCast(content.size.width - view_w) else 0;
        sc.y = std.math.clamp(sc.y, 0, max_y);
        sc.x = std.math.clamp(sc.x, 0, max_x);
    }

    // enter the detail pane by focusing its content box. the host arrives here on
    // right-arrow or Enter from the list. an empty pane (a directory or ".." row
    // is selected) can't be entered.
    fn focusDetail(self: *View, root_focus: *Focus) !void {
        const inner = self.detailInner();
        if (inner.children.count() == 0) return;
        const target = inner.getFocus().child_id orelse inner.children.keys()[0];
        try root_focus.setFocus(target);
        if (root_focus.grandchild_id == target) return;
        // the detail pane wasn't laid out last build (too narrow to show beside
        // the list), so its content isn't in the focus tree yet. select the pane
        // at the box level, and the content will be focused after the next build.
        self.contentBox().getFocus().child_id = self.detailOuter().getFocus().id;
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

    // for the parent's "scroll up at the top jumps to the header" check. inside
    // the detail pane up-arrow stays in the pane (scrolling); when the list holds
    // focus, report its selection directly so up-arrow at the top row ascends.
    pub fn getSelectedIndex(self: *View) ?usize {
        if (self.detailActive()) return 1;
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return null;
        return lb.children.getIndex(cid);
    }
};

// the index of the "README"/"README.md" file entry (case-insensitive), or null
// if none. used to pick the default selection at the repo root.
fn readmeIndex(entries: []const Entry) ?usize {
    for (entries, 0..) |entry, i| {
        if (entry.is_dir) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, "README") or std.ascii.eqlIgnoreCase(entry.name, "README.md"))
            return i;
    }
    return null;
}

// the "a:" link for the files route at `dir`, pinned to the listing's ref.
fn dirLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, dir: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoFilesRoute(data.identity, data.ref_or_oid, data.ref_or_oid_value, dir) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// `dir`/`name`, or just `name` at the root.
fn childDir(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return if (dir.len == 0) name else std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

// `dir` with its last segment removed ("" when `dir` has a single segment).
fn parentDir(dir: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return "";
    return dir[0..slash];
}

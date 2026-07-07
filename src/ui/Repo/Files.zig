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
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

const SubHeader = @import("SubHeader.zig");

// how many lines of a file's content one window shows before a "next" link.
const file_page = 2000;

// the most directory entries (files + dirs) we read from a tree and display.
// each file's content is also loaded (windowed), so an unbounded directory could
// add up to a lot of memory; entries past this limit are ignored.
//
// TODO: this caps what we keep, but `tr.Tree.init` still flattens the entire
// repo tree (every path) into memory before we ever apply the cap. read the
// directory level-by-level instead, using `obj.Object` to load one tree object
// at a time: initCommit -> root tree, then descend each `dir` segment, reading
// only the immediate entries of the target tree (and applying max_entries
// there). that bounds the work to O(depth) tree objects rather than the whole
// repo. it's doable entirely in haxy (no xit change) — `obj.Object(...).init`
// on a tree oid already returns just that tree's immediate children.
const max_entries = 100;

// one entry in the directory currently being viewed.
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    // a file's content window split into lines (each without its trailing
    // newline); empty for directories and for binary or empty files.
    lines: []const []const u8 = &.{},
    // true when xit's line iterator flagged the file as binary, so the detail
    // pane shows a placeholder rather than its bytes.
    is_binary: bool = false,
    // the line index this window starts at (0 = the first window). non-zero only
    // for the route's selected file, paginated by the url's `after`.
    window_start: usize = 0,
    // whether more lines exist after this window.
    has_more: bool = false,
};

// "owner/name", so the view can build /repo/owner/name/files/... links.
identity: []const u8,
// the resolved ref this listing is read at (the default branch when the route
// didn't name one), so the view's directory links stay pinned to it.
ref_or_oid: ui.RoutablePage.RefOrOid,
ref_or_oid_value: []const u8,
// the directory being viewed, relative to the repo root ("" at the root).
dir: []const u8,
// a file within `dir` to start selected (so its contents show and the url
// carries it), or null to fall back to a README / the first row. set when the
// route's path named a file rather than a directory.
selected_file: ?[]const u8 = null,
entries: []const Entry,
// the "viewing <ref> <value>" banner shown above the listing.
sub_header: SubHeader,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    path: []const u8,
    // the line offset the selected file's content window starts at (0 = first).
    after: usize,
) !Self {
    const aa = arena.allocator();

    // no filesystem (wasm) or nowhere to look: empty listing pinned to whatever
    // ref the route asked for. the wasm path never calls init anyway — it
    // rebuilds from the serialized snapshot.
    const io = session.io orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, path);
    const repos_dir = session.repos_dir orelse return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, path);

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // open + read the committed file list with the arena's backing allocator
    // (transient; freed before init returns); the listing is built into the
    // page arena so it outlives them. AnyRepo opens both sha1 and sha256 repos.
    const gpa = arena.child_allocator;
    var any_repo = rp.AnyRepo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return emptyResult(aa, identity, requested_ref_or_oid orelse .branch, requested_value, path);
    defer any_repo.deinit(io, gpa);

    return switch (any_repo) {
        inline else => |*repo| listing(repo.self_repo_opts, arena, repo, io, gpa, identity, requested_ref_or_oid, requested_value, path, after),
    };
}

// build the listing for an opened repo. generic over the repo's hash kind so
// the tree/diff types it threads through match the repo's opts.
fn listing(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    identity: []const u8,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    path: []const u8,
    after: usize,
) !Self {
    const aa = arena.allocator();

    // resolve the requested ref (or the default branch) to the commit oid whose
    // tree we list. a ref the route named explicitly that doesn't resolve is a
    // bad url (NotFound -> 404); the default-branch path falls through to empty.
    const resolved = (try ui.ResolvedRefOrOid(repo_opts).init(repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        return emptyResult(aa, identity, .branch, requested_value, path);
    };

    // read the tree at that commit. building the read-only state mirrors what
    // repo.status does internally, but for an arbitrary commit rather than HEAD.
    var moment = repo.core.latestMoment() catch return emptyResult(aa, identity, resolved.ref_or_oid, resolved.value, path);
    const state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var tree = tr.Tree(.xit, repo_opts).init(state, io, gpa, &resolved.oid) catch return emptyResult(aa, identity, resolved.ref_or_oid, resolved.value, path);
    defer tree.deinit();

    // `path` names a file when it's an exact tree entry: list its parent
    // directory and start that file selected. otherwise `path` is the directory.
    var dir = path;
    var selected_file: ?[]const u8 = null;
    if (path.len != 0 and tree.entries.get(path) != null) {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        selected_file = try aa.dupe(u8, if (slash) |s| path[s + 1 ..] else path);
        dir = if (slash) |s| path[0..s] else "";
    }

    // collect the immediate children of `dir`. each committed path is a full
    // file path; a child is a directory when more path follows its first
    // segment under `dir`.
    var children: std.StringArrayHashMapUnmanaged(bool) = .empty; // name -> is_dir
    defer children.deinit(gpa);
    const prefix_len = if (dir.len == 0) 0 else dir.len + 1; // skip "dir/"
    for (tree.entries.keys()) |entry_path| {
        if (dir.len != 0) {
            if (!std.mem.startsWith(u8, entry_path, dir) or entry_path.len <= dir.len or entry_path[dir.len] != '/') continue;
        }
        const rel = entry_path[prefix_len..];
        const slash = std.mem.indexOfScalar(u8, rel, '/');
        const name = if (slash) |s| rel[0..s] else rel;
        const is_dir = slash != null;
        // stop taking new entries once we hit the cap; the rest are ignored.
        if (children.count() >= max_entries and !children.contains(name)) continue;
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
                const file_path = try childDir(aa, dir, name);
                if (tree.entries.get(file_path)) |tree_entry| {
                    // only the route's selected file paginates; the rest show
                    // their first window (for the in-page detail when selected).
                    const is_selected = if (selected_file) |sf| std.mem.eql(u8, sf, name) else false;
                    const window_start = if (is_selected) after else 0;
                    const content = readFileContent(repo_opts, state, io, gpa, aa, file_path, tree_entry, window_start) catch
                        FileContent{ .lines = &.{} };
                    entry.lines = content.lines;
                    entry.is_binary = content.is_binary;
                    entry.window_start = window_start;
                    entry.has_more = content.has_more;
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
        .selected_file = selected_file,
        .entries = entries,
        .sub_header = try SubHeader.init(aa, resolved.ref_or_oid, resolved.value),
    };
}

const FileContent = struct {
    lines: []const []const u8,
    is_binary: bool = false,
    has_more: bool = false,
};

// read the window [start, start+file_page) of a committed file's contents at
// `tree_entry` into `arena`-owned lines, flagging whether more follow. xit's
// line iterator flags binary files (its source becomes `.binary`), in which case
// we report no lines and let the view show a placeholder.
fn readFileContent(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    tree_entry: tr.TreeEntry(repo_opts.hash),
    start: usize,
) !FileContent {
    var line_iter = try df.LineIterator(.xit, repo_opts).initFromTree(state, io, gpa, path, tree_entry);
    defer line_iter.deinit();
    if (line_iter.source == .binary) return .{ .lines = &.{}, .is_binary = true };

    // init reads through the file to validate it (and buffer it in memory), so
    // the line count is known and a window can be sliced out of the buffer.
    const total = line_iter.count();
    const end = @min(start + file_page, total);

    var lines: std.ArrayList([]const u8) = .empty;
    var i = start;
    while (i < end) : (i += 1) {
        const line = try line_iter.get(i);
        defer line_iter.free(line);
        try lines.append(arena, try arena.dupe(u8, line));
    }
    return .{
        .lines = try lines.toOwnedSlice(arena),
        .has_more = end < total,
    };
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
fn emptyResult(aa: std.mem.Allocator, identity: []const u8, ref_or_oid: ui.RoutablePage.RefOrOid, ref_or_oid_value: []const u8, dir: []const u8) !Self {
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
    // right showing the selected file's contents.
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
    // indices within the detail pane frame (nav box above the content scroll).
    const detail_nav_index: usize = 0;
    const detail_scroll_index: usize = 1;
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
                    const path = try childDir(aa, data.dir, entry.name);
                    const label = if (entry.is_dir) try std.fmt.allocPrint(aa, "{s}/", .{entry.name}) else entry.name;
                    const link = if (entry.is_dir)
                        try dirLink(session.page_arena, data, path)
                    else
                        try fileLink(session.page_arena, data, path);
                    try addRow(allocator, &list_box, label, link);
                }
                // select the file the route named, else prefer a README so its
                // contents greet the visitor in the detail pane, else the first
                // row. a non-root directory has a leading ".." row, so the entry
                // index is offset by one there.
                if (list_box.children.count() > 0) {
                    const base: usize = if (data.dir.len != 0) 1 else 0;
                    const entry_idx = selectedFileIndex(data) orelse readmeIndex(data.entries);
                    const sel = if (entry_idx) |i| i + base else 0;
                    list_box.getFocus().child_id = list_box.children.keys()[sel];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }

        // the detail pane on the right — a "next" nav box above a scroll of the
        // selected file's content window. both are repopulated per selection by
        // populateDetail.
        {
            var detail_outer = blk: {
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer frame.deinit(allocator);

                {
                    var nav_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
                    errdefer nav_box.deinit(allocator);
                    try frame.children.put(allocator, nav_box.getFocus().id, .{ .widget = .{ .box = nav_box }, .rect = null, .min_size = null });
                }
                {
                    // the content scroll wrapped in a bordered box; build sets the
                    // border single normally and double when the content is focused
                    // (the content box itself is borderless).
                    var scroll_frame = blk2: {
                        var detail_scroll = blk3: {
                            var detail_inner = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                            errdefer detail_inner.deinit(allocator);
                            break :blk3 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = detail_inner }, .{ .direction = .both, .web_native = !session.is_terminal, .fill = true });
                        };
                        errdefer detail_scroll.deinit(allocator);
                        var sf = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .single, .rounded_corners = true, .direction = .vert });
                        errdefer sf.deinit(allocator);
                        // the wrapper's selected child is its scroll, so the focus
                        // chain reaches the content box (populateDetail points the
                        // scroll's inner box at it).
                        sf.getFocus().child_id = detail_scroll.getFocus().id;
                        try sf.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = null });
                        break :blk2 sf;
                    };
                    errdefer scroll_frame.deinit(allocator);
                    // entering the detail pane lands on the content scroll (focus
                    // recovery descends the frame's selected child). the nav links
                    // above are reached by scrolling to the top, then up.
                    frame.getFocus().child_id = scroll_frame.getFocus().id;
                    try frame.children.put(allocator, scroll_frame.getFocus().id, .{ .widget = .{ .box = scroll_frame }, .rect = null, .min_size = null });
                }
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
    // it's borderless — the border lives on the surrounding scroll frame, which
    // doubles when this content is focused. `text` lives in the page arena.
    fn addContentBox(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8) !void {
        _ = self;
        var tb = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = null, .wrap_kind = .none });
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

    fn navBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailOuter().children.values()[detail_nav_index].widget.box;
    }

    // the bordered box wrapping the content scroll (border toggles with focus).
    fn detailScrollFrame(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailOuter().children.values()[detail_scroll_index].widget.box;
    }

    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.detailScrollFrame().children.values()[0].widget.scroll;
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

        // mirror the selected file into the url so it updates as the selection
        // moves, but only while focus is inside this view (so landing on the tab
        // keeps the page's base route). a file selection carries the file path and
        // its content window offset; a directory / ".." row (or no selection)
        // stays at the directory with no offset. the path is joined in a stack
        // buffer since build runs every frame on the web.
        if (root_focus.grandchild_id) |g| {
            if (self.box.getFocus().children.contains(g)) {
                var buf: [ui.RoutablePage.repo_route_max_len]u8 = undefined;
                var sel_path = self.data.dir;
                var sel_after: usize = 0;
                if (self.selectedEntry()) |entry| {
                    if (!entry.is_dir) {
                        sel_path = if (self.data.dir.len == 0)
                            entry.name
                        else
                            std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.data.dir, entry.name }) catch self.data.dir;
                        sel_after = entry.window_start;
                    }
                }
                if (ui.RoutablePage.repoFilesRoute(self.data.identity, self.data.ref_or_oid, self.data.ref_or_oid_value, sel_path, sel_after)) |route|
                    self.session.data.current_page = route;
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

        // the content scroll's border is single normally and double when the
        // content is focused (the content box itself is borderless).
        const has_content = self.detailInner().children.count() > 0;
        const content_focused = if (root_focus.grandchild_id) |g| self.detailInner().children.contains(g) else false;
        self.detailScrollFrame().options.border_style = if (!has_content) null else if (content_focused) .double else .single;

        // same for the "next" link above the content.
        const nav_box = self.navBox();
        for (nav_box.children.keys(), nav_box.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (nav_box.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }

        // cap the list at list_max_width only while the detail pane fits beside
        // it. the box drops the detail pane when the width can't hold both
        // minimums, so when it's that narrow we lift the cap and let the list
        // fill the whole width.
        const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
        self.contentBox().children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        // stretch the detail pane and its bordered scroll frame across the rest
        // of the width so the pane fills the area rather than shrinking to its
        // content, like the refs view's columns. the content scroll inside keeps
        // its natural width: forcing it to the full inner width would make it one
        // column too wide whenever the vertical scrollbar appears, leaving a
        // phantom horizontal scroll. (height fills via the scroll clipping to the
        // viewport.)
        if (constraint.max_size.width) |w| {
            const detail_w = if (both_panes_fit) w - list_max_width else w;
            self.contentBox().children.values()[detail_index].min_size = .{ .width = detail_w, .height = null };
            self.detailOuter().children.values()[detail_scroll_index].min_size = .{ .width = detail_w, .height = null };
        } else {
            self.contentBox().children.values()[detail_index].min_size = .{ .width = detail_min_width, .height = null };
            self.detailOuter().children.values()[detail_scroll_index].min_size = null;
        }

        // crossing panes only re-selects the content box's child (focusList /
        // focusDetail); when the window is too narrow to show both, the pane that
        // was holding focus is dropped here. the framework recovers focus after
        // the top-level build by re-deriving it down the selected-child chain, so
        // there's nothing to fix up afterward.
        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const cur = self.selectedRowIndex();
        if (std.meta.eql(cur, self.shown_index)) return;
        try self.populateDetail(allocator);
        self.shown_index = cur;
    }

    fn populateDetail(self: *View, allocator: std.mem.Allocator) !void {
        const nav_box = self.navBox();
        const inner = self.detailInner();

        for (nav_box.children.values()) |*child| child.widget.deinit(allocator);
        nav_box.children.clearAndFree(allocator);
        nav_box.getFocus().child_id = null;
        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        // only files have contents to show; directories and the ".." row leave
        // the pane empty.
        if (self.selectedEntry()) |entry| {
            if (!entry.is_dir) {
                // the "next" window link sits above the scroll, so it stays put
                // while the content scrolls.
                if (entry.has_more) try self.addNavLink(allocator, nav_box, "next lines →", entry, entry.window_start + file_page);
                if (entry.is_binary) {
                    try self.addContentBox(allocator, inner, "(binary file)");
                } else {
                    const text = try numberedContent(self.session.page_arena.allocator(), entry.lines, entry.window_start);
                    try self.addContentBox(allocator, inner, text);
                }
            }
        }
        // point each box at its first child so focus can descend into it.
        if (nav_box.children.count() > 0) nav_box.getFocus().child_id = nav_box.children.keys()[0];
        if (inner.children.count() > 0) inner.getFocus().child_id = inner.children.keys()[0];

        // reset the scroll to the top for the newly-shown file: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll();
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    // a focusable "next" link above the content. it's an `a:` link to the
    // selected file at `target_after`, so activating it (the host follows the
    // link) reloads the page on the next window.
    fn addNavLink(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, entry: Entry, target_after: usize) !void {
        const page_arena = self.session.page_arena;
        const path = try childDir(page_arena.allocator(), self.data.dir, entry.name);
        const route = ui.RoutablePage.repoFilesRoute(self.data.identity, self.data.ref_or_oid, self.data.ref_or_oid_value, path, target_after) orelse return error.RouteTooLong;
        const link = try std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.urlAlloc(page_arena)});
        var tb = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
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
        // up/down (and the scroll wheel) move the selection; page up/down jump a
        // fixed amount. right/Enter cross into the detail pane. Enter/clicks on a
        // directory (or "..") row are turned into navigation by the host
        // (crossPageLink) before reaching here.
        if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
            return;
        }
        switch (key) {
            .enter, .arrow_right => try self.focusDetail(root_focus),
            else => {},
        }
    }

    // whether focus is on the content box (vs. a "previous"/"next" nav link).
    fn focusOnContent(self: *View, root_focus: *Focus) bool {
        const g = root_focus.grandchild_id orelse return false;
        return self.detailInner().children.contains(g);
    }

    fn detailInput(self: *View, key: Key, root_focus: *Focus) !void {
        const sc = self.detailScroll();
        const on_content = self.focusOnContent(root_focus);
        // the "next" link sits above the content scroll. on the link, left returns
        // to the file list and down drops into the content. in the content, the
        // terminal scrolls by offset and reaching the top then pressing up crosses
        // back up to the link; on the web vertical scrolling is the browser's job
        // so up just crosses to the link.
        switch (key) {
            .arrow_left => {
                if (on_content) {
                    if (sc.x > 0) {
                        sc.x -= 1;
                        ui.clampScroll(self.detailScroll());
                    } else try self.focusList(root_focus);
                } else if (!self.moveNav(root_focus, -1)) {
                    try self.focusList(root_focus);
                }
            },
            .arrow_right => {
                if (on_content) {
                    sc.x += 1;
                    ui.clampScroll(self.detailScroll());
                } else _ = self.moveNav(root_focus, 1);
            },
            .arrow_up => {
                if (on_content) {
                    if (self.session.is_terminal and sc.y > 0) {
                        sc.y -= 1;
                        ui.clampScroll(self.detailScroll());
                    } else self.focusNav(root_focus); // cross up to the links
                }
            },
            .arrow_down => {
                if (on_content) {
                    if (self.session.is_terminal) {
                        sc.y += 1;
                        ui.clampScroll(self.detailScroll());
                    }
                } else self.focusContent(root_focus); // links -> content
            },
            .page_up => if (on_content and self.session.is_terminal) {
                sc.y -= 10;
                ui.clampScroll(self.detailScroll());
            },
            .page_down => if (on_content and self.session.is_terminal) {
                sc.y += 10;
                ui.clampScroll(self.detailScroll());
            },
            .home => if (on_content and self.session.is_terminal) {
                sc.y = 0;
                ui.clampScroll(self.detailScroll());
            },
            .end => if (on_content and self.session.is_terminal) {
                sc.y = std.math.maxInt(isize);
                ui.clampScroll(self.detailScroll());
            },
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| if (on_content and self.session.is_terminal) {
                    sc.y += if (dir == .up) -5 else 5;
                    ui.clampScroll(self.detailScroll());
                },
                else => {},
            },
            else => {},
        }
    }

    // focus the first (left-most) nav link; a no-op when there are none, leaving
    // focus on the content.
    fn focusNav(self: *View, root_focus: *Focus) void {
        const nav_box = self.navBox();
        if (nav_box.children.count() == 0) return;
        root_focus.setFocus(nav_box.children.keys()[0]);
    }

    fn focusContent(self: *View, root_focus: *Focus) void {
        const inner = self.detailInner();
        const id = inner.getFocus().child_id orelse (if (inner.children.count() > 0) inner.children.keys()[0] else return);
        root_focus.setFocus(id);
    }

    // move focus `delta` rows within the nav box; returns false (without moving)
    // when that would step off either end.
    fn moveNav(self: *View, root_focus: *Focus, delta: isize) bool {
        const nav_box = self.navBox();
        const keys = nav_box.children.keys();
        const cur_id = nav_box.getFocus().child_id orelse return false;
        const cur: isize = @intCast(nav_box.children.getIndex(cur_id) orelse return false);
        const target = cur + delta;
        if (target < 0 or target >= @as(isize, @intCast(keys.len))) return false;
        root_focus.setFocus(keys[@intCast(target)]);
        return true;
    }

    // enter the detail pane, landing on the "next" link when there is one (so
    // right-arrow reaches it), else on the content. a directory or ".." row has
    // neither, so there's nothing to enter. selecting the frame's child (then
    // focusing the frame) also handles the too-narrow case where the pane isn't
    // laid out yet — focus lands inside it after the next build.
    fn focusDetail(self: *View, root_focus: *Focus) !void {
        const frame = self.detailOuter();
        if (self.navBox().children.count() > 0) {
            frame.getFocus().child_id = self.navBox().getFocus().id;
        } else if (self.detailInner().children.count() > 0) {
            frame.getFocus().child_id = self.detailScrollFrame().getFocus().id;
        } else return;
        root_focus.setFocus(frame.getFocus().id);
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

// join `lines` into one string, each prefixed with its 1-based file line number
// (right-aligned in a column wide enough for the last number, then a space),
// like the diffs view. `start` is the window's 0-based first line, so numbers
// continue across paginated windows.
fn numberedContent(arena: std.mem.Allocator, lines: []const []const u8, start: usize) ![]const u8 {
    if (lines.len == 0) return "";
    const width = std.fmt.count("{d}", .{start + lines.len});
    const indent = try arena.alloc(u8, width);
    @memset(indent, ' ');

    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, i| {
        if (i != 0) try out.append(arena, '\n');
        const num_str = try std.fmt.allocPrint(arena, "{d}", .{start + i + 1});
        try out.appendSlice(arena, indent[0 .. width - num_str.len]);
        try out.appendSlice(arena, num_str);
        try out.append(arena, ' ');
        try out.appendSlice(arena, line);
    }
    return out.toOwnedSlice(arena);
}

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

// the index of the entry the route named (data.selected_file), or null if none.
fn selectedFileIndex(data: *const Self) ?usize {
    const name = data.selected_file orelse return null;
    for (data.entries, 0..) |entry, i| {
        if (!entry.is_dir and std.mem.eql(u8, entry.name, name)) return i;
    }
    return null;
}

// an "a:" link to the files route at `path`, pinned to the listing's ref, so
// following it navigates to that directory's listing.
fn dirLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, path: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoFilesRoute(data.identity, data.ref_or_oid, data.ref_or_oid_value, path, 0) orelse return error.RouteTooLong;
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.urlAlloc(page_arena)});
}

// an "ai:" link to the file's route: crossPageLink ignores it, so a wasm click
// selects the row in place and shows its contents in the detail pane.
fn fileLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, path: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoFilesRoute(data.identity, data.ref_or_oid, data.ref_or_oid_value, path, 0) orelse return error.RouteTooLong;
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{try route.urlAlloc(page_arena)});
}

// `dir`/`name`, or just `name` at the root.
pub fn childDir(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return if (dir.len == 0) name else std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

// `dir` with its last segment removed ("" when `dir` has a single segment).
fn parentDir(dir: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return "";
    return dir[0..slash];
}

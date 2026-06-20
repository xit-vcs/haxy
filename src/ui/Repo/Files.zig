const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const tr = xit.tree;
const rf = xit.ref;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const RefKindOrOid = ui.RoutablePage.RefKindOrOid;
// the hex-oid length for the default repo options the on-disk repos use.
const hex_len = hash.hexLen((rp.RepoOpts(.xit){}).hash);

// one entry in the directory currently being viewed.
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

// "owner/name", so the view can build /repo/owner/name/files/... links.
identity: []const u8,
// the resolved ref this listing is read at (the default branch when the route
// didn't name one), so the view's directory links stay pinned to it.
ref_kind: RefKindOrOid,
ref_value: []const u8,
// the directory being viewed, relative to the repo root ("" at the root).
dir: []const u8,
entries: []const Entry,

const Self = @This();

pub fn init(
    arena: *std.heap.ArenaAllocator,
    session: *ui.Session,
    event_id: *const [evt.event_id_size]u8,
    identity: []const u8,
    req_kind: ?RefKindOrOid,
    req_value: []const u8,
    dir: []const u8,
) !Self {
    const aa = arena.allocator();

    // no filesystem (wasm) or nowhere to look: empty listing pinned to whatever
    // ref the route asked for. the wasm path never calls init anyway — it
    // rebuilds from the serialized snapshot.
    const io = session.io orelse return emptyResult(aa, identity, req_kind orelse .branch, req_value, dir);
    const repos_dir = session.repos_dir orelse return emptyResult(aa, identity, req_kind orelse .branch, req_value, dir);

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // open + read the committed file list with the arena's backing allocator
    // (transient; freed before init returns); the listing is built into the
    // page arena so it outlives them.
    const gpa = arena.child_allocator;
    var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return emptyResult(aa, identity, req_kind orelse .branch, req_value, dir);
    defer repo.deinit(io, gpa);

    // resolve the effective ref: the one named in the route, else HEAD's branch.
    // ref_value is duped immediately so it outlives the stack buffer head() fills.
    var eff_kind: RefKindOrOid = req_kind orelse .branch;
    var eff_value: []const u8 = req_value;
    if (req_kind == null) {
        var head_buf: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
        if (repo.head(io, &head_buf)) |head| switch (head) {
            .ref => |ref| {
                eff_kind = .branch;
                eff_value = try aa.dupe(u8, ref.name);
            },
            .oid => |oid| {
                eff_kind = .oid;
                eff_value = try aa.dupe(u8, oid);
            },
        } else |_| {}
    }

    // resolve the ref to the commit oid whose tree we list. a ref the route
    // named explicitly that doesn't resolve is a bad url (NotFound -> 404); the
    // default-branch path instead falls through to an empty listing below.
    const explicit = req_kind != null;
    var oid: [hex_len]u8 = undefined;
    switch (eff_kind) {
        .oid => {
            if (eff_value.len != hex_len) return unresolved(aa, identity, explicit, eff_kind, eff_value, dir);
            @memcpy(&oid, eff_value);
        },
        .branch, .tag => {
            const ref_kind: rf.RefKind = if (eff_kind == .branch) .head else .tag;
            oid = (repo.readRef(io, .{ .kind = ref_kind, .name = eff_value }) catch null) orelse
                return unresolved(aa, identity, explicit, eff_kind, eff_value, dir);
        },
    }

    // read the tree at that commit. building the read-only state mirrors what
    // repo.status does internally, but for an arbitrary commit rather than HEAD.
    var moment = repo.core.latestMoment() catch return emptyResult(aa, identity, eff_kind, eff_value, dir);
    const state = rp.Repo(.xit, .{}).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var tree = tr.Tree(.xit, .{}).init(state, io, gpa, &oid) catch return emptyResult(aa, identity, eff_kind, eff_value, dir);
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
    // into the page arena.
    const entries = try aa.alloc(Entry, children.count());
    var i: usize = 0;
    for ([_]bool{ true, false }) |want_dir| {
        for (children.keys(), children.values()) |name, is_dir| {
            if (is_dir == want_dir) {
                entries[i] = .{ .name = try aa.dupe(u8, name), .is_dir = is_dir };
                i += 1;
            }
        }
    }

    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_kind = eff_kind,
        .ref_value = try aa.dupe(u8, eff_value),
        .dir = try aa.dupe(u8, dir),
        .entries = entries,
    };
}

// a ref that didn't resolve: a 404 when the route named it explicitly, else an
// empty listing (e.g. resolving an empty repo's default branch).
fn unresolved(aa: std.mem.Allocator, identity: []const u8, explicit: bool, ref_kind: RefKindOrOid, ref_value: []const u8, dir: []const u8) !Self {
    if (explicit) return error.NotFound;
    return emptyResult(aa, identity, ref_kind, ref_value, dir);
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
fn emptyResult(aa: std.mem.Allocator, identity: []const u8, ref_kind: RefKindOrOid, ref_value: []const u8, dir: []const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .ref_kind = ref_kind,
        .ref_value = try aa.dupe(u8, ref_value),
        .dir = try aa.dupe(u8, dir),
        .entries = &.{},
    };
}

pub const View = struct {
    // a vertical list: one focusable row per entry. each subdirectory row is an
    // `a:` link to its /repo/.../files/<path> route, so following it (click or
    // Enter) navigates through the host's link handling, like the Users/Repos
    // lists. files are unlinked. a ".." row at the top links to the parent.
    scroll: wgt.Scroll(ui.Widget), // wraps a vertical Box of rows
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);

        // labels and link kinds are borrowed by the rows, so they live in the
        // page arena (as long as this page's widget tree).
        const aa = session.page_arena.allocator();
        if (data.dir.len != 0) {
            try addRow(allocator, &box, "..", try dirLink(session.page_arena, data, parentDir(data.dir)));
        }
        for (data.entries) |entry| {
            const label = if (entry.is_dir) try std.fmt.allocPrint(aa, "{s}/", .{entry.name}) else entry.name;
            const link = if (entry.is_dir) try dirLink(session.page_arena, data, try childDir(aa, data.dir, entry.name)) else "";
            try addRow(allocator, &box, label, link);
        }
        if (box.children.count() > 0) box.getFocus().child_id = box.children.keys()[0];

        var scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .vert, .web_native = !session.is_terminal });
        errdefer scroll.deinit(allocator);
        return .{ .scroll = scroll, .data = data };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().focusable = true;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    fn innerBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.box;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // the selected row shows a border (the focused TextBox upgrades it to a
        // double border itself); the rest stay borderless.
        const box = self.innerBox();
        for (box.children.keys(), box.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (box.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        // clear the incoming min_size so rows size to their content rather than
        // stretching to fill the page height; max_size still bounds the scroll
        // viewport so a long listing clips and scrolls.
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        // up/down move the selection. Enter and clicks on a link row are turned
        // into navigation by the host (crossPageLink); the ".." row and the
        // browser Back button (or Escape on the TUI) handle ascending.
        switch (key) {
            .arrow_down => try self.moveSelection(root_focus, 1),
            .arrow_up => try self.moveSelection(root_focus, -1),
            else => {},
        }
    }

    fn moveSelection(self: *View, root_focus: *Focus, delta: isize) !void {
        const box = self.innerBox();
        const keys = box.children.keys();
        const cur_id = box.getFocus().child_id orelse return;
        const cur = box.children.getIndex(cur_id) orelse return;
        if (delta < 0 and cur == 0) return;
        if (delta > 0 and cur + 1 >= keys.len) return;
        const next = if (delta < 0) cur - 1 else cur + 1;
        try root_focus.setFocus(keys[next]);
        if (box.children.values()[next].rect) |rect| self.scroll.scrollToRect(rect);
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

    pub fn getSelectedIndex(self: View) ?usize {
        const box = &self.scroll.child.box;
        const child_id = box.focus.child_id orelse return null;
        return box.children.getIndex(child_id);
    }
};

// the "a:" link for the files route at `dir`, pinned to the listing's ref.
fn dirLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, dir: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoFilesRoute(data.identity, data.ref_kind, data.ref_value, dir) orelse return error.RouteTooLong;
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

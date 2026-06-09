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

const Oid = [xit.hash.hexLen(.sha1)]u8;

// how many commits a page shows before a "next" link appears.
const page_size = 20;

// one commit on the current page.
pub const Commit = struct {
    oid: []const u8,
    date: []const u8, // "YYYY-MM-DD"
    message: []const u8, // first line only
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
) !Self {
    const aa = arena.allocator();
    const empty: Self = .{ .identity = try aa.dupe(u8, identity), .commits = &.{}, .next_start = null };

    // no filesystem (wasm) or nowhere to look: empty listing. the wasm path
    // never calls init anyway — it rebuilds from the serialized snapshot.
    const io = session.io orelse return empty;
    const repos_dir = session.repos_dir orelse return empty;

    // the repo's working copy lives at <repos_dir>/<hex event id>.
    const hex = std.fmt.bytesToHex(event_id.*, .lower);
    const repo_path = try std.fs.path.join(aa, &.{ repos_dir, &hex });

    // walk the log with the arena's backing allocator (transient; the commits
    // we keep are duped into the page arena so they outlive it).
    const gpa = arena.child_allocator;
    var repo = rp.Repo(.xit, .{}).open(io, gpa, .{ .path = repo_path }) catch return empty;
    defer repo.deinit(io, gpa);

    // page 1 walks from HEAD (null); a later page starts at its first oid.
    var start_arr: [1]Oid = undefined;
    const start_oids: ?[]const Oid = if (start_oid.len == 0) null else blk: {
        if (start_oid.len != start_arr[0].len) return empty; // malformed oid
        @memcpy(&start_arr[0], start_oid);
        break :blk start_arr[0..1];
    };

    var iter = repo.log(io, gpa, start_oids) catch return empty;
    defer iter.deinit();

    // collect this page's commits, plus a peek at the one after it (its oid is
    // the next page's start).
    var buf: [page_size]Commit = undefined;
    var count: usize = 0;
    var next_start: ?[]const u8 = null;
    while (try iter.next(gpa)) |commit_object| {
        defer commit_object.deinit();
        if (count == page_size) {
            next_start = try aa.dupe(u8, &commit_object.oid);
            break;
        }
        const md = commit_object.content.commit.metadata;
        buf[count] = .{
            .oid = try aa.dupe(u8, &commit_object.oid),
            .date = try formatDate(aa, md.timestamp),
            .message = try aa.dupe(u8, firstLine(md.message orelse "")),
        };
        count += 1;
    }

    return .{
        .identity = empty.identity,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
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
    // a vertical list mirroring Files.View: one focusable row per commit
    // (showing its date and message), and — when there's another page — a
    // "next" row at the bottom that links to it.
    scroll: wgt.Scroll(ui.Widget), // wraps a vertical Box of rows
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = wgt.Box(ui.Widget).init(.{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);

        // labels and link kinds are borrowed by the rows, so they live in the
        // page arena (as long as this page's widget tree).
        const aa = session.page_arena.allocator();
        for (data.commits) |commit| {
            const label = try std.fmt.allocPrint(aa, "{s}  {s}", .{ commit.date, commit.message });
            try addRow(allocator, &box, label, "");
        }
        if (data.next_start) |next| {
            try addRow(allocator, &box, "next", try commitsPageLink(session.page_arena, data.identity, next));
        }
        if (box.children.count() > 0) box.getFocus().child_id = box.children.keys()[0];

        var scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .vert);
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

    // how many rows a page up/down jumps.
    const page_rows = 10;

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // move it a fixed jump. the scroll wheel only reaches here in the TUI —
        // the web build lets the browser scroll natively and never forwards it.
        // Enter/clicks on the "next" row are turned into navigation by the host
        // (crossPageLink).
        switch (key) {
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

    fn moveSelection(self: *View, root_focus: *Focus, delta: isize) !void {
        const box = self.innerBox();
        const keys = box.children.keys();
        if (keys.len == 0) return;
        const cur_id = box.getFocus().child_id orelse return;
        const cur: isize = @intCast(box.children.getIndex(cur_id) orelse return);
        const last: isize = @intCast(keys.len - 1);
        const next: usize = @intCast(std.math.clamp(cur + delta, 0, last));
        if (next == @as(usize, @intCast(cur))) return;
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

// the "a:" link for the commits page starting at `start_oid` within `identity`.
fn commitsPageLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, start_oid: []const u8) ![]const u8 {
    const route = ui.RoutablePage.repoCommitsRoute(identity, start_oid) orelse return error.RouteTooLong;
    const url = try route.urlAlloc(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

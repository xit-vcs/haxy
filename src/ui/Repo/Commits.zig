const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
pub const Diff = @import("Diff.zig");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

// how many commits a page shows before a "next" link appears.
const page_size = 20;
// how many diff hunks one window of a commit's diff shows; "next"/"previous"
// move to the adjacent window.
// the largest message read even when it has fewer than the preview's line
// limit.
const max_message_size = 100 * 1024;

// one commit on the current page, with its diff against its first parent
// pre-rendered up to the budget so the web client can show it without a repo.
pub const Commit = struct {
    oid: []const u8,
    date: []const u8, // "YYYY-MM-DD"
    message: []const u8, // trimmed, may be multi-line
    // whether `message` is a shortened preview.
    message_truncated: bool = false,
    author: ui.Author = .unknown,
    stats: ?xit.patch.CommitStats = null,
    window: Diff.Window = .{},
};

// where links and clone commands for this repository are rooted.
location: ui.RoutablePage.RepoLocation,
// the resolved ref/oid this log walks from (the default branch when the route
// didn't name one), so the page can canonicalize its url to it.
ref_or_oid: ui.RoutablePage.RefOrOid,
ref_or_oid_value: []const u8,
commit_count: ?u64 = null,
commits: []const Commit,
// the first oid of the next page, or null when this is the last page.
next_start: ?[]const u8,
// what the pane shows for the commit the log walks from.
content: Content = .{ .diff = .{} },
// the "viewing <ref> <value>" banner shown above the log.
header: Header,

const Self = @This();

// the diff and the message are alternatives, so a filtered diff can't also be
// a message. the message page reads up to the safety limit above.
pub const Content = union(enum) {
    diff: struct {
        // the file the top commit's diff is filtered to ("" = every file).
        path: []const u8 = "",
    },
    message,
};

// walk the log for an opened repo. generic over the repo's backend and hash
// kind so the oid buffers and diff types it threads through match the repo's
// opts. `content` is what the walk root's pane shows, the only commit any of
// it applies to. walks with the arena's backing allocator (transient; the
// commits we keep are duped into the page arena so they outlive it).
pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    // the admin db's moment, for resolving author emails to user names (null
    // in local mode, which has no users)
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    location: ui.RoutablePage.RepoLocation,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    content: ui.RoutablePage.RepoCommitsRoute.Content,
    base_oid_maybe: ?[xit.hash.hexLen(repo_opts.hash)]u8,
) !Self {
    const aa = arena.allocator();
    const hex_len = ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len;

    // the walk root's message replaces its diff, so it's read whole and its
    // hunks aren't rendered. the window and the filter are its diff's.
    const root_message = std.meta.activeTag(content) == .message;
    const root_start: usize = switch (content) {
        .diff => |d| d.start,
        .message => 0,
    };
    const root_path: []const u8 = switch (content) {
        .diff => |*d| d.path.slice(),
        .message => "",
    };

    // resolve the requested ref (or the default branch) to the commit oid to
    // walk from. an explicitly named ref that doesn't resolve is a bad url
    // (NotFound -> 404); the default-branch path falls through to empty.
    const resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        return emptyResult(aa, location, .branch, requested_value, content);
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
        var iter = repo.log(io, gpa, .{ .start_oids = start_oids, .first_parent = true }) catch return emptyResult(aa, location, resolved.ref_or_oid, resolved.value, content);
        defer iter.deinit();
        // omit the base and its ancestors
        if (base_oid_maybe) |base_oid| try iter.exclude(&base_oid);
        while (try iter.next(gpa)) |commit_object| {
            defer commit_object.deinit();
            if (count == page_size) {
                next_start = try aa.dupe(u8, &commit_object.oid);
                break;
            }
            const md = commit_object.content.commit.metadata;
            @memcpy(&oids[count], &commit_object.oid);
            const text, const truncated = try readMessage(repo_kind, repo_opts, aa, commit_object, root_message and count == 0);
            buf[count] = .{
                .oid = try aa.dupe(u8, &commit_object.oid),
                .date = try formatDate(aa, md.timestamp),
                .message = text,
                .message_truncated = truncated,
                .author = try ui.Author.init(admin_moment, arena, md.author orelse ""),
                .stats = if (repo_kind == .xit) try repo.commitStats(io, gpa, .{ .oid = &commit_object.oid }) else null,
            };
            count += 1;
        }
    }

    // render each commit's diff (best effort: a failed diff leaves it empty).
    // the diff machinery isn't wasm-clean and the wasm client never runs it (it
    // renders from the snapshot), so gate it out of the wasm build.
    if (!builtin.cpu.arch.isWasm()) {
        for (buf[0..count], oids[0..count], 0..) |*commit, oid, i| {
            if (root_message and i == 0) continue;
            // the walk root shows the window the url asks for and its filter;
            // the rest show their first window, unfiltered.
            const window_start = if (i == 0) root_start else 0;
            commit.window = renderCommitDiff(repo_kind, repo_opts, io, gpa, aa, repo, oid, window_start, if (i == 0) root_path else "") catch .{ .start = window_start };
        }
    }

    const commit_count: ?u64 = switch (repo_kind) {
        .git => null,
        .xit => blk: {
            const head_count = repo.commitCount(io, gpa, .{ .oid = &resolved.oid }) catch break :blk null;
            const base_oid = base_oid_maybe orelse break :blk head_count;
            const base_count = repo.commitCount(io, gpa, .{ .oid = &base_oid }) catch break :blk null;
            break :blk if (head_count >= base_count) head_count - base_count else null;
        },
    };

    return .{
        .location = try location.dupe(aa),
        .ref_or_oid = resolved.ref_or_oid,
        .ref_or_oid_value = resolved.value,
        .commit_count = commit_count,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
        .content = try pageContent(aa, content),
        .header = try Header.init(aa, resolved.ref_or_oid, resolved.value),
    };
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
pub fn emptyResult(aa: std.mem.Allocator, location: ui.RoutablePage.RepoLocation, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8, content: ui.RoutablePage.RepoCommitsRoute.Content) !Self {
    return .{
        .location = try location.dupe(aa),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = try aa.dupe(u8, value),
        .commit_count = null,
        .commits = &.{},
        .next_start = null,
        .content = try pageContent(aa, content),
        .header = try Header.init(aa, ref_or_oid, value),
    };
}

// the page's content for a route's, duped into `aa`. the diff window doesn't
// carry over: each commit holds the one its pane shows as `window.start`.
fn pageContent(aa: std.mem.Allocator, content: ui.RoutablePage.RepoCommitsRoute.Content) !Content {
    return switch (content) {
        .diff => |d| .{ .diff = .{ .path = try aa.dupe(u8, d.path.slice()) } },
        .message => .message,
    };
}

// render the window [start, start+len) of a commit's diff against its first
// parent into `arena`-owned hunks. start/has_more identify adjacent windows.
// a non-empty `path` filters to that file, so the window indexes its hunks.
fn renderCommitDiff(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    oid: [xit.hash.hexLen(repo_opts.hash)]u8,
    start: usize,
    path: []const u8,
) !Diff.Window {
    const empty = Diff.Window{ .start = start };

    // load the commit so we can diff it against its first parent.
    var start_oids = [_][xit.hash.hexLen(repo_opts.hash)]u8{oid};
    var commit_iter = repo.log(io, gpa, .{ .start_oids = start_oids[0..1] }) catch return empty;
    defer commit_iter.deinit();
    const commit_object = (commit_iter.next(gpa) catch return empty) orelse return empty;
    defer commit_object.deinit();

    const parent_maybe = commit_object.content.commit.metadata.firstParent();

    return Diff.render(repo_kind, repo_opts, io, gpa, arena, repo, parent_maybe, oid, start, path);
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

// the commit message, trimmed and read into `aa`, plus whether its preview was
// cut short.
fn readMessage(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    aa: std.mem.Allocator,
    commit_object: *xit.object.Object(repo_kind, repo_opts),
    full_message: bool,
) !struct { []const u8, bool } {
    var message: std.ArrayList(u8) = .empty;
    const byte_truncated = if (commit_object.readMessage(aa, &message, .limited(max_message_size))) |_|
        false
    else |err| switch (err) {
        error.StreamTooLong => true,
        else => |e| return e,
    };
    const preview_end = if (full_message) null else ui.detailPreviewEnd(message.items);
    const text = if (preview_end) |end|
        message.items[0..end]
    else if (byte_truncated)
        trimIncompleteCodepoint(message.items)
    else
        message.items;
    return .{ std.mem.trim(u8, text, " \t\r\n"), byte_truncated or preview_end != null };
}

/// drop any incomplete UTF data from the end of a byte array
fn trimIncompleteCodepoint(bytes: []const u8) []const u8 {
    var i = bytes.len;
    while (i > 0 and bytes.len - i < 4) {
        i -= 1;
        const byte = bytes[i];
        if (byte & 0b1100_0000 == 0b1000_0000) continue; // continuation byte
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch return bytes;
        return if (i + seq_len > bytes.len) bytes[0..i] else bytes;
    }
    return bytes;
}

// a focusable, word-wrapping box holding a commit message. `bottom_label`
// marks a message the page only shows part of ("" when it's whole).
fn messageBox(allocator: std.mem.Allocator, message: []const u8, bottom_label: []const u8) !wgt.TextBox {
    var tb = try wgt.TextBox.init(allocator, message, .{
        .border_style = .single,
        .rounded_corners = true,
        .wrap_kind = .word,
        .label = " message ",
        .bottom_label = bottom_label,
    });
    tb.getFocus().mode = .all;
    return tb;
}

// the first line of a commit message, for the one-row list entries.
fn firstLine(message: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, message, '\n');
    return if (nl) |i| std.mem.trimEnd(u8, message[0..i], " \t\r") else message;
}

pub const View = struct {
    // a vertical stack: the "viewing <ref>" banner on top, then a horizontal
    // split with the commit list on the left and a diff pane on the right
    // showing the selected commit's diff.
    box: wgt.Box(ui.Widget), // vert: [header_index] = banner, [content_index] = split
    data: *const Self,
    session: *ui.Session,
    // the commit whose diff the pane currently shows (index into data.commits).
    diffed_index: ?usize,

    const header_index: usize = 0;
    const content_index: usize = 1;
    // indices within the content box (the horizontal split).
    const list_index: usize = 0;
    const diff_index: usize = 1;
    const list_max_width: usize = 35;
    const diff_min_width: usize = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the ref banner at the top.
        {
            var header_view = try Header.View.init(allocator, &data.header, session, data.location);
            errdefer header_view.deinit(allocator);
            try outer.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .repo_commits_header = header_view }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the commit list (one focusable row each), plus a "next" link
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
                errdefer list_box.deinit(allocator);
                for (data.commits, 0..) |commit, index| {
                    // an in-page "ai:" anchor so a commit row is clickable with
                    // js off (the browser follows it, rooting the list there);
                    // with wasm the click just selects it and swaps the diff pane.
                    const content = if (index == 0) data.content else Content{ .diff = .{} };
                    try addRow(allocator, &list_box, firstLine(commit.message), try commitRowLink(session.page_arena, data.location, commit, content));
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next →", try commitsLink(session.page_arena, data.location, next, 0, ""));
                }
                if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }

        // the diff pane — a frame around a scroll of the hunks
        {
            var diff_outer = blk: {
                var diff_scroll = try Diff.View.initEmpty(allocator, session);
                errdefer diff_scroll.deinit(allocator);
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                // the frame's selected child is its scroll, so the focus chain
                // reaches a hunk (populateDiff points the scroll's inner box at
                // one), letting focus recovery descend into the diff pane after
                // it's laid out beside a too-narrow list.
                frame.getFocus().child_id = diff_scroll.getFocus().id;
                try frame.children.put(allocator, diff_scroll.getFocus().id, .{ .widget = .{ .diff_view = diff_scroll }, .rect = null, .min_size = null });
                break :blk frame;
            };
            errdefer diff_outer.deinit(allocator);
            diff_outer.getFocus().mode = .mouse;
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
        var row = try wgt.TextBox.init(allocator, label, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null, .max_size = .{ .width = null, .height = 5 } });
    }

    // a focusable window-navigation row ("previous"/"next"). it's a link to this
    // commit's route at `target_start`, so activating it (the host follows the
    // "a:" link) reloads the page on the adjacent window — same on TUI and web.
    fn addNavLink(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, oid: []const u8, target_start: usize, path: []const u8) !void {
        const link = try commitsLink(self.session.page_arena, self.data.location, oid, target_start, path);
        var tb = try wgt.TextBox.init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().mode = .all;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    // a focusable row for the top of the diff pane linking to the files tab at
    // this commit's tree, so its files are always viewable as of this object.
    fn addViewFilesLink(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), oid: []const u8) !void {
        const link = try filesObjectLink(self.session.page_arena, self.data.location, oid);
        var tb = try wgt.TextBox.init(allocator, "view files at this commit", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer tb.deinit(allocator);
        tb.getFocus().mode = .all;
        tb.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    // how much of the message a pane's box holds: a truncated preview links to
    // the pane holding the whole thing, which is that link's destination.
    const MessageBox = enum { preview, whole };

    // the selected commit's message.
    fn addMessageBox(self: *View, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), commit: Commit, kind: MessageBox) !void {
        // a truncated message keeps its box even with no whole line to show,
        // since the box is what links to the whole thing.
        if (commit.message.len == 0 and !commit.message_truncated) return;
        const cut_short = commit.message_truncated and kind == .preview;
        var tb = try messageBox(allocator, commit.message, if (cut_short) " click or press enter to see more " else "");
        errdefer tb.deinit(allocator);
        if (cut_short) tb.getFocus().kind = .{ .custom = try messageLink(self.session.page_arena, self.data.location, commit.oid) };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[content_index].widget.box;
    }

    fn header(self: *View) *Header.View {
        return &self.box.children.values()[header_index].widget.repo_commits_header;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.header().getFocus().id;
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
        return &self.diffOuter().children.values()[0].widget.diff_view.scroll;
    }

    fn diffInner(self: *View) *wgt.Box(ui.Widget) {
        return &self.diffScroll().child.box;
    }

    fn diffActive(self: *View) bool {
        const content = self.contentBox();
        const cid = content.getFocus().child_id orelse return false;
        return content.children.getIndex(cid) == diff_index;
    }

    // what the pane shows for the commit at `sel`. the page's content only
    // applies to the commit it walks from; the rest show their plain diff.
    fn paneContent(self: *View, sel: usize) Self.Content {
        return if (sel == 0) self.data.content else .{ .diff = .{} };
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

        // the selected list row shows a border (the focused TextBox upgrades it
        // to a double border itself); the rest stay borderless.
        const lb = self.listBox();
        for (lb.children.keys(), lb.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
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
        const diff_width: usize = if (constraint.max_size.width) |w|
            (if (both_panes_fit) w - list_max_width else w)
        else
            diff_min_width;
        self.contentBox().children.values()[diff_index].min_size = .{ .width = diff_width, .height = null };

        // the message is the pane's only wrapping row, and wrapping needs a
        // bounded width, which the pane's scroll doesn't grant (it scrolls
        // horizontally too). cap it to the pane, leaving room for the border
        // and the scrollbar column. re-capped each build so it tracks resizes.
        for (self.diffInner().children.values()) |*child| switch (child.widget) {
            .text_box => |text_box| if (text_box.options.wrap_kind == .word) {
                child.max_size = .{ .width = diff_width -| 3, .height = null };
            },
            else => {},
        };

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

        switch (self.paneContent(sel)) {
            .message => {
                try self.addNavLink(allocator, inner, "← back to diff", commit.oid, 0, "");
                try self.addMessageBox(allocator, inner, commit, .whole);
            },
            .diff => |d| {
                if (d.path.len == 0) {
                    try self.addMessageBox(allocator, inner, commit, .preview);
                    if (commit.author != .unknown) {
                        var tb = try ui.authorBox(allocator, self.session.page_arena, commit.author);
                        errdefer tb.deinit(allocator);
                        try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                    }
                    if (commit.stats) |stats| {
                        var text: std.Io.Writer.Allocating = .init(allocator);
                        defer text.deinit();
                        try text.writer.print("lines changed: {d}", .{stats.lines_added + stats.lines_changed});
                        if (stats.lines_removed != 0) try text.writer.print("\nlines removed: {d}", .{stats.lines_removed});
                        const bytes_added = stats.bytes_added >= stats.bytes_removed;
                        const bytes = if (bytes_added) stats.bytes_added - stats.bytes_removed else stats.bytes_removed - stats.bytes_added;
                        try text.writer.print("\nbytes {s}: {d}\nfiles changed: {d}", .{
                            if (bytes_added) "added" else "removed", bytes, stats.files_added + stats.files_changed,
                        });
                        if (stats.files_removed != 0) try text.writer.print("\nfiles removed: {d}", .{stats.files_removed});
                        var tb = try wgt.TextBox.init(allocator, text.written(), .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none, .label = " stats " });
                        errdefer tb.deinit(allocator);
                        tb.getFocus().mode = .all;
                        try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                    }
                    try self.addViewFilesLink(allocator, inner, commit.oid);
                }

                try (Diff{
                    .route = .{ .commit = .{ .location = self.data.location, .oid = commit.oid } },
                    .path = d.path,
                    .window = commit.window,
                }).appendWindow(allocator, self.session, inner);
            },
        }

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
        if (self.headerActive()) {
            if (key == .arrow_down) {
                root_focus.setFocus(self.contentBox().getFocus().id);
            } else {
                try self.header().input(allocator, key, root_focus);
            }
            return;
        }
        if (key == .arrow_up and self.contentAtTop() and self.header().focusCloneUrl(root_focus)) return;
        if (self.diffActive()) {
            if (key == .arrow_left and self.diffScroll().x == 0) {
                self.focusList(root_focus);
            } else {
                try self.diffOuter().children.values()[0].widget.diff_view.input(allocator, key, root_focus);
            }
        } else {
            try self.listInput(key, root_focus);
        }
    }

    fn listInput(self: *View, key: Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the diff pane. Enter/clicks
        // on the "next" row become navigation in the host before reaching here.
        if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.widget.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
            return;
        }
        switch (key) {
            .enter => if (self.selectedCommitIndex() != null)
                self.focusDiff(root_focus)
            else if (self.data.next_start) |next| {
                if (self.data.location.commitsRoute(.object, next, 0, "")) |route|
                    try self.session.navigate(route);
            },
            .arrow_right => self.focusDiff(root_focus),
            else => {},
        }
    }

    // enter the diff pane. the host arrives here on right-arrow or Enter from the
    // list. a diff with no rows can't be entered. setFocus handles the too-narrow
    // case where the pane isn't laid out yet (it gets selected, then focused after
    // the next build, landing on its remembered hunk).
    fn focusDiff(self: *View, root_focus: *Focus) void {
        if (self.diffInner().children.count() == 0) return;
        root_focus.setFocus(self.diffOuter().getFocus().id);
    }

    // return to the list.
    fn focusList(self: *View, root_focus: *Focus) void {
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

    fn contentAtTop(self: *View) bool {
        if (self.diffActive()) {
            const inner = self.diffInner();
            const cid = inner.getFocus().child_id orelse return true;
            const first_focused = inner.children.count() > 0 and cid == inner.children.keys()[0];
            return first_focused and self.diffScroll().y == 0;
        }
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return true;
        return lb.children.getIndex(cid) == 0;
    }

    // only the clone-url row sits directly below the repository header.
    pub fn atTop(self: *View) bool {
        return self.headerActive() or (!self.header().hasCloneUrl() and self.contentAtTop());
    }

    pub fn focusCloneUrl(self: *View, root_focus: *Focus) bool {
        return self.header().focusCloneUrl(root_focus);
    }
};

// the "a:" navigation link for the commits page walking from commit `oid` within
// `location`, windowing the selected commit's diff from hunk `start`, filtered
// to `path` ("" = every file).
fn commitsLink(page_arena: *std.heap.ArenaAllocator, location: ui.RoutablePage.RepoLocation, oid: []const u8, start: usize, path: []const u8) ![]const u8 {
    const route = location.commitsRoute(.object, oid, start, path) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "a:" link to the files tab at commit `oid` (an object ref), at its root
// directory, within `location`.
fn filesObjectLink(page_arena: *std.heap.ArenaAllocator, location: ui.RoutablePage.RepoLocation, oid: []const u8) ![]const u8 {
    const route = location.filesRoute(.object, oid, "", 0) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting a commit with its current pane content
// and window. the href is only followed with js off.
fn commitRowLink(page_arena: *std.heap.ArenaAllocator, location: ui.RoutablePage.RepoLocation, commit: Commit, content: Content) ![]const u8 {
    const route = (switch (content) {
        .message => location.commitMessageRoute(.object, commit.oid),
        .diff => |diff| location.commitsRoute(.object, commit.oid, commit.window.start, diff.path),
    }) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

// the "a:" link to the page showing `oid`'s message on its own.
fn messageLink(page_arena: *std.heap.ArenaAllocator, location: ui.RoutablePage.RepoLocation, oid: []const u8) ![]const u8 {
    const route = location.commitMessageRoute(.object, oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// the "<ref_or_oid> <value>" banner shown above the log.
pub const Header = struct {
    content: []const u8,

    // `value` arrives url-encoded, so decode it for display.
    pub fn init(aa: std.mem.Allocator, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8) !Header {
        const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, value));
        return .{
            .content = try std.fmt.allocPrint(aa, "{s} {s}", .{ @tagName(ref_or_oid), decoded }),
        };
    }

    pub const View = struct {
        box: wgt.Box(ui.Widget),
        data: *const Header,

        pub fn init(allocator: std.mem.Allocator, data: *const Header, session: *ui.Session, location: ui.RoutablePage.RepoLocation) !Header.View {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer box.deinit(allocator);

            if (!session.data.is_local) {
                if (try ui.widget.CopyableText.initClone(allocator, session, location)) |value| {
                    var clone_url = value;
                    errdefer clone_url.deinit(allocator);
                    const min_width = clone_url.minWidth();
                    box.getFocus().child_id = clone_url.getFocus().id;
                    try box.children.put(allocator, clone_url.getFocus().id, .{ .widget = .{ .copyable_text = clone_url }, .rect = null, .min_size = .{ .width = min_width, .height = 3 }, .max_size = .{ .width = min_width, .height = 3 } });
                }
            }

            var spacer = try ui.widget.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });

            var text_box = try wgt.TextBox.init(allocator, data.content, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            try box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null, .flex = .shrink });

            return .{ .box = box, .data = data };
        }

        pub fn deinit(self: *Header.View, allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        pub fn build(self: *Header.View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Header.View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const clone_url = self.cloneUrl() orelse return;
            try clone_url.input(allocator, key, root_focus);
        }

        pub fn focusCloneUrl(self: *Header.View, root_focus: *Focus) bool {
            const clone_url = self.cloneUrl() orelse return false;
            root_focus.setFocus(clone_url.getFocus().id);
            return true;
        }

        pub fn hasCloneUrl(self: *Header.View) bool {
            return self.cloneUrl() != null;
        }

        fn cloneUrl(self: *Header.View) ?*ui.widget.CopyableText {
            for (self.box.children.values()) |*child| switch (child.widget) {
                .copyable_text => |*copyable_text| return copyable_text,
                else => {},
            };
            return null;
        }

        pub fn clearGrid(self: *Header.View) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: Header.View) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *Header.View) *Focus {
            return self.box.getFocus();
        }
    };
};

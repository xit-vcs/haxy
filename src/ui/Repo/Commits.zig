const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const Diff = @import("Diff.zig");
const Undo = @import("Undo.zig");
const obj = xit.object;
const srch_cmmt = @import("../../search_commit.zig");
const srch = @import("../../search.zig");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");

// how many commits a page shows before a "next" link appears.
const page_size = 20;
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
    // .unknown when the committer is the author.
    committer: ui.Author = .unknown,
    // the committer timestamp, human-readable.
    timestamp: []const u8,
    stats: ?xit.patch.CommitStats = null,
    window: Diff.Window = .{},
};

// where links and clone commands for this repository are rooted.
location: ui.RoutablePage.RepoLocation,
// the resolved ref/oid this log walks from (the default branch when the route
// didn't name one), so the page can canonicalize its url to it.
ref_or_oid: ui.RoutablePage.RefOrOid,
ref_or_oid_value: []const u8,
base_oid: []const u8 = "",
commit_count: ?u64 = null,
commits: []const Commit,
// the first oid of the next page, or null when this is the last page.
next_start: ?[]const u8,
// what the pane shows for the commit the log walks from.
content: Content = .{ .diff = .{} },
// the decoded query this list holds the results of, or null for a plain log.
search: ?[]const u8 = null,
// whether the viewed ref has a commit index, so the search box shows and a
// search: route resolves. travels in the page json for the wasm view.
search_available: bool = false,

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
    base_oid: []const u8,
    search: []const u8,
    from: []const u8,
) !Self {
    const aa = arena.allocator();
    const hex_len = ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len;
    if (base_oid.len != 0) {
        evt.PatchRev.validateOid(repo_opts.hash, base_oid) catch return error.NotFound;
    }
    if (from.len != 0) {
        evt.PatchRev.validateOid(repo_opts.hash, from) catch return error.NotFound;
    }
    const query: ?[]const u8 = if (search.len == 0) null else std.Uri.percentDecodeInPlace(try aa.dupe(u8, search));

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
    var resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        return emptyResult(aa, location, .branch, requested_value, content, base_oid);
    };

    var moment = repo.core.latestMoment() catch return emptyResult(aa, location, resolved.ref_or_oid, resolved.value, content, base_oid);
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };

    // resolve annotated tags once, independently of the page's starting commit.
    {
        var tip = obj.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &resolved.oid) catch {
            if (query != null) return error.NotFound;
            return emptyResult(aa, location, resolved.ref_or_oid, resolved.value, content, base_oid);
        };
        defer tip.deinit();
        resolved.oid = tip.oid;
    }

    // collect this page's commit metadata, plus a peek at the one after it (its
    // oid is the next page's start). the diff for each is rendered afterward, so
    // the log iterator is closed before opening per-commit diff iterators.
    var buf: [page_size]Commit = undefined;
    var oids: [page_size][hex_len]u8 = undefined;
    var count: usize = 0;
    var next_start: ?[]const u8 = null;
    var search_available = false;
    var searched = false;

    // the index covers a repository's branch and tag tips, so a fork or an
    // object view gets no search box and refuses a search: url. nor does a list
    // bounded by a base, whose version also covers the commits before it.
    if (comptime repo_kind == .xit) index: {
        if (location != .repo or resolved.ref_or_oid == .object or base_oid.len != 0) break :index;
        const index = (try srch_cmmt.lookup(repo_opts, moment, &resolved.oid)) orelse break :index;
        search_available = true;
        const text = query orelse break :index;

        var results = try srch.Query(rp.Repo(.xit, repo_opts).DB).init(index, aa, text);
        if (from.len != 0) {
            var start = obj.Object(.xit, repo_opts).initCommit(state, io, gpa, from[0..hex_len]) catch return error.NotFound;
            defer start.deinit();
            const key = try srch_cmmt.docKey(repo_opts.hash, start.content.commit.metadata.timestamp, &start.oid);
            results.seek(&key);
        }
        while (try results.next()) |key| {
            const oid = try srch_cmmt.keyOid(repo_opts.hash, key);
            if (count == page_size) {
                next_start = try aa.dupe(u8, &oid);
                break;
            }
            // a result whose object is gone is skipped rather than shown
            var commit_object = obj.Object(.xit, repo_opts).init(state, io, gpa, &oid) catch continue;
            defer commit_object.deinit();
            if (commit_object.content != .commit) continue;
            @memcpy(&oids[count], &oid);
            buf[count] = try commitEntry(repo_kind, repo_opts, arena, repo, io, gpa, admin_moment, &commit_object, root_message and count == 0);
            count += 1;
        }
        searched = true;
    }
    if (query != null and !searched) return error.NotFound;

    if (!searched) {
        // paging keeps the ref and starts the walk at the url's commit
        var start_oid = resolved.oid;
        if (from.len != 0) @memcpy(&start_oid, from);

        var iter = repo.log(io, gpa, .{ .start_oids = &.{start_oid}, .first_parent = true }) catch return emptyResult(aa, location, resolved.ref_or_oid, resolved.value, content, base_oid);
        defer iter.deinit();
        while (try iter.next(gpa)) |commit_object| {
            defer commit_object.deinit();
            // the base is a stopping point, not an ancestry exclusion
            if (std.mem.eql(u8, &commit_object.oid, base_oid)) break;
            if (count == page_size) {
                next_start = try aa.dupe(u8, &commit_object.oid);
                break;
            }
            @memcpy(&oids[count], &commit_object.oid);
            buf[count] = try commitEntry(repo_kind, repo_opts, arena, repo, io, gpa, admin_moment, commit_object, root_message and count == 0);
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

    return .{
        .location = try location.dupe(aa),
        .ref_or_oid = resolved.ref_or_oid,
        .ref_or_oid_value = resolved.value,
        .base_oid = try aa.dupe(u8, base_oid),
        .commit_count = if (repo_kind == .xit and location == .repo) blk: {
            if (base_oid.len == 0) {
                const stats = (xit.patch.readCommitStats(repo_opts, state.extra.moment, &resolved.oid) catch null) orelse break :blk null;
                break :blk stats.first_parent_depth;
            }
            break :blk evt.PatchRev.commitCount(repo_kind, repo_opts, state, io, gpa, base_oid, &resolved.oid) catch null;
        } else null,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
        .content = try pageContent(aa, content),
        .search = query,
        .search_available = search_available,
    };
}

// one commit's row: its message, author and stats. the diff window is rendered
// afterward, once the log iterator is closed.
fn commitEntry(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    commit_object: *obj.Object(repo_kind, repo_opts),
    full_message: bool,
) !Commit {
    const aa = arena.allocator();
    const md = commit_object.content.commit.metadata;
    const text, const truncated = try readMessage(repo_kind, repo_opts, aa, commit_object, full_message);
    return .{
        .oid = try aa.dupe(u8, &commit_object.oid),
        .date = try formatDate(aa, md.timestamp),
        .message = text,
        .message_truncated = truncated,
        .author = try ui.Author.init(admin_moment, arena, md.author orelse ""),
        .committer = if (md.committer) |committer|
            (if (std.mem.eql(u8, identityOf(committer), identityOf(md.author orelse ""))) .unknown else try ui.Author.init(admin_moment, arena, committer))
        else
            .unknown,
        .timestamp = try Undo.formatTimestamp(aa, std.math.cast(i64, md.timestamp) orelse -1),
        .stats = if (repo_kind == .xit) try repo.commitStats(io, gpa, .{ .oid = &commit_object.oid }) else null,
    };
}

// an author or committer line without its timestamp.
fn identityOf(line: []const u8) []const u8 {
    const close_bracket = std.mem.indexOfScalar(u8, line, '>') orelse return line;
    return line[0 .. close_bracket + 1];
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
pub fn emptyResult(aa: std.mem.Allocator, location: ui.RoutablePage.RepoLocation, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8, content: ui.RoutablePage.RepoCommitsRoute.Content, base_oid: []const u8) !Self {
    return .{
        .location = try location.dupe(aa),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = try aa.dupe(u8, value),
        .base_oid = try aa.dupe(u8, base_oid),
        .commit_count = null,
        .commits = &.{},
        .next_start = null,
        .content = try pageContent(aa, content),
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
    var commit_iter = repo.log(io, gpa, .{ .start_oids = &.{oid} }) catch return empty;
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
    // a vertical stack: the clone url row on top, then a horizontal
    // split with the commit list on the left and a diff pane on the right
    // showing the selected commit's diff.
    box: wgt.Box(ui.Widget), // vert: [header_index] = clone url row, [content_index] = split
    data: *const Self,
    session: *ui.Session,
    // the commit whose diff the pane currently shows (index into data.commits).
    diffed_index: ?usize,

    // the sub-header leads the box where there is one; local mode has none
    const header_index: usize = 0;
    // indices within the content box (the horizontal split).
    const list_index: usize = 0;
    const diff_index: usize = 1;
    const list_max_width: usize = 35;
    const diff_min_width: usize = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the search box and the clone url at the top. local mode has neither.
        if (session.data.host_kind == .server) {
            var header_view = try ui.widget.SearchHeader.init(allocator, session, data.location, " search ", "search", data.search, data.search_available);
            errdefer header_view.deinit(allocator);
            try outer.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .search_header = header_view }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
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
                    try addRow(allocator, &list_box, firstLine(commit.message), try commitRowLink(session.page_arena, data, commit, content));
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next →", try nextPageLink(session.page_arena, data, next));
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

        // focus lives in the split, except that search results start in the
        // search box so the query can be refined right away.
        outer.getFocus().child_id = outer.children.keys()[if (data.search != null) header_index else outer.children.count() - 1];

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
        const link = try commitsLink(self.session.page_arena, self.data, oid, target_start, path);
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
        if (cut_short) tb.getFocus().kind = .{ .custom = try messageLink(self.session.page_arena, self.data, commit.oid) };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    // the split is last, after the sub-header where there is one
    fn contentIndex(self: *View) usize {
        return self.box.children.count() - 1;
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[self.contentIndex()].widget.box;
    }

    fn header(self: *View) ?*ui.widget.SearchHeader {
        switch (self.box.children.values()[header_index].widget) {
            .search_header => |*header_view| return header_view,
            else => return null,
        }
    }

    fn headerActive(self: *View) bool {
        const header_view = self.header() orelse return false;
        return self.box.getFocus().child_id == header_view.getFocus().id;
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
                    if (commit.author != .unknown or commit.committer != .unknown) {
                        var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
                        errdefer row.deinit(allocator);
                        if (commit.author != .unknown) {
                            var tb = try ui.authorBox(allocator, self.session.page_arena, commit.author);
                            errdefer tb.deinit(allocator);
                            try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                        }
                        if (commit.committer != .unknown) {
                            var tb = try ui.authorBox(allocator, self.session.page_arena, commit.committer);
                            errdefer tb.deinit(allocator);
                            tb.options.label = " committer ";
                            try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                        }
                        row.getFocus().child_id = row.children.keys()[0];
                        try inner.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
                    }
                    {
                        var tb = try wgt.TextBox.init(allocator, commit.timestamp, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none, .label = " timestamp " });
                        errdefer tb.deinit(allocator);
                        tb.getFocus().mode = .all;
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
                    .route = .{ .commit = .{ .location = self.data.location, .oid = commit.oid, .base_oid = self.data.base_oid } },
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
        // scrolling crosses the sub header boundary the same way arrows do
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            // active means there is one
            const header_view = self.header() orelse unreachable;
            if (direction == .down) {
                root_focus.setFocus(self.contentBox().getFocus().id);
                return;
            }
            if (key == .enter) if (try header_view.submittedText(allocator)) |text| {
                defer allocator.free(text);
                return self.submit(text);
            };
            return header_view.input(allocator, key, root_focus);
        }
        if (direction == .up and self.contentAtTop() and self.focusHeader(root_focus)) return;
        if (self.diffActive()) {
            const diff_view = &self.diffOuter().children.values()[0].widget.diff_view;
            if (key == .arrow_left and self.diffScroll().x == 0) {
                if (!diff_view.moveInRow(root_focus, false)) self.focusList(root_focus);
            } else {
                try diff_view.input(allocator, key, root_focus);
            }
        } else {
            try self.listInput(key, root_focus);
        }
    }

    // navigate to the typed query's results, pinned to the list's ref. an
    // empty query leaves the results for the plain log.
    fn submit(self: *View, text: []const u8) !void {
        if (text.len == 0 and self.data.search == null) return;
        const route = self.data.location.commitsRoute(self.data.ref_or_oid, self.data.ref_or_oid_value, 0, "", self.data.base_oid) orelse return;
        try self.session.navigate(route.withSearch(text) orelse return);
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
                if (pageRoute(self.data, next)) |route| try self.session.navigate(route);
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

    // only the header's own row sits directly below the repository header.
    pub fn atTop(self: *View) bool {
        const focusable = if (self.header()) |header_view| header_view.hasFocusable() else false;
        return self.headerActive() or (!focusable and self.contentAtTop());
    }

    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        const header_view = self.header() orelse return false;
        return header_view.focusHeader(root_focus);
    }
};

// the "a:" navigation link for the commits page walking from commit `oid` within
// `data.location`, windowing the selected commit's diff from hunk `start`, filtered
// to `path` ("" = every file).
fn commitsLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8, start: usize, path: []const u8) ![]const u8 {
    const route = data.location.commitsRoute(.object, oid, start, path, data.base_oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// this list's page starting at `oid`: a repo's branch or tag keeps its ref (and
// its query) and moves `from` along, so the search box survives paging. a fork
// or an object view roots the page at the commit itself.
fn pageRoute(data: *const Self, oid: []const u8) ?ui.RoutablePage {
    if (data.location != .repo or data.ref_or_oid == .object) {
        return data.location.commitsRoute(.object, oid, 0, "", data.base_oid);
    }
    const route = data.location.commitsRoute(data.ref_or_oid, data.ref_or_oid_value, 0, "", data.base_oid) orelse return null;
    const paged = route.withFrom(oid) orelse return null;
    return paged.withSearch(data.search orelse return paged);
}

fn nextPageLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8) ![]const u8 {
    const route = pageRoute(data, oid) orelse return error.RouteTooLong;
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
fn commitRowLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, commit: Commit, content: Content) ![]const u8 {
    // a result roots the same results page at its commit, so the query
    // survives following the row
    if (data.search != null) {
        const route = pageRoute(data, commit.oid) orelse return error.RouteTooLong;
        return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{try route.toUrl(page_arena)});
    }
    const route = (switch (content) {
        .message => data.location.commitMessageRoute(.object, commit.oid, data.base_oid),
        .diff => |diff| data.location.commitsRoute(.object, commit.oid, commit.window.start, diff.path, data.base_oid),
    }) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{url});
}

// the "a:" link to the page showing `oid`'s message on its own.
fn messageLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8) ![]const u8 {
    const route = data.location.commitMessageRoute(.object, oid, data.base_oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

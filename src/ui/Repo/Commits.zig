const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const Undo = @import("Undo.zig");
const obj = xit.object;
const mrg = xit.merge;
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

// one commit on the current page.
pub const Commit = struct {
    oid: []const u8,
    // what its diff is against: the first parent, all zeros for a root commit
    parent_oid: []const u8,
    date: []const u8, // "YYYY-MM-DD"
    message: []const u8, // trimmed, may be multi-line
    // whether `message` is a shortened preview.
    message_truncated: bool = false,
    author: ui.Author = .unknown,
    // .unknown when the committer is the author.
    committer: ui.Author = .unknown,
    // the committer timestamp, human-readable.
    timestamp: []const u8,
    // whether it has a second parent.
    merge: bool = false,
    stats: ?xit.patch.CommitStats = null,
};

// where links and clone commands for this repository are rooted, and who views it.
handle: ui.RepoHandle,
// the resolved ref/oid this log walks from (the default branch when the route
// didn't name one), so the page can canonicalize its url to it.
ref_or_oid: ui.RoutablePage.RefOrOid,
ref_or_oid_value: []const u8,
base_oid: []const u8 = "",
commit_count: ?u64 = null,
commits: []const Commit,
// the first oid of the next page, or null when this is the last page.
next_start: ?[]const u8,
// the pane shows the whole message of the commit the log walks from.
message: bool = false,
// the decoded query this list holds the results of, or null for a plain log.
search: ?[]const u8 = null,
// whether the viewed ref has a commit index, so the search box shows and a
// search: route resolves. travels in the page json for the wasm view.
search_available: bool = false,
// an object view or a base-bounded list searches the default branch: that
// branch's url-encoded name, when it is indexed
default_branch: []const u8 = "",
// the repo's default branch has no commit yet, so the tab shows a placeholder
no_commits: bool = false,

const Self = @This();

// walk the log for an opened repo. generic over the repo's backend and hash
// kind so the oid buffers it threads through match the repo's opts. `message`
// reads the walk root's message whole, up to the safety limit above. walks
// with the arena's backing allocator (transient; the commits we keep are
// duped into the page arena so they outlive it).
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
    handle: ui.RepoHandle,
    requested_ref_or_oid: ?ui.RoutablePage.RefOrOid,
    requested_value: []const u8,
    message: bool,
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

    // resolve the requested ref (or the default branch) to the commit oid to
    // walk from. an explicitly named ref that doesn't resolve is a bad url
    // (NotFound -> 404); the default-branch path falls through to empty.
    var resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, requested_ref_or_oid, requested_value)) orelse {
        if (requested_ref_or_oid != null) return error.NotFound;
        var data = try emptyResult(aa, handle, .branch, requested_value, base_oid);
        data.no_commits = true;
        return data;
    };

    var moment = repo.core.latestMoment() catch return emptyResult(aa, handle, resolved.ref_or_oid, resolved.value, base_oid);
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };

    // resolve annotated tags once, independently of the page's starting commit.
    {
        var tip = obj.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &resolved.oid) catch {
            if (query != null) return error.NotFound;
            return emptyResult(aa, handle, resolved.ref_or_oid, resolved.value, base_oid);
        };
        defer tip.deinit();
        resolved.oid = tip.oid;
    }

    // collect this page's commits, plus a peek at the one after it (its oid is
    // the next page's start).
    var buf: [page_size]Commit = undefined;
    var count: usize = 0;
    var next_start: ?[]const u8 = null;
    var search_available = false;
    var default_branch: []const u8 = "";
    var searched = false;

    // the index covers a repository's branch and tag tips, so a fork gets no
    // search box and refuses a search: url. an object view or a list bounded by
    // a base, whose version would also cover the commits before it, searches
    // the default branch instead.
    if (comptime repo_kind == .xit) index: {
        if (handle.location != .repo) break :index;
        if (resolved.ref_or_oid == .object or base_oid.len != 0) {
            var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
            const branch = switch (repo.head(io, &head_buffer) catch break :index) {
                .ref => |ref| ref.name,
                .oid => break :index,
            };
            const tip = (try repo.readRef(io, .{ .kind = .head, .name = branch })) orelse break :index;
            if (try srch_cmmt.lookup(repo_opts, moment, &tip) == null) break :index;
            search_available = true;
            default_branch = try ui.urlEncodeRef(aa, branch);
            break :index;
        }
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
            var commit_object = try obj.Object(.xit, repo_opts).initCommit(state, io, gpa, &oid);
            defer commit_object.deinit();
            buf[count] = try commitEntry(repo_kind, repo_opts, arena, repo, io, gpa, admin_moment, &commit_object, message and count == 0);
            count += 1;
        }
        searched = true;
    }
    if (query != null and !searched) return error.NotFound;

    if (!searched) {
        // paging keeps the ref and starts the walk at the url's commit
        var start_oid = resolved.oid;
        if (from.len != 0) @memcpy(&start_oid, from);

        var iter = repo.log(io, gpa, .{ .start_oids = &.{start_oid}, .first_parent = true }) catch return emptyResult(aa, handle, resolved.ref_or_oid, resolved.value, base_oid);
        defer iter.deinit();
        while (try iter.next(gpa)) |commit_object| {
            defer commit_object.deinit();
            // the base is a stopping point, not an ancestry exclusion
            if (std.mem.eql(u8, &commit_object.oid, base_oid)) break;
            if (count == page_size) {
                next_start = try aa.dupe(u8, &commit_object.oid);
                break;
            }
            buf[count] = try commitEntry(repo_kind, repo_opts, arena, repo, io, gpa, admin_moment, commit_object, message and count == 0);
            count += 1;
        }
    }

    return .{
        .handle = try handle.dupe(aa),
        .ref_or_oid = resolved.ref_or_oid,
        .ref_or_oid_value = resolved.value,
        .base_oid = try aa.dupe(u8, base_oid),
        .commit_count = if (repo_kind == .xit and handle.location == .repo) blk: {
            if (base_oid.len == 0) {
                const stats = (xit.patch.readCommitStats(repo_opts, state.extra.moment, &resolved.oid) catch null) orelse break :blk null;
                break :blk stats.first_parent_depth;
            }
            break :blk evt.PatchRev.commitCount(repo_kind, repo_opts, state, io, gpa, base_oid, &resolved.oid) catch null;
        } else null,
        .commits = try aa.dupe(Commit, buf[0..count]),
        .next_start = next_start,
        .message = message,
        .search = query,
        .search_available = search_available,
        .default_branch = default_branch,
    };
}

// one commit's row: its message, author and stats.
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
        .parent_oid = if (md.firstParent()) |parent| try aa.dupe(u8, parent) else &@as([xit.hash.hexLen(repo_opts.hash)]u8, @splat('0')),
        .date = try formatDate(aa, md.timestamp),
        .message = text,
        .message_truncated = truncated,
        .author = try ui.Author.init(admin_moment, arena, md.author orelse ""),
        .committer = if (md.committer) |committer|
            (if (std.mem.eql(u8, identityOf(committer), identityOf(md.author orelse ""))) .unknown else try ui.Author.init(admin_moment, arena, committer))
        else
            .unknown,
        .timestamp = try Undo.formatTimestamp(aa, std.math.cast(i64, md.timestamp) orelse -1),
        .merge = if (md.parent_oids) |parent_oids| parent_oids.len > 1 else false,
        .stats = if (repo_kind == .xit) try repo.commitStats(io, gpa, .{ .oid = &commit_object.oid }) else null,
    };
}

// what merge `merge_oid` brought in: its second parent's log back to the
// parents' common ancestor, or the whole log when they share none.
pub fn resolveMerge(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    merge_oid: []const u8,
) !struct { oid: []const u8, base_oid: []const u8 } {
    const aa = arena.allocator();
    evt.PatchRev.validateOid(repo_opts.hash, merge_oid) catch return error.NotFound;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var merge = obj.Object(repo_kind, repo_opts).initCommit(state, io, gpa, merge_oid[0..comptime xit.hash.hexLen(repo_opts.hash)]) catch return error.NotFound;
    defer merge.deinit();
    const parent_oids = merge.content.commit.metadata.parent_oids orelse &.{};
    if (parent_oids.len < 2) return error.NotFound;
    const oid = try aa.dupe(u8, &parent_oids[1]);
    const base_oid = mrg.commonAncestor(repo_kind, repo_opts, state, io, gpa, &parent_oids[0], &parent_oids[1]) catch |err| switch (err) {
        error.NoCommonAncestor => return .{ .oid = oid, .base_oid = "" },
        error.MultipleMergeBases => return error.NotFound,
        else => return err,
    };
    return .{ .oid = oid, .base_oid = try aa.dupe(u8, &base_oid) };
}

// an author or committer line without its timestamp.
fn identityOf(line: []const u8) []const u8 {
    const close_bracket = std.mem.indexOfScalar(u8, line, '>') orelse return line;
    return line[0 .. close_bracket + 1];
}

// an empty listing pinned to a ref, for the wasm / no-repo / unresolved paths.
pub fn emptyResult(aa: std.mem.Allocator, handle: ui.RepoHandle, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8, base_oid: []const u8) !Self {
    return .{
        .handle = try handle.dupe(aa),
        .ref_or_oid = ref_or_oid,
        .ref_or_oid_value = try aa.dupe(u8, value),
        .base_oid = try aa.dupe(u8, base_oid),
        .commit_count = null,
        .commits = &.{},
        .next_start = null,
    };
}

// "YYYY-MM-DD" for a unix timestamp.
fn formatDate(arena: std.mem.Allocator, timestamp: u64) ![]const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return arena.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
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
        .border = .single,
        .round_corners = true,
        .wrap_kind = .word,
        .top_label = .{ .text = " message " },
        .bottom_label = .{ .text = bottom_label },
        .detect_links = true,
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
    // split with the commit list on the left and a pane on the right
    // showing the selected commit's details.
    box: wgt.Box(ui.Widget), // vert: [header_index] = clone url row, [content_index] = split
    data: *const Self,
    session: *ui.Session,
    // the commit the pane currently shows (index into data.commits).
    detailed_index: ?usize,

    // the sub-header leads the box where there is one; local mode has none
    const header_index: usize = 0;
    // indices within the content box (the horizontal split).
    const list_index: usize = 0;
    const detail_index: usize = 1;
    const list_max_width: usize = 35;
    const detail_min_width: usize = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        if (data.no_commits) {
            var center = try ui.widget.initNoCommits(allocator, session, data.handle);
            errdefer center.deinit(allocator);
            outer.getFocus().child_id = center.getFocus().id;
            try outer.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
            return .{ .box = outer, .data = data, .session = session, .detailed_index = null };
        }

        // the search box and the clone url at the top. local mode has neither.
        if (session.data.host_kind == .server) {
            var header_view = try ui.widget.SearchHeader.init(allocator, session, data.handle, " search ", "search", data.search, data.search_available);
            errdefer header_view.deinit(allocator);
            // a row taller than the header, leaving a blank line beneath it
            try outer.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .search_header = header_view }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        // the commit list (one focusable row each), plus a "next" link
        {
            var list_scroll = blk: {
                var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert, .stretch = true });
                errdefer list_box.deinit(allocator);
                for (data.commits, 0..) |commit, index| {
                    // an in-page "ai:" anchor so a commit row is clickable with
                    // js off (the browser follows it, rooting the list there);
                    // with wasm the click just selects it and swaps the pane.
                    try addRow(allocator, &list_box, firstLine(commit.message), try commitRowLink(session.page_arena, data, commit, index == 0 and data.message), if (commit.merge) "(merge)" else "");
                }
                if (data.next_start) |next| {
                    try addRow(allocator, &list_box, "next →", try nextPageLink(session.page_arena, data, next), "");
                }
                if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer list_scroll.deinit(allocator);
            try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }

        // the detail pane: a frame around a scroll of its rows
        {
            var detail_outer = blk: {
                var detail_scroll = blk2: {
                    var rows = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
                    errdefer rows.deinit(allocator);
                    break :blk2 try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
                };
                errdefer detail_scroll.deinit(allocator);
                var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                // the frame's selected child is its scroll, so the focus chain
                // reaches a row (populateDetail points the scroll's inner box at
                // one), letting focus recovery descend into the pane after
                // it's laid out beside a too-narrow list.
                frame.getFocus().child_id = detail_scroll.getFocus().id;
                try frame.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = null });
                break :blk frame;
            };
            errdefer detail_outer.deinit(allocator);
            detail_outer.getFocus().mode = .mouse;
            try box.children.put(allocator, detail_outer.getFocus().id, .{ .widget = .{ .box = detail_outer }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }

        box.getFocus().child_id = box.children.keys()[if (data.commits.len > 0) detail_index else list_index];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });

        // focus lives in the split, except that search results start in the
        // search box so the query can be refined right away.
        outer.getFocus().child_id = outer.children.keys()[if (data.search != null) header_index else outer.children.count() - 1];

        return .{
            .box = outer,
            .data = data,
            .session = session,
            .detailed_index = null,
        };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8, bottom_label: []const u8) !void {
        var row = try wgt.TextBox.init(allocator, label, .{ .border = .hidden, .round_corners = true, .wrap_kind = .word, .bottom_label = .{ .text = bottom_label } });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link.len != 0) row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null, .max_size = .{ .width = null, .height = 5 } });
    }

    // a focusable row following the "a:" `link`.
    fn addLink(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, link: []const u8) !void {
        var tb = try wgt.TextBox.init(allocator, label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
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
        if (self.data.no_commits) return self.box.build(allocator, constraint, root_focus);

        // swap the detail pane to the selected commit when it changes.
        try self.refreshDetail(allocator);

        // the selected list row shows a border (the focused TextBox upgrades it
        // to a double border itself); the rest stay borderless.
        const lb = self.listBox();
        for (lb.children.keys(), lb.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| ui.widget.markSelected(tb, lb.getFocus().child_id == id),
                else => {},
            }
        }

        // cap the list at list_max_width only while the detail pane fits beside it.
        // the box drops the pane when the width can't hold both minimums, so when
        // it's that narrow we lift the cap and let the list fill the whole width.
        const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
        self.contentBox().children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

        // stretch the detail pane across the rest of the width so it fills the area
        // rather than shrinking to its content; its scroll fills the pane. when
        // too narrow for both, it fills the whole width.
        const detail_width: usize = if (constraint.max_size.width) |w|
            (if (both_panes_fit) w - list_max_width else w)
        else
            detail_min_width;
        self.contentBox().children.values()[detail_index].min_size = .{ .width = detail_width, .height = null };

        // the web bounds the layout to the browser viewport like the terminal;
        // each Scroll's web-native mode hands its full content to a real
        // scrollable element, so we no longer build unbounded here.
        //
        // crossing panes only re-selects the content box's child (focusDetail /
        // focusList); when the window is too narrow to show both, the pane that
        // held focus is dropped here. the framework recovers focus after the
        // top-level build by re-deriving it down the selected-child chain, so
        // there's nothing to fix up afterward.
        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const sel = self.selectedCommitIndex() orelse return;
        if (self.detailed_index) |d| if (d == sel) return;
        try self.populateDetail(allocator, sel);
        self.detailed_index = sel;
    }

    fn populateDetail(self: *View, allocator: std.mem.Allocator, sel: usize) !void {
        const commit = self.data.commits[sel];
        const inner = self.detailInner();

        for (inner.children.values()) |*child| child.widget.deinit(allocator);
        inner.children.clearAndFree(allocator);
        inner.getFocus().child_id = null;

        if (sel == 0 and self.data.message) {
            try addLink(allocator, inner, "← back to commit", try commitsLink(self.session.page_arena, self.data, commit.oid));
            try self.addMessageBox(allocator, inner, commit, .whole);
        } else {
            const pa = self.session.page_arena;
            {
                var row = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
                errdefer row.deinit(allocator);
                const diff_route = self.data.handle.location.commitDiffRoute(commit.oid, commit.parent_oid) orelse return error.RouteTooLong;
                try addLink(allocator, &row, "view diff", try pa.allocator().print("a:{s}", .{try diff_route.toUrl(pa)}));
                try addLink(allocator, &row, "view files at this commit", try filesObjectLink(pa, self.data.handle.location, commit.oid));
                row.getFocus().child_id = row.children.keys()[0];
                try inner.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
            }
            if (commit.merge) if (self.data.handle.location.commitsMergeRoute(commit.oid)) |route| {
                try addLink(allocator, inner, "view commits from this merge", try pa.allocator().print("a:{s}", .{try route.toUrl(pa)}));
            };
            {
                var row = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
                errdefer row.deinit(allocator);
                if (commit.author != .unknown) {
                    var tb = try ui.authorBox(allocator, pa, commit.author);
                    errdefer tb.deinit(allocator);
                    try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                }
                if (commit.committer != .unknown) {
                    var tb = try ui.authorBox(allocator, pa, commit.committer);
                    errdefer tb.deinit(allocator);
                    tb.options.top_label.text = " committer ";
                    try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                }
                var tb = try wgt.TextBox.init(allocator, commit.timestamp, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer tb.deinit(allocator);
                tb.getFocus().mode = .all;
                try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                row.getFocus().child_id = row.children.keys()[0];
                try inner.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
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
                var tb = try wgt.TextBox.init(allocator, text.written(), .{ .border = .single, .round_corners = true, .wrap_kind = .none, .top_label = .{ .text = " stats " } });
                errdefer tb.deinit(allocator);
                tb.getFocus().mode = .all;
                try inner.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
            }
            try self.addMessageBox(allocator, inner, commit, .preview);
        }

        // point the pane at its first row so focus recovery can land here.
        if (inner.children.count() > 0) inner.getFocus().child_id = inner.children.keys()[0];

        // reset the scroll to the top for the newly-shown commit: directly on the
        // terminal (the wasm offset), and via a version bump on the web (so the
        // renderer's scroll id changes and JS drops the preserved position).
        const sc = self.detailScroll();
        sc.x = 0;
        sc.y = 0;
        sc.getFocus().version +%= 1;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (self.data.no_commits) return self.box.input(allocator, key, root_focus);
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
        if (self.detailActive()) {
            const inner = self.detailInner();
            if (inp.rowDelta(key, @intCast(inner.children.count()))) |delta| {
                ui.widget.moveRowFocus(inner, self.detailScroll(), root_focus, delta);
            } else if (key == .arrow_left) {
                if (!ui.widget.moveInSelectedRow(inner, root_focus, false)) self.focusList(root_focus);
            } else if (key == .arrow_right) {
                _ = ui.widget.moveInSelectedRow(inner, root_focus, true);
            }
        } else {
            try self.listInput(allocator, key, root_focus);
        }
    }

    // navigate to the typed query's results, pinned to the list's ref. an
    // empty query leaves the results for the plain log.
    fn submit(self: *View, text: []const u8) !void {
        if (text.len == 0 and self.data.search == null) return;
        // an object view or a base-bounded list searches the default branch, so the url says so
        const route = if (self.data.default_branch.len != 0)
            self.data.handle.location.commitsRoute(.branch, self.data.default_branch, "")
        else
            self.data.handle.location.commitsRoute(self.data.ref_or_oid, self.data.ref_or_oid_value, self.data.base_oid);
        try self.session.navigate((route orelse return).withSearch(text) orelse return);
    }

    fn listInput(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // up/down (and the scroll wheel) move the selection a row; page up/down
        // jump a fixed amount. right/Enter cross into the detail pane. Enter/clicks
        // on the "next" row become navigation in the host before reaching here.
        if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.widget.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
            return;
        }
        switch (key) {
            .enter => if (self.selectedCommitIndex() != null)
                self.focusDetail(root_focus)
            else if (self.data.next_start) |next| {
                if (pageRoute(self.data, next)) |route| try self.session.navigate(route);
            },
            .arrow_right => self.focusDetail(root_focus),
            // when the window is too narrow to lay out the detail pane beside
            // the list, a click on a row opens it like enter. the row was just
            // selected, so the detail is swapped to it ahead of the build.
            .mouse => |mouse| if (self.contentBox().children.values()[detail_index].rect == null and ui.widget.clickOnSelectedRow(self.listBox(), root_focus, mouse)) {
                try self.refreshDetail(allocator);
                self.focusDetail(root_focus);
            },
            else => {},
        }
    }

    // enter the detail pane. the host arrives here on right-arrow or Enter from the
    // list. a pane with no rows can't be entered. setFocus handles the too-narrow
    // case where the pane isn't laid out yet (it gets selected, then focused after
    // the next build, landing on its remembered row).
    fn focusDetail(self: *View, root_focus: *Focus) void {
        if (self.detailInner().children.count() == 0) return;
        root_focus.setFocus(self.detailOuter().getFocus().id);
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
        if (self.detailActive()) {
            const inner = self.detailInner();
            const cid = inner.getFocus().child_id orelse return true;
            const first_focused = inner.children.count() > 0 and cid == inner.children.keys()[0];
            return first_focused and self.detailScroll().y == 0;
        }
        const lb = self.listBox();
        const cid = lb.getFocus().child_id orelse return true;
        return lb.children.getIndex(cid) == 0;
    }

    // only the header's own row sits directly below the repository header.
    pub fn atTop(self: *View) bool {
        if (self.data.no_commits) return true;
        const focusable = if (self.header()) |header_view| header_view.hasFocusable() else false;
        return self.headerActive() or (!focusable and self.contentAtTop());
    }

    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        const header_view = self.header() orelse return false;
        return header_view.focusHeader(root_focus);
    }
};

// the "a:" navigation link for the commits page walking from commit `oid` within
// `data.handle.location`.
fn commitsLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8) ![]const u8 {
    const route = data.handle.location.commitsRoute(.object, oid, data.base_oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return page_arena.allocator().print("a:{s}", .{url});
}

// this list's page starting at `oid`: a repo's branch or tag keeps its ref (and
// its query) and moves `from` along, so the search box survives paging. a fork
// or an object view roots the page at the commit itself.
fn pageRoute(data: *const Self, oid: []const u8) ?ui.RoutablePage {
    if (data.handle.location != .repo or data.ref_or_oid == .object) {
        return data.handle.location.commitsRoute(.object, oid, data.base_oid);
    }
    const route = data.handle.location.commitsRoute(data.ref_or_oid, data.ref_or_oid_value, data.base_oid) orelse return null;
    const paged = route.withFrom(oid) orelse return null;
    return paged.withSearch(data.search orelse return paged);
}

fn nextPageLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8) ![]const u8 {
    const route = pageRoute(data, oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return page_arena.allocator().print("a:{s}", .{url});
}

// the "a:" link to the files tab at commit `oid` (an object ref), at its root
// directory, within `location`.
fn filesObjectLink(page_arena: *std.heap.ArenaAllocator, location: ui.RoutablePage.RepoLocation, oid: []const u8) ![]const u8 {
    const route = location.filesRoute(.object, oid, "", 0) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return page_arena.allocator().print("a:{s}", .{url});
}

// the in-page "ai:" anchor for selecting a commit, showing its whole message
// when `message` is set. the href is only followed with js off.
fn commitRowLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, commit: Commit, message: bool) ![]const u8 {
    // a result roots the same results page at its commit, so the query
    // survives following the row
    if (data.search != null) {
        const route = pageRoute(data, commit.oid) orelse return error.RouteTooLong;
        return page_arena.allocator().print("ai:{s}", .{try route.toUrl(page_arena)});
    }
    const route = (if (message)
        data.handle.location.commitMessageRoute(.object, commit.oid, data.base_oid)
    else
        data.handle.location.commitsRoute(.object, commit.oid, data.base_oid)) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return page_arena.allocator().print("ai:{s}", .{url});
}

// the "a:" link to the page showing `oid`'s message on its own.
fn messageLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, oid: []const u8) ![]const u8 {
    const route = data.handle.location.commitMessageRoute(.object, oid, data.base_oid) orelse return error.RouteTooLong;
    const url = try route.toUrl(page_arena);
    return page_arena.allocator().print("a:{s}", .{url});
}

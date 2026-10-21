const std = @import("std");
const builtin = @import("builtin");
const ui = @import("../../ui.zig");
const evt = @import("../../event.zig");
const pch = @import("../../patch.zig");
const push = @import("../../push.zig");
const fork = @import("../../fork.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;
const Self = @This();

pub const page_size = 20;

// the action kind xit writes when a transaction is undone
const undo_action_kind = @tagName(xit.undo.ActionKind.undo);

// stands in for the description, as a focusable box that may link somewhere
pub const DetailButton = struct {
    label: []const u8,
    text: []const u8,
    link: ?[]const u8 = null,
};

pub const Item = struct {
    index: u64,
    action: []const u8,
    description: []const u8,
    timestamp: i64,
    link: []const u8,
    form: []const u8,
    buttons: []const DetailButton = &.{},
    undone: bool = false,
};

identity: []const u8,
count: u64 = 0,
items: []const Item = &.{},
next: ?u64 = null,
failure: ?[]const u8 = null,
handle: ui.RepoHandle,

// no history and no failure, which shows the empty message
fn isEmpty(self: *const Self, session: *ui.Session) bool {
    return self.items.len == 0 and (session.data.undo_failure orelse self.failure) == null;
}

pub fn init(comptime opts: rp.RepoOpts(.xit), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(.xit, opts), haxy_moment: ?evt.AdminDB.HashMap(.read_only), identity: []const u8, selected: ?u64, handle: ui.RepoHandle) !Self {
    const aa = arena.allocator();
    const DB = rp.Repo(.xit, opts).DB;
    const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());
    const count = try history.count();
    if (selected) |index| if (index >= count) return error.NotFound;
    var items: std.ArrayList(Item) = .empty;
    var remaining = if (selected) |index| index + 1 else count;
    var buffer: [opts.max_read_size]u8 = undefined;

    // an undo above the page discards transactions on it, so the walk starts
    // at the newest transaction. an undo discards everything from the one it
    // restored to down to the row below itself, so walking down, that row is
    // all the walk has to carry. the rows it discarded are skipped, since a
    // discarded undo discards nothing itself
    var undone_from: ?u64 = null;
    var scanned = count;
    while (scanned > remaining) {
        scanned -= 1;
        if (undone_from) |from| if (scanned >= from) {
            scanned = from;
            continue;
        };
        const record = try xit.undo.read(opts, try repo.core.momentAt(scanned), &buffer);
        if (try undoneFrom(arena, record)) |from| undone_from = from;
    }

    while (remaining > 0 and items.items.len < page_size) {
        remaining -= 1;
        const moment = try repo.core.momentAt(remaining);
        const record = try xit.undo.read(opts, moment, &buffer);
        const row_undone = if (undone_from) |from| remaining >= from else false;
        if (!row_undone) {
            if (try undoneFrom(arena, record)) |from| undone_from = from;
        }
        const detail = if (record) |value| try eventDetail(opts, arena, &repo.core, haxy_moment, identity, value, moment, remaining) else null;
        const shown = detail orelse Detail{
            .action = if (record) |value| try aa.dupe(u8, value.action_kind) else "unknown",
            .description = try formatRecord(opts, arena, &repo.core, record),
        };
        const route = ui.RoutablePage.repoUndoRoute(identity, remaining) orelse return error.RouteTooLong;
        const url = try route.toUrl(arena);
        try items.append(aa, .{
            .index = remaining,
            .action = shown.action,
            .description = shown.description,
            .buttons = shown.buttons,
            .timestamp = if (record) |value| value.timestamp else -1,
            .link = try aa.print("ai:{s}", .{url}),
            .form = try aa.print("form:{s}/undo", .{url}),
            .undone = row_undone,
        });
    }
    return .{ .identity = try aa.dupe(u8, identity), .handle = handle, .count = count, .items = items.items, .next = if (remaining > 0) remaining - 1 else null };
}

const Detail = struct {
    action: []const u8,
    description: []const u8,
    buttons: []const DetailButton = &.{},
};

// every haxy event transaction shares one action, and the events it wrote are
// named by the moment's index rather than by the record
fn eventDetail(
    comptime opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    core: *rp.Repo(.xit, opts).Core,
    haxy_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    record: xit.undo.Record,
    moment: rp.Repo(.xit, opts).DB.HashMap(.read_only),
    history_index: u64,
) !?Detail {
    const aa = arena.allocator();
    if (std.mem.eql(u8, record.action_kind, undo_action_kind)) {
        // an undo names a transaction earlier than itself, so the chain
        // below always moves down the history and ends
        const parsed = std.json.parseFromSlice(xit.undo.Undo, arena.child_allocator, record.payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        defer parsed.deinit();
        const button = try undoneButton(opts, arena, core, haxy_moment, identity, parsed.value);
        return .{ .action = undo_action_kind, .description = button.text, .buttons = try aa.dupe(DetailButton, &.{button}) };
    }
    if (std.mem.eql(u8, record.action_kind, evt.merge_undo_action)) return .{ .action = "merge events", .description = "merged the events ref from a remote" };
    if (std.mem.eql(u8, record.action_kind, pch.merge_undo_action)) return .{ .action = "merge patch", .description = "merged a patch into its target branch" };
    if (std.mem.eql(u8, record.action_kind, fork.undo_action)) return .{ .action = "fork", .description = "created a fork to draft a patch in" };
    if (std.mem.eql(u8, record.action_kind, pch.mergeability_undo_action)) return .{ .action = "mergeability", .description = "rechecked whether the open patches still merge cleanly" };
    if (std.mem.eql(u8, record.action_kind, push.undo_action)) {
        // a push consumes the events it carried in its own transaction
        var buttons: std.ArrayList(DetailButton) = .empty;
        if (try pushUser(arena, haxy_moment, record.payload)) |button| try buttons.append(aa, button);
        const count = try momentEventCount(opts, core, moment, history_index) orelse 0;
        if (count > 0) try buttons.append(aa, try eventsButton(arena, identity, history_index, count));
        try pushRefs(arena, identity, record.payload, &buttons);
        return .{ .action = "push", .description = "received a push", .buttons = buttons.items };
    }
    if (!std.mem.eql(u8, record.action_kind, evt.undo_action)) return null;

    const count = try momentEventCount(opts, core, moment, history_index) orelse return .{ .action = "events", .description = "updated the event database" };
    // a transaction that consumed only merge commits indexed no events of its own
    if (count == 0) return .{ .action = "events", .description = "merged the event history" };
    const buttons = try aa.dupe(DetailButton, &.{try eventsButton(arena, identity, history_index, count)});
    return .{
        .action = try aa.print("events ({d})", .{count}),
        .description = "updated the event database",
        .buttons = buttons,
    };
}

// xit formats the transactions haxy has no name of its own for
fn formatRecord(comptime opts: rp.RepoOpts(.xit), arena: *std.heap.ArenaAllocator, core: *rp.Repo(.xit, opts).Core, record: ?xit.undo.Record) ![]const u8 {
    const value = record orelse return "no undo record";
    var description: std.Io.Writer.Allocating = .init(arena.allocator());
    try xit.undo.format(opts, core, arena.child_allocator, value, &description.writer);
    return description.written();
}

// the transaction an undo restored, as a button that reads like its own row.
// the error set is explicit because this and `eventDetail` call each other
fn undoneButton(
    comptime opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    core: *rp.Repo(.xit, opts).Core,
    haxy_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    undo: xit.undo.Undo,
) anyerror!DetailButton {
    var buffer: [opts.max_read_size]u8 = undefined;
    const target = try xit.undo.undoneTarget(opts, core, arena.child_allocator, undo, &buffer);

    // the detail reads the event count out of the transaction's own moment
    const moment = try core.momentAt(target.index);
    const detail = if (target.record) |value| try eventDetail(opts, arena, core, haxy_moment, identity, value, moment, target.index) else null;
    const route = ui.RoutablePage.repoUndoRoute(identity, target.index) orelse return error.RouteTooLong;
    return .{
        .label = if (target.redo) " what was redone " else " what was undone ",
        .text = if (detail) |value| value.action else try formatRecord(opts, arena, core, target.record),
        .link = try arena.allocator().print("a:{s}", .{try route.toUrl(arena)}),
    };
}

// the page reads the transaction's own moment, so the url names the
// transaction rather than the state it produced
fn eventsButton(arena: *std.heap.ArenaAllocator, identity: []const u8, history_index: u64, count: u64) !DetailButton {
    const aa = arena.allocator();
    const route = ui.RoutablePage.repoEventsRoute(identity, .active, null, "", history_index) orelse return error.RouteTooLong;
    return .{
        .label = " events ",
        .text = try aa.print("view events ({d})", .{count}),
        .link = try aa.print("a:{s}", .{try route.toUrl(arena)}),
    };
}

// a button per ref the push moved, naming what it did to it: a changed branch
// links to the commits it added, or dropped when a force push added none,
// anything still there to the ref itself
fn pushRefs(arena: *std.heap.ArenaAllocator, identity: []const u8, payload: []const u8, buttons: *std.ArrayList(DetailButton)) !void {
    const head_prefix = "refs/heads/";
    const tag_prefix = "refs/tags/";
    const Payload = struct {
        // only a forced branch has a base, where the walk from its new tip
        // stops, or from its old one when the push dropped commits
        const Ref = struct { name: []const u8, old: []const u8, new: []const u8, forced: bool = false, dropped: bool = false, base: []const u8 = "" };
        refs: []const Ref = &.{},
    };
    const parsed = std.json.parseFromSlice(Payload, arena.child_allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();

    const aa = arena.allocator();
    for (parsed.value.refs) |ref| {
        // anything that is neither a head nor a tag is skipped
        const head = std.mem.startsWith(u8, ref.name, head_prefix);
        const prefix = if (head) head_prefix else tag_prefix;
        if (!std.mem.startsWith(u8, ref.name, prefix)) continue;
        const name = ref.name[prefix.len..];

        // a removed ref has nothing left to link to. a branch that was created
        // has no range to show either: what it added is whatever the other
        // refs did not already reach, which a base cannot express
        const removed = ref.new.len == 0;
        const created = ref.old.len == 0;
        const changed = head and !removed and !created;
        const route = if (removed)
            null
        else if (changed)
            ui.RoutablePage.repoCommitsRoute(identity, .object, if (ref.dropped) ref.old else ref.new, if (ref.forced) ref.base else ref.old) orelse continue
        else
            ui.RoutablePage.repoFilesRoute(identity, if (head) .branch else .tag, try ui.urlEncodeRef(aa, name), "", 0) orelse continue;

        try buttons.append(aa, .{
            .label = if (changed)
                try aa.print(" {s} branch{s} ", .{ if (ref.dropped) "removed from" else "added to", if (ref.forced) " (force)" else "" })
            else
                try aa.print(" {s} {s} ", .{ if (removed) "removed" else if (created) "created" else "moved", if (head) "branch" else "tag" }),
            .text = try aa.dupe(u8, name),
            .link = if (route) |value| try aa.print("a:{s}", .{try value.toUrl(arena)}) else null,
        });
    }
}

// the push record stores the email of the user whose key the server accepted.
// resolving it names them as they are now, and leaves the email when no user
// holds it
fn pushUser(arena: *std.heap.ArenaAllocator, haxy_moment: ?evt.AdminDB.HashMap(.read_only), payload: []const u8) !?DetailButton {
    const Payload = struct { author: struct { email: []const u8 } };
    const parsed = std.json.parseFromSlice(Payload, arena.child_allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    return switch (try ui.Author.initFromEmail(haxy_moment, arena, parsed.value.author.email)) {
        .unknown => null,
        .email => |email| .{ .label = " user ", .text = email },
        .user_name => |name| .{ .label = " user ", .text = name, .link = try ui.userLink(arena, name) },
    };
}

// how many events the transaction wrote: zero when it consumed nothing, null
// when its state cannot be read at all
fn momentEventCount(
    comptime opts: rp.RepoOpts(.xit),
    core: *rp.Repo(.xit, opts).Core,
    moment: rp.Repo(.xit, opts).DB.HashMap(.read_only),
    history_index: u64,
) !?u64 {
    const DB = rp.Repo(.xit, opts).DB;
    const haxy_moment = evt.currentMomentFromRepoMoment(opts.hash, moment) catch return null;
    const index = try momentIndex(opts, haxy_moment) orelse return null;

    // a transaction that consumed nothing inherits the moment it was cloned
    // from, whose events belong to the transaction that wrote it
    inherited: {
        if (history_index == 0) break :inherited;
        const previous = evt.currentMomentFromRepoMoment(opts.hash, try core.momentAt(history_index - 1)) catch break :inherited;
        if (try momentIndex(opts, previous)) |value| if (value == index) return 0;
    }

    const ids = try evt.momentEventIds(DB, opts.hash, haxy_moment, index) orelse return 0;
    return try ids.count();
}

// the oldest transaction `record` discarded, or null when it is not an undo
fn undoneFrom(arena: *std.heap.ArenaAllocator, record: ?xit.undo.Record) !?u64 {
    const value = record orelse return null;
    if (!std.mem.eql(u8, value.action_kind, undo_action_kind)) return null;
    const parsed = std.json.parseFromSlice(xit.undo.Undo, arena.child_allocator, value.payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    return parsed.value.index;
}

// the moment's own position in the haxy history
fn momentIndex(comptime opts: rp.RepoOpts(.xit), haxy_moment: evt.EventDB(opts.hash).HashMap(.read_only)) !?u64 {
    const cursor = try haxy_moment.getCursor(hash.hashInt(opts.hash, evt.moment_index_key)) orelse return null;
    return try cursor.readUint();
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, index: u64) !void {
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| try repo.undo(io, index),
    }
}

// keep action failures on the current tab without rebuilding a stale route.
pub fn handleRequest(allocator: std.mem.Allocator, session: *ui.Session, target: ui.RoutablePage.RepoUndoRoute) void {
    perform(allocator, session, target) catch |err| {
        session.data.undo_failure = @errorName(err);
        return;
    };
    session.data.undo_failure = null;
}

// both terminal hosts resolve and authorize the request afresh before opening
// the repository; the web handler uses its matching http authorization path.
pub fn perform(allocator: std.mem.Allocator, session: *ui.Session, target: ui.RoutablePage.RepoUndoRoute) !void {
    const identity = target.name.slice();
    const index = target.index orelse return error.InvalidHistoryIndex;
    const source = try authorizedSource(session, identity) orelse return error.Forbidden;
    const io = session.io orelse return error.NotFound;
    try execute(io, allocator, source, index);
    try session.navigate(ui.RoutablePage.repoUndoRoute(identity, null) orelse return error.RouteTooLong);
}

// the repo an owner may act on, or null when they may not
fn authorizedSource(session: *ui.Session, identity: []const u8) !?ui.RepoSource {
    if (try session.authorize(identity, .owner, null) == null) return null;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const pair = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const io = session.io orelse return error.NotFound;
    const users_dir = session.users_dir orelse return error.NotFound;
    const found = try evt.readRepoByOwnerAndName(io, session.page_arena.child_allocator, session.page_arena, moment, users_dir, pair.owner, pair.name, null) orelse return error.NotFound;
    return .{ .path = try evt.repoPath(session.page_arena.allocator(), users_dir, &try evt.parseEventId(&found.repo.event.user_id), &found.event_id), .repo_kind = .xit };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: ?usize = null,
    shown_failure: ?[]const u8 = null,

    const list_max_width = 20;
    const detail_min_width = 40;
    // the sub header leads the box where there is one
    const header_index = 0;
    // the undo button and timestamp stay; everything below them is rebuilt
    const fixed_rows = 2;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the sub header holds the command that clears the history. a server
        // without ssh has no way to.
        if (session.data.git_ssh_url) |ssh_url| {
            var header_scroll = try ui.widget.HeaderScroll.init(allocator, session);
            errdefer header_scroll.deinit(allocator);
            {
                const aa = session.page_arena.allocator();
                const command = try aa.print("git push {s}/{s} :" ++ push.clear_undo_ref, .{ ssh_url, data.identity });
                var copyable_text = try ui.widget.CopyableText.init(allocator, session, &.{.{
                    .text = command,
                    .copyable_text = try aa.print("{s}{s}", .{ session.data.git_ssh_prefix, command }),
                    .label = " clear undo history ",
                }}, 0);
                errdefer copyable_text.deinit(allocator);
                const min_width = copyable_text.minWidth();
                const row = header_scroll.row();
                row.getFocus().child_id = copyable_text.getFocus().id;
                try row.children.put(allocator, copyable_text.getFocus().id, .{ .widget = .{ .copyable_text = copyable_text }, .rect = null, .min_size = .{ .width = min_width, .height = 3 }, .max_size = .{ .width = min_width, .height = 3 } });
            }
            // a row taller than the header, leaving a blank line beneath it
            try outer.children.put(allocator, header_scroll.getFocus().id, .{ .widget = .{ .header_scroll = header_scroll }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        // the empty message when there is no history or failure to show
        if (data.isEmpty(session)) {
            var center = try ui.widget.initEmpty(allocator);
            errdefer center.deinit(allocator);
            try outer.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
            // the empty message has nothing to focus, so focus rests on the sub header where there is one
            outer.getFocus().child_id = outer.children.keys()[header_index];
            return .{ .box = outer, .data = data, .session = session };
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        {
            var scroll = blk: {
                var rows = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert, .stretch = true });
                errdefer rows.deinit(allocator);
                for (data.items) |item| {
                    try addText(allocator, &rows, item.action, item.link, .hidden);
                    // a transaction a later undo discarded says so on its border
                    if (item.undone) rows.children.values()[rows.children.count() - 1].widget.text_box.options.bottom_label.text = "(undone)";
                }
                if (data.next) |next| {
                    const route = ui.RoutablePage.repoUndoRoute(data.identity, next) orelse return error.RouteTooLong;
                    try addText(allocator, &rows, "next →", try session.page_arena.allocator().print("a:{s}", .{try route.toUrl(session.page_arena)}), .hidden);
                }
                // the failure row, filled in by build
                if (data.items.len == 0) try addText(allocator, &rows, "", null, .hidden);
                rows.getFocus().child_id = rows.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }
        // the detail scroll, below the way back to a hidden list
        {
            var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
            errdefer frame.deinit(allocator);
            try ui.widget.addListBack(allocator, &frame, "← back to undo list");
            var scroll = blk: {
                var details = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
                errdefer details.deinit(allocator);
                if (data.items.len > 0) {
                    try addText(allocator, &details, "", null, .single);
                    try addText(allocator, &details, "", null, .single);
                    details.getFocus().child_id = details.children.keys()[0];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = details }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            scroll.getFocus().mode = .mouse;
            frame.getFocus().child_id = scroll.getFocus().id;
            try frame.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });
            try box.children.put(allocator, frame.getFocus().id, .{ .widget = .{ .box = frame }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }
        box.getFocus().child_id = box.children.keys()[if (data.items.len > 0) 1 else 0];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });
        outer.getFocus().child_id = outer.children.keys()[outer.children.count() - 1];
        return .{ .box = outer, .data = data, .session = session };
    }

    fn addText(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: ?[]const u8, border: wgt.Border) !void {
        var row = try wgt.TextBox.init(allocator, text, .{ .border = border, .round_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link) |value| row.getFocus().kind = .{ .custom = value };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    // a labeled box, added as the selected action needs it
    fn addLabeled(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, text: []const u8, link: ?[]const u8) !void {
        try addText(allocator, box, text, link, .single);
        box.children.values()[box.children.count() - 1].widget.text_box.options.top_label.text = label;
    }

    // the terminal hosts run the action after rendering; the web renderer
    // posts the form instead, and wasm has no repository to act on
    fn requestUndo(self: *View, route: ui.RoutablePage) void {
        if (builtin.target.cpu.arch == .wasm32) return;
        if (!self.session.is_terminal or self.session.host_request != null) return;
        self.session.host_request = .{ .undo = route.repo_undo };
    }

    fn header(self: *View) ?*ui.widget.CopyableText {
        return switch (self.box.children.values()[header_index].widget) {
            .header_scroll => |*header_scroll| &header_scroll.row().children.values()[0].widget.copyable_text,
            else => null,
        };
    }
    fn headerActive(self: *View) bool {
        if (self.header() == null) return false;
        return self.box.getFocus().child_id == self.box.children.keys()[header_index];
    }
    // the content is last, below the sub header where there is one
    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[self.box.children.count() - 1].widget.box;
    }
    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[0].widget.scroll;
    }
    fn detailFrame(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[1].widget.box;
    }
    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.detailFrame().children.values()[ui.widget.list_pane_index].widget.scroll;
    }
    fn selected(self: *View) ?usize {
        const rows = &self.listScroll().child.box;
        const index = rows.children.getIndex(rows.getFocus().child_id orelse return null) orelse return null;
        return if (index < self.data.items.len) index else null;
    }
    fn detailActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.detailFrame().getFocus().id;
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const index = self.selected() orelse return;
        const failure = self.session.data.undo_failure orelse self.data.failure;
        if (self.detailed_index == index and std.meta.eql(self.shown_failure, failure)) return;
        const details = &self.detailScroll().child.box;
        while (details.children.count() > fixed_rows) {
            var entry = details.children.pop() orelse break;
            entry.value.widget.deinit(allocator);
        }
        const item = self.data.items[index];
        const enabled = self.data.handle.canUndo() and item.index > 0;

        // the fixed rows are filled first, since adding the ones below
        // invalidates every pointer into the box
        {
            const button = &details.children.values()[0].widget.text_box;
            try button.setContent(allocator, if (item.index == 0) "initial state cannot be undone" else if (item.index == self.data.count - 1) "undo this" else "undo this and all above it");
            button.getFocus().kind = if (enabled) .{ .custom = "submit" } else .text_box;
        }
        const timestamp = try ui.timestamp.format(self.session.page_arena.allocator(), item.timestamp, try self.session.nowSeconds());
        try details.children.values()[1].widget.text_box.setContent(allocator, timestamp.relative);
        details.children.values()[1].widget.text_box.options.bottom_label.text = timestamp.exact;

        // some actions put buttons where the description would go
        if (item.buttons.len == 0) {
            try addLabeled(allocator, details, " description ", item.description, null);
        } else for (item.buttons) |detail_button| {
            try addLabeled(allocator, details, detail_button.label, detail_button.text, detail_button.link);
        }
        if (failure) |message| try addText(allocator, details, try self.session.page_arena.allocator().print("error: {s}", .{message}), null, .single);
        self.shown_failure = failure;
        details.getFocus().kind = if (enabled) .{ .custom = item.form } else .container;
        details.getFocus().child_id = details.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        ui.widget.setListBackLink(self.detailFrame(), item.link);
        self.detailed_index = index;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // the empty message stands in for the list
        if (self.data.isEmpty(self.session)) return try self.box.build(allocator, constraint, root_focus);
        try self.refreshDetail(allocator);
        const rows = &self.listScroll().child.box;
        if (self.data.items.len == 0) {
            // an empty list only shows to report its failure
            const failure = self.session.data.undo_failure orelse self.data.failure orelse unreachable;
            if (!std.meta.eql(self.shown_failure, failure)) {
                try rows.children.values()[0].widget.text_box.setContent(allocator, try self.session.page_arena.allocator().print("error: {s}", .{failure}));
                self.shown_failure = failure;
            }
        }
        for (rows.children.keys(), rows.children.values()) |id, *child| ui.widget.markSelected(&child.widget.text_box, rows.getFocus().child_id == id);
        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        ui.widget.showListBack(self.detailFrame(), !both_fit);
        self.contentBox().children.values()[0].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const width = if (constraint.max_size.width) |value| if (both_fit) value - list_max_width else value else detail_min_width;
        self.contentBox().children.values()[1].min_size = .{ .width = width, .height = null };
        for (self.detailScroll().child.box.children.values()) |*child| child.max_size = .{ .width = width -| 2, .height = null };
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // scrolling crosses the sub header boundary the same way the arrow keys do
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            // active means there is one
            const copyable_text = self.header() orelse unreachable;
            if (direction == .down) {
                // the empty message has nothing to focus
                if (!self.data.isEmpty(self.session)) root_focus.setFocus(self.contentBox().getFocus().id);
                return;
            }
            return copyable_text.input(allocator, key, root_focus);
        }
        // the empty message has nothing to focus
        if (self.data.isEmpty(self.session)) return;
        // the way back to the list, by enter or a click
        if (self.detailActive()) if (ui.widget.listBackId(self.detailFrame())) |id| {
            if (inp.activated(root_focus, id, key)) return self.focusList(root_focus);
            if (root_focus.grandchild_id == id) return switch (direction) {
                // without a sub header, atTop hands it to the page's tabs
                .up => _ = self.focusHeader(root_focus),
                .down => root_focus.setFocus(self.detailScroll().getFocus().id),
                .none => if (key == .arrow_left) self.focusList(root_focus),
            };
            if (direction == .up and self.contentAtTop()) return root_focus.setFocus(id);
        };
        if (direction == .up and self.contentAtTop() and self.focusHeader(root_focus)) return;
        try self.refreshDetail(allocator);
        if (self.detailActive()) {
            const details = &self.detailScroll().child.box;
            if (self.selected()) |index| {
                if (inp.activated(root_focus, details.children.keys()[0], key) and self.data.handle.canUndo() and self.data.items[index].index > 0) {
                    self.requestUndo(ui.RoutablePage.repoUndoRoute(self.data.identity, self.data.items[index].index) orelse return error.RouteTooLong);
                    return;
                }
            }
            if (inp.rowDelta(key, @intCast(details.children.count()))) |delta| {
                ui.widget.moveRowFocus(details, self.detailScroll(), root_focus, delta);
            } else if (key == .arrow_left) {
                self.focusList(root_focus);
            }
        } else if (inp.rowDelta(key, @intCast(self.listScroll().child.box.children.count()))) |delta| {
            ui.widget.moveRowFocus(&self.listScroll().child.box, self.listScroll(), root_focus, delta);
        } else switch (key) {
            .arrow_right, .enter => if (self.selected() != null) self.focusDetail(root_focus),
            // when the window is too narrow to lay out the detail pane beside
            // the list, a click on a row opens it like enter. the detail was
            // swapped to the just-selected row above.
            .mouse => |mouse| if (self.selected() != null and self.contentBox().children.values()[1].rect == null and ui.widget.clickOnSelectedRow(&self.listScroll().child.box, root_focus, mouse)) {
                self.focusDetail(root_focus);
            },
            else => {},
        }
    }

    // enter the detail pane, landing on the way back to the list when it shows
    fn focusDetail(self: *View, root_focus: *Focus) void {
        if (ui.widget.listBackId(self.detailFrame()) != null) return ui.widget.focusListBack(self.detailFrame(), root_focus);
        root_focus.setFocus(self.detailScroll().getFocus().id);
    }

    fn focusList(self: *View, root_focus: *Focus) void {
        root_focus.setFocus(self.listScroll().getFocus().id);
    }

    fn contentAtTop(self: *View) bool {
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const rows = &scroll.child.box;
        const id = rows.getFocus().child_id orelse return true;
        return rows.children.getIndex(id) == 0 and scroll.y == 0;
    }

    // moving up from the sub header returns to the page's tabs, as does moving
    // up from the top of the content where there is no sub header
    pub fn atTop(self: *View) bool {
        if (self.header() != null) return self.headerActive();
        if (self.data.isEmpty(self.session)) return true;
        // the way back to the list sits above the detail while it shows
        if (self.detailActive()) if (ui.widget.listBackId(self.detailFrame())) |id| return self.detailFrame().getFocus().child_id == id;
        return self.contentAtTop();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        const copyable_text = self.header() orelse return false;
        root_focus.setFocus(copyable_text.getFocus().id);
        return true;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
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
};

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
    timestamp: []const u8,
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
can_undo: bool = false,
// the clear-history confirmation stands in for the list
clear: bool = false,

pub fn init(comptime opts: rp.RepoOpts(.xit), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(.xit, opts), haxy_moment: ?evt.AdminDB.HashMap(.read_only), identity: []const u8, selected: ?u64) !Self {
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
            .timestamp = if (record) |value| try formatTimestamp(aa, value.timestamp) else "timestamp unavailable",
            .link = try std.fmt.allocPrint(aa, "ai:{s}", .{url}),
            .form = try std.fmt.allocPrint(aa, "form:{s}/undo", .{url}),
            .undone = row_undone,
        });
    }
    return .{ .identity = try aa.dupe(u8, identity), .count = count, .items = items.items, .next = if (remaining > 0) remaining - 1 else null };
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
        .action = try std.fmt.allocPrint(aa, "events ({d})", .{count}),
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
        .link = try std.fmt.allocPrint(arena.allocator(), "a:{s}", .{try route.toUrl(arena)}),
    };
}

// the page reads the transaction's own moment, so the url names the
// transaction rather than the state it produced
fn eventsButton(arena: *std.heap.ArenaAllocator, identity: []const u8, history_index: u64, count: u64) !DetailButton {
    const aa = arena.allocator();
    const route = ui.RoutablePage.repoEventsRoute(identity, .active, null, "", history_index) orelse return error.RouteTooLong;
    return .{
        .label = " events ",
        .text = try std.fmt.allocPrint(aa, "view events ({d})", .{count}),
        .link = try std.fmt.allocPrint(aa, "a:{s}", .{try route.toUrl(arena)}),
    };
}

// a button per ref the push moved, naming what it did to it: a changed branch
// links to the commits it added, anything still there to the ref itself
fn pushRefs(arena: *std.heap.ArenaAllocator, identity: []const u8, payload: []const u8, buttons: *std.ArrayList(DetailButton)) !void {
    const head_prefix = "refs/heads/";
    const tag_prefix = "refs/tags/";
    const Payload = struct {
        const Ref = struct { name: []const u8, old: []const u8, new: []const u8 };
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
        const route = if (removed)
            null
        else if (head and !created)
            ui.RoutablePage.repoCommitsRoute(identity, .object, ref.new, 0, "", ref.old) orelse continue
        else
            ui.RoutablePage.repoFilesRoute(identity, if (head) .branch else .tag, try ui.urlEncodeRef(aa, name), "", 0) orelse continue;

        const action = if (removed) "removed" else if (created) "created" else "changed";
        try buttons.append(aa, .{
            .label = try std.fmt.allocPrint(aa, " {s} {s} ", .{ if (head) "branch" else "tag", action }),
            .text = try aa.dupe(u8, name),
            .link = if (route) |value| try std.fmt.allocPrint(aa, "a:{s}", .{try value.toUrl(arena)}) else null,
        });
    }
}

// the push record stores the email of the user whose key the server accepted.
// resolving it names them as they are now, and leaves the email when no user
// holds it, which is also what local mode sees with no admin db to read
fn pushUser(arena: *std.heap.ArenaAllocator, haxy_moment: ?evt.AdminDB.HashMap(.read_only), payload: []const u8) !?DetailButton {
    const Payload = struct { author: ?struct { email: []const u8 } = null };
    const parsed = std.json.parseFromSlice(Payload, arena.child_allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    const author = parsed.value.author orelse return null;
    return switch (try ui.Author.initFromEmail(haxy_moment, arena, author.email)) {
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

pub fn formatTimestamp(aa: std.mem.Allocator, timestamp: i64) ![]const u8 {
    if (timestamp < 0) return aa.dupe(u8, "timestamp unavailable");
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(aa, "{s} {d}, {d}, {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ months[month.month.numeric() - 1], month.day_index + 1, year.year, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, index: u64) !void {
    if (source.repo_kind != .xit) return error.NotFound;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| try repo.undo(io, index),
    }
}

// discard every earlier transaction by compacting the database. the patch
// revisions events point at are unreachable from the refs, so they are named
// as extra roots to survive the collection.
pub fn clearHistory(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !void {
    if (source.repo_kind != .xit) return error.NotFound;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| {
            const opts = repo.self_repo_opts;
            // a repo that has consumed no events has no revisions to protect
            const roots = if (evt.currentMoment(opts, repo)) |moment|
                try evt.PatchRev.gcRoots(rp.Repo(.xit, opts).DB, opts.hash, allocator, moment)
            else |_|
                &.{};
            defer allocator.free(roots);
            _ = try repo.garbageCollect(io, allocator, .{ .extra_roots = roots });
        },
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
    const index = if (target.clear) null else target.index orelse return error.InvalidHistoryIndex;
    const source = try authorizedSource(session, identity) orelse return error.Forbidden;
    const io = session.io orelse return error.NotFound;
    if (index) |value| try execute(io, allocator, source, value) else try clearHistory(io, allocator, source);
    try session.navigate(ui.RoutablePage.repoUndoRoute(identity, null) orelse return error.RouteTooLong);
}

// the repo an owner may act on, or null when they may not
fn authorizedSource(session: *ui.Session, identity: []const u8) !?ui.RepoSource {
    if (try session.authorize(identity, .owner) == null) return null;
    if (session.local) |local| return local;
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
    const pair = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const found = try evt.Repo.readByOwnerAndName(evt.AdminDB, evt.admin_repo_opts.hash, moment, session.page_arena, pair.owner, pair.name) orelse return error.NotFound;
    const hex = std.fmt.bytesToHex(found.event_id, .lower);
    return .{ .path = try std.fs.path.join(session.page_arena.allocator(), &.{ session.repos_dir orelse return error.NotFound, &hex }), .repo_kind = .xit };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: ?usize = null,
    shown_failure: ?[]const u8 = null,

    const list_max_width = 20;
    const detail_min_width = 40;
    const header_index = 0;
    const content_index = 1;
    // the undo button and the timestamp; everything below them is rebuilt
    const fixed_rows = 2;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        // the sub header carries the tab's only action
        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer header.deinit(allocator);
            const route = ui.RoutablePage.repoUndoClearRoute(data.identity) orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)});
            try addText(allocator, &header, "clear undo history", link, .single);
            header.getFocus().child_id = header.children.keys()[0];
            // a row taller than the header, leaving a blank line beneath it
            try outer.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = .{ .width = null, .height = 4 } });
        }

        if (data.clear) {
            var center = try initClearForm(allocator, data, session);
            errdefer center.deinit(allocator);
            try outer.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
            outer.getFocus().child_id = outer.children.keys()[content_index];
            return .{ .box = outer, .data = data, .session = session };
        }

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        {
            var scroll = blk: {
                var rows = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
                errdefer rows.deinit(allocator);
                for (data.items) |item| {
                    try addText(allocator, &rows, item.action, item.link, .hidden);
                    // a transaction a later undo discarded says so on its border
                    if (item.undone) rows.children.values()[rows.children.count() - 1].widget.text_box.options.bottom_label = "(undone)";
                }
                if (data.next) |next| {
                    const route = ui.RoutablePage.repoUndoRoute(data.identity, next) orelse return error.RouteTooLong;
                    try addText(allocator, &rows, "next →", try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}), .hidden);
                }
                if (data.items.len == 0) try addText(allocator, &rows, "no undo history", null, .hidden);
                rows.getFocus().child_id = rows.children.keys()[0];
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = rows }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
        }
        {
            var scroll = blk: {
                var details = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer details.deinit(allocator);
                if (data.items.len > 0) {
                    try addText(allocator, &details, "", null, .single);
                    try addLabeled(allocator, &details, " timestamp ", "", null);
                    details.getFocus().child_id = details.children.keys()[0];
                }
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .box = details }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            scroll.getFocus().mode = .mouse;
            try box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
        }
        box.getFocus().child_id = box.children.keys()[0];
        try outer.children.put(allocator, box.getFocus().id, .{ .widget = .{ .box = box }, .rect = null, .min_size = null });
        outer.getFocus().child_id = outer.children.keys()[content_index];
        return .{ .box = outer, .data = data, .session = session };
    }

    // the same shape the thread views use to confirm a removal
    fn initClearForm(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !ui.widget.Center {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .round_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoUndoClearRoute(data.identity) orelse return error.RouteTooLong;
        box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "form:{s}", .{try route.toUrl(session.page_arena)}) };

        var prompt = try wgt.Text.init(allocator, "are you sure?");
        errdefer prompt.deinit(allocator);
        try box.children.put(allocator, prompt.getFocus().id, .{ .widget = .{ .text = prompt }, .rect = null, .min_size = null });

        var button = try wgt.TextBox.init(allocator, "clear undo history", .{ .border_style = .single, .round_corners = true, .wrap_kind = .none });
        errdefer button.deinit(allocator);
        button.getFocus().mode = .all;
        button.getFocus().kind = if (data.can_undo) .{ .custom = "submit" } else .text_box;
        try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
        box.getFocus().child_id = button.getFocus().id;

        return ui.widget.Center.init(allocator, .{ .box = box });
    }

    fn addText(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: ?[]const u8, border: wgt.BorderStyle) !void {
        var row = try wgt.TextBox.init(allocator, text, .{ .border_style = border, .round_corners = true, .wrap_kind = .word });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        if (link) |value| row.getFocus().kind = .{ .custom = value };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    // a labeled row below the timestamp, added as the selected action needs it
    fn addLabeled(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), label: []const u8, text: []const u8, link: ?[]const u8) !void {
        try addText(allocator, box, text, link, .single);
        box.children.values()[box.children.count() - 1].widget.text_box.options.label = label;
    }

    // enter counts only on the focused button; a click counts anywhere on it
    fn activated(root_focus: *Focus, button_id: usize, key: Key) bool {
        return switch (key) {
            .enter => root_focus.grandchild_id == button_id,
            .mouse => |mouse| inp.leftClickOn(root_focus, button_id, mouse),
            else => false,
        };
    }

    // the terminal hosts run the action after rendering; the web renderer
    // posts the form instead, and wasm has no repository to act on
    fn requestUndo(self: *View, route: ui.RoutablePage) void {
        if (builtin.target.cpu.arch == .wasm32) return;
        if (!self.session.is_terminal or self.session.host_request != null) return;
        self.session.host_request = .{ .undo = route.repo_undo };
    }

    fn headerBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[header_index].widget.box;
    }
    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.headerBox().getFocus().id;
    }
    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[content_index].widget.box;
    }
    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[0].widget.scroll;
    }
    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.contentBox().children.values()[1].widget.scroll;
    }
    fn selected(self: *View) ?usize {
        const rows = &self.listScroll().child.box;
        const index = rows.children.getIndex(rows.getFocus().child_id orelse return null) orelse return null;
        return if (index < self.data.items.len) index else null;
    }
    fn detailActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.detailScroll().getFocus().id;
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
        const enabled = self.data.can_undo and item.index > 0;

        // the fixed rows are filled first, since adding the ones below
        // invalidates every pointer into the box
        {
            const button = &details.children.values()[0].widget.text_box;
            try button.setContent(allocator, if (item.index == 0) "initial state cannot be undone" else if (item.index == self.data.count - 1) "undo this" else "undo this and all above it");
            button.getFocus().kind = if (enabled) .{ .custom = "submit" } else .text_box;
        }
        try details.children.values()[1].widget.text_box.setContent(allocator, item.timestamp);

        // some actions put buttons where the description would go
        if (item.buttons.len == 0) {
            try addLabeled(allocator, details, " description ", item.description, null);
        } else for (item.buttons) |detail_button| {
            try addLabeled(allocator, details, detail_button.label, detail_button.text, detail_button.link);
        }
        if (failure) |message| try addText(allocator, details, try std.fmt.allocPrint(self.session.page_arena.allocator(), "error: {s}", .{message}), null, .single);
        self.shown_failure = failure;
        details.getFocus().kind = if (enabled) .{ .custom = item.form } else .container;
        details.getFocus().child_id = details.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        self.detailed_index = index;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        if (self.data.clear) return try self.box.build(allocator, constraint, root_focus);
        try self.refreshDetail(allocator);
        const rows = &self.listScroll().child.box;
        if (self.data.items.len == 0) {
            const failure = self.session.data.undo_failure orelse self.data.failure;
            if (!std.meta.eql(self.shown_failure, failure)) {
                const message = if (failure) |name| try std.fmt.allocPrint(self.session.page_arena.allocator(), "error: {s}", .{name}) else "no undo history";
                try rows.children.values()[0].widget.text_box.setContent(allocator, message);
                self.shown_failure = failure;
            }
        }
        for (rows.children.keys(), rows.children.values()) |id, *child| ui.widget.markSelected(&child.widget.text_box, rows.getFocus().child_id == id);
        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        self.contentBox().children.values()[0].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const width = if (constraint.max_size.width) |value| if (both_fit) value - list_max_width else value else detail_min_width;
        self.contentBox().children.values()[1].min_size = .{ .width = width, .height = null };
        for (self.detailScroll().child.box.children.values()) |*child| child.max_size = .{ .width = width -| 2, .height = null };
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the sub header sits above whichever content the route selects.
        // scrolling crosses the boundary the same way the arrow keys do
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            if (direction == .down) root_focus.setFocus(self.box.children.values()[content_index].widget.getFocus().id);
            return;
        }
        if (self.data.clear) {
            if (direction == .up) root_focus.setFocus(self.headerBox().getFocus().id) else try self.clearInput(key, root_focus);
            return;
        }
        if (direction == .up and self.contentAtTop()) {
            root_focus.setFocus(self.headerBox().getFocus().id);
            return;
        }
        try self.refreshDetail(allocator);
        if (self.detailActive()) {
            const details = &self.detailScroll().child.box;
            if (self.selected()) |index| {
                if (activated(root_focus, details.children.keys()[0], key) and self.data.can_undo and self.data.items[index].index > 0) {
                    self.requestUndo(ui.RoutablePage.repoUndoRoute(self.data.identity, self.data.items[index].index) orelse return error.RouteTooLong);
                    return;
                }
            }
            if (key == .arrow_left) root_focus.setFocus(self.listScroll().getFocus().id) else if (inp.rowDelta(key, @intCast(details.children.count()))) |delta| ui.widget.moveRowFocus(details, self.detailScroll(), root_focus, delta);
        } else if (inp.rowDelta(key, @intCast(self.listScroll().child.box.children.count()))) |delta| {
            ui.widget.moveRowFocus(&self.listScroll().child.box, self.listScroll(), root_focus, delta);
        } else switch (key) {
            .arrow_right, .enter => if (self.selected() != null) {
                root_focus.setFocus(self.detailScroll().getFocus().id);
            },
            else => {},
        }
    }

    // the confirm button submits the form the web renderer posts
    fn clearInput(self: *View, key: Key, root_focus: *Focus) !void {
        const center = &self.box.children.values()[content_index].widget.center;
        const button_id = center.child.box.getFocus().child_id orelse return;
        if (!activated(root_focus, button_id, key) or !self.data.can_undo) return;
        self.requestUndo(ui.RoutablePage.repoUndoClearRoute(self.data.identity) orelse return error.RouteTooLong);
    }

    fn contentAtTop(self: *View) bool {
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const rows = &scroll.child.box;
        const id = rows.getFocus().child_id orelse return true;
        return rows.children.getIndex(id) == 0 and scroll.y == 0;
    }

    // moving up from the sub header returns to the page's tabs
    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        root_focus.setFocus(self.headerBox().getFocus().id);
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

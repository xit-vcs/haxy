const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const Threads = @import("Threads.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

// how much of a description the detail pane shows before linking to the
// /description page, the same limit commit messages use.
pub const max_description_size = 2 * 1024;

// how many discussions one window shows before a "next" link appears.
pub const page_size = 20;

// how many tags the tags view shows at most.
pub const max_tags = 1000;

// one discussion from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const DiscussionWithId = struct {
    id: []const u8,
    record: evt.Discussion.Record,
    author: ui.Author = .unknown,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
};

pub const Entry = DiscussionWithId;

pub const Window = struct {
    items: []const DiscussionWithId,
    prev_id: ?[]const u8,
    next_id: ?[]const u8,
    count: usize,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

identity: []const u8,
tag: []const u8,
selected_id: []const u8,
comment_id: []const u8,
comments_start: usize,
comment_page: ?Comment.Permalink = null,
all: Window,
view: ui.RoutablePage.DiscussionsView,
description_page: bool = false,
tags: []const []const u8,
repo_source: ?ui.RepoSource = null,

const Self = @This();

pub const Event = evt.Discussion;
pub const Status = enum { all };
pub const ViewKind = ui.RoutablePage.DiscussionsView;

pub fn selectedThread(self: *const Self) ?*const DiscussionWithId {
    if (self.selected_id.len == 0) return null;
    for (self.all.items) |*entry| {
        if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
    }
    return null;
}

pub fn window(self: *const Self, _: Status) *const Window {
    return &self.all;
}

pub fn emptyResult(
    aa: std.mem.Allocator,
    identity: []const u8,
    tag: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .all = .empty,
        .view = if (view == .description) .all else view,
        .description_page = view == .description,
        .tags = &.{},
    };
}

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    tag: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, selected_id, comment_id, comments_start, view);
    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const rooted = empty.selected_id.len != 0;
    const tagged = empty.tag.len != 0;
    const strict = rooted or tagged;

    const gpa = arena.child_allocator;
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return empty
    else
        evt.currentMoment(repo_opts, repo)) catch {
        if (strict) return error.NotFound;
        return empty;
    };

    const set_maybe: ?DB.SortedSet(.read_only) = if (tagged) blk: {
        const tags_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Discussion.tag_to_id_set_key)) orelse return error.NotFound;
        const tag_sets = try DB.SortedMap(.read_only).init(tags_cursor);
        const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, empty.tag));
        const cursor = try tag_sets.getCursor(decoded) orelse return error.NotFound;
        break :blk try DB.SortedSet(.read_only).init(cursor);
    } else if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Discussion.active_id_set_key))) |cursor|
        try DB.SortedSet(.read_only).init(cursor)
    else
        null;

    const records_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Discussion.record_map_key)) orelse {
        if (strict) return error.NotFound;
        return empty;
    };
    const records = try DB.HashMap(.read_only).init(records_cursor);

    var root_key: ?[]const u8 = null;
    if (rooted) {
        if (empty.selected_id.len != evt.event_id_size * 2) return error.NotFound;
        var id: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, empty.selected_id) catch return error.NotFound;
        const record_cursor = try records.getCursor(hash.hashInt(repo_opts.hash, &id)) orelse return error.NotFound;
        const record = try evt.read(evt.Discussion.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(record_cursor));
        if (record.removed) return error.NotFound;
        const order_key = try aa.dupe(u8, &evt.orderKeyDesc(record.created_ts, &id));
        const set = set_maybe orelse return error.NotFound;
        if (!try set.contains(order_key)) return error.NotFound;
        root_key = order_key;
    }

    const discussion_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const loaded_window = try loadWindow(repo_opts.hash, arena, admin_moment, haxy_moment, records, set_maybe, root_key, empty.selected_id, discussion_comments_start);
    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start);

    var tag_names: std.ArrayList([]const u8) = .empty;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.Discussion.tag_to_id_set_key))) |tags_cursor| {
        const tag_sets = try DB.SortedMap(.read_only).init(tags_cursor);
        var tag_iter = try tag_sets.iterator();
        while (try tag_iter.next()) |entry_cursor| {
            if (tag_names.items.len == max_tags) break;
            var entry = entry_cursor;
            const pair = try entry.readKeyValuePair();
            try tag_names.append(aa, try pair.key_cursor.readBytesAlloc(aa, null));
        }
    }

    return .{
        .identity = empty.identity,
        .tag = empty.tag,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .all = loaded_window,
        .view = empty.view,
        .description_page = empty.description_page,
        .tags = tag_names.items,
    };
}

fn loadWindow(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    records: evt.EventDB(hash_kind).HashMap(.read_only),
    set_maybe: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    root_key: ?[]const u8,
    selected_id: []const u8,
    comments_start: usize,
) !Window {
    const set = set_maybe orelse return .empty;
    const DB = evt.EventDB(hash_kind);
    const aa = arena.allocator();

    var prev_id: ?[]const u8 = null;
    var iter = if (root_key) |key| blk: {
        const rank = try set.rank(key);
        if (rank > 0 and rank <= page_size) {
            prev_id = "";
        } else if (rank > page_size) {
            const pair = try set.getIndexKeyValuePair(@intCast(rank - page_size)) orelse return error.NotFound;
            var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try pair.key_cursor.readBytes(&order_key);
            const hex = std.fmt.bytesToHex(order_key[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &hex);
        }
        break :blk try set.iteratorFrom(key);
    } else try set.iteratorFromIndex(0);

    var discussions: std.ArrayList(DiscussionWithId) = .empty;
    var next_id: ?[]const u8 = null;
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(DB, cursor);
        const id_hex = std.fmt.bytesToHex(id, .lower);
        if (discussions.items.len == page_size) {
            next_id = try aa.dupe(u8, &id_hex);
            break;
        }
        const record_cursor = try records.getCursor(hash.hashInt(hash_kind, &id)) orelse continue;
        const record = try evt.read(evt.Discussion.Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
        try discussions.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .record = record,
            .author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email),
            .comments = try Comment.loadWindow(
                hash_kind,
                arena,
                admin_moment,
                haxy_moment,
                evt.Comment.thread_id_to_comment_id_set_key,
                &id_hex,
                if (std.mem.eql(u8, &id_hex, selected_id)) comments_start else 0,
            ),
            .attachments = try Attachment.load(hash_kind, arena, haxy_moment, &id_hex),
        });
    }

    return .{
        .items = discussions.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}
pub const View = Threads.View(.discussion, Self);

// tabs switching between the discussions page's views.
pub const Header = struct {
    box: wgt.Box(ui.Widget),
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, void),

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        var tab_ids: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
        errdefer tab_ids.deinit(allocator);

        const aa = session.page_arena.allocator();

        // all discussions
        {
            const route = ui.RoutablePage.repoDiscussionsRoute(data.identity, data.tag, "") orelse return error.RouteTooLong;
            const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
            const label = try std.fmt.allocPrint(aa, "all ({d})", .{data.all.count});
            try addTab(allocator, &box, &tab_ids, label, link);
        }

        // tags tab, labeled with the active tag filter
        {
            const tags_route = ui.RoutablePage.repoThreadTagsRoute(.discussion, data.identity, data.tag) orelse return error.RouteTooLong;
            const tags_link = try std.fmt.allocPrint(aa, "ai:{s}", .{try tags_route.toUrl(session.page_arena)});
            const label = if (data.tag.len == 0) "tags" else blk: {
                const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
                break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
            };
            try addTab(allocator, &box, &tab_ids, label, tags_link);
        }

        // new-discussion tab; an edit or comment url shows its tab in this place
        {
            const route = switch (data.view) {
                .edit => ui.RoutablePage.repoThreadEditRoute(.discussion, data.identity, data.selected_id) orelse return error.RouteTooLong,
                .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.discussion, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.discussion, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                .remove => ui.RoutablePage.repoThreadRemoveRoute(.discussion, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
                else => ui.RoutablePage.repoThreadNewRoute(.discussion, data.identity) orelse return error.RouteTooLong,
            };
            const link = try std.fmt.allocPrint(aa, "ai:{s}", .{try route.toUrl(session.page_arena)});
            const label: []const u8 = switch (data.view) {
                .edit => "edit",
                .new_comment => "reply",
                .edit_comment => "edit",
                .remove => "remove",
                else => "new",
            };
            try addTab(allocator, &box, &tab_ids, label, link);
        }

        var self = Header{ .box = box, .tab_ids = tab_ids };
        // the tab matching the page's view is selected initially.
        self.getFocus().child_id = self.tab_ids.keys()[View.viewIndex(data.view)];
        return self;
    }

    fn addTab(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), tab_ids: *std.AutoArrayHashMapUnmanaged(usize, void), label: []const u8, link: []const u8) !void {
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = link };
        try tab_ids.put(allocator, text_box.getFocus().id, {});
        try box.children.put(allocator, text_box.getFocus().id, .{
            .widget = .{ .text_box = text_box },
            .rect = null,
            .min_size = .{ .width = label.len + 2, .height = null },
        });
    }

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        self.tab_ids.deinit(allocator);
    }

    pub fn build(self: *Header, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // only the selected tab shows its border
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (self.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *Header, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        if (inp.moveTab(key, current_tab, self.tab_ids.count())) |new_tab| {
            root_focus.setFocus(self.tab_ids.keys()[new_tab]);
        }
    }

    pub fn clearGrid(self: *Header) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Header) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Header) *Focus {
        return self.box.getFocus();
    }

    pub fn getSelectedIndex(self: Header) ?usize {
        return self.currentTabIndex();
    }

    fn currentTabIndex(self: Header) ?usize {
        const child_id = self.box.focus.child_id orelse return null;
        return self.tab_ids.getIndex(child_id);
    }
};

const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const thread = ui.widget.thread;

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
recent: Window,
view: ui.RoutablePage.DiscussionsView,
description_page: bool = false,
tags: []const []const u8,
repo_source: ?ui.RepoSource = null,

const Self = @This();

pub const Event = evt.Discussion;
pub const Status = enum { recent };
pub const ViewKind = ui.RoutablePage.DiscussionsView;
pub const thread_name = "discussion";
pub const header_widget_name = "repo_discussions_header";

pub fn listRoute(identity: []const u8, _: Status, tag: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoDiscussionsRoute(identity, tag, selected);
}

pub fn selectedThread(self: *const Self) ?*const DiscussionWithId {
    if (self.selected_id.len == 0) return null;
    for (self.recent.items) |*entry| {
        if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
    }
    return null;
}

pub fn window(self: *const Self, _: Status) *const Window {
    return &self.recent;
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
        .recent = .empty,
        .view = if (view == .description) .recent else view,
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
        const id = evt.parseEventId(empty.selected_id) catch return error.NotFound;
        const record_cursor = try records.getCursor(hash.hashInt(repo_opts.hash, &id)) orelse return error.NotFound;
        const record = try evt.read(evt.Discussion.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(record_cursor));
        if (record.removed) return error.NotFound;
        const activity_order = try evt.Discussion.activityOrder(DB, repo_opts.hash, haxy_moment, &id);
        const order_key = try aa.dupe(u8, &evt.orderKeyDesc(activity_order, &id));
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
        .recent = loaded_window,
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
pub const View = thread.View(.discuss, Self);
pub const Detail = thread.Detail(.discuss, Self);
pub const detail_widget_name = "repo_discussion_detail";

pub const Header = thread.Header;

// tabs switching between the discussions page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    var header = try Header.init(allocator);
    errdefer header.deinit(allocator);
    const aa = session.page_arena.allocator();
    const selected_index = View.viewIndex(data.view);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_discussions;

    // recent discussions
    {
        const route = ui.RoutablePage.repoDiscussionsRoute(data.identity, data.tag, "") orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == 0);
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "recent ({d})", .{data.recent.count});
        try header.addTab(allocator, label, link, 0);
    }

    // tags tab, labeled with the active tag filter
    {
        const tags_route = ui.RoutablePage.repoThreadTagsRoute(.discuss, data.identity, data.tag) orelse return error.RouteTooLong;
        const tags_link = try ui.inPageTabLink(session, tags_route, page_selected and selected_index == View.viewIndex(.tags));
        const label = if (data.tag.len == 0) "tags" else blk: {
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
            break :blk try std.fmt.allocPrint(aa, "tags ({s})", .{decoded});
        };
        try header.addTab(allocator, label, tags_link, View.viewIndex(.tags));
    }

    // new-discussion tab; an edit or comment url shows its tab in this place
    {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.discuss, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.discuss, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.discuss, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.discuss, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.discuss, data.identity) orelse return error.RouteTooLong,
        };
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.new));
        const label: []const u8 = switch (data.view) {
            .edit => "edit",
            .new_comment => "reply",
            .edit_comment => "edit",
            .remove => "remove",
            else => "new",
        };
        try header.addTab(allocator, label, link, View.viewIndex(.new));
    }

    header.select(View.viewIndex(data.view));
    return header;
}

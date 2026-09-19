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
    // whether a search stopped counting at its cap, so `count` is a floor.
    more: bool = false,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

identity: []const u8,
tag: []const u8,
// the decoded query the list is filtered to, or null when unfiltered.
search: ?[]const u8 = null,
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
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .tag = try aa.dupe(u8, tag),
        .search = if (search.len == 0) null else std.Uri.percentDecodeInPlace(try aa.dupe(u8, search)),
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
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
) !Self {
    const empty = try emptyResult(arena.allocator(), identity, tag, search, selected_id, comment_id, comments_start, view);
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
    const loaded_window = try thread.loadWindow(Self, .discuss, repo_opts.hash, arena, admin_moment, haxy_moment, records, set_maybe, root_key, null, empty.selected_id, discussion_comments_start, empty.search);
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
        .search = empty.search,
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

pub const View = thread.View(.discuss, Self);
pub const Detail = thread.Detail(.discuss, Self);
pub const detail_widget_name = "repo_discussion_detail";

pub const Header = thread.Header;

const recent_tab_label = "recent";
const tags_tab_label = "tags";
const edit_tab_label = "edit";
const reply_tab_label = "reply";
const remove_tab_label = "remove";
const new_tab_label = "new";

// tabs switching between the discussions page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    var header = try Header.init(allocator, session, data.search);
    errdefer header.deinit(allocator);
    const aa = session.page_arena.allocator();
    const selected_index = View.viewIndex(data.view);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_discussions;

    // recent discussions
    {
        const route = try thread.searchRoute(ui.RoutablePage.repoDiscussionsRoute(data.identity, data.tag, ""), data.search);
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == 0);
        var label_buf: [64]u8 = undefined;
        const label = try thread.countLabel(&label_buf, recent_tab_label, data.recent);
        try header.addTab(allocator, label, link, 0);
    }

    // tags tab, labeled with the active tag filter
    {
        const tags_route = try thread.searchRoute(ui.RoutablePage.repoThreadTagsRoute(.discuss, data.identity, data.tag), data.search);
        const tags_link = try ui.inPageTabLink(session, tags_route, page_selected and selected_index == View.viewIndex(.tags));
        const label = if (data.tag.len == 0) tags_tab_label else blk: {
            const decoded = std.Uri.percentDecodeInPlace(try aa.dupe(u8, data.tag));
            break :blk try std.fmt.allocPrint(aa, tags_tab_label ++ " ({s})", .{decoded});
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
            .edit => edit_tab_label,
            .new_comment => reply_tab_label,
            .edit_comment => edit_tab_label,
            .remove => remove_tab_label,
            else => new_tab_label,
        };
        try header.addTab(allocator, label, link, View.viewIndex(.new));
    }

    header.select(View.viewIndex(data.view));
    return header;
}

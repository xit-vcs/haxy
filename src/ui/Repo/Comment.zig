const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const page_size = 10;

pub const CommentWithId = struct {
    id: []const u8,
    comment: evt.Comment.Record,
    author: ui.Author = .unknown,
    parent_author: ?ui.Author = null,
};

pub const Window = struct {
    comments: []const CommentWithId,
    start: usize,
    count: usize,
    has_prev: bool,
    has_more: bool,

    pub const empty: Window = .{ .comments = &.{}, .start = 0, .count = 0, .has_prev = false, .has_more = false };
};

pub const Permalink = struct {
    thread_id: []const u8,
    selected: CommentWithId,
    replies: Window,
};

// read a comment permalink and one window of its immediate replies.
pub fn init(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    thread_id: []const u8,
    selected_id: []const u8,
    start: usize,
) !Permalink {
    const selected = (try readOne(hash_kind, arena, admin_moment, haxy_moment, selected_id)) orelse return error.NotFound;
    if (!std.mem.eql(u8, &selected.comment.event.thread_id, thread_id)) return error.NotFound;

    return .{
        .thread_id = try arena.allocator().dupe(u8, thread_id),
        .selected = selected,
        .replies = try loadWindow(hash_kind, arena, admin_moment, haxy_moment, evt.Comment.parent_id_to_comment_id_set_key, selected_id, start),
    };
}

// read one chronological comment window from an id-to-comment-set index.
pub fn loadWindow(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    index_key: []const u8,
    owner_id: []const u8,
    start: usize,
) !Window {
    const DB = evt.EventDB(hash_kind);
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, index_key)) orelse return .{
        .comments = &.{},
        .start = start,
        .count = 0,
        .has_prev = start > 0,
        .has_more = false,
    };
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const set_cursor = try index.getCursor(hash.hashInt(hash_kind, owner_id)) orelse return .{
        .comments = &.{},
        .start = start,
        .count = 0,
        .has_prev = start > 0,
        .has_more = false,
    };
    const set = try DB.SortedSet(.read_only).init(set_cursor);
    const count: usize = @intCast(try set.count());
    const end = @min(start + page_size, count);
    var iter = try set.iteratorFromIndex(start);
    var comments: std.ArrayList(CommentWithId) = .empty;
    var i = start;
    while (i < end) : (i += 1) {
        var cursor = (try iter.next()) orelse break;
        const kv = try cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try kv.key_cursor.readBytes(&order_key);
        const id_hex = std.fmt.bytesToHex(order_key[@sizeOf(u64)..].*, .lower);
        const entry = (try readOneBytes(hash_kind, arena, admin_moment, haxy_moment, order_key[@sizeOf(u64)..], &id_hex)) orelse continue;
        try comments.append(arena.allocator(), entry);
    }
    return .{
        .comments = comments.items,
        .start = start,
        .count = count,
        .has_prev = start > 0,
        .has_more = end < count,
    };
}

fn readOne(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id: []const u8,
) !?CommentWithId {
    const bytes = (try idBytes(id)) orelse return null;
    return readOneBytes(hash_kind, arena, admin_moment, haxy_moment, &bytes, id);
}

fn readOneBytes(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id_bytes: []const u8,
    id: []const u8,
) !?CommentWithId {
    const DB = evt.EventDB(hash_kind);
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Comment.record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id_bytes)) orelse return null;
    const record_map = try DB.HashMap(.read_only).init(record_cursor);
    const comment = try evt.read(evt.Comment.Record, DB, hash_kind, arena, record_map);
    const parent_author: ?ui.Author = if (!std.mem.eql(u8, &comment.event.parent_id, &comment.event.thread_id)) blk: {
        const parent_bytes = (try idBytes(&comment.event.parent_id)) orelse break :blk null;
        const parent_cursor = try records.getCursor(hash.hashInt(hash_kind, &parent_bytes)) orelse break :blk null;
        const parent_map = try DB.HashMap(.read_only).init(parent_cursor);
        const parent = try evt.read(evt.Comment.Record, DB, hash_kind, arena, parent_map);
        break :blk try ui.Author.initFromEmail(admin_moment, arena, parent.author_email);
    } else null;
    return .{
        .id = try arena.allocator().dupe(u8, id),
        .comment = comment,
        .author = try ui.Author.initFromEmail(admin_moment, arena, comment.author_email),
        .parent_author = parent_author,
    };
}

fn idBytes(id: []const u8) !?[evt.event_id_size]u8 {
    if (id.len != evt.event_id_size * 2) return null;
    var bytes: [evt.event_id_size]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, id) catch return null;
    if (!std.mem.eql(u8, id, &std.fmt.bytesToHex(bytes, .lower))) return null;
    return bytes;
}

pub const Item = struct {
    box: wgt.Box(ui.Widget),

    const metadata_index: usize = 0;
    const body_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8, entry: CommentWithId) !Item {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var bar = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer bar.deinit(allocator);

            var author = try ui.authorBox(allocator, session.page_arena, entry.author);
            errdefer author.deinit(allocator);
            try bar.children.put(allocator, author.getFocus().id, .{ .widget = .{ .text_box = author }, .rect = null, .min_size = null, .shrink = true });

            var reply = try linkBox(allocator, session, "new reply", ui.RoutablePage.repoCommentNewRoute(identity, &entry.comment.event.thread_id, entry.id) orelse return error.RouteTooLong);
            errdefer reply.deinit(allocator);
            try bar.children.put(allocator, reply.getFocus().id, .{ .widget = .{ .text_box = reply }, .rect = null, .min_size = .{ .width = "new reply".len + 2, .height = null } });

            var permalink = try linkBox(allocator, session, "permalink", ui.RoutablePage.repoCommentsRoute(identity, &entry.comment.event.thread_id, entry.id, 0) orelse return error.RouteTooLong);
            errdefer permalink.deinit(allocator);
            try bar.children.put(allocator, permalink.getFocus().id, .{ .widget = .{ .text_box = permalink }, .rect = null, .min_size = .{ .width = "permalink".len + 2, .height = null } });

            if (!std.mem.eql(u8, &entry.comment.event.parent_id, &entry.comment.event.thread_id)) {
                const parent_text = if (entry.parent_author) |parent_author| switch (parent_author) {
                    .unknown => "",
                    .email, .user_name => |text| text,
                } else "";
                var parent = try wgt.TextBox(ui.Widget).init(allocator, parent_text, .{
                    .border_style = .single,
                    .rounded_corners = true,
                    .wrap_kind = .none,
                    .label = " replying to ",
                });
                errdefer parent.deinit(allocator);
                parent.getFocus().focusable = true;
                const route = ui.RoutablePage.repoCommentsRoute(identity, &entry.comment.event.thread_id, &entry.comment.event.parent_id, 0) orelse return error.RouteTooLong;
                parent.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}) };
                try bar.children.put(allocator, parent.getFocus().id, .{ .widget = .{ .text_box = parent }, .rect = null, .min_size = .{ .width = @max(parent_text.len, " replying to ".len) + 2, .height = null } });
            }

            bar.getFocus().child_id = bar.children.keys()[0];
            try box.children.put(allocator, bar.getFocus().id, .{ .widget = .{ .box = bar }, .rect = null, .min_size = null });
        }

        const body_text = if (entry.comment.deleted) "(deleted)" else entry.comment.event.body;
        var body_box = try wgt.TextBox(ui.Widget).init(allocator, body_text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word });
        errdefer body_box.deinit(allocator);
        body_box.getFocus().focusable = true;
        try box.children.put(allocator, body_box.getFocus().id, .{ .widget = .{ .text_box = body_box }, .rect = null, .min_size = null });
        box.getFocus().child_id = box.children.keys()[metadata_index];

        return .{ .box = box };
    }

    fn metadata(self: *Item) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[metadata_index].widget.box;
    }

    fn body(self: *Item) *wgt.TextBox(ui.Widget) {
        return &self.box.children.values()[body_index].widget.text_box;
    }

    pub fn bodyFocused(self: *Item) bool {
        return self.box.getFocus().child_id == self.body().getFocus().id;
    }

    pub fn focusMetadata(self: *Item, root_focus: *Focus) void {
        const bar = self.metadata();
        root_focus.setFocus(bar.getFocus().child_id orelse bar.children.keys()[0]);
    }

    pub fn focusBody(self: *Item, root_focus: *Focus) void {
        root_focus.setFocus(self.body().getFocus().id);
    }

    pub fn moveHorizontal(self: *Item, root_focus: *Focus, right: bool) bool {
        if (self.bodyFocused()) return false;
        const bar = self.metadata();
        const selected = bar.getFocus().child_id orelse return false;
        const selected_index = bar.children.getIndex(selected) orelse return false;
        const target = if (right) selected_index + 1 else selected_index -| 1;
        if (target == selected_index or target >= bar.children.count()) return false;
        root_focus.setFocus(bar.children.keys()[target]);
        return true;
    }

    pub fn rowRect(self: *Item, body_row: bool) ?layout.IRect {
        return self.box.children.values()[if (body_row) body_index else metadata_index].rect;
    }

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *Item, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *Item, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try self.box.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *Item) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Item) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Item) *Focus {
        return self.box.getFocus();
    }
};

// append one comment's metadata bar and body.
pub fn appendComment(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, identity: []const u8, entry: CommentWithId) !void {
    var item = try Item.init(allocator, session, identity, entry);
    errdefer item.deinit(allocator);
    try box.children.put(allocator, item.getFocus().id, .{ .widget = .{ .repo_comment = item }, .rect = null, .min_size = null });
}

pub fn appendCount(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), count: usize, singular: []const u8, plural: []const u8, arena: std.mem.Allocator) !void {
    const text = try std.fmt.allocPrint(arena, "{d} {s}", .{ count, if (count == 1) singular else plural });
    var count_box = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .hidden, .wrap_kind = .none });
    errdefer count_box.deinit(allocator);
    try box.children.put(allocator, count_box.getFocus().id, .{ .widget = .{ .text_box = count_box }, .rect = null, .min_size = null });
}

pub fn appendWindowNav(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, identity: []const u8, thread_id: []const u8, selected_id: ?[]const u8, window: Window) !void {
    if (!window.has_prev and !window.has_more) return;
    var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer row.deinit(allocator);
    if (window.has_prev) {
        const start = window.start -| page_size;
        const route = if (selected_id) |id|
            ui.RoutablePage.repoCommentsRoute(identity, thread_id, id, start)
        else
            ui.RoutablePage.repoIssueCommentsRoute(identity, thread_id, start);
        var previous = try linkBox(allocator, session, "← previous", route orelse return error.RouteTooLong);
        errdefer previous.deinit(allocator);
        try row.children.put(allocator, previous.getFocus().id, .{ .widget = .{ .text_box = previous }, .rect = null, .min_size = null });
    }
    if (window.has_more) {
        const start = window.start + page_size;
        const route = if (selected_id) |id|
            ui.RoutablePage.repoCommentsRoute(identity, thread_id, id, start)
        else
            ui.RoutablePage.repoIssueCommentsRoute(identity, thread_id, start);
        var next = try linkBox(allocator, session, "next →", route orelse return error.RouteTooLong);
        errdefer next.deinit(allocator);
        try row.children.put(allocator, next.getFocus().id, .{ .widget = .{ .text_box = next }, .rect = null, .min_size = null });
    }
    row.getFocus().child_id = row.children.keys()[0];
    try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
}

pub fn linkBox(allocator: std.mem.Allocator, session: *ui.Session, text: []const u8, route: ui.RoutablePage) !wgt.TextBox(ui.Widget) {
    var box = try wgt.TextBox(ui.Widget).init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
    errdefer box.deinit(allocator);
    box.getFocus().focusable = true;
    box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}) };
    return box;
}

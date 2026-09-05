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
    id: [evt.event_id_size * 2]u8,
    comment: evt.Comment.Record,
    author: ui.Author = .unknown,
    parent_author: ?ui.Author = null,
};

pub const Window = struct {
    comments: []const CommentWithId,
    start: usize,
    count: usize,

    pub const empty: Window = .{ .comments = &.{}, .start = 0, .count = 0 };
};

pub const Permalink = struct {
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
    };
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const set_cursor = try index.getCursor(hash.hashInt(hash_kind, owner_id)) orelse return .{
        .comments = &.{},
        .start = start,
        .count = 0,
    };
    const set = try DB.SortedSet(.read_only).init(set_cursor);
    const count: usize = @intCast(try set.count());
    const end = start + @min(page_size, count -| start);
    var iter = try set.iteratorFromIndex(start);
    var comments: std.ArrayList(CommentWithId) = .empty;
    var i = start;
    while (i < end) : (i += 1) {
        var cursor = (try iter.next()) orelse break;
        const kv = try cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try kv.key_cursor.readBytes(&order_key);
        const id_bytes = order_key[@sizeOf(u64)..].*;
        const entry = (try readOneBytes(hash_kind, arena, admin_moment, haxy_moment, &id_bytes)) orelse continue;
        try comments.append(arena.allocator(), entry);
    }
    return .{
        .comments = comments.items,
        .start = start,
        .count = count,
    };
}

fn readOne(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id: []const u8,
) !?CommentWithId {
    const bytes = idBytes(id) orelse return null;
    return readOneBytes(hash_kind, arena, admin_moment, haxy_moment, &bytes);
}

fn readOneBytes(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id_bytes: *const [evt.event_id_size]u8,
) !?CommentWithId {
    const DB = evt.EventDB(hash_kind);
    const comment = (try evt.Comment.readById(DB, hash_kind, haxy_moment, arena, id_bytes)) orelse return null;
    const parent_author: ?ui.Author = if (!std.mem.eql(u8, &comment.event.parent_id, &comment.event.thread_id)) blk: {
        const parent_bytes = idBytes(&comment.event.parent_id) orelse break :blk null;
        const parent = (try evt.Comment.readById(DB, hash_kind, haxy_moment, arena, &parent_bytes)) orelse break :blk null;
        break :blk try ui.Author.initFromEmail(admin_moment, arena, parent.author_email);
    } else null;
    return .{
        .id = std.fmt.bytesToHex(id_bytes.*, .lower),
        .comment = comment,
        .author = try ui.Author.initFromEmail(admin_moment, arena, comment.author_email),
        .parent_author = parent_author,
    };
}

fn idBytes(id: []const u8) ?[evt.event_id_size]u8 {
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
    const gap_index: usize = 2;
    const metadata_first_link_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8, thread_kind: evt.EventKind, entry: CommentWithId) !Item {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var bar = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer bar.deinit(allocator);

            var spacer = try ui.widget.Spacer.init(allocator);
            errdefer spacer.deinit(allocator);
            try bar.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });

            var author = try ui.authorBox(allocator, session.page_arena, entry.author);
            errdefer author.deinit(allocator);
            try bar.children.put(allocator, author.getFocus().id, .{ .widget = .{ .text_box = author }, .rect = null, .min_size = null, .flex = .shrink });

            var reply = try linkBox(allocator, session, "new reply", commentNewRoute(thread_kind, identity, &entry.comment.event.thread_id, &entry.id) orelse return error.RouteTooLong);
            errdefer reply.deinit(allocator);
            try bar.children.put(allocator, reply.getFocus().id, .{ .widget = .{ .text_box = reply }, .rect = null, .min_size = .{ .width = "new reply".len + 2, .height = null } });

            if (!entry.comment.removed) {
                var edit = try linkBox(allocator, session, "edit comment", commentEditRoute(thread_kind, identity, &entry.comment.event.thread_id, &entry.id) orelse return error.RouteTooLong);
                errdefer edit.deinit(allocator);
                try bar.children.put(allocator, edit.getFocus().id, .{ .widget = .{ .text_box = edit }, .rect = null, .min_size = .{ .width = "edit comment".len + 2, .height = null } });
            }

            var permalink = try linkBox(allocator, session, "permalink", commentsRoute(thread_kind, identity, &entry.comment.event.thread_id, &entry.id, 0) orelse return error.RouteTooLong);
            errdefer permalink.deinit(allocator);
            try bar.children.put(allocator, permalink.getFocus().id, .{ .widget = .{ .text_box = permalink }, .rect = null, .min_size = .{ .width = "permalink".len + 2, .height = null } });

            if (!std.mem.eql(u8, &entry.comment.event.parent_id, &entry.comment.event.thread_id)) {
                const parent_text = if (entry.parent_author) |parent_author| switch (parent_author) {
                    .unknown => "",
                    .email, .user_name => |text| text,
                } else "";
                var parent = try wgt.TextBox.init(allocator, parent_text, .{
                    .border_style = .single,
                    .rounded_corners = true,
                    .wrap_kind = .none,
                    .label = " replying to ",
                });
                errdefer parent.deinit(allocator);
                parent.getFocus().mode = .all;
                const route = commentsRoute(thread_kind, identity, &entry.comment.event.thread_id, &entry.comment.event.parent_id, 0) orelse return error.RouteTooLong;
                parent.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}) };
                try bar.children.put(allocator, parent.getFocus().id, .{ .widget = .{ .text_box = parent }, .rect = null, .min_size = .{ .width = @max(parent_text.len, " replying to ".len) + 2, .height = null } });
            }

            if (!entry.comment.removed and (session.data.is_local or session.data.user_id != null)) {
                var remove = try linkBox(allocator, session, "✕", removeRoute(thread_kind, identity, &entry.comment.event.thread_id, &entry.id) orelse return error.RouteTooLong);
                errdefer remove.deinit(allocator);
                try bar.children.put(allocator, remove.getFocus().id, .{ .widget = .{ .text_box = remove }, .rect = null, .min_size = .{ .width = 3, .height = null } });
            }

            bar.getFocus().child_id = bar.children.keys()[metadata_first_link_index];
            try box.children.put(allocator, bar.getFocus().id, .{ .widget = .{ .box = bar }, .rect = null, .min_size = null });
        }

        const body_text = if (entry.comment.removed) "(removed)" else entry.comment.event.body;
        var body_box = try wgt.TextBox.init(allocator, body_text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word });
        errdefer body_box.deinit(allocator);
        body_box.getFocus().mode = .all;
        try box.children.put(allocator, body_box.getFocus().id, .{ .widget = .{ .text_box = body_box }, .rect = null, .min_size = null });

        var gap = try wgt.Text.init(allocator, "");
        errdefer gap.deinit(allocator);
        try box.children.put(allocator, gap.getFocus().id, .{ .widget = .{ .text = gap }, .rect = null, .min_size = null });

        box.getFocus().child_id = box.children.keys()[metadata_index];

        return .{ .box = box };
    }

    fn metadata(self: *Item) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[metadata_index].widget.box;
    }

    fn body(self: *Item) *wgt.TextBox {
        return &self.box.children.values()[body_index].widget.text_box;
    }

    pub fn bodyFocused(self: *Item) bool {
        return self.box.getFocus().child_id == self.body().getFocus().id;
    }

    pub fn focusMetadata(self: *Item, root_focus: *Focus) void {
        const bar = self.metadata();
        root_focus.setFocus(bar.getFocus().child_id orelse bar.children.keys()[metadata_first_link_index]);
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
        if (target < metadata_first_link_index or target >= bar.children.count()) return false;
        root_focus.setFocus(bar.children.keys()[target]);
        return true;
    }

    pub fn rowRect(self: *Item, body_row: bool) ?layout.IRect {
        if (!body_row) return self.box.children.values()[metadata_index].rect;
        var rect = self.box.children.values()[body_index].rect orelse return null;
        if (self.box.children.values()[gap_index].rect) |gap| rect.size.height += gap.size.height;
        return rect;
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
pub fn appendComment(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, identity: []const u8, thread_kind: evt.EventKind, entry: CommentWithId) !void {
    var item = try Item.init(allocator, session, identity, thread_kind, entry);
    errdefer item.deinit(allocator);
    try box.children.put(allocator, item.getFocus().id, .{ .widget = .{ .repo_comment = item }, .rect = null, .min_size = null });
}

pub fn appendCount(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), count: usize, singular: []const u8, plural: []const u8) !void {
    var text_buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{d} {s}", .{ count, if (count == 1) singular else plural });
    var count_box = try wgt.TextBox.init(allocator, text, .{ .border_style = .hidden, .wrap_kind = .none });
    errdefer count_box.deinit(allocator);
    try box.children.put(allocator, count_box.getFocus().id, .{ .widget = .{ .text_box = count_box }, .rect = null, .min_size = null });
}

pub fn appendWindowNav(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, identity: []const u8, thread_kind: evt.EventKind, thread_id: []const u8, selected_id: ?[]const u8, window: Window) !void {
    const has_prev = window.start > 0;
    const has_more = window.start < window.count and window.count - window.start > page_size;
    if (!has_prev and !has_more) return;
    var row = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer row.deinit(allocator);
    if (has_prev) {
        const start = window.start -| page_size;
        const route = commentsRoute(thread_kind, identity, thread_id, selected_id, start);
        var previous = try linkBox(allocator, session, "← previous", route orelse return error.RouteTooLong);
        errdefer previous.deinit(allocator);
        try row.children.put(allocator, previous.getFocus().id, .{ .widget = .{ .text_box = previous }, .rect = null, .min_size = null });
    }
    if (has_more) {
        const start = window.start + page_size;
        const route = commentsRoute(thread_kind, identity, thread_id, selected_id, start);
        var next = try linkBox(allocator, session, "next →", route orelse return error.RouteTooLong);
        errdefer next.deinit(allocator);
        try row.children.put(allocator, next.getFocus().id, .{ .widget = .{ .text_box = next }, .rect = null, .min_size = null });
    }
    row.getFocus().child_id = row.children.keys()[0];
    try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
}

fn commentsRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, selected_id: ?[]const u8, start: usize) ?ui.RoutablePage {
    return if (selected_id) |id|
        ui.RoutablePage.repoThreadCommentRoute(kind, identity, thread_id, id, start)
    else
        ui.RoutablePage.repoThreadCommentsRoute(kind, identity, thread_id, start);
}

fn commentNewRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, parent_id: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoThreadCommentNewRoute(kind, identity, thread_id, parent_id);
}

fn commentEditRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, comment_id: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoThreadCommentEditRoute(kind, identity, thread_id, comment_id);
}

fn removeRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, comment_id: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoThreadRemoveRoute(kind, identity, thread_id, comment_id);
}

pub fn linkBox(allocator: std.mem.Allocator, session: *ui.Session, text: []const u8, route: ui.RoutablePage) !wgt.TextBox {
    var box = try wgt.TextBox.init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
    errdefer box.deinit(allocator);
    box.getFocus().mode = .all;
    box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try route.toUrl(session.page_arena)}) };
    return box;
}

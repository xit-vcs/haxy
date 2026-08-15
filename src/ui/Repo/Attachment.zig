const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;

pub const WithId = struct {
    id: [evt.event_id_size * 2]u8,
    name: []const u8,
};

// every attachment on a parent event, oldest first. tombstoned ones are
// left out.
pub fn load(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    parent_id: []const u8,
) ![]const WithId {
    const DB = evt.EventDB(hash_kind);
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Attachment.parent_id_to_attachment_id_set_key)) orelse return &.{};
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const set_cursor = try index.getCursor(hash.hashInt(hash_kind, parent_id)) orelse return &.{};
    const set = try DB.SortedSet(.read_only).init(set_cursor);

    var attachments: std.ArrayList(WithId) = .empty;
    var iter = try set.iteratorFromIndex(0);
    while (try iter.next()) |cursor_val| {
        const id_bytes = try evt.readOrderKeyId(DB, cursor_val);
        const record = (try evt.Attachment.readById(DB, hash_kind, haxy_moment, arena, &id_bytes)) orelse continue;
        if (record.deleted) continue;
        try attachments.append(arena.allocator(), .{
            .id = std.fmt.bytesToHex(id_bytes, .lower),
            .name = record.name,
        });
    }
    return attachments.items;
}

// one download link per attachment. the url isn't a page route, so the link
// carries the raw-link prefix rather than the cross-page one.
pub fn appendRows(
    allocator: std.mem.Allocator,
    box: *wgt.Box(ui.Widget),
    session: *ui.Session,
    identity: []const u8,
    attachments: []const WithId,
) !void {
    const pa = session.page_arena.allocator();
    for (attachments) |entry| {
        var tb = try wgt.TextBox(ui.Widget).init(allocator, entry.name, .{
            .border_style = .single,
            .rounded_corners = true,
            .wrap_kind = .none,
            .label = " attachment ",
        });
        errdefer tb.deinit(allocator);
        tb.getFocus().focusable = true;
        tb.getFocus().kind = .{ .custom = try std.fmt.allocPrint(pa, "{s}{s}", .{ ui.raw_link_prefix, try url(session.page_arena, identity, &entry.id) }) };
        try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
    }
}

// the url an attachment's bytes are served from
pub fn url(page_arena: *std.heap.ArenaAllocator, identity: []const u8, id: []const u8) ![]const u8 {
    return if (identity.len == 0)
        try std.fmt.allocPrint(page_arena.allocator(), "/attachment:{s}", .{id})
    else
        try std.fmt.allocPrint(page_arena.allocator(), "/repo/{s}/attachment:{s}", .{ identity, id });
}

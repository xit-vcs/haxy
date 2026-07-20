const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8, // space-separated
status: Status = .open,
created_ts: u64 = 0, // the commit timestamp of the event that first created this issue

pub const Status = enum {
    open,
    closed,

    const longest_len = blk: {
        var len: usize = 0;
        for (@typeInfo(Status).@"enum".fields) |field| len = @max(len, field.name.len);
        break :blk len;
    };
};

pub const tag_max_len = 64;

// a "tag status" key names a tag's per-status issue set (tags can't contain
// spaces, so the pair is unambiguous)
pub const TagStatusKey = [tag_max_len + 1 + Status.longest_len]u8;

pub fn tagStatusKey(buffer: *TagStatusKey, tag: []const u8, status: Status) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ tag, @tagName(status) });
}

pub fn tagIterator(tags: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, tags, ' ');
}

// `created_ts` comes from the commit timestamp, not the event
// payload, so it must not appear in the JSON we output
pub fn jsonStringify(self: @This(), jw: anytype) !void {
    try jw.beginObject();
    inline for (std.meta.fields(@This())) |field| {
        if (comptime std.mem.eql(u8, field.name, "created_ts")) continue;
        try jw.objectField(field.name);
        try jw.write(@field(self, field.name));
    }
    try jw.endObject();
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
    arena: *std.heap.ArenaAllocator,
    created_ts: u64,
) !void {
    const issue_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->issue"));
    const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

    // the per-status sets the issues views list, ordered by creation time,
    // keyed by status name
    const status_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "status->issue-id-set"));
    const status_to_issues = try DB.SortedMap(.read_write).init(status_to_issues_cursor);

    // the per-tag, per-status sets, keyed "tag,status"
    const tag_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "tag+status->issue-id-set"));
    const tag_to_issues = try DB.SortedMap(.read_write).init(tag_to_issues_cursor);

    if (event_maybe) |event| {
        var event_to_write = event;

        const existing_cursor_maybe = try event_id_to_issue.getCursor(issue_key);
        if (existing_cursor_maybe) |existing_cursor| {
            // updates preserve the original creation timestamp
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_issue);
            event_to_write.created_ts = existing_event.created_ts;

            // drop the old status's and tags' entries; the current ones are re-added below
            const order_key = evt.orderKey(existing_event.created_ts, event_id);
            const status_set = try statusSet(DB, status_to_issues, existing_event.status);
            _ = try status_set.remove(&order_key);
            try removeFromTagSets(DB, tag_to_issues, existing_event.tags, existing_event.status, &order_key);
        } else {
            // first time we've seen this issue: stamp it with the commit timestamp
            event_to_write.created_ts = created_ts;
        }

        const issue_cursor = try event_id_to_issue.putCursor(issue_key);
        const issue = try DB.HashMap(.read_write).init(issue_cursor);
        try evt.upsert(@This(), DB, hash_kind, issue, event_to_write);

        const order_key = evt.orderKey(event_to_write.created_ts, event_id);

        const status_set = try statusSet(DB, status_to_issues, event.status);
        try status_set.put(&order_key);

        var tag_iter = tagIterator(event.tags);
        while (tag_iter.next()) |tag| {
            if (tag.len == 0) continue;
            if (tag.len > tag_max_len) return error.TagTooLong;
            var key_buffer: TagStatusKey = undefined;
            const tag_set_cursor = try tag_to_issues.putCursor(try tagStatusKey(&key_buffer, tag, event.status));
            const tag_set = try DB.SortedSet(.read_write).init(tag_set_cursor);
            try tag_set.put(&order_key);
        }
    } else {
        // drop it from the ordered sets using its recorded creation timestamp and status
        if (try event_id_to_issue.getCursor(issue_key)) |existing_cursor| {
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_issue);
            const order_key = evt.orderKey(existing_event.created_ts, event_id);

            const status_set = try statusSet(DB, status_to_issues, existing_event.status);
            _ = try status_set.remove(&order_key);

            try removeFromTagSets(DB, tag_to_issues, existing_event.tags, existing_event.status, &order_key);
        }
        if (!try event_id_to_issue.remove(issue_key)) return error.EventNotFound;
    }
}

// `status`'s sorted set within `statuses`, keyed by status name
fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_write),
    status: Status,
) !DB.SortedSet(.read_write) {
    const cursor = try statuses.putCursor(@tagName(status));
    return DB.SortedSet(.read_write).init(cursor);
}

// remove an issue's order key from its tags' `status` sets, pruning entries
// whose set becomes empty
fn removeFromTagSets(
    comptime DB: type,
    tag_to_issues: DB.SortedMap(.read_write),
    tags: []const u8,
    status: Status,
    order_key: []const u8,
) !void {
    var tag_iter = tagIterator(tags);
    while (tag_iter.next()) |tag| {
        if (tag.len == 0) continue;
        var key_buffer: TagStatusKey = undefined;
        const key = try tagStatusKey(&key_buffer, tag, status);
        const tag_set_cursor = try tag_to_issues.putCursor(key);
        const tag_set = try DB.SortedSet(.read_write).init(tag_set_cursor);
        _ = try tag_set.remove(order_key);
        if (0 == try tag_set.count()) _ = try tag_to_issues.remove(key);
    }
}

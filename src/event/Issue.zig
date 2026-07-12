const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8,
created_ts: u64 = 0, // the commit timestamp of the event that first created this issue

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

    if (event_maybe) |event| {
        var event_to_write = event;

        const existing_cursor_maybe = try event_id_to_issue.getCursor(issue_key);
        if (existing_cursor_maybe) |existing_cursor| {
            // updates preserve the original creation timestamp
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_issue);
            event_to_write.created_ts = existing_event.created_ts;
        } else {
            // first time we've seen this issue: stamp it with the commit timestamp
            event_to_write.created_ts = created_ts;
        }

        const issue_cursor = try event_id_to_issue.putCursor(issue_key);
        const issue = try DB.HashMap(.read_write).init(issue_cursor);
        try evt.upsert(@This(), DB, hash_kind, issue, event_to_write);

        // first time we've seen this issue: add it to the set the issues view
        // lists, ordered by creation time. the key (orderKey) embeds the event
        // id, so the set needs no value.
        if (existing_cursor_maybe == null) {
            const issue_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "issue-id-set"));
            const issue_id_set = try DB.SortedSet(.read_write).init(issue_id_set_cursor);
            const order_key = evt.orderKey(event_to_write.created_ts, event_id);
            try issue_id_set.put(&order_key);
        }
    } else {
        // drop it from the ordered set using its recorded creation timestamp
        if (try event_id_to_issue.getCursor(issue_key)) |existing_cursor| {
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_issue);
            const issue_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "issue-id-set"));
            const issue_id_set = try DB.SortedSet(.read_write).init(issue_id_set_cursor);
            const order_key = evt.orderKey(existing_event.created_ts, event_id);
            _ = try issue_id_set.remove(&order_key);
        }
        if (!try event_id_to_issue.remove(issue_key)) return error.EventNotFound;
    }
}

const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8,

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
) !void {
    const issue_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->issue"));
    const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

    if (event_maybe) |event| {
        const issue_cursor = try event_id_to_issue.putCursor(issue_key);
        const issue = try DB.HashMap(.read_write).init(issue_cursor);
        try evt.upsert(@This(), DB, hash_kind, issue, event);
    } else {
        if (!try event_id_to_issue.remove(issue_key)) return error.EventNotFound;
    }
}

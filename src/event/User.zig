const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;
const bcrypt = std.crypto.pwhash.bcrypt;

name: []const u8,
display_name: []const u8,
email: []const u8,
password_hash: []const u8,

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
) !void {
    const user_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_user_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->user"));
    const event_id_to_user = try DB.HashMap(.read_write).init(event_id_to_user_cursor);

    if (event_maybe) |event| {
        const user_cursor = try event_id_to_user.putCursor(user_key);
        const user = try DB.HashMap(.read_write).init(user_cursor);
        try evt.upsert(@This(), DB, hash_kind, user, event);
    } else {
        if (!try event_id_to_user.remove(user_key)) return error.EventNotFound;

        const user_id_to_repos_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repos"));
        const user_id_to_repos = try DB.HashMap(.read_write).init(user_id_to_repos_cursor);
        _ = try user_id_to_repos.remove(user_key);
    }
}

pub const password_hash_max_len = bcrypt.hash_length * 2;

pub fn hashPassword(
    password: []const u8,
    out: []u8,
    io: std.Io,
) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = bcrypt.Params.owasp,
        .encoding = .phc,
    }, out, io);
}

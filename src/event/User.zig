const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const bcrypt = std.crypto.pwhash.bcrypt;

name: []const u8,
display_name: []const u8,
email: []const u8,
password_hash: []const u8,
enable_ansi: bool = false,

const Self = @This();

pub const name_max_len = 32;

// the subset of a user that's safe to hand to clients
pub const Safe = struct {
    name: []const u8,
    display_name: []const u8,

    pub fn init(user: Self) Safe {
        return .{ .name = user.name, .display_name = user.display_name };
    }
};

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    event_maybe: ?@This(),
    arena: *std.heap.ArenaAllocator,
) !void {
    const user_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_user_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->user"));
    const event_id_to_user = try DB.HashMap(.read_write).init(event_id_to_user_cursor);

    const name_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "name->user-id"));
    const name_to_user_id = try DB.HashMap(.read_write).init(name_to_user_id_cursor);

    if (event_maybe) |event| {
        if (event.name.len > name_max_len) return error.NameTooLong;

        // if this event_id already maps to a user with a different name,
        // drop the stale name->id entry first
        if (try event_id_to_user.getCursor(user_key)) |existing_cursor| {
            const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_user);
            if (!std.mem.eql(u8, existing_event.name, event.name)) {
                _ = try name_to_user_id.remove(hash.hashInt(hash_kind, existing_event.name));
            }
        }

        const user_cursor = try event_id_to_user.putCursor(user_key);
        const user = try DB.HashMap(.read_write).init(user_cursor);
        try evt.upsert(@This(), DB, hash_kind, user, event);

        try name_to_user_id.put(hash.hashInt(hash_kind, event.name), .{ .bytes = event_id });
    } else {
        // read the user's name so we can drop its name->id index entry
        if (try event_id_to_user.getCursor(user_key)) |existing_cursor| {
            const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_user);
            _ = try name_to_user_id.remove(hash.hashInt(hash_kind, existing_event.name));
        }

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

pub const VerifyResult = union(enum) {
    success: [evt.event_id_size]u8,
    unknown_user,
    wrong_password,
};

// look up a user by name (via the name->user-id index) and verify the
// supplied password against the stored bcrypt hash. used by both the TTY
// login submit and the server's /login route.
pub fn verifyCredentials(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    password: []const u8,
) !VerifyResult {
    const name_index_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "name->user-id")) orelse return .unknown_user;
    const name_index = try DB.HashMap(.read_only).init(name_index_cursor);

    const user_id_cursor = try name_index.getCursor(hash.hashInt(hash_kind, name)) orelse return .unknown_user;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);

    const user_key = hash.hashInt(hash_kind, &user_id);
    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse return .unknown_user;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    const user_cursor = try event_id_to_user.getCursor(user_key) orelse return .unknown_user;
    const user_map = try DB.HashMap(.read_only).init(user_cursor);
    const user_event = try evt.read(@This(), DB, hash_kind, arena, user_map);

    bcrypt.strVerify(user_event.password_hash, password, .{ .silently_truncate_password = false }) catch {
        return .wrong_password;
    };

    return .{ .success = user_id };
}

// read a user by event id via the event-id->user index, or null if the id
// isn't a known user. field byte slices are allocated in `arena`.
pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    user_id: []const u8,
) !?@This() {
    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse return null;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);
    const user_cursor = try event_id_to_user.getCursor(hash.hashInt(hash_kind, user_id)) orelse return null;
    const user_map = try DB.HashMap(.read_only).init(user_cursor);
    return try evt.read(@This(), DB, hash_kind, arena, user_map);
}

// flip a user's ANSI-art preference by re-emitting their User event with
// enable_ansi negated. a no-op for an unknown user. `repo` must be writable.
pub fn toggleAnsi(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    user_id: []const u8,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const moment = try evt.currentMoment(repo_opts, repo);
    const user = (try readById(DB, repo_opts.hash, moment, &arena, user_id)) orelse return;

    var updated = user;
    updated.enable_ansi = !user.enable_ansi;
    try evt.commitAndConsume(repo_opts, io, allocator, repo, evt.events_ref, &[_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(user_id[0..evt.event_id_size].*, .lower),
        .event = .{ .user = updated },
    }});
}

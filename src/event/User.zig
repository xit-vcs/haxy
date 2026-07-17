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
enable_ansi: bool = true,
ssh_keys: []const u8 = "", // newline-separated authorized_keys lines (one OpenSSH public key per line)
created_ts: u64 = 0, // the commit timestamp of the event that first created this user

const Self = @This();

pub const name_max_len = 32;

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.NameEmpty;
    if (name.len > name_max_len) return error.NameTooLong;
    if (name[0] == '-' or name[name.len - 1] == '-') return error.InvalidName;

    var previous_was_hyphen = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            previous_was_hyphen = false;
        } else if (c == '-' and !previous_was_hyphen) {
            previous_was_hyphen = true;
        } else {
            return error.InvalidName;
        }
    }
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
    created_ts: u64,
) !void {
    const user_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_user_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->user"));
    const event_id_to_user = try DB.HashMap(.read_write).init(event_id_to_user_cursor);

    const name_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "name->user-id"));
    const name_to_user_id = try DB.HashMap(.read_write).init(name_to_user_id_cursor);

    if (event_maybe) |event| {
        try validateName(event.name);

        var event_to_write = event;

        // if this event_id already maps to a user with a different name,
        // drop the stale name->id entry first
        const existing_cursor_maybe = try event_id_to_user.getCursor(user_key);
        if (existing_cursor_maybe) |existing_cursor| {
            const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_user);
            // updates preserve the original creation timestamp
            event_to_write.created_ts = existing_event.created_ts;
            if (!std.mem.eql(u8, existing_event.name, event.name)) {
                _ = try name_to_user_id.remove(hash.hashInt(hash_kind, existing_event.name));
            }
        } else {
            // first time we've seen this user: stamp it with the commit timestamp
            event_to_write.created_ts = created_ts;
        }

        const user_cursor = try event_id_to_user.putCursor(user_key);
        const user = try DB.HashMap(.read_write).init(user_cursor);
        try evt.upsert(@This(), DB, hash_kind, user, event_to_write);

        try name_to_user_id.put(hash.hashInt(hash_kind, event.name), .{ .bytes = event_id });

        // first time we've seen this user: add it to the ordered set the users
        // view paginates through. the key (orderKey) embeds the event id, so the
        // set needs no value.
        if (existing_cursor_maybe == null) {
            const user_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id-set"));
            const user_id_set = try DB.SortedSet(.read_write).init(user_id_set_cursor);
            const order_key = evt.orderKey(event_to_write.created_ts, event_id);
            try user_id_set.put(&order_key);
        }
    } else {
        // read the user's name so we can drop its name->id index entry
        if (try event_id_to_user.getCursor(user_key)) |existing_cursor| {
            const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_event = try evt.read(@This(), DB, hash_kind, arena, existing_user);
            _ = try name_to_user_id.remove(hash.hashInt(hash_kind, existing_event.name));

            // drop it from the ordered set using its recorded creation timestamp
            const user_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id-set"));
            const user_id_set = try DB.SortedSet(.read_write).init(user_id_set_cursor);
            const order_key = evt.orderKey(existing_event.created_ts, event_id);
            _ = try user_id_set.remove(&order_key);
        }

        if (!try event_id_to_user.remove(user_key)) return error.EventNotFound;

        const user_id_to_repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"));
        const user_id_to_repo_id_set = try DB.HashMap(.read_write).init(user_id_to_repo_id_set_cursor);
        _ = try user_id_to_repo_id_set.remove(user_key);
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

// read a user by name from the admin event store, or null if the admin repo or
// the user doesn't exist. field byte slices are allocated in `arena`.
pub fn readByName(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
) !?Self {
    var repo = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return null,
        else => |e| return e,
    };
    defer repo.deinit(io, allocator);

    const moment = try evt.currentMoment(evt.admin_repo_opts, &repo);

    const name_to_user_id_cursor = try moment.getCursor(hash.hashInt(evt.admin_repo_opts.hash, "name->user-id")) orelse return null;
    const name_to_user_id = try evt.AdminDB.HashMap(.read_only).init(name_to_user_id_cursor);
    const user_id_cursor = try name_to_user_id.getCursor(hash.hashInt(evt.admin_repo_opts.hash, name)) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);

    return try readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &user_id);
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
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .event = .{ .user = updated },
    }});
}

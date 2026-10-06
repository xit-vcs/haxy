const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const bcrypt = std.crypto.pwhash.bcrypt;

name: []const u8,
email: []const u8,
password_hash: []const u8,
ssh_keys: []const u8 = "", // newline-separated authorized_keys lines (one OpenSSH public key per line)

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

// the subset of a user that anyone may see
pub const Public = struct {
    name: []const u8,
};

const Self = @This();

pub const name_min_len = 4;
pub const name_max_len = 32;

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->user";
pub const all_id_set_key = "user-id-set";
pub const name_index_key = "name->user-id";

// resolves a commit's author email to its user at read time
pub const email_to_user_id_key = "email->user-id";

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.NameEmpty;
    if (name.len < name_min_len) return error.NameTooShort;
    if (name.len > name_max_len) return error.NameTooLong;
    if (name[0] == '-' or name[name.len - 1] == '-') return error.InvalidName;
    // reserved for the top-level pages' url segment
    if (std.ascii.eqlIgnoreCase(name, "home")) return error.InvalidName;

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

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    _: ?[]const u8,
) !void {
    const user_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_user_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->user"));
    const event_id_to_user = try DB.HashMap(.read_write).init(event_id_to_user_cursor);

    const name_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, name_index_key));
    const name_to_user_id = try DB.SortedMap(.read_write).init(name_to_user_id_cursor);

    const email_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, email_to_user_id_key));
    const email_to_user_id = try DB.HashMap(.read_write).init(email_to_user_id_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_user.getCursor(user_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_user);
    }

    var record_to_write = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_record_maybe);

    if (!record_to_write.removed) try validateName(record_to_write.event.name);

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation metadata
        record_to_write.created_order = existing_record.created_order;

        // drop the old active indexes; active values are re-added below
        if (!existing_record.removed) {
            _ = try name_to_user_id.remove(existing_record.event.name);
            _ = try email_to_user_id.remove(hash.hashInt(hash_kind, existing_record.event.email));
        }
    }

    const user_cursor = try event_id_to_user.putCursor(user_key);
    const user = try DB.HashMap(.read_write).init(user_cursor);
    try evt.upsert(Record, DB, hash_kind, user, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .user, existing_record_maybe, record_to_write);

    const order_key = evt.orderKeyDesc(record_to_write.created_order, event_id);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const user_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key));
        const user_id_set = try DB.SortedSet(.read_write).init(user_id_set_cursor);
        try user_id_set.put(&order_key);
    }

    if (!record_to_write.removed) {
        try name_to_user_id.put(record_to_write.event.name, .{ .bytes = event_id });
        try email_to_user_id.put(hash.hashInt(hash_kind, record_to_write.event.email), .{ .bytes = event_id });
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
    const user_id = try readIdByName(DB, hash_kind, haxy_moment, name) orelse return .unknown_user;

    const user_key = hash.hashInt(hash_kind, &user_id);
    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse return .unknown_user;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);

    const user_cursor = try event_id_to_user.getCursor(user_key) orelse return .unknown_user;
    const user_map = try DB.HashMap(.read_only).init(user_cursor);
    const user_event = try evt.read(Record, DB, hash_kind, arena, user_map);

    if (!verifyPassword(user_event.event.password_hash, password)) return .wrong_password;

    return .{ .success = user_id };
}

pub fn verifyPassword(password_hash: []const u8, password: []const u8) bool {
    bcrypt.strVerify(password_hash, password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

// read a user by event id via the event-id->user index, or null if the id
// isn't a known user. field byte slices are allocated in `arena`.
pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    user_id: []const u8,
) !?Record {
    const user_map = try userMap(DB, hash_kind, haxy_moment, user_id) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, user_map);
}

// read just the public part of a user by email via the email->user-id index, or
// null when no user has the email. field byte slices are allocated in `arena`.
pub fn readByEmail(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    email: []const u8,
) !?Public {
    const email_to_user_id_cursor = (try haxy_moment.getCursor(hash.hashInt(hash_kind, email_to_user_id_key))) orelse return null;
    const email_to_user_id = try DB.HashMap(.read_only).init(email_to_user_id_cursor);
    const user_id_cursor = (try email_to_user_id.getCursor(hash.hashInt(hash_kind, email))) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);
    const user_map = try userMap(DB, hash_kind, haxy_moment, &user_id) orelse return null;
    const record = try evt.read(struct { event: Public }, DB, hash_kind, arena, user_map);
    return record.event;
}

// a user's id via the name->user-id index
pub fn readIdByName(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    name: []const u8,
) !?[evt.event_id_size]u8 {
    const index_cursor = (try haxy_moment.getCursor(hash.hashInt(hash_kind, name_index_key))) orelse return null;
    const index = try DB.SortedMap(.read_only).init(index_cursor);
    const user_id_cursor = (try index.getCursor(name)) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);
    return user_id;
}

// a user's record map via the event-id->user index
fn userMap(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    user_id: []const u8,
) !?DB.HashMap(.read_only) {
    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse return null;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);
    const user_cursor = try event_id_to_user.getCursor(hash.hashInt(hash_kind, user_id)) orelse return null;
    return try DB.HashMap(.read_only).init(user_cursor);
}

// read a user by name from the admin event store, or null if the admin repo or
// the user doesn't exist. field byte slices are allocated in `arena`.
pub fn readByName(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
) !?Record {
    var repo = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return null,
        else => |e| return e,
    };
    defer repo.deinit(io, allocator);

    const moment = try evt.currentMoment(evt.admin_repo_opts, &repo);

    const user_id = try readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, name) orelse return null;

    return try readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &user_id);
}

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

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    deleted: bool = false,
    created_ts: u64 = 0, // the commit timestamp of the event that first created this user

    // a user's key in the name index
    pub fn indexKey(self: Record, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        return self.event.name;
    }
};

// the subset of a user that anyone may see
pub const Public = struct {
    name: []const u8,
    display_name: []const u8,
};

const Self = @This();

pub const name_max_len = 32;

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->user";
pub const id_set_key = "user-id-set";
pub const name_index_key = "name->user-id";

// resolves a commit's author email to its user at read time
pub const email_to_user_id_key = "email->user-id";

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

    const name_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "name->user-id"));
    const name_to_user_id = try DB.HashMap(.read_write).init(name_to_user_id_cursor);

    const email_to_user_id_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, email_to_user_id_key));
    const email_to_user_id = try DB.HashMap(.read_write).init(email_to_user_id_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_user.getCursor(user_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_user = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_user);
    }

    var record_to_write = if (record_maybe) |record|
        record
    else blk: {
        var record = existing_record_maybe orelse return error.EventNotFound;
        record.deleted = true;
        break :blk record;
    };

    if (!record_to_write.deleted) try validateName(record_to_write.event.name);

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation timestamp
        record_to_write.created_ts = existing_record.created_ts;

        // drop the old active indexes; active values are re-added below
        if (!existing_record.deleted) {
            _ = try name_to_user_id.remove(hash.hashInt(hash_kind, existing_record.event.name));
            _ = try email_to_user_id.remove(hash.hashInt(hash_kind, existing_record.event.email));
        }
    }

    const user_cursor = try event_id_to_user.putCursor(user_key);
    const user = try DB.HashMap(.read_write).init(user_cursor);
    try evt.upsert(Record, DB, hash_kind, user, record_to_write);

    const order_key = evt.orderKeyDesc(record_to_write.created_ts, event_id);

    // the id set retains tombstones so merges can carry deletions
    if (existing_cursor_maybe == null) {
        const user_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key));
        const user_id_set = try DB.SortedSet(.read_write).init(user_id_set_cursor);
        try user_id_set.put(&order_key);
    }

    if (!record_to_write.deleted) {
        try name_to_user_id.put(hash.hashInt(hash_kind, record_to_write.event.name), .{ .bytes = event_id });
        try email_to_user_id.put(hash.hashInt(hash_kind, record_to_write.event.email), .{ .bytes = event_id });
    }

    const became_deleted = record_to_write.deleted and if (existing_record_maybe) |existing| !existing.deleted else true;
    if (became_deleted) {
        // the user's repos go with them: the repo name index is keyed by owner
        // id, so one left behind is listed but can never be resolved again
        const user_id_to_repo_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "user-id->repo-id-set"));
        const user_id_to_repo_id_set = try DB.HashMap(.read_write).init(user_id_to_repo_id_set_cursor);
        if (try user_id_to_repo_id_set.getCursor(user_key)) |user_repos_cursor| {
            const user_repos = try DB.SortedSet(.read_only).init(user_repos_cursor);

            // collected up front, since deleting a repo removes it from this set
            var repo_ids: std.ArrayList([evt.event_id_size]u8) = .empty;
            var repo_iter = try user_repos.iteratorFromIndex(0);
            while (try repo_iter.next()) |kv_pair_cursor| {
                try repo_ids.append(arena.allocator(), try evt.readOrderKeyId(DB, kv_pair_cursor));
            }

            for (repo_ids.items) |*repo_id| {
                try evt.Repo.consume(DB, hash_kind, haxy_moment, repo_id, null, arena, null);
            }
        }
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
    const user_event = try evt.read(Record, DB, hash_kind, arena, user_map);

    bcrypt.strVerify(user_event.event.password_hash, password, .{ .silently_truncate_password = false }) catch {
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
) !?Record {
    const event_id_to_user_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, "event-id->user")) orelse return null;
    const event_id_to_user = try DB.HashMap(.read_only).init(event_id_to_user_cursor);
    const user_cursor = try event_id_to_user.getCursor(hash.hashInt(hash_kind, user_id)) orelse return null;
    const user_map = try DB.HashMap(.read_only).init(user_cursor);
    return try evt.read(Record, DB, hash_kind, arena, user_map);
}

// read a user by email via the email->user-id index, or null when no user has
// the email. field byte slices are allocated in `arena`.
pub fn readByEmail(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    email: []const u8,
) !?Record {
    const email_to_user_id_cursor = (try haxy_moment.getCursor(hash.hashInt(hash_kind, email_to_user_id_key))) orelse return null;
    const email_to_user_id = try DB.HashMap(.read_only).init(email_to_user_id_cursor);
    const user_id_cursor = (try email_to_user_id.getCursor(hash.hashInt(hash_kind, email))) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    _ = try user_id_cursor.readBytes(&user_id);
    return try readById(DB, hash_kind, haxy_moment, arena, &user_id);
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

    var updated = user.event;
    updated.enable_ansi = !updated.enable_ansi;
    try evt.consume(.xit, repo_opts, io, allocator, repo, evt.events_ref, &[_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(user_id[0..evt.event_id_size].*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author_email = user.event.email,
        .event = .{ .user = updated },
    }});
}

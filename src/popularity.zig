// counts the distinct clients that fetch each public repo and each owner's
// repos, as a hyperloglog sketch in the repo's and the owner's user repo's
// `.xit` dir, and keeps the users list's order by those counts in
// `users/index.db`

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("./event.zig");

const hash_kind: hash.HashKind = .sha1;
const DB = xit.xitdb.Database(.buffered_file, hash.HashInt(hash_kind));

const index_name = "index.db";
// user id to the user's count, for every active user
const user_scores_key = "user-scores";
// `orderKeyDesc(count, user id)` for every active user
const order_key = "order";

const repo_dir_name = ".xit";
// a repo's sketch in its `.xit` dir, and an owner's in their user repo's
const sketch_name = "haxy-fetchers";

// held across a fetch's sketch and index writes, so concurrent fetches can't
// overwrite each other's sketch or write the index out of order
var mutex: std.Io.Mutex = .init;

// a hyperloglog sketch file: one byte per slot, with the bytes missing from
// its end being 0
const sketch = struct {
    const slot_bits = 14;
    const slot_count = 1 << slot_bits;

    // raise the slot the hash falls in. false when it was already as high.
    fn add(io: std.Io, file: std.Io.File, address_hash: u64) !bool {
        const slot = address_hash >> (64 - slot_bits);
        const value: u8 = @intCast(@min(@clz(address_hash << slot_bits), 64 - slot_bits) + 1);
        var old: [1]u8 = .{0};
        _ = try file.readPositionalAll(io, &old, slot);
        if (value <= old[0]) return false;
        try file.writePositionalAll(io, &.{value}, slot);
        try file.sync(io);
        return true;
    }

    // how many distinct hashes were added: the original hyperloglog
    // estimator, with linear counting for small counts
    fn estimate(io: std.Io, file: std.Io.File) !u64 {
        var slots: [slot_count]u8 = @splat(0);
        _ = try file.readPositionalAll(io, &slots, 0);
        const m: f64 = slot_count;
        var sum: f64 = 0;
        var zeros: usize = 0;
        for (slots) |value| {
            sum += @exp2(-@as(f64, @floatFromInt(value)));
            if (value == 0) zeros += 1;
        }
        const alpha = 0.7213 / (1 + 1.079 / m);
        const raw = alpha * m * m / sum;
        const result = if (raw <= 2.5 * m and zeros > 0) m * @log(m / @as(f64, @floatFromInt(zeros))) else raw;
        return @intFromFloat(@round(result));
    }
};

const ipv4_mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

// a client address's hash in the sketch of the repo or owner `id`. ipv6
// counts by its /48, and an ipv4-mapped address as its ipv4 address.
fn addressHash(address: std.Io.net.IpAddress, id: *const [evt.event_id_size]u8) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    switch (address) {
        .ip4 => |ip4| {
            hasher.update(&.{4});
            hasher.update(&ip4.bytes);
        },
        .ip6 => |ip6| if (std.mem.eql(u8, ip6.bytes[0..ipv4_mapped_prefix.len], &ipv4_mapped_prefix)) {
            hasher.update(&.{4});
            hasher.update(ip6.bytes[ipv4_mapped_prefix.len..]);
        } else {
            hasher.update(&.{6});
            hasher.update(ip6.bytes[0..6]);
        },
    }
    hasher.update(id);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .big);
}

// the sketch of the repo at `repo_path`, created when it has none, or null
// when the repo is gone
fn openSketch(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) !?std.Io.File {
    const path = try std.Io.Dir.path.join(allocator, &.{ repo_path, repo_dir_name, sketch_name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

// count a fetch of the repo at `location` from `address`, in the repo's
// sketch and its owner's. failures are logged, not returned.
pub fn count(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    location: evt.RepoLocation,
    address: std.Io.net.IpAddress,
) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    countLocked(io, allocator, users_path, location, address) catch |err| {
        std.log.warn("failed to count a fetch: {s}", .{@errorName(err)});
    };
}

fn countLocked(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    location: evt.RepoLocation,
    address: std.Io.net.IpAddress,
) !void {
    // a deleted repo or owner has no dir left to hold a sketch
    const repo_path = try evt.repoPath(allocator, users_path, &location.owner_id, &location.repo_id);
    defer allocator.free(repo_path);
    if (try openSketch(io, allocator, repo_path)) |file| {
        defer file.close(io);
        _ = try sketch.add(io, file, addressHash(address, &location.repo_id));
    }

    const user_repo_path = try evt.userRepoPath(allocator, users_path, &location.owner_id);
    defer allocator.free(user_repo_path);
    const file = try openSketch(io, allocator, user_repo_path) orelse return;
    defer file.close(io);
    if (!try sketch.add(io, file, addressHash(address, &location.owner_id))) return;

    const Ctx = struct {
        user_id: *const [evt.event_id_size]u8,
        score: u64,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const scores, const order = try openIndex(cursor);
            const key = hash.hashInt(hash_kind, ctx.user_id);
            // a deleted user stays out
            const old_cursor = try scores.getCursor(key) orelse return error.CancelTransaction;
            const old_score = try old_cursor.readUint();
            if (old_score == ctx.score) return error.CancelTransaction;
            try scores.put(key, .{ .uint = ctx.score });
            _ = try order.remove(&evt.orderKeyDesc(old_score, ctx.user_id));
            try order.put(&evt.orderKeyDesc(ctx.score, ctx.user_id));
        }
    };
    try writeIndex(io, allocator, users_path, Ctx{ .user_id = &location.owner_id, .score = try sketch.estimate(io, file) });
}

// the index's user scores and order, from its root
fn openIndex(cursor: *DB.Cursor(.read_write)) !struct { DB.HashMap(.read_write), DB.SortedSet(.read_write) } {
    const root = try DB.HashMap(.read_write).init(cursor.*);
    return .{
        try DB.HashMap(.read_write).init(try root.putCursor(hash.hashInt(hash_kind, user_scores_key))),
        try DB.SortedSet(.read_write).init(try root.putCursor(hash.hashInt(hash_kind, order_key))),
    };
}

// run `ctx` as one transaction on the index, under its exclusive lock. the
// root is a map, so no history is kept.
fn writeIndex(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, ctx: anytype) !void {
    const path = try std.Io.Dir.path.join(allocator, &.{ users_path, index_name });
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    try file.lock(io, .exclusive);
    defer file.unlock(io);

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    var db = try DB.init(io, .{ .file = file, .buffer = &buffer, .hash_id = .{ .id = hash.hashId(hash_kind) } });
    db.runContext(ctx) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => |e| return e,
    };
}

// list a new user, at 0
pub fn addUser(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, user_id: *const [evt.event_id_size]u8) !void {
    const Ctx = struct {
        user_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const scores, const order = try openIndex(cursor);
            try scores.put(hash.hashInt(hash_kind, ctx.user_id), .{ .uint = 0 });
            try order.put(&evt.orderKeyDesc(0, ctx.user_id));
        }
    };
    try writeIndex(io, allocator, users_path, Ctx{ .user_id = user_id });
}

// unlist a deleted user
pub fn removeUser(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, user_id: *const [evt.event_id_size]u8) !void {
    const Ctx = struct {
        user_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const scores, const order = try openIndex(cursor);
            const key = hash.hashInt(hash_kind, ctx.user_id);
            const score_cursor = try scores.getCursor(key) orelse return error.CancelTransaction;
            _ = try order.remove(&evt.orderKeyDesc(try score_cursor.readUint(), ctx.user_id));
            _ = try scores.remove(key);
        }
    };
    try writeIndex(io, allocator, users_path, Ctx{ .user_id = user_id });
}

// list every active user missing from the index, with their sketch's estimate
pub fn reconcile(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, admin_repo: *rp.Repo(.xit, evt.admin_repo_opts)) !void {
    const Ctx = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        users_path: []const u8,
        admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const scores, const order = try openIndex(cursor);
            const moment = evt.currentMoment(evt.admin_repo_opts, ctx.admin_repo) catch |err| switch (err) {
                // a fresh admin repo has no moment until its first event
                error.NotFound => return,
                else => |e| return e,
            };
            // absent until the first user exists
            const names_cursor = try moment.getCursor(hash.hashInt(evt.admin_repo_opts.hash, evt.User.name_index_key)) orelse return;
            const names = try evt.AdminDB.SortedMap(.read_only).init(names_cursor);
            var iter = try names.iterator();
            while (try iter.next()) |name_cursor| {
                const pair = try name_cursor.readKeyValuePair();
                var user_id: [evt.event_id_size]u8 = undefined;
                _ = try pair.value_cursor.readBytes(&user_id);
                const key = hash.hashInt(hash_kind, &user_id);
                if (try scores.getCursor(key) != null) continue;

                const user_repo_path = try evt.userRepoPath(ctx.allocator, ctx.users_path, &user_id);
                defer ctx.allocator.free(user_repo_path);
                const path = try std.Io.Dir.path.join(ctx.allocator, &.{ user_repo_path, repo_dir_name, sketch_name });
                defer ctx.allocator.free(path);
                // a user whose repos were never fetched has no sketch
                const score = if (std.Io.Dir.cwd().openFile(ctx.io, path, .{})) |file| blk: {
                    defer file.close(ctx.io);
                    break :blk try sketch.estimate(ctx.io, file);
                } else |err| switch (err) {
                    error.FileNotFound => 0,
                    else => |e| return e,
                };
                try scores.put(key, .{ .uint = score });
                try order.put(&evt.orderKeyDesc(score, &user_id));
            }
        }
    };
    try writeIndex(io, allocator, users_path, Ctx{ .io = io, .allocator = allocator, .users_path = users_path, .admin_repo = admin_repo });
}

// a window of the users list, most fetched first
pub const Window = struct {
    user_ids: []const [evt.event_id_size]u8,
    // the `start` of the window after this one, or null when this is the last
    next_start: ?usize,
};

// up to `max` user ids from `start` in the users list order
pub fn readUsers(io: std.Io, arena: *std.heap.ArenaAllocator, users_path: []const u8, start: usize, max: usize) !Window {
    const gpa = arena.child_allocator;
    const path = try std.Io.Dir.path.join(gpa, &.{ users_path, index_name });
    defer gpa.free(path);
    // readers take no lock
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var db = try DB.init(io, .{ .file = file, .buffer = &buffer });
    const root = try DB.HashMap(.read_only).init(db.rootCursor().readOnly());
    const order_cursor = try root.getCursor(hash.hashInt(hash_kind, order_key)) orelse return .{ .user_ids = &.{}, .next_start = null };
    const order = try DB.SortedSet(.read_only).init(order_cursor);

    const total = try order.count();
    const end = @min(start +| max, total);
    const user_ids = try arena.allocator().alloc([evt.event_id_size]u8, end -| start);
    var iter = try order.iteratorFromIndex(start);
    for (user_ids) |*user_id| user_id.* = try evt.readOrderKeyId(DB, (try iter.next()) orelse unreachable);
    return .{ .user_ids = user_ids, .next_start = if (end < total) end else null };
}

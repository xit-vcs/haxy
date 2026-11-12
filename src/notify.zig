const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("event.zig");
const progress = @import("progress.zig");

const UserDB = evt.UserDB;
const hash_kind = evt.user_repo_opts.hash;

// the user repo keys, outside the haxy moment
const notif_map_key = "haxy/notif-id->notif";
const recent_notif_id_set_key = "haxy/recent-notif-id-set";
const unread_notif_id_set_key = "haxy/unread-notif-id-set";

// the most notifs a user keeps
pub const max_notifs = 1000;

// the most users a thread's capped tiers hold
pub const max_commented = 250;
pub const max_subscribed = 100;

// the owner's user repo key mapping each thread's notif id to the user ids in
// `mode`'s tier, and the most that tier holds. a mute has no tier.
fn tierOf(comptime mode: evt.Notify.Mode) ?struct { map_key: []const u8, cap: ?u64 } {
    const map_key = "haxy/notif-id->" ++ @tagName(mode) ++ "-id-set";
    return switch (mode) {
        .involved => .{ .map_key = map_key, .cap = null },
        .commented => .{ .map_key = map_key, .cap = max_commented },
        .subscribed => .{ .map_key = map_key, .cap = max_subscribed },
        .muted => null,
    };
}

// one thread's item in a user's inbox. the names and title are as of its last bump.
pub const Notif = struct {
    // the repo holding the thread
    repo_id: [evt.event_id_size]u8,
    owner_name: []const u8,
    repo_name: []const u8,
    thread_id: [evt.event_id_size]u8,
    thread_kind: evt.EventKind,
    title: []const u8,
    // the comment or assignment that last bumped it
    last_child_id: [evt.event_id_size]u8,
    // when it was last bumped, which also orders the sets
    time: u64 = 0,
};

// a notif as the inbox lists it
pub const Item = struct {
    notif: Notif,
    unread: bool,
};

// the id of the one notif a user can hold on a thread
pub fn idOf(repo_id: *const [evt.event_id_size]u8, thread_id: *const [evt.event_id_size]u8) [evt.event_id_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(repo_id);
    hasher.update(thread_id);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..evt.event_id_size].*;
}

// run `ctx` in a transaction on the user's repo
fn transact(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, user_id: *const [evt.event_id_size]u8, ctx: anytype) !void {
    var user_repo = (try evt.openUserRepo(io, allocator, users_path, user_id)) orelse return error.NotFound;
    defer user_repo.deinit(io, allocator);

    try user_repo.core.db_file.lock(io, .exclusive);
    defer user_repo.core.db_file.unlock(io);

    const history = try UserDB.ArrayList(.read_write).init(user_repo.core.db.rootCursor());
    history.appendContext(.{ .slot = try history.getSlot(-1) }, ctx) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => |e| return e,
    };
}

// a stored notif's time, or null when the user has none for the id
fn readTime(arena: *std.heap.ArenaAllocator, records: UserDB.HashMap(.read_only), id: *const [evt.event_id_size]u8) !?u64 {
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return (try evt.read(struct { time: u64 }, UserDB, hash_kind, arena, try UserDB.HashMap(.read_only).init(record_cursor))).time;
}

// drop a notif from the map and both sets
fn removeNotif(moment: UserDB.HashMap(.read_write), records: UserDB.HashMap(.read_write), id: *const [evt.event_id_size]u8, time: u64) !void {
    const order_key = evt.orderKeyDesc(time, id);
    _ = try records.remove(hash.hashInt(hash_kind, id));
    _ = try (try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)))).remove(&order_key);
    _ = try (try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)))).remove(&order_key);
}

// upsert one user's batch as unread and newest, pruning past the cap
pub fn deliver(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, user_id: *const [evt.event_id_size]u8, notifs: []const Notif) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notifs: []const Notif,
        time: u64,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, notif_map_key)));
            const recent = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)));
            const unread = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)));

            for (ctx.notifs) |notif| {
                const id = idOf(&notif.repo_id, &notif.thread_id);
                if (try readTime(ctx.arena, records.readOnly(), &id)) |old_time| {
                    const old_key = evt.orderKeyDesc(old_time, &id);
                    _ = try recent.remove(&old_key);
                    _ = try unread.remove(&old_key);
                }
                var stored = notif;
                stored.time = ctx.time;
                try evt.upsert(Notif, UserDB, hash_kind, try UserDB.HashMap(.read_write).init(try records.putCursor(hash.hashInt(hash_kind, &id))), stored);
                const order_key = evt.orderKeyDesc(ctx.time, &id);
                try recent.put(&order_key);
                try unread.put(&order_key);
            }

            // the oldest go past the cap
            var count = try recent.count();
            while (count > max_notifs) : (count -= 1) {
                const oldest = (try recent.getIndexKeyValuePair(@intCast(count - 1))) orelse unreachable;
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try oldest.key_cursor.readBytes(&order_key);
                const id = order_key[@sizeOf(u64)..].*;
                const time = std.math.maxInt(u64) - std.mem.readInt(u64, order_key[0..@sizeOf(u64)], .big);
                try removeNotif(moment, records, &id, time);
            }
        }
    };

    try transact(io, allocator, users_path, user_id, Ctx{
        .arena = &arena,
        .notifs = notifs,
        .time = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
}

// mark a notif read, unless it was bumped past `last_child_id` since the user saw it
pub fn markRead(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    user_id: *const [evt.event_id_size]u8,
    notif_id: *const [evt.event_id_size]u8,
    last_child_id: *const [evt.event_id_size]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notif_id: *const [evt.event_id_size]u8,
        last_child_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records_cursor = try moment.readOnly().getCursor(hash.hashInt(hash_kind, notif_map_key)) orelse return error.CancelTransaction;
            const record_cursor = try (try UserDB.HashMap(.read_only).init(records_cursor)).getCursor(hash.hashInt(hash_kind, ctx.notif_id)) orelse return error.CancelTransaction;
            const notif = try evt.read(Notif, UserDB, hash_kind, ctx.arena, try UserDB.HashMap(.read_only).init(record_cursor));
            if (!std.mem.eql(u8, &notif.last_child_id, ctx.last_child_id)) return error.CancelTransaction;

            const unread = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)));
            if (!try unread.remove(&evt.orderKeyDesc(notif.time, ctx.notif_id))) return error.CancelTransaction;
        }
    };

    try transact(io, allocator, users_path, user_id, Ctx{ .arena = &arena, .notif_id = notif_id, .last_child_id = last_child_id });
}

// remove a notif. the thread's next bump recreates it.
pub fn dismiss(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, user_id: *const [evt.event_id_size]u8, notif_id: *const [evt.event_id_size]u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notif_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, notif_map_key)));
            const time = (try readTime(ctx.arena, records.readOnly(), ctx.notif_id)) orelse return error.CancelTransaction;
            try removeNotif(moment, records, ctx.notif_id, time);
        }
    };

    try transact(io, allocator, users_path, user_id, Ctx{ .arena = &arena, .notif_id = notif_id });
}

// up to `count` notifs from `start`, newest first. `moment` is the user repo's latest.
pub fn readRecent(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, start: u64, count: usize) ![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const recent_cursor = try moment.getCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)) orelse return items.items;
    const recent = try UserDB.SortedSet(.read_only).init(recent_cursor);

    var iter = try recent.iteratorFromIndex(start);
    while (items.items.len < count) {
        const kv_cursor = (try iter.next()) orelse break;
        const id = try evt.readOrderKeyId(UserDB, kv_cursor);
        try items.append(arena.allocator(), (try readItem(moment, arena, &id)) orelse return error.NotFound);
    }
    return items.items;
}

// the notif `id` names with its read state, or null when the user has none. `moment` is the user repo's latest.
pub fn readItem(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, id: *const [evt.event_id_size]u8) !?Item {
    const records_cursor = try moment.getCursor(hash.hashInt(hash_kind, notif_map_key)) orelse return null;
    const record_cursor = try (try UserDB.HashMap(.read_only).init(records_cursor)).getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    const notif = try evt.read(Notif, UserDB, hash_kind, arena, try UserDB.HashMap(.read_only).init(record_cursor));
    const unread_cursor = try moment.getCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)) orelse return .{ .notif = notif, .unread = false };
    const unread = try (try UserDB.SortedSet(.read_only).init(unread_cursor)).contains(&evt.orderKeyDesc(notif.time, id));
    return .{ .notif = notif, .unread = unread };
}

// a user repo's latest moment, or null before its first transaction
pub fn latestMoment(user_repo: *rp.Repo(.xit, evt.user_repo_opts)) !?UserDB.HashMap(.read_only) {
    return user_repo.core.latestMoment() catch |err| switch (err) {
        error.DatabaseIsEmpty => null,
        else => |e| e,
    };
}

// how many notifs are unread. `moment` is the user repo's latest.
pub fn unreadCount(moment: UserDB.HashMap(.read_only)) !u64 {
    const unread_cursor = try moment.getCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)) orelse return 0;
    return try (try UserDB.SortedSet(.read_only).init(unread_cursor)).count();
}

// notify `user_id` of the thread `thread_id` in the repo at `location` by
// choice, unless a tier already holds them or the subscribed tier is full
pub fn subscribe(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !void {
    {
        var owner_repo = (try evt.openUserRepo(io, allocator, users_path, &location.owner_id)) orelse return error.NotFound;
        defer owner_repo.deinit(io, allocator);
        const moment = try owner_repo.core.latestMoment();
        const notif_id = idOf(&location.repo_id, thread_id);
        if (try isNotified(moment, &notif_id, user_id)) return;
        if (try tierFull(moment, &notif_id, .subscribed)) return;
    }
    try writeMode(io, allocator, users_path, user_id, &location, thread_id, .subscribed, author);
}

// never notify `user_id` of the thread `thread_id` in the repo at `location`, dropping its notif
pub fn mute(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !void {
    try writeMode(io, allocator, users_path, user_id, &location, thread_id, .muted, author);
    try dismiss(io, allocator, users_path, user_id, &idOf(&location.repo_id, thread_id));
}

// write the user's notify event for a thread, then move them to its tier in the owner's index
pub fn writeMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
    author: evt.CommitAuthor,
) !void {
    {
        var user_repo = (try evt.openUserRepo(io, allocator, users_path, user_id)) orelse return error.NotFound;
        defer user_repo.deinit(io, allocator);
        try evt.consume(.{ .server = .{ .users_path = users_path } }, .user, .xit, evt.user_repo_opts, io, allocator, &user_repo, evt.events_ref, &[_]evt.EventWithId{.{
            .id = std.fmt.bytesToHex(evt.Notify.idOf(&location.repo_id, thread_id), .lower),
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
            .author = author,
            .event = .{ .notify = .{
                .owner_id = std.fmt.bytesToHex(location.owner_id, .lower),
                .repo_id = std.fmt.bytesToHex(location.repo_id, .lower),
                .thread_id = std.fmt.bytesToHex(thread_id.*, .lower),
                .mode = mode,
            } },
        }});
    }
    indexMode(io, allocator, users_path, location, thread_id, user_id, mode);
}

// move `user_id` to `mode`'s tier on the thread in its repo owner's index, or
// out of every tier for a mute, logging rather than returning a failure
fn indexMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
) void {
    const Ctx = struct {
        notif_id: [evt.event_id_size]u8,
        user_id: *const [evt.event_id_size]u8,
        mode: evt.Notify.Mode,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            inline for (comptime std.enums.values(evt.Notify.Mode)) |tier_mode| {
                if (comptime tierOf(tier_mode)) |tier| {
                    const sets = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, tier.map_key)));
                    const users = try UserDB.SortedSet(.read_write).init(try sets.putCursor(hash.hashInt(hash_kind, &ctx.notif_id)));
                    if (tier_mode == ctx.mode) try users.put(ctx.user_id) else _ = try users.remove(ctx.user_id);
                }
            }
        }
    };

    transact(io, allocator, users_path, &location.owner_id, Ctx{
        .notif_id = idOf(&location.repo_id, thread_id),
        .user_id = user_id,
        .mode = mode,
    }) catch |err| {
        std.log.warn("failed to index thread notify mode: {s}", .{@errorName(err)});
    };
}

// put the users `events` show taking part in their threads in a tier, the
// threads' authors and the assignees as involved and the commenters as
// commented. logs rather than returning a failure.
pub fn subscribeParticipants(io: std.Io, allocator: std.mem.Allocator, server: evt.Host.Server, repo_path: []const u8, events: []const evt.EventWithId) void {
    const admin_repo_path = server.admin_repo_path orelse return;
    const location = evt.parseRepoPath(server.users_path, repo_path) orelse return;
    subscribeEach(io, allocator, server.users_path, admin_repo_path, location, events) catch |err| {
        std.log.warn("failed to subscribe thread participants: {s}", .{@errorName(err)});
    };
}

fn subscribeEach(io: std.Io, allocator: std.mem.Allocator, users_path: []const u8, admin_repo_path: []const u8, location: evt.RepoLocation, events: []const evt.EventWithId) !void {
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for (events) |event| {
        const thread_hex: [evt.event_id_size * 2]u8, const email: []const u8, const mode: evt.Notify.Mode = switch (event.event) {
            inline .discuss, .issue, .patch => |thread| if (thread != null) .{ event.id, event.author.email, .involved } else continue,
            .comment => |comment_maybe| if (comment_maybe) |comment| .{ comment.thread_id, event.author.email, .commented } else continue,
            .assign => |assign_maybe| if (assign_maybe) |assign| .{ assign.thread_id, assign.email, .involved } else continue,
            else => continue,
        };
        const user_id = (try evt.User.readIdByEmail(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, email)) orelse continue;
        const thread_id = try evt.parseEventId(&thread_hex);
        // a mute stands, and a record only ever moves up to involved
        {
            var user_repo = (try evt.openUserRepo(io, allocator, users_path, &user_id)) orelse continue;
            defer user_repo.deinit(io, allocator);
            if (try evt.userMoment(&user_repo)) |moment| {
                if (try evt.Notify.readMode(UserDB, hash_kind, moment, &arena, &location.repo_id, &thread_id)) |existing| {
                    if (mode != .involved or existing == .involved or existing == .muted) continue;
                }
            }
        }
        // a full commented tier takes nobody new, so a later comment checks again
        if (mode == .commented) {
            var owner_repo = (try evt.openUserRepo(io, allocator, users_path, &location.owner_id)) orelse return error.NotFound;
            defer owner_repo.deinit(io, allocator);
            if (try tierFull(try owner_repo.core.latestMoment(), &idOf(&location.repo_id, &thread_id), .commented)) continue;
        }
        // the write's own author, which for an assignment is the assigner
        try writeMode(io, allocator, users_path, &user_id, &location, &thread_id, mode, event.author);
    }
}

// the thread `notif_id` names' set under a tier's `map_key`, or null before its
// first user. `moment` is its repo owner's user repo's latest.
fn tierSet(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, map_key: []const u8) !?UserDB.SortedSet(.read_only) {
    const sets_cursor = try moment.getCursor(hash.hashInt(hash_kind, map_key)) orelse return null;
    const users_cursor = try (try UserDB.HashMap(.read_only).init(sets_cursor)).getCursor(hash.hashInt(hash_kind, notif_id)) orelse return null;
    return try UserDB.SortedSet(.read_only).init(users_cursor);
}

// the users in the tiers of the thread `notif_id` names. `moment` is its repo owner's user repo's latest.
pub fn readNotified(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, notif_id: *const [evt.event_id_size]u8) ![]const [evt.event_id_size]u8 {
    var user_ids: std.ArrayList([evt.event_id_size]u8) = .empty;
    inline for (comptime std.enums.values(evt.Notify.Mode)) |mode| {
        if (comptime tierOf(mode)) |tier| {
            if (try tierSet(moment, notif_id, tier.map_key)) |users| {
                var iter = try users.iteratorFromIndex(0);
                while (try iter.next()) |kv_cursor| {
                    var cursor = kv_cursor;
                    const kv_pair = try cursor.readKeyValuePair();
                    var user_id: [evt.event_id_size]u8 = undefined;
                    _ = try kv_pair.key_cursor.readBytes(&user_id);
                    try user_ids.append(arena.allocator(), user_id);
                }
            }
        }
    }
    return user_ids.items;
}

// whether a tier of the thread `notif_id` names holds `user_id`. `moment` is its repo owner's user repo's latest.
pub fn isNotified(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, user_id: *const [evt.event_id_size]u8) !bool {
    inline for (comptime std.enums.values(evt.Notify.Mode)) |mode| {
        if (comptime tierOf(mode)) |tier| {
            if (try tierSet(moment, notif_id, tier.map_key)) |users| {
                if (try users.contains(user_id)) return true;
            }
        }
    }
    return false;
}

// whether `mode`'s tier on the thread `notif_id` names is at its cap. `moment` is its repo owner's user repo's latest.
pub fn tierFull(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, comptime mode: evt.Notify.Mode) !bool {
    const tier = comptime tierOf(mode) orelse @compileError("a mute has no tier");
    const cap = tier.cap orelse return false;
    const users = (try tierSet(moment, notif_id, tier.map_key)) orelse return false;
    return try users.count() >= cap;
}

//
// delivery
//

// deliver the notifs of the comments and assignments the repo transaction at
// `moment_index` created, logging rather than returning a failure.
// `pusher_id` is the user who pushed it, if a push did.
pub fn deliverTransaction(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    moment_index: u64,
    pusher_id: ?*const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) void {
    const admin_repo_path = server.admin_repo_path orelse return;
    const location = evt.parseRepoPath(server.users_path, repo.core.work_path) orelse return;
    deliverEach(repo_opts, io, allocator, server.users_path, admin_repo_path, location, repo, moment_index, pusher_id, progress_ctx_maybe) catch |err| {
        std.log.warn("failed to deliver notifications: {s}", .{@errorName(err)});
    };
}

// a transaction's notifs, coalesced per user and thread
const Inboxes = struct {
    arena: *std.heap.ArenaAllocator,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    owner_moment: UserDB.HashMap(.read_only),
    repo: evt.Repo.Record,
    repo_id: *const [evt.event_id_size]u8,
    // whether each user is active and can read the repo
    readers: std.AutoHashMapUnmanaged([evt.event_id_size]u8, bool) = .empty,
    by_user: std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, std.ArrayList(Notif)) = .empty,

    fn add(self: *Inboxes, user_id: [evt.event_id_size]u8, notif: Notif) !void {
        if (!try self.canRead(user_id)) return;
        const entry = try self.by_user.getOrPut(self.arena.allocator(), user_id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // events arrive newest first, so a thread keeps its latest child
        for (entry.value_ptr.items) |existing| {
            if (std.mem.eql(u8, &existing.thread_id, &notif.thread_id)) return;
        }
        try entry.value_ptr.append(self.arena.allocator(), notif);
    }

    fn canRead(self: *Inboxes, user_id: [evt.event_id_size]u8) !bool {
        if (self.readers.get(user_id)) |can_read| return can_read;
        const can_read = if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, self.admin_moment, self.arena, &user_id)) |user|
            !user.removed and try evt.Repo.roleOf(UserDB, hash_kind, self.owner_moment, self.arena, self.repo, self.repo_id, user_id) != null
        else
            false;
        try self.readers.put(self.arena.allocator(), user_id, can_read);
        return can_read;
    }
};

fn deliverEach(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    admin_repo_path: []const u8,
    location: evt.RepoLocation,
    repo: *rp.Repo(.xit, repo_opts),
    moment_index: u64,
    pusher_id: ?*const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    const haxy_moment = try evt.currentMoment(repo_opts, repo);
    // the transaction's events, newest first
    const ids = (try evt.momentEventIds(DB, repo_opts.hash, haxy_moment, moment_index)) orelse return;

    var owner_repo = (try evt.openUserRepo(io, allocator, users_path, &location.owner_id)) orelse return;
    defer owner_repo.deinit(io, allocator);
    const owner_moment = (try evt.userMoment(&owner_repo)) orelse return;
    // the owner's plain data, which holds the tier index
    const owner_latest = try owner_repo.core.latestMoment();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const repo_record = (try evt.Repo.readById(UserDB, hash_kind, owner_moment, &arena, &location.repo_id)) orelse return;
    if (repo_record.removed) return;

    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
    defer admin_repo.deinit(io, allocator);

    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &location.owner_id)) orelse return;

    var inboxes: Inboxes = .{
        .arena = &arena,
        .admin_moment = admin_moment,
        .owner_moment = owner_moment,
        .repo = repo_record,
        .repo_id = &location.repo_id,
    };

    const kinds_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse return error.CursorNotFound;
    const kinds = try DB.HashMap(.read_only).init(kinds_cursor);

    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |kv_cursor| {
        var cursor = kv_cursor;
        const kv_pair = try cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try kv_pair.key_cursor.readBytes(&order_key);
        const id = order_key[@sizeOf(u64)..].*;
        const order = std.math.maxInt(u64) - std.mem.readInt(u64, order_key[0..@sizeOf(u64)], .big);

        // edits keep the created order, so only creations notify
        const Created = struct { thread_id: [evt.event_id_size * 2]u8, actor_email: ?[]const u8 };
        const created: Created = switch ((try evt.readEventKind(repo_opts.hash, kinds, &id)) orelse continue) {
            inline .comment, .assign => |kind| blk: {
                const Fields = struct { removed: bool, author_email: ?[]const u8, created_order: u64, event: struct { thread_id: [evt.event_id_size * 2]u8 } };
                const T = if (kind == .comment) evt.Comment else evt.Assignment;
                const record = (try evt.readRecordSubset(T, Fields, DB, repo_opts.hash, haxy_moment, &arena, &id)) orelse continue;
                if (record.removed or record.created_order != order) continue;
                break :blk .{ .thread_id = record.event.thread_id, .actor_email = record.author_email };
            },
            else => continue,
        };

        const thread_id = try evt.parseEventId(&created.thread_id);
        const Titled = struct { event: struct { title: []const u8 } };
        const thread_kind = (try evt.readEventKind(repo_opts.hash, kinds, &thread_id)) orelse continue;
        // nobody can open a thread in a hidden tab
        if (repo_record.event.threadRole(thread_kind) == null) continue;
        const thread = (switch (thread_kind) {
            .issue => try evt.readRecordSubset(evt.Issue, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            .patch => try evt.readRecordSubset(evt.Patch, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            .discuss => try evt.readRecordSubset(evt.Discussion, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            else => null,
        }) orelse continue;

        const notif: Notif = .{
            .repo_id = location.repo_id,
            .owner_name = owner.event.name,
            .repo_name = repo_record.event.name,
            .thread_id = thread_id,
            .thread_kind = thread_kind,
            .title = thread.event.title,
            .last_child_id = id,
        };

        // a user hears of no comment or assignment they made or pushed
        const actor_id = if (created.actor_email) |email| try evt.User.readIdByEmail(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, email) else null;
        for (try readNotified(owner_latest, &arena, &idOf(&location.repo_id, &thread_id))) |user_id| {
            if (actor_id) |actor| if (std.mem.eql(u8, &actor, &user_id)) continue;
            if (pusher_id) |pusher| if (std.mem.eql(u8, pusher, &user_id)) continue;
            try inboxes.add(user_id, notif);
        }
    }

    if (inboxes.by_user.count() == 0) return;
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Delivering notifications" });
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = inboxes.by_user.count() } });
    for (inboxes.by_user.keys(), inboxes.by_user.values()) |*user_id, notifs| {
        deliver(io, allocator, users_path, user_id, notifs.items) catch |err| {
            std.log.warn("failed to deliver notifications: {s}", .{@errorName(err)});
        };
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
    }
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
}

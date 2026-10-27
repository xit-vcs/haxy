const std = @import("std");
const evt = @import("../../event.zig");
const notify = @import("../../notify.zig");
const xit = @import("xit");
const rp = xit.repo;

const author = evt.CommitAuthor{ .name = "haxyuser", .email = "user@haxy" };
const repo_opts: rp.RepoOpts(.xit) = .{ .hash = .sha1 };

fn unreadCount(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8) !u64 {
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return error.TestUnexpectedResult;
    defer user_repo.deinit(io, allocator);
    return try notify.unreadCount(try user_repo.core.latestMoment());
}

fn readRecent(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8) ![]const notify.Item {
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return error.TestUnexpectedResult;
    defer user_repo.deinit(io, allocator);
    return try notify.readRecent(try user_repo.core.latestMoment(), arena, 0, notify.max_notifs + 10);
}

fn readMode(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8, repo_id: *const [evt.event_id_size]u8, thread_id: *const [evt.event_id_size]u8) !?evt.Notify.Mode {
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return error.TestUnexpectedResult;
    defer user_repo.deinit(io, allocator);
    const moment = (try evt.userMoment(&user_repo)) orelse return error.TestUnexpectedResult;
    return try evt.Notify.readMode(evt.UserDB, evt.user_repo_opts.hash, moment, arena, repo_id, thread_id);
}

fn readNotified(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, users_dir: []const u8, owner_id: *const [evt.event_id_size]u8, notif_id: *const [evt.event_id_size]u8) ![]const [evt.event_id_size]u8 {
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, owner_id)) orelse return error.TestUnexpectedResult;
    defer user_repo.deinit(io, allocator);
    return try notify.readNotified(try user_repo.core.latestMoment(), arena, notif_id);
}

fn initUserRepo(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8) !void {
    const path = try evt.userRepoPath(allocator, users_dir, user_id);
    defer allocator.free(path);
    var user_repo = try evt.initUserRepo(io, allocator, path);
    defer user_repo.deinit(io, allocator);
}

test "notifs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);
    const users_dir = try std.Io.Dir.path.join(allocator, &.{ temp_path, "users" });
    defer allocator.free(users_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const owner_id = evt.EventWithId.randomId(prng.random());
    const recipient_id = evt.EventWithId.randomId(prng.random());
    for ([_]*const [evt.event_id_size]u8{ &owner_id, &recipient_id }) |user_id| try initUserRepo(io, allocator, users_dir, user_id);
    const location = try evt.createRepo(io, allocator, users_dir, &owner_id, author, "repo", "", .private, repo_opts.hash, null);

    //
    // notifs
    //

    const thread_a = evt.EventWithId.randomId(prng.random());
    const thread_b = evt.EventWithId.randomId(prng.random());
    var child_ids: [4][evt.event_id_size]u8 = undefined;
    for (&child_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());
    const notif_a: notify.Notif = .{
        .repo_id = location.repo_id,
        .owner_name = "owner",
        .repo_name = "repo",
        .thread_id = thread_a,
        .thread_kind = .issue,
        .title = "a",
        .last_child_id = child_ids[0],
    };
    var notif_b = notif_a;
    notif_b.thread_id = thread_b;
    notif_b.title = "b";
    notif_b.last_child_id = child_ids[1];
    const id_a = notify.idOf(&location.repo_id, &thread_a);

    try notify.deliver(io, allocator, users_dir, &recipient_id, &.{ notif_a, notif_b });
    try std.testing.expectEqual(2, try unreadCount(io, allocator, users_dir, &recipient_id));
    try std.testing.expectEqual(2, (try readRecent(io, allocator, &arena, users_dir, &recipient_id)).len);

    // a bump updates the thread's one notif. times tie within a second, so order isn't checked.
    var bump = notif_a;
    bump.last_child_id = child_ids[2];
    try notify.deliver(io, allocator, users_dir, &recipient_id, &.{bump});
    bump.last_child_id = child_ids[3];
    try notify.deliver(io, allocator, users_dir, &recipient_id, &.{bump});
    {
        const recent = try readRecent(io, allocator, &arena, users_dir, &recipient_id);
        try std.testing.expectEqual(2, recent.len);
        for (recent) |item| {
            if (std.mem.eql(u8, &item.notif.thread_id, &thread_a)) try std.testing.expectEqualSlices(u8, &child_ids[3], &item.notif.last_child_id);
        }
    }

    // a read of a child the thread has moved past leaves it unread
    try notify.markRead(io, allocator, users_dir, &recipient_id, &id_a, &child_ids[2]);
    try std.testing.expectEqual(2, try unreadCount(io, allocator, users_dir, &recipient_id));
    try notify.markRead(io, allocator, users_dir, &recipient_id, &id_a, &child_ids[3]);
    try std.testing.expectEqual(1, try unreadCount(io, allocator, users_dir, &recipient_id));
    for (try readRecent(io, allocator, &arena, users_dir, &recipient_id)) |item| {
        try std.testing.expectEqual(!std.mem.eql(u8, &item.notif.thread_id, &thread_a), item.unread);
    }

    try notify.dismiss(io, allocator, users_dir, &recipient_id, &id_a);
    {
        const recent = try readRecent(io, allocator, &arena, users_dir, &recipient_id);
        try std.testing.expectEqual(1, recent.len);
        try std.testing.expectEqualSlices(u8, &thread_b, &recent[0].notif.thread_id);
    }

    //
    // notify records
    //

    // muting a thread drops its notif
    try notify.mute(io, allocator, users_dir, &recipient_id, location, &thread_b, author);
    try std.testing.expectEqual(0, (try readRecent(io, allocator, &arena, users_dir, &recipient_id)).len);

    // subscribing replaces the mute record and indexes the subscriber in the owner's repo
    const id_b = notify.idOf(&location.repo_id, &thread_b);
    try std.testing.expectEqual(.muted, try readMode(io, allocator, &arena, users_dir, &recipient_id, &location.repo_id, &thread_b));
    try notify.subscribe(io, allocator, users_dir, &recipient_id, location, &thread_b, author);
    try std.testing.expectEqual(.subscribed, try readMode(io, allocator, &arena, users_dir, &recipient_id, &location.repo_id, &thread_b));
    try notify.deliver(io, allocator, users_dir, &recipient_id, &.{notif_b});
    try std.testing.expectEqual(1, (try readRecent(io, allocator, &arena, users_dir, &recipient_id)).len);
    {
        const notified = try readNotified(io, allocator, &arena, users_dir, &owner_id, &id_b);
        try std.testing.expectEqual(1, notified.len);
        try std.testing.expectEqualSlices(u8, &recipient_id, &notified[0]);
    }

    // muting drops the subscriber from the index
    try notify.mute(io, allocator, users_dir, &recipient_id, location, &thread_b, author);
    try std.testing.expectEqual(0, (try readNotified(io, allocator, &arena, users_dir, &owner_id, &id_b)).len);

    // a full subscribed tier refuses one more
    for (0..notify.max_subscribed) |_| {
        const user_id = evt.EventWithId.randomId(prng.random());
        try initUserRepo(io, allocator, users_dir, &user_id);
        try notify.subscribe(io, allocator, users_dir, &user_id, location, &thread_a, author);
    }
    try notify.subscribe(io, allocator, users_dir, &recipient_id, location, &thread_a, author);
    try std.testing.expectEqual(null, try readMode(io, allocator, &arena, users_dir, &recipient_id, &location.repo_id, &thread_a));

    // past the cap, the oldest go. times tie within a second, so which one goes isn't checked.
    {
        const many = try allocator.alloc(notify.Notif, notify.max_notifs + 1);
        defer allocator.free(many);
        for (many, 0..) |*notif, i| {
            notif.* = notif_a;
            notif.thread_id = @splat(0);
            std.mem.writeInt(u64, notif.thread_id[0..@sizeOf(u64)], i, .big);
        }
        try notify.deliver(io, allocator, users_dir, &recipient_id, many);
    }
    try std.testing.expectEqual(notify.max_notifs, (try readRecent(io, allocator, &arena, users_dir, &recipient_id)).len);
}

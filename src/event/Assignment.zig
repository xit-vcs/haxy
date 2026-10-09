const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

thread_id: [evt.event_id_size * 2]u8,
email: []const u8,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->assignment";
pub const all_id_set_key = "assignment-id-set";

// the index a thread's view reads
pub const thread_id_to_assignment_id_set_key = "thread-id->assignment-id-set";
// the issues each email is assigned to, keyed like the issue status sets
pub const assignee_to_issue_id_set_key = "assignee->issue-id-set";

// the longest email an assignment holds
pub const email_max_len = 254;

// the id of the one assignment an email can hold on a thread
pub fn idOf(thread_id: *const [evt.event_id_size]u8, email: []const u8) [evt.event_id_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(thread_id);
    hasher.update(email);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..evt.event_id_size].*;
}

fn emailValid(email: []const u8) bool {
    if (email.len == 0 or email.len > email_max_len) return false;
    for (email) |ch| {
        if (std.ascii.isWhitespace(ch)) return false;
    }
    return true;
}

// only what the event says about itself is checked. an assignment naming a
// missing thread is inert.
fn validate(event_id: *const [evt.event_id_size]u8, record: Record) !void {
    const thread_id = try evt.parseEventId(&record.event.thread_id);
    if (!emailValid(record.event.email)) return error.InvalidEmail;
    if (!std.mem.eql(u8, event_id, &idOf(&thread_id, record.event.email))) return error.InvalidAssignmentId;
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
    const assignment_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const by_thread = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, thread_id_to_assignment_id_set_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(assignment_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!record.removed) try validate(event_id, record);

    if (existing_maybe) |existing| {
        // updates preserve the original creation metadata
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
    }

    const assignment_cursor = try records.putCursor(assignment_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(assignment_cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .assign, existing_maybe, record);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&evt.orderKeyDesc(record.created_order, event_id));
    }

    // the thread's set holds active assignments only, oldest first. the id
    // fixes the thread, so an assignment never moves between sets.
    const order_key = evt.orderKey(record.created_order, event_id);
    const thread_assignments = try DB.SortedSet(.read_write).init(try by_thread.putCursor(hash.hashInt(hash_kind, &record.event.thread_id)));
    if (record.removed) {
        _ = try thread_assignments.remove(&order_key);
    } else {
        try thread_assignments.put(&order_key);
    }

    // only an issue is indexed by assignee
    const thread_id = try evt.parseEventId(&record.event.thread_id);
    const issue = (try evt.readRecordSubset(evt.Issue, struct { created_order: u64, removed: bool }, DB, hash_kind, haxy_moment.readOnly(), arena, &thread_id)) orelse return;
    try indexIssue(DB, hash_kind, haxy_moment, record.event.email, &evt.orderKeyDesc(issue.created_order, &thread_id), !record.removed and !issue.removed);
}

// put or drop an issue's order key in `email`'s assignee set, pruning an emptied set
pub fn indexIssue(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    email: []const u8,
    order_key: []const u8,
    active: bool,
) !void {
    const by_assignee = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, assignee_to_issue_id_set_key)));
    const email_key = hash.hashInt(hash_kind, email);
    if (active) {
        const issues = try DB.SortedSet(.read_write).init(try by_assignee.putCursor(email_key));
        try issues.put(order_key);
        return;
    }
    if (null == try by_assignee.getCursor(email_key)) return;
    const issues = try DB.SortedSet(.read_write).init(try by_assignee.putCursor(email_key));
    _ = try issues.remove(order_key);
    if (0 == try issues.count()) _ = try by_assignee.remove(email_key);
}

// assign `email` to a thread and return the event id. `repo` must be writable.
pub fn create(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size * 2]u8,
    email: []const u8,
    author: evt.CommitAuthor,
) ![evt.event_id_size * 2]u8 {
    if (!emailValid(email)) return error.InvalidFields;

    const thread_id_bytes = evt.parseEventId(thread_id) catch return error.NotFound;
    if (!try evt.threadHolds(repo_kind, repo_opts, io, allocator, repo, thread_kind, &thread_id_bytes, null)) return error.NotFound;

    const id_bytes = idOf(&thread_id_bytes, email);
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (try evt.readFromRepo(Self, repo_kind, repo_opts, io, allocator, &arena, repo, &id_bytes)) |existing| {
            if (!existing.removed) return error.AlreadyAssigned;
        }
    }

    const event_id = std.fmt.bytesToHex(id_bytes, .lower);
    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = event_id,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .assign = .{ .thread_id = thread_id.*, .email = email } },
    }});
    return event_id;
}

// read an assignment by event id, or null if the id isn't a known assignment
pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    assignment_id: []const u8,
) !?Record {
    return try evt.readRecordSubset(Self, Record, DB, hash_kind, haxy_moment, arena, assignment_id);
}

// the emails assigned to a thread, oldest first
pub fn load(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    thread_id: []const u8,
) ![]const []const u8 {
    const DB = evt.EventDB(hash_kind);
    var emails: std.ArrayList([]const u8) = .empty;
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, thread_id_to_assignment_id_set_key)) orelse return emails.items;
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const set_cursor = try index.getCursor(hash.hashInt(hash_kind, thread_id)) orelse return emails.items;
    const set = try DB.SortedSet(.read_only).init(set_cursor);

    var iter = try set.iteratorFromIndex(0);
    while (try iter.next()) |kv_cursor| {
        const id_bytes = try evt.readOrderKeyId(DB, kv_cursor);
        const record = (try evt.readRecordSubset(Self, struct { event: struct { email: []const u8 } }, DB, hash_kind, haxy_moment, arena, &id_bytes)) orelse continue;
        try emails.append(arena.allocator(), record.event.email);
    }
    return emails.items;
}

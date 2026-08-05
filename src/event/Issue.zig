const std = @import("std");
const evt = @import("../event.zig");
const diff3 = @import("../diff3.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8, // space-separated
status: Status = .open,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    author_email: ?[]const u8 = null,
    created_ts: u64 = 0, // the commit timestamp of the event that first created this issue
};

const Self = @This();

pub const Status = enum {
    open,
    closed,

    const longest_len = blk: {
        var len: usize = 0;
        for (@typeInfo(Status).@"enum".fields) |field| len = @max(len, field.name.len);
        break :blk len;
    };
};

pub const tag_max_len = 64;

// the moment keys `evt.merge` reads and writes for this kind
pub const record_map_key = "event-id->issue";
pub const id_set_key = "issue-id-set";
pub const conflicts_key = "conflicted-issue-id->conflict";
pub const id_to_field_to_oid_key = "issue-id->field->oid";

// a "tag status" key names a tag's per-status issue set (tags can't contain
// spaces, so the pair is unambiguous)
pub const TagStatusKey = [tag_max_len + 1 + Status.longest_len]u8;

pub fn tagStatusKey(buffer: *TagStatusKey, tag: []const u8, status: Status) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ tag, @tagName(status) });
}

pub fn tagIterator(tags: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, tags, ' ');
}

// a title is required, and a too-long tag would go unindexed once consumed
pub fn fieldsValid(title: []const u8, tags: []const u8) bool {
    if (title.len == 0) return false;
    var tag_iter = tagIterator(tags);
    while (tag_iter.next()) |tag| {
        if (tag.len > tag_max_len) return false;
    }
    return true;
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    // the commit this event came from, recorded against every field it
    // changes. null from `merge`, which sets oids and conflicts itself.
    event_oid: ?[]const u8,
) !void {
    const issue_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "event-id->issue"));
    const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

    // the per-status sets the issues views list, ordered by creation time,
    // keyed by status name
    const status_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "status->issue-id-set"));
    const status_to_issues = try DB.SortedMap(.read_write).init(status_to_issues_cursor);

    // the per-tag, per-status sets, keyed "tag,status"
    const tag_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, "tag+status->issue-id-set"));
    const tag_to_issues = try DB.SortedMap(.read_write).init(tag_to_issues_cursor);

    const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key));
    const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);

    const issue_id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key));
    const issue_id_to_field_to_oid = try DB.HashMap(.read_write).init(issue_id_to_field_to_oid_cursor);

    if (record_maybe) |record| {
        var record_to_write = record;

        var existing_record_maybe: ?Record = null;
        const existing_cursor_maybe = try event_id_to_issue.getCursor(issue_key);
        if (existing_cursor_maybe) |existing_cursor| {
            // updates preserve the original creation timestamp and author
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_record = try evt.read(Record, DB, hash_kind, arena, existing_issue);
            existing_record_maybe = existing_record;
            record_to_write.created_ts = existing_record.created_ts;
            record_to_write.author_email = existing_record.author_email;

            // drop the old status's and tags' entries; the current ones are re-added below
            const order_key = evt.orderKeyDesc(existing_record.created_ts, event_id);
            const status_set = try statusSet(DB, status_to_issues, existing_record.event.status);
            _ = try status_set.remove(&order_key);
            try removeFromTagSets(DB, tag_to_issues, existing_record.event.tags, existing_record.event.status, &order_key);

            // any event settles the conflict, since resolving in the ui may
            // keep our own values and so change nothing to detect
            if (event_oid != null) _ = try conflicts.remove(&order_key);
        }

        try evt.writeOid(Self, DB, hash_kind, issue_id_to_field_to_oid, issue_key, if (existing_record_maybe) |existing| existing.event else null, record.event, event_oid);

        const issue_cursor = try event_id_to_issue.putCursor(issue_key);
        const issue = try DB.HashMap(.read_write).init(issue_cursor);
        try evt.upsert(Record, DB, hash_kind, issue, record_to_write);

        const order_key = evt.orderKeyDesc(record_to_write.created_ts, event_id);

        // first time we've seen this issue: add it to the set that enumerates
        // every issue regardless of status
        if (existing_cursor_maybe == null) {
            const issue_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key));
            const issue_id_set = try DB.SortedSet(.read_write).init(issue_id_set_cursor);
            try issue_id_set.put(&order_key);
        }

        const status_set = try statusSet(DB, status_to_issues, record.event.status);
        try status_set.put(&order_key);

        var tag_iter = tagIterator(record.event.tags);
        while (tag_iter.next()) |tag| {
            // an over-long tag goes unindexed rather than failing the consume,
            // which would wedge the branch it arrived on
            if (tag.len == 0 or tag.len > tag_max_len) continue;
            var key_buffer: TagStatusKey = undefined;
            const tag_set_cursor = try tag_to_issues.putCursor(try tagStatusKey(&key_buffer, tag, record.event.status));
            const tag_set = try DB.SortedSet(.read_write).init(tag_set_cursor);
            try tag_set.put(&order_key);
        }
    } else {
        // drop it from the ordered sets using its recorded creation timestamp and status
        if (try event_id_to_issue.getCursor(issue_key)) |existing_cursor| {
            const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
            const existing_record = try evt.read(Record, DB, hash_kind, arena, existing_issue);
            const order_key = evt.orderKeyDesc(existing_record.created_ts, event_id);

            const status_set = try statusSet(DB, status_to_issues, existing_record.event.status);
            _ = try status_set.remove(&order_key);

            try removeFromTagSets(DB, tag_to_issues, existing_record.event.tags, existing_record.event.status, &order_key);

            const issue_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key));
            const issue_id_set = try DB.SortedSet(.read_write).init(issue_id_set_cursor);
            _ = try issue_id_set.remove(&order_key);

            _ = try conflicts.remove(&order_key);
            _ = try issue_id_to_field_to_oid.remove(issue_key);
        }
        if (!try event_id_to_issue.remove(issue_key)) return error.EventNotFound;
    }
}

// `status`'s sorted set within `statuses`, keyed by status name
fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_write),
    status: Status,
) !DB.SortedSet(.read_write) {
    const cursor = try statuses.putCursor(@tagName(status));
    return DB.SortedSet(.read_write).init(cursor);
}

// the resolve form's inputs: null fields keep the live values, `hunks` holds
// the description conflict hunks' resolutions in chunk order (absent
// trailing ones keep our side)
pub const Resolve = struct {
    title: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    hunks: []const []const u8 = &.{},
};

// what an update replaces on an issue: its status, its content, or — for a
// conflicted issue — the resolution of its conflict
pub const Update = union(enum) {
    status: Status,
    fields: struct { title: []const u8, tags: []const u8, description: []const u8 },
    resolve: Resolve,
};

// re-emit the issue `id_bytes` names with `change` applied, preserving the
// rest of its current state. error.NotFound when the id names no issue,
// error.InvalidFields when a resolve composes invalid fields. `repo` must be
// writable.
pub fn update(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
    change: Update,
    author_email: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const issue = (try readById(repo_kind, repo_opts, io, allocator, &arena, repo, id_bytes)) orelse return error.NotFound;

    var updated = issue.event;
    switch (change) {
        .status => |status| {
            if (updated.status == status) return;
            updated.status = status;
        },
        .fields => |fields| {
            updated.title = fields.title;
            updated.tags = fields.tags;
            updated.description = fields.description;
        },
        .resolve => |resolve| {
            updated = try resolveFields(repo_kind, repo_opts, io, allocator, &arena, repo, id_bytes, issue, resolve);
            if (!fieldsValid(updated.title, updated.tags)) return error.InvalidFields;
        },
    }

    try evt.consume(repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &[_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(id_bytes.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author_email = author_email,
        .event = .{ .issue = updated },
    }});
}

// the live fields with `resolve` applied: posted title/tags stand in for the
// live ones, and a conflicted description is reassembled from the hunk
// resolutions against the conflict entry. the chunking is deterministic: the
// entry holds immutable slots and any event since would have removed it, so
// the hunks match what the resolve form was built from. a settled or
// unreadable entry keeps the live description.
fn resolveFields(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
    live: Record,
    resolve: Resolve,
) !Self {
    const DB = evt.EventDB(repo_opts.hash);
    const aa = arena.allocator();

    var updated = live.event;
    if (resolve.title) |title| updated.title = title;
    if (resolve.tags) |tags| updated.tags = tags;

    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return updated
    else
        evt.currentMoment(repo_opts, repo)) catch return updated;

    const conflicts_cursor = (try moment.getCursor(hash.hashInt(repo_opts.hash, conflicts_key))) orelse return updated;
    const conflicts = try DB.SortedMap(.read_only).init(conflicts_cursor);
    const order_key = evt.orderKeyDesc(live.created_ts, id_bytes);
    const conflict_cursor = (try conflicts.getCursor(&order_key)) orelse return updated;
    const entry = try DB.HashMap(.read_only).init(conflict_cursor);

    const fields_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key))) orelse return updated;
    const conflicted_fields = try fields_cursor.readBytesAlloc(aa, null);
    if (std.mem.indexOf(u8, conflicted_fields, "description") == null) return updated;

    const their_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key))) orelse return updated;
    const theirs = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(their_cursor));

    // absent when both sides created the issue independently
    var base_description: []const u8 = "";
    if (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.base_record_key))) |base_cursor| {
        const base = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(base_cursor));
        base_description = base.event.description;
    }

    const chunks = try diff3.chunks(io, allocator, arena, base_description, live.event.description, theirs.event.description);
    var resolutions: std.ArrayList([]const u8) = .empty;
    var hunk_index: usize = 0;
    for (chunks) |chunk| {
        if (chunk != .conflict) continue;
        try resolutions.append(aa, if (hunk_index < resolve.hunks.len) resolve.hunks[hunk_index] else (chunk.conflict.ours orelse ""));
        hunk_index += 1;
    }
    updated.description = try diff3.assemble(aa, chunks, resolutions.items);
    return updated;
}

// the issue `id_bytes` names in the repo's consumed event db (the repo's own
// db for xit; the side db next to a git repo), or null
fn readById(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
) !?Record {
    const DB = evt.EventDB(repo_opts.hash);
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return null
    else
        evt.currentMoment(repo_opts, repo)) catch return null;
    const event_id_to_issue_cursor = (try moment.getCursor(hash.hashInt(repo_opts.hash, "event-id->issue"))) orelse return null;
    const event_id_to_issue = try DB.HashMap(.read_only).init(event_id_to_issue_cursor);
    const issue_cursor = (try event_id_to_issue.getCursor(hash.hashInt(repo_opts.hash, id_bytes))) orelse return null;
    const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
    return try evt.read(Record, DB, repo_opts.hash, arena, issue_map);
}

// remove an issue's order key from its tags' `status` sets, pruning entries
// whose set becomes empty
fn removeFromTagSets(
    comptime DB: type,
    tag_to_issues: DB.SortedMap(.read_write),
    tags: []const u8,
    status: Status,
    order_key: []const u8,
) !void {
    var tag_iter = tagIterator(tags);
    while (tag_iter.next()) |tag| {
        // skipped the same way consume skipped it, so it was never indexed
        if (tag.len == 0 or tag.len > tag_max_len) continue;
        var key_buffer: TagStatusKey = undefined;
        const key = try tagStatusKey(&key_buffer, tag, status);
        const tag_set_cursor = try tag_to_issues.putCursor(key);
        const tag_set = try DB.SortedSet(.read_write).init(tag_set_cursor);
        _ = try tag_set.remove(order_key);
        if (0 == try tag_set.count()) _ = try tag_to_issues.remove(key);
    }
}

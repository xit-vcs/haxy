const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8, // space-separated
target_patch_id: ?[evt.event_id_size * 2]u8 = null,
revision: ?Revision = null,
status: Status = .open,

pub const Revision = struct {
    id: [evt.event_id_size * 2]u8,
    squash_oid: []const u8,
    source_oid: []const u8,
    target_ref: []const u8,

    pub fn fromRecord(id: [evt.event_id_size]u8, record: evt.PatchRev.Record) Revision {
        return .{
            .id = std.fmt.bytesToHex(id, .lower),
            .squash_oid = record.patch_oid,
            .source_oid = record.event.source_oid,
            .target_ref = record.event.target_ref,
        };
    }

    pub fn matches(self: Revision, record: evt.PatchRev.Record) bool {
        return !record.removed and
            std.mem.eql(u8, record.patch_oid, self.squash_oid) and
            std.mem.eql(u8, record.event.source_oid, self.source_oid) and
            std.mem.eql(u8, record.event.target_ref, self.target_ref);
    }
};

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
};

const Self = @This();

pub const Status = enum {
    open,
    closed,
    merged,

    const longest_len = blk: {
        var len: usize = 0;
        for (@typeInfo(Status).@"enum".fields) |field| len = @max(len, field.name.len);
        break :blk len;
    };
};

pub const tag_max_len = 64;
pub const merge_policy: evt.MergePolicy = .field_conflicts;
pub const record_map_key = "event-id->patch";
pub const id_set_key = "patch-id-set";
pub const conflicts_key = "conflicted-patch-id->conflict";
pub const id_to_field_to_oid_key = "patch-id->field->oid";
pub const target_patch_id_to_patch_id_set_key = "target-patch-id->patch-id-set";
pub const status_to_id_set_key = "status->patch-id-set";
pub const tag_status_to_id_set_key = "tag+status->patch-id-set";
pub const revision_to_id_set_key = "target-ref+oid->patch-id-set";

pub const TagStatusKey = [tag_max_len + 1 + Status.longest_len]u8;

pub fn tagStatusKey(buffer: *TagStatusKey, tag: []const u8, status: Status) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ tag, @tagName(status) });
}

pub fn tagIterator(tags: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, tags, ' ');
}

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
    event_oid: ?[]const u8,
) !void {
    const record_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const statuses = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, status_to_id_set_key)));
    const tag_statuses = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, tag_status_to_id_set_key)));
    const conflicts = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key)));
    const field_oid_map = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(record_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = if (record_maybe) |value|
        value
    else blk: {
        var value = existing_maybe orelse return error.EventNotFound;
        value.removed = true;
        break :blk value;
    };

    if (!fieldsValid(record.event.title, record.event.tags)) return error.InvalidPatch;
    const revision_id = if (record.event.revision) |*revision| blk: {
        try evt.PatchRev.validateOid(hash_kind, revision.squash_oid);
        try evt.PatchRev.validateOid(hash_kind, revision.source_oid);
        try evt.PatchRev.validateTarget(revision.target_ref);
        break :blk try evt.parseEventId(&revision.id);
    } else null;
    const target_patch_id = if (record.event.target_patch_id) |*id| try evt.parseEventId(id) else null;
    if (target_patch_id) |*id| {
        if (std.mem.eql(u8, id, event_id)) return error.InvalidPatch;
    }

    if (existing_maybe) |existing| {
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
        if (existing.event.status == .merged and record.event.status != .merged) return error.PatchAlreadyMerged;
        if (event_oid != null) {
            if (!std.meta.eql(existing.event.target_patch_id, record.event.target_patch_id)) {
                return error.TargetPatchChanged;
            }
        }
    }

    if (record.event.status == .merged) {
        const id = revision_id orelse return error.InvalidPatch;
        const selected = record.event.revision orelse return error.InvalidPatch;
        const revision = (try evt.PatchRev.readById(DB, hash_kind, haxy_moment.readOnly(), arena, &id)) orelse return error.InvalidPatch;
        if (!selected.matches(revision)) return error.InvalidPatch;
    }

    const order_key = evt.orderKeyDesc(record.created_order, event_id);
    if (existing_maybe) |existing| {
        if (event_oid != null or record.removed) _ = try conflicts.remove(&order_key);
        if (!existing.removed) {
            const old_status = try statusSet(DB, statuses, existing.event.status);
            _ = try old_status.remove(&order_key);
            try removeFromTagSets(DB, tag_statuses, existing.event.tags, existing.event.status, &order_key);
            if (existing.event.status != .merged) {
                if (existing.event.revision) |revision| {
                    const revisions = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, revision_to_id_set_key)));
                    for ([_][]const u8{ revision.squash_oid, revision.source_oid }, 0..) |oid, i| {
                        if (i != 0 and std.mem.eql(u8, revision.squash_oid, revision.source_oid)) continue;
                        const key_hash = hash.hashInt(hash_kind, try revisionKey(arena.allocator(), revision.target_ref, oid));
                        const ids = try DB.CountedHashSet(.read_write).init(try revisions.putCursor(key_hash));
                        _ = try ids.remove(record_key);
                        if (try ids.count() == 0) _ = try revisions.remove(key_hash);
                    }
                }
            }
        }
    }

    try evt.writeOid(Self, DB, hash_kind, field_oid_map, record_key, if (existing_maybe) |existing| existing.event else null, record.event, event_oid);

    const cursor = try records.putCursor(record_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .patch, record.created_order, record.removed);

    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_set_key)));
        try ids.put(&order_key);
        if (target_patch_id) |*target_id| {
            const targets = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, target_patch_id_to_patch_id_set_key)));
            const children = try DB.SortedSet(.read_write).init(try targets.putCursor(hash.hashInt(hash_kind, target_id)));
            try children.put(&order_key);
        }
    }

    if (!record.removed) {
        const status = try statusSet(DB, statuses, record.event.status);
        try status.put(&order_key);

        var tag_iter = tagIterator(record.event.tags);
        while (tag_iter.next()) |tag| {
            if (tag.len == 0 or tag.len > tag_max_len) continue;
            var key_buffer: TagStatusKey = undefined;
            const set = try DB.SortedSet(.read_write).init(try tag_statuses.putCursor(try tagStatusKey(&key_buffer, tag, record.event.status)));
            try set.put(&order_key);
        }

        if (record.event.status != .merged) {
            if (record.event.revision) |revision| {
                const revisions = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, revision_to_id_set_key)));
                for ([_][]const u8{ revision.squash_oid, revision.source_oid }, 0..) |oid, i| {
                    if (i != 0 and std.mem.eql(u8, revision.squash_oid, revision.source_oid)) continue;
                    const key = try revisionKey(arena.allocator(), revision.target_ref, oid);
                    const ids = try DB.CountedHashSet(.read_write).init(try revisions.putCursor(hash.hashInt(hash_kind, key)));
                    try ids.put(record_key, .{ .bytes = event_id });
                }
            }
        }
    }
}

pub fn resolveMerge(
    target: Self,
    parent: Self,
    merged: *Self,
    outcome: *[std.meta.fields(Self).len]evt.FieldMerge,
) void {
    const status_index = std.meta.fieldIndex(Self, "status") orelse @compileError("Patch.status not found");
    const revision_index = std.meta.fieldIndex(Self, "revision") orelse @compileError("Patch.revision not found");
    if (outcome[status_index] != .conflicted or outcome[revision_index] == .conflicted) return;

    if (target.status == .merged and evt.fieldEqual(?Revision, target.revision, merged.revision)) {
        merged.status = .merged;
        outcome[status_index] = .kept;
    } else if (parent.status == .merged and evt.fieldEqual(?Revision, parent.revision, merged.revision)) {
        merged.status = .merged;
        outcome[status_index] = .parent;
    }
}

fn revisionKey(allocator: std.mem.Allocator, target_ref: []const u8, oid: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ target_ref, "\x00", oid });
}

fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_write),
    status: Status,
) !DB.SortedSet(.read_write) {
    return DB.SortedSet(.read_write).init(try statuses.putCursor(@tagName(status)));
}

fn removeFromTagSets(
    comptime DB: type,
    tag_statuses: DB.SortedMap(.read_write),
    tags: []const u8,
    status: Status,
    order_key: []const u8,
) !void {
    var tag_iter = tagIterator(tags);
    while (tag_iter.next()) |tag| {
        if (tag.len == 0 or tag.len > tag_max_len) continue;
        var key_buffer: TagStatusKey = undefined;
        const key = try tagStatusKey(&key_buffer, tag, status);
        const set = try DB.SortedSet(.read_write).init(try tag_statuses.putCursor(key));
        _ = try set.remove(order_key);
        if (0 == try set.count()) _ = try tag_statuses.remove(key);
    }
}

pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
}

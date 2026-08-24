const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

title: []const u8,
description: []const u8,
tags: []const u8, // space-separated
target_ref: []const u8,
target_patch_id: ?[evt.event_id_size * 2]u8 = null,
source_url: []const u8,
source_ref: []const u8,
patchrev_id: [evt.event_id_size * 2]u8,

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
};

const Self = @This();

pub const tag_max_len = 64;
pub const merge_policy: evt.MergePolicy = .field_conflicts;
pub const record_map_key = "event-id->patch";
pub const id_set_key = "patch-id-set";
pub const conflicts_key = "conflicted-patch-id->conflict";
pub const id_to_field_to_oid_key = "patch-id->field->oid";
pub const target_patch_id_to_patch_id_set_key = "target-patch-id->patch-id-set";

pub fn fieldsValid(title: []const u8, tags: []const u8) bool {
    if (title.len == 0) return false;
    var tag_iter = std.mem.splitScalar(u8, tags, ' ');
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

    if (!fieldsValid(record.event.title, record.event.tags) or
        record.event.target_ref.len == 0 or
        record.event.source_url.len == 0 or
        record.event.source_ref.len == 0)
    {
        return error.InvalidPatch;
    }
    const patchrev_id = try evt.parseEventId(&record.event.patchrev_id);
    const target_patch_id = if (record.event.target_patch_id) |*id| try evt.parseEventId(id) else null;
    if (target_patch_id) |*id| {
        if (std.mem.eql(u8, id, event_id)) return error.InvalidPatch;
    }

    if (existing_maybe) |existing| {
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
        if (event_oid != null) {
            if (!std.mem.eql(u8, existing.event.target_ref, record.event.target_ref) or
                !std.meta.eql(existing.event.target_patch_id, record.event.target_patch_id) or
                !std.mem.eql(u8, existing.event.source_url, record.event.source_url) or
                !std.mem.eql(u8, existing.event.source_ref, record.event.source_ref))
            {
                return error.PatchTargetChanged;
            }
        }
        if (event_oid != null or record.removed) {
            _ = try conflicts.remove(&evt.orderKeyDesc(existing.created_order, event_id));
        }
    }

    if (event_oid != null) {
        const changed = if (existing_maybe) |existing| !std.mem.eql(u8, &existing.event.patchrev_id, &record.event.patchrev_id) else true;
        if (changed) {
            const patchrev = (try evt.PatchRev.readById(DB, hash_kind, haxy_moment.readOnly(), arena, &patchrev_id)) orelse return error.PatchRevNotFound;
            if (patchrev.removed) return error.PatchRevNotFound;
            if (target_patch_id) |*target_id| {
                const target = (try readById(DB, hash_kind, haxy_moment.readOnly(), arena, target_id)) orelse return error.TargetPatchNotFound;
                if (target.removed) return error.TargetPatchNotFound;
                const target_patchrev_id = try evt.parseEventId(&target.event.patchrev_id);
                const target_patchrev = (try evt.PatchRev.readById(DB, hash_kind, haxy_moment.readOnly(), arena, &target_patchrev_id)) orelse return error.PatchRevNotFound;
                if (target_patchrev.removed) return error.PatchRevNotFound;
                if (!std.mem.eql(u8, patchrev.event.base_oid, target_patchrev.patch_oid) or
                    !std.mem.eql(u8, patchrev.base_tree_oid, target_patchrev.head_tree_oid))
                {
                    return error.InvalidPatchBase;
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
        try ids.put(&evt.orderKeyDesc(record.created_order, event_id));
        if (target_patch_id) |*target_id| {
            const targets = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, target_patch_id_to_patch_id_set_key)));
            const children = try DB.SortedSet(.read_write).init(try targets.putCursor(hash.hashInt(hash_kind, target_id)));
            try children.put(&evt.orderKeyDesc(record.created_order, event_id));
        }
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

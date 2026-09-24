const std = @import("std");
const evt = @import("../event.zig");
const diff3 = @import("../diff3.zig");
const srch_thrd = @import("../search_thread.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const rf = xit.ref;

title: []const u8,
description: []const u8,
labels: []const u8, // space-separated
source_branch: ?[]const u8 = null,
target_branch: []const u8,
target_patch_id: ?[evt.event_id_size * 2]u8 = null,
revision: ?Revision = null,
status: Status = .open,

pub const Revision = struct {
    id: [evt.event_id_size * 2]u8,
    squash_oid: []const u8,
    source_oid: []const u8,
    commit_count: ?u64 = null,

    pub fn fromRecord(id: [evt.event_id_size]u8, record: evt.PatchRev.Record) Revision {
        return .{
            .id = std.fmt.bytesToHex(id, .lower),
            .squash_oid = record.patch_oid,
            .source_oid = record.event.source_oid,
            .commit_count = record.commit_count,
        };
    }

    pub fn matches(self: Revision, record: evt.PatchRev.Record) bool {
        return !record.removed and
            std.mem.eql(u8, record.patch_oid, self.squash_oid) and
            std.mem.eql(u8, record.event.source_oid, self.source_oid);
    }
};

pub const MergeRevision = enum { squash, source };

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

pub const StatusKind = enum {
    open,
    closed,
    merged,

    const longest_len = blk: {
        var len: usize = 0;
        for (@typeInfo(StatusKind).@"enum".fields) |field| len = @max(len, field.name.len);
        break :blk len;
    };
};

pub const Status = union(StatusKind) {
    open,
    closed,
    merged: Merged,

    pub const Merged = struct {
        revision: MergeRevision,
        patchrev_id: [evt.event_id_size * 2]u8,
    };

    pub fn kind(self: Status) StatusKind {
        return std.meta.activeTag(self);
    }
};

pub const Resolve = struct {
    title: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    hunks: []const []const u8 = &.{},
    theirs: []const u8 = "",
};

pub const Update = union(enum) {
    status: StatusKind,
    fields: struct { title: []const u8, labels: []const u8, description: []const u8, target_branch: []const u8 },
    resolve: Resolve,
};

pub const label_max_len = 64;
pub const merge_policy: evt.MergePolicy = .field_conflicts;
pub const record_map_key = "event-id->patch";
pub const all_id_set_key = "patch-id-set";
pub const conflicts_key = "conflicted-patch-id->conflict";
pub const id_to_field_to_oid_key = "patch-id->field->oid";
pub const target_patch_id_to_patch_id_set_key = "target-patch-id->patch-id-set";
pub const status_to_id_set_key = "status->patch-id-set";
pub const label_status_to_id_set_key = "label+status->patch-id-set";
pub const revision_to_id_set_key = "target-branch+oid->patch-id-set";
pub const source_to_id_set_key = "source-branch->patch-id-set";
pub const patch_id_to_mergeability_key = "patch-id->mergeability";

pub const LabelStatusKey = [label_max_len + 1 + StatusKind.longest_len]u8;

pub fn labelStatusKey(buffer: *LabelStatusKey, label: []const u8, status: StatusKind) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ label, @tagName(status) });
}

pub fn labelIterator(labels: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, labels, ' ');
}

pub fn fieldsValid(title: []const u8, labels: []const u8) bool {
    if (!evt.titleValid(title)) return false;
    var label_iter = labelIterator(labels);
    while (label_iter.next()) |label| {
        if (label.len > label_max_len) return false;
    }
    return true;
}

pub fn branchValid(branch: []const u8) bool {
    return rf.validateName(branch) and !std.mem.eql(u8, branch, evt.events_ref.name);
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
    const label_statuses = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, label_status_to_id_set_key)));
    const conflicts = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key)));
    const field_oid_map = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(record_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!fieldsValid(record.event.title, record.event.labels)) return error.InvalidPatch;
    if (!branchValid(record.event.target_branch)) return error.InvalidTargetBranch;
    if (record.event.source_branch) |branch| {
        if (!branchValid(branch)) return error.InvalidSourceBranch;
        if (std.mem.eql(u8, branch, record.event.target_branch)) return error.SameBranch;
    }
    const revision_id = if (record.event.revision) |*revision| blk: {
        try evt.PatchRev.validateOid(hash_kind, revision.squash_oid);
        try evt.PatchRev.validateOid(hash_kind, revision.source_oid);
        break :blk try evt.parseEventId(&revision.id);
    } else null;
    const target_patch_id = if (record.event.target_patch_id) |*id| try evt.parseEventId(id) else null;
    if (target_patch_id) |*id| {
        if (std.mem.eql(u8, id, event_id)) return error.InvalidPatch;
    }
    const status_kind = record.event.status.kind();

    if (existing_maybe) |existing| {
        if (!evt.fieldEqual(?[]const u8, existing.event.source_branch, record.event.source_branch)) return error.PatchSourceChanged;
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
        const existing_status_kind = existing.event.status.kind();
        if (existing_status_kind == .merged and !evt.fieldEqual(Status, existing.event.status, record.event.status)) return error.PatchAlreadyMerged;
        if (existing_status_kind == .merged and !std.mem.eql(u8, existing.event.target_branch, record.event.target_branch)) return error.PatchAlreadyMerged;
        if (event_oid != null) {
            if (!std.meta.eql(existing.event.target_patch_id, record.event.target_patch_id)) {
                return error.TargetPatchChanged;
            }
        }
    }

    switch (record.event.status) {
        .open, .closed => {},
        .merged => |merged| {
            const merged_id = try evt.parseEventId(&merged.patchrev_id);
            const merged_revision = (try evt.PatchRev.readById(DB, hash_kind, haxy_moment.readOnly(), arena, &merged_id)) orelse return error.InvalidPatch;
            if (merged_revision.removed) return error.InvalidPatch;
            const id = revision_id orelse return error.InvalidPatch;
            const selected = record.event.revision orelse return error.InvalidPatch;
            const revision = (try evt.PatchRev.readById(DB, hash_kind, haxy_moment.readOnly(), arena, &id)) orelse return error.InvalidPatch;
            if (!selected.matches(revision)) return error.InvalidPatch;
        },
    }

    if (record.removed or status_kind != .open) {
        const key = hash.hashInt(hash_kind, patch_id_to_mergeability_key);
        if (try haxy_moment.getCursor(key) != null) {
            const checks = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(key));
            _ = try checks.remove(record_key);
        }
    }

    const order_key = evt.orderKeyDesc(record.created_order, event_id);
    if (existing_maybe) |existing| {
        if (event_oid != null or record.removed) _ = try conflicts.remove(&order_key);
        if (!existing.removed) {
            const existing_status_kind = existing.event.status.kind();
            const old_status = try statusSet(DB, statuses, existing_status_kind);
            _ = try old_status.remove(&order_key);
            try removeFromLabelSets(DB, label_statuses, existing.event.labels, existing_status_kind, &order_key);
            if (existing_status_kind != .merged) {
                if (existing.event.revision) |revision| {
                    const revisions = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, revision_to_id_set_key)));
                    for ([_][]const u8{ revision.squash_oid, revision.source_oid }, 0..) |oid, i| {
                        if (i != 0 and std.mem.eql(u8, revision.squash_oid, revision.source_oid)) continue;
                        const key_hash = hash.hashInt(hash_kind, try revisionKey(arena.allocator(), existing.event.target_branch, oid));
                        const ids = try DB.CountedHashSet(.read_write).init(try revisions.putCursor(key_hash));
                        _ = try ids.remove(record_key);
                        if (try ids.count() == 0) _ = try revisions.remove(key_hash);
                    }
                }
            }
        }
    }

    if (record.event.source_branch) |branch| {
        const sources = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, source_to_id_set_key)));
        if (!record.removed and status_kind != .merged) {
            const ids = try DB.CountedHashSet(.read_write).init(try sources.putCursor(branch));
            try ids.put(record_key, .{ .bytes = event_id });
        } else if (try sources.getCursor(branch) != null) {
            const ids = try DB.CountedHashSet(.read_write).init(try sources.putCursor(branch));
            _ = try ids.remove(record_key);
            if (try ids.count() == 0) _ = try sources.remove(branch);
        }
    }

    try evt.writeOid(Self, DB, hash_kind, field_oid_map, record_key, if (existing_maybe) |existing| existing.event else null, record.event, event_oid);

    const cursor = try records.putCursor(record_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .patch, existing_maybe, record);

    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&order_key);
        if (target_patch_id) |*target_id| {
            const targets = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, target_patch_id_to_patch_id_set_key)));
            const children = try DB.SortedSet(.read_write).init(try targets.putCursor(hash.hashInt(hash_kind, target_id)));
            try children.put(&order_key);
        }
    }

    // the search index is keyed by the same order key as the sets above
    try srch_thrd.update(DB, hash_kind, .patch, haxy_moment, arena.child_allocator, &order_key, existing_maybe, record);

    if (!record.removed) {
        const status = try statusSet(DB, statuses, status_kind);
        try status.put(&order_key);

        var label_iter = labelIterator(record.event.labels);
        while (label_iter.next()) |label| {
            if (label.len == 0 or label.len > label_max_len) continue;
            var key_buffer: LabelStatusKey = undefined;
            const set = try DB.SortedSet(.read_write).init(try label_statuses.putCursor(try labelStatusKey(&key_buffer, label, status_kind)));
            try set.put(&order_key);
        }

        if (status_kind != .merged) {
            if (record.event.revision) |revision| {
                const revisions = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, revision_to_id_set_key)));
                for ([_][]const u8{ revision.squash_oid, revision.source_oid }, 0..) |oid, i| {
                    if (i != 0 and std.mem.eql(u8, revision.squash_oid, revision.source_oid)) continue;
                    const key = try revisionKey(arena.allocator(), record.event.target_branch, oid);
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

    if (target.status.kind() == .merged and evt.fieldEqual(?Revision, target.revision, merged.revision)) {
        merged.status = target.status;
        outcome[status_index] = .kept;
    } else if (parent.status.kind() == .merged and evt.fieldEqual(?Revision, parent.revision, merged.revision)) {
        merged.status = parent.status;
        outcome[status_index] = .parent;
    }
}

pub fn update(
    host_kind: evt.HostKind,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
    change: Update,
    author: evt.CommitAuthor,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const record = (try evt.readFromRepo(Self, repo_kind, repo_opts, io, allocator, &arena, repo, id)) orelse return error.NotFound;
    if (record.removed) return error.NotFound;

    var updated = record.event;
    switch (change) {
        .status => |status| {
            if (updated.status.kind() == status) return;
            updated.status = switch (status) {
                .open => .open,
                .closed => .closed,
                .merged => return error.InvalidPatchStatus,
            };
            // a closed patch may have missed source branch updates
            if (status == .open and updated.source_branch != null) updated.revision = null;
        },
        .fields => |fields| {
            if (!branchValid(fields.target_branch)) return error.InvalidTargetBranch;
            if ((try repo.readRef(io, .{ .kind = .head, .name = fields.target_branch })) == null) return error.InvalidTargetBranch;
            updated.title = fields.title;
            updated.labels = fields.labels;
            updated.description = fields.description;
            if (!std.mem.eql(u8, updated.target_branch, fields.target_branch)) updated.revision = null;
            updated.target_branch = fields.target_branch;
        },
        .resolve => |resolve| {
            updated = try resolveFields(repo_kind, repo_opts, io, allocator, &arena, repo, id, record, resolve);
        },
    }
    if (!fieldsValid(updated.title, updated.labels)) return error.InvalidFields;

    if (updated.source_branch != null and updated.revision == null) return @import("../patch.zig").writeBranchPatch(host_kind, repo_kind, repo_opts, io, allocator, repo, std.fmt.bytesToHex(id.*, .lower), updated, record.event, author);
    try evt.consume(host_kind, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .patch = updated },
    }});
}

fn resolveFields(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
    live: Record,
    resolve: Resolve,
) !Self {
    const DB = evt.EventDB(repo_opts.hash);
    var updated = live.event;
    if (resolve.title) |title| updated.title = title;
    if (resolve.labels) |labels| updated.labels = labels;

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
    const conflict_cursor = (try conflicts.getCursor(&evt.orderKeyDesc(live.created_order, id))) orelse return updated;
    const entry = try DB.HashMap(.read_only).init(conflict_cursor);
    const fields_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key))) orelse return updated;
    const fields = try fields_cursor.readBytesAlloc(arena.allocator(), null);
    const their_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key))) orelse return updated;
    const theirs = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(their_cursor));

    const original_target_branch = updated.target_branch;
    var field_iter = std.mem.splitScalar(u8, fields, ' ');
    while (field_iter.next()) |field| {
        if (std.mem.eql(u8, field, "status") and fieldListed(resolve.theirs, ',', field)) updated.status = theirs.event.status;
        if (std.mem.eql(u8, field, "revision") and fieldListed(resolve.theirs, ',', field)) updated.revision = theirs.event.revision;
        if (std.mem.eql(u8, field, "target_branch") and fieldListed(resolve.theirs, ',', field)) updated.target_branch = theirs.event.target_branch;
    }
    if (!std.mem.eql(u8, original_target_branch, updated.target_branch)) updated.revision = null;

    if (!fieldListed(fields, ' ', "description")) return updated;
    var base_description: []const u8 = "";
    if (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.base_record_key))) |base_cursor| {
        const base = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(base_cursor));
        base_description = base.event.description;
    }
    const chunks = try diff3.chunks(allocator, arena, base_description, live.event.description, theirs.event.description);
    var resolutions: std.ArrayList([]const u8) = .empty;
    var hunk_index: usize = 0;
    for (chunks) |chunk| {
        if (chunk != .conflict) continue;
        try resolutions.append(arena.allocator(), if (hunk_index < resolve.hunks.len) resolve.hunks[hunk_index] else (chunk.conflict.ours orelse ""));
        hunk_index += 1;
    }
    updated.description = try diff3.assemble(arena.allocator(), chunks, resolutions.items);
    return updated;
}

fn fieldListed(fields: []const u8, delimiter: u8, name: []const u8) bool {
    var iter = std.mem.splitScalar(u8, fields, delimiter);
    while (iter.next()) |field| {
        if (std.mem.eql(u8, field, name)) return true;
    }
    return false;
}

fn revisionKey(allocator: std.mem.Allocator, target_branch: []const u8, oid: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ target_branch, "\x00", oid });
}

fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_write),
    status: StatusKind,
) !DB.SortedSet(.read_write) {
    return DB.SortedSet(.read_write).init(try statuses.putCursor(@tagName(status)));
}

fn removeFromLabelSets(
    comptime DB: type,
    label_statuses: DB.SortedMap(.read_write),
    labels: []const u8,
    status: StatusKind,
    order_key: []const u8,
) !void {
    var label_iter = labelIterator(labels);
    while (label_iter.next()) |label| {
        if (label.len == 0 or label.len > label_max_len) continue;
        var key_buffer: LabelStatusKey = undefined;
        const key = try labelStatusKey(&key_buffer, label, status);
        const set = try DB.SortedSet(.read_write).init(try label_statuses.putCursor(key));
        _ = try set.remove(order_key);
        if (0 == try set.count()) _ = try label_statuses.remove(key);
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

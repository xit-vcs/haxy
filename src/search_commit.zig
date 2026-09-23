const std = @import("std");
const evt = @import("event.zig");
const srch = @import("search.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const rf = xit.ref;
const obj = xit.object;
const mrg = xit.merge;
const progress = @import("./progress.zig");

// the repo moment key holding one commit-message index per ref tip. it sits
// outside the haxy moment because pushes change it and events never do. each
// entry is keyed by its commit oid's hash: its value is the index as of that
// commit, and its key slot holds the raw commit oid followed by its timestamp.
pub const index_key = "haxy/commit-oid->word->time+oid";

// a ref move: the old tip's version, when it has one, is the base the new
// tip's derives from
pub const Move = struct {
    old_oid: []const u8,
    new_oid: []const u8,
};

// `commit_oid`'s index, or null when it has none. a version is correct for its
// commit by construction, so there is nothing to check for staleness.
pub fn lookup(
    comptime repo_opts: rp.RepoOpts(.xit),
    moment: rp.Repo(.xit, repo_opts).DB.HashMap(.read_only),
    commit_oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !?rp.Repo(.xit, repo_opts).DB.SortedMap(.read_only) {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const index_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, index_key)) orelse return null;
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const cursor = try index.getCursor(try hash.hexToInt(repo_opts.hash, commit_oid)) orelse return null;
    return try DB.SortedMap(.read_only).init(cursor);
}

// a commit's doc key: its committer timestamp counting down, so a posting set
// iterates newest first and a new commit inserts at the front, then its raw
// oid, which makes the key unique.
pub fn docKey(
    comptime hash_kind: hash.HashKind,
    timestamp: u64,
    oid: *const [hash.hexLen(hash_kind)]u8,
) ![docKeyLen(hash_kind)]u8 {
    var key: [docKeyLen(hash_kind)]u8 = undefined;
    std.mem.writeInt(u64, key[0..@sizeOf(u64)], std.math.maxInt(u64) - timestamp, .big);
    _ = try std.fmt.hexToBytes(key[@sizeOf(u64)..], oid);
    return key;
}

// the commit a doc key names.
pub fn keyOid(comptime hash_kind: hash.HashKind, key: []const u8) ![hash.hexLen(hash_kind)]u8 {
    if (key.len != docKeyLen(hash_kind)) return error.InvalidCommitIndex;
    var oid: [hash.byteLen(hash_kind)]u8 = undefined;
    @memcpy(&oid, key[@sizeOf(u64)..]);
    return std.fmt.bytesToHex(oid, .lower);
}

fn docKeyLen(comptime hash_kind: hash.HashKind) usize {
    return @sizeOf(u64) + hash.byteLen(hash_kind);
}

// reconcile them inside the caller's transaction, so the index lands with the
// change that invalidated it. `moves` are the refs that change moved, whose
// old oids are the cheapest bases to derive the new tips from. reports whether
// anything was written, so a caller that owns an otherwise empty transaction
// can cancel it
pub fn refreshInTransaction(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    moment: *rp.Repo(.xit, repo_opts).DB.HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    moves: []const Move,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const Oid = [hash.hexLen(repo_opts.hash)]u8;
    const oid_len = comptime hash.byteLen(repo_opts.hash);
    // an entry's key slot: the raw commit oid followed by its timestamp
    const Entry = [oid_len + @sizeOf(u64)]u8;

    // one version to build: the commit it covers, and the commit whose version
    // it derives from (null = walk the whole history).
    const Work = struct {
        oid: Oid,
        timestamp: u64,
        base: ?Oid,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var work: std.ArrayList(Work) = .empty;
    var gone: std.ArrayList(Oid) = .empty;
    var default_tip: ?Oid = null;
    // the versions in the index, each with its commit's timestamp. the ones
    // built here join them, so a later tip can derive from an earlier one.
    var versions: std.AutoArrayHashMapUnmanaged(Oid, u64) = .empty;

    {
        const read_state = state.readOnly();

        if (try moment.getCursor(hash.hashInt(repo_opts.hash, index_key))) |index_cursor| {
            const index = try DB.HashMap(.read_only).init(index_cursor);
            var iter = try index.iterator();
            while (try iter.next()) |cursor| {
                const pair = try cursor.readKeyValuePair();
                var entry: Entry = undefined;
                if ((try pair.key_cursor.readBytes(&entry)).len != entry.len) return error.InvalidCommitIndex;
                const oid = std.fmt.bytesToHex(entry[0..oid_len].*, .lower);
                try versions.put(aa, oid, std.mem.readInt(u64, entry[oid_len..], .big));
            }
        }

        // what every head except the events branch and every tag points at
        var tips: std.ArrayList(Oid) = .empty;
        {
            var branches = try rf.RefIterator(.xit, repo_opts).init(read_state, io, allocator, .head, .beginning);
            defer branches.deinit();
            while (try branches.next()) |ref| {
                if (std.mem.eql(u8, ref.name, evt.events_ref.name)) continue;
                try tips.append(aa, (try rf.readRecur(.xit, repo_opts, read_state, io, .{ .ref = .{ .kind = .head, .name = ref.name } })) orelse continue);
            }
        }
        {
            var tags = try rf.RefIterator(.xit, repo_opts).init(read_state, io, allocator, .tag, .beginning);
            defer tags.deinit();
            while (try tags.next()) |ref| {
                try tips.append(aa, (try rf.readRecur(.xit, repo_opts, read_state, io, .{ .ref = .{ .kind = .tag, .name = ref.name } })) orelse continue);
            }
        }

        // the commits a version is wanted for, annotated tags peeled. refs
        // sharing a commit share its version.
        var wanted: std.AutoArrayHashMapUnmanaged(Oid, void) = .empty;
        var missing: std.AutoArrayHashMapUnmanaged(Oid, Work) = .empty;
        for (tips.items) |tip| {
            // a tip that already has a version needs no reading
            if (versions.contains(tip)) {
                try wanted.put(aa, tip, {});
                continue;
            }
            var commit = obj.Object(.xit, repo_opts).initCommit(read_state, io, allocator, &tip) catch continue;
            defer commit.deinit();
            try wanted.put(aa, commit.oid, {});
            if (versions.contains(commit.oid)) continue;
            const entry = try missing.getOrPut(aa, commit.oid);
            if (!entry.found_existing) entry.value_ptr.* = .{
                .oid = commit.oid,
                .timestamp = commit.content.commit.metadata.timestamp,
                .base = null,
            };
            if (entry.value_ptr.base == null) entry.value_ptr.base = movedFrom(repo_opts, moves, &tip, versions);
        }

        var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
        if (rf.readHead(.xit, repo_opts, read_state, io, &head_buffer) catch null) |head| switch (head) {
            .ref => |ref| default_tip = try rf.readRecur(.xit, repo_opts, read_state, io, .{ .ref = .{ .kind = .head, .name = ref.name } }),
            .oid => {},
        };

        try work.appendSlice(aa, missing.values());
        // oldest first, so a later tip derives from an earlier one
        std.mem.sort(Work, work.items, {}, struct {
            fn lessThan(_: void, a: Work, b: Work) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        for (versions.keys()) |oid| {
            if (!wanted.contains(oid)) try gone.append(aa, oid);
        }
    }

    if (work.items.len == 0 and gone.items.len == 0) return false;

    {
        const index_hash = hash.hashInt(repo_opts.hash, index_key);

        for (work.items) |item| {
            const index = try DB.HashMap(.read_write).init(try moment.putCursor(index_hash));
            const base = item.base orelse nearestVersion(repo_opts.hash, versions, default_tip, item.timestamp);

            var entry: Entry = undefined;
            _ = try std.fmt.hexToBytes(entry[0..oid_len], &item.oid);
            std.mem.writeInt(u64, entry[oid_len..], item.timestamp, .big);
            const oid_int = hash.bytesToInt(repo_opts.hash, entry[0..oid_len]);
            try index.putKey(oid_int, .{ .bytes = &entry });
            var version_cursor = try index.putCursor(oid_int);
            if (base) |base_oid| {
                const base_cursor = (try index.getCursor(try hash.hexToInt(repo_opts.hash, &base_oid))) orelse return error.InvalidCommitIndex;
                try version_cursor.write(.{ .slot = base_cursor.slot() });
            }
            const version = try DB.SortedMap(.read_write).init(version_cursor);

            if (base) |*base_oid| {
                try derive(repo_opts, state.readOnly(), io, allocator, version, base_oid, &item.oid, progress_ctx_maybe);
            } else {
                try indexHistory(repo_opts, state.readOnly(), io, allocator, version, &item.oid, progress_ctx_maybe);
            }

            try versions.put(aa, item.oid, item.timestamp);
            // the next version copies this one's slot, so everything
            // written so far has to be shared rather than mutated
            try state.core.db.freeze();
        }

        // removing last keeps a tip that is going away available as a base
        const index = try DB.HashMap(.read_write).init(try moment.putCursor(index_hash));
        for (gone.items) |oid| _ = try index.remove(try hash.hexToInt(repo_opts.hash, &oid));
    }
    return true;
}

// the version a tip committed at `timestamp` derives from when no move names
// one: the default branch's unless it is newer than the tip, else the nearest
// older one, else the oldest. a guess by dates that only the cost rides on.
fn nearestVersion(
    comptime hash_kind: hash.HashKind,
    versions: std.AutoArrayHashMapUnmanaged([hash.hexLen(hash_kind)]u8, u64),
    default_tip: ?[hash.hexLen(hash_kind)]u8,
    timestamp: u64,
) ?[hash.hexLen(hash_kind)]u8 {
    var older: ?[hash.hexLen(hash_kind)]u8 = null;
    var older_timestamp: u64 = 0;
    var oldest: ?[hash.hexLen(hash_kind)]u8 = null;
    var oldest_timestamp: u64 = std.math.maxInt(u64);
    for (versions.keys(), versions.values()) |oid, version_timestamp| {
        if (version_timestamp <= timestamp) {
            if (default_tip) |tip| if (std.mem.eql(u8, &tip, &oid)) return tip;
            if (older == null or version_timestamp > older_timestamp) {
                older = oid;
                older_timestamp = version_timestamp;
            }
        }
        if (version_timestamp < oldest_timestamp) {
            oldest = oid;
            oldest_timestamp = version_timestamp;
        }
    }
    return older orelse oldest;
}

// the commit a move took a ref to `tip` from, when it has a version to derive
// from.
fn movedFrom(
    comptime repo_opts: rp.RepoOpts(.xit),
    moves: []const Move,
    tip: *const [hash.hexLen(repo_opts.hash)]u8,
    versions: std.AutoArrayHashMapUnmanaged([hash.hexLen(repo_opts.hash)]u8, u64),
) ?[hash.hexLen(repo_opts.hash)]u8 {
    for (moves) |move| {
        if (!std.mem.eql(u8, move.new_oid, tip)) continue;
        if (move.old_oid.len != hash.hexLen(repo_opts.hash)) continue;
        var oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        @memcpy(&oid, move.old_oid);
        if (versions.contains(oid)) return oid;
    }
    return null;
}

// turn a copy of `base_tip`'s version into `tip`'s by moving the postings of
// the commits the two don't share
fn derive(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    version: rp.Repo(.xit, repo_opts).DB.SortedMap(.read_write),
    base_tip: *const [hash.hexLen(repo_opts.hash)]u8,
    tip: *const [hash.hexLen(repo_opts.hash)]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const Ancestry = mrg.Ancestry(.xit, repo_opts);
    var ancestry = try Ancestry.init(state, io, allocator, base_tip, tip);
    defer ancestry.deinit();

    progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .walking_commit, .estimated_total_items = 0 } });
    try ancestry.finish(progress_ctx_maybe);
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .walking_commit });

    // the walk stops at the shared history, so it trusts timestamps: a
    // commit dated later than a descendant can be passed from the base
    // side before the tip turns out to reach it too, and its postings are
    // then dropped. settling that would mean walking the whole history.
    // a wrong addition only re-puts postings, so a fast-forward removes
    // nothing, which the base tip picking up the tip's flag proves.
    const base_node = ancestry.nodes.get(ancestry.tips[0]) orelse unreachable;
    const fast_forward = base_node.flags & Ancestry.two != 0;

    // a commit one tip alone reaches has postings to move. tag objects are
    // peeled through, not walked.
    var total: usize = 0;
    var counted = ancestry.nodes.valueIterator();
    while (counted.next()) |node| {
        if (node.tag_target != null) continue;
        switch (node.flags & Ancestry.both) {
            Ancestry.one => total += @intFromBool(!fast_forward),
            Ancestry.two => total += 1,
            else => {},
        }
    }

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);

    progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Indexing commits" });
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = total } });
    var iter = ancestry.nodes.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.tag_target != null) continue;
        const flags = entry.value_ptr.flags & Ancestry.both;
        if (flags == Ancestry.both or flags == 0 or (flags == Ancestry.one and fast_forward)) continue;
        if (progress.cancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
        defer progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });

        var object = try obj.Object(.xit, repo_opts).init(state, io, allocator, entry.key_ptr);
        defer object.deinit();
        const key = try readPosting(repo_opts, allocator, &message, &object);
        const removed = flags == Ancestry.one;
        try srch.replace(DB, version, allocator, &key, if (removed) message.items else "", if (removed) "" else message.items);
    }
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
}

// index every commit `tip` reaches into an empty `version`, as the walk
// reaches it.
// TODO: the walk holds every visited oid in memory. if that proves too costly
// for large repositories, consider indexing first-parent history only, which
// needs no visited set and matches the commits list.
fn indexHistory(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    version: rp.Repo(.xit, repo_opts).DB.SortedMap(.read_write),
    tip: *const [hash.hexLen(repo_opts.hash)]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const DB = rp.Repo(.xit, repo_opts).DB;

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);

    // a whole history has no count until it is walked, so it reports the
    // commits indexed so far
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Indexing commits" });
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = 0 } });
    var iter = try obj.ObjectIterator(.xit, repo_opts).init(state, io, allocator, .{ .kind = .commit });
    defer iter.deinit();
    try iter.include(tip);
    while (try iter.next(allocator)) |object| {
        defer object.deinit();
        if (progress.cancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
        const key = try readPosting(repo_opts, allocator, &message, object);
        try srch.replace(DB, version, allocator, &key, "", message.items);
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
    }
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
}

// replace `message` with the indexed prefix of `object`'s message and return
// the doc key it indexes under
fn readPosting(
    comptime repo_opts: rp.RepoOpts(.xit),
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    object: *obj.Object(.xit, repo_opts),
) ![docKeyLen(repo_opts.hash)]u8 {
    message.clearRetainingCapacity();
    object.readMessage(allocator, message, .limited(srch.max_indexed_bytes)) catch |err| switch (err) {
        // only the indexed prefix matters
        error.StreamTooLong => {},
        else => |e| return e,
    };
    return docKey(repo_opts.hash, object.content.commit.metadata.timestamp, &object.oid);
}

const std = @import("std");
const evt = @import("event.zig");
const srch = @import("search.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const rf = xit.ref;
const obj = xit.object;
const mrg = xit.merge;
const serve_common = @import("serve_common.zig");

// the repo moment key holding one commit-message index per ref tip. it sits
// outside the haxy moment because pushes change it and events never do. each
// entry is keyed by its commit oid's hash: its value is the index as of that
// commit, and its key slot holds the raw commit oid.
pub const index_key = "haxy/commit-oid->word->time+oid";

// a commit a version covers.
pub fn Commit(comptime hash_kind: hash.HashKind) type {
    return struct {
        oid: [hash.hexLen(hash_kind)]u8,
        timestamp: u64,
    };
}

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

// the action a commit index refresh records when it runs on its own
pub const undo_action = "haxy/commit-index";

// reconcile the index versions with the repo's ref tips, in a transaction of
// its own
pub fn refresh(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
) !void {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const Save = struct {
        core: *Repo.Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = Repo.State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            if (!try refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, ctx.updates, null)) return error.CancelTransaction;

            // record the user action for undo
            try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = undo_action } });
        }
    };

    // held across the reads and the writes, so a concurrent refresh can't
    // change the entries these decisions were made from.
    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    history.appendContext(.{ .slot = try history.getSlot(-1) }, Save{ .core = &repo.core, .io = io, .allocator = allocator, .updates = updates }) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => return err,
    };
}

// reconcile them inside the caller's transaction, so the index lands with the
// push that invalidated it. `updates` is that push, whose old oids are the
// cheapest bases to derive the new tips from. reports whether anything was
// written, so a caller that owns an otherwise empty transaction can cancel it
pub fn refreshInTransaction(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    moment: *rp.Repo(.xit, repo_opts).DB.HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const Oid = [hash.hexLen(repo_opts.hash)]u8;
    const Tip = Commit(repo_opts.hash);

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
    // the versions a new tip can derive from
    var versions: std.ArrayList(Tip) = .empty;

    {
        const read_state = state.readOnly();

        // the commits that already have a version
        var existing: std.AutoArrayHashMapUnmanaged(Oid, void) = .empty;
        if (try moment.getCursor(hash.hashInt(repo_opts.hash, index_key))) |index_cursor| {
            const index = try DB.HashMap(.read_only).init(index_cursor);
            var iter = try index.iterator();
            while (try iter.next()) |cursor| {
                const pair = try cursor.readKeyValuePair();
                var oid_bytes: [hash.byteLen(repo_opts.hash)]u8 = undefined;
                if ((try pair.key_cursor.readBytes(&oid_bytes)).len != oid_bytes.len) return error.InvalidCommitIndex;
                try existing.put(aa, std.fmt.bytesToHex(oid_bytes, .lower), {});
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
            if (existing.contains(tip)) {
                try wanted.put(aa, tip, {});
                continue;
            }
            var commit = obj.Object(.xit, repo_opts).initCommit(read_state, io, allocator, &tip) catch continue;
            defer commit.deinit();
            try wanted.put(aa, commit.oid, {});
            if (existing.contains(commit.oid)) continue;
            const entry = try missing.getOrPut(aa, commit.oid);
            if (!entry.found_existing) entry.value_ptr.* = .{
                .oid = commit.oid,
                .timestamp = commit.content.commit.metadata.timestamp,
                .base = null,
            };
            if (entry.value_ptr.base == null) entry.value_ptr.base = pushedFrom(repo_opts, updates, &tip, existing);
        }

        var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
        if (rf.readHead(.xit, repo_opts, read_state, io, &head_buffer) catch null) |head| switch (head) {
            .ref => |ref| default_tip = try rf.readRecur(.xit, repo_opts, read_state, io, .{ .ref = .{ .kind = .head, .name = ref.name } }),
            .oid => {},
        };

        // an entry whose commit is gone can't be walked from, so it isn't a
        // candidate.
        const unbased = for (missing.values()) |item| {
            if (item.base == null) break true;
        } else false;
        if (unbased) for (existing.keys()) |oid| {
            var commit = obj.Object(.xit, repo_opts).initCommit(read_state, io, allocator, &oid) catch continue;
            defer commit.deinit();
            try versions.append(aa, .{ .oid = oid, .timestamp = commit.content.commit.metadata.timestamp });
        };

        try work.appendSlice(aa, missing.values());
        // oldest first, so a later tip derives from an earlier one
        std.mem.sort(Work, work.items, {}, struct {
            fn lessThan(_: void, a: Work, b: Work) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        for (existing.keys()) |oid| {
            if (!wanted.contains(oid)) try gone.append(aa, oid);
        }
    }

    if (work.items.len == 0 and gone.items.len == 0) return false;

    {
        const index_hash = hash.hashInt(repo_opts.hash, index_key);

        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(allocator);

        for (work.items) |item| {
            const index = try DB.HashMap(.read_write).init(try moment.putCursor(index_hash));
            const base = item.base orelse nearestVersion(repo_opts.hash, versions.items, default_tip, item.timestamp);

            var oid_bytes: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&oid_bytes, &item.oid);
            const oid_int = hash.bytesToInt(repo_opts.hash, &oid_bytes);
            try index.putKey(oid_int, .{ .bytes = &oid_bytes });
            var version_cursor = try index.putCursor(oid_int);
            if (base) |base_oid| {
                const base_cursor = (try index.getCursor(try hash.hexToInt(repo_opts.hash, &base_oid))) orelse return error.InvalidCommitIndex;
                try version_cursor.write(.{ .slot = base_cursor.slot() });
            }
            const version = try DB.SortedMap(.read_write).init(version_cursor);

            var diff_arena = std.heap.ArenaAllocator.init(allocator);
            defer diff_arena.deinit();
            const diff = try commitDiff(repo_opts, state.readOnly(), io, allocator, diff_arena.allocator(), if (base) |*base_oid| base_oid else null, &item.oid, progress_ctx_maybe);

            // the walk is done, so the messages left to read are the total
            serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .text = "Indexing commits" });
            serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = diff.removed.len + diff.added.len } });
            for (diff.removed) |commit| {
                if (serve_common.progressCancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
                defer serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
                const key = try readPosting(repo_opts, state.readOnly(), io, allocator, &message, commit);
                try srch.remove(DB, version, allocator, &key, message.items);
            }
            for (diff.added) |commit| {
                if (serve_common.progressCancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
                defer serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
                const key = try readPosting(repo_opts, state.readOnly(), io, allocator, &message, commit);
                try srch.add(DB, version, allocator, &key, message.items);
            }
            serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });

            try versions.append(aa, .{ .oid = item.oid, .timestamp = item.timestamp });
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

// the version a tip committed at `timestamp` derives from when no push names
// one: the default branch's unless it is newer than the tip, else the nearest
// older one, else the oldest. a guess by dates that only the cost rides on.
fn nearestVersion(
    comptime hash_kind: hash.HashKind,
    versions: []const Commit(hash_kind),
    default_tip: ?[hash.hexLen(hash_kind)]u8,
    timestamp: u64,
) ?[hash.hexLen(hash_kind)]u8 {
    var older: ?Commit(hash_kind) = null;
    var oldest: ?Commit(hash_kind) = null;
    for (versions) |version| {
        if (version.timestamp <= timestamp) {
            if (default_tip) |oid| if (std.mem.eql(u8, &oid, &version.oid)) return oid;
            const nearer = if (older) |found| version.timestamp > found.timestamp else true;
            if (nearer) older = version;
        }
        const earlier = if (oldest) |found| version.timestamp < found.timestamp else true;
        if (earlier) oldest = version;
    }
    return if (older orelse oldest) |version| version.oid else null;
}

// the commit this push moved a ref to `tip` from, when it has a version to
// derive from.
fn pushedFrom(
    comptime repo_opts: rp.RepoOpts(.xit),
    updates: ?[]const xit.net_server_receive_pack.AppliedRefUpdate,
    tip: *const [hash.hexLen(repo_opts.hash)]u8,
    existing: std.AutoArrayHashMapUnmanaged([hash.hexLen(repo_opts.hash)]u8, void),
) ?[hash.hexLen(repo_opts.hash)]u8 {
    for (updates orelse &.{}) |update| {
        if (!std.mem.eql(u8, update.new_oid, tip)) continue;
        if (update.old_oid.len != hash.hexLen(repo_opts.hash)) continue;
        var oid: [hash.hexLen(repo_opts.hash)]u8 = undefined;
        @memcpy(&oid, update.old_oid);
        if (existing.contains(oid)) return oid;
    }
    return null;
}

// read `commit`'s message into `message` and return the doc key it indexes
// under.
fn readPosting(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    message: *std.ArrayList(u8),
    commit: Commit(repo_opts.hash),
) ![docKeyLen(repo_opts.hash)]u8 {
    message.clearRetainingCapacity();
    var object = try obj.Object(.xit, repo_opts).init(state, io, allocator, &commit.oid);
    defer object.deinit();
    object.readMessage(allocator, message, .limited(srch.max_indexed_bytes)) catch |err| switch (err) {
        // only the indexed prefix matters
        error.StreamTooLong => {},
        else => |e| return e,
    };
    return docKey(repo_opts.hash, commit.timestamp, &commit.oid);
}

// what `tip` reaches that `base_tip` doesn't, and the other way round, built
// into `aa`. with no base the whole history is added.
fn commitDiff(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    base_tip: ?*const [hash.hexLen(repo_opts.hash)]u8,
    tip: *const [hash.hexLen(repo_opts.hash)]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !struct { removed: []const Commit(repo_opts.hash), added: []const Commit(repo_opts.hash) } {
    var removed: std.ArrayList(Commit(repo_opts.hash)) = .empty;
    var added: std.ArrayList(Commit(repo_opts.hash)) = .empty;

    if (base_tip) |base| {
        const Ancestry = mrg.Ancestry(.xit, repo_opts);
        var ancestry = try Ancestry.init(state, io, allocator, base, tip);
        defer ancestry.deinit();
        try ancestry.finish();

        // timestamps only choose the walk's order, so a commit the base reached
        // can be passed before the tip turns out to reach it too. that can only
        // make a removal wrong, never an addition. a fast-forward removes
        // nothing, which the base tip picking up the tip's flag proves. anything
        // else is settled by walking until nothing is left to carry down.
        const base_node = ancestry.nodes.get(ancestry.tips[0]) orelse unreachable;
        const fast_forward = base_node.flags & Ancestry.two != 0;
        if (!fast_forward) {
            var candidates = false;
            var flagged = ancestry.nodes.valueIterator();
            while (flagged.next()) |node| {
                if (node.flags & Ancestry.both == Ancestry.one) candidates = true;
            }
            if (candidates) while (try ancestry.step()) {};
        }

        var iter = ancestry.nodes.iterator();
        while (iter.next()) |entry| {
            // tag objects are peeled through, not walked
            if (entry.value_ptr.tag_target != null) continue;
            const commit = Commit(repo_opts.hash){ .oid = entry.key_ptr.*, .timestamp = entry.value_ptr.timestamp };
            switch (entry.value_ptr.flags & Ancestry.both) {
                Ancestry.one => if (!fast_forward) try removed.append(aa, commit),
                Ancestry.two => try added.append(aa, commit),
                else => {},
            }
        }
    } else {
        // a whole history has no count until it is walked, so the walk reports
        // the commits it has reached so far
        serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .text = "Walking commits" });
        serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = 0 } });
        var iter = try obj.ObjectIterator(.xit, repo_opts).init(state, io, allocator, .{ .kind = .commit });
        defer iter.deinit();
        try iter.include(tip);
        while (try iter.next(allocator)) |object| {
            defer object.deinit();
            try added.append(aa, .{ .oid = object.oid, .timestamp = object.content.commit.metadata.timestamp });
            serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
        }
        serve_common.reportProgress(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
    }

    return .{ .removed = removed.items, .added = added.items };
}

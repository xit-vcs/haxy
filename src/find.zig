const std = @import("std");
const evt = @import("event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const rf = xit.ref;
const tr = xit.tree;
const obj = xit.object;
const fs = xit.fs;
const progress = @import("./progress.zig");

// the repo moment key holding one file map per branch tip. it sits outside the
// haxy moment because pushes change it and events never do. each entry is
// keyed by its branch name's hash: its value is the branch's file map, and its
// key slot holds the raw tip commit oid that map covers rather than the name.
const index_key = "haxy/branch->file-name+path->oid";

// what a search returns: the matching files and whether the cap cut the list
// short.
pub fn Results(comptime hash_kind: hash.HashKind) type {
    return struct {
        matches: []const Match,
        capped: bool = false,

        pub const Match = struct {
            path: []const u8,
            oid: [hash.byteLen(hash_kind)]u8,
        };
    };
}

// `branch`'s file index, or null when it has none or its entry is stale: one
// that doesn't cover `oid`, the branch's tip.
pub fn lookup(
    comptime repo_opts: rp.RepoOpts(.xit),
    moment: rp.Repo(.xit, repo_opts).DB.HashMap(.read_only),
    branch: []const u8,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
) !?rp.Repo(.xit, repo_opts).DB.SortedMap(.read_only) {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const index_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, index_key)) orelse return null;
    const index = try DB.HashMap(.read_only).init(index_cursor);
    const pair = try index.getKeyValuePair(hash.hashInt(repo_opts.hash, branch)) orelse return null;
    const entry_oid = try readOid(repo_opts, pair.key_cursor);
    if (!std.mem.eql(u8, &entry_oid, oid)) return null;
    return try DB.SortedMap(.read_only).init(pair.value_cursor);
}

// the indexed files whose basename starts with `term`, ordered by basename then
// path. the separator between basename and path keeps a match inside the
// basename, so the walk stops at the first key that doesn't share the prefix.
pub fn search(
    comptime repo_opts: rp.RepoOpts(.xit),
    files: rp.Repo(.xit, repo_opts).DB.SortedMap(.read_only),
    aa: std.mem.Allocator,
    term: []const u8,
    max: usize,
) !Results(repo_opts.hash) {
    const Match = Results(repo_opts.hash).Match;
    const prefix = try aa.alloc(u8, term.len);
    _ = std.ascii.lowerString(prefix, term);

    var matches: std.ArrayList(Match) = .empty;
    var iter = try files.iteratorFrom(prefix);
    while (try iter.next()) |cursor| {
        const pair = try cursor.readKeyValuePair();
        const key = try pair.key_cursor.readBytesAlloc(aa, null);
        if (!std.mem.startsWith(u8, key, prefix)) break;
        if (matches.items.len == max) return .{ .matches = matches.items, .capped = true };
        const separator = std.mem.indexOfScalar(u8, key, 0) orelse return error.InvalidFileIndex;
        const value = try pair.value_cursor.readBytesAlloc(aa, null);
        try matches.append(aa, .{ .path = key[separator + 1 ..], .oid = try parseOid(repo_opts.hash, value) });
    }
    return .{ .matches = matches.items };
}

// the indexed file at `path`, for a selected result the cap cut off.
pub fn get(
    comptime repo_opts: rp.RepoOpts(.xit),
    files: rp.Repo(.xit, repo_opts).DB.SortedMap(.read_only),
    aa: std.mem.Allocator,
    path: []const u8,
) !?[hash.byteLen(repo_opts.hash)]u8 {
    var key: std.ArrayList(u8) = .empty;
    try fileKey(aa, &key, path);
    const cursor = (try files.getCursor(key.items)) orelse return null;
    return try parseOid(repo_opts.hash, try cursor.readBytesAlloc(aa, null));
}

// peel an oid to the root tree it names, following commits and tags.
fn rootTreeOid(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
) ![hash.hexLen(repo_opts.hash)]u8 {
    var current = oid.*;
    while (true) {
        var object = try obj.Object(.xit, repo_opts).init(state, io, allocator, &current);
        defer object.deinit();
        switch (object.content) {
            .tree => return current,
            .commit => |commit| current = commit.tree,
            .tag => |tag| current = tag.target,
            .blob => return error.ObjectInvalid,
        }
    }
}

// the action a file index refresh records when it runs on its own
pub const undo_action = "haxy/find-index";

// reconcile every branch tip's index, in a transaction of its own
pub fn refresh(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, repo_opts),
) !void {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const Save = struct {
        core: *Repo.Core,
        io: std.Io,
        allocator: std.mem.Allocator,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = Repo.State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            if (!try refreshInTransaction(repo_opts, state, &moment, ctx.io, ctx.allocator, null)) return error.CancelTransaction;

            // record the user action for undo
            try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = undo_action } });
        }
    };

    // held across the reads and the writes, so a concurrent refresh can't
    // change the entries these decisions were made from.
    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    history.appendContext(.{ .slot = try history.getSlot(-1) }, Save{ .core = &repo.core, .io = io, .allocator = allocator }) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => return err,
    };
}

// reconcile them inside the caller's transaction, so the index lands with the
// change that invalidated it. every branch is reconciled, since an up-to-date
// one costs a ref read and an oid compare. reports whether anything was
// written, so a caller that owns an otherwise empty transaction can cancel it
pub fn refreshInTransaction(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    moment: *rp.Repo(.xit, repo_opts).DB.HashMap(.read_write),
    io: std.Io,
    allocator: std.mem.Allocator,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !bool {
    const Repo = rp.Repo(.xit, repo_opts);
    const DB = Repo.DB;
    const HashInt = hash.HashInt(repo_opts.hash);
    const Oid = [hash.hexLen(repo_opts.hash)]u8;

    // an entry in the index: the tip it covers and its file map
    const Entry = struct {
        oid: Oid,
        files: xit.xitdb.Slot,

        fn init(pair: DB.KeyValuePairCursor(.read_only)) !@This() {
            return .{ .oid = try readOid(repo_opts, pair.key_cursor), .files = pair.value_cursor.slot() };
        }
    };
    // what one branch needs written
    const Work = struct {
        branch_hash: HashInt,
        // the tip (null = the branch is gone, so its entry goes)
        oid: ?Oid,
        // the entry the branch has now
        own: ?Entry,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var work: std.ArrayList(Work) = .empty;
    var base: ?Entry = null;

    {
        const read_state = state.readOnly();

        // entries carry no branch name, so branches are matched by hash
        var existing: std.AutoArrayHashMapUnmanaged(HashInt, Entry) = .empty;
        if (try moment.getCursor(hash.hashInt(repo_opts.hash, index_key))) |index_cursor| {
            const index = try DB.HashMap(.read_only).init(index_cursor);
            var iter = try index.iterator();
            while (try iter.next()) |cursor| {
                const pair = try cursor.readKeyValuePair();
                try existing.put(aa, pair.hash, try Entry.init(pair));
            }
        }

        // a brand-new branch copies the default branch's map when there is one,
        // else any other branch's, so only its own changes are written.
        if (existing.count() > 0) base = existing.values()[0];
        var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
        if (rf.readHead(.xit, repo_opts, read_state, io, &head_buffer) catch null) |head| switch (head) {
            .ref => |ref| if (existing.get(hash.hashInt(repo_opts.hash, ref.name))) |entry| {
                base = entry;
            },
            .oid => {},
        };

        var branches = try rf.RefIterator(.xit, repo_opts).init(read_state, io, allocator, .head, .beginning);
        defer branches.deinit();
        while (try branches.next()) |ref| {
            if (std.mem.eql(u8, ref.name, evt.events_ref.name)) continue;
            const branch_hash = hash.hashInt(repo_opts.hash, ref.name);
            const own = if (existing.fetchSwapRemove(branch_hash)) |kv| kv.value else null;
            const oid = (try rf.readRecur(.xit, repo_opts, read_state, io, .{ .ref = .{ .kind = .head, .name = ref.name } })) orelse continue;
            if (own) |entry| if (std.mem.eql(u8, &entry.oid, &oid)) continue;
            try work.append(aa, .{ .branch_hash = branch_hash, .oid = oid, .own = own });
        }

        // whatever is left belongs to a branch that no longer exists
        for (existing.keys()) |branch_hash| try work.append(aa, .{ .branch_hash = branch_hash, .oid = null, .own = null });
    }

    if (work.items.len == 0) return false;

    {
        const index_hash = hash.hashInt(repo_opts.hash, index_key);
        var new_branch_base = base;
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Indexing files" });

        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(allocator);

        for (work.items) |item| {
            if (progress.cancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
            const index = try DB.HashMap(.read_write).init(try moment.putCursor(index_hash));
            const tip = item.oid orelse {
                _ = try index.remove(item.branch_hash);
                continue;
            };
            // the entry this one starts from (null = index the whole tree)
            const from = item.own orelse new_branch_base;

            var tip_bytes: [hash.byteLen(repo_opts.hash)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&tip_bytes, &tip);
            // putKey only fills an empty key slot, and this one changes
            // whenever the branch moves
            var tip_cursor = try index.putKeyCursor(item.branch_hash);
            try tip_cursor.write(.{ .bytes = &tip_bytes });
            var files_cursor = try index.putCursor(item.branch_hash);
            if (from) |entry| try files_cursor.write(.{ .slot = entry.files });
            const files = try DB.SortedMap(.read_write).init(files_cursor);

            const tree = try rootTreeOid(repo_opts, state.readOnly(), io, allocator, &tip);
            if (from) |entry| {
                const from_tree = try rootTreeOid(repo_opts, state.readOnly(), io, allocator, &entry.oid);
                var tree_diff = tr.TreeDiff(.xit, repo_opts).init(allocator);
                defer tree_diff.deinit();
                try tree_diff.compare(state.readOnly(), io, &from_tree, &tree, null);
                progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = tree_diff.changes.count() } });
                for (tree_diff.changes.keys(), tree_diff.changes.values()) |path, change| {
                    defer progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
                    try fileKey(allocator, &key, path);
                    const oid = if (change.new) |*tree_entry| indexedOid(repo_opts.hash, tree_entry) else null;
                    if (oid) |bytes| {
                        try files.put(key.items, .{ .bytes = bytes });
                    } else {
                        _ = try files.remove(key.items);
                    }
                }
            } else {
                // a whole tree has no count until it is walked, so it reports
                // the files it has indexed so far
                progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = 0 } });
                var paths = std.heap.ArenaAllocator.init(allocator);
                defer paths.deinit();
                try indexTree(repo_opts, state.readOnly(), io, allocator, paths.allocator(), files, &key, "", &tree, progress_ctx_maybe);
            }
            progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });

            // the first entry ever written becomes the base for the next
            // new branch, so only one branch walks a whole tree.
            if (new_branch_base == null) new_branch_base = .{ .oid = tip, .files = (try index.getSlot(item.branch_hash)) orelse unreachable };
            // a later entry copies an earlier one's slot, so everything
            // written so far has to be shared rather than mutated
            try state.core.db.freeze();
        }
    }
    return true;
}

// insert every file under `oid` (a tree), as tr.Tree.read walks one.
fn indexTree(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_only),
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: std.mem.Allocator,
    files: rp.Repo(.xit, repo_opts).DB.SortedMap(.read_write),
    key: *std.ArrayList(u8),
    prefix: []const u8,
    oid: *const [hash.hexLen(repo_opts.hash)]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    var object = try obj.Object(.xit, repo_opts).init(state, io, allocator, oid);
    defer object.deinit();
    const tree = switch (object.content) {
        .tree => |tree| tree,
        else => return,
    };
    for (tree.entries.keys(), tree.entries.values()) |name, *tree_entry| {
        if (progress.cancelled(repo_opts, progress_ctx_maybe)) return error.ClientGone;
        const path = try fs.joinPath(paths, &.{ prefix, name });
        if (tree_entry.isTree()) {
            try indexTree(repo_opts, state, io, allocator, paths, files, key, path, &std.fmt.bytesToHex(tree_entry.oid, .lower), progress_ctx_maybe);
        } else if (indexedOid(repo_opts.hash, tree_entry)) |bytes| {
            try fileKey(allocator, key, path);
            try files.put(key.items, .{ .bytes = bytes });
            progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
        }
    }
}

// the tip an index entry covers, read from its key slot as hex.
fn readOid(
    comptime repo_opts: rp.RepoOpts(.xit),
    key_cursor: rp.Repo(.xit, repo_opts).DB.Cursor(.read_only),
) ![hash.hexLen(repo_opts.hash)]u8 {
    var oid: [hash.byteLen(repo_opts.hash)]u8 = undefined;
    if ((try key_cursor.readBytes(&oid)).len != oid.len) return error.InvalidFileIndex;
    return std.fmt.bytesToHex(oid, .lower);
}

// build a file's key: its lowercased basename, a separator, then its full path.
fn fileKey(allocator: std.mem.Allocator, key: *std.ArrayList(u8), path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |i| path[i + 1 ..] else path;
    key.clearRetainingCapacity();
    try key.ensureTotalCapacity(allocator, base.len + 1 + path.len);
    for (base) |char| key.appendAssumeCapacity(std.ascii.toLower(char));
    key.appendAssumeCapacity(0);
    key.appendSliceAssumeCapacity(path);
}

// the blob oid a tree entry is indexed under, or null for a submodule: its oid
// is a commit in another repo, not a file here.
fn indexedOid(comptime hash_kind: hash.HashKind, tree_entry: *const tr.TreeEntry(hash_kind)) ?[]const u8 {
    if (tree_entry.mode.content.object_type == .gitlink) return null;
    return &tree_entry.oid;
}

fn parseOid(comptime hash_kind: hash.HashKind, value: []const u8) ![hash.byteLen(hash_kind)]u8 {
    const len = comptime hash.byteLen(hash_kind);
    if (value.len != len) return error.InvalidFileIndex;
    return value[0..len].*;
}

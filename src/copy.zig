const std = @import("std");
const evt = @import("event.zig");
const fork = @import("fork.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const rf = xit.ref;

// the action creating a repo as a copy of another records
pub const undo_action = "haxy/copy";

// the history index of the transaction that made the repo a copy
const index_key = "haxy/copy-index";

// stream `source`'s db into a new db in `repo_dir`
pub fn copyDb(io: std.Io, source: std.Io.File, repo_dir: std.Io.Dir) !void {
    try source.lock(io, .shared);
    defer source.unlock(io);

    // file to file streaming uses copy_file_range, which reflinks where the filesystem can
    const destination = try repo_dir.createFile(io, "db", .{ .exclusive = true, .read = true });
    defer destination.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = source.reader(io, &read_buffer);
    var writer = destination.writer(io, &write_buffer);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
    try destination.sync(io);
}

// drop the events a copied db carries, with the state consuming them built
pub fn clearEvents(
    comptime repo_opts: rp.RepoOpts(.xit),
    state: rp.Repo(.xit, repo_opts).State(.read_write),
    io: std.Io,
) !void {
    var path_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    rf.remove(.xit, repo_opts, state, io, try evt.events_ref.toPath(&path_buffer)) catch |err| switch (err) {
        error.RefNotFound => {},
        else => |other| return other,
    };
    _ = try state.extra.moment.remove(hash.hashInt(repo_opts.hash, evt.history_key));
    _ = try state.extra.moment.remove(hash.hashInt(repo_opts.hash, evt.last_object_id_key));
}

// create the repo at `path` as a copy of the one at `source_path`, keeping
// its git data and dropping its events
pub fn create(io: std.Io, allocator: std.mem.Allocator, source_path: []const u8, path: []const u8) !void {
    var any_source = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = source_path, .require_repo_root = true });
    defer any_source.deinit(io, allocator);
    switch (any_source) {
        inline else => |*source| try copyRepo(source.self_repo_opts, io, allocator, source, path),
    }
}

fn copyRepo(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    source: *rp.Repo(.xit, repo_opts),
    path: []const u8,
) !void {
    errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    {
        const repo_dir_path = try std.Io.Dir.path.join(allocator, &.{ path, ".xit" });
        defer allocator.free(repo_dir_path);
        var repo_dir = try std.Io.Dir.cwd().createDirPathOpen(io, repo_dir_path, .{});
        defer repo_dir.close(io);
        try copyDb(io, source.core.db_file, repo_dir);
    }

    var repo = try rp.Repo(.xit, repo_opts).open(io, allocator, .{ .path = path, .require_repo_root = true });
    defer repo.deinit(io, allocator);

    const DB = rp.Repo(.xit, repo_opts).DB;
    const State = rp.Repo(.xit, repo_opts).State;
    const Ctx = struct {
        core: *rp.Repo(.xit, repo_opts).Core,
        io: std.Io,
        allocator: std.mem.Allocator,
        index: u64,

        pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
            var moment = try DB.HashMap(.read_write).init(cursor.*);
            const state = State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
            try clearEvents(repo_opts, state, ctx.io);

            var config = try xit.config.Config(.xit, repo_opts).init(state.readOnly(), ctx.io, ctx.allocator);
            defer config.deinit();
            try fork.clearForkers(repo_opts, state, ctx.io, ctx.allocator, &config);

            try moment.put(hash.hashInt(repo_opts.hash, index_key), .{ .uint = ctx.index });
            try xit.undo.write(repo_opts, state, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), .{ .custom = .{ .action_kind = undo_action } });
        }
    };

    try repo.core.db_file.lock(io, .exclusive);
    defer repo.core.db_file.unlock(io);

    const history = try DB.ArrayList(.read_write).init(repo.core.db.rootCursor());
    try history.appendContext(
        .{ .slot = try history.getSlot(-1) },
        Ctx{ .core = &repo.core, .io = io, .allocator = allocator, .index = try history.count() },
    );
}

// the lowest transaction undo may reach, or null when the repo isn't a copy.
// the history beneath it belongs to the repo it copied
pub fn undoFloor(comptime repo_opts: rp.RepoOpts(.xit), core: *rp.Repo(.xit, repo_opts).Core) !?u64 {
    const cursor = try (try core.latestMoment()).getCursor(hash.hashInt(repo_opts.hash, index_key)) orelse return null;
    const index = try cursor.readUint();
    // a gc compacts the history away, leaving an index that names some other transaction
    const moment = core.momentAt(index) catch |err| switch (err) {
        error.TransactionNotFound => return null,
        else => |other| return other,
    };
    var buffer: [repo_opts.max_read_size]u8 = undefined;
    const record = try xit.undo.read(repo_opts, moment, &buffer) orelse return null;
    if (!std.mem.eql(u8, record.action_kind, undo_action)) return null;
    return index;
}

const std = @import("std");
const evt = @import("./event.zig");
const rp = @import("xit").repo;

// the outcome of resolving a requested repo path to its on-disk directory.
// the http and ssh paths each map the cases to their own error responses.
pub const RepoPath = union(enum) {
    ok: []const u8, // resolved on-disk path; the caller owns and frees it
    invalid, // a <owner>:<repo> path was expected but not given
    not_found, // unknown owner, or the repo doesn't exist
};

// resolve a requested repo path to its on-disk directory, parsed as
// <owner>:<repo> through the event store.
pub fn resolveRepoPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_path: []const u8,
    admin_repo_path: []const u8,
    requested: []const u8,
) !RepoPath {
    const owner_repo = evt.parseOwnerRepoPath(requested) orelse return .invalid;
    const location = (try evt.resolveOrCreateRepo(
        io,
        allocator,
        users_path,
        admin_repo_path,
        owner_repo.owner,
        owner_repo.name,
        null,
    )) orelse return .not_found;
    return .{ .ok = try evt.repoPath(allocator, users_path, &location.owner_id, &location.repo_id) };
}

// every connection task shares one error writer, so writing to it takes a
// lock. uncancelable, since a log line shouldn't be a cancelation point.
var log_mutex: std.Io.Mutex = .init;

pub fn logError(io: std.Io, err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

// accept connections forever, spawning `handleConn(context, stream)` as a task
// for each. the handler owns the stream (it closes it). `name` labels accept
// errors in the log. shared by the ssh and web ui listeners. concurrent, since
// async runs inline once the cpu-sized pool is busy.
pub fn runListener(
    io: std.Io,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
    name: []const u8,
    context: anytype,
    comptime handleConn: fn (@TypeOf(context), std.Io.net.Stream) void,
) void {
    const Context = @TypeOf(context);

    const Conn = struct {
        context: Context,
        stream: std.Io.net.Stream,

        fn run(c: @This()) void {
            handleConn(c.context, c.stream);
        }
    };

    const Listener = struct {
        io: std.Io,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,
        name: []const u8,
        context: Context,

        fn run(self: @This()) void {
            while (true) {
                const stream = self.net_server.accept(self.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(self.io, self.err, "{s} accept failed: {s}\n", .{ self.name, @errorName(accept_err) });
                    continue;
                };
                self.tasks.concurrent(self.io, Conn.run, .{Conn{ .context = self.context, .stream = stream }}) catch |spawn_err| {
                    logError(self.io, self.err, "{s} connection spawn failed: {s}\n", .{ self.name, @errorName(spawn_err) });
                    stream.close(self.io);
                };
            }
        }
    };

    tasks.concurrent(io, Listener.run, .{Listener{
        .io = io,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
        .name = name,
        .context = context,
    }}) catch |spawn_err| {
        logError(io, err, "{s}: listener spawn failed: {s}\n", .{ name, @errorName(spawn_err) });
    };
}

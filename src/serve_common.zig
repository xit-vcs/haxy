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
// async runs inline once the cpu-sized pool is busy. over `max_connections`
// in-flight handlers, a stream is closed before any task is spawned.
pub fn runListener(
    io: std.Io,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
    name: []const u8,
    context: anytype,
    max_connections: ?u32,
    comptime handleConn: fn (@TypeOf(context), std.Io.net.Stream) void,
) void {
    const Context = @TypeOf(context);

    // one per instantiation, shared by every connection this listener spawns
    const active = struct {
        var count: std.atomic.Value(u32) = .init(0);
    };

    const Conn = struct {
        context: Context,
        stream: std.Io.net.Stream,

        fn run(c: @This()) void {
            defer _ = active.count.fetchSub(1, .acq_rel);
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
        max_connections: ?u32,

        fn run(self: @This()) void {
            while (true) {
                const stream = self.net_server.accept(self.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(self.io, self.err, "{s} accept failed: {s}\n", .{ self.name, @errorName(accept_err) });
                    continue;
                };
                const in_flight = active.count.fetchAdd(1, .acq_rel);
                if (self.max_connections) |max| {
                    if (in_flight >= max) {
                        _ = active.count.fetchSub(1, .acq_rel);
                        logError(self.io, self.err, "{s} connection limit reached: ip={f}\n", .{ self.name, stream.socket.address });
                        stream.close(self.io);
                        continue;
                    }
                }
                self.tasks.concurrent(self.io, Conn.run, .{Conn{ .context = self.context, .stream = stream }}) catch |spawn_err| {
                    _ = active.count.fetchSub(1, .acq_rel);
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
        .max_connections = max_connections,
    }}) catch |spawn_err| {
        logError(io, err, "{s}: listener spawn failed: {s}\n", .{ name, @errorName(spawn_err) });
    };
}

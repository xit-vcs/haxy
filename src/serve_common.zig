const std = @import("std");
const evt = @import("./event.zig");

// the outcome of resolving a requested repo path to its on-disk directory.
// the http and ssh paths each map the cases to their own error responses.
pub const RepoPath = union(enum) {
    ok: []const u8, // resolved on-disk path; the caller owns and frees it
    invalid, // a <owner>/<repo> path was expected but not given
    not_found, // unknown owner, or the repo doesn't exist and we aren't creating
};

// resolve a requested repo path to its on-disk directory, parsed as
// <owner>/<repo> through the event store, minting a repo event for a fresh push.
pub fn resolveRepoPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo_path: []const u8,
    requested: []const u8,
    create_if_missing: bool,
) !RepoPath {
    const owner_repo = evt.parseOwnerRepoPath(requested) orelse return .invalid;
    const event_id_hex = (try evt.resolveOrCreateRepo(io, allocator, admin_repo_path, owner_repo.owner, owner_repo.name, create_if_missing)) orelse return .not_found;
    return .{ .ok = try std.fs.path.join(allocator, &.{ repo_root_path, &event_id_hex }) };
}

pub fn logError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

// accept connections forever, spawning `handleConn(context, stream)` as a task
// for each. the handler owns the stream (it closes it). `name` labels accept
// errors in the log. shared by the http, ssh, and web ui listeners.
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
                    logError(self.err, "{s} accept failed: {s}\n", .{ self.name, @errorName(accept_err) });
                    continue;
                };
                self.tasks.async(self.io, Conn.run, .{Conn{ .context = self.context, .stream = stream }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
        .name = name,
        .context = context,
    }});
}

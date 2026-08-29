const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const serve_common = @import("./serve_common.zig");
const serve_ssh_protocol = @import("./serve_ssh_protocol.zig");
const serve_ssh = @import("./serve_ssh.zig");
const serve_http = @import("./serve_http.zig");

pub const Options = struct {
    http_listen: ?[]const u8 = "127.0.0.1:8080",
    ssh_listen: ?[]const u8 = "127.0.0.1:8022",
    wui_listen: []const u8 = "127.0.0.1:8000",
    data_dir: []const u8 = ".",
};

const ListenAddress = struct {
    host: []const u8,
    port: u16,
};

const BoundListener = struct {
    address: ListenAddress,
    server: std.Io.net.Server,

    fn deinit(self: *BoundListener, io: std.Io) void {
        self.server.deinit(io);
    }

    fn port(self: *const BoundListener) u16 {
        return self.server.socket.address.getPort();
    }
};

const SshService = struct {
    listener: BoundListener,
    host_key: serve_ssh_protocol.HostKey,
    session_handler: serve_ssh.SessionHandler,
};

pub fn run(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    options: Options,
    err: *std.Io.Writer,
    runnable: anytype,
) !void {
    // create the data dir

    const data_dir_path = try std.fs.path.resolve(allocator, &.{ cwd_path, options.data_dir });
    defer allocator.free(data_dir_path);

    const data_dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir_path, .{});
    defer data_dir.close(io);

    // create the repos dir

    const repo_root_path = try std.fs.path.resolve(allocator, &.{ data_dir_path, "repos" });
    defer allocator.free(repo_root_path);

    try std.Io.Dir.cwd().createDirPath(io, repo_root_path);

    // the admin repo path is where the user/repo metadata events live

    const admin_repo_path = try std.fs.path.resolve(allocator, &.{ data_dir_path, "admin" });
    defer allocator.free(admin_repo_path);

    // create http listener

    var http_maybe: ?BoundListener = if (options.http_listen) |value| blk: {
        const address = try parseListenAddress(value);
        break :blk .{ .address = address, .server = try listen(io, address, .reuse) };
    } else null;
    defer if (http_maybe) |*http| http.deinit(io);

    // disk-backed store for web login sessions
    const session_store = try web.SessionStore.init(io, data_dir);
    defer session_store.deinit();

    // create wui listener

    const wui_listen_address = try parseListenAddress(options.wui_listen);
    var wui_server = try listen(io, wui_listen_address, .reuse);
    defer wui_server.deinit(io);

    // create ssh listener and its session state

    const git_http_port: ?u16 = if (http_maybe) |*http| http.port() else null;
    var ssh_maybe: ?SshService = if (options.ssh_listen) |value| blk: {
        const address = try parseListenAddress(value);
        var listener = BoundListener{ .address = address, .server = try listen(io, address, .reuse) };
        errdefer listener.deinit(io);
        const ssh_port = listener.port();
        break :blk .{
            .listener = listener,
            .host_key = try serve_ssh_protocol.HostKey.loadOrGenerate(io, allocator, data_dir_path),
            .session_handler = .{
                .admin_repo_path = admin_repo_path,
                .repo_root_path = repo_root_path,
                .wui_port = wui_server.socket.address.getPort(),
                .git_http_port = git_http_port,
                .git_ssh_port = ssh_port,
                .err = err,
            },
        };
    } else null;
    defer if (ssh_maybe) |*ssh| ssh.listener.deinit(io);

    // start task group

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    // run listeners, printing the ports actually bound

    const git_ssh_port: ?u16 = if (ssh_maybe) |*ssh| ssh.listener.port() else null;

    if (http_maybe) |*http| {
        try err.print("serving HTTP on {s}:{d}, repo root {s}\n", .{ http.address.host, http.port(), repo_root_path });
        try err.flush();
        serve_http.runListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, admin_repo_path, &http.server, &tasks, err);
    }

    if (ssh_maybe) |*ssh| {
        try err.print("serving SSH on {s}:{d}\n", .{ ssh.listener.address.host, ssh.listener.port() });
        try err.flush();
        serve_ssh.runListener(io, allocator, &ssh.host_key, &ssh.session_handler, &ssh.listener.server, &tasks, err);
    }

    try err.print("serving web UI on http://{s}:{d}/\n", .{ wui_listen_address.host, wui_server.socket.address.getPort() });
    try err.flush();

    runWebListener(io, allocator, &wui_server, &tasks, .{ .remote = .{
        .admin_repo_path = admin_repo_path,
        .session_store = session_store,
        .git_http_port = git_http_port,
        .git_ssh_port = git_ssh_port,
    } }, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run(wui_server.socket.address.getPort(), git_http_port, git_ssh_port);
    } else {
        try tasks.await(io);
    }
}

// serve just the web UI for a single local repo, running `runnable` (the
// local TUI) in the foreground while the listener runs in the background.
// when the default port is taken, a random ephemeral port is used instead;
// the bound port is passed to `runnable.run`.
pub fn runLocal(
    io: std.Io,
    allocator: std.mem.Allocator,
    local: ui.RepoSource,
    err: *std.Io.Writer,
    runnable: anytype,
) !void {
    // always fall back, so another instance viewing a second repo just binds
    // its own port
    const wui_listen_address = try parseListenAddress((Options{}).wui_listen);
    var wui_server = try listen(io, wui_listen_address, .fallback);
    defer wui_server.deinit(io);

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    runWebListener(io, allocator, &wui_server, &tasks, .{ .local = local }, err);

    try runnable.run(wui_server.socket.address.getPort());
}

fn runWebListener(
    io: std.Io,
    allocator: std.mem.Allocator,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    host: web.Host,
    err: *std.Io.Writer,
) void {
    const Context = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        host: web.Host,
        err: *std.Io.Writer,
    };

    const handle = struct {
        fn h(ctx: Context, stream: std.Io.net.Stream) void {
            defer stream.close(ctx.io);
            web.handleConnection(ctx.io, ctx.allocator, stream, ctx.host, ctx.err) catch |request_err| {
                serve_common.logError(ctx.io, ctx.err, "web ui request failed: {s}\n", .{@errorName(request_err)});
            };
        }
    }.h;

    serve_common.runListener(io, net_server, tasks, err, "web ui", Context{
        .io = io,
        .allocator = allocator,
        .host = host,
        .err = err,
    }, handle);
}

// what a listener does with a port that is already taken
const PortPolicy = enum {
    // bind it anyway, so a restart isn't blocked by the last run's connections
    // sitting in TIME_WAIT. on linux this also sets SO_REUSEPORT, so a server
    // already holding the port ends up sharing it.
    reuse,
    // leave it to whoever holds it and take an OS-assigned port instead
    fallback,
};

fn listen(io: std.Io, listen_address: ListenAddress, policy: PortPolicy) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4(listen_address.host, listen_address.port);
    return switch (policy) {
        .reuse => try address.listen(io, .{ .reuse_address = true }),
        .fallback => address.listen(io, .{}) catch |listen_err| switch (listen_err) {
            error.AddressInUse => blk: {
                const any_port = try std.Io.net.IpAddress.parseIp4(listen_address.host, 0);
                break :blk try any_port.listen(io, .{});
            },
            else => |e| return e,
        },
    };
}

fn parseListenAddress(value: []const u8) !ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

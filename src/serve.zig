const std = @import("std");
const builtin = @import("builtin");
const xit = @import("xit");
const rp = xit.repo;
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const serve_common = @import("./serve_common.zig");
const serve_ssh_protocol = @import("./serve_ssh_protocol.zig");
const serve_ssh = @import("./serve_ssh.zig");
const serve_http = @import("./serve_http.zig");

pub const Options = struct {
    http_listen: []const u8 = "127.0.0.1:8080",
    ssh_listen: []const u8 = "127.0.0.1:8022",
    wui_listen: []const u8 = "127.0.0.1:8000",
    data_dir: []const u8 = ".",
};

const ListenAddress = struct {
    host: []const u8,
    port: u16,
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

    // a debug build is a dev run, so a taken port falls back to a random one;
    // a release build fails, since whatever points at the configured port
    // would silently break.
    const fallback = builtin.mode == .Debug;

    // create http listener

    const http_listen_address = try parseListenAddress(options.http_listen);
    var http_server = try listenWithFallback(io, http_listen_address, fallback);
    defer http_server.deinit(io);

    // create ssh listener

    const ssh_listen_address = try parseListenAddress(options.ssh_listen);
    var ssh_server = try listenWithFallback(io, ssh_listen_address, fallback);
    defer ssh_server.deinit(io);

    // load or generate the SSH host key
    const host_key = try serve_ssh_protocol.HostKey.loadOrGenerate(io, allocator, data_dir_path);

    // disk-backed store for web login sessions
    const session_store = try web.SessionStore.init(io, data_dir);
    defer session_store.deinit();

    // create wui listener

    const wui_listen_address = try parseListenAddress(options.wui_listen);
    var wui_server = try listenWithFallback(io, wui_listen_address, fallback);
    defer wui_server.deinit(io);

    // start task group

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    // run listeners, printing the ports actually bound

    try err.print("serving HTTP on {s}:{d}, repo root {s}\n", .{ http_listen_address.host, http_server.socket.address.getPort(), repo_root_path });
    try err.flush();

    serve_http.runListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, admin_repo_path, &http_server, &tasks, err);

    try err.print("serving SSH on {s}:{d}\n", .{ ssh_listen_address.host, ssh_server.socket.address.getPort() });
    try err.flush();

    const ssh_session_handler = serve_ssh.SessionHandler{
        .admin_repo_path = admin_repo_path,
        .repo_root_path = repo_root_path,
        .wui_port = wui_server.socket.address.getPort(),
        .err = err,
    };
    serve_ssh.runListener(io, allocator, &host_key, &ssh_session_handler, &ssh_server, &tasks, err);

    try err.print("serving web UI on http://{s}:{d}/\n", .{ wui_listen_address.host, wui_server.socket.address.getPort() });
    try err.flush();

    runWebListener(io, allocator, &wui_server, &tasks, .{ .remote = .{
        .admin_repo_path = admin_repo_path,
        .session_store = session_store,
    } }, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run(wui_server.socket.address.getPort(), ssh_server.socket.address.getPort());
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
    var wui_server = try listenWithFallback(io, wui_listen_address, true);
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

// bind the address. when it's taken, fall back to an OS-assigned port, or
// fail without `fallback`. no reuse_address: on linux it also sets
// SO_REUSEPORT, which would let this bind silently share a port an
// already-running server holds rather than seeing it as taken.
fn listenWithFallback(io: std.Io, listen_address: ListenAddress, fallback: bool) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4(listen_address.host, listen_address.port);
    return address.listen(io, .{}) catch |listen_err| switch (listen_err) {
        error.AddressInUse => blk: {
            if (!fallback) return listen_err;
            const any_port = try std.Io.net.IpAddress.parseIp4(listen_address.host, 0);
            break :blk try any_port.listen(io, .{});
        },
        else => |e| return e,
    };
}

fn parseListenAddress(value: []const u8) !ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

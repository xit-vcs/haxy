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
    http_listen: []const u8 = "127.0.0.1:8080",
    ssh_listen: []const u8 = "127.0.0.1:8022",
    wui_listen: []const u8 = "127.0.0.1:8000",
    data_dir: []const u8 = ".",

    // the port from `wui_listen`, for the TUI footer's url.
    pub fn wuiPort(self: Options) !u16 {
        return (try parseListenAddress(self.wui_listen)).port;
    }
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

    // create http listener

    const http_listen_address = try parseListenAddress(options.http_listen);
    const http_address = try std.Io.net.IpAddress.parseIp4(http_listen_address.host, http_listen_address.port);
    var http_server = try http_address.listen(io, .{ .reuse_address = true });
    defer http_server.deinit(io);

    // create ssh listener

    const ssh_listen_address = try parseListenAddress(options.ssh_listen);
    const ssh_address = try std.Io.net.IpAddress.parseIp4(ssh_listen_address.host, ssh_listen_address.port);
    var ssh_server = try ssh_address.listen(io, .{ .reuse_address = true });
    defer ssh_server.deinit(io);

    // load or generate the SSH host key
    const host_key = try serve_ssh_protocol.HostKey.loadOrGenerate(io, allocator, data_dir_path);

    // disk-backed store for web login sessions
    const session_store = try web.SessionStore.init(io, data_dir);
    defer session_store.deinit();

    // create wui listener

    const wui_listen_address = try parseListenAddress(options.wui_listen);
    const wui_address = try std.Io.net.IpAddress.parseIp4(wui_listen_address.host, wui_listen_address.port);
    var wui_server = try wui_address.listen(io, .{ .reuse_address = true });
    defer wui_server.deinit(io);

    // start task group

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    // run listeners

    try err.print("serving HTTP on {s}, repo root {s}\n", .{ options.http_listen, repo_root_path });
    try err.flush();

    serve_http.runListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, admin_repo_path, &http_server, &tasks, err);

    try err.print("serving SSH on {s}\n", .{options.ssh_listen});
    try err.flush();

    const ssh_session_handler = serve_ssh.SessionHandler{
        .admin_repo_path = admin_repo_path,
        .repo_root_path = repo_root_path,
        .wui_port = wui_listen_address.port,
        .err = err,
    };
    serve_ssh.runListener(io, allocator, &host_key, &ssh_session_handler, &ssh_server, &tasks, err);

    try err.print("serving web UI on http://{s}/\n", .{options.wui_listen});
    try err.flush();

    runWebListener(io, allocator, &wui_server, &tasks, .{ .remote = .{
        .admin_repo_path = admin_repo_path,
        .session_store = session_store,
    } }, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run();
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
    // no reuse_address here: on linux it also sets SO_REUSEPORT, which would
    // let this bind silently share a port an already-running server holds
    // instead of failing over to a random one.
    const wui_listen_address = try parseListenAddress((Options{}).wui_listen);
    const wui_address = try std.Io.net.IpAddress.parseIp4(wui_listen_address.host, wui_listen_address.port);
    var wui_server = wui_address.listen(io, .{}) catch |listen_err| switch (listen_err) {
        // the default port is taken; bind port 0 so the OS assigns a free one
        error.AddressInUse => blk: {
            const any_port = try std.Io.net.IpAddress.parseIp4(wui_listen_address.host, 0);
            break :blk try any_port.listen(io, .{});
        },
        else => |e| return e,
    };
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
                serve_common.logError(ctx.err, "web ui request failed: {s}\n", .{@errorName(request_err)});
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

fn parseListenAddress(value: []const u8) !ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

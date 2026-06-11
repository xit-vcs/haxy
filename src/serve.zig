const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const web = @import("./web.zig");
const serve_ssh_protocol = @import("./serve_ssh_protocol.zig");
const serve_ssh = @import("./serve_ssh.zig");
const serve_http = @import("./serve_http.zig");

pub const Options = struct {
    http_listen: []const u8 = "127.0.0.1:8080",
    ssh_listen: []const u8 = "127.0.0.1:8022",
    wui_listen: []const u8 = "127.0.0.1:8000",
    data_dir: []const u8 = ".",
    // test mode, used by the networking tests. it serves repos directly by
    // their on-disk path instead of resolving them as <owner>/<repo> through
    // the event store, giving the plain git-server behavior those tests rely on.
    is_test: bool = false,
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

    serve_http.runListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, admin_repo_path, options.is_test, &http_server, &tasks, err);

    try err.print("serving SSH on {s}\n", .{options.ssh_listen});
    try err.flush();

    const ssh_session_handler = serve_ssh.SessionHandler{
        .admin_repo_path = admin_repo_path,
        .repo_root_path = repo_root_path,
        .is_test = options.is_test,
    };
    serve_ssh.runListener(io, allocator, &host_key, &ssh_session_handler, &ssh_server, &tasks, err);

    try err.print("serving web UI on http://{s}/\n", .{options.wui_listen});
    try err.flush();

    web.run(io, allocator, &wui_server, &tasks, admin_repo_path, session_store, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run();
    } else {
        try tasks.await(io);
    }
}

fn parseListenAddress(value: []const u8) !ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

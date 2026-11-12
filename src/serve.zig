const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const serve_common = @import("./serve_common.zig");
const serve_ssh_protocol = @import("./serve_ssh_protocol.zig");
const serve_ssh = @import("./serve_ssh.zig");
const serve_http = @import("./serve_http.zig");
const evt = @import("./event.zig");
const popularity = @import("./popularity.zig");

pub const Options = struct {
    web_listen: []const u8 = "127.0.0.1:8080",
    ssh_listen: ?[]const u8 = "127.0.0.1:8022",
    // the public urls shown to users, defaulting to localhost and the bound port
    web_url: ?[]const u8 = null,
    ssh_url: ?[]const u8 = null,
    // the size a pushed repo's db may grow to, or null for no limit
    max_repo_size: ?u64 = null,
    data_path: []const u8 = ".",
    git_ssh_prefix: []const u8 = "",
    fallback_on_address_in_use: bool = false,
};

pub const DeleteUserOptions = struct {
    name: []const u8,
    data_path: []const u8 = ".",
};

// delete the named user as their own delete tab does, minus the password check
pub fn deleteUser(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    options: DeleteUserOptions,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    const data_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ cwd_path, options.data_path });
    defer allocator.free(data_path);
    const users_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ data_path, "users" });
    defer allocator.free(users_path);
    const admin_repo_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ data_path, "admin" });
    defer allocator.free(admin_repo_path);

    var admin_repo = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |open_err| switch (open_err) {
        error.RepoNotFound, error.FileNotFound => {
            try err.print("no haxy data in {s}\n", .{data_path});
            return error.HandledError;
        },
        else => |e| return e,
    };
    defer admin_repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    const user_id, const user = blk: {
        if (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, options.name)) |id| {
            if (try ui.activeUser(moment, &arena, id)) |found| break :blk .{ id, found };
        }
        try err.print("no user named {s}\n", .{options.name});
        return error.HandledError;
    };

    try evt.deleteUser(io, allocator, users_path, &admin_repo, &user_id, .{ .name = user.event.name, .email = user.event.email });
    try out.print("deleted user {s}\n", .{user.event.name});
}

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
    watchdog: serve_ssh.Watchdog = .{},
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

    const data_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ cwd_path, options.data_path });
    defer allocator.free(data_path);

    const data_dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_path, .{});
    defer data_dir.close(io);

    // create the users dir

    const users_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ data_path, "users" });
    defer allocator.free(users_path);

    try std.Io.Dir.cwd().createDirPath(io, users_path);

    // the admin repo path is where the user/repo metadata events live

    const admin_repo_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ data_path, "admin" });
    defer allocator.free(admin_repo_path);

    // create the admin repo on first run, and bring the users list's index in
    // line with its users
    {
        var admin_repo = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |open_err| switch (open_err) {
            error.RepoNotFound, error.FileNotFound => try evt.initAdminRepo(io, allocator, admin_repo_path),
            else => |e| return e,
        };
        defer admin_repo.deinit(io, allocator);
        try popularity.reconcile(io, allocator, users_path, &admin_repo);
    }

    const port_policy: PortPolicy = if (options.fallback_on_address_in_use) .fallback else .exact;

    // disk-backed store for web login sessions
    const session_store = try web.SessionStore.init(io, data_dir);
    defer session_store.deinit();

    // create web listener

    const web_listen_address = try parseListenAddress(options.web_listen);
    var web_server = try listen(io, web_listen_address, port_policy);
    defer web_server.deinit(io);

    const web_url = options.web_url orelse try allocator.print("http://localhost:{d}", .{web_server.socket.address.getPort()});
    defer if (options.web_url == null) allocator.free(web_url);

    // create ssh listener and its session state

    var ssh_url_owned: ?[]const u8 = null;
    defer if (ssh_url_owned) |url| allocator.free(url);
    var ssh_maybe: ?SshService = if (options.ssh_listen) |value| blk: {
        const address = try parseListenAddress(value);
        var listener = BoundListener{ .address = address, .server = try listen(io, address, port_policy) };
        errdefer listener.deinit(io);
        const ssh_url = options.ssh_url orelse url_blk: {
            const url = try allocator.print("ssh://localhost:{d}", .{listener.port()});
            ssh_url_owned = url;
            break :url_blk url;
        };
        break :blk .{
            .listener = listener,
            .host_key = try serve_ssh_protocol.HostKey.loadOrGenerate(io, allocator, data_path),
            .session_handler = .{
                .admin_repo_path = admin_repo_path,
                .server = .{ .users_path = users_path, .admin_repo_path = admin_repo_path },
                .web_url = web_url,
                .ssh_url = ssh_url,
                .git_ssh_prefix = options.git_ssh_prefix,
                .max_repo_size = options.max_repo_size,
                .err = err,
            },
        };
    } else null;
    defer if (ssh_maybe) |*ssh| ssh.listener.deinit(io);

    // start task group

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    // run listeners, printing the ports actually bound

    const ssh_url: ?[]const u8 = if (ssh_maybe) |*ssh| ssh.session_handler.ssh_url else null;

    if (ssh_maybe) |*ssh| {
        try err.print("serving SSH on {s}:{d}, host key ED25519 {s}\n", .{ ssh.listener.address.host, ssh.listener.port(), try ssh.host_key.fingerprint(allocator) });
        try err.flush();
        serve_ssh.runListener(io, allocator, &ssh.host_key, &ssh.session_handler, &ssh.watchdog, &ssh.listener.server, &tasks, err);
    }

    try err.print("serving web UI and git over HTTP on http://{s}:{d}/, users dir {s}\n", .{ web_listen_address.host, web_server.socket.address.getPort(), users_path });
    try err.flush();

    runWebListener(io, allocator, &web_server, &tasks, .{ .server = .{
        .admin_repo_path = admin_repo_path,
        .users_path = users_path,
        .session_store = session_store,
        .web_url = web_url,
        .ssh_url = ssh_url,
        .git_ssh_prefix = options.git_ssh_prefix,
        .serve_git = serve_http.gitHandler(repo_kind, any_repo_opts),
    } }, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run(web_url, ssh_url);
    } else {
        try tasks.await(io);
    }
}

// serve just the web UI for a single local repo, running `runnable` (the
// local TUI) in the foreground while the listener runs in the background.
// when the default port is taken, a random ephemeral port is used instead;
// the web UI's url is passed to `runnable.run`.
pub fn runLocal(
    io: std.Io,
    allocator: std.mem.Allocator,
    local: ui.RepoSource,
    err: *std.Io.Writer,
    runnable: anytype,
) !void {
    // always fall back, so another instance viewing a second repo just binds
    // its own port
    const web_listen_address = try parseListenAddress((Options{}).web_listen);
    var web_server = try listen(io, web_listen_address, .fallback);
    defer web_server.deinit(io);

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);

    runWebListener(io, allocator, &web_server, &tasks, .{ .local = local }, err);

    const web_url = try allocator.print("http://localhost:{d}", .{web_server.socket.address.getPort()});
    defer allocator.free(web_url);
    try runnable.run(web_url);
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
    exact,
    // leave it to whoever holds it and take an OS-assigned port instead
    fallback,
};

fn listen(io: std.Io, listen_address: ListenAddress, policy: PortPolicy) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4(listen_address.host, listen_address.port);
    return switch (policy) {
        // so a restart can bind past the old process's connections in TIME_WAIT.
        // not for fallback, where it would let a second instance share the port.
        .exact => try address.listen(io, .{ .reuse_address = true }),
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

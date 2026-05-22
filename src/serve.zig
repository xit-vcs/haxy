const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const serve_ssh_tui = @import("./serve_ssh_tui.zig");

pub const Options = struct {
    http_listen: []const u8 = "127.0.0.1:8080",
    ssh_listen: []const u8 = "127.0.0.1:8081",
    tui_listen: []const u8 = "127.0.0.1:8082",
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

    // the admin repo path is where the user/repo metadata events live;
    // web.zig opens it per request to render the server-side TUI

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

    // create tui listener

    const tui_listen_address = try parseListenAddress(options.tui_listen);
    const tui_address = try std.Io.net.IpAddress.parseIp4(tui_listen_address.host, tui_listen_address.port);
    var tui_server = try tui_address.listen(io, .{ .reuse_address = true });
    defer tui_server.deinit(io);

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

    runHttpListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, &http_server, &tasks, err);

    try err.print("serving SSH helper connections on {s}, repo root {s}\n", .{ options.ssh_listen, repo_root_path });
    try err.flush();

    runSshListener(repo_kind, any_repo_opts, io, allocator, repo_root_path, &ssh_server, &tasks, err);

    try err.print("serving TUI sessions on {s}\n", .{options.tui_listen});
    try err.flush();

    runTuiListener(io, allocator, admin_repo_path, &tui_server, &tasks, err);

    try err.print("serving web UI on http://{s}/\n", .{options.wui_listen});
    try err.flush();

    web.run(io, allocator, &wui_server, &tasks, admin_repo_path, err);

    if (@TypeOf(runnable) != void) {
        try runnable.run();
    } else {
        try tasks.await(io);
    }
}

fn runHttpListener(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        repo_root_path: []const u8,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,

        fn run(ctx: @This()) void {
            while (true) {
                const stream = ctx.net_server.accept(ctx.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(ctx.err, "accept failed: {s}\n", .{@errorName(accept_err)});
                    continue;
                };

                const Connection = struct {
                    io: std.Io,
                    allocator: std.mem.Allocator,
                    repo_root_path: []const u8,
                    stream: std.Io.net.Stream,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        handleHttpConnection(repo_kind, any_repo_opts, conn.io, conn.allocator, conn.repo_root_path, conn.stream, conn.err) catch |request_err| {
                            logError(conn.err, "connection failed: {s}\n", .{@errorName(request_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .allocator = ctx.allocator,
                    .repo_root_path = ctx.repo_root_path,
                    .stream = stream,
                    .err = ctx.err,
                }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .allocator = allocator,
        .repo_root_path = repo_root_path,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
    }});
}

fn handleHttpConnection(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    stream: std.Io.net.Stream,
    err: *std.Io.Writer,
) !void {
    var send_buffer = [_]u8{0} ** any_repo_opts.net_buffer_size;
    var recv_buffer = [_]u8{0} ** any_repo_opts.net_buffer_size;
    var conn_br = stream.reader(io, &recv_buffer);
    var conn_bw = stream.writer(io, &send_buffer);
    var http_server = std.http.Server.init(&conn_br.interface, &conn_bw.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |receive_err| switch (receive_err) {
            error.HttpConnectionClosing => break,
            error.ReadFailed => break,
            else => |e| return e,
        };

        handleHttpGitRequest(repo_kind, any_repo_opts, io, allocator, repo_root_path, &http_server, &request) catch |request_err| {
            try err.print("request failed: {s}\n", .{@errorName(request_err)});
            try err.flush();
            if (http_server.reader.state == .received_head) {
                http_server.reader.state = .ready;
            }
            try writeSimpleResponse(&http_server, 500, "Internal Server Error", "text/plain", @errorName(request_err));
        };
        try http_server.out.flush();
        break;
    }
}

fn handleHttpGitRequest(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    http_server: *std.http.Server,
    request: *std.http.Server.Request,
) !void {
    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;
    if (path.len == 0 or path[0] != '/') {
        try writeSimpleResponse(http_server, 400, "Bad Request", "text/plain", "bad path");
        return;
    }

    const handler, const suffix = findRoute(path) orelse {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 404, "Not Found", "text/plain", "not found");
        return;
    };

    const repo_rel_encoded = path[1 .. path.len - suffix.len];
    const repo_rel = try decodeAndValidateRepoPath(allocator, repo_rel_encoded);
    defer allocator.free(repo_rel);

    const repo_path = try std.fs.path.resolve(allocator, &.{ repo_root_path, repo_rel });
    defer allocator.free(repo_path);

    if (!isSubPath(repo_root_path, repo_path)) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 403, "Forbidden", "text/plain", "forbidden");
        return;
    }

    const request_method = normalizeMethod(request.head.method);
    const content_type = try allocator.dupe(u8, findHeader(request, "content-type") orelse "");
    defer allocator.free(content_type);
    const has_remote_user = findHeader(request, "authorization") != null;
    const protocol_version = protocolVersionFromHeader(findHeader(request, "git-protocol"));

    const body = if (request.head.method == .POST) blk: {
        const reader = try request.readerExpectContinue(&.{});
        break :blk try reader.allocRemaining(allocator, .unlimited);
    } else try allocator.dupe(u8, "");
    defer allocator.free(body);

    if (http_server.reader.state == .received_head) {
        http_server.reader.state = .ready;
    }

    var body_reader = std.Io.Reader.fixed(body);
    const create_if_missing = isReceivePack(handler, suffix, uri.query);
    const http_backend_options = xit.net_server_http_backend.Options{
        .request_method = request_method,
        .handler = handler,
        .suffix = suffix,
        .query_string = if (uri.query) |q| q.percent_encoded else "",
        .content_type = content_type,
        .has_remote_user = has_remote_user,
        .protocol_version = protocol_version,
    };

    try openRepoAndServe(repo_kind, any_repo_opts, io, allocator, repo_path, create_if_missing, HttpGitService{
        .body_reader = &body_reader,
        .writer = http_server.out,
        .options = http_backend_options,
    });
}

fn findRoute(path: []const u8) ?struct { xit.net_server_http_backend.HandlerKind, []const u8 } {
    for (&xit.net_server_http_backend.routes) |*route| {
        if (std.mem.endsWith(u8, path, route.suffix)) {
            return .{ route.handler, route.suffix };
        }
    }
    return null;
}

const SshService = enum {
    upload_pack,
    receive_pack,
};

const SshRequest = struct {
    service: SshService,
    protocol_version: xit.net_server_common.ProtocolVersion,
    repo: []const u8,

    fn deinit(self: SshRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
    }
};

fn runSshListener(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        repo_root_path: []const u8,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,

        fn run(ctx: @This()) void {
            while (true) {
                const stream = ctx.net_server.accept(ctx.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(ctx.err, "ssh accept failed: {s}\n", .{@errorName(accept_err)});
                    continue;
                };

                const Connection = struct {
                    io: std.Io,
                    allocator: std.mem.Allocator,
                    repo_root_path: []const u8,
                    stream: std.Io.net.Stream,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        handleSshGitConnection(repo_kind, any_repo_opts, conn.io, conn.allocator, conn.repo_root_path, conn.stream) catch |request_err| {
                            logError(conn.err, "ssh request failed: {s}\n", .{@errorName(request_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .allocator = ctx.allocator,
                    .repo_root_path = ctx.repo_root_path,
                    .stream = stream,
                    .err = ctx.err,
                }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .allocator = allocator,
        .repo_root_path = repo_root_path,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
    }});
}

fn runTuiListener(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        admin_repo_path: []const u8,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,

        fn run(ctx: @This()) void {
            while (true) {
                const stream = ctx.net_server.accept(ctx.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(ctx.err, "tui accept failed: {s}\n", .{@errorName(accept_err)});
                    continue;
                };

                const Connection = struct {
                    io: std.Io,
                    allocator: std.mem.Allocator,
                    admin_repo_path: []const u8,
                    stream: std.Io.net.Stream,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        serve_ssh_tui.handleConnection(conn.io, conn.allocator, conn.stream, conn.admin_repo_path) catch |session_err| {
                            logError(conn.err, "tui session failed: {s}\n", .{@errorName(session_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .allocator = ctx.allocator,
                    .admin_repo_path = ctx.admin_repo_path,
                    .stream = stream,
                    .err = ctx.err,
                }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .allocator = allocator,
        .admin_repo_path = admin_repo_path,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
    }});
}

fn handleSshGitConnection(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    stream: std.Io.net.Stream,
) !void {
    var send_buffer = [_]u8{0} ** any_repo_opts.net_buffer_size;
    var recv_buffer = [_]u8{0} ** any_repo_opts.net_buffer_size;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);

    const request = try readSshRequest(allocator, &reader.interface);
    defer request.deinit(allocator);

    const repo_path = try resolveSshRepoPath(allocator, repo_root_path, request.repo);
    defer allocator.free(repo_path);

    if (!isSubPath(repo_root_path, repo_path)) return error.Forbidden;

    try openRepoAndServe(repo_kind, any_repo_opts, io, allocator, repo_path, request.service == .receive_pack, SshGitService{
        .reader = &reader.interface,
        .writer = &writer.interface,
        .request = request,
    });
}

fn openRepoAndServe(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    create_if_missing: bool,
    service: anytype,
) !void {
    if (any_repo_opts.hash) |hash_kind| {
        var repo = try openRepo(repo_kind, any_repo_opts.toRepoOptsWithHash(hash_kind), io, allocator, repo_path, create_if_missing);
        defer repo.deinit(io, allocator);
        try service.serve(repo_kind, any_repo_opts.toRepoOptsWithHash(hash_kind), &repo, io, allocator);
    } else {
        var any_repo = rp.AnyRepo(repo_kind, any_repo_opts).open(io, allocator, .{ .path = repo_path }) catch |open_err| switch (open_err) {
            error.RepoNotFound => {
                if (!create_if_missing) return open_err;

                var repo = try openRepo(repo_kind, any_repo_opts.toRepoOpts(), io, allocator, repo_path, true);
                defer repo.deinit(io, allocator);
                try service.serve(repo_kind, any_repo_opts.toRepoOpts(), &repo, io, allocator);
                return;
            },
            else => |e| return e,
        };
        defer any_repo.deinit(io, allocator);

        switch (any_repo) {
            inline else => |*repo| {
                try service.serve(repo.self_repo_kind, repo.self_repo_opts, repo, io, allocator);
            },
        }
    }
}

fn openRepo(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    create_if_missing: bool,
) !rp.Repo(repo_kind, repo_opts) {
    return rp.Repo(repo_kind, repo_opts).open(io, allocator, .{ .path = repo_path }) catch |open_err| switch (open_err) {
        error.RepoNotFound => {
            if (!create_if_missing) return open_err;

            var repo = try rp.Repo(repo_kind, repo_opts).init(io, allocator, .{ .path = repo_path });
            errdefer repo.deinit(io, allocator);
            try repo.addConfig(io, allocator, .{ .name = "http.receivepack", .value = "true" });
            try repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
            return repo;
        },
        else => |e| return e,
    };
}

const HttpGitService = struct {
    body_reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: xit.net_server_http_backend.Options,

    fn serve(
        self: @This(),
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        try repo.httpBackend(io, allocator, self.body_reader, self.writer, .http, self.options);
    }
};

const SshGitService = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    request: SshRequest,

    fn serve(
        self: @This(),
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        switch (self.request.service) {
            .upload_pack => try repo.uploadPack(io, allocator, self.reader, self.writer, .{
                .protocol_version = self.request.protocol_version,
            }),
            .receive_pack => try repo.receivePack(io, allocator, self.reader, self.writer, .{
                .protocol_version = self.request.protocol_version,
            }),
        }
    }
};

fn isReceivePack(
    handler: xit.net_server_http_backend.HandlerKind,
    suffix: []const u8,
    query: ?std.Uri.Component,
) bool {
    return switch (handler) {
        .run_service => std.mem.eql(u8, suffix, "/git-receive-pack"),
        .get_info_refs => if (query) |q|
            std.mem.startsWith(u8, q.percent_encoded, "service=git-receive-pack")
        else
            false,
    };
}

fn readSshRequest(allocator: std.mem.Allocator, reader: *std.Io.Reader) !SshRequest {
    const magic = try readSshPreludeLine(reader);
    if (!std.mem.eql(u8, magic, "haxy-ssh-git-v1")) return error.InvalidSshMagic;

    const service_line = try readSshPreludeLine(reader);
    const service = parseSshService(stripPrefix(service_line, "service=") orelse return error.InvalidSshServiceLine) orelse return error.InvalidSshService;

    const protocol_line = try readSshPreludeLine(reader);
    const protocol_version = std.meta.stringToEnum(
        xit.net_server_common.ProtocolVersion,
        stripPrefix(protocol_line, "protocol=") orelse return error.InvalidSshProtocolLine,
    ) orelse return error.InvalidSshProtocol;

    const repo_length_line = try readSshPreludeLine(reader);
    const repo_len = try std.fmt.parseInt(usize, stripPrefix(repo_length_line, "repo-length=") orelse return error.InvalidSshRepoLengthLine, 10);

    const empty_line = try readSshPreludeLine(reader);
    if (empty_line.len != 0) return error.InvalidSshPreludeTerminator;

    const repo = try reader.readAlloc(allocator, repo_len);
    errdefer allocator.free(repo);

    return .{
        .service = service,
        .protocol_version = protocol_version,
        .repo = repo,
    };
}

fn readSshPreludeLine(reader: *std.Io.Reader) ![]const u8 {
    return (try reader.takeDelimiter('\n')) orelse error.InvalidSshHelperRequest;
}

fn parseSshService(value: []const u8) ?SshService {
    if (std.mem.eql(u8, value, "upload-pack")) return .upload_pack;
    if (std.mem.eql(u8, value, "receive-pack")) return .receive_pack;
    return null;
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn resolveSshRepoPath(
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    repo: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(repo)) {
        return try std.fs.path.resolve(allocator, &.{repo});
    }
    return try std.fs.path.resolve(allocator, &.{ repo_root_path, repo });
}

fn parseListenAddress(value: []const u8) !ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidListenAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

fn decodeAndValidateRepoPath(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    if (encoded.len == 0) return error.InvalidRepoPath;

    const mutable = try allocator.dupe(u8, encoded);
    errdefer allocator.free(mutable);
    const decoded = std.Uri.percentDecodeInPlace(mutable);

    var iter = std.mem.splitScalar(u8, decoded, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidRepoPath;
        }
    }

    return try allocator.realloc(mutable, decoded.len);
}

fn isSubPath(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, std.fs.path.sep_str)) return std.fs.path.isAbsolute(child);
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or child[parent.len] == std.fs.path.sep;
}

fn normalizeMethod(method: std.http.Method) std.http.Method {
    return if (method == .HEAD) .GET else method;
}

fn protocolVersionFromHeader(header: ?[]const u8) xit.net_server_common.ProtocolVersion {
    const git_protocol = header orelse return .v0;
    var version: xit.net_server_common.ProtocolVersion = .v0;
    var iter = std.mem.splitScalar(u8, git_protocol, ':');
    while (iter.next()) |entry| {
        const value = std.mem.trimStart(u8, entry, " ");
        if (std.mem.startsWith(u8, value, "version=")) {
            const v = value["version=".len..];
            if (std.mem.eql(u8, v, "2")) {
                version = .v2;
            } else if (std.mem.eql(u8, v, "1") and version != .v2) {
                version = .v1;
            }
        }
    }
    return version;
}

fn findHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn writeSimpleResponse(
    http_server: *std.http.Server,
    code: u16,
    message: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    try http_server.out.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ code, message, content_type, body.len, body },
    );
}

fn logError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

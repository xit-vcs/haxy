const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const serve_common = @import("./serve_common.zig");

pub fn runListener(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo_path: []const u8,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Context = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        repo_root_path: []const u8,
        admin_repo_path: []const u8,
        err: *std.Io.Writer,
    };

    const handle = struct {
        fn h(ctx: Context, stream: std.Io.net.Stream) void {
            defer stream.close(ctx.io);
            handleConnection(repo_kind, any_repo_opts, ctx.io, ctx.allocator, ctx.repo_root_path, ctx.admin_repo_path, stream, ctx.err) catch |request_err| {
                serve_common.logError(ctx.err, "connection failed: {s}\n", .{@errorName(request_err)});
            };
        }
    }.h;

    serve_common.runListener(io, net_server, tasks, err, "http", Context{
        .io = io,
        .allocator = allocator,
        .repo_root_path = repo_root_path,
        .admin_repo_path = admin_repo_path,
        .err = err,
    }, handle);
}

fn handleConnection(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo_path: []const u8,
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

        handleGitRequest(repo_kind, any_repo_opts, io, allocator, repo_root_path, admin_repo_path, &http_server, &request) catch |request_err| {
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

fn handleGitRequest(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo_path: []const u8,
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

    const request_method = normalizeMethod(request.head.method);
    const content_type = try allocator.dupe(u8, findHeader(request, "content-type") orelse "");
    defer allocator.free(content_type);
    const has_remote_user = findHeader(request, "authorization") != null;
    const protocol_version = protocolVersionFromHeader(findHeader(request, "git-protocol"));

    // pushing over HTTP is not supported; pushes go over SSH
    if (isReceivePack(handler, suffix, uri.query)) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 403, "Forbidden", "text/plain", "push over HTTP is not supported");
        return;
    }

    const body = if (request.head.method == .POST) blk: {
        const reader = try request.readerExpectContinue(&.{});
        break :blk try reader.allocRemaining(allocator, .unlimited);
    } else try allocator.dupe(u8, "");
    defer allocator.free(body);

    if (http_server.reader.state == .received_head) {
        http_server.reader.state = .ready;
    }

    const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, repo_root_path, admin_repo_path, repo_rel, false)) {
        .ok => |p| p,
        .invalid => return writeSimpleResponse(http_server, 400, "Bad Request", "text/plain", "repo path must be <owner>/<repo>"),
        .not_found => return error.RepoNotFound,
    };
    defer allocator.free(repo_path);

    var body_reader = std.Io.Reader.fixed(body);
    const http_backend_options = xit.net_server_http_backend.Options{
        .request_method = request_method,
        .handler = handler,
        .suffix = suffix,
        .query_string = if (uri.query) |q| q.percent_encoded else "",
        .content_type = content_type,
        .has_remote_user = has_remote_user,
        .protocol_version = protocol_version,
    };

    try openRepoAndServe(repo_kind, any_repo_opts, io, allocator, repo_path, GitService{
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

fn openRepoAndServe(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    service: anytype,
) !void {
    // serve the existing on-disk repo at its event-id directory; HTTP only
    // handles fetch/clone, so a missing repo is simply not found
    if (try serveIfExists(repo_kind, any_repo_opts, io, allocator, repo_path, service)) return;
    return error.RepoNotFound;
}

// serve an existing repo at `repo_path`, or return false if none is there
fn serveIfExists(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    service: anytype,
) !bool {
    // a bare open() creates the directory while probing for the repo, so only
    // attempt it when the path already exists
    std.Io.Dir.accessAbsolute(io, repo_path, .{}) catch return false;

    if (any_repo_opts.hash) |hash_kind| {
        var repo = rp.Repo(repo_kind, any_repo_opts.toRepoOptsWithHash(hash_kind)).open(io, allocator, .{ .path = repo_path }) catch |open_err| switch (open_err) {
            error.RepoNotFound => return false,
            else => |e| return e,
        };
        defer repo.deinit(io, allocator);
        try service.serve(repo_kind, any_repo_opts.toRepoOptsWithHash(hash_kind), &repo, io, allocator);
    } else {
        var any_repo = rp.AnyRepo(repo_kind, any_repo_opts).open(io, allocator, .{ .path = repo_path }) catch |open_err| switch (open_err) {
            error.RepoNotFound => return false,
            else => |e| return e,
        };
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| try service.serve(repo.self_repo_kind, repo.self_repo_opts, repo, io, allocator),
        }
    }
    return true;
}

const GitService = struct {
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

fn decodeAndValidateRepoPath(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    if (encoded.len == 0) return error.InvalidRepoPath;

    const mutable = try allocator.dupe(u8, encoded);
    errdefer allocator.free(mutable);
    const decoded = std.Uri.percentDecodeInPlace(mutable);

    var iter = std.fs.path.componentIterator(decoded);
    while (iter.next()) |component| {
        if (component.name.len == 0 or std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidRepoPath;
        }
    }

    return try allocator.realloc(mutable, decoded.len);
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

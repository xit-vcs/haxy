const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("./event.zig");
const serve_common = @import("./serve_common.zig");

// whether a web listener request is git's smart http rather than a page
pub fn isGitRequest(head: *const std.http.Server.Request.Head) bool {
    const uri = std.Uri.parseAfterScheme("", head.target) catch return false;
    const handler, _ = findRoute(uri.path.percent_encoded) orelse return false;
    return switch (handler) {
        // a page url can end in "/info/refs" too, but never has a query
        .get_info_refs => if (uri.query) |q| std.mem.startsWith(u8, q.percent_encoded, "service=") else false,
        .run_service => head.method == .POST,
    };
}

pub const GitHandler = *const fn (
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    admin_repo_path: []const u8,
    http_server: *std.http.Server,
    request: *std.http.Server.Request,
    err: *std.Io.Writer,
) anyerror!void;

// the git request handler for one repo backend, so the web listener needn't be generic
pub fn gitHandler(comptime repo_kind: rp.RepoKind, comptime any_repo_opts: rp.AnyRepoOpts(repo_kind)) GitHandler {
    return struct {
        fn handle(
            io: std.Io,
            allocator: std.mem.Allocator,
            users_dir: []const u8,
            admin_repo_path: []const u8,
            http_server: *std.http.Server,
            request: *std.http.Server.Request,
            err: *std.Io.Writer,
        ) anyerror!void {
            handleGitRequest(repo_kind, any_repo_opts, io, allocator, users_dir, admin_repo_path, http_server, request) catch |request_err| {
                serve_common.logError(io, err, "request failed: {s}\n", .{@errorName(request_err)});
                try writeSimpleResponse(http_server, 500, "Internal Server Error", "text/plain", @errorName(request_err));
            };
            try http_server.out.flush();
        }
    }.handle;
}

fn handleGitRequest(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
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
    const protocol_version = xit.net_server_common.parseProtocolVersion(findHeader(request, "git-protocol"));

    // pushing over HTTP is not supported; pushes go over SSH
    if (isReceivePack(handler, suffix, uri.query)) {
        try writeSimpleResponse(http_server, 403, "Forbidden", "text/plain", "push over HTTP is not supported");
        return;
    }

    const owner_repo = evt.parseOwnerRepoPath(repo_rel) orelse {
        try writeSimpleResponse(http_server, 400, "Bad Request", "text/plain", "repo path must be <owner>:<repo>");
        return;
    };
    const repo_path = blk: {
        var admin = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
            error.RepoNotFound => return error.RepoNotFound,
            else => |e| return e,
        };
        defer admin.deinit(io, allocator);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
        const repo = (try evt.readRepoByOwnerAndName(io, allocator, &arena, moment, users_dir, owner_repo.owner, owner_repo.name, null)) orelse {
            try writeSimpleResponse(http_server, 404, "Not Found", "text/plain", "repo not found");
            return;
        };
        if (repo.repo.event.read_access == .private) {
            try writeSimpleResponse(http_server, 403, "Forbidden", "text/plain", "private repos cannot be fetched over HTTP");
            return;
        }
        break :blk try evt.repoPath(allocator, users_dir, &try evt.parseEventId(&repo.repo.event.user_id), &repo.event_id);
    };
    defer allocator.free(repo_path);

    const body = if (request.head.method == .POST) blk: {
        const reader = try request.readerExpectContinue(&.{});
        break :blk try reader.allocRemaining(allocator, .unlimited);
    } else try allocator.dupe(u8, "");
    defer allocator.free(body);

    if (http_server.reader.state == .received_head) {
        http_server.reader.state = .ready;
    }

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

    // serve the existing on-disk repo at its event-id directory; HTTP only
    // handles fetch/clone, so a missing repo is simply not found
    if (!try serveIfExists(repo_kind, any_repo_opts, io, allocator, repo_path, GitService{
        .body_reader = &body_reader,
        .writer = http_server.out,
        .options = http_backend_options,
    })) try writeSimpleResponse(http_server, 404, "Not Found", "text/plain", "repo not found");
}

fn findRoute(path: []const u8) ?struct { xit.net_server_http_backend.HandlerKind, []const u8 } {
    for (&xit.net_server_http_backend.routes) |*route| {
        if (std.mem.endsWith(u8, path, route.suffix)) {
            return .{ route.handler, route.suffix };
        }
    }
    return null;
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

    var iter = std.Io.Dir.path.componentIterator(decoded);
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

pub fn findHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
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
    if (http_server.reader.state == .received_head) http_server.reader.state = .ready;
    try http_server.out.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ code, message, content_type, body.len, body },
    );
}

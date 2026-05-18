const std = @import("std");

const Asset = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const assets = [_]Asset{
    .{ .path = "index.html", .content_type = "text/html; charset=utf-8", .body = @embedFile("assets/index.html") },
    .{ .path = "script.js", .content_type = "text/javascript; charset=utf-8", .body = @embedFile("assets/script.js") },
    .{ .path = "term.ttf", .content_type = "font/ttf", .body = @embedFile("assets/term.ttf") },
    .{ .path = "haxy.wasm", .content_type = "application/wasm", .body = @embedFile("assets/haxy.wasm") },
};

pub fn run(
    io: std.Io,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,

        fn run(ctx: @This()) void {
            while (true) {
                const stream = ctx.net_server.accept(ctx.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(ctx.err, "web ui accept failed: {s}\n", .{@errorName(accept_err)});
                    continue;
                };

                const Connection = struct {
                    io: std.Io,
                    stream: std.Io.net.Stream,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        handleConnection(conn.io, conn.stream, conn.err) catch |request_err| {
                            logError(conn.err, "web ui request failed: {s}\n", .{@errorName(request_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .stream = stream,
                    .err = ctx.err,
                }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
    }});
}

fn handleConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    err: *std.Io.Writer,
) !void {
    var send_buffer = [_]u8{0} ** 4096;
    var recv_buffer = [_]u8{0} ** 4096;
    var conn_br = stream.reader(io, &recv_buffer);
    var conn_bw = stream.writer(io, &send_buffer);
    var http_server = std.http.Server.init(&conn_br.interface, &conn_bw.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |receive_err| switch (receive_err) {
            error.HttpConnectionClosing => break,
            error.ReadFailed => break,
            else => |e| return e,
        };

        handleRequest(&http_server, &request) catch |request_err| {
            try err.print("web ui request failed: {s}\n", .{@errorName(request_err)});
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

fn handleRequest(
    http_server: *std.http.Server,
    request: *std.http.Server.Request,
) !void {
    const method = if (request.head.method == .HEAD) .GET else request.head.method;
    if (method != .GET) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 405, "Method Not Allowed", "text/plain", "method not allowed");
        return;
    }

    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;

    if (std.mem.eql(u8, path, "/favicon.ico")) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeStaticResponse(http_server, 204, "No Content", "image/x-icon", "", true);
        return;
    }

    const asset = findAsset(path) orelse {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 404, "Not Found", "text/plain", "not found");
        return;
    };

    if (http_server.reader.state == .received_head) {
        http_server.reader.state = .ready;
    }

    try writeStaticResponse(http_server, 200, "OK", asset.content_type, asset.body, request.head.method == .HEAD);
}

fn findAsset(request_path: []const u8) ?Asset {
    const path = if (std.mem.eql(u8, request_path, "/"))
        "index.html"
    else if (request_path.len > 1 and request_path[0] == '/')
        request_path[1..]
    else
        return null;

    for (assets) |asset| {
        if (std.mem.eql(u8, path, asset.path)) return asset;
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

fn writeStaticResponse(
    http_server: *std.http.Server,
    code: u16,
    message: []const u8,
    content_type: []const u8,
    body: []const u8,
    head_only: bool,
) !void {
    try http_server.out.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ code, message, content_type, body.len },
    );
    if (!head_only) {
        try http_server.out.writeAll(body);
    }
}

fn logError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

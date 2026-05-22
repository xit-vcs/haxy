const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const ui = @import("./ui.zig");
const xitui = xit.xitui;
const Focus = xitui.focus.Focus;

const Embed = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const embeds = [_]Embed{
    .{ .path = "index.html", .content_type = "text/html; charset=utf-8", .body = @embedFile("embed/index.html") },
    .{ .path = "script.js", .content_type = "text/javascript; charset=utf-8", .body = @embedFile("embed/script.js") },
    .{ .path = "term.ttf", .content_type = "font/ttf", .body = @embedFile("embed/term.ttf") },
    .{ .path = "haxy.wasm", .content_type = "application/wasm", .body = @embedFile("embed/haxy.wasm") },
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    admin_repo_path: []const u8,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        admin_repo_path: []const u8,
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
                    allocator: std.mem.Allocator,
                    stream: std.Io.net.Stream,
                    admin_repo_path: []const u8,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        handleConnection(conn.io, conn.allocator, conn.stream, conn.admin_repo_path, conn.err) catch |request_err| {
                            logError(conn.err, "web ui request failed: {s}\n", .{@errorName(request_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .allocator = ctx.allocator,
                    .stream = stream,
                    .admin_repo_path = ctx.admin_repo_path,
                    .err = ctx.err,
                }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .allocator = allocator,
        .net_server = net_server,
        .tasks = tasks,
        .admin_repo_path = admin_repo_path,
        .err = err,
    }});
}

fn renderIndexHtml(io: std.Io, allocator: std.mem.Allocator, admin_repo_path: []const u8) ![]const u8 {
    const template = (findEmbed("/index.html") orelse return error.MissingIndexAsset).body;

    // open the admin repo to read live user/repo data; if it doesn't exist
    // yet (e.g. a fresh `haxy serve` with no admin repo) fall back to empty.
    const repo_opts: rp.RepoOpts(.xit) = .{};
    const Repo = rp.Repo(.xit, repo_opts);
    var repo_or_err = Repo.open(io, allocator, .{ .path = admin_repo_path });
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const page: ui.Page = if (repo_or_err) |*repo| blk: {
        defer repo.deinit(io, allocator);
        break :blk .{ .users_and_repos = try .init(repo_opts, &page_arena, repo) };
    } else |_| .{ .users_and_repos = .empty() };

    var root = try ui.initRoot(allocator, &page);
    defer root.deinit();

    const content = try generateHtml(allocator, &root);
    defer allocator.free(content);

    // serialize the page so the wasm side can parse it back without making
    // a second request. base64-encoded so the json can be embedded in html.
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(page, .{}, &json.writer);

    const b64 = std.base64.standard.Encoder;
    const json_b64 = try allocator.alloc(u8, b64.calcSize(json.written().len));
    defer allocator.free(json_b64);
    _ = b64.encode(json_b64, json.written());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    {
        var cursor: usize = 0;
        for (&[_]struct { needle: []const u8, replacement: []const u8 }{
            .{ .needle = "{{{ HAXY_HTML }}}", .replacement = content },
            .{ .needle = "{{{ HAXY_JSON }}}", .replacement = json_b64 },
        }) |sub| {
            const idx = std.mem.indexOfPos(u8, template, cursor, sub.needle) orelse return error.MissingTemplateToken;
            try out.appendSlice(allocator, template[cursor..idx]);
            try out.appendSlice(allocator, sub.replacement);
            cursor = idx + sub.needle.len;
        }
        try out.appendSlice(allocator, template[cursor..]);
    }
    return try out.toOwnedSlice(allocator);
}

fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    admin_repo_path: []const u8,
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

        handleRequest(io, &http_server, &request, allocator, admin_repo_path) catch |request_err| {
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
    io: std.Io,
    http_server: *std.http.Server,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
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

    const embed = findEmbed(path) orelse {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 404, "Not Found", "text/plain", "not found");
        return;
    };

    if (http_server.reader.state == .received_head) {
        http_server.reader.state = .ready;
    }

    if (std.mem.eql(u8, embed.path, "index.html")) {
        const index_html = try renderIndexHtml(io, allocator, admin_repo_path);
        defer allocator.free(index_html);
        try writeStaticResponse(http_server, 200, "OK", embed.content_type, index_html, request.head.method == .HEAD);
    } else {
        try writeStaticResponse(http_server, 200, "OK", embed.content_type, embed.body, request.head.method == .HEAD);
    }
}

fn findEmbed(request_path: []const u8) ?Embed {
    const path = if (std.mem.eql(u8, request_path, "/"))
        "index.html"
    else if (request_path.len > 1 and request_path[0] == '/')
        request_path[1..]
    else
        return null;

    for (embeds) |embed| {
        if (std.mem.eql(u8, path, embed.path)) return embed;
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

pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..grid.size.height) |y| {
        // wrap runs of cells belonging to a focusable widget in a span tagged
        // with that widget's focus id. CSS paints them with a pointer cursor;
        // JS reads the id on click and dispatches focus directly.
        var current_id: ?usize = null;
        for (0..grid.size.width) |x| {
            const cell_id = cellFocusId(root_focus, x, y);
            if (cell_id != current_id) {
                if (current_id != null) try out.appendSlice(allocator, "</span>");
                if (cell_id) |id| {
                    var buf: [64]u8 = undefined;
                    const tag = try std.fmt.bufPrint(&buf, "<span class=\"clickable\" data-focus-id=\"{}\">", .{id});
                    try out.appendSlice(allocator, tag);
                }
                current_id = cell_id;
            }
            const rune = grid.cells.items[try grid.cells.at(.{ y, x })].rune orelse " ";
            try appendEscapedHtml(allocator, &out, rune);
        }
        if (current_id != null) try out.appendSlice(allocator, "</span>");
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn cellFocusId(focus: *Focus, x: usize, y: usize) ?usize {
    var iter = focus.children.iterator();
    while (iter.next()) |entry| {
        const child = entry.value_ptr.*;
        if (!child.focus.focusable) continue;
        const r = child.rect;
        if (x >= r.x and y >= r.y and x < r.x + r.size.width and y < r.y + r.size.height) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn appendEscapedHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
}

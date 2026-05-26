const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("./event.zig");
const ui = @import("./ui.zig");
const xitui = xit.xitui;
const wgt = xitui.widget;
const Focus = xitui.focus.Focus;

const cookie_name = "haxy_user";

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
    const method = request.head.method;
    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;

    if (method == .POST and std.mem.eql(u8, path, "/login")) {
        return handleLogin(io, http_server, request, allocator, admin_repo_path);
    }
    if (method == .POST and std.mem.eql(u8, path, "/logout")) {
        return handleLogout(http_server, request);
    }

    const get_or_head = method == .GET or method == .HEAD;
    if (!get_or_head) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeSimpleResponse(http_server, 405, "Method Not Allowed", "text/plain", "method not allowed");
        return;
    }

    if (std.mem.eql(u8, path, "/favicon.ico")) {
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        try writeStaticResponse(http_server, 204, "No Content", "image/x-icon", "", true);
        return;
    }

    // for the index page we need to consult the session cookie before
    // consuming the request, so we don't dispatch through findEmbed here.
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        const user_id_hex = getCookieValue(request, cookie_name);
        if (http_server.reader.state == .received_head) {
            http_server.reader.state = .ready;
        }
        const html = try renderIndexHtml(io, allocator, admin_repo_path, user_id_hex);
        defer allocator.free(html);
        try writeStaticResponse(http_server, 200, "OK", "text/html; charset=utf-8", html, method == .HEAD);
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
    try writeStaticResponse(http_server, 200, "OK", embed.content_type, embed.body, method == .HEAD);
}

fn handleLogin(
    io: std.Io,
    http_server: *std.http.Server,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
) !void {
    var body_buf: [256]u8 = undefined;
    const reader = request.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(allocator, .limited(65536)) catch &[_]u8{};
    defer allocator.free(body);

    const username = (try parseFormField(allocator, body, "username")) orelse try allocator.dupe(u8, "");
    defer allocator.free(username);
    const password = (try parseFormField(allocator, body, "password")) orelse try allocator.dupe(u8, "");
    defer allocator.free(password);

    const repo_opts: rp.RepoOpts(.xit) = .{};
    const Repo = rp.Repo(.xit, repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
    defer repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const haxy_moment = try openHaxyMoment(repo_opts, &repo);
    const result = try evt.User.verifyCredentials(Repo.DB, repo_opts.hash, haxy_moment, &arena, username, password);

    switch (result) {
        .success => |user_id| {
            const hex = std.fmt.bytesToHex(user_id, .lower);
            try http_server.out.print(
                "HTTP/1.1 303 See Other\r\nLocation: /\r\nSet-Cookie: " ++ cookie_name ++ "={s}; Path=/; HttpOnly; SameSite=Strict\r\nContent-Length: 0\r\n\r\n",
                .{hex},
            );
        },
        .unknown_user, .wrong_password => {
            try http_server.out.print(
                "HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\n\r\n",
                .{},
            );
        },
    }
}

fn handleLogout(http_server: *std.http.Server, request: *std.http.Server.Request) !void {
    // we don't need the body, but the http server wants the request consumed
    // before the next one (and before we write the response).
    var sink_buf: [64]u8 = undefined;
    _ = request.readerExpectNone(&sink_buf).discardRemaining() catch {};

    try http_server.out.print(
        "HTTP/1.1 303 See Other\r\nLocation: /\r\nSet-Cookie: " ++ cookie_name ++ "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0\r\nContent-Length: 0\r\n\r\n",
        .{},
    );
}

fn renderIndexHtml(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    user_id_hex_opt: ?[]const u8,
) ![]const u8 {
    const template = (findEmbed("/index.html") orelse return error.MissingIndexAsset).body;

    // open the admin repo to read live user/repo data.
    const repo_opts: rp.RepoOpts(.xit) = .{};
    const Repo = rp.Repo(.xit, repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
    defer repo.deinit(io, allocator);
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    var session: ui.Session = .{};
    if (user_id_hex_opt) |hex| {
        if (decodeHexAlloc(page_arena.allocator(), hex)) |bytes| {
            session.user_id = bytes;
        } else |_| {}
    }

    const page: ui.Page = .{ .home = try .init(repo_opts, &page_arena, &repo, &session) };
    var root = try ui.initRoot(allocator, &page, &session);
    defer root.deinit(allocator);

    const content = try generateHtml(allocator, &root, &session);
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

pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget, session: *const ui.Session) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // determines the form route for any submit_button on this page. only one
    // is visible at a time: login when logged out, logout when logged in.
    const submit_url: []const u8 = if (session.user_id != null) "/logout" else "/login";

    // collect the text inputs in deterministic top-to-bottom, left-to-right
    // order. root_focus.children is a hash map so iterating it directly would
    // give arbitrary tab order between username / password.
    const InputEntry = struct {
        focus_id: usize,
        x: usize,
        y: usize,
        width: usize,
        is_password: bool,
        ti: *wgt.TextInput(ui.Widget),
    };
    var inputs: std.ArrayList(InputEntry) = .empty;
    defer inputs.deinit(allocator);
    var focus_iter = root_focus.children.iterator();
    while (focus_iter.next()) |entry| {
        const child = entry.value_ptr.*;
        const is_password = switch (child.focus.kind) {
            .text_input => false,
            .text_input_password => true,
            else => continue,
        };
        try inputs.append(allocator, .{
            .focus_id = entry.key_ptr.*,
            .x = child.rect.x,
            .y = child.rect.y,
            .width = child.rect.size.width,
            .is_password = is_password,
            .ti = @fieldParentPtr("focus", child.focus),
        });
    }
    std.mem.sort(InputEntry, inputs.items, {}, struct {
        fn lt(_: void, a: InputEntry, b: InputEntry) bool {
            if (a.y != b.y) return a.y < b.y;
            return a.x < b.x;
        }
    }.lt);

    // emit the overlay inputs FIRST so they precede any submit-button span
    // in DOM order; with the submit button carrying tabindex="0", that puts
    // it at the end of the natural tab order — username -> password -> button.
    for (inputs.items) |entry| {
        const inner_left = entry.x + 1;
        const inner_top = entry.y + 1;
        const inner_width = if (entry.width > 2) entry.width - 2 else 0;

        try out.appendSlice(allocator, "<input type=\"");
        try out.appendSlice(allocator, if (entry.is_password) "password" else "text");
        try out.appendSlice(allocator, "\" data-focus-id=\"");
        var id_buf: [32]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{entry.focus_id}));
        if (entry.ti.options.name.len > 0) {
            try out.appendSlice(allocator, "\" name=\"");
            try appendEscapedHtml(allocator, &out, entry.ti.options.name);
        }
        try out.appendSlice(allocator, "\" value=\"");
        var value_buf: std.ArrayList(u8) = .empty;
        defer value_buf.deinit(allocator);
        for (entry.ti.content.items) |cp| {
            try value_buf.appendSlice(allocator, cp);
        }
        try appendEscapedHtml(allocator, &out, value_buf.items);
        try out.appendSlice(allocator, "\" style=\"left:");
        var pos_buf: [64]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:1em", .{ inner_left, inner_top, inner_width }));
        try out.appendSlice(allocator, "\">");
    }

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
                    const kind = if (root_focus.children.get(id)) |entry| entry.focus.kind else .container;
                    var buf: [256]u8 = undefined;
                    // tabindex="0" on submit buttons puts them in the browser's
                    // natural Tab order alongside the inputs above.
                    const tag = if (kind == .submit_button)
                        try std.fmt.bufPrint(&buf, "<span class=\"clickable\" data-focus-id=\"{d}\" data-action=\"submit\" data-url=\"{s}\" tabindex=\"0\">", .{ id, submit_url })
                    else
                        try std.fmt.bufPrint(&buf, "<span class=\"clickable\" data-focus-id=\"{d}\">", .{id});
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

// --- helpers --------------------------------------------------------------

fn openHaxyMoment(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
) !rp.Repo(.xit, repo_opts).DB.HashMap(.read_only) {
    const DB = rp.Repo(.xit, repo_opts).DB;
    const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());
    const moment_cursor = try history.getCursor(-1) orelse return error.NotFound;
    const moment = try DB.HashMap(.read_only).init(moment_cursor);
    const last_object_id_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy-last-object-id")) orelse return error.NotFound;
    var last_object_id: [hash.byteLen(repo_opts.hash)]u8 = undefined;
    _ = try last_object_id_cursor.readBytes(&last_object_id);
    const haxy_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, "haxy")) orelse return error.NotFound;
    const haxy = try DB.ArrayList(.read_only).init(haxy_cursor);
    const haxy_moments_cursor = try haxy.getCursor(-1) orelse return error.NotFound;
    const haxy_moments = try DB.HashMap(.read_only).init(haxy_moments_cursor);
    const haxy_moment_cursor = try haxy_moments.getCursor(hash.bytesToInt(repo_opts.hash, &last_object_id)) orelse return error.NotFound;
    return try DB.HashMap(.read_only).init(haxy_moment_cursor);
}

fn getCookieValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, header.value, ';');
        while (pairs.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            if (std.mem.eql(u8, trimmed[0..eq], name)) {
                return trimmed[eq + 1 ..];
            }
        }
    }
    return null;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = std.fmt.hexToBytes(bytes, hex) catch return error.InvalidHex;
    return bytes;
}

fn parseFormField(allocator: std.mem.Allocator, body: []const u8, key: []const u8) !?[]u8 {
    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            return try decodeFormValue(allocator, pair[eq + 1 ..]);
        }
    }
    return null;
}

fn decodeFormValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        switch (encoded[i]) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (i + 2 >= encoded.len) return error.InvalidPercentEncoding;
                const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidPercentEncoding;
                const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidPercentEncoding;
                try out.append(allocator, hi * 16 + lo);
                i += 2;
            },
            else => try out.append(allocator, encoded[i]),
        }
    }
    return try out.toOwnedSlice(allocator);
}

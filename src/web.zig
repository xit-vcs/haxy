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
// flash cookie for surfacing the outcome of the most recent /login POST.
// set on the failure redirect, read and immediately expired on the next
// GET / so refreshing the page doesn't keep showing the error.
const login_failure_cookie = "haxy_login_failure";

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

    // serve multiple requests on a single connection so HTTP/1.1 keep-alive
    // works — important for browser-native form POST: after the 303 the
    // browser issues GET / on the same socket, and forcibly closing here
    // would race the follow-up request into a "site can't be reached".
    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |receive_err| switch (receive_err) {
            error.HttpConnectionClosing => break,
            error.ReadFailed => break,
            else => |e| return e,
        };

        handleRequest(io, &request, allocator, admin_repo_path) catch |request_err| {
            try err.print("web ui request failed: {s}\n", .{@errorName(request_err)});
            try err.flush();
            // best-effort 500. if handleRequest already started writing a
            // response before throwing, this respond may fail too, but at
            // that point the connection is unrecoverable anyway.
            request.respond(@errorName(request_err), .{
                .status = .internal_server_error,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            }) catch {};
        };
    }
}

fn handleRequest(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
) !void {
    const method = request.head.method;
    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;

    if (method == .POST and std.mem.eql(u8, path, "/login")) {
        return handleLogin(io, request, allocator, admin_repo_path);
    }
    if (method == .POST and std.mem.eql(u8, path, "/logout")) {
        return handleLogout(request);
    }

    const get_or_head = method == .GET or method == .HEAD;
    if (!get_or_head) {
        try request.respond("method not allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }

    if (std.mem.eql(u8, path, "/favicon.ico")) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{.{ .name = "content-type", .value = "image/x-icon" }},
        });
        return;
    }

    if (ui.RoutablePage.fromUrl(path)) |current_page| {
        // decode the haxy_user cookie into raw bytes on the stack; the
        // slice lives for the rest of handleRequest, which is plenty for
        // renderIndexHtml to consume.
        var user_id_buf: [evt.event_id_size]u8 = undefined;
        const user_id: ?[]const u8 = blk: {
            const hex = getCookieValue(request, cookie_name) orelse break :blk null;
            if (hex.len != evt.event_id_size * 2) break :blk null;
            _ = std.fmt.hexToBytes(&user_id_buf, hex) catch break :blk null;
            break :blk user_id_buf[0..evt.event_id_size];
        };
        const login_failure: ?ui.Home.Auth.Login.Failure =
            if (getCookieValue(request, login_failure_cookie)) |raw|
                if (std.mem.eql(u8, raw, "unknown_user"))
                    .unknown_user
                else if (std.mem.eql(u8, raw, "wrong_password"))
                    .wrong_password
                else
                    null
            else
                null;
        const html = try renderIndexHtml(io, allocator, admin_repo_path, .{
            .user_id = user_id,
            .login_failure = login_failure,
            .current_page = current_page,
        });
        defer allocator.free(html);
        // expire the flash cookie on the way out so a refresh doesn't keep
        // showing the failure label.
        var headers: [2]std.http.Header = undefined;
        headers[0] = .{ .name = "content-type", .value = "text/html; charset=utf-8" };
        var headers_slice: []const std.http.Header = headers[0..1];
        if (login_failure != null) {
            headers[1] = .{ .name = "set-cookie", .value = login_failure_cookie ++ "=; Path=/; Max-Age=0" };
            headers_slice = headers[0..2];
        }
        try request.respond(html, .{ .extra_headers = headers_slice });
        return;
    }

    const embed = findEmbed(path) orelse {
        try request.respond("not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    try request.respond(embed.body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = embed.content_type }},
    });
}

fn handleLogin(
    io: std.Io,
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
            var cookie_buf: [256]u8 = undefined;
            const cookie = try std.fmt.bufPrint(&cookie_buf, cookie_name ++ "={s}; Path=/; HttpOnly; SameSite=Strict", .{hex});
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = ui.RoutablePage.url(.default) },
                    .{ .name = "set-cookie", .value = cookie },
                },
            });
        },
        .unknown_user => {
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = ui.RoutablePage.url(.home_auth) },
                    .{ .name = "set-cookie", .value = login_failure_cookie ++ "=unknown_user; Path=/; HttpOnly; SameSite=Strict" },
                },
            });
        },
        .wrong_password => {
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = ui.RoutablePage.url(.home_auth) },
                    .{ .name = "set-cookie", .value = login_failure_cookie ++ "=wrong_password; Path=/; HttpOnly; SameSite=Strict" },
                },
            });
        },
    }
}

fn handleLogout(request: *std.http.Server.Request) !void {
    // request.respond's discardBody reads any unused body for us and lands
    // the connection back in the .ready state for the next request on the
    // same connection (keep_alive defaults to true).
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = ui.RoutablePage.url(.home_auth) },
            .{ .name = "set-cookie", .value = cookie_name ++ "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
        },
    });
}

fn renderIndexHtml(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    session_data: ui.Session.Data,
) ![]const u8 {
    const template = (findEmbed("/index.html") orelse return error.MissingIndexAsset).body;

    // open the admin repo to read live user/repo data.
    const repo_opts: rp.RepoOpts(.xit) = .{};
    const Repo = rp.Repo(.xit, repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
    defer repo.deinit(io, allocator);
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    var session = try ui.Session.init(repo_opts, &page_arena, &repo, session_data);

    const snapshot: ui.Snapshot = .{
        .page = .{ .home = try .init(repo_opts, session.arena, session.haxy_moment orelse unreachable) },
        .session = session.data,
    };
    var root = try ui.initRoot(allocator, &snapshot.page, &session);
    defer root.deinit(allocator);

    const content = try generateHtml(allocator, &root, &session);
    defer allocator.free(content);
    const overlay = try generateOverlay(allocator, &root, &session);
    defer allocator.free(overlay);

    // serialize the snapshot so the wasm side can parse it back without
    // making a second request. base64-encoded so the json can be embedded
    // safely inside the host html.
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(snapshot, .{}, &json.writer);

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
            .{ .needle = "{{{ HAXY_OVERLAY }}}", .replacement = overlay },
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

fn logError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

// emits the TUI grid cells (one <span> run per focusable widget)
pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget, session: *const ui.Session) ![]const u8 {
    _ = session;
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..grid.size.height) |y| {
        var current_id: ?usize = null;
        for (0..grid.size.width) |x| {
            const cell_id = cellFocusId(root_focus, x, y);
            if (cell_id != current_id) {
                if (current_id != null) try out.appendSlice(allocator, "</span>");
                if (cell_id) |id| {
                    var buf: [128]u8 = undefined;
                    const tag = try std.fmt.bufPrint(&buf, "<span class=\"clickable\" data-focus-id=\"{d}\">", .{id});
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

// emits the form overlay — a <form> wrapping the text inputs and submit
// button, positioned absolutely over the matching grid cells
pub fn generateOverlay(allocator: std.mem.Allocator, root: *ui.Widget, session: *const ui.Session) ![]const u8 {
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const InputEntry = struct {
        focus_id: usize,
        x: usize,
        y: usize,
        width: usize,
        is_password: bool,
        ti: *wgt.TextInput(ui.Widget),
    };
    const SubmitButton = struct {
        focus_id: usize,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
    };
    var inputs: std.ArrayList(InputEntry) = .empty;
    defer inputs.deinit(allocator);
    var submit: ?SubmitButton = null;

    var iter = root_focus.children.iterator();
    while (iter.next()) |entry| {
        const child = entry.value_ptr.*;
        switch (child.focus.kind) {
            .text_input, .text_input_password => {
                try inputs.append(allocator, .{
                    .focus_id = entry.key_ptr.*,
                    .x = child.rect.x,
                    .y = child.rect.y,
                    .width = child.rect.size.width,
                    .is_password = child.focus.kind == .text_input_password,
                    .ti = @fieldParentPtr("focus", child.focus),
                });
            },
            .submit_button => {
                submit = .{
                    .focus_id = entry.key_ptr.*,
                    .x = child.rect.x,
                    .y = child.rect.y,
                    .width = child.rect.size.width,
                    .height = child.rect.size.height,
                };
            },
            else => {},
        }
    }

    if (submit == null and inputs.items.len == 0) return try out.toOwnedSlice(allocator);

    // top-to-bottom, left-to-right order so the natural tab cycle matches
    // visual layout (username -> password -> submit button).
    std.mem.sort(InputEntry, inputs.items, {}, struct {
        fn lt(_: void, a: InputEntry, b: InputEntry) bool {
            if (a.y != b.y) return a.y < b.y;
            return a.x < b.x;
        }
    }.lt);

    // only the auth page hosts a form right now; on any other page we
    // emit nothing. on auth, the URL depends on whether there's already
    // an active session.
    const action_url: []const u8 = switch (session.data.current_page) {
        .home_auth => if (session.data.user_id != null) "/logout" else "/login",
        .home_users, .home_repos => return try out.toOwnedSlice(allocator),
    };

    try out.appendSlice(allocator, "<form action=\"");
    try out.appendSlice(allocator, action_url);
    try out.appendSlice(allocator, "\" method=\"post\">");

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
        // intentionally no `value` attribute: the browser tracks user input
        // natively, and including the wasm-side value here would make the
        // overlay HTML differ on every keystroke — that would trip the diff
        // in _setOverlay and rebuild the <input>, eating the user's caret.
        try out.appendSlice(allocator, "\" style=\"left:");
        var pos_buf: [64]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:1em", .{ inner_left, inner_top, inner_width }));
        try out.appendSlice(allocator, "\">");
    }

    if (submit) |btn| {
        // inside the dashed border the TUI cells draw around the button.
        const inner_left = btn.x + 1;
        const inner_top = btn.y + 1;
        const inner_width = if (btn.width > 2) btn.width - 2 else 0;
        const inner_height = if (btn.height > 2) btn.height - 2 else 0;
        try out.appendSlice(allocator, "<button type=\"submit\" data-focus-id=\"");
        var id_buf: [32]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{btn.focus_id}));
        try out.appendSlice(allocator, "\" style=\"left:");
        var pos_buf: [128]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:{d}em", .{ inner_left, inner_top, inner_width, inner_height }));
        try out.appendSlice(allocator, "\"></button>");
    }

    try out.appendSlice(allocator, "</form>");

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

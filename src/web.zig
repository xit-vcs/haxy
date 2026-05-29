const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("./event.zig");
const ui = @import("./ui.zig");
const xitui = xit.xitui;
const wgt = xitui.widget;
const Focus = xitui.focus.Focus;
const Grid = xitui.grid.Grid;

const cookie_name = "haxy_session";
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
    session_store: SessionStore,
    err: *std.Io.Writer,
) void {
    const Listener = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        admin_repo_path: []const u8,
        session_store: SessionStore,
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
                    session_store: SessionStore,
                    err: *std.Io.Writer,

                    fn run(conn: @This()) void {
                        defer conn.stream.close(conn.io);
                        handleConnection(conn.io, conn.allocator, conn.stream, conn.admin_repo_path, conn.session_store, conn.err) catch |request_err| {
                            logError(conn.err, "web ui request failed: {s}\n", .{@errorName(request_err)});
                        };
                    }
                };

                ctx.tasks.async(ctx.io, Connection.run, .{Connection{
                    .io = ctx.io,
                    .allocator = ctx.allocator,
                    .stream = stream,
                    .admin_repo_path = ctx.admin_repo_path,
                    .session_store = ctx.session_store,
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
        .session_store = session_store,
        .err = err,
    }});
}

fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    admin_repo_path: []const u8,
    session_store: SessionStore,
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

        handleRequest(io, &request, allocator, admin_repo_path, session_store) catch |request_err| {
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
    session_store: SessionStore,
) !void {
    const method = request.head.method;
    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;

    if (method == .POST and std.mem.eql(u8, path, "/login")) {
        return handleLogin(io, request, allocator, admin_repo_path, session_store);
    }
    if (method == .POST and std.mem.eql(u8, path, "/logout")) {
        return handleLogout(request, session_store);
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
        // resolve the haxy_session cookie's token to a user_id via the
        // store. user_id_buf lives on the stack for the rest of handleRequest,
        // which is plenty for renderIndexHtml to consume.
        var user_id_buf: [evt.event_id_size]u8 = undefined;
        const user_id: ?[]const u8 = blk: {
            const token = getCookieValue(request, cookie_name) orelse break :blk null;
            if (!session_store.lookup(token, &user_id_buf)) break :blk null;
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
    session_store: SessionStore,
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
            const token = try session_store.create(&user_id);
            var cookie_buf: [256]u8 = undefined;
            const cookie = try std.fmt.bufPrint(&cookie_buf, cookie_name ++ "={s}; Path=/; HttpOnly; SameSite=Strict", .{token});
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

fn handleLogout(request: *std.http.Server.Request, session_store: SessionStore) !void {
    // revoke the session server-side so the cookie is dead for anyone holding
    // a copy, not just this browser.
    if (getCookieValue(request, cookie_name)) |token| session_store.remove(token);
    // close the connection instead of keeping it alive: we don't read the
    // request body, and respond()'s keep-alive path would otherwise try to
    // discard it — which asserts on a bodyless POST that carries no
    // content-length, and would block on one with no framing at all. a logout
    // is just a redirect, so the browser reconnects for the follow-up GET.
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
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

    const content = try generateHtml(allocator, &root);
    defer allocator.free(content);
    const overlay = try generateOverlay(allocator, &root);
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

// emits the TUI grid cells as static HTML
pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    const Tag = union(enum) {
        span, // clickable focusable cell
        a: []const u8, // clickable focusable link
        plain, // non-focusable, colored

        const a_prefix = "a:";

        fn init(str: []const u8) @This() {
            if (std.mem.startsWith(u8, str, a_prefix)) {
                return .{ .a = str[a_prefix.len..] };
            }
            return .span;
        }

        fn writeOpenTag(self: @This(), alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: usize, style_attr: []const u8) !void {
            var id_buf: [32]u8 = undefined;
            switch (self) {
                .span => {
                    try out.appendSlice(alloc, "<span class=\"clickable\" data-focus-id=\"");
                    try out.appendSlice(alloc, try std.fmt.bufPrint(&id_buf, "{d}", .{id}));
                    try out.appendSlice(alloc, "\"");
                    try out.appendSlice(alloc, style_attr);
                    try out.appendSlice(alloc, ">");
                },
                .a => |href| {
                    try out.appendSlice(alloc, "<a class=\"clickable\" data-focus-id=\"");
                    try out.appendSlice(alloc, try std.fmt.bufPrint(&id_buf, "{d}", .{id}));
                    try out.appendSlice(alloc, "\" href=\"");
                    try appendEscapedHtml(alloc, out, href);
                    try out.appendSlice(alloc, "\"");
                    try out.appendSlice(alloc, style_attr);
                    try out.appendSlice(alloc, ">");
                },
                .plain => {
                    try out.appendSlice(alloc, "<span");
                    try out.appendSlice(alloc, style_attr);
                    try out.appendSlice(alloc, ">");
                },
            }
        }

        fn closeTag(self: @This()) []const u8 {
            return switch (self) {
                .span, .plain => "</span>",
                .a => "</a>",
            };
        }
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..grid.size.height) |y| {
        var cur_id: ?usize = null;
        var cur_fg: ?Grid.Color = null;
        var cur_bg: ?Grid.Color = null;
        var open_tag: ?Tag = null;
        var first = true;
        for (0..grid.size.width) |x| {
            const cell = grid.cells.items[try grid.cells.at(.{ y, x })];
            const cell_id = cellFocusId(root_focus, x, y);
            const fg = cell.style.fg;
            const bg = cell.style.bg;

            if (first or cell_id != cur_id or !colorEql(fg, cur_fg) or !colorEql(bg, cur_bg)) {
                if (open_tag) |t| try out.appendSlice(allocator, t.closeTag());

                var new_tag: ?Tag = null;
                if (cell_id) |id| {
                    if (root_focus.children.get(id)) |child| {
                        new_tag = switch (child.focus.kind) {
                            .custom => |custom| Tag.init(custom),
                            else => .span,
                        };
                    }
                }
                if (new_tag == null and (fg != null or bg != null)) new_tag = .plain;

                if (new_tag) |t| {
                    var style_buf: [64]u8 = undefined;
                    try t.writeOpenTag(allocator, &out, cell_id orelse 0, styleAttr(&style_buf, fg, bg));
                }

                open_tag = new_tag;
                cur_id = cell_id;
                cur_fg = fg;
                cur_bg = bg;
                first = false;
            }

            try appendEscapedHtml(allocator, &out, cell.rune orelse " ");
        }
        if (open_tag) |t| try out.appendSlice(allocator, t.closeTag());
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

// emits the form overlay — one <form> per "form:<url>" focus subtree in the
// widget tree, each wrapping the text inputs and submit button inside it,
// positioned absolutely over the matching grid cells.
pub fn generateOverlay(allocator: std.mem.Allocator, root: *ui.Widget) ![]const u8 {
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const form_prefix = "form:";

    // Focus.children is an AutoArrayHashMap that preserves insertion order,
    // which matches the order widgets were added in code
    var iter = root_focus.children.iterator();
    while (iter.next()) |entry| {
        const child = entry.value_ptr.*;
        const action_url = switch (child.focus.kind) {
            .custom => |custom| if (std.mem.startsWith(u8, custom, form_prefix))
                custom[form_prefix.len..]
            else
                continue,
            else => continue,
        };

        try out.appendSlice(allocator, "<form action=\"");
        try appendEscapedHtml(allocator, &out, action_url);
        try out.appendSlice(allocator, "\" method=\"post\">");

        // form.focus.children was populated by addChild, which flattens the
        // whole subtree into one map — so descendants (inputs + the submit
        // button) all appear here. positions on form.focus are relative to
        // the form, so we look up absolute rects via root_focus for layout.
        var inner_iter = child.focus.children.iterator();
        while (inner_iter.next()) |inner_entry| {
            const inner_id = inner_entry.key_ptr.*;
            const root_child = root_focus.children.get(inner_id) orelse continue;
            const r = root_child.rect;
            switch (root_child.focus.kind) {
                .text_input, .text_input_password => {
                    const ti: *wgt.TextInput(ui.Widget) = @fieldParentPtr("focus", root_child.focus);
                    const inner_left = r.x + 1;
                    const inner_top = r.y + 1;
                    const inner_width = if (r.size.width > 2) r.size.width - 2 else 0;

                    try out.appendSlice(allocator, "<input type=\"");
                    try out.appendSlice(allocator, if (root_child.focus.kind == .text_input_password) "password" else "text");
                    try out.appendSlice(allocator, "\" data-focus-id=\"");
                    var id_buf: [32]u8 = undefined;
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{inner_id}));
                    if (ti.options.name.len > 0) {
                        try out.appendSlice(allocator, "\" name=\"");
                        try appendEscapedHtml(allocator, &out, ti.options.name);
                    }
                    // intentionally no `value` attribute: the browser tracks user input
                    // natively, and including the wasm-side value here would make the
                    // overlay HTML differ on every keystroke — that would trip the diff
                    // in _setOverlay and rebuild the <input>, eating the user's caret.
                    try out.appendSlice(allocator, "\" style=\"left:");
                    var pos_buf: [64]u8 = undefined;
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:1em", .{ inner_left, inner_top, inner_width }));
                    try out.appendSlice(allocator, "\">");
                },
                .custom => |custom| {
                    if (std.mem.eql(u8, "submit", custom)) {
                        // inside the dashed border the TUI cells draw around the button.
                        const inner_left = r.x + 1;
                        const inner_top = r.y + 1;
                        const inner_width = if (r.size.width > 2) r.size.width - 2 else 0;
                        const inner_height = if (r.size.height > 2) r.size.height - 2 else 0;
                        try out.appendSlice(allocator, "<button type=\"submit\" data-focus-id=\"");
                        var id_buf: [32]u8 = undefined;
                        try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{inner_id}));
                        try out.appendSlice(allocator, "\" style=\"left:");
                        var pos_buf: [128]u8 = undefined;
                        try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:{d}em", .{ inner_left, inner_top, inner_width, inner_height }));
                        try out.appendSlice(allocator, "\"></button>");
                    }
                },
                else => {},
            }
        }

        try out.appendSlice(allocator, "</form>");
    }

    return try out.toOwnedSlice(allocator);
}

fn colorEql(a: ?Grid.Color, b: ?Grid.Color) bool {
    if (a) |av| return if (b) |bv| av.eql(bv) else false;
    return b == null;
}

// builds an HTML ` style="color:#rrggbb;background-color:#rrggbb"` attribute
// from a cell's fg/bg into `buf`, omitting whichever color is unset. returns an
// empty slice when neither is set.
fn styleAttr(buf: []u8, fg: ?Grid.Color, bg: ?Grid.Color) []const u8 {
    if (fg == null and bg == null) return buf[0..0];
    const prefix = " style=\"";
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    if (fg) |c| {
        const s = std.fmt.bufPrint(buf[i..], "color:#{x:0>2}{x:0>2}{x:0>2};", .{ c.r, c.g, c.b }) catch return buf[0..0];
        i += s.len;
    }
    if (bg) |c| {
        const s = std.fmt.bufPrint(buf[i..], "background-color:#{x:0>2}{x:0>2}{x:0>2};", .{ c.r, c.g, c.b }) catch return buf[0..0];
        i += s.len;
    }
    buf[i] = '"';
    i += 1;
    return buf[0..i];
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

// disk-backed web session store. each login mints a random, opaque token
// (not the user's id) that is stored as a file named by the token hex, whose
// contents are the raw user_id bytes. authenticating a request is a lookup of
// the cookie's token; logout deletes the file, revoking the session. there is
// deliberately no expiry — a session lives until logout.
pub const SessionStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub const token_hex_len = evt.event_id_size * 2;

    pub fn init(io: std.Io, data_dir: std.Io.Dir) !SessionStore {
        try data_dir.createDirPath(io, "sessions");
        const dir = try data_dir.openDir(io, "sessions", .{});
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: SessionStore) void {
        self.dir.close(self.io);
    }

    // mint a new session for user_id, returning the token hex to set as the
    // cookie value.
    pub fn create(self: SessionStore, user_id: *const [evt.event_id_size]u8) ![token_hex_len]u8 {
        var token: [evt.event_id_size]u8 = undefined;
        self.io.random(&token);
        const token_hex = std.fmt.bytesToHex(token, .lower);
        const file = try self.dir.createFile(self.io, &token_hex, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, user_id);
        return token_hex;
    }

    // resolve a cookie's token to its user_id. returns false (logged out) for a
    // missing, malformed, or unknown token.
    pub fn lookup(self: SessionStore, token_hex: []const u8, out: *[evt.event_id_size]u8) bool {
        if (!isToken(token_hex)) return false;
        const file = self.dir.openFile(self.io, token_hex, .{ .mode = .read_only }) catch return false;
        defer file.close(self.io);
        var storage: [evt.event_id_size]u8 = undefined;
        var file_reader = file.reader(self.io, &storage);
        file_reader.interface.readSliceAll(out) catch return false;
        return true;
    }

    // revoke a session. a no-op for a missing or malformed token.
    pub fn remove(self: SessionStore, token_hex: []const u8) void {
        if (!isToken(token_hex)) return;
        self.dir.deleteFile(self.io, token_hex) catch {};
    }

    // a token is exactly token_hex_len hex chars. validating before using the
    // value as a path keeps attacker-supplied cookies from escaping the
    // sessions dir (e.g. via "/" or ".." bytes).
    fn isToken(token_hex: []const u8) bool {
        if (token_hex.len != token_hex_len) return false;
        for (token_hex) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
};

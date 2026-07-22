const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("./event.zig");
const serve_common = @import("./serve_common.zig");
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
    .{ .path = "haxy.wasm", .content_type = "application/wasm", .body = @embedFile("haxy.wasm") },
};

// what a web request is served from: the multi-user server (admin repo +
// login sessions) or a single local repo.
pub const Host = union(enum) {
    remote: struct {
        admin_repo_path: []const u8,
        session_store: SessionStore,
    },
    local: ui.RepoSource,
};

pub fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    host: Host,
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

        handleRequest(io, &request, allocator, host) catch |request_err| {
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
    host: Host,
) !void {
    const method = request.head.method;
    const uri = try std.Uri.parseAfterScheme("", request.head.target);
    const path = uri.path.percent_encoded;

    // POST routes can be scoped by any page, so they can redirect using
    // the base of the URL. this allows logging in to keep you on the page
    // you were on. local mode has no accounts, so only the issue routes.
    if (method == .POST) {
        switch (host) {
            .remote => |remote| {
                const PostRoute = enum { login, logout, ansi, issue, open, close, edit };
                inline for (@typeInfo(PostRoute).@"enum".fields) |field| {
                    const suffix = "/" ++ field.name;
                    if (std.mem.endsWith(u8, path, suffix)) {
                        const base = path[0 .. path.len - suffix.len];
                        return switch (@field(PostRoute, field.name)) {
                            .login => handleLogin(io, request, allocator, base, remote.admin_repo_path, remote.session_store),
                            .logout => handleLogout(request, base, remote.session_store),
                            .ansi => handleAnsi(io, request, allocator, base, remote.admin_repo_path, remote.session_store),
                            .issue => handleIssue(io, request, allocator, base, host),
                            .open => handleIssueStatus(io, request, allocator, base, host, .open),
                            .close => handleIssueStatus(io, request, allocator, base, host, .closed),
                            .edit => handleIssueEdit(io, request, allocator, base, host),
                        };
                    }
                }
            },
            .local => {
                const PostRoute = enum { issue, open, close, edit };
                inline for (@typeInfo(PostRoute).@"enum".fields) |field| {
                    const suffix = "/" ++ field.name;
                    if (std.mem.endsWith(u8, path, suffix)) {
                        const base = path[0 .. path.len - suffix.len];
                        return switch (@field(PostRoute, field.name)) {
                            .issue => handleIssue(io, request, allocator, base, host),
                            .open => handleIssueStatus(io, request, allocator, base, host, .open),
                            .close => handleIssueStatus(io, request, allocator, base, host, .closed),
                            .edit => handleIssueEdit(io, request, allocator, base, host),
                        };
                    }
                }
            },
        }
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

    const current_page_maybe = switch (host) {
        .remote => ui.RoutablePage.fromUrl(path),
        .local => ui.RoutablePage.fromUrlLocal(path),
    };
    if (current_page_maybe) |current_page| {
        // resolve the haxy_session cookie's token to a user_id via the
        // store. user_id_buf lives on the stack for the rest of handleRequest,
        // which is plenty for renderIndexHtml to consume. local mode has no
        // accounts, so it is always logged out.
        var user_id_buf: [evt.event_id_size]u8 = undefined;
        var user_id: ?[]const u8 = null;
        var login_failure: ?ui.Home.Auth.Login.Failure = null;
        switch (host) {
            .remote => |remote| {
                user_id = blk: {
                    const token = getCookieValue(request, cookie_name) orelse break :blk null;
                    if (!remote.session_store.lookup(token, &user_id_buf)) break :blk null;
                    break :blk user_id_buf[0..evt.event_id_size];
                };
                login_failure = if (getCookieValue(request, login_failure_cookie)) |raw|
                    if (std.mem.eql(u8, raw, "unknown_user"))
                        .unknown_user
                    else if (std.mem.eql(u8, raw, "wrong_password"))
                        .wrong_password
                    else
                        null
                else
                    null;
            },
            .local => {},
        }

        const html = renderIndexHtml(io, allocator, host, .{
            .user_id = user_id,
            .login_failure = login_failure,
            .current_page = current_page,
            .is_local = host == .local,
        }) catch |err| switch (err) {
            error.NotFound => {
                try request.respond("not found", .{
                    .status = .not_found,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                });
                return;
            },
            else => |e| return e,
        };
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

    // the embeds change with every build, so the browser must revalidate
    // rather than heuristically cache them across server restarts
    try request.respond(embed.body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = embed.content_type },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

fn handleLogin(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
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

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
    defer repo.deinit(io, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const haxy_moment = try evt.currentMoment(evt.admin_repo_opts, &repo);
    const result = try evt.User.verifyCredentials(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, &arena, username, password);

    // on success, return to the page the login came from (base, or "/" at the
    // root); on failure, stay on its auth tab to surface the error.
    const success_location: []const u8 = if (base.len == 0) "/" else base;
    const failure_location = try std.fmt.allocPrint(arena.allocator(), "{s}/auth", .{base});

    switch (result) {
        .success => |user_id| {
            const token = try session_store.create(&user_id);
            var cookie_buf: [256]u8 = undefined;
            const cookie = try std.fmt.bufPrint(&cookie_buf, cookie_name ++ "={s}; Path=/; HttpOnly; SameSite=Strict", .{token});
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = success_location },
                    .{ .name = "set-cookie", .value = cookie },
                },
            });
        },
        .unknown_user => {
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = failure_location },
                    .{ .name = "set-cookie", .value = login_failure_cookie ++ "=unknown_user; Path=/; HttpOnly; SameSite=Strict" },
                },
            });
        },
        .wrong_password => {
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = failure_location },
                    .{ .name = "set-cookie", .value = login_failure_cookie ++ "=wrong_password; Path=/; HttpOnly; SameSite=Strict" },
                },
            });
        },
    }
}

fn handleLogout(request: *std.http.Server.Request, base: []const u8, session_store: SessionStore) !void {
    // revoke the session server-side so the cookie is dead for anyone holding
    // a copy, not just this browser.
    if (getCookieValue(request, cookie_name)) |token| session_store.remove(token);
    // return to the page the logout came from (base, or "/" at the root).
    const location: []const u8 = if (base.len == 0) "/" else base;
    // close the connection instead of keeping it alive: we don't read the
    // request body, and respond()'s keep-alive path would otherwise try to
    // discard it — which asserts on a bodyless POST that carries no
    // content-length, and would block on one with no framing at all. a logout
    // is just a redirect, so the browser reconnects for the follow-up GET.
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
            .{ .name = "set-cookie", .value = cookie_name ++ "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
        },
    });
}

fn handleAnsi(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    admin_repo_path: []const u8,
    session_store: SessionStore,
) !void {
    var user_id: [evt.event_id_size]u8 = undefined;
    if (getCookieValue(request, cookie_name)) |token| {
        if (session_store.lookup(token, &user_id)) {
            const Repo = rp.Repo(.xit, evt.admin_repo_opts);
            var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
            defer repo.deinit(io, allocator);

            try evt.User.toggleAnsi(evt.admin_repo_opts, io, allocator, &repo, &user_id);
        }
    }

    // return to the settings tab the toggle came from so the change is visible.
    const location = try std.fmt.allocPrint(allocator, "{s}/settings", .{base});
    defer allocator.free(location);

    // like logout, this is a bodyless POST, so close the connection rather than
    // letting the keep-alive path try to discard a body that isn't framed.
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
        },
    });
}

// create an issue in the repo the form's page names (base is
// "/repo/<owner>/<name>", or "" in local mode) and redirect to it
fn handleIssue(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    var body_buf: [256]u8 = undefined;
    const reader = request.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(allocator, .limited(65536)) catch &[_]u8{};
    defer allocator.free(body);

    const title = (try parseFormField(allocator, body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title);
    const tags = (try parseFormField(allocator, body, "tags")) orelse try allocator.dupe(u8, "");
    defer allocator.free(tags);
    const description_crlf = (try parseFormField(allocator, body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_crlf);
    // form submission normalizes textarea line breaks to CRLF; store plain
    // newlines so the text renders the same on every host
    const description = try std.mem.replaceOwned(u8, allocator, description_crlf, "\r\n", "\n");
    defer allocator.free(description);

    if (!evt.Issue.fieldsValid(title, tags)) {
        const form_location = try std.fmt.allocPrint(allocator, "{s}/issues/new", .{base});
        defer allocator.free(form_location);
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    const event = evt.EventWithId{
        .id = event_id_hex,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .event = .{ .issue = .{
            .title = title,
            .description = description,
            .tags = tags,
        } },
    };

    const not_found = "repo not found";
    switch (host) {
        .remote => |remote| {
            const repo_prefix = "/repo/";
            if (!std.mem.startsWith(u8, base, repo_prefix)) {
                try request.respond(not_found, .{
                    .status = .not_found,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                });
                return;
            }

            const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(remote.admin_repo_path) orelse ".", "repos" });
            defer allocator.free(repos_dir);
            const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, repos_dir, remote.admin_repo_path, base[repo_prefix.len..], false)) {
                .ok => |p| p,
                .invalid, .not_found => {
                    try request.respond(not_found, .{
                        .status = .not_found,
                        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                    });
                    return;
                },
            };
            defer allocator.free(repo_path);

            var repo = try rp.Repo(.xit, .{}).open(io, allocator, .{ .path = repo_path });
            defer repo.deinit(io, allocator);
            try evt.commitAndConsume(.xit, .{}, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{event});
        },
        .local => |src| {
            // the local form posts to "/issue", so base is empty
            if (base.len != 0) {
                try request.respond(not_found, .{
                    .status = .not_found,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                });
                return;
            }
            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try evt.commitAndConsume(repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &[_]evt.EventWithId{event}),
                    }
                },
            }
        },
    }

    const location = try std.fmt.allocPrint(allocator, "{s}/issues/{s}", .{ base, &event_id_hex });
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

// split an issue url ("/repo/<owner>/<name>/issues/<id>", identity elided in
// local mode) into what precedes "/issues/" and the decoded id, null when it
// isn't one. the repo base is validated per host in updateIssue.
const IssueBaseParts = struct { repo_base: []const u8, id_bytes: [evt.event_id_size]u8 };
fn issueBaseParts(base: []const u8) ?IssueBaseParts {
    const issues_infix = "/issues/";
    const id_len = evt.event_id_size * 2;
    if (base.len < issues_infix.len + id_len) return null;
    var id_bytes: [evt.event_id_size]u8 = undefined;
    _ = std.fmt.hexToBytes(&id_bytes, base[base.len - id_len ..]) catch return null;
    const head = base[0 .. base.len - id_len];
    if (!std.mem.endsWith(u8, head, issues_infix)) return null;
    return .{ .repo_base = head[0 .. head.len - issues_infix.len], .id_bytes = id_bytes };
}

// re-emit the issue `parts` names with `update` applied, in the repo the
// host resolves the base to. error.NotFound when the base names no repo or
// the id no issue.
fn updateIssue(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    parts: IssueBaseParts,
    update: evt.Issue.Update,
) !void {
    switch (host) {
        .remote => |remote| {
            const repo_prefix = "/repo/";
            if (!std.mem.startsWith(u8, parts.repo_base, repo_prefix)) return error.NotFound;
            const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(remote.admin_repo_path) orelse ".", "repos" });
            defer allocator.free(repos_dir);
            const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, repos_dir, remote.admin_repo_path, parts.repo_base[repo_prefix.len..], false)) {
                .ok => |p| p,
                .invalid, .not_found => return error.NotFound,
            };
            defer allocator.free(repo_path);

            var repo = try rp.Repo(.xit, .{}).open(io, allocator, .{ .path = repo_path });
            defer repo.deinit(io, allocator);
            try evt.Issue.update(.xit, .{}, io, allocator, &repo, &parts.id_bytes, update);
        },
        .local => |src| {
            // the local forms post to "/issues/<id>/...", so the repo base
            // is empty
            if (parts.repo_base.len != 0) return error.NotFound;
            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, .{ .path = src.path });
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try evt.Issue.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &parts.id_bytes, update),
                    }
                },
            }
        },
    }
}

// set the status of the issue the url names (base is
// "/repo/<owner>/<name>/issues/<id>", identity elided in local mode) by
// re-emitting its event, then redirect back to it
fn handleIssueStatus(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    status: evt.Issue.Status,
) !void {
    const not_found = "issue not found";
    const parts = issueBaseParts(base) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    updateIssue(io, allocator, host, parts, .{ .status = status }) catch |err| switch (err) {
        error.NotFound => {
            try request.respond(not_found, .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            });
            return;
        },
        else => |e| return e,
    };

    // like logout, this is a bodyless POST, so close the connection rather than
    // letting the keep-alive path try to discard a body that isn't framed.
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = base }},
    });
}

// replace the title/tags/description of the issue the url names (base is
// "/repo/<owner>/<name>/issues/<id>", identity elided in local mode; the
// form posts to "<base>/edit") by re-emitting its event with its status
// preserved, then redirect back to it
fn handleIssueEdit(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    var body_buf: [256]u8 = undefined;
    const reader = request.readerExpectNone(&body_buf);
    const body = reader.allocRemaining(allocator, .limited(65536)) catch &[_]u8{};
    defer allocator.free(body);

    const title = (try parseFormField(allocator, body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title);
    const tags = (try parseFormField(allocator, body, "tags")) orelse try allocator.dupe(u8, "");
    defer allocator.free(tags);
    const description_crlf = (try parseFormField(allocator, body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_crlf);
    // form submission normalizes textarea line breaks to CRLF; store plain
    // newlines so the text renders the same on every host
    const description = try std.mem.replaceOwned(u8, allocator, description_crlf, "\r\n", "\n");
    defer allocator.free(description);

    // invalid fields send the user back to the edit form
    if (!evt.Issue.fieldsValid(title, tags)) {
        const form_location = try std.fmt.allocPrint(allocator, "{s}/edit", .{base});
        defer allocator.free(form_location);
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    const not_found = "issue not found";
    const parts = issueBaseParts(base) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    updateIssue(io, allocator, host, parts, .{ .fields = .{
        .title = title,
        .tags = tags,
        .description = description,
    } }) catch |err| switch (err) {
        error.NotFound => {
            try request.respond(not_found, .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            });
            return;
        },
        else => |e| return e,
    };

    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = base }},
    });
}

fn renderIndexHtml(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    session_data: ui.Session.Data,
) ![]const u8 {
    const template = (findEmbed("/index.html") orelse return error.MissingIndexAsset).body;

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    // the remote admin repo must outlive the page build, since the session's
    // moment reads from it.
    var repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (repo_maybe) |*repo| repo.deinit(io, allocator);

    var session = switch (host) {
        .remote => |remote| blk: {
            // open the admin repo to read live user/repo data.
            repo_maybe = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = remote.admin_repo_path });
            const repo = if (repo_maybe) |*repo| repo else unreachable;
            var session = try ui.Session.init(&page_arena, repo, session_data);
            // give the page builders filesystem access to the on-disk repos (a
            // sibling "repos" dir next to the admin repo) so the Repo page can
            // read its files.
            session.repos_dir = try std.fs.path.join(page_arena.allocator(), &.{ std.fs.path.dirname(remote.admin_repo_path) orelse ".", "repos" });
            break :blk session;
        },
        .local => |local| ui.Session{
            .data = session_data,
            .arena = &page_arena,
            .page_arena = &page_arena,
            .local = local,
        },
    };
    session.io = io;

    const snapshot: ui.Snapshot = .{
        .page = try ui.Page.init(session.page_arena, &session, session.data.current_page),
        .session = session.data,
    };
    var root = try ui.initRoot(allocator, &snapshot.page, &session);
    defer root.deinit(allocator);

    const content = try generateHtml(allocator, &root);
    defer allocator.free(content);
    const overlay = try generateOverlay(allocator, &root, &session);
    defer allocator.free(overlay);

    // serialize the snapshot so the wasm side can parse it back without making
    // a second request. it's embedded raw in a <script type="application/json">
    // block, whose content is raw text terminated only by "</script". in json,
    // '<' appears solely inside string values, so escaping every '<' (and '>'
    // for good measure) to its \uXXXX form yields equivalent json that can't
    // break out of the tag.
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(snapshot, .{}, &json.writer);

    var json_escaped: std.ArrayList(u8) = .empty;
    defer json_escaped.deinit(allocator);
    for (json.written()) |c| switch (c) {
        '<' => try json_escaped.appendSlice(allocator, "\\u003c"),
        '>' => try json_escaped.appendSlice(allocator, "\\u003e"),
        else => try json_escaped.append(allocator, c),
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    {
        var cursor: usize = 0;
        for (&[_]struct { needle: []const u8, replacement: []const u8 }{
            .{ .needle = "{{{ HAXY_HTML }}}", .replacement = content },
            .{ .needle = "{{{ HAXY_OVERLAY }}}", .replacement = overlay },
            .{ .needle = "{{{ HAXY_JSON }}}", .replacement = json_escaped.items },
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

// emits the TUI grid cells as static HTML. each web-native Scroll becomes its
// own absolutely-positioned, natively-scrollable <div> holding its full content,
// rendered recursively so nested scrolls work.
pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try renderPanel(allocator, &out, root.getFocus(), grid);
    return try out.toOwnedSlice(allocator);
}

// render one panel — a focus subtree and its content grid — as HTML, recursing
// once per web-native Scroll inside it. the root panel is the whole page; each
// Scroll becomes a nested, natively-scrollable div holding its full content.
// emits the panel's grid cells as text, leaving holes where child scrolls sit,
// then the child scroll divs over those holes.
fn renderPanel(allocator: std.mem.Allocator, output: *std.ArrayList(u8), focus: *Focus, grid: Grid) !void {
    // `direct` is this panel's scroll children, each drawn as an overlaid div.
    // `excluded` is every focus id that belongs to a scroll (the scroll nodes
    // plus their descendants, which the focus tree flattens into this panel's
    // children): the cell hit-test below skips them so this panel doesn't claim
    // cells that are really rendered inside a child scroll's own panel.
    // (scrolls aren't nested in practice, so every scroll child is direct here.)
    var direct: std.ArrayList(usize) = .empty;
    defer direct.deinit(allocator);
    var excluded: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer excluded.deinit(allocator);
    {
        var it = focus.children.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.focus.scroll == null) continue;
            try direct.append(allocator, e.key_ptr.*);
            try excluded.put(allocator, e.key_ptr.*, {});
            var mit = e.value_ptr.focus.children.iterator();
            while (mit.next()) |m| try excluded.put(allocator, m.key_ptr.*, {});
        }
    }

    // the HTML element a run of cells is wrapped in, chosen from the cell's
    // focusable kind
    const CellTag = union(enum) {
        span, // clickable focusable cell
        a: []const u8, // clickable focusable link
        plain, // non-focusable, colored

        const a_prefix = "a:";
        // an "in-page" anchor: rendered as a real <a href> so it works with js
        // disabled, but crossPageLink ignores it, so with wasm the click just
        // moves focus rather than navigating.
        const inpage_prefix = "ai:";

        fn init(str: []const u8) @This() {
            if (std.mem.startsWith(u8, str, inpage_prefix)) {
                return .{ .a = str[inpage_prefix.len..] };
            }
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
                    // tabindex=-1 keeps these out of the browser's tab order
                    try out.appendSlice(alloc, "<a class=\"clickable\" tabindex=\"-1\" data-focus-id=\"");
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

    // emit this panel's grid as rows of text, coalescing adjacent cells that
    // share a focus id and colors into one tag (a clickable span, a link, or a
    // plain colored span). cells under a child scroll keep only their background.
    for (0..grid.size.height) |y| {
        var cur_id: ?usize = null;
        var cur_fg: ?Grid.Color = null;
        var cur_bg: ?Grid.Color = null;
        var open_tag: ?CellTag = null;
        var first = true;
        for (0..grid.size.width) |x| {
            const cell = grid.cells.items[try grid.cells.at(.{ y, x })];
            // a cell covered by a child scroll's viewport is drawn by that scroll's
            // own div, so blank its glyph and make it non-clickable here — but keep
            // its background, so the backdrop still shows through the scroll's
            // transparent div instead of a bare hole.
            const covered_by_scroll = blk: {
                for (direct.items) |id| {
                    const r = (focus.children.get(id) orelse continue).rect;
                    if (x >= r.x and y >= r.y and x < r.x + r.size.width and y < r.y + r.size.height) break :blk true;
                }
                break :blk false;
            };
            // the focusable cell at (x, y) among this panel's own focusables (skipping
            // any that belong to a child scroll, whose cells are drawn in their own
            // panel); none for a covered cell.
            const cell_id = if (covered_by_scroll) null else blk: {
                var iter = focus.children.iterator();
                while (iter.next()) |entry| {
                    const child = entry.value_ptr.*;
                    if (!child.focus.focusable) continue;
                    if (excluded.contains(entry.key_ptr.*)) continue;
                    const r = child.rect;
                    if (x >= r.x and y >= r.y and x < r.x + r.size.width and y < r.y + r.size.height) {
                        break :blk entry.key_ptr.*;
                    }
                }
                break :blk null;
            };
            const fg = if (covered_by_scroll) null else cell.style.fg;
            const bg = cell.style.bg;

            if (first or cell_id != cur_id or !colorEql(fg, cur_fg) or !colorEql(bg, cur_bg)) {
                if (open_tag) |t| try output.appendSlice(allocator, t.closeTag());

                var new_tag: ?CellTag = null;
                if (cell_id) |id| {
                    if (focus.children.get(id)) |child| {
                        new_tag = switch (child.focus.kind) {
                            .custom => |custom| CellTag.init(custom),
                            else => .span,
                        };
                    }
                }
                if (new_tag == null and (fg != null or bg != null)) new_tag = .plain;

                if (new_tag) |t| {
                    var style_buf: [64]u8 = undefined;
                    try t.writeOpenTag(allocator, output, cell_id orelse 0, styleAttr(&style_buf, fg, bg));
                }

                open_tag = new_tag;
                cur_id = cell_id;
                cur_fg = fg;
                cur_bg = bg;
                first = false;
            }

            if (covered_by_scroll) {
                try appendEscapedHtml(allocator, output, " ");
            } else if (cell.continuation) {
                // the wide rune to the left was emitted 2ch wide, covering this column
            } else if (cell.rune) |rune| {
                // a double-width rune is pinned inside a 2ch span so the
                // fallback glyph's advance width can't shift the rest of the row
                const wide = x + 1 < grid.size.width and grid.cells.items[try grid.cells.at(.{ y, x + 1 })].continuation;
                if (wide) {
                    try output.appendSlice(allocator, "<span class=\"w2\">");
                    try appendEscapedHtml(allocator, output, rune);
                    try output.appendSlice(allocator, "</span>");
                } else {
                    try appendEscapedHtml(allocator, output, rune);
                }
            } else {
                try appendEscapedHtml(allocator, output, " ");
            }
        }
        if (open_tag) |t| try output.appendSlice(allocator, t.closeTag());
        try output.append(allocator, '\n');
    }

    // each child scroll becomes a natively-scrollable div positioned over its
    // viewport, holding its full content rendered recursively.
    for (direct.items) |id| {
        const child = focus.children.get(id) orelse continue;
        const info = child.focus.scroll orelse continue;
        const r = child.rect;
        // overflow only on the axes the widget scrolls; `auto` shows a bar only
        // when that axis actually overflows. the other axis is clipped (hidden),
        // matching how the terminal Scroll handles its non-scrolling axis.
        const overflow = switch (info.direction) {
            .vert => "overflow-x:hidden;overflow-y:auto",
            .horiz => "overflow-x:auto;overflow-y:hidden",
            .both => "overflow:auto",
        };
        // the id carries a content version so JS preserves the native scroll
        // position across re-renders of the same content but resets it when the
        // content is replaced — e.g. selecting a different commit. the widget's
        // scroll offset (in cells) rides along so JS can apply it when it has no
        // preserved position, letting a wasm-side scrollToRect (the files list
        // scrolling to its selected row on page load) reach the browser.
        var buf: [224]u8 = undefined;
        try output.appendSlice(allocator, try std.fmt.bufPrint(&buf, "<div class=\"scroll\" data-scroll-id=\"{d}-{d}\" data-scroll-x=\"{d}\" data-scroll-y=\"{d}\" style=\"left:{d}ch;top:{d}em;width:{d}ch;height:{d}em;{s}\">", .{ id, child.focus.version, info.offset_x, info.offset_y, r.x, r.y, r.size.width, r.size.height, overflow }));
        try renderPanel(allocator, output, child.focus, info.content);
        try output.appendSlice(allocator, "</div>");
    }
}

// emits the form overlay — one <form> per "form:<url>" focus subtree in the
// widget tree, each wrapping the text inputs and submit button inside it,
// positioned absolutely over the matching grid cells.
pub fn generateOverlay(allocator: std.mem.Allocator, root: *ui.Widget, session: *ui.Session) ![]const u8 {
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
        try out.appendSlice(allocator, "\" method=\"post\"");
        // an empty action must not POST — block it and send the input to the TUI instead
        if (action_url.len == 0) try out.appendSlice(allocator, " onsubmit=\"event.preventDefault();sendEnter(this);\"");
        try out.appendSlice(allocator, ">");

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
                    const ti = session.text_inputs.get(inner_id) orelse continue;
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
                    // never the live content as the `value`: the browser tracks user
                    // input natively, and including the wasm-side value here would make
                    // the overlay HTML differ on every keystroke — that would trip the
                    // diff in _setOverlay and rebuild the <input>, eating the user's
                    // caret. a page-constant initial value is safe.
                    if (session.input_values.get(inner_id)) |value| {
                        try out.appendSlice(allocator, "\" value=\"");
                        try appendEscapedHtml(allocator, &out, value);
                    }
                    try out.appendSlice(allocator, "\" style=\"left:");
                    var pos_buf: [64]u8 = undefined;
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:1em", .{ inner_left, inner_top, inner_width }));
                    try out.appendSlice(allocator, "\">");
                },
                .text_area => {
                    const ti = session.text_inputs.get(inner_id) orelse continue;
                    const inner_left = r.x + 1;
                    const inner_top = r.y + 1;
                    const inner_width = if (r.size.width > 2) r.size.width - 2 else 0;
                    const inner_height = if (r.size.height > 2) r.size.height - 2 else 0;

                    try out.appendSlice(allocator, "<textarea data-focus-id=\"");
                    var id_buf: [32]u8 = undefined;
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{inner_id}));
                    if (ti.options.name.len > 0) {
                        try out.appendSlice(allocator, "\" name=\"");
                        try appendEscapedHtml(allocator, &out, ti.options.name);
                    }
                    // like the input above, only a page-constant initial value
                    // inside: the browser tracks the live value and the
                    // overlay diff must stay stable across keystrokes
                    try out.appendSlice(allocator, "\" style=\"left:");
                    var pos_buf: [128]u8 = undefined;
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:{d}em", .{ inner_left, inner_top, inner_width, inner_height }));
                    try out.appendSlice(allocator, "\">");
                    if (session.input_values.get(inner_id)) |value| try appendEscapedHtml(allocator, &out, value);
                    try out.appendSlice(allocator, "</textarea>");
                },
                .custom => |custom| {
                    if (std.mem.eql(u8, "submit", custom)) {
                        try out.appendSlice(allocator, "<button type=\"submit\" data-focus-id=\"");
                        var id_buf: [32]u8 = undefined;
                        try out.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{inner_id}));
                        try out.appendSlice(allocator, "\" style=\"left:");
                        var pos_buf: [128]u8 = undefined;
                        try out.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, "{d}ch;top:{d}em;width:{d}ch;height:{d}em", .{ r.x, r.y, r.size.width, r.size.height }));
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

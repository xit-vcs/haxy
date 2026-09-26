const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const hash = xit.hash;
const evt = @import("./event.zig");
const serve_common = @import("./serve_common.zig");
const ui = @import("./ui.zig");
const fork = @import("./fork.zig");
const pch = @import("./patch.zig");
const xitui = xit.xitui;
const wgt = xitui.widget;
const Focus = xitui.focus.Focus;
const Grid = xitui.grid.Grid;

const cookie_name = "haxy_session";
// the session cookie a login or a claimed auto-login sets; both must scope
// it the same way.
const session_cookie_fmt = cookie_name ++ "={s}; Path=/; HttpOnly; SameSite=Strict";
const form_flash_cookie = "haxy_form_flash";
const local_flash_cookie = "haxy_local_flash";
const local_required_title_prefix = "required_title:";
const local_sync_failure_prefix = "sync:";

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
pub const Host = union(evt.HostKind) {
    local: ui.RepoSource,
    server: struct {
        admin_repo_path: []const u8,
        session_store: SessionStore,
        git_http_port: ?u16,
        git_ssh_port: ?u16,
        git_ssh_prefix: []const u8,
    },
};

// an on-disk repo resolved from a request url. server paths are owned.
const RequestRepoSource = struct {
    source: ui.RepoSource,
    owned_path: ?[]const u8 = null,

    fn deinit(self: RequestRepoSource, allocator: std.mem.Allocator) void {
        if (self.owned_path) |path| allocator.free(path);
    }
};

fn requestRepoSource(io: std.Io, allocator: std.mem.Allocator, host: Host, repo_base: []const u8) !?RequestRepoSource {
    return switch (host) {
        .server => |server| blk: {
            const repo_prefix = "/repo/";
            if (!std.mem.startsWith(u8, repo_base, repo_prefix)) break :blk null;
            const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
            defer allocator.free(repos_dir);
            const path = switch (try serve_common.resolveRepoPath(io, allocator, repos_dir, server.admin_repo_path, repo_base[repo_prefix.len..], false)) {
                .ok => |value| value,
                .invalid, .not_found => break :blk null,
            };
            break :blk .{
                .source = .{ .path = path, .repo_kind = .xit },
                .owned_path = path,
            };
        },
        .local => |source| if (repo_base.len == 0) .{ .source = source } else null,
    };
}

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
            serve_common.logError(io, err, "web ui request failed: {s}\n", .{@errorName(request_err)});
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
    const owned_target = if (method == .POST) try allocator.dupe(u8, request.head.target) else null;
    defer if (owned_target) |target| allocator.free(target);
    const uri = try std.Uri.parseAfterScheme("", owned_target orelse request.head.target);
    const path = uri.path.percent_encoded;

    // POST routes can be scoped by any page, so they can redirect using
    // the base of the URL. this allows logging in to keep you on the page
    // you were on. local mode has no accounts, so only the repo routes.
    if (method == .POST) {
        switch (host) {
            .server => |server| {
                const PostRoute = enum { login, logout, ansi, new, edit, remove, open, close, resolve, publish, merge, squash, attach, undo, clear };
                inline for (@typeInfo(PostRoute).@"enum".fields) |field| {
                    const suffix = "/" ++ field.name;
                    if (std.mem.endsWith(u8, path, suffix)) {
                        const base = path[0 .. path.len - suffix.len];
                        return switch (@field(PostRoute, field.name)) {
                            .login => handleLogin(io, request, allocator, base, server.admin_repo_path, server.session_store),
                            .logout => handleLogout(request, base, server.session_store),
                            .ansi => handleAnsi(io, request, allocator, base, server.admin_repo_path, server.session_store),
                            .new => handleNew(io, request, allocator, base, host),
                            .edit => handleEdit(io, request, allocator, base, host),
                            .remove => handleRemove(io, request, allocator, base, host),
                            .open => handleThreadStatus(io, request, allocator, base, host, true),
                            .close => handleThreadStatus(io, request, allocator, base, host, false),
                            .resolve => handleThreadResolve(io, request, allocator, base, host),
                            .publish => handlePatchPublish(io, request, allocator, base, host),
                            .merge => handlePatchMerge(io, request, allocator, base, host, .source),
                            .squash => handlePatchMerge(io, request, allocator, base, host, .squash),
                            .undo => handleUndo(io, request, allocator, base, host, .undo),
                            .clear => handleUndo(io, request, allocator, base, host, .clear),
                            .attach => handleAttach(io, request, allocator, base, host),
                        };
                    }
                }
            },
            .local => |local| {
                const PostRoute = enum { new, edit, remove, open, close, resolve, sync, attach, undo, clear };
                inline for (@typeInfo(PostRoute).@"enum".fields) |field| {
                    const suffix = "/" ++ field.name;
                    if (std.mem.endsWith(u8, path, suffix)) {
                        const base = path[0 .. path.len - suffix.len];
                        return switch (@field(PostRoute, field.name)) {
                            .new => handleNew(io, request, allocator, base, host),
                            .edit => handleEdit(io, request, allocator, base, host),
                            .remove => handleRemove(io, request, allocator, base, host),
                            .open => handleThreadStatus(io, request, allocator, base, host, true),
                            .close => handleThreadStatus(io, request, allocator, base, host, false),
                            .resolve => handleThreadResolve(io, request, allocator, base, host),
                            .sync => handleSync(io, request, allocator, base, local),
                            .undo => handleUndo(io, request, allocator, base, host, .undo),
                            .clear => handleUndo(io, request, allocator, base, host, .clear),
                            .attach => handleAttach(io, request, allocator, base, host),
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

    // an attachment serves raw bytes rather than a page, so it is matched
    // before the routable pages
    if (attachmentRequest(path)) |attachment| return serveAttachment(io, request, allocator, attachment, host);

    const current_page_maybe = switch (host) {
        .server => ui.RoutablePage.fromUrl(path),
        .local => ui.RoutablePage.fromUrlLocal(path),
    };
    if (current_page_maybe) |current_page| {
        // resolve the haxy_session cookie's token to a user_id via the
        // store. user_id_buf lives on the stack for the rest of handleRequest,
        // which is plenty for renderIndexHtml to consume. local mode has no
        // accounts, so it is always logged out.
        var user_id_buf: [evt.event_id_size]u8 = undefined;
        var user_id: ?[]const u8 = null;
        // the session token that named the user, so a stale one can be revoked
        var token_buf: [SessionStore.token_hex_len]u8 = undefined;
        var session_token: ?[]const u8 = null;
        var form_arena = std.heap.ArenaAllocator.init(allocator);
        defer form_arena.deinit();
        var form_feedback: ?ui.Session.FormFeedback = null;
        var form_cookie_seen = false;
        var local_flash_seen = false;
        var sync_failure: ?[]const u8 = null;
        var sync_failure_allocated: ?[]u8 = null;
        defer if (sync_failure_allocated) |value| allocator.free(value);
        // backs the cookie a claimed auto-login sets
        var cookie_buf: [256]u8 = undefined;
        var session_cookie: ?[]const u8 = null;
        switch (host) {
            .server => |server| {
                user_id = blk: {
                    const token = getCookieValue(request, cookie_name) orelse break :blk null;
                    if (!server.session_store.lookup(token, &user_id_buf)) break :blk null;
                    session_token = token;
                    break :blk user_id_buf[0..evt.event_id_size];
                };
                // whoever seeded the store may have left a session to claim
                if (user_id == null) {
                    if (server.session_store.autoLogin(&token_buf) and server.session_store.lookup(&token_buf, &user_id_buf)) {
                        session_cookie = try std.fmt.bufPrint(&cookie_buf, session_cookie_fmt, .{token_buf});
                        session_token = &token_buf;
                        user_id = user_id_buf[0..evt.event_id_size];
                    }
                }
                if (getCookieValue(request, form_flash_cookie)) |token| {
                    form_cookie_seen = true;
                    form_feedback = server.session_store.takeFlash(form_arena.allocator(), token);
                }
            },
            .local => {
                if (getCookieValue(request, local_flash_cookie)) |raw| {
                    local_flash_seen = true;
                    if (std.mem.startsWith(u8, raw, local_required_title_prefix)) {
                        const tag = std.meta.stringToEnum(std.meta.Tag(ui.Session.FormFeedback), raw[local_required_title_prefix.len..]);
                        form_feedback = if (tag) |feedback_tag| switch (feedback_tag) {
                            .issue => .{ .issue = .{ .failure = .required_title } },
                            .patch => .{ .patch = .{ .failure = .required_title } },
                            .discussion => .{ .discussion = .{ .failure = .required_title } },
                            else => null,
                        } else null;
                    } else if (std.mem.startsWith(u8, raw, local_sync_failure_prefix)) {
                        const value = try allocator.dupe(u8, raw[local_sync_failure_prefix.len..]);
                        sync_failure_allocated = value;
                        sync_failure = std.Uri.percentDecodeInPlace(value);
                    }
                }
            },
        }

        const git_http_port: ?u16, const git_ssh_port: ?u16, const git_ssh_prefix: []const u8 = switch (host) {
            .server => |server| .{ server.git_http_port, server.git_ssh_port, server.git_ssh_prefix },
            .local => .{ null, null, "" },
        };
        const html = renderIndexHtml(io, allocator, host, session_token, .{
            .user_id = user_id,
            .form_feedback = form_feedback,
            .sync_failure = sync_failure,
            .current_page = current_page,
            .host_kind = std.meta.activeTag(host),
            .git_http_port = git_http_port,
            .git_ssh_port = git_ssh_port,
            .git_ssh_prefix = git_ssh_prefix,
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

        const expired_form_cookie = if (form_cookie_seen)
            try std.fmt.allocPrint(allocator, form_flash_cookie ++ "=; Path={s}; Max-Age=0", .{path})
        else
            null;
        defer if (expired_form_cookie) |cookie| allocator.free(cookie);
        var header_buf: [4]std.http.Header = undefined;
        var headers: std.ArrayList(std.http.Header) = .initBuffer(&header_buf);
        headers.appendAssumeCapacity(.{ .name = "content-type", .value = "text/html; charset=utf-8" });
        if (expired_form_cookie) |cookie| headers.appendAssumeCapacity(.{ .name = "set-cookie", .value = cookie });
        if (local_flash_seen) headers.appendAssumeCapacity(.{ .name = "set-cookie", .value = local_flash_cookie ++ "=; Path=/; Max-Age=0" });
        if (session_cookie) |cookie| headers.appendAssumeCapacity(.{ .name = "set-cookie", .value = cookie });
        try request.respond(html, .{ .extra_headers = headers.items });
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
    const body = try readFormBody(request, allocator);
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
            const cookie = try std.fmt.bufPrint(&cookie_buf, session_cookie_fmt, .{token});
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = success_location },
                    .{ .name = "set-cookie", .value = cookie },
                },
            });
        },
        .unknown_user => try respondFormFailure(request, allocator, session_store, failure_location, .{ .login = .{ .failure = .unknown_user, .username = username } }),
        .wrong_password => try respondFormFailure(request, allocator, session_store, failure_location, .{ .login = .{ .failure = .wrong_password, .username = username } }),
    }
}

fn respondFormFailure(request: *std.http.Server.Request, allocator: std.mem.Allocator, session_store: SessionStore, location: []const u8, feedback: ui.Session.FormFeedback) !void {
    const token = try session_store.createFlash(allocator, feedback);
    const cookie = try std.fmt.allocPrint(allocator, form_flash_cookie ++ "={s}; Path={s}; HttpOnly; SameSite=Strict", .{ token, location });
    defer allocator.free(cookie);
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
            .{ .name = "set-cookie", .value = cookie },
        },
    });
}

fn respondThreadFormFailure(request: *std.http.Server.Request, allocator: std.mem.Allocator, host: Host, location: []const u8, feedback: ui.Session.FormFeedback) !void {
    return switch (host) {
        .server => |server| respondFormFailure(request, allocator, server.session_store, location, feedback),
        .local => {
            const tag = std.meta.activeTag(feedback);
            const required_title = switch (feedback) {
                .issue => |value| value.failure == .required_title,
                .discussion => |value| value.failure == .required_title,
                .patch => |value| value.failure == .required_title,
                else => false,
            };
            if (!required_title) return error.InvalidFormFeedback;
            const cookie = try std.fmt.allocPrint(allocator, local_flash_cookie ++ "=" ++ local_required_title_prefix ++ "{s}; Path=/; HttpOnly; SameSite=Strict", .{@tagName(tag)});
            defer allocator.free(cookie);
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{
                    .{ .name = "location", .value = location },
                    .{ .name = "set-cookie", .value = cookie },
                },
            });
        },
    };
}

fn requiredTitleFeedback(kind: evt.EventKind, title: []const u8, labels: []const u8, description: []const u8, target_branch: []const u8, source_branch: ?[]const u8) ui.Session.FormFeedback {
    return switch (kind) {
        .issue => .{ .issue = .{ .failure = .required_title, .fields = .{
            .title = title,
            .labels = labels,
            .description = description,
        } } },
        .patch => patchFeedback(.required_title, title, labels, description, target_branch, source_branch),
        .discuss => .{ .discussion = .{ .failure = .required_title, .fields = .{
            .title = title,
            .labels = labels,
            .description = description,
        } } },
        else => unreachable,
    };
}

fn patchFeedback(failure: ui.Session.FormFeedback.PatchFailure, title: []const u8, labels: []const u8, description: []const u8, target_branch: []const u8, source_branch: ?[]const u8) ui.Session.FormFeedback {
    return .{ .patch = .{ .failure = failure, .fields = .{
        .title = title,
        .labels = labels,
        .description = description,
        .target_branch = target_branch,
        .source_branch = source_branch orelse "",
        .source_kind = if (source_branch != null) .branch else .fork,
    } } };
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
    // the toggle re-emits the user's own event, so it takes a logged-in user
    var user_id: [evt.event_id_size]u8 = undefined;
    const token = getCookieValue(request, cookie_name) orelse return respondLoginRequired(request);
    if (!session_store.lookup(token, &user_id)) return respondLoginRequired(request);

    {
        const Repo = rp.Repo(.xit, evt.admin_repo_opts);
        var repo = try Repo.open(io, allocator, .{ .path = admin_repo_path });
        defer repo.deinit(io, allocator);

        try evt.User.toggleAnsi(evt.admin_repo_opts, io, allocator, &repo, &user_id);
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

// the actor for a write to the repo `repo_base` names with at least `min_role`,
// or null once the refusal has been sent. local mode always writes.
fn authorizeWrite(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    request: *std.http.Server.Request,
    host: Host,
    repo_base: []const u8,
    min_role: evt.Repo.Role,
) !?ui.Actor {
    const server = switch (host) {
        .server => |server| server,
        .local => |src| return .{ .author = try ui.localAuthor(src, io, allocator, arena), .role = .owner },
    };
    const authorization: ui.Authorization = blk: {
        const user_id = requestUserId(request, server.session_store) orelse break :blk .login_required;

        const repo_prefix = "/repo/";
        if (!std.mem.startsWith(u8, repo_base, repo_prefix)) break :blk .repo_not_found;

        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
        break :blk try ui.authorizeUser(moment, arena, user_id, repo_base[repo_prefix.len..], min_role);
    };
    switch (authorization) {
        .actor => |actor| return actor,
        .login_required => try respondLoginRequired(request),
        .repo_not_found => try respondRepoNotFound(request),
        .forbidden => try respondForbidden(request),
    }
    return null;
}

// whether the request may read the repo `repo_base` names. local mode always
// may.
fn mayRead(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    host: Host,
    repo_base: []const u8,
) !bool {
    const server = switch (host) {
        .server => |server| server,
        .local => return true,
    };
    const repo_prefix = "/repo/";
    if (!std.mem.startsWith(u8, repo_base, repo_prefix)) return false;

    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    const user_id = blk: {
        const id = requestUserId(request, server.session_store) orelse break :blk null;
        break :blk if (try ui.activeUser(moment, &arena, id) != null) id else null;
    };
    const role = (try ui.repoRole(moment, &arena, user_id, repo_base[repo_prefix.len..])) orelse return false;
    return role != .none;
}

// the logged-in user the request's session cookie names
fn requestUserId(request: *std.http.Server.Request, session_store: SessionStore) ?[evt.event_id_size]u8 {
    const token = getCookieValue(request, cookie_name) orelse return null;
    var user_id: [evt.event_id_size]u8 = undefined;
    return if (session_store.lookup(token, &user_id)) user_id else null;
}

// refuse a write from a request with no logged-in user. the body goes unread,
// so the connection closes.
fn respondLoginRequired(request: *std.http.Server.Request) !void {
    try request.respond("log in to make changes", .{
        .status = .forbidden,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

// refuse a write the user's role in the repo doesn't allow
fn respondForbidden(request: *std.http.Server.Request) !void {
    try request.respond("you don't have permission to do that", .{
        .status = .forbidden,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn respondRepoNotFound(request: *std.http.Server.Request) !void {
    try request.respond("repo not found", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

// new actions share a suffix; the base identifies whether the form creates a
// thread or comment.
fn handleNew(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    if (commentBaseParts(base) != null) return handleCommentNew(io, request, allocator, base, host);

    const issues_suffix = "/issues";
    if (std.mem.endsWith(u8, base, issues_suffix))
        return handleThreadNew(io, request, allocator, base[0 .. base.len - issues_suffix.len], host, .issue);
    const discussions_suffix = "/discussions";
    if (std.mem.endsWith(u8, base, discussions_suffix))
        return handleThreadNew(io, request, allocator, base[0 .. base.len - discussions_suffix.len], host, .discuss);
    const patches_suffix = "/patches";
    if (std.mem.endsWith(u8, base, patches_suffix))
        return handleThreadNew(io, request, allocator, base[0 .. base.len - patches_suffix.len], host, .patch);

    try request.respond("new event target not found", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

// create a thread in the repo the form's page names and redirect to it.
fn handleThreadNew(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    kind: evt.EventKind,
) !void {
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, base, .read)) orelse return;
    const author = actor.author;
    const body = try readFormBody(request, allocator);
    defer allocator.free(body);

    const title = (try parseFormField(allocator, body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title);
    const labels = (try parseFormField(allocator, body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels);
    const description_crlf = (try parseFormField(allocator, body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_crlf);
    // form submission normalizes textarea line breaks to CRLF; store plain
    // newlines so the text renders the same on every host
    const description = try std.mem.replaceOwned(u8, allocator, description_crlf, "\r\n", "\n");
    defer allocator.free(description);
    const target_branch = (try parseFormField(allocator, body, "target_branch")) orelse try allocator.dupe(u8, "");
    defer allocator.free(target_branch);

    const source_branch = if (kind == .patch) try parseFormField(allocator, body, "source_branch") else null;
    defer if (source_branch) |branch| allocator.free(branch);

    const valid = switch (kind) {
        .issue => evt.Issue.fieldsValid(title, labels),
        .patch => evt.Patch.fieldsValid(title, labels),
        .discuss => evt.Discussion.fieldsValid(title, labels),
        else => unreachable,
    };
    if (!valid) {
        const list_name: []const u8 = switch (kind) {
            .issue => "issues",
            .patch => "patches",
            .discuss => "discussions",
            else => unreachable,
        };
        const form_location = try std.fmt.allocPrint(allocator, "{s}/{s}/new", .{ base, list_name });
        defer allocator.free(form_location);
        if (!evt.titleValid(title)) {
            return respondThreadFormFailure(request, allocator, host, form_location, requiredTitleFeedback(kind, title, labels, description, target_branch, source_branch));
        }
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    const not_found = "repo not found";
    const request_repo = (try requestRepoSource(io, allocator, host, base)) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    if (kind == .patch and source_branch == null) {
        const server = switch (host) {
            .server => |server| server,
            .local => return respondRemoveNotFound(request),
        };
        const user_id = actor.user_id orelse return respondLoginRequired(request);
        if (!evt.Patch.branchValid(target_branch) or !try request_repo.source.hasBranch(io, allocator, target_branch)) {
            const form_location = try std.fmt.allocPrint(allocator, "{s}/patches/new", .{base});
            defer allocator.free(form_location);
            return respondThreadFormFailure(request, allocator, host, form_location, patchFeedback(.invalid_target_branch, title, labels, description, target_branch, null));
        }
        const repo_id = evt.parseEventId(std.fs.path.basename(request_repo.source.path)) catch return respondRemoveNotFound(request);
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
        defer allocator.free(repos_dir);
        const fork_path = try fork.create(.{}, io, allocator, repos_dir, &admin_repo, .{
            .id = event_id_hex,
            .user_id = user_id,
            .repo_id = repo_id,
            .title = title,
            .description = description,
            .labels = labels,
            .target_branch = target_branch,
            .author = author,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        });
        defer allocator.free(fork_path);
    } else {
        const event = evt.EventWithId{
            .id = event_id_hex,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
            .author = author,
            .event = switch (kind) {
                .issue => .{ .issue = .{ .title = title, .description = description, .labels = labels } },
                .patch => .{ .patch = .{ .title = title, .description = description, .labels = labels, .target_branch = target_branch, .source_branch = source_branch } },
                .discuss => .{ .discuss = .{ .title = title, .description = description, .labels = labels } },
                else => unreachable,
            },
        };

        switch (source.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
                defer any_repo.deinit(io, allocator);
                switch (any_repo) {
                    inline else => |*repo| {
                        const result = if (kind == .patch)
                            pch.writeBranchPatch(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, event_id_hex, event.event.patch orelse unreachable, null, author)
                        else
                            evt.consume(std.meta.activeTag(host), .repo, repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{event});
                        result catch |err| {
                            if (kind != .patch) return err;
                            const failure = ui.Session.FormFeedback.PatchFailure.fromError(err) orelse return err;
                            const form_location = try std.fmt.allocPrint(allocator, "{s}/patches/new", .{base});
                            defer allocator.free(form_location);
                            return respondThreadFormFailure(request, allocator, host, form_location, patchFeedback(failure, title, labels, description, target_branch, source_branch));
                        };
                    },
                }
            },
        }
    }

    const location = try std.fmt.allocPrint(allocator, "{s}/{s}:{s}", .{ base, @tagName(kind), &event_id_hex });
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

const CommentBaseParts = struct {
    repo_base: []const u8,
    thread_kind: evt.EventKind,
    thread_id: [evt.event_id_size]u8,
    comment_id: ?[evt.event_id_size]u8,
};

fn commentBaseParts(base: []const u8) ?CommentBaseParts {
    const route = ui.RoutablePage.fromUrl(base) orelse ui.RoutablePage.fromUrlLocal(base) orelse return null;
    const identity, const thread_kind, const thread_hex, const comment_hex = switch (route) {
        .repo_issues => |*issue| .{ issue.name.slice(), evt.EventKind.issue, issue.selected.slice(), issue.comment.slice() },
        .repo_patches => |*patch| .{ patch.name.slice(), evt.EventKind.patch, patch.selected.slice(), patch.comment.slice() },
        .repo_discussions => |*discussion| .{ discussion.name.slice(), evt.EventKind.discuss, discussion.selected.slice(), discussion.comment.slice() },
        else => return null,
    };
    const thread_id = evt.parseEventId(thread_hex) catch return null;
    const comment_id = if (comment_hex.len == 0) null else evt.parseEventId(comment_hex) catch return null;
    const repo_base_len = if (identity.len == 0) 0 else "/repo/".len + identity.len;
    return .{ .repo_base = base[0..repo_base_len], .thread_kind = thread_kind, .thread_id = thread_id, .comment_id = comment_id };
}

fn handlePatchPublish(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const parts = commentBaseParts(base) orelse return respondRemoveNotFound(request);
    if (parts.thread_kind != .patch or parts.comment_id != null) return respondRemoveNotFound(request);
    const server = switch (host) {
        .server => |server| server,
        .local => return respondRemoveNotFound(request),
    };
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    // only the draft's author may publish it, which publish checks
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const user_id = actor.user_id orelse return respondLoginRequired(request);
    const author = actor.author;

    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
    defer request_repo.deinit(allocator);
    const repo_id = evt.parseEventId(std.fs.path.basename(request_repo.source.path)) catch return respondRemoveNotFound(request);
    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, request_repo.source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const id = std.fmt.bytesToHex(parts.thread_id, .lower);
    const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
    defer allocator.free(repos_dir);
    const fork_path = try fork.forkPath(allocator, repos_dir, &id);
    defer allocator.free(fork_path);
    try pch.publish(.{}, io, allocator, &admin_repo, &target_repo, fork_path, .{
        .id = id,
        .user_id = user_id,
        .repo_id = repo_id,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = base }},
    });
}

fn handlePatchMerge(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    revision: evt.Patch.MergeRevision,
) !void {
    const parts = commentBaseParts(base) orelse return respondRemoveNotFound(request);
    if (parts.thread_kind != .patch or parts.comment_id != null) return respondRemoveNotFound(request);
    const server = switch (host) {
        .server => |server| server,
        .local => return respondRemoveNotFound(request),
    };
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const author = ((try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .write)) orelse return).author;

    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
    defer request_repo.deinit(allocator);
    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, request_repo.source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);

    const id = std.fmt.bytesToHex(parts.thread_id, .lower);
    const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
    defer allocator.free(repos_dir);
    pch.mergeAndRemoveFork(.{}, io, allocator, repos_dir, &admin_repo, &target_repo, .{
        .id = id,
        .revision = revision,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    }) catch |err| switch (err) {
        error.MergeConflict => return request.respond("merge conflict", .{
            .status = .conflict,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        }),
        error.MergeCheckUnavailable, error.PatchOutOfDate, error.PatchDataUnavailable => {},
        else => return err,
    };

    const location = try std.fmt.allocPrint(allocator, "{s}/patch:{s}", .{ parts.repo_base, &id });
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

// create a reply and redirect to its permalink.
fn handleCommentNew(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const not_found = "comment parent not found";
    const parts = commentBaseParts(base) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const author = ((try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return).author;

    const form_body = try readFormBody(request, allocator);
    defer allocator.free(form_body);
    const body_crlf = (try parseFormField(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_crlf);
    const body = try std.mem.replaceOwned(u8, allocator, body_crlf, "\r\n", "\n");
    defer allocator.free(body);

    if (!evt.Comment.fieldsValid(body)) {
        const form_location = try std.fmt.allocPrint(allocator, "{s}/new", .{base});
        defer allocator.free(form_location);
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    const thread_id_hex = std.fmt.bytesToHex(parts.thread_id, .lower);
    const parent_id_hex = std.fmt.bytesToHex(parts.comment_id orelse parts.thread_id, .lower);

    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    var event_id_hex: [evt.event_id_size * 2]u8 = undefined;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| event_id_hex = try evt.Comment.create(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, &thread_id_hex, &parent_id_hex, body, author),
            }
        },
    }

    const location = try std.fmt.allocPrint(allocator, "{s}/{s}:{s}/comment:{s}", .{ parts.repo_base, @tagName(parts.thread_kind), &thread_id_hex, &event_id_hex });
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

const AttachmentRequest = struct {
    repo_base: []const u8,
    id: [evt.event_id_size]u8,
};

// an attachment url is its repo's base and the attachment's event id
fn attachmentRequest(path: []const u8) ?AttachmentRequest {
    const infix = "/attachment:";
    const at = std.mem.lastIndexOf(u8, path, infix) orelse return null;
    const tail = path[at + infix.len ..];
    const id = evt.parseEventId(tail) catch return null;
    return .{ .repo_base = path[0..at], .id = id };
}

// serve an attachment's bytes from the repo its url names
fn serveAttachment(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    attachment: AttachmentRequest,
    host: Host,
) !void {
    if (!try mayRead(io, allocator, request, host, attachment.repo_base)) return respondAttachmentNotFound(request);
    const request_repo = (try requestRepoSource(io, allocator, host, attachment.repo_base)) orelse return respondAttachmentNotFound(request);
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try sendAttachment(repo_kind, repo.self_repo_opts, io, request, allocator, repo, &attachment.id),
            }
        },
    }
}

fn sendAttachment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const DB = evt.EventDB(repo_opts.hash);
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return respondAttachmentNotFound(request)
    else
        evt.currentMoment(repo_opts, repo)) catch return respondAttachmentNotFound(request);

    const record = (try evt.Attachment.readById(DB, repo_opts.hash, haxy_moment, &arena, id)) orelse return respondAttachmentNotFound(request);
    if (record.removed) return respondAttachmentNotFound(request);
    if (record.blob_oid.len != hash.hexLen(repo_opts.hash)) return respondAttachmentNotFound(request);
    const blob_oid: *const [hash.hexLen(repo_opts.hash)]u8 = @ptrCast(record.blob_oid.ptr);

    var moment = repo.core.latestMoment() catch return respondAttachmentNotFound(request);
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object_reader = obj.ObjectReader(repo_kind, repo_opts).init(state, io, allocator, blob_oid) catch return respondAttachmentNotFound(request);
    defer object_reader.deinit();
    if (object_reader.header().kind != .blob) return respondAttachmentNotFound(request);

    const content_type = attachmentContentType(record.name);
    const encoded_name = try ui.urlEncodeRef(allocator, record.name);
    defer allocator.free(encoded_name);
    const disposition = try std.fmt.allocPrint(allocator, "{s}; filename*=UTF-8''{s}", .{ if (content_type == null) "attachment" else "inline", encoded_name });
    defer allocator.free(disposition);

    var send_buf: [8192]u8 = undefined;
    var body = try request.respondStreaming(&send_buf, .{
        .content_length = object_reader.header().size,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type orelse "application/octet-stream" },
                .{ .name = "content-disposition", .value = disposition },
                // uploaded bytes are never sniffed into a type that could run
                // as script on this origin
                .{ .name = "x-content-type-options", .value = "nosniff" },
            },
        },
    });
    _ = try object_reader.interface.streamRemaining(&body.writer);
    try body.end();
}

// the images a browser renders safely inline. anything else downloads as
// opaque bytes, so an uploaded page can't run on this origin.
fn attachmentContentType(name: []const u8) ?[]const u8 {
    const types = [_]struct { ext: []const u8, value: []const u8 }{
        .{ .ext = ".png", .value = "image/png" },
        .{ .ext = ".jpg", .value = "image/jpeg" },
        .{ .ext = ".jpeg", .value = "image/jpeg" },
        .{ .ext = ".gif", .value = "image/gif" },
        .{ .ext = ".webp", .value = "image/webp" },
    };
    for (types) |entry| {
        if (name.len > entry.ext.len and std.ascii.eqlIgnoreCase(name[name.len - entry.ext.len ..], entry.ext)) return entry.value;
    }
    return null;
}

fn respondAttachmentNotFound(request: *std.http.Server.Request) !void {
    try request.respond("attachment not found", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn respondAttachmentParentNotFound(request: *std.http.Server.Request) !void {
    try request.respond("attachment parent not found", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

// the upload declares its file's name here, since the body is the file itself
const attachment_name_header = "x-attachment-name";

const AttachParentParts = struct {
    repo_base: []const u8,
    kind: evt.EventKind,
    id_bytes: [evt.event_id_size]u8,
};

// what an attachment hangs off: the `<kind>:<id>` segment the form's page ends
// with, whatever kind that is
fn attachParentParts(base: []const u8) ?AttachParentParts {
    const segment_at = std.mem.lastIndexOfScalar(u8, base, '/') orelse return null;
    const segment = base[segment_at + 1 ..];
    const colon_at = std.mem.lastIndexOfScalar(u8, segment, ':') orelse return null;
    const kind = std.meta.stringToEnum(evt.EventKind, segment[0..colon_at]) orelse return null;
    const id_bytes = evt.parseEventId(segment[colon_at + 1 ..]) catch return null;
    return .{ .repo_base = base[0..segment_at], .kind = kind, .id_bytes = id_bytes };
}

// attach the uploaded file to the event the url names, then reload. the file is
// the whole request body, so it streams from the socket into the object store
// without being buffered.
fn handleAttach(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const parts = attachParentParts(base) orelse return respondAttachmentParentNotFound(request);

    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const author = actor.author;
    // an attachment changes the event it hangs off
    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondAttachmentParentNotFound(request);
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    if (!try source.canModify(io, allocator, actor, parts.kind, &parts.id_bytes)) return respondForbidden(request);

    const name = (try attachmentName(allocator, request)) orelse return respondUploadError(request, .bad_request, "attachment needs a name");
    defer allocator.free(name);
    if (!evt.Attachment.nameValid(name)) return respondUploadError(request, .bad_request, "invalid attachment name");

    const size = request.head.content_length orelse return respondUploadError(request, .length_required, "attachments must declare a content length");
    if (size == 0) return respondUploadError(request, .bad_request, "attachment is empty");
    if (size > evt.Attachment.max_size) return respondUploadError(request, .payload_too_large, "attachment is too large");

    const parent_id_hex = std.fmt.bytesToHex(parts.id_bytes, .lower);

    var body_buf: [4096]u8 = undefined;
    const blob: evt.Blob = .{ .name = name, .size = size, .reader = try request.readerExpectContinue(&body_buf) };

    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| _ = evt.Attachment.create(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, &parent_id_hex, blob, author) catch |err| switch (err) {
                    error.ParentNotFound => return respondAttachmentParentNotFound(request),
                    else => return err,
                },
            }
        },
    }

    // the client reloads the page itself
    try request.respond("", .{ .status = .no_content, .keep_alive = false });
}

// the name the upload declares for its file, percent-encoded so it survives a
// header
fn attachmentName(allocator: std.mem.Allocator, request: *std.http.Server.Request) !?[]u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, attachment_name_header)) continue;
        return try decodeFormValue(allocator, header.value);
    }
    return null;
}

// an upload that failed leaves the body partly read, so the connection closes
fn respondUploadError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    try request.respond(message, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

// re-emit the comment `parts` names with a new body, in the repo the host
// resolves the base to.
fn updateComment(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    parts: CommentBaseParts,
    body: []const u8,
    author: evt.CommitAuthor,
) !void {
    const comment_id = parts.comment_id orelse return error.NotFound;
    const thread_id = std.fmt.bytesToHex(parts.thread_id, .lower);
    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return error.NotFound;
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try evt.Comment.update(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, &thread_id, &comment_id, body, author),
            }
        },
    }
}

// edit actions share a suffix; the base identifies the event being edited.
fn handleEdit(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const parts = commentBaseParts(base) orelse return respondRemoveNotFound(request);
    if (parts.comment_id != null) return handleCommentEdit(io, request, allocator, base, host, parts);
    return handleThreadEdit(io, request, allocator, base, host, parts);
}

// replace the body of the comment the url names, then redirect to its
// permalink.
fn handleCommentEdit(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    parts: CommentBaseParts,
) !void {
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const author = actor.author;
    // edits only reach here for a comment
    const comment_id = parts.comment_id orelse unreachable;
    {
        const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
        defer request_repo.deinit(allocator);
        if (!try request_repo.source.canModify(io, allocator, actor, .comment, &comment_id)) return respondForbidden(request);
    }

    const form_body = try readFormBody(request, allocator);
    defer allocator.free(form_body);
    const body_crlf = (try parseFormField(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_crlf);
    const body = try std.mem.replaceOwned(u8, allocator, body_crlf, "\r\n", "\n");
    defer allocator.free(body);

    if (!evt.Comment.fieldsValid(body)) {
        const form_location = try std.fmt.allocPrint(allocator, "{s}/edit", .{base});
        defer allocator.free(form_location);
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    const not_found = "comment not found";
    updateComment(io, allocator, host, parts, body, author) catch |err| switch (err) {
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

fn updateThread(
    comptime Event: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    repo_base: []const u8,
    id: *const [evt.event_id_size]u8,
    update: Event.Update,
    author: evt.CommitAuthor,
) !void {
    const request_repo = (try requestRepoSource(io, allocator, host, repo_base)) orelse return error.NotFound;
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try Event.update(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, id, update, author),
            }
        },
    }
}

const RemoveParts = struct {
    repo_base: []const u8,
    kind: evt.EventKind,
    id: [evt.event_id_size]u8,
};

// split a remove url into the repo and event it names
fn removeParts(base: []const u8) ?RemoveParts {
    if (attachmentRequest(base)) |attachment| {
        const parent = attachParentParts(attachment.repo_base) orelse return null;
        return .{
            .repo_base = parent.repo_base,
            .kind = .attach,
            .id = attachment.id,
        };
    }
    if (commentBaseParts(base)) |thread| return .{
        .repo_base = thread.repo_base,
        .kind = if (thread.comment_id != null) .comment else thread.thread_kind,
        .id = thread.comment_id orelse thread.thread_id,
    };
    return null;
}

// remove the event named by the form's url
fn handleRemove(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const parts = removeParts(base) orelse return respondRemoveNotFound(request);

    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const author = actor.author;

    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
    defer request_repo.deinit(allocator);
    const source = request_repo.source;

    if (parts.kind == .patch) switch (host) {
        .server => |server| {
            const user_id = actor.user_id orelse return respondLoginRequired(request);

            var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
            defer admin_repo.deinit(io, allocator);
            const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
            const record = try evt.Fork.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &author_arena, &parts.id);
            if (record) |fork_record| {
                const repo_id = evt.parseEventId(std.fs.path.basename(source.path)) catch return respondRemoveNotFound(request);
                if (!fork_record.removed and fork_record.event.stage == .draft and std.mem.eql(u8, fork_record.event.repo_id, &repo_id)) {
                    const id = std.fmt.bytesToHex(parts.id, .lower);
                    const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
                    defer allocator.free(repos_dir);
                    try fork.remove(io, allocator, repos_dir, &admin_repo, &id, &user_id, author);

                    const location = try std.fmt.allocPrint(allocator, "{s}/patches/drafts", .{parts.repo_base});
                    defer allocator.free(location);
                    try request.respond("", .{
                        .status = .see_other,
                        .keep_alive = false,
                        .extra_headers = &.{.{ .name = "location", .value = location }},
                    });
                    return;
                }
            }
        },
        .local => {},
    };

    // a draft is its author's alone, which its removal above checks
    if (!try source.canModify(io, allocator, actor, parts.kind, &parts.id)) return respondForbidden(request);

    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| evt.remove(std.meta.activeTag(host), .repo, repo_kind, repo.self_repo_opts, io, allocator, repo, &parts.id, parts.kind, author) catch |err| switch (err) {
                    error.EventNotFound => return respondRemoveNotFound(request),
                    else => |e| return e,
                },
            }
        },
    }

    const id = std.fmt.bytesToHex(parts.id, .lower);
    const location = try std.fmt.allocPrint(allocator, "{s}/event:{s}/kind:{s}", .{ parts.repo_base, &id, @tagName(parts.kind) });
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

fn respondRemoveNotFound(request: *std.http.Server.Request) !void {
    try request.respond("event not found", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn updateDiscussion(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    repo_base: []const u8,
    id: *const [evt.event_id_size]u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    author: evt.CommitAuthor,
) !void {
    const request_repo = (try requestRepoSource(io, allocator, host, repo_base)) orelse return error.NotFound;
    defer request_repo.deinit(allocator);
    const source = request_repo.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try evt.Discussion.update(std.meta.activeTag(host), repo_kind, repo.self_repo_opts, io, allocator, repo, id, title, labels, description, author),
            }
        },
    }
}

// set the status of the issue the url names (base is
// "/repo/<owner>/<name>/issue:<id>", identity elided in local mode) by
// re-emitting its event, then redirect back to it
fn handleThreadStatus(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    open: bool,
) !void {
    const not_found = "thread not found";
    const parts = commentBaseParts(base) orelse {
        try request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const author = actor.author;
    {
        const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
        defer request_repo.deinit(allocator);
        if (!try request_repo.source.canModify(io, allocator, actor, parts.thread_kind, &parts.thread_id)) return respondForbidden(request);
    }

    (switch (parts.thread_kind) {
        .issue => updateThread(evt.Issue, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .status = if (open) .open else .closed }, author),
        .patch => updateThread(evt.Patch, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .status = if (open) .open else .closed }, author),
        else => return respondRemoveNotFound(request),
    }) catch |err| switch (err) {
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

// replace a thread's editable fields.
fn handleThreadEdit(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
    parts: CommentBaseParts,
) !void {
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const actor = (try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .read)) orelse return;
    const author = actor.author;

    const body = try readFormBody(request, allocator);
    defer allocator.free(body);

    const title = (try parseFormField(allocator, body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title);
    const labels = (try parseFormField(allocator, body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels);
    const description_crlf = (try parseFormField(allocator, body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_crlf);
    // form submission normalizes textarea line breaks to CRLF; store plain
    // newlines so the text renders the same on every host
    const description = try std.mem.replaceOwned(u8, allocator, description_crlf, "\r\n", "\n");
    defer allocator.free(description);
    const target_branch = (try parseFormField(allocator, body, "target_branch")) orelse try allocator.dupe(u8, "");
    defer allocator.free(target_branch);

    // invalid fields send the user back to the edit form
    const valid = switch (parts.thread_kind) {
        .issue => evt.Issue.fieldsValid(title, labels),
        .patch => evt.Patch.fieldsValid(title, labels),
        .discuss => evt.Discussion.fieldsValid(title, labels),
        else => unreachable,
    };
    if (!valid) {
        const form_location = try std.fmt.allocPrint(allocator, "{s}/edit", .{base});
        defer allocator.free(form_location);
        if (!evt.titleValid(title)) {
            return respondThreadFormFailure(request, allocator, host, form_location, requiredTitleFeedback(parts.thread_kind, title, labels, description, target_branch, null));
        }
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{ .name = "location", .value = form_location }},
        });
        return;
    }

    const request_repo = (try requestRepoSource(io, allocator, host, parts.repo_base)) orelse return respondRemoveNotFound(request);
    defer request_repo.deinit(allocator);

    const draft_user_id = if (parts.thread_kind == .patch) actor.user_id else null;
    if (draft_user_id) |user_id| {
        const server = switch (host) {
            .server => |server| server,
            .local => unreachable,
        };
        if (!evt.Patch.branchValid(target_branch) or !try request_repo.source.hasBranch(io, allocator, target_branch)) {
            const form_location = try std.fmt.allocPrint(allocator, "{s}/edit", .{base});
            defer allocator.free(form_location);
            return respondThreadFormFailure(request, allocator, host, form_location, patchFeedback(.invalid_target_branch, title, labels, description, target_branch, null));
        }
        const repo_id = evt.parseEventId(std.fs.path.basename(request_repo.source.path)) catch return respondRemoveNotFound(request);
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        const id = std.fmt.bytesToHex(parts.thread_id, .lower);
        const repos_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
        defer allocator.free(repos_dir);
        const fork_path = try fork.forkPath(allocator, repos_dir, &id);
        defer allocator.free(fork_path);
        if (try pch.editDraft(.{}, io, allocator, &admin_repo, fork_path, .{
            .id = id,
            .user_id = user_id,
            .repo_id = repo_id,
            .title = title,
            .labels = labels,
            .description = description,
            .target_branch = target_branch,
            .author = author,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        })) {
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{.{ .name = "location", .value = base }},
            });
            return;
        }
    }

    // a draft is its author's alone, which its edit above checks
    if (!try request_repo.source.canModify(io, allocator, actor, parts.thread_kind, &parts.thread_id)) return respondForbidden(request);

    const not_found = switch (parts.thread_kind) {
        .issue => "issue not found",
        .patch => "patch not found",
        .discuss => "discussion not found",
        else => unreachable,
    };
    (switch (parts.thread_kind) {
        .issue => updateThread(evt.Issue, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .fields = .{
            .title = title,
            .labels = labels,
            .description = description,
        } }, author),
        .patch => updateThread(evt.Patch, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .fields = .{
            .title = title,
            .labels = labels,
            .description = description,
            .target_branch = target_branch,
        } }, author),
        .discuss => updateDiscussion(io, allocator, host, parts.repo_base, &parts.thread_id, title, labels, description, author),
        else => unreachable,
    }) catch |err| switch (err) {
        error.NotFound => {
            try request.respond(not_found, .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            });
            return;
        },
        else => {
            if (parts.thread_kind != .patch) return err;
            const failure = ui.Session.FormFeedback.PatchFailure.fromError(err) orelse return err;
            const form_location = try std.fmt.allocPrint(allocator, "{s}/edit", .{base});
            defer allocator.free(form_location);
            return respondThreadFormFailure(request, allocator, host, form_location, patchFeedback(failure, title, labels, description, target_branch, null));
        },
    };

    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = base }},
    });
}

// resolve every conflicted field of the thread the url names
fn handleThreadResolve(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    host: Host,
) !void {
    const parts = commentBaseParts(base) orelse {
        try request.respond("thread not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };

    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const author = ((try authorizeWrite(io, allocator, &author_arena, request, host, parts.repo_base, .write)) orelse return).author;

    const body = try readFormBody(request, allocator);
    defer allocator.free(body);

    var field_arena = std.heap.ArenaAllocator.init(allocator);
    defer field_arena.deinit();
    const aa = field_arena.allocator();
    const title = try parseFormField(aa, body, "title");
    const labels = try parseFormField(aa, body, "labels");

    // the hunk inputs are submitted as d0, d1, ...; form submission normalizes their
    // textarea line breaks to CRLF
    var hunks: std.ArrayList([]const u8) = .empty;
    var hunk_index: usize = 0;
    while (true) : (hunk_index += 1) {
        const name = try std.fmt.allocPrint(aa, "d{d}", .{hunk_index});
        const submitted = (try parseFormField(aa, body, name)) orelse break;
        try hunks.append(aa, try std.mem.replaceOwned(u8, aa, submitted, "\r\n", "\n"));
    }

    if (parts.comment_id != null or (parts.thread_kind != .issue and parts.thread_kind != .patch)) {
        try request.respond("thread not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }
    const route = ui.RoutablePage.fromUrl(base) orelse ui.RoutablePage.fromUrlLocal(base) orelse {
        try request.respond("thread not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };
    const theirs: []const u8 = switch (route) {
        .repo_patches => |*patch| patch.theirs.slice(),
        .repo_issues => "",
        else => unreachable,
    };
    const not_found = if (parts.thread_kind == .patch) "patch not found" else "issue not found";

    (switch (parts.thread_kind) {
        .issue => updateThread(evt.Issue, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .resolve = .{
            .title = title,
            .labels = labels,
            .hunks = hunks.items,
        } }, author),
        .patch => updateThread(evt.Patch, io, allocator, host, parts.repo_base, &parts.thread_id, .{ .resolve = .{
            .title = title,
            .labels = labels,
            .hunks = hunks.items,
            .theirs = theirs,
        } }, author),
        else => unreachable,
    }) catch |err| switch (err) {
        error.NotFound => {
            try request.respond(not_found, .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
            });
            return;
        },
        // invalid fields send the user back to the resolve form
        error.InvalidFields => {
            const form_location = try std.fmt.allocPrint(allocator, "{s}/resolve", .{base});
            defer allocator.free(form_location);
            try request.respond("", .{
                .status = .see_other,
                .extra_headers = &.{.{ .name = "location", .value = form_location }},
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

// the posted path drops the action's own segment, so the route it parses is
// the undo page the action applies to, never the confirmation page itself
fn handleUndo(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, base: []const u8, host: Host, action: enum { undo, clear }) !void {
    const route = (switch (host) {
        .local => ui.RoutablePage.fromUrlLocal(base),
        .server => ui.RoutablePage.fromUrl(base),
    }) orelse return respondRepoNotFound(request);
    if (route != .repo_undo) return respondRepoNotFound(request);
    const target = route.repo_undo;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const repo_base = if (target.name.len == 0) "" else try std.fmt.allocPrint(arena.allocator(), "/repo/{s}", .{target.name.slice()});
    _ = (try authorizeWrite(io, allocator, &arena, request, host, repo_base, .owner)) orelse return;
    const resolved = (try requestRepoSource(io, allocator, host, repo_base)) orelse return respondRepoNotFound(request);
    defer resolved.deinit(allocator);
    (switch (action) {
        .undo => ui.Repo.Undo.execute(io, allocator, resolved.source, target.index orelse return respondRepoNotFound(request)),
        .clear => ui.Repo.Undo.clearHistory(io, allocator, resolved.source),
    }) catch |err| switch (err) {
        error.NotFound, error.InvalidHistoryIndex, error.TransactionNotFound => return respondRepoNotFound(request),
        else => return err,
    };
    const location = try (ui.RoutablePage.repoUndoRoute(target.name.slice(), null) orelse return error.RouteTooLong).toUrl(&arena);
    try request.respond("", .{ .status = .see_other, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = location }} });
}

fn handleSync(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    base: []const u8,
    source: ui.RepoSource,
) !void {
    if (base.len != 0) {
        try request.respond("not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }

    var owned_failure: ?[]u8 = null;
    defer if (owned_failure) |message| allocator.free(message);
    const failure: ?[]const u8 = blk: {
        owned_failure = ui.Repo.Events.sync(io, allocator, source) catch |err| break :blk @errorName(err);
        break :blk owned_failure;
    };
    if (failure) |message| {
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try std.Uri.Component.percentEncode(&encoded.writer, message, struct {
            fn isUnreserved(c: u8) bool {
                return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
            }
        }.isUnreserved);
        const cookie = try std.fmt.allocPrint(
            allocator,
            local_flash_cookie ++ "=" ++ local_sync_failure_prefix ++ "{s}; Path=/; HttpOnly; SameSite=Strict",
            .{encoded.written()},
        );
        defer allocator.free(cookie);
        try request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "location", .value = "/events" },
                .{ .name = "set-cookie", .value = cookie },
            },
        });
        return;
    }

    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = "/events" },
            .{ .name = "set-cookie", .value = local_flash_cookie ++ "=; Path=/; Max-Age=0" },
        },
    });
}

fn renderIndexHtml(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: Host,
    session_token: ?[]const u8,
    session_data: ui.Session.Data,
) ![]const u8 {
    const template = (findEmbed("/index.html") orelse return error.MissingIndexAsset).body;

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    // the server admin repo must outlive the page build, since the session's
    // moment reads from it.
    var repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (repo_maybe) |*repo| repo.deinit(io, allocator);

    var session = switch (host) {
        .server => |server| blk: {
            // open the admin repo to read live user/repo data.
            repo_maybe = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
            const repo = if (repo_maybe) |*repo| repo else unreachable;
            var session = try ui.Session.init(&page_arena, repo, session_data);
            // the session dropped a user whose account was removed, so revoke
            // the token that named them
            if (session_token) |token| {
                if (session.data.user_id == null) server.session_store.remove(token);
            }
            // give the page builders filesystem access to the on-disk repos (a
            // sibling "repos" dir next to the admin repo) so the Repo page can
            // read its files.
            session.repos_dir = try std.fs.path.join(page_arena.allocator(), &.{ std.fs.path.dirname(server.admin_repo_path) orelse ".", "repos" });
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

    var page = try ui.Page.init(session.page_arena, &session, session.data.current_page);
    var root = try ui.initRoot(allocator, &page, &session);
    defer root.deinit(allocator);

    const snapshot: ui.Snapshot = .{ .page = page, .session = session.data };

    const content = try generateHtml(allocator, &root, &session);
    defer allocator.free(content);

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
pub fn generateHtml(allocator: std.mem.Allocator, root: *ui.Widget, session: *ui.Session) ![]const u8 {
    const grid = root.getGrid() orelse return error.MissingGrid;
    const root_focus = root.getFocus();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (root.*) {
        .background => |*background| {
            if (background.art.getGrid()) |art| {
                var position_buf: [64]u8 = undefined;
                try out.appendSlice(allocator, try std.fmt.bufPrint(&position_buf, "<div class=\"ansi-art\" aria-hidden=\"true\" style=\"left:{d}ch\">", .{grid.size.width -| art.size.width}));
                try renderPanel(allocator, &out, background.art.getFocus(), art, session, root_focus);
                try out.appendSlice(allocator, "</div>");
            }
        },
        else => {},
    }
    try out.appendSlice(allocator, "<div class=\"grid-content\" data-key=\"panel:root\">");
    try renderPanel(allocator, &out, root_focus, grid, session, root_focus);
    try out.appendSlice(allocator, "</div>");
    try renderForms(allocator, &out, root_focus);
    return try out.toOwnedSlice(allocator);
}

// render one panel — a focus subtree and its content grid — as HTML, recursing
// once per web-native Scroll inside it. the root panel is the whole page; each
// Scroll becomes a nested, natively-scrollable div holding its full content.
// emits the panel's grid cells as text, leaving holes where child scrolls sit,
// then the child scroll divs over those holes.
fn renderPanel(allocator: std.mem.Allocator, output: *std.ArrayList(u8), focus: *Focus, grid: Grid, session: *ui.Session, root_focus: *Focus) !void {
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
        // disabled, but wasm handles it without navigating.
        fn init(str: []const u8) @This() {
            if (std.mem.startsWith(u8, str, ui.raw_link_prefix)) {
                return .{ .a = str[ui.raw_link_prefix.len..] };
            }
            if (std.mem.startsWith(u8, str, ui.in_page_link_prefix)) {
                return .{ .a = str[ui.in_page_link_prefix.len..] };
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

    // the focusable owning each cell, among this panel's own (skipping any
    // that belong to a child scroll, whose cells are drawn in their own panel).
    // claimed in focus order, so the first focusable over a cell keeps it.
    // looking every focusable up for every cell is quadratic in a long list.
    const owners = try allocator.alloc(?usize, grid.size.width * grid.size.height);
    defer allocator.free(owners);
    @memset(owners, null);
    {
        var it = focus.children.iterator();
        while (it.next()) |entry| {
            const child = entry.value_ptr.*;
            if (child.focus.mode != .all) continue;
            if (excluded.contains(entry.key_ptr.*)) continue;
            const r = child.rect;
            for (@min(r.y, grid.size.height)..@min(r.y + r.size.height, grid.size.height)) |y| {
                for (@min(r.x, grid.size.width)..@min(r.x + r.size.width, grid.size.width)) |x| {
                    const owner = &owners[y * grid.size.width + x];
                    if (owner.* == null) owner.* = entry.key_ptr.*;
                }
            }
        }
    }

    // the cells are the volatile part of a panel. js replaces this one subtree
    // wholesale while retaining the panel's native controls and scroll shells.
    try output.appendSlice(allocator, "<div class=\"grid-cells\">");

    // emit this panel's grid as rows of text, coalescing adjacent cells that
    // share a focus id and style into one tag (a clickable span, a link, or a
    // plain styled span). cells under a child scroll keep only their background.
    // a cell's own link is an anchor nested in that tag.
    for (0..grid.size.height) |y| {
        var cur_id: ?usize = null;
        var cur_style: Grid.Style = .{};
        var open_tag: ?CellTag = null;
        var open_link: ?[]const u8 = null;
        var first = true;
        for (0..grid.size.width) |x| {
            const cell = (try grid.cell(x, y)).*;
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
            // the focusable owning the cell at (x, y); none for a covered cell.
            const cell_id = if (covered_by_scroll) null else owners[y * grid.size.width + x];
            const style: Grid.Style = if (covered_by_scroll) .{ .bg = cell.style.bg } else cell.style;

            if (first or cell_id != cur_id or !style.eql(cur_style)) {
                if (open_link != null) try output.appendSlice(allocator, "</a>");
                open_link = null;
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
                if (new_tag == null and !style.eql(.{})) new_tag = .plain;

                if (new_tag) |t| {
                    var style_buf: [192]u8 = undefined;
                    try t.writeOpenTag(allocator, output, cell_id orelse 0, styleAttr(&style_buf, style));
                }

                open_tag = new_tag;
                cur_id = cell_id;
                cur_style = style;
                first = false;
            }

            // an anchor can't nest in another, so a link tag's cells skip theirs
            const in_anchor = if (open_tag) |t| t == .a else false;
            const link = if (covered_by_scroll or in_anchor) null else webLink(cell.link);
            if (!sameLink(link, open_link)) {
                if (open_link != null) try output.appendSlice(allocator, "</a>");
                if (link) |url| {
                    try output.appendSlice(allocator, "<a class=\"cell-link\" tabindex=\"-1\" target=\"_blank\" rel=\"noopener noreferrer\" href=\"");
                    try appendEscapedHtml(allocator, output, url);
                    try output.appendSlice(allocator, "\">");
                }
                open_link = link;
            }

            if (covered_by_scroll) {
                try appendEscapedHtml(allocator, output, " ");
            } else if (cell.continuation) {
                // the wide rune to the left was emitted 2ch wide, covering this column
            } else if (cell.rune) |rune| {
                var encoded: [4]u8 = undefined;
                const encoded_len = try std.unicode.utf8Encode(rune, &encoded);
                const rune_text = encoded[0..encoded_len];
                // a double-width rune is pinned inside a 2ch span so the
                // fallback glyph's advance width can't shift the rest of the row
                const wide = x + 1 < grid.size.width and (try grid.cell(x + 1, y)).continuation;
                if (wide) {
                    try output.appendSlice(allocator, "<span class=\"w2\">");
                    try appendEscapedHtml(allocator, output, rune_text);
                    try output.appendSlice(allocator, "</span>");
                } else {
                    try appendEscapedHtml(allocator, output, rune_text);
                }
            } else {
                try appendEscapedHtml(allocator, output, " ");
            }
        }
        if (open_link != null) try output.appendSlice(allocator, "</a>");
        if (open_tag) |t| try output.appendSlice(allocator, t.closeTag());
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, "</div>");

    // native controls live in their panel, beside the replaceable cells. their
    // stable keys let JS update layout without recreating their DOM nodes, and
    // being actual descendants of a scroll gives them native movement/clipping.
    try renderPanelControls(allocator, output, focus, session, root_focus, &excluded);

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
        var buf: [256]u8 = undefined;
        try output.appendSlice(allocator, try std.fmt.bufPrint(&buf, "<div class=\"scroll\" data-key=\"scroll:{d}\" data-scroll-id=\"{d}-{d}\" data-scroll-direction=\"{s}\" data-scroll-x=\"{d}\" data-scroll-y=\"{d}\" style=\"left:{d}ch;top:{d}em;width:{d}ch;height:{d}em;{s}\">", .{ id, id, child.focus.version, @tagName(info.direction), info.offset_x, info.offset_y, r.x, r.y, r.size.width, r.size.height, overflow }));
        try renderPanel(allocator, output, child.focus, info.content, session, root_focus);
        try output.appendSlice(allocator, "</div>");
    }
}

const form_prefix = "form:";
const form_id_prefix = "haxy-form-";

fn formAction(focus: *const Focus) ?[]const u8 {
    return switch (focus.kind) {
        .custom => |custom| if (std.mem.startsWith(u8, custom, form_prefix)) custom[form_prefix.len..] else null,
        else => null,
    };
}

// find the form ancestor of a flattened focus-tree child. html's `form`
// attribute then associates the control with that form without requiring the
// form and control to share a DOM parent.
fn formOwner(root_focus: *Focus, focus_id: usize) ?usize {
    var id = focus_id;
    while (root_focus.children.get(id)) |child| {
        const parent_id = child.parent_id;
        if (parent_id == root_focus.id) return if (formAction(root_focus) != null) root_focus.id else null;
        const parent = root_focus.children.get(parent_id) orelse return null;
        if (formAction(parent.focus) != null) return parent_id;
        id = parent_id;
    }
    return null;
}

fn appendFormAttribute(allocator: std.mem.Allocator, output: *std.ArrayList(u8), root_focus: *Focus, focus_id: usize) !void {
    const form_id = formOwner(root_focus, focus_id) orelse return;
    var buf: [64]u8 = undefined;
    try output.appendSlice(allocator, try std.fmt.bufPrint(&buf, " form=\"" ++ form_id_prefix ++ "{d}\"", .{form_id}));
}

fn renderPanelControls(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    focus: *Focus,
    session: *ui.Session,
    root_focus: *Focus,
    excluded: *const std.AutoHashMapUnmanaged(usize, void),
) !void {
    var iter = focus.children.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr.*;
        if (excluded.contains(id)) continue;
        const child = entry.value_ptr.*;
        const r = child.rect;

        if (r.size.width == 0 or r.size.height == 0) continue; // not laid out, rather than merely off-screen

        switch (child.focus.kind) {
            .text_input, .text_input_password, .text_area => {
                const ti = session.text_inputs.get(id) orelse continue;

                const inner_left = r.x + 1;
                const inner_top = r.y + 1;
                const inner_width = if (r.size.width > 2) r.size.width - 2 else 0;
                const preserve = !ti.options.read_only;

                if (child.focus.kind == .text_area) {
                    const value = try ti.text(allocator);
                    defer allocator.free(value);
                    var id_buf: [128]u8 = undefined;
                    try output.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "<textarea data-key=\"control:{d}\" data-focus-id=\"{d}\"", .{ id, id }));
                    if (preserve) try output.appendSlice(allocator, " data-preserve-value") else try output.appendSlice(allocator, " readonly");
                    try appendFormAttribute(allocator, output, root_focus, id);
                    if (ti.options.name.len > 0) {
                        try output.appendSlice(allocator, " name=\"");
                        try appendEscapedHtml(allocator, output, ti.options.name);
                        try output.append(allocator, '"');
                    }
                    const inner_height = if (r.size.height > 2) r.size.height - 2 else 0;
                    var pos_buf: [128]u8 = undefined;
                    try output.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, " style=\"left:{d}ch;top:{d}em;width:{d}ch;height:{d}em\">\n", .{ inner_left, inner_top, inner_width, inner_height }));
                    try appendEscapedHtml(allocator, output, value);
                    try output.appendSlice(allocator, "</textarea>");
                    continue;
                }

                var id_buf: [160]u8 = undefined;
                try output.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "<input type=\"{s}\" data-key=\"control:{d}\" data-focus-id=\"{d}\"", .{ if (child.focus.kind == .text_input_password) "password" else "text", id, id }));
                if (preserve) try output.appendSlice(allocator, " data-preserve-value") else try output.appendSlice(allocator, " readonly");
                try appendFormAttribute(allocator, output, root_focus, id);
                if (ti.options.name.len > 0) {
                    try output.appendSlice(allocator, " name=\"");
                    try appendEscapedHtml(allocator, output, ti.options.name);
                    try output.append(allocator, '"');
                }
                if (child.focus.kind != .text_input_password) {
                    const value = try ti.text(allocator);
                    defer allocator.free(value);
                    try output.appendSlice(allocator, " value=\"");
                    try appendEscapedHtml(allocator, output, value);
                    try output.append(allocator, '"');
                }
                var pos_buf: [96]u8 = undefined;
                try output.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, " style=\"left:{d}ch;top:{d}em;width:{d}ch;height:1em\">", .{ inner_left, inner_top, inner_width }));
            },
            .custom => |custom| {
                if (std.mem.eql(u8, custom, "submit") or std.mem.startsWith(u8, custom, ui.submit_action_prefix)) {
                    if (formOwner(root_focus, id) == null) continue;
                    var id_buf: [128]u8 = undefined;
                    try output.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "<button type=\"submit\" data-key=\"control:{d}\" data-focus-id=\"{d}\"", .{ id, id }));
                    try appendFormAttribute(allocator, output, root_focus, id);
                    if (std.mem.startsWith(u8, custom, ui.submit_action_prefix)) {
                        try output.appendSlice(allocator, " formaction=\"");
                        try appendEscapedHtml(allocator, output, custom[ui.submit_action_prefix.len..]);
                        try output.append(allocator, '"');
                    }
                    var pos_buf: [128]u8 = undefined;
                    try output.appendSlice(allocator, try std.fmt.bufPrint(&pos_buf, " style=\"left:{d}ch;top:{d}em;width:{d}ch;height:{d}em\"></button>", .{ r.x, r.y, r.size.width, r.size.height }));
                } else if (std.mem.startsWith(u8, custom, ui.file_input_prefix)) {
                    try output.appendSlice(allocator, "<input type=\"file\" data-preserve-value data-action=\"");
                    try appendEscapedHtml(allocator, output, custom[ui.file_input_prefix.len..]);
                    var id_buf: [128]u8 = undefined;
                    try output.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "\" data-key=\"control:{d}\" data-focus-id=\"{d}\" style=\"opacity:0;left:{d}ch;top:{d}em;width:{d}ch;height:{d}em\">", .{ id, id, r.x, r.y, r.size.width, r.size.height }));
                }
            },
            else => {},
        }
    }
}

// emit hidden form owners beside the rendered panels. their controls point
// back here with the standard HTML `form` attribute.
fn renderForms(allocator: std.mem.Allocator, output: *std.ArrayList(u8), root_focus: *Focus) !void {
    // the focus child map preserves insertion order, which matches the order
    // widgets were added in code
    var iter = root_focus.children.iterator();
    while (iter.next()) |entry| {
        const child = entry.value_ptr.*;
        const action_url = formAction(child.focus) orelse continue;

        try output.appendSlice(allocator, "<form hidden data-key=\"form:");
        var id_buf: [96]u8 = undefined;
        try output.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, "{d}\" id=\"" ++ form_id_prefix ++ "{d}\" action=\"", .{ entry.key_ptr.*, entry.key_ptr.* }));
        try appendEscapedHtml(allocator, output, action_url);
        try output.appendSlice(allocator, "\" method=\"post\"></form>");
    }
}

// the 16 ansi colors as the browser shows them (xterm's defaults)
const ansi_palette = [16]Grid.Color.Rgb{
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, .{ .r = 0xcd, .g = 0x00, .b = 0x00 }, .{ .r = 0x00, .g = 0xcd, .b = 0x00 }, .{ .r = 0xcd, .g = 0xcd, .b = 0x00 },
    .{ .r = 0x00, .g = 0x00, .b = 0xee }, .{ .r = 0xcd, .g = 0x00, .b = 0xcd }, .{ .r = 0x00, .g = 0xcd, .b = 0xcd }, .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    .{ .r = 0x7f, .g = 0x7f, .b = 0x7f }, .{ .r = 0xff, .g = 0x00, .b = 0x00 }, .{ .r = 0x00, .g = 0xff, .b = 0x00 }, .{ .r = 0xff, .g = 0xff, .b = 0x00 },
    .{ .r = 0x5c, .g = 0x5c, .b = 0xff }, .{ .r = 0xff, .g = 0x00, .b = 0xff }, .{ .r = 0x00, .g = 0xff, .b = 0xff }, .{ .r = 0xff, .g = 0xff, .b = 0xff },
};

// resolve any color to rgb: palette colors through the ansi table and the
// xterm 256-color layout (16 ansi, a 6x6x6 cube, then 24 grays)
fn colorRgb(color: Grid.Color) Grid.Color.Rgb {
    return switch (color) {
        .rgb => |c| c,
        .ansi => |a| ansi_palette[@intFromEnum(a)],
        .indexed => |n| if (n < 16)
            ansi_palette[n]
        else if (n < 232) blk: {
            const levels = [6]u8{ 0, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
            const i = n - 16;
            break :blk .{ .r = levels[i / 36], .g = levels[(i / 6) % 6], .b = levels[i % 6] };
        } else blk: {
            const v: u8 = 8 + (n - 232) * 10;
            break :blk .{ .r = v, .g = v, .b = v };
        },
    };
}

// builds an HTML ` style="color:…;background-color:…"` attribute from a
// cell's style into `buf`, omitting whichever color is unset. an inverted
// cell swaps the two, falling back to the page's --fg/--bg variables for
// whichever side is unset. text attributes follow the colors. returns an
// empty slice when nothing is set.
fn styleAttr(buf: []u8, style: Grid.Style) []const u8 {
    if (style.eql(.{})) return buf[0..0];
    const prefix = " style=\"";
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    const inverted = style.inverted;
    i = cssColor(buf, i, "color", if (inverted) style.bg else style.fg, if (inverted) "var(--bg)" else null) orelse return buf[0..0];
    i = cssColor(buf, i, "background-color", if (inverted) style.fg else style.bg, if (inverted) "var(--fg)" else null) orelse return buf[0..0];
    const decoration: []const u8 = if (style.underline and style.strikethrough)
        "text-decoration:underline line-through;"
    else if (style.underline)
        "text-decoration:underline;"
    else if (style.strikethrough)
        "text-decoration:line-through;"
    else
        "";
    const attributes = std.fmt.bufPrint(buf[i..], "{s}{s}{s}{s}", .{
        if (style.bold) "font-weight:bold;" else "",
        if (style.italic) "font-style:italic;" else "",
        decoration,
        if (style.dim) "opacity:.6;" else "",
    }) catch return buf[0..0];
    i += attributes.len;
    if (i >= buf.len) return buf[0..0];
    buf[i] = '"';
    return buf[0 .. i + 1];
}

// append `prop:value;` at buf[i..] for the color, or for the fallback when
// the color is unset (nothing when both are). returns the new end, or null
// when it doesn't fit.
fn cssColor(buf: []u8, i: usize, prop: []const u8, color: ?Grid.Color, fallback: ?[]const u8) ?usize {
    const s = if (color) |c| blk: {
        const v = colorRgb(c);
        break :blk std.fmt.bufPrint(buf[i..], "{s}:#{x:0>2}{x:0>2}{x:0>2};", .{ prop, v.r, v.g, v.b }) catch return null;
    } else if (fallback) |f|
        std.fmt.bufPrint(buf[i..], "{s}:{s};", .{ prop, f }) catch return null
    else
        return i;
    return i + s.len;
}

// a cell's link as an href, when it's a web or mail url
fn webLink(link: ?[]const u8) ?[]const u8 {
    const url = link orelse return null;
    for ([_][]const u8{ "http://", "https://", "mailto:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) return url;
    }
    return null;
}

fn sameLink(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
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

fn readFormBody(request: *std.http.Server.Request, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [256]u8 = undefined;
    return request.readerExpectNone(&buffer).allocRemaining(allocator, .limited(65536));
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
// deliberately no expiry — a session lives until logout. form failures use
// files in the flash subdirectory that the redirected GET consumes. the
// directory is cleared whenever the server starts.
pub const SessionStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    flash_dir: std.Io.Dir,
    auto_login: ?[token_hex_len]u8,

    pub const token_hex_len = evt.event_id_size * 2;

    pub fn init(io: std.Io, data_dir: std.Io.Dir) !SessionStore {
        try data_dir.createDirPath(io, "sessions");
        const dir = try data_dir.openDir(io, "sessions", .{});
        errdefer dir.close(io);
        try dir.deleteTree(io, "flash");
        try dir.createDirPath(io, "flash");
        const flash_dir = try dir.openDir(io, "flash", .{});
        errdefer flash_dir.close(io);
        const auto_login = blk: {
            const file = dir.openFile(io, auto_login_name, .{ .mode = .read_only }) catch break :blk null;
            defer file.close(io);
            var token: [token_hex_len]u8 = undefined;
            var storage: [token_hex_len]u8 = undefined;
            var reader = file.reader(io, &storage);
            reader.interface.readSliceAll(&token) catch break :blk null;
            break :blk token;
        };
        return .{ .io = io, .dir = dir, .flash_dir = flash_dir, .auto_login = auto_login };
    }

    pub fn deinit(self: SessionStore) void {
        self.flash_dir.close(self.io);
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

    fn createFlash(self: SessionStore, allocator: std.mem.Allocator, value: ui.Session.FormFeedback) ![token_hex_len]u8 {
        var token: [evt.event_id_size]u8 = undefined;
        self.io.random(&token);
        const token_hex = std.fmt.bytesToHex(token, .lower);
        const file = try self.flash_dir.createFile(self.io, &token_hex, .{});
        errdefer self.flash_dir.deleteFile(self.io, &token_hex) catch {};
        defer file.close(self.io);

        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();
        try std.json.Stringify.value(value, .{}, &json.writer);
        try file.writeStreamingAll(self.io, json.written());
        return token_hex;
    }

    fn takeFlash(self: SessionStore, allocator: std.mem.Allocator, token_hex: []const u8) ?ui.Session.FormFeedback {
        if (!isToken(token_hex)) return null;
        const file = self.flash_dir.openFile(self.io, token_hex, .{ .mode = .read_only }) catch return null;
        defer self.flash_dir.deleteFile(self.io, token_hex) catch {};
        defer file.close(self.io);

        var storage: [4096]u8 = undefined;
        var reader = file.reader(self.io, &storage);
        const bytes = reader.interface.allocRemaining(allocator, .limited(512 * 1024)) catch return null;
        return std.json.parseFromSliceLeaky(ui.Session.FormFeedback, allocator, bytes, .{}) catch null;
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

    // leave `token_hex`'s session for visitors arriving without one. only the
    // `try` fixture writes one. the name can't collide with a session token.
    pub fn offerAutoLogin(self: SessionStore, token_hex: *const [token_hex_len]u8) !void {
        const file = try self.dir.createFile(self.io, auto_login_name, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, token_hex);
    }

    pub fn autoLogin(self: SessionStore, out: *[token_hex_len]u8) bool {
        out.* = self.auto_login orelse return false;
        return true;
    }

    const auto_login_name = "auto-login";

    // a token is exactly token_hex_len hex chars. validating before using the
    // value as a path keeps attacker-supplied cookies from escaping the
    // sessions dir (e.g. via "/" or ".." bytes).
    fn isToken(token_hex: []const u8) bool {
        if (token_hex.len != token_hex_len) return false;
        for (token_hex) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
};

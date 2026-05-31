//! haxy-side dispatcher for SSH sessions served by serve_ssh_protocol.
//! routes shell + pty-req → StreamTerminal (TUI), exec git-upload-pack /
//! git-receive-pack → repo.uploadPack / repo.receivePack (git).

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;
const Grid = xitui.grid.Grid;
const Size = xitui.layout.Size;
const ui = @import("./ui.zig");
const ssh = @import("./serve_ssh_protocol.zig");
const evt = @import("./event.zig");

pub const SessionHandler = struct {
    admin_repo_path: []const u8,
    repo_root_path: []const u8,

    pub fn handleSession(self: *const SessionHandler, sess: *ssh.SessionCtx, request: ssh.Request) !void {
        std.debug.print("ssh session: kind={s} key={s}\n", .{ @tagName(request), sess.fingerprint });
        switch (request) {
            .shell => |pty_maybe| {
                const pty = pty_maybe orelse {
                    // a shell without a pty has no useful TUI to render; in
                    // openssh client terms this is `ssh -T host`. say so and
                    // exit non-zero.
                    try sess.writeBytes("haxy ssh: this server only serves the TUI when a pty is allocated (use a normal `ssh` invocation).\r\n");
                    try sess.exit(1);
                    return;
                };
                try runTuiSession(self, sess, pty);
            },
            .exec => |command| {
                try runGitSession(self, sess, command);
            },
        }
    }
};

fn runTuiSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize) !void {
    // runTui owns the terminal, whose deinit restores the client's screen and
    // runs as the function unwinds — so any error it returns leaves the TUI torn
    // down and we can surface the failure on the restored screen before exiting.
    runTui(handler, sess, pty) catch |err| {
        std.debug.print("ssh tui session failed: {s}\n", .{@errorName(err)});
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "haxy ssh: {s}\r\n", .{@errorName(err)}) catch "haxy ssh: internal error\r\n";
        sess.writeBytes(msg) catch {};
        try sess.exit(1);
        return;
    };
    try sess.exit(0);
}

fn runTui(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize) !void {
    const allocator = sess.allocator;
    const io = sess.io;

    // some clients (notably scripted ssh with no local controlling tty)
    // allocate a pty without ever sending a non-zero size. fall back to a
    // conventional 80x24 in that case so render emits something.
    const effective_pty = ssh.PtySize{
        .width_cells = if (pty.width_cells == 0) 80 else pty.width_cells,
        .height_cells = if (pty.height_cells == 0) 24 else pty.height_cells,
    };

    // session-lifetime allocations (login, prefs); Nav owns the per-page arenas.
    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = handler.admin_repo_path });
    defer repo.deinit(io, allocator);
    var ui_session = try ui.Session.init(&session_arena, &repo, .{});

    var nav = try ui.Nav.init(allocator, &ui_session);
    defer nav.deinit(allocator);

    var session_writer_buf: [8192]u8 = undefined;
    var session_writer = ssh.SessionWriter.init(sess, &session_writer_buf);

    // the terminal's deinit writes leave-alt / show-cursor / disable-mouse and
    // flushes, restoring the client's screen. as a function-scoped defer it runs
    // before runTui returns — on the normal path and on any error — so the
    // caller can write to the client afterward (and sess.exit can close cleanly).
    var terminal = try StreamTerminal.init(allocator, &session_writer.interface, .{
        .width = effective_pty.width_cells,
        .height = effective_pty.height_cells,
    });
    defer terminal.deinit();

    var last_size = Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    // initial render — user sees the page immediately
    try nav.root.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = last_size.width, .height = last_size.height },
    }, nav.root.getFocus());
    _ = try terminal.render(&nav.root, &last_grid, &last_size);

    // event loop. nextEvent blocks until something interesting arrives;
    // for each event, rebuild the widget tree and re-render so the user
    // sees the effect of their input on the same iteration.
    while (!terminal.shouldQuit()) {
        const event = try sess.nextEvent();
        switch (event) {
            .data => |payload| {
                defer allocator.free(payload);
                try terminal.writeBytes(payload);
                while (terminal.popKey()) |key| {
                    try ui.inputKey(allocator, &nav.root, key, &ui_session);
                }
            },
            .resize => |sz| {
                terminal.pushResize(.{ .width = sz.width_cells, .height = sz.height_cells });
                while (terminal.popKey()) |key| {
                    try ui.inputKey(allocator, &nav.root, key, &ui_session);
                }
            },
            .close => terminal.requestQuit(),
        }

        try ui_session.applyAndWritePending(io, allocator, &repo);

        // reconcile navigation: forward to a new page, or back on escape (and
        // quit when there's nothing left to go back to).
        if (!try nav.sync(allocator, &ui_session)) terminal.requestQuit();

        try nav.root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, nav.root.getFocus());
        _ = try terminal.render(&nav.root, &last_grid, &last_size);
    }
}

// ---------------------------------------------------------------------------
// git path (exec)
// ---------------------------------------------------------------------------

pub const GitService = enum { upload_pack, receive_pack };

pub const ParsedGitCommand = struct {
    service: GitService,
    dir: []u8,

    pub fn deinit(self: ParsedGitCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
    }
};

fn runGitSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, command: []const u8) !void {
    const allocator = sess.allocator;
    const io = sess.io;

    const parsed = parseGitCommand(allocator, command) catch {
        try writeError(sess, "unsupported command (expected git-upload-pack or git-receive-pack)");
        try sess.exit(1);
        return;
    };
    defer parsed.deinit(allocator);

    const repo_path = try resolveRepoPath(allocator, handler.repo_root_path, parsed.dir);
    defer allocator.free(repo_path);

    if (!isSubPath(handler.repo_root_path, repo_path)) {
        try writeError(sess, "forbidden path");
        try sess.exit(1);
        return;
    }

    const create_if_missing = parsed.service == .receive_pack;
    const any_repo_opts: rp.AnyRepoOpts(.xit) = .{};

    var any_repo = rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = repo_path }) catch |err| switch (err) {
        error.RepoNotFound => {
            if (!create_if_missing) {
                try writeError(sess, "repo not found");
                try sess.exit(1);
                return;
            }
            // nothing on disk to detect a hash from, so create with the
            // default concrete options and serve that.
            var repo = try createRepo(any_repo_opts.toRepoOpts(), io, allocator, repo_path);
            defer repo.deinit(io, allocator);
            try servePack(repo.self_repo_opts, &repo, sess, io, allocator, parsed.service);
            try sess.exit(0);
            return;
        },
        else => |e| return e,
    };
    defer any_repo.deinit(io, allocator);

    switch (any_repo) {
        inline else => |*repo| try servePack(repo.self_repo_opts, repo, sess, io, allocator, parsed.service),
    }

    try sess.exit(0);
}

fn createRepo(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
) !rp.Repo(.xit, repo_opts) {
    var repo = try rp.Repo(.xit, repo_opts).init(io, allocator, .{ .path = repo_path });
    errdefer repo.deinit(io, allocator);
    try repo.addConfig(io, allocator, .{ .name = "http.receivepack", .value = "true" });
    try repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
    return repo;
}

// wrap the channel I/O in std.Io.Reader/Writer adapters so the repo's pack
// functions can consume them like any other stream, then run the requested
// service
fn servePack(
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    sess: *ssh.SessionCtx,
    io: std.Io,
    allocator: std.mem.Allocator,
    service: GitService,
) !void {
    var session_reader_buf: [4096]u8 = undefined;
    var session_writer_buf: [4096]u8 = undefined;
    var session_reader = ssh.SessionReader.init(sess, &session_reader_buf);
    var session_writer = ssh.SessionWriter.init(sess, &session_writer_buf);

    switch (service) {
        .upload_pack => try repo.uploadPack(io, allocator, &session_reader.interface, &session_writer.interface, .{}),
        .receive_pack => try repo.receivePack(io, allocator, &session_reader.interface, &session_writer.interface, .{}),
    }

    // flush whatever the pack op buffered into our writer adapter
    session_writer.interface.flush() catch {};
}

fn parseGitCommand(allocator: std.mem.Allocator, command: []const u8) !ParsedGitCommand {
    var tokens = try std.process.Args.IteratorGeneral(.{ .single_quotes = true }).init(allocator, command);
    defer tokens.deinit();

    const service_token = tokens.next() orelse return error.InvalidCommand;
    const dir_token = tokens.next() orelse return error.InvalidCommand;

    const service: GitService =
        if (std.mem.eql(u8, service_token, "git-upload-pack") or std.mem.eql(u8, service_token, "upload-pack"))
            .upload_pack
        else if (std.mem.eql(u8, service_token, "git-receive-pack") or std.mem.eql(u8, service_token, "receive-pack"))
            .receive_pack
        else
            return error.UnsupportedService;

    return .{ .service = service, .dir = try allocator.dupe(u8, dir_token) };
}

fn resolveRepoPath(allocator: std.mem.Allocator, repo_root_path: []const u8, dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(dir)) return try std.fs.path.resolve(allocator, &.{dir});
    return try std.fs.path.resolve(allocator, &.{ repo_root_path, dir });
}

fn isSubPath(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, std.fs.path.sep_str)) return std.fs.path.isAbsolute(child);
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or child[parent.len] == std.fs.path.sep;
}

fn writeError(sess: *ssh.SessionCtx, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "haxy ssh: {s}\n", .{msg});
    try sess.writeBytes(text);
}

test "parseGitCommand rejects malformed input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCommand, parseGitCommand(allocator, "git-upload-pack"));
    try std.testing.expectError(error.UnsupportedService, parseGitCommand(allocator, "ls -la"));
    try std.testing.expectError(error.UnsupportedService, parseGitCommand(allocator, "git-fake-pack 'repo'"));
}

test "parseGitCommand happy paths" {
    const allocator = std.testing.allocator;

    {
        const parsed = try parseGitCommand(allocator, "git-upload-pack 'some-repo'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("some-repo", parsed.dir);
    }
    {
        const parsed = try parseGitCommand(allocator, "git-receive-pack 'user/proj'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.receive_pack, parsed.service);
        try std.testing.expectEqualStrings("user/proj", parsed.dir);
    }
    {
        const parsed = try parseGitCommand(allocator, "git-upload-pack repo");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("repo", parsed.dir);
    }
}

test "isSubPath rejects prefix collisions and traversal" {
    const sep = std.fs.path.sep_str;
    const parent = sep ++ "srv" ++ sep ++ "git";

    try std.testing.expect(isSubPath(parent, parent ++ sep ++ "repo"));
    try std.testing.expect(isSubPath(parent, parent));

    // common-prefix-but-not-subpath: "/srv/git" should NOT swallow
    // "/srv/git2" or "/srv/gitignore" just because the bytes start the same.
    try std.testing.expect(!isSubPath(parent, parent ++ "2"));
    try std.testing.expect(!isSubPath(parent, parent ++ "ignore"));

    // resolveRepoPath normalizes `..` first, so `/srv/git/../etc/passwd`
    // becomes `/etc/passwd` — isSubPath then rejects it.
    try std.testing.expect(!isSubPath(parent, sep ++ "etc" ++ sep ++ "passwd"));

    const builtin = @import("builtin");

    if (.windows != builtin.os.tag) {
        try std.testing.expect(isSubPath(sep, sep ++ "anything"));
        try std.testing.expect(isSubPath(sep, sep));
    }
}

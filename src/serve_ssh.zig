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
const serve_common = @import("./serve_common.zig");

// listener resource limits. idle enforcement is coarse: the watchdog wakes
// once per interval and shuts the connection down if no SSH packet arrived
// during the entire previous interval. each connection holds two OS threads
// under std.Io.Threaded (session + watchdog), so the cap is sized to keep
// the worst-case thread count in comfortable territory, not by RAM.
const max_connections: u32 = 4096;
const idle_interval = std.Io.Duration.fromSeconds(120);

var active_connections: std.atomic.Value(u32) = .init(0);

pub const SessionHandler = struct {
    admin_repo_path: []const u8,
    repo_root_path: []const u8,
    wui_port: u16, // port the web UI is served on, shown in the TUI footer's url
    err: *std.Io.Writer,

    pub fn handleSession(self: *const SessionHandler, sess: *ssh.SessionCtx, request: ssh.Request) !void {
        serve_common.logError(self.err, "ssh session: kind={s} key={s}\n", .{ @tagName(request), sess.fingerprint });
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
                sess.exemptFromIdleTimeout();
                try runTuiSession(self, sess, pty);
            },
            .exec => |command| {
                try runGitSession(self, sess, command);
            },
        }
    }
};

pub fn runListener(
    io: std.Io,
    allocator: std.mem.Allocator,
    host_key: *const ssh.HostKey,
    session_handler: *const SessionHandler,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Context = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        host_key: *const ssh.HostKey,
        session_handler: *const SessionHandler,
        err: *std.Io.Writer,
    };

    const handle = struct {
        fn h(ctx: Context, stream: std.Io.net.Stream) void {
            defer stream.close(ctx.io);

            const prev_count = active_connections.fetchAdd(1, .monotonic);
            defer _ = active_connections.fetchSub(1, .monotonic);
            if (prev_count >= max_connections) {
                serve_common.logError(ctx.err, "ssh: connection limit reached, dropping\n", .{});
                return;
            }

            var idle_state = ssh.IdleState{};
            var watchdog_future = std.Io.concurrent(ctx.io, watchdog, .{ ctx.io, &stream, &idle_state }) catch |spawn_err| {
                serve_common.logError(ctx.err, "ssh: watchdog spawn failed: {s}\n", .{@errorName(spawn_err)});
                return;
            };
            defer watchdog_future.cancel(ctx.io);

            var recv_buf: [4096]u8 = undefined;
            var send_buf: [4096]u8 = undefined;
            var stream_reader = stream.reader(ctx.io, &recv_buf);
            var stream_writer = stream.writer(ctx.io, &send_buf);
            ssh.handleConnection(
                ctx.io,
                ctx.allocator,
                &stream_reader.interface,
                &stream_writer.interface,
                ctx.host_key,
                &idle_state,
                ctx.session_handler,
            ) catch |session_err| {
                serve_common.logError(ctx.err, "ssh session failed: {s}\n", .{@errorName(session_err)});
            };
        }
    }.h;

    serve_common.runListener(io, net_server, tasks, err, "ssh", Context{
        .io = io,
        .allocator = allocator,
        .host_key = host_key,
        .session_handler = session_handler,
        .err = err,
    }, handle);
}

// shut down connections that made no SSH packet progress for a whole
// interval. exempt connections (interactive TUIs) end enforcement instead.
fn watchdog(io: std.Io, stream: *const std.Io.net.Stream, idle_state: *ssh.IdleState) void {
    var last_seen: u64 = 0;
    while (true) {
        io.sleep(idle_interval, .awake) catch return; // canceled — connection is done
        if (idle_state.exempt.load(.monotonic)) return;
        const seen = idle_state.activity.load(.monotonic);
        if (seen == last_seen) {
            stream.shutdown(io, .both) catch {};
            return;
        }
        last_seen = seen;
    }
}

fn runTuiSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize) !void {
    // runTui owns the terminal, whose deinit restores the client's screen and
    // runs as the function unwinds — so any error it returns leaves the TUI torn
    // down and we can surface the failure on the restored screen before exiting.
    runTui(handler, sess, pty) catch |err| {
        serve_common.logError(handler.err, "ssh tui session failed: {s}\n", .{@errorName(err)});
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "haxy ssh: {s}\r\n", .{@errorName(err)}) catch "haxy ssh: internal error\r\n";
        sess.writeBytes(msg) catch {};
        try sess.exit(1);
        return;
    };
    try sess.exit(0);
}

fn runTui(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

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
    ui_session.is_terminal = true;
    ui_session.web_port = handler.wui_port;
    // let page builders open on-disk repos (sibling "repos" dir of the admin repo)
    ui_session.io = io;
    ui_session.repos_dir = try std.fs.path.join(session_arena.allocator(), &.{ std.fs.path.dirname(handler.admin_repo_path) orelse ".", "repos" });

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

        // pick up data written by other handles so the next navigation
        // builds its page from a current moment
        try ui_session.reloadMoment(&repo);

        // reconcile navigation: forward to a new page, or back on escape
        try nav.sync(allocator, &ui_session);

        // the quit button (on the quit tab) asks the host to tear down
        if (ui_session.quit_requested) terminal.requestQuit();

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
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    const parsed = parseGitCommand(allocator, command) catch return writeError(sess, "unsupported command (expected git-upload-pack or git-receive-pack)");
    defer parsed.deinit(allocator);

    const create_if_missing = parsed.service == .receive_pack;
    const any_repo_opts: rp.AnyRepoOpts(.xit) = .{};

    // authenticate pushes: the authenticated key must be registered to the
    // repo's owner.
    if (create_if_missing) {
        const owner_repo = evt.parseOwnerRepoPath(parsed.dir) orelse return writeError(sess, "repo path must be <owner>/<repo>");
        if (!try isKeyAuthorized(io, allocator, handler.admin_repo_path, owner_repo.owner, &sess.fingerprint))
            return writeError(sess, "unauthorized: this SSH key is not registered to the repo owner");
    }

    const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, handler.repo_root_path, handler.admin_repo_path, parsed.dir, create_if_missing)) {
        .ok => |p| p,
        .invalid => return writeError(sess, "repo path must be <owner>/<repo>"),
        .not_found => return writeError(sess, "repo not found"),
    };
    defer allocator.free(repo_path);

    if (try serveIfExists(repo_path, sess, io, allocator, parsed.service)) {
        try sess.exit(0);
        return;
    }

    if (!create_if_missing) return writeError(sess, "repo not found");

    // create the on-disk repo for the just-minted event and serve the push
    var repo = try createRepo(any_repo_opts.toRepoOpts(), io, allocator, repo_path);
    defer repo.deinit(io, allocator);
    try servePack(repo.self_repo_opts, &repo, sess, io, allocator, parsed.service);
    try sess.exit(0);
}

// serve an existing repo at `repo_path`, or return false if none is there
fn serveIfExists(
    repo_path: []const u8,
    sess: *ssh.SessionCtx,
    io: std.Io,
    allocator: std.mem.Allocator,
    service: GitService,
) !bool {
    // a bare open() creates the directory while probing for the repo, so only
    // attempt it when the path already exists
    std.Io.Dir.accessAbsolute(io, repo_path, .{}) catch return false;

    const any_repo_opts: rp.AnyRepoOpts(.xit) = .{};
    var any_repo = rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return false,
        else => |e| return e,
    };
    defer any_repo.deinit(io, allocator);

    switch (any_repo) {
        inline else => |*repo| try servePack(repo.self_repo_opts, repo, sess, io, allocator, service),
    }
    return true;
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

// true if `fingerprint` matches one of the named user's registered SSH keys
fn isKeyAuthorized(
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo_path: []const u8,
    owner_name: []const u8,
    fingerprint: *const [ssh.fingerprint_len]u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const user = (try evt.User.readByName(io, allocator, admin_repo_path, &arena, owner_name)) orelse return false;

    var it = std.mem.splitScalar(u8, user.ssh_keys, '\n');
    while (it.next()) |line| {
        const fp = fingerprintOfAuthorizedKey(line) orelse continue;
        if (std.mem.eql(u8, &fp, fingerprint)) return true;
    }
    return false;
}

// the SHA256 fingerprint of one authorized_keys line, or null if the line is
// blank or not a parseable "<type> <base64> [comment]" entry
fn fingerprintOfAuthorizedKey(line: []const u8) ?[ssh.fingerprint_len]u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    _ = it.next() orelse return null; // key type
    const blob_b64 = it.next() orelse return null;

    const decoder = std.base64.standard.Decoder;
    const blob_len = decoder.calcSizeForSlice(blob_b64) catch return null;
    var blob_buf: [4096]u8 = undefined;
    if (blob_len > blob_buf.len) return null;
    decoder.decode(blob_buf[0..blob_len], blob_b64) catch return null;

    return ssh.formatFingerprint(blob_buf[0..blob_len]);
}

// write an error to the client's stderr and exit non-zero. stderr (not stdout)
// because the git exec sessions that call this carry the pack protocol on
// stdout, where stray text breaks the client's pkt-line parser.
fn writeError(sess: *ssh.SessionCtx, comptime msg: []const u8) !void {
    try sess.writeStderr("haxy ssh: " ++ msg ++ "\n");
    try sess.exit(1);
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

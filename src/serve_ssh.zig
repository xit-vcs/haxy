const std = @import("std");
const push = @import("push.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;
const Size = xitui.layout.Size;
const ui = @import("./ui.zig");
const ssh = @import("./serve_ssh_protocol.zig");
const evt = @import("./event.zig");
const serve_common = @import("./serve_common.zig");
const fork = @import("./fork.zig");
const progress = @import("./progress.zig");

// listener resource limits. the watchdog gives peers a hard deadline to start
// a session, times out non-interactive sessions that stall while we're blocked
// on the peer, and bounds the post-CLOSE drain.
const max_connections: u32 = 4096;
const watchdog_interval = std.Io.Duration.fromSeconds(5);
const presession_timeout_ticks: u32 = 6; // 30 seconds
const idle_timeout_ticks: u32 = 24; // 120 seconds
const close_drain_timeout_ticks: u32 = 2; // 5-10 seconds
const escape_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .awake } };

var active_connections: std.atomic.Value(u32) = .init(0);

const any_repo_opts: rp.AnyRepoOpts(.xit) = .{ .ProgressCtx = *progress.Sideband };

pub const SessionHandler = struct {
    admin_repo_path: []const u8,
    // where event writes go
    server: evt.Host.Server,
    // the web UI's url, shown in the TUI footer and shared by git's http clones
    web_url: []const u8,
    ssh_url: ?[]const u8,
    git_ssh_prefix: []const u8,
    // the size a pushed repo's db may grow to, or null for no limit
    max_repo_size: ?u64,
    err: *std.Io.Writer,

    /// returning without an exit leaves the protocol layer to send status 0
    pub fn handleSession(self: *const SessionHandler, sess: *ssh.SessionCtx, request: ssh.Request) !void {
        const io = sess.conn.io;
        const start = std.Io.Timestamp.now(io, .awake);
        switch (request) {
            .shell => serve_common.logError(io, self.err, "ssh session: ip={f} kind=shell key={s}\n", .{ sess.conn.peer, sess.fingerprint }),
            .exec => |exec| serve_common.logError(io, self.err, "ssh session: ip={f} kind=exec key={s} cmd=\"{f}\"\n", .{ sess.conn.peer, sess.fingerprint, std.zig.fmtString(exec.command) }),
        }
        const result = self.runSession(sess, request);
        const failure: ?anyerror = if (result) |_| null else |e| sess.underlyingError(e);
        // git otherwise only sees the connection drop. stderr is safe however far its protocol got
        if (failure) |e| if (request == .exec) {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "haxy ssh: {s}\n", .{@errorName(e)}) catch "haxy ssh: internal error\n";
            sess.writeStderr(line) catch {};
        };
        // haxy only closes a session itself to refuse it
        const status: u32 = if (failure != null or sess.closed) 1 else 0;
        serve_common.logError(io, self.err, "ssh session end: ip={f} kind={s} status={d} duration={f} in={d} out={d}{s}{s}\n", .{
            sess.conn.peer,
            @tagName(request),
            status,
            start.untilNow(io, .awake),
            sess.bytes_in,
            sess.bytes_out,
            if (failure != null) " error=" else "",
            if (failure) |e| @errorName(e) else "",
        });
        return result;
    }

    fn runSession(self: *const SessionHandler, sess: *ssh.SessionCtx, request: ssh.Request) !void {
        switch (request) {
            .shell => |shell| {
                const pty = shell.pty orelse {
                    // a shell without a pty has no useful TUI to render; in
                    // openssh client terms this is `ssh -T host`. say so and
                    // exit non-zero.
                    logRefusal(self, sess, "shell without a pty");
                    try sess.writeBytes("haxy ssh: this server only serves the TUI when a pty is allocated (use a normal `ssh` invocation).\r\n");
                    try sess.exit(1);
                    return;
                };
                sess.exemptFromIdleTimeout();
                try runTuiSession(self, sess, pty, shell.color);
            },
            .exec => |exec| {
                try runGitSession(self, sess, exec);
            },
        }
    }
};

pub fn runListener(
    io: std.Io,
    allocator: std.mem.Allocator,
    host_key: *const ssh.HostKey,
    session_handler: *const SessionHandler,
    watchdog: *Watchdog,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Context = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        host_key: *const ssh.HostKey,
        session_handler: *const SessionHandler,
        watchdog: *Watchdog,
        err: *std.Io.Writer,
    };

    const handle = struct {
        fn h(ctx: Context, stream: std.Io.net.Stream) void {
            defer stream.close(ctx.io);
            const peer = stream.socket.address;

            const prev_count = active_connections.fetchAdd(1, .acq_rel);
            defer _ = active_connections.fetchSub(1, .acq_rel);
            if (prev_count >= max_connections) {
                serve_common.logError(ctx.io, ctx.err, "ssh connection limit reached: ip={f}\n", .{peer});
                return;
            }

            var connection = Watchdog.Connection{ .stream = &stream };
            ctx.watchdog.add(ctx.io, &connection);
            defer ctx.watchdog.remove(ctx.io, &connection);

            // timed peeks need room for a complete encrypted packet
            var recv_buf: [ssh.packet_buffer_size]u8 = undefined;
            var send_buf: [4096]u8 = undefined;
            var stream_reader = stream.reader(ctx.io, &recv_buf);
            var stream_writer = stream.writer(ctx.io, &send_buf);
            ssh.handleConnection(
                ctx.io,
                ctx.allocator,
                &stream_reader.interface,
                &stream_writer.interface,
                ctx.host_key,
                &connection.idle_state,
                peer,
                ctx.session_handler,
            ) catch |session_err| {
                // a session logs its own end, and hanging up before one
                // starts is mostly scanners
                if (connection.idle_state.session_started.load(.acquire)) return;
                switch (session_err) {
                    error.EndOfStream, error.UnexpectedEof, error.ReadFailed, error.WriteFailed => {},
                    else => serve_common.logError(ctx.io, ctx.err, "ssh connect failed: ip={f} error={s}\n", .{ peer, @errorName(session_err) }),
                }
            };
        }
    }.h;

    // without the watchdog nothing bounds a connection, so don't listen
    tasks.concurrent(io, Watchdog.run, .{ watchdog, io }) catch |spawn_err| {
        serve_common.logError(io, err, "ssh: watchdog spawn failed: {s}\n", .{@errorName(spawn_err)});
        return;
    };

    serve_common.runListener(io, net_server, tasks, err, "ssh", Context{
        .io = io,
        .allocator = allocator,
        .host_key = host_key,
        .session_handler = session_handler,
        .watchdog = watchdog,
        .err = err,
    }, handle);
}

/// one task watches every connection. a connection links its entry only
/// while it runs, so the watchdog never sees a closed stream.
pub const Watchdog = struct {
    mutex: std.Io.Mutex = .init,
    connections: std.DoublyLinkedList = .{},

    const Connection = struct {
        node: std.DoublyLinkedList.Node = .{},
        stream: *const std.Io.net.Stream,
        idle_state: ssh.IdleState = .{},
        // tick state, touched only by the watchdog
        last_seen: u64 = 0,
        presession_ticks: u32 = 0,
        idle_ticks: u32 = 0,
        closing_ticks: u32 = 0,

        // interactive sessions are exempt only from the idle timeout, so a
        // stalled teardown can still be broken
        fn timedOut(self: *Connection) bool {
            if (self.idle_state.closing.load(.acquire)) {
                self.closing_ticks += 1;
                return self.closing_ticks >= close_drain_timeout_ticks;
            }
            if (!self.idle_state.session_started.load(.acquire)) {
                self.presession_ticks += 1;
                return self.presession_ticks >= presession_timeout_ticks;
            }
            if (self.idle_state.exempt.load(.acquire)) return false;

            // our own work between packets is not the peer idling
            const seen = self.idle_state.activity.load(.acquire);
            defer self.last_seen = seen;
            if (self.idle_state.waiting.load(.acquire) and seen == self.last_seen) {
                self.idle_ticks += 1;
            } else {
                self.idle_ticks = 0;
            }
            return self.idle_ticks >= idle_timeout_ticks;
        }
    };

    fn add(self: *Watchdog, io: std.Io, connection: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connections.append(&connection.node);
    }

    fn remove(self: *Watchdog, io: std.Io, connection: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connections.remove(&connection.node);
    }

    fn run(self: *Watchdog, io: std.Io) void {
        while (true) {
            io.sleep(watchdog_interval, .awake) catch return;
            self.mutex.lock(io) catch return;
            defer self.mutex.unlock(io);
            var node = self.connections.first;
            while (node) |n| : (node = n.next) {
                const connection: *Connection = @fieldParentPtr("node", n);
                if (connection.timedOut()) connection.stream.shutdown(io, .both) catch {};
            }
        }
    }
};

fn runTuiSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize, color: bool) !void {
    // runTui owns the terminal, whose deinit restores the client's screen and
    // runs as the function unwinds — so any error it returns leaves the TUI torn
    // down and we can surface the failure on the restored screen before exiting.
    runTui(handler, sess, pty, color) catch |tui_err| {
        const err = sess.underlyingError(tui_err);
        serve_common.logError(sess.conn.io, handler.err, "ssh tui session failed: ip={f} error={s}\n", .{ sess.conn.peer, @errorName(err) });
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "haxy ssh: {s}\r\n", .{@errorName(err)}) catch "haxy ssh: internal error\r\n";
        sess.writeBytes(msg) catch {};
        try sess.exit(1);
    };
}

fn runTui(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize, color: bool) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    // some clients (notably scripted ssh with no local controlling tty)
    // allocate a pty without ever sending a non-zero size. fall back to a
    // conventional 80x24 in that case so render emits something.
    var terminal_size = Size{
        .width = if (pty.width_cells == 0) 80 else pty.width_cells,
        .height = if (pty.height_cells == 0) 24 else pty.height_cells,
    };

    // session-lifetime allocations (login, prefs); Nav owns the per-page arenas.
    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = handler.admin_repo_path });
    defer repo.deinit(io, allocator);
    var ui_session = try ui.Session.init(&session_arena, &repo, .{});
    ui_session.is_terminal = true;
    ui_session.color = color;
    ui_session.web_url = handler.web_url;
    ui_session.data.git_http_url = handler.web_url;
    ui_session.data.git_ssh_url = handler.ssh_url;
    ui_session.data.git_ssh_prefix = handler.git_ssh_prefix;
    // let page builders open on-disk repos
    ui_session.io = io;
    ui_session.users_dir = handler.server.users_dir;
    ui_session.ssh_key = try authorizedKeyLine(session_arena.allocator(), sess.public_key);
    ui_session.server_log = .{ .writer = handler.err, .peer = try session_arena.allocator().print("{f}", .{sess.conn.peer}) };
    try ui_session.logInWithSshKey();

    var nav = try ui.Nav.init(allocator, &ui_session);
    defer nav.deinit(allocator);

    var session_writer_buf: [8192]u8 = undefined;
    var session_writer = ssh.SessionWriter.init(sess, &session_writer_buf);

    // the terminal's deinit writes leave-alt / show-cursor / disable-mouse and
    // flushes, restoring the client's screen. as a function-scoped defer it runs
    // before runTui returns — on the normal path and on any error — so the
    // caller can write to the client afterward (and sess.exit can close cleanly).
    var terminal_maybe: ?StreamTerminal = try StreamTerminal.init(allocator, &session_writer.interface, terminal_size);
    defer if (terminal_maybe) |*terminal| terminal.deinit();

    // initial render — user sees the page immediately
    if (terminal_maybe) |*terminal| {
        terminal.render_state.no_color = !color;
        try terminal.queryBackground();
        _ = try terminal.render(&nav.root);
    }

    // event loop. nextEvent blocks until something interesting arrives;
    // for each event, rebuild the widget tree and re-render so the user
    // sees the effect of their input on the same iteration.
    event_loop: while (true) {
        const event = try nextTuiEvent(sess, if (terminal_maybe) |*terminal| terminal else null);
        if (event) |ev| switch (ev) {
            .data => |payload| {
                defer allocator.free(payload);
                if (terminal_maybe) |*terminal| {
                    try terminal.writeBytes(payload);
                } else {
                    // the copyable text stays up until enter
                    if (std.mem.indexOfAny(u8, payload, "\r\n") == null) continue;
                    var terminal = try StreamTerminal.init(allocator, &session_writer.interface, terminal_size);
                    terminal.render_state.no_color = !color;
                    terminal_maybe = terminal;
                }
            },
            .resize => |sz| {
                terminal_size = .{ .width = sz.width_cells, .height = sz.height_cells };
                if (terminal_maybe) |*terminal| terminal.pushResize(terminal_size) else continue;
            },
            .eof, .close => break :event_loop,
        };
        if (terminal_maybe) |*terminal| {
            while (terminal.popKey()) |key| {
                try ui.inputKey(allocator, &nav.root, key, &ui_session);
            }
        }

        if (ui_session.host_request) |request| {
            ui_session.host_request = null;
            switch (request) {
                .show_copyable_text => |copyable_text| {
                    if (terminal_maybe) |*terminal| terminal.deinit();
                    terminal_maybe = null;
                    try session_writer.interface.writeAll("\x1b[2J\x1b[Hcopy the following text and then press enter to go back:\r\n\r\n");
                    // the channel has no line discipline, so each line break needs its carriage return
                    var lines = std.mem.splitScalar(u8, copyable_text, '\n');
                    while (lines.next()) |line| try session_writer.interface.print("{s}\r\n", .{line});
                    try session_writer.interface.flush();
                    continue;
                },
                .sync_events => {},
                .undo => |target| ui.Repo.Undo.handleRequest(allocator, &ui_session, target),
            }
        }

        // pick up data written by other handles so the next navigation
        // builds its page from a current moment
        try ui_session.reloadMoment(allocator, &repo);

        // reconcile navigation: forward to a new page, or back on escape.
        // the terminal background can change at any time, so recheck it on each page
        if (try nav.sync(allocator, &ui_session)) {
            if (terminal_maybe) |*terminal| try terminal.queryBackground();
        }

        // the quit button (on the quit tab) asks the host to tear down
        if (ui_session.quit_requested) break :event_loop;

        try nav.root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = terminal_size.width, .height = terminal_size.height },
        }, nav.root.getFocus());
        if (terminal_maybe) |*terminal| _ = try terminal.render(&nav.root);
    }
}

// only ambiguous input (a lone ESC or ESC ]) needs a deadline; longer
// fragments must remain buffered until complete. a timeout leaves partial SSH
// packets in the reader.
pub fn nextTuiEvent(sess: *ssh.SessionCtx, terminal: ?*StreamTerminal) !?ssh.Event {
    if (terminal) |t| {
        if (t.parser.isAmbiguous()) {
            sess.conn.read_timeout = escape_timeout.toDeadline(sess.conn.io);
            defer sess.conn.read_timeout = .none;
            return sess.nextEvent() catch |err| switch (err) {
                error.Timeout => {
                    try t.flushEscape();
                    return null;
                },
                else => return err,
            };
        }
    }
    return try sess.nextEvent();
}

// ---------------------------------------------------------------------------
// git path (exec)
// ---------------------------------------------------------------------------

const GitService = enum { upload_pack, receive_pack };

const ParsedGitCommand = struct {
    service: GitService,
    dir: []u8,

    fn deinit(self: ParsedGitCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
    }
};

fn runGitSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, exec: ssh.Request.Exec) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;
    const protocol_version = xit.net_server_common.parseProtocolVersion(exec.git_protocol);

    // the repo's pack functions consume the channel like any other stream.
    // whatever they leave buffered is flushed before the exit status goes out.
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var reader = ssh.SessionReader.init(sess, &reader_buf);
    var writer = ssh.SessionWriter.init(sess, &writer_buf);
    defer writer.interface.flush() catch {};

    const parsed = parseGitCommand(allocator, exec.command) catch |err| switch (err) {
        error.LfsCommand => return writeLfsError(handler, sess),
        else => return writeError(handler, sess, "unsupported command (expected git-upload-pack or git-receive-pack)"),
    };
    defer parsed.deinit(allocator);
    const repo_identity = std.mem.trimStart(u8, parsed.dir, "/");

    // a "+" names a fork's patch draft
    if (std.mem.indexOfScalar(u8, repo_identity, '+') != null) {
        return runForkSession(handler, sess, repo_identity, parsed.service, protocol_version, &reader.interface, &writer.interface);
    }

    const owner_repo = evt.parseOwnerRepoPath(repo_identity) orelse return writeError(handler, sess, "repo path must be <owner>:<repo>");
    var allowed_arena = std.heap.ArenaAllocator.init(allocator);
    defer allowed_arena.deinit();
    const allowed = switch (try authorizeRepoKey(io, &allowed_arena, handler.admin_repo_path, handler.server.users_dir, owner_repo.owner, owner_repo.name, parsed.service, &sess.fingerprint)) {
        .allowed => |value| value,
        .create => |creator| return runCreatingPush(handler, sess, &creator, owner_repo.name, protocol_version, &reader.interface, &writer.interface),
        .denied => return switch (parsed.service) {
            .upload_pack => writeFingerprintError(handler, sess, "repo not found, or this SSH key can't read it"),
            .receive_pack => writeKeyError(handler, sess, "unauthorized: the account with this SSH key cannot push to this repo"),
        },
        .not_found => return writeError(handler, sess, "repo not found"),
    };

    const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, handler.server.users_dir, handler.admin_repo_path, repo_identity)) {
        .ok => |p| p,
        .invalid => unreachable, // parsed above
        .not_found => return writeError(handler, sess, "repo not found"),
    };
    defer allocator.free(repo_path);

    var any_repo = try rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = repo_path });
    defer any_repo.deinit(io, allocator);

    switch (any_repo) {
        inline else => |*repo| switch (allowed) {
            .fetch => {
                var sideband = progress.Sideband{ .writer = &writer.interface, .sess = sess };
                try repo.uploadPack(io, allocator, &reader.interface, &writer.interface, .{ .protocol_version = protocol_version }, &sideband);
            },
            .push => |pusher| try push.receivePackAndConsume(repo.self_repo_opts, io, allocator, repo, &reader.interface, &writer.interface, .{
                .protocol_version = protocol_version,
                .protected_branches = pusher.protected_branches,
                .locked_branches = pusher.locked_branches,
                .pseudo_ref = .{ .name = push.clear_undo_ref, .deletable = pusher.owner },
            }, pusher.author, &pusher.user_id, handler.server, handler.max_repo_size, handler.err, sess),
        },
    }
}

// push to a repo that doesn't exist yet, creating it in the hash format the
// client's first command names
fn runCreatingPush(
    handler: *const SessionHandler,
    sess: *ssh.SessionCtx,
    creator: *const RepoCreator,
    name: []const u8,
    protocol_version: xit.net_server_common.ProtocolVersion,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    evt.Repo.validateName(name) catch return writeError(handler, sess, "invalid repo name");

    try xit.net_server_receive_pack.advertiseUncreated(.xit, writer, .{ .protocol_version = protocol_version });
    try writer.flush();
    // a client with nothing to push creates nothing
    const hash_kind = (try xit.net_server_receive_pack.peekObjectFormat(reader)) orelse return;

    const location = evt.createRepo(io, allocator, handler.server.users_dir, &creator.owner_id, creator.owner, name, "", .private, hash_kind, null) catch |err| switch (err) {
        error.NameTaken => return writeError(handler, sess, "repo was just created by another push, try again"),
        else => |e| return e,
    };
    const repo_path = try evt.repoPath(allocator, handler.server.users_dir, &location.owner_id, &location.repo_id);
    defer allocator.free(repo_path);

    switch (hash_kind) {
        inline else => |kind| {
            var repo = try rp.Repo(.xit, any_repo_opts.toRepoOptsWithHash(kind)).open(io, allocator, .{ .path = repo_path });
            defer repo.deinit(io, allocator);
            // stateless since the advertisement already went out
            try push.receivePackAndConsume(repo.self_repo_opts, io, allocator, &repo, reader, writer, .{ .protocol_version = protocol_version, .is_stateless = true, .pseudo_ref = .{ .name = push.clear_undo_ref, .deletable = true } }, creator.owner, &creator.owner_id, handler.server, handler.max_repo_size, handler.err, sess);
        },
    }
}

// serve a patch draft: anyone may fetch it, only its author may push to it
fn runForkSession(
    handler: *const SessionHandler,
    sess: *ssh.SessionCtx,
    fork_path: []const u8,
    service: GitService,
    protocol_version: xit.net_server_common.ProtocolVersion,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    const route = fork.parseRoute(fork_path) orelse return writeError(handler, sess, "invalid fork path");
    // the route names the forker and the target repo
    const forker_repo = evt.parseOwnerRepoPath(route.identity) orelse return writeError(handler, sess, "repo path must be <forker>:<repo>");

    var admin = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = handler.admin_repo_path });
    defer admin.deinit(io, allocator);
    var admin_arena = std.heap.ArenaAllocator.init(allocator);
    defer admin_arena.deinit();
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    const fork_id = try evt.parseEventId(&route.id);
    const forker_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, forker_repo.owner)) orelse
        return writeError(handler, sess, "patch draft not found");
    const fork_record = (try evt.readForkById(io, allocator, &admin_arena, handler.server.users_dir, &forker_id, &fork_id)) orelse
        return writeError(handler, sess, "patch draft not found");
    if (fork_record.removed) return writeError(handler, sess, "patch draft not found");
    // the url keeps the name the fork was made under, even after a rename
    if (!std.mem.eql(u8, fork_record.event.repo_name, forker_repo.name)) return writeError(handler, sess, "patch draft not found");
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &admin_arena, &forker_id)) orelse
        return writeError(handler, sess, "invalid patch draft");
    if (user.removed) return writeError(handler, sess, "invalid patch draft");
    if (service == .receive_pack and !try evt.User.holdsKey(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &forker_id, &sess.fingerprint))
        return writeKeyError(handler, sess, "unauthorized: this SSH key is not registered to the patch author");

    const target_owner_id = try evt.parseEventId(&fork_record.event.repo_user_id);
    const target_id = try evt.parseEventId(&fork_record.event.repo_id);
    // a deleted target, or one whose owner was deleted, leaves the fork fetchable but not pushable
    const target = try evt.readRepoById(io, allocator, &admin_arena, handler.server.users_dir, &target_owner_id, &target_id, forker_id);
    if (target) |value| {
        // patches that are off take their drafts with them
        const patch_role = value.repo.event.patch_role orelse return writeError(handler, sess, "patch draft not found");
        if (service == .receive_pack) {
            const role = value.role orelse return writeError(handler, sess, "repo not found");
            if (!role.atLeast(patch_role)) return writeError(handler, sess, "unauthorized: your role in this repo may not write patches");
        }
    }
    if (service == .upload_pack) {
        // a fork is as readable as its target, and only its forker's once the target is gone
        const readable = if (target) |value| readable: {
            const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &admin_arena, &target_owner_id)) orelse unreachable;
            break :readable try authorizeRepoKey(io, &admin_arena, handler.admin_repo_path, handler.server.users_dir, owner.event.name, value.repo.event.name, .upload_pack, &sess.fingerprint) == .allowed;
        } else try evt.User.holdsKey(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &forker_id, &sess.fingerprint);
        if (!readable) return writeKeyError(handler, sess, "unauthorized: the account with this SSH key cannot read this patch draft");
    }

    const draft_path = try fork.forkPath(allocator, handler.server.users_dir, &forker_id, &fork_id);
    defer allocator.free(draft_path);
    var draft = rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = draft_path }) catch
        return writeError(handler, sess, "patch draft not found");
    defer draft.deinit(io, allocator);
    if (service == .upload_pack) {
        var sideband = progress.Sideband{ .writer = writer, .sess = sess };
        switch (draft) {
            inline else => |*repo| try repo.uploadPack(io, allocator, reader, writer, .{ .protocol_version = protocol_version }, &sideband),
        }
    } else {
        if (target == null) return writeError(handler, sess, "the repo this patch draft targets was deleted");
        const target_path = try evt.repoPath(allocator, handler.server.users_dir, &target_owner_id, &target_id);
        defer allocator.free(target_path);
        const author: evt.CommitAuthor = .{ .name = user.event.name, .email = user.event.email };
        const timestamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
        switch (draft) {
            inline else => |*repo| {
                var target_repo = rp.Repo(.xit, repo.self_repo_opts).open(io, allocator, .{ .path = target_path }) catch
                    return writeError(handler, sess, "repo not found or has the wrong hash");
                defer target_repo.deinit(io, allocator);
                try push.receiveFork(repo.self_repo_opts, io, allocator, repo, &target_repo, handler.server, &route.id, author, timestamp, reader, writer, handler.max_repo_size, handler.err, sess);
            },
        }
    }
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
        else if (std.mem.startsWith(u8, service_token, "git-lfs-"))
            return error.LfsCommand
        else
            return error.UnsupportedService;

    return .{ .service = service, .dir = try allocator.dupe(u8, dir_token) };
}

const RepoAuthorization = union(enum) { allowed: Allowed, create: RepoCreator, denied, not_found };

// what a key may do in an existing repo
const Allowed = union(enum) {
    fetch,
    push: Pusher,
};

// the key holder a push acts as
const Pusher = struct {
    user_id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
    protected_branches: []const []const u8,
    locked_branches: []const []const u8,
    // only owners may clear the undo history
    owner: bool,
};

// the owner of a repo a push may create
const RepoCreator = struct {
    owner_id: [evt.event_id_size]u8,
    owner: evt.CommitAuthor,
};

fn authorizeRepoKey(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    admin_repo_path: []const u8,
    users_dir: []const u8,
    owner_name: []const u8,
    repo_name: []const u8,
    service: GitService,
    fingerprint: *const [ssh.fingerprint_len]u8,
) !RepoAuthorization {
    const allocator = arena.child_allocator;
    var admin = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return .not_found,
        else => |e| return e,
    };
    defer admin.deinit(io, allocator);

    const moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    // no viewer yet, so this carries the base role
    const repo = (try evt.readRepoByOwnerAndName(io, allocator, arena, moment, users_dir, owner_name, repo_name, null)) orelse {
        // answered like an unreadable repo, so a private repo's name stays hidden
        if (service == .upload_pack) return .denied;
        const owner_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, owner_name)) orelse return .not_found;
        if (!try evt.User.holdsKey(evt.AdminDB, evt.admin_repo_opts.hash, moment, &owner_id, fingerprint)) return .denied;
        return .{ .create = .{ .owner_id = owner_id, .owner = try commitAuthor(moment, arena, &owner_id) } };
    };

    const min_role: evt.Repo.Role = switch (service) {
        .upload_pack => .read,
        .receive_pack => .write,
    };
    // any key may fetch a public repo; a push always needs a key holder
    if (service == .upload_pack and repo.role != null) return .{ .allowed = .fetch };

    // a shared key acts as its highest-role holder, and only the owner and
    // members rise above the base role
    const owner_id = try evt.parseEventId(&repo.repo.event.user_id);
    var best: ?struct { id: [evt.event_id_size]u8, role: evt.Repo.Role } = null;
    if (try evt.User.holdsKey(evt.AdminDB, evt.admin_repo_opts.hash, moment, &owner_id, fingerprint)) {
        best = .{ .id = owner_id, .role = .owner };
    } else for (try evt.readRepoGrants(io, allocator, arena, users_dir, &owner_id, &repo.event_id)) |grant| {
        const member_id = try evt.parseEventId(&grant.user_id);
        if (!try evt.User.holdsKey(evt.AdminDB, evt.admin_repo_opts.hash, moment, &member_id, fingerprint)) continue;
        if (best) |held| if (held.role.atLeast(grant.role)) continue;
        best = .{ .id = member_id, .role = grant.role };
    }
    const holder = best orelse return .denied;
    if (!holder.role.atLeast(min_role)) return .denied;
    return .{
        .allowed = switch (service) {
            .upload_pack => .fetch,
            .receive_pack => blk: {
                const names = try repo.repo.event.protectedBranchNames(arena.allocator());
                // members change protected branches only by merging a patch
                const owner = holder.role == .owner;
                break :blk .{ .push = .{
                    .user_id = holder.id,
                    .author = try commitAuthor(moment, arena, &holder.id),
                    .protected_branches = if (owner) names else &.{},
                    .locked_branches = if (owner) &.{} else names,
                    .owner = owner,
                } };
            },
        },
    };
}

// an active user as a commit author
fn commitAuthor(
    moment: evt.AdminDB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    user_id: *const [evt.event_id_size]u8,
) !evt.CommitAuthor {
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, user_id)) orelse unreachable;
    return .{ .name = user.event.name, .email = user.event.email };
}

// the authorized_keys line of a pubkey blob: its type, then the blob in base64
fn authorizedKeyLine(allocator: std.mem.Allocator, blob: []const u8) ![]const u8 {
    var reader = std.Io.Reader.fixed(blob);
    const key_type = try ssh.takeString(&reader, 64);
    const encoder = std.base64.standard.Encoder;
    const line = try allocator.alloc(u8, key_type.len + 1 + encoder.calcSize(blob.len));
    @memcpy(line[0..key_type.len], key_type);
    line[key_type.len] = ' ';
    _ = encoder.encode(line[key_type.len + 1 ..], blob);
    return line;
}

// the reason a session was turned away, beside its session lines
fn logRefusal(handler: *const SessionHandler, sess: *ssh.SessionCtx, reason: []const u8) void {
    serve_common.logError(sess.conn.io, handler.err, "ssh refused: ip={f} key={s} reason=\"{s}\"\n", .{ sess.conn.peer, sess.fingerprint, reason });
}

fn writeError(handler: *const SessionHandler, sess: *ssh.SessionCtx, comptime msg: []const u8) !void {
    logRefusal(handler, sess, msg);
    const body = "ERR haxy ssh: " ++ msg;
    var packet: [body.len + 4]u8 = undefined;
    const line = try std.fmt.bufPrint(&packet, "{x:0>4}{s}", .{ packet.len, body });
    try sess.writeBytes(line);
    try sess.exit(1);
}

// git-lfs shows the command's stderr, not git's ERR packet
fn writeLfsError(handler: *const SessionHandler, sess: *ssh.SessionCtx) !void {
    const msg = "Git LFS isn't supported";
    logRefusal(handler, sess, msg);
    try sess.writeStderr("haxy ssh: " ++ msg ++ "\n");
    try sess.exit(1);
}

// a refusal naming the key the client presented. a key on no account gets its
// own message, since clients send whichever key they offer first.
fn writeKeyError(handler: *const SessionHandler, sess: *ssh.SessionCtx, comptime msg: []const u8) !void {
    const known = known: {
        const io = sess.conn.io;
        const allocator = sess.conn.allocator;
        var admin = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = handler.admin_repo_path });
        defer admin.deinit(io, allocator);
        break :known try evt.User.keyHeld(evt.AdminDB, evt.admin_repo_opts.hash, try evt.currentMoment(evt.admin_repo_opts, &admin), &sess.fingerprint);
    };
    if (known) return writeFingerprintError(handler, sess, msg);
    return writeFingerprintError(handler, sess, "unauthorized: this SSH key isn't added to any haxy account. if you have several keys, your SSH client may be offering a different one first");
}

// an error line ending with the presented key's fingerprint
fn writeFingerprintError(handler: *const SessionHandler, sess: *ssh.SessionCtx, comptime msg: []const u8) !void {
    logRefusal(handler, sess, msg);
    const prefix = "ERR haxy ssh: " ++ msg ++ " (key ";
    var packet: [4 + prefix.len + ssh.fingerprint_len + 1]u8 = undefined;
    const line = try std.fmt.bufPrint(&packet, "{x:0>4}" ++ prefix ++ "{s})", .{ packet.len, &sess.fingerprint });
    try sess.writeBytes(line);
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

//! the `ssh-tui` helper subcommand, plus the wire protocol it uses to talk
//! to the tui listener inside `haxy serve`. the protocol types and codecs
//! are shared between this file (which originates the messages) and
//! `serve_ssh_tui.zig` (which consumes them).
//!
//! the session begins with a text prelude:
//!
//!   haxy-tui-v1
//!   user-key=<ssh key fingerprint>
//!   term=<value of $TERM>
//!   width=<u16>
//!   height=<u16>
//!   <empty line>
//!
//! after the empty terminator line, the helper sends a stream of binary
//! frames. each frame is:
//!
//!   1 byte  type
//!   4 bytes payload length (big-endian)
//!   N bytes payload
//!
//! types are:
//!   0x01 data    — raw stdin bytes from the user's terminal
//!   0x02 resize  — payload is 4 bytes: u16 width, u16 height (big-endian)
//!   0x03 close   — empty payload; clean session termination
//!
//! the reverse direction (serve → helper) is unframed: the server writes
//! ANSI bytes and the helper copies them straight to stdout. nothing on
//! that side needs out-of-band signaling.

const std = @import("std");
const builtin = @import("builtin");
const ssh = @import("./ssh.zig");

pub const magic = "haxy-tui-v1";

pub const max_user_key_len: usize = 256;
pub const max_term_len: usize = 64;
pub const max_data_frame_len: usize = 64 * 1024;

pub const Prelude = struct {
    user_key: []const u8,
    term: []const u8,
    width: u16,
    height: u16,

    pub fn deinit(self: Prelude, allocator: std.mem.Allocator) void {
        allocator.free(self.user_key);
        allocator.free(self.term);
    }
};

pub fn writePrelude(writer: *std.Io.Writer, prelude: Prelude) !void {
    try writer.print(
        "{s}\nuser-key={s}\nterm={s}\nwidth={d}\nheight={d}\n\n",
        .{ magic, prelude.user_key, prelude.term, prelude.width, prelude.height },
    );
}

pub fn readPrelude(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Prelude {
    const magic_line = try takeLine(reader);
    if (!std.mem.eql(u8, magic_line, magic)) return error.InvalidMagic;

    const user_key_val = stripPrefix(try takeLine(reader), "user-key=") orelse return error.InvalidPrelude;
    if (user_key_val.len > max_user_key_len) return error.InvalidPrelude;
    const user_key = try allocator.dupe(u8, user_key_val);
    errdefer allocator.free(user_key);

    const term_val = stripPrefix(try takeLine(reader), "term=") orelse return error.InvalidPrelude;
    if (term_val.len > max_term_len) return error.InvalidPrelude;
    const term = try allocator.dupe(u8, term_val);
    errdefer allocator.free(term);

    const width_val = stripPrefix(try takeLine(reader), "width=") orelse return error.InvalidPrelude;
    const width = std.fmt.parseInt(u16, width_val, 10) catch return error.InvalidPrelude;

    const height_val = stripPrefix(try takeLine(reader), "height=") orelse return error.InvalidPrelude;
    const height = std.fmt.parseInt(u16, height_val, 10) catch return error.InvalidPrelude;

    const terminator = try takeLine(reader);
    if (terminator.len != 0) return error.InvalidPrelude;

    return .{ .user_key = user_key, .term = term, .width = width, .height = height };
}

fn takeLine(reader: *std.Io.Reader) ![]const u8 {
    return (try reader.takeDelimiter('\n')) orelse error.InvalidPrelude;
}

fn stripPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

pub const FrameKind = enum(u8) {
    data = 0x01,
    resize = 0x02,
    close = 0x03,
};

pub const Frame = union(FrameKind) {
    data: []u8,
    resize: struct { width: u16, height: u16 },
    close,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        switch (self) {
            .data => |bytes| allocator.free(bytes),
            else => {},
        }
    }
};

pub fn writeDataFrame(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len > max_data_frame_len) return error.FrameTooLarge;
    try writeFrameHeader(writer, .data, @intCast(payload.len));
    try writer.writeAll(payload);
}

pub fn writeResizeFrame(writer: *std.Io.Writer, width: u16, height: u16) !void {
    try writeFrameHeader(writer, .resize, 4);
    try writer.writeInt(u16, width, .big);
    try writer.writeInt(u16, height, .big);
}

pub fn writeCloseFrame(writer: *std.Io.Writer) !void {
    try writeFrameHeader(writer, .close, 0);
}

fn writeFrameHeader(writer: *std.Io.Writer, kind: FrameKind, length: u32) !void {
    try writer.writeByte(@intFromEnum(kind));
    try writer.writeInt(u32, length, .big);
}

pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Frame {
    const type_byte = try reader.takeByte();
    const length = try reader.takeInt(u32, .big);
    const kind: FrameKind = switch (type_byte) {
        @intFromEnum(FrameKind.data) => .data,
        @intFromEnum(FrameKind.resize) => .resize,
        @intFromEnum(FrameKind.close) => .close,
        else => return error.InvalidFrameType,
    };

    return switch (kind) {
        .data => blk: {
            if (length > max_data_frame_len) return error.FrameTooLarge;
            const payload = try reader.readAlloc(allocator, length);
            break :blk .{ .data = payload };
        },
        .resize => blk: {
            if (length != 4) return error.InvalidResizeFrame;
            const w = try reader.takeInt(u16, .big);
            const h = try reader.takeInt(u16, .big);
            break :blk .{ .resize = .{ .width = w, .height = h } };
        },
        .close => blk: {
            if (length != 0) return error.InvalidCloseFrame;
            break :blk .close;
        },
    };
}

// helper subcommand: connects to the tui listener and proxies the user's
// PTY in both directions. invoked by sshd via a forced-command entry in
// authorized_keys.

pub const Options = struct {
    tui_connect: []const u8 = blk: {
        const srv = @import("./serve.zig");
        const opts: srv.Options = .{};
        break :blk opts.tui_listen;
    },
    user_key: ?[]const u8 = null,
};

// SIGWINCH delivers no context; the handler reads this file-scope fd to
// know where to write its wake-up byte. set by run() before sigaction is
// installed; reset on the way out.
var sigwinch_pipe_write: std.posix.fd_t = -1;

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    environ_map: *std.process.Environ.Map,
) !void {
    _ = allocator;

    if (builtin.os.tag == .windows) return error.WindowsNotSupported;

    const user_key = options.user_key orelse return error.MissingUserKey;
    const term_name = environ_map.get("TERM") orelse "xterm";

    const initial_size = try getWinSize(io);

    const conn = try ssh.parseConnectAddress(options.tui_connect);
    const address = try std.Io.net.IpAddress.parseIp4(conn.host, conn.port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // put stdin into raw mode so the server sees user keystrokes as-is.
    // restore the original termios on the way out so we don't leave the
    // user's shell in a broken state if anything throws.
    const cooked = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, cooked) catch {};
    try setRawMode(std.posix.STDIN_FILENO, cooked);

    // self-pipe: SIGWINCH handler writes a byte, stdinProxy polls on the
    // read end and converts it into a resize frame.
    const pipe_fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer {
        sigwinch_pipe_write = -1;
        _ = std.posix.system.close(pipe_fds[1]);
        _ = std.posix.system.close(pipe_fds[0]);
    }
    sigwinch_pipe_write = pipe_fds[1];

    std.posix.sigaction(std.posix.SIG.WINCH, &.{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    // prelude
    var prelude_buf: [1024]u8 = undefined;
    var prelude_writer = stream.writer(io, &prelude_buf);
    try writePrelude(&prelude_writer.interface, .{
        .user_key = user_key,
        .term = term_name,
        .width = initial_size.width,
        .height = initial_size.height,
    });
    try prelude_writer.interface.flush();

    // stdin proxy thread: frames stdin bytes + emits resize frames on
    // SIGWINCH. detached so we don't have to coordinate shutdown — when
    // run() returns, the process exits and the thread goes with it.
    const ctx = StdinThreadCtx{ .io = io, .stream = stream, .pipe_read = pipe_fds[0] };
    const stdin_thread = try std.Thread.spawn(.{}, stdinProxy, .{ctx});
    stdin_thread.detach();

    // main: socket → stdout, raw. server's already-formed ANSI bytes pass
    // straight through to the user's terminal.
    try ssh.copyFd(stream.socket.handle, std.posix.STDOUT_FILENO);
}

fn sigwinchHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = sigwinch_pipe_write;
    if (fd >= 0) {
        const byte = [_]u8{1};
        _ = std.posix.system.write(fd, byte[0..].ptr, 1);
    }
}

fn setRawMode(fd: std.posix.fd_t, cooked: std.posix.termios) !void {
    var raw = cooked;
    raw.iflag = .{};
    raw.oflag = .{};
    raw.lflag = .{};
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
}

const WinSize = struct { width: u16, height: u16 };

// fall back to a conventional 80x24 if the PTY hasn't been told a size yet —
// this happens when the SSH client has no local controlling terminal (e.g.
// non-interactive piped input) and never sends a window-change request.
const default_width: u16 = 80;
const default_height: u16 = 24;

fn getWinSize(io: std.Io) !WinSize {
    var ws: std.posix.winsize = undefined;
    const result = (try io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } })).device_io_control;
    if (result < 0) return error.IoctlFailed;
    return .{
        .width = if (ws.col == 0) default_width else ws.col,
        .height = if (ws.row == 0) default_height else ws.row,
    };
}

const StdinThreadCtx = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    pipe_read: std.posix.fd_t,
};

fn stdinProxy(ctx: StdinThreadCtx) void {
    var send_buf: [4096]u8 = undefined;
    var stream_writer = ctx.stream.writer(ctx.io, &send_buf);
    const w = &stream_writer.interface;

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = ctx.pipe_read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch return;

        if (fds[1].revents & std.posix.POLL.IN != 0) {
            // drain whatever's in the pipe — multiple coalesced SIGWINCHes
            // all collapse into one resize-frame emission.
            var drain: [16]u8 = undefined;
            _ = std.posix.read(ctx.pipe_read, &drain) catch {};
            if (getWinSize(ctx.io)) |size| {
                writeResizeFrame(w, size.width, size.height) catch return;
                w.flush() catch return;
            } else |_| {}
        }
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return;
            if (n == 0) {
                writeCloseFrame(w) catch {};
                w.flush() catch {};
                ctx.stream.shutdown(ctx.io, .send) catch {};
                return;
            }
            writeDataFrame(w, buf[0..n]) catch return;
            w.flush() catch return;
        }
    }
}

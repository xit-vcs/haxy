//! In-process SSH server: full server side of SSH-2 for haxy's use case.
//!
//! handles, per connection: version exchange, KEXINIT, curve25519 key
//! exchange, NEWKEYS, key derivation, chacha20-poly1305 packet codec,
//! strict kex (Terrapin mitigation), client-initiated rekeying,
//! ssh-userauth service request, publickey authentication (ed25519 only;
//! captures the SHA256 fingerprint of the verified key), channel-layer
//! requests (pty-req, env, window-change, shell, exec), CHANNEL_DATA
//! flow with sender/receiver windows, and clean teardown
//! (exit-status / EOF / CLOSE).
//!
//! public surface for haxy code:
//!   handleConnection — call from the listener with a session handler.
//!   SessionCtx       — handed to the handler; carries the channel + ciphers,
//!                      the verified key's fingerprint, and an event /
//!                      writeBytes / exit API.
//!   SessionReader / SessionWriter — std.Io adapters so consumers (xit's
//!                      pack code, StreamTerminal, etc.) can use ordinary
//!                      Reader/Writer interfaces.
//!   Request          — what the client asked for: shell+pty or exec command.
//!   HostKey          — generated or loaded once at startup.
//!
//! hardcoded choices to keep the implementation small:
//!   KEX:       curve25519-sha256 (RFC 8731)
//!   host key:  ssh-ed25519       (RFC 8709)
//!   cipher:    chacha20-poly1305@openssh.com (RFC 4253 + openssh extension)
//!   MAC:       none (implicit in AEAD)
//!   compress:  none
//!   user auth: publickey + ssh-ed25519 only (RSA/ECDSA deferred)

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ChaCha20 = std.crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = std.crypto.onetimeauth.Poly1305;

pub const server_version = "SSH-2.0-haxy_0.0";
pub const host_key_file_name = "ssh_host_ed25519_key";

const max_packet_len: u32 = 35000; // RFC 4253 §6.1 — minimum implementations must support
const max_name_list_len: u32 = 4096;
const max_auth_attempts: u32 = 20;
const max_exit_drain_packets: u32 = 32;
const max_banner_lines: u32 = 32;

// SSH message type bytes (RFC 4250 §4.1)
pub const SSH_MSG_DISCONNECT: u8 = 1;
pub const SSH_MSG_IGNORE: u8 = 2;
pub const SSH_MSG_UNIMPLEMENTED: u8 = 3;
pub const SSH_MSG_DEBUG: u8 = 4;
pub const SSH_MSG_SERVICE_REQUEST: u8 = 5;
pub const SSH_MSG_SERVICE_ACCEPT: u8 = 6;
pub const SSH_MSG_KEXINIT: u8 = 20;
pub const SSH_MSG_NEWKEYS: u8 = 21;
pub const SSH_MSG_KEX_ECDH_INIT: u8 = 30;
pub const SSH_MSG_KEX_ECDH_REPLY: u8 = 31;
pub const SSH_MSG_USERAUTH_REQUEST: u8 = 50;
pub const SSH_MSG_USERAUTH_FAILURE: u8 = 51;
pub const SSH_MSG_USERAUTH_SUCCESS: u8 = 52;
pub const SSH_MSG_USERAUTH_PK_OK: u8 = 60; // method-specific name for publickey
pub const SSH_MSG_GLOBAL_REQUEST: u8 = 80;
pub const SSH_MSG_REQUEST_SUCCESS: u8 = 81;
pub const SSH_MSG_REQUEST_FAILURE: u8 = 82;
pub const SSH_MSG_CHANNEL_OPEN: u8 = 90;
pub const SSH_MSG_CHANNEL_OPEN_CONFIRMATION: u8 = 91;
pub const SSH_MSG_CHANNEL_OPEN_FAILURE: u8 = 92;
pub const SSH_MSG_CHANNEL_WINDOW_ADJUST: u8 = 93;
pub const SSH_MSG_CHANNEL_DATA: u8 = 94;
pub const SSH_MSG_CHANNEL_EXTENDED_DATA: u8 = 95;
pub const SSH_MSG_CHANNEL_EOF: u8 = 96;
pub const SSH_MSG_CHANNEL_CLOSE: u8 = 97;
pub const SSH_MSG_CHANNEL_REQUEST: u8 = 98;
pub const SSH_MSG_CHANNEL_SUCCESS: u8 = 99;
pub const SSH_MSG_CHANNEL_FAILURE: u8 = 100;

pub const SSH_DISCONNECT_PROTOCOL_ERROR: u32 = 2;

// SSH_OPEN_* reason codes for CHANNEL_OPEN_FAILURE
pub const SSH_OPEN_RESOURCE_SHORTAGE: u32 = 4;
pub const SSH_OPEN_UNKNOWN_CHANNEL_TYPE: u32 = 3;

// data type code for CHANNEL_EXTENDED_DATA (stderr)
pub const SSH_EXTENDED_DATA_STDERR: u32 = 1;

// initial flow-control window we advertise. typical openssh setting; large
// enough that small interactive sessions never need a WINDOW_ADJUST.
const initial_recv_window: u32 = 1 << 20;
const max_packet_size: u32 = 32768;
const max_incoming_buffered: usize = initial_recv_window;
const incoming_refill_threshold: usize = max_incoming_buffered / 2;

/// shared with the host's idle watchdog. `activity` is bumped on every
/// successfully decrypted packet so the watchdog can tell an idle connection
/// from a slow one; `exempt` is set once an interactive session starts,
/// since users idle in a TUI legitimately.
pub const IdleState = struct {
    activity: std.atomic.Value(u64) = .init(0),
    exempt: std.atomic.Value(bool) = .init(false),
};

// ---------------------------------------------------------------------------
// host key
// ---------------------------------------------------------------------------

pub const HostKey = struct {
    keypair: Ed25519.KeyPair,

    pub fn loadOrGenerate(io: std.Io, allocator: std.mem.Allocator, data_dir_path: []const u8) !HostKey {
        const path = try std.fs.path.join(allocator, &.{ data_dir_path, host_key_file_name });
        defer allocator.free(path);

        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(io, path, .{ .mode = .read_only })) |file| {
            defer file.close(io);
            var buf: [Ed25519.SecretKey.encoded_length]u8 = undefined;
            var read_storage: [128]u8 = undefined;
            var file_reader = file.reader(io, &read_storage);
            try file_reader.interface.readSliceAll(&buf);
            const sk = try Ed25519.SecretKey.fromBytes(buf);
            const keypair = try Ed25519.KeyPair.fromSecretKey(sk);
            return .{ .keypair = keypair };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const keypair = Ed25519.KeyPair.generate(io);
        // owner-only from the start — never a window where the key is readable
        const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
        const file = try cwd.createFile(io, path, .{ .permissions = permissions });
        defer file.close(io);
        try file.writeStreamingAll(io, &keypair.secret_key.bytes);
        return .{ .keypair = keypair };
    }

    /// SSH wire-format ed25519 public key blob (used as K_S in the hash and
    /// returned in KEX_ECDH_REPLY): string "ssh-ed25519" || string pubkey.
    pub fn appendPublicBlob(self: HostKey, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try writeStringField(buf, allocator, "ssh-ed25519");
        try writeStringField(buf, allocator, &self.keypair.public_key.bytes);
    }

    /// SSH wire-format signature blob: string "ssh-ed25519" || string sig.
    fn appendSignatureBlob(self: HostKey, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, message: []const u8) !void {
        const sig = try self.keypair.sign(message, null);
        const sig_bytes = sig.toBytes();
        try writeStringField(buf, allocator, "ssh-ed25519");
        try writeStringField(buf, allocator, &sig_bytes);
    }
};

// ---------------------------------------------------------------------------
// public session API
// ---------------------------------------------------------------------------

/// what the client wants to do on this channel.
pub const Request = union(enum) {
    shell: ?PtySize, // pty info if a pty-req arrived before the shell
    exec: []const u8, // command string from the exec request
};

/// next thing that arrived from the client.
pub const Event = union(enum) {
    data: []u8, // CHANNEL_DATA payload — caller owns and must free via sess.allocator
    resize: PtySize, // window-change request
    close, // peer sent EOF or CHANNEL_CLOSE
};

/// session bridge handed to the consumer's handleSession callback. exposes a
/// pumped event API plus a byte-write API; the byte stream goes out as
/// CHANNEL_DATA packets respecting the channel's flow-control window.
pub const SessionCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: *Cipher,
    sc_cipher: *Cipher,
    rekey: *const RekeyState,
    channel: *Channel,
    /// SHA256 fingerprint of the pubkey this session authenticated with,
    /// formatted as "SHA256:<base64-no-padding>" — same value the openssh
    /// client logs as `Offering public key: ED25519 SHA256:…`. consumers
    /// can use it as a stable per-key identity.
    fingerprint: [fingerprint_len]u8,
    closed: bool = false,

    // shared state for the blocking I/O mode (SessionReader + writeBytes
    // window-stall pump). incoming CHANNEL_DATA bytes accumulate here
    // until the consumer drains them via SessionReader.
    incoming_buffer: std.ArrayList(u8) = .empty,
    incoming_eof: bool = false,
    // resize seen by the background pump, returned by the next nextEvent call
    pending_resize: ?PtySize = null,

    pub fn deinit(self: *SessionCtx) void {
        self.incoming_buffer.deinit(self.allocator);
    }

    /// interactive sessions idle legitimately; tell the host's idle
    /// watchdog to stand down for the rest of this connection.
    pub fn exemptFromIdleTimeout(self: *SessionCtx) void {
        if (self.cs_cipher.idle) |idle| idle.exempt.store(true, .monotonic);
    }

    /// pump SSH packets until something interesting (data / resize / close)
    /// arrives. background traffic (window adjusts, env requests, etc.) is
    /// handled silently. used by pumped-event consumers (e.g. the TUI path);
    /// do not mix with SessionReader, which has its own packet pump.
    pub fn nextEvent(self: *SessionCtx) !Event {
        if (self.pending_resize) |sz| {
            self.pending_resize = null;
            return .{ .resize = sz };
        }
        while (true) {
            const packet = readSessionPacket(self.io, self.allocator, self.reader, self.writer, self.cs_cipher, self.sc_cipher, self.rekey) catch |err| switch (err) {
                error.EndOfStream => {
                    self.closed = true;
                    return .close;
                },
                else => return err,
            };
            defer self.allocator.free(packet);
            if (packet.len < 1) return error.EmptyPacket;

            switch (packet[0]) {
                SSH_MSG_CHANNEL_DATA => {
                    const payload = try parseChannelData(packet, false, self.channel.local_id);
                    const data_len: u32 = @intCast(payload.len);
                    if (data_len > self.channel.local_window) return error.WindowExceeded;
                    self.channel.local_window -= data_len;
                    try maybeRefillRecvWindow(self.io, self.allocator, self.sc_cipher, self.writer, self.channel);
                    // hand the payload bytes to the caller (caller owns)
                    return .{ .data = try self.allocator.dupe(u8, payload) };
                },
                SSH_MSG_CHANNEL_EXTENDED_DATA => {
                    // stderr from the client is unusual; discard, but adjust window
                    try discardChannelData(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, packet, true);
                },
                SSH_MSG_CHANNEL_WINDOW_ADJUST => try handleWindowAdjust(self.channel, packet),
                SSH_MSG_CHANNEL_REQUEST => {
                    var r = std.Io.Reader.fixed(packet[1..]);
                    const recipient_channel = try r.takeInt(u32, .big);
                    if (recipient_channel != self.channel.local_id) return error.UnknownChannel;
                    const req_type = try takeStringField(self.allocator, &r, 64);
                    defer self.allocator.free(req_type);
                    const want_reply = (try r.takeByte()) != 0;
                    if (std.mem.eql(u8, req_type, "window-change")) {
                        const sz = try takePtySize(&r);
                        if (self.channel.pty != null) self.channel.pty = sz;
                        try replyChannelRequest(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, want_reply, true);
                        return .{ .resize = sz };
                    }
                    // unknown / not interesting — fail it and keep going
                    try replyChannelRequest(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, want_reply, false);
                },
                SSH_MSG_CHANNEL_EOF, SSH_MSG_CHANNEL_CLOSE => {
                    try parseChannelId(packet, self.channel.local_id);
                    self.closed = true;
                    return .close;
                },
                SSH_MSG_GLOBAL_REQUEST => try handleGlobalRequest(self.io, self.allocator, self.sc_cipher, self.writer, packet),
                else => {},
            }
        }
    }

    /// send bytes to the client's stdout (CHANNEL_DATA).
    pub fn writeBytes(self: *SessionCtx, bytes: []const u8) !void {
        try self.writeChannel(bytes, false);
    }

    /// send bytes to the client's stderr (CHANNEL_EXTENDED_DATA). use this for
    /// server messages on a git exec session, where stdout carries the pack
    /// protocol and stray text breaks the client's pkt-line parser.
    pub fn writeStderr(self: *SessionCtx, bytes: []const u8) !void {
        try self.writeChannel(bytes, true);
    }

    /// ship bytes as one or more stdout CHANNEL_DATA (or stderr
    /// CHANNEL_EXTENDED_DATA) packets, respecting the peer's max-packet size.
    /// if the remote window is exhausted, pump incoming SSH packets until a
    /// WINDOW_ADJUST arrives (background packets are processed for their side
    /// effects — incoming CHANNEL_DATA goes into incoming_buffer for a future
    /// SessionReader).
    fn writeChannel(self: *SessionCtx, bytes: []const u8, extended: bool) !void {
        var rest = bytes;
        while (rest.len > 0) {
            while (self.channel.remote_window == 0) {
                if (self.incoming_eof) return error.RemoteClosed;
                try self.processOneBackgroundPacket();
            }
            const cap = @min(@min(rest.len, self.channel.max_packet), self.channel.remote_window);
            const chunk_len: u32 = @intCast(cap);

            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            try msg.append(self.allocator, if (extended) SSH_MSG_CHANNEL_EXTENDED_DATA else SSH_MSG_CHANNEL_DATA);
            try writeU32(&msg, self.allocator, self.channel.remote_id);
            if (extended) try writeU32(&msg, self.allocator, SSH_EXTENDED_DATA_STDERR);
            try writeStringField(&msg, self.allocator, rest[0..chunk_len]);
            try self.sc_cipher.writePacket(self.io, self.allocator, self.writer, msg.items);

            self.channel.remote_window -= chunk_len;
            rest = rest[chunk_len..];
        }
    }

    /// process exactly one SSH packet for side effects only. CHANNEL_DATA
    /// payloads accumulate in incoming_buffer; CHANNEL_EOF/CLOSE flips
    /// incoming_eof; WINDOW_ADJUST updates the channel state; window-change
    /// is stashed in pending_resize for the next nextEvent call; other
    /// channel/global requests get a polite failure. used both by
    /// SessionReader (waiting for inbound bytes) and writeBytes (waiting
    /// for send-window).
    fn processOneBackgroundPacket(self: *SessionCtx) !void {
        const packet = readSessionPacket(self.io, self.allocator, self.reader, self.writer, self.cs_cipher, self.sc_cipher, self.rekey) catch |err| switch (err) {
            error.EndOfStream => {
                self.incoming_eof = true;
                return;
            },
            else => return err,
        };
        defer self.allocator.free(packet);
        if (packet.len < 1) return;

        switch (packet[0]) {
            SSH_MSG_CHANNEL_DATA => {
                const payload = try parseChannelData(packet, false, self.channel.local_id);
                const data_len: u32 = @intCast(payload.len);
                if (data_len > self.channel.local_window) return error.WindowExceeded;
                self.channel.local_window -= data_len;
                if (payload.len > max_incoming_buffered - self.incoming_buffer.items.len) {
                    return error.IncomingBufferExceeded;
                }
                try self.incoming_buffer.appendSlice(self.allocator, payload);
                try self.maybeRefillRecvWindowForBufferedInput();
            },
            SSH_MSG_CHANNEL_EXTENDED_DATA => {
                try discardChannelData(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, packet, true);
            },
            SSH_MSG_CHANNEL_WINDOW_ADJUST => try handleWindowAdjust(self.channel, packet),
            SSH_MSG_CHANNEL_REQUEST => {
                var r = std.Io.Reader.fixed(packet[1..]);
                const recipient_channel = try r.takeInt(u32, .big);
                if (recipient_channel != self.channel.local_id) return error.UnknownChannel;
                const req_type = try takeStringField(self.allocator, &r, 64);
                defer self.allocator.free(req_type);
                const want_reply = (try r.takeByte()) != 0;
                if (std.mem.eql(u8, req_type, "window-change")) {
                    const sz = try takePtySize(&r);
                    if (self.channel.pty != null) self.channel.pty = sz;
                    self.pending_resize = sz;
                    try replyChannelRequest(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, want_reply, true);
                } else {
                    // other mid-session channel requests aren't honored — fail them
                    try replyChannelRequest(self.io, self.allocator, self.sc_cipher, self.writer, self.channel, want_reply, false);
                }
            },
            SSH_MSG_CHANNEL_EOF, SSH_MSG_CHANNEL_CLOSE => {
                try parseChannelId(packet, self.channel.local_id);
                self.incoming_eof = true;
            },
            SSH_MSG_GLOBAL_REQUEST => try handleGlobalRequest(self.io, self.allocator, self.sc_cipher, self.writer, packet),
            else => {},
        }
    }

    fn maybeRefillRecvWindowForBufferedInput(self: *SessionCtx) !void {
        if (self.incoming_buffer.items.len >= incoming_refill_threshold) return;
        try maybeRefillRecvWindow(self.io, self.allocator, self.sc_cipher, self.writer, self.channel);
    }

    /// signal the consumer's exit status and tear the channel down.
    pub fn exit(self: *SessionCtx, status: u32) !void {
        if (self.closed) return;
        self.closed = true;

        // exit-status request (informational; client uses it as the
        // command's exit code)
        {
            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(self.allocator);
            try req.append(self.allocator, SSH_MSG_CHANNEL_REQUEST);
            try writeU32(&req, self.allocator, self.channel.remote_id);
            try writeStringField(&req, self.allocator, "exit-status");
            try req.append(self.allocator, 0); // want_reply MUST be false
            try writeU32(&req, self.allocator, status);
            try self.sc_cipher.writePacket(self.io, self.allocator, self.writer, req.items);
        }

        // EOF then CLOSE
        var eof: std.ArrayList(u8) = .empty;
        defer eof.deinit(self.allocator);
        try eof.append(self.allocator, SSH_MSG_CHANNEL_EOF);
        try writeU32(&eof, self.allocator, self.channel.remote_id);
        try self.sc_cipher.writePacket(self.io, self.allocator, self.writer, eof.items);

        var close: std.ArrayList(u8) = .empty;
        defer close.deinit(self.allocator);
        try close.append(self.allocator, SSH_MSG_CHANNEL_CLOSE);
        try writeU32(&close, self.allocator, self.channel.remote_id);
        try self.sc_cipher.writePacket(self.io, self.allocator, self.writer, close.items);

        // read and discard until the peer closes (TCP FIN) before letting the
        // caller close the socket. a git client, after our CHANNEL_CLOSE, still
        // sends its own CHANNEL_CLOSE and SSH_MSG_DISCONNECT before closing; if
        // we close with those unread, Linux sends RST instead of FIN, which the
        // client reports as "Connection reset by peer" and treats as a failed
        // push even though the ref updated. draining to EOF leaves nothing
        // unread, so we send a clean FIN. we're tearing down, so the packet
        // contents don't matter — just get them off the socket.
        var drain_packets: u32 = 0;
        while (drain_packets < max_exit_drain_packets) : (drain_packets += 1) {
            const packet = self.cs_cipher.readPacket(self.allocator, self.reader) catch break;
            self.allocator.free(packet);
        }
    }
};

/// std.Io.Writer adapter that ships bytes to a SessionCtx as CHANNEL_DATA.
/// useful for plugging the session into anything that wants a *std.Io.Writer
/// (e.g. xitui.StreamTerminal).
pub const SessionWriter = struct {
    interface: std.Io.Writer,
    sess: *SessionCtx,

    pub fn init(sess: *SessionCtx, buffer: []u8) SessionWriter {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
            .sess = sess,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SessionWriter = @fieldParentPtr("interface", w);

        // first ship anything already accumulated in the Writer's buffer
        const buffered = w.buffered();
        if (buffered.len > 0) {
            self.sess.writeBytes(buffered) catch return error.WriteFailed;
        }

        // then ship the bytes passed in directly. data[0..len-1] are written
        // once each; data[len-1] is written `splat` times (this is how the
        // Writer interface represents fan-out / repeated patterns).
        var extra: usize = 0;
        if (data.len > 1) {
            for (data[0 .. data.len - 1]) |chunk| {
                if (chunk.len == 0) continue;
                self.sess.writeBytes(chunk) catch return error.WriteFailed;
                extra += chunk.len;
            }
        }
        if (data.len > 0) {
            const pattern = data[data.len - 1];
            if (pattern.len > 0) {
                var i: usize = 0;
                while (i < splat) : (i += 1) {
                    self.sess.writeBytes(pattern) catch return error.WriteFailed;
                    extra += pattern.len;
                }
            }
        }

        // consume tells the Writer how many bytes (buffered + data) were
        // processed and clears w.end. it returns the count attributed to
        // data, which is what `write` propagates back to the caller.
        return w.consume(buffered.len + extra);
    }
};

/// std.Io.Reader adapter that drains incoming CHANNEL_DATA from a SessionCtx.
/// when the consumer reads beyond what's buffered, runs the SSH packet loop
/// (via processOneBackgroundPacket) until more bytes arrive or the peer
/// closes the channel.
pub const SessionReader = struct {
    interface: std.Io.Reader,
    sess: *SessionCtx,

    pub fn init(sess: *SessionCtx, buffer: []u8) SessionReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .readVec = readVec,
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .sess = sess,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SessionReader = @fieldParentPtr("interface", r);

        // wait for data to arrive (or EOF)
        while (self.sess.incoming_buffer.items.len == 0) {
            if (self.sess.incoming_eof) return error.EndOfStream;
            self.sess.processOneBackgroundPacket() catch return error.ReadFailed;
        }

        // drain as much of incoming_buffer as the limit allows, in one go
        const chunk = limit.sliceConst(self.sess.incoming_buffer.items);
        const written = try w.write(chunk);

        std.mem.copyForwards(u8, self.sess.incoming_buffer.items, self.sess.incoming_buffer.items[written..]);
        self.sess.incoming_buffer.shrinkRetainingCapacity(self.sess.incoming_buffer.items.len - written);
        self.sess.maybeRefillRecvWindowForBufferedInput() catch return error.ReadFailed;

        return written;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *SessionReader = @fieldParentPtr("interface", r);

        // wait until something is in incoming_buffer (or EOF)
        while (self.sess.incoming_buffer.items.len == 0) {
            if (self.sess.incoming_eof) return error.EndOfStream;
            self.sess.processOneBackgroundPacket() catch return error.ReadFailed;
        }

        const src = self.sess.incoming_buffer.items;

        // vtable.readVec contract: if data[0] is empty, write into r.buffer
        // instead and return 0. without this branch the caller spins,
        // calling readVec repeatedly with the same empty buffer.
        if (data.len == 0 or data[0].len == 0) {
            const dest = r.buffer[r.end..];
            if (dest.len == 0) return 0;
            const copy = @min(dest.len, src.len);
            @memcpy(dest[0..copy], src[0..copy]);
            r.end += copy;
            std.mem.copyForwards(u8, self.sess.incoming_buffer.items, src[copy..]);
            self.sess.incoming_buffer.shrinkRetainingCapacity(src.len - copy);
            self.sess.maybeRefillRecvWindowForBufferedInput() catch return error.ReadFailed;
            return 0;
        }

        const dest = data[0];
        const copy = @min(dest.len, src.len);
        @memcpy(dest[0..copy], src[0..copy]);
        std.mem.copyForwards(u8, self.sess.incoming_buffer.items, src[copy..]);
        self.sess.incoming_buffer.shrinkRetainingCapacity(src.len - copy);
        self.sess.maybeRefillRecvWindowForBufferedInput() catch return error.ReadFailed;
        return copy;
    }
};

// ---------------------------------------------------------------------------
// public entry point
// ---------------------------------------------------------------------------

/// `handler` must be a pointer to a struct with a method:
///   pub fn handleSession(self, sess: *SessionCtx, request: Request) anyerror!void
/// invoked once the channel is open and a shell/exec request has arrived.
///
/// `reader` and `writer` are the bidirectional byte stream. `idle`, if
/// given, is bumped on packet reads for the host's idle watchdog.
pub fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_key: *const HostKey,
    idle: ?*IdleState,
    handler: anytype,
) !void {
    const client_version = try exchangeVersions(allocator, reader, writer);
    defer allocator.free(client_version);

    const kex = try runKex(io, allocator, reader, writer, host_key, client_version);

    // post-KEX everything is encrypted with chacha20-poly1305@openssh.com
    var cs_cipher = Cipher.init(&kex.cs_key, kex.next_cs_seq);
    var sc_cipher = Cipher.init(&kex.sc_key, kex.next_sc_seq);
    cs_cipher.idle = idle;

    const rekey = RekeyState{
        .host_key = host_key,
        .client_version = client_version,
        .session_id = kex.session_id,
        .strict = kex.strict,
    };

    const fingerprint = try runAuth(io, allocator, reader, writer, &cs_cipher, &sc_cipher, &rekey);

    try runChannelLayer(io, allocator, reader, writer, &cs_cipher, &sc_cipher, &rekey, &fingerprint, handler);
}

// ---------------------------------------------------------------------------
// version exchange (RFC 4253 §4.2)
// ---------------------------------------------------------------------------

fn exchangeVersions(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) ![]u8 {
    try writer.writeAll(server_version ++ "\r\n");
    try writer.flush();

    // the spec allows the client to send comment lines before its banner;
    // skip anything that isn't an "SSH-2.0-…" / "SSH-1.99-…" line, up to a cap
    // so a garbage-spewing peer can't hold the connection open forever.
    var lines: u32 = 0;
    while (lines < max_banner_lines) : (lines += 1) {
        const line = (try reader.takeDelimiter('\n')) orelse return error.UnexpectedEof;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (std.mem.startsWith(u8, trimmed, "SSH-2.0-") or std.mem.startsWith(u8, trimmed, "SSH-1.99-")) {
            return try allocator.dupe(u8, trimmed);
        }
    }
    return error.TooManyBannerLines;
}

// ---------------------------------------------------------------------------
// binary packet codec, unencrypted form (RFC 4253 §6)
// ---------------------------------------------------------------------------

pub fn writePlainPacket(io: std.Io, writer: *std.Io.Writer, payload: []const u8) !void {
    const block: usize = 8;
    const initial_pad = block - ((5 + payload.len) % block);
    const padding_len: u8 = @intCast(if (initial_pad < 4) initial_pad + block else initial_pad);
    const packet_len: u32 = @intCast(1 + payload.len + padding_len);

    try writer.writeInt(u32, packet_len, .big);
    try writer.writeByte(padding_len);
    try writer.writeAll(payload);

    var padding: [255]u8 = undefined;
    io.random(padding[0..padding_len]);
    try writer.writeAll(padding[0..padding_len]);
    try writer.flush();
}

pub fn readPlainPacket(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const packet_len = try reader.takeInt(u32, .big);
    if (packet_len < 8 or packet_len > max_packet_len) return error.InvalidPacketLength;
    const padding_len = try reader.takeByte();
    if (padding_len < 4 or @as(u32, padding_len) + 1 > packet_len) return error.InvalidPadding;
    const payload_len = packet_len - 1 - @as(u32, padding_len);

    const payload = try reader.readAlloc(allocator, payload_len);
    errdefer allocator.free(payload);
    try reader.discardAll(padding_len);
    return payload;
}

// IGNORE/DEBUG/UNIMPLEMENTED may arrive at any time (RFC 4253 §11); skip
// them wherever a specific message is expected
fn isIgnorableMsg(msg_type: u8) bool {
    return msg_type == SSH_MSG_IGNORE or msg_type == SSH_MSG_UNIMPLEMENTED or msg_type == SSH_MSG_DEBUG;
}

// transport for KEX packets: the initial exchange runs in plaintext, a rekey
// runs under the current session ciphers.
const KexTransport = union(enum) {
    plain: *u64, // counts packets read so the caller can seed cipher seqnos
    encrypted: struct { cs: *Cipher, sc: *Cipher },

    // read one packet, skipping ignorable messages — unless strict kex is in
    // force, which bans them mid-handshake
    fn readPacket(self: KexTransport, allocator: std.mem.Allocator, reader: *std.Io.Reader, strict: bool) ![]u8 {
        while (true) {
            const packet = switch (self) {
                .plain => |count| packet: {
                    const packet = try readPlainPacket(allocator, reader);
                    count.* += 1;
                    break :packet packet;
                },
                .encrypted => |ciphers| try ciphers.cs.readPacket(allocator, reader),
            };
            if (packet.len >= 1 and isIgnorableMsg(packet[0])) {
                allocator.free(packet);
                if (strict) return error.StrictKexViolation;
                continue;
            }
            return packet;
        }
    }

    fn writePacket(self: KexTransport, io: std.Io, allocator: std.mem.Allocator, writer: *std.Io.Writer, payload: []const u8) !void {
        switch (self) {
            .plain => try writePlainPacket(io, writer, payload),
            .encrypted => |ciphers| try ciphers.sc.writePacket(io, allocator, writer, payload),
        }
    }
};

// read one encrypted packet for the auth and channel layers, transparently
// skipping ignorable messages and servicing client-initiated rekeys.
fn readSessionPacket(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: *Cipher,
    sc_cipher: *Cipher,
    rekey: *const RekeyState,
) ![]u8 {
    while (true) {
        const packet = try cs_cipher.readPacket(allocator, reader);
        if (packet.len >= 1 and isIgnorableMsg(packet[0])) {
            allocator.free(packet);
            continue;
        }
        if (packet.len >= 1 and packet[0] == SSH_MSG_KEXINIT) {
            defer allocator.free(packet);
            try runRekey(io, allocator, reader, writer, cs_cipher, sc_cipher, rekey, packet);
            continue;
        }
        return packet;
    }
}

// ---------------------------------------------------------------------------
// SSH field encoders / decoders (RFC 4251 §5)
// ---------------------------------------------------------------------------

pub fn writeStringField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(bytes.len), .big);
    try buf.appendSlice(allocator, &len_bytes);
    try buf.appendSlice(allocator, bytes);
}

pub fn writeNameList(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    var total: usize = 0;
    for (names, 0..) |name, i| {
        if (i > 0) total += 1; // comma separator
        total += name.len;
    }
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(total), .big);
    try buf.appendSlice(allocator, &len_bytes);
    for (names, 0..) |name, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, name);
    }
}

/// SSH "mpint" — big-endian two's complement multi-precision integer. for
/// our use (X25519 shared secret) the value is always non-negative, so we
/// strip leading zero bytes, then prepend a single 0x00 if the high bit of
/// the most-significant byte is set (to keep it parsed as positive).
pub fn writeMpint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) start += 1;
    const trimmed = bytes[start..];
    if (trimmed.len == 0) {
        try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
        return;
    }
    const prepend = (trimmed[0] & 0x80) != 0;
    const out_len: u32 = @intCast(trimmed.len + @as(usize, @intFromBool(prepend)));
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, out_len, .big);
    try buf.appendSlice(allocator, &len_bytes);
    if (prepend) try buf.append(allocator, 0);
    try buf.appendSlice(allocator, trimmed);
}

pub fn takeStringField(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_len: u32) ![]u8 {
    const len = try reader.takeInt(u32, .big);
    if (len > max_len) return error.FieldTooLarge;
    return try reader.readAlloc(allocator, len);
}

fn nameListContainsAny(haystack: []const u8, our_options: []const []const u8) bool {
    var iter = std.mem.splitScalar(u8, haystack, ',');
    while (iter.next()) |name| {
        for (our_options) |opt| {
            if (std.mem.eql(u8, name, opt)) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// KEXINIT (RFC 4253 §7.1)
// ---------------------------------------------------------------------------

pub const our_kex_algos = [_][]const u8{ "mlkem768x25519-sha256", "curve25519-sha256", "curve25519-sha256@libssh.org" };

// strict kex markers (Terrapin / CVE-2023-48795 mitigation). pseudo-algorithms
// carried in the initial KEXINIT's kex list: we advertise the -s form, the
// client advertises the -c form. they are never selected as an actual kex
// algorithm because the matcher only picks from our_kex_algos.
pub const kex_strict_server = "kex-strict-s-v00@openssh.com";
pub const kex_strict_client = "kex-strict-c-v00@openssh.com";

const MLKem768 = std.crypto.kem.ml_kem.MLKem768;
const hybrid_client_blob_len = MLKem768.PublicKey.encoded_length + X25519.public_length; // 1216
const hybrid_server_blob_len = MLKem768.ciphertext_length + X25519.public_length; // 1120
pub const our_host_key_algos = [_][]const u8{"ssh-ed25519"};
pub const our_ciphers = [_][]const u8{"chacha20-poly1305@openssh.com"};
const our_macs = [_][]const u8{}; // none — implicit in the AEAD cipher
const our_compression = [_][]const u8{"none"};

/// Build a KEXINIT payload with the given algorithm name-lists
pub fn buildKexInit(
    io: std.Io,
    allocator: std.mem.Allocator,
    kex_algos: []const []const u8,
    host_key_algos: []const []const u8,
    ciphers: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, SSH_MSG_KEXINIT);

    var cookie: [16]u8 = undefined;
    io.random(&cookie);
    try buf.appendSlice(allocator, &cookie);

    try writeNameList(&buf, allocator, kex_algos);
    try writeNameList(&buf, allocator, host_key_algos);
    try writeNameList(&buf, allocator, ciphers); // c->s
    try writeNameList(&buf, allocator, ciphers); // s->c
    try writeNameList(&buf, allocator, &our_macs);
    try writeNameList(&buf, allocator, &our_macs);
    try writeNameList(&buf, allocator, &our_compression);
    try writeNameList(&buf, allocator, &our_compression);
    try writeNameList(&buf, allocator, &.{}); // langs c->s
    try writeNameList(&buf, allocator, &.{}); // langs s->c
    try buf.append(allocator, 0); // first_kex_packet_follows = false
    try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // reserved

    return try buf.toOwnedSlice(allocator);
}

fn buildServerKexInit(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return buildKexInit(io, allocator, &(our_kex_algos ++ [_][]const u8{kex_strict_server}), &our_host_key_algos, &our_ciphers);
}

const ParsedKexInit = struct {
    kex_algos: []u8,
    host_key_algos: []u8,
    cs_cipher: []u8,
    sc_cipher: []u8,

    fn deinit(self: ParsedKexInit, allocator: std.mem.Allocator) void {
        allocator.free(self.kex_algos);
        allocator.free(self.host_key_algos);
        allocator.free(self.cs_cipher);
        allocator.free(self.sc_cipher);
    }
};

fn parseClientKexInit(allocator: std.mem.Allocator, payload: []const u8) !ParsedKexInit {
    if (payload.len < 1 + 16) return error.KexInitTruncated;
    if (payload[0] != SSH_MSG_KEXINIT) return error.UnexpectedMessage;

    var reader = std.Io.Reader.fixed(payload[1 + 16 ..]); // skip type + cookie

    const kex_algos = try takeStringField(allocator, &reader, max_name_list_len);
    errdefer allocator.free(kex_algos);
    const host_key_algos = try takeStringField(allocator, &reader, max_name_list_len);
    errdefer allocator.free(host_key_algos);
    const cs_cipher = try takeStringField(allocator, &reader, max_name_list_len);
    errdefer allocator.free(cs_cipher);
    const sc_cipher = try takeStringField(allocator, &reader, max_name_list_len);
    errdefer allocator.free(sc_cipher);

    // skip c->s mac, s->c mac, c->s compress, s->c compress, lang c->s, lang s->c
    for (0..6) |_| {
        const len = try reader.takeInt(u32, .big);
        if (len > max_name_list_len) return error.FieldTooLarge;
        try reader.discardAll(len);
    }
    _ = try reader.takeByte(); // first_kex_packet_follows
    _ = try reader.takeInt(u32, .big); // reserved

    return .{
        .kex_algos = kex_algos,
        .host_key_algos = host_key_algos,
        .cs_cipher = cs_cipher,
        .sc_cipher = sc_cipher,
    };
}

// ---------------------------------------------------------------------------
// KEX orchestration: KEXINIT → ECDH → NEWKEYS → key derivation
// ---------------------------------------------------------------------------

const KexResult = struct {
    cs_key: [64]u8, // client → server cipher key material (K_2 || K_1)
    sc_key: [64]u8, // server → client cipher key material
    session_id: [Sha256.digest_length]u8,
    next_cs_seq: u64,
    next_sc_seq: u64,
    strict: bool,
};

fn runKex(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_key: *const HostKey,
    client_version: []const u8,
) !KexResult {
    var client_seq: u64 = 0;
    const transport = KexTransport{ .plain = &client_seq };

    // exchange KEXINITs
    const server_kex_init = try buildServerKexInit(io, allocator);
    defer allocator.free(server_kex_init);
    try writePlainPacket(io, writer, server_kex_init);

    const client_kex_init = try transport.readPacket(allocator, reader, false);
    defer allocator.free(client_kex_init);

    // strict kex: when the client advertises it, its KEXINIT must be the
    // first packet, ignorable messages are banned until NEWKEYS, and both
    // seqnos reset to 0 after every NEWKEYS.
    const strict = strict: {
        var parsed = try parseClientKexInit(allocator, client_kex_init);
        defer parsed.deinit(allocator);
        break :strict nameListContainsAny(parsed.kex_algos, &.{kex_strict_client});
    };
    if (strict and client_seq != 1) return error.StrictKexViolation;

    const negotiated = try exchangeKeys(
        io,
        allocator,
        reader,
        writer,
        transport,
        strict,
        host_key,
        client_version,
        client_kex_init,
        server_kex_init,
        null,
    );

    return .{
        .cs_key = negotiated.keys.cs_enc,
        .sc_key = negotiated.keys.sc_enc,
        .session_id = negotiated.exchange_hash,
        // the server sent exactly KEXINIT, KEX_ECDH_REPLY and NEWKEYS; the
        // client's count includes any skipped IGNORE/DEBUG packets.
        .next_cs_seq = if (strict) 0 else client_seq,
        .next_sc_seq = if (strict) 0 else 3,
        .strict = strict,
    };
}

/// everything needed to service a client-initiated rekey mid-session.
pub const RekeyState = struct {
    host_key: *const HostKey,
    client_version: []const u8,
    session_id: [Sha256.digest_length]u8,
    strict: bool,
};

// service a rekey whose triggering KEXINIT payload has just been read: run
// the whole exchange under the current keys, then swap the new keys into
// both ciphers in place.
fn runRekey(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: *Cipher,
    sc_cipher: *Cipher,
    rekey: *const RekeyState,
    client_kex_init: []const u8,
) !void {
    const server_kex_init = try buildServerKexInit(io, allocator);
    defer allocator.free(server_kex_init);
    try sc_cipher.writePacket(io, allocator, writer, server_kex_init);

    const negotiated = try exchangeKeys(
        io,
        allocator,
        reader,
        writer,
        .{ .encrypted = .{ .cs = cs_cipher, .sc = sc_cipher } },
        false,
        rekey.host_key,
        rekey.client_version,
        client_kex_init,
        server_kex_init,
        &rekey.session_id,
    );

    // seqnos continue across a rekey unless strict kex was negotiated,
    // which resets them after every NEWKEYS
    cs_cipher.setKeys(&negotiated.keys.cs_enc, if (rekey.strict) 0 else cs_cipher.seq);
    sc_cipher.setKeys(&negotiated.keys.sc_enc, if (rekey.strict) 0 else sc_cipher.seq);
}

const NegotiatedKeys = struct {
    keys: SessionKeys,
    exchange_hash: [Sha256.digest_length]u8,
};

// the KEX core shared by the initial exchange and rekeys: pick algorithms,
// run the (hybrid) ECDH round trip, exchange NEWKEYS, derive keys. both
// KEXINIT payloads have already been exchanged by the caller. session_id is
// null on the initial exchange (where it becomes the exchange hash) and the
// original session id on a rekey.
fn exchangeKeys(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    transport: KexTransport,
    strict: bool,
    host_key: *const HostKey,
    client_version: []const u8,
    client_kex_init: []const u8,
    server_kex_init: []const u8,
    session_id: ?*const [Sha256.digest_length]u8,
) !NegotiatedKeys {
    var parsed = try parseClientKexInit(allocator, client_kex_init);
    defer parsed.deinit(allocator);

    // pick the first kex algo in the client's preference list that we also
    // support (RFC 4253 §7.1.3).
    const kex_algo = blk: {
        var iter = std.mem.splitScalar(u8, parsed.kex_algos, ',');
        while (iter.next()) |name| {
            for (our_kex_algos) |opt| {
                if (std.mem.eql(u8, name, opt)) break :blk opt;
            }
        }
        return error.NoCommonKexAlgorithm;
    };
    if (!nameListContainsAny(parsed.host_key_algos, &our_host_key_algos)) return error.NoCommonHostKeyAlgorithm;
    if (!nameListContainsAny(parsed.cs_cipher, &our_ciphers)) return error.NoCommonCipher;
    if (!nameListContainsAny(parsed.sc_cipher, &our_ciphers)) return error.NoCommonCipher;
    const hybrid = std.mem.eql(u8, kex_algo, "mlkem768x25519-sha256");

    // receive KEX_ECDH_INIT (mlkem768x25519 reuses message code 30 — same
    // wire shape, only the string size differs).
    const ecdh_init = try transport.readPacket(allocator, reader, strict);
    defer allocator.free(ecdh_init);
    if (ecdh_init.len < 1 or ecdh_init[0] != SSH_MSG_KEX_ECDH_INIT) return error.UnexpectedMessage;

    var ecdh_init_reader = std.Io.Reader.fixed(ecdh_init[1..]);
    const expected_client_len: u32 = if (hybrid) hybrid_client_blob_len else X25519.public_length;
    const client_blob = try takeStringField(allocator, &ecdh_init_reader, expected_client_len);
    defer allocator.free(client_blob);
    if (client_blob.len != expected_client_len) return error.InvalidEphemeralKey;

    // derive server reply blob (S_REPLY) + shared secret K.
    //   ECDH: server_blob = X25519 server pub (32B); K = X25519(s, c_pub).
    //   hybrid: server_blob = MLKEM ciphertext (1088B) || X25519 server pub (32B);
    //           K = SHA-256(K_MLKEM || K_X25519).
    var server_blob: []u8 = undefined;
    var k: []u8 = undefined;
    {
        const x25519_offset: usize = if (hybrid) MLKem768.PublicKey.encoded_length else 0;
        var x25519_client_pub: [X25519.public_length]u8 = undefined;
        @memcpy(&x25519_client_pub, client_blob[x25519_offset..]);
        const server_kp = X25519.KeyPair.generate(io);
        const x25519_shared = try X25519.scalarmult(server_kp.secret_key, x25519_client_pub);

        if (hybrid) {
            var pq_pub_bytes: [MLKem768.PublicKey.encoded_length]u8 = undefined;
            @memcpy(&pq_pub_bytes, client_blob[0..MLKem768.PublicKey.encoded_length]);
            const pq_pub = try MLKem768.PublicKey.fromBytes(&pq_pub_bytes);
            const encap = pq_pub.encaps(io);

            server_blob = try allocator.alloc(u8, hybrid_server_blob_len);
            @memcpy(server_blob[0..MLKem768.ciphertext_length], &encap.ciphertext);
            @memcpy(server_blob[MLKem768.ciphertext_length..], &server_kp.public_key);

            var h = Sha256.init(.{});
            h.update(&encap.shared_secret);
            h.update(&x25519_shared);
            k = try allocator.dupe(u8, &h.finalResult());
        } else {
            server_blob = try allocator.dupe(u8, &server_kp.public_key);
            k = try allocator.dupe(u8, &x25519_shared);
        }
    }
    defer allocator.free(server_blob);
    defer allocator.free(k);

    // build host key blob (K_S)
    var host_key_blob: std.ArrayList(u8) = .empty;
    defer host_key_blob.deinit(allocator);
    try host_key.appendPublicBlob(&host_key_blob, allocator);

    // build exchange hash input and compute H
    const exchange_hash = try computeExchangeHash(
        allocator,
        client_version,
        server_version,
        client_kex_init,
        server_kex_init,
        host_key_blob.items,
        client_blob,
        server_blob,
        k,
        hybrid,
    );

    // sign H with the host key, format as ssh signature blob
    var signature_blob: std.ArrayList(u8) = .empty;
    defer signature_blob.deinit(allocator);
    try host_key.appendSignatureBlob(&signature_blob, allocator, &exchange_hash);

    // build & send KEX_ECDH_REPLY (msg code 31 reused as KEX_HYBRID_REPLY)
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.append(allocator, SSH_MSG_KEX_ECDH_REPLY);
    try writeStringField(&reply, allocator, host_key_blob.items);
    try writeStringField(&reply, allocator, server_blob);
    try writeStringField(&reply, allocator, signature_blob.items);
    try transport.writePacket(io, allocator, writer, reply.items);

    // NEWKEYS — both sides switch to the new keys after this is sent and
    // the peer's NEWKEYS is received.
    try transport.writePacket(io, allocator, writer, &[_]u8{SSH_MSG_NEWKEYS});

    const peer_newkeys = try transport.readPacket(allocator, reader, strict);
    defer allocator.free(peer_newkeys);
    if (peer_newkeys.len < 1 or peer_newkeys[0] != SSH_MSG_NEWKEYS) return error.UnexpectedMessage;

    // derive session keys per RFC 4253 §7.2. only the encrypt keys are
    // needed for chacha20-poly1305 (no separate MAC/IV).
    var keys: SessionKeys = undefined;
    try deriveSessionKeys(allocator, k, &exchange_hash, if (session_id) |sid| sid else &exchange_hash, &keys, hybrid);

    return .{ .keys = keys, .exchange_hash = exchange_hash };
}

// ---------------------------------------------------------------------------
// exchange hash (RFC 4253 §8, RFC 5656 §4)
// ---------------------------------------------------------------------------

pub fn computeExchangeHash(
    allocator: std.mem.Allocator,
    client_version: []const u8,
    server_version_str: []const u8,
    client_kex_init: []const u8,
    server_kex_init: []const u8,
    host_key_blob: []const u8,
    client_ephemeral: []const u8,
    server_ephemeral: []const u8,
    shared_secret: []const u8,
    /// curve25519-sha256 encodes K as mpint; mlkem768x25519-sha256 encodes it
    /// as a plain SSH string (length-prefixed bytes).
    k_is_string: bool,
) ![Sha256.digest_length]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try writeStringField(&buf, allocator, client_version);
    try writeStringField(&buf, allocator, server_version_str);
    try writeStringField(&buf, allocator, client_kex_init);
    try writeStringField(&buf, allocator, server_kex_init);
    try writeStringField(&buf, allocator, host_key_blob);
    try writeStringField(&buf, allocator, client_ephemeral);
    try writeStringField(&buf, allocator, server_ephemeral);
    if (k_is_string) {
        try writeStringField(&buf, allocator, shared_secret);
    } else {
        try writeMpint(&buf, allocator, shared_secret);
    }

    var hasher = Sha256.init(.{});
    hasher.update(buf.items);
    return hasher.finalResult();
}

// ---------------------------------------------------------------------------
// key derivation (RFC 4253 §7.2)
// ---------------------------------------------------------------------------

// chacha20-poly1305@openssh.com wants 64 bytes per direction (32-byte main key
// + 32-byte header key); SHA256 produces 32, so each encrypt key is two hash
// blocks chained per RFC 4253.
pub const SessionKeys = struct {
    cs_enc: [64]u8,
    sc_enc: [64]u8,
};

pub fn deriveSessionKeys(
    allocator: std.mem.Allocator,
    shared_secret: []const u8,
    exchange_hash: []const u8,
    session_id: []const u8,
    out: *SessionKeys,
    /// see computeExchangeHash — must match the KEX algorithm's K encoding.
    k_is_string: bool,
) !void {
    // pre-build the K || H prefix once; reused for every derivation
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    if (k_is_string) {
        try writeStringField(&prefix, allocator, shared_secret);
    } else {
        try writeMpint(&prefix, allocator, shared_secret);
    }
    try prefix.appendSlice(allocator, exchange_hash);

    try deriveKey(allocator, prefix.items, 'C', session_id, &out.cs_enc);
    try deriveKey(allocator, prefix.items, 'D', session_id, &out.sc_enc);
}

fn deriveKey(
    allocator: std.mem.Allocator,
    prefix: []const u8, // K || H, already encoded
    letter: u8,
    session_id: []const u8,
    out: []u8,
) !void {
    // first block: HASH(K || H || letter || session_id)
    var first_block: [Sha256.digest_length]u8 = undefined;
    {
        var hasher = Sha256.init(.{});
        hasher.update(prefix);
        hasher.update(&[_]u8{letter});
        hasher.update(session_id);
        first_block = hasher.finalResult();
    }
    const first_copy = @min(out.len, first_block.len);
    @memcpy(out[0..first_copy], first_block[0..first_copy]);

    // chain additional blocks if requested length exceeds one hash:
    //   K_{n+1} = HASH(K || H || K_1 || K_2 || … || K_n)
    var chained: std.ArrayList(u8) = .empty;
    defer chained.deinit(allocator);
    try chained.appendSlice(allocator, first_block[0..]);

    var produced: usize = first_copy;
    while (produced < out.len) {
        var hasher = Sha256.init(.{});
        hasher.update(prefix);
        hasher.update(chained.items);
        const block = hasher.finalResult();
        const copy_len = @min(out.len - produced, block.len);
        @memcpy(out[produced .. produced + copy_len], block[0..copy_len]);
        produced += copy_len;
        try chained.appendSlice(allocator, block[0..]);
    }
}

// ---------------------------------------------------------------------------
// chacha20-poly1305@openssh.com packet codec
// ---------------------------------------------------------------------------
//
// per openssh's PROTOCOL.chacha20poly1305:
//   K_2 = first 32 bytes of key material  — encrypts the packet body
//   K_1 = next 32 bytes                   — encrypts the 4-byte length field
//   nonce = 64-bit big-endian sequence number
//   body = chacha20(K_2, nonce, counter=1) XOR plaintext_body
//   length = chacha20(K_1, nonce, counter=0) XOR length_uint32_be
//   mac = poly1305(poly_key, encrypted_length || encrypted_body)
//     where poly_key = chacha20(K_2, nonce, counter=0)[0..32]
//
// padding is computed on the body alone (padding_length byte + payload +
// padding) — the 4-byte length field is excluded from alignment. body must
// be a multiple of 8 bytes; minimum padding 4 bytes.

pub const Cipher = struct {
    main_key: [32]u8, // K_2
    header_key: [32]u8, // K_1
    seq: u64,
    idle: ?*IdleState = null,

    pub fn init(key_material: *const [64]u8, initial_seq: u64) Cipher {
        return .{
            .main_key = key_material[0..32].*,
            .header_key = key_material[32..64].*,
            .seq = initial_seq,
        };
    }

    /// swap in new key material after a rekey, leaving the rest of the
    /// cipher state alone
    fn setKeys(self: *Cipher, key_material: *const [64]u8, seq: u64) void {
        self.main_key = key_material[0..32].*;
        self.header_key = key_material[32..64].*;
        self.seq = seq;
    }

    fn makeNonce(seq: u64) [8]u8 {
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, seq, .big);
        return nonce;
    }

    pub fn writePacket(
        self: *Cipher,
        io: std.Io,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        payload: []const u8,
    ) !void {
        const block: usize = 8;
        const initial_pad = block - ((1 + payload.len) % block);
        const padding_len: u8 = @intCast(if (initial_pad < 4) initial_pad + block else initial_pad);
        const body_len: u32 = @intCast(1 + payload.len + padding_len);

        const nonce = makeNonce(self.seq);

        // plaintext body = padding_length || payload || random padding
        const body = try allocator.alloc(u8, body_len);
        defer allocator.free(body);
        body[0] = padding_len;
        @memcpy(body[1 .. 1 + payload.len], payload);
        io.random(body[1 + payload.len ..]);

        // encrypt body in place with counter=1
        ChaCha20.xor(body, body, 1, self.main_key, nonce);

        // encrypt length field with header key, counter=0
        var enc_length: [4]u8 = undefined;
        var length_plain: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_plain, body_len, .big);
        ChaCha20.xor(&enc_length, &length_plain, 0, self.header_key, nonce);

        // poly1305 key = first 32 bytes of chacha20(K_2, nonce, counter=0)
        var poly_key: [Poly1305.key_length]u8 = undefined;
        ChaCha20.stream(&poly_key, 0, self.main_key, nonce);

        // mac over encrypted_length || encrypted_body
        var poly = Poly1305.init(&poly_key);
        poly.update(&enc_length);
        poly.update(body);
        var tag: [Poly1305.mac_length]u8 = undefined;
        poly.final(&tag);

        try writer.writeAll(&enc_length);
        try writer.writeAll(body);
        try writer.writeAll(&tag);
        try writer.flush();

        self.seq += 1;
    }

    pub fn readPacket(
        self: *Cipher,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) ![]u8 {
        const nonce = makeNonce(self.seq);

        var enc_length: [4]u8 = undefined;
        try reader.readSliceAll(&enc_length);

        var length_plain: [4]u8 = undefined;
        ChaCha20.xor(&length_plain, &enc_length, 0, self.header_key, nonce);
        const body_len = std.mem.readInt(u32, &length_plain, .big);
        if (body_len < 8 or body_len > max_packet_len or body_len % 8 != 0) return error.InvalidPacketLength;

        const enc_body = try allocator.alloc(u8, body_len);
        defer allocator.free(enc_body);
        try reader.readSliceAll(enc_body);

        var tag_recv: [Poly1305.mac_length]u8 = undefined;
        try reader.readSliceAll(&tag_recv);

        var poly_key: [Poly1305.key_length]u8 = undefined;
        ChaCha20.stream(&poly_key, 0, self.main_key, nonce);

        var poly = Poly1305.init(&poly_key);
        poly.update(&enc_length);
        poly.update(enc_body);
        var tag_computed: [Poly1305.mac_length]u8 = undefined;
        poly.final(&tag_computed);
        if (!std.crypto.timing_safe.eql([Poly1305.mac_length]u8, tag_recv, tag_computed)) {
            return error.MacVerificationFailed;
        }

        // decrypt the body in place, then copy out the payload (caller owns)
        ChaCha20.xor(enc_body, enc_body, 1, self.main_key, nonce);

        const padding_len = enc_body[0];
        if (padding_len < 4 or 1 + @as(u32, padding_len) > body_len) return error.InvalidPadding;
        const payload_len = body_len - 1 - @as(u32, padding_len);

        const payload = try allocator.dupe(u8, enc_body[1 .. 1 + payload_len]);

        self.seq += 1;
        if (self.idle) |idle| _ = idle.activity.fetchAdd(1, .monotonic);
        return payload;
    }
};

// ---------------------------------------------------------------------------
// post-KEX: service request + user authentication (RFC 4252)
// ---------------------------------------------------------------------------

/// "SHA256:" (7 bytes) + base64-no-padding of a 32-byte SHA256 digest
/// (43 bytes) = 50 bytes. matches what openssh's client logs as
/// `Offering public key: … SHA256:…`.
pub const fingerprint_len = 50;

/// hash the SSH wire-format pubkey blob (`string algo` + `string raw_key`)
/// the same way openssh does for `ssh-keygen -lf` / authorized-key logs.
pub fn formatFingerprint(pubkey_blob: []const u8) [fingerprint_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(pubkey_blob, &digest, .{});

    var out: [fingerprint_len]u8 = undefined;
    @memcpy(out[0..7], "SHA256:");
    const encoded = std.base64.standard_no_pad.Encoder.encode(out[7..], &digest);
    std.debug.assert(encoded.len == fingerprint_len - 7);
    return out;
}

fn runAuth(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: *Cipher,
    sc_cipher: *Cipher,
    rekey: *const RekeyState,
) ![fingerprint_len]u8 {
    // step 1: service request for ssh-userauth → service accept
    {
        const req = try readSessionPacket(io, allocator, reader, writer, cs_cipher, sc_cipher, rekey);
        defer allocator.free(req);
        if (req.len < 1 or req[0] != SSH_MSG_SERVICE_REQUEST) return error.UnexpectedMessage;

        var req_reader = std.Io.Reader.fixed(req[1..]);
        const service = try takeStringField(allocator, &req_reader, 64);
        defer allocator.free(service);
        if (!std.mem.eql(u8, service, "ssh-userauth")) return error.UnsupportedService;

        var accept: std.ArrayList(u8) = .empty;
        defer accept.deinit(allocator);
        try accept.append(allocator, SSH_MSG_SERVICE_ACCEPT);
        try writeStringField(&accept, allocator, "ssh-userauth");
        try sc_cipher.writePacket(io, allocator, writer, accept.items);
    }

    // step 2: USERAUTH loop until SUCCESS. accept any ed25519 key whose
    // signature verifies against the offered pubkey.
    var auth_attempts: u32 = 0;
    while (true) {
        const req = try readSessionPacket(io, allocator, reader, writer, cs_cipher, sc_cipher, rekey);
        defer allocator.free(req);
        if (req.len < 1 or req[0] != SSH_MSG_USERAUTH_REQUEST) return error.UnexpectedMessage;

        var req_reader = std.Io.Reader.fixed(req[1..]);
        const user_name = try takeStringField(allocator, &req_reader, 256);
        defer allocator.free(user_name);
        const service_name = try takeStringField(allocator, &req_reader, 64);
        defer allocator.free(service_name);
        const method = try takeStringField(allocator, &req_reader, 64);
        defer allocator.free(method);

        // RFC 4252 §5: the server must verify the requested service
        if (!std.mem.eql(u8, service_name, "ssh-connection")) {
            auth_attempts += 1;
            if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
            try sendUserauthFailure(io, allocator, sc_cipher, writer);
            continue;
        }

        if (!std.mem.eql(u8, method, "publickey")) {
            auth_attempts += 1;
            if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
            try sendUserauthFailure(io, allocator, sc_cipher, writer);
            continue;
        }

        const has_signature = (try req_reader.takeByte()) != 0;
        const algo = try takeStringField(allocator, &req_reader, 64);
        defer allocator.free(algo);
        const pubkey_blob = try takeStringField(allocator, &req_reader, 4096);
        defer allocator.free(pubkey_blob);

        if (!std.mem.eql(u8, algo, "ssh-ed25519")) {
            auth_attempts += 1;
            if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
            try sendUserauthFailure(io, allocator, sc_cipher, writer);
            continue;
        }

        if (!has_signature) {
            // probes count as attempts so a client can't loop here forever
            auth_attempts += 1;
            if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
            // probe — tell the client this key is acceptable so it'll send
            // the signed version next.
            var pk_ok: std.ArrayList(u8) = .empty;
            defer pk_ok.deinit(allocator);
            try pk_ok.append(allocator, SSH_MSG_USERAUTH_PK_OK);
            try writeStringField(&pk_ok, allocator, algo);
            try writeStringField(&pk_ok, allocator, pubkey_blob);
            try sc_cipher.writePacket(io, allocator, writer, pk_ok.items);
            continue;
        }

        // has signature — verify it
        const signature_blob = try takeStringField(allocator, &req_reader, 1024);
        defer allocator.free(signature_blob);

        const ok = verifyUserauthSignature(
            allocator,
            &rekey.session_id,
            user_name,
            service_name,
            algo,
            pubkey_blob,
            signature_blob,
        ) catch false;

        if (!ok) {
            auth_attempts += 1;
            if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
            try sendUserauthFailure(io, allocator, sc_cipher, writer);
            continue;
        }

        try sc_cipher.writePacket(io, allocator, writer, &[_]u8{SSH_MSG_USERAUTH_SUCCESS});
        return formatFingerprint(pubkey_blob);
    }
}

fn sendUserauthFailure(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, SSH_MSG_USERAUTH_FAILURE);
    try writeNameList(&buf, allocator, &.{"publickey"}); // allowed methods
    try buf.append(allocator, 0); // partial_success = false
    try sc_cipher.writePacket(io, allocator, writer, buf.items);
}

/// Append the canonical publickey-signed-data bytes (RFC 4252 §7) to `buf`.
/// Used by the server to recompute the signed input for verification
pub fn appendPublickeySignedData(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    session_id: []const u8,
    user_name: []const u8,
    service_name: []const u8,
    algo: []const u8,
    pubkey_blob: []const u8,
) !void {
    try writeStringField(buf, allocator, session_id);
    try buf.append(allocator, SSH_MSG_USERAUTH_REQUEST);
    try writeStringField(buf, allocator, user_name);
    try writeStringField(buf, allocator, service_name);
    try writeStringField(buf, allocator, "publickey");
    try buf.append(allocator, 1);
    try writeStringField(buf, allocator, algo);
    try writeStringField(buf, allocator, pubkey_blob);
}

// build the bytes a publickey signature is computed over (RFC 4252 §7) and
// verify the supplied signature against them.
fn verifyUserauthSignature(
    allocator: std.mem.Allocator,
    session_id: *const [Sha256.digest_length]u8,
    user_name: []const u8,
    service_name: []const u8,
    algo: []const u8,
    pubkey_blob: []const u8,
    signature_blob: []const u8,
) !bool {
    var signed: std.ArrayList(u8) = .empty;
    defer signed.deinit(allocator);
    try appendPublickeySignedData(&signed, allocator, session_id, user_name, service_name, algo, pubkey_blob);

    // parse pubkey_blob: string "ssh-ed25519" || string raw_pubkey
    var pubkey_reader = std.Io.Reader.fixed(pubkey_blob);
    const pk_algo = try takeStringField(allocator, &pubkey_reader, 64);
    defer allocator.free(pk_algo);
    if (!std.mem.eql(u8, pk_algo, "ssh-ed25519")) return false;
    const raw_pubkey = try takeStringField(allocator, &pubkey_reader, 64);
    defer allocator.free(raw_pubkey);
    if (raw_pubkey.len != Ed25519.PublicKey.encoded_length) return false;

    // parse signature_blob: string "ssh-ed25519" || string raw_signature
    var sig_reader = std.Io.Reader.fixed(signature_blob);
    const sig_algo = try takeStringField(allocator, &sig_reader, 64);
    defer allocator.free(sig_algo);
    if (!std.mem.eql(u8, sig_algo, "ssh-ed25519")) return false;
    const raw_sig = try takeStringField(allocator, &sig_reader, Ed25519.Signature.encoded_length);
    defer allocator.free(raw_sig);
    if (raw_sig.len != Ed25519.Signature.encoded_length) return false;

    var pubkey_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    @memcpy(&pubkey_bytes, raw_pubkey);
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_bytes, raw_sig);

    const pk = Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return false;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(signed.items, pk) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// connection layer (RFC 4254): channels, requests, data, flow control
// ---------------------------------------------------------------------------

const Channel = struct {
    local_id: u32,
    remote_id: u32,
    local_window: u32, // bytes peer may still send us before we adjust
    remote_window: u32, // bytes we may still send to peer before they adjust
    max_packet: u32, // max CHANNEL_DATA payload the peer accepts in one packet
    pty: ?PtySize = null,
};

pub const PtySize = struct { width_cells: u16, height_cells: u16 };

// take the uint32 width/height cell counts of a pty-req or window-change,
// clamped to u16
fn takePtySize(r: *std.Io.Reader) !PtySize {
    const width = try r.takeInt(u32, .big);
    const height = try r.takeInt(u32, .big);
    return .{
        .width_cells = @intCast(@min(width, 0xFFFF)),
        .height_cells = @intCast(@min(height, 0xFFFF)),
    };
}

fn runChannelLayer(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: *Cipher,
    sc_cipher: *Cipher,
    rekey: *const RekeyState,
    fingerprint: *const [fingerprint_len]u8,
    handler: anytype,
) !void {
    var channel: ?Channel = null;
    var pending_exec: ?[]u8 = null;
    defer if (pending_exec) |s| allocator.free(s);

    while (true) {
        const packet = try readSessionPacket(io, allocator, reader, writer, cs_cipher, sc_cipher, rekey);
        defer allocator.free(packet);
        if (packet.len < 1) return error.EmptyPacket;
        const msg_type = packet[0];

        switch (msg_type) {
            SSH_MSG_GLOBAL_REQUEST => try handleGlobalRequest(io, allocator, sc_cipher, writer, packet),

            SSH_MSG_CHANNEL_OPEN => {
                if (channel != null) {
                    try sendChannelOpenFailure(io, allocator, sc_cipher, writer, packet, SSH_OPEN_RESOURCE_SHORTAGE, "only one channel per connection");
                    continue;
                }
                channel = try handleChannelOpen(io, allocator, sc_cipher, writer, packet) orelse continue;
            },

            SSH_MSG_CHANNEL_REQUEST => {
                const ch = if (channel) |*c| c else continue;
                const start_request = try handleChannelRequest(io, allocator, sc_cipher, writer, ch, packet, &pending_exec);
                if (start_request) |req_kind| {
                    const request: Request = switch (req_kind) {
                        .shell => .{ .shell = ch.pty },
                        .exec => .{ .exec = pending_exec.? },
                    };
                    var sess = SessionCtx{
                        .io = io,
                        .allocator = allocator,
                        .reader = reader,
                        .writer = writer,
                        .cs_cipher = cs_cipher,
                        .sc_cipher = sc_cipher,
                        .rekey = rekey,
                        .channel = ch,
                        .fingerprint = fingerprint.*,
                    };
                    defer sess.deinit();
                    handler.handleSession(&sess, request) catch |session_err| {
                        // try to send a non-zero exit status before closing
                        sess.exit(1) catch {};
                        return session_err;
                    };
                    if (!sess.closed) try sess.exit(0);
                    return;
                }
            },

            SSH_MSG_CHANNEL_WINDOW_ADJUST => {
                const ch = if (channel) |*c| c else continue;
                try handleWindowAdjust(ch, packet);
            },

            SSH_MSG_CHANNEL_DATA, SSH_MSG_CHANNEL_EXTENDED_DATA => {
                const ch = if (channel) |*c| c else continue;
                // before shell/exec the client shouldn't be sending data, but
                // some clients are chatty; discard and refill window.
                try discardChannelData(io, allocator, sc_cipher, writer, ch, packet, msg_type == SSH_MSG_CHANNEL_EXTENDED_DATA);
            },

            SSH_MSG_CHANNEL_EOF => {
                if (channel) |*c| try parseChannelId(packet, c.local_id);
            },

            SSH_MSG_CHANNEL_CLOSE => {
                if (channel) |*c| try parseChannelId(packet, c.local_id);
                return;
            },

            else => {}, // ignore unknown messages
        }
    }
}

fn handleGlobalRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    packet: []const u8,
) !void {
    // byte SSH_MSG_GLOBAL_REQUEST
    // string request_name
    // boolean want_reply
    // …request-specific data we ignore
    var r = std.Io.Reader.fixed(packet[1..]);
    const name = try takeStringField(allocator, &r, 256);
    defer allocator.free(name);
    const want_reply = (try r.takeByte()) != 0;
    if (want_reply) {
        try sc_cipher.writePacket(io, allocator, writer, &[_]u8{SSH_MSG_REQUEST_FAILURE});
    }
}

/// Parse a CHANNEL_OPEN. On a session channel, send CHANNEL_OPEN_CONFIRMATION
/// and return the new Channel. On other types, send CHANNEL_OPEN_FAILURE and
/// return null.
fn handleChannelOpen(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    packet: []const u8,
) !?Channel {
    // byte SSH_MSG_CHANNEL_OPEN
    // string channel_type
    // uint32 sender_channel (peer's id)
    // uint32 initial_window
    // uint32 max_packet
    var r = std.Io.Reader.fixed(packet[1..]);
    const ch_type = try takeStringField(allocator, &r, 64);
    defer allocator.free(ch_type);
    const remote_id = try r.takeInt(u32, .big);
    const initial_window = try r.takeInt(u32, .big);
    const max_packet = try r.takeInt(u32, .big);

    if (!std.mem.eql(u8, ch_type, "session")) {
        try sendChannelOpenFailure(io, allocator, sc_cipher, writer, packet, SSH_OPEN_UNKNOWN_CHANNEL_TYPE, "only session channels are supported");
        return null;
    }

    // a zero max_packet would leave writeChannel looping without progress
    if (max_packet == 0) {
        try sendChannelOpenFailure(io, allocator, sc_cipher, writer, packet, SSH_OPEN_RESOURCE_SHORTAGE, "max packet size must be non-zero");
        return null;
    }

    const local_id: u32 = 0; // single-channel connection — id is always 0 from our side
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.append(allocator, SSH_MSG_CHANNEL_OPEN_CONFIRMATION);
    try writeU32(&reply, allocator, remote_id);
    try writeU32(&reply, allocator, local_id);
    try writeU32(&reply, allocator, initial_recv_window);
    try writeU32(&reply, allocator, max_packet_size);
    try sc_cipher.writePacket(io, allocator, writer, reply.items);

    return .{
        .local_id = local_id,
        .remote_id = remote_id,
        .local_window = initial_recv_window,
        .remote_window = initial_window,
        .max_packet = max_packet,
    };
}

fn sendChannelOpenFailure(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    open_packet: []const u8,
    reason: u32,
    description: []const u8,
) !void {
    // recover the sender_channel field from the CHANNEL_OPEN packet so we
    // address the failure to the correct id
    var r = std.Io.Reader.fixed(open_packet[1..]);
    const ch_type_len = try r.takeInt(u32, .big);
    try r.discardAll(ch_type_len);
    const remote_id = try r.takeInt(u32, .big);

    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.append(allocator, SSH_MSG_CHANNEL_OPEN_FAILURE);
    try writeU32(&reply, allocator, remote_id);
    try writeU32(&reply, allocator, reason);
    try writeStringField(&reply, allocator, description);
    try writeStringField(&reply, allocator, ""); // language tag
    try sc_cipher.writePacket(io, allocator, writer, reply.items);
}

const RequestKind = enum { shell, exec };

/// Returns the kind of session request if this triggered one, else null.
fn handleChannelRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    ch: *Channel,
    packet: []const u8,
    pending_exec: *?[]u8,
) !?RequestKind {
    // byte SSH_MSG_CHANNEL_REQUEST
    // uint32 recipient_channel (== our local_id)
    // string request_type
    // boolean want_reply
    // …request-specific data
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != ch.local_id) return error.UnknownChannel;
    const req_type = try takeStringField(allocator, &r, 64);
    defer allocator.free(req_type);
    const want_reply = (try r.takeByte()) != 0;

    if (std.mem.eql(u8, req_type, "pty-req")) {
        // string TERM, uint32 width chars, uint32 height rows, uint32 width px,
        // uint32 height px, string modes
        const term = try takeStringField(allocator, &r, 64);
        defer allocator.free(term);
        ch.pty = try takePtySize(&r);
        try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "env")) {
        // ignore environment variables silently (we don't pass them anywhere)
        try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "window-change")) {
        // uint32 width cells, uint32 height rows, uint32 width px, uint32 height px
        const sz = try takePtySize(&r);
        if (ch.pty != null) ch.pty = sz;
        // spec: window-change MUST NOT request a reply, but accept either
        try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "shell")) {
        try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, true);
        return .shell;
    }

    if (std.mem.eql(u8, req_type, "exec")) {
        // capture the command string for the handler to inspect
        const cmd = try takeStringField(allocator, &r, 4096);
        if (pending_exec.*) |old| allocator.free(old);
        pending_exec.* = cmd;
        try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, true);
        return .exec;
    }

    // unknown request kind — fail it
    try replyChannelRequest(io, allocator, sc_cipher, writer, ch, want_reply, false);
    return null;
}

fn replyChannelRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    ch: *Channel,
    want_reply: bool,
    success: bool,
) !void {
    if (!want_reply) return;
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.append(allocator, if (success) SSH_MSG_CHANNEL_SUCCESS else SSH_MSG_CHANNEL_FAILURE);
    try writeU32(&reply, allocator, ch.remote_id);
    try sc_cipher.writePacket(io, allocator, writer, reply.items);
}

fn handleWindowAdjust(ch: *Channel, packet: []const u8) !void {
    // byte SSH_MSG_CHANNEL_WINDOW_ADJUST
    // uint32 recipient_channel
    // uint32 bytes_to_add
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != ch.local_id) return error.UnknownChannel;
    const add = try r.takeInt(u32, .big);
    ch.remote_window +|= add;
}

fn discardChannelData(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    ch: *Channel,
    packet: []const u8,
    extended: bool,
) !void {
    // byte SSH_MSG_CHANNEL_DATA/EXTENDED_DATA
    // uint32 recipient_channel
    // [if extended: uint32 type_code]
    // string data
    const payload = try parseChannelData(packet, extended, ch.local_id);
    const data_len: u32 = @intCast(payload.len);

    if (data_len > ch.local_window) return error.WindowExceeded;
    ch.local_window -= data_len;
    try maybeRefillRecvWindow(io, allocator, sc_cipher, writer, ch);
}

pub fn parseChannelData(packet: []const u8, extended: bool, expected_channel: u32) ![]const u8 {
    if (packet.len < 1) return error.EmptyPacket;
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != expected_channel) return error.UnknownChannel;
    if (extended) {
        const data_type = try r.takeInt(u32, .big);
        if (data_type != SSH_EXTENDED_DATA_STDERR) return error.UnsupportedExtendedData;
    }
    const data_len = try r.takeInt(u32, .big);
    // catches both data_len > remaining (would otherwise be a bounds-check
    // panic on the slice) and trailing junk after the declared payload.
    if (data_len != r.buffered().len) return error.InvalidChannelData;
    return r.buffered();
}

fn parseChannelId(packet: []const u8, expected_channel: u32) !void {
    if (packet.len < 1) return error.EmptyPacket;
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != expected_channel) return error.UnknownChannel;
    if (r.buffered().len != 0) return error.InvalidChannelMessage;
}

/// Send a CHANNEL_WINDOW_ADJUST if our receive window has dipped below half
/// of the initial value. Used both for the pre-session discard path and by
/// SessionCtx after it consumes a CHANNEL_DATA payload.
fn maybeRefillRecvWindow(
    io: std.Io,
    allocator: std.mem.Allocator,
    sc_cipher: *Cipher,
    writer: *std.Io.Writer,
    ch: *Channel,
) !void {
    if (ch.local_window >= initial_recv_window / 2) return;
    const add = initial_recv_window - ch.local_window;
    ch.local_window += add;
    var adj: std.ArrayList(u8) = .empty;
    defer adj.deinit(allocator);
    try adj.append(allocator, SSH_MSG_CHANNEL_WINDOW_ADJUST);
    try writeU32(&adj, allocator, ch.remote_id);
    try writeU32(&adj, allocator, add);
    try sc_cipher.writePacket(io, allocator, writer, adj.items);
}

pub fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

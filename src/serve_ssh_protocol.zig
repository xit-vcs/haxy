//! In-process SSH server: full server side of SSH-2 for haxy's use case.
//!
//! handles, per connection: version exchange, KEXINIT, curve25519 key
//! exchange, NEWKEYS, key derivation, chacha20-poly1305 packet codec,
//! strict kex (Terrapin mitigation), client-initiated rekeying,
//! ssh-userauth service request, publickey authentication (ed25519 and
//! rsa-sha2; captures the SHA256 fingerprint of the verified key), channel-layer
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
//!   user auth: publickey + ssh-ed25519, rsa-sha2-512, rsa-sha2-256

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const rsa = std.crypto.Certificate.rsa;
const ChaCha20 = std.crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = std.crypto.onetimeauth.Poly1305;

pub const server_version = "SSH-2.0-haxy_0.0";
pub const host_key_file_name = "ssh_host_ed25519_key";
const max_host_key_file_len = 4096;

const max_packet_len: u32 = 35000; // RFC 4253 §6.1 — minimum implementations must support
pub const packet_buffer_size = 4 + max_packet_len + Poly1305.mac_length;
const max_name_list_len: u32 = 4096;
const max_auth_attempts: u32 = 20;
const max_banner_lines: u32 = 32;
// terminal grids can have several live copies during layout and rendering
const max_pty_width: u32 = 512;
const max_pty_height: u32 = 128;

// SSH message type bytes (RFC 4250 §4.1)
pub const SSH_MSG_DISCONNECT: u8 = 1;
pub const SSH_MSG_IGNORE: u8 = 2;
pub const SSH_MSG_UNIMPLEMENTED: u8 = 3;
pub const SSH_MSG_DEBUG: u8 = 4;
pub const SSH_MSG_SERVICE_REQUEST: u8 = 5;
pub const SSH_MSG_SERVICE_ACCEPT: u8 = 6;
pub const SSH_MSG_EXT_INFO: u8 = 7;
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
pub const SSH_DISCONNECT_MAC_ERROR: u32 = 5;
pub const SSH_DISCONNECT_BY_APPLICATION: u32 = 11;

// SSH_OPEN_* reason codes for CHANNEL_OPEN_FAILURE
pub const SSH_OPEN_RESOURCE_SHORTAGE: u32 = 4;
pub const SSH_OPEN_UNKNOWN_CHANNEL_TYPE: u32 = 3;

// data type code for CHANNEL_EXTENDED_DATA (stderr)
pub const SSH_EXTENDED_DATA_STDERR: u32 = 1;

// initial flow-control window we advertise. typical openssh setting; large
// enough that small interactive sessions never need a WINDOW_ADJUST.
const initial_recv_window: u32 = 1 << 20;
const max_packet_size: u32 = 32768;
// ceiling on unread CHANNEL_DATA held for the consumer. window credit is only
// ever restored up to what's left of this, so the peer can't send more than
// the buffer will take.
const max_incoming_buffered: u32 = initial_recv_window;

/// shared with the host's watchdog. `activity` is bumped for non-ignored
/// session packets and for packets we send, `waiting` is set while we're
/// blocked on the peer, `session_started` releases the hard pre-session
/// deadline, and `closing` starts the bounded close drain. `exempt` is set
/// once an interactive session starts, since users idle in a TUI legitimately.
pub const IdleState = struct {
    activity: std.atomic.Value(u64) = .init(0),
    waiting: std.atomic.Value(bool) = .init(false),
    session_started: std.atomic.Value(bool) = .init(false),
    exempt: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
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
        var text_buf: [max_host_key_file_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &text_buf);
        if (cwd.readFile(io, path, &text_buf)) |text| {
            return parseOpenssh(text);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const host_key: HostKey = .{ .keypair = Ed25519.KeyPair.generate(io) };
        const text = try host_key.formatOpenssh(allocator);
        defer allocator.free(text);
        defer std.crypto.secureZero(u8, text);
        // owner-only from the start — never a window where the key is readable
        const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
        // linked into place only once complete, and never over an existing key
        var atomic_file = try cwd.createFileAtomic(io, path, .{ .permissions = permissions });
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, text);
        try atomic_file.link(io);
        return host_key;
    }

    const openssh_magic = "openssh-key-v1\x00";
    const openssh_begin = "-----BEGIN OPENSSH PRIVATE KEY-----";
    const openssh_end = "-----END OPENSSH PRIVATE KEY-----";

    /// the unencrypted openssh-key-v1 file that `ssh-keygen` writes and reads
    fn formatOpenssh(self: HostKey, allocator: std.mem.Allocator) ![]u8 {
        var public_blob: std.ArrayList(u8) = .empty;
        defer public_blob.deinit(allocator);
        try self.appendPublicBlob(&public_blob, allocator);

        // two equal check ints show a reader that the section decrypted
        // properly, a formality without a cipher
        var private: std.ArrayList(u8) = .empty;
        defer private.deinit(allocator);
        defer std.crypto.secureZero(u8, private.items);
        // every buffer that holds the secret is reserved up front, so a
        // reallocation can't leave a copy behind, and wiped before it's freed
        const private_capacity = 256;
        try private.ensureTotalCapacityPrecise(allocator, private_capacity);
        try writeU32(&private, allocator, 0);
        try writeU32(&private, allocator, 0);
        try writeStringField(&private, allocator, "ssh-ed25519");
        try writeStringField(&private, allocator, &self.keypair.public_key.bytes);
        try writeStringField(&private, allocator, &self.keypair.secret_key.bytes);
        try writeStringField(&private, allocator, "haxy"); // comment
        // padded with 1, 2, 3 and so on to the cipher's block size, 8 for none
        var pad: u8 = 1;
        while (private.items.len % 8 != 0) : (pad += 1) try private.append(allocator, pad);
        std.debug.assert(private.items.len <= private_capacity);

        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(allocator);
        defer std.crypto.secureZero(u8, blob.items);
        const blob_capacity = 128 + public_blob.items.len + private.items.len;
        try blob.ensureTotalCapacityPrecise(allocator, blob_capacity);
        try blob.appendSlice(allocator, openssh_magic);
        try writeStringField(&blob, allocator, "none"); // cipher
        try writeStringField(&blob, allocator, "none"); // kdf
        try writeStringField(&blob, allocator, ""); // kdf options
        try writeU32(&blob, allocator, 1); // number of keys
        try writeStringField(&blob, allocator, public_blob.items);
        try writeStringField(&blob, allocator, private.items);
        std.debug.assert(blob.items.len <= blob_capacity);

        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(blob.items.len));
        defer allocator.free(encoded);
        defer std.crypto.secureZero(u8, encoded);
        _ = encoder.encode(encoded, blob.items);

        // sized exactly, so toOwnedSlice hands over the allocation as it is
        const line_len = 70;
        const line_count = std.math.divCeil(usize, encoded.len, line_len) catch unreachable;
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        errdefer std.crypto.secureZero(u8, text.items);
        try text.ensureTotalCapacityPrecise(allocator, openssh_begin.len + 1 + encoded.len + line_count + openssh_end.len + 1);
        try text.appendSlice(allocator, openssh_begin ++ "\n");
        var lines = std.mem.window(u8, encoded, line_len, line_len);
        while (lines.next()) |line| {
            try text.appendSlice(allocator, line);
            try text.append(allocator, '\n');
        }
        try text.appendSlice(allocator, openssh_end ++ "\n");
        return try text.toOwnedSlice(allocator);
    }

    fn parseOpenssh(text: []const u8) !HostKey {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, openssh_begin) or !std.mem.endsWith(u8, trimmed, openssh_end)) return error.InvalidHostKey;
        const encoded = trimmed[openssh_begin.len .. trimmed.len - openssh_end.len];

        var blob_buf: [max_host_key_file_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &blob_buf);
        const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const blob_len = decoder.decode(&blob_buf, encoded) catch return error.InvalidHostKey;
        return parseOpensshBlob(blob_buf[0..blob_len]) catch |err| switch (err) {
            error.EncryptedHostKey, error.UnsupportedHostKeyType => |e| e,
            else => error.InvalidHostKey,
        };
    }

    fn parseOpensshBlob(blob: []const u8) !HostKey {
        var r = std.Io.Reader.fixed(blob);
        if (!std.mem.eql(u8, try r.take(openssh_magic.len), openssh_magic)) return error.InvalidHostKey;
        const cipher_name = try takeString(&r, 64);
        const kdf_name = try takeString(&r, 64);
        _ = try takeString(&r, 1024); // kdf options
        if (!std.mem.eql(u8, cipher_name, "none") or !std.mem.eql(u8, kdf_name, "none")) return error.EncryptedHostKey;
        if (try r.takeInt(u32, .big) != 1) return error.InvalidHostKey;
        var outer = std.Io.Reader.fixed(try takeString(&r, 1024));
        const private_section = try takeString(&r, 2048);
        if (r.bufferedLen() != 0) return error.InvalidHostKey;

        var private = std.Io.Reader.fixed(private_section);
        if (try private.takeInt(u32, .big) != try private.takeInt(u32, .big)) return error.InvalidHostKey;
        if (!std.mem.eql(u8, try takeString(&private, 64), "ssh-ed25519")) return error.UnsupportedHostKeyType;
        const public = try takeString(&private, 64);
        const secret = try takeString(&private, 128);
        if (secret.len != Ed25519.SecretKey.encoded_length) return error.InvalidHostKey;
        _ = try takeString(&private, 1024); // comment

        // padded with 1, 2, 3 and so on to the cipher's block size, 8 for none
        if (private_section.len % 8 != 0) return error.InvalidHostKey;
        for (private.buffered(), 1..) |byte, i| {
            if (byte != i) return error.InvalidHostKey;
        }

        // the outer public key must be the same key
        if (!std.mem.eql(u8, try takeString(&outer, 64), "ssh-ed25519") or
            !std.mem.eql(u8, try takeString(&outer, 64), public) or
            outer.bufferedLen() != 0) return error.InvalidHostKey;

        // the secret is seed || public. rebuild it from the seed so a file
        // whose halves disagree is rejected in every build mode.
        const keypair = try Ed25519.KeyPair.generateDeterministic(secret[0..Ed25519.KeyPair.seed_length].*);
        if (!std.mem.eql(u8, secret, &keypair.secret_key.bytes) or
            !std.mem.eql(u8, public, &keypair.public_key.bytes)) return error.InvalidHostKey;
        return .{ .keypair = keypair };
    }

    /// what `ssh` shows a user on first connect
    pub fn fingerprint(self: HostKey, allocator: std.mem.Allocator) ![fingerprint_len]u8 {
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(allocator);
        try self.appendPublicBlob(&blob, allocator);
        return formatFingerprint(blob.items);
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
    exec: Exec,

    pub const Exec = struct {
        command: []const u8,
        /// the GIT_PROTOCOL env value, if one arrived before the exec
        git_protocol: ?[]const u8,
    };
};

/// next thing that arrived from the client.
pub const Event = union(enum) {
    data: []u8, // CHANNEL_DATA payload — caller owns and must free via sess.conn.allocator
    resize: PtySize, // window-change request
    eof, // peer sent CHANNEL_EOF: no more input, but we may still write
    close, // peer sent CHANNEL_CLOSE, or the transport hit EOF
};

/// per-connection transport state: the byte stream, both ciphers, and what a
/// rekey needs. built once after the initial KEX and threaded through the
/// auth and channel layers.
pub const Conn = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    cs_cipher: Cipher,
    sc_cipher: Cipher,
    rekey: RekeyState,
    idle: *IdleState,
    // set only while the TUI waits to resolve a lone escape key
    read_timeout: std.Io.Timeout = .none,
    // teardown ran to the peer's EOF, so nothing more can be said
    drained: bool = false,

    fn writePacket(self: *Conn, parts: []const []const u8) !void {
        self.idle.waiting.store(true, .release);
        defer self.idle.waiting.store(false, .release);
        try self.sc_cipher.writePacket(self.io, self.writer, parts);
        // a peer that keeps reading is alive
        _ = self.idle.activity.fetchAdd(1, .acq_rel);
    }

    fn readPacket(self: *Conn) ![]u8 {
        self.idle.waiting.store(true, .release);
        defer self.idle.waiting.store(false, .release);
        if (self.read_timeout != .none and !try self.cs_cipher.hasBufferedPacket(self.reader)) {
            // peek keeps partial packets in the reader if the timer wins.
            // join both tasks before consuming bytes or changing cipher state.
            const Result = union(enum) { ready: anyerror!void, timeout: std.Io.Cancelable!void };
            var results: [2]Result = undefined;
            var select = std.Io.Select(Result).init(self.io, &results);
            defer select.cancelDiscard();
            try select.concurrent(.ready, Cipher.peekPacket, .{ &self.cs_cipher, self.reader });
            try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ self.read_timeout, self.io });
            switch (try select.await()) {
                .ready => |result| try result,
                .timeout => |result| {
                    try result;
                    return error.Timeout;
                },
            }
        }
        return self.cs_cipher.readPacket(self.allocator, self.reader);
    }
};

// how long a peer probe waits for a packet that may already be on its way
const probe_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };

/// session bridge handed to the consumer's handleSession callback. exposes a
/// pumped event API plus a byte-write API; the byte stream goes out as
/// CHANNEL_DATA packets respecting the channel's flow-control window.
pub const SessionCtx = struct {
    conn: *Conn,
    channel: *Channel,
    /// SHA256 fingerprint of the pubkey this session authenticated with,
    /// formatted as "SHA256:<base64-no-padding>" — same value the openssh
    /// client logs as `Offering public key: ED25519 SHA256:…`. consumers
    /// can use it as a stable per-key identity.
    fingerprint: [fingerprint_len]u8,
    closed: bool = false,
    // what a SessionReader or SessionWriter actually hit. kept apart so a
    // cleanup write can't replace the cause of a failed read.
    read_err: ?anyerror = null,
    write_err: ?anyerror = null,

    // shared state for the packet pump. incoming CHANNEL_DATA bytes
    // accumulate in incoming_buffer (already-consumed prefix tracked by
    // incoming_start) until drained via SessionReader or nextEvent.
    incoming_buffer: std.ArrayList(u8) = .empty,
    incoming_start: usize = 0,
    // peer sent CHANNEL_EOF — no more input arrives, but the channel stays
    // open and we may keep writing (RFC 4254 §5.3)
    incoming_eof: bool = false,
    // peer sent CHANNEL_CLOSE, or the transport died — the channel is gone
    remote_closed: bool = false,
    // .eof is handed to the caller once; later pumps wait for the close
    eof_reported: bool = false,
    // resize seen by the background pump, returned by the next nextEvent call
    pending_resize: ?PtySize = null,

    pub fn deinit(self: *SessionCtx) void {
        self.incoming_buffer.deinit(self.conn.allocator);
    }

    /// whether the client is gone. a push spends its transaction writing
    /// rather than reading, so a peer that hung up has to be pumped for. one
    /// pending packet is processed, which is where a close is seen.
    pub fn peerGone(self: *SessionCtx) bool {
        if (self.closed or self.remote_closed) return true;
        self.conn.read_timeout = probe_timeout.toDeadline(self.conn.io);
        defer self.conn.read_timeout = .none;
        self.processOneBackgroundPacket() catch |err| return err != error.Timeout;
        return self.remote_closed;
    }

    /// the std.Io adapters can only report ReadFailed or WriteFailed. recover
    /// what the session hit.
    pub fn underlyingError(self: *const SessionCtx, err: anyerror) anyerror {
        return switch (err) {
            error.ReadFailed => self.read_err orelse err,
            error.WriteFailed => self.write_err orelse err,
            else => err,
        };
    }

    fn failRead(self: *SessionCtx, err: anyerror) error{ReadFailed} {
        self.read_err = err;
        return error.ReadFailed;
    }

    fn failWrite(self: *SessionCtx, err: anyerror) error{WriteFailed} {
        self.write_err = err;
        return error.WriteFailed;
    }

    fn incomingBytes(self: *const SessionCtx) []const u8 {
        return self.incoming_buffer.items[self.incoming_start..];
    }

    // mark n incoming bytes as consumed; the buffer is recycled once empty
    fn consumeIncoming(self: *SessionCtx, n: usize) void {
        self.incoming_start += n;
        if (self.incoming_start == self.incoming_buffer.items.len) {
            self.incoming_buffer.clearRetainingCapacity();
            self.incoming_start = 0;
        }
    }

    // append to the incoming buffer, first compacting away the consumed
    // prefix so the buffer only ever holds unread bytes. bounded by the
    // receive window, which is never credited past max_incoming_buffered.
    fn appendIncoming(self: *SessionCtx, payload: []const u8) !void {
        if (self.incoming_start > 0) {
            const remaining = self.incoming_buffer.items.len - self.incoming_start;
            std.mem.copyForwards(u8, self.incoming_buffer.items[0..remaining], self.incoming_buffer.items[self.incoming_start..]);
            self.incoming_buffer.shrinkRetainingCapacity(remaining);
            self.incoming_start = 0;
        }
        try self.incoming_buffer.appendSlice(self.conn.allocator, payload);
    }

    /// interactive sessions idle legitimately; tell the host's idle
    /// watchdog to stand down for the rest of this connection.
    pub fn exemptFromIdleTimeout(self: *SessionCtx) void {
        self.conn.idle.exempt.store(true, .release);
    }

    /// pump SSH packets until something interesting (data / resize / close)
    /// arrives. background traffic (window adjusts, env requests, etc.) is
    /// handled silently. drains the same incoming state as SessionReader,
    /// so a session should consume through one or the other, not both.
    pub fn nextEvent(self: *SessionCtx) !Event {
        while (true) {
            if (self.pending_resize) |sz| {
                self.pending_resize = null;
                return .{ .resize = sz };
            }
            if (self.incomingBytes().len > 0) {
                // hand the buffered bytes to the caller (caller owns)
                const payload = try self.conn.allocator.dupe(u8, self.incomingBytes());
                errdefer self.conn.allocator.free(payload);
                self.consumeIncoming(payload.len);
                try self.maybeRefillRecvWindowForBufferedInput();
                return .{ .data = payload };
            }
            if (self.remote_closed) return .close;
            if (self.incoming_eof and !self.eof_reported) {
                self.eof_reported = true;
                return .eof;
            }
            try self.processOneBackgroundPacket();
        }
    }

    /// ship bytes to the client's stdout as one or more CHANNEL_DATA packets,
    /// respecting the peer's max-packet size. if the remote window is
    /// exhausted, pump incoming SSH packets until a WINDOW_ADJUST arrives
    /// (background packets are processed for their side effects — incoming
    /// CHANNEL_DATA goes into incoming_buffer for a future SessionReader).
    pub fn writeBytes(self: *SessionCtx, bytes: []const u8) !void {
        const conn = self.conn;

        // byte SSH_MSG_CHANNEL_DATA, uint32 recipient_channel, uint32 data length
        var header: [9]u8 = undefined;
        header[0] = SSH_MSG_CHANNEL_DATA;
        std.mem.writeInt(u32, header[1..5], self.channel.remote_id, .big);

        var rest = bytes;
        while (rest.len > 0) {
            if (self.closed or self.remote_closed) return error.RemoteClosed;
            while (self.channel.remote_window == 0) {
                if (self.remote_closed) return error.RemoteClosed;
                try self.processOneBackgroundPacket();
            }
            // also clamp to our own max so the chunk fits writePacket's buffer
            const cap = @min(rest.len, self.channel.max_packet, self.channel.remote_window, max_packet_size);
            const chunk_len: u32 = @intCast(cap);

            std.mem.writeInt(u32, header[5..9], chunk_len, .big);
            try conn.writePacket(&.{ &header, rest[0..chunk_len] });

            self.channel.remote_window -= chunk_len;
            rest = rest[chunk_len..];
        }
    }

    /// the session's packet pump: process exactly one SSH packet for side
    /// effects only. CHANNEL_DATA payloads accumulate in incoming_buffer;
    /// CHANNEL_EOF/CLOSE flips incoming_eof; WINDOW_ADJUST updates the
    /// channel state; window-change is stashed in pending_resize; other
    /// channel/global requests get a polite failure. driven by nextEvent,
    /// SessionReader, and writeBytes (waiting for send-window).
    fn processOneBackgroundPacket(self: *SessionCtx) !void {
        const conn = self.conn;
        const packet = readSessionPacket(conn) catch |err| switch (err) {
            error.EndOfStream => {
                self.incoming_eof = true;
                self.remote_closed = true;
                return;
            },
            else => return err,
        };
        defer conn.allocator.free(packet);

        switch (packet[0]) {
            SSH_MSG_CHANNEL_DATA => {
                const payload = try parseChannelData(packet, false, self.channel.local_id);
                const data_len: u32 = @intCast(payload.len);
                if (data_len > self.channel.local_window) return error.WindowExceeded;
                self.channel.local_window -= data_len;
                try self.appendIncoming(payload);
                try self.maybeRefillRecvWindowForBufferedInput();
            },
            SSH_MSG_CHANNEL_EXTENDED_DATA => {
                // discarded, but the window is still credited against what the
                // incoming buffer can take, since CHANNEL_DATA may be sitting
                // in it unread
                try discardChannelData(self.channel, packet, true);
                try self.maybeRefillRecvWindowForBufferedInput();
            },
            SSH_MSG_CHANNEL_WINDOW_ADJUST => try handleWindowAdjust(self.channel, packet),
            SSH_MSG_CHANNEL_REQUEST => {
                var r = std.Io.Reader.fixed(packet[1..]);
                const recipient_channel = try r.takeInt(u32, .big);
                if (recipient_channel != self.channel.local_id) return error.UnknownChannel;
                const req_type = try takeString(&r, 64);
                const want_reply = (try r.takeByte()) != 0;
                if (std.mem.eql(u8, req_type, "window-change")) {
                    const sz = try takePtySize(&r);
                    if (self.channel.pty != null) self.channel.pty = sz;
                    self.pending_resize = sz;
                    try replyChannelRequest(conn, self.channel, want_reply, true);
                } else {
                    // other mid-session channel requests aren't honored — fail them
                    try replyChannelRequest(conn, self.channel, want_reply, false);
                }
            },
            SSH_MSG_CHANNEL_EOF => {
                try parseChannelId(packet, self.channel.local_id);
                self.incoming_eof = true;
            },
            SSH_MSG_CHANNEL_CLOSE => {
                try parseChannelId(packet, self.channel.local_id);
                self.incoming_eof = true;
                self.remote_closed = true;
                try sendChannelMessage(conn, self.channel, SSH_MSG_CHANNEL_CLOSE);
            },
            SSH_MSG_GLOBAL_REQUEST => try handleGlobalRequest(conn, packet),
            // refused, so a multiplexing client doesn't wait on it
            SSH_MSG_CHANNEL_OPEN => _ = try handleChannelOpen(conn, packet, true),
            // RFC 4252 §5.1: silently ignored once authenticated
            SSH_MSG_USERAUTH_REQUEST => {},
            else => try sendUnimplemented(conn),
        }
    }

    fn maybeRefillRecvWindowForBufferedInput(self: *SessionCtx) !void {
        if (self.remote_closed or self.closed) return;
        // credit only what the incoming buffer can still take
        const buffered: u32 = @intCast(self.incomingBytes().len);
        try maybeRefillRecvWindow(self.conn, self.channel, max_incoming_buffered - buffered);
    }

    /// signal the consumer's exit status and tear the channel down.
    pub fn exit(self: *SessionCtx, status: u32) !void {
        if (self.closed) return;
        self.closed = true;
        const conn = self.conn;
        conn.idle.closing.store(true, .release);

        // a peer CLOSE is acknowledged by the packet pump. don't send data,
        // exit-status, or EOF after that acknowledgement.
        if (!self.remote_closed) {
            // exit-status request (informational; client uses it as the
            // command's exit code)
            {
                var req: std.ArrayList(u8) = .empty;
                defer req.deinit(conn.allocator);
                try req.append(conn.allocator, SSH_MSG_CHANNEL_REQUEST);
                try writeU32(&req, conn.allocator, self.channel.remote_id);
                try writeStringField(&req, conn.allocator, "exit-status");
                try req.append(conn.allocator, 0); // want_reply MUST be false
                try writeU32(&req, conn.allocator, status);
                try conn.writePacket(&.{req.items});
            }

            // EOF then CLOSE
            try sendChannelMessage(conn, self.channel, SSH_MSG_CHANNEL_EOF);
            try sendChannelMessage(conn, self.channel, SSH_MSG_CHANNEL_CLOSE);
        }
        drainConnection(conn);
    }
};

fn drainConnection(conn: *Conn) void {
    conn.idle.closing.store(true, .release);
    // read and discard until the peer closes (TCP FIN) before letting the
    // caller close the socket. a git client, after our CHANNEL_CLOSE, still
    // sends its own CHANNEL_CLOSE and SSH_MSG_DISCONNECT before closing; if
    // we close with those unread, Linux sends RST instead of FIN, which the
    // client reports as "Connection reset by peer" and treats as a failed
    // push even though the ref updated. draining to EOF leaves nothing
    // unread, so we send a clean FIN. the bytes don't matter, and the host's
    // watchdog bounds how long a peer can keep this going.
    _ = conn.reader.discardRemaining() catch {};
    conn.drained = true;
}

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
        self.sess.writeBytes(buffered) catch |err| return self.sess.failWrite(err);

        // then ship the bytes passed in directly. data[0..len-1] are written
        // once each; data[len-1] is written `splat` times (this is how the
        // Writer interface represents fan-out / repeated patterns).
        var extra: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            self.sess.writeBytes(chunk) catch |err| return self.sess.failWrite(err);
            extra += chunk.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.sess.writeBytes(pattern) catch |err| return self.sess.failWrite(err);
            extra += pattern.len;
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
                .vtable = &.{ .stream = stream },
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
        while (self.sess.incomingBytes().len == 0) {
            if (self.sess.incoming_eof) return error.EndOfStream;
            self.sess.processOneBackgroundPacket() catch |err| return self.sess.failRead(err);
        }

        // drain as much buffered input as the limit allows, in one go
        const chunk = limit.sliceConst(self.sess.incomingBytes());
        const written = try w.write(chunk);

        self.sess.consumeIncoming(written);
        self.sess.maybeRefillRecvWindowForBufferedInput() catch |err| return self.sess.failRead(err);

        return written;
    }
};

// ---------------------------------------------------------------------------
// public entry point
// ---------------------------------------------------------------------------

/// `handler` must be a pointer to a struct with a method:
///   pub fn handleSession(self, sess: *SessionCtx, request: Request) anyerror!void
/// invoked once the channel is open and a shell/exec request has arrived.
///
/// `reader` and `writer` are the bidirectional byte stream. `idle` is kept
/// current for the host's watchdog.
pub fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_key: *const HostKey,
    idle: *IdleState,
    handler: anytype,
) !void {
    const client_version = try exchangeVersions(allocator, reader, writer);
    defer allocator.free(client_version);

    var conn = try runKex(io, allocator, reader, writer, host_key, client_version, idle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&conn.cs_cipher));
    defer std.crypto.secureZero(u8, std.mem.asBytes(&conn.sc_cipher));

    errdefer |err| disconnectOnError(&conn, err);

    const fingerprint = try runAuth(&conn);
    try runChannelLayer(&conn, &fingerprint, handler);
}

/// tell the peer why we're hanging up (RFC 4253 §11.1), best effort. protocol
/// errors are named for whoever is debugging the client.
fn disconnectOnError(conn: *Conn, err: anyerror) void {
    if (conn.drained) return;
    const reason: u32, const description: []const u8 = switch (err) {
        // the peer hung up first, or the transport is broken
        error.EndOfStream, error.ReadFailed, error.WriteFailed => return,
        error.MacVerificationFailed => .{ SSH_DISCONNECT_MAC_ERROR, @errorName(err) },
        error.OutOfMemory, error.Canceled => .{ SSH_DISCONNECT_BY_APPLICATION, "server error" },
        else => .{ SSH_DISCONNECT_PROTOCOL_ERROR, @errorName(err) },
    };

    disconnect(conn, reason, description) catch {};
}

fn disconnect(conn: *Conn, reason: u32, description: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(conn.allocator);
    try buf.append(conn.allocator, SSH_MSG_DISCONNECT);
    try writeU32(&buf, conn.allocator, reason);
    try writeStringField(&buf, conn.allocator, description);
    try writeStringField(&buf, conn.allocator, ""); // language tag
    try conn.writePacket(&.{buf.items});
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
    // a payload starts with its message type
    if (payload_len == 0) return error.EmptyPacket;

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

/// packets handled during the plaintext phase — each direction's cipher picks
/// up its sequence number where that direction left off.
pub const PlainSeqs = struct { read: u64 = 0, written: u64 = 0 };

// transport for KEX packets: the initial exchange runs in plaintext, a rekey
// runs under the current session ciphers.
pub const KexTransport = union(enum) {
    plain: *PlainSeqs,
    encrypted: struct { cs: *Cipher, sc: *Cipher },

    // read one packet, skipping ignorable messages — unless strict kex is in
    // force, which bans them mid-handshake
    pub fn readPacket(self: KexTransport, allocator: std.mem.Allocator, reader: *std.Io.Reader, strict: bool) ![]u8 {
        while (true) {
            const packet = switch (self) {
                .plain => |seqs| packet: {
                    const packet = try readPlainPacket(allocator, reader);
                    seqs.read += 1;
                    break :packet packet;
                },
                .encrypted => |ciphers| try ciphers.cs.readPacket(allocator, reader),
            };
            if (isIgnorableMsg(packet[0])) {
                allocator.free(packet);
                if (strict) return error.StrictKexViolation;
                continue;
            }
            return packet;
        }
    }

    fn writePacket(self: KexTransport, io: std.Io, writer: *std.Io.Writer, payload: []const u8) !void {
        switch (self) {
            .plain => |seqs| {
                try writePlainPacket(io, writer, payload);
                seqs.written += 1;
            },
            .encrypted => |ciphers| try ciphers.sc.writePacket(io, writer, &.{payload}),
        }
    }
};

// read one encrypted packet for the auth and channel layers, transparently
// skipping ignorable messages and servicing client-initiated rekeys.
pub fn readSessionPacket(conn: *Conn) ![]u8 {
    while (true) {
        const packet = try conn.readPacket();
        if (isIgnorableMsg(packet[0])) {
            conn.allocator.free(packet);
            continue;
        }
        // the peer is hanging up (RFC 4253 §11.1). same end of the packet
        // stream as a transport close, so callers handle both the same way.
        if (packet[0] == SSH_MSG_DISCONNECT) {
            conn.allocator.free(packet);
            return error.EndOfStream;
        }
        if (packet[0] == SSH_MSG_KEXINIT) {
            defer conn.allocator.free(packet);
            _ = conn.idle.activity.fetchAdd(1, .acq_rel);
            try runRekey(conn, packet);
            continue;
        }
        _ = conn.idle.activity.fetchAdd(1, .acq_rel);
        return packet;
    }
}

/// RFC 4253 §11.4 — an unrecognized message must be answered with
/// SSH_MSG_UNIMPLEMENTED carrying the offending packet's sequence number.
fn sendUnimplemented(conn: *Conn) !void {
    var packet: [5]u8 = undefined;
    packet[0] = SSH_MSG_UNIMPLEMENTED;
    // the read already advanced past the packet we're rejecting
    std.mem.writeInt(u32, packet[1..5], @truncate(conn.cs_cipher.seq - 1), .big);
    try conn.writePacket(&.{&packet});
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

/// a string field's bytes, borrowed from the packet behind a fixed reader
pub fn takeString(reader: *std.Io.Reader, max_len: u32) ![]const u8 {
    const len = try reader.takeInt(u32, .big);
    if (len > max_len) return error.FieldTooLarge;
    return reader.take(len);
}

// the first name in the peer's preference list that we also support (RFC
// 4253 §7.1)
fn firstCommonName(peer_names: []const u8, our_names: []const []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, peer_names, ',');
    while (iter.next()) |name| {
        for (our_names) |ours| {
            if (std.mem.eql(u8, name, ours)) return ours;
        }
    }
    return null;
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
// the client asks for EXT_INFO after the initial NEWKEYS (RFC 8308)
pub const ext_info_client = "ext-info-c";

const MLKem768 = std.crypto.kem.ml_kem.MLKem768;
const hybrid_client_blob_len = MLKem768.PublicKey.encoded_length + X25519.public_length; // 1216
const hybrid_server_blob_len = MLKem768.ciphertext_length + X25519.public_length; // 1120
pub const our_host_key_algos = [_][]const u8{"ssh-ed25519"};
pub const our_userauth_algos = [_][]const u8{ "ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256" };
pub const our_ciphers = [_][]const u8{"chacha20-poly1305@openssh.com"};
const our_macs = [_][]const u8{}; // none — implicit in the AEAD cipher
const our_compression = [_][]const u8{"none"};

/// build a KEXINIT payload with the given algorithm name-lists
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

// the name-lists borrow from the KEXINIT payload
const ParsedKexInit = struct {
    kex_algos: []const u8,
    host_key_algos: []const u8,
    cs_cipher: []const u8,
    sc_cipher: []const u8,
    first_kex_packet_follows: bool,
};

fn parseClientKexInit(payload: []const u8) !ParsedKexInit {
    if (payload.len < 1 + 16) return error.KexInitTruncated;
    if (payload[0] != SSH_MSG_KEXINIT) return error.UnexpectedMessage;

    var reader = std.Io.Reader.fixed(payload[1 + 16 ..]); // skip type + cookie

    const kex_algos = try takeString(&reader, max_name_list_len);
    const host_key_algos = try takeString(&reader, max_name_list_len);
    const cs_cipher = try takeString(&reader, max_name_list_len);
    const sc_cipher = try takeString(&reader, max_name_list_len);

    // skip c->s mac, s->c mac, c->s compress, s->c compress, lang c->s, lang s->c
    for (0..6) |_| _ = try takeString(&reader, max_name_list_len);
    const first_kex_packet_follows = (try reader.takeByte()) != 0;
    _ = try reader.takeInt(u32, .big); // reserved

    return .{
        .kex_algos = kex_algos,
        .host_key_algos = host_key_algos,
        .cs_cipher = cs_cipher,
        .sc_cipher = sc_cipher,
        .first_kex_packet_follows = first_kex_packet_follows,
    };
}

// ---------------------------------------------------------------------------
// KEX orchestration: KEXINIT → ECDH → NEWKEYS → key derivation
// ---------------------------------------------------------------------------

fn runKex(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    host_key: *const HostKey,
    client_version: []const u8,
    idle: *IdleState,
) !Conn {
    var seqs: PlainSeqs = .{};
    const transport = KexTransport{ .plain = &seqs };

    // exchange KEXINITs
    const server_kex_init = try buildServerKexInit(io, allocator);
    defer allocator.free(server_kex_init);
    try transport.writePacket(io, writer, server_kex_init);

    const client_kex_init = try transport.readPacket(allocator, reader, false);
    defer allocator.free(client_kex_init);

    const parsed = try parseClientKexInit(client_kex_init);

    // strict kex: when the client advertises it, its KEXINIT must be the
    // first packet, ignorable messages are banned until NEWKEYS, and both
    // seqnos reset to 0 after every NEWKEYS.
    const strict = firstCommonName(parsed.kex_algos, &.{kex_strict_client}) != null;
    if (strict and seqs.read != 1) return error.StrictKexViolation;
    const ext_info = firstCommonName(parsed.kex_algos, &.{ext_info_client}) != null;

    var keys: SessionKeys = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
    const session_id = try exchangeKeys(
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
        &parsed,
        null,
        &keys,
    );

    // post-KEX everything is encrypted with chacha20-poly1305@openssh.com.
    // each cipher continues its own direction's count; the read side
    // includes any skipped IGNORE/DEBUG packets.
    var conn: Conn = .{
        .io = io,
        .allocator = allocator,
        .reader = reader,
        .writer = writer,
        .cs_cipher = .init(&keys.cs_enc, if (strict) 0 else seqs.read),
        .sc_cipher = .init(&keys.sc_enc, if (strict) 0 else seqs.written),
        .rekey = .{
            .host_key = host_key,
            .client_version = client_version,
            .session_id = session_id,
            .strict = strict,
        },
        .idle = idle,
    };
    if (ext_info) try sendExtInfo(&conn);
    return conn;
}

// advertise server-sig-algs so clients will offer rsa-sha2 keys (RFC 8308 §3.1)
fn sendExtInfo(conn: *Conn) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(conn.allocator);
    try buf.append(conn.allocator, SSH_MSG_EXT_INFO);
    try writeU32(&buf, conn.allocator, 1); // one extension
    try writeStringField(&buf, conn.allocator, "server-sig-algs");
    try writeNameList(&buf, conn.allocator, &our_userauth_algos);
    try conn.writePacket(&.{buf.items});
}

/// everything needed to service a client-initiated rekey mid-session.
const RekeyState = struct {
    host_key: *const HostKey,
    client_version: []const u8,
    session_id: [Sha256.digest_length]u8,
    strict: bool,
};

// service a rekey whose triggering KEXINIT payload has just been read: run
// the whole exchange under the current keys, then swap the new keys into
// both ciphers in place.
fn runRekey(conn: *Conn, client_kex_init: []const u8) !void {
    const parsed = try parseClientKexInit(client_kex_init);

    // the exchange reads and writes through the ciphers directly
    conn.idle.waiting.store(true, .release);
    defer conn.idle.waiting.store(false, .release);

    const server_kex_init = try buildServerKexInit(conn.io, conn.allocator);
    defer conn.allocator.free(server_kex_init);
    try conn.sc_cipher.writePacket(conn.io, conn.writer, &.{server_kex_init});

    var keys: SessionKeys = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
    _ = try exchangeKeys(
        conn.io,
        conn.allocator,
        conn.reader,
        conn.writer,
        .{ .encrypted = .{ .cs = &conn.cs_cipher, .sc = &conn.sc_cipher } },
        false, // strict kex message rules apply to the initial exchange only
        conn.rekey.host_key,
        conn.rekey.client_version,
        client_kex_init,
        server_kex_init,
        &parsed,
        &conn.rekey.session_id,
        &keys,
    );

    // seqnos continue across a rekey unless strict kex was negotiated,
    // which resets them after every NEWKEYS
    conn.cs_cipher = .init(&keys.cs_enc, if (conn.rekey.strict) 0 else conn.cs_cipher.seq);
    conn.sc_cipher = .init(&keys.sc_enc, if (conn.rekey.strict) 0 else conn.sc_cipher.seq);
}

// the KEX core shared by the initial exchange and rekeys: pick algorithms,
// run the (hybrid) ECDH round trip, exchange NEWKEYS, derive keys. both
// KEXINIT payloads have already been exchanged by the caller, which also owns
// `parsed`; the client's raw payload comes along too because the exchange hash
// covers it verbatim. session_id is null on the initial exchange (where it
// becomes the exchange hash) and the original session id on a rekey. fills
// `keys` and returns the exchange hash.
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
    parsed: *const ParsedKexInit,
    session_id: ?*const [Sha256.digest_length]u8,
    keys: *SessionKeys,
) ![Sha256.digest_length]u8 {
    const kex_algo = firstCommonName(parsed.kex_algos, &our_kex_algos) orelse return error.NoCommonKexAlgorithm;
    if (firstCommonName(parsed.host_key_algos, &our_host_key_algos) == null) return error.NoCommonHostKeyAlgorithm;
    if (firstCommonName(parsed.cs_cipher, &our_ciphers) == null) return error.NoCommonCipher;
    if (firstCommonName(parsed.sc_cipher, &our_ciphers) == null) return error.NoCommonCipher;
    const hybrid = std.mem.eql(u8, kex_algo, "mlkem768x25519-sha256");

    // a client may follow its KEXINIT with a kex packet for its guess. the
    // guess is right only when both sides' first kex and host key algorithms
    // match (RFC 4253 §7.1) — not when the client's first choice merely
    // happens to be kex_algo, so this compares against our list. a client
    // whose guess was wrong re-sends an init for the negotiated method.
    if (parsed.first_kex_packet_follows) {
        var kex_iter = std.mem.splitScalar(u8, parsed.kex_algos, ',');
        var host_key_iter = std.mem.splitScalar(u8, parsed.host_key_algos, ',');
        const guessed_right = std.mem.eql(u8, kex_iter.first(), our_kex_algos[0]) and
            std.mem.eql(u8, host_key_iter.first(), our_host_key_algos[0]);
        if (!guessed_right) {
            const wrong_guess = try transport.readPacket(allocator, reader, strict);
            allocator.free(wrong_guess);
        }
    }

    // receive KEX_ECDH_INIT (mlkem768x25519 reuses message code 30 — same
    // wire shape, only the string size differs).
    const ecdh_init = try transport.readPacket(allocator, reader, strict);
    defer allocator.free(ecdh_init);
    if (ecdh_init[0] != SSH_MSG_KEX_ECDH_INIT) return error.UnexpectedMessage;

    var ecdh_init_reader = std.Io.Reader.fixed(ecdh_init[1..]);
    const expected_client_len: u32 = if (hybrid) hybrid_client_blob_len else X25519.public_length;
    const client_blob = try takeString(&ecdh_init_reader, expected_client_len);
    if (client_blob.len != expected_client_len) return error.InvalidEphemeralKey;

    // derive server reply blob (S_REPLY) + shared secret K.
    //   ECDH: server_blob = X25519 server pub (32B); K = X25519(s, c_pub).
    //   hybrid: server_blob = MLKEM ciphertext (1088B) || X25519 server pub (32B);
    //           K = SHA-256(K_MLKEM || K_X25519).
    var server_blob_buf: [hybrid_server_blob_len]u8 = undefined;
    var k: [Sha256.digest_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &k);
    const server_blob: []const u8 = blk: {
        const x25519_offset: usize = if (hybrid) MLKem768.PublicKey.encoded_length else 0;
        var x25519_client_pub: [X25519.public_length]u8 = undefined;
        @memcpy(&x25519_client_pub, client_blob[x25519_offset..]);
        var server_kp = X25519.KeyPair.generate(io);
        defer std.crypto.secureZero(u8, &server_kp.secret_key);
        var x25519_shared = try X25519.scalarmult(server_kp.secret_key, x25519_client_pub);
        defer std.crypto.secureZero(u8, &x25519_shared);

        if (!hybrid) {
            server_blob_buf[0..X25519.public_length].* = server_kp.public_key;
            k = x25519_shared;
            break :blk server_blob_buf[0..X25519.public_length];
        }

        var pq_pub_bytes: [MLKem768.PublicKey.encoded_length]u8 = undefined;
        @memcpy(&pq_pub_bytes, client_blob[0..MLKem768.PublicKey.encoded_length]);
        const pq_pub = try MLKem768.PublicKey.fromBytes(&pq_pub_bytes);
        var encap = pq_pub.encaps(io);
        defer std.crypto.secureZero(u8, &encap.shared_secret);

        server_blob_buf[0..MLKem768.ciphertext_length].* = encap.ciphertext;
        server_blob_buf[MLKem768.ciphertext_length..].* = server_kp.public_key;

        var h = Sha256.init(.{});
        defer std.crypto.secureZero(u8, std.mem.asBytes(&h));
        h.update(&encap.shared_secret);
        h.update(&x25519_shared);
        h.final(&k);
        break :blk &server_blob_buf;
    };

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
        &k,
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
    try transport.writePacket(io, writer, reply.items);

    // NEWKEYS — both sides switch to the new keys after this is sent and
    // the peer's NEWKEYS is received.
    try transport.writePacket(io, writer, &[_]u8{SSH_MSG_NEWKEYS});

    const peer_newkeys = try transport.readPacket(allocator, reader, strict);
    defer allocator.free(peer_newkeys);
    if (peer_newkeys[0] != SSH_MSG_NEWKEYS) return error.UnexpectedMessage;

    // derive session keys per RFC 4253 §7.2. only the encrypt keys are
    // needed for chacha20-poly1305 (no separate MAC/IV).
    try deriveSessionKeys(allocator, &k, &exchange_hash, if (session_id) |sid| sid else &exchange_hash, keys, hybrid);
    return exchange_hash;
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
    defer std.crypto.secureZero(u8, buf.items);
    // reserved up front so a reallocation can't leave K behind
    try buf.ensureTotalCapacityPrecise(allocator, 8 * 4 + 1 + client_version.len + server_version_str.len +
        client_kex_init.len + server_kex_init.len + host_key_blob.len + client_ephemeral.len +
        server_ephemeral.len + shared_secret.len);

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
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hasher));
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
    defer std.crypto.secureZero(u8, prefix.items);
    // reserved up front so a reallocation can't leave K behind
    try prefix.ensureTotalCapacityPrecise(allocator, 4 + 1 + shared_secret.len + exchange_hash.len);
    if (k_is_string) {
        try writeStringField(&prefix, allocator, shared_secret);
    } else {
        try writeMpint(&prefix, allocator, shared_secret);
    }
    try prefix.appendSlice(allocator, exchange_hash);

    deriveKey(prefix.items, 'C', session_id, &out.cs_enc);
    deriveKey(prefix.items, 'D', session_id, &out.sc_enc);
}

fn deriveKey(
    prefix: []const u8, // K || H, already encoded
    letter: u8,
    session_id: []const u8,
    out: *[2 * Sha256.digest_length]u8,
) void {
    // a finished context still holds its digest and last input block
    // K_1 = HASH(K || H || letter || session_id)
    var first = Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&first));
    first.update(prefix);
    first.update(&.{letter});
    first.update(session_id);
    first.final(out[0..Sha256.digest_length]);

    // K_2 = HASH(K || H || K_1)
    var second = Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&second));
    second.update(prefix);
    second.update(out[0..Sha256.digest_length]);
    second.final(out[Sha256.digest_length..]);
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
    // wider than the 32-bit wire seqno, so a peer that never rekeys fails the
    // mac at 2^32 packets instead of wrapping into nonce reuse
    seq: u64,

    pub fn init(key_material: *const [64]u8, initial_seq: u64) Cipher {
        return .{
            .main_key = key_material[0..32].*,
            .header_key = key_material[32..64].*,
            .seq = initial_seq,
        };
    }

    fn makeNonce(seq: u64) [8]u8 {
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, seq, .big);
        return nonce;
    }

    fn bodyLength(self: *const Cipher, enc_length: *const [4]u8) !u32 {
        var plain: [4]u8 = undefined;
        ChaCha20.xor(&plain, enc_length, 0, self.header_key, makeNonce(self.seq));
        const len = std.mem.readInt(u32, &plain, .big);
        if (len < 8 or len > max_packet_len or len % 8 != 0) return error.InvalidPacketLength;
        return len;
    }

    fn peekPacket(self: *const Cipher, reader: *std.Io.Reader) !void {
        const len = 4 + (try self.bodyLength(try reader.peekArray(4))) + Poly1305.mac_length;
        if (len > reader.buffer.len) return error.ReadBufferTooSmall;
        _ = try reader.peek(len);
    }

    fn hasBufferedPacket(self: *const Cipher, reader: *std.Io.Reader) !bool {
        const bytes = reader.buffered();
        if (bytes.len < 4) return false;
        return bytes.len >= 4 + (try self.bodyLength(bytes[0..4])) + Poly1305.mac_length;
    }

    /// the payload is the concatenation of `parts`
    pub fn writePacket(
        self: *Cipher,
        io: std.Io,
        writer: *std.Io.Writer,
        parts: []const []const u8,
    ) !void {
        var payload_len: usize = 0;
        for (parts) |part| payload_len += part.len;

        const block: usize = 8;
        const initial_pad = block - ((1 + payload_len) % block);
        const padding_len: u8 = @intCast(if (initial_pad < 4) initial_pad + block else initial_pad);
        const body_len = 1 + payload_len + padding_len;
        if (body_len > max_packet_len) return error.PacketTooLarge;

        const nonce = makeNonce(self.seq);

        // encrypted length || body || mac, contiguous so the packet goes out
        // in one write. stack-allocated to avoid a heap alloc on every packet.
        var packet_buf: [packet_buffer_size]u8 = undefined;
        const packet = packet_buf[0 .. 4 + body_len + Poly1305.mac_length];
        const enc_length = packet[0..4];
        const body = packet[4..][0..body_len];

        // plaintext body = padding_length || payload || random padding
        body[0] = padding_len;
        var end: usize = 1;
        for (parts) |part| {
            @memcpy(body[end..][0..part.len], part);
            end += part.len;
        }
        io.random(body[end..]);

        // encrypt body in place with counter=1
        ChaCha20.xor(body, body, 1, self.main_key, nonce);

        // encrypt length field with header key, counter=0
        std.mem.writeInt(u32, enc_length, @intCast(body_len), .big);
        ChaCha20.xor(enc_length, enc_length, 0, self.header_key, nonce);

        // poly1305 key = first 32 bytes of chacha20(K_2, nonce, counter=0)
        var poly_key: [Poly1305.key_length]u8 = undefined;
        ChaCha20.stream(&poly_key, 0, self.main_key, nonce);

        // mac over encrypted_length || encrypted_body
        var poly = Poly1305.init(&poly_key);
        poly.update(packet[0 .. 4 + body_len]);
        poly.final(packet[4 + body_len ..][0..Poly1305.mac_length]);

        try writer.writeAll(packet);
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

        const body_len = try self.bodyLength(&enc_length);

        // the body allocation becomes the returned payload, so a packet only
        // ever costs one allocation
        const body = try allocator.alloc(u8, body_len);
        errdefer allocator.free(body);
        try reader.readSliceAll(body);

        var tag_recv: [Poly1305.mac_length]u8 = undefined;
        try reader.readSliceAll(&tag_recv);

        var poly_key: [Poly1305.key_length]u8 = undefined;
        ChaCha20.stream(&poly_key, 0, self.main_key, nonce);

        var poly = Poly1305.init(&poly_key);
        poly.update(&enc_length);
        poly.update(body);
        var tag_computed: [Poly1305.mac_length]u8 = undefined;
        poly.final(&tag_computed);
        if (!std.crypto.timing_safe.eql([Poly1305.mac_length]u8, tag_recv, tag_computed)) {
            return error.MacVerificationFailed;
        }

        // decrypt the body in place
        ChaCha20.xor(body, body, 1, self.main_key, nonce);

        const padding_len = body[0];
        if (padding_len < 4 or 1 + @as(u32, padding_len) > body_len) return error.InvalidPadding;
        const payload_len = body_len - 1 - @as(u32, padding_len);
        // a payload starts with its message type
        if (payload_len == 0) return error.EmptyPacket;

        // shift the payload over the padding_length byte, then release the
        // trailing padding (caller owns the result)
        std.mem.copyForwards(u8, body[0..payload_len], body[1 .. 1 + payload_len]);
        const payload = try allocator.realloc(body, payload_len);

        self.seq += 1;
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

fn runAuth(conn: *Conn) ![fingerprint_len]u8 {
    const allocator = conn.allocator;

    // step 1: service request for ssh-userauth → service accept
    {
        const req = try readSessionPacket(conn);
        defer allocator.free(req);
        if (req[0] != SSH_MSG_SERVICE_REQUEST) return error.UnexpectedMessage;

        var req_reader = std.Io.Reader.fixed(req[1..]);
        const service = try takeString(&req_reader, 64);
        if (!std.mem.eql(u8, service, "ssh-userauth")) return error.UnsupportedService;

        var accept: std.ArrayList(u8) = .empty;
        defer accept.deinit(allocator);
        try accept.append(allocator, SSH_MSG_SERVICE_ACCEPT);
        try writeStringField(&accept, allocator, "ssh-userauth");
        try conn.writePacket(&.{accept.items});
    }

    // step 2: USERAUTH loop until SUCCESS. accept any supported key whose
    // signature verifies against the offered pubkey.
    var auth_attempts: u32 = 0;
    while (true) {
        const req = try readSessionPacket(conn);
        defer allocator.free(req);
        if (req[0] != SSH_MSG_USERAUTH_REQUEST) return error.UnexpectedMessage;

        // every request counts, probes included, so a client can't loop here
        // forever
        if (auth_attempts >= max_auth_attempts) return error.TooManyAuthAttempts;
        auth_attempts += 1;

        var req_reader = std.Io.Reader.fixed(req[1..]);
        const user_name = try takeString(&req_reader, 256);
        const service_name = try takeString(&req_reader, 64);
        const method = try takeString(&req_reader, 64);

        // RFC 4252 §5: the server must verify the requested service
        if (!std.mem.eql(u8, service_name, "ssh-connection")) {
            try sendUserauthFailure(conn);
            continue;
        }

        if (!std.mem.eql(u8, method, "publickey")) {
            try sendUserauthFailure(conn);
            continue;
        }

        const has_signature = (try req_reader.takeByte()) != 0;
        const algo = try takeString(&req_reader, 64);
        const pubkey_blob = try takeString(&req_reader, 4096);

        if (firstCommonName(algo, &our_userauth_algos) == null) {
            try sendUserauthFailure(conn);
            continue;
        }

        if (!has_signature) {
            // probe — tell the client this key is acceptable so it'll send
            // the signed version next.
            var pk_ok: std.ArrayList(u8) = .empty;
            defer pk_ok.deinit(allocator);
            try pk_ok.append(allocator, SSH_MSG_USERAUTH_PK_OK);
            try writeStringField(&pk_ok, allocator, algo);
            try writeStringField(&pk_ok, allocator, pubkey_blob);
            try conn.writePacket(&.{pk_ok.items});
            continue;
        }

        // has signature — verify it
        const signature_blob = try takeString(&req_reader, 1024);

        const ok = verifyUserauthSignature(
            allocator,
            &conn.rekey.session_id,
            user_name,
            service_name,
            algo,
            pubkey_blob,
            signature_blob,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // a malformed key or signature blob
            else => false,
        };

        if (!ok) {
            try sendUserauthFailure(conn);
            continue;
        }

        try conn.writePacket(&.{&[_]u8{SSH_MSG_USERAUTH_SUCCESS}});
        return formatFingerprint(pubkey_blob);
    }
}

fn sendUserauthFailure(conn: *Conn) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(conn.allocator);
    try buf.append(conn.allocator, SSH_MSG_USERAUTH_FAILURE);
    try writeNameList(&buf, conn.allocator, &.{"publickey"}); // allowed methods
    try buf.append(conn.allocator, 0); // partial_success = false
    try conn.writePacket(&.{buf.items});
}

/// append the canonical publickey-signed-data bytes (RFC 4252 §7) to `buf`.
/// used by the server to recompute the signed input for verification
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

    if (std.mem.eql(u8, algo, "ssh-ed25519")) return verifyEd25519(pubkey_blob, signature_blob, signed.items);
    if (std.mem.eql(u8, algo, "rsa-sha2-512")) return verifyRsa(Sha512, algo, pubkey_blob, signature_blob, signed.items);
    if (std.mem.eql(u8, algo, "rsa-sha2-256")) return verifyRsa(Sha256, algo, pubkey_blob, signature_blob, signed.items);
    return false;
}

fn verifyEd25519(pubkey_blob: []const u8, signature_blob: []const u8, signed: []const u8) !bool {
    // parse pubkey_blob: string "ssh-ed25519" || string raw_pubkey
    var pubkey_reader = std.Io.Reader.fixed(pubkey_blob);
    const pk_algo = try takeString(&pubkey_reader, 64);
    if (!std.mem.eql(u8, pk_algo, "ssh-ed25519")) return false;
    const raw_pubkey = try takeString(&pubkey_reader, 64);
    if (raw_pubkey.len != Ed25519.PublicKey.encoded_length) return false;
    // the fingerprint hashes the whole blob, so it must hold nothing else
    if (pubkey_reader.bufferedLen() != 0) return false;

    // parse signature_blob: string "ssh-ed25519" || string raw_signature
    var sig_reader = std.Io.Reader.fixed(signature_blob);
    const sig_algo = try takeString(&sig_reader, 64);
    if (!std.mem.eql(u8, sig_algo, "ssh-ed25519")) return false;
    const raw_sig = try takeString(&sig_reader, Ed25519.Signature.encoded_length);
    if (raw_sig.len != Ed25519.Signature.encoded_length) return false;

    var pubkey_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    @memcpy(&pubkey_bytes, raw_pubkey);
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_bytes, raw_sig);

    const pk = Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return false;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(signed, pk) catch return false;
    return true;
}

fn verifyRsa(comptime Hash: type, algo: []const u8, pubkey_blob: []const u8, signature_blob: []const u8, signed: []const u8) !bool {
    // parse pubkey_blob: string "ssh-rsa" || mpint e || mpint n
    var pubkey_reader = std.Io.Reader.fixed(pubkey_blob);
    if (!std.mem.eql(u8, try takeString(&pubkey_reader, 64), "ssh-rsa")) return false;
    // the fingerprint hashes the whole blob, so one key must have one encoding
    const e = canonicalMpintMagnitude(try takeString(&pubkey_reader, 1024)) orelse return false;
    const n = canonicalMpintMagnitude(try takeString(&pubkey_reader, 1024)) orelse return false;
    if (pubkey_reader.bufferedLen() != 0) return false;

    // parse signature_blob: string algo || string sig
    var sig_reader = std.Io.Reader.fixed(signature_blob);
    if (!std.mem.eql(u8, try takeString(&sig_reader, 64), algo)) return false;
    const sig = try takeString(&sig_reader, 1024);
    if (sig.len != n.len) return false;

    const pk = rsa.PublicKey.fromBytes(e, n) catch return false;
    switch (n.len) {
        inline 256, 384, 512 => |len| {
            rsa.PKCS1v1_5Signature.verify(len, sig[0..len].*, signed, pk, Hash) catch return false;
            return true;
        },
        else => return false,
    }
}

// the unsigned bytes of a positive mpint in its shortest encoding (RFC 4251
// §5), or null for zero, negative, or padded encodings
fn canonicalMpintMagnitude(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[0] & 0x80 != 0) return null;
    if (bytes[0] != 0) return bytes;
    if (bytes.len < 2 or bytes[1] & 0x80 == 0) return null;
    return bytes[1..];
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
    // value of GIT_PROTOCOL, the one env variable we keep
    git_protocol_buf: [64]u8 = undefined,
    git_protocol_len: ?usize = null,
};

pub const PtySize = struct { width_cells: u16, height_cells: u16 };

// take the uint32 width/height cell counts of a pty-req or window-change,
// bounded before either initial rendering or a resize can allocate grids.
// keep zero dimensions intact (unspecified at startup, minimized on resize).
fn takePtySize(r: *std.Io.Reader) !PtySize {
    const width = @min(try r.takeInt(u32, .big), max_pty_width);
    const height = @min(try r.takeInt(u32, .big), max_pty_height);
    return .{
        .width_cells = @intCast(width),
        .height_cells = @intCast(height),
    };
}

fn runChannelLayer(
    conn: *Conn,
    fingerprint: *const [fingerprint_len]u8,
    handler: anytype,
) !void {
    const allocator = conn.allocator;
    var channel: ?Channel = null;

    while (true) {
        const packet = try readSessionPacket(conn);
        defer allocator.free(packet);
        const msg_type = packet[0];

        switch (msg_type) {
            SSH_MSG_GLOBAL_REQUEST => try handleGlobalRequest(conn, packet),

            SSH_MSG_CHANNEL_OPEN => {
                channel = try handleChannelOpen(conn, packet, channel != null) orelse continue;
            },

            SSH_MSG_CHANNEL_REQUEST => {
                const ch = if (channel) |*c| c else continue;
                const start_request = try handleChannelRequest(conn, ch, packet);
                // the request borrows from the packet, which outlives the session
                if (start_request) |request| {
                    // any key authenticates, so the deadline holds until here
                    conn.idle.session_started.store(true, .release);
                    var sess = SessionCtx{
                        .conn = conn,
                        .channel = ch,
                        .fingerprint = fingerprint.*,
                    };
                    defer sess.deinit();
                    handler.handleSession(&sess, request) catch |session_err| {
                        // try to send a non-zero exit status before closing
                        sess.exit(1) catch {};
                        return sess.underlyingError(session_err);
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
                // some clients are chatty; discard and refill window. nothing
                // is buffered yet, so the whole window is available to credit.
                try discardChannelData(ch, packet, msg_type == SSH_MSG_CHANNEL_EXTENDED_DATA);
                try maybeRefillRecvWindow(conn, ch, initial_recv_window);
            },

            SSH_MSG_CHANNEL_EOF => {
                if (channel) |*c| try parseChannelId(packet, c.local_id);
            },

            SSH_MSG_CHANNEL_CLOSE => {
                if (channel) |*c| {
                    try parseChannelId(packet, c.local_id);
                    try sendChannelMessage(conn, c, SSH_MSG_CHANNEL_CLOSE);
                    drainConnection(conn);
                }
                return;
            },

            // RFC 4252 §5.1: silently ignored once authenticated
            SSH_MSG_USERAUTH_REQUEST => {},
            else => try sendUnimplemented(conn),
        }
    }
}

fn handleGlobalRequest(conn: *Conn, packet: []const u8) !void {
    // byte SSH_MSG_GLOBAL_REQUEST
    // string request_name
    // boolean want_reply
    // …request-specific data we ignore
    var r = std.Io.Reader.fixed(packet[1..]);
    _ = try takeString(&r, 256);
    const want_reply = (try r.takeByte()) != 0;
    if (want_reply) {
        try conn.writePacket(&.{&[_]u8{SSH_MSG_REQUEST_FAILURE}});
    }
}

/// parse a CHANNEL_OPEN. on a session channel, send CHANNEL_OPEN_CONFIRMATION
/// and return the new Channel. on other types, send CHANNEL_OPEN_FAILURE and
/// return null.
fn handleChannelOpen(conn: *Conn, packet: []const u8, has_channel: bool) !?Channel {
    // byte SSH_MSG_CHANNEL_OPEN
    // string channel_type
    // uint32 sender_channel (peer's id)
    // uint32 initial_window
    // uint32 max_packet
    var r = std.Io.Reader.fixed(packet[1..]);
    const ch_type = try takeString(&r, 64);
    const remote_id = try r.takeInt(u32, .big);
    const initial_window = try r.takeInt(u32, .big);
    const max_packet = try r.takeInt(u32, .big);

    if (has_channel) {
        try sendChannelOpenFailure(conn, remote_id, SSH_OPEN_RESOURCE_SHORTAGE, "only one channel per connection");
        return null;
    }

    if (!std.mem.eql(u8, ch_type, "session")) {
        try sendChannelOpenFailure(conn, remote_id, SSH_OPEN_UNKNOWN_CHANNEL_TYPE, "only session channels are supported");
        return null;
    }

    // a zero max_packet would leave writeBytes looping without progress
    if (max_packet == 0) {
        try sendChannelOpenFailure(conn, remote_id, SSH_OPEN_RESOURCE_SHORTAGE, "max packet size must be non-zero");
        return null;
    }

    const local_id: u32 = 0; // single-channel connection — id is always 0 from our side
    var reply: [17]u8 = undefined;
    reply[0] = SSH_MSG_CHANNEL_OPEN_CONFIRMATION;
    std.mem.writeInt(u32, reply[1..5], remote_id, .big);
    std.mem.writeInt(u32, reply[5..9], local_id, .big);
    std.mem.writeInt(u32, reply[9..13], initial_recv_window, .big);
    std.mem.writeInt(u32, reply[13..17], max_packet_size, .big);
    try conn.writePacket(&.{&reply});

    return .{
        .local_id = local_id,
        .remote_id = remote_id,
        .local_window = initial_recv_window,
        .remote_window = initial_window,
        .max_packet = max_packet,
    };
}

fn sendChannelOpenFailure(conn: *Conn, remote_id: u32, reason: u32, description: []const u8) !void {
    const allocator = conn.allocator;

    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.append(allocator, SSH_MSG_CHANNEL_OPEN_FAILURE);
    try writeU32(&reply, allocator, remote_id);
    try writeU32(&reply, allocator, reason);
    try writeStringField(&reply, allocator, description);
    try writeStringField(&reply, allocator, ""); // language tag
    try conn.writePacket(&.{reply.items});
}

/// returns the session request if this one triggered it, else null. an exec
/// command borrows from `packet`.
fn handleChannelRequest(conn: *Conn, ch: *Channel, packet: []const u8) !?Request {
    // byte SSH_MSG_CHANNEL_REQUEST
    // uint32 recipient_channel (== our local_id)
    // string request_type
    // boolean want_reply
    // …request-specific data
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != ch.local_id) return error.UnknownChannel;
    const req_type = try takeString(&r, 64);
    const want_reply = (try r.takeByte()) != 0;

    if (std.mem.eql(u8, req_type, "pty-req")) {
        // string TERM, uint32 width chars, uint32 height rows, uint32 width px,
        // uint32 height px, string modes
        _ = try takeString(&r, 64);
        ch.pty = try takePtySize(&r);
        try replyChannelRequest(conn, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "env")) {
        // string name, string value. the rest are ignored silently.
        const name = try takeString(&r, max_packet_len);
        const value = try takeString(&r, max_packet_len);
        if (std.mem.eql(u8, name, "GIT_PROTOCOL") and value.len <= ch.git_protocol_buf.len) {
            @memcpy(ch.git_protocol_buf[0..value.len], value);
            ch.git_protocol_len = value.len;
        }
        try replyChannelRequest(conn, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "window-change")) {
        // uint32 width cells, uint32 height rows, uint32 width px, uint32 height px
        const sz = try takePtySize(&r);
        if (ch.pty != null) ch.pty = sz;
        // spec: window-change MUST NOT request a reply, but accept either
        try replyChannelRequest(conn, ch, want_reply, true);
        return null;
    }

    if (std.mem.eql(u8, req_type, "shell")) {
        try replyChannelRequest(conn, ch, want_reply, true);
        return .{ .shell = ch.pty };
    }

    if (std.mem.eql(u8, req_type, "exec")) {
        // capture the command string for the handler to inspect
        const cmd = try takeString(&r, 4096);
        try replyChannelRequest(conn, ch, want_reply, true);
        return .{ .exec = .{
            .command = cmd,
            .git_protocol = if (ch.git_protocol_len) |len| ch.git_protocol_buf[0..len] else null,
        } };
    }

    // unknown request kind — fail it
    try replyChannelRequest(conn, ch, want_reply, false);
    return null;
}

fn replyChannelRequest(conn: *Conn, ch: *Channel, want_reply: bool, success: bool) !void {
    if (!want_reply) return;
    try sendChannelMessage(conn, ch, if (success) SSH_MSG_CHANNEL_SUCCESS else SSH_MSG_CHANNEL_FAILURE);
}

fn sendChannelMessage(conn: *Conn, ch: *Channel, msg_type: u8) !void {
    var packet: [5]u8 = undefined;
    packet[0] = msg_type;
    std.mem.writeInt(u32, packet[1..5], ch.remote_id, .big);
    try conn.writePacket(&.{&packet});
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

// charge a payload's bytes against the receive window without keeping them.
// the caller credits the window back, choosing the budget that suits it.
fn discardChannelData(ch: *Channel, packet: []const u8, extended: bool) !void {
    // byte SSH_MSG_CHANNEL_DATA/EXTENDED_DATA
    // uint32 recipient_channel
    // [if extended: uint32 type_code]
    // string data
    const payload = try parseChannelData(packet, extended, ch.local_id);
    const data_len: u32 = @intCast(payload.len);

    if (data_len > ch.local_window) return error.WindowExceeded;
    ch.local_window -= data_len;
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
    var r = std.Io.Reader.fixed(packet[1..]);
    const recipient_channel = try r.takeInt(u32, .big);
    if (recipient_channel != expected_channel) return error.UnknownChannel;
    if (r.buffered().len != 0) return error.InvalidChannelMessage;
}

/// send a CHANNEL_WINDOW_ADJUST if our receive window has dipped below half
/// of `budget`, the credit we're willing to have outstanding. used both for
/// the pre-session discard path and by SessionCtx after it consumes a
/// CHANNEL_DATA payload.
fn maybeRefillRecvWindow(conn: *Conn, ch: *Channel, budget: u32) !void {
    if (ch.local_window >= budget / 2) return;
    const add = budget - ch.local_window;
    ch.local_window += add;
    var packet: [9]u8 = undefined;
    packet[0] = SSH_MSG_CHANNEL_WINDOW_ADJUST;
    std.mem.writeInt(u32, packet[1..5], ch.remote_id, .big);
    std.mem.writeInt(u32, packet[5..9], add, .big);
    try conn.writePacket(&.{&packet});
}

pub fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

test "pty dimensions have bounded axes, preserving normal and zero sizes" {
    for ([_]struct { width: u32, height: u32, expected: PtySize }{
        .{ .width = 80, .height = 24, .expected = .{ .width_cells = 80, .height_cells = 24 } },
        .{ .width = 0, .height = 0, .expected = .{ .width_cells = 0, .height_cells = 0 } },
        .{ .width = 0xffffffff, .height = 0xffffffff, .expected = .{ .width_cells = 512, .height_cells = 128 } },
    }) |case| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], case.width, .big);
        std.mem.writeInt(u32, bytes[4..8], case.height, .big);
        var reader = std.Io.Reader.fixed(&bytes);
        try std.testing.expectEqual(case.expected, try takePtySize(&reader));
    }
}

test "channel close before shell or exec is acknowledged" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const key = [_]u8{0x5a} ** 64;
    var encoded: [256]u8 = undefined;
    var encoded_writer = std.Io.Writer.fixed(&encoded);
    var sender = Cipher.init(&key, 0);
    var open: std.ArrayList(u8) = .empty;
    defer open.deinit(allocator);
    try open.append(allocator, SSH_MSG_CHANNEL_OPEN);
    try writeStringField(&open, allocator, "session");
    try writeU32(&open, allocator, 7);
    try writeU32(&open, allocator, 32768);
    try writeU32(&open, allocator, 32768);
    try sender.writePacket(io, &encoded_writer, &.{open.items});
    try sender.writePacket(io, &encoded_writer, &.{&.{ SSH_MSG_CHANNEL_CLOSE, 0, 0, 0, 0 }});
    var reader = std.Io.Reader.fixed(encoded_writer.buffered());
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var idle = IdleState{};
    var conn = Conn{
        .io = io,
        .allocator = allocator,
        .reader = &reader,
        .writer = &writer,
        .cs_cipher = Cipher.init(&key, 0),
        .sc_cipher = Cipher.init(&key, 0),
        .rekey = undefined,
        .idle = &idle,
    };
    const Handler = struct {
        pub fn handleSession(_: *@This(), _: *SessionCtx, _: Request) !void {
            return error.UnexpectedSession;
        }
    };
    var handler = Handler{};
    try runChannelLayer(&conn, &([_]u8{0} ** fingerprint_len), &handler);
    var output_reader = std.Io.Reader.fixed(writer.buffered());
    var receiver = Cipher.init(&key, 0);
    const confirmation = try receiver.readPacket(allocator, &output_reader);
    defer allocator.free(confirmation);
    try std.testing.expectEqual(SSH_MSG_CHANNEL_OPEN_CONFIRMATION, confirmation[0]);
    const close = try receiver.readPacket(allocator, &output_reader);
    defer allocator.free(close);
    try std.testing.expectEqualSlices(u8, &.{ SSH_MSG_CHANNEL_CLOSE, 0, 0, 0, 7 }, close);
    try std.testing.expectEqual(0, output_reader.buffered().len);
}

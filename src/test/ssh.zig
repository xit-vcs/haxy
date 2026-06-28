const std = @import("std");
const proto = @import("../serve_ssh_protocol.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

comptime {
    std.testing.refAllDecls(@import("../serve_ssh.zig"));
}

test "fingerprint format matches openssh layout" {
    const seed = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const keypair = try Ed25519.KeyPair.generateDeterministic(seed);

    // SSH wire-format pubkey blob: string "ssh-ed25519" || string raw_pubkey.
    const algo = "ssh-ed25519";
    var blob: [4 + algo.len + 4 + Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.mem.writeInt(u32, blob[0..4], algo.len, .big);
    @memcpy(blob[4 .. 4 + algo.len], algo);
    std.mem.writeInt(u32, blob[4 + algo.len ..][0..4], Ed25519.PublicKey.encoded_length, .big);
    @memcpy(blob[4 + algo.len + 4 ..], &keypair.public_key.bytes);

    const formatted = proto.formatFingerprint(&blob);

    try std.testing.expectEqual(50, formatted.len);
    try std.testing.expectEqualStrings("SHA256:", formatted[0..7]);

    // the body must decode to the SHA256 of the input blob.
    var decoded: [Sha256.digest_length]u8 = undefined;
    try std.base64.standard_no_pad.Decoder.decode(&decoded, formatted[7..]);
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&blob, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &decoded);
}

test "channel data parser rejects malformed payloads" {
    const allocator = std.testing.allocator;

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    try packet.append(allocator, proto.SSH_MSG_CHANNEL_DATA);
    try proto.writeU32(&packet, allocator, 0);
    try proto.writeU32(&packet, allocator, 3);
    try packet.appendSlice(allocator, "abc");

    try std.testing.expectEqualStrings("abc", try proto.parseChannelData(packet.items, false, 0));

    // wrong recipient channel
    packet.items[4] = 1;
    try std.testing.expectError(error.UnknownChannel, proto.parseChannelData(packet.items, false, 0));

    // declared length larger than the packet carries
    var too_long = std.ArrayList(u8).empty;
    defer too_long.deinit(allocator);
    try too_long.append(allocator, proto.SSH_MSG_CHANNEL_DATA);
    try proto.writeU32(&too_long, allocator, 0);
    try proto.writeU32(&too_long, allocator, 4);
    try too_long.appendSlice(allocator, "abc");
    try std.testing.expectError(error.InvalidChannelData, proto.parseChannelData(too_long.items, false, 0));

    // declared length smaller than the packet carries (trailing junk)
    var trailing = std.ArrayList(u8).empty;
    defer trailing.deinit(allocator);
    try trailing.append(allocator, proto.SSH_MSG_CHANNEL_DATA);
    try proto.writeU32(&trailing, allocator, 0);
    try proto.writeU32(&trailing, allocator, 3);
    try trailing.appendSlice(allocator, "abcd");
    try std.testing.expectError(error.InvalidChannelData, proto.parseChannelData(trailing.items, false, 0));
}

test "extended channel data parser accepts only stderr type" {
    const allocator = std.testing.allocator;

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    try packet.append(allocator, proto.SSH_MSG_CHANNEL_EXTENDED_DATA);
    try proto.writeU32(&packet, allocator, 0);
    try proto.writeU32(&packet, allocator, proto.SSH_EXTENDED_DATA_STDERR);
    try proto.writeU32(&packet, allocator, 3);
    try packet.appendSlice(allocator, "err");

    try std.testing.expectEqualStrings("err", try proto.parseChannelData(packet.items, true, 0));

    // any other data_type code is rejected
    packet.items[8] = 2;
    try std.testing.expectError(error.UnsupportedExtendedData, proto.parseChannelData(packet.items, true, 0));
}

test "SSH-2 negotiation: walk through every step (banner -> KEX -> auth -> channel -> exec)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const host_key = try newHostKey();
    const user_kp = try newUserKeypair();

    // c2s = bytes the client sends, server reads. s2c = the other direction.
    var c2s_buf: [4096]u8 = undefined;
    var c2s = Pipe.init(&c2s_buf);
    var s2c_buf: [4096]u8 = undefined;
    var s2c = Pipe.init(&s2c_buf);

    var server_rd_buf: [4096]u8 = undefined;
    var server_wr_buf: [4096]u8 = undefined;
    var client_rd_buf: [4096]u8 = undefined;
    var client_wr_buf: [4096]u8 = undefined;
    var server_pipe_reader = PipeReader.init(io, &c2s, &server_rd_buf);
    var server_pipe_writer = PipeWriter.init(io, &s2c, &server_wr_buf);
    var client_pipe_reader = PipeReader.init(io, &s2c, &client_rd_buf);
    var client_pipe_writer = PipeWriter.init(io, &c2s, &client_wr_buf);
    const cr = &client_pipe_reader.interface;
    const cw = &client_pipe_writer.interface;

    var server: ServerTask = .{
        .io = io,
        .allocator = allocator,
        .host_key = &host_key,
        .reader = &server_pipe_reader.interface,
        .writer = &server_pipe_writer.interface,
        .outgoing = &s2c,
    };
    var server_future = try std.Io.concurrent(io, ServerTask.run, .{&server});
    defer server_future.await(io);
    defer c2s.close(io); // unblocks the server even on early test failure

    // STEP 1: VERSION EXCHANGE (RFC 4253 §4.2)
    // Each side writes one "SSH-protoversion-softwareversion\r\n" line.
    // The exact strings get hashed into the exchange hash later, so they
    // bind the session's identity.
    try cw.writeAll(client_version ++ "\r\n");
    try cw.flush();
    const v_s_line = (try cr.takeDelimiter('\n')) orelse return error.UnexpectedEof;
    const v_s = if (v_s_line.len > 0 and v_s_line[v_s_line.len - 1] == '\r') v_s_line[0 .. v_s_line.len - 1] else v_s_line;
    try std.testing.expect(std.mem.startsWith(u8, v_s, "SSH-2.0-haxy_"));
    const v_c = client_version;

    // STEP 2: ALGORITHM NEGOTIATION (RFC 4253 §7.1)
    // Both sides send SSH_MSG_KEXINIT listing supported algorithms, in
    // preference order, for: key exchange, host-key signature, c->s and
    // s->c ciphers, c->s and s->c MACs (none with chacha20-poly1305 since
    // it's an AEAD), c->s and s->c compression, plus languages. The first
    // algorithm in each slot that the *client* prefers and the server also
    // offers is selected. Both raw KEXINITs are hashed into the exchange
    // hash so tampering is caught at signature verification time.
    const client_kex_init = try proto.buildKexInit(io, allocator, &.{"curve25519-sha256"}, &proto.our_host_key_algos, &proto.our_ciphers);
    defer allocator.free(client_kex_init);
    try proto.writePlainPacket(io, cw, client_kex_init);

    const server_kex_init = try proto.readPlainPacket(allocator, cr);
    defer allocator.free(server_kex_init);
    try std.testing.expectEqual(@as(u8, proto.SSH_MSG_KEXINIT), server_kex_init[0]);

    // STEP 3: ECDH KEY EXCHANGE (RFC 8731)
    // Client generates a fresh X25519 keypair, sends its public ephemeral
    // q_c in SSH_MSG_KEX_ECDH_INIT. Server:
    //   1. generates its own ephemeral
    //   2. computes K = X25519(server_priv, q_c) — shared secret
    //   3. computes H = SHA256(V_C || V_S || I_C || I_S || K_S || q_c || q_s || K)
    //      (each "||" element is length-prefixed; K is an mpint)
    //   4. signs H with its long-term host key
    //   5. replies KEX_ECDH_REPLY with K_S (host key blob), q_s, signature
    //
    // Client verifies the signature against K_S — MITM defense.
    const client_eph = try newClientEphemeral();
    {
        var pkt: std.ArrayList(u8) = .empty;
        defer pkt.deinit(allocator);
        try pkt.append(allocator, proto.SSH_MSG_KEX_ECDH_INIT);
        try proto.writeStringField(&pkt, allocator, &client_eph.public_key);
        try proto.writePlainPacket(io, cw, pkt.items);
    }
    const ecdh_reply = try proto.readPlainPacket(allocator, cr);
    defer allocator.free(ecdh_reply);
    try std.testing.expectEqual(@as(u8, proto.SSH_MSG_KEX_ECDH_REPLY), ecdh_reply[0]);

    var server_eph_pub: [X25519.public_length]u8 = undefined;
    var k_s: []u8 = undefined;
    var sig_blob: []u8 = undefined;
    {
        var r = std.Io.Reader.fixed(ecdh_reply[1..]);
        k_s = try proto.takeStringField(allocator, &r, 4096);
        errdefer allocator.free(k_s);
        const q_s = try proto.takeStringField(allocator, &r, X25519.public_length);
        defer allocator.free(q_s);
        try std.testing.expectEqual(X25519.public_length, q_s.len);
        @memcpy(&server_eph_pub, q_s);
        sig_blob = try proto.takeStringField(allocator, &r, 1024);
    }
    defer allocator.free(k_s);
    defer allocator.free(sig_blob);

    // K_S must be the host's ed25519 pubkey we configured.
    var expected_k_s: std.ArrayList(u8) = .empty;
    defer expected_k_s.deinit(allocator);
    try host_key.appendPublicBlob(&expected_k_s, allocator);
    try std.testing.expectEqualSlices(u8, expected_k_s.items, k_s);

    // K = X25519(client_priv, q_s) — same scalarmult on the other side.
    const k = try X25519.scalarmult(client_eph.secret_key, server_eph_pub);

    // Recompute H independently. If the server lied about any input the
    // signature won't verify against the trusted host key.
    const h = try proto.computeExchangeHash(allocator, v_c, v_s, client_kex_init, server_kex_init, k_s, &client_eph.public_key, &server_eph_pub, &k, false);

    // Verify the host signature on H.
    {
        var r = std.Io.Reader.fixed(sig_blob);
        const algo = try proto.takeStringField(allocator, &r, 64);
        defer allocator.free(algo);
        try std.testing.expectEqualStrings("ssh-ed25519", algo);
        const raw_sig = try proto.takeStringField(allocator, &r, Ed25519.Signature.encoded_length);
        defer allocator.free(raw_sig);
        var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
        @memcpy(&sig_bytes, raw_sig);
        const sig = Ed25519.Signature.fromBytes(sig_bytes);
        try sig.verify(&h, host_key.keypair.public_key);
    }

    // STEP 4: NEWKEYS — switch to encrypted mode (RFC 4253 §7.3)
    // Each side sends a one-byte SSH_MSG_NEWKEYS and starts encrypting
    // from the next packet on. chacha20-poly1305@openssh.com needs 64
    // bytes per direction (32 for the body cipher, 32 for the length
    // cipher); only the 'C' (c->s) and 'D' (s->c) RFC 4253 §7.2 outputs
    // are used since the AEAD covers MAC.
    try proto.writePlainPacket(io, cw, &[_]u8{proto.SSH_MSG_NEWKEYS});
    {
        const server_newkeys = try proto.readPlainPacket(allocator, cr);
        defer allocator.free(server_newkeys);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_NEWKEYS), server_newkeys[0]);
    }

    var keys: proto.SessionKeys = undefined;
    try proto.deriveSessionKeys(allocator, &k, &h, &h, &keys, false);
    // KEXINIT/KEX_ECDH_INIT/NEWKEYS were seqno 0/1/2; first encrypted is 3.
    var cs_cipher = proto.Cipher.init(&keys.cs_enc, 3);
    var sc_cipher = proto.Cipher.init(&keys.sc_enc, 3);

    // STEP 5: SERVICE REQUEST (RFC 4253 §10)
    // First encrypted message: client asks for the "ssh-userauth" service.
    // Server replies SERVICE_ACCEPT. ("ssh-connection" comes after auth.)
    {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_SERVICE_REQUEST);
        try proto.writeStringField(&req, allocator, "ssh-userauth");
        try cs_cipher.writePacket(io, allocator, cw, req.items);
    }
    {
        const accept = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(accept);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_SERVICE_ACCEPT), accept[0]);
    }

    // STEP 6: PUBLIC-KEY USERAUTH — PROBE (RFC 4252 §7)
    // Two-trip dance. Round 1: USERAUTH_REQUEST with method=publickey and
    // has_signature=false, carrying just the algo + public key blob. The
    // server says USERAUTH_PK_OK if it would accept that key (haxy
    // accepts any ed25519) or USERAUTH_FAILURE if not — so the client
    // doesn't waste a signature on a rejected key.
    var user_pubkey_blob: std.ArrayList(u8) = .empty;
    defer user_pubkey_blob.deinit(allocator);
    try proto.writeStringField(&user_pubkey_blob, allocator, "ssh-ed25519");
    try proto.writeStringField(&user_pubkey_blob, allocator, &user_kp.public_key.bytes);

    {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_USERAUTH_REQUEST);
        try proto.writeStringField(&req, allocator, "testuser");
        try proto.writeStringField(&req, allocator, "ssh-connection");
        try proto.writeStringField(&req, allocator, "publickey");
        try req.append(allocator, 0); // has_signature = false
        try proto.writeStringField(&req, allocator, "ssh-ed25519");
        try proto.writeStringField(&req, allocator, user_pubkey_blob.items);
        try cs_cipher.writePacket(io, allocator, cw, req.items);
    }
    {
        const pk_ok = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(pk_ok);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_USERAUTH_PK_OK), pk_ok[0]);
    }

    // STEP 7: PUBLIC-KEY USERAUTH — SIGNED REQUEST
    // Round 2: same USERAUTH_REQUEST, now with has_signature=true and an
    // ed25519 signature over the canonical signed-data block — see
    // proto.appendPublickeySignedData for the exact byte layout. The
    // block includes session_id (== H of the first KEX), so signatures
    // can't be replayed across sessions.
    var signed: std.ArrayList(u8) = .empty;
    defer signed.deinit(allocator);
    try proto.appendPublickeySignedData(&signed, allocator, &h, "testuser", "ssh-connection", "ssh-ed25519", user_pubkey_blob.items);
    const sig = try user_kp.sign(signed.items, null);
    const sig_bytes = sig.toBytes();

    var sig_wire: std.ArrayList(u8) = .empty;
    defer sig_wire.deinit(allocator);
    try proto.writeStringField(&sig_wire, allocator, "ssh-ed25519");
    try proto.writeStringField(&sig_wire, allocator, &sig_bytes);

    {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_USERAUTH_REQUEST);
        try proto.writeStringField(&req, allocator, "testuser");
        try proto.writeStringField(&req, allocator, "ssh-connection");
        try proto.writeStringField(&req, allocator, "publickey");
        try req.append(allocator, 1);
        try proto.writeStringField(&req, allocator, "ssh-ed25519");
        try proto.writeStringField(&req, allocator, user_pubkey_blob.items);
        try proto.writeStringField(&req, allocator, sig_wire.items);
        try cs_cipher.writePacket(io, allocator, cw, req.items);
    }
    {
        const success = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(success);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_USERAUTH_SUCCESS), success[0]);
    }

    // STEP 8: CHANNEL_OPEN (RFC 4254 §5.1)
    // Open a "session" channel — SSH's container for shell/exec/subsystem.
    // Client picks its own channel id and announces an initial receive
    // window + max-packet size; server replies CHANNEL_OPEN_CONFIRMATION
    // with its own channel id and c->s limits. Each side identifies the
    // channel by *the other's* id when sending.
    //
    // haxy supports exactly one channel per connection — a second
    // CHANNEL_OPEN here gets CHANNEL_OPEN_FAILURE (see the failure tests).
    const client_channel_id: u32 = 42;
    {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_CHANNEL_OPEN);
        try proto.writeStringField(&req, allocator, "session");
        try proto.writeU32(&req, allocator, client_channel_id);
        try proto.writeU32(&req, allocator, 1 << 20); // initial window
        try proto.writeU32(&req, allocator, 32768); // max packet
        try cs_cipher.writePacket(io, allocator, cw, req.items);
    }
    var server_channel_id: u32 = undefined;
    {
        const conf = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(conf);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_CHANNEL_OPEN_CONFIRMATION), conf[0]);
        var r = std.Io.Reader.fixed(conf[1..]);
        const recipient = try r.takeInt(u32, .big);
        try std.testing.expectEqual(client_channel_id, recipient);
        server_channel_id = try r.takeInt(u32, .big);
    }

    // STEP 9: CHANNEL_REQUEST exec (RFC 4254 §6.5)
    // Ask the server to run a command on this channel. Packet is
    // addressed to the *server's* channel id. With want_reply=true the
    // server must respond CHANNEL_SUCCESS or CHANNEL_FAILURE before any
    // CHANNEL_DATA flows.
    const exec_command = "git-upload-pack 'demo-repo'";
    {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_CHANNEL_REQUEST);
        try proto.writeU32(&req, allocator, server_channel_id);
        try proto.writeStringField(&req, allocator, "exec");
        try req.append(allocator, 1); // want_reply
        try proto.writeStringField(&req, allocator, exec_command);
        try cs_cipher.writePacket(io, allocator, cw, req.items);
    }
    {
        const success = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(success);
        try std.testing.expectEqual(@as(u8, proto.SSH_MSG_CHANNEL_SUCCESS), success[0]);
    }

    // STEP 10: HANDLER RUNS, CHANNEL TEARDOWN
    // The server is now in handleSession. Our recording handler returns
    // immediately; runChannelLayer's wrap-up then sends:
    //   - CHANNEL_REQUEST "exit-status" (status=0, want_reply=false)
    //   - CHANNEL_EOF
    //   - CHANNEL_CLOSE
    // …and waits for our CHANNEL_CLOSE in reply (so the underlying socket
    // isn't closed-with-unread-data, which would surface as TCP RST).
    var saw_exit_status = false;
    var saw_server_close = false;
    while (!saw_server_close) {
        const pkt = try sc_cipher.readPacket(allocator, cr);
        defer allocator.free(pkt);
        switch (pkt[0]) {
            proto.SSH_MSG_CHANNEL_REQUEST => {
                var r = std.Io.Reader.fixed(pkt[1..]);
                _ = try r.takeInt(u32, .big);
                const req_type = try proto.takeStringField(allocator, &r, 64);
                defer allocator.free(req_type);
                if (std.mem.eql(u8, req_type, "exit-status")) {
                    _ = try r.takeByte();
                    const status = try r.takeInt(u32, .big);
                    try std.testing.expectEqual(@as(u32, 0), status);
                    saw_exit_status = true;
                }
            },
            proto.SSH_MSG_CHANNEL_EOF => {},
            proto.SSH_MSG_CHANNEL_CLOSE => saw_server_close = true,
            proto.SSH_MSG_CHANNEL_WINDOW_ADJUST => {},
            else => {},
        }
    }
    try std.testing.expect(saw_exit_status);

    {
        var pkt: std.ArrayList(u8) = .empty;
        defer pkt.deinit(allocator);
        try pkt.append(allocator, proto.SSH_MSG_CHANNEL_CLOSE);
        try proto.writeU32(&pkt, allocator, server_channel_id);
        try cs_cipher.writePacket(io, allocator, cw, pkt.items);
    }

    // simulate the client's TCP FIN so the server's teardown drain reads EOF
    // and returns instead of blocking on a packet that never arrives.
    c2s.close(io);

    server_future.await(io);
    try std.testing.expect(server.result == null);

    // FINAL ASSERTIONS
    // the exec command we sent on the wire should have reached the handler
    // verbatim, and the server should have recorded our pubkey's SHA256
    // fingerprint as the authenticated identity for this session.
    try std.testing.expectEqualStrings(exec_command, server.captured_exec_buf[0..server.captured_exec_len]);
    const expected_fp = proto.formatFingerprint(user_pubkey_blob.items);
    try std.testing.expectEqualSlices(u8, &expected_fp, &server.captured_fp);
}

// failure modes against a single live session, in increasing severity:
//   - publickey signed-data binding (session_id and user_name) — server
//     replies USERAUTH_FAILURE, connection continues
//   - second CHANNEL_OPEN on the same connection — server replies
//     CHANNEL_OPEN_FAILURE, connection continues
//   - MAC-tampered encrypted packet — server bails out of handleConnection
//     with MacVerificationFailed (terminal)
// running all of these against one negotiated session avoids paying the
// KEX cost per failure case and keeps the failure tests visually together.
test "auth + channel layer failure modes" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const host_key = try newHostKey();

    var c2s_buf: [4096]u8 = undefined;
    var c2s = Pipe.init(&c2s_buf);
    var s2c_buf: [4096]u8 = undefined;
    var s2c = Pipe.init(&s2c_buf);

    var server_rd_buf: [4096]u8 = undefined;
    var server_wr_buf: [4096]u8 = undefined;
    var client_rd_buf: [4096]u8 = undefined;
    var client_wr_buf: [4096]u8 = undefined;
    var server_pipe_reader = PipeReader.init(io, &c2s, &server_rd_buf);
    var server_pipe_writer = PipeWriter.init(io, &s2c, &server_wr_buf);
    var client_pipe_reader = PipeReader.init(io, &s2c, &client_rd_buf);
    var client_pipe_writer = PipeWriter.init(io, &c2s, &client_wr_buf);
    const cr = &client_pipe_reader.interface;
    const cw = &client_pipe_writer.interface;

    var server: ServerTask = .{
        .io = io,
        .allocator = allocator,
        .host_key = &host_key,
        .reader = &server_pipe_reader.interface,
        .writer = &server_pipe_writer.interface,
        .outgoing = &s2c,
    };
    var server_future = try std.Io.concurrent(io, ServerTask.run, .{&server});
    defer server_future.await(io);
    defer c2s.close(io);

    // bring the connection up to a post-NEWKEYS, ready-to-encrypt state:
    // banner exchange, KEXINIT exchange, ECDH, NEWKEYS, key derivation.
    var cs: proto.Cipher = undefined;
    var sc: proto.Cipher = undefined;
    var session_id: [Sha256.digest_length]u8 = undefined;
    {
        try cw.writeAll(client_version ++ "\r\n");
        try cw.flush();
        const v_s_line = (try cr.takeDelimiter('\n')) orelse return error.UnexpectedEof;
        const v_s_trimmed = if (v_s_line.len > 0 and v_s_line[v_s_line.len - 1] == '\r') v_s_line[0 .. v_s_line.len - 1] else v_s_line;
        const v_s = try allocator.dupe(u8, v_s_trimmed);
        defer allocator.free(v_s);

        const ckex = try proto.buildKexInit(io, allocator, &.{"curve25519-sha256"}, &proto.our_host_key_algos, &proto.our_ciphers);
        defer allocator.free(ckex);
        try proto.writePlainPacket(io, cw, ckex);
        const skex = try proto.readPlainPacket(allocator, cr);
        defer allocator.free(skex);

        const eph = try newClientEphemeral();
        {
            var pkt: std.ArrayList(u8) = .empty;
            defer pkt.deinit(allocator);
            try pkt.append(allocator, proto.SSH_MSG_KEX_ECDH_INIT);
            try proto.writeStringField(&pkt, allocator, &eph.public_key);
            try proto.writePlainPacket(io, cw, pkt.items);
        }
        const reply = try proto.readPlainPacket(allocator, cr);
        defer allocator.free(reply);
        var rr = std.Io.Reader.fixed(reply[1..]);
        const k_s = try proto.takeStringField(allocator, &rr, 4096);
        defer allocator.free(k_s);
        const q_s = try proto.takeStringField(allocator, &rr, X25519.public_length);
        defer allocator.free(q_s);
        var server_pub: [X25519.public_length]u8 = undefined;
        @memcpy(&server_pub, q_s);
        const sig_blob = try proto.takeStringField(allocator, &rr, 1024);
        defer allocator.free(sig_blob);
        const k = try X25519.scalarmult(eph.secret_key, server_pub);
        const exchange = try proto.computeExchangeHash(allocator, client_version, v_s, ckex, skex, k_s, &eph.public_key, &server_pub, &k, false);

        try proto.writePlainPacket(io, cw, &[_]u8{proto.SSH_MSG_NEWKEYS});
        {
            const server_newkeys = try proto.readPlainPacket(allocator, cr);
            defer allocator.free(server_newkeys);
            try std.testing.expectEqual(@as(u8, proto.SSH_MSG_NEWKEYS), server_newkeys[0]);
        }

        var keys: proto.SessionKeys = undefined;
        try proto.deriveSessionKeys(allocator, &k, &exchange, &exchange, &keys, false);
        cs = proto.Cipher.init(&keys.cs_enc, 3);
        sc = proto.Cipher.init(&keys.sc_enc, 3);
        session_id = exchange;
    }

    // SERVICE_REQUEST → SERVICE_ACCEPT, then USERAUTH_REQUEST publickey
    // probe → PK_OK, then three signed USERAUTH_REQUEST attempts that
    // exercise the cryptographic-binding properties of publickey auth:
    //   1. signed with a different session_id → USERAUTH_FAILURE
    //      (replay-across-sessions defense — H is bound into the signature)
    //   2. signed with one user_name but the request carries another →
    //      USERAUTH_FAILURE (user_name is bound into the signature)
    //   3. legit (correct session_id and user_name) → USERAUTH_SUCCESS
    // each USERAUTH_FAILURE is non-terminal: the server's auth loop just
    // increments attempts and waits for the next request.
    const user_kp = try newUserKeypair();
    {
        {
            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(allocator);
            try req.append(allocator, proto.SSH_MSG_SERVICE_REQUEST);
            try proto.writeStringField(&req, allocator, "ssh-userauth");
            try cs.writePacket(io, allocator, cw, req.items);
        }
        {
            const accept = try sc.readPacket(allocator, cr);
            defer allocator.free(accept);
            try std.testing.expectEqual(@as(u8, proto.SSH_MSG_SERVICE_ACCEPT), accept[0]);
            var r = std.Io.Reader.fixed(accept[1..]);
            const service = try proto.takeStringField(allocator, &r, 64);
            defer allocator.free(service);
            try std.testing.expectEqualStrings("ssh-userauth", service);
        }

        var pubkey_blob: std.ArrayList(u8) = .empty;
        defer pubkey_blob.deinit(allocator);
        try proto.writeStringField(&pubkey_blob, allocator, "ssh-ed25519");
        try proto.writeStringField(&pubkey_blob, allocator, &user_kp.public_key.bytes);

        {
            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(allocator);
            try req.append(allocator, proto.SSH_MSG_USERAUTH_REQUEST);
            try proto.writeStringField(&req, allocator, "testuser");
            try proto.writeStringField(&req, allocator, "ssh-connection");
            try proto.writeStringField(&req, allocator, "publickey");
            try req.append(allocator, 0);
            try proto.writeStringField(&req, allocator, "ssh-ed25519");
            try proto.writeStringField(&req, allocator, pubkey_blob.items);
            try cs.writePacket(io, allocator, cw, req.items);
        }
        {
            const pk_ok = try sc.readPacket(allocator, cr);
            defer allocator.free(pk_ok);
            try std.testing.expectEqual(@as(u8, proto.SSH_MSG_USERAUTH_PK_OK), pk_ok[0]);
            var r = std.Io.Reader.fixed(pk_ok[1..]);
            const algo = try proto.takeStringField(allocator, &r, 64);
            defer allocator.free(algo);
            try std.testing.expectEqualStrings("ssh-ed25519", algo);
            const accepted_blob = try proto.takeStringField(allocator, &r, 4096);
            defer allocator.free(accepted_blob);
            try std.testing.expectEqualSlices(u8, pubkey_blob.items, accepted_blob);
        }

        const wrong_session = [_]u8{0xFF} ** Sha256.digest_length;
        for ([_]struct {
            sign_session: []const u8,
            sign_user: []const u8,
            send_user: []const u8,
            expect: u8,
        }{
            .{ .sign_session = &wrong_session, .sign_user = "testuser", .send_user = "testuser", .expect = proto.SSH_MSG_USERAUTH_FAILURE },
            .{ .sign_session = &session_id, .sign_user = "alice", .send_user = "bob", .expect = proto.SSH_MSG_USERAUTH_FAILURE },
            .{ .sign_session = &session_id, .sign_user = "testuser", .send_user = "testuser", .expect = proto.SSH_MSG_USERAUTH_SUCCESS },
        }) |attempt| {
            var signed: std.ArrayList(u8) = .empty;
            defer signed.deinit(allocator);
            try proto.appendPublickeySignedData(&signed, allocator, attempt.sign_session, attempt.sign_user, "ssh-connection", "ssh-ed25519", pubkey_blob.items);
            const sig = try user_kp.sign(signed.items, null);
            const sig_bytes = sig.toBytes();
            var sig_wire: std.ArrayList(u8) = .empty;
            defer sig_wire.deinit(allocator);
            try proto.writeStringField(&sig_wire, allocator, "ssh-ed25519");
            try proto.writeStringField(&sig_wire, allocator, &sig_bytes);

            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(allocator);
            try req.append(allocator, proto.SSH_MSG_USERAUTH_REQUEST);
            try proto.writeStringField(&req, allocator, attempt.send_user);
            try proto.writeStringField(&req, allocator, "ssh-connection");
            try proto.writeStringField(&req, allocator, "publickey");
            try req.append(allocator, 1);
            try proto.writeStringField(&req, allocator, "ssh-ed25519");
            try proto.writeStringField(&req, allocator, pubkey_blob.items);
            try proto.writeStringField(&req, allocator, sig_wire.items);
            try cs.writePacket(io, allocator, cw, req.items);

            const reply = try sc.readPacket(allocator, cr);
            defer allocator.free(reply);
            try std.testing.expectEqual(attempt.expect, reply[0]);
        }
    }

    // open two channels back to back: server confirms the first, then
    // refuses the second with OPEN_FAILURE and stays running.
    for ([_]struct { id: u32, expect: u8 }{
        .{ .id = 7, .expect = proto.SSH_MSG_CHANNEL_OPEN_CONFIRMATION },
        .{ .id = 8, .expect = proto.SSH_MSG_CHANNEL_OPEN_FAILURE },
    }) |case| {
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.append(allocator, proto.SSH_MSG_CHANNEL_OPEN);
        try proto.writeStringField(&req, allocator, "session");
        try proto.writeU32(&req, allocator, case.id);
        try proto.writeU32(&req, allocator, 1 << 20);
        try proto.writeU32(&req, allocator, 32768);
        try cs.writePacket(io, allocator, cw, req.items);

        const reply = try sc.readPacket(allocator, cr);
        defer allocator.free(reply);
        try std.testing.expectEqual(case.expect, reply[0]);
    }

    // now break the connection: build any encrypted packet, flip one bit of
    // its trailing Poly1305 tag, and ship the corrupted bytes. server must
    // surface MacVerificationFailed out of handleConnection.
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);
    try req.append(allocator, proto.SSH_MSG_CHANNEL_REQUEST);
    try proto.writeU32(&req, allocator, 0);
    try proto.writeStringField(&req, allocator, "shell");
    try req.append(allocator, 0);

    var tmp_buf: [512]u8 = undefined;
    var sink = std.Io.Writer.fixed(&tmp_buf);
    try cs.writePacket(io, allocator, &sink, req.items);
    const written = sink.buffered();
    tmp_buf[written.len - 1] ^= 0x01;
    try cw.writeAll(tmp_buf[0..written.len]);
    try cw.flush();

    server_future.await(io);
    try std.testing.expectEqual(@as(?anyerror, error.MacVerificationFailed), server.result);
}

const client_version = "SSH-2.0-haxy_test";

// in-memory bidirectional pipe — drives the server side of handleConnection
// without a socket. one Pipe carries bytes in one direction.

const Pipe = std.Io.Queue(u8);

const PipeReader = struct {
    interface: std.Io.Reader,
    io: std.Io,
    pipe: *Pipe,

    fn init(io: std.Io, pipe: *Pipe, buf: []u8) PipeReader {
        return .{
            .interface = .{
                .vtable = &.{ .readVec = readVec, .stream = stream },
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
            .io = io,
            .pipe = pipe,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        // tests don't drive any code path that calls stream, but the vtable
        // requires a non-default impl. read into a small staging buffer and
        // forward, so the implementation is correct if it ever fires.
        const self: *PipeReader = @fieldParentPtr("interface", r);
        var stage: [256]u8 = undefined;
        const cap = limit.minInt(stage.len);
        if (cap == 0) return 0;
        const n = self.pipe.get(self.io, stage[0..cap], 1) catch |err| switch (err) {
            error.Closed => return error.EndOfStream,
            error.Canceled => return error.ReadFailed,
        };
        return try w.write(stage[0..n]);
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *PipeReader = @fieldParentPtr("interface", r);
        // vtable contract: if data[0] is empty, fill r.buffer[r.end..] instead.
        const dest = if (data.len == 0 or data[0].len == 0) r.buffer[r.end..] else data[0];
        if (dest.len == 0) return 0;
        const n = self.pipe.get(self.io, dest, 1) catch |err| switch (err) {
            error.Closed => return error.EndOfStream,
            error.Canceled => return error.ReadFailed,
        };
        if (data.len == 0 or data[0].len == 0) {
            r.end += n;
            return 0;
        }
        return n;
    }
};

const PipeWriter = struct {
    interface: std.Io.Writer,
    io: std.Io,
    pipe: *Pipe,

    fn init(io: std.Io, pipe: *Pipe, buf: []u8) PipeWriter {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buf,
            },
            .io = io,
            .pipe = pipe,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *PipeWriter = @fieldParentPtr("interface", w);
        const buffered = w.buffered();
        if (buffered.len > 0) self.pipe.putAll(self.io, buffered) catch return error.WriteFailed;

        var extra: usize = 0;
        if (data.len > 1) {
            for (data[0 .. data.len - 1]) |chunk| {
                if (chunk.len == 0) continue;
                self.pipe.putAll(self.io, chunk) catch return error.WriteFailed;
                extra += chunk.len;
            }
        }
        if (data.len > 0) {
            const pattern = data[data.len - 1];
            if (pattern.len > 0) {
                var i: usize = 0;
                while (i < splat) : (i += 1) {
                    self.pipe.putAll(self.io, pattern) catch return error.WriteFailed;
                    extra += pattern.len;
                }
            }
        }
        return w.consume(buffered.len + extra);
    }
};

// runs proto.handleConnection in a concurrent task (spawned via std.Io.concurrent).
// also acts as the session handler — captures the authenticated key's
// fingerprint and returns immediately, leaving runChannelLayer's wrap-up to
// send exit-status / EOF / CLOSE. records any error so the test can assert
// on it after awaiting the future.
const ServerTask = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    host_key: *const proto.HostKey,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    outgoing: *Pipe, // closed on exit so the client's reads return EOF
    captured_fp: [proto.fingerprint_len]u8 = undefined,
    captured_exec_buf: [256]u8 = undefined,
    captured_exec_len: usize = 0,
    result: ?anyerror = null,

    pub fn handleSession(self: *ServerTask, sess: *proto.SessionCtx, request: proto.Request) !void {
        @memcpy(&self.captured_fp, &sess.fingerprint);
        switch (request) {
            .exec => |cmd| {
                // copy out of the protocol's stack-scoped buffer so the
                // test can assert on it after the handler returns.
                @memcpy(self.captured_exec_buf[0..cmd.len], cmd);
                self.captured_exec_len = cmd.len;
            },
            .shell => {},
        }
    }

    fn run(self: *ServerTask) void {
        defer self.outgoing.close(self.io);
        proto.handleConnection(
            self.io,
            self.allocator,
            self.reader,
            self.writer,
            self.host_key,
            self,
        ) catch |e| {
            self.result = e;
        };
    }
};

// deterministic keys so failures don't depend on RNG state.

fn newHostKey() !proto.HostKey {
    const seed = [_]u8{0xAA} ** Ed25519.KeyPair.seed_length;
    return .{ .keypair = try Ed25519.KeyPair.generateDeterministic(seed) };
}

fn newUserKeypair() !Ed25519.KeyPair {
    const seed = [_]u8{0xBB} ** Ed25519.KeyPair.seed_length;
    return try Ed25519.KeyPair.generateDeterministic(seed);
}

fn newClientEphemeral() !X25519.KeyPair {
    const seed = [_]u8{0xCC} ** X25519.seed_length;
    return try X25519.KeyPair.generateDeterministic(seed);
}

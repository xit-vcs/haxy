const std = @import("std");
const builtin = @import("builtin");
const hx = @import("haxy");
const ssh = hx.serve_ssh;
const proto = hx.serve_ssh_protocol;

test "fingerprint format matches openssh layout" {
    // a deterministic ed25519 public key — using a fixed seed so the test
    // output stays stable across runs.
    const Ed25519 = std.crypto.sign.Ed25519;
    const seed = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const keypair = try Ed25519.KeyPair.generateDeterministic(seed);

    // SSH wire-format pubkey blob: string "ssh-ed25519" || string raw_pubkey.
    // mirrors what HostKey.appendPublicBlob writes and what
    // verifyUserauthSignature receives from the client.
    const algo = "ssh-ed25519";
    var blob: [4 + algo.len + 4 + Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.mem.writeInt(u32, blob[0..4], algo.len, .big);
    @memcpy(blob[4 .. 4 + algo.len], algo);
    std.mem.writeInt(u32, blob[4 + algo.len ..][0..4], Ed25519.PublicKey.encoded_length, .big);
    @memcpy(blob[4 + algo.len + 4 ..], &keypair.public_key.bytes);

    const formatted = proto.formatFingerprint(&blob);

    // exact shape openssh prints in `Offering public key: … SHA256:…`
    try std.testing.expectEqual(50, formatted.len);
    try std.testing.expectEqualStrings("SHA256:", formatted[0..7]);

    // the body is 43 base64-no-padding chars (= ceil(32 * 4 / 3)). decoding
    // it back must yield exactly the SHA256 of the input blob — this is
    // the actual security/identity property other code relies on.
    var decoded: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    try std.base64.standard_no_pad.Decoder.decode(&decoded, formatted[7..]);
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&blob, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &decoded);
}

test "isSubPath rejects prefix collisions and traversal" {
    const sep = std.fs.path.sep_str;
    const parent = sep ++ "srv" ++ sep ++ "git";

    // simple containment
    try std.testing.expect(ssh.isSubPath(parent, parent ++ sep ++ "repo"));
    try std.testing.expect(ssh.isSubPath(parent, parent));

    // common-prefix-but-not-subpath: "/srv/git" should NOT swallow
    // "/srv/git2" or "/srv/gitignore" just because the bytes start the same.
    try std.testing.expect(!ssh.isSubPath(parent, parent ++ "2"));
    try std.testing.expect(!ssh.isSubPath(parent, parent ++ "ignore"));

    // the resolveRepoPath caller passes a `..`-normalized child, so the
    // resolved path of e.g. `/srv/git/../etc/passwd` is just `/etc/passwd`
    // — isSubPath then correctly rejects it.
    try std.testing.expect(!ssh.isSubPath(parent, sep ++ "etc" ++ sep ++ "passwd"));

    // root-as-parent (only meaningful on POSIX)
    if (.windows != builtin.os.tag) {
        try std.testing.expect(ssh.isSubPath(sep, sep ++ "anything"));
        try std.testing.expect(ssh.isSubPath(sep, sep));
    }
}

test "parseGitCommand happy paths" {
    const allocator = std.testing.allocator;

    {
        const parsed = try ssh.parseGitCommand(allocator, "git-upload-pack 'some-repo'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(ssh.GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("some-repo", parsed.dir);
    }

    {
        const parsed = try ssh.parseGitCommand(allocator, "git-receive-pack 'user/proj'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(ssh.GitService.receive_pack, parsed.service);
        try std.testing.expectEqualStrings("user/proj", parsed.dir);
    }

    // bare (no quotes) form: git accepts it, so we should too
    {
        const parsed = try ssh.parseGitCommand(allocator, "git-upload-pack repo");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(ssh.GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("repo", parsed.dir);
    }
}

test "parseGitCommand rejects malformed input" {
    const allocator = std.testing.allocator;

    // missing dir argument
    try std.testing.expectError(error.InvalidCommand, ssh.parseGitCommand(allocator, "git-upload-pack"));

    // unknown service — only git-upload-pack and git-receive-pack are dispatched
    try std.testing.expectError(error.UnsupportedService, ssh.parseGitCommand(allocator, "ls -la"));
    try std.testing.expectError(error.UnsupportedService, ssh.parseGitCommand(allocator, "git-fake-pack 'repo'"));
}

test "channel data parser rejects malformed payloads" {
    const allocator = std.testing.allocator;
    const SSH_MSG_CHANNEL_DATA: u8 = 94;

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    try packet.append(allocator, SSH_MSG_CHANNEL_DATA);
    try appendU32(allocator, &packet, 0);
    try appendU32(allocator, &packet, 3);
    try packet.appendSlice(allocator, "abc");

    // valid form first — confirms the wire layout we're constructing
    try std.testing.expectEqualStrings("abc", try proto.parseChannelData(packet.items, false, 0));

    // wrong recipient channel — flip the last byte of the channel-id field
    // in place; we're done with the success case above.
    packet.items[4] = 1;
    try std.testing.expectError(error.UnknownChannel, proto.parseChannelData(packet.items, false, 0));

    // declared length larger than the packet actually carries
    var too_long = std.ArrayList(u8).empty;
    defer too_long.deinit(allocator);
    try too_long.append(allocator, SSH_MSG_CHANNEL_DATA);
    try appendU32(allocator, &too_long, 0);
    try appendU32(allocator, &too_long, 4);
    try too_long.appendSlice(allocator, "abc");
    try std.testing.expectError(error.InvalidChannelData, proto.parseChannelData(too_long.items, false, 0));

    // declared length smaller than the packet carries (trailing junk)
    var trailing = std.ArrayList(u8).empty;
    defer trailing.deinit(allocator);
    try trailing.append(allocator, SSH_MSG_CHANNEL_DATA);
    try appendU32(allocator, &trailing, 0);
    try appendU32(allocator, &trailing, 3);
    try trailing.appendSlice(allocator, "abcd");
    try std.testing.expectError(error.InvalidChannelData, proto.parseChannelData(trailing.items, false, 0));
}

test "extended channel data parser accepts only stderr type" {
    const allocator = std.testing.allocator;
    const SSH_MSG_CHANNEL_EXTENDED_DATA: u8 = 95;
    const SSH_EXTENDED_DATA_STDERR: u32 = 1;

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    try packet.append(allocator, SSH_MSG_CHANNEL_EXTENDED_DATA);
    try appendU32(allocator, &packet, 0);
    try appendU32(allocator, &packet, SSH_EXTENDED_DATA_STDERR);
    try appendU32(allocator, &packet, 3);
    try packet.appendSlice(allocator, "err");

    // stderr (data_type == 1) is accepted
    try std.testing.expectEqualStrings("err", try proto.parseChannelData(packet.items, true, 0));

    // any other data_type code is rejected — flip the last byte of the
    // data_type field in place.
    packet.items[8] = 2;
    try std.testing.expectError(error.UnsupportedExtendedData, proto.parseChannelData(packet.items, true, 0));
}

fn appendU32(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

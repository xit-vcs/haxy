const std = @import("std");
const hx = @import("haxy");
const ssh_tui = hx.ssh_tui;

test "prelude round-trip" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try ssh_tui.writePrelude(&out.writer, .{
        .user_key = "SHA256:abcdef",
        .term = "xterm-256color",
        .width = 120,
        .height = 40,
    });

    var in = std.Io.Reader.fixed(out.written());
    const prelude = try ssh_tui.readPrelude(allocator, &in);
    defer prelude.deinit(allocator);

    try std.testing.expectEqualStrings("SHA256:abcdef", prelude.user_key);
    try std.testing.expectEqualStrings("xterm-256color", prelude.term);
    try std.testing.expectEqual(@as(u16, 120), prelude.width);
    try std.testing.expectEqual(@as(u16, 40), prelude.height);
}

test "prelude rejects bad magic" {
    const allocator = std.testing.allocator;
    var in = std.Io.Reader.fixed("not-the-magic\nuser-key=x\nterm=x\nwidth=80\nheight=24\n\n");
    try std.testing.expectError(error.InvalidMagic, ssh_tui.readPrelude(allocator, &in));
}

test "prelude rejects missing field" {
    const allocator = std.testing.allocator;
    var in = std.Io.Reader.fixed("haxy-tui-v1\nuser-key=x\nwidth=80\nheight=24\n\n");
    try std.testing.expectError(error.InvalidPrelude, ssh_tui.readPrelude(allocator, &in));
}

test "prelude rejects unparseable width" {
    const allocator = std.testing.allocator;
    var in = std.Io.Reader.fixed("haxy-tui-v1\nuser-key=x\nterm=x\nwidth=wide\nheight=24\n\n");
    try std.testing.expectError(error.InvalidPrelude, ssh_tui.readPrelude(allocator, &in));
}

test "prelude rejects oversized user-key" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("haxy-tui-v1\nuser-key=");
    try buf.writer.splatByteAll('x', ssh_tui.max_user_key_len + 1);
    try buf.writer.writeAll("\nterm=x\nwidth=80\nheight=24\n\n");

    var in = std.Io.Reader.fixed(buf.written());
    try std.testing.expectError(error.InvalidPrelude, ssh_tui.readPrelude(allocator, &in));
}

test "data frame round-trip" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ssh_tui.writeDataFrame(&out.writer, "hello");

    var in = std.Io.Reader.fixed(out.written());
    const frame = try ssh_tui.readFrame(allocator, &in);
    defer frame.deinit(allocator);

    try std.testing.expectEqualStrings("hello", frame.data);
}

test "resize frame round-trip" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ssh_tui.writeResizeFrame(&out.writer, 132, 50);

    var in = std.Io.Reader.fixed(out.written());
    const frame = try ssh_tui.readFrame(allocator, &in);
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 132), frame.resize.width);
    try std.testing.expectEqual(@as(u16, 50), frame.resize.height);
}

test "close frame round-trip" {
    const allocator = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ssh_tui.writeCloseFrame(&out.writer);

    var in = std.Io.Reader.fixed(out.written());
    const frame = try ssh_tui.readFrame(allocator, &in);
    defer frame.deinit(allocator);

    try std.testing.expect(frame == .close);
}

test "frame rejects unknown type" {
    const allocator = std.testing.allocator;
    // type 0xFF (unknown), length 0
    var in = std.Io.Reader.fixed(&[_]u8{ 0xFF, 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidFrameType, ssh_tui.readFrame(allocator, &in));
}

test "frame rejects oversized data payload" {
    const allocator = std.testing.allocator;
    // type 0x01 (data), length max+1
    var header: [5]u8 = undefined;
    header[0] = 0x01;
    std.mem.writeInt(u32, header[1..5], @intCast(ssh_tui.max_data_frame_len + 1), .big);

    var in = std.Io.Reader.fixed(&header);
    try std.testing.expectError(error.FrameTooLarge, ssh_tui.readFrame(allocator, &in));
}

test "frame rejects resize with wrong length" {
    const allocator = std.testing.allocator;
    // type 0x02 (resize), length 3 (should be 4)
    var in = std.Io.Reader.fixed(&[_]u8{ 0x02, 0, 0, 0, 3, 0, 0, 0 });
    try std.testing.expectError(error.InvalidResizeFrame, ssh_tui.readFrame(allocator, &in));
}

test "frame rejects close with non-zero length" {
    const allocator = std.testing.allocator;
    // type 0x03 (close), length 1 (should be 0)
    var in = std.Io.Reader.fixed(&[_]u8{ 0x03, 0, 0, 0, 1, 0 });
    try std.testing.expectError(error.InvalidCloseFrame, ssh_tui.readFrame(allocator, &in));
}

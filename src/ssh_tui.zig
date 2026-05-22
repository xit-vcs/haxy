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

const std = @import("std");

pub const ConnectAddress = struct {
    host: []const u8,
    port: u16,
};

pub fn parseConnectAddress(value: []const u8) !ConnectAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidConnectAddress;
    if (colon == 0 or colon + 1 >= value.len) return error.InvalidConnectAddress;
    const port = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
    return .{ .host = value[0..colon], .port = port };
}

pub fn copyFd(src: std.posix.fd_t, dst: std.posix.fd_t) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const len = try std.posix.read(src, &buffer);
        if (len == 0) break;
        try writeAllFd(dst, buffer[0..len]);
    }
}

pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => written += @intCast(rc),
            .INTR => continue,
            .PIPE => return error.BrokenPipe,
            else => return error.WriteFailed,
        }
    }
}

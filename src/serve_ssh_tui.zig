//! server-side handler for a single ssh-tui session

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;
const Grid = xitui.grid.Grid;
const Size = xitui.layout.Size;
const ui = @import("./ui.zig");
const ssh_tui = @import("./ssh_tui.zig");

pub fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    admin_repo_path: []const u8,
) !void {
    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    // read the prelude. if it fails we owe the client a plain-text reason
    // before we drop the connection — the helper is going to dump whatever
    // we send to the user's terminal, and a silent close looks like a bug.
    const prelude = ssh_tui.readPrelude(allocator, reader) catch |err| {
        writer.print("haxy ssh-tui: invalid prelude: {s}\n", .{@errorName(err)}) catch {};
        writer.flush() catch {};
        return err;
    };
    defer prelude.deinit(allocator);

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    const repo_opts: rp.RepoOpts(.xit) = .{};
    const Repo = rp.Repo(.xit, repo_opts);
    var repo_or_err = Repo.open(io, allocator, .{ .path = admin_repo_path });
    const page: ui.Page = if (repo_or_err) |*repo| blk: {
        defer repo.deinit(io, allocator);
        break :blk .{ .users_and_repos = try .init(repo_opts, &page_arena, repo) };
    } else |_| .{ .users_and_repos = .empty() };

    var root = try ui.initRoot(allocator, &page);
    defer root.deinit();

    var terminal = try StreamTerminal.init(allocator, writer, .{
        .width = prelude.width,
        .height = prelude.height,
    });
    defer terminal.deinit();

    // initial render so the user sees something before they type
    var last_size = Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();
    _ = try terminal.render(&root, &last_grid, &last_size);
    try root.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = last_size.width, .height = last_size.height },
    }, root.getFocus());

    // frame-decode loop. each iteration reads one frame, dispatches it, and
    // re-renders. blocking happens naturally in readFrame waiting on the
    // socket.
    while (!terminal.shouldQuit()) {
        const frame = ssh_tui.readFrame(allocator, reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);

        switch (frame) {
            .data => |payload| {
                try terminal.writeBytes(payload);
                while (terminal.popKey()) |key| {
                    try ui.inputKey(&root, key, &terminal);
                }
            },
            .resize => |sz| {
                terminal.pushResize(.{ .width = sz.width, .height = sz.height });
                while (terminal.popKey()) |key| {
                    try ui.inputKey(&root, key, &terminal);
                }
            },
            .close => terminal.requestQuit(),
        }

        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());
        _ = try terminal.render(&root, &last_grid, &last_size);
    }
}

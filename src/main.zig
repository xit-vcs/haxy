const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const cmd = @import("./command.zig");
const srv = @import("./serve.zig");
const ui = @import("./ui.zig");

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = xit.xitui.terminal.crash_debug_io;

pub const RunOpts = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        try args.append(allocator, arg);
    }

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const run_opts = RunOpts{ .out = &stdout_writer.interface, .err = &stderr_writer.interface };

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    run(.xit, .{}, io, allocator, args.items, cwd_path, run_opts) catch |err| switch (err) {
        error.HandledError => return 1,
        else => |e| return e,
    };

    return 0;
}

pub fn run(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd_path: []const u8,
    run_opts: RunOpts,
) !void {
    var cmd_args = try cmd.CommandArgs.init(allocator, args);
    defer cmd_args.deinit();

    switch (try cmd.CommandDispatch.init(&cmd_args)) {
        .invalid => |invalid| switch (invalid) {
            .command => |command| {
                try run_opts.err.print("\"{s}\" is not a valid command\n\n", .{command});
                try cmd.printHelp(null, run_opts.err);
                return error.HandledError;
            },
            .argument => |argument| {
                try run_opts.err.print("\"{s}\" is not a valid argument\n\n", .{argument.value});
                try cmd.printHelp(argument.command, run_opts.err);
                return error.HandledError;
            },
        },
        .help => |cmd_kind_maybe| try cmd.printHelp(cmd_kind_maybe, run_opts.out),
        .local => {
            // session-lifetime allocations (the repo path, session state)
            var session_arena = std.heap.ArenaAllocator.init(allocator);
            defer session_arena.deinit();

            // probe for a git repo first, then a xit repo. only the work path
            // and backend kind are kept; pages re-open the repo on each build.
            const local: ui.RepoSource = blk: {
                if (rp.AnyRepo(.git, .{}).open(io, allocator, .{ .path = cwd_path })) |repo| {
                    var git_repo = repo;
                    defer git_repo.deinit(io, allocator);
                    const work_path = switch (git_repo) {
                        inline else => |*r| r.core.work_path,
                    };
                    break :blk .{ .path = try session_arena.allocator().dupe(u8, work_path), .repo_kind = .git };
                } else |err| switch (err) {
                    error.RepoNotFound => {},
                    else => |e| return e,
                }
                var xit_repo = rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = cwd_path }) catch |err| switch (err) {
                    error.RepoNotFound => {
                        try run_opts.err.print("no git or xit repo found in the current directory\n", .{});
                        return error.HandledError;
                    },
                    else => |e| return e,
                };
                defer xit_repo.deinit(io, allocator);
                const work_path = switch (xit_repo) {
                    inline else => |*r| r.core.work_path,
                };
                break :blk .{ .path = try session_arena.allocator().dupe(u8, work_path), .repo_kind = .xit };
            };

            // every local route internally carries this synthetic
            // "owner/name"; urls elide it.
            const identity = try std.fmt.allocPrint(session_arena.allocator(), "local/{s}", .{std.fs.path.basename(local.path)});
            const route = ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0) orelse {
                try run_opts.err.print("repo directory name is too long\n", .{});
                return error.HandledError;
            };

            var session = ui.Session{
                .arena = &session_arena,
                .page_arena = &session_arena,
                .io = io,
                .local = local,
                .is_terminal = true,
                .data = .{ .current_page = route },
            };

            try ui.run(io, allocator, &session, null);
        },
        .cli => |cli_cmd| switch (cli_cmd) {
            .serve => |options| try srv.run(repo_kind, any_repo_opts, io, allocator, cwd_path, options, run_opts.err, {}),
        },
    }
}

const std = @import("std");
const srv = @import("./serve.zig");

pub const CommandKind = enum {
    serve,
};

const Help = struct {
    name: []const u8,
    descrip: []const u8,
    example: []const u8,
};

fn commandHelp(command_kind: CommandKind) Help {
    return switch (command_kind) {
        .serve => .{
            .name = "serve",
            .descrip =
            \\a long-running server forwarding receive-pack and upload-pack.
            ,
            .example =
            \\haxy serve --http-listen 127.0.0.1:8080 --ssh-listen 127.0.0.1:8022 --wui-listen 127.0.0.1:8000 --data-dir /srv/git
            ,
        },
    };
}

pub fn printHelp(cmd_kind_maybe: ?CommandKind, writer: *std.Io.Writer) !void {
    const print_indent = comptime blk: {
        var indent = 0;
        for (0..@typeInfo(CommandKind).@"enum".fields.len) |i| {
            indent = @max(commandHelp(@enumFromInt(i)).name.len, indent);
        }
        indent += 2;
        break :blk indent;
    };

    if (cmd_kind_maybe) |cmd_kind| {
        const help = commandHelp(cmd_kind);
        // name and description
        try writer.print("{s}", .{help.name});
        for (0..print_indent - help.name.len) |_| try writer.print(" ", .{});
        var split_iter = std.mem.splitScalar(u8, help.descrip, '\n');
        try writer.print("{s}\n", .{split_iter.first()});
        while (split_iter.next()) |line| {
            for (0..print_indent) |_| try writer.print(" ", .{});
            try writer.print("{s}\n", .{line});
        }
        try writer.print("\n", .{});
        // example
        split_iter = std.mem.splitScalar(u8, help.example, '\n');
        while (split_iter.next()) |line| {
            for (0..print_indent) |_| try writer.print(" ", .{});
            try writer.print("{s}\n", .{line});
        }
    } else {
        try writer.print("help: xit <command> [<args>]\n\n", .{});
        inline for (@typeInfo(CommandKind).@"enum".fields) |field| {
            const help = commandHelp(@enumFromInt(field.value));
            // name and description
            try writer.print("{s}", .{help.name});
            for (0..print_indent - help.name.len) |_| try writer.print(" ", .{});
            var split_iter = std.mem.splitScalar(u8, help.descrip, '\n');
            try writer.print("{s}\n", .{split_iter.first()});
            while (split_iter.next()) |line| {
                for (0..print_indent) |_| try writer.print(" ", .{});
                try writer.print("{s}\n", .{line});
            }
        }
    }
}

pub const CommandArgs = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    command_kind: ?CommandKind,
    command_name: ?[]const u8,
    positional_args: []const []const u8,
    map_args: std.StringArrayHashMapUnmanaged(?[]const u8),
    unused_args: std.StringArrayHashMapUnmanaged(void),

    // flags that can have a value associated with them
    // must be included here
    const value_flags = std.StaticStringMap(void).initComptime(.{
        .{"--http-listen"},
        .{"--ssh-listen"},
        .{"--wui-listen"},
        .{"--data-dir"},
    });

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) !CommandArgs {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        var positional_args: std.ArrayList([]const u8) = .empty;
        var map_args: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        var unused_args: std.StringArrayHashMapUnmanaged(void) = .empty;

        for (args) |arg| {
            if (arg.len > 1 and arg[0] == '-') {
                try map_args.put(arena.allocator(), arg, null);
                try unused_args.put(arena.allocator(), arg, {});
            } else {
                // if the last key is a value flag and doesn't have a value yet,
                // set this arg as its value
                const keys = map_args.keys();
                if (keys.len > 0) {
                    const last_key = keys[keys.len - 1];
                    if (map_args.get(last_key)) |last_val| {
                        if (value_flags.has(last_key) and last_val == null) {
                            try map_args.put(arena.allocator(), last_key, arg);
                            continue;
                        }
                    }
                }

                // in any other case, just consider it a positional arg
                try positional_args.append(arena.allocator(), arg);
            }
        }

        const args_slice = try positional_args.toOwnedSlice(arena.allocator());
        if (args_slice.len == 0) {
            return .{
                .allocator = allocator,
                .arena = arena,
                .command_kind = null,
                .command_name = null,
                .positional_args = args_slice,
                .map_args = map_args,
                .unused_args = unused_args,
            };
        } else {
            const command_name = args_slice[0];
            const extra_args = args_slice[1..];

            const command_kind: ?CommandKind = inline for (0..@typeInfo(CommandKind).@"enum".fields.len) |i| {
                if (std.mem.eql(u8, command_name, commandHelp(@enumFromInt(i)).name)) {
                    break @enumFromInt(i);
                }
            } else null;

            return .{
                .allocator = allocator,
                .arena = arena,
                .command_kind = command_kind,
                .command_name = command_name,
                .positional_args = extra_args,
                .map_args = map_args,
                .unused_args = unused_args,
            };
        }
    }

    pub fn deinit(self: *CommandArgs) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn contains(self: *CommandArgs, arg: []const u8) bool {
        _ = self.unused_args.orderedRemove(arg);
        return self.map_args.contains(arg);
    }

    pub fn get(self: *CommandArgs, comptime arg: []const u8) ??[]const u8 {
        comptime std.debug.assert(value_flags.has(arg)); // can only call `get` with flags included in `value_flags`
        _ = self.unused_args.orderedRemove(arg);
        return self.map_args.get(arg);
    }
};

/// parses the args into a format that can be directly used by a repo.
/// if any additional allocation needs to be done, the arena inside the cmd args will be used.
pub const Command = union(CommandKind) {
    serve: srv.Options,

    pub fn initMaybe(cmd_args: *CommandArgs) !?Command {
        const command_kind = cmd_args.command_kind orelse return null;
        switch (command_kind) {
            .serve => {
                if (cmd_args.positional_args.len != 0) return null;

                var options: srv.Options = .{};

                if (cmd_args.get("--http-listen")) |val_maybe| {
                    options.http_listen = val_maybe orelse return error.HttpListenNeedsValue;
                }
                if (cmd_args.get("--ssh-listen")) |val_maybe| {
                    options.ssh_listen = val_maybe orelse return error.SshListenNeedsValue;
                }
                if (cmd_args.get("--wui-listen")) |val_maybe| {
                    options.wui_listen = val_maybe orelse return error.WuiListenNeedsValue;
                }
                if (cmd_args.get("--data-dir")) |val_maybe| {
                    options.data_dir = val_maybe orelse return error.DataDirNeedsValue;
                }

                return .{ .serve = options };
            },
        }
    }
};

/// parses the given args into a command if valid, and determines how it should be run
/// (via the TUI or CLI).
pub const CommandDispatch = union(enum) {
    invalid: union(enum) {
        command: []const u8,
        argument: struct {
            command: ?CommandKind,
            value: []const u8,
        },
    },
    help: ?CommandKind,
    cli: Command,

    pub fn init(cmd_args: *CommandArgs) !CommandDispatch {
        const dispatch = try initIgnoreUnused(cmd_args);
        if (cmd_args.unused_args.count() > 0) {
            return .{
                .invalid = .{
                    .argument = .{
                        .command = switch (dispatch) {
                            .invalid => return dispatch, // if there was already an error, return it instead
                            .help => |cmd_kind_maybe| cmd_kind_maybe,
                            .cli => |command| command,
                        },
                        .value = cmd_args.unused_args.keys()[0],
                    },
                },
            };
        }
        return dispatch;
    }

    pub fn initIgnoreUnused(cmd_args: *CommandArgs) !CommandDispatch {
        const show_help = cmd_args.contains("--help");

        if (cmd_args.command_kind) |command_kind| {
            if (show_help) {
                return .{ .help = command_kind };
            } else if (try Command.initMaybe(cmd_args)) |cmd| {
                return .{ .cli = cmd };
            } else {
                return .{ .help = command_kind };
            }
        } else if (cmd_args.command_name) |command_name| {
            return .{ .invalid = .{ .command = command_name } };
        } else if (show_help) {
            return .{ .help = null };
        } else {
            return .{ .help = null };
        }
    }
};

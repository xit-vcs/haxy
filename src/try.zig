//! start a server with some fake data and then launch
//! the TUI. this provides a nice way to test things
//! out safely.

const std = @import("std");
const hx = @import("haxy");
const srv = hx.serve;
const evt = hx.event;
const xit = hx.xit;
const rp = xit.repo;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const temp_dir_name = "temp-try";

    // create the temp dir
    const cwd = std.Io.Dir.cwd();
    var temp_dir_or_err = cwd.openDir(io, temp_dir_name, .{});
    if (temp_dir_or_err) |*temp_dir| {
        temp_dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server" });
    defer allocator.free(server_path);

    // create the admin repo
    {
        const work_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server", "admin" });
        defer allocator.free(work_path);

        const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
        const Repo = rp.Repo(.xit, repo_opts);
        var repo = try Repo.init(io, allocator, .{ .path = work_path });
        defer repo.deinit(io, allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // define test events

        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
        const alice_id = evt.EventWithId.randomId(prng.random());
        const repo_event_id = evt.EventWithId.randomId(prng.random());

        var alice_password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
        const alice_password_hash = try evt.User.hashPassword("correct horse battery staple", &alice_password_hash_buf, io);

        const events_to_consume = [_]evt.EventWithId{
            .{
                .id = std.fmt.bytesToHex(alice_id, .lower),
                .event = .{
                    .user = .{
                        .name = "alice",
                        .display_name = "Alice Example",
                        .email = "alice@example.test",
                        .password_hash = alice_password_hash,
                    },
                },
            },
            .{
                .id = std.fmt.bytesToHex(repo_event_id, .lower),
                .event = .{
                    .repo = .{
                        .user_id = &alice_id,
                        .name = "ziglings",
                        .description = "Learn the Zig programming language by fixing tiny broken programs",
                        .enable_issue = true,
                    },
                },
            },
        };

        // insert users and repos as commits in the repo
        {
            var json: std.Io.Writer.Allocating = .init(allocator);
            defer json.deinit();

            for (events_to_consume) |event| {
                json.clearRetainingCapacity();

                try std.json.Stringify.value(event, .{}, &json.writer);

                // commit the event into a special branch
                _ = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, .{ .kind = .head, .name = "haxy/meta" });
            }
        }

        // consume events into the database
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });
    }

    // start server

    var null_writer = std.Io.Writer.Discarding.init(&.{});
    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    const run_opts = hx.main.RunOpts{ .out = &null_writer.writer, .err = &null_writer.writer, .environ_map = &environ_map };

    try srv.run(.xit, .{}, io, allocator, cwd_path, .{
        .data_dir = server_path,
        .tui = true,
    }, run_opts.err);
}

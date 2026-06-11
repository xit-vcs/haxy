//! start a server with some fake data and then launch
//! the TUI. this provides a nice way to test things
//! out safely.

const std = @import("std");
const hx = @import("haxy");
const srv = hx.serve;
const evt = hx.event;
const xit = hx.xit;
const rp = xit.repo;
const ui = hx.ui;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = init.minimal.environ,
    });
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

    const work_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server", "admin" });
    defer allocator.free(work_path);

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.init(io, allocator, .{ .path = work_path });
    defer repo.deinit(io, allocator);

    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "admin@haxy" });

    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();

    var session: ui.Session = blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // define test events

        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);

        const user_data = [_]struct {
            name: []const u8,
            display_name: []const u8,
            email: []const u8,
        }{
            .{ .name = "admin", .display_name = "Admin", .email = "admin@example.test" },
            .{ .name = "alice", .display_name = "Alice Tulley", .email = "alice@example.test" },
            .{ .name = "bob", .display_name = "Bob Smith", .email = "bob@example.test" },
            .{ .name = "carol", .display_name = "Carol Johnson", .email = "carol@example.test" },
            .{ .name = "dave", .display_name = "Dave Wilson", .email = "dave@example.test" },
            .{ .name = "eve", .display_name = "Eve Anderson", .email = "eve@example.test" },
            .{ .name = "frank", .display_name = "Frank Miller", .email = "frank@example.test" },
            .{ .name = "grace", .display_name = "Grace Lee", .email = "grace@example.test" },
            .{ .name = "henry", .display_name = "Henry Davis", .email = "henry@example.test" },
            .{ .name = "ivy", .display_name = "Ivy Martinez", .email = "ivy@example.test" },
            .{ .name = "jack", .display_name = "Jack Thompson", .email = "jack@example.test" },
            .{ .name = "kate", .display_name = "Kate Robinson", .email = "kate@example.test" },
            .{ .name = "liam", .display_name = "Liam Walker", .email = "liam@example.test" },
            .{ .name = "mona", .display_name = "Mona Patel", .email = "mona@example.test" },
            .{ .name = "noah", .display_name = "Noah Garcia", .email = "noah@example.test" },
            .{ .name = "olivia", .display_name = "Olivia Hernandez", .email = "olivia@example.test" },
            .{ .name = "peter", .display_name = "Peter Wright", .email = "peter@example.test" },
            .{ .name = "quinn", .display_name = "Quinn Foster", .email = "quinn@example.test" },
            .{ .name = "rachel", .display_name = "Rachel Bennett", .email = "rachel@example.test" },
            .{ .name = "sam", .display_name = "Sam Brooks", .email = "sam@example.test" },
            .{ .name = "tina", .display_name = "Tina Cooper", .email = "tina@example.test" },
        };

        const repo_data = [_]struct {
            user_index: usize,
            name: []const u8,
            description: []const u8,
        }{
            .{ .user_index = 0, .name = "ziglings", .description = "Learn the Zig programming language by fixing tiny broken programs" },
            .{ .user_index = 1, .name = "linux", .description = "Linux kernel source tree" },
            .{ .user_index = 2, .name = "kubernetes", .description = "Production-grade container orchestration" },
            .{ .user_index = 3, .name = "react", .description = "A declarative, efficient, and flexible JavaScript library for building user interfaces" },
            .{ .user_index = 4, .name = "typescript", .description = "TypeScript is a superset of JavaScript that compiles to clean JavaScript output" },
            .{ .user_index = 5, .name = "rust", .description = "Empowering everyone to build reliable and efficient software" },
            .{ .user_index = 6, .name = "go", .description = "The Go programming language" },
            .{ .user_index = 7, .name = "nodejs", .description = "Node.js JavaScript runtime" },
            .{ .user_index = 8, .name = "cpython", .description = "The Python programming language" },
            .{ .user_index = 9, .name = "docker", .description = "Container platform for developing, shipping, and running applications" },
            .{ .user_index = 0, .name = "vim", .description = "The ubiquitous text editor" },
            .{ .user_index = 1, .name = "neovim", .description = "Hyperextensible Vim-based text editor" },
            .{ .user_index = 2, .name = "emacs", .description = "GNU Emacs source code mirror" },
            .{ .user_index = 3, .name = "tmux", .description = "Terminal multiplexer" },
            .{ .user_index = 4, .name = "zsh", .description = "Mirror of the Z shell source code repository" },
            .{ .user_index = 5, .name = "git", .description = "Distributed version control system" },
            .{ .user_index = 6, .name = "mercurial", .description = "Source-control management tool" },
            .{ .user_index = 7, .name = "tensorflow", .description = "An end-to-end open source machine learning platform" },
            .{ .user_index = 8, .name = "pytorch", .description = "Tensors and dynamic neural networks in Python with strong GPU acceleration" },
            .{ .user_index = 9, .name = "numpy", .description = "The fundamental package for scientific computing with Python" },
            .{ .user_index = 0, .name = "pandas", .description = "Flexible and powerful data analysis and manipulation library for Python" },
            .{ .user_index = 1, .name = "scikit-learn", .description = "Machine learning in Python" },
            .{ .user_index = 2, .name = "nginx", .description = "High performance HTTP server and reverse proxy" },
            .{ .user_index = 3, .name = "redis", .description = "In-memory data structure store, used as a database, cache, and message broker" },
            .{ .user_index = 4, .name = "postgres", .description = "The world's most advanced open source relational database" },
            .{ .user_index = 5, .name = "sqlite", .description = "Self-contained, serverless, zero-configuration SQL database engine" },
            .{ .user_index = 6, .name = "mongodb", .description = "The MongoDB Database" },
            .{ .user_index = 7, .name = "elasticsearch", .description = "Free and open, distributed, RESTful search engine" },
            .{ .user_index = 8, .name = "kafka", .description = "Distributed event streaming platform" },
            .{ .user_index = 9, .name = "terraform", .description = "Infrastructure as code tool" },
            .{ .user_index = 10, .name = "svelte", .description = "Cybernetically enhanced web apps" },
            .{ .user_index = 11, .name = "vue", .description = "The progressive JavaScript framework" },
            .{ .user_index = 12, .name = "flask", .description = "The Python micro framework for building web applications" },
            .{ .user_index = 13, .name = "django", .description = "The web framework for perfectionists with deadlines" },
            .{ .user_index = 14, .name = "rails", .description = "Ruby on Rails web framework" },
            .{ .user_index = 15, .name = "phoenix", .description = "Peace of mind from prototype to production for Elixir web apps" },
            .{ .user_index = 16, .name = "laravel", .description = "The PHP framework for web artisans" },
            .{ .user_index = 17, .name = "prometheus", .description = "The Prometheus monitoring system and time series database" },
            .{ .user_index = 18, .name = "grafana", .description = "The open and composable observability and data visualization platform" },
            .{ .user_index = 19, .name = "ansible", .description = "Simple, agentless IT automation" },
        };

        var user_ids: [user_data.len][evt.event_id_size]u8 = undefined;
        for (&user_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var repo_event_ids: [repo_data.len][evt.event_id_size]u8 = undefined;
        for (&repo_event_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
        const password_hash = try evt.User.hashPassword("password", &password_hash_buf, io);

        var events_to_consume: [user_data.len + repo_data.len]evt.EventWithId = undefined;
        for (user_data, 0..) |u, i| {
            events_to_consume[i] = .{
                .id = std.fmt.bytesToHex(user_ids[i], .lower),
                .event = .{
                    .user = .{
                        .name = u.name,
                        .display_name = u.display_name,
                        .email = u.email,
                        .password_hash = password_hash,
                    },
                },
            };
        }
        for (repo_data, 0..) |r, i| {
            events_to_consume[user_data.len + i] = .{
                .id = std.fmt.bytesToHex(repo_event_ids[i], .lower),
                .event = .{
                    .repo = .{
                        .user_id = &user_ids[r.user_index],
                        .name = r.name,
                        .description = r.description,
                        .enable_issue = true,
                    },
                },
            };
        }

        // commit the seed events and consume them into the database
        try evt.commitAndConsume(evt.admin_repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume);

        // create the actual repos on disk, named by their hex-encoded event id
        for (repo_data, 0..) |r, i| {
            const repo_id = std.fmt.bytesToHex(repo_event_ids[i], .lower);
            const repo_path = try std.fs.path.join(arena.allocator(), &.{ cwd_path, temp_dir_name, "server", "repos", &repo_id });

            var repo_i = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = repo_path });
            defer repo_i.deinit(io, allocator);

            try repo_i.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
            try repo_i.addConfig(io, allocator, .{ .name = "user.email", .value = "admin@haxy" });

            // write the repo's name and description into a README, plus a
            // nested doc so the file tree has a directory to descend into
            {
                var repo_dir = try cwd.openDir(io, repo_path, .{});
                defer repo_dir.close(io);

                const readme = try repo_dir.createFile(io, "README.md", .{});
                defer readme.close(io);
                const readme_content = try std.fmt.allocPrint(arena.allocator(), "# {s}\n\n{s}\n", .{ r.name, r.description });
                try readme.writeStreamingAll(io, readme_content);

                try repo_dir.createDirPath(io, "docs/dev");
                const doc = try repo_dir.createFile(io, "docs/dev/contribute.md", .{});
                defer doc.close(io);
                try doc.writeStreamingAll(io, "To contribute, please make a pull request");
            }

            try repo_i.add(io, allocator, &.{ "README.md", "docs/dev/contribute.md" });
            _ = try repo_i.commit(io, allocator, .{ .message = "let there be light" });

            // a batch of empty commits so the commits tab has more than one page
            // to paginate through. stepped timestamps vary the date column.
            const base_ts: u64 = 1_700_000_000; // 2023-11-14
            var c: usize = 0;
            while (c < 30) : (c += 1) {
                const message = try std.fmt.allocPrint(arena.allocator(), "empty commit {d}", .{c + 1});
                _ = try repo_i.commit(io, allocator, .{ .message = message, .allow_empty = true, .timestamp = base_ts + c * std.time.s_per_day });
            }
        }

        break :blk try ui.Session.init(&session_arena, &repo, .{});
    };
    session.is_terminal = true;

    // start the server

    var cli = false;

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, "--cli", arg)) {
            cli = true;
        }
    }

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server" });
    defer allocator.free(server_path);

    // let the native TUI's page builders open the on-disk repos for the file tree
    session.io = io;
    session.repos_dir = try std.fs.path.join(session_arena.allocator(), &.{ server_path, "repos" });

    if (cli) {
        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        const run_opts = hx.main.RunOpts{ .out = &stdout_writer.interface, .err = &stderr_writer.interface };

        const Runnable = struct {
            io: std.Io,

            pub fn run(self: @This()) !void {
                std.debug.print(
                    \\
                    \\connect to the TUI with:
                    \\  ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost
                    \\
                    \\create a git repo and push over SSH:
                    \\  mkdir -p temp-try/client/test
                    \\  cd temp-try/client/test
                    \\  git init
                    \\  echo "hello" > hello.txt
                    \\  git add hello.txt
                    \\  git commit -m "let there be light"
                    \\  GIT_SSH_COMMAND='ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' git push localhost:admin/test HEAD:master
                    \\
                    \\to quit, press enter.
                    \\
                , .{});
                // portable stdin read via std.Io — equivalent to the
                // std.posix.read(STDIN_FILENO, ...) that doesn't compile
                // on windows.
                var buf: [1]u8 = undefined;
                var stdin_reader = std.Io.File.stdin().reader(self.io, &buf);
                _ = stdin_reader.interface.takeByte() catch {};
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, .{
            .data_dir = server_path,
        }, run_opts.err, Runnable{ .io = io });
    } else {
        var null_writer = std.Io.Writer.Discarding.init(&.{});
        const run_opts = hx.main.RunOpts{ .out = &null_writer.writer, .err = &null_writer.writer };

        const Runnable = struct {
            io: std.Io,
            allocator: std.mem.Allocator,
            session: *ui.Session,

            pub fn run(self: @This()) !void {
                // launch the TUI
                try hx.ui.run(self.io, self.allocator, self.session);
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, .{
            .data_dir = server_path,
        }, run_opts.err, Runnable{ .io = io, .allocator = allocator, .session = &session });
    }
}

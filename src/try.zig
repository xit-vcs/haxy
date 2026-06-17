//! start a server with some fake data and then launch
//! the TUI. this provides a nice way to test things
//! out safely.

const std = @import("std");
const builtin = @import("builtin");
const hx = @import("haxy");
const srv = hx.serve;
const evt = hx.event;
const xit = hx.xit;
const rp = xit.repo;
const ui = hx.ui;

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = xit.xitui.terminal.crash_debug_io;

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

    // write the dev SSH private key so pushes can authenticate against the
    // matching public key seeded on the admin account below
    {
        const priv_key_file = try temp_dir.createFile(io, "key", .{});
        defer priv_key_file.close(io);
        try priv_key_file.writeStreamingAll(io,
            \\-----BEGIN OPENSSH PRIVATE KEY-----
            \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
            \\QyNTUxOQAAACCniLPJiaooAWecvOCeAjoJwCSeWxzysvpTNkpYjF22JgAAAJA+7hikPu4Y
            \\pAAAAAtzc2gtZWQyNTUxOQAAACCniLPJiaooAWecvOCeAjoJwCSeWxzysvpTNkpYjF22Jg
            \\AAAEDVlopOMnKt/7by/IA8VZvQXUS/O6VLkixOqnnahUdPCKeIs8mJqigBZ5y84J4COgnA
            \\JJ5bHPKy+lM2SliMXbYmAAAAC3JhZGFyQHJvYXJrAQI=
            \\-----END OPENSSH PRIVATE KEY-----
            \\
        );
        if (.windows != builtin.os.tag) {
            try priv_key_file.setPermissions(io, @enumFromInt(0o600));
        }
    }

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
            .{ .user_index = 1, .name = "ziglings", .description = "Learn the Zig programming language by fixing tiny broken programs" },
            .{ .user_index = 2, .name = "linux", .description = "Linux kernel source tree" },
            .{ .user_index = 3, .name = "kubernetes", .description = "Production-grade container orchestration" },
            .{ .user_index = 4, .name = "react", .description = "A declarative, efficient, and flexible JavaScript library for building user interfaces" },
            .{ .user_index = 5, .name = "typescript", .description = "TypeScript is a superset of JavaScript that compiles to clean JavaScript output" },
            .{ .user_index = 6, .name = "rust", .description = "Empowering everyone to build reliable and efficient software" },
            .{ .user_index = 7, .name = "go", .description = "The Go programming language" },
            .{ .user_index = 8, .name = "nodejs", .description = "Node.js JavaScript runtime" },
            .{ .user_index = 9, .name = "cpython", .description = "The Python programming language" },
            .{ .user_index = 10, .name = "docker", .description = "Container platform for developing, shipping, and running applications" },
            .{ .user_index = 1, .name = "vim", .description = "The ubiquitous text editor" },
            .{ .user_index = 2, .name = "neovim", .description = "Hyperextensible Vim-based text editor" },
            .{ .user_index = 3, .name = "emacs", .description = "GNU Emacs source code mirror" },
            .{ .user_index = 4, .name = "tmux", .description = "Terminal multiplexer" },
            .{ .user_index = 5, .name = "zsh", .description = "Mirror of the Z shell source code repository" },
            .{ .user_index = 6, .name = "git", .description = "Distributed version control system" },
            .{ .user_index = 7, .name = "mercurial", .description = "Source-control management tool" },
            .{ .user_index = 8, .name = "tensorflow", .description = "An end-to-end open source machine learning platform" },
            .{ .user_index = 9, .name = "pytorch", .description = "Tensors and dynamic neural networks in Python with strong GPU acceleration" },
            .{ .user_index = 10, .name = "numpy", .description = "The fundamental package for scientific computing with Python" },
            .{ .user_index = 1, .name = "pandas", .description = "Flexible and powerful data analysis and manipulation library for Python" },
            .{ .user_index = 2, .name = "scikit-learn", .description = "Machine learning in Python" },
            .{ .user_index = 3, .name = "nginx", .description = "High performance HTTP server and reverse proxy" },
            .{ .user_index = 4, .name = "redis", .description = "In-memory data structure store, used as a database, cache, and message broker" },
            .{ .user_index = 5, .name = "postgres", .description = "The world's most advanced open source relational database" },
            .{ .user_index = 6, .name = "sqlite", .description = "Self-contained, serverless, zero-configuration SQL database engine" },
            .{ .user_index = 7, .name = "mongodb", .description = "The MongoDB Database" },
            .{ .user_index = 8, .name = "elasticsearch", .description = "Free and open, distributed, RESTful search engine" },
            .{ .user_index = 9, .name = "kafka", .description = "Distributed event streaming platform" },
            .{ .user_index = 10, .name = "terraform", .description = "Infrastructure as code tool" },
            .{ .user_index = 11, .name = "svelte", .description = "Cybernetically enhanced web apps" },
            .{ .user_index = 12, .name = "vue", .description = "The progressive JavaScript framework" },
            .{ .user_index = 13, .name = "flask", .description = "The Python micro framework for building web applications" },
            .{ .user_index = 14, .name = "django", .description = "The web framework for perfectionists with deadlines" },
            .{ .user_index = 15, .name = "rails", .description = "Ruby on Rails web framework" },
            .{ .user_index = 16, .name = "phoenix", .description = "Peace of mind from prototype to production for Elixir web apps" },
            .{ .user_index = 17, .name = "laravel", .description = "The PHP framework for web artisans" },
            .{ .user_index = 18, .name = "prometheus", .description = "The Prometheus monitoring system and time series database" },
            .{ .user_index = 19, .name = "grafana", .description = "The open and composable observability and data visualization platform" },
            .{ .user_index = 20, .name = "ansible", .description = "Simple, agentless IT automation" },
        };

        var user_ids: [user_data.len][evt.event_id_size]u8 = undefined;
        for (&user_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var repo_event_ids: [repo_data.len][evt.event_id_size]u8 = undefined;
        for (&repo_event_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
        const password_hash = try evt.User.hashPassword("password", &password_hash_buf, io);

        // public key matching temp-try/key, given to admin so we can push as admin
        const admin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark";

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
                        .ssh_keys = if (i == 0) admin_ssh_key else "",
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

        // every repo gets the same generated history, so build it once into a
        // template repo and copy that to each repo's location below rather than
        // redoing the expensive commit work for every repo.
        const template_path = try std.fs.path.join(arena.allocator(), &.{ cwd_path, temp_dir_name, "template" });
        {
            var template_repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = template_path });
            defer template_repo.deinit(io, allocator);

            try template_repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
            try template_repo.addConfig(io, allocator, .{ .name = "user.email", .value = "admin@haxy" });

            // a README plus a nested doc so the file tree has a directory to
            // descend into
            {
                var repo_dir = try cwd.openDir(io, template_path, .{});
                defer repo_dir.close(io);

                const readme = try repo_dir.createFile(io, "README.md", .{});
                defer readme.close(io);
                try readme.writeStreamingAll(io, "# Sample Repo\n\nA repository seeded with test data.\n");

                try repo_dir.createDirPath(io, "docs/dev");
                const doc = try repo_dir.createFile(io, "docs/dev/contribute.md", .{});
                defer doc.close(io);
                try doc.writeStreamingAll(io, "To contribute, please make a pull request");
            }

            try template_repo.add(io, allocator, &.{ "README.md", "docs/dev/contribute.md" });
            _ = try template_repo.commit(io, allocator, .{ .message = "let there be light" });

            // a batch of commits so the commits tab has more than one page to
            // paginate through. each rewrites a few files with scattered line
            // edits, so every commit is a multi-file diff with several separate
            // hunks to look at. stepped timestamps vary the date column.
            const base_ts: u64 = 1_700_000_000; // 2023-11-14
            const edit_files = [_][]const u8{ "src/alpha.txt", "src/beta.txt", "src/gamma.txt" };
            // cycled through to pad each line into prose-like content.
            const words = [_][]const u8{
                "lorem",   "ipsum",  "dolor",  "sit",    "amet",   "consectetur",
                "quantum", "vector", "matrix", "buffer", "kernel", "socket",
                "falcon",  "otter",  "badger", "walrus", "ferret", "marmot",
                "scatter", "gather", "encode", "decode", "render", "commit",
            };
            // commit subjects, cycled then padded to a varying length.
            const subjects = [_][]const u8{
                "fix off-by-one in scatter loop",
                "encode and decode buffers",
                "tune kernel socket timeouts",
                "render matrix vector product",
                "gather falcon and otter stats",
                "refactor badger walrus module",
                "drop dead ferret marmot branch",
            };
            var c: usize = 0;
            while (c < 30) : (c += 1) {
                {
                    var repo_dir = try cwd.openDir(io, template_path, .{});
                    defer repo_dir.close(io);
                    try repo_dir.createDirPath(io, "src");
                    for (edit_files, 0..) |path, fi| {
                        const file = try repo_dir.createFile(io, path, .{});
                        defer file.close(io);
                        var writer = std.Io.Writer.Allocating.init(allocator);
                        defer writer.deinit();
                        // every 8th line is edited by this commit; the stride
                        // offset shifts with c so consecutive commits touch
                        // different lines, and the edited text carries a
                        // c-dependent word, so each commit's diff is a distinct
                        // scatter of hunks. untouched lines stay byte-identical
                        // across commits (their padding ignores c) so they don't
                        // all change every commit. each line is padded with
                        // cycled words to a per-line length, capped at 120.
                        for (0..40) |line| {
                            const start = writer.written().len;
                            if ((line + fi + c) % 8 == 0) {
                                const tag = words[(line + fi + c * 3) % words.len];
                                try writer.writer.print("rev {d} {s}", .{ c, tag });
                            }
                            const target = 40 + (line * 17 + fi * 23) % 70;
                            var w = line + fi;
                            while (true) : (w += 1) {
                                const word = words[w % words.len];
                                const len = writer.written().len - start;
                                if (len >= target or len + 1 + word.len > 120) break;
                                if (len == 0)
                                    try writer.writer.print("{s}", .{word})
                                else
                                    try writer.writer.print(" {s}", .{word});
                            }
                            try writer.writer.writeByte('\n');
                        }
                        try file.writeStreamingAll(io, writer.written());
                    }
                }
                try template_repo.add(io, allocator, &edit_files);
                // a cycling subject padded to a c-varying length so the commit
                // list shows messages of different widths, capped at 120.
                var msg_writer = std.Io.Writer.Allocating.init(allocator);
                defer msg_writer.deinit();
                try msg_writer.writer.print("{s}", .{subjects[c % subjects.len]});
                const msg_target = 16 + (c * 41) % 96;
                var mw = c;
                while (true) : (mw += 1) {
                    const word = words[mw % words.len];
                    const len = msg_writer.written().len;
                    if (len >= msg_target or len + 1 + word.len > 120) break;
                    try msg_writer.writer.print(" {s}", .{word});
                }
                const message = try arena.allocator().dupe(u8, msg_writer.written());
                _ = try template_repo.commit(io, allocator, .{ .message = message, .timestamp = base_ts + c * std.time.s_per_day });
            }
        }

        // copy the template to each repo's on-disk location, named by its
        // hex-encoded event id. the template repo is deinitialized above, so its
        // db file is fully written before we copy it.
        {
            var template_dir = try cwd.openDir(io, template_path, .{ .iterate = true });
            defer template_dir.close(io);

            for (repo_event_ids) |id_bytes| {
                const repo_id = std.fmt.bytesToHex(id_bytes, .lower);
                const repo_path = try std.fs.path.join(arena.allocator(), &.{ cwd_path, temp_dir_name, "server", "repos", &repo_id });
                var dest_dir = try cwd.createDirPathOpen(io, repo_path, .{});
                defer dest_dir.close(io);
                try copyDir(io, template_dir, dest_dir);
            }
        }

        break :blk try ui.Session.init(&session_arena, &repo, .{});
    };
    session.is_terminal = true;
    // try uses the default serve options below, so the footer's url points at
    // the default web UI port.
    session.web_port = try (srv.Options{}).wuiPort();

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

        const key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(key_path);

        const Runnable = struct {
            io: std.Io,
            key_path: []const u8,

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
                    \\  GIT_SSH_COMMAND='ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i {s}' git push localhost:admin/test HEAD:master
                    \\
                    \\to quit, press enter.
                    \\
                , .{self.key_path});
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
        }, run_opts.err, Runnable{ .io = io, .key_path = key_path });
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

// recursively copy the contents of src_dir into dest_dir
fn copyDir(io: std.Io, src_dir: std.Io.Dir, dest_dir: std.Io.Dir) !void {
    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => try src_dir.copyFile(entry.name, dest_dir, entry.name, io, .{}),
            .directory => {
                try dest_dir.createDirPath(io, entry.name);
                var dest_entry_dir = try dest_dir.openDir(io, entry.name, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
                defer dest_entry_dir.close(io);
                var src_entry_dir = try src_dir.openDir(io, entry.name, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
                defer src_entry_dir.close(io);
                try copyDir(io, src_entry_dir, dest_entry_dir);
            },
            else => {},
        }
    }
}

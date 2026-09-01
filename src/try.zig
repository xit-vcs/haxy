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
const hash = xit.hash;
const obj = xit.object;
const ui = hx.ui;
const fork = hx.fork;
const pch = hx.pch;

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = xit.xitui.terminal.crash_debug_io;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

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
    const key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
    defer allocator.free(key_path);

    var cli = false;
    var serve_args: std.ArrayList([]const u8) = .empty;
    defer serve_args.deinit(allocator);
    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, "--cli", arg)) {
            cli = true;
        } else {
            try serve_args.append(allocator, arg);
        }
    }
    var serve_options = try hx.command.parseServeOptions(allocator, serve_args.items);
    const git_ssh_prefix = if (builtin.mode == .Debug)
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='ssh -i \"{s}\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR' \\\r\n", .{key_path})
    else
        "";
    defer if (git_ssh_prefix.len != 0) allocator.free(git_ssh_prefix);
    serve_options.git_ssh_prefix = git_ssh_prefix;
    serve_options.fallback_on_address_in_use = true;

    const server_path = if (std.mem.eql(u8, serve_options.data_dir, "."))
        try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server" })
    else
        try std.fs.path.resolve(allocator, &.{ cwd_path, serve_options.data_dir });
    defer allocator.free(server_path);
    serve_options.data_dir = server_path;

    const work_path = try std.fs.path.join(allocator, &.{ server_path, "admin" });
    defer allocator.free(work_path);

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.init(io, allocator, .{ .path = work_path });
    defer repo.deinit(io, allocator);

    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();

    // the seeded admin's event id, so both uis start logged in as them
    var admin_user_id: [evt.event_id_size]u8 = undefined;

    var session: ui.Session = blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // define test events

        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);

        const user_data = [_]struct {
            name: []const u8,
            email: []const u8,
        }{
            .{ .name = "admin", .email = "admin@example.test" },
            .{ .name = "alice", .email = "alice@example.test" },
            .{ .name = "bob", .email = "bob@example.test" },
            .{ .name = "carol", .email = "carol@example.test" },
            .{ .name = "dave", .email = "dave@example.test" },
            .{ .name = "eve", .email = "eve@example.test" },
            .{ .name = "frank", .email = "frank@example.test" },
            .{ .name = "grace", .email = "grace@example.test" },
            .{ .name = "henry", .email = "henry@example.test" },
            .{ .name = "ivy", .email = "ivy@example.test" },
            .{ .name = "jack", .email = "jack@example.test" },
            .{ .name = "kate", .email = "kate@example.test" },
            .{ .name = "liam", .email = "liam@example.test" },
            .{ .name = "mona", .email = "mona@example.test" },
            .{ .name = "noah", .email = "noah@example.test" },
            .{ .name = "olivia", .email = "olivia@example.test" },
            .{ .name = "peter", .email = "peter@example.test" },
            .{ .name = "quinn", .email = "quinn@example.test" },
            .{ .name = "rachel", .email = "rachel@example.test" },
            .{ .name = "sam", .email = "sam@example.test" },
            .{ .name = "tina", .email = "tina@example.test" },
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
        // admin is the first entry of user_data above
        admin_user_id = user_ids[0];

        var repo_event_ids: [repo_data.len][evt.event_id_size]u8 = undefined;
        for (&repo_event_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
        const password_hash = try evt.User.hashPassword("password", &password_hash_buf, io);

        // public key matching temp-try/key, given to admin so we can push as admin
        const admin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark";

        var events_to_consume: [user_data.len + repo_data.len]evt.EventWithId = undefined;
        // inserted back to front, so the newest-first listing shows them in the
        // order they're written above
        for (0..user_data.len) |slot| {
            const i = user_data.len - 1 - slot;
            const u = user_data[i];
            events_to_consume[slot] = .{
                .id = std.fmt.bytesToHex(user_ids[i], .lower),
                // stepped timestamps so the seeded users/repos list in a stable order
                .timestamp = @intCast(slot + 1),
                .author = .{ .name = "admin", .email = "admin@example.test" },
                .event = .{
                    .user = .{
                        .name = u.name,
                        .email = u.email,
                        .password_hash = password_hash,
                        .ssh_keys = if (std.mem.eql(u8, "admin", u.name)) admin_ssh_key else "",
                    },
                },
            };
        }
        for (repo_data, 0..) |r, i| {
            events_to_consume[user_data.len + i] = .{
                .id = std.fmt.bytesToHex(repo_event_ids[i], .lower),
                .timestamp = @intCast(user_data.len + i + 1),
                .author = .{ .name = user_data[r.user_index].name, .email = user_data[r.user_index].email },
                .event = .{
                    .repo = .{
                        .user_id = &user_ids[r.user_index],
                        .name = r.name,
                        .description = r.description,
                        .read_access = .public,
                        .write_access = .public,
                    },
                },
            };
        }

        // commit the seed events and consume them into the database
        try evt.consume(.admin, .xit, evt.admin_repo_opts, io, allocator, &repo, evt.events_ref, &events_to_consume);

        // every repo gets the same generated history, so build it once into a
        // template repo and copy that to each repo's location below rather than
        // redoing the expensive commit work for every repo.
        const template_path = try std.fs.path.join(arena.allocator(), &.{ cwd_path, temp_dir_name, "template" });
        {
            var template_repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = template_path });
            defer template_repo.deinit(io, allocator);

            try template_repo.setMergeAlgorithm(io, allocator, .diff3);
            try template_repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
            try template_repo.addConfig(io, allocator, .{ .name = "user.email", .value = "admin@example.test" });
            try template_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });

            // a README plus a nested doc so the file tree has a directory to
            // descend into
            {
                var repo_dir = try cwd.openDir(io, template_path, .{});
                defer repo_dir.close(io);

                const readme = try repo_dir.createFile(io, "README.md", .{});
                defer readme.close(io);
                try readme.writeStreamingAll(io,
                    \\# Sample Repo
                    \\
                    \\A repository seeded with test data for exercising the UI.
                    \\
                    \\## Features
                    \\
                    \\- Fast and lightweight
                    \\- Zero configuration required
                    \\- Works out of the box
                    \\
                    \\## Installation
                    \\
                    \\Clone the repository and build it from source:
                    \\
                    \\```sh
                    \\git clone https://example.test/sample-repo.git
                    \\cd sample-repo
                    \\make install
                    \\```
                    \\
                    \\## Usage
                    \\
                    \\Run the program with the `--help` flag to see all available
                    \\options:
                    \\
                    \\```sh
                    \\sample-repo --help
                    \\```
                    \\
                    \\| Option      | Description                    |
                    \\| ----------- | ------------------------------ |
                    \\| `--verbose` | Print extra diagnostic output  |
                    \\| `--quiet`   | Suppress all non-error output  |
                    \\| `--version` | Print the version and exit     |
                    \\
                    \\## Contributing
                    \\
                    \\Contributions are welcome! Please open an issue to discuss
                    \\any significant changes before submitting a pull request.
                    \\See the docs under `docs/dev` for more details.
                    \\
                    \\## License
                    \\
                    \\Released under the MIT License. See `LICENSE` for the full
                    \\text.
                    \\
                );

                try repo_dir.createDirPath(io, "docs/dev");
                const doc = try repo_dir.createFile(io, "docs/dev/contribute.md", .{});
                defer doc.close(io);
                try doc.writeStreamingAll(io, "To contribute, please make a pull request");
            }

            try template_repo.add(io, allocator, &.{ "README.md", "docs/dev/contribute.md" });
            _ = try template_repo.commit(io, allocator, .{ .message = "let there be light" });

            // tag every commit in creation order as v1, v2, and so on
            var tag_num: usize = 1;
            try addNextTag(&template_repo, io, allocator, &tag_num);

            // a batch of commits so the commits tab has more than one page to
            // paginate through. each rewrites a few files with scattered line
            // edits, so every commit is a multi-file diff with several separate
            // hunks to look at. stepped timestamps vary the date column.
            const base_ts: u64 = 1_700_000_000; // 2023-11-14
            const edit_files = [_][]const u8{ "src/alpha.txt", "src/beta.txt", "src/gamma.txt" };
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
            const commit_count = 30;
            var c: usize = 0;
            while (c < commit_count) : (c += 1) {
                {
                    var repo_dir = try cwd.openDir(io, template_path, .{});
                    defer repo_dir.close(io);
                    try repo_dir.createDirPath(io, "src");
                    for (edit_files, 0..) |path, fi| {
                        try writeScatterFile(io, allocator, repo_dir, path, fi, c);
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
                    const word = scatter_words[mw % scatter_words.len];
                    const len = msg_writer.written().len;
                    if (len >= msg_target or len + 1 + word.len > 120) break;
                    try msg_writer.writer.print(" {s}", .{word});
                }
                // the newest commit's message runs past what the detail pane
                // reads, so it shows the truncated message and its link.
                if (c == commit_count - 1) {
                    for (0..ui.detail_preview_lines) |line| {
                        try msg_writer.writer.print("\n{d} {s}", .{ line, scatter_words[line % scatter_words.len] });
                    }
                }
                const message = try arena.allocator().dupe(u8, msg_writer.written());
                _ = try template_repo.commit(io, allocator, .{ .message = message, .timestamp = base_ts + c * std.time.s_per_day });
                try addNextTag(&template_repo, io, allocator, &tag_num);
            }

            // two more branches forked off master, each adding a single commit
            // that makes a scattered edit to one file. tag each new commit too,
            // and switch back to master after each so the next branch also
            // forks from master and the template ends up back on master.
            const branch_data = [_]struct {
                name: []const u8,
                file: []const u8,
                fi: usize,
                message: []const u8,
                rev: usize,
            }{
                .{ .name = "extra", .file = "src/alpha.txt", .fi = 0, .message = "scatter alpha on the extra branch", .rev = 30 },
                .{ .name = "feature", .file = "src/beta.txt", .fi = 1, .message = "scatter beta on the feature branch", .rev = 31 },
            };
            for (branch_data) |b| {
                try template_repo.addBranch(io, .{ .name = b.name });
                {
                    var to_branch = try template_repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = b.name } } });
                    defer to_branch.deinit();
                }

                {
                    var repo_dir = try cwd.openDir(io, template_path, .{});
                    defer repo_dir.close(io);
                    try writeScatterFile(io, allocator, repo_dir, b.file, b.fi, b.rev);
                }
                try template_repo.add(io, allocator, &.{b.file});
                _ = try template_repo.commit(io, allocator, .{ .message = b.message, .timestamp = base_ts + b.rev * std.time.s_per_day });
                try addNextTag(&template_repo, io, allocator, &tag_num);

                {
                    var to_master = try template_repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
                    defer to_master.deinit();
                }
            }

            // the timestamps issue's description, in paragraphs, so the
            // seeded conflict below can insert and delete among them
            const tz_p1 = "All timestamps in the activity feed render in UTC regardless of the system timezone.";
            const tz_p2 = "The tooltip on each entry repeats the same UTC value, so there is no way to see the local time without converting by hand.";
            const tz_p3 = "A quick survey of other clients shows every one of them rendering local time by default.";
            const tz_p4 = "Convert to local time and include the offset in tooltips.";

            // the sync issue's description, in paragraphs, so each side of its
            // seeded conflict can rework a different one
            const sync_p1 = "The sync engine only has unit tests with mocked transports.";
            const sync_p2 = "Failures seen in production involve reconnects and partial writes, which the mocks can't reproduce.";
            const sync_p3 = "Add end-to-end tests that run two instances against a real local server.";

            // seed issues so every repo's issue tracker has content
            const issue_data = [_]struct {
                title: []const u8,
                description: []const u8,
                tags: []const u8,
                status: evt.Issue.Status = .open,
            }{
                .{
                    .title = "Crash on startup when config file is missing",
                    .description = "Running the program without a config file present dereferences a null pointer and segfaults. Fall back to the built-in defaults and log a warning instead.",
                    .tags = "bug priority-high crash",
                },
                .{
                    .title = "Support dark mode in the settings panel",
                    .description = "The settings panel is always rendered with the light palette even when the rest of the app is in dark mode. Read the active theme and pick colors accordingly.",
                    .tags = "enhancement ui theme",
                },
                .{
                    .title = "Memory leak when reconnecting after network failure",
                    .description = "Each reconnect allocates a new connection state without freeing the previous one. After a flaky network session, memory usage grows by several megabytes per hour.",
                    .tags = "bug memory networking",
                    .status = .closed,
                },
                .{
                    .title = "Document the plugin API",
                    .description = "The plugin interface has no documentation beyond the header comments. Add a guide covering the lifecycle hooks, the event callbacks, and a minimal working plugin.",
                    .tags = "documentation plugins",
                },
                .{
                    .title = "Slow file indexing on large directories",
                    .description = "Indexing a directory with more than 100k files takes several minutes because every entry is stat'd twice. Cache the first stat result and batch the reads.",
                    .tags = "performance indexing",
                },
                .{
                    .title = "Add keyboard shortcut for quick search",
                    .description = "Opening the search box currently requires clicking the toolbar icon. Bind a shortcut and show it in the tooltip so keyboard users can search without the mouse.",
                    .tags = "enhancement ux keyboard",
                },
                .{
                    .title = "Unicode filenames are garbled in the export dialog",
                    .description = "Filenames containing non-ASCII characters display as replacement characters in the export dialog. The dialog decodes the path as Latin-1 instead of UTF-8.",
                    .tags = "bug unicode i18n",
                },
                .{
                    .title = "Flaky test: integration suite times out on CI",
                    .description = "The integration suite intermittently exceeds the CI time limit because the server fixture waits for a fixed 30 seconds. Poll for readiness instead of sleeping.",
                    .tags = "bug testing ci",
                },
                .{
                    .title = "Upgrade bundled zlib to the latest release",
                    .description = "The vendored zlib is two major releases behind and misses several upstream fixes. Update the bundled copy and re-run the compression benchmarks.",
                    .tags = "dependencies maintenance",
                },
                .{
                    .title = "Progress bar overshoots 100% during resumed downloads",
                    .description = "Resuming a partial download counts the already-downloaded bytes twice, so the progress bar reads up to 150%. Subtract the resume offset from the total.",
                    .tags = "bug ui downloads",
                    .status = .closed,
                },
                .{
                    .title = "Config parser rejects trailing commas",
                    .description = "A trailing comma after the last entry in a config block is reported as a syntax error. Most editors add one automatically, so accept it.",
                    .tags = "bug config parser",
                },
                .{
                    .title = "Add a --json flag to the status command",
                    .description = "Scripts currently scrape the human-readable status output, which breaks whenever the format changes. Emit a stable machine-readable JSON form behind a flag.",
                    .tags = "enhancement cli",
                },
                .{
                    .title = "Race condition between autosave and manual save",
                    .description = "Saving manually while an autosave is in flight can interleave the two writes and corrupt the file. Serialize saves through a single queue.",
                    .tags = "bug priority-high data-loss",
                },
                .{
                    .title = "Reduce binary size of release builds",
                    .description = "The release binary has grown past 40 MB, mostly from debug info and an unused bundled font. Strip symbols and drop the font from the default build.",
                    .tags = "performance build",
                },
                .{
                    .title = "Tooltips flicker when the cursor moves between adjacent buttons",
                    .description = "Moving the cursor across a toolbar hides and re-shows the tooltip for every button. Keep the tooltip open with a short grace period between neighbors.",
                    .tags = "bug ui polish",
                },
                .{
                    .title = "Support environment variable expansion in config paths",
                    .description = "Paths in the config file are taken literally, so shared configs can't refer to the home directory portably. Expand environment variables when loading.",
                    .tags = "enhancement config",
                },
                .{
                    .title = "Log rotation deletes the newest file instead of the oldest",
                    .description = "When the log directory hits its size cap, the rotation logic sorts by name rather than mtime and removes the most recent log. Sort by modification time.",
                    .tags = "bug logging",
                    .status = .closed,
                },
                .{
                    .title = "Add man pages for all subcommands",
                    .description = "Only the top-level command has a man page. Generate one per subcommand from the existing help text as part of the release build.",
                    .tags = "documentation cli",
                },
                .{
                    .title = "High CPU usage while idle in the background",
                    .description = "The main loop polls for file changes every 10 ms even when no window is visible. Switch to native file watching and idle at zero CPU.",
                    .tags = "performance priority-high",
                },
                .{
                    .title = "Paste from clipboard drops the final newline",
                    .description = "Pasting text that ends with a newline silently trims it, which breaks pasted shell snippets. Preserve the clipboard content exactly.",
                    .tags = "bug editor clipboard",
                },
                .{
                    .title = "Improve error message for expired credentials",
                    .description = "An expired token currently surfaces as a bare 401 with no guidance. Detect the expiry case and tell the user how to re-authenticate.",
                    .tags = "enhancement ux auth",
                },
                .{
                    .title = "Crash when window is resized during startup animation",
                    .description = "Resizing the window while the splash animation is running dereferences a freed layout node. Cancel the animation before rebuilding the layout.",
                    .tags = "bug crash ui",
                },
                .{
                    .title = "Add integration tests for the sync engine",
                    .description = sync_p1 ++ "\n\n" ++ sync_p2 ++ "\n\n" ++ sync_p3,
                    .tags = "testing sync",
                },
                .{
                    .title = "Timestamps display in UTC instead of local time",
                    .description = tz_p1 ++ "\n\n" ++ tz_p2 ++ "\n\n" ++ tz_p3 ++ "\n\n" ++ tz_p4,
                    .tags = "bug i18n time",
                },
                .{
                    .title = "Deprecate the legacy plugin format",
                    .description = "Both plugin formats are currently loaded, doubling the maintenance surface. Warn on legacy plugins this release and drop support in the next.",
                    .tags = "maintenance plugins",
                },
            };

            var issue_events: [issue_data.len]evt.EventWithId = undefined;
            for (issue_data, 0..) |issue, i| {
                // the fifth-newest issue's description runs past what the detail
                // pane shows, so it shows the truncated description and its
                // link.
                const description = if (i == issue_data.len - 5)
                    try longDescription(arena.allocator(), issue.description)
                else
                    issue.description;
                issue_events[i] = .{
                    .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
                    // stepped timestamps so the issues list in a stable order
                    .timestamp = @intCast(i + 1),
                    .author = .{ .name = user_data[i % user_data.len].name, .email = user_data[i % user_data.len].email },
                    .event = .{
                        .issue = .{
                            .title = issue.title,
                            .description = description,
                            .tags = issue.tags,
                            .status = issue.status,
                        },
                    },
                };
            }
            try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &issue_events);
            // the tip is the branch point for the conflicting edits below
            const seed_tip = (try template_repo.readRef(io, evt.events_ref)) orelse unreachable;

            // two divergent edits per conflicted issue: ours on the events
            // branch, theirs on a temp branch rooted at the seed tip, then a
            // merge. the 4th-newest issue conflicts on title and tags; the
            // 3rd-newest on its description with every hunk auto-resolving
            // (each side reworks a different paragraph); the 2nd-newest on
            // its description with a removal conflict (ours removes a
            // paragraph theirs rewords) and an insertion conflict (each side
            // appends a different closing paragraph).
            {
                const other_ref: xit.ref.Ref = .{ .kind = .head, .name = "haxy/other" };
                const title_issue = issue_data[issue_data.len - 4];
                const sync_issue = issue_data[issue_data.len - 3];
                const desc_issue = issue_data[issue_data.len - 2];

                const ours = [_]evt.EventWithId{ .{
                    .id = issue_events[issue_data.len - 4].id,
                    .timestamp = 100,
                    .author = .{ .name = user_data[1].name, .email = user_data[1].email },
                    .event = .{ .issue = .{
                        .title = "Crash when resizing the window during the splash animation",
                        .description = title_issue.description,
                        .tags = "bug crash ui priority-high",
                    } },
                }, .{
                    .id = issue_events[issue_data.len - 3].id,
                    .timestamp = 101,
                    .author = .{ .name = user_data[1].name, .email = user_data[1].email },
                    .event = .{ .issue = .{
                        .title = sync_issue.title,
                        .description = "The sync engine's coverage is unit tests only, with every transport mocked out." ++ "\n\n" ++
                            sync_p2 ++ "\n\n" ++ sync_p3,
                        .tags = sync_issue.tags,
                    } },
                }, .{
                    .id = issue_events[issue_data.len - 2].id,
                    .timestamp = 102,
                    .author = .{ .name = user_data[1].name, .email = user_data[1].email },
                    .event = .{ .issue = .{
                        .title = desc_issue.title,
                        .description = tz_p1 ++ "\n\n" ++ tz_p2 ++ "\n\n" ++ tz_p4 ++ "\n\n" ++
                            "The confusion is worst for teams spread across timezones, who each read a different wall-clock time from the same feed.",
                        .tags = desc_issue.tags,
                    } },
                } };
                const theirs = [_]evt.EventWithId{ .{
                    .id = issue_events[issue_data.len - 4].id,
                    .timestamp = 103,
                    .author = .{ .name = user_data[2].name, .email = user_data[2].email },
                    .event = .{ .issue = .{
                        .title = "Segfault on early window resize",
                        .description = title_issue.description,
                        .tags = "bug crash rendering",
                    } },
                }, .{
                    .id = issue_events[issue_data.len - 3].id,
                    .timestamp = 104,
                    .author = .{ .name = user_data[2].name, .email = user_data[2].email },
                    .event = .{ .issue = .{
                        .title = sync_issue.title,
                        .description = sync_p1 ++ "\n\n" ++ sync_p2 ++ "\n\n" ++
                            "Add end-to-end tests that drive two live instances against a local server on every CI run.",
                        .tags = sync_issue.tags,
                    } },
                }, .{
                    .id = issue_events[issue_data.len - 2].id,
                    .timestamp = 105,
                    .author = .{ .name = user_data[2].name, .email = user_data[2].email },
                    .event = .{ .issue = .{
                        .title = desc_issue.title,
                        .description = tz_p1 ++ "\n\n" ++ tz_p2 ++ "\n\n" ++
                            "Most other clients already render local time by default, which makes our UTC output stand out as a bug." ++ "\n\n" ++ tz_p4 ++ "\n\n" ++
                            "Log exports inherit the same UTC rendering, so downstream tooling has to guess the source timezone.",
                        .tags = desc_issue.tags,
                    } },
                } };

                try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &ours);

                // consume can't root a new branch, so theirs commits by hand
                var json: std.Io.Writer.Allocating = .init(allocator);
                defer json.deinit();
                for (theirs, 0..) |event, i| {
                    json.clearRetainingCapacity();
                    try std.json.Stringify.value(event, .{}, &json.writer);
                    const author = try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ event.author.name, event.author.email });
                    defer allocator.free(author);
                    _ = try template_repo.commitAtRef(io, allocator, .{
                        .author = author,
                        .message = json.written(),
                        .timestamp = event.timestamp,
                        // root the branch at the shared seed tip
                        .parent_oids = if (i == 0) &.{seed_tip} else null,
                    }, null, other_ref);
                }

                {
                    var to_events = try template_repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
                    defer to_events.deinit();
                }
                {
                    var merge = try template_repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_ref }} } } }, null);
                    defer merge.deinit();
                    if (merge.result != .success) return error.MergeFailed;
                }
                {
                    var to_master = try template_repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
                    defer to_master.deinit();
                }
                try template_repo.removeBranch(io, .{ .name = other_ref.name });
            }

            try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &.{});

            // seed a small comment tree on the newest issue
            var comment_ids: [5][evt.event_id_size]u8 = undefined;
            for (&comment_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

            const comment_bodies = [_][]const u8{
                "I can take this. The compatibility scanner already reports which repositories still use the legacy format.",
                "Can we keep loading legacy plugins for one release after the warning lands? That would give downstream maintainers time to migrate.",
                "That sounds good. I'll include the scanner output in the warning so each affected plugin is named.",
                "Please include the replacement manifest path too. That should make the warning actionable without opening the migration guide.",
                "I'll add release-note text once the warning format is settled.",
            };

            var comment_events: [comment_ids.len]evt.EventWithId = undefined;
            for (&comment_events, 0..) |*event, i| {
                event.* = .{
                    .id = std.fmt.bytesToHex(comment_ids[i], .lower),
                    .timestamp = @intCast(200 + i),
                    .author = .{ .name = user_data[(i + 1) % user_data.len].name, .email = user_data[(i + 1) % user_data.len].email },
                    .event = .{ .comment = .{
                        .thread_id = issue_events[issue_events.len - 1].id,
                        .parent_id = switch (i) {
                            0, 1 => issue_events[issue_events.len - 1].id,
                            2, 4 => std.fmt.bytesToHex(comment_ids[0], .lower),
                            3 => std.fmt.bytesToHex(comment_ids[2], .lower),
                            else => unreachable,
                        },
                        .body = comment_bodies[i],
                    } },
                };
            }
            try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &comment_events);

            const discussion_data = [_]struct {
                title: []const u8,
                description: []const u8,
                tags: []const u8,
            }{
                .{
                    .title = "How should plugins declare capabilities?",
                    .description = "I'd like the manifest to make privileged capabilities explicit without making simple plugins verbose.",
                    .tags = "plugins design",
                },
                .{
                    .title = "Ideas for making large repositories faster",
                    .description = "This is a place to collect profiling results and discuss which indexing work is worth pursuing first.",
                    .tags = "performance indexing",
                },
                .{
                    .title = "What should the next release focus on?",
                    .description = "Let's compare the most important reliability fixes with the larger features already in progress.",
                    .tags = "release planning",
                },
                .{
                    .title = "Improving keyboard navigation",
                    .description = "Share workflows that still require a mouse and suggestions for making their focus behavior predictable.",
                    .tags = "ui keyboard accessibility",
                },
                .{
                    .title = "Configuration format discussion",
                    .description = "Should the next configuration format favor strict validation or accept common conveniences such as trailing commas?",
                    .tags = "config design",
                },
            };

            var discussion_events: [discussion_data.len]evt.EventWithId = undefined;
            for (discussion_data, 0..) |discussion, i| {
                discussion_events[i] = .{
                    .id = std.fmt.bytesToHex(evt.EventWithId.randomId(prng.random()), .lower),
                    .timestamp = @intCast(300 + i),
                    .author = .{ .name = user_data[i % user_data.len].name, .email = user_data[i % user_data.len].email },
                    .event = .{ .discuss = .{
                        .title = discussion.title,
                        .description = discussion.description,
                        .tags = discussion.tags,
                    } },
                };
            }
            try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &discussion_events);

            var discussion_comment_ids: [discussion_data.len][3][evt.event_id_size]u8 = undefined;
            for (&discussion_comment_ids) |*ids| {
                for (ids) |*id| id.* = evt.EventWithId.randomId(prng.random());
            }
            var discussion_comment_events: [discussion_data.len * 3]evt.EventWithId = undefined;
            for (&discussion_comment_events, 0..) |*event, i| {
                const discussion_index = i / 3;
                const comment_index = i % 3;
                event.* = .{
                    .id = std.fmt.bytesToHex(discussion_comment_ids[discussion_index][comment_index], .lower),
                    .timestamp = @intCast(400 + i),
                    .author = .{ .name = user_data[(i + 1) % user_data.len].name, .email = user_data[(i + 1) % user_data.len].email },
                    .event = .{ .comment = .{
                        .thread_id = discussion_events[discussion_index].id,
                        .parent_id = if (comment_index < 2)
                            discussion_events[discussion_index].id
                        else
                            std.fmt.bytesToHex(discussion_comment_ids[discussion_index][0], .lower),
                        .body = switch (comment_index) {
                            0 => "My preference is to start with the smallest useful version and expand it after we have real usage to learn from.",
                            1 => "It would help to write down the tradeoffs we are accepting so the decision is easy to revisit later.",
                            2 => "Agreed. A narrow first version should also make it easier to keep the implementation understandable.",
                            else => unreachable,
                        },
                    } },
                };
            }
            try evt.consume(.repo, .xit, .{}, io, allocator, &template_repo, evt.events_ref, &discussion_comment_events);
        }

        // copy the template to each repo's on-disk location, named by its
        // hex-encoded event id. the template repo is deinitialized above, so its
        // db file is fully written before we copy it.
        {
            var template_dir = try cwd.openDir(io, template_path, .{ .iterate = true });
            defer template_dir.close(io);

            for (repo_event_ids, 0..) |id_bytes, repo_index| {
                const repo_id = std.fmt.bytesToHex(id_bytes, .lower);
                const repo_path = try std.fs.path.join(arena.allocator(), &.{ server_path, "repos", &repo_id });
                {
                    var dest_dir = try cwd.createDirPathOpen(io, repo_path, .{});
                    defer dest_dir.close(io);
                    try copyDir(io, template_dir, dest_dir);
                }

                if (repo_index + 1 == repo_data.len) {
                    var target_repo = try rp.Repo(.xit, .{}).open(io, allocator, .{ .path = repo_path, .require_repo_root = true });
                    defer target_repo.deinit(io, allocator);
                    try seedPatches(io, allocator, server_path, &repo, &target_repo, &repo_event_ids[repo_index], &admin_user_id, prng.random());
                }
            }
        }

        break :blk try ui.Session.init(&session_arena, &repo, .{ .user_id = &admin_user_id });
    };
    session.is_terminal = true;
    session.data.git_ssh_prefix = git_ssh_prefix;

    // start the server

    // let the native TUI's page builders open the on-disk repos for the file tree
    session.io = io;
    session.repos_dir = try std.fs.path.join(session_arena.allocator(), &.{ server_path, "repos" });

    // leave a one-shot session for the first browser to hit the web ui, so it
    // starts logged in as admin
    {
        var data_dir = try cwd.createDirPathOpen(io, server_path, .{});
        defer data_dir.close(io);
        const store = try hx.web.SessionStore.init(io, data_dir);
        defer store.deinit();
        const token = try store.create(&admin_user_id);
        try store.offerAutoLogin(&token);
    }

    if (cli) {
        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        const run_opts = hx.main.RunOpts{ .out = &stdout_writer.interface, .err = &stderr_writer.interface };

        const Runnable = struct {
            io: std.Io,
            key_path: []const u8,

            pub fn run(self: @This(), web_port: u16, http_port: ?u16, ssh_port_maybe: ?u16) !void {
                _ = web_port;
                _ = http_port;
                const ssh_port = ssh_port_maybe orelse return error.SshDisabled;
                std.debug.print(
                    \\
                    \\connect to the TUI with:
                    \\  ssh -p {d} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost
                    \\
                    \\create a git repo and push over SSH:
                    \\  mkdir -p temp-try/client/test
                    \\  cd temp-try/client/test
                    \\  git init
                    \\  echo "hello" > hello.txt
                    \\  git add hello.txt
                    \\  git commit -m "let there be light"
                    \\  GIT_SSH_COMMAND='ssh -p {d} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i {s}' git push localhost:admin/test HEAD:master
                    \\
                    \\to quit, press enter.
                    \\
                , .{ ssh_port, ssh_port, self.key_path });
                // portable stdin read via std.Io — equivalent to the
                // std.posix.read(STDIN_FILENO, ...) that doesn't compile
                // on windows.
                var buf: [1]u8 = undefined;
                var stdin_reader = std.Io.File.stdin().reader(self.io, &buf);
                _ = stdin_reader.interface.takeByte() catch {};
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, serve_options, run_opts.err, Runnable{ .io = io, .key_path = key_path });
    } else {
        var null_writer = std.Io.Writer.Discarding.init(&.{});
        const run_opts = hx.main.RunOpts{ .out = &null_writer.writer, .err = &null_writer.writer };

        const Runnable = struct {
            io: std.Io,
            allocator: std.mem.Allocator,
            session: *ui.Session,
            repo: *Repo,

            pub fn run(self: @This(), web_port: u16, http_port: ?u16, ssh_port: ?u16) !void {
                // launch the TUI; the footer points at whatever port was bound
                self.session.web_port = web_port;
                self.session.data.git_http_port = http_port;
                self.session.data.git_ssh_port = ssh_port;
                try hx.ui.run(self.io, self.allocator, self.session, self.repo);
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, serve_options, run_opts.err, Runnable{ .io = io, .allocator = allocator, .session = &session, .repo = &repo });
    }
}

// words cycled through to pad generated lines into prose-like content
const scatter_words = [_][]const u8{
    "lorem",   "ipsum",  "dolor",  "sit",    "amet",   "consectetur",
    "quantum", "vector", "matrix", "buffer", "kernel", "socket",
    "falcon",  "otter",  "badger", "walrus", "ferret", "marmot",
    "scatter", "gather", "encode", "decode", "render", "commit",
};

fn longDescription(allocator: std.mem.Allocator, initial: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try writer.writer.print("{s}", .{initial});
    for (0..ui.detail_preview_lines) |line|
        try writer.writer.print("\n{d} {s}", .{ line, scatter_words[line % scatter_words.len] });
    return writer.toOwnedSlice();
}

// write `path` as 40 lines of mostly-stable filler. revision `c` and file
// index `fi` shift which lines change and the words used, so each (c, fi)
// yields a distinct multi-hunk diff against the previous revision. untouched
// lines stay byte-identical across revisions, so a bump in `c` is a scatter of
// small hunks rather than a full rewrite.
fn writeScatterFile(io: std.Io, allocator: std.mem.Allocator, repo_dir: std.Io.Dir, path: []const u8, fi: usize, c: usize) !void {
    const file = try repo_dir.createFile(io, path, .{});
    defer file.close(io);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    for (0..40) |line| {
        const start = writer.written().len;
        if ((line + fi + c) % 8 == 0) {
            const tag = scatter_words[(line + fi + c * 3) % scatter_words.len];
            try writer.writer.print("rev {d} {s}", .{ c, tag });
        }
        const target = 40 + (line * 17 + fi * 23) % 70;
        var w = line + fi;
        while (true) : (w += 1) {
            const word = scatter_words[w % scatter_words.len];
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

// tag the current HEAD as the next sequential version: v1, v2, and so on
fn addNextTag(repo: *rp.Repo(.xit, .{}), io: std.Io, allocator: std.mem.Allocator, n: *usize) !void {
    var buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "v{d}", .{n.*});
    _ = try repo.addTag(io, allocator, .{ .name = name });
    n.* += 1;
}

fn commitTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(.xit, .{}),
    oid: *const [hash.hexLen(.sha1)]u8,
) ![hash.hexLen(.sha1)]u8 {
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(.xit, .{}).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object = try obj.Object(.xit, .{}).init(state, io, allocator, oid);
    defer object.deinit();
    return switch (object.content) {
        .commit => |commit| commit.tree,
        else => error.InvalidObject,
    };
}

fn seedPatchRevision(
    io: std.Io,
    allocator: std.mem.Allocator,
    repos_path: []const u8,
    patch_id: *const [evt.event_id_size]u8,
    title: []const u8,
    author: evt.CommitAuthor,
    timestamp: u64,
    random: std.Random,
) !void {
    const patch_hex = std.fmt.bytesToHex(patch_id.*, .lower);
    const fork_path = try fork.forkPath(allocator, repos_path, &patch_hex);
    defer allocator.free(fork_path);
    var fork_repo = try rp.Repo(.xit, .{}).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer fork_repo.deinit(io, allocator);

    const base_oid = (try fork_repo.readRef(io, fork.ref)) orelse return error.NotFound;
    const base_tree_oid = try commitTree(io, allocator, &fork_repo, &base_oid);
    var source_oid = base_oid;
    var fork_dir = try std.Io.Dir.cwd().openDir(io, fork_path, .{});
    defer fork_dir.close(io);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    for (0..3) |i| {
        writer.clearRetainingCapacity();
        for (0..i + 1) |line| try writer.writer.print("{s}: part {d}\n", .{ title, line + 1 });
        {
            const file = try fork_dir.createFile(io, "patch.txt", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, writer.written());
        }
        try fork_repo.add(io, allocator, &.{"patch.txt"});
        writer.clearRetainingCapacity();
        try writer.writer.print("{s} ({d}/3)", .{ title, i + 1 });
        source_oid = try fork_repo.commit(io, allocator, .{ .message = writer.written(), .timestamp = timestamp + i });
    }
    const revision_id = evt.EventWithId.randomId(random);
    const head_tree_oid = try commitTree(io, allocator, &fork_repo, &source_oid);
    const revision: evt.PatchRev = .{
        .base_oid = &base_oid,
        .source_oid = &source_oid,
        .message = title,
    };
    const revision_timestamp = timestamp + 3;
    const tree_entries = [_]evt.EventTreeEntry{
        .{ .tree = .{ .name = "base", .oid = &base_tree_oid } },
        .{ .tree = .{ .name = "head", .oid = &head_tree_oid } },
    };
    try evt.consume(.fork, .xit, .{}, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(revision_id, .lower),
        .timestamp = revision_timestamp,
        .author = author,
        .tree_entries = &tree_entries,
        .event = .{ .patchrev = revision },
    }});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moment = try evt.currentMoment(.{}, &fork_repo);
    const revision_record = (try evt.PatchRev.readById(evt.EventDB(.sha1), .sha1, moment, &arena, &revision_id)) orelse return error.NotFound;
    const patch_record = (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, moment, &arena, patch_id)) orelse return error.NotFound;
    var patch = patch_record.event;
    patch.revision = evt.Patch.Revision.fromRecord(revision_id, revision_record);
    try evt.consume(.fork, .xit, .{}, io, allocator, &fork_repo, evt.events_ref, &.{.{
        .id = patch_hex,
        .timestamp = revision_timestamp + 1,
        .author = author,
        .event = .{ .patch = patch },
    }});
}

fn seedPatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    server_path: []const u8,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target_repo: *rp.Repo(.xit, .{}),
    repo_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
    random: std.Random,
) !void {
    const patch_data = [_]struct {
        title: []const u8,
        description: []const u8,
        tags: []const u8,
        status: ?evt.Patch.StatusKind,
    }{
        .{
            .title = "Draft a faster dependency scanner",
            .description = "Rework dependency discovery so a large workspace can be scanned without repeatedly opening the same manifests.",
            .tags = "performance build",
            .status = null,
        },
        .{
            .title = "Remove the legacy configuration loader",
            .description = "Delete the compatibility loader now that the replacement format has shipped and the migration warning has been available for a full release.",
            .tags = "cleanup config",
            .status = .merged,
        },
        .{
            .title = "Cache parsed manifests between commands",
            .description = "Keep parsed manifests in the command context so consecutive operations do not repeat identical filesystem and parsing work.",
            .tags = "performance cache",
            .status = .closed,
        },
        .{
            .title = "Add structured output to the inspect command",
            .description = "Add a stable JSON representation of inspect results for scripts and editor integrations.",
            .tags = "enhancement cli",
            .status = .open,
        },
        .{
            .title = "Preserve file permissions during export",
            .description = "Carry executable bits through archive exports so unpacked command-line tools remain runnable without a manual chmod step.",
            .tags = "bug export permissions",
            .status = .open,
        },
    };

    const repos_path = try std.fs.path.join(allocator, &.{ server_path, "repos" });
    defer allocator.free(repos_path);
    const patch_author = evt.CommitAuthor{ .name = "admin", .email = "admin@example.test" };
    var patch_ids: [patch_data.len][evt.event_id_size]u8 = undefined;
    for (patch_data, 0..) |patch, i| {
        const timestamp: u64 = @intCast(500 + i * 10);
        patch_ids[i] = evt.EventWithId.randomId(random);
        const patch_hex = std.fmt.bytesToHex(patch_ids[i], .lower);
        const path = try fork.create(.{}, io, allocator, repos_path, admin_repo, .{
            .id = patch_hex,
            .user_id = user_id.*,
            .repo_id = repo_id.*,
            .title = patch.title,
            .description = patch.description,
            .tags = patch.tags,
            .target_branch = "master",
            .author = patch_author,
            .timestamp = timestamp,
        });
        allocator.free(path);

        try seedPatchRevision(io, allocator, repos_path, &patch_ids[i], patch.title, patch_author, timestamp + 1, random);
        const status = patch.status orelse continue;
        const fork_path = try fork.forkPath(allocator, repos_path, &patch_hex);
        defer allocator.free(fork_path);
        try pch.publish(.{}, io, allocator, admin_repo, target_repo, fork_path, .{
            .id = patch_hex,
            .user_id = user_id.*,
            .repo_id = repo_id.*,
            .author = patch_author,
            .timestamp = timestamp + 6,
        });

        if (status == .merged) {
            try pch.mergeAndRemoveFork(.{}, io, allocator, repos_path, admin_repo, target_repo, .{
                .id = patch_hex,
                .revision = .source,
                .author = patch_author,
                .timestamp = timestamp + 7,
            });
        } else if (status != .open) {
            try evt.Patch.update(.xit, .{}, io, allocator, target_repo, &patch_ids[i], .{ .status = status }, patch_author);
        }
    }

    // seed a small comment tree on the newest patch
    var comment_ids: [5][evt.event_id_size]u8 = undefined;
    for (&comment_ids) |*id| id.* = evt.EventWithId.randomId(random);
    const comment_bodies = [_][]const u8{
        "This also needs to preserve the executable bit for files nested inside generated directories.",
        "I tested the archive path and the direct-copy path; both currently lose the mode.",
        "The archive writer is the right place to centralize it, since every exporter already goes through that layer.",
        "Please include a regression fixture with a mix of executable and ordinary files.",
        "I'll add that fixture and cover both supported archive formats.",
    };
    var comments: [comment_ids.len]evt.EventWithId = undefined;
    for (&comments, 0..) |*comment, i| {
        comment.* = .{
            .id = std.fmt.bytesToHex(comment_ids[i], .lower),
            .timestamp = @intCast(700 + i),
            .author = .{ .name = if (i % 2 == 0) "alice" else "bob", .email = if (i % 2 == 0) "alice@example.test" else "bob@example.test" },
            .event = .{ .comment = .{
                .thread_id = std.fmt.bytesToHex(patch_ids[patch_ids.len - 1], .lower),
                .parent_id = switch (i) {
                    0, 1 => std.fmt.bytesToHex(patch_ids[patch_ids.len - 1], .lower),
                    2, 4 => std.fmt.bytesToHex(comment_ids[0], .lower),
                    3 => std.fmt.bytesToHex(comment_ids[2], .lower),
                    else => unreachable,
                },
                .body = comment_bodies[i],
            } },
        };
    }
    try evt.consume(.repo, .xit, .{}, io, allocator, target_repo, evt.events_ref, &comments);

    // create divergent metadata edits on the next three patches
    var patch_arena = std.heap.ArenaAllocator.init(allocator);
    defer patch_arena.deinit();
    const moment = try evt.currentMoment(.{}, target_repo);
    var values: [3]evt.Patch = undefined;
    for (1..4) |i| {
        const record = (try evt.Patch.readById(evt.EventDB(.sha1), .sha1, moment, &patch_arena, &patch_ids[i])) orelse return error.NotFound;
        values[i - 1] = record.event;
    }
    var ours_values = values;
    ours_values[0].title = "Drop the legacy configuration loader";
    ours_values[0].tags = "cleanup config breaking";
    const closed_description = try longDescription(
        patch_arena.allocator(),
        "Cache parsed manifests for the lifetime of a command invocation and invalidate entries when their files change.",
    );
    ours_values[1].description = closed_description;
    ours_values[2].description = "Add JSON output to inspect with versioned field names and deterministic object ordering.";
    var theirs_values = values;
    theirs_values[0].title = "Delete compatibility configuration support";
    theirs_values[0].tags = "config maintenance";
    theirs_values[1].description = "Keep a process-wide manifest cache shared by every command and refresh it after writes.";
    theirs_values[2].description = "Expose inspect results as newline-delimited JSON so callers can stream large repositories.";

    const seed_tip = (try target_repo.readRef(io, evt.events_ref)) orelse return error.NotFound;
    const other_ref = xit.ref.Ref{ .kind = .head, .name = "haxy/patch-other" };
    var ours = [_]evt.EventWithId{
        .{
            .id = std.fmt.bytesToHex(patch_ids[1], .lower),
            .timestamp = 800,
            .author = .{ .name = "alice", .email = "alice@example.test" },
            .event = .{ .patch = ours_values[0] },
        },
        .{
            .id = std.fmt.bytesToHex(patch_ids[2], .lower),
            .timestamp = 801,
            .author = .{ .name = "alice", .email = "alice@example.test" },
            .event = .{ .patch = ours_values[1] },
        },
        .{
            .id = std.fmt.bytesToHex(patch_ids[3], .lower),
            .timestamp = 802,
            .author = .{ .name = "alice", .email = "alice@example.test" },
            .event = .{ .patch = ours_values[2] },
        },
    };

    var theirs = ours;
    theirs[0].timestamp = 810;
    theirs[0].author = .{ .name = "bob", .email = "bob@example.test" };
    theirs[0].event.patch = theirs_values[0];
    theirs[1].timestamp = 811;
    theirs[1].author = .{ .name = "bob", .email = "bob@example.test" };
    theirs[1].event.patch = theirs_values[1];
    theirs[2].timestamp = 812;
    theirs[2].author = .{ .name = "bob", .email = "bob@example.test" };
    theirs[2].event.patch = theirs_values[2];

    try evt.consume(.repo, .xit, .{}, io, allocator, target_repo, evt.events_ref, &ours);
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    for (theirs, 0..) |event, i| {
        json.clearRetainingCapacity();
        try std.json.Stringify.value(event, .{}, &json.writer);
        const author = try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ event.author.name, event.author.email });
        defer allocator.free(author);
        _ = try target_repo.commitAtRef(io, allocator, .{
            .author = author,
            .message = json.written(),
            .timestamp = event.timestamp,
            .parent_oids = if (i == 0) &.{seed_tip} else null,
        }, null, other_ref);
    }
    {
        var to_events = try target_repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer to_events.deinit();
    }
    {
        var merge = try target_repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_ref }} } } }, null);
        defer merge.deinit();
        if (merge.result != .success) return error.MergeFailed;
    }
    {
        var to_master = try target_repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
        defer to_master.deinit();
    }
    try target_repo.removeBranch(io, .{ .name = other_ref.name });
    try evt.consume(.repo, .xit, .{}, io, allocator, target_repo, evt.events_ref, &.{});
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

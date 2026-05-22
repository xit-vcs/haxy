const std = @import("std");
const builtin = @import("builtin");
const hx = @import("haxy");
const xit = hx.xit;
const rp = xit.repo;
const rf = xit.ref;
const work = xit.workdir;
const hash = xit.hash;
const net = xit.net;

test "fetch small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testFetch(.xit, .{ .wire = .http }, 3000, io, allocator);
    if (.windows != builtin.os.tag) {
        try testFetch(.xit, .{ .wire = .ssh }, 3001, io, allocator);
    }
}

test "push small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testPush(.xit, .{ .wire = .http }, 3010, io, allocator);
    if (.windows != builtin.os.tag) {
        try testPush(.xit, .{ .wire = .ssh }, 3011, io, allocator);
    }
}

test "push creates missing repo under serve" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testPushCreatesMissingRepo(.xit, .{ .wire = .http }, 3020, io, allocator);
    if (.windows != builtin.os.tag) {
        try testPushCreatesMissingRepo(.xit, .{ .wire = .ssh }, 3021, io, allocator);
    }
}

test "clone small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testClone(.xit, .{ .wire = .http }, 3030, false, io, allocator);
    if (.windows != builtin.os.tag) {
        try testClone(.xit, .{ .wire = .ssh }, 3031, false, io, allocator);
    }
}

test "clone small subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testClone(.git, .{ .wire = .http }, 3040, true, io, allocator);
    if (.windows != builtin.os.tag) {
        try testClone(.git, .{ .wire = .ssh }, 3041, true, io, allocator);
    }
}
test "fetch large subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testFetchLarge(.git, .{ .wire = .http }, 3050, true, io, allocator);
    if (.windows != builtin.os.tag) {
        try testFetchLarge(.git, .{ .wire = .ssh }, 3051, true, io, allocator);
    }
}
test "push large subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testPushLarge(.git, .{ .wire = .http }, 3060, true, io, allocator);
    if (.windows != builtin.os.tag) {
        try testPushLarge(.git, .{ .wire = .ssh }, 3061, true, io, allocator);
    }
}

fn Server(
    comptime transport_def: net.TransportDefinition,
    comptime temp_dir_name: []const u8,
    comptime port: u16,
) type {
    return struct {
        core: Core,

        const Core = switch (transport_def) {
            .file => void,
            .wire => |wire_kind| switch (wire_kind) {
                .http => struct {
                    io: std.Io,
                    allocator: std.mem.Allocator,
                    process: ?std.process.Child,
                },
                .raw => unreachable,
                .ssh => struct {
                    io: std.Io,
                    allocator: std.mem.Allocator,
                    sshd_process: ?std.process.Child,
                    serve_process: ?std.process.Child,
                },
            },
        };

        fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
        ) !Server(transport_def, temp_dir_name, port) {
            switch (transport_def) {
                .file => return .{ .core = {} },
                .wire => |wire_kind| switch (wire_kind) {
                    .http => return .{
                        .core = .{
                            .io = io,
                            .allocator = allocator,
                            .process = null,
                        },
                    },
                    .raw => unreachable,
                    .ssh => {
                        // create priv host key
                        const host_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/host_key", .{});
                        defer host_key_file.close(io);
                        try host_key_file.writeStreamingAll(io,
                            \\-----BEGIN OPENSSH PRIVATE KEY-----
                            \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
                            \\1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQS1ppUfk8n7yvVKEgz3tXjt4q76VGuj
                            \\LcQlRwmogzovV40LLcX0aTObZlQaLWfzJMNpCa/ztMpQlr86nsarE4lEAAAAqLe43zK3uN
                            \\8yAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLWmlR+TyfvK9UoS
                            \\DPe1eO3irvpUa6MtxCVHCaiDOi9XjQstxfRpM5tmVBotZ/Mkw2kJr/O0ylCWvzqexqsTiU
                            \\QAAAAgQ+LCk30ZNJxb2Da5JL+QOFWCMf7bgXCWcEzhEGGvFWYAAAALcmFkYXJAcm9hcmsB
                            \\AgMEBQ==
                            \\-----END OPENSSH PRIVATE KEY-----
                            \\
                        );
                        if (.windows != builtin.os.tag) {
                            try host_key_file.setPermissions(io, @enumFromInt(0o600));
                        }

                        // create priv client key
                        const priv_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/key", .{});
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

                        // create pub key
                        const pub_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/key.pub", .{});
                        defer pub_key_file.close(io);
                        try pub_key_file.writeStreamingAll(io,
                            \\ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark
                            \\
                        );
                        if (.windows != builtin.os.tag) {
                            try pub_key_file.setPermissions(io, @enumFromInt(0o600));
                        }

                        // create authorized_keys file
                        const auth_keys_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/authorized_keys", .{});
                        defer auth_keys_file.close(io);
                        try auth_keys_file.writeStreamingAll(io,
                            \\ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark
                            \\
                        );
                        if (.windows != builtin.os.tag) {
                            try auth_keys_file.setPermissions(io, @enumFromInt(0o600));
                        }

                        // create known_hosts file
                        const known_hosts_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/known_hosts", .{});
                        defer known_hosts_file.close(io);
                        const port_str = std.fmt.comptimePrint("{}", .{port});
                        try known_hosts_file.writeStreamingAll(io, "[localhost]:" ++ port_str ++ " ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLWmlR+TyfvK9UoSDPe1eO3irvpUa6MtxCVHCaiDOi9XjQstxfRpM5tmVBotZ/Mkw2kJr/O0ylCWvzqexqsTiUQ=");
                        if (.windows != builtin.os.tag) {
                            try known_hosts_file.setPermissions(io, @enumFromInt(0o600));
                        }

                        // create sshd_config file
                        const sshd_config_str = blk: {
                            // SetEnv PATH=... allows us to propagate the test process's PATH
                            // to the spawned login shell (in sshd).
                            //
                            // without it, shells that don't auto-resource PATH on startup (e.g. nushell
                            // on NixOS) through /etc/set-environment will fail to find
                            // git-upload-pack / git-receive-pack.
                            const base_config =
                                \\AuthenticationMethods publickey
                                \\PubkeyAuthentication yes
                                \\PasswordAuthentication no
                                \\StrictModes no
                                //SetEnv PATH={s} -- if we find $PATH defined.
                            ;
                            var env_map = try std.process.Environ.createMap(std.testing.io_instance.environ.process_environ, allocator);
                            defer env_map.deinit();

                            const config_str = if (env_map.get("PATH")) |path_str|
                                try std.fmt.allocPrint(allocator, "{s}\n" ++ "SetEnv PATH={s}\n", .{ base_config, path_str })
                            else
                                try std.fmt.allocPrint(allocator, "{s}", .{base_config});

                            break :blk config_str;
                        };
                        defer allocator.free(sshd_config_str);

                        const sshd_config_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/sshd_config", .{});
                        defer sshd_config_file.close(io);
                        try sshd_config_file.writeStreamingAll(io, sshd_config_str);
                        if (.windows != builtin.os.tag) {
                            try sshd_config_file.setPermissions(io, @enumFromInt(0o600));
                        }

                        // create sshd.sh contents
                        const cwd_path = try std.process.currentPathAlloc(io, allocator);
                        defer allocator.free(cwd_path);
                        const host_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "host_key" });
                        defer allocator.free(host_key_path);
                        const auth_keys_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "authorized_keys" });
                        defer allocator.free(auth_keys_path);
                        const sshd_contents = try std.fmt.allocPrint(
                            allocator,
                            "#!/bin/sh\nexec $(which sshd) -p {} -f sshd_config -h \"{s}\" -D -e -o AuthorizedKeysFile=\"{s}\"",
                            .{ port, host_key_path, auth_keys_path },
                        );
                        defer allocator.free(sshd_contents);

                        // if path has a space char, it fucks up sshd
                        try std.testing.expect(null == std.mem.indexOfScalar(u8, auth_keys_path, ' '));

                        // create sshd.sh
                        {
                            const sshd_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/sshd.sh", .{});
                            defer sshd_file.close(io);
                            try sshd_file.writeStreamingAll(io, sshd_contents);
                            if (.windows != builtin.os.tag) {
                                try sshd_file.setPermissions(io, .executable_file);
                            }
                        }
                        return .{
                            .core = .{
                                .io = io,
                                .allocator = allocator,
                                .sshd_process = null,
                                .serve_process = null,
                            },
                        };
                    },
                },
            }
        }

        fn start(self: *Server(transport_def, temp_dir_name, port)) !void {
            switch (transport_def) {
                .file => {},
                .wire => |wire_kind| switch (wire_kind) {
                    .http => {
                        std.debug.assert(self.core.process == null);

                        const cwd_path = try std.process.currentPathAlloc(self.core.io, self.core.allocator);
                        defer self.core.allocator.free(cwd_path);
                        const haxy_path = try std.fs.path.join(self.core.allocator, &.{ cwd_path, "zig-out/bin/haxy" });
                        defer self.core.allocator.free(haxy_path);
                        const listen_arg = std.fmt.comptimePrint("127.0.0.1:{}", .{port});

                        self.core.process = try std.process.spawn(self.core.io, .{
                            .argv = &.{ haxy_path, "serve", "--http-listen", listen_arg, "--data-dir", temp_dir_name },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        });
                    },
                    .raw => unreachable,
                    .ssh => {
                        std.debug.assert(self.core.sshd_process == null);
                        std.debug.assert(self.core.serve_process == null);

                        const cwd_path = try std.process.currentPathAlloc(self.core.io, self.core.allocator);
                        defer self.core.allocator.free(cwd_path);
                        const haxy_path = try std.fs.path.join(self.core.allocator, &.{ cwd_path, "zig-out/bin/haxy" });
                        defer self.core.allocator.free(haxy_path);
                        const ssh_listen_arg = std.fmt.comptimePrint("127.0.0.1:{}", .{port + 1000});
                        const http_listen_arg = std.fmt.comptimePrint("127.0.0.1:{}", .{port + 2000});

                        self.core.serve_process = try std.process.spawn(self.core.io, .{
                            .argv = &.{ haxy_path, "serve", "--http-listen", http_listen_arg, "--ssh-listen", ssh_listen_arg, "--data-dir", temp_dir_name },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        });

                        const serve_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port + 1000);
                        for (0..50) |_| {
                            const stream = serve_address.connect(self.core.io, .{ .mode = .stream }) catch {
                                try std.Io.sleep(self.core.io, .fromMilliseconds(100), .real);
                                continue;
                            };
                            var probe_buf = [_]u8{0} ** 16;
                            var probe_writer = stream.writer(self.core.io, &probe_buf);
                            try probe_writer.interface.writeAll("probe\n");
                            try probe_writer.interface.flush();
                            stream.close(self.core.io);
                            break;
                        }

                        self.core.sshd_process = try std.process.spawn(self.core.io, .{
                            .argv = &.{"./sshd.sh"},
                            .cwd = .{ .path = temp_dir_name },
                            .stdin = .pipe,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        });
                    },
                },
            }

            if (transport_def == .wire) {
                const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
                for (0..50) |_| {
                    const stream = address.connect(self.core.io, .{ .mode = .stream }) catch {
                        try std.Io.sleep(self.core.io, .fromMilliseconds(100), .real);
                        continue;
                    };
                    stream.close(self.core.io);
                    break;
                }
            }
        }

        fn stop(self: *Server(transport_def, temp_dir_name, port)) void {
            switch (transport_def) {
                .file => {},
                .wire => |wire_kind| switch (wire_kind) {
                    .http => if (self.core.process) |*process| {
                        _ = process.kill(self.core.io);
                        self.core.process = null;
                    },
                    .raw => unreachable,
                    .ssh => {
                        if (self.core.sshd_process) |*process| {
                            _ = process.kill(self.core.io);
                            self.core.sshd_process = null;
                        }
                        if (self.core.serve_process) |*process| {
                            _ = process.kill(self.core.io);
                            self.core.serve_process = null;
                        }
                    },
                },
            }
        }
    };
}

fn uploadPackCommand(
    comptime is_ssh: bool,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    comptime port: u16,
) ![]const u8 {
    return if (is_ssh)
        std.fmt.allocPrint(allocator, "{s}/zig-out/bin/haxy ssh-git --ssh-connect 127.0.0.1:{} --service upload-pack", .{ cwd_path, port + 1000 })
    else
        allocator.dupe(u8, "git-upload-pack");
}

fn receivePackCommand(
    comptime is_ssh: bool,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    comptime port: u16,
) ![]const u8 {
    return if (is_ssh)
        std.fmt.allocPrint(allocator, "{s}/zig-out/bin/haxy ssh-git --ssh-connect 127.0.0.1:{} --service receive-pack", .{ cwd_path, port + 1000 })
    else
        allocator.dupe(u8, "git-receive-pack");
}

fn testFetch(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-fetch";

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

    // init server
    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    // make a commit
    const commit1 = blk: {
        const hello_txt = try server_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");
        try server_repo.add(io, allocator, &.{"hello.txt"});
        break :blk try server_repo.commit(io, allocator, .{ .message = "let there be light" });
    };

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);

        try server_repo.addConfig(io, allocator, .{ .name = "uploadpack.allowAnySHA1InWant", .value = "true" });
    }

    // add a tag
    _ = try server_repo.addTag(io, allocator, .{ .name = "1.0.0", .message = "hi" });

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    // add remote
    {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        const remote_url = switch (transport_def) {
            //.file => try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ separator, server_path }),
            .file => try std.fmt.allocPrint(allocator, "../server", .{}), // relative file paths work too
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/server", .{port}),
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    // create refspec with oid as a test
    const oid_refspec = try std.fmt.allocPrint(allocator, "+{s}:refs/heads/foo", .{&commit1});
    defer allocator.free(oid_refspec);

    const refspecs = &.{
        "+refs/heads/master:refs/heads/master",
        oid_refspec,
    };

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };
    const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
        const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
        defer allocator.free(known_hosts_path);

        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);

        break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
    } else null;
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    const upload_pack_command = try uploadPackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(upload_pack_command);

    try client_repo.fetch(
        io,
        allocator,
        "origin",
        .{ .refspecs = refspecs, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .upload_pack_command = upload_pack_command,
        } } },
    );

    // update the working dir
    try client_repo.restore(io, allocator, ".");

    // make sure fetch was successful
    {
        const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
        defer hello_txt.close(io);

        try std.testing.expect(null != try client_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));
        try std.testing.expect(null != try client_repo.readRef(io, .{ .kind = .head, .name = "foo" }));

        const oid_master = (try client_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit1, &oid_master);
    }

    // make another commit
    const commit2 = blk: {
        const goodbye_txt = try server_repo.core.work_dir.createFile(io, "goodbye.txt", .{ .truncate = true });
        defer goodbye_txt.close(io);
        try goodbye_txt.writeStreamingAll(io, "goodbye, world!");
        try server_repo.add(io, allocator, &.{"goodbye.txt"});
        break :blk try server_repo.commit(io, allocator, .{ .message = "goodbye" });
    };

    try client_repo.fetch(
        io,
        allocator,
        "origin",
        .{ .refspecs = refspecs, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .upload_pack_command = upload_pack_command,
        } } },
    );

    // update the working dir
    try client_repo.restore(io, allocator, ".");

    // make sure fetch was successful
    {
        const goodbye_txt = try temp_dir.openFile(io, "client/goodbye.txt", .{});
        defer goodbye_txt.close(io);

        const oid_master = (try client_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit2, &oid_master);
    }
}

fn testPush(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-push";

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

    // init server
    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    // add config
    switch (transport_def) {
        .file => try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "true" }),
        .wire => {
            try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
            try server_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
        },
    }
    try server_repo.addConfig(io, allocator, .{ .name = "http.receivepack", .value = "true" });

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);
    }

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    // make a commit
    const commit1 = blk: {
        const hello_txt = try client_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");
        try client_repo.add(io, allocator, &.{"hello.txt"});
        break :blk try client_repo.commit(io, allocator, .{ .message = "let there be light" });
    };

    // add a tag
    _ = try client_repo.addTag(io, allocator, .{ .name = "1.0.0", .message = "hi" });

    // add remote
    {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        const remote_url = switch (transport_def) {
            //.file => try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ separator, server_path }),
            .file => try std.fmt.allocPrint(allocator, "../server", .{}), // relative file paths work too
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/server", .{port}),
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const refspecs = &.{
        "refs/tags/1.0.0:refs/tags/1.0.0",
    };

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };
    const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
        const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
        defer allocator.free(known_hosts_path);

        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);

        break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
    } else null;
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    const upload_pack_command = try uploadPackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(upload_pack_command);
    const receive_pack_command = try receivePackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(receive_pack_command);

    try client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .refspecs = refspecs, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    );

    // make sure push was successful
    {
        try std.testing.expect(null != try server_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));

        const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit1, &oid_master);
    }

    // make a commit on the server
    {
        const hello_txt = try server_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world from the server!");
        try server_repo.add(io, allocator, &.{"hello.txt"});
        _ = try server_repo.commit(io, allocator, .{ .message = "new commit from the server" });
    }

    // make another commit
    const commit2 = blk: {
        const goodbye_txt = try client_repo.core.work_dir.createFile(io, "goodbye.txt", .{ .truncate = true });
        defer goodbye_txt.close(io);
        try goodbye_txt.writeStreamingAll(io, "goodbye, world!");
        try client_repo.add(io, allocator, &.{"goodbye.txt"});
        break :blk try client_repo.commit(io, allocator, .{ .message = "goodbye" });
    };

    // can't push because server has commit not found locally
    try std.testing.expectError(error.RemoteRefContainsCommitsNotFoundLocally, client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    ));

    // make a commit on the server with no parents, thus creating an incompatible git history
    {
        const hello_txt = try server_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world from the server again!");
        try server_repo.add(io, allocator, &.{"hello.txt"});
        _ = try server_repo.commit(io, allocator, .{ .message = "new git history on the server", .parent_oids = &.{} });
    }

    // can't push because commit doesn't exist locally
    try std.testing.expectError(error.RemoteRefContainsCommitsNotFoundLocally, client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    ));

    // retrieve the commit object
    try client_repo.fetch(
        io,
        allocator,
        "origin",
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .upload_pack_command = upload_pack_command,
        } } },
    );

    // can't push because server's history is incompatible
    try std.testing.expectError(error.RemoteRefContainsIncompatibleHistory, client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    ));

    // test denyNonFastForwards (only for wire transports, file transport bypasses receive-pack)
    switch (transport_def) {
        .file => {},
        .wire => {
            // set denyNonFastForwards on server
            try server_repo.addConfig(io, allocator, .{ .name = "receive.denynonfastforwards", .value = "true" });

            // save the server's current master ref
            const oid_before_denied_push = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;

            // force push should be rejected by server due to denyNonFastForwards
            try client_repo.push(
                io,
                allocator,
                "origin",
                "master",
                true,
                .{ .wire = .{ .ssh = .{
                    .command = ssh_cmd_maybe,
                    .receive_pack_command = receive_pack_command,
                } } },
            );

            // verify the server ref was not updated (push was denied)
            {
                const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
                try std.testing.expectEqualStrings(&oid_before_denied_push, &oid_master);
            }

            // remove denyNonFastForwards from server
            try server_repo.removeConfig(io, allocator, .{ .name = "receive.denynonfastforwards" });
        },
    }

    // force push
    try client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        true,
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    );

    // make sure push was successful
    {
        const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit2, &oid_master);
    }

    // remove the remote tag
    try client_repo.push(
        io,
        allocator,
        "origin",
        ":refs/tags/1.0.0",
        false,
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    );

    // make sure push was successful
    try std.testing.expect(null == try server_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));
}

fn testPushCreatesMissingRepo(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-push-create";

    const cwd = std.Io.Dir.cwd();
    var temp_dir_or_err = cwd.openDir(io, temp_dir_name, .{});
    if (temp_dir_or_err) |*temp_dir| {
        temp_dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    const commit1 = blk: {
        const hello_txt = try client_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");
        try client_repo.add(io, allocator, &.{"hello.txt"});
        break :blk try client_repo.commit(io, allocator, .{ .message = "let there be light" });
    };

    _ = try client_repo.addTag(io, allocator, .{ .name = "1.0.0", .message = "hi" });

    {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        const remote_url = switch (transport_def) {
            .file => unreachable,
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => unreachable,
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };
    const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
        const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
        defer allocator.free(known_hosts_path);

        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);

        break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
    } else null;
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    const receive_pack_command = try receivePackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(receive_pack_command);

    try client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .refspecs = &.{"refs/tags/1.0.0:refs/tags/1.0.0"}, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
            .receive_pack_command = receive_pack_command,
        } } },
    );

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).open(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    try std.testing.expect(null != try server_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));

    const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
    try std.testing.expectEqualStrings(&commit1, &oid_master);
}

fn testClone(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    comptime shell_out_to_git: bool,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-clone";

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

    // init server
    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const temp_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(temp_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    // init server repo with default branch name as main
    // is_test must be false when shell_out_to_git so commits get real timestamps (needed for --shallow-since)
    var server_repo = try rp.Repo(.xit, .{ .is_test = !shell_out_to_git }).init(io, allocator, .{ .path = server_path, .create_default_branch = "main" });
    defer server_repo.deinit(io, allocator);

    if (shell_out_to_git) {
        try server_repo.addConfig(io, allocator, .{ .name = "user.name", .value = "test" });
        try server_repo.addConfig(io, allocator, .{ .name = "user.email", .value = "test@test" });
        try server_repo.addConfig(io, allocator, .{ .name = "uploadpack.allowfilter", .value = "true" });
    }

    // make a commit
    {
        const hello_txt = try server_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");
        try server_repo.add(io, allocator, &.{"hello.txt"});
        _ = try server_repo.commit(io, allocator, .{ .message = "let there be light" });
    }

    // tag first commit
    _ = try server_repo.addTag(io, allocator, .{ .name = "v1", .message = "first" });

    // make a commit
    {
        const goodbye_txt = try server_repo.core.work_dir.createFile(io, "goodbye.txt", .{ .truncate = true });
        defer goodbye_txt.close(io);
        try goodbye_txt.writeStreamingAll(io, "goodbye, world!");
        try server_repo.add(io, allocator, &.{"goodbye.txt"});
        _ = try server_repo.commit(io, allocator, .{ .message = "add goodbye file" });
    }

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);
    }

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    // get remote url
    const remote_url = blk: {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        break :blk switch (transport_def) {
            //.file => try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ separator, server_path }),
            .file => try std.fmt.allocPrint(allocator, "server", .{}), // relative file paths work too
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/server", .{port}),
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
    };
    defer allocator.free(remote_url);

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    const upload_pack_command = try uploadPackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(upload_pack_command);

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -o StrictHostKeyChecking=no -o IdentityFile={s}", .{priv_key_path});
        defer allocator.free(ssh_config_arg);

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--upload-pack", upload_pack_command, "--depth", "1", remote_url, "client" }
                else
                    &.{ "git", "clone", "--depth", "1", remote_url, "client" },
                .cwd = .{ .path = temp_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure shallow clone was successful
        {
            const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
            hello_txt.close(io);
        }

        // make a third commit on the server
        {
            const extra_txt = try server_repo.core.work_dir.createFile(io, "extra.txt", .{ .truncate = true });
            defer extra_txt.close(io);
            try extra_txt.writeStreamingAll(io, "extra content");
            try server_repo.add(io, allocator, &.{"extra.txt"});
            _ = try server_repo.commit(io, allocator, .{ .message = "add extra file" });
        }

        // pull --unshallow to deepen the clone and get the new commit
        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "pull", "--upload-pack", upload_pack_command, "--unshallow" }
                else
                    &.{ "git", "pull", "--unshallow" },
                .cwd = .{ .path = client_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure unshallow pull was successful
        {
            const extra_txt = try temp_dir.openFile(io, "client/extra.txt", .{});
            extra_txt.close(io);
        }

        // delete client and clone again with --shallow-since
        try cwd.deleteTree(io, temp_dir_name ++ "/client");

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--upload-pack", upload_pack_command, "--shallow-since=2000-01-01", remote_url, "client" }
                else
                    &.{ "git", "clone", "--shallow-since=2000-01-01", remote_url, "client" },
                .cwd = .{ .path = temp_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure shallow clone was successful
        {
            const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
            hello_txt.close(io);
        }

        // delete client and clone again with --shallow-exclude
        try cwd.deleteTree(io, temp_dir_name ++ "/client");

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--upload-pack", upload_pack_command, "--shallow-exclude=v1", remote_url, "client" }
                else
                    &.{ "git", "clone", "--shallow-exclude=v1", remote_url, "client" },
                .cwd = .{ .path = temp_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure shallow clone was successful
        {
            const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
            hello_txt.close(io);
        }

        // delete client and clone again with --filter=blob:none
        try cwd.deleteTree(io, temp_dir_name ++ "/client");

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--upload-pack", upload_pack_command, "--filter=blob:none", remote_url, "client" }
                else
                    &.{ "git", "clone", "--filter=blob:none", remote_url, "client" },
                .cwd = .{ .path = temp_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure partial clone was successful
        {
            const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
            hello_txt.close(io);
        }

        // delete client and clone again with --filter=tree:0
        try cwd.deleteTree(io, temp_dir_name ++ "/client");

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--upload-pack", upload_pack_command, "--filter=tree:0", remote_url, "client" }
                else
                    &.{ "git", "clone", "--filter=tree:0", remote_url, "client" },
                .cwd = .{ .path = temp_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure treeless clone was successful
        {
            const goodbye_txt = try temp_dir.openFile(io, "client/goodbye.txt", .{});
            goodbye_txt.close(io);
        }
    } else {
        const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
            const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
            defer allocator.free(known_hosts_path);

            const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
            defer allocator.free(priv_key_path);

            break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
        } else null;
        defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

        // clone repo
        var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).clone(
            io,
            allocator,
            remote_url,
            temp_path,
            client_path,
            .{ .wire = .{ .ssh = .{
                .command = ssh_cmd_maybe,
                .upload_pack_command = upload_pack_command,
            } } },
        );
        defer client_repo.deinit(io, allocator);

        // make sure HEAD points to the right default branch
        var current_branch_buffer = [_]u8{0} ** rf.MAX_REF_CONTENT_SIZE;
        const head = try client_repo.head(io, &current_branch_buffer);
        try std.testing.expectEqualStrings("main", head.ref.name);

        // make sure clone was successful
        const hello_txt = try temp_dir.openFile(io, "client/hello.txt", .{});
        defer hello_txt.close(io);
    }
}

fn testFetchLarge(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    comptime shell_out_to_git: bool,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-fetch-large";

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

    // init server
    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    var server_dir = try cwd.openDir(io, server_path, .{});
    defer server_dir.close(io);

    // copy files from current repo into server dir
    for (&[_][]const u8{"src"}) |dir_name| {
        var src_repo_dir = try cwd.openDir(io, dir_name, .{ .iterate = true });
        defer src_repo_dir.close(io);

        var dest_repo_dir = try server_dir.createDirPathOpen(io, dir_name, .{});
        defer dest_repo_dir.close(io);

        try copyDir(io, src_repo_dir, dest_repo_dir);

        try server_repo.add(io, allocator, &.{dir_name});
    }

    // make a commit
    const commit1 = try server_repo.commit(io, allocator, .{ .message = "let there be light" });

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);
    }

    if (shell_out_to_git) {
        try server_repo.addConfig(io, allocator, .{ .name = "uploadpack.allowrefinwant", .value = "true" });
    }

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    // add remote
    {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        const remote_url = switch (transport_def) {
            //.file => try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ separator, server_path }),
            .file => try std.fmt.allocPrint(allocator, "../server", .{}), // relative file paths work too
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/server", .{port}),
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    const upload_pack_command = try uploadPackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(upload_pack_command);

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -o StrictHostKeyChecking=no -o IdentityFile={s}", .{priv_key_path});
        defer allocator.free(ssh_config_arg);

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "pull", "--upload-pack", upload_pack_command, "origin", "master" }
                else
                    &.{ "git", "pull", "origin", "master" },
                .cwd = .{ .path = client_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure pull was successful
        {
            const oid_master = (try client_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
            try std.testing.expectEqualStrings(&commit1, &oid_master);
        }

        // make another commit on the server
        const commit2 = blk: {
            const extra_txt = try server_repo.core.work_dir.createFile(io, "extra.txt", .{ .truncate = true });
            defer extra_txt.close(io);
            try extra_txt.writeStreamingAll(io, "extra content");
            try server_repo.add(io, allocator, &.{"extra.txt"});
            break :blk try server_repo.commit(io, allocator, .{ .message = "add extra file" });
        };

        // fetch with ref-in-want (git uses want-ref in protocol v2 when fetching named refs)
        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "fetch", "--upload-pack", upload_pack_command, "origin", "master" }
                else
                    &.{ "git", "fetch", "origin", "master" },
                .cwd = .{ .path = client_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try process.wait(io);
            if (term != .exited or term.exited != 0) {
                return error.GitCommandFailed;
            }
        }

        // make sure fetch with want-ref was successful
        {
            const oid_remote_master = (try client_repo.readRef(io, .{ .kind = .{ .remote = "origin" }, .name = "master" })).?;
            try std.testing.expectEqualStrings(&commit2, &oid_remote_master);
        }
    } else {
        const refspecs = &.{
            "+refs/heads/master:refs/heads/master",
        };

        const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
            const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
            defer allocator.free(known_hosts_path);

            const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
            defer allocator.free(priv_key_path);

            break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
        } else null;
        defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

        try client_repo.fetch(
            io,
            allocator,
            "origin",
            .{ .refspecs = refspecs, .wire = .{ .ssh = .{
                .command = ssh_cmd_maybe,
                .upload_pack_command = upload_pack_command,
            } } },
        );

        // update the working dir
        try client_repo.restore(io, allocator, ".");
    }

    // make sure fetch was successful
    {
        const oid_master = (try client_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit1, &oid_master);
    }
}

fn testPushLarge(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
    comptime port: u16,
    comptime shell_out_to_git: bool,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const temp_dir_name = "temp-testnet-push-large";

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

    // init server
    var server = try Server(transport_def, temp_dir_name, port).init(io, allocator);
    try server.start();
    defer server.stop();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "repos", "server" });
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    // add config
    switch (transport_def) {
        .file => try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "true" }),
        .wire => {
            try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
            try server_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
        },
    }
    try server_repo.addConfig(io, allocator, .{ .name = "http.receivepack", .value = "true" });

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);
    }

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    var client_dir = try cwd.openDir(io, client_path, .{});
    defer client_dir.close(io);

    {
        const hello_txt = try client_repo.core.work_dir.createFile(io, "hello.txt", .{ .truncate = true });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");
        try client_repo.add(io, allocator, &.{"hello.txt"});
    }

    // copy files from current repo into client dir
    for (&[_][]const u8{"src"}) |dir_name| {
        var src_repo_dir = try cwd.openDir(io, dir_name, .{ .iterate = true });
        defer src_repo_dir.close(io);

        var dest_repo_dir = try client_dir.createDirPathOpen(io, dir_name, .{});
        defer dest_repo_dir.close(io);

        try copyDir(io, src_repo_dir, dest_repo_dir);

        try client_repo.add(io, allocator, &.{dir_name});
    }

    _ = try client_repo.commit(io, allocator, .{ .message = "let there be light" });

    // change the files so git will send them as delta objects
    for (&[_][]const u8{"src"}) |dir_name| {
        var dest_repo_dir = try client_dir.createDirPathOpen(io, dir_name, .{ .open_options = .{ .iterate = true } });
        defer dest_repo_dir.close(io);

        {
            var iter = dest_repo_dir.iterate();
            while (try iter.next(io)) |entry| {
                switch (entry.kind) {
                    .file => {
                        const file = try dest_repo_dir.openFile(io, entry.name, .{ .mode = .read_write });
                        defer file.close(io);
                        var writer = file.writer(io, &.{});
                        try writer.interface.writeAll("EDIT");
                    },
                    else => {},
                }
            }
        }

        try client_repo.add(io, allocator, &.{dir_name});
    }

    const commit2 = try client_repo.commit(io, allocator, .{ .message = "more stuff" });

    // add remote
    {
        if (.windows == builtin.os.tag) {
            std.mem.replaceScalar(u8, server_path, '\\', '/');
        }
        const separator = if (server_path[0] == '/') "" else "/";

        const remote_url = switch (transport_def) {
            //.file => try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ separator, server_path }),
            .file => try std.fmt.allocPrint(allocator, "../server", .{}), // relative file paths work too
            .wire => |wire_kind| switch (wire_kind) {
                .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/server", .{port}),
                .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/server", .{port}),
                .ssh => try std.fmt.allocPrint(allocator, "ssh://localhost:{}{s}{s}", .{ port, separator, server_path }),
            },
        };
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    const receive_pack_command = try receivePackCommand(is_ssh, allocator, cwd_path, port);
    defer allocator.free(receive_pack_command);

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -o StrictHostKeyChecking=no -o IdentityFile={s}", .{priv_key_path});
        defer allocator.free(ssh_config_arg);

        // shell out to git so it will send delta objects
        var process = try std.process.spawn(io, .{
            .argv = if (is_ssh)
                &.{ "git", "-c", ssh_config_arg, "push", "--receive-pack", receive_pack_command, "origin", "master" }
            else
                &.{ "git", "push", "origin", "master" },
            .cwd = .{ .path = client_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try process.wait(io);
        if (term != .exited or term.exited != 0) {
            return error.GitCommandFailed;
        }
    } else {
        const ssh_cmd_maybe: ?[]const u8 = if (is_ssh) blk: {
            const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
            defer allocator.free(known_hosts_path);

            const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
            defer allocator.free(priv_key_path);

            break :blk try std.fmt.allocPrint(allocator, "ssh -o UserKnownHostsFile=\"{s}\" -o IdentityFile=\"{s}\"", .{ known_hosts_path, priv_key_path });
        } else null;
        defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

        try client_repo.push(
            io,
            allocator,
            "origin",
            "master",
            false,
            .{ .wire = .{ .ssh = .{
                .command = ssh_cmd_maybe,
                .receive_pack_command = receive_pack_command,
            } } },
        );

        if (transport_def == .file) {
            // update the working dir
            try server_repo.restore(io, allocator, ".");
        }
    }

    // make sure push was successful
    {
        const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit2, &oid_master);

        const hello_txt = try temp_dir.openFile(io, "repos/server/hello.txt", .{});
        defer hello_txt.close(io);
    }
}

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

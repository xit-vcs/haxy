const std = @import("std");
const builtin = @import("builtin");
const hx = @import("haxy");
const xit = hx.xit;
const evt = hx.event;
const rp = xit.repo;
const rf = xit.ref;
const work = xit.workdir;
const hash = xit.hash;
const net = xit.net;

const http_port: u16 = 3000;
const ssh_port: u16 = 3001;

test "fetch small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testFetch(.xit, .{ .wire = .http }, io, allocator);
    if (.windows != builtin.os.tag) {
        try testFetch(.xit, .{ .wire = .ssh }, io, allocator);
    }
}

test "push small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    if (.windows != builtin.os.tag) {
        try testPush(.xit, .{ .wire = .ssh }, io, allocator);
    }
}

test "push creates missing repo under serve" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    if (.windows != builtin.os.tag) {
        try testPushCreatesMissingRepo(.xit, .{ .wire = .ssh }, io, allocator);
    }
}

test "clone small" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testClone(.xit, .{ .wire = .http }, false, io, allocator);
    if (.windows != builtin.os.tag) {
        try testClone(.xit, .{ .wire = .ssh }, false, io, allocator);
    }
}

test "clone small subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testClone(.git, .{ .wire = .http }, true, io, allocator);
    if (.windows != builtin.os.tag) {
        try testClone(.git, .{ .wire = .ssh }, true, io, allocator);
    }
}

test "fetch large subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try testFetchLarge(.git, .{ .wire = .http }, true, io, allocator);
    if (.windows != builtin.os.tag) {
        try testFetchLarge(.git, .{ .wire = .ssh }, true, io, allocator);
    }
}

test "push large subprocess" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    if (.windows != builtin.os.tag) {
        try testPushLarge(.git, .{ .wire = .ssh }, true, io, allocator);
    }
}

fn runServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    comptime temp_dir_name: []const u8,
) !std.process.Child {
    {
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
    }

    // seed the admin event store so the server can resolve <owner>/<repo> paths
    // and authenticate pushes from the dev key above
    try setupAdmin(io, allocator, temp_dir_name);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const haxy_path = try std.fs.path.join(allocator, &.{ cwd_path, "zig-out/bin/haxy" });
    defer allocator.free(haxy_path);

    const http_listen_arg = std.fmt.comptimePrint("127.0.0.1:{}", .{http_port});
    const ssh_listen_arg = std.fmt.comptimePrint("127.0.0.1:{}", .{ssh_port});

    const process = try std.process.spawn(io, .{
        .argv = &.{ haxy_path, "serve", "--http-listen", http_listen_arg, "--ssh-listen", ssh_listen_arg, "--data-dir", temp_dir_name },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", http_port);
    for (0..50) |_| {
        const stream = address.connect(io, .{ .mode = .stream }) catch {
            try std.Io.sleep(io, .fromMilliseconds(100), .real);
            continue;
        };
        stream.close(io);
        break;
    }

    return process;
}

fn testFetch(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
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
    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    // register the repo under admin and locate its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", true)).?;
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

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const client_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "client" });
    defer allocator.free(client_path);

    var client_repo = try rp.Repo(repo_kind, .{ .is_test = true }).init(io, allocator, .{ .path = client_path });
    defer client_repo.deinit(io, allocator);

    // add remote
    {
        const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
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
    const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    try client_repo.fetch(
        io,
        allocator,
        "origin",
        .{ .refspecs = refspecs, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
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
    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    // register the repo under admin and locate its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", true)).?;
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    // add config
    try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
    try server_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
    try server_repo.addConfig(io, allocator, .{ .name = "http.receivepack", .value = "true" });

    // export server repo
    {
        const export_file = try server_repo.core.repo_dir.createFile(io, "git-daemon-export-ok", .{});
        defer export_file.close(io);
    }

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

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
        const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
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
    const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    try client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .refspecs = refspecs, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
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
        } } },
    ));

    // retrieve the commit object
    try client_repo.fetch(
        io,
        allocator,
        "origin",
        .{ .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
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
        } } },
    ));

    // test denyNonFastForwards
    {
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
            } } },
        );

        // verify the server ref was not updated (push was denied)
        {
            const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
            try std.testing.expectEqualStrings(&oid_before_denied_push, &oid_master);
        }

        // remove denyNonFastForwards from server
        try server_repo.removeConfig(io, allocator, .{ .name = "receive.denynonfastforwards" });
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
        } } },
    );

    // make sure push was successful
    try std.testing.expect(null == try server_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));
}

fn testPushCreatesMissingRepo(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
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

    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

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

    // the repo is not pre-registered; the push should mint the repo event under
    // admin and create the repo on disk
    {
        const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };
    const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
    defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

    try client_repo.push(
        io,
        allocator,
        "origin",
        "master",
        false,
        .{ .refspecs = &.{"refs/tags/1.0.0:refs/tags/1.0.0"}, .wire = .{ .ssh = .{
            .command = ssh_cmd_maybe,
        } } },
    );

    // the push registered admin/server; resolve its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", false)).?;
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).open(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    try std.testing.expect(null != try server_repo.readRef(io, .{ .kind = .tag, .name = "1.0.0" }));

    const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
    try std.testing.expectEqualStrings(&commit1, &oid_master);
}

fn testClone(
    comptime repo_kind: rp.RepoKind,
    comptime transport_def: net.TransportDefinition,
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
    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const temp_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name });
    defer allocator.free(temp_path);

    // register the repo under admin and locate its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", true)).?;
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
    const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
    defer allocator.free(remote_url);

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -p {} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o IdentityFile={s}", .{ ssh_port, priv_key_path });
        defer allocator.free(ssh_config_arg);

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "clone", "--depth", "1", remote_url, "client" }
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
                    &.{ "git", "-c", ssh_config_arg, "pull", "--unshallow" }
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
                    &.{ "git", "-c", ssh_config_arg, "clone", "--shallow-since=2000-01-01", remote_url, "client" }
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
                    &.{ "git", "-c", ssh_config_arg, "clone", "--shallow-exclude=v1", remote_url, "client" }
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
                    &.{ "git", "-c", ssh_config_arg, "clone", "--filter=blob:none", remote_url, "client" }
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
                    &.{ "git", "-c", ssh_config_arg, "clone", "--filter=tree:0", remote_url, "client" }
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
        const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
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
    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // register the repo under admin and locate its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", true)).?;
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
        const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -p {} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o IdentityFile={s}", .{ ssh_port, priv_key_path });
        defer allocator.free(ssh_config_arg);

        {
            var process = try std.process.spawn(io, .{
                .argv = if (is_ssh)
                    &.{ "git", "-c", ssh_config_arg, "pull", "origin", "master" }
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
                    &.{ "git", "-c", ssh_config_arg, "fetch", "origin", "master" }
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

        const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
        defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

        try client_repo.fetch(
            io,
            allocator,
            "origin",
            .{ .refspecs = refspecs, .wire = .{ .ssh = .{
                .command = ssh_cmd_maybe,
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
    var server_process = try runServer(io, allocator, temp_dir_name);
    defer _ = server_process.kill(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // register the repo under admin and locate its on-disk directory
    const server_path = (try repoOnDiskPath(io, allocator, temp_dir_name, "testrepo", true)).?;
    defer allocator.free(server_path);

    var server_repo = try rp.Repo(.xit, .{ .is_test = true }).init(io, allocator, .{ .path = server_path });
    defer server_repo.deinit(io, allocator);

    // add config
    try server_repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
    try server_repo.addConfig(io, allocator, .{ .name = "receive.denycurrentbranch", .value = "updateinstead" });
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
        const remote_url = try remoteUrl(transport_def, allocator, "testrepo");
        defer allocator.free(remote_url);

        try client_repo.addRemote(io, allocator, .{ .name = "origin", .value = remote_url });
        try client_repo.addConfig(io, allocator, .{ .name = "branch.master.remote", .value = "origin" });
    }

    const is_ssh = switch (transport_def) {
        .file => false,
        .wire => |wire_kind| .ssh == wire_kind,
    };

    if (shell_out_to_git) {
        const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(priv_key_path);
        const ssh_config_arg = try std.fmt.allocPrint(allocator, "core.sshCommand=ssh -p {} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o IdentityFile={s}", .{ ssh_port, priv_key_path });
        defer allocator.free(ssh_config_arg);

        // shell out to git so it will send delta objects
        var process = try std.process.spawn(io, .{
            .argv = if (is_ssh)
                &.{ "git", "-c", ssh_config_arg, "push", "origin", "master" }
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
        const ssh_cmd_maybe = try sshCommand(is_ssh, allocator, cwd_path, temp_dir_name);
        defer if (ssh_cmd_maybe) |ssh_cmd| allocator.free(ssh_cmd);

        try client_repo.push(
            io,
            allocator,
            "origin",
            "master",
            false,
            .{ .wire = .{ .ssh = .{
                .command = ssh_cmd_maybe,
            } } },
        );
    }

    // make sure push was successful
    {
        const oid_master = (try server_repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        try std.testing.expectEqualStrings(&commit2, &oid_master);

        const hello_txt = try server_repo.core.work_dir.openFile(io, "hello.txt", .{});
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

// the dev SSH public key matching the private key written by runServer
const admin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark";

// create the admin event repo with a user holding the dev SSH public key
fn setupAdmin(io: std.Io, allocator: std.mem.Allocator, data_dir_name: []const u8) !void {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const admin_repo_path = try std.fs.path.join(allocator, &.{ cwd_path, data_dir_name, "admin" });
    defer allocator.free(admin_repo_path);

    var repo = try rp.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_repo_path });
    defer repo.deinit(io, allocator);

    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "admin@haxy" });

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const user_id = evt.EventWithId.randomId(prng.random());

    var password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
    const password_hash = try evt.User.hashPassword("password", &password_hash_buf, io);

    try evt.commitAndConsume(.xit, evt.admin_repo_opts, io, allocator, &repo, evt.events_ref, &[_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(user_id, .lower),
        .event = .{ .user = .{
            .name = "admin",
            .display_name = "Admin",
            .email = "admin@example.test",
            .password_hash = password_hash,
            .ssh_keys = admin_ssh_key,
        } },
    }}, false);
}

// resolve admin/<repo_name> to its on-disk directory under <data_dir>/repos via
// the event store
fn repoOnDiskPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir_name: []const u8,
    repo_name: []const u8,
    create: bool,
) !?[]u8 {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    const admin_repo_path = try std.fs.path.join(allocator, &.{ cwd_path, data_dir_name, "admin" });
    defer allocator.free(admin_repo_path);

    const event_id_hex = (try evt.resolveOrCreateRepo(io, allocator, admin_repo_path, "admin", repo_name, create)) orelse return null;
    return try std.fs.path.join(allocator, &.{ cwd_path, data_dir_name, "repos", &event_id_hex });
}

// build the remote URL addressing admin/<repo_name> over the given transport
fn remoteUrl(
    comptime transport_def: net.TransportDefinition,
    allocator: std.mem.Allocator,
    repo_name: []const u8,
) ![]u8 {
    return switch (transport_def) {
        .file => unreachable,
        .wire => |wire_kind| switch (wire_kind) {
            .http => try std.fmt.allocPrint(allocator, "http://localhost:{}/admin/{s}", .{ http_port, repo_name }),
            .raw => try std.fmt.allocPrint(allocator, "git://localhost:{}/admin/{s}", .{ http_port, repo_name }),
            .ssh => try std.fmt.allocPrint(allocator, "git@localhost:admin/{s}", .{repo_name}),
        },
    };
}

// the ssh command the haxy git client should invoke, or null when not using
// ssh. haxy generates a fresh host key on every run, so accept the unknown host
// and skip writing to known_hosts.
fn sshCommand(
    is_ssh: bool,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    temp_dir_name: []const u8,
) !?[]u8 {
    if (!is_ssh) return null;

    const priv_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
    defer allocator.free(priv_key_path);

    return try std.fmt.allocPrint(allocator, "ssh -p {} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o IdentityFile=\"{s}\"", .{ ssh_port, priv_key_path });
}

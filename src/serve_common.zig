const std = @import("std");
const evt = @import("./event.zig");
const xit = @import("xit");
const rp = xit.repo;
const ssh = @import("./serve_ssh_protocol.zig");

// progress is optional and best effort: a failed report must not fail the work
pub fn reportProgress(comptime repo_opts: rp.RepoOpts(.xit), io: std.Io, progress_ctx_maybe: ?repo_opts.ProgressCtx, event: rp.ProgressEvent) void {
    if (repo_opts.ProgressCtx != void) {
        if (progress_ctx_maybe) |progress_ctx| progress_ctx.run(io, event) catch {};
    }
}

// progress for a push, sent on the pack stream's sideband
pub const PushProgress = struct {
    response: *xit.net_server_receive_pack.Response,
    writer: *std.Io.Writer,
    // the client to probe, absent when nothing is listening
    sess: ?*ssh.SessionCtx = null,
    // set once it has hung up, so the phase in flight can stop too
    gone: bool = false,
    label: []const u8 = "Processing commits",
    count: usize = 0,
    total: usize = 0,
    // the last reported step, so a line is sent only when it changes
    step: usize = 0,

    // how many items a phase with no total advances between reports
    const report_every = 1000;

    // the phases a push reports: the objects unpacked from the pack it
    // received, then everything counted after it
    fn reported(kind: rp.ProgressKind) bool {
        return kind == .writing_object_from_pack or kind == .writing_patch;
    }

    pub fn run(self: *PushProgress, _: std.Io, event: rp.ProgressEvent) !void {
        switch (event) {
            .start => |start| {
                if (!reported(start.kind)) return;
                // the unpack phase sends no label of its own
                if (start.kind == .writing_object_from_pack) self.label = "Unpacking objects";
                self.total = start.estimated_total_items;
                self.count = 0;
                self.step = 0;
            },
            .complete_one => |kind| {
                if (!reported(kind)) return;
                self.count += 1;
            },
            .end => |kind| {
                if (!reported(kind)) return;
            },
            // each phase names itself before reporting its count
            .text => |text| {
                self.label = text;
                return;
            },
            else => return,
        }
        // a phase that knows no total counts instead, and stays quiet until it
        // has something to count
        if (self.total == 0 and self.count == 0) return;

        // every report flushes, so one is sent per percent, or per block of
        // items when there is no total to turn into one
        const step: usize = if (self.total > 0) @intCast(@as(u128, self.count) * 100 / self.total) else self.count / report_every;
        if (event == .complete_one and step == self.step) return;
        self.step = step;

        // reporting is the only moment a transaction looks up from its work
        if (self.sess) |sess| if (sess.peerGone()) {
            self.gone = true;
            return error.ClientGone;
        };

        var buffer: [128]u8 = undefined;
        const suffix = if (event == .end) "\n" else "\r";
        const text = if (self.total > 0)
            try std.fmt.bufPrint(&buffer, "{s}: {d}% ({d}/{d}){s}", .{ self.label, step, self.count, self.total, suffix })
        else
            try std.fmt.bufPrint(&buffer, "{s}: {d}{s}", .{ self.label, self.count, suffix });
        try self.response.progress(self.writer, text);
    }
};

// whether the client the work is reporting to has hung up. only a sideband
// reporter probes, so any other context never cancels.
pub fn progressCancelled(comptime repo_opts: rp.RepoOpts(.xit), progress_ctx_maybe: ?repo_opts.ProgressCtx) bool {
    if (repo_opts.ProgressCtx != *SidebandProgress) return false;
    const progress_ctx = progress_ctx_maybe orelse return false;
    return progress_ctx.gone;
}

// the outcome of resolving a requested repo path to its on-disk directory.
// the http and ssh paths each map the cases to their own error responses.
pub const RepoPath = union(enum) {
    ok: []const u8, // resolved on-disk path; the caller owns and frees it
    invalid, // a <owner>/<repo> path was expected but not given
    not_found, // unknown owner, or the repo doesn't exist and we aren't creating
};

// resolve a requested repo path to its on-disk directory, parsed as
// <owner>/<repo> through the event store, minting a repo event for a fresh push.
pub fn resolveRepoPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root_path: []const u8,
    admin_repo_path: []const u8,
    requested: []const u8,
    create_if_missing: bool,
) !RepoPath {
    const owner_repo = evt.parseOwnerRepoPath(requested) orelse return .invalid;
    const event_id_hex = (try evt.resolveOrCreateRepo(
        io,
        allocator,
        admin_repo_path,
        owner_repo.owner,
        owner_repo.name,
        if (create_if_missing) .{} else null,
    )) orelse return .not_found;
    return .{ .ok = try std.fs.path.join(allocator, &.{ repo_root_path, &event_id_hex }) };
}

// every connection task shares one error writer, so writing to it takes a
// lock. uncancelable, since a log line shouldn't be a cancelation point.
var log_mutex: std.Io.Mutex = .init;

pub fn logError(io: std.Io, err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    err.print(fmt, args) catch return;
    err.flush() catch {};
}

// accept connections forever, spawning `handleConn(context, stream)` as a task
// for each. the handler owns the stream (it closes it). `name` labels accept
// errors in the log. shared by the http, ssh, and web ui listeners.
pub fn runListener(
    io: std.Io,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
    name: []const u8,
    context: anytype,
    comptime handleConn: fn (@TypeOf(context), std.Io.net.Stream) void,
) void {
    const Context = @TypeOf(context);

    const Conn = struct {
        context: Context,
        stream: std.Io.net.Stream,

        fn run(c: @This()) void {
            handleConn(c.context, c.stream);
        }
    };

    const Listener = struct {
        io: std.Io,
        net_server: *std.Io.net.Server,
        tasks: *std.Io.Group,
        err: *std.Io.Writer,
        name: []const u8,
        context: Context,

        fn run(self: @This()) void {
            while (true) {
                const stream = self.net_server.accept(self.io) catch |accept_err| {
                    if (accept_err == error.Canceled) return;
                    logError(self.io, self.err, "{s} accept failed: {s}\n", .{ self.name, @errorName(accept_err) });
                    continue;
                };
                self.tasks.async(self.io, Conn.run, .{Conn{ .context = self.context, .stream = stream }});
            }
        }
    };

    tasks.async(io, Listener.run, .{Listener{
        .io = io,
        .net_server = net_server,
        .tasks = tasks,
        .err = err,
        .name = name,
        .context = context,
    }});
}

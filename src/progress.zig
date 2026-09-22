const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const ssh = @import("./serve_ssh_protocol.zig");

// reporting is optional and best effort: a failed report must not fail the work
pub fn report(comptime repo_opts: rp.RepoOpts(.xit), io: std.Io, progress_ctx_maybe: ?repo_opts.ProgressCtx, event: rp.ProgressEvent) void {
    if (repo_opts.ProgressCtx != void) {
        if (progress_ctx_maybe) |progress_ctx| progress_ctx.run(io, event) catch {};
    }
}

// a push's or a clone's progress, sent on the pack stream's sideband
pub const Sideband = struct {
    // a push reports through its deferred response, which knows whether the
    // client wanted sideband at all. a clone has none and writes band 2 itself.
    response: ?*xit.net_server_receive_pack.Response = null,
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

    // the phases a client is told about, listed so a new kind has to be
    // decided on rather than inherit whatever label was last set
    fn reported(kind: rp.ProgressKind) bool {
        return switch (kind) {
            .writing_object_from_pack, .checking_object, .enumerating_object, .compressing_object, .writing_patch => true,
            .writing_object, .sending_bytes, .receiving_bytes => false,
        };
    }

    pub fn run(self: *Sideband, _: std.Io, event: rp.ProgressEvent) !void {
        switch (event) {
            .start => |start| {
                if (!reported(start.kind)) return;
                // a pack phase carries no label of its own; the rest send a
                // .text first
                switch (start.kind) {
                    .writing_object_from_pack => self.label = "Unpacking objects",
                    .checking_object => self.label = "Checking connectivity",
                    .enumerating_object => self.label = "Enumerating objects",
                    .compressing_object => self.label = "Compressing objects",
                    else => {},
                }
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
        if (self.response) |response| {
            try response.progress(self.writer, text);
        } else {
            try xit.net_server_pkt.sendSideband(self.writer, 2, text);
            try self.writer.flush();
        }
    }
};

// whether the client the work is reporting to has hung up. only a sideband
// reporter probes, so any other context never cancels.
pub fn cancelled(comptime repo_opts: rp.RepoOpts(.xit), progress_ctx_maybe: ?repo_opts.ProgressCtx) bool {
    if (repo_opts.ProgressCtx != *Sideband) return false;
    const progress_ctx = progress_ctx_maybe orelse return false;
    return progress_ctx.gone;
}

const std = @import("std");
const builtin = @import("builtin");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const ansi_arts: []const []const u8 = if (builtin.cpu.arch == .wasm32) &.{} else @import("ansi_art").art;
const evt = @import("./event.zig");
const inp = @import("./ui/input.zig");

pub const Home = @import("./ui/Home.zig");
pub const User = @import("./ui/User.zig");
pub const Repo = @import("./ui/Repo.zig");
pub const Fork = @import("./ui/Fork.zig");
pub const Title = @import("./ui/Title.zig");
pub const SubTitle = @import("./ui/SubTitle.zig");
pub const Quit = @import("./ui/Quit.zig");
pub const Unauthorized = @import("./ui/Unauthorized.zig");
pub const widget = @import("./ui/widget.zig");
pub const Widget = widget.Widget;

pub const clipped_bottom_label_max_len = 10 * 4;

pub fn clippedBottomLabel(buffer: []u8, text: []const u8) ![]const u8 {
    var iter = (try std.unicode.Utf8View.init(text)).iterator();
    var end: usize = 0;
    var clipped_end: usize = 0;
    for (0..10) |i| {
        const codepoint = iter.nextCodepointSlice() orelse break;
        end += codepoint.len;
        if (i == 7) clipped_end = end;
    }
    const clipped = iter.nextCodepointSlice() != null;
    return try std.fmt.bufPrint(buffer, "{s}{s}", .{ text[0..if (clipped) clipped_end else end], if (clipped) ".." else "" });
}

pub const detail_preview_lines = 50;

pub fn detailPreviewEnd(text: []const u8) ?usize {
    var lines: usize = 1;
    for (text, 0..) |byte, i| {
        if (byte != '\n') continue;
        if (lines == detail_preview_lines and i + 1 < text.len) return i;
        lines += 1;
    }
    return null;
}

pub const PageKind = enum {
    home,
    user,
    repo,
    fork,
};

pub const Page = union(PageKind) {
    home: Home,
    user: User,
    repo: Repo,
    fork: Fork,

    pub fn init(arena: *std.heap.ArenaAllocator, session: *Session, route: RoutablePage) !Page {
        // the repo page can build without a moment in local mode; the home and
        // user pages always read from the admin db.
        return switch (route.parent()) {
            .home => .{ .home = try Home.init(arena, session.haxy_moment orelse return error.NoMoment, switch (route) {
                .home_users => |start| start,
                else => 0,
            }, switch (route) {
                .home_repos => |start| start,
                else => 0,
            }) },
            .user => blk: {
                const haxy_moment = session.haxy_moment orelse return error.NoMoment;
                break :blk switch (route) {
                    .user_repos => |u| .{ .user = try User.init(arena, session, haxy_moment, u.name, u.start, 0) },
                    .user_forks => |u| .{ .user = try User.init(arena, session, haxy_moment, u.name, 0, u.start) },
                    .user_settings, .user_auth => |name| .{ .user = try User.init(arena, session, haxy_moment, name, 0, 0) },
                    else => return error.UnexpectedRoute,
                };
            },
            .repo => switch (route) {
                .repo_files, .repo_commits, .repo_refs, .repo_issues, .repo_patches, .repo_discussions, .repo_events, .repo_settings, .repo_auth => .{ .repo = try Repo.init(arena, session, route) },
                else => return error.UnexpectedRoute,
            },
            .fork => switch (route) {
                .fork_patch, .fork_files, .fork_commits, .fork_settings, .fork_auth => .{ .fork = try Fork.init(arena, session, route) },
                else => return error.UnexpectedRoute,
            },
        };
    }
};

// what the server hands to the client (and what main_wasm parses on _start).
// keeps Page free of any per-request session state.
pub const Snapshot = struct {
    page: Page,
    session: Session.Data = .{},
};

// a top-level "page" the user can navigate to. the user_* variants are the
// tabs of a user page; they each carry the user's name and all map to the
// .user parent page, so switching between them stays on that page (and just
// updates the url) rather than navigating away.
pub const RoutablePage = union(enum) {
    home_users: usize, // 0 = first page
    home_repos: usize, // 0 = first page
    home_settings,
    home_auth,
    user_repos: struct { name: Array(evt.User.name_max_len), start: usize = 0 },
    user_forks: struct { name: Array(evt.User.name_max_len), start: usize = 0 },
    user_settings: Array(evt.User.name_max_len),
    user_auth: Array(evt.User.name_max_len),
    repo_files: RepoFilesRoute,
    repo_commits: RepoCommitsRoute,
    repo_refs: struct {
        name: Array(repo_route_max_len),
        kind: RefKind = .branch,
        // the url-encoded ref name `kind`'s column windows from ("" = the
        // first window; the other column always shows its first window).
        from: Array(ref_route_max_len) = .{},
    },
    repo_issues: struct {
        name: Array(repo_route_max_len),
        // the tag the list is filtered to, url-encoded ("" = unfiltered).
        tag: Array(issue_tag_route_max_len) = .{},
        // the issue the route names: the list's window root, or the issue the
        // edit/description/resolve view shows.
        selected: Array(evt.event_id_size * 2) = .{},
        // the resolve view's comma-separated list of fields prefilled from
        // their side of the conflict.
        theirs: Array(theirs_route_max_len) = .{},
        // the view the url names; a route with `selected` derives its view
        // from that issue's status instead.
        view: IssuesView = .open,
        // the selected issue's comment window (0 = the first window).
        comments_start: usize = 0,
        // the comment shown in the detail pane (empty = the issue thread).
        comment: Array(evt.event_id_size * 2) = .{},
    },
    repo_patches: struct {
        name: Array(repo_route_max_len),
        tag: Array(patch_tag_route_max_len) = .{},
        selected: Array(evt.event_id_size * 2) = .{},
        theirs: Array(theirs_route_max_len) = .{},
        view: PatchesView = .open,
        comments_start: usize = 0,
        comment: Array(evt.event_id_size * 2) = .{},
    },
    repo_discussions: struct {
        name: Array(repo_route_max_len),
        tag: Array(discussion_tag_route_max_len) = .{},
        selected: Array(evt.event_id_size * 2) = .{},
        view: DiscussionsView = .recent,
        comments_start: usize = 0,
        comment: Array(evt.event_id_size * 2) = .{},
    },
    repo_events: RepoEventsRoute,
    repo_settings: Array(repo_route_max_len),
    repo_auth: Array(repo_route_max_len),
    fork_patch: ForkRoute,
    fork_files: ForkFilesRoute,
    fork_commits: ForkCommitsRoute,
    fork_settings: ForkRoute,
    fork_auth: ForkRoute,

    pub const default: RoutablePage = .{ .home_repos = 0 };

    pub const RefKind = enum { branch, tag };

    pub const IssuesView = enum { open, closed, tags, new, edit, description, new_comment, edit_comment, remove, conflicts, resolve };

    pub const PatchesView = enum { open, closed, merged, tags, new, drafts, edit, publish, merge, description, new_comment, edit_comment, remove, conflicts, resolve };

    pub const DiscussionsView = enum { recent, tags, new, edit, description, new_comment, edit_comment, remove };

    pub const EventsView = enum { active, removed };

    pub const RefOrOid = enum {
        branch,
        tag,
        object,
    };

    // the "key:value" segments of a url tail, collected in any order
    const Params = struct {
        const ParamKey = enum { start, line, branch, tag, object, theirs };

        // a branch:/tag:/object: param; the value stays url-encoded
        const RefParam = struct { kind: RefOrOid, value: []const u8 };

        values: std.enums.EnumArray(ParamKey, ?[]const u8) = .initFill(null),

        // consume the leading "key:value" segments, stopping at the first
        // segment that isn't one
        fn scanPairs(self: *Params, segments: *std.mem.SplitIterator(u8, .scalar)) error{BadUrl}!void {
            while (segments.peek()) |seg| {
                const colon = std.mem.indexOfScalar(u8, seg, ':') orelse return;
                const key = std.meta.stringToEnum(ParamKey, seg[0..colon]) orelse return;
                const value = seg[colon + 1 ..];
                if (value.len == 0) return error.BadUrl;
                if (self.values.get(key) != null) return error.BadUrl;
                self.values.set(key, value);
                _ = segments.next();
            }
        }

        // consume every remaining segment: pairs plus at most one bare word,
        // which is returned
        fn scanTail(self: *Params, segments: *std.mem.SplitIterator(u8, .scalar)) error{BadUrl}!?[]const u8 {
            var word: ?[]const u8 = null;
            while (true) {
                try self.scanPairs(segments);
                const seg = segments.next() orelse return word;
                if (seg.len == 0 or word != null) return error.BadUrl;
                word = seg;
            }
        }

        // true when every set param is one of `allowed`
        fn only(self: Params, allowed: []const ParamKey) bool {
            for (std.enums.values(ParamKey)) |key| {
                if (self.values.get(key) == null) continue;
                if (std.mem.indexOfScalar(ParamKey, allowed, key) == null) return false;
            }
            return true;
        }

        // the "start:<n>" window param (0 when absent), null when malformed
        fn start(self: Params) ?usize {
            const value = self.values.get(.start) orelse return 0;
            return std.fmt.parseInt(usize, value, 10) catch null;
        }

        // the "line:<n>" first-line param (0 when absent), null when malformed
        fn line(self: Params) ?usize {
            const value = self.values.get(.line) orelse return 0;
            return std.fmt.parseInt(usize, value, 10) catch null;
        }

        // the single branch:/tag:/object: param, null when none is set
        fn ref(self: Params) error{BadUrl}!?RefParam {
            var result: ?RefParam = null;
            inline for (@typeInfo(RefOrOid).@"enum".fields) |field| {
                if (self.values.get(@field(ParamKey, field.name))) |value| {
                    if (result != null) return error.BadUrl;
                    result = .{ .kind = @field(RefOrOid, field.name), .value = value };
                }
            }
            return result;
        }
    };

    const user_segment = "/user/";
    const repo_segment = "/repo/";
    const fork_segment = "/fork/";
    const files_seg = "files";
    const commits_seg = "commits";
    // ends a commits route naming its commit's full message
    const message_seg = "message";
    // the `Params` key spellings the url emitters use
    const tag_filter_seg = @tagName(Params.ParamKey.tag) ++ ":";
    const start_seg = @tagName(Params.ParamKey.start) ++ ":";
    const line_seg = @tagName(Params.ParamKey.line) ++ ":";
    const theirs_seg = @tagName(Params.ParamKey.theirs) ++ ":";
    const issue_seg = "issue:";
    const patch_seg = "patch:";
    const discuss_seg = "discuss:";
    const comment_seg = "comment:";
    // marks a files or commits route's trailing path: the value is the raw
    // remainder of the url, so it must come last
    const path_seg = "path:";

    // a repo route is "username/reponame", optionally followed by the files
    // tab's "/files/<refkind>:<refvalue>[/line:<n>][/path:<dir>]"; the bare
    // pair means the default branch's files root. a local session's routes
    // elide the identity: "" at the bare root, else starting at the tail's "/".
    pub const repo_route_max_len = 1024;
    pub const repo_identity_max_len = evt.User.name_max_len + 1 + evt.Repo.name_max_len;

    // true when a repo route's stored string elides its identity (local mode).
    // unambiguous because a full string always starts with its owner segment.
    fn identityElided(s: []const u8) bool {
        return s.len == 0 or s[0] == '/';
    }

    // a url-encoded tag can grow to three bytes per source byte.
    pub const issue_tag_route_max_len = evt.Issue.tag_max_len * 3;
    pub const patch_tag_route_max_len = evt.Patch.tag_max_len * 3;
    pub const discussion_tag_route_max_len = evt.Discussion.tag_max_len * 3;

    // caps the resolve view's theirs: field list (a longer one doesn't route).
    pub const theirs_route_max_len = 512;

    // caps a url-encoded ref name in a route (a longer name doesn't route).
    pub const ref_route_max_len = 512;

    // the identity stored by every repo route. Local routes elide it.
    pub const RepoIdentity = struct {
        identity: []const u8, // "owner/name"
        owner: []const u8,
        name: []const u8,

        pub fn parse(s: []const u8) ?RepoIdentity {
            var result: RepoIdentity = .{
                .identity = "",
                .owner = "",
                .name = "",
            };
            if (identityElided(s)) {
                return result;
            } else {
                var id_segments = std.mem.splitScalar(u8, s, '/');
                const owner = id_segments.next() orelse return null;
                const name = id_segments.next() orelse return null;
                if (owner.len == 0 or name.len == 0) return null;
                result.identity = s[0 .. owner.len + 1 + name.len];
                result.owner = owner;
                result.name = name;
            }
            return result;
        }
    };

    pub const RepoFilesRoute = struct {
        name: Array(repo_identity_max_len),
        ref_kind: ?RefOrOid = null,
        ref_value: Array(ref_route_max_len) = .{},
        path: Array(repo_route_max_len) = .{},
        // the selected file's first visible line (1-based; 0 = unset).
        line: usize = 0,
    };

    pub const RepoCommitsRoute = struct {
        name: Array(repo_identity_max_len),
        ref_or_oid: ?RefOrOid = null,
        value: Array(ref_route_max_len) = .{},
        // what the pane shows for the commit the log walks from.
        content: Content = .{ .diff = .{} },

        // a diff window and the message are alternatives, so the window's
        // params can't be named alongside the message.
        pub const Content = union(enum) {
            diff: struct {
                // the hunk index the window starts at.
                start: usize = 0,
                // the file the diff is filtered to ("" = every file).
                path: Array(repo_route_max_len) = .{},
            },
            message,
        };
    };

    pub const RepoEventsRoute = struct {
        name: Array(repo_identity_max_len),
        view: EventsView = .active,
        kind: ?evt.EventKind = null,
        selected: Array(evt.event_id_size * 2) = .{},
    };

    pub const ForkRoute = struct {
        name: Array(repo_identity_max_len),
        id: Array(evt.event_id_size * 2),
    };

    pub const ForkFilesRoute = struct {
        fork: ForkRoute,
        oid: Array(ref_route_max_len) = .{},
        path: Array(repo_route_max_len) = .{},
        line: usize = 0,
    };

    pub const ForkCommitsRoute = struct {
        fork: ForkRoute,
        oid: Array(ref_route_max_len) = .{},
        content: RepoCommitsRoute.Content = .{ .diff = .{} },
    };

    // where the shared files and commits views are mounted. fork routes always
    // read their implicit `patch` branch unless they name an object directly.
    pub const RepoLocation = union(enum) {
        repo: []const u8,
        fork: struct {
            identity: []const u8,
            id: []const u8,
        },

        pub fn dupe(self: RepoLocation, allocator: std.mem.Allocator) !RepoLocation {
            return switch (self) {
                .repo => |identity_value| .{ .repo = try allocator.dupe(u8, identity_value) },
                .fork => |f| .{ .fork = .{
                    .identity = try allocator.dupe(u8, f.identity),
                    .id = try allocator.dupe(u8, f.id),
                } },
            };
        }

        pub fn filesRoute(self: RepoLocation, ref_or_oid: RefOrOid, value: []const u8, path: []const u8, line: usize) ?RoutablePage {
            return switch (self) {
                .repo => |repo_identity| repoFilesRoute(repo_identity, ref_or_oid, value, path, line),
                .fork => |f| if (ref_or_oid == .branch and std.mem.eql(u8, value, "patch"))
                    forkFilesRoute(f.identity, f.id, "", path, line)
                else if (ref_or_oid == .object)
                    forkFilesRoute(f.identity, f.id, value, path, line)
                else
                    null,
            };
        }

        pub fn commitsRoute(self: RepoLocation, ref_or_oid: ?RefOrOid, value: []const u8, start: usize, path: []const u8) ?RoutablePage {
            return switch (self) {
                .repo => |repo_identity| repoCommitsRoute(repo_identity, ref_or_oid, value, start, path),
                .fork => |f| if (ref_or_oid == null or (ref_or_oid == .branch and std.mem.eql(u8, value, "patch")))
                    forkCommitsRoute(f.identity, f.id, "", start, path)
                else if (ref_or_oid == .object)
                    forkCommitsRoute(f.identity, f.id, value, start, path)
                else
                    null,
            };
        }

        pub fn commitMessageRoute(self: RepoLocation, ref_or_oid: RefOrOid, value: []const u8) ?RoutablePage {
            return switch (self) {
                .repo => |repo_identity| repoCommitMessageRoute(repo_identity, ref_or_oid, value),
                .fork => |f| if (ref_or_oid == .object) forkCommitMessageRoute(f.identity, f.id, value) else null,
            };
        }
    };

    fn initForkRoute(identity: []const u8, id: []const u8) ?ForkRoute {
        if (id.len != evt.event_id_size * 2) return null;
        return .{
            .name = Array(repo_identity_max_len).from(identity) orelse return null,
            .id = Array(evt.event_id_size * 2).from(id) orelse return null,
        };
    }

    pub fn forkPatchRoute(identity: []const u8, id: []const u8) ?RoutablePage {
        return .{ .fork_patch = initForkRoute(identity, id) orelse return null };
    }

    pub fn forkFilesRoute(identity: []const u8, id: []const u8, oid: []const u8, path: []const u8, line: usize) ?RoutablePage {
        return .{ .fork_files = .{
            .fork = initForkRoute(identity, id) orelse return null,
            .oid = Array(ref_route_max_len).from(oid) orelse return null,
            .path = Array(repo_route_max_len).from(path) orelse return null,
            .line = line,
        } };
    }

    pub fn forkCommitsRoute(identity: []const u8, id: []const u8, oid: []const u8, start: usize, path: []const u8) ?RoutablePage {
        return .{ .fork_commits = .{
            .fork = initForkRoute(identity, id) orelse return null,
            .oid = Array(ref_route_max_len).from(oid) orelse return null,
            .content = .{ .diff = .{
                .start = start,
                .path = Array(repo_route_max_len).from(path) orelse return null,
            } },
        } };
    }

    pub fn forkCommitMessageRoute(identity: []const u8, id: []const u8, oid: []const u8) ?RoutablePage {
        if (oid.len == 0) return null;
        return .{ .fork_commits = .{
            .fork = initForkRoute(identity, id) orelse return null,
            .oid = Array(ref_route_max_len).from(oid) orelse return null,
            .content = .message,
        } };
    }

    pub fn forkSettingsRoute(identity: []const u8, id: []const u8) ?RoutablePage {
        return .{ .fork_settings = initForkRoute(identity, id) orelse return null };
    }

    pub fn forkAuthRoute(identity: []const u8, id: []const u8) ?RoutablePage {
        return .{ .fork_auth = initForkRoute(identity, id) orelse return null };
    }

    // build a `.repo_files` route (a null ref_kind = the bare default-branch
    // root). null if the result doesn't fit the inline name.
    pub fn repoFilesRoute(identity: []const u8, ref_kind: ?RefOrOid, ref_value: []const u8, dir: []const u8, line: usize) ?RoutablePage {
        if (ref_kind == null and (ref_value.len != 0 or dir.len != 0)) return null;
        if (ref_kind != null and ref_value.len == 0 and dir.len != 0) return null;
        return .{ .repo_files = .{
            .name = Array(repo_identity_max_len).from(identity) orelse return null,
            .ref_kind = ref_kind,
            .ref_value = Array(ref_route_max_len).from(ref_value) orelse return null,
            .path = Array(repo_route_max_len).from(dir) orelse return null,
            .line = line,
        } };
    }

    // build a `.repo_commits` route (a null ref_or_oid = the default branch).
    // always carries the `commits` marker so the bare route doesn't collide
    // with the files root. a non-empty `path` filters the diff pane to that
    // file and requires a ref.
    pub fn repoCommitsRoute(identity: []const u8, ref_or_oid: ?RefOrOid, value: []const u8, start: usize, path: []const u8) ?RoutablePage {
        if (ref_or_oid == null and (value.len != 0 or path.len != 0)) return null;
        return .{ .repo_commits = .{
            .name = Array(repo_identity_max_len).from(identity) orelse return null,
            .ref_or_oid = ref_or_oid,
            .value = Array(ref_route_max_len).from(value) orelse return null,
            .content = .{ .diff = .{
                .start = start,
                .path = Array(repo_route_max_len).from(path) orelse return null,
            } },
        } };
    }

    // build a `.repo_commits` route showing the ref/oid's commit message in
    // full, which is the only content that page renders.
    pub fn repoCommitMessageRoute(identity: []const u8, ref_or_oid: RefOrOid, value: []const u8) ?RoutablePage {
        if (value.len == 0) return null;
        return .{ .repo_commits = .{
            .name = Array(repo_identity_max_len).from(identity) orelse return null,
            .ref_or_oid = ref_or_oid,
            .value = Array(ref_route_max_len).from(value) orelse return null,
            .content = .message,
        } };
    }

    // build a `.repo_refs` route windowing `kind`'s column from the
    // url-encoded ref name `from` ("" = the first window).
    pub fn repoRefsRoute(identity: []const u8, kind: RefKind, from: []const u8) ?RoutablePage {
        return .{ .repo_refs = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .kind = kind,
            .from = Array(ref_route_max_len).from(from) orelse return null,
        } };
    }

    // build the events list or a window rooted at one event.
    pub fn repoEventsRoute(identity: []const u8, view: EventsView, kind: ?evt.EventKind, selected: []const u8) ?RoutablePage {
        if ((kind == null) != (selected.len == 0)) return null;
        return .{ .repo_events = .{
            .name = Array(repo_identity_max_len).from(identity) orelse return null,
            .view = view,
            .kind = kind,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
        } };
    }

    // build a `.repo_issues` route for "owner/name" (identity) showing
    // `status`'s list, filtered to the url-encoded `tag` ("" = unfiltered) and
    // rooted at the issue with hex event id `selected` ("" = the first window).
    pub fn repoIssuesRoute(identity: []const u8, status: evt.Issue.Status, tag: []const u8, selected: []const u8) ?RoutablePage {
        return .{ .repo_issues = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .tag = Array(issue_tag_route_max_len).from(tag) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
            .view = switch (status) {
                .open => .open,
                .closed => .closed,
            },
        } };
    }

    pub fn repoPatchesRoute(identity: []const u8, status: evt.Patch.StatusKind, tag: []const u8, selected: []const u8) ?RoutablePage {
        return .{ .repo_patches = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .tag = Array(patch_tag_route_max_len).from(tag) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
            .view = switch (status) {
                .open => .open,
                .closed => .closed,
                .merged => .merged,
            },
        } };
    }

    pub fn repoPatchesDraftsRoute(identity: []const u8) ?RoutablePage {
        return .{ .repo_patches = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .view = .drafts,
        } };
    }

    pub fn repoPatchPublishRoute(identity: []const u8, selected: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        var route = repoPatchesRoute(identity, .open, "", selected) orelse return null;
        switch (route) {
            .repo_patches => |*patch| patch.view = .publish,
            else => unreachable,
        }
        return route;
    }

    pub fn repoPatchMergeRoute(identity: []const u8, selected: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        var route = repoPatchesRoute(identity, .open, "", selected) orelse return null;
        switch (route) {
            .repo_patches => |*patch| patch.view = .merge,
            else => unreachable,
        }
        return route;
    }

    pub fn repoDiscussionsRoute(identity: []const u8, tag: []const u8, selected: []const u8) ?RoutablePage {
        return .{ .repo_discussions = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .tag = Array(discussion_tag_route_max_len).from(tag) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
        } };
    }

    // build the default list route for a thread event kind.
    pub fn repoThreadRoute(kind: evt.EventKind, identity: []const u8, tag: []const u8, selected: []const u8) ?RoutablePage {
        return switch (kind) {
            .issue => repoIssuesRoute(identity, .open, tag, selected),
            .patch => repoPatchesRoute(identity, .open, tag, selected),
            .discuss => repoDiscussionsRoute(identity, tag, selected),
            else => null,
        };
    }

    // build a selected thread route at one of its comment windows.
    pub fn repoThreadCommentsRoute(kind: evt.EventKind, identity: []const u8, selected: []const u8, start: usize) ?RoutablePage {
        var route = repoThreadRoute(kind, identity, "", selected) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.comments_start = start,
            .repo_patches => |*thread| thread.comments_start = start,
            .repo_discussions => |*thread| thread.comments_start = start,
            else => unreachable,
        }
        return route;
    }

    // build a comment permalink route at one of its immediate-reply windows.
    pub fn repoThreadCommentRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, comment_id: []const u8, start: usize) ?RoutablePage {
        if (thread_id.len == 0 or comment_id.len == 0) return null;
        var route = repoThreadCommentsRoute(kind, identity, thread_id, start) orelse return null;
        const comment = Array(evt.event_id_size * 2).from(comment_id) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.comment = comment,
            .repo_patches => |*thread| thread.comment = comment,
            .repo_discussions => |*thread| thread.comment = comment,
            else => unreachable,
        }
        return route;
    }

    // build the form route for replying to a thread or one of its comments.
    pub fn repoThreadCommentNewRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, parent_id: []const u8) ?RoutablePage {
        if (thread_id.len == 0) return null;
        var route = repoThreadCommentsRoute(kind, identity, thread_id, 0) orelse return null;
        const parent_event_id = Array(evt.event_id_size * 2).from(parent_id) orelse return null;
        switch (route) {
            .repo_issues => |*thread| {
                thread.comment = parent_event_id;
                thread.view = .new_comment;
            },
            .repo_patches => |*thread| {
                thread.comment = parent_event_id;
                thread.view = .new_comment;
            },
            .repo_discussions => |*thread| {
                thread.comment = parent_event_id;
                thread.view = .new_comment;
            },
            else => unreachable,
        }
        return route;
    }

    // build the form route for editing a comment.
    pub fn repoThreadCommentEditRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, comment_id: []const u8) ?RoutablePage {
        var route = repoThreadCommentRoute(kind, identity, thread_id, comment_id, 0) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .edit_comment,
            .repo_patches => |*thread| thread.view = .edit_comment,
            .repo_discussions => |*thread| thread.view = .edit_comment,
            else => unreachable,
        }
        return route;
    }

    // build the confirmation route for removing a thread or comment.
    pub fn repoThreadRemoveRoute(kind: evt.EventKind, identity: []const u8, thread_id: []const u8, comment_id: []const u8) ?RoutablePage {
        var route = if (comment_id.len == 0)
            repoThreadCommentsRoute(kind, identity, thread_id, 0) orelse return null
        else
            repoThreadCommentRoute(kind, identity, thread_id, comment_id, 0) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .remove,
            .repo_patches => |*thread| thread.view = .remove,
            .repo_discussions => |*thread| thread.view = .remove,
            else => unreachable,
        }
        return route;
    }

    // build a thread tags route, keeping its url-encoded tag filter.
    pub fn repoThreadTagsRoute(kind: evt.EventKind, identity: []const u8, tag: []const u8) ?RoutablePage {
        var route = repoThreadRoute(kind, identity, tag, "") orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .tags,
            .repo_patches => |*thread| thread.view = .tags,
            .repo_discussions => |*thread| thread.view = .tags,
            else => unreachable,
        }
        return route;
    }

    // build a new-thread form route.
    pub fn repoThreadNewRoute(kind: evt.EventKind, identity: []const u8) ?RoutablePage {
        var route = repoThreadRoute(kind, identity, "", "") orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .new,
            .repo_patches => |*thread| thread.view = .new,
            .repo_discussions => |*thread| thread.view = .new,
            else => unreachable,
        }
        return route;
    }

    // build the edit form route for a thread.
    pub fn repoThreadEditRoute(kind: evt.EventKind, identity: []const u8, selected: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        var route = repoThreadRoute(kind, identity, "", selected) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .edit,
            .repo_patches => |*thread| thread.view = .edit,
            .repo_discussions => |*thread| thread.view = .edit,
            else => unreachable,
        }
        return route;
    }

    // build a route showing a thread's whole description.
    pub fn repoThreadDescriptionRoute(kind: evt.EventKind, identity: []const u8, selected: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        var route = repoThreadRoute(kind, identity, "", selected) orelse return null;
        switch (route) {
            .repo_issues => |*thread| thread.view = .description,
            .repo_patches => |*thread| thread.view = .description,
            .repo_discussions => |*thread| thread.view = .description,
            else => unreachable,
        }
        return route;
    }

    // build a `.repo_issues` route showing the conflicts list, rooted at the
    // issue with hex event id `start` ("" = the first window).
    pub fn repoIssuesConflictsRoute(identity: []const u8, start: []const u8) ?RoutablePage {
        return .{ .repo_issues = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(start) orelse return null,
            .view = .conflicts,
        } };
    }

    // build a `.repo_issues` route showing the conflict resolve form for the
    // issue with hex event id `selected`; `theirs` is the comma-separated list
    // of fields prefilled from their side.
    pub fn repoIssuesResolveRoute(identity: []const u8, selected: []const u8, theirs: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        return .{ .repo_issues = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
            .theirs = Array(theirs_route_max_len).from(theirs) orelse return null,
            .view = .resolve,
        } };
    }

    pub fn repoPatchesConflictsRoute(identity: []const u8, start: []const u8) ?RoutablePage {
        return .{ .repo_patches = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(start) orelse return null,
            .view = .conflicts,
        } };
    }

    pub fn repoPatchesResolveRoute(identity: []const u8, selected: []const u8, theirs: []const u8) ?RoutablePage {
        if (selected.len == 0) return null;
        return .{ .repo_patches = .{
            .name = Array(repo_route_max_len).from(identity) orelse return null,
            .selected = Array(evt.event_id_size * 2).from(selected) orelse return null,
            .theirs = Array(theirs_route_max_len).from(theirs) orelse return null,
            .view = .resolve,
        } };
    }

    // an inline, owned array of data. keeping it in the route (rather than a
    // borrowed slice) makes RoutablePage a plain value: it can be copied, stored
    // in history, and serialized without any arena tracking.
    pub fn Array(comptime max_len: usize) type {
        return struct {
            bytes: [max_len]u8 = undefined,
            len: u16 = 0,

            pub fn from(s: []const u8) ?Array(max_len) {
                if (s.len > max_len) return null;
                var name = Array(max_len){ .len = @intCast(s.len) };
                @memcpy(name.bytes[0..s.len], s);
                return name;
            }

            pub fn slice(self: *const Array(max_len)) []const u8 {
                return self.bytes[0..self.len];
            }

            // round-trip as a json string instead of an array of numbers.
            pub fn jsonStringify(self: *const Array(max_len), jw: anytype) !void {
                try jw.write(self.slice());
            }

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Array(max_len) {
                const s = try std.json.innerParse([]const u8, allocator, source, options);
                // ValueTooLong is std.json's error for an over-long field.
                return from(s) orelse error.ValueTooLong;
            }
        };
    }

    pub fn toUrl(self: RoutablePage, arena: *std.heap.ArenaAllocator) ![]const u8 {
        return switch (self) {
            .home_users => |start| if (start == 0) @as([]const u8, "/users") else try std.fmt.allocPrint(arena.allocator(), "/users/" ++ start_seg ++ "{d}", .{start}),
            .home_repos => |start| if (start == 0) @as([]const u8, "/repos") else try std.fmt.allocPrint(arena.allocator(), "/repos/" ++ start_seg ++ "{d}", .{start}),
            .home_settings => "/settings",
            .home_auth => "/auth",
            .user_repos => |u| if (u.start == 0)
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/repos", .{u.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/repos/" ++ start_seg ++ "{d}", .{ u.name.slice(), u.start }),
            .user_forks => |u| if (u.start == 0)
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/forks", .{u.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/forks/" ++ start_seg ++ "{d}", .{ u.name.slice(), u.start }),
            .user_settings => |name| try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/settings", .{name.slice()}),
            .user_auth => |name| try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/auth", .{name.slice()}),
            .repo_files => |f| blk: {
                const prefix = try repoUrlPrefix(arena, f.name.slice());
                if (f.ref_kind == null and f.line == 0) break :blk if (prefix.len == 0) "/" else prefix;
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try out.writer.print("{s}/" ++ files_seg, .{prefix});
                if (f.ref_kind) |kind| if (f.ref_value.len != 0) try out.writer.print("/{s}:{s}", .{ @tagName(kind), f.ref_value.slice() });
                if (f.line != 0) try out.writer.print("/" ++ line_seg ++ "{d}", .{f.line});
                if (f.path.len != 0) try out.writer.print("/" ++ path_seg ++ "{s}", .{f.path.slice()});
                break :blk out.written();
            },
            .repo_commits => |c| blk: {
                const prefix = try repoUrlPrefix(arena, c.name.slice());
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try out.writer.print("{s}/" ++ commits_seg, .{prefix});
                if (c.ref_or_oid) |kind| if (c.value.len != 0) try out.writer.print("/{s}:{s}", .{ @tagName(kind), c.value.slice() });
                switch (c.content) {
                    .diff => |d| {
                        if (d.start != 0) try out.writer.print("/" ++ start_seg ++ "{d}", .{d.start});
                        if (d.path.len != 0) try out.writer.print("/" ++ path_seg ++ "{s}", .{d.path.slice()});
                    },
                    .message => try out.writer.print("/" ++ message_seg, .{}),
                }
                break :blk out.written();
            },
            .repo_refs => |r| blk: {
                const prefix = try repoUrlPrefix(arena, r.name.slice());
                break :blk if (r.from.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/refs", .{prefix})
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/refs/{s}:{s}", .{ prefix, @tagName(r.kind), r.from.slice() });
            },
            .repo_issues => |i| blk: {
                const prefix = try repoUrlPrefix(arena, i.name.slice());
                if (i.view == .edit) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/edit", .{ prefix, i.selected.slice() });
                if (i.view == .description) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/description", .{ prefix, i.selected.slice() });
                if (i.view == .resolve) break :blk if (i.theirs.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/resolve", .{ prefix, i.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ theirs_seg ++ "{s}/resolve", .{ prefix, i.selected.slice(), i.theirs.slice() });
                if (i.view == .new_comment) break :blk if (i.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/new", .{ prefix, i.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ comment_seg ++ "{s}/new", .{ prefix, i.selected.slice(), i.comment.slice() });
                if (i.view == .edit_comment) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ comment_seg ++ "{s}/edit", .{ prefix, i.selected.slice(), i.comment.slice() });
                if (i.view == .remove) break :blk if (i.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/remove", .{ prefix, i.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ comment_seg ++ "{s}/remove", .{ prefix, i.selected.slice(), i.comment.slice() });
                if (i.view == .conflicts) break :blk if (i.selected.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/issues/conflicts", .{prefix})
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/issues/" ++ start_seg ++ "{s}/conflicts", .{ prefix, i.selected.slice() });
                if (i.comment.len != 0) break :blk if (i.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ comment_seg ++ "{s}", .{ prefix, i.selected.slice(), i.comment.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ comment_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, i.selected.slice(), i.comment.slice(), i.comments_start });
                if (i.selected.len != 0) break :blk if (i.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}", .{ prefix, i.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ issue_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, i.selected.slice(), i.comments_start });
                break :blk if (i.tag.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/issues/{s}", .{ prefix, @tagName(i.view) })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/issues/{s}/" ++ tag_filter_seg ++ "{s}", .{ prefix, @tagName(i.view), i.tag.slice() });
            },
            .repo_patches => |p| blk: {
                const prefix = try repoUrlPrefix(arena, p.name.slice());
                if (p.view == .edit) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/edit", .{ prefix, p.selected.slice() });
                if (p.view == .publish) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/publish", .{ prefix, p.selected.slice() });
                if (p.view == .merge) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/merge", .{ prefix, p.selected.slice() });
                if (p.view == .description) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/description", .{ prefix, p.selected.slice() });
                if (p.view == .resolve) break :blk if (p.theirs.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/resolve", .{ prefix, p.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ theirs_seg ++ "{s}/resolve", .{ prefix, p.selected.slice(), p.theirs.slice() });
                if (p.view == .new_comment) break :blk if (p.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/new", .{ prefix, p.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ comment_seg ++ "{s}/new", .{ prefix, p.selected.slice(), p.comment.slice() });
                if (p.view == .edit_comment) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ comment_seg ++ "{s}/edit", .{ prefix, p.selected.slice(), p.comment.slice() });
                if (p.view == .remove) break :blk if (p.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/remove", .{ prefix, p.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ comment_seg ++ "{s}/remove", .{ prefix, p.selected.slice(), p.comment.slice() });
                if (p.view == .conflicts) break :blk if (p.selected.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/patches/conflicts", .{prefix})
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/patches/" ++ start_seg ++ "{s}/conflicts", .{ prefix, p.selected.slice() });
                if (p.comment.len != 0) break :blk if (p.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ comment_seg ++ "{s}", .{ prefix, p.selected.slice(), p.comment.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ comment_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, p.selected.slice(), p.comment.slice(), p.comments_start });
                if (p.selected.len != 0) break :blk if (p.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}", .{ prefix, p.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ patch_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, p.selected.slice(), p.comments_start });
                break :blk if (p.tag.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/patches/{s}", .{ prefix, @tagName(p.view) })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/patches/{s}/" ++ tag_filter_seg ++ "{s}", .{ prefix, @tagName(p.view), p.tag.slice() });
            },
            .repo_discussions => |t| blk: {
                const prefix = try repoUrlPrefix(arena, t.name.slice());
                if (t.view == .edit) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/edit", .{ prefix, t.selected.slice() });
                if (t.view == .description) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/description", .{ prefix, t.selected.slice() });
                if (t.view == .new_comment) break :blk if (t.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/new", .{ prefix, t.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ comment_seg ++ "{s}/new", .{ prefix, t.selected.slice(), t.comment.slice() });
                if (t.view == .edit_comment) break :blk try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ comment_seg ++ "{s}/edit", .{ prefix, t.selected.slice(), t.comment.slice() });
                if (t.view == .remove) break :blk if (t.comment.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/remove", .{ prefix, t.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ comment_seg ++ "{s}/remove", .{ prefix, t.selected.slice(), t.comment.slice() });
                if (t.comment.len != 0) break :blk if (t.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ comment_seg ++ "{s}", .{ prefix, t.selected.slice(), t.comment.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ comment_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, t.selected.slice(), t.comment.slice(), t.comments_start });
                if (t.selected.len != 0) break :blk if (t.comments_start == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}", .{ prefix, t.selected.slice() })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/" ++ discuss_seg ++ "{s}/" ++ start_seg ++ "{d}", .{ prefix, t.selected.slice(), t.comments_start });
                break :blk if (t.tag.len == 0)
                    try std.fmt.allocPrint(arena.allocator(), "{s}/discussions/{s}", .{ prefix, @tagName(t.view) })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/discussions/{s}/" ++ tag_filter_seg ++ "{s}", .{ prefix, @tagName(t.view), t.tag.slice() });
            },
            .repo_events => |e| blk: {
                const prefix = try repoUrlPrefix(arena, e.name.slice());
                break :blk if (e.kind) |kind|
                    try std.fmt.allocPrint(arena.allocator(), "{s}/event:{s}/kind:{s}", .{ prefix, e.selected.slice(), @tagName(kind) })
                else
                    try std.fmt.allocPrint(arena.allocator(), "{s}/events/{s}", .{ prefix, @tagName(e.view) });
            },
            .repo_settings => |name| try std.fmt.allocPrint(arena.allocator(), "{s}/settings", .{try repoUrlPrefix(arena, name.slice())}),
            .repo_auth => |name| try std.fmt.allocPrint(arena.allocator(), "{s}/auth", .{try repoUrlPrefix(arena, name.slice())}),
            .fork_patch => |f| try std.fmt.allocPrint(arena.allocator(), fork_segment ++ "{s}/" ++ patch_seg ++ "{s}", .{ f.name.slice(), f.id.slice() }),
            .fork_files => |f| blk: {
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try out.writer.print(fork_segment ++ "{s}/" ++ patch_seg ++ "{s}/" ++ files_seg, .{ f.fork.name.slice(), f.fork.id.slice() });
                if (f.oid.len != 0) try out.writer.print("/object:{s}", .{f.oid.slice()});
                if (f.line != 0) try out.writer.print("/" ++ line_seg ++ "{d}", .{f.line});
                if (f.path.len != 0) try out.writer.print("/" ++ path_seg ++ "{s}", .{f.path.slice()});
                break :blk out.written();
            },
            .fork_commits => |c| blk: {
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try out.writer.print(fork_segment ++ "{s}/" ++ patch_seg ++ "{s}/" ++ commits_seg, .{ c.fork.name.slice(), c.fork.id.slice() });
                if (c.oid.len != 0) try out.writer.print("/object:{s}", .{c.oid.slice()});
                switch (c.content) {
                    .diff => |d| {
                        if (d.start != 0) try out.writer.print("/" ++ start_seg ++ "{d}", .{d.start});
                        if (d.path.len != 0) try out.writer.print("/" ++ path_seg ++ "{s}", .{d.path.slice()});
                    },
                    .message => try out.writer.print("/" ++ message_seg, .{}),
                }
                break :blk out.written();
            },
            .fork_settings => |f| try std.fmt.allocPrint(arena.allocator(), fork_segment ++ "{s}/" ++ patch_seg ++ "{s}/settings", .{ f.name.slice(), f.id.slice() }),
            .fork_auth => |f| try std.fmt.allocPrint(arena.allocator(), fork_segment ++ "{s}/" ++ patch_seg ++ "{s}/auth", .{ f.name.slice(), f.id.slice() }),
        };
    }

    pub fn fromUrl(path: []const u8) ?RoutablePage {
        if (std.mem.eql(u8, path, "/")) return default;
        if (path.len < 2 or path[0] != '/') return null;
        var segments = std.mem.splitScalar(u8, path[1..], '/');
        const first = segments.next() orelse return null;
        if (std.mem.eql(u8, first, "users")) return .{ .home_users = listStart(&segments) orelse return null };
        if (std.mem.eql(u8, first, "repos")) return .{ .home_repos = listStart(&segments) orelse return null };
        if (std.mem.eql(u8, first, "settings")) return if (segments.next() == null) .home_settings else null;
        if (std.mem.eql(u8, first, "auth")) return if (segments.next() == null) .home_auth else null;
        // "user/<name>[/repos[/start:<n>]|/settings|/auth]"
        if (std.mem.eql(u8, first, "user")) {
            const name = segments.next() orelse return null;
            if (name.len == 0) return null;
            const parsed = Array(evt.User.name_max_len).from(name) orelse return null; // name too long
            const sub = segments.next() orelse return .{ .user_repos = .{ .name = parsed } };
            if (std.mem.eql(u8, sub, "repos")) return .{ .user_repos = .{ .name = parsed, .start = listStart(&segments) orelse return null } };
            if (std.mem.eql(u8, sub, "forks")) return .{ .user_forks = .{ .name = parsed, .start = listStart(&segments) orelse return null } };
            if (std.mem.eql(u8, sub, "settings")) return if (segments.next() == null) .{ .user_settings = parsed } else null;
            if (std.mem.eql(u8, sub, "auth")) return if (segments.next() == null) .{ .user_auth = parsed } else null;
            return null; // unknown sub-path
        }
        // "fork/<username>/<reponame>/patch:<id>[/files|/commits]"; the
        // patch branch is implicit, while object ids and view-specific params
        // use the same tails as the repo files and commits routes.
        if (std.mem.eql(u8, first, "fork")) {
            const rest = segments.rest();
            const owner = segments.next() orelse return null;
            const repo_name = segments.next() orelse return null;
            if (owner.len == 0 or repo_name.len == 0) return null;
            const identity = rest[0 .. owner.len + 1 + repo_name.len];
            const patch = segments.next() orelse return null;
            if (!std.mem.startsWith(u8, patch, patch_seg)) return null;
            const id = patch[patch_seg.len..];
            if (id.len != evt.event_id_size * 2) return null;
            const tab = segments.next() orelse return forkPatchRoute(identity, id);
            var params = Params{};
            if (std.mem.eql(u8, tab, files_seg)) {
                params.scanPairs(&segments) catch return null;
                if (!params.only(&.{ .line, .object })) return null;
                const line = params.line() orelse return null;
                const ref = params.ref() catch return null;
                const oid = if (ref) |value| if (value.kind == .object) value.value else return null else "";
                const file_path = pathValue(segments.rest()) orelse return null;
                return forkFilesRoute(identity, id, oid, file_path, line);
            }
            if (std.mem.eql(u8, tab, commits_seg)) {
                params.scanPairs(&segments) catch return null;
                if (!params.only(&.{ .start, .object })) return null;
                const start = params.start() orelse return null;
                const ref = params.ref() catch return null;
                const oid = if (ref) |value| if (value.kind == .object) value.value else return null else "";
                if (std.mem.eql(u8, segments.rest(), message_seg))
                    return if (start == 0 and oid.len != 0) forkCommitMessageRoute(identity, id, oid) else null;
                const file_path = pathValue(segments.rest()) orelse return null;
                return forkCommitsRoute(identity, id, oid, start, file_path);
            }
            if (std.mem.eql(u8, tab, "settings")) return if (segments.next() == null) forkSettingsRoute(identity, id) else null;
            if (std.mem.eql(u8, tab, "auth")) return if (segments.next() == null) forkAuthRoute(identity, id) else null;
            return null;
        }
        // "repo/<username>/<reponame>[/<tab tail>]"; the bare pair is the
        // files root
        if (std.mem.eql(u8, first, "repo")) {
            const rest = segments.rest(); // "username/reponame[/...]"
            const owner = segments.next() orelse return null;
            const repo_name = segments.next() orelse return null;
            // reject an empty username or reponame
            if (owner.len == 0 or repo_name.len == 0) return null;
            const pair = rest[0 .. owner.len + 1 + repo_name.len]; // "username/reponame"
            if (segments.peek() != null) {
                return repoSubRoute(pair, segments.rest());
            }
            return repoFilesRoute(pair, null, "", "", 0);
        }
        return null;
    }

    // parse a local-mode url, which elides the "/repo/<owner>/<name>" prefix:
    // "/" is the files root and the sub-paths follow directly.
    pub fn fromUrlLocal(path: []const u8) ?RoutablePage {
        if (std.mem.eql(u8, path, "/")) return repoFilesRoute("", null, "", "", 0);
        if (path.len < 2 or path[0] != '/') return null;
        return repoSubRoute("", path[1..]);
    }

    // the url prefix for a repo route's identity: "/repo/<identity>", or ""
    // when the identity is elided.
    fn repoUrlPrefix(arena: *std.heap.ArenaAllocator, identity: []const u8) ![]const u8 {
        if (identity.len == 0) return "";
        return std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}", .{identity});
    }

    // true when the page builds at its content height on the web, letting the
    // browser scroll the whole page, rather than being pinned to the viewport
    pub fn fullHeight(self: RoutablePage) bool {
        return switch (self) {
            .repo_issues => |i| i.view == .resolve,
            .repo_patches => |p| p.view == .resolve,
            else => false,
        };
    }

    // the "owner/name" a repo route carries, null for any other route. the
    // result borrows the route, so it must outlive the slice.
    pub fn repoIdentity(self: *const RoutablePage) ?[]const u8 {
        return switch (self.*) {
            .repo_files => |*f| f.name.slice(),
            .repo_commits => |*c| c.name.slice(),
            .repo_refs => |*r| r.name.slice(),
            .repo_issues => |*i| i.name.slice(),
            .repo_patches => |*p| p.name.slice(),
            .repo_discussions => |*t| t.name.slice(),
            .repo_events => |*e| e.name.slice(),
            .repo_settings, .repo_auth => |*name| name.slice(),
            else => null,
        };
    }

    pub fn forkRoute(self: *const RoutablePage) ?*const ForkRoute {
        return switch (self.*) {
            .fork_patch => |*f| f,
            .fork_files => |*f| &f.fork,
            .fork_commits => |*f| &f.fork,
            .fork_settings => |*f| f,
            .fork_auth => |*f| f,
            else => null,
        };
    }

    // the route this route's page lands on, with no tab or params: the users
    // list, a user's repos, or a repo's files root.
    pub fn pageRoot(self: RoutablePage) RoutablePage {
        return switch (self.parent()) {
            .home => .default,
            .user => switch (self) {
                .user_repos => |u| .{ .user_repos = .{ .name = u.name } },
                .user_forks => |u| .{ .user_repos = .{ .name = u.name } },
                .user_settings, .user_auth => |name| .{ .user_repos = .{ .name = name } },
                else => self,
            },
            // every repo route stores the same identity, so it always fits
            .repo => repoFilesRoute(self.repoIdentity() orelse return self, null, "", "", 0) orelse self,
            .fork => blk: {
                const f = self.forkRoute() orelse break :blk self;
                break :blk forkPatchRoute(f.name.slice(), f.id.slice()) orelse self;
            },
        };
    }

    pub fn parent(self: RoutablePage) PageKind {
        return switch (self) {
            .home_users, .home_repos, .home_settings, .home_auth => .home,
            .user_repos, .user_forks, .user_settings, .user_auth => .user,
            .repo_files, .repo_commits, .repo_refs, .repo_issues, .repo_patches, .repo_discussions, .repo_events, .repo_settings, .repo_auth => .repo,
            .fork_patch, .fork_files, .fork_commits, .fork_settings, .fork_auth => .fork,
        };
    }

    // the dir a trailing "path:<dir>" names: the raw remainder ("" when
    // absent, null when malformed)
    fn pathValue(rest: []const u8) ?[]const u8 {
        if (rest.len == 0) return "";
        if (!std.mem.startsWith(u8, rest, path_seg)) return null;
        const dir = rest[path_seg.len..];
        return if (dir.len == 0) null else dir;
    }

    // a list route's tail: at most a "start:<n>" param, null on anything else
    fn listStart(segments: *std.mem.SplitIterator(u8, .scalar)) ?usize {
        var params = Params{};
        const word = params.scanTail(segments) catch return null;
        if (word != null or !params.only(&.{.start})) return null;
        return params.start();
    }

    // parse the sub-path after a repo route's identity ("" for a local
    // route): a tab keyword followed by "key:value" params in any order, plus
    // the files tab's trailing "path:<dir>".
    fn repoSubRoute(pair: []const u8, sub: []const u8) ?RoutablePage {
        var segments = std.mem.splitScalar(u8, sub, '/');
        const tab = segments.next() orelse return null;
        var params = Params{};
        if (std.mem.eql(u8, tab, "settings")) return if (segments.next() == null) .{ .repo_settings = Array(repo_route_max_len).from(pair) orelse return null } else null;
        if (std.mem.eql(u8, tab, "auth")) return if (segments.next() == null) .{ .repo_auth = Array(repo_route_max_len).from(pair) orelse return null } else null;
        if (std.mem.eql(u8, tab, "refs")) {
            const word = params.scanTail(&segments) catch return null;
            if (word != null or !params.only(&.{ .branch, .tag })) return null;
            const ref = (params.ref() catch return null) orelse return repoRefsRoute(pair, .branch, "");
            const kind = std.meta.stringToEnum(RefKind, @tagName(ref.kind)) orelse return null;
            return repoRefsRoute(pair, kind, ref.value);
        }
        if (std.mem.startsWith(u8, tab, issue_seg)) {
            const issue_id = tab[issue_seg.len..];
            if (issue_id.len == 0) return null;
            if (segments.peek()) |tail| {
                if (std.mem.startsWith(u8, tail, comment_seg)) {
                    _ = segments.next();
                    const comment_id = tail[comment_seg.len..];
                    if (comment_id.len == 0) return null;
                    const word = params.scanTail(&segments) catch return null;
                    if (word) |last| {
                        if (!params.only(&.{})) return null;
                        if (std.mem.eql(u8, last, "new")) return repoThreadCommentNewRoute(.issue, pair, issue_id, comment_id);
                        if (std.mem.eql(u8, last, "edit")) return repoThreadCommentEditRoute(.issue, pair, issue_id, comment_id);
                        if (std.mem.eql(u8, last, "remove")) return repoThreadRemoveRoute(.issue, pair, issue_id, comment_id);
                        return null;
                    }
                    if (!params.only(&.{.start})) return null;
                    return repoThreadCommentRoute(.issue, pair, issue_id, comment_id, params.start() orelse return null);
                }
            }
            const word = params.scanTail(&segments) catch return null;
            if (word) |tail| {
                if (std.mem.eql(u8, tail, "new")) return if (params.only(&.{})) repoThreadCommentNewRoute(.issue, pair, issue_id, "") else null;
                if (std.mem.eql(u8, tail, "edit")) return if (params.only(&.{})) repoThreadEditRoute(.issue, pair, issue_id) else null;
                if (std.mem.eql(u8, tail, "remove")) return if (params.only(&.{})) repoThreadRemoveRoute(.issue, pair, issue_id, "") else null;
                if (std.mem.eql(u8, tail, "description")) return if (params.only(&.{})) repoThreadDescriptionRoute(.issue, pair, issue_id) else null;
                if (std.mem.eql(u8, tail, "resolve")) {
                    if (!params.only(&.{.theirs})) return null;
                    return repoIssuesResolveRoute(pair, issue_id, params.values.get(.theirs) orelse "");
                }
                return null;
            }
            if (!params.only(&.{.start})) return null;
            return repoThreadCommentsRoute(.issue, pair, issue_id, params.start() orelse return null);
        }
        if (std.mem.startsWith(u8, tab, patch_seg)) {
            const patch_id = tab[patch_seg.len..];
            if (patch_id.len == 0) return null;
            if (segments.peek()) |tail| {
                if (std.mem.startsWith(u8, tail, comment_seg)) {
                    _ = segments.next();
                    const comment_id = tail[comment_seg.len..];
                    if (comment_id.len == 0) return null;
                    const word = params.scanTail(&segments) catch return null;
                    if (word) |last| {
                        if (!params.only(&.{})) return null;
                        if (std.mem.eql(u8, last, "new")) return repoThreadCommentNewRoute(.patch, pair, patch_id, comment_id);
                        if (std.mem.eql(u8, last, "edit")) return repoThreadCommentEditRoute(.patch, pair, patch_id, comment_id);
                        if (std.mem.eql(u8, last, "remove")) return repoThreadRemoveRoute(.patch, pair, patch_id, comment_id);
                        return null;
                    }
                    if (!params.only(&.{.start})) return null;
                    return repoThreadCommentRoute(.patch, pair, patch_id, comment_id, params.start() orelse return null);
                }
            }
            const word = params.scanTail(&segments) catch return null;
            if (word) |tail| {
                if (std.mem.eql(u8, tail, "new")) return if (params.only(&.{})) repoThreadCommentNewRoute(.patch, pair, patch_id, "") else null;
                if (std.mem.eql(u8, tail, "edit")) return if (params.only(&.{})) repoThreadEditRoute(.patch, pair, patch_id) else null;
                if (std.mem.eql(u8, tail, "publish")) return if (params.only(&.{})) repoPatchPublishRoute(pair, patch_id) else null;
                if (std.mem.eql(u8, tail, "merge")) return if (params.only(&.{})) repoPatchMergeRoute(pair, patch_id) else null;
                if (std.mem.eql(u8, tail, "remove")) return if (params.only(&.{})) repoThreadRemoveRoute(.patch, pair, patch_id, "") else null;
                if (std.mem.eql(u8, tail, "description")) return if (params.only(&.{})) repoThreadDescriptionRoute(.patch, pair, patch_id) else null;
                if (std.mem.eql(u8, tail, "resolve")) {
                    if (!params.only(&.{.theirs})) return null;
                    return repoPatchesResolveRoute(pair, patch_id, params.values.get(.theirs) orelse "");
                }
                return null;
            }
            if (!params.only(&.{.start})) return null;
            return repoThreadCommentsRoute(.patch, pair, patch_id, params.start() orelse return null);
        }
        if (std.mem.startsWith(u8, tab, discuss_seg)) {
            const discussion_id = tab[discuss_seg.len..];
            if (discussion_id.len == 0) return null;
            if (segments.peek()) |tail| {
                if (std.mem.startsWith(u8, tail, comment_seg)) {
                    _ = segments.next();
                    const comment_id = tail[comment_seg.len..];
                    if (comment_id.len == 0) return null;
                    const word = params.scanTail(&segments) catch return null;
                    if (word) |last| {
                        if (!params.only(&.{})) return null;
                        if (std.mem.eql(u8, last, "new")) return repoThreadCommentNewRoute(.discuss, pair, discussion_id, comment_id);
                        if (std.mem.eql(u8, last, "edit")) return repoThreadCommentEditRoute(.discuss, pair, discussion_id, comment_id);
                        if (std.mem.eql(u8, last, "remove")) return repoThreadRemoveRoute(.discuss, pair, discussion_id, comment_id);
                        return null;
                    }
                    if (!params.only(&.{.start})) return null;
                    return repoThreadCommentRoute(.discuss, pair, discussion_id, comment_id, params.start() orelse return null);
                }
            }
            const word = params.scanTail(&segments) catch return null;
            if (word) |tail| {
                if (std.mem.eql(u8, tail, "new")) return if (params.only(&.{})) repoThreadCommentNewRoute(.discuss, pair, discussion_id, "") else null;
                if (std.mem.eql(u8, tail, "edit")) return if (params.only(&.{})) repoThreadEditRoute(.discuss, pair, discussion_id) else null;
                if (std.mem.eql(u8, tail, "remove")) return if (params.only(&.{})) repoThreadRemoveRoute(.discuss, pair, discussion_id, "") else null;
                if (std.mem.eql(u8, tail, "description")) return if (params.only(&.{})) repoThreadDescriptionRoute(.discuss, pair, discussion_id) else null;
                return null;
            }
            if (!params.only(&.{.start})) return null;
            return repoThreadCommentsRoute(.discuss, pair, discussion_id, params.start() orelse return null);
        }
        if (std.mem.eql(u8, tab, "issues")) {
            // the word is a list view; a filter with neither is never emitted.
            const word = params.scanTail(&segments) catch return null;
            const tag_value = params.values.get(.tag) orelse "";
            const w = word orelse return if (params.only(&.{})) repoIssuesRoute(pair, .open, "", "") else null;
            // the conflicts list windows by an issue id, not a number, so it
            // reads the start param raw
            if (std.mem.eql(u8, w, "conflicts")) {
                if (!params.only(&.{.start})) return null;
                return repoIssuesConflictsRoute(pair, params.values.get(.start) orelse "");
            }
            if (!params.only(&.{.tag})) return null;
            if (std.meta.stringToEnum(evt.Issue.Status, w)) |status| return repoIssuesRoute(pair, status, tag_value, "");
            if (std.mem.eql(u8, w, "tags")) return repoThreadTagsRoute(.issue, pair, tag_value);
            if (std.mem.eql(u8, w, "new")) return if (tag_value.len == 0) repoThreadNewRoute(.issue, pair) else null;
            return null;
        }
        if (std.mem.eql(u8, tab, "patches")) {
            const word = params.scanTail(&segments) catch return null;
            const tag_value = params.values.get(.tag) orelse "";
            const view = word orelse return if (params.only(&.{})) repoPatchesRoute(pair, .open, "", "") else null;
            if (std.mem.eql(u8, view, "conflicts")) {
                if (!params.only(&.{.start})) return null;
                return repoPatchesConflictsRoute(pair, params.values.get(.start) orelse "");
            }
            if (!params.only(&.{.tag})) return null;
            if (std.meta.stringToEnum(evt.Patch.StatusKind, view)) |status| return repoPatchesRoute(pair, status, tag_value, "");
            if (std.mem.eql(u8, view, "tags")) return repoThreadTagsRoute(.patch, pair, tag_value);
            if (std.mem.eql(u8, view, "new")) return if (tag_value.len == 0) repoThreadNewRoute(.patch, pair) else null;
            if (std.mem.eql(u8, view, "drafts")) return if (tag_value.len == 0) repoPatchesDraftsRoute(pair) else null;
            return null;
        }
        if (std.mem.eql(u8, tab, "discussions")) {
            const word = params.scanTail(&segments) catch return null;
            const tag_value = params.values.get(.tag) orelse "";
            const view = word orelse return if (params.only(&.{})) repoDiscussionsRoute(pair, "", "") else null;
            if (!params.only(&.{.tag})) return null;
            if (std.mem.eql(u8, view, "recent")) return repoDiscussionsRoute(pair, tag_value, "");
            if (std.mem.eql(u8, view, "tags")) return repoThreadTagsRoute(.discuss, pair, tag_value);
            if (std.mem.eql(u8, view, "new")) return if (tag_value.len == 0) repoThreadNewRoute(.discuss, pair) else null;
            return null;
        }
        if (std.mem.eql(u8, tab, "events")) {
            const view = if (segments.next()) |word|
                std.meta.stringToEnum(EventsView, word) orelse return null
            else
                .active;
            return if (segments.next() == null) repoEventsRoute(pair, view, null, "") else null;
        }
        if (std.mem.startsWith(u8, tab, "event:")) {
            const event_id = tab["event:".len..];
            const kind_segment = segments.next() orelse return null;
            if (!std.mem.startsWith(u8, kind_segment, "kind:")) return null;
            const kind = std.meta.stringToEnum(evt.EventKind, kind_segment["kind:".len..]) orelse return null;
            if (event_id.len == 0 or segments.next() != null) return null;
            return repoEventsRoute(pair, .active, kind, event_id);
        }
        if (std.mem.eql(u8, tab, files_seg)) {
            params.scanPairs(&segments) catch return null;
            if (!params.only(&.{ .line, .branch, .tag, .object })) return null;
            const line = params.line() orelse return null;
            const dir = pathValue(segments.rest()) orelse return null;
            const ref = (params.ref() catch return null) orelse
                return if (dir.len == 0) repoFilesRoute(pair, null, "", "", line) else null;
            return repoFilesRoute(pair, ref.kind, ref.value, dir, line);
        }
        if (std.mem.eql(u8, tab, commits_seg)) {
            params.scanPairs(&segments) catch return null;
            if (!params.only(&.{ .start, .branch, .tag, .object })) return null;
            const start = params.start() orelse return null;
            const ref = (params.ref() catch return null) orelse {
                const file = pathValue(segments.rest()) orelse return null;
                return if (file.len == 0) repoCommitsRoute(pair, null, "", start, "") else null;
            };
            // the message page names its commit and nothing else
            if (std.mem.eql(u8, segments.rest(), message_seg))
                return if (start == 0) repoCommitMessageRoute(pair, ref.kind, ref.value) else null;
            const file = pathValue(segments.rest()) orelse return null;
            return repoCommitsRoute(pair, ref.kind, ref.value, start, file);
        }
        return null; // unknown sub-path
    }

    pub fn eql(a: RoutablePage, b: RoutablePage) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .home_users => |a_start| a_start == b.home_users,
            .home_repos => |a_start| a_start == b.home_repos,
            .user_repos => |a_u| std.mem.eql(u8, a_u.name.slice(), b.user_repos.name.slice()) and a_u.start == b.user_repos.start,
            .user_forks => |a_u| std.mem.eql(u8, a_u.name.slice(), b.user_forks.name.slice()) and a_u.start == b.user_forks.start,
            .user_settings => |a_name| std.mem.eql(u8, a_name.slice(), b.user_settings.slice()),
            .user_auth => |a_name| std.mem.eql(u8, a_name.slice(), b.user_auth.slice()),
            .repo_files => |a_f| std.mem.eql(u8, a_f.name.slice(), b.repo_files.name.slice()) and
                a_f.ref_kind == b.repo_files.ref_kind and
                std.mem.eql(u8, a_f.ref_value.slice(), b.repo_files.ref_value.slice()) and
                std.mem.eql(u8, a_f.path.slice(), b.repo_files.path.slice()) and
                a_f.line == b.repo_files.line,
            .repo_commits => |a_c| std.mem.eql(u8, a_c.name.slice(), b.repo_commits.name.slice()) and
                a_c.ref_or_oid == b.repo_commits.ref_or_oid and
                std.mem.eql(u8, a_c.value.slice(), b.repo_commits.value.slice()) and
                switch (a_c.content) {
                    .diff => |a_d| switch (b.repo_commits.content) {
                        .diff => |b_d| a_d.start == b_d.start and std.mem.eql(u8, a_d.path.slice(), b_d.path.slice()),
                        .message => false,
                    },
                    .message => std.meta.activeTag(b.repo_commits.content) == .message,
                },
            .repo_refs => |a_r| std.mem.eql(u8, a_r.name.slice(), b.repo_refs.name.slice()) and a_r.kind == b.repo_refs.kind and std.mem.eql(u8, a_r.from.slice(), b.repo_refs.from.slice()),
            .repo_issues => |a_i| std.mem.eql(u8, a_i.name.slice(), b.repo_issues.name.slice()) and
                std.mem.eql(u8, a_i.tag.slice(), b.repo_issues.tag.slice()) and
                std.mem.eql(u8, a_i.selected.slice(), b.repo_issues.selected.slice()) and
                std.mem.eql(u8, a_i.theirs.slice(), b.repo_issues.theirs.slice()) and
                a_i.view == b.repo_issues.view and
                a_i.comments_start == b.repo_issues.comments_start and
                std.mem.eql(u8, a_i.comment.slice(), b.repo_issues.comment.slice()),
            .repo_discussions => |a_t| std.mem.eql(u8, a_t.name.slice(), b.repo_discussions.name.slice()) and
                std.mem.eql(u8, a_t.tag.slice(), b.repo_discussions.tag.slice()) and
                std.mem.eql(u8, a_t.selected.slice(), b.repo_discussions.selected.slice()) and
                a_t.view == b.repo_discussions.view and
                a_t.comments_start == b.repo_discussions.comments_start and
                std.mem.eql(u8, a_t.comment.slice(), b.repo_discussions.comment.slice()),
            .repo_patches => |a_p| std.mem.eql(u8, a_p.name.slice(), b.repo_patches.name.slice()) and
                std.mem.eql(u8, a_p.tag.slice(), b.repo_patches.tag.slice()) and
                std.mem.eql(u8, a_p.selected.slice(), b.repo_patches.selected.slice()) and
                std.mem.eql(u8, a_p.theirs.slice(), b.repo_patches.theirs.slice()) and
                a_p.view == b.repo_patches.view and
                a_p.comments_start == b.repo_patches.comments_start and
                std.mem.eql(u8, a_p.comment.slice(), b.repo_patches.comment.slice()),
            .repo_events => |a_e| std.mem.eql(u8, a_e.name.slice(), b.repo_events.name.slice()) and
                a_e.view == b.repo_events.view and
                a_e.kind == b.repo_events.kind and
                std.mem.eql(u8, a_e.selected.slice(), b.repo_events.selected.slice()),
            .repo_settings => |a_name| std.mem.eql(u8, a_name.slice(), b.repo_settings.slice()),
            .repo_auth => |a_name| std.mem.eql(u8, a_name.slice(), b.repo_auth.slice()),
            .fork_patch => |a_f| std.mem.eql(u8, a_f.name.slice(), b.fork_patch.name.slice()) and std.mem.eql(u8, a_f.id.slice(), b.fork_patch.id.slice()),
            .fork_files => |a_f| std.mem.eql(u8, a_f.fork.name.slice(), b.fork_files.fork.name.slice()) and
                std.mem.eql(u8, a_f.fork.id.slice(), b.fork_files.fork.id.slice()) and
                std.mem.eql(u8, a_f.oid.slice(), b.fork_files.oid.slice()) and
                std.mem.eql(u8, a_f.path.slice(), b.fork_files.path.slice()) and
                a_f.line == b.fork_files.line,
            .fork_commits => |a_c| std.mem.eql(u8, a_c.fork.name.slice(), b.fork_commits.fork.name.slice()) and
                std.mem.eql(u8, a_c.fork.id.slice(), b.fork_commits.fork.id.slice()) and
                std.mem.eql(u8, a_c.oid.slice(), b.fork_commits.oid.slice()) and
                switch (a_c.content) {
                    .diff => |a_d| switch (b.fork_commits.content) {
                        .diff => |b_d| a_d.start == b_d.start and std.mem.eql(u8, a_d.path.slice(), b_d.path.slice()),
                        .message => false,
                    },
                    .message => std.meta.activeTag(b.fork_commits.content) == .message,
                },
            .fork_settings => |a_f| std.mem.eql(u8, a_f.name.slice(), b.fork_settings.name.slice()) and std.mem.eql(u8, a_f.id.slice(), b.fork_settings.id.slice()),
            .fork_auth => |a_f| std.mem.eql(u8, a_f.name.slice(), b.fork_auth.name.slice()) and std.mem.eql(u8, a_f.id.slice(), b.fork_auth.id.slice()),
            else => true,
        };
    }

    // true when following a link from `b` to `a` (both repo routes) should reload
    // rather than stay in page
    pub fn repoPageChanged(a: RoutablePage, b: RoutablePage) bool {
        if (a.parent() != .repo or b.parent() != .repo) return false;
        if (std.meta.activeTag(a) == .repo_refs and std.meta.activeTag(b) == .repo_refs and
            a.repo_refs.from.len == 0 and b.repo_refs.from.len == 0)
            return !std.mem.eql(u8, a.repo_refs.name.slice(), b.repo_refs.name.slice());
        return !a.eql(b);
    }

    pub fn forkPageChanged(a: RoutablePage, b: RoutablePage) bool {
        return a.parent() == .fork and b.parent() == .fork and !a.eql(b);
    }

    // true when `a` and `b` are the same user paginated to a different repos
    // window. switching between a user's tabs is in-page, so
    // only a changed `start` on the repos list navigates.
    pub fn userPageChanged(a: RoutablePage, b: RoutablePage) bool {
        return switch (a) {
            .user_repos => |aa| switch (b) {
                .user_repos => |bb| std.mem.eql(u8, aa.name.slice(), bb.name.slice()) and aa.start != bb.start,
                else => false,
            },
            .user_forks => |aa| switch (b) {
                .user_forks => |bb| std.mem.eql(u8, aa.name.slice(), bb.name.slice()) and aa.start != bb.start,
                else => false,
            },
            else => false,
        };
    }

    // true when `a` and `b` are the same home list tab paginated to a different
    // window. switching between the users/repos tabs is in-page (the home page
    // holds both lists), so only a changed `after` on the same tab navigates.
    pub fn homePageChanged(a: RoutablePage, b: RoutablePage) bool {
        return switch (a) {
            .home_users => |aa| switch (b) {
                .home_users => |bb| aa != bb,
                else => false,
            },
            .home_repos => |aa| switch (b) {
                .home_repos => |bb| aa != bb,
                else => false,
            },
            else => false,
        };
    }
};

// a `RefOrOid` resolved against an on-disk repo to the commit oid it points at
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

// percent-encode a ref name for use as a single url path segment.
pub fn urlEncodeRef(aa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(aa);
    try std.Uri.Component.percentEncode(&out.writer, raw, isUnreserved);
    return out.written();
}

// a resolved ref/oid for a repo opened with `repo_kind`/`repo_opts`
pub fn ResolvedRefOrOid(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind)) type {
    return struct {
        pub const hex_len = hash.hexLen(repo_opts.hash);

        // the concrete ref/oid (a null request resolves to the default branch)
        ref_or_oid: RoutablePage.RefOrOid,
        // its branch/tag name or oid, url-encoded (ref names may contain '/', so
        // the route layer — which splits on '/' — stores them encoded). duped
        // into `aa`.
        value: []const u8,
        // the commit oid it points at
        oid: [hex_len]u8,

        const Self = @This();

        // resolve a requested ref/oid (null = the repo's default branch) to a
        // concrete ref/oid plus the commit oid it points at. `requested_value` is
        // the url-encoded form (as it appears in the route). null when it doesn't
        // resolve (an unknown branch/tag, or a malformed/unknown oid).
        pub fn init(
            repo: *rp.Repo(repo_kind, repo_opts),
            io: std.Io,
            aa: std.mem.Allocator,
            requested_ref_or_oid: ?RoutablePage.RefOrOid,
            requested_value: []const u8,
        ) !?Self {
            var ref_or_oid: RoutablePage.RefOrOid = requested_ref_or_oid orelse .branch;
            // the decoded ref name / oid to look up. a named ref arrives url-encoded.
            var value: []const u8 = if (requested_ref_or_oid == null)
                requested_value
            else
                std.Uri.percentDecodeInPlace(try aa.dupe(u8, requested_value));
            // no ref named: fall back to HEAD's branch (or its oid when detached).
            if (requested_ref_or_oid == null) {
                var head_buf: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
                if (repo.head(io, &head_buf)) |head| switch (head) {
                    .ref => |r| {
                        ref_or_oid = .branch;
                        value = r.name;
                    },
                    .oid => |o| {
                        ref_or_oid = .object;
                        value = o;
                    },
                } else |_| {}
            }

            var oid: [hex_len]u8 = undefined;
            switch (ref_or_oid) {
                .object => {
                    if (value.len != hex_len) return null;
                    @memcpy(&oid, value);
                },
                .branch, .tag => {
                    const ref_kind: rf.RefKind = if (ref_or_oid == .branch) .head else .tag;
                    oid = (repo.readRef(io, .{ .kind = ref_kind, .name = value }) catch null) orelse return null;
                },
            }
            // store url-encoded so the route layer can hold the value verbatim.
            return .{ .ref_or_oid = ref_or_oid, .value = try urlEncodeRef(aa, value), .oid = oid };
        }
    };
}

// where a repo page reads its on-disk repo from
pub const RepoSource = struct {
    path: []const u8,
    repo_kind: rp.RepoKind,
    // the user's global git config, so local mode picks up their identity and
    // their signing and ssh settings. null on the server paths, which must not
    // read whoever runs the server.
    global_config_path: ?[]const u8 = null,

    pub fn localInitOpts(self: RepoSource) rp.InitOpts {
        return .{ .path = self.path, .global_config_path = self.global_config_path };
    }

    pub fn hasBranch(self: RepoSource, io: std.Io, allocator: std.mem.Allocator, branch: []const u8) !bool {
        if (!xit.ref.validateName(branch)) return false;
        return switch (self.repo_kind) {
            inline else => |repo_kind| blk: {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, self.localInitOpts());
                defer any_repo.deinit(io, allocator);
                break :blk switch (any_repo) {
                    inline else => |*repo| (try repo.readRef(io, .{ .kind = .head, .name = branch })) != null,
                };
            },
        };
    }
};

// events created in local mode have no account behind them, so the commit
// author comes from the repo's config, which the global config feeds into.
pub const local_author_fallback = evt.CommitAuthor{ .name = "haxy", .email = "user@haxy" };

pub fn localAuthor(
    src: RepoSource,
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
) !evt.CommitAuthor {
    switch (src.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts()) catch return local_author_fallback;
            defer any_repo.deinit(io, allocator);

            switch (any_repo) {
                inline else => |*repo| {
                    var config = try repo.listConfig(io, allocator);
                    defer config.deinit();

                    const user = config.sections.get("user") orelse return local_author_fallback;
                    const name = user.get("name") orelse return local_author_fallback;
                    const email = user.get("email") orelse return local_author_fallback;
                    return .{
                        .name = try arena.allocator().dupe(u8, name),
                        .email = try arena.allocator().dupe(u8, email),
                    };
                },
            }
        },
    }
}

// per-connection mutable state. each SSH session / web session / local TUI
// run gets its own.
pub const Session = struct {
    data: Data = .{},
    // session-lifetime allocations: login/user_id, persisted prefs, queued
    // actions. lives as long as the connection.
    arena: *std.heap.ArenaAllocator,
    // current page's allocations: page data and the page-scoped strings widgets
    // build (form actions, links). owned by Nav, swapped on each navigation, so
    // it doesn't accumulate over a long-lived session. on the web/wasm paths,
    // where a render is one-shot, this points at the same arena as `arena`.
    page_arena: *std.heap.ArenaAllocator,
    haxy_moment: ?evt.AdminDB.HashMap(.read_only) = null, // db cursor (null on the wasm side)
    // filesystem io and the path to <server>/repos, for opening on-disk repos
    // during page construction. both null on wasm, which has no filesystem and
    // rebuilds pages from the serialized snapshot rather than from disk.
    io: ?std.Io = null,
    admin_repo: ?*rp.Repo(.xit, evt.admin_repo_opts) = null,
    repos_dir: ?[]const u8 = null,
    // the single on-disk repo this session views, when running in local mode
    // (haxy invoked with no arguments inside a repo). null on the server paths,
    // which resolve repos from the admin db instead.
    local: ?RepoSource = null,
    pending: std.ArrayList(Action) = .empty, // actions queued by widgets this frame
    // focus id -> the live TextInput, refreshed each frame by the views that own
    // inputs. web/wasm form handling looks widgets up here by focus id.
    text_inputs: std.AutoHashMapUnmanaged(usize, *wgt.TextInput) = .empty,
    back: enum { unavailable, available, requested } = .unavailable,
    refresh_requested: bool = false, // set by input (ctrl+r)
    // a requested forward navigation. set this (via navigate) to move to a new
    // page; Nav.sync builds it and then copies it into current_page, clearing
    // this back to null. setting current_page directly only updates the url and
    // does not navigate.
    next_page: ?RoutablePage = null,
    is_terminal: bool = false, // true on remote SSH and local TUI
    // port the web UI is served on, for the TUI/SSH footer's "http://localhost:<port>..."
    // url. null on the web itself (no footer there).
    web_port: ?u16 = null,
    // a host operation requested by a widget
    host_request: ?HostRequest = null,
    quit_requested: bool = false,

    pub const HostRequest = union(enum) {
        show_copyable_text: []const u8,
        sync_events,
    };

    pub const FormFeedback = union(enum) {
        pub const LoginFailure = enum { unknown_user, wrong_password };
        pub const ThreadFailure = enum { required_title };
        pub const PatchFailure = enum { required_title, invalid_target_branch };

        login: struct {
            failure: LoginFailure,
            username: []const u8,
        },
        issue: struct {
            failure: ThreadFailure,
            fields: ?struct {
                title: []const u8,
                tags: []const u8,
                description: []const u8,
            } = null,
        },
        patch: struct {
            failure: PatchFailure,
            fields: ?struct {
                title: []const u8,
                tags: []const u8,
                description: []const u8,
                target_branch: []const u8,
            } = null,
        },
        discussion: struct {
            failure: ThreadFailure,
            fields: ?struct {
                title: []const u8,
                tags: []const u8,
                description: []const u8,
            } = null,
        },
    };

    const Self = @This();

    // serializable data sent down to web client
    pub const Data = struct {
        user_id: ?[]const u8 = null,
        // the logged-in user's name, for the views that show it
        user_name: ?[]const u8 = null,
        // a failed form retained long enough to render it for correction
        form_feedback: ?FormFeedback = null,
        // a transient local event-sync error
        sync_failure: ?[]const u8 = null,
        current_page: RoutablePage = .default,
        // whether to render the ANSI art backdrop
        enable_ansi: bool = true,
        // the selected ANSI art. the server serializes one image for WASM so
        // the browser does not need the whole build-generated collection.
        ansi_art: []const u8 = "",
        // the bound git-service ports. absent in local mode, where remote urls
        // are not shown.
        git_http_port: ?u16 = null,
        git_ssh_port: ?u16 = null,
        git_ssh_prefix: []const u8 = "",
        // true when this session views a single local repo. unlike `local`
        // (the host-side filesystem source) this travels in the snapshot, so
        // the wasm side also parses elided link urls and hides the multi-user
        // chrome.
        is_local: bool = false,
    };

    // a user-initiated state change. widgets enqueue these on the session during
    // input instead of mutating state or touching the DB themselves; the host
    // drains them each frame (see applyAndWritePending / applyPending). this keeps DB
    // side effects out of the widget tree and gives every render path one place to
    // turn a UI action into a state change + event.
    pub const Action = union(enum) {
        toggle_ansi,
    };

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        repo: *rp.Repo(.xit, evt.admin_repo_opts),
        data: Data,
    ) !Self {
        var session = Self{
            .data = data,
            .arena = arena,
            // until a host swaps in a page-scoped arena (Nav does this), page
            // allocations land in the session arena. on the web path that's the
            // intended behavior, since the whole arena is per-request.
            .page_arena = arena,
            .admin_repo = repo,
            .haxy_moment = try evt.currentMoment(evt.admin_repo_opts, repo),
        };
        try session.loadUser();
        return session;
    }

    // load the logged-in user's name and persisted preferences from the db
    pub fn loadUser(self: *Self) !void {
        const user_id = self.data.user_id orelse return;
        const moment = self.haxy_moment orelse return;
        if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, self.arena, user_id)) |user| {
            self.data.user_name = user.event.name;
            self.data.enable_ansi = user.event.enable_ansi;
        }
    }

    pub fn userId(self: *const Self) ?[evt.event_id_size]u8 {
        const bytes = self.data.user_id orelse return null;
        if (bytes.len != evt.event_id_size) return null;
        var id: [evt.event_id_size]u8 = undefined;
        @memcpy(&id, bytes);
        return id;
    }

    pub fn formFeedback(self: *const Self, comptime tag: std.meta.Tag(FormFeedback)) ?@FieldType(FormFeedback, @tagName(tag)) {
        const feedback = self.data.form_feedback orelse return null;
        if (std.meta.activeTag(feedback) != tag) return null;
        return @field(feedback, @tagName(tag));
    }

    pub fn clearFormFeedback(self: *Self) void {
        self.data.form_feedback = null;
    }

    // the commit author for an event this session creates, or null when it may
    // not create one
    pub fn eventAuthor(self: *Self) !?evt.CommitAuthor {
        if (self.data.is_local) {
            const src = self.local orelse return local_author_fallback;
            const io = self.io orelse return local_author_fallback;
            return try localAuthor(src, io, self.page_arena.child_allocator, self.page_arena);
        }
        const user_id = self.data.user_id orelse return null;
        const moment = self.haxy_moment orelse return null;
        const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, self.page_arena, user_id)) orelse return null;
        return .{ .name = user.event.name, .email = user.event.email };
    }

    // queue an action for the host to drain this frame.
    pub fn push(self: *Self, action: Action) !void {
        try self.pending.append(self.arena.allocator(), action);
    }

    // apply a single action's in-memory effect only (no persistence).
    fn apply(self: *Self, action: Action) void {
        switch (action) {
            .toggle_ansi => self.data.enable_ansi = !self.data.enable_ansi,
        }
    }

    // drain the session's queued actions by applying them to the session.
    // used on the wasm path, which has no repo to persist to.
    pub fn applyPending(self: *Self) void {
        for (self.pending.items) |action| self.apply(action);
        self.pending.clearRetainingCapacity();
    }

    // drain the session's queued actions by applying them to the session and
    // writing them to the db
    pub fn applyAndWritePending(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        repo: *rp.Repo(.xit, evt.admin_repo_opts),
    ) !void {
        defer self.pending.clearRetainingCapacity();
        for (self.pending.items) |action| {
            self.apply(action);
            switch (action) {
                .toggle_ansi => if (self.data.user_id) |user_id| {
                    try evt.User.toggleAnsi(evt.admin_repo_opts, io, allocator, repo, user_id);
                },
            }
        }
    }

    // reload the moment from the admin repo and re-read user preferences
    pub fn reloadMoment(self: *Self, allocator: std.mem.Allocator, repo: *rp.Repo(.xit, evt.admin_repo_opts)) !void {
        const moment = try evt.currentMoment(evt.admin_repo_opts, repo);
        self.haxy_moment = moment;

        const user_id = self.data.user_id orelse return;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, user_id)) |user| {
            self.data.enable_ansi = user.event.enable_ansi;
        }
    }

    // request a forward navigation to `route`; the host consumes next_page
    // (Nav.sync on the terminal, the wasm tick on the web).
    pub fn navigate(self: *Session, route: RoutablePage) !void {
        self.clearFormFeedback();
        self.next_page = route;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, session: *Session, repo_maybe: ?*rp.Repo(.xit, evt.admin_repo_opts)) !void {
    var nav = try Nav.init(allocator, session);
    defer nav.deinit(allocator);

    var terminal = try term.Terminal.init(io, allocator);
    var terminal_live = true;
    defer if (terminal_live) terminal.deinit(io);

    // set term as active so it will be properly cooked
    // when a panic/segfault happens
    term.setActive(&terminal);
    defer term.setActive(null);

    while (!terminal.shouldQuit()) {
        const grid_changed = try terminal.render(&nav.root);

        // process any inputs.
        //
        // if the grid didn't change, then first do a blocking
        // read, so the thread will sleep until further input.
        // after that, all remaining reads are non-blocking so
        // we can process the rest of the queued inputs.
        //
        // if the grid *did* change, then only do non-blocking
        // reads. we do not want to sleep the thread because
        // there may be an animation that requires more looping.
        var blocking = !grid_changed;
        while (try terminal.readKey(io, blocking)) |key| {
            blocking = false;
            try inputKey(allocator, &nav.root, key, session);
        }

        if (session.host_request) |request| {
            session.host_request = null;
            switch (request) {
                .show_copyable_text => |copyable_text| {
                    term.setActive(null);
                    terminal.deinit(io);
                    terminal_live = false;
                    showCopyableText(io, copyable_text) catch |show_err| {
                        terminal = try term.Terminal.init(io, allocator);
                        terminal_live = true;
                        term.setActive(&terminal);
                        return show_err;
                    };
                    terminal = try term.Terminal.init(io, allocator);
                    terminal_live = true;
                    term.setActive(&terminal);
                },
                .sync_events => {
                    try nav.root.build(allocator, .{
                        .min_size = .{ .width = null, .height = null },
                        .max_size = .{ .width = terminal.size.width, .height = terminal.size.height },
                    }, nav.root.getFocus());
                    _ = try terminal.render(&nav.root);
                    try Repo.Events.performSync(allocator, session);
                },
            }
        }

        // persist queued actions when there's a repo; local mode has none,
        // so just apply in-memory
        if (repo_maybe) |repo| {
            try session.applyAndWritePending(io, allocator, repo);
            // reload so the next navigation builds its page from the current moment
            try session.reloadMoment(allocator, repo);
        } else {
            session.applyPending();
        }

        // reconcile navigation: forward to a new page, or back on escape.
        try nav.sync(allocator, session);

        // the quit button (on the quit tab) asks the host to tear down.
        if (session.quit_requested) terminal.requestQuit();

        try nav.root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = terminal.size.width, .height = terminal.size.height },
        }, nav.root.getFocus());
    }
}

fn showCopyableText(io: std.Io, copyable_text: []const u8) !void {
    const tty: ?std.Io.File = if (builtin.os.tag == .windows)
        null
    else
        try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write });
    defer if (tty) |file| file.close(io);

    const input = if (tty) |file| file else std.Io.File.stdin();
    const output = if (tty) |file| file else std.Io.File.stdout();

    var write_buf: [1024]u8 = undefined;
    var writer = output.writer(io, &write_buf);
    try writer.interface.print("\x1b[2J\x1b[Hcopy the following text and then press enter to go back:\r\n\r\n{s}\r\n", .{copyable_text});
    try writer.interface.flush();

    var read_buf: [1]u8 = undefined;
    var reader = input.reader(io, &read_buf);
    while (true) {
        const byte = try reader.interface.takeByte();
        if (byte == '\r' or byte == '\n') return;
    }
}

pub fn inputKey(allocator: std.mem.Allocator, root: *Widget, key: Key, session: *Session) !void {
    const root_focus = root.getFocus();
    const focused_before = root_focus.grandchild_id;
    var activate_in_page_link = false;
    switch (key) {
        // request a navigation pop; the host's Nav.sync goes back a page, or
        // quits when there's no history left.
        .escape => {
            session.back = .requested;
            return;
        },
        .ctrl => |letter| switch (letter) {
            'r' => {
                session.refresh_requested = true;
                return;
            },
            else => try root.input(allocator, key, root_focus),
        },
        .enter => {
            if (root_focus.grandchild_id) |gid| {
                // follow a cross-page link
                if (crossPageLink(root_focus, gid, session.data)) |route| {
                    return session.navigate(route);
                }
                if (rawLink(root_focus, gid)) |url| return requestRawLink(session, url);
            }
            activate_in_page_link = true;
            try root.input(allocator, key, root_focus);
        },
        .mouse => |mouse| {
            if (mouse.action == .press and mouse.action.press == .left) {
                var clicked: ?usize = null;
                var iter = root_focus.children.iterator();
                while (iter.next()) |entry| {
                    const child = entry.value_ptr.*;
                    if (!child.focus.focusable and !widget.isBackButton(child.focus)) continue;
                    const r = child.rect;
                    if (mouse.x >= r.x and mouse.y >= r.y and
                        mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                    {
                        clicked = entry.key_ptr.*;
                        break;
                    }
                }
                if (clicked) |focus_id| {
                    if (widget.isBackButton((root_focus.children.get(focus_id) orelse return).focus)) {
                        if (session.back == .available) session.back = .requested;
                        return;
                    }
                    // follow a cross-page link
                    if (crossPageLink(root_focus, focus_id, session.data)) |route| {
                        return session.navigate(route);
                    }
                    if (rawLink(root_focus, focus_id)) |url| {
                        if (!mouse.ctrl) try requestRawLink(session, url);
                        return;
                    }
                    root_focus.setFocus(focus_id);
                    activate_in_page_link = true;
                }
                // forward the press into the widget tree so buttons (and any
                // future click-aware widgets) can react. widgets that don't
                // care about presses ignore it.
                try root.input(allocator, key, root_focus);
            } else {
                try root.input(allocator, key, root_focus);
            }
        },
        else => try root.input(allocator, key, root_focus),
    }

    const focused_after = root_focus.grandchild_id;
    if (!activate_in_page_link and focused_before == focused_after) return;
    const focus_id = focused_after orelse return;
    if (inPageLink(root_focus, focus_id, session.data)) |route| session.data.current_page = route;
}

// a link to bytes the server serves directly rather than to a page route, so
// it never resolves to a RoutablePage
pub const raw_link_prefix = "ax:";

// a route already loaded into the current page; focusing it changes the url
// without rebuilding the page
pub const in_page_link_prefix = "ai:";

// an in-page tab's base route, or the exact current route when it is selected
pub fn inPageTabLink(session: *Session, route: RoutablePage, selected: bool) ![]const u8 {
    const target = if (selected) session.data.current_page else route;
    return std.fmt.allocPrint(session.page_arena.allocator(), "{s}{s}", .{ in_page_link_prefix, try target.toUrl(session.page_arena) });
}

// a button the web renderer covers with a file picker that posts the chosen
// file to the url after the prefix
pub const file_input_prefix = "file:";

// a submit button that overrides its enclosing form's action
pub const submit_action_prefix = "submit:";

// the url an `ax:` link points at, or null for anything else. a host that
// suppresses the anchor's own navigation needs this to follow the link.
pub fn rawLink(root_focus: *Focus, focus_id: usize) ?[]const u8 {
    const child = root_focus.children.get(focus_id) orelse return null;
    const custom = switch (child.focus.kind) {
        .custom => |c| c,
        else => return null,
    };
    if (!std.mem.startsWith(u8, custom, raw_link_prefix)) return null;
    return custom[raw_link_prefix.len..];
}

fn requestRawLink(session: *Session, url: []const u8) !void {
    session.host_request = .{ .show_copyable_text = try terminalWebUrl(session.page_arena.allocator(), session, url) };
}

pub fn terminalWebUrl(allocator: std.mem.Allocator, session: *const Session, path: []const u8) ![]const u8 {
    return if (session.web_port) |port|
        try std.fmt.allocPrint(allocator, "http://localhost:{d}{s}", .{ port, path })
    else
        path;
}

// if the focus target at focus_id is an `a:` link that should navigate (a
// different parent page, or a different files directory within the repo page),
// return its route; otherwise null. lets a host turn a click / enter on such a
// link into a navigation rather than a focus change.
pub fn crossPageLink(root_focus: *Focus, focus_id: usize, data: Session.Data) ?RoutablePage {
    const current = data.current_page;
    const route = pageLink(root_focus, focus_id, data, "a:") orelse return null;
    // a link to a different parent page always navigates; within a page, a
    // files-directory / commits-page / list-window change navigates while tab
    // links stay in-page.
    if (route.parent() != current.parent() or RoutablePage.repoPageChanged(route, current) or RoutablePage.forkPageChanged(route, current) or RoutablePage.homePageChanged(route, current) or RoutablePage.userPageChanged(route, current)) return route;
    return null;
}

// the route carried by an `ai:` focus target, or null for any other target
pub fn inPageLink(root_focus: *Focus, focus_id: usize, data: Session.Data) ?RoutablePage {
    return pageLink(root_focus, focus_id, data, in_page_link_prefix);
}

fn pageLink(root_focus: *Focus, focus_id: usize, data: Session.Data, prefix: []const u8) ?RoutablePage {
    const child = root_focus.children.get(focus_id) orelse return null;
    const custom = switch (child.focus.kind) {
        .custom => |c| c,
        else => return null,
    };
    if (!std.mem.startsWith(u8, custom, prefix)) return null;
    const path = custom[prefix.len..];
    // local sessions build (and parse) links with the repo identity elided
    return if (data.is_local) RoutablePage.fromUrlLocal(path) else RoutablePage.fromUrl(path);
}

// a display author, resolved against the admin db at read time
pub const Author = union(enum) {
    unknown,
    email: []const u8, // an email no user matches
    user_name: []const u8,

    // the commit author line's email, resolved like initFromEmail
    pub fn init(
        haxy_moment: ?evt.AdminDB.HashMap(.read_only),
        arena: *std.heap.ArenaAllocator,
        author_line: []const u8,
    ) !Author {
        return initFromEmail(haxy_moment, arena, evt.authorEmail(author_line));
    }

    // from a record's stored author email: it resolves to the user currently
    // holding it, else stays the email. the result is allocated in `arena`,
    // so the email may borrow transient memory.
    pub fn initFromEmail(
        haxy_moment: ?evt.AdminDB.HashMap(.read_only),
        arena: *std.heap.ArenaAllocator,
        author_email: ?[]const u8,
    ) !Author {
        const email = author_email orelse return .unknown;
        if (haxy_moment) |moment| {
            if (try evt.User.readByEmail(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, email)) |user| {
                return .{ .user_name = user.event.name };
            }
        }
        return .{ .email = try arena.allocator().dupe(u8, email) };
    }
};

// the "a:" link to user `name`'s page.
pub fn userLink(page_arena: *std.heap.ArenaAllocator, name: []const u8) ![]const u8 {
    const parsed = RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    const url = try (RoutablePage{ .user_repos = .{ .name = parsed } }).toUrl(page_arena);
    return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{url});
}

// a focusable " author " box showing `author`, linking to their user page
// when it is a known user
pub fn authorBox(allocator: std.mem.Allocator, page_arena: *std.heap.ArenaAllocator, author: Author) !wgt.TextBox {
    const text = switch (author) {
        .unknown => "",
        .email, .user_name => |t| t,
    };
    var tb = try wgt.TextBox.init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none, .label = " author " });
    errdefer tb.deinit(allocator);
    tb.getFocus().focusable = true;
    switch (author) {
        .user_name => |name| tb.getFocus().kind = .{ .custom = try userLink(page_arena, name) },
        else => {},
    }
    return tb;
}

// native-TUI navigation
pub const Nav = struct {
    root: Widget,
    route: RoutablePage,
    // backs the current page (its Page data and the page-scoped strings its
    // widgets build). owned here, swapped on each navigation. session.page_arena
    // tracks whichever of these is current so widgets allocate into it.
    arena: *std.heap.ArenaAllocator,
    history: std.ArrayList(Entry),

    // each retained page keeps its own arena, freed when the page leaves the
    // stack (popped on back, evicted at cap, or on deinit). this is what keeps a
    // long-lived session from accumulating every page it ever visited.
    const Entry = struct { root: Widget, route: RoutablePage, arena: *std.heap.ArenaAllocator };

    // cap on retained back-history so the chain can't grow memory without bound
    const max_history: usize = 16;

    pub fn init(allocator: std.mem.Allocator, session: *Session) !Nav {
        session.back = .unavailable;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        session.page_arena = arena;
        const route = session.data.current_page;

        const page = try arena.allocator().create(Page);
        page.* = try Page.init(arena, session, route);
        return .{
            .root = try initRoot(allocator, page, session),
            .route = route,
            .arena = arena,
            .history = .empty,
        };
    }

    pub fn deinit(self: *Nav, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        freeArena(allocator, self.arena);
        for (self.history.items) |*entry| {
            entry.root.deinit(allocator);
            freeArena(allocator, entry.arena);
        }
        self.history.deinit(allocator);
    }

    fn freeArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
        arena.deinit();
        allocator.destroy(arena);
    }

    // reconcile the displayed root with the session's navigation state. a
    // forward nav (current_page moved to a different parent page) pushes the
    // current root and builds the new page in a fresh arena; a back request
    // frees the current page and restores the previous one. when escape is
    // pressed with no history left we switch to the quit tab instead of quitting.
    pub fn sync(self: *Nav, allocator: std.mem.Allocator, session: *Session) !void {
        // refresh: rebuild the current page in place from a current moment
        if (session.refresh_requested) {
            session.refresh_requested = false;
            if (session.haxy_moment != null or session.local != null) {
                const arena = try allocator.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(allocator);
                errdefer freeArena(allocator, arena);

                session.page_arena = arena;

                const route = session.data.current_page;
                const page = try arena.allocator().create(Page);
                page.* = try Page.init(arena, session, route);
                const new_root = try initRoot(allocator, page, session);

                self.root.deinit(allocator);
                freeArena(allocator, self.arena);
                self.root = new_root;
                self.route = route;
                self.arena = arena;
            }
            return;
        }

        if (session.back == .requested) {
            if (self.history.pop()) |entry| {
                session.back = if (self.history.items.len == 0) .unavailable else .available;
                self.root.deinit(allocator);
                freeArena(allocator, self.arena);
                self.root = entry.root;
                self.route = entry.route;
                self.arena = entry.arena;
                session.page_arena = entry.arena;
                session.data.current_page = entry.route;
                chooseAnsiArtForNavigation(session);
                return;
            }
            session.back = .unavailable;
            // nothing to go back to; switch to the quit confirmation
            const root_focus = self.root.getFocus();
            var iter = root_focus.children.iterator();
            while (iter.next()) |entry| {
                switch (entry.value_ptr.focus.kind) {
                    .custom => |custom| if (std.mem.eql(u8, custom, Quit.tab_kind)) {
                        root_focus.setFocus(entry.key_ptr.*);
                        // a Stack only builds its selected child, so the quit
                        // button isn't in the focus tree until a build runs with
                        // the quit tab selected. build once, then send a
                        // synthetic arrow_down to drop focus from the tab onto
                        // the button so it's ready to confirm.
                        try self.root.build(allocator, .{
                            .min_size = .{ .width = null, .height = 40 },
                            .max_size = .{ .width = 80, .height = null },
                        }, root_focus);
                        try self.root.input(allocator, .arrow_down, root_focus);
                        break;
                    },
                    else => {},
                }
            }
            return;
        }

        // forward navigation: navigate() set next_page to the page to move to (a
        // cross-page link or tab change crossing pages)
        if (session.next_page) |route| {
            session.next_page = null;
            if (session.haxy_moment == null and session.local == null) return;
            // the page we navigated to becomes the current page
            session.data.current_page = route;
            session.back = .available;

            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer freeArena(allocator, arena);

            session.page_arena = arena;

            const page = try arena.allocator().create(Page);
            page.* = try Page.init(arena, session, route);
            const new_root = try initRoot(allocator, page, session);

            try self.history.append(allocator, .{ .root = self.root, .route = self.route, .arena = self.arena });
            // drop the oldest entry (freeing its widget tree and arena) once over cap
            if (self.history.items.len > max_history) {
                var oldest = self.history.orderedRemove(0);
                oldest.root.deinit(allocator);
                freeArena(allocator, oldest.arena);
            }
            self.root = new_root;
            self.route = route;
            self.arena = arena;
        }
    }
};

pub fn initRoot(allocator: std.mem.Allocator, page: *const Page, session: *Session) !Widget {
    const page_widget: Widget = switch (page.*) {
        .home => |*p| .{ .home = try .init(allocator, p, session) },
        .user => |*p| .{ .user = try .init(allocator, p, session) },
        .repo => |*p| .{ .repo = try .init(allocator, p, session) },
        .fork => |*p| .{ .fork = try .init(allocator, p, session) },
    };

    chooseAnsiArtForNavigation(session);

    // on the TUI/SSH, the page sits above a one-row footer showing the url
    var root = if (session.is_terminal) blk: {
        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const bg_id = bg_blk: {
            var background = try widget.AnsiBackground.init(allocator, page_widget, session);
            errdefer background.deinit(allocator);
            const id = background.getFocus().id;
            try box.children.put(allocator, id, .{ .widget = .{ .background = background }, .rect = null, .min_size = null });
            break :bg_blk id;
        };
        {
            var footer = try widget.Footer.init(allocator, session);
            errdefer footer.deinit(allocator);
            try box.children.put(allocator, footer.getFocus().id, .{ .widget = .{ .footer = footer }, .rect = null, .min_size = .{ .width = null, .height = 1 } });
        }
        box.getFocus().child_id = bg_id;
        break :blk Widget{ .box = box };
    } else Widget{ .background = try widget.AnsiBackground.init(allocator, page_widget, session) };
    errdefer root.deinit(allocator);

    // input-owning views build their TextInputs in init, so reset their
    // registrations here
    session.text_inputs.clearRetainingCapacity();

    try root.build(allocator, .{
        .min_size = .{ .width = null, .height = 40 },
        .max_size = .{ .width = 100, .height = null },
    }, root.getFocus());

    return root;
}

// native and server-side sessions choose from the embedded collection. WASM
// keeps the art serialized by the server instead.
fn chooseAnsiArtForNavigation(session: *Session) void {
    if (comptime ansi_arts.len == 0) return;
    const io = session.io orelse return;
    var random: usize = undefined;
    io.random(std.mem.asBytes(&random));
    session.data.ansi_art = ansi_arts[random % ansi_arts.len];
}

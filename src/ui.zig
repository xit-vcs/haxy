const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;
const xitui = xit.xitui;
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const evt = @import("./event.zig");

pub const Home = @import("./ui/Home.zig");
pub const User = @import("./ui/User.zig");
pub const Repo = @import("./ui/Repo.zig");
pub const Title = @import("./ui/Title.zig");
pub const SubTitle = @import("./ui/SubTitle.zig");
pub const Quit = @import("./ui/Quit.zig");

pub const PageKind = enum {
    home,
    user,
    repo,
};

pub const Page = union(PageKind) {
    home: Home,
    user: User,
    repo: Repo,

    pub fn init(arena: *std.heap.ArenaAllocator, session: *Session, route: RoutablePage) !Page {
        const haxy_moment = session.haxy_moment orelse return error.NoMoment;
        return switch (route.parent()) {
            .home => .{ .home = try Home.init(arena, haxy_moment, switch (route) {
                .home_users => |after| after,
                else => 0,
            }, switch (route) {
                .home_repos => |after| after,
                else => 0,
            }) },
            .user => switch (route) {
                .user_repos => |u| .{ .user = try User.init(arena, haxy_moment, u.name, u.after) },
                .user_settings, .user_auth => |name| .{ .user = try User.init(arena, haxy_moment, name, 0) },
                else => return error.UnexpectedRoute,
            },
            .repo => switch (route) {
                .repo_files, .repo_commits, .repo_refs, .repo_settings, .repo_auth => .{ .repo = try Repo.init(arena, session, route) },
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
    user_repos: struct { name: Array(evt.User.name_max_len), after: usize = 0 },
    user_settings: Array(evt.User.name_max_len),
    user_auth: Array(evt.User.name_max_len),
    repo_files: struct { name: Array(repo_route_max_len), after: usize = 0 },
    repo_commits: struct { name: Array(repo_route_max_len), after: usize = 0 },
    repo_refs: struct { name: Array(repo_route_max_len), kind: RefKind = .branch, after: usize = 0 },
    repo_settings: Array(repo_route_max_len),
    repo_auth: Array(repo_route_max_len),

    pub const default: RoutablePage = .{ .home_users = 0 };

    pub const RefKind = enum { branch, tag };

    pub const RefOrOid = enum {
        branch,
        tag,
        object,

        fn fromSeg(s: []const u8) ?RefOrOid {
            return std.meta.stringToEnum(RefOrOid, s);
        }
    };

    const user_segment = "/user/";
    const repo_segment = "/repo/";
    const files_seg = "files";
    const commits_seg = "commits";

    // a repo route is "username/reponame", optionally followed by the files tab's
    // "/files/<refkind>/<refvalue>/<dir>" (refkind/refvalue name the ref the tree
    // is read at). the bare "username/reponame" (and "username/reponame/files")
    // mean the files root of the repo's default branch.
    pub const repo_route_max_len = 1024;

    // the parts of a `.repo_files` route. all slices point into the route's
    // stored string. ref_kind is null (and ref_value/dir empty) for the bare
    // default-branch root; dir is "" at a ref's root.
    pub const RepoFiles = struct {
        identity: []const u8, // "owner/name"
        owner: []const u8,
        name: []const u8,
        ref_kind: ?RefOrOid,
        ref_value: []const u8,
        dir: []const u8,

        // parse a `.repo_files` route's stored string ("owner/name" or
        // "owner/name/files/<refkind>/<refvalue>[/<dir>]").
        pub fn parse(s: []const u8) ?RepoFiles {
            const s1 = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            const owner = s[0..s1];
            const after = s[s1 + 1 ..];
            const s2 = std.mem.indexOfScalar(u8, after, '/');
            const name = if (s2) |i| after[0..i] else after;
            if (owner.len == 0 or name.len == 0) return null;
            var result: RepoFiles = .{
                .identity = s[0 .. s1 + 1 + name.len],
                .owner = owner,
                .name = name,
                .ref_kind = null,
                .ref_value = "",
                .dir = "",
            };
            // the tail after "owner/name/". absent (or a bare "files") = default root.
            const tail = if (s2) |i| after[i + 1 ..] else return result;
            if (std.mem.eql(u8, tail, files_seg)) return result;
            if (!std.mem.startsWith(u8, tail, files_seg ++ "/")) return result;
            // "<refkind>/<refvalue>[/<dir>]"
            const ref_part = tail[files_seg.len + 1 ..];
            const k1 = std.mem.indexOfScalar(u8, ref_part, '/') orelse return result;
            const kind = RefOrOid.fromSeg(ref_part[0..k1]) orelse return result;
            const after_kind = ref_part[k1 + 1 ..];
            const k2 = std.mem.indexOfScalar(u8, after_kind, '/');
            const value = if (k2) |i| after_kind[0..i] else after_kind;
            if (value.len == 0) return result;
            result.ref_kind = kind;
            result.ref_value = value;
            result.dir = if (k2) |i| after_kind[i + 1 ..] else "";
            return result;
        }
    };

    // build a `.repo_files` route for "owner/name" (identity) at `dir` ("" = the
    // ref's root) pinned to `ref_kind`/`ref_value`, showing the file content
    // window starting at line `after` (0 = the first window, dropped from the
    // url). a null ref_kind yields the bare default-branch root. null if the
    // result doesn't fit the inline name.
    pub fn repoFilesRoute(identity: []const u8, ref_kind: ?RefOrOid, ref_value: []const u8, dir: []const u8, after: usize) ?RoutablePage {
        const kind = ref_kind orelse return .{ .repo_files = .{ .name = Array(repo_route_max_len).from(identity) orelse return null, .after = after } };
        var buf: [repo_route_max_len]u8 = undefined;
        const s = if (dir.len == 0)
            std.fmt.bufPrint(&buf, "{s}/" ++ files_seg ++ "/{s}/{s}", .{ identity, @tagName(kind), ref_value }) catch return null
        else
            std.fmt.bufPrint(&buf, "{s}/" ++ files_seg ++ "/{s}/{s}/{s}", .{ identity, @tagName(kind), ref_value, dir }) catch return null;
        return .{ .repo_files = .{ .name = Array(repo_route_max_len).from(s) orelse return null, .after = after } };
    }

    // the ref/oid a `.repo_commits` route's stored string walks from. kind is
    // null for the bare "owner/name/commits" (the repo's default branch). the
    // returned value slices into `s`.
    pub const CommitsRef = struct { ref_or_oid: ?RefOrOid, value: []const u8 };
    pub fn repoCommitsRef(s: []const u8) CommitsRef {
        const marker = "/" ++ commits_seg ++ "/";
        const i = std.mem.indexOf(u8, s, marker) orelse return .{ .ref_or_oid = null, .value = "" };
        const ref_part = s[i + marker.len ..]; // "<refkind>/<refvalue>"
        const k1 = std.mem.indexOfScalar(u8, ref_part, '/') orelse return .{ .ref_or_oid = null, .value = "" };
        const kind = RefOrOid.fromSeg(ref_part[0..k1]) orelse return .{ .ref_or_oid = null, .value = "" };
        const value = ref_part[k1 + 1 ..];
        if (value.len == 0) return .{ .ref_or_oid = null, .value = "" };
        return .{ .ref_or_oid = kind, .value = value };
    }

    // build a `.repo_commits` route for "owner/name" (identity), walking from
    // `ref_or_oid`/`value` (a null ref_or_oid yields the bare default-branch
    // route). always carries the `commits` marker so the bare route
    // ("owner/name/commits") doesn't collide with the files root.
    pub fn repoCommitsRoute(identity: []const u8, ref_or_oid: ?RefOrOid, value: []const u8, after: usize) ?RoutablePage {
        var buf: [repo_route_max_len]u8 = undefined;
        const s = if (ref_or_oid) |kind|
            std.fmt.bufPrint(&buf, "{s}/" ++ commits_seg ++ "/{s}/{s}", .{ identity, @tagName(kind), value }) catch return null
        else
            std.fmt.bufPrint(&buf, "{s}/" ++ commits_seg, .{identity}) catch return null;
        return .{ .repo_commits = .{ .name = Array(repo_route_max_len).from(s) orelse return null, .after = after } };
    }

    // build a `.repo_refs` route for "owner/name" (identity) paginating `kind`'s
    // column to `after` (0 = the first window, the other column always at 0).
    pub fn repoRefsRoute(identity: []const u8, kind: RefKind, after: usize) ?RoutablePage {
        return .{ .repo_refs = .{ .name = Array(repo_route_max_len).from(identity) orelse return null, .kind = kind, .after = after } };
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
        };
    }

    pub fn url(comptime self: RoutablePage) []const u8 {
        return switch (self) {
            .home_users => "/users",
            .home_repos => "/repos",
            .home_settings => "/settings",
            .home_auth => "/auth",
            .user_repos, .user_settings, .user_auth => @compileError("user routes are dynamic; use urlAlloc"),
            .repo_files, .repo_commits, .repo_refs, .repo_settings, .repo_auth => @compileError("repo routes are dynamic; use urlAlloc"),
        };
    }

    pub fn urlAlloc(self: RoutablePage, arena: *std.heap.ArenaAllocator) ![]const u8 {
        return switch (self) {
            .home_users => |after| if (after == 0) @as([]const u8, "/users") else try std.fmt.allocPrint(arena.allocator(), "/users?after={d}", .{after}),
            .home_repos => |after| if (after == 0) @as([]const u8, "/repos") else try std.fmt.allocPrint(arena.allocator(), "/repos?after={d}", .{after}),
            .user_repos => |u| if (u.after == 0)
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/repos", .{u.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/repos?after={d}", .{ u.name.slice(), u.after }),
            .user_settings => |name| try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/settings", .{name.slice()}),
            .user_auth => |name| try std.fmt.allocPrint(arena.allocator(), user_segment ++ "{s}/auth", .{name.slice()}),
            .repo_files => |f| if (f.after == 0)
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}", .{f.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}?after={d}", .{ f.name.slice(), f.after }),
            .repo_commits => |c| if (c.after == 0)
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}", .{c.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}?after={d}", .{ c.name.slice(), c.after }),
            .repo_refs => |r| if (r.after == 0)
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}/refs", .{r.name.slice()})
            else
                try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}/refs?kind={s}&after={d}", .{ r.name.slice(), @tagName(r.kind), r.after }),
            .repo_settings => |name| try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}/settings", .{name.slice()}),
            .repo_auth => |name| try std.fmt.allocPrint(arena.allocator(), repo_segment ++ "{s}/auth", .{name.slice()}),
            inline else => |_, tag| url(tag),
        };
    }

    pub fn parent(self: RoutablePage) PageKind {
        return switch (self) {
            .home_users, .home_repos, .home_settings, .home_auth => .home,
            .user_repos, .user_settings, .user_auth => .user,
            .repo_files, .repo_commits, .repo_refs, .repo_settings, .repo_auth => .repo,
        };
    }

    // parse a path plus its raw query string
    pub fn fromUrl(path: []const u8, query: ?[]const u8) ?RoutablePage {
        const after = uintParam(query, "after") orelse 0;
        if (std.mem.eql(u8, path, "/")) return default;
        if (std.mem.eql(u8, path, "/users")) return .{ .home_users = after };
        if (std.mem.eql(u8, path, "/repos")) return .{ .home_repos = after };
        if (std.mem.eql(u8, path, "/settings")) return .home_settings;
        if (std.mem.eql(u8, path, "/auth")) return .home_auth;
        // /user/<name>[/repos|/settings|/auth]
        if (std.mem.startsWith(u8, path, user_segment)) {
            const rest = path[user_segment.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const name = if (slash) |s| rest[0..s] else rest;
            if (name.len == 0) return null;
            const parsed = Array(evt.User.name_max_len).from(name) orelse return null; // name too long
            if (slash) |s| {
                const sub = rest[s + 1 ..];
                if (std.mem.eql(u8, sub, "repos")) return .{ .user_repos = .{ .name = parsed, .after = after } };
                if (std.mem.eql(u8, sub, "settings")) return .{ .user_settings = parsed };
                if (std.mem.eql(u8, sub, "auth")) return .{ .user_auth = parsed };
                return null; // unknown sub-path
            }
            return .{ .user_repos = .{ .name = parsed, .after = after } };
        }
        // /repo/<username>/<reponame> (files root), then optionally /settings,
        // /auth, or /files/<dir> for a directory in the files tab. the `repo`
        // variant stores "username/reponame" (root) or
        // "username/reponame/files/<dir>"; settings/auth store just the pair.
        if (std.mem.startsWith(u8, path, repo_segment)) {
            const rest = path[repo_segment.len..];
            const user_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            const after_user = rest[user_slash + 1 ..];
            const repo_slash = std.mem.indexOfScalar(u8, after_user, '/');
            const repo_name = if (repo_slash) |s| after_user[0..s] else after_user;
            // reject an empty username or reponame
            if (user_slash == 0 or repo_name.len == 0) return null;
            const pair = rest[0 .. user_slash + 1 + repo_name.len]; // "username/reponame"
            if (repo_slash) |s| {
                const sub = after_user[s + 1 ..];
                if (std.mem.eql(u8, sub, "refs")) return .{ .repo_refs = .{
                    .name = Array(repo_route_max_len).from(pair) orelse return null,
                    .kind = refsKind(query),
                    .after = after,
                } };
                if (std.mem.eql(u8, sub, "settings")) return .{ .repo_settings = Array(repo_route_max_len).from(pair) orelse return null };
                if (std.mem.eql(u8, sub, "auth")) return .{ .repo_auth = Array(repo_route_max_len).from(pair) orelse return null };
                if (std.mem.eql(u8, sub, files_seg)) return repoFilesRoute(pair, null, "", "", after); // trailing /files == default-branch root
                if (std.mem.startsWith(u8, sub, files_seg ++ "/")) {
                    // "files/<refkind>/<refvalue>[/<dir>]"
                    const ref_part = sub[files_seg.len + 1 ..];
                    const k1 = std.mem.indexOfScalar(u8, ref_part, '/') orelse return null;
                    const kind = RefOrOid.fromSeg(ref_part[0..k1]) orelse return null;
                    const after_kind = ref_part[k1 + 1 ..];
                    const k2 = std.mem.indexOfScalar(u8, after_kind, '/');
                    const value = if (k2) |i| after_kind[0..i] else after_kind;
                    if (value.len == 0) return null;
                    const dir = if (k2) |i| after_kind[i + 1 ..] else "";
                    return repoFilesRoute(pair, kind, value, dir, after);
                }
                if (std.mem.eql(u8, sub, commits_seg)) return repoCommitsRoute(pair, null, "", after); // trailing /commits == default branch
                if (std.mem.startsWith(u8, sub, commits_seg ++ "/")) {
                    // "commits/<refkind>/<refvalue>"
                    const ref_part = sub[commits_seg.len + 1 ..];
                    const k1 = std.mem.indexOfScalar(u8, ref_part, '/') orelse return null;
                    const kind = RefOrOid.fromSeg(ref_part[0..k1]) orelse return null;
                    const value = ref_part[k1 + 1 ..];
                    if (value.len == 0) return null;
                    return repoCommitsRoute(pair, kind, value, after);
                }
                return null; // unknown sub-path
            }
            return repoFilesRoute(pair, null, "", "", after);
        }
        return null;
    }

    // the refs column a "kind=" query param names; absent or unrecognized reads
    // as the branches column.
    fn refsKind(query: ?[]const u8) RefKind {
        const qs = query orelse return .branch;
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], "kind") and std.mem.eql(u8, pair[eq + 1 ..], "tag")) return .tag;
        }
        return .branch;
    }

    // read a "key=<uint>" value from a raw "a=1&b=2" query string.
    fn uintParam(query: ?[]const u8, key: []const u8) ?usize {
        const qs = query orelse return null;
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key))
                return std.fmt.parseInt(usize, pair[eq + 1 ..], 10) catch null;
        }
        return null;
    }

    pub fn eql(a: RoutablePage, b: RoutablePage) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .home_users => |a_after| a_after == b.home_users,
            .home_repos => |a_after| a_after == b.home_repos,
            .user_repos => |a_u| std.mem.eql(u8, a_u.name.slice(), b.user_repos.name.slice()) and a_u.after == b.user_repos.after,
            .user_settings => |a_name| std.mem.eql(u8, a_name.slice(), b.user_settings.slice()),
            .user_auth => |a_name| std.mem.eql(u8, a_name.slice(), b.user_auth.slice()),
            .repo_files => |a_f| std.mem.eql(u8, a_f.name.slice(), b.repo_files.name.slice()) and a_f.after == b.repo_files.after,
            .repo_commits => |a_c| std.mem.eql(u8, a_c.name.slice(), b.repo_commits.name.slice()) and a_c.after == b.repo_commits.after,
            .repo_refs => |a_r| std.mem.eql(u8, a_r.name.slice(), b.repo_refs.name.slice()) and a_r.kind == b.repo_refs.kind and a_r.after == b.repo_refs.after,
            .repo_settings => |a_name| std.mem.eql(u8, a_name.slice(), b.repo_settings.slice()),
            .repo_auth => |a_name| std.mem.eql(u8, a_name.slice(), b.repo_auth.slice()),
            else => true,
        };
    }

    // true when following a link from `b` to `a` (both repo routes) should reload
    // rather than stay in page
    pub fn repoPageChanged(a: RoutablePage, b: RoutablePage) bool {
        if (a.parent() != .repo or b.parent() != .repo) return false;
        if (std.meta.activeTag(a) == .repo_refs and std.meta.activeTag(b) == .repo_refs and
            a.repo_refs.after == 0 and b.repo_refs.after == 0)
            return !std.mem.eql(u8, a.repo_refs.name.slice(), b.repo_refs.name.slice());
        return !a.eql(b);
    }

    // true when `a` and `b` are the same user paginated to a different repos
    // window. switching between a user's tabs is in-page (header-handled), so
    // only a changed `after` on the repos list navigates.
    pub fn userPageChanged(a: RoutablePage, b: RoutablePage) bool {
        return switch (a) {
            .user_repos => |aa| switch (b) {
                .user_repos => |bb| std.mem.eql(u8, aa.name.slice(), bb.name.slice()) and aa.after != bb.after,
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

    // serialize as { "kind": <tag>, "name"?: <name>, "after"?: <n> }. the default
    // union(enum) codec doesn't round-trip here: Stringify emits a void
    // variant as a bare tag string, but the parser expects an object — so the
    // server->wasm Snapshot JSON would fail to parse.
    pub fn jsonStringify(self: RoutablePage, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(@tagName(self));
        switch (self) {
            .user_repos => |u| {
                try jw.objectField("name");
                try jw.write(u.name.slice());
                try jw.objectField("after");
                try jw.write(u.after);
            },
            .user_settings, .user_auth => |name| {
                try jw.objectField("name");
                try jw.write(name.slice());
            },
            .repo_settings, .repo_auth => |name| {
                try jw.objectField("name");
                try jw.write(name.slice());
            },
            .repo_files => |f| {
                try jw.objectField("name");
                try jw.write(f.name.slice());
                try jw.objectField("after");
                try jw.write(f.after);
            },
            .repo_commits => |c| {
                try jw.objectField("name");
                try jw.write(c.name.slice());
                try jw.objectField("after");
                try jw.write(c.after);
            },
            .repo_refs => |r| {
                try jw.objectField("name");
                try jw.write(r.name.slice());
                // "kind" already holds the union tag, so the paginated column
                // travels under a distinct field.
                try jw.objectField("ref_kind");
                try jw.write(@tagName(r.kind));
                try jw.objectField("after");
                try jw.write(r.after);
            },
            .home_users, .home_repos => |after| {
                try jw.objectField("after");
                try jw.write(after);
            },
            else => {},
        }
        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !RoutablePage {
        const Helper = struct { kind: std.meta.Tag(RoutablePage), name: ?[]const u8 = null, after: usize = 0, ref_kind: ?[]const u8 = null };
        const helper = try std.json.innerParse(Helper, allocator, source, options);
        const parseName = struct {
            // errors must stay within std.json's ParseError set; ValueTooLong
            // is its member for an over-long field.
            fn f(comptime max_len: usize, maybe: ?[]const u8) !Array(max_len) {
                return Array(max_len).from(maybe orelse return error.MissingField) orelse error.ValueTooLong;
            }
        }.f;
        return switch (helper.kind) {
            .home_users => .{ .home_users = helper.after },
            .home_repos => .{ .home_repos = helper.after },
            .home_settings => .home_settings,
            .home_auth => .home_auth,
            .user_repos => .{ .user_repos = .{ .name = try parseName(evt.User.name_max_len, helper.name), .after = helper.after } },
            .user_settings => .{ .user_settings = try parseName(evt.User.name_max_len, helper.name) },
            .user_auth => .{ .user_auth = try parseName(evt.User.name_max_len, helper.name) },
            .repo_files => .{ .repo_files = .{ .name = try parseName(repo_route_max_len, helper.name), .after = helper.after } },
            .repo_commits => .{ .repo_commits = .{ .name = try parseName(repo_route_max_len, helper.name), .after = helper.after } },
            .repo_refs => .{ .repo_refs = .{
                .name = try parseName(repo_route_max_len, helper.name),
                .kind = if (helper.ref_kind) |k| (if (std.mem.eql(u8, k, "tag")) .tag else .branch) else .branch,
                .after = helper.after,
            } },
            .repo_settings => .{ .repo_settings = try parseName(repo_route_max_len, helper.name) },
            .repo_auth => .{ .repo_auth = try parseName(repo_route_max_len, helper.name) },
        };
    }
};

// a `RefOrOid` resolved against an on-disk repo to the commit oid it points at
pub const ResolvedRefOrOid = struct {
    // the hex-oid length for the default repo options the on-disk repos use
    pub const hex_len = hash.hexLen((rp.RepoOpts(.xit){}).hash);

    // the concrete ref/oid (a null request resolves to the default branch)
    ref_or_oid: RoutablePage.RefOrOid,
    // its branch/tag name or oid, url-encoded (ref names may contain '/', so the
    // route layer — which splits on '/' — stores them encoded). duped into `aa`.
    value: []const u8,
    // the commit oid it points at
    oid: [hex_len]u8,

    // resolve a requested ref/oid (null = the repo's default branch) to a
    // concrete ref/oid plus the commit oid it points at. `requested_value` is the
    // url-encoded form (as it appears in the route). null when it doesn't resolve
    // (an unknown branch/tag, or a malformed/unknown oid).
    pub fn init(
        repo: *rp.Repo(.xit, .{}),
        io: std.Io,
        aa: std.mem.Allocator,
        requested_ref_or_oid: ?RoutablePage.RefOrOid,
        requested_value: []const u8,
    ) !?ResolvedRefOrOid {
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
        return .{ .ref_or_oid = ref_or_oid, .value = try urlEncode(aa, value), .oid = oid };
    }

    fn isUnreserved(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
    }

    // percent-encode a ref name for use as a single url path segment.
    pub fn urlEncode(aa: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(aa);
        try std.Uri.Component.percentEncode(&out.writer, raw, isUnreserved);
        return out.written();
    }
};

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
    repos_dir: ?[]const u8 = null,
    pending: std.ArrayList(Action) = .empty, // actions queued by widgets this frame
    // focus id -> the live TextInput, refreshed each frame by the views that own
    // inputs. web/wasm form handling looks widgets up here by focus id.
    text_inputs: std.AutoHashMapUnmanaged(usize, *wgt.TextInput(Widget)) = .empty,
    nav_back: bool = false, // set by input (escape) to request the native TUI pop a page; see Nav
    // a requested forward navigation. set this (via navigate) to move to a new
    // page; Nav.sync builds it and then copies it into current_page, clearing
    // this back to null. setting current_page directly only updates the url and
    // does not navigate.
    next_page: ?RoutablePage = null,
    is_terminal: bool = false, // true on remote SSH and local TUI
    // port the web UI is served on, for the TUI/SSH footer's "http://localhost:<port>..."
    // url. null on the web itself (no footer there).
    web_port: ?u16 = null,
    quit_requested: bool = false,

    const Self = @This();

    // serializable data sent down to web client
    pub const Data = struct {
        user_id: ?[]const u8 = null,
        // a transient outcome to surface from the last /login POST attempt
        login_failure: ?Home.Auth.Login.Failure = null,
        current_page: RoutablePage = .default,
        // whether to render the ANSI art backdrop
        enable_ansi: bool = true,
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
            .haxy_moment = try evt.currentMoment(evt.admin_repo_opts, repo),
        };
        try session.loadUserPrefs();
        return session;
    }

    // load the logged-in user's persisted preferences from the db
    pub fn loadUserPrefs(self: *Self) !void {
        const user_id = self.data.user_id orelse return;
        const moment = self.haxy_moment orelse return;
        if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, self.arena, user_id)) |user| {
            self.data.enable_ansi = user.enable_ansi;
        }
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

    // reload the moment from the admin repo
    pub fn reloadMoment(self: *Self, repo: *rp.Repo(.xit, evt.admin_repo_opts)) !void {
        self.haxy_moment = try evt.currentMoment(evt.admin_repo_opts, repo);
    }

    // request a forward navigation to `route`; the host consumes next_page
    // (Nav.sync on the terminal, the wasm tick on the web).
    pub fn navigate(self: *Session, route: RoutablePage) !void {
        self.next_page = route;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, session: *Session, repo: *rp.Repo(.xit, evt.admin_repo_opts)) !void {
    var nav = try Nav.init(allocator, session);
    defer nav.deinit(allocator);

    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);

    // set term as active so it will be properly cooked
    // when a panic/segfault happens
    term.setActive(&terminal);
    defer term.setActive(null);

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    while (!terminal.shouldQuit()) {
        const grid_changed = try terminal.render(&nav.root, &last_grid, &last_size);

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

        // local run has no repo to persist to, so just apply in-memory
        session.applyPending();

        // pick up data written by other handles so the next navigation
        // builds its page from a current moment
        try session.reloadMoment(repo);

        // reconcile navigation: forward to a new page, or back on escape.
        try nav.sync(allocator, session);

        // the quit button (on the quit tab) asks the host to tear down.
        if (session.quit_requested) terminal.requestQuit();

        try nav.root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, nav.root.getFocus());
    }
}

pub fn inputKey(allocator: std.mem.Allocator, root: *Widget, key: inp.Key, session: *Session) !void {
    switch (key) {
        // request a navigation pop; the host's Nav.sync goes back a page, or
        // quits when there's no history left.
        .escape => session.nav_back = true,
        .enter => {
            const root_focus = root.getFocus();
            if (root_focus.grandchild_id) |gid| {
                // follow a cross-page link
                if (crossPageLink(root_focus, gid, session.data.current_page)) |route| {
                    return session.navigate(route);
                }
            }
            try root.input(allocator, key, root_focus);
        },
        .mouse => |mouse| {
            if (mouse.action == .press and mouse.action.press == .left) {
                const root_focus = root.getFocus();
                var clicked: ?usize = null;
                var iter = root_focus.children.iterator();
                while (iter.next()) |entry| {
                    const child = entry.value_ptr.*;
                    if (!child.focus.focusable) continue;
                    const r = child.rect;
                    if (mouse.x >= r.x and mouse.y >= r.y and
                        mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                    {
                        clicked = entry.key_ptr.*;
                        break;
                    }
                }
                if (clicked) |focus_id| {
                    // follow a cross-page link
                    if (crossPageLink(root_focus, focus_id, session.data.current_page)) |route| {
                        return session.navigate(route);
                    }
                    root_focus.setFocus(focus_id);
                }
                // forward the press into the widget tree so buttons (and any
                // future click-aware widgets) can react. widgets that don't
                // care about presses ignore it.
                try root.input(allocator, key, root.getFocus());
            } else {
                try root.input(allocator, key, root.getFocus());
            }
        },
        else => try root.input(allocator, key, root.getFocus()),
    }
}

// if the focus target at focus_id is an `a:` link that should navigate (a
// different parent page, or a different files directory within the repo page),
// return its route; otherwise null. lets a host turn a click / enter on such a
// link into a navigation rather than a focus change.
pub fn crossPageLink(root_focus: *Focus, focus_id: usize, current: RoutablePage) ?RoutablePage {
    const child = root_focus.children.get(focus_id) orelse return null;
    const custom = switch (child.focus.kind) {
        .custom => |c| c,
        else => return null,
    };
    const a_prefix = "a:";
    if (!std.mem.startsWith(u8, custom, a_prefix)) return null;
    const url = custom[a_prefix.len..];
    const q = std.mem.indexOfScalar(u8, url, '?');
    const route = RoutablePage.fromUrl(if (q) |i| url[0..i] else url, if (q) |i| url[i + 1 ..] else null) orelse return null;
    // a link to a different parent page always navigates; within a page, a
    // files-directory / commits-page / list-window change navigates while tab
    // links stay in-page (header-handled).
    if (route.parent() != current.parent() or RoutablePage.repoPageChanged(route, current) or RoutablePage.homePageChanged(route, current) or RoutablePage.userPageChanged(route, current)) return route;
    return null;
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
        if (session.nav_back) {
            session.nav_back = false;
            if (self.history.pop()) |entry| {
                self.root.deinit(allocator);
                freeArena(allocator, self.arena);
                self.root = entry.root;
                self.route = entry.route;
                self.arena = entry.arena;
                session.page_arena = entry.arena;
                session.data.current_page = entry.route;
                return;
            }
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
            if (session.haxy_moment == null) return;
            // the page we navigated to becomes the current page
            session.data.current_page = route;

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
    };

    const demon_art = @embedFile("embed/demon.ans");

    // on the TUI/SSH, the page sits above a one-row footer showing the url
    var root = if (session.is_terminal) blk: {
        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const bg_id = bg_blk: {
            var background = try AnsiBackground.init(allocator, page_widget, demon_art, session);
            errdefer background.deinit(allocator);
            const id = background.getFocus().id;
            try box.children.put(allocator, id, .{ .widget = .{ .background = background }, .rect = null, .min_size = null });
            break :bg_blk id;
        };
        {
            var footer = try Footer.init(allocator, session);
            errdefer footer.deinit(allocator);
            try box.children.put(allocator, footer.getFocus().id, .{ .widget = .{ .footer = footer }, .rect = null, .min_size = .{ .width = null, .height = 1 } });
        }
        box.getFocus().child_id = bg_id;
        break :blk Widget{ .box = box };
    } else Widget{ .background = try AnsiBackground.init(allocator, page_widget, demon_art, session) };
    errdefer root.deinit(allocator);

    // input-owning views build their TextInputs in init — so reset the
    // focus-id -> *TextInput map here
    session.text_inputs.clearRetainingCapacity();

    try root.build(allocator, .{
        .min_size = .{ .width = null, .height = 40 },
        .max_size = .{ .width = 80, .height = null },
    }, root.getFocus());

    return root;
}

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    text_input: wgt.TextInput(Widget),
    scroll: wgt.Scroll(Widget),
    stack: wgt.Stack(Widget),
    flow_box: FlowBox,
    flow_box_scroll: FlowBox.Scroll,
    spacer: Spacer,
    center: Center,
    ansi_art: AnsiArt,
    background: AnsiBackground,
    home: Home.View,
    user: User.View,
    repo: Repo.View,
    quit: Quit.View,
    title: Title.View,
    sub_title: SubTitle.View,
    home_header: Home.Header.View,
    user_header: User.Header.View,
    repo_header: Repo.Header.View,
    repo_sub_header: Repo.SubHeader.View,
    repo_files: Repo.Files.View,
    repo_commits: Repo.Commits.View,
    repo_refs: Repo.Refs.View,
    home_users: Home.Users.View,
    home_repos: Home.Repos.View,
    auth_tab: Home.Header.AuthTab.View,
    home_settings: Home.Settings.View,
    home_auth: Home.Auth.View,
    footer: Footer,

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }

    pub fn build(self: *Widget, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(allocator, constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(allocator, key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

pub const FlowBox = struct {
    focus: *Focus,
    grid: ?Grid,
    text_boxes: std.ArrayList(wgt.TextBox(Widget)),
    // backs the per-item strings the text boxes borrow: each box's `content`
    // and, for link items, its `.custom` focus kind (e.g. "a:/user/foo"). reset
    // wholesale on each setItems so there's no per-string ownership to track.
    arena: std.heap.ArenaAllocator,
    // column count from the last build — FlowBox.Scroll.input uses it so arrow
    // up/down can step by a row's worth of items.
    last_cols: usize,
    options: Options,

    const border_rows: usize = 2;

    pub const Options = struct {
        cell_width: usize = 40,
        cell_height: usize = 3,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !FlowBox {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .text_boxes = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .last_cols = 1,
            .options = options,
        };
    }

    pub fn deinit(self: *FlowBox, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.deinit(allocator);
        self.arena.deinit();
    }

    // one flow item: its display text plus an optional link. a non-empty `link`
    // sets the item's focus kind such as `.{ .custom = "a:/user/foo" }`, which
    // the web renderer turns into an anchor.
    pub const Item = struct { text: []const u8, link: []const u8 = "" };

    // both the item text and the link are copied into the arena, so the caller's
    // slices needn't outlive this call.
    pub fn setItems(self: *FlowBox, allocator: std.mem.Allocator, items: []const Item) !void {
        for (self.text_boxes.items) |*tb| tb.deinit(allocator);
        self.text_boxes.clearAndFree(allocator);

        // the old text boxes (and their borrowed content/links) are gone now, so
        // the arena that backed those strings can be reclaimed.
        _ = self.arena.reset(.retain_capacity);
        const aa = self.arena.allocator();

        self.focus.clear();
        self.focus.child_id = null;

        for (items) |item| {
            const line = try aa.dupe(u8, item.text);

            var text_box = try wgt.TextBox(Widget).init(allocator, line, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;

            if (item.link.len > 0) {
                text_box.getFocus().kind = .{ .custom = try aa.dupe(u8, item.link) };
            }

            try self.text_boxes.append(allocator, text_box);
        }

        if (self.text_boxes.items.len > 0) {
            self.focus.child_id = self.text_boxes.items[0].getFocus().id;
        }
    }

    pub fn build(self: *FlowBox, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.focus.clear();

        const cell_width = self.options.cell_width;
        const max_width = constraint.max_size.width orelse cell_width;
        const cols = if (cell_width == 0) 1 else @max(1, max_width / cell_width);
        self.last_cols = cols;

        const count = self.text_boxes.items.len;
        if (count == 0) return;
        const slot_height = self.options.cell_height + border_rows;
        if (slot_height == 0) return;

        // build at the slot size so every text box fits a single grid cell
        for (self.text_boxes.items) |*tb| {
            tb.options.border_style = if (self.focus.child_id == tb.getFocus().id) .single else .hidden;
            try tb.build(allocator, .{
                .min_size = .{ .width = cell_width, .height = null },
                .max_size = .{ .width = cell_width, .height = slot_height },
            }, root_focus);
        }

        const rows = (count + cols - 1) / cols;
        const content_height = rows * slot_height;
        const total_width = cols * cell_width;
        if (total_width == 0 or content_height == 0) return;

        var grid = try Grid.init(allocator, .{ .width = total_width, .height = content_height });
        errdefer grid.deinit();

        for (self.text_boxes.items, 0..) |*tb, i| {
            const tb_grid = tb.getGrid() orelse continue;
            const col = i % cols;
            const row = i / cols;
            const cell_x = col * cell_width;
            const cell_y = row * slot_height;
            try self.focus.addChild(allocator, tb.getFocus(), tb_grid.size, cell_x, cell_y);
            try grid.drawGrid(tb_grid, cell_x, cell_y);
        }

        self.grid = grid;
    }

    pub fn input(self: *FlowBox, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *FlowBox) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        for (self.text_boxes.items) |*tb| tb.clearGrid();
    }

    pub fn getGrid(self: FlowBox) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *FlowBox) *Focus {
        return self.focus;
    }

    pub fn cellRect(self: FlowBox, index: usize) ?layout.IRect {
        if (self.last_cols == 0 or index >= self.text_boxes.items.len) return null;
        const slot_height = self.options.cell_height + border_rows;
        const col = index % self.last_cols;
        const row = index / self.last_cols;
        return .{
            .x = @intCast(col * self.options.cell_width),
            .y = @intCast(row * slot_height),
            .size = .{ .width = self.options.cell_width, .height = slot_height },
        };
    }

    pub fn indexOfFocusId(self: FlowBox, focus_id: usize) ?usize {
        for (self.text_boxes.items, 0..) |tb, i| {
            if (tb.box.focus.id == focus_id) return i;
        }
        return null;
    }

    pub const Scroll = struct {
        scroll: wgt.Scroll(Widget),

        pub fn init(allocator: std.mem.Allocator, options: FlowBox.Options, web_native: bool) !Scroll {
            var layout_inner = try FlowBox.init(allocator, options);
            errdefer layout_inner.deinit(allocator);
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .flow_box = layout_inner }, .{ .direction = .vert, .web_native = web_native });
            errdefer scroll.deinit(allocator);
            return .{ .scroll = scroll };
        }

        pub fn deinit(self: *Scroll, allocator: std.mem.Allocator) void {
            self.scroll.deinit(allocator);
        }

        pub fn setItems(self: *Scroll, allocator: std.mem.Allocator, items: []const Item) !void {
            self.scroll.x = 0;
            self.scroll.y = 0;
            try self.inner().setItems(allocator, items);
        }

        pub fn build(self: *Scroll, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            try self.scroll.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Scroll, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = allocator;
            const in = self.inner();
            const child_id = in.focus.child_id orelse return;
            const current_index = in.indexOfFocusId(child_id) orelse return;
            const count = in.text_boxes.items.len;
            if (count == 0) return;
            const cols = in.last_cols;
            const slot_height = in.options.cell_height + FlowBox.border_rows;

            var index = current_index;
            switch (key) {
                .arrow_up => index -|= cols,
                .arrow_down => if (index + cols < count) {
                    index += cols;
                },
                .arrow_left => index -|= 1,
                .arrow_right => if (index + 1 < count) {
                    index += 1;
                },
                .home => index = 0,
                .end => index = count - 1,
                .page_up => {
                    if (self.scroll.grid) |grid| if (slot_height > 0) {
                        const rows_per_page = grid.size.height / slot_height;
                        index -|= rows_per_page * cols;
                    };
                },
                .page_down => {
                    if (self.scroll.grid) |grid| if (slot_height > 0) {
                        const rows_per_page = grid.size.height / slot_height;
                        index = @min(index + rows_per_page * cols, count - 1);
                    };
                },
                // scroll wheel moves the focused cell by a full row so the
                // viewport (via scrollToRect) follows in row-sized steps,
                // matching how a scroll wheel feels in a grid view.
                .mouse => |mouse| switch (mouse.action) {
                    .scroll => |dir| switch (dir) {
                        .up => index -|= cols,
                        .down => if (index + cols < count) {
                            index += cols;
                        },
                    },
                    else => {},
                },
                else => {},
            }

            if (index != current_index) {
                root_focus.setFocus(in.text_boxes.items[index].getFocus().id);
                if (in.cellRect(index)) |rect| {
                    self.scroll.scrollToRect(rect);
                }
            }
        }

        pub fn clearGrid(self: *Scroll) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: Scroll) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *Scroll) *Focus {
            return self.scroll.getFocus();
        }

        pub fn getSelectedIndex(self: Scroll) ?usize {
            const in = self.scroll.child.flow_box;
            const child_id = in.focus.child_id orelse return null;
            return in.indexOfFocusId(child_id);
        }

        fn inner(self: *Scroll) *FlowBox {
            return &self.scroll.child.flow_box;
        }
    };
};

// an invisible widget that fills the horizontal space granted by its parent.
// used inside Box(horiz) with a min_size so the box reserves space for the
// children that follow, pushing them to the right.
pub const Spacer = struct {
    focus: *Focus,
    grid: ?Grid,

    pub fn init(allocator: std.mem.Allocator) !Spacer {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
        };
    }

    pub fn deinit(self: *Spacer, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn build(self: *Spacer, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();
        const width = constraint.max_size.width orelse return;
        if (width == 0) return;
        self.grid = try Grid.init(allocator, .{ .width = width, .height = 1 });
    }

    pub fn input(self: *Spacer, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *Spacer) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: Spacer) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Spacer) *Focus {
        return self.focus;
    }
};

// a one-row, non-focusable status bar showing the current page's url
pub const Footer = struct {
    focus: *Focus,
    grid: ?Grid,
    session: *Session,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, session: *Session) !Footer {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .session = session,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Footer, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| grid.deinit();
        self.arena.deinit();
    }

    pub fn build(self: *Footer, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();
        const width = constraint.max_size.width orelse return;
        if (width == 0) return;

        _ = self.arena.reset(.retain_capacity);
        const aa = self.arena.allocator();
        const path = self.session.data.current_page.urlAlloc(&self.arena) catch return;
        const text = if (self.session.web_port) |port|
            std.fmt.allocPrint(aa, "http://localhost:{d}{s}", .{ port, path }) catch return
        else
            path;

        var grid = try Grid.init(allocator, .{ .width = width, .height = 1 });
        errdefer grid.deinit();
        var utf8 = (std.unicode.Utf8View.init(text) catch return).iterator();
        var i: usize = 0;
        while (utf8.nextCodepointSlice()) |ch| {
            if (i == width) break;
            grid.cells.items[try grid.cells.at(.{ 0, i })].rune = ch;
            i += 1;
        }
        self.grid = grid;
    }

    pub fn input(self: *Footer, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *Footer) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: Footer) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Footer) *Focus {
        return self.focus;
    }
};

// a single-child wrapper that builds the child at its natural size and
// positions its grid in the middle of the area granted by the parent
pub const Center = struct {
    focus: *Focus,
    grid: ?Grid,
    child: *Widget,
    direction: Direction,

    pub const Direction = enum { both, horiz, vert };

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget, direction: Direction) !Center {
        const child = try allocator.create(Widget);
        errdefer allocator.destroy(child);
        child.* = child_widget;
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .child = child,
            .direction = direction,
        };
    }

    pub fn deinit(self: *Center, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.deinit(allocator);
        allocator.destroy(self.child);
    }

    pub fn build(self: *Center, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        self.getFocus().clear();

        // build the child without forcing it to fill min_size; it sizes
        // itself to its content within the available max.
        try self.child.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);

        const child_grid = self.child.getGrid() orelse return;

        // prefer max when given; otherwise grow to max(min, child) so that
        // when only a min is set (e.g. the wasm path passes viewport rows
        // as min_height with no max), we can still vertically center while
        // letting taller content extend past the min.
        const width = if (constraint.max_size.width) |w| w else if (constraint.min_size.width) |min_w| @max(min_w, child_grid.size.width) else child_grid.size.width;
        const height = if (constraint.max_size.height) |h| h else if (constraint.min_size.height) |min_h| @max(min_h, child_grid.size.height) else child_grid.size.height;
        if (width == 0 or height == 0) return;

        const offset_x: usize = if (self.direction == .horiz or self.direction == .both)
            (width -| child_grid.size.width) / 2
        else
            0;
        const offset_y: usize = if (self.direction == .vert or self.direction == .both)
            (height -| child_grid.size.height) / 2
        else
            0;

        var grid = try Grid.init(allocator, .{ .width = width, .height = height });
        errdefer grid.deinit();
        try grid.drawGrid(child_grid, offset_x, offset_y);
        try self.getFocus().addChild(allocator, self.child.getFocus(), child_grid.size, offset_x, offset_y);
        self.getFocus().child_id = self.child.getFocus().id;

        self.grid = grid;
    }

    pub fn input(self: *Center, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        try self.child.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *Center) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.clearGrid();
    }

    pub fn getGrid(self: Center) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *Center) *Focus {
        return self.focus;
    }
};

// renders truecolor ANSI art
pub const AnsiArt = struct {
    focus: *Focus,
    grid: ?Grid,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !AnsiArt {
        return .{
            .focus = try Focus.create(allocator, .container),
            .grid = null,
            .content = content,
        };
    }

    pub fn deinit(self: *AnsiArt, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn build(self: *AnsiArt, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        _ = root_focus;
        self.clearGrid();

        // parse into rows of cells, then copy into a rectangular grid
        var rows: std.ArrayList(std.ArrayList(Grid.Cell)) = .empty;
        defer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }
        var row: std.ArrayList(Grid.Cell) = .empty;
        errdefer row.deinit(allocator);

        var style: Grid.Style = .{};
        var width: usize = 0;
        const content = self.content;
        var i: usize = 0;
        while (i < content.len) {
            const byte = content[i];
            if (byte == '\n') {
                width = @max(width, row.items.len);
                try rows.append(allocator, row);
                row = .empty;
                i += 1;
            } else if (byte == 0x1B and i + 1 < content.len and content[i + 1] == '[') {
                // CSI: scan to the final byte (0x40..0x7E); apply it if it's 'm'
                var j = i + 2;
                while (j < content.len and !(content[j] >= 0x40 and content[j] <= 0x7E)) j += 1;
                if (j >= content.len) {
                    i = content.len; // malformed trailing escape; stop
                } else {
                    if (content[j] == 'm') applySgr(&style, content[i + 2 .. j]);
                    i = j + 1;
                }
            } else {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                const end = @min(content.len, i + len);
                const rune = content[i..end];
                const transparent = end - i == 1 and rune[0] == ' ' and
                    style.fg == null and style.bg == null and !style.inverted;
                try row.append(allocator, .{
                    .rune = if (transparent) null else rune,
                    .style = style,
                });
                i = end;
            }
        }
        // a trailing row with content but no closing newline
        if (row.items.len > 0) {
            width = @max(width, row.items.len);
            try rows.append(allocator, row);
        } else {
            row.deinit(allocator);
        }
        row = .empty; // ownership moved into rows (or freed); keep errdefer safe

        const height = rows.items.len;
        if (width == 0 or height == 0) return;

        const clamped_w = @min(width, constraint.max_size.width orelse width);
        const clamped_h = @min(height, constraint.max_size.height orelse height);

        var grid = try Grid.init(allocator, .{ .width = clamped_w, .height = clamped_h });
        errdefer grid.deinit();
        for (rows.items[0..clamped_h], 0..) |r, y| {
            const n = @min(r.items.len, clamped_w);
            for (r.items[0..n], 0..) |cell, x| {
                grid.cells.items[try grid.cells.at(.{ y, x })] = cell;
            }
        }
        self.grid = grid;
    }

    pub fn input(self: *AnsiArt, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *AnsiArt) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn getGrid(self: AnsiArt) ?Grid {
        return self.grid;
    }

    pub fn getFocus(self: *AnsiArt) *Focus {
        return self.focus;
    }

    fn applySgr(style: *Grid.Style, params: []const u8) void {
        var nums: [16]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |tok| {
            if (n >= nums.len) break;
            // an empty parameter (e.g. bare "\x1b[m") means 0
            nums[n] = std.fmt.parseInt(u32, tok, 10) catch 0;
            n += 1;
        }
        if (n == 0) {
            style.* = .{};
            return;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            switch (nums[i]) {
                0 => style.* = .{},
                7 => style.inverted = true,
                27 => style.inverted = false,
                39 => style.fg = null,
                49 => style.bg = null,
                38, 48 => {
                    // truecolor form: 38;2;r;g;b — anything else is ignored
                    if (i + 4 < n and nums[i + 1] == 2) {
                        const c = Grid.Color{
                            .r = @truncate(nums[i + 2]),
                            .g = @truncate(nums[i + 3]),
                            .b = @truncate(nums[i + 4]),
                        };
                        if (nums[i] == 38) style.fg = c else style.bg = c;
                        i += 4;
                    }
                },
                else => {},
            }
        }
    }
};

// a full-screen wrapper that renders ANSI art behind whatever page it wraps
pub const AnsiBackground = struct {
    grid: ?Grid,
    child: *Widget,
    art: AnsiArt,
    session: *Session,

    pub fn init(allocator: std.mem.Allocator, child_widget: Widget, art_content: []const u8, session: *Session) !AnsiBackground {
        var cw = child_widget;
        const child = allocator.create(Widget) catch |e| {
            cw.deinit(allocator);
            return e;
        };
        child.* = cw;
        errdefer {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        return .{ .grid = null, .child = child, .art = try AnsiArt.init(allocator, art_content), .session = session };
    }

    pub fn deinit(self: *AnsiBackground, allocator: std.mem.Allocator) void {
        if (self.grid) |*grid| grid.deinit();
        self.art.deinit(allocator);
        self.child.deinit(allocator);
        allocator.destroy(self.child);
    }

    pub fn build(self: *AnsiBackground, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        // make the wrapped page fill the whole available area
        try self.child.build(allocator, .{
            .min_size = .{
                .width = constraint.max_size.width orelse constraint.min_size.width,
                .height = constraint.max_size.height orelse constraint.min_size.height,
            },
            .max_size = constraint.max_size,
        }, root_focus);

        if (self.session.data.enable_ansi) {
            if (self.child.getGrid()) |fg| {
                self.grid = try artBehind(allocator, fg, &self.art, .top_right, root_focus);
            }
        }
    }

    pub fn input(self: *AnsiBackground, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        try self.child.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *AnsiBackground) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        self.child.clearGrid();
        self.art.clearGrid();
    }

    pub fn getGrid(self: AnsiBackground) ?Grid {
        return self.grid orelse self.child.getGrid();
    }

    pub fn getFocus(self: *AnsiBackground) *Focus {
        return self.child.getFocus();
    }

    // which top corner the art hugs.
    const ArtAnchor = enum { top_left, top_right };

    // a foreground cell counts as blank if it's empty or a bare space without styling
    fn cellIsBlank(cell: Grid.Cell) bool {
        if (cell.rune) |rune| {
            return std.mem.eql(u8, rune, " ") and
                cell.style.fg == null and cell.style.bg == null and !cell.style.inverted;
        }
        return true;
    }

    // the art is dimmed to this fraction of its brightness so foreground text
    // stays legible over it
    const art_brightness = 45; // percent

    fn dimColor(color: ?Grid.Color) ?Grid.Color {
        const c = color orelse return null;
        return .{
            .r = @intCast(@as(u16, c.r) * art_brightness / 100),
            .g = @intCast(@as(u16, c.g) * art_brightness / 100),
            .b = @intCast(@as(u16, c.b) * art_brightness / 100),
        };
    }

    // terminals that don't support truecolor misparse a "38;2;r;g;b"/"48;2;…"
    // SGR as a list of plain SGR codes, so any channel value in 1..9 turns on
    // a text attribute (5/6 = blink, 7 = inverse, 8 = conceal, …).
    // snap such channels clear of that range so the backdrop doesn't blink or
    // hide text there; the ≤9/255 shift is imperceptible on terminals that
    // actually render truecolor.
    fn sgrSafe(color: ?Grid.Color) ?Grid.Color {
        const c = color orelse return null;
        const snap = struct {
            fn f(v: u8) u8 {
                return if (v >= 1 and v <= 9) 10 else v;
            }
        }.f;
        return .{ .r = snap(c.r), .g = snap(c.g), .b = snap(c.b) };
    }

    // composites ANSI art behind a foreground grid
    fn artBehind(allocator: std.mem.Allocator, foreground: Grid, art: *AnsiArt, anchor: ArtAnchor, root_focus: *Focus) !Grid {
        art.clearGrid();
        try art.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = foreground.size.width, .height = foreground.size.height },
        }, root_focus);

        var out = try Grid.initFromGrid(allocator, foreground, foreground.size, 0, 0);
        errdefer out.deinit();

        if (art.getGrid()) |art_grid| {
            const anchor_x = switch (anchor) {
                .top_left => 0,
                .top_right => foreground.size.width -| art_grid.size.width,
            };
            for (0..art_grid.size.height) |y| {
                for (0..art_grid.size.width) |x| {
                    const src = art_grid.cells.items[try art_grid.cells.at(.{ y, x })];
                    if (src.rune == null) continue;
                    const idx = out.cells.at(.{ y, anchor_x + x }) catch continue;
                    const dst = &out.cells.items[idx];
                    // composite the dimmed art behind every cell so it shows
                    // through the whole UI: a blank cell becomes the art, while a
                    // cell with a glyph keeps the glyph but takes the dimmed art as
                    // its background (replacing whatever background it had, which
                    // would otherwise obscure the art).
                    if (cellIsBlank(dst.*)) {
                        dst.* = src;
                        dst.style.fg = sgrSafe(dimColor(dst.style.fg));
                        dst.style.bg = sgrSafe(dimColor(dst.style.bg));
                    } else {
                        dst.style.bg = sgrSafe(dimColor(src.style.bg orelse src.style.fg));
                    }
                }
            }
        }
        return out;
    }
};

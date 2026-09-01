const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const widget = @import("../widget.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("../input.zig");
const diff3 = @import("../../diff3.zig");
const Comment = @import("../Repo/Comment.zig");
const Attachment = @import("../Repo/Attachment.zig");

const Widget = widget.Widget;
const TagFlow = widget.TagFlow;
const Center = widget.Center;
const SubmitButton = widget.SubmitButton;
const Spacer = widget.Spacer;
const SectionLabel = widget.SectionLabel;
const moveRowFocus = widget.moveRowFocus;
const wasm = builtin.target.cpu.arch == .wasm32;

// read the selected thread's conflicted fields and attribute each side to its
// event commit author
pub fn readConflict(
    comptime Data: type,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    id_bytes: *const [evt.event_id_size]u8,
    ours: Data.Event.Record,
    conflict_entry: evt.EventDB(repo_opts.hash).HashMap(.read_only),
) !Data.Conflict {
    const Event = Data.Event;
    const DB = evt.EventDB(repo_opts.hash);
    const aa = arena.allocator();

    const fields_cursor = (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key))) orelse return error.NotFound;
    const conflicted_fields = try fields_cursor.readBytesAlloc(aa, null);
    const their_cursor = (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key))) orelse return error.NotFound;
    const theirs = try evt.read(Event.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(their_cursor));

    // absent when both sides created the thread independently
    var base: ?Event.Record = null;
    if (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.base_record_key))) |base_cursor| {
        base = try evt.read(Event.Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(base_cursor));
    }

    var their_field_oids: ?DB.SortedMap(.read_only) = null;
    if (try conflict_entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_field_to_oid_key))) |cursor|
        their_field_oids = try DB.SortedMap(.read_only).init(cursor);
    var our_field_oids: ?DB.SortedMap(.read_only) = null;
    if (try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, Event.id_to_field_to_oid_key))) |map_cursor| {
        const id_to_field_to_oid = try DB.HashMap(.read_only).init(map_cursor);
        if (try id_to_field_to_oid.getCursor(hash.hashInt(repo_opts.hash, id_bytes))) |cursor|
            our_field_oids = try DB.SortedMap(.read_only).init(cursor);
    }

    var conflict = Data.Conflict{};
    var field_iter = std.mem.splitScalar(u8, conflicted_fields, ' ');
    while (field_iter.next()) |field| {
        const our_author = try oidAuthor(repo_kind, repo_opts, arena, repo, io, admin_moment, try readFieldOid(repo_opts.hash, our_field_oids, field));
        const their_author = try oidAuthor(repo_kind, repo_opts, arena, repo, io, admin_moment, try readFieldOid(repo_opts.hash, their_field_oids, field));
        if (std.mem.eql(u8, field, "title")) {
            conflict.title = .{
                .ours = .{ .text = ours.event.title, .author = our_author },
                .theirs = .{ .text = theirs.event.title, .author = their_author },
            };
        } else if (std.mem.eql(u8, field, "tags")) {
            conflict.tags = .{
                .ours = .{ .text = ours.event.tags, .author = our_author },
                .theirs = .{ .text = theirs.event.tags, .author = their_author },
            };
        } else if (std.mem.eql(u8, field, "description")) {
            conflict.description = .{
                .chunks = try diff3.chunks(io, arena.child_allocator, arena, if (base) |b| b.event.description else "", ours.event.description, theirs.event.description),
                .ours_author = our_author,
                .theirs_author = their_author,
            };
        } else if (comptime @hasField(Data.Conflict, "status")) {
            if (std.mem.eql(u8, field, "status")) {
                conflict.status = .{
                    .ours = .{ .text = @tagName(Data.statusKind(ours.event)), .author = our_author },
                    .theirs = .{ .text = @tagName(Data.statusKind(theirs.event)), .author = their_author },
                };
            } else if (std.mem.eql(u8, field, "revision")) {
                conflict.revision = .{
                    .ours = .{ .text = try revisionSummary(aa, ours.event.revision), .author = our_author },
                    .theirs = .{ .text = try revisionSummary(aa, theirs.event.revision), .author = their_author },
                };
            } else if (std.mem.eql(u8, field, "target_branch")) {
                conflict.target_branch = .{
                    .ours = .{ .text = ours.event.target_branch, .author = our_author },
                    .theirs = .{ .text = theirs.event.target_branch, .author = their_author },
                };
            }
        }
    }
    return conflict;
}

fn revisionSummary(allocator: std.mem.Allocator, revision_maybe: ?evt.Patch.Revision) ![]const u8 {
    const revision = revision_maybe orelse return "(none)";
    return std.fmt.allocPrint(allocator, "squash {s}\nsource {s}", .{ revision.squash_oid, revision.source_oid });
}

fn readFieldOid(
    comptime hash_kind: hash.HashKind,
    field_oids_maybe: ?evt.EventDB(hash_kind).SortedMap(.read_only),
    field: []const u8,
) !?[hash.byteLen(hash_kind)]u8 {
    const field_oids = field_oids_maybe orelse return null;
    const cursor = (try field_oids.getCursor(field)) orelse return null;
    var oid: [hash.byteLen(hash_kind)]u8 = undefined;
    _ = try cursor.readBytes(&oid);
    return oid;
}

fn oidAuthor(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    oid_maybe: ?[hash.byteLen(repo_opts.hash)]u8,
) !ui.Author {
    const oid = oid_maybe orelse return .unknown;
    const gpa = arena.child_allocator;
    var start_oids = [_][hash.hexLen(repo_opts.hash)]u8{std.fmt.bytesToHex(oid, .lower)};
    var commit_iter = repo.log(io, gpa, start_oids[0..1]) catch return .unknown;
    defer commit_iter.deinit();
    const commit_object = (commit_iter.next(gpa) catch return .unknown) orelse return .unknown;
    defer commit_object.deinit();
    return try ui.Author.init(admin_moment, arena, commit_object.content.commit.metadata.author orelse "");
}

pub fn statusSet(
    comptime Data: type,
    comptime DB: type,
    statuses: DB.SortedMap(.read_only),
    status: Data.Status,
) !?DB.SortedSet(.read_only) {
    const cursor = (try statuses.getCursor(@tagName(status))) orelse return null;
    return try DB.SortedSet(.read_only).init(cursor);
}

pub fn tagStatusSet(
    comptime Data: type,
    comptime DB: type,
    tag_statuses: DB.SortedMap(.read_only),
    tag: []const u8,
    status: Data.Status,
) !?DB.SortedSet(.read_only) {
    var key_buffer: Data.Event.TagStatusKey = undefined;
    const key = Data.Event.tagStatusKey(&key_buffer, tag, status) catch return null;
    const cursor = (try tag_statuses.getCursor(key)) orelse return null;
    return try DB.SortedSet(.read_only).init(cursor);
}

pub fn loadTags(
    comptime Data: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
) ![]const []const u8 {
    const aa = arena.allocator();
    const DB = evt.EventDB(hash_kind);
    const cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, Data.Event.tag_status_to_id_set_key)) orelse return &.{};
    const tag_statuses = try DB.SortedMap(.read_only).init(cursor);
    var tags: std.ArrayList([]const u8) = .empty;
    var iter = try tag_statuses.iterator();
    while (try iter.next()) |pair_cursor| {
        if (tags.items.len == Data.max_tags) break;
        var entry_cursor = pair_cursor;
        const pair = try entry_cursor.readKeyValuePair();
        const key = try pair.key_cursor.readBytesAlloc(aa, null);
        const space = std.mem.indexOfScalar(u8, key, ' ') orelse continue;
        const tag = key[0..space];
        if (tags.getLastOrNull()) |last| {
            if (std.mem.eql(u8, last, tag)) continue;
        }
        try tags.append(aa, tag);
    }
    return tags.items;
}

pub fn loadWindow(
    comptime Data: type,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    records: evt.EventDB(hash_kind).HashMap(.read_only),
    set_maybe: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    root_key: ?[]const u8,
    conflict_set: ?evt.EventDB(hash_kind).SortedSet(.read_only),
    selected_id: []const u8,
    comments_start: usize,
) !Data.Window {
    const set = set_maybe orelse return .empty;
    const DB = evt.EventDB(hash_kind);
    const aa = arena.allocator();

    var prev_id: ?[]const u8 = null;
    var iter = if (root_key) |key| blk: {
        const rank = try set.rank(key);
        if (rank > 0 and rank <= Data.page_size) {
            prev_id = "";
        } else if (rank > Data.page_size) {
            const pair = try set.getIndexKeyValuePair(@intCast(rank - Data.page_size)) orelse return error.NotFound;
            var previous: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try pair.key_cursor.readBytes(&previous);
            const hex = std.fmt.bytesToHex(previous[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &hex);
        }
        break :blk try set.iteratorFrom(key);
    } else try set.iteratorFromIndex(0);

    var items: std.ArrayList(Data.Entry) = .empty;
    var next_id: ?[]const u8 = null;
    while (try iter.next()) |cursor_value| {
        var cursor = cursor_value;
        const pair = try cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try pair.key_cursor.readBytes(&order_key);
        const id = order_key[@sizeOf(u64)..];
        const id_hex = std.fmt.bytesToHex(id.*, .lower);
        if (items.items.len == Data.page_size) {
            next_id = try aa.dupe(u8, &id_hex);
            break;
        }
        const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse continue;
        const record = try evt.read(Data.Event.Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
        try items.append(aa, .{
            .id = try aa.dupe(u8, &id_hex),
            .record = record,
            .author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email),
            .conflicted = if (conflict_set) |conflicts| try conflicts.contains(&order_key) else false,
            .comments = try Comment.loadWindow(
                hash_kind,
                arena,
                admin_moment,
                haxy_moment,
                evt.Comment.thread_id_to_comment_id_set_key,
                &id_hex,
                if (std.mem.eql(u8, &id_hex, selected_id)) comments_start else 0,
            ),
            .attachments = try Attachment.load(hash_kind, arena, haxy_moment, &id_hex),
        });
    }

    return .{
        .items = items.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

// the common tab strip used by each thread page's sub-header
pub const Header = struct {
    box: wgt.Box(Widget),
    // focus id -> semantic stack index; some pages omit unavailable tabs
    tab_ids: std.AutoArrayHashMapUnmanaged(usize, usize),

    pub fn init(allocator: std.mem.Allocator) !Header {
        var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        return .{ .box = box, .tab_ids = .empty };
    }

    pub fn addTab(self: *Header, allocator: std.mem.Allocator, label: []const u8, link: []const u8, view_index: usize) !void {
        var text_box = try wgt.TextBox.init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = link };
        try self.tab_ids.put(allocator, text_box.getFocus().id, view_index);
        try self.box.children.put(allocator, text_box.getFocus().id, .{
            .widget = .{ .text_box = text_box },
            .rect = null,
            .min_size = .{ .width = label.len + 2, .height = null },
        });
    }

    pub fn select(self: *Header, view_index: usize) void {
        for (self.tab_ids.keys(), self.tab_ids.values()) |id, index| {
            if (index == view_index) {
                self.getFocus().child_id = id;
                return;
            }
        }
    }

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        self.tab_ids.deinit(allocator);
    }

    pub fn build(self: *Header, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        // only the selected tab shows its border
        for (self.box.children.keys(), self.box.children.values()) |id, *child| {
            switch (child.widget) {
                .text_box => |*tb| tb.options.border_style = if (self.getFocus().child_id == id) .single else .hidden,
                else => {},
            }
        }
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *Header, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const current_tab = self.currentTabIndex() orelse return;
        if (inp.moveTab(key, current_tab, self.tab_ids.count())) |new_tab| {
            root_focus.setFocus(self.tab_ids.keys()[new_tab]);
        }
    }

    pub fn clearGrid(self: *Header) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Header) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Header) *Focus {
        return self.box.getFocus();
    }

    pub fn getSelectedIndex(self: Header) ?usize {
        const index = self.currentTabIndex() orelse return null;
        return self.tab_ids.values()[index];
    }

    fn currentTabIndex(self: Header) ?usize {
        const child_id = self.box.focus.child_id orelse return null;
        return self.tab_ids.getIndex(child_id);
    }
};

// the selected thread's scrollable contents, shared by repo and fork views
pub fn Detail(comptime kind: evt.EventKind, comptime Data: type) type {
    const Entry = Data.Entry;
    const Event = Data.Event;
    const Status = Data.Status;
    const has_status = @hasField(Event, "status");
    const supports_conflicts = Event.merge_policy == .field_conflicts;
    const supports_drafts = @hasField(Data, "drafts");
    const supports_forks = @hasField(Entry, "fork_exists");
    const supports_merge = @hasDecl(Data, "mergeRoute");
    return struct {
        const This = @This();
        const thread_name = Data.thread_name;

        pub const Exit = enum { none, list, header };
        pub const Options = struct { actions: bool = true };

        scroll: wgt.Scroll(Widget),
        data: *const Data,
        session: *ui.Session,
        entry: ?Entry,
        title_id: ?usize,
        description_id: ?usize,
        author_id: ?usize,
        actions: bool,
        exit: Exit,

        const tool_row_index: usize = 0;

        pub fn init(allocator: std.mem.Allocator, data: *const Data, session: *ui.Session, entry: ?Entry, options: Options) !This {
            var content = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer content.deinit(allocator);
            var detail_scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = content }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            errdefer detail_scroll.deinit(allocator);

            var self: This = .{
                .scroll = detail_scroll,
                .data = data,
                .session = session,
                .entry = null,
                .title_id = null,
                .description_id = null,
                .author_id = null,
                .actions = options.actions,
                .exit = .none,
            };
            if (entry) |value| try self.setEntry(allocator, value);
            return self;
        }

        pub fn deinit(self: *This, allocator: std.mem.Allocator) void {
            self.scroll.deinit(allocator);
        }

        pub fn build(self: *This, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            try self.scroll.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            _ = try self.inputWithExit(allocator, key, root_focus);
        }

        pub fn clearGrid(self: *This) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: This) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *This) *Focus {
            return self.scroll.getFocus();
        }

        fn inner(self: *This) *wgt.Box(Widget) {
            return &self.scroll.child.box;
        }

        fn toolRow(self: *This) *wgt.Box(Widget) {
            return &self.inner().children.values()[tool_row_index].widget.box;
        }

        fn entryConflicted(entry: Entry) bool {
            return if (supports_conflicts) entry.conflicted else false;
        }

        fn entryStatus(entry: Entry) Status {
            if (comptime has_status) return Data.statusKind(entry.record.event);
            return @enumFromInt(0);
        }

        fn entryDraft(entry: Entry) bool {
            return if (supports_drafts) entry.draft else false;
        }

        fn entryHasFork(entry: Entry) bool {
            return if (supports_forks) entry.fork_exists else false;
        }

        const StatusChange = struct {
            action: []const u8,
            status: Status,
        };

        fn statusChange(status: Status) ?StatusChange {
            const name = @tagName(status);
            if (std.mem.eql(u8, name, "open")) return .{
                .action = "close",
                .status = std.meta.stringToEnum(Status, "closed") orelse return null,
            };
            if (std.mem.eql(u8, name, "closed")) return .{
                .action = "open",
                .status = std.meta.stringToEnum(Status, "open") orelse return null,
            };
            return null;
        }

        fn listRoute(identity: []const u8, status: Status, tag: []const u8, selected: []const u8) ?ui.RoutablePage {
            return Data.listRoute(identity, status, tag, selected);
        }

        fn draftsRoute(identity: []const u8) ?ui.RoutablePage {
            return if (supports_drafts) Data.draftsRoute(identity) else null;
        }

        fn publishRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
            return if (supports_drafts) Data.publishRoute(identity, selected) else null;
        }

        fn mergeRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
            return if (supports_merge) Data.mergeRoute(identity, selected) else null;
        }

        fn forkRoute(identity: []const u8, id: []const u8) ?ui.RoutablePage {
            return if (supports_forks) Data.forkRoute(identity, id) else null;
        }

        fn resolveRoute(identity: []const u8, selected: []const u8, picks: []const u8) ?ui.RoutablePage {
            return if (supports_conflicts) Data.resolveRoute(identity, selected, picks) else null;
        }

        fn listLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: Status, tag: []const u8, id: []const u8) ![]const u8 {
            const route = listRoute(identity, status, tag, id) orelse return error.RouteTooLong;
            return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.toUrl(page_arena)});
        }

        fn tagLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: Status, tag: []const u8) ![]const u8 {
            const encoded = try ui.urlEncodeRef(page_arena.allocator(), tag);
            return listLink(page_arena, identity, status, encoded, "");
        }

        fn addToolButton(allocator: std.mem.Allocator, row: *wgt.Box(Widget), label: []const u8, action: []const u8) !void {
            var button = try wgt.TextBox.init(allocator, label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            button.getFocus().kind = .{ .custom = action };
            try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = try xitui.width.displayWidth(label) + 2, .height = null } });
        }

        pub fn setEntry(self: *This, allocator: std.mem.Allocator, entry: Entry) !void {
            const inner_box = self.inner();
            const description_page = self.data.description_page and std.mem.eql(u8, entry.id, self.data.selected_id);
            const comment_page = if (std.mem.eql(u8, entry.id, self.data.selected_id)) self.data.comment_page else null;

            for (inner_box.children.values()) |*child| child.widget.deinit(allocator);
            inner_box.children.clearAndFree(allocator);
            inner_box.getFocus().child_id = null;
            self.entry = entry;
            self.title_id = null;
            self.author_id = null;

            {
                var row = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
                errdefer row.deinit(allocator);
                try inner_box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
            }
            if (self.actions and !description_page and comment_page == null) {
                const row = self.toolRow();
                const pa = self.session.page_arena.allocator();

                if (entryHasFork(entry) and self.session.data.current_page.parent() != .fork) {
                    const route = forkRoute(self.data.identity, entry.id) orelse return error.RouteTooLong;
                    try addToolButton(allocator, row, "view fork", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                }

                {
                    var spacer = try Spacer.init(allocator);
                    errdefer spacer.deinit(allocator);
                    try row.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
                }

                if (comptime supports_merge) {
                    if (Data.canMerge(entry, self.session)) {
                        const route = mergeRoute(self.data.identity, entry.id) orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "merge", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                    }
                }

                if (supports_drafts and entryDraft(entry)) {
                    const route = publishRoute(self.data.identity, entry.id) orelse return error.RouteTooLong;
                    try addToolButton(allocator, row, "publish", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                    if (self.session.data.user_id != null) {
                        const edit_route = ui.RoutablePage.repoThreadEditRoute(kind, self.data.identity, entry.id) orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "edit", try std.fmt.allocPrint(pa, "a:{s}", .{try edit_route.toUrl(self.session.page_arena)}));
                        const remove_route = ui.RoutablePage.repoThreadRemoveRoute(kind, self.data.identity, entry.id, "") orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "✕", try std.fmt.allocPrint(pa, "a:{s}", .{try remove_route.toUrl(self.session.page_arena)}));
                    }
                } else {
                    if (!self.session.is_terminal and !entryConflicted(entry) and (self.session.data.is_local or self.session.data.user_id != null)) {
                        const label = "add attachment";
                        const action = if (self.data.identity.len == 0)
                            try std.fmt.allocPrint(pa, "{s}/{s}:{s}/attach", .{ ui.file_input_prefix, @tagName(kind), entry.id })
                        else
                            try std.fmt.allocPrint(pa, "{s}/repo/{s}/{s}:{s}/attach", .{ ui.file_input_prefix, self.data.identity, @tagName(kind), entry.id });
                        try addToolButton(allocator, row, label, action);
                    }

                    if (supports_conflicts and entryConflicted(entry)) {
                        const route = resolveRoute(self.data.identity, entry.id, "") orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "resolve conflict", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                    } else {
                        if (has_status and (self.session.data.is_local or self.session.data.user_id != null)) {
                            if (statusChange(entryStatus(entry))) |change| {
                                const route = ui.RoutablePage.repoThreadCommentsRoute(kind, self.data.identity, entry.id, 0) orelse return error.RouteTooLong;
                                row.getFocus().kind = .{ .custom = try std.fmt.allocPrint(pa, "form:{s}/{s}", .{ try route.toUrl(self.session.page_arena), change.action }) };
                                try addToolButton(allocator, row, change.action, "submit");
                            }
                        }

                        const route = ui.RoutablePage.repoThreadEditRoute(kind, self.data.identity, entry.id) orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "edit", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                    }

                    if (self.session.data.is_local or self.session.data.user_id != null) {
                        const route = ui.RoutablePage.repoThreadRemoveRoute(kind, self.data.identity, entry.id, "") orelse return error.RouteTooLong;
                        try addToolButton(allocator, row, "✕", try std.fmt.allocPrint(pa, "a:{s}", .{try route.toUrl(self.session.page_arena)}));
                    }
                }

                for (row.children.keys(), row.children.values()) |id, *child| {
                    if (!child.widget.getFocus().focusable) continue;
                    row.getFocus().child_id = id;
                    break;
                }
            }

            if (supports_drafts and !description_page and comment_page == null)
                try self.data.appendDetails(allocator, inner_box, self.session, entry);

            if (comment_page) |comment_view| {
                var back_label_buf: ["← back to ".len + thread_name.len]u8 = undefined;
                const back_label = try std.fmt.bufPrint(&back_label_buf, "← back to {s}", .{thread_name});
                var back = try Comment.linkBox(allocator, self.session, back_label, ui.RoutablePage.repoThreadCommentsRoute(kind, self.data.identity, entry.id, 0) orelse return error.RouteTooLong);
                errdefer back.deinit(allocator);
                try inner_box.children.put(allocator, back.getFocus().id, .{ .widget = .{ .text_box = back }, .rect = null, .min_size = null });

                try Comment.appendComment(allocator, inner_box, self.session, self.data.identity, kind, comment_view.selected);
                try Comment.appendCount(allocator, inner_box, comment_view.replies.count, "reply", "replies");
                for (comment_view.replies.comments) |comment| try Comment.appendComment(allocator, inner_box, self.session, self.data.identity, kind, comment);
                try Comment.appendWindowNav(allocator, inner_box, self.session, self.data.identity, kind, &comment_view.selected.comment.event.thread_id, &comment_view.selected.id, comment_view.replies);

                var spacer = try Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try inner_box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });

                inner_box.getFocus().child_id = inner_box.children.keys()[tool_row_index + 1];
                self.resetScroll();
                return;
            }

            if (description_page) {
                var back_label_buf: ["← back to ".len + thread_name.len]u8 = undefined;
                const back_label = try std.fmt.bufPrint(&back_label_buf, "← back to {s}", .{thread_name});
                var text_box = try wgt.TextBox.init(allocator, back_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer text_box.deinit(allocator);
                text_box.getFocus().focusable = true;
                text_box.getFocus().kind = .{ .custom = try listLink(self.session.page_arena, self.data.identity, entryStatus(entry), "", entry.id) };
                try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
                self.title_id = text_box.getFocus().id;
            } else {
                var title = try wgt.TextBox.init(allocator, entry.record.event.title, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = " title " });
                errdefer title.deinit(allocator);
                title.getFocus().focusable = true;
                try inner_box.children.put(allocator, title.getFocus().id, .{ .widget = .{ .text_box = title }, .rect = null, .min_size = null });
                self.title_id = title.getFocus().id;

                var author = try ui.authorBox(allocator, self.session.page_arena, entry.author);
                errdefer author.deinit(allocator);
                try inner_box.children.put(allocator, author.getFocus().id, .{ .widget = .{ .text_box = author }, .rect = null, .min_size = null });
                self.author_id = author.getFocus().id;

                var items: std.ArrayList(TagFlow.Item) = .empty;
                defer items.deinit(allocator);
                var tag_iter = Event.tagIterator(entry.record.event.tags);
                while (tag_iter.next()) |tag| {
                    if (tag.len == 0) continue;
                    try items.append(allocator, .{ .text = tag, .link = try tagLink(self.session.page_arena, self.data.identity, entryStatus(entry), tag) });
                }
                if (items.items.len > 0) {
                    var tags = try TagFlow.init(allocator);
                    errdefer tags.deinit(allocator);
                    try tags.setItems(allocator, items.items);
                    try inner_box.children.put(allocator, tags.getFocus().id, .{ .widget = .{ .tag_flow = tags }, .rect = null, .min_size = null });
                }
            }

            const whole = entry.record.event.description;
            const preview_end = if (description_page) null else ui.detailPreviewEnd(whole);
            const shown = if (preview_end) |end|
                std.mem.trimEnd(u8, whole[0..end], " \t\r\n")
            else if (whole.len == 0)
                "(no description)"
            else
                whole;
            var description = try wgt.TextBox.init(allocator, shown, .{
                .border_style = .single,
                .rounded_corners = true,
                .wrap_kind = .word,
                .label = " description ",
                .bottom_label = if (preview_end != null) " click or press enter to see more " else "",
            });
            errdefer description.deinit(allocator);
            description.getFocus().focusable = true;
            if (preview_end != null) {
                const route = ui.RoutablePage.repoThreadDescriptionRoute(kind, self.data.identity, entry.id) orelse return error.RouteTooLong;
                description.getFocus().kind = .{ .custom = try std.fmt.allocPrint(self.session.page_arena.allocator(), "a:{s}", .{try route.toUrl(self.session.page_arena)}) };
            }
            try inner_box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_box = description }, .rect = null, .min_size = null });
            self.description_id = description.getFocus().id;

            if (!supports_drafts or !entryDraft(entry)) {
                const parent_route = ui.RoutablePage.repoThreadCommentsRoute(kind, self.data.identity, entry.id, 0) orelse return error.RouteTooLong;
                try Attachment.appendRows(allocator, inner_box, self.session, self.data.identity, try parent_route.toUrl(self.session.page_arena), entry.attachments);

                if (!description_page) {
                    var reply = try Comment.linkBox(allocator, self.session, "new comment", ui.RoutablePage.repoThreadCommentNewRoute(kind, self.data.identity, entry.id, "") orelse return error.RouteTooLong);
                    errdefer reply.deinit(allocator);
                    try inner_box.children.put(allocator, reply.getFocus().id, .{ .widget = .{ .text_box = reply }, .rect = null, .min_size = null });

                    try Comment.appendCount(allocator, inner_box, entry.comments.count, "comment", "comments");
                    for (entry.comments.comments) |comment| try Comment.appendComment(allocator, inner_box, self.session, self.data.identity, kind, comment);
                    try Comment.appendWindowNav(allocator, inner_box, self.session, self.data.identity, kind, entry.id, null, entry.comments);
                }
            }

            if (!description_page) {
                var spacer = try Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try inner_box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }

            _ = self.focusFirst(null);
            self.resetScroll();
        }

        fn resetScroll(self: *This) void {
            const detail_scroll = &self.scroll;
            detail_scroll.x = 0;
            detail_scroll.y = 0;
            detail_scroll.getFocus().version +%= 1;
        }

        pub fn inputWithExit(self: *This, allocator: std.mem.Allocator, raw_key: Key, root_focus: *Focus) !Exit {
            self.exit = .none;
            const key: Key = if (raw_key == .mouse and raw_key.mouse.action == .scroll)
                (if (raw_key.mouse.action.scroll == .up) .arrow_up else .arrow_down)
            else
                raw_key;

            switch (key) {
                .page_up => self.pageDetail(root_focus, -10),
                .page_down => self.pageDetail(root_focus, 10),
                .home => self.jump(root_focus, false),
                .end => self.jump(root_focus, true),
                else => {
                    const entry = self.entry orelse return self.exit;
                    if (self.data.comment_page != null and std.mem.eql(u8, entry.id, self.data.selected_id)) {
                        self.commentInput(key, root_focus);
                    } else if (self.toolRowFocused(root_focus)) {
                        try self.toolRowInput(allocator, key, root_focus);
                    } else {
                        try self.childInput(allocator, key, root_focus);
                    }
                },
            }
            return self.exit;
        }

        fn childInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const child_index = self.focusedChild(root_focus) orelse return;
            const inner_box = self.inner();
            const child_id = inner_box.children.keys()[child_index];
            const child = &inner_box.children.values()[child_index].widget;

            if (child_id == self.title_id) {
                switch (key) {
                    .arrow_left => self.exit = .list,
                    .arrow_up => if (!self.moveVertical(root_focus, false)) self.focusToolRow(root_focus),
                    .arrow_down => _ = self.moveVertical(root_focus, true),
                    else => {},
                }
                return;
            }
            if (child_id == self.author_id) {
                switch (key) {
                    .arrow_left => self.exit = .list,
                    .arrow_up => _ = self.moveVertical(root_focus, false),
                    .arrow_down => _ = self.moveVertical(root_focus, true),
                    else => {},
                }
                return;
            }
            if (child_id == self.description_id) {
                self.descriptionInput(key, root_focus);
                return;
            }

            switch (child.*) {
                .tag_flow => |*tags| self.tagsInput(child_index, tags, key, root_focus),
                .copyable_text => |*copyable| switch (key) {
                    .arrow_up => if (!self.moveVertical(root_focus, false)) self.focusToolRow(root_focus),
                    .arrow_down => _ = self.moveVertical(root_focus, true),
                    .arrow_left => if (copyable.selected == 0) {
                        self.exit = .list;
                    } else try copyable.input(allocator, key, root_focus),
                    else => try copyable.input(allocator, key, root_focus),
                },
                .box => |*row| if (Attachment.removeId(row)) |attachment_id| {
                    const remove_id = row.children.keys()[1];
                    switch (key) {
                        .arrow_left => if (!self.moveHorizontal(root_focus, false)) {
                            self.exit = .list;
                        },
                        .arrow_right => _ = self.moveHorizontal(root_focus, true),
                        .arrow_up => _ = self.moveVertical(root_focus, false),
                        .arrow_down => _ = self.moveVertical(root_focus, true),
                        .enter => if (row.getFocus().child_id == remove_id) try self.removeEvent(allocator, .attach, attachment_id),
                        .mouse => |mouse| if (inp.leftClickOn(root_focus, remove_id, mouse)) try self.removeEvent(allocator, .attach, attachment_id),
                        else => {},
                    }
                } else self.commentInput(key, root_focus),
                else => self.commentInput(key, root_focus),
            }
        }

        fn toolRowInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const row = self.toolRow();
            const child_id = row.getFocus().child_id orelse return;
            const cur = row.children.getIndex(child_id) orelse return;
            const on_primary = switch (row.children.values()[cur].widget.getFocus().kind) {
                .custom => |action| std.mem.eql(u8, action, "submit"),
                else => false,
            };
            switch (key) {
                .arrow_left => {
                    var previous = cur;
                    while (previous > 0) {
                        previous -= 1;
                        if (!row.children.values()[previous].widget.getFocus().focusable) continue;
                        root_focus.setFocus(row.children.keys()[previous]);
                        return;
                    }
                    self.exit = .list;
                },
                .arrow_right => {
                    var next = cur + 1;
                    while (next < row.children.count()) : (next += 1) {
                        if (!row.children.values()[next].widget.getFocus().focusable) continue;
                        root_focus.setFocus(row.children.keys()[next]);
                        return;
                    }
                },
                .arrow_up => self.exit = .header,
                .arrow_down => _ = self.moveVertical(root_focus, true),
                .enter => if (on_primary) try self.primaryAction(allocator),
                .mouse => |mouse| if (on_primary and inp.leftClickOn(root_focus, child_id, mouse)) try self.primaryAction(allocator),
                else => {},
            }
        }

        fn primaryAction(self: *This, allocator: std.mem.Allocator) !void {
            try self.toggleStatus(allocator);
        }

        fn descriptionInput(self: *This, key: Key, root_focus: *Focus) void {
            const detail_scroll = &self.scroll;
            switch (key) {
                .arrow_left => self.exit = .list,
                .arrow_up => {
                    if (!self.session.is_terminal) {
                        _ = self.moveVertical(root_focus, false);
                        return;
                    }
                    if (self.focusAdjacentVisible(root_focus, false)) return;
                    const before = detail_scroll.y;
                    detail_scroll.y -= 1;
                    detail_scroll.clampToContent();
                    if (detail_scroll.y == before) _ = self.moveVertical(root_focus, false);
                },
                .arrow_down => {
                    if (!self.session.is_terminal) {
                        _ = self.moveVertical(root_focus, true);
                        return;
                    }
                    if (self.focusAdjacentVisible(root_focus, true)) return;
                    const before = detail_scroll.y;
                    detail_scroll.y += 1;
                    detail_scroll.clampToContent();
                    if (detail_scroll.y == before) _ = self.moveVertical(root_focus, true);
                },
                else => {},
            }
        }

        fn commentInput(self: *This, key: Key, root_focus: *Focus) void {
            switch (key) {
                .arrow_left => if (!self.moveHorizontal(root_focus, false)) {
                    self.exit = .list;
                },
                .arrow_right => _ = self.moveHorizontal(root_focus, true),
                .arrow_up => _ = self.moveVertical(root_focus, false),
                .arrow_down => _ = self.moveVertical(root_focus, true),
                else => {},
            }
        }

        fn pageDetail(self: *This, root_focus: *Focus, delta: isize) void {
            if (!self.session.is_terminal) return;
            const detail_scroll = &self.scroll;
            detail_scroll.y += delta;
            detail_scroll.clampToContent();
            self.focusVisible(root_focus, delta > 0);
        }

        fn jump(self: *This, root_focus: *Focus, to_end: bool) void {
            if (self.session.is_terminal) {
                const detail_scroll = &self.scroll;
                detail_scroll.y = if (to_end) std.math.maxInt(isize) else 0;
                detail_scroll.clampToContent();
                self.focusVisible(root_focus, to_end);
            } else {
                const focus = self.inner().getFocus();
                var chosen: ?usize = null;
                for (focus.children.keys(), focus.children.values()) |id, child| {
                    if (!child.focus.focusable) continue;
                    chosen = id;
                    if (!to_end) break;
                }
                if (chosen) |id| root_focus.setFocus(id);
            }
        }

        fn rectVisible(self: *This, rect: layout.IRect) bool {
            const detail_scroll = &self.scroll;
            const viewport = detail_scroll.grid orelse return false;
            const top = detail_scroll.y;
            const bottom = top + @as(isize, @intCast(viewport.size.height - detail_scroll.bar_h));
            return rect.y + @as(isize, @intCast(rect.size.height)) > top and rect.y < bottom;
        }

        fn focusVisible(self: *This, root_focus: *Focus, last: bool) void {
            const inner_box = self.inner();
            var offset: usize = 0;
            while (offset < inner_box.children.count()) : (offset += 1) {
                const child_index = if (last) inner_box.children.count() - 1 - offset else offset;
                if (self.focusVisibleChild(child_index, root_focus, last)) return;
            }
        }

        fn focusVisibleChild(self: *This, child_index: usize, root_focus: *Focus, last: bool) bool {
            const inner_box = self.inner();
            const child = &inner_box.children.values()[child_index];
            const child_rect = child.rect orelse return false;
            var chosen: ?usize = null;
            if (child.widget.getFocus().focusable and self.rectVisible(child_rect)) {
                const id = inner_box.children.keys()[child_index];
                chosen = id;
                if (!last) {
                    root_focus.setFocus(id);
                    return true;
                }
            }

            for (child.widget.getFocus().children.keys(), child.widget.getFocus().children.values()) |id, focus_child| {
                if (!focus_child.focus.focusable) continue;
                const rect: layout.IRect = .{
                    .x = child_rect.x + @as(isize, @intCast(focus_child.rect.x)),
                    .y = child_rect.y + @as(isize, @intCast(focus_child.rect.y)),
                    .size = focus_child.rect.size,
                };
                if (!self.rectVisible(rect)) continue;
                chosen = id;
                if (!last) break;
            }
            if (chosen) |id| {
                root_focus.setFocus(id);
                return true;
            }
            return false;
        }

        fn focusAdjacentVisible(self: *This, root_focus: *Focus, down: bool) bool {
            const inner_box = self.inner();
            var next = self.focusedChild(root_focus) orelse return false;
            while (true) {
                if (down) {
                    next += 1;
                    if (next >= inner_box.children.count()) return false;
                } else {
                    if (next == 0) return false;
                    next -= 1;
                }
                if (self.focusVisibleChild(next, root_focus, !down)) {
                    self.focusChild(next, !down, root_focus);
                    return true;
                }
            }
        }

        fn focusedChild(self: *This, root_focus: *Focus) ?usize {
            const inner_box = self.inner();
            var id = root_focus.grandchild_id orelse return null;
            while (inner_box.getFocus().children.get(id)) |child| {
                if (child.parent_id == inner_box.getFocus().id) return inner_box.children.getIndex(id);
                id = child.parent_id;
            }
            return null;
        }

        fn childFocusable(self: *This, child_index: usize) bool {
            const focus = self.inner().children.values()[child_index].widget.getFocus();
            if (focus.focusable) return true;
            for (focus.children.values()) |item| {
                if (item.focus.focusable) return true;
            }
            return false;
        }

        fn focusChild(self: *This, child_index: usize, last: bool, root_focus: *Focus) void {
            const inner_box = self.inner();
            const child = &inner_box.children.values()[child_index];
            var target = inner_box.children.keys()[child_index];
            var rect = child.rect orelse return;
            switch (child.widget) {
                .repo_comment => |*comment| {
                    if (comment.rowRect(last)) |row_rect| {
                        rect.x += row_rect.x;
                        rect.y += row_rect.y;
                        rect.size = row_rect.size;
                    }
                    if (last) comment.focusBody(root_focus) else comment.focusMetadata(root_focus);
                },
                .box => |*box| if (box.children.count() > 0) {
                    target = if (child_index == tool_row_index)
                        box.getFocus().child_id orelse return
                    else
                        box.children.keys()[if (last) box.children.count() - 1 else 0];
                    root_focus.setFocus(target);
                },
                else => root_focus.setFocus(target),
            }
            const detail_scroll = &self.scroll;
            if (detail_scroll.grid) |viewport| {
                const viewport_height = viewport.size.height - detail_scroll.bar_h;
                if (rect.size.height > viewport_height) {
                    const bottom_aligned = rect.y + @as(isize, @intCast(rect.size.height - viewport_height));
                    detail_scroll.y = std.math.clamp(detail_scroll.y, rect.y, bottom_aligned);
                    detail_scroll.clampToContent();
                    return;
                }
            }
            detail_scroll.scrollToRect(rect);
        }

        fn moveVertical(self: *This, root_focus: *Focus, down: bool) bool {
            const inner_box = self.inner();
            const current = self.focusedChild(root_focus) orelse return false;
            if (inner_box.children.values()[current].widget == .repo_comment) {
                const comment = &inner_box.children.values()[current].widget.repo_comment;
                if (down and !comment.bodyFocused()) {
                    self.focusChild(current, true, root_focus);
                    return true;
                }
                if (!down and comment.bodyFocused()) {
                    self.focusChild(current, false, root_focus);
                    return true;
                }
            }

            var next = current;
            while (true) {
                if (down) {
                    next += 1;
                    if (next >= inner_box.children.count()) return false;
                } else {
                    if (next == 0) return false;
                    next -= 1;
                }
                if (!self.childFocusable(next)) continue;
                self.focusChild(next, !down, root_focus);
                return true;
            }
        }

        fn moveHorizontal(self: *This, root_focus: *Focus, right: bool) bool {
            const inner_box = self.inner();
            const current = self.focusedChild(root_focus) orelse return false;
            const child = &inner_box.children.values()[current];
            if (child.widget == .repo_comment) {
                const moved = child.widget.repo_comment.moveHorizontal(root_focus, right);
                if (moved) if (child.rect) |rect| self.scroll.scrollToRect(rect);
                return moved;
            }
            const row = switch (child.widget) {
                .box => |*box| box,
                else => return false,
            };
            const selected = row.getFocus().child_id orelse return false;
            const selected_index = row.children.getIndex(selected) orelse return false;
            const target = if (right) selected_index + 1 else selected_index -| 1;
            if (target == selected_index or target >= row.children.count()) return false;
            root_focus.setFocus(row.children.keys()[target]);
            if (child.rect) |rect| self.scroll.scrollToRect(rect);
            return true;
        }

        fn tagsInput(self: *This, child_index: usize, tags: *TagFlow, key: Key, root_focus: *Focus) void {
            const child_id = tags.focus.child_id orelse return;
            const cur = tags.indexOfFocusId(child_id) orelse return;
            const count = tags.text_boxes.items.len;
            switch (key) {
                .arrow_left => if (cur > 0) self.focusTag(child_index, tags, root_focus, cur - 1) else {
                    self.exit = .list;
                },
                .arrow_right => if (cur + 1 < count) self.focusTag(child_index, tags, root_focus, cur + 1),
                .arrow_up => if (tags.rowStep(cur, false)) |index| {
                    self.focusTag(child_index, tags, root_focus, index);
                } else {
                    _ = self.moveVertical(root_focus, false);
                },
                .arrow_down => if (tags.rowStep(cur, true)) |index| {
                    self.focusTag(child_index, tags, root_focus, index);
                } else {
                    _ = self.moveVertical(root_focus, true);
                },
                .home => self.focusTag(child_index, tags, root_focus, 0),
                .end => self.focusTag(child_index, tags, root_focus, count - 1),
                else => {},
            }
        }

        fn focusTag(self: *This, child_index: usize, tags: *TagFlow, root_focus: *Focus, item: usize) void {
            root_focus.setFocus(tags.text_boxes.items[item].getFocus().id);
            if (self.session.is_terminal and item < tags.rects.items.len) {
                if (self.inner().children.values()[child_index].rect) |flow_rect| {
                    var rect = tags.rects.items[item];
                    rect.x += flow_rect.x;
                    rect.y += flow_rect.y;
                    self.scroll.scrollToRect(rect);
                }
            }
        }

        fn toolRowFocused(self: *This, root_focus: *Focus) bool {
            return self.focusedChild(root_focus) == tool_row_index;
        }

        fn focusToolRow(self: *This, root_focus: *Focus) void {
            const child_id = self.toolRow().getFocus().child_id orelse {
                self.exit = .header;
                return;
            };
            root_focus.setFocus(child_id);
            if (self.inner().children.values()[tool_row_index].rect) |rect| self.scroll.scrollToRect(rect);
        }

        pub fn focusFirst(self: *This, root_focus: ?*Focus) bool {
            const inner_box = self.inner();
            for (tool_row_index + 1..inner_box.children.count()) |child_index| {
                if (!self.childFocusable(child_index)) continue;
                if (root_focus) |focus|
                    self.focusChild(child_index, false, focus)
                else
                    inner_box.getFocus().child_id = inner_box.children.keys()[child_index];
                return true;
            }
            return false;
        }

        pub fn atTop(self: *This, root_focus: *Focus) bool {
            const focused = self.focusedChild(root_focus) orelse return false;
            for (0..self.inner().children.count()) |child_index| {
                if (!self.childFocusable(child_index)) continue;
                return focused == child_index;
            }
            return false;
        }

        fn removeEvent(self: *This, allocator: std.mem.Allocator, event_kind: evt.EventKind, id: [evt.event_id_size]u8) !void {
            if (comptime wasm) return;

            if (comptime supports_drafts) {
                const entry = self.entry orelse return;
                if (event_kind == kind and entryDraft(entry)) {
                    try Data.removeDraft(self.session, allocator, &id);
                    const route = draftsRoute(self.data.identity) orelse return;
                    try self.session.navigate(route);
                    return;
                }
            }

            const io = self.session.io orelse return;
            const source = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;

            switch (source.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try evt.remove(.repo, repo_kind, repo.self_repo_opts, io, allocator, repo, &id, event_kind, author),
                    }
                },
            }

            const id_hex = std.fmt.bytesToHex(id, .lower);
            const route = ui.RoutablePage.repoEventsRoute(self.data.identity, .removed, event_kind, &id_hex) orelse return;
            try self.session.navigate(route);
        }

        fn toggleStatus(self: *This, allocator: std.mem.Allocator) !void {
            if (comptime (!has_status or wasm)) return;
            const entry = self.entry orelse return;
            const io = self.session.io orelse return;
            const source = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;
            const status = (statusChange(entryStatus(entry)) orelse return).status;
            const id = try evt.parseEventId(entry.id);

            switch (source.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try Event.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id, .{ .status = status }, author),
                    }
                },
            }

            const route = listRoute(self.data.identity, status, "", entry.id) orelse return;
            try self.session.navigate(route);
        }
    };
}

pub fn View(comptime kind: evt.EventKind, comptime Data: type) type {
    const Self = Data;
    const HeaderType = Data.Header;
    const Window = Data.Window;
    const Entry = Data.Entry;
    const Event = Data.Event;
    const Status = Data.Status;
    const has_status = @hasField(Event, "status");
    const supports_conflicts = Event.merge_policy == .field_conflicts;
    const supports_drafts = @hasField(Self, "drafts");
    const supports_merge = @hasDecl(Data, "mergeRoute");
    const FieldConflict = if (supports_conflicts) Data.FieldConflict else void;
    const ViewKind = Data.ViewKind;
    const thread_name = Data.thread_name;
    const DetailType = Data.Detail;

    return struct {
        const This = @This();
        // a vertical box: the header tabs on top, then a stack holding a
        // master-detail split (thread list + description pane) per status list,
        // plus the tags view.
        box: wgt.Box(Widget), // vert: [header_index] = tabs, [stack_index] = stack
        data: *const Self,
        session: *ui.Session,

        const header_index: usize = 0;
        const stack_index: usize = 1;
        // indices within the stack, 1:1 with the header tabs.
        const status_count = @typeInfo(Status).@"enum".fields.len;
        const tags_view_index: usize = status_count;
        // the new-thread form, or the edit, comment, or resolve form when the page was
        // loaded at one of their urls.
        const form_view_index: usize = tags_view_index + 1;
        // the conflicts split; the tab and stack child exist only when the repo
        // has conflicted threads.
        const drafts_view_index: usize = form_view_index + 1;
        const conflict_view_index: usize = drafts_view_index + @intFromBool(supports_drafts);
        const view_count: usize = conflict_view_index + @intFromBool(supports_conflicts);
        // indices within a split (the horizontal box inside the stack).
        const list_index: usize = 0;
        const detail_index: usize = 1;
        const list_max_width: usize = 35;
        const detail_min_width: usize = 40;
        // indices within the thread form.
        const title_field_index: usize = 0;
        const tags_field_index: usize = 1;
        const description_field_index: usize = 2;
        const target_branch_field_index: usize = 3;
        const submit_field_index: usize = 3 + @as(usize, @intFromBool(supports_drafts));
        const comment_author_field_index: usize = 0;
        const comment_body_field_index: usize = 1;
        const comment_submit_field_index: usize = 2;

        pub fn viewIndex(view: ViewKind) usize {
            const name = @tagName(view);
            if (std.mem.eql(u8, name, "tags")) return tags_view_index;
            if (std.mem.eql(u8, name, "new") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "publish") or std.mem.eql(u8, name, "merge") or std.mem.eql(u8, name, "new_comment") or std.mem.eql(u8, name, "edit_comment") or std.mem.eql(u8, name, "remove") or std.mem.eql(u8, name, "resolve")) return form_view_index;
            if (std.mem.eql(u8, name, "conflicts")) return conflict_view_index;
            if (std.mem.eql(u8, name, "drafts")) return drafts_view_index;
            if (std.mem.eql(u8, name, "description")) unreachable;
            inline for (@typeInfo(Status).@"enum".fields, 0..) |field, index| {
                if (std.mem.eql(u8, name, field.name)) return index;
            }
            unreachable;
        }

        const Confirmation = enum { remove, publish, merge };

        fn confirmation(view: ViewKind) ?Confirmation {
            if (view == .remove) return .remove;
            if (supports_drafts and std.mem.eql(u8, @tagName(view), "publish")) return .publish;
            if (supports_merge and std.mem.eql(u8, @tagName(view), "merge")) return .merge;
            return null;
        }

        // the status a status split lists; the conflicts split has none (its
        // threads carry their own).
        fn splitStatus(index: usize) Status {
            return @enumFromInt(index);
        }

        fn entryConflicted(entry: Entry) bool {
            return if (supports_conflicts) entry.conflicted else false;
        }

        fn entryStatus(entry: Entry) Status {
            if (comptime has_status) return Data.statusKind(entry.record.event);
            return @enumFromInt(0);
        }

        fn entryDraft(entry: Entry) bool {
            return if (supports_drafts) entry.draft else false;
        }

        fn listRoute(identity: []const u8, status: Status, tag: []const u8, selected: []const u8) ?ui.RoutablePage {
            return Data.listRoute(identity, status, tag, selected);
        }

        fn draftsRoute(identity: []const u8) ?ui.RoutablePage {
            return if (supports_drafts) Data.draftsRoute(identity) else null;
        }

        fn publishRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
            return if (supports_drafts) Data.publishRoute(identity, selected) else null;
        }

        fn mergeRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
            return if (supports_merge) Data.mergeRoute(identity, selected) else null;
        }

        fn conflictsRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
            return if (supports_conflicts) Data.conflictsRoute(identity, selected) else null;
        }

        fn resolveRoute(identity: []const u8, selected: []const u8, picks: []const u8) ?ui.RoutablePage {
            return if (supports_conflicts) Data.resolveRoute(identity, selected, picks) else null;
        }

        fn listLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: Status, tag: []const u8, id: []const u8) ![]const u8 {
            const route = listRoute(identity, status, tag, id) orelse return error.RouteTooLong;
            return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.toUrl(page_arena)});
        }

        fn rowLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, id: []const u8) ![]const u8 {
            const selected = std.mem.eql(u8, id, data.selected_id);
            const route = (if (selected and data.description_page)
                ui.RoutablePage.repoThreadDescriptionRoute(kind, data.identity, id)
            else if (selected)
                if (data.comment_page) |page|
                    ui.RoutablePage.repoThreadCommentRoute(kind, data.identity, id, &page.selected.id, page.replies.start)
                else
                    ui.RoutablePage.repoThreadCommentsRoute(kind, data.identity, id, data.comments_start)
            else
                ui.RoutablePage.repoThreadCommentsRoute(kind, data.identity, id, 0)) orelse return error.RouteTooLong;
            return std.fmt.allocPrint(page_arena.allocator(), "ai:{s}", .{try route.toUrl(page_arena)});
        }

        fn windowLink(page_arena: *std.heap.ArenaAllocator, data: *const Self, status_maybe: ?Status, drafts: bool, id: []const u8) ![]const u8 {
            if (supports_conflicts and status_maybe == null and !drafts) {
                const route = conflictsRoute(data.identity, id) orelse return error.RouteTooLong;
                return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.toUrl(page_arena)});
            }
            if (drafts and id.len == 0) {
                const route = draftsRoute(data.identity) orelse return error.RouteTooLong;
                return std.fmt.allocPrint(page_arena.allocator(), "a:{s}", .{try route.toUrl(page_arena)});
            }
            return listLink(page_arena, data.identity, status_maybe orelse @enumFromInt(0), data.tag, id);
        }

        fn tagLink(page_arena: *std.heap.ArenaAllocator, identity: []const u8, status: Status, tag: []const u8) ![]const u8 {
            const encoded = try ui.urlEncodeRef(page_arena.allocator(), tag);
            return listLink(page_arena, identity, status, encoded, "");
        }

        pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !This {
            var outer = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer outer.deinit(allocator);

            // the tabs at the top.
            {
                var hdr = try Data.initHeader(allocator, session, data);
                errdefer hdr.deinit(allocator);
                try outer.children.put(allocator, hdr.getFocus().id, .{ .widget = @unionInit(Widget, Data.header_widget_name, hdr), .rect = null, .min_size = null });
            }

            // the stack enters `outer` before its children enter it, so an error
            // frees each child exactly once.
            {
                var stack = try wgt.Stack(Widget).init(allocator);
                errdefer stack.deinit(allocator);
                try outer.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
            }
            const stack = &outer.children.values()[stack_index].widget.stack;

            inline for (@typeInfo(Status).@"enum".fields) |field| {
                var split = try initSplit(allocator, session, data, @enumFromInt(field.value), false);
                errdefer split.deinit(allocator);
                try stack.children.put(allocator, split.getFocus().id, .{ .box = split });
            }

            // the tags view
            {
                var tf = try TagFlow.init(allocator);
                errdefer tf.deinit(allocator);
                var items: std.ArrayList(TagFlow.Item) = .empty;
                defer items.deinit(allocator);
                // when filtered, the first item clears the filter
                if (data.tag.len != 0)
                    try items.append(allocator, .{ .text = "✕", .link = try listLink(session.page_arena, data.identity, @enumFromInt(0), "", "") });
                for (data.tags) |tag|
                    try items.append(allocator, .{ .text = tag, .link = try tagLink(session.page_arena, data.identity, @enumFromInt(0), tag) });
                try tf.setItems(allocator, items.items);
                try stack.children.put(allocator, tf.getFocus().id, .{ .tag_flow = tf });
            }

            // the new-thread form, or — on an edit, comment, or resolve url — that form in
            // its place, prefilled with the selected thread's content. a
            // logged-out session can't create events, so the unauthorized view
            // stands in.
            if (session.data.is_local or session.data.user_id != null) {
                if (confirmation(data.view)) |confirmation_kind| {
                    const aa = session.page_arena.allocator();
                    const route = switch (confirmation_kind) {
                        .remove => ui.RoutablePage.repoThreadRemoveRoute(kind, data.identity, data.selected_id, data.comment_id),
                        .publish => publishRoute(data.identity, data.selected_id),
                        .merge => mergeRoute(data.identity, data.selected_id),
                    } orelse return error.RouteTooLong;
                    const page_url = try route.toUrl(session.page_arena);
                    const action = try std.fmt.allocPrint(aa, "form:{s}", .{page_url});
                    const event_name = if (data.comment_id.len == 0) thread_name else "comment";
                    var label_buf: ["remove ".len + @max(thread_name.len, "comment".len)]u8 = undefined;
                    var buttons: [2]ConfirmationButton = undefined;
                    buttons[0] = .{ .label = switch (confirmation_kind) {
                        .remove => try std.fmt.bufPrint(&label_buf, "remove {s}", .{event_name}),
                        .publish => "publish patch",
                        .merge => "merge patch",
                    } };
                    var button_count: usize = 1;
                    if (confirmation_kind == .merge) {
                        if (comptime supports_merge) {
                            buttons[1] = .{
                                .label = "squash and merge patch",
                                .action = try std.fmt.allocPrint(aa, "{s}{s}/squash", .{ ui.submit_action_prefix, page_url }),
                            };
                            button_count += 1;
                        } else unreachable;
                    }
                    var center = try initConfirmationForm(allocator, action, buttons[0..button_count]);
                    errdefer center.deinit(allocator);
                    try stack.children.put(allocator, center.getFocus().id, .{ .center = center });
                } else if (data.view == .new_comment or data.view == .edit_comment) {
                    const editing = data.view == .edit_comment;
                    const route = if (editing)
                        ui.RoutablePage.repoThreadCommentEditRoute(kind, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong
                    else
                        ui.RoutablePage.repoThreadCommentNewRoute(kind, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong;
                    const page_url = try route.toUrl(session.page_arena);
                    const action = try std.fmt.allocPrint(session.page_arena.allocator(), "form:{s}", .{page_url});
                    const page = data.comment_page;
                    const top_level = if (page) |p| std.mem.eql(u8, &p.selected.comment.event.parent_id, &p.selected.comment.event.thread_id) else false;
                    const parent_route = if (editing)
                        if (top_level)
                            ui.RoutablePage.repoThreadCommentsRoute(kind, data.identity, data.selected_id, 0)
                        else if (page) |p|
                            ui.RoutablePage.repoThreadCommentRoute(kind, data.identity, data.selected_id, &p.selected.comment.event.parent_id, 0)
                        else
                            null
                    else if (page) |p|
                        ui.RoutablePage.repoThreadCommentRoute(kind, data.identity, data.selected_id, &p.selected.id, 0)
                    else
                        ui.RoutablePage.repoThreadCommentsRoute(kind, data.identity, data.selected_id, 0);
                    const parent_author: ui.Author = if (editing)
                        if (top_level)
                            if (data.selectedThread()) |entry| entry.author else .unknown
                        else if (page) |p|
                            p.selected.parent_author orelse .unknown
                        else
                            .unknown
                    else if (page) |p|
                        p.selected.author
                    else if (data.selectedThread()) |entry|
                        entry.author
                    else
                        .unknown;
                    const initial_body: ?[]const u8 = if (editing) if (page) |p| p.selected.comment.event.body else null else null;
                    var form = try initCommentForm(allocator, session, action, parent_author, parent_route orelse return error.RouteTooLong, initial_body);
                    errdefer form.deinit(allocator);
                    try stack.children.put(allocator, form.getFocus().id, .{ .box = form });
                } else if (supports_conflicts and data.view == .resolve) {
                    // on the web the page grows to the form's height and the
                    // browser scrolls it; the terminal scrolls the form itself
                    var form_widget: Widget = blk: {
                        var form = try initResolveForm(allocator, session, data);
                        errdefer form.deinit(allocator);
                        break :blk if (session.is_terminal)
                            .{ .scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = form }, .{ .direction = .vert }) }
                        else
                            .{ .box = form };
                    };
                    errdefer form_widget.deinit(allocator);
                    try stack.children.put(allocator, form_widget.getFocus().id, form_widget);
                } else {
                    const aa = session.page_arena.allocator();
                    const route = if (data.view == .edit)
                        ui.RoutablePage.repoThreadEditRoute(kind, data.identity, data.selected_id) orelse return error.RouteTooLong
                    else
                        ui.RoutablePage.repoThreadNewRoute(kind, data.identity) orelse return error.RouteTooLong;
                    const action = try std.fmt.allocPrint(aa, "form:{s}", .{try route.toUrl(session.page_arena)});
                    const record = if (data.view == .edit)
                        (if (data.selectedThread()) |entry| &entry.record else null)
                    else
                        null;
                    var form = try initThreadForm(allocator, session, data, action, record);
                    errdefer form.deinit(allocator);
                    try stack.children.put(allocator, form.getFocus().id, .{ .box = form });
                }
            } else {
                var message = try ui.Unauthorized.View.init(allocator);
                errdefer message.deinit(allocator);
                try stack.children.put(allocator, message.getFocus().id, .{ .unauthorized = message });
            }

            if (supports_drafts) {
                var split = try initSplit(allocator, session, data, null, true);
                errdefer split.deinit(allocator);
                try stack.children.put(allocator, split.getFocus().id, .{ .box = split });
            }

            // the conflicts split; its tab exists only when the repo has
            // conflicts, so skip the child too to keep the stack 1:1 with the
            // tabs.
            if (supports_conflicts and data.conflicts.count > 0) {
                var split = try initSplit(allocator, session, data, null, false);
                errdefer split.deinit(allocator);
                try stack.children.put(allocator, split.getFocus().id, .{ .box = split });
            }

            // the stack starts on the page's view.
            stack.getFocus().child_id = stack.children.keys()[viewIndex(data.view)];

            // focus entering the view lands on the tabs first.
            outer.getFocus().child_id = outer.children.keys()[header_index];

            return .{
                .box = outer,
                .data = data,
                .session = session,
            };
        }

        // the master-detail split showing `status`'s window, or the conflicts
        // window when null.
        fn initSplit(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self, status_maybe: ?Status, drafts: bool) !wgt.Box(Widget) {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer box.deinit(allocator);

            const win = if (status_maybe) |status| data.window(status) else if (drafts and supports_drafts) &data.drafts else if (supports_conflicts) &data.conflicts else unreachable;

            // the thread list (one focusable row per title), plus a "next" link that
            // reloads the page rooted at the following thread.
            {
                var list_scroll = blk: {
                    var list_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert, .stretch = true });
                    errdefer list_box.deinit(allocator);
                    if (win.prev_id) |prev|
                        try addRow(allocator, &list_box, "← previous", "", try windowLink(session.page_arena, data, status_maybe, drafts, prev));
                    for (win.items) |entry| {
                        // conflicts take precedence over the comment count
                        const label: []const u8 = if (entryConflicted(entry) and status_maybe != null)
                            " conflict "
                        else if (entry.comments.count > 0)
                            try std.fmt.allocPrint(session.page_arena.allocator(), " {d} comments ", .{entry.comments.count})
                        else
                            "";
                        try addRow(allocator, &list_box, entry.record.event.title, label, try rowLink(session.page_arena, data, entry.id));
                    }
                    if (win.next_id) |next|
                        try addRow(allocator, &list_box, "next →", "", try windowLink(session.page_arena, data, status_maybe, drafts, next));
                    // select the window's first thread (past a leading "previous"
                    // row) so its description shows on load.
                    if (win.items.len > 0)
                        list_box.getFocus().child_id = list_box.children.keys()[if (win.prev_id != null) 1 else 0]
                    else if (list_box.children.count() > 0)
                        list_box.getFocus().child_id = list_box.children.keys()[0];
                    break :blk try wgt.Scroll(Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal });
                };
                errdefer list_scroll.deinit(allocator);
                try box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });
            }

            // frame the detail pane inside the master-detail split
            {
                var frame = try wgt.Box(Widget).init(allocator, .{ .border_style = .hidden, .direction = .vert });
                errdefer frame.deinit(allocator);
                var detail_view = try DetailType.init(allocator, data, session, null, .{});
                errdefer detail_view.deinit(allocator);
                frame.getFocus().child_id = detail_view.getFocus().id;
                try frame.children.put(allocator, detail_view.getFocus().id, .{ .widget = @unionInit(Widget, Data.detail_widget_name, detail_view), .rect = null, .min_size = null });
                try box.children.put(allocator, frame.getFocus().id, .{ .widget = .{ .box = frame }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });
            }

            box.getFocus().child_id = box.children.keys()[list_index];
            return box;
        }

        // a thread form, plus the target branch for patches, prefilled from
        // `record` when given. its form: subtree makes the web renderer POST
        // the inputs to `action`'s route.
        fn initThreadForm(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self, action: []const u8, record: ?*const Event.Record) !wgt.Box(Widget) {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer box.deinit(allocator);
            box.getFocus().kind = .{ .custom = action };

            {
                var title = try wgt.TextInput.init(allocator, .{ .label = " title ", .name = "title", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
                errdefer title.deinit(allocator);
                title.getFocus().focusable = true;
                if (record) |r| try title.setContent(allocator, r.event.title);
                try box.children.put(allocator, title.getFocus().id, .{ .widget = .{ .text_input = title }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            {
                var tags = try wgt.TextInput.init(allocator, .{ .label = " tags (separate with spaces) ", .name = "tags", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
                errdefer tags.deinit(allocator);
                tags.getFocus().focusable = true;
                if (record) |r| try tags.setContent(allocator, r.event.tags);
                try box.children.put(allocator, tags.getFocus().id, .{ .widget = .{ .text_input = tags }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            {
                var description = try wgt.TextInput.init(allocator, .{ .label = " description ", .name = "description", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal, .multiline = true, .scroll = .{ .fill = true } });
                errdefer description.deinit(allocator);
                description.getFocus().focusable = true;
                if (record) |r| try description.setContent(allocator, r.event.description);
                try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = null });
            }

            if (supports_drafts) {
                var target = try wgt.TextInput.init(allocator, .{ .label = " target branch ", .name = "target_branch", .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
                errdefer target.deinit(allocator);
                target.getFocus().focusable = true;
                const content = if (record) |r| r.event.target_branch else data.default_target_branch;
                try target.setContent(allocator, content);
                try box.children.put(allocator, target.getFocus().id, .{ .widget = .{ .text_input = target }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            try addSubmitButtonLabeled(allocator, &box, if (supports_drafts and record == null) "submit draft" else "submit");

            box.getFocus().child_id = box.children.keys()[title_field_index];
            return box;
        }

        fn initCommentForm(allocator: std.mem.Allocator, session: *ui.Session, action: []const u8, author: ui.Author, parent_route: ui.RoutablePage, initial_body: ?[]const u8) !wgt.Box(Widget) {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer box.deinit(allocator);
            box.getFocus().kind = .{ .custom = action };

            {
                var parent = try ui.authorBox(allocator, session.page_arena, author);
                errdefer parent.deinit(allocator);
                parent.options.label = " replying to ";
                parent.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "a:{s}", .{try parent_route.toUrl(session.page_arena)}) };
                try box.children.put(allocator, parent.getFocus().id, .{ .widget = .{ .text_box = parent }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }

            {
                var body = try wgt.TextInput.init(allocator, .{
                    .label = " comment ",
                    .name = "body",
                    .visible_width = null,
                    .rounded_corners = true,
                    .render_content = session.is_terminal,
                    .multiline = true,
                    .visible_height = 5,
                    .scroll = .{ .fill = true },
                });
                errdefer body.deinit(allocator);
                body.getFocus().focusable = true;
                if (initial_body) |text| try body.setContent(allocator, text);
                try box.children.put(allocator, body.getFocus().id, .{ .widget = .{ .text_input = body }, .rect = null, .min_size = null });
            }

            try addSubmitButtonLabeled(allocator, &box, "submit");
            box.getFocus().child_id = box.children.keys()[comment_author_field_index];
            return box;
        }

        const ConfirmationButton = struct {
            label: []const u8,
            action: []const u8 = "submit",
        };

        fn initConfirmationForm(allocator: std.mem.Allocator, action: []const u8, buttons: []const ConfirmationButton) !Center {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
            errdefer box.deinit(allocator);
            box.getFocus().kind = .{ .custom = action };

            var prompt = try wgt.Text.init(allocator, "are you sure?");
            errdefer prompt.deinit(allocator);
            try box.children.put(allocator, prompt.getFocus().id, .{ .widget = .{ .text = prompt }, .rect = null, .min_size = null });

            for (buttons, 0..) |options, index| {
                var button = try wgt.TextBox.init(allocator, options.label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().focusable = true;
                button.getFocus().kind = .{ .custom = options.action };
                try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
                if (index == 0) box.getFocus().child_id = button.getFocus().id;
            }

            return Center.init(allocator, .{ .box = box });
        }

        // a form's submit button, then a spacer absorbing the leftover
        // min-height the box hands its last child, so the button keeps its
        // natural height
        fn addSubmitButtonLabeled(allocator: std.mem.Allocator, box: *wgt.Box(Widget), label: []const u8) !void {
            {
                var submit = try SubmitButton.initLabeled(allocator, label);
                errdefer submit.deinit(allocator);
                try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }
            {
                var spacer = try Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null });
            }
        }

        // the conflict resolve form. the "use this" links are navigations that
        // flip the url's theirs: pick, reloading the prefills; one submit
        // settles every conflict. the form: subtree makes the web renderer POST
        // to the resolve route.
        fn initResolveForm(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !wgt.Box(Widget) {
            const aa = session.page_arena.allocator();
            // init only picks the resolve view once it has read the conflict
            const conflict = if (data.conflict) |*c| c else unreachable;

            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer box.deinit(allocator);
            const route = resolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong;
            box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(aa, "form:{s}", .{try route.toUrl(session.page_arena)}) };

            if (conflict.title) |*fc| {
                try addLabel(allocator, &box, "title conflict:");
                try addFieldConflict(allocator, &box, session, data, "title", fc);
            }
            if (conflict.tags) |*fc| {
                try addLabel(allocator, &box, "tags conflict:");
                try addFieldConflict(allocator, &box, session, data, "tags", fc);
            }
            if (comptime @hasField(Data.Conflict, "status")) {
                if (conflict.status) |*fc| {
                    try addLabel(allocator, &box, "status conflict:");
                    try addAtomicConflict(allocator, &box, session, data, "status", fc);
                }
            }
            if (comptime @hasField(Data.Conflict, "revision")) {
                if (conflict.revision) |*fc| {
                    try addLabel(allocator, &box, "revision conflict:");
                    try addAtomicConflict(allocator, &box, session, data, "revision", fc);
                }
                if (conflict.target_branch) |*fc| {
                    try addLabel(allocator, &box, "target branch conflict:");
                    try addAtomicConflict(allocator, &box, session, data, "target_branch", fc);
                }
            }

            if (conflict.description) |*desc| {
                try addLabel(allocator, &box, "description conflict:");
                var hunk_index: usize = 0;
                for (desc.chunks, 0..) |*chunk, chunk_index| {
                    switch (chunk.*) {
                        .same => |text| {
                            var tb = try wgt.TextBox.init(allocator, text, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word });
                            errdefer tb.deinit(allocator);
                            tb.getFocus().focusable = true;
                            try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                        },
                        // an auto-resolved chunk: only one side changed it, so its
                        // version stands, shown distinctly with its author
                        .auto => |auto| {
                            const author = if (auto.theirs) desc.theirs_author else desc.ours_author;
                            const verb: []const u8 = if (auto.text == null) "removed" else "edited";
                            const label = switch (author) {
                                .user_name, .email => |name| try std.fmt.allocPrint(aa, " {s} by {s} ", .{ verb, name }),
                                .unknown => try std.fmt.allocPrint(aa, " {s} by {s} ", .{ verb, if (auto.theirs) @as([]const u8, "them") else "us" }),
                            };
                            var tb = try wgt.TextBox.init(allocator, auto.text orelse "(removed)", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = label });
                            errdefer tb.deinit(allocator);
                            tb.getFocus().focusable = true;
                            try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
                        },
                        .conflict => |hunk| {
                            // a blank row on each side sets the group apart from
                            // the flowing shared and auto-resolved chunks
                            if (chunk_index > 0) try addGap(allocator, &box);
                            const name = try std.fmt.allocPrint(aa, "d{d}", .{hunk_index});
                            hunk_index += 1;
                            const picked_theirs = data.theirsPicked(name);
                            try addVersionRow(allocator, &box, try sideLabel(aa, desc.ours_author, true), hunk.ours orelse "", try useThisLink(session, data, name, false));
                            try addVersionRow(allocator, &box, try sideLabel(aa, desc.theirs_author, false), hunk.theirs orelse "", try useThisLink(session, data, name, true));
                            var resolution_input = try wgt.TextInput.init(allocator, .{ .label = " resolution ", .name = name, .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal, .multiline = true });
                            errdefer resolution_input.deinit(allocator);
                            resolution_input.getFocus().focusable = true;
                            try resolution_input.setContent(allocator, (if (picked_theirs) hunk.theirs else hunk.ours) orelse "");
                            try box.children.put(allocator, resolution_input.getFocus().id, .{ .widget = .{ .text_input = resolution_input }, .rect = null, .min_size = null });
                            if (chunk_index + 1 < desc.chunks.len) try addGap(allocator, &box);
                        },
                    }
                }
            }

            try addSubmitButtonLabeled(allocator, &box, "submit");

            box.getFocus().child_id = box.children.keys()[0];
            return box;
        }

        // one conflicted scalar field: both sides' version rows, then the
        // resolution input prefilled from the picked side.
        fn addFieldConflict(allocator: std.mem.Allocator, box: *wgt.Box(Widget), session: *ui.Session, data: *const Self, comptime name: []const u8, fc: *const FieldConflict) !void {
            const aa = session.page_arena.allocator();
            try addVersionRow(allocator, box, try sideLabel(aa, fc.ours.author, true), fc.ours.text, try useThisLink(session, data, name, false));
            try addVersionRow(allocator, box, try sideLabel(aa, fc.theirs.author, false), fc.theirs.text, try useThisLink(session, data, name, true));

            var resolution_input = try wgt.TextInput.init(allocator, .{ .label = " resolution ", .name = name, .visible_width = null, .rounded_corners = true, .render_content = session.is_terminal });
            errdefer resolution_input.deinit(allocator);
            resolution_input.getFocus().focusable = true;
            try resolution_input.setContent(allocator, if (data.theirsPicked(name)) fc.theirs.text else fc.ours.text);
            try box.children.put(allocator, resolution_input.getFocus().id, .{ .widget = .{ .text_input = resolution_input }, .rect = null, .min_size = null });
        }

        // atomic fields can only pick one complete side
        fn addAtomicConflict(allocator: std.mem.Allocator, box: *wgt.Box(Widget), session: *ui.Session, data: *const Self, comptime name: []const u8, fc: *const FieldConflict) !void {
            const aa = session.page_arena.allocator();
            try addVersionRow(allocator, box, try sideLabel(aa, fc.ours.author, true), fc.ours.text, try useThisLink(session, data, name, false));
            try addVersionRow(allocator, box, try sideLabel(aa, fc.theirs.author, false), fc.theirs.text, try useThisLink(session, data, name, true));
            var selected = try wgt.TextBox.init(allocator, if (data.theirsPicked(name)) fc.theirs.text else fc.ours.text, .{
                .border_style = .single,
                .rounded_corners = true,
                .wrap_kind = .word,
                .label = " resolution ",
            });
            errdefer selected.deinit(allocator);
            selected.getFocus().focusable = true;
            try box.children.put(allocator, selected.getFocus().id, .{ .widget = .{ .text_box = selected }, .rect = null, .min_size = null });
        }

        // a blank row setting a conflict group apart from its neighbors
        fn addGap(allocator: std.mem.Allocator, box: *wgt.Box(Widget)) !void {
            var text = try wgt.Text.init(allocator, " ");
            errdefer text.deinit(allocator);
            try box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
        }

        fn addLabel(allocator: std.mem.Allocator, box: *wgt.Box(Widget), content: []const u8) !void {
            var label = try SectionLabel.init(allocator, content);
            errdefer label.deinit(allocator);
            try box.children.put(allocator, label.getFocus().id, .{ .widget = .{ .section_label = label }, .rect = null, .min_size = null });
        }

        // one side of a conflict: the "use this" link on the left, the version
        // itself as a labeled read-only box.
        fn addVersionRow(allocator: std.mem.Allocator, box: *wgt.Box(Widget), label: []const u8, text: []const u8, link: []const u8) !void {
            var row = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer row.deinit(allocator);

            {
                const use_label = "use this";
                var use = try wgt.TextBox.init(allocator, use_label, .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer use.deinit(allocator);
                use.getFocus().focusable = true;
                use.getFocus().kind = .{ .custom = link };
                try row.children.put(allocator, use.getFocus().id, .{
                    .widget = .{ .text_box = use },
                    .rect = null,
                    .min_size = .{ .width = use_label.len + 2, .height = null },
                    .max_size = .{ .width = use_label.len + 2, .height = null },
                });
            }

            {
                var tb = try wgt.TextBox.init(allocator, if (text.len > 0) text else "(removed)", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .word, .label = label });
                errdefer tb.deinit(allocator);
                tb.getFocus().focusable = true;
                try row.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null });
            }

            row.getFocus().child_id = row.children.keys()[0];
            try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
        }

        // the label of one side's version box, naming its author
        fn sideLabel(aa: std.mem.Allocator, author: ui.Author, ours: bool) ![]const u8 {
            return switch (author) {
                .user_name, .email => |name| try std.fmt.allocPrint(aa, " edited by {s} ", .{name}),
                .unknown => if (ours) " current version " else " their version ",
            };
        }

        // the a: link that reloads the resolve page with `name` picked from ours
        // or theirs, reprefilling its resolution input
        fn useThisLink(session: *ui.Session, data: *const Self, name: []const u8, theirs: bool) ![]const u8 {
            const aa = session.page_arena.allocator();
            var picks: std.ArrayList(u8) = .empty;
            var it = std.mem.splitScalar(u8, data.theirs_picks, ',');
            while (it.next()) |pick| {
                if (pick.len == 0 or std.mem.eql(u8, pick, name)) continue;
                if (picks.items.len > 0) try picks.append(aa, ',');
                try picks.appendSlice(aa, pick);
            }
            if (theirs) {
                if (picks.items.len > 0) try picks.append(aa, ',');
                try picks.appendSlice(aa, name);
            }
            const route = resolveRoute(data.identity, data.selected_id, picks.items) orelse return error.RouteTooLong;
            return std.fmt.allocPrint(aa, "a:{s}", .{try route.toUrl(session.page_arena)});
        }

        fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(Widget), text: []const u8, bottom_label: []const u8, link: []const u8) !void {
            var row = try wgt.TextBox.init(allocator, text, .{ .border_style = .hidden, .rounded_corners = true, .wrap_kind = .word, .bottom_label = bottom_label });
            errdefer row.deinit(allocator);
            row.getFocus().focusable = true;
            if (link.len != 0) row.getFocus().kind = .{ .custom = link };
            try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null, .max_size = .{ .width = null, .height = 5 } });
        }

        pub fn deinit(self: *This, allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        fn header(self: *This) *HeaderType {
            return &@field(self.box.children.values()[header_index].widget, Data.header_widget_name);
        }

        fn viewStack(self: *This) *wgt.Stack(Widget) {
            return &self.box.children.values()[stack_index].widget.stack;
        }

        // `index`'s master-detail split inside the stack.
        fn resultsBox(self: *This, index: usize) *wgt.Box(Widget) {
            return &self.viewStack().children.values()[index].box;
        }

        // the tags view's flow inside the stack.
        fn tagsView(self: *This) *TagFlow {
            return &self.viewStack().children.values()[tags_view_index].tag_flow;
        }

        // the new-thread, edit, or resolve form inside the stack, or null when the
        // unauthorized view stands in for it.
        fn threadForm(self: *This) ?*wgt.Box(Widget) {
            return switch (self.viewStack().children.values()[form_view_index]) {
                .box => |*box| box,
                // the resolve form sits inside a scroll on the terminal
                .scroll => |*scroll| &scroll.child.box,
                else => null,
            };
        }

        fn confirmationForm(self: *This) ?*wgt.Box(Widget) {
            return switch (self.viewStack().children.values()[form_view_index]) {
                .center => |*center| switch (center.child.*) {
                    .box => |*box| box,
                    else => null,
                },
                else => null,
            };
        }

        // the resolve form's scroll on the terminal (the web page scrolls itself)
        fn resolveScroll(self: *This) ?*wgt.Scroll(Widget) {
            return switch (self.viewStack().children.values()[form_view_index]) {
                .scroll => |*scroll| scroll,
                else => null,
            };
        }

        fn listScroll(self: *This, index: usize) *wgt.Scroll(Widget) {
            return &self.resultsBox(index).children.values()[list_index].widget.scroll;
        }

        fn listBox(self: *This, index: usize) *wgt.Box(Widget) {
            return &self.listScroll(index).child.box;
        }

        fn detail(self: *This, index: usize) *DetailType {
            const frame = &self.resultsBox(index).children.values()[detail_index].widget.box;
            return &@field(frame.children.values()[0].widget, Data.detail_widget_name);
        }

        fn window(self: *This, index: usize) *const Window {
            if (supports_conflicts and index == conflict_view_index) return &self.data.conflicts;
            if (supports_drafts and index == drafts_view_index) return &self.data.drafts;
            return self.data.window(splitStatus(index));
        }

        fn stackSelectedIndex(self: *This) ?usize {
            const stack = self.viewStack();
            const cid = stack.getFocus().child_id orelse return null;
            return stack.children.getIndex(cid);
        }

        // the stack's selected master-detail split (null when the tags view or the
        // new-thread form shows).
        fn selectedSplitIndex(self: *This) ?usize {
            const idx = self.stackSelectedIndex() orelse return null;
            return if (idx < status_count or (supports_drafts and idx == drafts_view_index) or idx == conflict_view_index) idx else null;
        }

        fn detailActive(self: *This, index: usize) bool {
            const rb = self.resultsBox(index);
            const cid = rb.getFocus().child_id orelse return false;
            return rb.children.getIndex(cid) == detail_index;
        }

        fn headerActive(self: *This) bool {
            const cid = self.box.getFocus().child_id orelse return false;
            return self.box.children.getIndex(cid) == header_index;
        }

        fn tagsViewActive(self: *This) bool {
            if (self.headerActive()) return false;
            return self.stackSelectedIndex() == tags_view_index;
        }

        fn formViewActive(self: *This) bool {
            if (self.headerActive()) return false;
            return self.stackSelectedIndex() == form_view_index;
        }

        // the selected thread's index, or null when a window-navigation row is
        // selected (a leading "previous" row shifts the thread rows down by one).
        fn selectedThreadIndex(self: *This, index: usize) ?usize {
            const lb = self.listBox(index);
            const cid = lb.getFocus().child_id orelse return null;
            const idx = lb.children.getIndex(cid) orelse return null;
            const win = self.window(index);
            const lead: usize = if (win.prev_id != null) 1 else 0;
            if (idx < lead or idx - lead >= win.items.len) return null;
            return idx - lead;
        }

        pub fn build(self: *This, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            // each header tab maps 1:1 to a stack child by position
            if (self.header().getSelectedIndex()) |index| {
                const stack = self.viewStack();
                stack.getFocus().child_id = stack.children.keys()[index];
            }

            if (self.selectedSplitIndex()) |i| {
                // swap the detail pane to the selected thread when it changes.
                if (self.selectedThreadIndex(i)) |selected| {
                    const entry = self.window(i).items[selected];
                    const changed = if (self.detail(i).entry) |current| !std.mem.eql(u8, current.id, entry.id) else true;
                    if (changed) {
                        try self.detail(i).setEntry(allocator, entry);
                    }
                }

                // the selected list row shows a border (the focused TextBox
                // upgrades it to a double border itself); the rest stay borderless.
                const lb = self.listBox(i);
                for (lb.children.keys(), lb.children.values()) |id, *child| {
                    switch (child.widget) {
                        .text_box => |*tb| tb.options.border_style = if (lb.getFocus().child_id == id) .single else .hidden,
                        else => {},
                    }
                }

                // cap the list at list_max_width only while the detail pane fits
                // beside it. the box drops the detail when the width can't hold
                // both minimums, so when it's that narrow we lift the cap and let
                // the list fill the whole width.
                const both_panes_fit = if (constraint.max_size.width) |w| w >= list_max_width + detail_min_width else true;
                self.resultsBox(i).children.values()[list_index].max_size = if (both_panes_fit) .{ .width = list_max_width, .height = null } else null;

                // stretch the detail pane across the rest of the width so it fills
                // the area rather than shrinking to its content; its scroll fills
                // the pane.
                if (constraint.max_size.width) |w| {
                    self.resultsBox(i).children.values()[detail_index].min_size = .{ .width = if (both_panes_fit) w - list_max_width else w, .height = null };
                } else {
                    self.resultsBox(i).children.values()[detail_index].min_size = .{ .width = detail_min_width, .height = null };
                }
            }

            // refresh the form inputs' entries in the session's focus-id -> input
            // map with this frame's addresses, so the web/wasm form handling can
            // find them by focus id
            if (self.threadForm()) |form| {
                const inputs_arena = self.session.arena.allocator();
                for (form.children.values()) |*child| switch (child.widget) {
                    .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
                    else => {},
                };
            }

            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *This, allocator: std.mem.Allocator, raw_key: Key, root_focus: *Focus) !void {
            // wheel input moves focus like the arrows
            const key: Key = if (raw_key == .mouse and raw_key.mouse.action == .scroll)
                (if (raw_key.mouse.action.scroll == .up) .arrow_up else .arrow_down)
            else
                raw_key;

            if (self.headerActive()) {
                // down from the tabs re-enters the stack if the selected view has
                // something to focus; other keys move the tabs.
                if (inp.vertDirection(key) == .down) {
                    const enterable = if (self.viewStack().getSelected()) |selected| switch (selected.*) {
                        .tag_flow => |*tf| tf.text_boxes.items.len > 0,
                        // nothing focusable in the unauthorized view
                        .unauthorized => false,
                        else => true,
                    } else false;
                    if (enterable) root_focus.setFocus(self.box.children.keys()[stack_index]);
                } else {
                    try self.header().input(allocator, key, root_focus);
                }
                return;
            }
            if (self.tagsViewActive()) {
                self.tagsViewInput(key, root_focus);
                return;
            }
            if (self.formViewActive()) {
                if (confirmation(self.data.view) != null) {
                    try self.confirmationFormInput(allocator, key, root_focus);
                } else if (supports_conflicts and self.data.view == .resolve) {
                    try self.resolveInput(allocator, key, root_focus);
                } else if (self.data.view == .new_comment or self.data.view == .edit_comment) {
                    try self.commentFormInput(allocator, key, root_focus);
                } else {
                    try self.formInput(allocator, key, root_focus);
                }
                return;
            }
            const i = self.selectedSplitIndex() orelse return;
            if (self.detailActive(i)) {
                switch (try self.detail(i).inputWithExit(allocator, key, root_focus)) {
                    .none => {},
                    .list => self.focusList(i, root_focus),
                    .header => self.focusHeader(root_focus),
                }
            } else {
                self.listInput(i, key, root_focus);
            }
        }

        // arrow keys move the tag selection; up from the top row crosses to the
        // header tabs.
        fn tagsViewInput(self: *This, key: Key, root_focus: *Focus) void {
            const tf = self.tagsView();
            const cid = tf.focus.child_id orelse return;
            const cur = tf.indexOfFocusId(cid) orelse return;
            const count = tf.text_boxes.items.len;
            switch (key) {
                .arrow_left => if (cur > 0) root_focus.setFocus(tf.text_boxes.items[cur - 1].getFocus().id),
                .arrow_right => if (cur + 1 < count) root_focus.setFocus(tf.text_boxes.items[cur + 1].getFocus().id),
                .arrow_up => if (tf.rowStep(cur, false)) |i| root_focus.setFocus(tf.text_boxes.items[i].getFocus().id) else self.focusHeader(root_focus),
                .arrow_down => if (tf.rowStep(cur, true)) |i| root_focus.setFocus(tf.text_boxes.items[i].getFocus().id),
                .home => root_focus.setFocus(tf.text_boxes.items[0].getFocus().id),
                .end => root_focus.setFocus(tf.text_boxes.items[count - 1].getFocus().id),
                else => {},
            }
        }

        fn listInput(self: *This, index: usize, key: Key, root_focus: *Focus) void {
            // up/down (and the scroll wheel) move the selection a row; page up/down
            // jump a fixed amount. right/Enter cross into the detail pane. up from
            // the top row crosses into the header tabs.
            if (inp.rowDelta(key, @intCast(self.listBox(index).children.count()))) |delta| {
                const lb = self.listBox(index);
                const at_top = if (lb.getFocus().child_id) |cid| lb.children.getIndex(cid) == 0 else true;
                if (delta < 0 and at_top) return self.focusHeader(root_focus);
                moveRowFocus(lb, self.listScroll(index), root_focus, delta);
                return;
            }
            switch (key) {
                .enter, .arrow_right => _ = self.detail(index).focusFirst(root_focus),
                else => {},
            }
        }

        fn formInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const form = self.threadForm() orelse return;
            const cid = form.getFocus().child_id orelse return;
            const cur = form.children.getIndex(cid) orelse return;

            if (cur == description_field_index) {
                const child = &form.children.values()[cur];
                if (try multilineKeepsKey(&child.widget.text_input, allocator, key))
                    return child.widget.input(allocator, key, root_focus);
            }

            switch (key) {
                .arrow_up, .back_tab => if (cur > 0)
                    root_focus.setFocus(form.children.keys()[cur - 1])
                else
                    self.focusHeader(root_focus),
                .arrow_down, .tab => if (cur < submit_field_index) {
                    root_focus.setFocus(form.children.keys()[cur + 1]);
                },
                .enter => if (cur == submit_field_index) try self.submitForm(allocator),
                .mouse => |mouse| if (cur == submit_field_index) {
                    const submit = &form.children.values()[cur].widget.submit_button;
                    if (inp.leftClickOn(root_focus, submit.buttonId(), mouse)) try self.submitForm(allocator);
                },
                else => try form.children.values()[cur].widget.input(allocator, key, root_focus),
            }
        }

        fn commentFormInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const form = self.threadForm() orelse return;
            const cid = form.getFocus().child_id orelse return;
            const cur = form.children.getIndex(cid) orelse return;
            const child = &form.children.values()[cur];

            if (cur == comment_body_field_index and try multilineKeepsKey(&child.widget.text_input, allocator, key))
                return child.widget.input(allocator, key, root_focus);

            switch (key) {
                .arrow_up, .back_tab => if (cur > comment_author_field_index)
                    root_focus.setFocus(form.children.keys()[cur - 1])
                else
                    self.focusHeader(root_focus),
                .arrow_down, .tab => if (cur < comment_submit_field_index)
                    root_focus.setFocus(form.children.keys()[cur + 1]),
                .enter => if (cur == comment_submit_field_index) try self.submitComment(allocator),
                .mouse => |mouse| if (cur == comment_submit_field_index) {
                    const submit = &child.widget.submit_button;
                    if (inp.leftClickOn(root_focus, submit.buttonId(), mouse)) try self.submitComment(allocator);
                },
                else => try child.widget.input(allocator, key, root_focus),
            }
        }

        fn confirmationFormInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const form = self.confirmationForm() orelse return;
            const child_id = form.getFocus().child_id orelse return;
            const index = form.children.getIndex(child_id) orelse return;
            switch (key) {
                .arrow_up, .back_tab => if (index > 1)
                    root_focus.setFocus(form.children.keys()[index - 1])
                else
                    self.focusHeader(root_focus),
                .arrow_down, .tab => if (index + 1 < form.children.count()) root_focus.setFocus(form.children.keys()[index + 1]),
                .enter => try self.submitConfirmation(allocator, index),
                .mouse => |mouse| for (form.children.keys()[1..], 1..) |button_id, button_index| {
                    if (inp.leftClickOn(root_focus, button_id, mouse)) {
                        try self.submitConfirmation(allocator, button_index);
                        break;
                    }
                },
                else => {},
            }
        }

        // the multiline hunk inputs keep enter and any up/down that has a row to
        // move to; enter on a "use this" link is a navigation the host follows
        // before this runs.
        fn resolveInput(self: *This, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const form = self.threadForm() orelse return;
            const cid = form.getFocus().child_id orelse return;
            const cur = form.children.getIndex(cid) orelse return;
            const child = &form.children.values()[cur];

            if (child.widget == .text_input) {
                const ti = &child.widget.text_input;
                if (ti.options.multiline and try multilineKeepsKey(ti, allocator, key))
                    return child.widget.input(allocator, key, root_focus);
            }

            const on_submit = child.widget == .submit_button;

            switch (key) {
                .arrow_up, .back_tab => if (resolveStep(form, cur, false)) |i| self.focusResolveChild(form, i, root_focus) else self.focusHeader(root_focus),
                .arrow_down, .tab => if (resolveStep(form, cur, true)) |i| self.focusResolveChild(form, i, root_focus),
                .arrow_left, .arrow_right => switch (child.widget) {
                    .box => |*row| {
                        const row_cid = row.getFocus().child_id orelse return;
                        const row_index = row.children.getIndex(row_cid) orelse return;
                        if (key == .arrow_left) {
                            if (row_index > 0) root_focus.setFocus(row.children.keys()[row_index - 1]);
                        } else if (row_index + 1 < row.children.count()) {
                            root_focus.setFocus(row.children.keys()[row_index + 1]);
                        }
                    },
                    else => try child.widget.input(allocator, key, root_focus),
                },
                .enter => if (on_submit) try self.submitResolution(allocator),
                .mouse => |mouse| if (on_submit) {
                    if (inp.leftClickOn(root_focus, child.widget.submit_button.buttonId(), mouse)) try self.submitResolution(allocator);
                },
                else => try child.widget.input(allocator, key, root_focus),
            }
        }

        // a multiline input keeps enter and any up/down that has a row to move to
        fn multilineKeepsKey(text_input: *wgt.TextInput, allocator: std.mem.Allocator, key: Key) !bool {
            return switch (key) {
                .enter => true,
                .arrow_up => !try text_input.cursorOnFirstRow(allocator),
                .arrow_down => !try text_input.cursorOnLastRow(allocator),
                else => false,
            };
        }

        // the neighboring focusable resolve-form child, skipping the spacer and
        // the blank gap rows
        fn resolveStep(form: *wgt.Box(Widget), cur: usize, down: bool) ?usize {
            var i = cur;
            while (true) {
                if (down) {
                    i += 1;
                    if (i >= form.children.count()) return null;
                } else {
                    if (i == 0) return null;
                    i -= 1;
                }
                switch (form.children.values()[i].widget) {
                    .spacer, .text => continue,
                    else => return i,
                }
            }
        }

        // focus the resolve-form child at `i` (a version row focuses its selected
        // child) and keep it visible on the terminal
        fn focusResolveChild(self: *This, form: *wgt.Box(Widget), i: usize, root_focus: *Focus) void {
            const child = &form.children.values()[i];
            switch (child.widget) {
                .box => |*row| root_focus.setFocus(row.getFocus().child_id orelse form.children.keys()[i]),
                else => root_focus.setFocus(form.children.keys()[i]),
            }
            if (self.session.is_terminal) {
                if (self.resolveScroll()) |sc| {
                    if (child.rect) |rect| sc.scrollToRect(rect);
                }
            }
        }

        // re-emit the conflicted thread's event with the resolved content; any
        // event on the thread settles its conflict entry. this is the terminal
        // path; the web posts the form to the resolve route.
        fn submitResolution(self: *This, allocator: std.mem.Allocator) !void {
            if (comptime wasm) return;
            const io = self.session.io orelse return;
            const src = self.data.repo_source orelse return;
            const entry = self.data.selectedThread() orelse return;
            const author = (try self.session.eventAuthor()) orelse return;
            const form = self.threadForm() orelse return;

            // gather the inputs by name; the d<n> hunk inputs appear in chunk order
            var title: ?[]u8 = null;
            var tags: ?[]u8 = null;
            var hunks: std.ArrayList([]const u8) = .empty;
            defer {
                if (title) |t| allocator.free(t);
                if (tags) |t| allocator.free(t);
                for (hunks.items) |h| allocator.free(h);
                hunks.deinit(allocator);
            }
            for (form.children.values()) |*child| switch (child.widget) {
                .text_input => |*ti| {
                    const text = try ti.text(allocator);
                    errdefer allocator.free(text);
                    if (std.mem.eql(u8, ti.options.name, "title")) {
                        title = text;
                    } else if (std.mem.eql(u8, ti.options.name, "tags")) {
                        tags = text;
                    } else {
                        try hunks.append(allocator, text);
                    }
                },
                else => {},
            };

            const id_bytes = try evt.parseEventId(entry.id);

            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| {
                            var resolution: Event.Resolve = .{
                                .title = title,
                                .tags = tags,
                                .hunks = hunks.items,
                            };
                            if (comptime @hasField(Event.Resolve, "theirs")) resolution.theirs = self.data.theirs_picks;
                            const change = Event.Update{ .resolve = resolution };
                            Event.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, change, author) catch |err| switch (err) {
                                // leave the form up for correction
                                error.InvalidFields => return,
                                else => |e| return e,
                            };
                        },
                    }
                },
            }

            const route = listRoute(self.data.identity, entryStatus(entry.*), "", entry.id) orelse return;
            try self.session.navigate(route);
        }

        // commit a new or edited comment and navigate to its permalink. this is the
        // terminal path; the web posts the form to its comment route.
        fn submitComment(self: *This, allocator: std.mem.Allocator) !void {
            if (comptime wasm) return;
            const io = self.session.io orelse return;
            const src = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;
            const form = self.threadForm() orelse return;
            const body_input = &form.children.values()[comment_body_field_index].widget.text_input;
            const body = try body_input.text(allocator);
            defer allocator.free(body);
            if (!evt.Comment.fieldsValid(body)) return;

            var thread_id: [evt.event_id_size * 2]u8 = undefined;
            @memcpy(&thread_id, self.data.selected_id);
            const parent_id = if (self.data.comment_id.len == 0) thread_id else blk: {
                var parent: [evt.event_id_size * 2]u8 = undefined;
                @memcpy(&parent, self.data.comment_id);
                break :blk parent;
            };
            var event_id_hex: [evt.event_id_size * 2]u8 = undefined;
            const editing = self.data.view == .edit_comment;
            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| if (editing) {
                            const comment_id = evt.parseEventId(self.data.comment_id) catch return;
                            try evt.Comment.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &thread_id, &comment_id, body, author);
                            event_id_hex = std.fmt.bytesToHex(comment_id, .lower);
                        } else {
                            event_id_hex = try evt.Comment.create(repo_kind, repo.self_repo_opts, io, allocator, repo, &thread_id, &parent_id, body, author);
                        },
                    }
                },
            }

            body_input.clear(allocator);
            const route = ui.RoutablePage.repoThreadCommentRoute(kind, self.data.identity, &thread_id, &event_id_hex, 0) orelse return;
            try self.session.navigate(route);
        }

        // the terminal submit paths: the new form commits a new thread event, the
        // edit form re-emits the selected thread's event with the form's content.
        // the web posts the forms to their routes instead.
        fn submitForm(self: *This, allocator: std.mem.Allocator) !void {
            if (self.data.view == .edit) {
                try self.submitEditedThread(allocator);
            } else {
                try self.submitNewThread(allocator);
            }
        }

        // commit the new thread to the repo's events branch and navigate to it.
        // this is the terminal path; the web posts the form to the thread route,
        // so the wasm side never runs (or compiles) the repo access below.
        fn submitNewThread(self: *This, allocator: std.mem.Allocator) !void {
            if (comptime wasm) return;
            const io = self.session.io orelse return;
            const src = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;

            const form = self.threadForm() orelse return;
            const title_input = &form.children.values()[title_field_index].widget.text_input;
            const tags_input = &form.children.values()[tags_field_index].widget.text_input;
            const description_input = &form.children.values()[description_field_index].widget.text_input;

            const title = try title_input.text(allocator);
            defer allocator.free(title);
            const tags = try tags_input.text(allocator);
            defer allocator.free(tags);
            const description = try description_input.text(allocator);
            defer allocator.free(description);
            const target_branch = if (comptime supports_drafts) try form.children.values()[target_branch_field_index].widget.text_input.text(allocator) else "";
            defer if (comptime supports_drafts) allocator.free(target_branch);

            if (!Event.fieldsValid(title, tags)) return;

            if (comptime supports_drafts) {
                const event_id_hex = Data.createDraft(self.data, self.session, allocator, title, tags, description, target_branch) catch return;
                title_input.clear(allocator);
                tags_input.clear(allocator);
                description_input.clear(allocator);
                form.children.values()[target_branch_field_index].widget.text_input.clear(allocator);
                const route = ui.RoutablePage.repoThreadCommentsRoute(kind, self.data.identity, &event_id_hex, 0) orelse return;
                try self.session.navigate(route);
                return;
            }

            var id_bytes: [evt.event_id_size]u8 = undefined;
            io.random(&id_bytes);
            const event_id_hex = std.fmt.bytesToHex(id_bytes, .lower);

            const event = evt.EventWithId{
                .id = event_id_hex,
                .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
                .author = author,
                .event = @unionInit(evt.Event, @tagName(kind), Event{
                    .title = title,
                    .description = description,
                    .tags = tags,
                }),
            };

            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try evt.consume(.repo, repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{event}),
                    }
                },
            }

            // wipe the form so a return visit starts fresh
            title_input.clear(allocator);
            tags_input.clear(allocator);
            description_input.clear(allocator);

            const route = listRoute(self.data.identity, @enumFromInt(0), "", &event_id_hex) orelse return;
            try self.session.navigate(route);
        }

        // re-emit the selected thread's event with the form's content (status
        // preserved), then reload the thread's page. this is the terminal path;
        // the web posts the form to the edit route.
        fn submitEditedThread(self: *This, allocator: std.mem.Allocator) !void {
            if (comptime wasm) return;
            const io = self.session.io orelse return;
            const entry = self.data.selectedThread() orelse return;

            const form = self.threadForm() orelse return;
            const title_input = &form.children.values()[title_field_index].widget.text_input;
            const tags_input = &form.children.values()[tags_field_index].widget.text_input;
            const description_input = &form.children.values()[description_field_index].widget.text_input;

            const title = try title_input.text(allocator);
            defer allocator.free(title);
            const tags = try tags_input.text(allocator);
            defer allocator.free(tags);
            const description = try description_input.text(allocator);
            defer allocator.free(description);
            const target_branch = if (comptime supports_drafts) try form.children.values()[target_branch_field_index].widget.text_input.text(allocator) else "";
            defer if (comptime supports_drafts) allocator.free(target_branch);

            if (!Event.fieldsValid(title, tags)) return;

            if (comptime supports_drafts) {
                if (entryDraft(entry.*)) {
                    self.data.editDraft(self.session, allocator, entry.id, title, tags, description, target_branch) catch return;
                    const route = listRoute(self.data.identity, entryStatus(entry.*), "", entry.id) orelse return;
                    try self.session.navigate(route);
                    return;
                }
            }

            const id_bytes = try evt.parseEventId(entry.id);
            const src = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;

            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| if (supports_drafts) {
                            try Event.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, .{ .fields = .{
                                .title = title,
                                .tags = tags,
                                .description = description,
                                .target_branch = target_branch,
                            } }, author);
                        } else if (has_status)
                            try Event.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, .{ .fields = .{
                                .title = title,
                                .tags = tags,
                                .description = description,
                            } }, author)
                        else
                            try Event.update(repo_kind, repo.self_repo_opts, io, allocator, repo, &id_bytes, title, tags, description, author),
                    }
                },
            }

            const route = listRoute(self.data.identity, entryStatus(entry.*), "", entry.id) orelse return;
            try self.session.navigate(route);
        }

        fn submitConfirmation(self: *This, allocator: std.mem.Allocator, button_index: usize) !void {
            switch (confirmation(self.data.view) orelse return) {
                .publish => if (comptime supports_drafts) {
                    if (comptime wasm) return;
                    const entry = self.data.selectedThread() orelse return;
                    if (!entryDraft(entry.*)) return;
                    try self.data.publishDraft(self.session, allocator, entry.id);
                    const route = listRoute(self.data.identity, @enumFromInt(0), "", entry.id) orelse return;
                    try self.session.navigate(route);
                } else unreachable,
                .merge => if (comptime supports_merge) {
                    if (comptime wasm) return;
                    const entry = self.data.selectedThread() orelse return;
                    try self.data.mergePatch(self.session, allocator, entry.id, button_index > 1);
                    const merged = std.meta.stringToEnum(Status, "merged") orelse return;
                    const route = listRoute(self.data.identity, merged, "", entry.id) orelse return;
                    try self.session.navigate(route);
                } else unreachable,
                .remove => try self.submitRemove(allocator),
            }
        }

        fn submitRemove(self: *This, allocator: std.mem.Allocator) !void {
            const comment = self.data.comment_id.len != 0;
            const event_id = if (comment) self.data.comment_id else self.data.selected_id;
            const id = evt.parseEventId(event_id) catch return;
            try self.removeEvent(allocator, if (comment) .comment else kind, id);
        }

        fn removeEvent(self: *This, allocator: std.mem.Allocator, event_kind: evt.EventKind, id: [evt.event_id_size]u8) !void {
            if (comptime wasm) return;

            if (comptime supports_drafts) {
                const selected = self.data.selectedThread() orelse return;
                if (event_kind == kind and entryDraft(selected.*)) {
                    try Data.removeDraft(self.session, allocator, &id);
                    const route = draftsRoute(self.data.identity) orelse return;
                    try self.session.navigate(route);
                    return;
                }
            }

            const io = self.session.io orelse return;
            const src = self.data.repo_source orelse return;
            const author = (try self.session.eventAuthor()) orelse return;

            switch (src.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts());
                    defer any_repo.deinit(io, allocator);
                    switch (any_repo) {
                        inline else => |*repo| try evt.remove(.repo, repo_kind, repo.self_repo_opts, io, allocator, repo, &id, event_kind, author),
                    }
                },
            }

            const id_hex = std.fmt.bytesToHex(id, .lower);
            const route = ui.RoutablePage.repoEventsRoute(self.data.identity, .removed, event_kind, &id_hex) orelse return;
            try self.session.navigate(route);
        }

        // return to the list.
        fn focusList(self: *This, index: usize, root_focus: *Focus) void {
            root_focus.setFocus(self.listScroll(index).getFocus().id);
        }

        // cross to the header tabs above the stack.
        fn focusHeader(self: *This, root_focus: *Focus) void {
            root_focus.setFocus(self.box.children.keys()[header_index]);
        }

        pub fn clearGrid(self: *This) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: This) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *This) *Focus {
            return self.box.getFocus();
        }

        // for the parent's "scroll up at the top jumps to the header" check: at the
        // top only while the header tabs hold focus, so up from the split
        // crosses into the tabs first.
        pub fn getSelectedIndex(self: *This) ?usize {
            return if (self.headerActive()) 0 else 1;
        }
    };
}

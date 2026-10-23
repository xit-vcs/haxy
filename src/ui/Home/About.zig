const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const md = @import("../../markdown.zig");
const Markdown = @import("../Repo/Markdown.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// the admin repo's about page, re-read on every page build. a level 1
// heading on its first line becomes the header title instead.
title: ?[]const u8,
text: []const u8,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session) !Self {
    const admin_repo = session.admin_repo orelse return error.NotFound;
    const io = session.io orelse return error.NotFound;
    const text = admin_repo.core.work_dir.readFileAlloc(io, evt.admin_about_path, arena.allocator(), .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => |e| return e,
    };
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trimEnd(u8, text[0..line_end], "\r");
    if (line.len < 2 or line[0] != '#' or (line[1] != ' ' and line[1] != '\t')) return .{ .title = null, .text = text };
    const title = std.mem.trim(u8, line[2..], " \t");
    if (title.len == 0) return .{ .title = null, .text = text };
    return .{ .title = title, .text = std.mem.trimStart(u8, text[line_end..], "\r\n") };
}

pub const View = struct {
    // the scroll wrapped in a border that turns double while the page has focus,
    // centered at a readable width
    center: ui.widget.Center,
    session: *ui.Session,

    const max_width = 80;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const doc = try md.parseText(session.page_arena.allocator(), data.text);

        var scroll = blk: {
            var markdown = try Markdown.View.init(allocator, session, doc, null, evt.admin_about_path);
            errdefer markdown.deinit(allocator);
            break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .markdown = markdown }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
        };
        errdefer scroll.deinit(allocator);
        var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border = .single, .round_corners = true, .direction = .vert });
        errdefer frame.deinit(allocator);
        frame.getFocus().child_id = scroll.getFocus().id;
        try frame.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null, .flex = .grow });
        var center = try ui.widget.Center.init(allocator, .{ .box = frame });
        center.max_width = max_width;
        return .{ .center = center, .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const focused = if (root_focus.grandchild_id) |id| self.markdownView().owns(id) else false;
        self.frameBox().options.border = if (focused) .double else .single;
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the web scrolls natively and leaves tab to the browser
        if (!self.session.is_terminal) return;
        try self.markdownView().input(allocator, key, root_focus);
        const sc = self.contentScroll();
        switch (key) {
            .arrow_up => sc.y -= 1,
            .arrow_down => sc.y += 1,
            .page_up => sc.y -= 10,
            .page_down => sc.y += 10,
            .home => sc.y = 0,
            .end => sc.y = std.math.maxInt(isize),
            .scroll_up => sc.y -= 5,
            .scroll_down => sc.y += 5,
            .tab, .back_tab => try self.markdownView().stepLink(allocator, root_focus, sc, 0, 0, key == .tab),
            else => {},
        }
        sc.clampToContent();
    }

    pub fn clearGrid(self: *View) void {
        self.center.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.center.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.center.getFocus();
    }

    pub fn atTop(self: View) bool {
        return self.center.child.box.children.values()[0].widget.scroll.y <= 0;
    }

    fn frameBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.center.child.box;
    }

    fn contentScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.frameBox().children.values()[0].widget.scroll;
    }

    fn markdownView(self: *View) *Markdown.View {
        return &self.contentScroll().child.markdown;
    }
};

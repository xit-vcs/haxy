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
    // the scroll wrapped in a border that turns double while the page has focus
    frame: wgt.Box(ui.Widget),
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const aa = session.page_arena.allocator();
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, data.text, '\n');
        while (it.next()) |line| try lines.append(aa, line);
        const doc = try md.parse(aa, lines.items);

        var scroll = blk: {
            var markdown = try Markdown.View.init(allocator, doc, null, evt.admin_about_path, session.page_arena);
            errdefer markdown.deinit(allocator);
            break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .markdown = markdown }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
        };
        errdefer scroll.deinit(allocator);
        var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = .single, .round_corners = true, .direction = .vert });
        errdefer frame.deinit(allocator);
        frame.getFocus().child_id = scroll.getFocus().id;
        try frame.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null, .flex = .grow });
        return .{ .frame = frame, .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const focused = if (root_focus.grandchild_id) |id| self.markdownView().owns(id) else false;
        self.frame.options.border_style = if (focused) .double else .single;
        try self.frame.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the web scrolls natively and leaves tab to the browser
        if (!self.session.is_terminal) return;
        const sc = self.contentScroll();
        switch (key) {
            .arrow_up => sc.y -= 1,
            .arrow_down => sc.y += 1,
            .page_up => sc.y -= 10,
            .page_down => sc.y += 10,
            .home => sc.y = 0,
            .end => sc.y = std.math.maxInt(isize),
            .mouse => |mouse| switch (mouse.action) {
                .scroll => |dir| sc.y += if (dir == .up) -5 else 5,
                else => {},
            },
            .tab, .back_tab => try self.markdownView().stepLink(allocator, root_focus, sc, key == .tab),
            else => {},
        }
        sc.clampToContent();
    }

    pub fn clearGrid(self: *View) void {
        self.frame.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.frame.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.frame.getFocus();
    }

    pub fn atTop(self: View) bool {
        return self.frame.children.values()[0].widget.scroll.y <= 0;
    }

    fn contentScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.frame.children.values()[0].widget.scroll;
    }

    fn markdownView(self: *View) *Markdown.View {
        return &self.contentScroll().child.markdown;
    }
};

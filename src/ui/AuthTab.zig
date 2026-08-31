const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const View = struct {
    text_box: wgt.TextBox,
    session: *ui.Session,
    // backs the bottom label, which borrows it
    bottom_label_buf: [ui.clipped_bottom_label_max_len]u8,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var text_box = try wgt.TextBox.init(allocator, "login", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = "ai:/auth" };
        return .{
            .text_box = text_box,
            .session = session,
            .bottom_label_buf = undefined,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    fn text(self: *const View) []const u8 {
        return if (self.session.data.user_id == null) "login" else "logout";
    }

    fn bottomLabel(self: *View) []const u8 {
        if (self.session.data.user_id == null) return "";
        const name = self.session.data.user_name orelse return "";
        return ui.clippedBottomLabel(&self.bottom_label_buf, name) catch unreachable;
    }

    pub fn minWidth(self: *View) usize {
        return @max(self.text().len, self.bottomLabel().len) + 2;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.text_box.setContent(allocator, self.text());
        self.text_box.options.bottom_label = self.bottomLabel();
        try self.text_box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        try self.text_box.input(allocator, key, root_focus);
    }

    pub fn clearGrid(self: *View) void {
        self.text_box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.text_box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.text_box.getFocus();
    }
};

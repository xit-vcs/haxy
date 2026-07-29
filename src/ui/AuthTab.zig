const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Self = @This();

pub fn init() Self {
    return .{};
}

pub const View = struct {
    text_box: wgt.TextBox(ui.Widget),
    session: *ui.Session,
    // backs the tab's text, which borrows it. sized for the longest name, so
    // build never allocates.
    text_buf: [logout_prefix.len + evt.User.name_max_len]u8,

    const logout_prefix = "logout ";

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, "login", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = "ai:/auth" };
        return .{
            .text_box = text_box,
            .session = session,
            .text_buf = undefined,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    // the action the tab performs, naming whoever is logged in
    fn text(self: *View) []const u8 {
        if (self.session.data.user_id == null) return "login";
        const name = self.session.data.user_name orelse return "logout";
        // validateName caps the name, so the buffer always fits it
        return std.fmt.bufPrint(&self.text_buf, logout_prefix ++ "{s}", .{name}) catch unreachable;
    }

    // what the tab's text needs, plus its border
    pub fn minWidth(self: *View) usize {
        return self.text().len + 2;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // update the displayed text based on session state. the inner Text
        // widget's content is just a slice, so we can repoint it without
        // re-allocating.
        if (self.text_box.box.children.values().len > 0) {
            const text_widget = &self.text_box.box.children.values()[0].widget.text;
            text_widget.content = self.text();
        }
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

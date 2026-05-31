const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Self = @This();

pub const min_width: usize = "logout".len + 2;

pub fn init() Self {
    return .{};
}

pub const View = struct {
    text_box: wgt.TextBox(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, "login", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        text_box.getFocus().focusable = true;
        text_box.getFocus().kind = .{ .custom = "a:/auth" };
        return .{
            .text_box = text_box,
            .data = data,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // update the displayed label based on session state. the inner Text
        // widget's content is just a slice, so we can repoint it without
        // re-allocating.
        if (self.text_box.box.children.values().len > 0) {
            const text_widget = &self.text_box.box.children.values()[0].widget.text;
            text_widget.content = if (self.session.data.user_id != null) "logout" else "login";
        }
        try self.text_box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
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

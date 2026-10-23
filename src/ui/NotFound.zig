const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

// shown in place of a page whose build found nothing to show
pub const View = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,

    const header_index: usize = 0;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var header = try wgt.Box(ui.Widget).init(allocator, .{ .border = .hidden, .direction = .horiz });
            errdefer header.deinit(allocator);
            try ui.widget.addBackButton(allocator, &header, session);
            _ = try ui.widget.addHomeButton(allocator, &header, session);
            try box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .box = header }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox.init(allocator, "can't find it, homie", .{ .border = null, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            var center = try ui.widget.Center.init(allocator, .{ .text_box = text_box });
            errdefer center.deinit(allocator);
            try box.children.put(allocator, center.getFocus().id, .{ .widget = .{ .center = center }, .rect = null, .min_size = null });
        }

        return .{ .box = box, .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        ui.widget.setBackButtonVisible(&self.box.children.values()[header_index].widget.box, self.session.back == .available);
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }
};

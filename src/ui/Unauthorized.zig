const std = @import("std");
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

// shown in place of a view that requires being logged in
pub const View = struct {
    center: ui.widget.Center,

    const message =
        \\you must be logged in to view this.
        \\
        \\here's an emoticon from the early 2000s instead:
        \\
        \\<('o'<) ^( '-' )^ (>'o')>
        \\
        \\hope it helps.
    ;

    pub fn init(allocator: std.mem.Allocator) !View {
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, message, .{ .border_style = null, .rounded_corners = false, .wrap_kind = .word });
        errdefer text_box.deinit(allocator);
        return .{ .center = try ui.widget.Center.init(allocator, .{ .text_box = text_box }) };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
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
};

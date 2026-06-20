const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const RefOrOid = ui.RoutablePage.RefOrOid;

// "viewing <ref_or_oid> <value>", e.g. "viewing branch master".
content: []const u8,

const Self = @This();

pub fn init(aa: std.mem.Allocator, ref_or_oid: RefOrOid, value: []const u8) !Self {
    return .{
        .content = try std.fmt.allocPrint(aa, "viewing {s} {s}", .{ @tagName(ref_or_oid), value }),
    };
}

pub const View = struct {
    text_box: wgt.TextBox(ui.Widget),
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        _ = session;
        var text_box = try wgt.TextBox(ui.Widget).init(allocator, data.content, .{ .border_style = .hidden, .wrap_kind = .none });
        errdefer text_box.deinit(allocator);
        return .{ .text_box = text_box, .data = data };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.text_box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // a single line plus the hidden border is 3 rows tall; stretch the box to
        // the full width by handing the available width down as a min width.
        try self.text_box.build(allocator, .{
            .min_size = .{ .width = constraint.max_size.width, .height = null },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = self;
        _ = allocator;
        _ = key;
        _ = root_focus;
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

const std = @import("std");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Self = @This();

// focus kind marking the header's quit tab
pub const tab_kind = "quit";

// label shown on the header's quit tab (a single-column box-drawing cross)
pub const tab_label = "╳";

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.widget.Center,
    session: *ui.Session,
    button_id: usize,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var prompt = try wgt.Text.init(allocator, "are you sure?");
            errdefer prompt.deinit(allocator);
            try box.children.put(allocator, prompt.getFocus().id, .{
                .widget = .{ .text = prompt },
                .rect = null,
                .min_size = null,
            });
        }

        var button_id: usize = undefined;
        {
            var button = try wgt.TextBox.init(allocator, "quit", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().mode = .all;
            button_id = button.getFocus().id;
            try box.children.put(allocator, button.getFocus().id, .{
                .widget = .{ .text_box = button },
                .rect = null,
                .min_size = null,
            });
        }

        box.getFocus().child_id = button_id;

        return .{
            .center = try ui.widget.Center.init(allocator, .{ .box = box }),
            .session = session,
            .button_id = button_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        switch (key) {
            .enter => {
                self.session.quit_requested = true;
                return;
            },
            .mouse => |mouse| {
                if (inp.leftClickOn(root_focus, self.button_id, mouse)) {
                    self.session.quit_requested = true;
                    return;
                }
            },
            else => {},
        }
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
        _ = self;
        return true;
    }
};

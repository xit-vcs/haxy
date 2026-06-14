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

// focus kind marking the header's quit tab
pub const tab_kind = "quit";

// label shown on the header's quit tab (a single-column box-drawing cross)
pub const tab_label = "╳";

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.Center,
    data: *const Self,
    session: *ui.Session,
    button_id: usize,

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            var prompt = try wgt.Text(ui.Widget).init(allocator, "are you sure?");
            errdefer prompt.deinit(allocator);
            try box.children.put(allocator, prompt.getFocus().id, .{
                .widget = .{ .text = prompt },
                .rect = null,
                .min_size = null,
            });
        }

        var button_id: usize = undefined;
        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, "quit", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            button_id = button.getFocus().id;
            try box.children.put(allocator, button.getFocus().id, .{
                .widget = .{ .text_box = button },
                .rect = null,
                .min_size = null,
            });
        }

        box.getFocus().child_id = button_id;

        return .{
            .center = try ui.Center.init(allocator, .{ .box = box }, .both),
            .data = data,
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

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        switch (key) {
            .enter => {
                self.session.quit_requested = true;
                return;
            },
            .mouse => |mouse| {
                if (mouse.action == .press and mouse.action.press == .left) {
                    if (root_focus.children.get(self.button_id)) |entry| {
                        const r = entry.rect;
                        if (mouse.x >= r.x and mouse.y >= r.y and
                            mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                        {
                            self.session.quit_requested = true;
                            return;
                        }
                    }
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

    pub fn getSelectedIndex(self: View) ?usize {
        _ = self;
        return 0;
    }
};

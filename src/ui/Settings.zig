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

pub fn init() Self {
    return .{};
}

pub const View = struct {
    stack: wgt.Stack(ui.Widget),
    session: *ui.Session,
    button_id: usize,

    const authorized_index = 0;
    const unauthorized_index = 1;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var stack = try wgt.Stack(ui.Widget).init(allocator);
        errdefer stack.deinit(allocator);
        var button_id: usize = undefined;
        {
            var authorized = blk: {
                var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer box.deinit(allocator);

                // on the web each control posts to a page-scoped form
                box.getFocus().kind = .{ .custom = "form:ansi" };

                {
                    var button = try wgt.TextBox.init(allocator, ansiLabel(session), .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                    errdefer button.deinit(allocator);
                    // the renderer distinguishes plain clickables from buttons that
                    // should POST to a server route by this kind.
                    button.getFocus().kind = .{ .custom = "submit" };
                    button.getFocus().mode = .all;
                    button_id = button.getFocus().id;
                    try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
                }

                box.getFocus().child_id = button_id;
                break :blk try ui.widget.Center.init(allocator, .{ .box = box });
            };
            errdefer authorized.deinit(allocator);
            try stack.children.put(allocator, authorized.getFocus().id, .{ .center = authorized });
        }
        {
            var unauthorized = try ui.Unauthorized.View.init(allocator);
            errdefer unauthorized.deinit(allocator);
            try stack.children.put(allocator, unauthorized.getFocus().id, .{ .unauthorized = unauthorized });
        }

        return .{
            .stack = stack,
            .session = session,
            .button_id = button_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // decided per-frame since the tty doesn't rebuild the page on login
        const index: usize = if (self.session.data.user_id != null) authorized_index else unauthorized_index;
        self.stack.getFocus().child_id = self.stack.children.keys()[index];
        if (self.session.data.user_id != null) {
            const box = &self.stack.children.values()[authorized_index].center.child.box;
            const button = &box.children.values()[0].widget.text_box;
            try button.setContent(allocator, ansiLabel(self.session));
        }
        try self.stack.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.session.data.user_id == null) return; // blank/disabled when logged out
        switch (key) {
            .enter => try self.toggle(),
            .mouse => |mouse| {
                if (inp.leftClickOn(root_focus, self.button_id, mouse)) {
                    try self.toggle();
                }
            },
            else => {},
        }
    }

    fn toggle(self: *View) !void {
        try self.session.push(.toggle_ansi);
    }

    pub fn clearGrid(self: *View) void {
        self.stack.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.stack.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.stack.getFocus();
    }

    pub fn atTop(self: View) bool {
        _ = self;
        return true;
    }
};

fn ansiLabel(session: *const ui.Session) []const u8 {
    const label_on = "turn off ANSI art";
    const label_off = "turn on ANSI art";
    return if (session.data.enable_ansi) label_on else label_off;
}

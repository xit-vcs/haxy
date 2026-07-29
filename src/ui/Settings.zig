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
    // own container focus so callers see a stable id while login/logout swap
    // the shown view
    focus: *Focus,
    // the settings controls, shown when logged in
    authorized: ui.Center,
    unauthorized: ui.Unauthorized.View,
    session: *ui.Session,
    button_id: usize,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var button_id: usize = undefined;
        var authorized = blk: {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer box.deinit(allocator);

            // on the web each control posts to a page-scoped form
            box.getFocus().kind = .{ .custom = "form:ansi" };

            {
                var button = try wgt.TextBox(ui.Widget).init(allocator, ansiLabel(session), .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                // the renderer distinguishes plain clickables from buttons that
                // should POST to a server route by this kind.
                button.getFocus().kind = .{ .custom = "submit" };
                button.getFocus().focusable = true;
                button_id = button.getFocus().id;
                try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = null });
            }

            box.getFocus().child_id = button_id;
            break :blk try ui.Center.init(allocator, .{ .box = box });
        };
        errdefer authorized.deinit(allocator);

        var unauthorized = try ui.Unauthorized.View.init(allocator);
        errdefer unauthorized.deinit(allocator);

        return .{
            .focus = try Focus.create(allocator, .container),
            .authorized = authorized,
            .unauthorized = unauthorized,
            .session = session,
            .button_id = button_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.focus.destroy(allocator);
        self.authorized.deinit(allocator);
        self.unauthorized.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // decided per-frame since the tty doesn't rebuild the page on login
        self.focus.clear();
        if (self.session.data.user_id != null) {
            const box = &self.authorized.child.box;
            const button = &box.children.values()[0].widget.text_box;
            button.box.children.values()[0].widget.text.content = ansiLabel(self.session);
            try self.authorized.build(allocator, constraint, root_focus);
            if (self.authorized.getGrid()) |inner_grid| {
                try self.focus.addChild(allocator, self.authorized.getFocus(), inner_grid.size, 0, 0);
            }
            self.focus.child_id = self.authorized.getFocus().id;
        } else {
            try self.unauthorized.build(allocator, constraint, root_focus);
            if (self.unauthorized.getGrid()) |inner_grid| {
                try self.focus.addChild(allocator, self.unauthorized.getFocus(), inner_grid.size, 0, 0);
            }
            self.focus.child_id = self.unauthorized.getFocus().id;
        }
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
        self.authorized.clearGrid();
        self.unauthorized.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        if (self.session.data.user_id != null) return self.authorized.getGrid();
        return self.unauthorized.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.focus;
    }

    pub fn getSelectedIndex(self: View) ?usize {
        _ = self;
        return 0;
    }
};

fn ansiLabel(session: *const ui.Session) []const u8 {
    const label_on = "turn off ANSI art";
    const label_off = "turn on ANSI art";
    return if (session.data.enable_ansi) label_on else label_off;
}

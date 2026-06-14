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

const label_on = "turn off ANSI art";
const label_off = "turn on ANSI art";

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.Center,
    data: *const Self,
    session: *ui.Session,
    button_id: usize,

    const button_index: usize = 0;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const logged_in = session.data.user_id != null;

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        // when logged in, the toggle posts to a page-scoped /ansi path so the
        // server sends us back to this page's settings tab; logged out, the
        // empty action blocks the POST and the input goes to the TUI instead.
        box.getFocus().kind = .{ .custom = if (!logged_in) "form:" else switch (session.data.current_page) {
            .user, .user_settings, .user_auth => |name| try std.fmt.allocPrint(session.page_arena.allocator(), "form:/user/{s}/ansi", .{name.slice()}),
            else => "form:/ansi",
        } };

        var button_id: usize = undefined;
        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, labelFor(session), .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
            button.getFocus().focusable = true;
            // the renderer distinguishes plain clickables from buttons that
            // should POST to a server route by this kind.
            button.getFocus().kind = .{ .custom = "submit" };
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
        const box = &self.center.child.box;
        if (box.children.values().len > 0) {
            const button = &box.children.values()[button_index].widget.text_box;
            button.box.children.values()[0].widget.text.content = labelFor(self.session);
        }
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        switch (key) {
            .enter => try self.toggle(),
            .mouse => |mouse| {
                if (mouse.action == .press and mouse.action.press == .left) {
                    if (root_focus.children.get(self.button_id)) |entry| {
                        const r = entry.rect;
                        if (mouse.x >= r.x and mouse.y >= r.y and
                            mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                        {
                            try self.toggle();
                        }
                    }
                }
            },
            else => {},
        }
    }

    // enqueue the toggle; the host drains it (applying + persisting) this frame.
    fn toggle(self: *View) !void {
        try self.session.push(.toggle_ansi);
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

fn labelFor(session: *const ui.Session) []const u8 {
    return if (session.data.enable_ansi) label_on else label_off;
}

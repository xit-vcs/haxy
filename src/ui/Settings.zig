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
    center: ui.Center,
    session: *ui.Session,
    button_id: usize,

    // the stack switches between two whole views; build() selects one based on
    // whether a user is logged in. the logged-in view holds the settings
    // controls (currently just the ANSI toggle, but it will grow).
    const logged_in_index: usize = 0;
    const logged_out_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session) !View {
        var stack = try wgt.Stack(ui.Widget).init(allocator);
        errdefer stack.deinit(allocator);

        var button_id: usize = undefined;
        // the logged-in view: the controls shown to a signed-in user.
        {
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
            try stack.children.put(allocator, box.getFocus().id, .{ .box = box });
        }

        // the logged-out view: shown when no user is signed in.
        {
            const logged_out_message =
                \\you must be logged in to see settings.
                \\
                \\here's an emoticon from the early 2000s instead:
                \\
                \\<('o'<) ^( '-' )^ (>'o')>
                \\
                \\hope it helps.
            ;

            var message = try wgt.TextBox(ui.Widget).init(allocator, logged_out_message, .{ .border_style = null, .rounded_corners = false, .wrap_kind = .word });
            errdefer message.deinit(allocator);
            try stack.children.put(allocator, message.getFocus().id, .{ .text_box = message });
        }

        return .{
            .center = try ui.Center.init(allocator, .{ .stack = stack }),
            .session = session,
            .button_id = button_id,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        // select the logged-in view when logged in, else the logged-out view.
        // decided per-frame since the tty doesn't rebuild the page on login.
        const logged_in = self.session.data.user_id != null;
        const stack = &self.center.child.stack;
        if (logged_in) {
            const box = &stack.children.values()[logged_in_index].box;
            const button = &box.children.values()[0].widget.text_box;
            button.box.children.values()[0].widget.text.content = ansiLabel(self.session);
        }
        stack.getFocus().child_id = stack.children.keys()[if (logged_in) logged_in_index else logged_out_index];
        try self.center.build(allocator, constraint, root_focus);
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

fn ansiLabel(session: *const ui.Session) []const u8 {
    const label_on = "turn off ANSI art";
    const label_off = "turn on ANSI art";
    return if (session.data.enable_ansi) label_on else label_off;
}

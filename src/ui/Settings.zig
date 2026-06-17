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

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.Center,
    data: *const Self,
    session: *ui.Session,
    button_id: usize,

    // the box holds the toggle button and the logged-out message; build() shows
    // exactly one of them based on whether a user is logged in.
    const button_index: usize = 0;
    const message_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        // on the web the toggle is an overlay form posting to a page-scoped /ansi
        // path; only mark it a form when logged in so a logged-out page stays
        // blank (the web rebuilds per request, so this is correct there; the tty
        // ignores the form kind and toggles in-process via input).
        if (session.data.user_id != null) {
            box.getFocus().kind = .{ .custom = switch (session.data.current_page) {
                .user, .user_settings, .user_auth => |name| try std.fmt.allocPrint(session.page_arena.allocator(), "form:/user/{s}/ansi", .{name.slice()}),
                else => "form:/ansi",
            } };
        }

        var button_id: usize = undefined;
        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, ansiLabel(session), .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
            errdefer button.deinit(allocator);
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

        // the logged-out message (shown in place of the toggle)
        {
            const logged_out_message =
                \\you must be logged in to see settings :(
                \\
                \\instead, here's an emoticon from the early 2000s:
                \\<('o'<) ^( '-' )^ (>'o')>
                \\
                \\hope it helps.
            ;

            var message = try wgt.TextBox(ui.Widget).init(allocator, logged_out_message, .{ .border_style = null, .rounded_corners = false, .wrap_kind = .word });
            errdefer message.deinit(allocator);
            try box.children.put(allocator, message.getFocus().id, .{
                .widget = .{ .text_box = message },
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
        // show the toggle when logged in, else the message. decided per-frame
        // since the tty doesn't rebuild the page on login. a zero max height
        // hides the inactive one (it builds to nothing).
        const logged_in = self.session.data.user_id != null;
        const box = &self.center.child.box;
        const button = &box.children.values()[button_index].widget.text_box;
        if (logged_in) button.box.children.values()[0].widget.text.content = ansiLabel(self.session);
        button.getFocus().focusable = logged_in;
        const hidden = layout.MaybeSize{ .width = null, .height = 0 };
        box.children.values()[button_index].max_size = if (logged_in) null else hidden;
        box.children.values()[message_index].max_size = if (logged_in) hidden else null;
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        _ = allocator;
        if (self.session.data.user_id == null) return; // blank/disabled when logged out
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

fn ansiLabel(session: *const ui.Session) []const u8 {
    const label_on = "turn off ANSI art";
    const label_off = "turn on ANSI art";
    return if (session.data.enable_ansi) label_on else label_off;
}

const std = @import("std");
const ui = @import("../../ui.zig");
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
    // focus id of the header's "users" tab; on logout we jump there so the
    // user isn't stranded on a button that's about to be hidden.
    users_tab_id: usize,

    const prompt_index: usize = 0;
    const button_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, users_tab_id: usize) !View {
        var box = wgt.Box(ui.Widget).init(.{ .border_style = null, .rounded_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);
        // marks this subtree as an HTML form scope for the web overlay
        box.getFocus().kind = .{ .custom = switch (session.data.current_page) {
            .user, .user_settings, .user_auth => |name| try std.fmt.allocPrint(session.page_arena.allocator(), "form:/user/{s}/logout", .{name.slice()}),
            else => "form:/logout",
        } };

        {
            var prompt = wgt.Text(ui.Widget).init("are you sure?");
            errdefer prompt.deinit(allocator);
            try box.children.put(allocator, prompt.getFocus().id, .{
                .widget = .{ .text = prompt },
                .rect = null,
                .min_size = null,
            });
        }

        var button_id: usize = undefined;
        {
            var button = try wgt.TextBox(ui.Widget).init(allocator, "logout", .{ .border_style = .single, .rounded_corners = true, .wrap_kind = .none });
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
            .users_tab_id = users_tab_id,
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
                try self.logout(root_focus);
                return;
            },
            .mouse => |mouse| {
                if (mouse.action == .press and mouse.action.press == .left) {
                    if (root_focus.children.get(self.button_id)) |entry| {
                        const r = entry.rect;
                        if (mouse.x >= r.x and mouse.y >= r.y and
                            mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                        {
                            try self.logout(root_focus);
                            return;
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn logout(self: *View, root_focus: *Focus) !void {
        self.session.data.user_id = null;
        // jump focus back to the users tab — the logout button is about to
        // be hidden by the tab-label swap.
        try root_focus.setFocus(self.users_tab_id);
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

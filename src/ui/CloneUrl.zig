const std = @import("std");
const ui = @import("../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("input.zig");

pub const View = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    urls: [2][]const u8,
    selected: usize = 0,

    const http_index: usize = 0;
    const ssh_index: usize = 1;
    const input_index: usize = 2;

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8) !View {
        const http_port = session.data.clone_http_port orelse return error.MissingClonePort;
        const ssh_port = session.data.clone_ssh_port orelse return error.MissingClonePort;
        const aa = session.page_arena.allocator();
        const urls = [2][]const u8{
            try std.fmt.allocPrint(aa, "http://localhost:{d}/repo/{s}", .{ http_port, identity }),
            try std.fmt.allocPrint(aa, "ssh://localhost:{d}/repo/{s}", .{ ssh_port, identity }),
        };

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = "form:" };

        inline for ([_][]const u8{ "http", "ssh" }) |protocol| {
            var label = try wgt.TextBox(ui.Widget).init(allocator, protocol, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer label.deinit(allocator);
            label.getFocus().focusable = true;
            try box.children.put(allocator, label.getFocus().id, .{ .widget = .{ .text_box = label }, .rect = null, .min_size = .{ .width = protocol.len + 2, .height = 3 } });
        }

        var url_input = try wgt.TextInput(ui.Widget).init(allocator, .{
            .border_style = .single,
            .label = " clone ",
            .render_content = session.is_terminal,
            .visible_width = @max(urls[0].len, urls[1].len),
        });
        errdefer url_input.deinit(allocator);
        url_input.getFocus().focusable = true;
        try url_input.setContent(allocator, urls[0]);
        box.getFocus().child_id = url_input.getFocus().id;
        try box.children.put(allocator, url_input.getFocus().id, .{ .widget = .{ .text_input = url_input }, .rect = null, .min_size = .{ .width = @max(urls[0].len, urls[1].len) + 2, .height = 3 } });

        return .{ .box = box, .session = session, .urls = urls };
    }

    pub fn minWidth(self: *const View) usize {
        return "http".len + "ssh".len + 4 + @max(self.urls[0].len, self.urls[1].len) + 2;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        if (root_focus.grandchild_id) |id| {
            const clicked = if (id == self.protocolLabel(http_index).getFocus().id)
                http_index
            else if (id == self.protocolLabel(ssh_index).getFocus().id)
                ssh_index
            else
                null;
            if (clicked) |selected| {
                if (selected != self.selected) {
                    self.selected = selected;
                    try self.urlInput().setContent(allocator, self.urls[selected]);
                }
                root_focus.setFocus(self.urlInput().getFocus().id);
            }
        }

        const focused = root_focus.grandchild_id == self.urlInput().getFocus().id;
        for (0..2) |i| {
            self.protocolLabel(i).options.border_style = if (i == self.selected)
                (if (focused) .double else .single)
            else
                .hidden;
        }
        self.urlInput().options.border_style = .single;
        self.urlInput().cursor = 0;
        self.urlInput().scroll_offset = 0;
        try self.box.build(allocator, constraint, root_focus);

        if (!self.session.is_terminal) {
            const aa = self.session.arena.allocator();
            const id = self.urlInput().getFocus().id;
            try self.session.text_inputs.put(aa, id, self.urlInput());
            try self.session.input_values.put(aa, id, self.urls[self.selected]);
        }
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const next = switch (key) {
            .arrow_left => if (self.selected == ssh_index) http_index else return,
            .arrow_right => if (self.selected == http_index) ssh_index else return,
            .enter => {
                if (self.session.is_terminal) self.session.host_request = .{ .clone_url = self.urls[self.selected] };
                return;
            },
            .mouse => |mouse| if (inp.leftClickOn(root_focus, self.protocolLabel(http_index).getFocus().id, mouse))
                http_index
            else if (inp.leftClickOn(root_focus, self.protocolLabel(ssh_index).getFocus().id, mouse))
                ssh_index
            else if (inp.leftClickOn(root_focus, self.urlInput().getFocus().id, mouse)) {
                if (self.session.is_terminal) self.session.host_request = .{ .clone_url = self.urls[self.selected] };
                return;
            } else return,
            else => return,
        };
        self.selected = next;
        try self.urlInput().setContent(allocator, self.urls[next]);
    }

    fn urlInput(self: *View) *wgt.TextInput(ui.Widget) {
        return &self.box.children.values()[input_index].widget.text_input;
    }

    fn protocolLabel(self: *View, index: usize) *wgt.TextBox(ui.Widget) {
        return &self.box.children.values()[index].widget.text_box;
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }
};

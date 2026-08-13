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
    protocols: [2]Protocol,
    protocol_count: usize,
    selected: usize = 0,

    const Protocol = struct {
        name: []const u8,
        url: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8) !View {
        const aa = session.page_arena.allocator();
        var protocols: [2]Protocol = undefined;
        var protocol_count: usize = 0;
        if (session.data.clone_http_port) |port| {
            protocols[protocol_count] = .{
                .name = "http",
                .url = try std.fmt.allocPrint(aa, "http://localhost:{d}/repo/{s}", .{ port, identity }),
            };
            protocol_count += 1;
        }
        if (session.data.clone_ssh_port) |port| {
            protocols[protocol_count] = .{
                .name = "ssh",
                .url = try std.fmt.allocPrint(aa, "ssh://localhost:{d}/repo/{s}", .{ port, identity }),
            };
            protocol_count += 1;
        }
        if (protocol_count == 0) return error.MissingClonePort;

        var max_url_len: usize = 0;
        for (protocols[0..protocol_count]) |protocol| max_url_len = @max(max_url_len, protocol.url.len);

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = "form:" };

        for (protocols[0..protocol_count]) |protocol| {
            var label = try wgt.TextBox(ui.Widget).init(allocator, protocol.name, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer label.deinit(allocator);
            label.getFocus().focusable = true;
            try box.children.put(allocator, label.getFocus().id, .{ .widget = .{ .text_box = label }, .rect = null, .min_size = .{ .width = protocol.name.len + 2, .height = 3 } });
        }

        var url_input = try wgt.TextInput(ui.Widget).init(allocator, .{
            .border_style = .single,
            .label = " clone ",
            .render_content = session.is_terminal,
            .visible_width = max_url_len,
        });
        errdefer url_input.deinit(allocator);
        url_input.getFocus().focusable = true;
        try url_input.setContent(allocator, protocols[0].url);
        box.getFocus().child_id = url_input.getFocus().id;
        try box.children.put(allocator, url_input.getFocus().id, .{ .widget = .{ .text_input = url_input }, .rect = null, .min_size = .{ .width = max_url_len + 2, .height = 3 } });

        return .{ .box = box, .session = session, .protocols = protocols, .protocol_count = protocol_count };
    }

    pub fn minWidth(self: *const View) usize {
        var width: usize = 0;
        var max_url_len: usize = 0;
        for (self.protocols[0..self.protocol_count]) |protocol| {
            width += protocol.name.len + 2;
            max_url_len = @max(max_url_len, protocol.url.len);
        }
        return width + max_url_len + 2;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        if (root_focus.grandchild_id) |id| {
            var clicked: ?usize = null;
            for (0..self.protocol_count) |i| {
                if (id == self.protocolLabel(i).getFocus().id) clicked = i;
            }
            if (clicked) |selected| {
                if (selected != self.selected) {
                    self.selected = selected;
                    try self.urlInput().setContent(allocator, self.protocols[selected].url);
                }
                root_focus.setFocus(self.urlInput().getFocus().id);
            }
        }

        const focused = root_focus.grandchild_id == self.urlInput().getFocus().id;
        for (0..self.protocol_count) |i| {
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
            try self.session.input_values.put(aa, id, self.protocols[self.selected].url);
        }
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const next = switch (key) {
            .arrow_left => if (self.selected > 0) self.selected - 1 else return,
            .arrow_right => if (self.selected + 1 < self.protocol_count) self.selected + 1 else return,
            .enter => {
                if (self.session.is_terminal) self.session.host_request = .{ .show_url = self.protocols[self.selected].url };
                return;
            },
            .mouse => |mouse| blk: {
                for (0..self.protocol_count) |i| {
                    if (inp.leftClickOn(root_focus, self.protocolLabel(i).getFocus().id, mouse)) break :blk i;
                }
                if (self.session.is_terminal and !mouse.ctrl and inp.leftClickOn(root_focus, self.urlInput().getFocus().id, mouse))
                    self.session.host_request = .{ .show_url = self.protocols[self.selected].url };
                return;
            },
            else => return,
        };
        self.selected = next;
        try self.urlInput().setContent(allocator, self.protocols[next].url);
    }

    fn urlInput(self: *View) *wgt.TextInput(ui.Widget) {
        return &self.box.children.values()[self.protocol_count].widget.text_input;
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

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

pub const Choice = struct {
    selector: []const u8 = "",
    text: []const u8,
    copyable_text: ?[]const u8 = null,
    label: []const u8 = "",
    bottom_label: []const u8 = "",
};

pub const View = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    choices: []Choice,
    selected: usize = 0,

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, choices: []const Choice) !View {
        if (choices.len == 0) return error.MissingCopyableText;

        const owned_choices = try allocator.dupe(Choice, choices);
        errdefer allocator.free(owned_choices);

        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit(allocator);

        if (choices.len > 1) for (choices) |choice| {
            var selector_box = try wgt.TextBox(ui.Widget).init(allocator, choice.selector, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer selector_box.deinit(allocator);
            selector_box.getFocus().focusable = true;
            try box.children.put(allocator, selector_box.getFocus().id, .{ .widget = .{ .text_box = selector_box }, .rect = null, .min_size = .{ .width = choice.selector.len + 2, .height = 3 } });
        };

        var text_input = try wgt.TextInput(ui.Widget).init(allocator, .{
            .border_style = .single,
            .label = choices[0].label,
            .bottom_label = choices[0].bottom_label,
            .read_only = true,
            .render_content = session.is_terminal,
            .visible_width = null,
        });
        errdefer text_input.deinit(allocator);
        text_input.getFocus().focusable = true;
        try text_input.setContent(allocator, choices[0].text);
        box.getFocus().child_id = text_input.getFocus().id;
        try box.children.put(allocator, text_input.getFocus().id, .{ .widget = .{ .text_input = text_input }, .rect = null, .min_size = null, .flex = .shrink });

        return .{ .box = box, .session = session, .choices = owned_choices };
    }

    pub fn initClone(allocator: std.mem.Allocator, session: *ui.Session, identity: []const u8) !View {
        const aa = session.page_arena.allocator();
        var choices: [2]Choice = undefined;
        var count: usize = 0;
        if (session.data.git_http_port) |port| {
            const url = try std.fmt.allocPrint(aa, "http://localhost:{d}/repo/{s}", .{ port, identity });
            choices[count] = .{
                .selector = "http",
                .text = url,
                .copyable_text = try std.fmt.allocPrint(aa, "git clone {s}", .{url}),
                .label = " clone ",
            };
            count += 1;
        }
        if (session.data.git_ssh_port) |port| {
            const url = try std.fmt.allocPrint(aa, "ssh://localhost:{d}/repo/{s}", .{ port, identity });
            choices[count] = .{
                .selector = "ssh",
                .text = url,
                .copyable_text = try std.fmt.allocPrint(aa, "{s}git clone {s}", .{ session.data.git_ssh_prefix, url }),
                .label = " clone ",
            };
            count += 1;
        }
        if (count == 0) return error.MissingGitPort;
        return init(allocator, session, choices[0..count]);
    }

    pub fn minWidth(self: *const View) usize {
        var width = maxWidth(self.choices) + 2;
        if (self.choices.len > 1) {
            for (self.choices) |choice| width += choice.selector.len + 2;
        }
        return width;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
        allocator.free(self.choices);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();

        if (self.choices.len > 1) {
            if (root_focus.grandchild_id) |id| {
                for (0..self.choices.len) |i| {
                    if (id != self.selector(i).getFocus().id) continue;
                    if (i != self.selected) try self.select(allocator, i);
                    root_focus.setFocus(self.textInput().getFocus().id);
                    break;
                }
            }

            const focused = root_focus.grandchild_id == self.textInput().getFocus().id;
            for (0..self.choices.len) |i| {
                self.selector(i).options.border_style = if (i == self.selected)
                    (if (focused) .double else .single)
                else
                    .hidden;
            }
        }
        self.textInput().options.border_style = .single;
        self.textInput().cursor = 0;
        self.textInput().scroll_offset = 0;
        try self.box.build(allocator, constraint, root_focus);

        if (!self.session.is_terminal) {
            const aa = self.session.arena.allocator();
            const id = self.textInput().getFocus().id;
            try self.session.text_inputs.put(aa, id, self.textInput());
            try self.session.input_values.put(aa, id, self.choices[self.selected].text);
        }
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        switch (key) {
            .arrow_left => if (self.selected > 0) try self.select(allocator, self.selected - 1),
            .arrow_right => if (self.selected + 1 < self.choices.len) try self.select(allocator, self.selected + 1),
            .enter => if (self.session.is_terminal) self.show(),
            .mouse => |mouse| {
                if (self.choices.len > 1) for (0..self.choices.len) |i| {
                    if (!inp.leftClickOn(root_focus, self.selector(i).getFocus().id, mouse)) continue;
                    try self.select(allocator, i);
                    root_focus.setFocus(self.textInput().getFocus().id);
                    return;
                };
                if (self.session.is_terminal and !mouse.ctrl and inp.leftClickOn(root_focus, self.textInput().getFocus().id, mouse)) self.show();
            },
            else => {},
        }
    }

    fn select(self: *View, allocator: std.mem.Allocator, selected: usize) !void {
        self.selected = selected;
        const choice = self.choices[selected];
        const text_input = self.textInput();
        text_input.options.label = choice.label;
        text_input.options.bottom_label = choice.bottom_label;
        try text_input.setContent(allocator, choice.text);
    }

    fn show(self: *View) void {
        const choice = self.choices[self.selected];
        self.session.host_request = .{ .show_copyable_text = choice.copyable_text orelse choice.text };
    }

    fn textInput(self: *View) *wgt.TextInput(ui.Widget) {
        return &self.box.children.values()[if (self.choices.len > 1) self.choices.len else 0].widget.text_input;
    }

    fn selector(self: *View, index: usize) *wgt.TextBox(ui.Widget) {
        return &self.box.children.values()[index].widget.text_box;
    }

    fn maxWidth(choices: []const Choice) usize {
        var width: usize = 0;
        for (choices) |choice| width = @max(width, choice.text.len, choice.label.len, choice.bottom_label.len);
        return width;
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

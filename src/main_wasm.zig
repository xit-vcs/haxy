const std = @import("std");
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const inp = xitui.input;
const wgt = xitui.widget;

const allocator = std.heap.wasm_allocator;

var root: ?ui.Widget = null;

fn updateHtml() !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    const html = try web.generateHtml(allocator, root_ptr, &session);
    defer allocator.free(html);
    setHtml(html);
}

// the snapshot is allocated into this arena via parseFromSliceLeaky. it
// has to outlive `root`, because `root` holds slices into the parsed strings.
var page_arena: ?std.heap.ArenaAllocator = null;
var snapshot: ?ui.Snapshot = null;
var session: ui.Session = .{};

fn start(json: []const u8, min_height: u32, max_width: u32) !void {
    if (page_arena) |*a| a.deinit();
    page_arena = std.heap.ArenaAllocator.init(allocator);

    // alloc_always so the parsed strings live entirely inside the arena
    // and don't borrow from the caller's json buffer.
    snapshot = try std.json.parseFromSliceLeaky(ui.Snapshot, (page_arena orelse unreachable).allocator(), json, .{
        .allocate = .alloc_always,
    });

    // adopt the server's session view wholesale — one assignment instead of
    // hand-restoring each field by reaching into the page's data tree.
    session.data = (snapshot orelse unreachable).session;

    var next_root = try ui.initRoot(allocator, &(snapshot orelse unreachable).page, &session);
    errdefer next_root.deinit(allocator);

    if (root) |*old_root| old_root.deinit(allocator);
    root = next_root;

    try tick(min_height, max_width);
}

fn tick(min_height: u32, max_width: u32) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    try root_ptr.build(allocator, .{
        // min_height lets the TUI fill the viewport when its content is
        // short; max height stays null so taller content extends downward
        // and the browser scrolls.
        .min_size = .{ .width = null, .height = min_height },
        .max_size = .{ .width = max_width, .height = null },
    }, root_ptr.getFocus());
    try updateHtml();
}

fn onKeyDown(key_code: u32) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    const key: inp.Key = switch (key_code) {
        13 => .enter,
        33 => .page_up,
        34 => .page_down,
        35 => .end,
        36 => .home,
        37 => .arrow_left,
        38 => .arrow_up,
        39 => .arrow_right,
        40 => .arrow_down,
        else => return,
    };
    try root_ptr.input(allocator, key, root_ptr.getFocus());
}

fn onMouseClick(focus_id: usize) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    try root_ptr.getFocus().setFocus(focus_id);
}

fn consoleLog(arg: []const u8) void {
    _consoleLog(arg.ptr, @intCast(arg.len));
}

fn setHtml(arg: []const u8) void {
    _setHtml(arg.ptr, @intCast(arg.len));
}

extern fn _consoleLog(arg: [*]const u8, len: u32) void;
extern fn _setHtml(arg: [*]const u8, len: u32) void;

/// js calls this first to get a wasm pointer it can write the page json into.
export fn _alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn _start(json_ptr: [*]u8, json_len: u32, min_height: u32, max_width: u32) void {
    const json = json_ptr[0..json_len];
    defer allocator.free(json);
    start(json, min_height, max_width) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "start: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

export fn _tick(min_height: u32, max_width: u32) bool {
    tick(min_height, max_width) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "tick: {}", .{err}) catch unreachable;
        consoleLog(str);
        return false;
    };
    return true;
}

export fn _onKeyDown(key_code: u32) void {
    onKeyDown(key_code) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "onKeyDown: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

export fn _onMouseClick(focus_id: u32) void {
    onMouseClick(focus_id) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "onMouseClick: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

// js calls this when the value of an overlay <input> changes; we replace
// the matching TextInput's content with the supplied utf-8 bytes.
export fn _setTextInputValue(focus_id: u32, value_ptr: [*]const u8, value_len: u32) void {
    setTextInputValue(focus_id, value_ptr[0..value_len]) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "setTextInputValue: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

fn setTextInputValue(focus_id: u32, bytes: []const u8) !void {
    const root_ptr = if (root) |*r| r else return error.NotStarted;
    const root_focus = root_ptr.getFocus();
    const child = root_focus.children.get(focus_id) orelse return error.UnknownFocusId;
    switch (child.focus.kind) {
        .text_input, .text_input_password => {},
        else => return error.NotATextInput,
    }
    const ti: *wgt.TextInput(ui.Widget) = @fieldParentPtr("focus", child.focus);
    try ti.setContent(allocator, bytes);
    // mirror the TTY behavior in Login.View.input: editing an input clears
    // the stale failure flag so the "(invalid)" label doesn't linger after
    // the user has typed a correction
    session.data.login_failure = null;
}

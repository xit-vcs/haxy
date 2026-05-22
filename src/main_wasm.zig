const std = @import("std");
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const xitui = @import("xit").xitui;
const inp = xitui.input;

const allocator = std.heap.wasm_allocator;

var root: ?ui.Widget = null;

fn updateHtml() !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    const html = try web.generateHtml(allocator, root_ptr);
    defer allocator.free(html);
    setHtml(html);
}

// the page is allocated into this arena via parseFromSliceLeaky. it has
// to outlive `root`, because `root` holds slices into the parsed strings.
var page_arena: ?std.heap.ArenaAllocator = null;
var page: ?ui.Page = null;

fn start(json: []const u8, max_width: u32) !void {
    if (page_arena) |*a| a.deinit();
    page_arena = std.heap.ArenaAllocator.init(allocator);

    // alloc_always so the parsed strings live entirely inside the arena
    // and don't borrow from the caller's json buffer.
    page = try std.json.parseFromSliceLeaky(ui.Page, (page_arena orelse unreachable).allocator(), json, .{
        .allocate = .alloc_always,
    });

    var next_root = try ui.initRoot(allocator, &(page orelse unreachable));
    errdefer next_root.deinit();

    if (root) |*old_root| old_root.deinit();
    root = next_root;

    try tick(max_width);
}

fn tick(max_width: u32) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    try root_ptr.build(.{
        .min_size = .{ .width = null, .height = null },
        // height is null so the TUI grows to fit all its content; the browser
        // page handles vertical scrolling.
        .max_size = .{ .width = max_width, .height = null },
    }, root_ptr.getFocus());
    try updateHtml();
}

fn onKeyDown(key_code: u32) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    const key: inp.Key = switch (key_code) {
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
    try root_ptr.input(key, root_ptr.getFocus());
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

export fn _start(json_ptr: [*]u8, json_len: u32, max_width: u32) void {
    const json = json_ptr[0..json_len];
    defer allocator.free(json);
    start(json, max_width) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "start: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

export fn _tick(max_width: u32) bool {
    tick(max_width) catch |err| {
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

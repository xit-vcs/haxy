const std = @import("std");
const ui = @import("./ui.zig");
const pg = @import("./page.zig");
const xitui = @import("xit").xitui;
const inp = xitui.input;

const allocator = std.heap.wasm_allocator;

var root: ?ui.Widget = null;

fn updateHtml() !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    const html = try ui.generateHtml(allocator, root_ptr);
    defer allocator.free(html);
    setHtml(html);
}

// TODO: receive the Page as json from the host and parse it back into
// a Page so initRoot can render real data. for now we initialize with
// an empty page just so the wasm build compiles.
var page_maybe: ?pg.Page = null;

fn start() !void {
    const page = page_maybe orelse pg.Page{ .user_repo = pg.UserRepoPage.empty() };

    var next_root = try ui.initRoot(allocator, &page);
    errdefer next_root.deinit();

    if (root) |*old_root| old_root.deinit();
    root = next_root;

    try updateHtml();
}

fn tick() !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    // TODO: make this fit the current size of the browser window
    try root_ptr.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 80, .height = 24 },
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
        38 => .arrow_up,
        40 => .arrow_down,
        else => return,
    };
    try root_ptr.input(key, root_ptr.getFocus());
}

fn consoleLog(arg: []const u8) void {
    _consoleLog(arg.ptr, @intCast(arg.len));
}

fn setHtml(arg: []const u8) void {
    _setHtml(arg.ptr, @intCast(arg.len));
}

extern fn _consoleLog(arg: [*]const u8, len: u32) void;
extern fn _setHtml(arg: [*]const u8, len: u32) void;

export fn _start() void {
    start() catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "start: {}", .{err}) catch unreachable;
        consoleLog(str);
    };
}

export fn _tick() bool {
    tick() catch |err| {
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

const std = @import("std");
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const inp = xitui.input;
const wgt = xitui.widget;

const allocator = std.heap.wasm_allocator;

var root: ?ui.Widget = null;
var page_arena = std.heap.ArenaAllocator.init(allocator);
var snapshot: ui.Snapshot = undefined;
var session: ui.Session = undefined;
var last_pushed_page_maybe: ?ui.RoutablePage = null; // last current_page we told JS about
var last_scrolled_focus_id: ?usize = null; // last focused widget we asked JS to scroll into view

fn init(json: []const u8, min_height: u32, max_width: u32) !void {
    _ = page_arena.reset(.free_all);
    // drop the last-pushed page so the next tick pushes the freshly-loaded
    // page's url.
    last_pushed_page_maybe = null;

    // alloc_always so the parsed strings live entirely inside the arena
    // and don't borrow from the caller's json buffer.
    snapshot = try std.json.parseFromSliceLeaky(ui.Snapshot, page_arena.allocator(), json, .{
        .allocate = .alloc_always,
    });

    // adopt the server's session view wholesale — one assignment instead of
    // hand-restoring each field by reaching into the page's data tree.
    session = .{
        .data = snapshot.session,
        .arena = &page_arena,
        // one render per page load (init resets the arena), so page-scoped and
        // session-scoped allocations share the same arena here.
        .page_arena = &page_arena,
    };

    var next_root = try ui.initRoot(allocator, &snapshot.page, &session);
    errdefer next_root.deinit(allocator);

    if (root) |*old_root| old_root.deinit(allocator);
    root = next_root;

    try tick(min_height, max_width);
}

fn tick(min_height: u32, max_width: u32) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;

    // apply actions queued during input. the wasm path has no repo, so this is
    // in-memory only; logged-in web persistence goes through the /ansi POST.
    session.applyPending();

    try root_ptr.build(allocator, .{
        // bind the UI to the browser viewport (cols x rows) like the terminal:
        // min == max height fills it exactly, and each Scroll clips to its
        // viewport while handing its full content to a native-scrollable element.
        .min_size = .{ .width = null, .height = min_height },
        .max_size = .{ .width = max_width, .height = min_height },
    }, root_ptr.getFocus());

    // mirror the page Header settled on into the browser URL. these are
    // passive same-page changes, like moving down the commits list, so we
    // replace the URL in place rather than pushing a history entry. real
    // cross-page navigations go through _navigate.
    const current_page = session.data.current_page;
    const should_push = if (last_pushed_page_maybe) |lp| !lp.eql(current_page) else true;
    if (should_push) {
        last_pushed_page_maybe = current_page;
        const url = try current_page.urlAlloc(&page_arena);
        _replaceState(url.ptr, @intCast(url.len));
    }

    const html = try web.generateHtml(allocator, root_ptr);
    defer allocator.free(html);
    setHtml(html);

    // emit the overlay (form + inputs + button) on every tick so the wasm
    // layout drives positions, not just the server's initial render. JS
    // diffs the result against the previous overlay; an unchanged overlay
    // leaves the live <form> alone — crucial since wiping it mid-click
    // would detach the submit button before the browser can dispatch the
    // form submission.
    const overlay = try web.generateOverlay(allocator, root_ptr, &session);
    defer allocator.free(overlay);
    setOverlay(overlay);

    const root_focus = root_ptr.getFocus();
    if (root_focus.grandchild_id) |gid| {
        if (root_focus.children.get(gid)) |child| {
            // browser-focus the focused overlay control (text input or submit button)
            // so the browser handles typing and Enter-to-submit natively. without this
            // the submit button never gets focus and Enter falls through to the wasm.
            switch (child.focus.kind) {
                .text_input, .text_input_password => _focusInput(@intCast(gid)),
                .custom => |custom| if (std.mem.eql(u8, custom, "submit")) _focusInput(@intCast(gid)),
                else => {},
            }

            // keep the focused widget visible within its own scrollable element.
            // only fire on an actual focus change so we don't fight the user's
            // manual scrolling on unrelated ticks.
            if (gid != last_scrolled_focus_id) {
                last_scrolled_focus_id = gid;
                _scrollToFocus(@intCast(gid));
            }
        }
    }
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

    if (key == .enter) {
        if (root_ptr.getFocus().grandchild_id) |gid| {
            // follow a cross-page link
            if (ui.crossPageLink(root_ptr.getFocus(), gid, session.data.current_page)) |route| {
                const url = try route.urlAlloc(&page_arena);
                navigate(url);
                return;
            }
        }
    }

    try root_ptr.input(allocator, key, root_ptr.getFocus());
}

fn onMouseClick(focus_id: usize) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    // follow a cross-page link
    if (ui.crossPageLink(root_ptr.getFocus(), focus_id, session.data.current_page)) |route| {
        const url = try route.urlAlloc(&page_arena);
        navigate(url);
        return;
    }
    try root_ptr.getFocus().setFocus(focus_id);
}

fn setFocus(focus_id: usize) !void {
    const root_ptr = if (root) |*root_value| root_value else return error.NotStarted;
    try root_ptr.getFocus().setFocus(focus_id);
}

fn consoleLog(arg: []const u8) void {
    _consoleLog(arg.ptr, @intCast(arg.len));
}

fn setHtml(arg: []const u8) void {
    _setHtml(arg.ptr, @intCast(arg.len));
}

fn setOverlay(arg: []const u8) void {
    _setOverlay(arg.ptr, @intCast(arg.len));
}

fn navigate(arg: []const u8) void {
    _navigate(arg.ptr, @intCast(arg.len));
}

extern fn _consoleLog(arg: [*]const u8, len: u32) void;
extern fn _setHtml(arg: [*]const u8, len: u32) void;
extern fn _setOverlay(arg: [*]const u8, len: u32) void;
extern fn _replaceState(arg: [*]const u8, len: u32) void;
extern fn _focusInput(focus_id: u32) void;
extern fn _navigate(arg: [*]const u8, len: u32) void;
extern fn _scrollToFocus(focus_id: u32) void;

/// js calls this first to get a wasm pointer it can write the page json into.
export fn _alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn _init(json_ptr: [*]u8, json_len: u32, min_height: u32, max_width: u32) void {
    const json = json_ptr[0..json_len];
    defer allocator.free(json);
    init(json, min_height, max_width) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "init: {}", .{err}) catch unreachable;
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

export fn _setFocus(focus_id: u32) void {
    setFocus(focus_id) catch |err| {
        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "setFocus: {}", .{err}) catch unreachable;
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
    const ti = session.text_inputs.get(focus_id) orelse return error.UnknownFocusId;
    try ti.setContent(allocator, bytes);
    // mirror the TTY behavior in Login.View.input: editing an input clears
    // the stale failure flag so the "(invalid)" label doesn't linger after
    // the user has typed a correction
    session.data.login_failure = null;
}

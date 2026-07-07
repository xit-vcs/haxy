const xit = @import("xit");
const xitui = xit.xitui;
const Key = xitui.input.Key;
const Mouse = xitui.input.Mouse;
const Focus = xitui.focus.Focus;

/// the vertical direction of a navigation key press, including mouse scroll
pub const Direction = enum { up, down, none };

pub fn vertDirection(key: Key) Direction {
    return switch (key) {
        .arrow_up => .up,
        .arrow_down => .down,
        .mouse => |mouse| if (mouse.action == .scroll)
            (if (mouse.action.scroll == .up) .up else .down)
        else
            .none,
        else => .none,
    };
}

/// how many rows a navigation key press moves the selection (negative is up),
/// or null if the key doesn't move the selection. `count` is the row count,
/// so home/end jump past either end and get clamped by the caller.
pub fn rowDelta(key: Key, count: isize) ?isize {
    switch (key) {
        .arrow_up => return -1,
        .arrow_down => return 1,
        .page_up => return -10,
        .page_down => return 10,
        .home => return -count,
        .end => return count,
        .mouse => |mouse| switch (mouse.action) {
            .scroll => |dir| return if (dir == .up) -1 else 1,
            else => {},
        },
        else => {},
    }
    return null;
}

/// whether `mouse` is a left press inside the rect of `focus_id`'s focus entry
pub fn leftClickOn(root_focus: *Focus, focus_id: usize, mouse: Mouse) bool {
    if (mouse.action != .press or mouse.action.press != .left) return false;
    const entry = root_focus.children.get(focus_id) orelse return false;
    const r = entry.rect;
    return mouse.x >= r.x and mouse.y >= r.y and
        mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height;
}

/// the tab index after a left/right arrow press, clamped to the ends,
/// or null when the key doesn't move the selection
pub fn moveTab(key: Key, current_tab: usize, tab_count: usize) ?usize {
    var new_tab = current_tab;
    switch (key) {
        .arrow_left => new_tab -|= 1,
        .arrow_right => if (new_tab + 1 < tab_count) {
            new_tab += 1;
        },
        else => {},
    }
    return if (new_tab != current_tab) new_tab else null;
}
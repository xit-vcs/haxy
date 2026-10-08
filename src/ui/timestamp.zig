const std = @import("std");

pub const Text = struct {
    relative: []const u8,
    exact: []const u8,
};

pub fn format(aa: std.mem.Allocator, timestamp: i64, now: i64) !Text {
    if (timestamp < 0) return .{ .relative = "timestamp unavailable", .exact = "" };
    return .{ .relative = try relative(aa, timestamp, now), .exact = try exact(aa, @intCast(timestamp)) };
}

// show only the largest whole unit; months and years use fixed durations.
fn relative(aa: std.mem.Allocator, timestamp: i64, now: i64) ![]const u8 {
    const future = timestamp > now;
    const elapsed = @abs(@as(i128, now) - timestamp);
    if (elapsed == 0) return "just now";
    const units = [_]struct { seconds: u64, name: []const u8 }{
        .{ .seconds = 365 * std.time.s_per_day, .name = "year" },
        .{ .seconds = 30 * std.time.s_per_day, .name = "month" },
        .{ .seconds = std.time.s_per_day, .name = "day" },
        .{ .seconds = std.time.s_per_hour, .name = "hour" },
        .{ .seconds = std.time.s_per_min, .name = "minute" },
        .{ .seconds = 1, .name = "second" },
    };
    for (units) |unit| {
        if (elapsed < unit.seconds) continue;
        const count = elapsed / unit.seconds;
        return aa.print("{s}{d} {s}{s}{s}", .{ if (future) "in " else "", count, unit.name, if (count == 1) "" else "s", if (future) "" else " ago" });
    }
    unreachable;
}

// compact utc, including seconds; z is the utc designator.
fn exact(aa: std.mem.Allocator, timestamp: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    return aa.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{ year.year, month.month.numeric(), month.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

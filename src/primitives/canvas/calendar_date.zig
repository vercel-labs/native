//! The calendar's civil-date value: a proleptic-Gregorian year/month/day
//! with the arithmetic the `calendar` component needs — weekday of a day,
//! days in a month, month stepping, and the 42-cell month grid — plus the
//! `YYYY-MM-DD` parse/format the markup element speaks. Deliberately small
//! and dependency-free (no clock: a calendar is a controlled component, so
//! the app supplies the shown month and "today"), which keeps every
//! rendering deterministic for the reference renderer.

const std = @import("std");

/// A civil date. `month` is 1..12 and `day` is 1..31; the constructors and
/// parser keep them in range, and the arithmetic below assumes it.
pub const CalendarDate = struct {
    year: u16,
    month: u8,
    day: u8,

    pub const Weekday = enum(u8) { sunday, monday, tuesday, wednesday, thursday, friday, saturday };

    /// Full month names, indexed by `month - 1`.
    pub const month_names = [_][]const u8{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    };

    /// Three-letter month abbreviations, indexed by `month - 1`.
    pub const month_abbr = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    /// Two-letter weekday abbreviations in Sunday-first order (index 0 =
    /// Sunday), the column heads the day grid draws.
    pub const weekday_abbr = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };

    /// Gregorian leap-year test.
    pub fn isLeapYear(year: u16) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    /// Number of days in `month` of `year` (28..31; 0 for an out-of-range
    /// month, which the parser and constructors never produce).
    pub fn daysInMonth(year: u16, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) @as(u8, 29) else 28,
            else => 0,
        };
    }

    /// Weekday of this date (Sakamoto's algorithm), Sunday = 0.
    pub fn weekday(self: CalendarDate) Weekday {
        const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        var y: i32 = @intCast(self.year);
        const m: i32 = @intCast(self.month);
        if (m < 3) y -= 1;
        const d: i32 = @intCast(self.day);
        const w = @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[@intCast(m - 1)] + d, 7);
        return @enumFromInt(@as(u8, @intCast(w)));
    }

    pub fn eql(a: CalendarDate, b: CalendarDate) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    pub fn order(a: CalendarDate, b: CalendarDate) std.math.Order {
        if (a.year != b.year) return std.math.order(a.year, b.year);
        if (a.month != b.month) return std.math.order(a.month, b.month);
        return std.math.order(a.day, b.day);
    }

    /// True when `self` lies within `[a, b]` inclusive, regardless of which
    /// of `a`/`b` is the earlier bound.
    pub fn between(self: CalendarDate, a: CalendarDate, b: CalendarDate) bool {
        const lo = if (a.order(b) == .gt) b else a;
        const hi = if (a.order(b) == .gt) a else b;
        return self.order(lo) != .lt and self.order(hi) != .gt;
    }

    /// This date's `year`/`month` with the day pinned to 1.
    pub fn firstOfMonth(self: CalendarDate) CalendarDate {
        return .{ .year = self.year, .month = self.month, .day = 1 };
    }

    /// Same year/month with `day` clamped into the month (so stepping onto
    /// a shorter month lands on its last day, not an invalid one).
    pub fn withDay(self: CalendarDate, day: u8) CalendarDate {
        const last = daysInMonth(self.year, self.month);
        return .{ .year = self.year, .month = self.month, .day = @min(@max(day, 1), last) };
    }

    /// This date's month stepped by `delta` months (day clamped to the
    /// destination month's length). The app's prev/next handlers use it.
    pub fn addMonths(self: CalendarDate, delta: i32) CalendarDate {
        const zero_based: i32 = @as(i32, @intCast(self.year)) * 12 + @as(i32, @intCast(self.month)) - 1 + delta;
        const year: u16 = @intCast(@divFloor(zero_based, 12));
        const month: u8 = @intCast(@mod(zero_based, 12) + 1);
        const last = daysInMonth(year, month);
        return .{ .year = year, .month = month, .day = @min(self.day, last) };
    }

    /// This date shifted by `delta` days across month/year boundaries
    /// (Howard Hinnant's civil-from-days round trip).
    pub fn addDays(self: CalendarDate, delta: i32) CalendarDate {
        return fromOrdinal(self.toOrdinal() + delta);
    }

    /// Days from `other` to `self` (positive when `self` is later).
    pub fn daysBetween(self: CalendarDate, other: CalendarDate) i64 {
        return self.toOrdinal() - other.toOrdinal();
    }

    /// Days since the Unix epoch (1970-01-01 = 0).
    pub fn toOrdinal(self: CalendarDate) i64 {
        var y: i64 = @intCast(self.year);
        const m: i64 = @intCast(self.month);
        const d: i64 = @intCast(self.day);
        if (m <= 2) y -= 1;
        const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
        const yoe: i64 = y - era * 400;
        const doy: i64 = @divTrunc(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
        const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    /// The date `z` days after the Unix epoch (inverse of `toOrdinal`).
    pub fn fromOrdinal(z0: i64) CalendarDate {
        const z: i64 = z0 + 719468;
        const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
        const doe: i64 = z - era * 146097;
        const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
        const mp: i64 = @divTrunc(5 * doy + 2, 153);
        const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
        const m: i64 = if (mp < 10) mp + 3 else mp - 9;
        // A month grid at the year boundaries (e.g. `0000-01` or `65535-12`)
        // spills into the previous/next year, which can fall outside the u16
        // `year` field. Saturate rather than `@intCast`-panic so an
        // out-of-range grid cell degrades to a clamped date, keeping the
        // module's "degrade, don't crash" contract.
        const yr: i64 = if (m <= 2) y + 1 else y;
        return .{
            .year = std.math.cast(u16, yr) orelse (if (yr < 0) 0 else std.math.maxInt(u16)),
            .month = @intCast(m),
            .day = @intCast(d),
        };
    }

    /// The date shown in the top-left cell of a month grid: the first day
    /// of `self`'s month walked back to the most recent `week_start`
    /// weekday. Grid cell `i` (0..41) is `gridStart(...).addDays(i)`.
    pub fn gridStart(self: CalendarDate, week_start: Weekday) CalendarDate {
        const first = self.firstOfMonth();
        const lead: i32 = @mod(@as(i32, @intCast(@intFromEnum(first.weekday()))) - @as(i32, @intCast(@intFromEnum(week_start))), 7);
        return first.addDays(-lead);
    }

    /// Parse a strict `YYYY-MM-DD` date; returns null on any malformed or
    /// out-of-range field (so a bad model value degrades to "no date"
    /// rather than a crash).
    pub fn parseIso(text: []const u8) ?CalendarDate {
        if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
        const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
        if (month < 1 or month > 12) return null;
        if (day < 1 or day > daysInMonth(year, month)) return null;
        return .{ .year = year, .month = month, .day = day };
    }

    /// Format as `YYYY-MM-DD` into `buf`.
    pub fn formatIso(self: CalendarDate, buf: *[10]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day }) catch buf[0..0];
    }

    /// The delimiters a `selected` attribute's ISO-date list may use.
    const list_delims = " ,\t\n";

    /// Upper bound on the dates a delimited list holds (its token count) —
    /// the size the markup backends allocate before parsing.
    pub fn countIsoList(text: []const u8) usize {
        var it = std.mem.tokenizeAny(u8, text, list_delims);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Parse a whitespace/comma-delimited ISO-date list into `out`,
    /// returning how many parsed. Malformed tokens are skipped so one bad
    /// entry never sinks the rest.
    pub fn parseIsoList(text: []const u8, out: []CalendarDate) usize {
        var it = std.mem.tokenizeAny(u8, text, list_delims);
        var n: usize = 0;
        while (it.next()) |token| {
            if (n >= out.len) break;
            if (parseIso(token)) |date| {
                out[n] = date;
                n += 1;
            }
        }
        return n;
    }
};

const testing = std.testing;

test "leap year rule" {
    try testing.expect(CalendarDate.isLeapYear(2000));
    try testing.expect(CalendarDate.isLeapYear(2024));
    try testing.expect(!CalendarDate.isLeapYear(1900));
    try testing.expect(!CalendarDate.isLeapYear(2023));
}

test "days in month" {
    try testing.expectEqual(@as(u8, 29), CalendarDate.daysInMonth(2024, 2));
    try testing.expectEqual(@as(u8, 28), CalendarDate.daysInMonth(2023, 2));
    try testing.expectEqual(@as(u8, 31), CalendarDate.daysInMonth(2026, 7));
    try testing.expectEqual(@as(u8, 30), CalendarDate.daysInMonth(2026, 4));
}

test "weekday of known dates" {
    // 2026-07-08 is a Wednesday; 2000-01-01 a Saturday; 1970-01-01 a Thursday.
    try testing.expectEqual(CalendarDate.Weekday.wednesday, (CalendarDate{ .year = 2026, .month = 7, .day = 8 }).weekday());
    try testing.expectEqual(CalendarDate.Weekday.saturday, (CalendarDate{ .year = 2000, .month = 1, .day = 1 }).weekday());
    try testing.expectEqual(CalendarDate.Weekday.thursday, (CalendarDate{ .year = 1970, .month = 1, .day = 1 }).weekday());
}

test "ordinal round trip and epoch anchor" {
    try testing.expectEqual(@as(i64, 0), (CalendarDate{ .year = 1970, .month = 1, .day = 1 }).toOrdinal());
    const d = CalendarDate{ .year = 2026, .month = 7, .day = 8 };
    try testing.expect(d.eql(CalendarDate.fromOrdinal(d.toOrdinal())));
}

test "addDays crosses month and year boundaries" {
    const end_of_july = CalendarDate{ .year = 2026, .month = 7, .day = 31 };
    try testing.expect((CalendarDate{ .year = 2026, .month = 8, .day = 1 }).eql(end_of_july.addDays(1)));
    const nye = CalendarDate{ .year = 2026, .month = 12, .day = 31 };
    try testing.expect((CalendarDate{ .year = 2027, .month = 1, .day = 1 }).eql(nye.addDays(1)));
    // Leap-day boundaries.
    try testing.expect((CalendarDate{ .year = 2024, .month = 2, .day = 29 }).eql((CalendarDate{ .year = 2024, .month = 2, .day = 28 }).addDays(1)));
    try testing.expect((CalendarDate{ .year = 2024, .month = 3, .day = 1 }).eql((CalendarDate{ .year = 2024, .month = 2, .day = 29 }).addDays(1)));
    // A full common year later (2025 is not a leap year).
    try testing.expect((CalendarDate{ .year = 2027, .month = 7, .day = 8 }).eql((CalendarDate{ .year = 2026, .month = 7, .day = 8 }).addDays(365)));
}

test "addMonths clamps the day into the destination month" {
    const jan31 = CalendarDate{ .year = 2026, .month = 1, .day = 31 };
    try testing.expect((CalendarDate{ .year = 2026, .month = 2, .day = 28 }).eql(jan31.addMonths(1)));
    try testing.expect((CalendarDate{ .year = 2025, .month = 12, .day = 31 }).eql(jan31.addMonths(-1)));
    try testing.expect((CalendarDate{ .year = 2027, .month = 1, .day = 31 }).eql(jan31.addMonths(12)));
}

test "between is inclusive and order-independent" {
    const mid = CalendarDate{ .year = 2026, .month = 7, .day = 10 };
    const a = CalendarDate{ .year = 2026, .month = 7, .day = 8 };
    const b = CalendarDate{ .year = 2026, .month = 7, .day = 12 };
    try testing.expect(mid.between(a, b));
    try testing.expect(mid.between(b, a));
    try testing.expect(a.between(a, b));
    try testing.expect(!(CalendarDate{ .year = 2026, .month = 7, .day = 13 }).between(a, b));
}

test "grid start walks back to the week start" {
    // July 2026: the 1st is a Wednesday. Sunday-first grid starts 2026-06-28.
    const july = CalendarDate{ .year = 2026, .month = 7, .day = 1 };
    try testing.expect((CalendarDate{ .year = 2026, .month = 6, .day = 28 }).eql(july.gridStart(.sunday)));
    // Monday-first grid starts 2026-06-29.
    try testing.expect((CalendarDate{ .year = 2026, .month = 6, .day = 29 }).eql(july.gridStart(.monday)));
    // When the 1st already is the week start, no walk-back.
    const feb = CalendarDate{ .year = 2026, .month = 2, .day = 1 }; // Sunday
    try testing.expect(feb.eql(feb.gridStart(.sunday)));
}

test "iso parse and format" {
    const d = CalendarDate.parseIso("2026-07-08").?;
    try testing.expectEqual(@as(u16, 2026), d.year);
    try testing.expectEqual(@as(u8, 7), d.month);
    try testing.expectEqual(@as(u8, 8), d.day);
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2026-07-08", d.formatIso(&buf));

    try testing.expect(CalendarDate.parseIso("2026-13-01") == null); // bad month
    try testing.expect(CalendarDate.parseIso("2026-02-30") == null); // bad day
    try testing.expect(CalendarDate.parseIso("2023-02-29") == null); // non-leap
    try testing.expect(CalendarDate.parseIso("2026-7-8") == null); // unpadded
    try testing.expect(CalendarDate.parseIso("2026/07/08") == null); // wrong sep
    try testing.expect(CalendarDate.parseIso("") == null);
}

test "iso list parses delimited dates and skips bad tokens" {
    var buf: [4]CalendarDate = undefined;
    try testing.expectEqual(@as(usize, 3), CalendarDate.countIsoList("2026-07-08, 2026-07-10 2026-07-15"));
    const n = CalendarDate.parseIsoList("2026-07-08, nope 2026-07-10", &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect((CalendarDate{ .year = 2026, .month = 7, .day = 8 }).eql(buf[0]));
    try testing.expect((CalendarDate{ .year = 2026, .month = 7, .day = 10 }).eql(buf[1]));
    try testing.expectEqual(@as(usize, 0), CalendarDate.parseIsoList("", &buf));
}

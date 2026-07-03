const std = @import("std");
const protocol = @import("automation_protocol");

const automation_dir = protocol.default_dir;

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        try printFile(io, "windows.txt");
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try printFile(io, "snapshot.txt");
    } else if (std.mem.eql(u8, command, "screenshot")) {
        if (args.len < 2 or args.len > 3) return usage();
        var name_buffer: [128]u8 = undefined;
        const name = protocol.screenshotFileName(args[1], &name_buffer) catch return usage();
        deleteAutomationFile(io, name);
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "screenshot", value);
        try waitForScreenshot(io, name);
    } else if (std.mem.eql(u8, command, "reload")) {
        try sendCommand(allocator, io, "reload", "");
    } else if (std.mem.eql(u8, command, "resize")) {
        if (args.len < 3 or args.len > 4) return usage();
        const value = if (args.len == 4)
            try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "resize", value);
    } else if (std.mem.eql(u8, command, "menu-command")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "menu-command", args[1]);
    } else if (std.mem.eql(u8, command, "native-command")) {
        if (args.len < 2 or args.len > 3) return usage();
        if (args.len == 3) {
            const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
            defer allocator.free(value);
            try sendCommand(allocator, io, "native-command", value);
        } else {
            try sendCommand(allocator, io, "native-command", args[1]);
        }
    } else if (std.mem.eql(u8, command, "widget-action")) {
        if (args.len < 4) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-action", value);
    } else if (std.mem.eql(u8, command, "widget-click")) {
        if (args.len != 3) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-click", value);
    } else if (std.mem.eql(u8, command, "widget-drag")) {
        if (args.len != 5 and args.len != 7) return usage();
        const value = if (args.len == 7)
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4], args[5], args[6] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-drag", value);
    } else if (std.mem.eql(u8, command, "widget-wheel")) {
        if (args.len != 4) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-wheel", value);
    } else if (std.mem.eql(u8, command, "widget-key")) {
        if (args.len < 3) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-key", value);
    } else if (std.mem.eql(u8, command, "shortcut")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "shortcut", args[1]);
    } else if (std.mem.eql(u8, command, "focus")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "focus", args[1]);
    } else if (std.mem.eql(u8, command, "focus-next")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-next", "");
    } else if (std.mem.eql(u8, command, "focus-previous")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-previous", "");
    } else if (std.mem.eql(u8, command, "wait")) {
        try waitForFile(allocator, io, "snapshot.txt", "ready=true");
    } else if (std.mem.eql(u8, command, "assert")) {
        try runAssert(allocator, io, args[1..]);
    } else if (std.mem.eql(u8, command, "bridge")) {
        if (args.len < 2) return usage();
        deleteAutomationFile(io, "bridge-response.txt");
        try sendCommand(allocator, io, "bridge", args[1]);
        try waitForFile(allocator, io, "bridge-response.txt", "");
    } else {
        return usage();
    }
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native automate <command>
        \\
        \\commands:
        \\  list
        \\  snapshot
        \\  screenshot <view-label> [scale]   (renders the gpu_surface view's canvas to screenshot-<view-label>.png)
        \\  reload
        \\  resize <width> <height> [scale]
        \\  menu-command <id>
        \\  native-command <id> [view-label]
        \\  widget-action <view-label> <widget-id> <action> [value]
        \\  widget-click <view-label> <widget-id>   (ids are the bare number; snapshots print #id)
        \\  widget-drag <view-label> <widget-id> <start-x-ratio> <end-x-ratio> [start-y-ratio end-y-ratio]
        \\  widget-wheel <view-label> <widget-id> <delta-y>
        \\  widget-key <view-label> <key> [text]
        \\  shortcut <id>
        \\  focus <view-label>
        \\  focus-next
        \\  focus-previous
        \\  wait
        \\  assert [--absent] [--timeout-ms 30000] <pattern> [more patterns...]
        \\      (each pattern is a regex that must match snapshot.txt; --absent
        \\       inverts: every pattern must be gone. Polls until the timeout.)
        \\  bridge <request-json>
        \\
    , .{});
}

fn sendCommand(allocator: std.mem.Allocator, io: std.Io, action: []const u8, value: []const u8) !void {
    const buffer = try allocator.alloc(u8, protocol.max_command_bytes);
    defer allocator.free(buffer);
    const line = try protocol.commandLine(action, value, buffer);
    // The automation dir is created by the RUNNING APP (built with
    // -Dautomation=true), never by this CLI: a queue written into a
    // freshly created dir would go to an app that does not exist —
    // classically, the wrong cwd — and silently do nothing. Refuse
    // loudly instead, naming the dir we looked at.
    try requireAutomationDir(io);
    var command_path: [256]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path(&command_path, "command.txt"), .data = line });
    var dir_buffer: [1024]u8 = undefined;
    std.debug.print("queued {s} -> {s}\n", .{ action, automationDirDescription(io, &dir_buffer) });
}

/// Error out (loudly, with the absolute path) when the automation dir
/// does not exist under the current cwd — the app creates it at start,
/// so its absence means no automation-enabled app runs HERE and the
/// command would be queued into the void.
fn requireAutomationDir(io: std.Io) error{AutomationCommandFailed}!void {
    var dir = std.Io.Dir.cwd().openDir(io, automation_dir, .{}) catch {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print(
            "error: no automation dir at {s}\n" ++
                "       (the app creates it on launch when built with -Dautomation=true;\n" ++
                "        run this command from the app project's working directory)\n",
            .{automationDirDescription(io, &dir_buffer)},
        );
        return error.AutomationCommandFailed;
    };
    dir.close(io);
}

/// The automation dir as an absolute path when the cwd resolves, the
/// relative default otherwise — for messages only.
fn automationDirDescription(io: std.Io, buffer: []u8) []const u8 {
    var cwd_buffer: [1024]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer) catch return automation_dir;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ cwd_buffer[0..cwd_len], automation_dir }) catch automation_dir;
}

fn printFile(io: std.Io, name: []const u8) !void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(std.heap.page_allocator, io, path(&file_path, name)) catch {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print("error: no app connected — nothing readable at {s}\n", .{automationDirDescription(io, &dir_buffer)});
        return error.AutomationCommandFailed;
    };
    defer std.heap.page_allocator.free(bytes);
    std.debug.print("{s}", .{bytes});
}

fn waitForFile(allocator: std.mem.Allocator, io: std.Io, name: []const u8, marker: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const bytes = readFile(allocator, io, path(&file_path, name)) catch {
            try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            continue;
        };
        if (marker.len == 0 or std.mem.indexOf(u8, bytes, marker) != null) {
            std.debug.print("{s}", .{bytes});
            allocator.free(bytes);
            return;
        }
        allocator.free(bytes);
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    return fail("timed out waiting for automation");
}

fn waitForScreenshot(io: std.Io, name: []const u8) !void {
    // Screenshots are published atomically (write + rename), so existence
    // means the PNG is complete. Reference rendering large surfaces takes a
    // moment, so poll longer than text artifacts.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const screenshot_path = path(&file_path, name);
        if (std.Io.Dir.cwd().openFile(io, screenshot_path, .{})) |opened| {
            var file = opened;
            file.close(io);
            std.debug.print("{s}\n", .{screenshot_path});
            return;
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    return fail("timed out waiting for screenshot");
}

fn deleteAutomationFile(io: std.Io, name: []const u8) void {
    var file_path: [256]u8 = undefined;
    std.Io.Dir.cwd().deleteFile(io, path(&file_path, name)) catch {};
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn path(buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ automation_dir, name }) catch unreachable;
}

fn fail(message: []const u8) error{AutomationCommandFailed} {
    std.debug.print("error: {s}\n", .{message});
    return error.AutomationCommandFailed;
}

// ---------------------------------------------------------------- assert

const assert_poll_interval_ms = 100;
const assert_default_timeout_ms: u32 = 30_000;
const assert_tail_lines = 20;
const assert_max_patterns = 32;

const AssertSpec = struct {
    patterns: []const []const u8,
    absent: bool = false,
    timeout_ms: u32 = assert_default_timeout_ms,
};

const AssertParseError = error{
    MissingFlagValue,
    InvalidTimeout,
    NoPatterns,
    TooManyPatterns,
};

/// `assert [--absent] [--timeout-ms N] <pattern>...` — flags may appear
/// anywhere; everything else is a pattern. `patterns_buffer` holds the
/// positional slices, so no allocation happens here.
fn parseAssertArgs(args: []const []const u8, patterns_buffer: [][]const u8) AssertParseError!AssertSpec {
    var spec: AssertSpec = .{ .patterns = &.{} };
    var count: usize = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--absent")) {
            spec.absent = true;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            index += 1;
            if (index >= args.len) return error.MissingFlagValue;
            spec.timeout_ms = std.fmt.parseUnsigned(u32, args[index], 10) catch return error.InvalidTimeout;
        } else {
            if (count >= patterns_buffer.len) return error.TooManyPatterns;
            patterns_buffer[count] = arg;
            count += 1;
        }
    }
    if (count == 0) return error.NoPatterns;
    spec.patterns = patterns_buffer[0..count];
    return spec;
}

fn runAssert(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var patterns_buffer: [assert_max_patterns][]const u8 = undefined;
    const spec = parseAssertArgs(args, &patterns_buffer) catch |err| switch (err) {
        error.NoPatterns => return fail("assert needs at least one pattern (see: zero-native automate)"),
        error.MissingFlagValue => return fail("--timeout-ms requires a value in milliseconds"),
        error.InvalidTimeout => return fail("--timeout-ms value must be a positive integer"),
        error.TooManyPatterns => return fail("too many assert patterns (max 32)"),
    };
    for (spec.patterns) |pattern| {
        validatePattern(pattern) catch {
            std.debug.print("error: invalid pattern: {s}\n", .{pattern});
            std.debug.print("       (supported: literals, . * + ? ^ $ [...] and \\d \\w \\s escapes)\n", .{});
            return error.AutomationCommandFailed;
        };
    }

    var elapsed_ms: u64 = 0;
    var snapshot: ?[]u8 = null;
    defer if (snapshot) |bytes| allocator.free(bytes);
    while (true) {
        if (snapshot) |bytes| {
            allocator.free(bytes);
            snapshot = null;
        }
        var file_path: [256]u8 = undefined;
        snapshot = readFile(allocator, io, path(&file_path, "snapshot.txt")) catch null;
        if (snapshot) |bytes| {
            if (assertSatisfied(bytes, spec.patterns, spec.absent)) {
                std.debug.print("assert ok: {d} pattern(s) {s} after {d}ms\n", .{
                    spec.patterns.len,
                    if (spec.absent) "absent" else "matched",
                    elapsed_ms,
                });
                return;
            }
        }
        if (elapsed_ms >= spec.timeout_ms) break;
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(assert_poll_interval_ms * std.time.ns_per_ms), .awake);
        elapsed_ms += assert_poll_interval_ms;
    }

    // Timed out: name every unsatisfied pattern, then show where we looked
    // and the snapshot tail so CI logs carry the evidence.
    std.debug.print("error: automate assert failed after {d}ms\n", .{spec.timeout_ms});
    if (snapshot) |bytes| {
        for (spec.patterns) |pattern| {
            const matched = matchesPattern(pattern, bytes) catch false;
            if (spec.absent and matched) {
                std.debug.print("  still present: {s}\n", .{pattern});
            } else if (!spec.absent and !matched) {
                std.debug.print("  missing: {s}\n", .{pattern});
            }
        }
        const tail = textTail(bytes, assert_tail_lines);
        std.debug.print("--- snapshot.txt tail (last {d} lines) ---\n{s}", .{ assert_tail_lines, tail });
        if (tail.len == 0 or tail[tail.len - 1] != '\n') std.debug.print("\n", .{});
    } else {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print(
            "  no snapshot at {s}\n" ++
                "  (the app creates it on launch when built with -Dautomation=true;\n" ++
                "   run this command from the app project's working directory)\n",
            .{automationDirDescription(io, &dir_buffer)},
        );
    }
    return error.AutomationCommandFailed;
}

/// All patterns must match (or, with `absent`, none may match).
fn assertSatisfied(text: []const u8, patterns: []const []const u8, absent: bool) bool {
    for (patterns) |pattern| {
        const matched = matchesPattern(pattern, text) catch return false;
        if (matched == absent) return false;
    }
    return true;
}

/// The last `max_lines` lines of `text` (for failure output).
fn textTail(text: []const u8, max_lines: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return text[0..0];
    var lines: usize = 0;
    var index = trimmed.len;
    while (index > 0) {
        index -= 1;
        if (trimmed[index] == '\n') {
            lines += 1;
            if (lines == max_lines) return text[index + 1 ..];
        }
    }
    return text;
}

// ------------------------------------------------------- pattern matching
//
// A small grep-style regex subset, so CI assertions do not need a shell
// pipeline: literals, `.` (any char but newline), postfix `*` `+` `?`,
// line anchors `^` and `$`, character classes `[abc]` / `[^a-z0-9]`, and
// the escapes `\d \D \w \W \s \S` plus escaped metacharacters (`\.`).
// No groups or alternation — assert takes multiple patterns instead.

const PatternError = error{InvalidPattern};

/// True when `pattern` matches anywhere in `text`.
fn matchesPattern(pattern: []const u8, text: []const u8) PatternError!bool {
    try validatePattern(pattern);
    var start: usize = 0;
    while (true) {
        if (matchHere(pattern, 0, text, start)) return true;
        if (start >= text.len) return false;
        start += 1;
    }
}

fn validatePattern(pattern: []const u8) PatternError!void {
    var index: usize = 0;
    var last_atom = false;
    while (index < pattern.len) {
        const ch = pattern[index];
        switch (ch) {
            '*', '+', '?' => {
                if (!last_atom) return error.InvalidPattern;
                last_atom = false;
                index += 1;
            },
            '^', '$' => {
                last_atom = false;
                index += 1;
            },
            else => {
                index = try atomEnd(pattern, index);
                last_atom = true;
            },
        }
    }
}

/// End index (exclusive) of the atom starting at `index`.
fn atomEnd(pattern: []const u8, index: usize) PatternError!usize {
    switch (pattern[index]) {
        '\\' => {
            if (index + 1 >= pattern.len) return error.InvalidPattern;
            return index + 2;
        },
        '[' => {
            var end = index + 1;
            if (end < pattern.len and pattern[end] == '^') end += 1;
            // A `]` directly after `[` or `[^` is a literal member.
            if (end < pattern.len and pattern[end] == ']') end += 1;
            while (end < pattern.len and pattern[end] != ']') {
                end += if (pattern[end] == '\\') @as(usize, 2) else 1;
            }
            if (end >= pattern.len) return error.InvalidPattern;
            return end + 1;
        },
        else => return index + 1,
    }
}

fn matchHere(pattern: []const u8, p: usize, text: []const u8, t: usize) bool {
    if (p >= pattern.len) return true;
    switch (pattern[p]) {
        '^' => {
            if (t == 0 or text[t - 1] == '\n') return matchHere(pattern, p + 1, text, t);
            return false;
        },
        '$' => {
            if (t == text.len or text[t] == '\n') return matchHere(pattern, p + 1, text, t);
            return false;
        },
        else => {},
    }
    const end = atomEnd(pattern, p) catch return false;
    const quantifier: u8 = if (end < pattern.len) pattern[end] else 0;
    switch (quantifier) {
        '*' => return matchRepeat(pattern, p, end, end + 1, text, t, 0),
        '+' => return matchRepeat(pattern, p, end, end + 1, text, t, 1),
        '?' => {
            if (t < text.len and atomMatches(pattern[p..end], text[t])) {
                if (matchHere(pattern, end + 1, text, t + 1)) return true;
            }
            return matchHere(pattern, end + 1, text, t);
        },
        else => {
            if (t < text.len and atomMatches(pattern[p..end], text[t])) {
                return matchHere(pattern, end, text, t + 1);
            }
            return false;
        },
    }
}

/// Greedy repetition with backtracking: consume as many atom matches as
/// possible, then retreat until the rest of the pattern matches.
fn matchRepeat(pattern: []const u8, atom_start: usize, atom_stop: usize, rest: usize, text: []const u8, t: usize, min: usize) bool {
    const atom = pattern[atom_start..atom_stop];
    var count: usize = 0;
    while (t + count < text.len and atomMatches(atom, text[t + count])) count += 1;
    while (true) {
        if (count >= min and matchHere(pattern, rest, text, t + count)) return true;
        if (count == 0) return false;
        count -= 1;
        if (count < min) return false;
    }
}

fn atomMatches(atom: []const u8, ch: u8) bool {
    if (atom.len == 1) {
        return switch (atom[0]) {
            '.' => ch != '\n',
            else => atom[0] == ch,
        };
    }
    if (atom[0] == '\\') return escapeMatches(atom[1], ch);
    if (atom[0] == '[') return classMatches(atom[1 .. atom.len - 1], ch);
    return false;
}

fn escapeMatches(escape: u8, ch: u8) bool {
    return switch (escape) {
        'd' => std.ascii.isDigit(ch),
        'D' => !std.ascii.isDigit(ch),
        'w' => std.ascii.isAlphanumeric(ch) or ch == '_',
        'W' => !(std.ascii.isAlphanumeric(ch) or ch == '_'),
        's' => std.ascii.isWhitespace(ch),
        'S' => !std.ascii.isWhitespace(ch),
        'n' => ch == '\n',
        't' => ch == '\t',
        else => escape == ch,
    };
}

/// `body` is the class content without brackets; supports leading `^`,
/// ranges (`a-z`), `\`-escapes, and a literal `]` as the first member.
fn classMatches(body: []const u8, ch: u8) bool {
    var negate = false;
    var index: usize = 0;
    if (index < body.len and body[index] == '^') {
        negate = true;
        index += 1;
    }
    var found = false;
    while (index < body.len) {
        const low: u8 = body[index];
        if (low == '\\' and index + 1 < body.len) {
            index += 1;
            if (escapeMatches(body[index], ch)) found = true;
            index += 1;
            continue;
        }
        index += 1;
        if (index + 1 < body.len and body[index] == '-') {
            const high = body[index + 1];
            if (ch >= low and ch <= high) found = true;
            index += 2;
        } else if (low == ch) {
            found = true;
        }
    }
    return found != negate;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "matchesPattern: literals and metacharacters" {
    try testing.expect(try matchesPattern("ready=true", "app foo\nready=true\n"));
    try testing.expect(!try matchesPattern("ready=true", "ready=false\n"));
    try testing.expect(try matchesPattern("count: \\d+", "status count: 42 open"));
    try testing.expect(!try matchesPattern("count: \\d+", "status count: none"));
    try testing.expect(try matchesPattern("role=button name=\"Reset\"", "widget #3 role=button name=\"Reset\"\n"));
    try testing.expect(try matchesPattern("gpu_.*=true", "gpu_nonblank=true"));
    try testing.expect(try matchesPattern("a.c", "abc"));
    try testing.expect(!try matchesPattern("a.c", "a\nc"));
}

test "matchesPattern: quantifiers backtrack" {
    try testing.expect(try matchesPattern("wo*rld", "wrld"));
    try testing.expect(try matchesPattern("wo+rld", "wooorld"));
    try testing.expect(!try matchesPattern("wo+rld", "wrld"));
    try testing.expect(try matchesPattern("colou?r", "color"));
    try testing.expect(try matchesPattern("colou?r", "colour"));
    try testing.expect(try matchesPattern("a.*b", "a x b y b"));
    try testing.expect(try matchesPattern(".*=true$", "gpu_nonblank=true"));
}

test "matchesPattern: line anchors work mid-file" {
    const snapshot = "app demo\nready=true dispatch_errors=0\nwindow main\n";
    try testing.expect(try matchesPattern("^ready=true", snapshot));
    try testing.expect(try matchesPattern("^window main$", snapshot));
    try testing.expect(!try matchesPattern("^main$", snapshot));
    try testing.expect(try matchesPattern("dispatch_errors=0$", snapshot));
}

test "matchesPattern: character classes" {
    try testing.expect(try matchesPattern("[0-9]+ open", "inbox 4 open"));
    try testing.expect(try matchesPattern("[a-z_]+=true", "gpu_nonblank=true"));
    try testing.expect(try matchesPattern("[^a]bc", "xbc"));
    try testing.expect(!try matchesPattern("[^a]bc", "abc"));
    try testing.expect(try matchesPattern("[]x]", "]"));
}

test "matchesPattern: invalid patterns are rejected" {
    try testing.expectError(error.InvalidPattern, matchesPattern("*x", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("a\\", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("[abc", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("^*", "anything"));
}

test "assertSatisfied: present and absent modes" {
    const snapshot = "ready=true\ngpu_nonblank=true\nwidget role=button name=\"Reset\"\n";
    const present = [_][]const u8{ "ready=true", "gpu_nonblank=true", "name=\"Reset\"" };
    try testing.expect(assertSatisfied(snapshot, &present, false));
    const with_missing = [_][]const u8{ "ready=true", "name=\"Delete\"" };
    try testing.expect(!assertSatisfied(snapshot, &with_missing, false));
    const gone = [_][]const u8{ "error event=", "panicked" };
    try testing.expect(assertSatisfied(snapshot, &gone, true));
    const still_there = [_][]const u8{"gpu_nonblank=true"};
    try testing.expect(!assertSatisfied(snapshot, &still_there, true));
}

test "parseAssertArgs: flags and patterns in any order" {
    var buffer: [assert_max_patterns][]const u8 = undefined;

    const plain = try parseAssertArgs(&.{ "ready=true", "count: 0" }, &buffer);
    try testing.expectEqual(@as(usize, 2), plain.patterns.len);
    try testing.expect(!plain.absent);
    try testing.expectEqual(assert_default_timeout_ms, plain.timeout_ms);

    const flagged = try parseAssertArgs(&.{ "--absent", "error event=", "--timeout-ms", "5000" }, &buffer);
    try testing.expect(flagged.absent);
    try testing.expectEqual(@as(u32, 5000), flagged.timeout_ms);
    try testing.expectEqualStrings("error event=", flagged.patterns[0]);

    try testing.expectError(error.NoPatterns, parseAssertArgs(&.{"--absent"}, &buffer));
    try testing.expectError(error.MissingFlagValue, parseAssertArgs(&.{ "x", "--timeout-ms" }, &buffer));
    try testing.expectError(error.InvalidTimeout, parseAssertArgs(&.{ "x", "--timeout-ms", "soon" }, &buffer));
}

test "textTail keeps the last lines only" {
    try testing.expectEqualStrings("", textTail("", 3));
    try testing.expectEqualStrings("a\nb\n", textTail("a\nb\n", 3));
    try testing.expectEqualStrings("c\nd\ne\n", textTail("a\nb\nc\nd\ne\n", 3));
    try testing.expectEqualStrings("d\ne", textTail("c\nd\ne", 2));
}

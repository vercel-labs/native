const std = @import("std");
const builtin = @import("builtin");

pub const ParseError = error{
    EmptySpec,
    MissingKey,
    DuplicateKey,
    DuplicateModifier,
    UnknownToken,
};

pub const Modifier = packed struct {
    command: bool = false,
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    function: bool = false,
};

pub const KeyCode = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    key_0,
    key_1,
    key_2,
    key_3,
    key_4,
    key_5,
    key_6,
    key_7,
    key_8,
    key_9,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    Space,
    Tab,
    Return,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    Plus,
    Minus,
};

pub const KeyCombo = struct {
    modifier: Modifier = .{},
    key: KeyCode,
};

pub fn parse(spec: []const u8) ParseError!KeyCombo {
    if (std.mem.trim(u8, spec, &std.ascii.whitespace).len == 0) return error.EmptySpec;

    var modifier: Modifier = .{};
    var key: ?KeyCode = null;
    var parts = std.mem.splitScalar(u8, spec, '+');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, &std.ascii.whitespace);
        if (part.len == 0) return error.UnknownToken;

        if (try parseModifier(part, &modifier)) continue;

        if (key != null) return error.DuplicateKey;
        key = parseKey(part) orelse return error.UnknownToken;
    }

    return .{ .modifier = modifier, .key = key orelse return error.MissingKey };
}

fn parseModifier(part: []const u8, modifier: *Modifier) ParseError!bool {
    if (eqlIgnoreCase(part, "command") or eqlIgnoreCase(part, "cmd") or eqlIgnoreCase(part, "super") or eqlIgnoreCase(part, "meta")) {
        if (modifier.command) return error.DuplicateModifier;
        modifier.command = true;
        return true;
    }
    if (eqlIgnoreCase(part, "control") or eqlIgnoreCase(part, "ctrl")) {
        if (modifier.control) return error.DuplicateModifier;
        modifier.control = true;
        return true;
    }
    if (eqlIgnoreCase(part, "commandorcontrol") or eqlIgnoreCase(part, "cmdorctrl") or eqlIgnoreCase(part, "commandorctrl")) {
        if (builtin.os.tag == .macos) {
            if (modifier.command) return error.DuplicateModifier;
            modifier.command = true;
        } else {
            if (modifier.control) return error.DuplicateModifier;
            modifier.control = true;
        }
        return true;
    }
    if (eqlIgnoreCase(part, "alt") or eqlIgnoreCase(part, "option")) {
        if (modifier.alt) return error.DuplicateModifier;
        modifier.alt = true;
        return true;
    }
    if (eqlIgnoreCase(part, "shift")) {
        if (modifier.shift) return error.DuplicateModifier;
        modifier.shift = true;
        return true;
    }
    if (eqlIgnoreCase(part, "function") or eqlIgnoreCase(part, "fn")) {
        if (modifier.function) return error.DuplicateModifier;
        modifier.function = true;
        return true;
    }
    return false;
}

fn parseKey(part: []const u8) ?KeyCode {
    if (part.len == 1) {
        const ch = std.ascii.toLower(part[0]);
        if (ch >= 'a' and ch <= 'z') return @enumFromInt(@as(u8, ch - 'a'));
        if (ch >= '0' and ch <= '9') return @enumFromInt(@intFromEnum(KeyCode.key_0) + @as(u8, ch - '0'));
        if (part[0] == '=') return .Plus;
        if (part[0] == '-') return .Minus;
    }

    if ((part.len == 2 or part.len == 3) and (part[0] == 'f' or part[0] == 'F')) {
        const value = std.fmt.parseUnsigned(u8, part[1..], 10) catch return null;
        if (value >= 1 and value <= 19) return @enumFromInt(@intFromEnum(KeyCode.F1) + value - 1);
    }

    if (eqlIgnoreCase(part, "space")) return .Space;
    if (eqlIgnoreCase(part, "tab")) return .Tab;
    if (eqlIgnoreCase(part, "return") or eqlIgnoreCase(part, "enter")) return .Return;
    if (eqlIgnoreCase(part, "escape") or eqlIgnoreCase(part, "esc")) return .Escape;
    if (eqlIgnoreCase(part, "up") or eqlIgnoreCase(part, "arrowup")) return .Up;
    if (eqlIgnoreCase(part, "down") or eqlIgnoreCase(part, "arrowdown")) return .Down;
    if (eqlIgnoreCase(part, "left") or eqlIgnoreCase(part, "arrowleft")) return .Left;
    if (eqlIgnoreCase(part, "right") or eqlIgnoreCase(part, "arrowright")) return .Right;
    if (eqlIgnoreCase(part, "home")) return .Home;
    if (eqlIgnoreCase(part, "end")) return .End;
    if (eqlIgnoreCase(part, "pageup")) return .PageUp;
    if (eqlIgnoreCase(part, "pagedown")) return .PageDown;
    if (eqlIgnoreCase(part, "insert") or eqlIgnoreCase(part, "ins")) return .Insert;
    if (eqlIgnoreCase(part, "delete") or eqlIgnoreCase(part, "del")) return .Delete;
    if (eqlIgnoreCase(part, "plus")) return .Plus;
    if (eqlIgnoreCase(part, "minus")) return .Minus;
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "parses accelerator strings case-insensitively" {
    const combo = try parse("CommandOrControl+Shift+P");

    if (builtin.os.tag == .macos) {
        try std.testing.expect(combo.modifier.command);
        try std.testing.expect(!combo.modifier.control);
    } else {
        try std.testing.expect(!combo.modifier.command);
        try std.testing.expect(combo.modifier.control);
    }
    try std.testing.expect(combo.modifier.shift);
    try std.testing.expectEqual(KeyCode.p, combo.key);
}

test "normalizes modifier and key aliases" {
    const cmd = try parse("Cmd+Space");
    const command = try parse("Command+Space");
    const ctrl = try parse("Ctrl+Esc");

    try std.testing.expectEqual(cmd.modifier, command.modifier);
    try std.testing.expect(cmd.modifier.command);
    try std.testing.expectEqual(KeyCode.Space, command.key);
    try std.testing.expect(ctrl.modifier.control);
    try std.testing.expectEqual(KeyCode.Escape, ctrl.key);
}

test "rejects invalid shortcut strings" {
    try std.testing.expectError(error.EmptySpec, parse(""));
    try std.testing.expectError(error.MissingKey, parse("Cmd+Shift"));
    try std.testing.expectError(error.UnknownToken, parse("Cmd+Hyper+P"));
    try std.testing.expectError(error.DuplicateKey, parse("Cmd+P+Q"));
    try std.testing.expectError(error.DuplicateModifier, parse("Cmd+Command+P"));
}

//! Bounded transport for ordered automation interactions. All labels, text,
//! paths, clocks and delivered events remain owned by the native caller.
const std = @import("std");
const geometry = @import("geometry");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Mode = enum(u8) { click, hold, context_press, wheel, key, pinch, pointer_drag, replace_text, composition, drag, drop, menu_admission, menu_completion };
pub const Fact = struct {
    pub const node: u32 = 1;
    pub const interactive: u32 = 2;
    pub const editable: u32 = 4;
    pub const point: u32 = 8;
    pub const text: u32 = 16;
    pub const view: u32 = 32;
    pub const menu: u32 = 64;
    pub const item: u32 = 128;
    pub const separator: u32 = 256;
    pub const enabled: u32 = 512;
    pub const pending: u32 = 1024;
    pub const window: u32 = 2048;
};
pub const Options = struct {
    facts: u32 = 0,
    phase: u8 = 0,
    frame: geometry.RectF = .zero(),
    point: geometry.PointF = .zero(),
    delta: geometry.OffsetF = .zero(),
    ratios: [4]f32 = @splat(0),
    expected_token: u64 = 0,
    current_token: u64 = 0,
};
pub const Event = enum(u32) { down, up, drag, scroll, key, text, pinch_begin, pinch_change, pinch_end, hold_timer, composition, drop };
pub const Key = enum(u32) { borrowed, select_all, backspace };
pub const Step = struct {
    event: Event,
    button: i32,
    key: Key,
    text: bool,
    point: geometry.PointF,
    delta: geometry.OffsetF,
    scale: f32,
};
pub const Program = struct {
    status: u32,
    flags: u32,
    count: usize,
    origin: geometry.PointF,
    end: geometry.PointF,
    steps: [3]Step = undefined,
    pub fn admit(self: Program) !void {
        return switch (self.status) {
            0 => {},
            1 => error.InvalidCommand,
            2 => error.WheelTargetUnknown,
            3 => error.WheelTargetNotInteractive,
            4 => error.WheelTargetHasEmptyBounds,
            5 => error.PinchScaleBelowWireMinimum,
            7 => error.ViewNotFound,
            8 => error.WindowNotFound,
            9 => error.ContextMenuUndeclared,
            10 => error.ContextMenuItemOutOfRange,
            11 => error.ContextMenuItemSeparator,
            12 => error.ContextMenuItemDisabled,
            13 => error.ContextMenuSuperseded,
            14 => error.ContextMenuViewClosed,
            else => unreachable,
        };
    }
};
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn float(bytes: []u8, at: usize, value: f32) void {
    put(bytes, at, @bitCast(value));
}
pub fn request(mode: Mode, options: Options) [128]u8 {
    var bytes: [128]u8 = @splat(0);
    bytes[0..4].* = .{ 91, 1, @intFromEnum(mode), options.phase };
    put(&bytes, 4, options.facts);
    for ([_]f32{ options.frame.x, options.frame.y, options.frame.width, options.frame.height, options.point.x, options.point.y, options.delta.dx, options.delta.dy } ++ options.ratios, 0..) |value, i| float(&bytes, 8 + i * 4, value);
    std.mem.writeInt(u64, bytes[64..72], options.expected_token, .little);
    std.mem.writeInt(u64, bytes[72..80], options.current_token, .little);
    return bytes;
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn real(bytes: []const u8, at: usize) f32 {
    return @bitCast(word(bytes, at));
}
pub fn plan(policy: Policy, mode: Mode, options: Options) Program {
    const input = request(mode, options);
    var bytes: [148]u8 = @splat(0xa5);
    const size = policy(&input, &bytes);
    if (size < 40 or size > bytes.len or word(&bytes, 0) != 1 or word(&bytes, 4) != @intFromEnum(mode) or word(&bytes, 36) != 0) @panic("invalid compiled automation interaction header");
    const count = word(&bytes, 16);
    if (count > 3 or size != 40 + count * 36) @panic("invalid compiled automation interaction extent");
    var result = Program{ .status = word(&bytes, 8), .flags = word(&bytes, 12), .count = count, .origin = .init(real(&bytes, 20), real(&bytes, 24)), .end = .init(real(&bytes, 28), real(&bytes, 32)) };
    if (result.status > 14 or result.status == 6 or result.flags & ~@as(u32, 63) != 0 or (result.status != 0 and count != 0)) @panic("invalid compiled automation interaction result");
    for (result.steps[0..count], 0..) |*step, i| {
        const at = 40 + i * 36;
        const event = std.enums.fromInt(Event, word(&bytes, at)) orelse @panic("invalid compiled automation event");
        const key = std.enums.fromInt(Key, word(&bytes, at + 8)) orelse @panic("invalid compiled automation key");
        if (word(&bytes, at + 4) > 1 or word(&bytes, at + 12) > 1) @panic("invalid compiled automation event fields");
        step.* = .{ .event = event, .button = @intCast(word(&bytes, at + 4)), .key = key, .text = word(&bytes, at + 12) != 0, .point = .init(real(&bytes, at + 16), real(&bytes, at + 20)), .delta = .init(real(&bytes, at + 24), real(&bytes, at + 28)), .scale = real(&bytes, at + 32) };
    }
    return result;
}

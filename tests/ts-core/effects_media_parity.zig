const std = @import("std");
pub fn equal(expected: anytype, actual: anytype) anyerror!void {
    const T = @TypeOf(expected);
    // Callback implementation addresses differ between compiled policies
    // and their native reference. Compare all widget data; the complete
    // driver snapshots and replay exercise the callback behavior.
    if (comptime @typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (comptime @typeInfo(Child) == .pointer and @typeInfo(@typeInfo(Child).pointer.child) == .@"fn") return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "compiled_scroll_policy")) continue;
            try equal(@field(expected, field.name), @field(actual, field.name));
        },
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try equal(value, actual.?);
        },
        .pointer => |info| if (info.size == .slice) {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |a, b| try equal(a, b);
        } else try std.testing.expectEqual(expected, actual),
        .array => for (expected, actual) |a, b| try equal(a, b),
        .@"union" => |info| if (info.tag_type != null) {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) {
                inline else => |value, tag| try equal(value, @field(actual, @tagName(tag))),
            }
        } else @compileError("untagged parity value"),
        .@"enum" => try std.testing.expectEqualStrings(@tagName(expected), @tagName(actual)),
        else => try std.testing.expectEqual(expected, actual),
    }
}

pub fn number(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("non-numeric parity value"),
    };
}

const sdk = @import("native_sdk");
pub const JournalBuffer = struct {
    bytes: std.Io.Writer.Allocating,
    pub fn init() JournalBuffer {
        return .{ .bytes = .init(std.testing.allocator) };
    }
    pub fn deinit(self: *JournalBuffer) void {
        self.bytes.deinit();
    }
    pub fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        try self.bytes.writer.writeAll(bytes);
    }
};
pub fn find(widget: *const sdk.canvas.Widget, name: []const u8) ?*const sdk.canvas.Widget {
    if (std.mem.eql(u8, widget.text, name) or std.mem.eql(u8, widget.semantics.label, name)) return widget;
    for (widget.children) |*child| if (find(child, name)) |found| return found;
    return null;
}
pub fn action(runtime: *sdk.Runtime, app: sdk.App, root: *const sdk.canvas.Widget, label: []const u8, name: []const u8, verb: []const u8) !void {
    const widget = find(root, name) orelse return error.WidgetNotFound;
    var command: [128]u8 = undefined;
    try runtime.dispatchAutomationCommand(app, try std.fmt.bufPrint(&command, "widget-action {s} {d} {s}", .{ label, widget.id, verb }));
}

//! Owned boundary to compiled schema intake. JSON syntax and exact native
//! integer decoding remain native capabilities; schema policy is TypeScript.
const std = @import("std");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_contract_intake([*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) void;

pub const Result = struct {
    normalized: []const u8,
    diagnostics: []const struct { path: []const u8, message: []const u8, severity: enum { @"error", warning } },
};
fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: contract intake trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}
pub fn evaluate(arena: std.mem.Allocator, canonical: []const u8, mode: []const u8) error{OutOfMemory}!Result {
    return call(Result, arena, canonical, mode);
}
pub fn call(comptime T: type, arena: std.mem.Allocator, input: []const u8, mode: []const u8) error{OutOfMemory}!T {
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_contract_intake(input.ptr, input.len, mode.ptr, mode.len, &ptr, &len);
    return std.json.parseFromSliceLeaky(T, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled contract intake result"),
    };
}

pub const IntegerFact = struct { literal: []const u8, value: []const u8, @"error": []const u8 };
/// Probe exact conversion for scalar tokens without choosing schema fields.
/// TypeScript decides which facts a schema actually consumes, and in order.
pub fn integerFacts(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const IntegerFact {
    var scanner = std.json.Scanner.initCompleteInput(arena, source);
    defer scanner.deinit();
    var facts: std.ArrayList(IntegerFact) = .empty;
    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_always) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic("corewire: syntax changed after validation"),
        };
        const literal: []const u8 = switch (token) {
            .end_of_document => break,
            inline .number, .allocated_number => |text| text,
            inline .string, .allocated_string => |text| try std.json.Stringify.valueAlloc(arena, text, .{}),
            else => continue,
        };
        var fact: IntegerFact = .{ .literal = literal, .value = "", .@"error" = "" };
        const value = std.json.parseFromSliceLeaky(i64, arena, literal, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            fact.@"error" = @errorName(err);
            try facts.append(arena, fact);
            continue;
        };
        fact.value = try std.fmt.allocPrint(arena, "{d}", .{value});
        try facts.append(arena, fact);
    }
    return facts.toOwnedSlice(arena);
}

test "normalized contracts and nested diagnostics survive alternating collect and init" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const source = @import("sidecar.zig").minimal_valid_json;
    const good = try evaluate(arena, source, "core");
    const bad = try evaluate(arena, "{\"format\":0,\"new_fact\":true}", "core");
    const normalized = try arena.dupe(u8, good.normalized);
    const path = try arena.dupe(u8, bad.diagnostics[1].path);
    const message = try arena.dupe(u8, bad.diagnostics[1].message);
    for (0..6) |_| {
        _ = try evaluate(arena, source, "core");
        _ = try evaluate(arena, "null", "core");
        try std.testing.expectEqualStrings(normalized, good.normalized);
        try std.testing.expectEqualStrings(path, bad.diagnostics[1].path);
        try std.testing.expectEqualStrings(message, bad.diagnostics[1].message);
    }
}

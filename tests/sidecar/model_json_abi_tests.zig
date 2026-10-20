//! Model JSON fidelity over a REAL compiled core: after every committed
//! cycle, the core's own `native_model_json` rendering is byte-identical
//! to `std.json` over the mirror's decoded model with byte strings as
//! arrays (the shape the test protocol reports). The fixture's model
//! reaches every value family the writer spells: exact integers at the
//! +-(2^53 - 1) extremes, plain and optional; every f64 special (signed
//! zeros, infinities, both NaN signs, the smallest subnormal, the
//! positional/exponent switch points, the largest finite value);
//! non-UTF-8 and escape-worthy bytes; every enum member; every union arm
//! family; optional records and unions; and slices of records.

const std = @import("std");
const core = @import("model_json_core");

const testing = std.testing;
const max_exact = 9007199254740991; // 2^53 - 1

const Shape = @FieldType(core.Msg, "shape_set");
const Point = @FieldType(core.Msg, "point_set");

/// The JSON `std.json` gives the decoded committed model, the reference
/// every compiled rendering must equal byte for byte.
fn referenceJson(arena: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, core.snapshotModel().*, .{ .emit_strings_as_arrays = true });
}

fn expectFidelity(arena: std.mem.Allocator, step: usize) ![]const u8 {
    const expected = try referenceJson(arena);
    const actual = try arena.dupe(u8, core.modelJson());
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("model JSON diverges at step {d}\n", .{step});
        return err;
    };
    // The rendering is a pure read: asking twice in one cycle agrees.
    try testing.expectEqualStrings(actual, core.modelJson());
    return actual;
}

fn dispatch(model: *const core.Model, msg: core.Msg) *const core.Model {
    const next = core.commitModelRoot(core.update(model, msg));
    core.rt.frameReset();
    return next;
}

const floats = [_]f64{
    0.0,
    -0.0,
    std.math.inf(f64),
    -std.math.inf(f64),
    std.math.nan(f64),
    -std.math.nan(f64),
    5e-324,
    std.math.floatMin(f64),
    1e-7,
    1e-6,
    0.000025,
    0.1,
    1.5,
    -1234.5678,
    4.35,
    9007199254740993.0,
    999999999999999900000.0,
    1e21,
    123456789012345680000.0,
    1e300,
    std.math.floatMax(f64),
    -std.math.floatMax(f64),
};

test "the core's model JSON equals std.json over the decoded model every cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    core.rt.resetAll();
    defer core.rt.resetAll();
    var model = core.commitModelRoot(core.initialModel());
    core.rt.frameReset();
    try testing.expectEqualStrings(
        \\{"count":0,"maybeCount":null,"ratio":0,"samples":[],"bytes":[],"flag":false,"mode":"idle","shape":{"empty":{}},"maybeShape":null,"maybePoint":null,"tags":[]}
    , try expectFidelity(arena, 0));

    var script: std.ArrayList(core.Msg) = .empty;
    for ([_]i64{ max_exact, -max_exact, -1, 0, 1 }) |value| try script.append(arena, .{ .count_set = value });
    try script.append(arena, .count_clear);
    for (floats) |value| try script.append(arena, .{ .ratio_set = value });
    try script.append(arena, .{ .bytes_set = &.{ 0, 255, 128, '"', '\\', '\n', 200, 'a' } });
    try script.append(arena, .{ .flag_set = true });
    for (std.enums.values(@FieldType(core.Msg, "mode_set"))) |mode| try script.append(arena, .{ .mode_set = mode });
    const shapes = [_]Shape{
        .{ .box = .{ .width = 2.5, .height = -0.0 } },
        .{ .dot = .{ .x = 1e21, .y = 0.1 } },
        .{ .named = &.{ 0xff, 0xfe, 'x' } },
        .{ .moded = .busy },
        .{ .nested = .on },
        .{ .nested = .{ .off = &.{ 0, 'q' } } },
        .{ .sized = std.math.inf(f64) },
        .{ .ranked = -max_exact },
        .{ .ranked = max_exact },
        .{ .flagged = true },
        .empty,
    };
    for (shapes) |shape| try script.append(arena, .{ .shape_set = shape });
    try script.append(arena, .{ .shape_set = .{ .moded = .done } });
    try script.append(arena, .{ .point_set = .{ .x = -0.0, .y = 5e-324 } });
    try script.append(arena, .{ .tag_add = .{ .weight = max_exact, .label = &.{ 0xc3, 0x28 } } });
    try script.append(arena, .{ .tag_add = .{ .weight = -max_exact, .label = "" } });
    try script.append(arena, .{ .count_set = 42 });

    for (script.items, 1..) |msg, step| {
        model = dispatch(model, msg);
        _ = try expectFidelity(arena, step);
    }

    // The final state pins the spellings the reference produces, so a
    // writer and a reference that drifted together still fail here.
    const final = try expectFidelity(arena, script.items.len + 1);
    try testing.expectEqualStrings(
        \\{"count":42,"maybeCount":42,"ratio":-179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000,"samples":[{"value":0},{"value":-0},{"value":inf},{"value":-inf},{"value":"nan"},{"value":"-nan"},{"value":0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005},{"value":0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022250738585072014},{"value":0.0000001},{"value":0.000001},{"value":0.000025},{"value":0.1},{"value":1.5},{"value":-1234.5678},{"value":4.35},{"value":9007199254740992},{"value":999999999999999900000},{"value":1000000000000000000000},{"value":123456789012345680000},{"value":1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000},{"value":179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000},{"value":-179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000}],"bytes":[0,255,128,34,92,10,200,97],"flag":true,"mode":"done","shape":{"moded":"done"},"maybeShape":{"moded":"done"},"maybePoint":{"x":-0,"y":0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005},"tags":[{"label":[195,40],"weight":9007199254740991},{"label":[],"weight":-9007199254740991}]}
    , final);
}

test "a refreshed boot renders the initial model again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    core.rt.resetAll();
    defer core.rt.resetAll();
    var model = core.commitModelRoot(core.initialModel());
    core.rt.frameReset();
    const boot = try arena.dupe(u8, try expectFidelity(arena, 0));
    model = dispatch(model, .{ .shape_set = .{ .nested = .{ .off = "why" } } });
    _ = try expectFidelity(arena, 1);
    core.rt.resetAll();
    model = core.commitModelRoot(core.initialModel());
    core.rt.frameReset();
    try testing.expectEqualStrings(boot, try expectFidelity(arena, 2));
}

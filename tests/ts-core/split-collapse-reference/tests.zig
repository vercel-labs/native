//! split-collapse tests: the manual tween's model math (easing endpoints,
//! frame ticks, completion) — the runtime-tween coverage lives with the
//! runtime's own layout-animation tests.

const std = @import("std");
const main = @import("main.zig");
const testing = std.testing;

const Model = main.Model;

test "manual tween eases the fraction from expanded to collapsed and completes" {
    var model = main.initModel(true);
    try testing.expectEqual(main.expanded_fraction, model.fraction);

    main.update(&model, .toggle);
    try testing.expect(model.collapsed);
    try testing.expect(model.tween != null);

    // First tick stamps the start; fraction still at the origin.
    main.update(&model, .{ .frame_tick = 1_000_000_000 });
    try testing.expectEqual(main.expanded_fraction, model.fraction);

    // Halfway: strictly between the endpoints.
    main.update(&model, .{ .frame_tick = 1_000_000_000 + 90_000_000 });
    try testing.expect(model.fraction < main.expanded_fraction);
    try testing.expect(model.fraction > main.collapsed_fraction);

    // Past the duration: snapped to the target, tween cleared.
    main.update(&model, .{ .frame_tick = 1_000_000_000 + 200_000_000 });
    try testing.expectEqual(main.collapsed_fraction, model.fraction);
    try testing.expect(model.tween == null);
}

test "runtime mode flips only the resting flag; the tween hook declares the target" {
    var model = main.initModel(false);
    main.update(&model, .toggle);
    // The model's fraction is the controlled `value` (last echo), not
    // the target — the runtime moves it; no manual tween ever opens.
    try testing.expectEqual(main.expanded_fraction, model.fraction);
    try testing.expect(model.collapsed);
    try testing.expect(model.tween == null);

    // The echo path is the only writer of the fraction in runtime mode.
    main.update(&model, .{ .split_resized = 0.21 });
    try testing.expectEqual(@as(f32, 0.21), model.fraction);
}

test "markup mode derives the split's declared resting fraction from the collapsed flag" {
    // The markup view binds value="{pane_fraction}" with resize-duration,
    // so flipping the flag IS the collapse: the declared value moves to
    // the target and the runtime tween eases the rendered fraction there.
    var model = main.initModel(false);
    try testing.expectEqual(main.expanded_fraction, model.pane_fraction());
    main.update(&model, .toggle);
    try testing.expectEqual(main.collapsed_fraction, model.pane_fraction());
    main.update(&model, .toggle);
    try testing.expectEqual(main.expanded_fraction, model.pane_fraction());
}

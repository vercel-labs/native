const std = @import("std");
const native_sdk = @import("native_sdk");

/// Apply the state-store lookup result at the one layer that can distinguish
/// an actual restore from a fresh launch with persistence merely enabled.
pub fn applySavedWindow(window: *native_sdk.WindowOptions, saved: ?native_sdk.WindowState) bool {
    const state = saved orelse return false;
    window.default_frame = state.frame;
    window.initial_placement = .restored;
    return true;
}

test "fresh default-restoring window keeps default placement on a store miss" {
    var window: native_sdk.WindowOptions = .{ .restore_state = true };
    try std.testing.expect(!applySavedWindow(&window, null));
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.default, window.initial_placement);
}

test "fresh explicitly positioned window keeps explicit placement on a store miss" {
    var window: native_sdk.WindowOptions = .{ .initial_placement = .explicit };
    try std.testing.expect(!applySavedWindow(&window, null));
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.explicit, window.initial_placement);
}

test "state-store hit replaces the frame and marks it restored" {
    var window: native_sdk.WindowOptions = .{ .initial_placement = .explicit };
    const frame = native_sdk.geometry.RectF.init(40, 60, 900, 640);
    try std.testing.expect(applySavedWindow(&window, .{ .frame = frame }));
    try std.testing.expectEqual(frame, window.default_frame);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.restored, window.initial_placement);
}

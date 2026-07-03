test {
    _ = @import("canvas_widget_semantics_tests.zig");
    _ = @import("canvas_widget_floating_tests.zig");
    _ = @import("canvas_widget_scroll_tests.zig");
    _ = @import("canvas_widget_scroll_driver_tests.zig");
    _ = @import("canvas_widget_context_menu_tests.zig");
    _ = @import("canvas_widget_text_tests.zig");
    _ = @import("canvas_widget_clipboard_tests.zig");
    _ = @import("canvas_widget_control_tests.zig");
    _ = @import("canvas_widget_accessibility_tests.zig");
}

test "the automation snapshot widget cap tracks the per-view node budget" {
    // `automation.snapshot` cannot import the runtime's canvas_limits, so
    // its per-view widget cap is a mirrored literal; if they drift,
    // snapshots silently truncate widget enumeration below the budget.
    const std = @import("std");
    const canvas_limits = @import("canvas_limits.zig");
    const automation = @import("../automation/root.zig");
    try std.testing.expectEqual(canvas_limits.max_canvas_widget_nodes_per_view, automation.snapshot.max_widgets_per_view);
}

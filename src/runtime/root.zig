const std = @import("std");
const core = @import("core.zig");

pub const max_canvas_commands_per_view = core.max_canvas_commands_per_view;
pub const max_canvas_gradient_stops_per_view = core.max_canvas_gradient_stops_per_view;
pub const max_canvas_path_elements_per_view = core.max_canvas_path_elements_per_view;
pub const max_canvas_glyphs_per_view = core.max_canvas_glyphs_per_view;
pub const max_canvas_text_bytes_per_view = core.max_canvas_text_bytes_per_view;
pub const max_canvas_widget_nodes_per_view = core.max_canvas_widget_nodes_per_view;
pub const max_canvas_widget_semantics_per_view = core.max_canvas_widget_semantics_per_view;
pub const max_canvas_widget_text_bytes_per_view = core.max_canvas_widget_text_bytes_per_view;

pub const LifecycleEvent = core.LifecycleEvent;
pub const CommandEvent = core.CommandEvent;
pub const Command = core.Command;
pub const CommandSource = core.CommandSource;
pub const ShortcutEvent = core.ShortcutEvent;
pub const Appearance = core.Appearance;
pub const GpuFrame = core.GpuFrame;
pub const GpuSurfaceFrameEvent = core.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = core.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = core.GpuSurfaceInputEvent;
pub const CanvasWidgetPointerEvent = core.CanvasWidgetPointerEvent;
pub const CanvasWidgetKeyboardEvent = core.CanvasWidgetKeyboardEvent;
pub const CanvasWidgetDisplayListChrome = core.CanvasWidgetDisplayListChrome;
pub const CanvasPresentationMode = core.CanvasPresentationMode;
pub const CanvasPresentationResult = core.CanvasPresentationResult;
pub const CanvasWidgetAccessibilityActionKind = core.CanvasWidgetAccessibilityActionKind;
pub const CanvasWidgetAccessibilityAction = core.CanvasWidgetAccessibilityAction;
pub const CanvasWidgetFileDropEvent = core.CanvasWidgetFileDropEvent;
pub const CanvasWidgetDragEvent = core.CanvasWidgetDragEvent;
pub const InvalidationReason = core.InvalidationReason;
pub const FrameDiagnostics = core.FrameDiagnostics;
pub const Event = core.Event;
pub const App = core.App;
pub const Options = core.Options;
pub const Runtime = core.Runtime;
pub const TestHarness = core.TestHarness;
pub const UiApp = @import("ui_app.zig").UiApp;
pub const testing = core.testing;
pub const canvasSurfacePixelSize = core.canvasSurfacePixelSize;
pub const canvasFramePixelSize = core.canvasFramePixelSize;
pub const CanvasPixelSize = core.CanvasPixelSize;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}

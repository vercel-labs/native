//! The menu-bar lifecycle loop through the REAL dispatch paths: the
//! status item installs with the declared rows, each tray selection
//! dispatches its command through `on_command`, and the Open/Quit rows
//! land on the real window verbs (`fx.showWindow` / `fx.quitApp`) whose
//! requests the effects mirror pins. The hide half of the loop
//! (`close_policy = .hide`) is a host behavior the runtime suites cover
//! end to end; here the declaration itself is pinned so the example
//! never silently loses the pattern.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const PlayerApp = native_sdk.UiApp(Model, Msg);

fn createApp() !*PlayerApp {
    const app_state = try testing.allocator.create(PlayerApp);
    app_state.* = PlayerApp.init(std.heap.page_allocator, .{}, main.options());
    return app_state;
}

fn startedHarness(app_state: *PlayerApp) !*native_sdk.TestHarness() {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(420, 260) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(420, 260),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

test "the scene declares the hide-on-close main window (the menu-bar shape)" {
    // The declaration IS the pattern: close hides, the app keeps
    // running. app.zon threads the same declaration to the host create;
    // the scene mirror pinned here keeps the two from drifting.
    try testing.expectEqual(native_sdk.app_manifest.WindowClosePolicy.hide, main.shell_scene.windows[0].close_policy);
    try testing.expectEqualStrings(main.window_label, main.shell_scene.windows[0].label);
}

test "the status item installs with the Open/transport/Quit rows" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);

    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqual(@as(usize, main.status_items.len), harness.null_platform.trayItems().len);
    try testing.expectEqualStrings("MB", harness.null_platform.lastTrayTitle());
}

test "tray Open dispatches the showWindow verb and tray Quit the graceful terminate" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    // Hermetic verbs: the fake executor records every request in the
    // window-action mirror instead of reaching the OS.
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // "Open Player" (id 1): tray selection -> command name ->
    // on_command -> .open_player -> fx.showWindow(window label).
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 1 });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().show_count);
    try testing.expectEqualStrings(main.window_label, app_state.effects.windowActionState().lastLabel());

    // "Quit" (id 4): the same path landing on fx.quitApp — the real
    // graceful terminate request.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 4 });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().quit_count);

    // The host's shutdown echo runs the exactly-once stop hook, the
    // same event a last-window close emits.
    try harness.stop(app);
}

test "the transport rows drive playback without touching the window verbs" {
    const app_state = try createApp();
    defer testing.allocator.destroy(app_state);
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // "Play/Pause" (id 2) toggles; the model-driven status title
    // re-applies so the menu bar shows the transport state even while
    // the window is hidden.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 2 });
    try testing.expect(app_state.model.playing);
    try testing.expectEqualStrings("MB \u{25B6}", harness.null_platform.lastTrayTitle());

    // "Next Track" (id 3) advances.
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = 3 });
    try testing.expectEqual(@as(usize, 1), app_state.model.track);

    // Neither transport row rode the window-action seam.
    try testing.expectEqual(@as(u32, 0), app_state.effects.windowActionState().show_count);
    try testing.expectEqual(@as(u32, 0), app_state.effects.windowActionState().quit_count);
}

test "the player view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{ .playing = true };
    var ui = main.PlayerUi.init(arena);
    const tree = try ui.finalize(main.view(&ui, &model));

    var nodes: [128]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 420, 260), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(findByText(tree.root, .button, "Pause") != null);
    try testing.expect(findByText(tree.root, .button, "Next") != null);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

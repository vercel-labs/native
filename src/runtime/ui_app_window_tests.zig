//! Model-declared secondary windows through the REAL dispatch paths: a
//! TEA app whose `windows_fn` declares a settings window while the
//! model's flag is set — opened by a Msg, reconciled into a live
//! platform window, installed by its own gpu frame, driven by
//! automation widget verbs addressed at its canvas label, closed by a
//! Msg (reconcile) and by the user (the `on_close` Msg the model owns),
//! and reopened under the same label.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const support = @import("test_support.zig");

const canvas_label = "panel-canvas";
const settings_canvas_label = "settings-canvas";
const settings_window_label = "settings";

const PanelModel = struct {
    settings_open: bool = false,
    bumps: u32 = 0,
    user_closes: u32 = 0,
};

const PanelMsg = union(enum) {
    toggle_settings,
    bump,
    settings_closed,
};

const PanelApp = ui_app_model.UiApp(PanelModel, PanelMsg);

fn panelUpdate(model: *PanelModel, msg: PanelMsg) void {
    switch (msg) {
        .toggle_settings => model.settings_open = !model.settings_open,
        .bump => model.bumps += 1,
        .settings_closed => {
            model.settings_open = false;
            model.user_closes += 1;
        },
    }
}

fn panelView(ui: *PanelApp.Ui, model: *const PanelModel) PanelApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.button(.{ .on_press = .toggle_settings }, "Settings"),
        ui.text(.{}, ui.fmt("bumps {d}", .{model.bumps})),
    });
}

fn panelWindows(model: *const PanelModel, scratch: *PanelApp.WindowsScratch) []const PanelApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Settings",
            .width = 320,
            .height = 240,
            .min_width = 280,
            .min_height = 200,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn panelWindowView(ui: *PanelApp.Ui, model: *const PanelModel, window_label: []const u8) PanelApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.button(.{ .on_press = .bump }, "Bump"),
        ui.text(.{}, ui.fmt("bumped {d}", .{model.bumps})),
    });
}

const panel_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const panel_windows_scene = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Panel",
    .width = 400,
    .height = 300,
    .views = &panel_views,
}};
const panel_scene: app_manifest.ShellConfig = .{ .windows = &panel_windows_scene };

const Fixture = struct {
    harness: *core.TestHarness(),
    app_state: *PanelApp,
    app: core.App,

    fn create() !Fixture {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try PanelApp.create(std.heap.page_allocator, .{
            .name = "ui-app-panel",
            .scene = panel_scene,
            .canvas_label = canvas_label,
            .update = panelUpdate,
            .view = panelView,
            .windows_fn = panelWindows,
            .window_view = panelWindowView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: Fixture) void {
        self.app_state.destroy();
        self.harness.destroy(std.testing.allocator);
    }

    fn settingsWindowInfo(self: Fixture) ?support.platform.WindowInfo {
        var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
        for (self.harness.runtime.listWindows(&buffer)) |info| {
            if (std.mem.eql(u8, info.label, settings_window_label)) return info;
        }
        return null;
    }

    /// Toggle the settings flag through the REAL main-canvas press path.
    fn clickSettingsButton(self: Fixture) !void {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        const id = widgetIdByText(layout, .button, "Settings") orelse return error.TestUnexpectedResult;
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    /// Deliver the settings window's installing gpu frame.
    fn installSettingsCanvas(self: Fixture, window_id: support.platform.WindowId) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .window_id = window_id,
            .label = settings_canvas_label,
            .size = geometry.SizeF.init(320, 240),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 2_000_000,
            .nonblank = true,
        } });
    }
};

fn widgetIdByText(layout: canvas.WidgetLayoutTree, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    for (layout.nodes) |node| {
        if (node.widget.kind == kind and std.mem.eql(u8, node.widget.text, text)) return node.widget.id;
    }
    return null;
}

test "a Msg declares the settings window, its canvas installs, and automation drives it by label" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try std.testing.expect(fixture.settingsWindowInfo() == null);

    // Open: the Msg flips the model flag; the reconcile after the
    // rebuild creates the declared window on the platform.
    try fixture.clickSettingsButton();
    try std.testing.expect(fixture.app_state.model.settings_open);
    const info = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    try std.testing.expect(info.open);
    try std.testing.expectEqualStrings("Settings", info.title);

    // The descriptor's min-size floor survives to the platform create
    // seam (the macOS host applies it as `contentMinSize`).
    {
        const null_platform = fixture.harness.null_platform;
        var found = false;
        for (null_platform.windows[0..null_platform.window_count], 0..) |window, index| {
            if (window.id != info.id) continue;
            try std.testing.expectEqual(@as(f32, 280), null_platform.window_min_width[index]);
            try std.testing.expectEqual(@as(f32, 200), null_platform.window_min_height[index]);
            found = true;
        }
        try std.testing.expect(found);
    }

    // The window's own first frame installs its tree.
    try fixture.installSettingsCanvas(info.id);
    const layout = try fixture.harness.runtime.canvasWidgetLayout(info.id, settings_canvas_label);
    const bump_id = widgetIdByText(layout, .button, "Bump") orelse return error.TestUnexpectedResult;

    // Automation widget verbs address the secondary canvas by label —
    // the same verbs, no window argument.
    var buffer: [96]u8 = undefined;
    const bump_click = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ settings_canvas_label, bump_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, bump_click);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.bumps);

    // The Msg's rebuild refreshed the SECONDARY window's tree too: the
    // count text in the settings canvas reflects the new model.
    const rebuilt = try fixture.harness.runtime.canvasWidgetLayout(info.id, settings_canvas_label);
    try std.testing.expect(widgetIdByText(rebuilt, .text, "bumped 1") != null);

    // The automation snapshot enumerates both windows.
    const snapshot = fixture.harness.runtime.automationSnapshot("panel");
    try std.testing.expectEqual(@as(usize, 2), snapshot.windows.len);

    // Close: the model stops declaring it; the reconcile closes the
    // platform window and NO on_close Msg fires (the model already
    // knows).
    try fixture.clickSettingsButton();
    try std.testing.expect(!fixture.app_state.model.settings_open);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.user_closes);
    const closed = fixture.settingsWindowInfo();
    try std.testing.expect(closed == null or !closed.?.open);

    // Reopen under the SAME label: the closed slot released it.
    try fixture.clickSettingsButton();
    try std.testing.expect(fixture.app_state.model.settings_open);
    const reopened = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    try std.testing.expect(reopened.open);
}

test "a user close dispatches on_close and the model owns the consequence" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.clickSettingsButton();
    const info = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    try fixture.installSettingsCanvas(info.id);

    // The user clicks the close button: the fake host tears the window
    // out of its records (as the real delegates do) and reports it
    // gone. The runtime tears down its views and the app maps it to the
    // descriptor's on_close Msg — the model clears its flag, so the
    // reconcile after that dispatch does NOT resurrect the window.
    const close_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, close_event);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.user_closes);
    try std.testing.expect(!fixture.app_state.model.settings_open);
    const closed = fixture.settingsWindowInfo();
    try std.testing.expect(closed == null or !closed.?.open);

    // A second close event for the already-closed window is a no-op:
    // the transition fired exactly once.
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, close_event);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.user_closes);
}

test "a model that keeps declaring the window vetoes the user close (source wins)" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Point the close Msg at something that does NOT clear the flag:
    // the model keeps declaring the window, so the rebuild after the
    // on_close dispatch re-creates it — the dismissal precedent's
    // "deliberately re-open on the next rebuild".
    fixture.app_state.model.settings_open = true;
    try fixture.app_state.dispatch(&fixture.harness.runtime, 1, .bump);
    const info = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;

    // Swap the slot's close Msg for a non-clearing one, then close as
    // the user.
    for (fixture.app_state.window_slots[0..fixture.app_state.window_slot_count]) |*slot| {
        slot.on_close = .bump;
    }
    const close_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, close_event);
    // The on_close Msg dispatched (bump), the model still declares the
    // window, and the reconcile brought it back under the same label.
    try std.testing.expect(fixture.app_state.model.bumps >= 1);
    try std.testing.expect(fixture.app_state.model.settings_open);
    const reopened = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    try std.testing.expect(reopened.open);
}

test "input from the secondary window dispatches through its own tree with its window identity" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.clickSettingsButton();
    const info = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    try fixture.installSettingsCanvas(info.id);

    // A raw pointer click at the Bump button's frame in the settings
    // canvas: the full gpu_surface_input path, not the automation verb.
    const layout = try fixture.harness.runtime.canvasWidgetLayout(info.id, settings_canvas_label);
    const bump_id = widgetIdByText(layout, .button, "Bump") orelse return error.TestUnexpectedResult;
    const frame = layout.findById(bump_id).?.frame.center();
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .window_id = info.id,
        .label = settings_canvas_label,
        .kind = .pointer_down,
        .x = frame.x,
        .y = frame.y,
    } });
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .window_id = info.id,
        .label = settings_canvas_label,
        .kind = .pointer_up,
        .x = frame.x,
        .y = frame.y,
    } });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.bumps);
}

test "each window's tokens carry its own surface density, not the main canvas's" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // Static tokens make this the strict case: ordinary slot rebuilds
    // skip the redundant emission, so every re-stamped stored copy below
    // proves the stale-scale re-emit fired for THAT window.
    var static_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .light });
    static_tokens.pixel_snap = .{ .geometry = true, .text = true };
    const app_state = try PanelApp.create(std.heap.page_allocator, .{
        .name = "ui-app-panel-density",
        .scene = panel_scene,
        .canvas_label = canvas_label,
        .tokens = static_tokens,
        .update = panelUpdate,
        .view = panelView,
        .windows_fn = panelWindows,
        .window_view = panelWindowView,
    });
    defer app_state.destroy();
    const app = app_state.app();
    try harness.start(app);

    // Main canvas installs on a 1x monitor; the model already declares
    // the settings window, so the installing rebuild creates it.
    app_state.model.settings_open = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var settings_id: support.platform.WindowId = 0;
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, settings_window_label)) settings_id = info.id;
    }
    try std.testing.expect(settings_id != 0);

    // The settings window installs on a 2x monitor: ITS stored tokens
    // carry 2 while the main canvas keeps 1 — the scale is per-window
    // state, the appearance is still the app's single set.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = settings_id,
        .label = settings_canvas_label,
        .size = geometry.SizeF.init(320, 240),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });
    const main_stored = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 1), main_stored.pixel_snap.scale);
    var slot_stored = try harness.runtime.canvasWidgetDesignTokens(settings_id, settings_canvas_label);
    try std.testing.expectEqual(@as(f32, 2), slot_stored.pixel_snap.scale);
    try std.testing.expectEqualDeep(static_tokens.colors.background, slot_stored.colors.background);

    // Dragging the SECONDARY window to a 1x monitor re-stamps only its
    // own tokens. The model is poked directly (no dispatch) so the
    // refreshed slot text proves the frame triggered the slot rebuild.
    app_state.model.bumps = 3;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = settings_id,
        .label = settings_canvas_label,
        .size = geometry.SizeF.init(320, 240),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 3_000_000,
        .nonblank = true,
    } });
    const rebuilt = try harness.runtime.canvasWidgetLayout(settings_id, settings_canvas_label);
    try std.testing.expect(widgetIdByText(rebuilt, .text, "bumped 3") != null);
    slot_stored = try harness.runtime.canvasWidgetDesignTokens(settings_id, settings_canvas_label);
    try std.testing.expectEqual(@as(f32, 1), slot_stored.pixel_snap.scale);

    // A density-carrying RESIZE (the DPI-change channel on hosts that
    // rescale the frame in place) re-stamps the slot's tokens too, even
    // at an unchanged logical size.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{
        .window_id = settings_id,
        .label = settings_canvas_label,
        .frame = geometry.RectF.init(0, 0, 320, 240),
        .scale_factor = 2,
    } });
    slot_stored = try harness.runtime.canvasWidgetDesignTokens(settings_id, settings_canvas_label);
    try std.testing.expectEqual(@as(f32, 2), slot_stored.pixel_snap.scale);
    const main_after = try harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expectEqual(@as(f32, 1), main_after.pixel_snap.scale);
}

// ------------------------------------------------- window-action effects

const VerbModel = struct {
    settings_open: bool = true,
};

const VerbMsg = union(enum) {
    minimize_settings,
    minimize_main,
    close_settings,
    settings_closed,
};

const VerbApp = ui_app_model.UiApp(VerbModel, VerbMsg);

fn verbUpdate(model: *VerbModel, msg: VerbMsg, fx: *VerbApp.Effects) void {
    switch (msg) {
        .minimize_settings => fx.minimizeWindow(settings_window_label),
        .minimize_main => fx.minimizeWindow("main"),
        // The imperative close, for the seam test — a real app's
        // model-declared window usually closes declaratively instead.
        .close_settings => fx.closeWindow(settings_window_label),
        .settings_closed => model.settings_open = false,
    }
}

fn verbView(ui: *VerbApp.Ui, model: *const VerbModel) VerbApp.Ui.Node {
    _ = model;
    return ui.text(.{}, "main");
}

fn verbWindows(model: *const VerbModel, scratch: *VerbApp.WindowsScratch) []const VerbApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Settings",
            .width = 320,
            .height = 240,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn verbWindowView(ui: *VerbApp.Ui, model: *const VerbModel, window_label: []const u8) VerbApp.Ui.Node {
    _ = model;
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));
    return ui.text(.{}, "settings");
}

test "window-action effects resolve labels to live windows and drive the real verbs" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try VerbApp.create(std.heap.page_allocator, .{
        .name = "ui-app-window-verbs",
        .scene = panel_scene,
        .canvas_label = canvas_label,
        .update_fx = verbUpdate,
        .view = verbView,
        .windows_fn = verbWindows,
        .window_view = verbWindowView,
    });
    defer app_state.destroy();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    // Real hosts report the startup window they created; the runtime
    // adopts it into its window table (id 1, the app's "main" label) —
    // the entry the label-addressed window actions resolve against.
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "Panel",
        .frame = geometry.RectF.init(0, 0, 400, 300),
        .scale_factor = 2,
        .open = true,
        .focused = true,
    } });

    // The settings window is declared open from boot.
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var settings_id: support.platform.WindowId = 0;
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, settings_window_label)) settings_id = info.id;
    }
    try std.testing.expect(settings_id != 0);

    // Minimize by label reaches the platform's minimize verb for a
    // window the platform owns (the model-declared secondary was
    // created through the create-window service). A minimized window
    // stays OPEN.
    try app_state.dispatch(&harness.runtime, 1, .minimize_settings);
    try std.testing.expectEqual(@as(u32, 1), harness.null_platform.minimizeCountForWindow(settings_id));
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (info.id == settings_id) try std.testing.expect(info.open);
    }

    // The main window resolves by label too (the runtime adopted the
    // host-reported startup window above). The fake host never created
    // a native window for it — live hosts own the startup window — so
    // the pinned observable is the resolved request riding the channel:
    // no error, and the mirror counts both minimizes.
    try app_state.dispatch(&harness.runtime, 1, .minimize_main);
    try std.testing.expectEqual(@as(u32, 2), app_state.effects.windowActionState().minimize_count);

    // Close by label performs the runtime's REAL close (the platform's
    // close verb runs and the runtime bookkeeping flips with it). The
    // model still declares this window, so the reconcile's source-wins
    // rule may re-create it on the next rebuild — which is exactly why
    // model-declared windows should close DECLARATIVELY instead (the
    // deck example does); the imperative seam exists for the main
    // window and windows the model does not own.
    try app_state.dispatch(&harness.runtime, 1, .close_settings);
    try std.testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().close_count);

    // Labels resolve at call time against the LIVE window set, so the
    // main window still answers after the secondary's churn.
    try app_state.dispatch(&harness.runtime, 1, .minimize_main);
    try std.testing.expectEqual(@as(u32, 3), app_state.effects.windowActionState().minimize_count);
}

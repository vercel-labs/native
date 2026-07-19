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

// ------------------- window-control clearance in secondary windows

const CaptionWinModel = struct {
    settings_open: bool = true,
    /// The padded variant appends the contract spacer (the soundboard
    /// pattern) so its header already clears the caption cluster.
    padded: bool = false,
};

const CaptionWinMsg = union(enum) {
    settings_closed,
};

const CaptionWinApp = ui_app_model.UiApp(CaptionWinModel, CaptionWinMsg);

fn captionWinUpdate(model: *CaptionWinModel, msg: CaptionWinMsg) void {
    switch (msg) {
        .settings_closed => model.settings_open = false,
    }
}

fn captionWinView(ui: *CaptionWinApp.Ui, model: *const CaptionWinModel) CaptionWinApp.Ui.Node {
    _ = model;
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, "main body"),
    });
}

fn captionWinWindows(model: *const CaptionWinModel, scratch: *CaptionWinApp.WindowsScratch) []const CaptionWinApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            .canvas_label = settings_canvas_label,
            .title = "Tools",
            .width = 320,
            .height = 240,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

/// A hidden-inset SECONDARY window's titlebar: a drag row with a
/// leading title and a right-aligned status text — the same
/// system-monitor shape the main-canvas caption tests use, but built
/// through `window_view` and `rebuildWindowSlot`.
fn captionWinWindowView(ui: *CaptionWinApp.Ui, model: *const CaptionWinModel, window_label: []const u8) CaptionWinApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));
    if (model.padded) {
        return ui.column(.{}, .{
            ui.row(.{ .window_drag = true, .height = 40 }, .{
                ui.text(.{}, "Tools"),
                ui.el(.stack, .{ .grow = 1 }, .{}),
                ui.text(.{}, "recording"),
                ui.el(.stack, .{ .width = 138 }, .{}),
            }),
            ui.text(.{}, "body"),
        });
    }
    return ui.column(.{}, .{
        ui.row(.{ .window_drag = true, .height = 40 }, .{
            ui.text(.{}, "Tools"),
            ui.el(.stack, .{ .grow = 1 }, .{}),
            ui.text(.{}, "recording"),
        }),
        ui.text(.{}, "body"),
    });
}

const CaptionWinFixture = struct {
    harness: *core.TestHarness(),
    app_state: *CaptionWinApp,
    app: core.App,
    settings_id: support.platform.WindowId,

    /// Start the app with Windows-shaped hidden-titlebar chrome (the
    /// DWM caption cluster overlays the trailing 138pt of the 320pt
    /// secondary window's top band) and install both canvases.
    fn create(padded: bool) !CaptionWinFixture {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.window_chrome = .{
            .insets = .{ .top = 32, .right = 138 },
            .buttons = geometry.RectF.init(182, 0, 138, 32),
        };
        const app_state = try CaptionWinApp.create(std.heap.page_allocator, .{
            .name = "ui-app-caption-window",
            .scene = panel_scene,
            .canvas_label = canvas_label,
            .update = captionWinUpdate,
            .view = captionWinView,
            .windows_fn = captionWinWindows,
            .window_view = captionWinWindowView,
        });
        errdefer app_state.destroy();
        app_state.model.padded = padded;
        const app = app_state.app();
        try harness.start(app);
        // The model declares the settings window from the start, so the
        // main canvas's installing rebuild creates it.
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
        if (settings_id == 0) return error.TestUnexpectedResult;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .window_id = settings_id,
            .label = settings_canvas_label,
            .size = geometry.SizeF.init(320, 240),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 2_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app, .settings_id = settings_id };
    }

    fn destroy(self: CaptionWinFixture) void {
        self.app_state.destroy();
        self.harness.destroy(std.testing.allocator);
    }

    fn textFrame(self: CaptionWinFixture, window_id: support.platform.WindowId, label: []const u8, text: []const u8) !geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(window_id, label);
        for (layout.nodes) |node| {
            if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, text)) return node.frame;
        }
        return error.TestUnexpectedResult;
    }
};

test "a secondary window's drag header content stays clear of the Windows caption cluster" {
    // The naive shape: the window view never consumed the chrome
    // channel, so its right-aligned status would lay out flush to the
    // window edge — UNDER the min/max/close buttons. `rebuildWindowSlot`
    // must run the same collision scan + one-retry clearance the main
    // rebuild runs, with the cluster stamped into the SLOT's tokens.
    const fixture = try CaptionWinFixture.create(false);
    defer fixture.destroy();

    // The trailing status text ends at (or before) the cluster's
    // leading edge (182 = 320 - 138); without the reservation it ended
    // at the window's right edge, inside the cluster.
    const status = try fixture.textFrame(fixture.settings_id, settings_canvas_label, "recording");
    try std.testing.expect(status.maxX() <= 182 + 0.01);
    // The leading title and the body below the band are untouched.
    const title = try fixture.textFrame(fixture.settings_id, settings_canvas_label, "Tools");
    try std.testing.expectEqual(@as(f32, 0), title.x);

    // The stamp lived in a LOCAL copy of the slot's tokens: the main
    // canvas (no drag header, no collision) keeps an unstamped stored
    // set and its own layout.
    const main_stored = try fixture.harness.runtime.canvasWidgetDesignTokens(1, canvas_label);
    try std.testing.expect(main_stored.window_controls == null);
    const main_body = try fixture.textFrame(1, canvas_label, "main body");
    try std.testing.expectEqual(@as(f32, 12), main_body.x);
}

test "a padded secondary drag header keeps its layout (no double reservation)" {
    // The contract shape: the header's own trailing spacer already
    // clears the cluster, so nothing collides and the slot retry must
    // NOT fire — a double reservation would shove the status text a
    // full cluster-width further left (near 182 - 138 = 44).
    const fixture = try CaptionWinFixture.create(true);
    defer fixture.destroy();

    const status = try fixture.textFrame(fixture.settings_id, settings_canvas_label, "recording");
    try std.testing.expect(@abs(status.maxX() - 182) < 0.5);
}

// ------------------------------------------------- window-action effects

const VerbModel = struct {
    settings_open: bool = true,
};

const VerbMsg = union(enum) {
    minimize_settings,
    minimize_main,
    close_settings,
    show_settings,
    quit,
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
        .show_settings => fx.showWindow(settings_window_label),
        .quit => fx.quitApp(),
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

    // Show by label is the counterpart verb: it reaches the platform's
    // show (the minimized window comes back with focus) and the mirror
    // counts it.
    try app_state.dispatch(&harness.runtime, 1, .show_settings);
    try std.testing.expectEqual(@as(u32, 1), harness.null_platform.showCountForWindow(settings_id));
    try std.testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().show_count);
    try std.testing.expectEqualStrings(settings_window_label, app_state.effects.windowActionState().lastLabel());

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

    // quitApp asks the platform for the graceful terminate (the modeled
    // host records the request; a real host QUEUES the stop so
    // app_shutdown emits on the next loop turn, after this dispatch
    // has returned) and the mirror counts it.
    try app_state.dispatch(&harness.runtime, 1, .quit);
    try std.testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().quit_count);
    try std.testing.expectEqual(@as(u32, 1), harness.null_platform.quit_request_count);
    // The host's queued shutdown echo delivers the exactly-once stop
    // hook — the same path a last-window close takes. Draining it here
    // IS the next loop turn, and it drains exactly once.
    const shutdown_event = harness.null_platform.takeQueuedQuit() orelse return error.TestUnexpectedResult;
    try std.testing.expect(harness.null_platform.takeQueuedQuit() == null);
    try harness.runtime.dispatchPlatformEvent(app, shutdown_event);
}

test "the .hide close then showWindow round-trip: tray Open brings the hidden window back" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try VerbApp.create(std.heap.page_allocator, .{
        .name = "ui-app-hide-show-loop",
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
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var settings_id: support.platform.WindowId = 0;
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, settings_window_label)) settings_id = info.id;
    }
    try std.testing.expect(settings_id != 0);

    // Give the live window the .hide policy at the platform (the seam a
    // manifest declaration rides) and close it as the user: hidden, not
    // gone.
    for (harness.null_platform.windows[0..harness.null_platform.window_count], 0..) |window, index| {
        if (window.id == settings_id) harness.null_platform.window_close_policy[index] = .hide;
    }
    const hide_event = harness.null_platform.userCloseWindow(settings_id).?;
    try harness.runtime.dispatchPlatformEvent(app, hide_event);
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (info.id == settings_id) try std.testing.expect(info.hidden);
    }

    // The tray "Open" consequence: the model returns the show verb, the
    // label resolves against the still-open hidden window, and the
    // platform + runtime state both flip back.
    try app_state.dispatch(&harness.runtime, 1, .show_settings);
    try std.testing.expectEqual(@as(u32, 1), harness.null_platform.showCountForWindow(settings_id));
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (info.id == settings_id) try std.testing.expect(!info.hidden);
    }
    for (harness.null_platform.windows[0..harness.null_platform.window_count]) |window| {
        if (window.id == settings_id) {
            try std.testing.expect(!window.hidden);
            try std.testing.expect(window.focused);
        }
    }
}

// ------------------------------------- close_policy (.quit | .hide)

test "close_policy .hide: the user close hides the window, nothing tears down, and the reopen re-shows it" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // A menu-bar-shaped window through the REAL create seam (the same
    // `ShellWindow` path a manifest-declared window rides): the
    // declared policy must survive to the platform.
    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });
    try std.testing.expectEqual(support.platform.WindowClosePolicy.hide, fixture.harness.null_platform.closePolicyForWindow(info.id).?);

    // The user clicks the red button: the modeled close delegate hides
    // instead of closing — the window stays in the host's records
    // (open = true), only the hidden flag flips, and because open never
    // transitioned, NO window_closed app event (and so no on_close Msg)
    // fires.
    const hide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try std.testing.expect(hide_event.window_frame_changed.open);
    try std.testing.expect(hide_event.window_frame_changed.hidden);
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, hide_event);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.user_closes);
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.open);
        try std.testing.expect(window.hidden);
    }

    // The Dock-icon reopen: every policy-hidden window re-shows and the
    // hidden flag clears through the same journaled frame channel.
    var reopen_buffer: [support.platform.max_windows]support.platform.Event = undefined;
    const reopen_events = fixture.harness.null_platform.userReopenApp(&reopen_buffer);
    try std.testing.expectEqual(@as(usize, 1), reopen_events.len);
    try std.testing.expect(!reopen_events[0].window_frame_changed.hidden);
    for (reopen_events) |event| try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, event);
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.open);
        try std.testing.expect(!window.hidden);
    }

    // A reopen with nothing hidden is honestly empty — the host's
    // default reopen behavior stays in charge.
    try std.testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.userReopenApp(&reopen_buffer).len);
}

test "an app-driven close of a policy-hidden window clears hidden with open, and rolls it back on platform failure" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // A menu-bar-shaped window through the REAL create seam, hidden by
    // its .hide close policy (the user clicked the red button).
    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });
    const hide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, hide_event);
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.open);
        try std.testing.expect(window.hidden);
    }

    // The platform refuses the close: EVERY optimistically flipped flag
    // rolls back — the window is still open, still policy-hidden.
    fixture.harness.null_platform.fail_next_close_window = true;
    try std.testing.expectError(error.CloseFailed, fixture.harness.runtime.closeWindow(info.id));
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.open);
        try std.testing.expect(window.hidden);
    }

    // The app closes its hidden window for real: a closed window is not
    // "hidden", it is gone — the runtime table (the JS bridge's window
    // list) must read {open=false, hidden=false}, never a closed window
    // still flying the hidden flag.
    try fixture.harness.runtime.closeWindow(info.id);
    var found = false;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        found = true;
        try std.testing.expect(!window.open);
        try std.testing.expect(!window.hidden);
        try std.testing.expect(!window.focused);
    }
    try std.testing.expect(found);
}

test "showWindow activates: the shown window takes key in the runtime table, and a refused show moves nothing" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // A policy-hidden window (the user's close under .hide).
    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });
    const hide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, hide_event);

    // The show verb's contract is show AND activate — every host's show
    // path makes the window key. After a successful platform show, the
    // runtime table (what listWindows and the JS bridge serve) must
    // read the shown window focused and every other window unfocused,
    // not a frontmost window still reported keyless.
    try fixture.harness.runtime.showWindow(info.id);
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var found = false;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id == info.id) {
            found = true;
            try std.testing.expect(!window.hidden);
            try std.testing.expect(window.focused);
        } else {
            try std.testing.expect(!window.focused);
        }
    }
    try std.testing.expect(found);

    // Hide again, then refuse the show at the platform: hidden rolls
    // back and focus does not move — a refused show must never report
    // a focused window that never came back to the glass.
    const rehide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, rehide_event);
    fixture.harness.null_platform.fail_next_show_window = true;
    try std.testing.expectError(error.ShowFailed, fixture.harness.runtime.showWindow(info.id));
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.hidden);
        try std.testing.expect(!window.focused);
    }
}

test "the window verbs refuse a retained closed slot: show, focus, and minimize answer WindowNotFound with no platform call" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // A closed window keeps its table slot (the id and label release
    // lazily, at the next create), so resolving the id is not liveness.
    // Without the open gate the null platform accepts the verbs and
    // reports {open:false, focused:true}, and the CEF host — which
    // retains browser-bearing windows past their close — would visibly
    // re-order the closed window onto the glass. The runtime gate holds
    // independent of host timing.
    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });
    try fixture.harness.runtime.closeWindow(info.id);

    // show: the dead-slot answer, and the platform recorder never moves.
    try std.testing.expectError(error.WindowNotFound, fixture.harness.runtime.showWindow(info.id));
    try std.testing.expectEqual(@as(u32, 0), fixture.harness.null_platform.showCountForWindow(info.id));

    // focus resolves by id too, and close cleared `hidden` with `open`,
    // so without its own gate it skips the hidden-routing and reaches
    // the platform's focus verb directly.
    try std.testing.expectError(error.WindowNotFound, fixture.harness.runtime.focusWindow(info.id));
    try std.testing.expectEqual(@as(u32, 0), fixture.harness.null_platform.showCountForWindow(info.id));

    // The minimize twin (the CEF host would genie the retained closed
    // window into the Dock).
    try std.testing.expectError(error.WindowNotFound, fixture.harness.runtime.minimizeWindow(info.id));
    try std.testing.expectEqual(@as(u32, 0), fixture.harness.null_platform.minimizeCountForWindow(info.id));

    // Nothing resurrected: the runtime table and the platform mirror
    // both still read the window closed, unfocused, un-hidden.
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var found = false;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        found = true;
        try std.testing.expect(!window.open);
        try std.testing.expect(!window.focused);
        try std.testing.expect(!window.hidden);
    }
    try std.testing.expect(found);
    for (fixture.harness.null_platform.windows[0..fixture.harness.null_platform.window_count]) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(!window.open);
        try std.testing.expect(!window.focused);
    }
}

test "the modeled host mirrors the app close of a hidden window, and the reopen never resurrects a closed one" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // A menu-bar-shaped window, policy-hidden by the user's close.
    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });
    const hide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, hide_event);

    // The app closes the hidden window through the runtime. The modeled
    // host's mirror must read closed AND un-hidden — the same
    // hidden-clears-with-open rule the real hosts' close paths carry
    // (set cleanup before the open=false emit) and the runtime table
    // already pins for its own flags.
    try fixture.harness.runtime.closeWindow(info.id);
    for (fixture.harness.null_platform.windows[0..fixture.harness.null_platform.window_count]) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(!window.open);
        try std.testing.expect(!window.hidden);
        try std.testing.expect(!window.focused);
    }

    // The Dock reopen after the close: NO frame event for the closed
    // window — nothing hidden-and-open remains to re-show.
    var reopen_buffer: [support.platform.max_windows]support.platform.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.userReopenApp(&reopen_buffer).len);

    // The reopen's liveness check must hold on its own, not lean on the
    // close mirror's hidden clear: model a host whose close path forgot
    // that cleanup by forcing the stale flag onto the closed slot — the
    // reopen still refuses to resurrect (hidden alone is not liveness).
    for (fixture.harness.null_platform.windows[0..fixture.harness.null_platform.window_count]) |*window| {
        if (window.id == info.id) window.hidden = true;
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.userReopenApp(&reopen_buffer).len);

    // No events dispatched, so the runtime table is untouched: the
    // window stays closed, un-hidden, never re-focused.
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    var found = false;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        found = true;
        try std.testing.expect(!window.open);
        try std.testing.expect(!window.hidden);
        try std.testing.expect(!window.focused);
    }
    try std.testing.expect(found);
}

test "focus-while-hidden routes through the show verb: hidden clears before the window takes key" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const info = try fixture.harness.runtime.createSourcelessShellWindow(.{
        .label = "player",
        .title = "Player",
        .width = 400,
        .height = 300,
        .close_policy = .hide,
    });

    // The user close hides the window (policy .hide) and the runtime
    // adopts the hidden state off the journaled frame channel.
    const hide_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, hide_event);
    var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id == info.id) try std.testing.expect(window.hidden);
    }

    // Focusing the hidden window must drive the platform's SHOW verb
    // (the path that clears the hosts' policy-hidden bookkeeping and
    // emits consistent state), not just its focus verb: the hidden
    // flag clears, focus lands, and the show count pins the routing —
    // a focusWindow that skips the show seam leaves this count at 0
    // and the window reported hidden while standing on the glass.
    try fixture.harness.runtime.focusWindow(info.id);
    try std.testing.expectEqual(@as(u32, 1), fixture.harness.null_platform.showCountForWindow(info.id));
    for (fixture.harness.runtime.listWindows(&buffer)) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(window.open);
        try std.testing.expect(!window.hidden);
        try std.testing.expect(window.focused);
    }
    // The platform mirror agrees on both flags.
    for (fixture.harness.null_platform.windows[0..fixture.harness.null_platform.window_count]) |window| {
        if (window.id != info.id) continue;
        try std.testing.expect(!window.hidden);
        try std.testing.expect(window.focused);
    }

    // A visible window's focus stays a plain focus: no second show.
    try fixture.harness.runtime.focusWindow(info.id);
    try std.testing.expectEqual(@as(u32, 1), fixture.harness.null_platform.showCountForWindow(info.id));
}

test "close_policy default stays .quit: the user close still tears the window down" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.clickSettingsButton();
    const info = fixture.settingsWindowInfo() orelse return error.TestUnexpectedResult;
    // No declaration means .quit: the capture proves the default rode
    // the create seam unchanged.
    try std.testing.expectEqual(support.platform.WindowClosePolicy.quit, fixture.harness.null_platform.closePolicyForWindow(info.id).?);
    const close_event = fixture.harness.null_platform.userCloseWindow(info.id).?;
    try std.testing.expect(!close_event.window_frame_changed.open);
    try std.testing.expect(!close_event.window_frame_changed.hidden);
}

test "close_policy .hide is refused loudly at create on hosts without the affordance" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    // Model a GTK-shaped host: no status item, no way to bring a
    // hidden window back — the feature reports false and window create
    // refuses the declaration instead of stranding the window.
    harness.null_platform.window_hide_on_close = false;
    try std.testing.expectError(error.UnsupportedWindowClosePolicy, harness.runtime.createSourcelessShellWindow(.{
        .label = "tools",
        .title = "Tools",
        .width = 320,
        .height = 240,
        .close_policy = .hide,
    }));
    // The same shape under .quit (the default) creates fine.
    const info = try harness.runtime.createSourcelessShellWindow(.{
        .label = "tools",
        .title = "Tools",
        .width = 320,
        .height = 240,
    });
    try std.testing.expect(info.open);
}

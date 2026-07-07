const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const automation = @import("../automation/root.zig");
const types = @import("types.zig");
const conversions = @import("conversions.zig");

const max_mobile_command_name_bytes = types.max_mobile_command_name_bytes;
const max_mobile_input_text_bytes = types.max_mobile_input_text_bytes;
const max_mobile_asset_root_bytes = types.max_mobile_asset_root_bytes;
const max_mobile_asset_entry_bytes = types.max_mobile_asset_entry_bytes;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const mobileTouchKindFromPhase = conversions.mobileTouchKindFromPhase;
const mobileKeyKindFromPhase = conversions.mobileKeyKindFromPhase;
const mobileImeKindFromInt = conversions.mobileImeKindFromInt;
const mobileModifiersFromMask = conversions.mobileModifiersFromMask;
const copyInputText = conversions.copyInputText;
const nowNanoseconds = conversions.nowNanoseconds;

/// Host-owned storage for the shim's registered text-measure callback.
/// The canvas `TextMeasureProvider` carries a pointer to this struct as
/// its context, so the field must live on the (heap-allocated) host for
/// the runtime's lifetime.
pub const MobileTextMeasure = struct {
    measure: ?types.MobileTextMeasureFn = null,
    context: ?*anyopaque = null,
};

/// Bridges the C-ABI measure callback into the canvas provider seam. A
/// negative return (including a cleared callback) falls back to the
/// deterministic estimator inside `TextMeasureProvider.measureWidth`.
fn mobileMeasureText(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    const store: *const MobileTextMeasure = @ptrCast(@alignCast(context.?));
    const measure = store.measure orelse return -1;
    return @floatCast(measure(store.context, font_id, size, text.ptr, text.len));
}

/// Install (or clear, with a null callback) the platform text measurement
/// on the embedded runtime — the mobile counterpart of the desktop
/// platforms' `measure_text_fn` service, threaded into layout the same
/// way (`Runtime.tokensWithTextMeasure` stamps it into design tokens on
/// every rebuild). Register it before `native_sdk_app_start` so the
/// installing layout already uses real metrics; later changes apply on
/// the next rebuild.
///
/// Retained display-list commands carry the provider *pointer*, so once
/// the runtime's provider is installed it must stay in place for the
/// runtime's lifetime (the same invariant desktop platforms keep by
/// capturing it at init). Clearing therefore only nulls the callback
/// inside the host's bridge storage; the bridge then reports "no
/// measurement" and every consumer falls back to the deterministic
/// estimator.
pub fn setTextMeasure(self: anytype, measure: ?types.MobileTextMeasureFn, context: ?*anyopaque) void {
    self.text_measure = .{ .measure = measure, .context = context };
    if (measure != null and self.embedded.runtime.text_measure_provider == null) {
        self.embedded.runtime.text_measure_provider = .{
            .context = &self.text_measure,
            .measure_fn = mobileMeasureText,
        };
    }
}

pub const EmbeddedApp = struct {
    app: runtime.App,
    runtime: runtime.Runtime,

    pub fn init(app: runtime.App, platform_value: platform.Platform) EmbeddedApp {
        var embedded: EmbeddedApp = undefined;
        embedded.initInPlace(app, platform_value);
        return embedded;
    }

    pub fn initInPlace(self: *EmbeddedApp, app: runtime.App, platform_value: platform.Platform) void {
        self.app = app;
        runtime.Runtime.initAt(&self.runtime, .{ .platform = platform_value });
    }

    pub fn start(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_start);
    }

    pub fn activate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_activated);
    }

    pub fn deactivate(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_deactivated);
    }

    pub fn resize(self: *EmbeddedApp, surface: platform.Surface) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .surface_resized = surface });
        if (surface.native_handle != null) {
            try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_resized = .{
                .window_id = 1,
                .label = mobile_gpu_surface_label,
                .frame = geometry.RectF.fromSize(surface.size),
                .scale_factor = surface.scale_factor,
            } });
        }
    }

    pub fn touch(self: *EmbeddedApp, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileTouchKindFromPhase(phase),
            .timestamp_ns = nowNanoseconds(),
            .pointer_id = id,
            .x = x,
            .y = y,
            .button = 0,
            .pressure = pressure,
        } });
    }

    pub fn scroll(self: *EmbeddedApp, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = .scroll,
            .timestamp_ns = nowNanoseconds(),
            .pointer_id = id,
            .x = x,
            .y = y,
            .delta_x = delta_x,
            .delta_y = delta_y,
        } });
    }

    pub fn key(self: *EmbeddedApp, phase: c_int, key_value: []const u8, text_value: []const u8, modifiers_mask: u32) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileKeyKindFromPhase(phase),
            .timestamp_ns = nowNanoseconds(),
            .key = key_value,
            .text = text_value,
            .modifiers = mobileModifiersFromMask(modifiers_mask),
        } });
    }

    pub fn text(self: *EmbeddedApp, text_value: []const u8) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = .text_input,
            .timestamp_ns = nowNanoseconds(),
            .text = text_value,
        } });
    }

    pub fn ime(self: *EmbeddedApp, kind: c_int, text_value: []const u8, cursor: isize) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = mobile_gpu_surface_label,
            .kind = try mobileImeKindFromInt(kind),
            .timestamp_ns = nowNanoseconds(),
            .text = text_value,
            .composition_cursor = if (cursor >= 0) @intCast(cursor) else null,
        } });
    }

    pub fn frame(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .frame_requested);
    }

    pub fn command(self: *EmbeddedApp, name: []const u8) anyerror!void {
        try self.runtime.dispatchCommand(self.app, .{
            .name = name,
            .source = .native_view,
            .window_id = 1,
            .view_label = "mobile-header",
        });
    }

    pub fn widgetSemantics(self: *const EmbeddedApp) anyerror![]const canvas.WidgetSemanticsNode {
        return self.runtime.canvasWidgetSemantics(1, mobile_gpu_surface_label);
    }

    pub fn gpuFrameState(self: *const EmbeddedApp) anyerror!platform.GpuFrame {
        return self.runtime.gpuSurfaceFrame(1, mobile_gpu_surface_label);
    }

    pub fn widgetTextGeometry(self: *const EmbeddedApp, id: canvas.ObjectId) anyerror!canvas.WidgetTextGeometry {
        return self.runtime.canvasWidgetTextGeometry(1, mobile_gpu_surface_label, id);
    }

    pub fn widgetAction(self: *EmbeddedApp, action: runtime.CanvasWidgetAccessibilityAction) anyerror!void {
        _ = try self.runtime.dispatchCanvasWidgetAccessibilityAction(self.app, 1, mobile_gpu_surface_label, action);
    }

    /// Focus / IME-intent state for the mobile surface: reads the live
    /// pointer/keyboard focus (`canvas_widget_focused_id`, the same state
    /// desktop hosts key their IME activation on) rather than the
    /// source-declared semantics `focused` flag, and reports whether the
    /// focused widget accepts text edits right now.
    pub fn textInputState(self: *const EmbeddedApp) types.MobileTextInputState {
        var state = types.MobileTextInputState{};
        for (self.runtime.views[0..self.runtime.view_count]) |*view| {
            if (!view.open or view.window_id != 1 or view.kind != .gpu_surface) continue;
            if (!std.mem.eql(u8, view.label, mobile_gpu_surface_label)) continue;
            if (!view.focused or view.canvas_widget_focused_id == 0) return state;
            state.widget_id = view.canvas_widget_focused_id;
            for (view.widgetSemantics()) |node| {
                if (node.id != state.widget_id) continue;
                state.x = node.bounds.x;
                state.y = node.bounds.y;
                state.width = node.bounds.width;
                state.height = node.bounds.height;
                break;
            }
            if (view.canEditCanvasWidgetText(state.widget_id)) state.active = 1;
            return state;
        }
        return state;
    }

    pub fn stop(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_shutdown);
    }
};

pub const MobileHostApp = struct {
    null_platform: platform.NullPlatform,
    embedded: EmbeddedApp,
    last_error: ?anyerror = null,
    activation_count: usize = 0,
    deactivation_count: usize = 0,
    command_count: usize = 0,
    mobile_surface_resize_count: usize = 0,
    mobile_surface_width: f32 = 0,
    mobile_surface_height: f32 = 0,
    mobile_surface_scale: f32 = 1,
    input_count: usize = 0,
    touch_count: usize = 0,
    last_touch_id: u64 = 0,
    last_touch_kind: platform.GpuSurfaceInputKind = .pointer_up,
    last_touch_timestamp_ns: u64 = 0,
    last_touch_x: f32 = 0,
    last_touch_y: f32 = 0,
    last_touch_delta_x: f32 = 0,
    last_touch_delta_y: f32 = 0,
    last_touch_pressure: f32 = 0,
    last_input_kind: platform.GpuSurfaceInputKind = .pointer_up,
    last_input_timestamp_ns: u64 = 0,
    last_input_key: [max_mobile_input_text_bytes]u8 = undefined,
    last_input_key_len: usize = 0,
    last_input_text: [max_mobile_input_text_bytes]u8 = undefined,
    last_input_text_len: usize = 0,
    last_input_composition_cursor: ?usize = null,
    last_input_modifiers: platform.ShortcutModifiers = .{},
    asset_root: [max_mobile_asset_root_bytes]u8 = undefined,
    asset_root_len: usize = 0,
    asset_entry: [max_mobile_asset_entry_bytes]u8 = undefined,
    asset_entry_len: usize = 0,
    automation_dir: [max_mobile_asset_root_bytes]u8 = undefined,
    automation_dir_len: usize = 0,
    automation_io: ?*std.Io.Threaded = null,
    text_measure: MobileTextMeasure = .{},
    last_command_name: [max_mobile_command_name_bytes + 1]u8 = [_]u8{0} ** (max_mobile_command_name_bytes + 1),

    pub fn create() !*MobileHostApp {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(MobileHostApp);
        errdefer allocator.destroy(self);
        self.null_platform = platform.NullPlatform.init(.{});
        self.last_error = null;
        self.activation_count = 0;
        self.deactivation_count = 0;
        self.command_count = 0;
        self.mobile_surface_resize_count = 0;
        self.mobile_surface_width = 0;
        self.mobile_surface_height = 0;
        self.mobile_surface_scale = 1;
        self.input_count = 0;
        self.touch_count = 0;
        self.last_touch_id = 0;
        self.last_touch_kind = .pointer_up;
        self.last_touch_timestamp_ns = 0;
        self.last_touch_x = 0;
        self.last_touch_y = 0;
        self.last_touch_delta_x = 0;
        self.last_touch_delta_y = 0;
        self.last_touch_pressure = 0;
        self.last_input_kind = .pointer_up;
        self.last_input_timestamp_ns = 0;
        self.last_input_key = undefined;
        self.last_input_key_len = 0;
        self.last_input_text = undefined;
        self.last_input_text_len = 0;
        self.last_input_composition_cursor = null;
        self.last_input_modifiers = .{};
        self.asset_root = undefined;
        self.asset_root_len = 0;
        self.asset_entry = undefined;
        self.asset_entry_len = 0;
        self.automation_dir = undefined;
        self.automation_dir_len = 0;
        self.automation_io = null;
        self.text_measure = .{};
        self.last_command_name = [_]u8{0} ** (max_mobile_command_name_bytes + 1);
        self.embedded.initInPlace(.{
            .context = self,
            .name = "native-sdk-mobile",
            .source_fn = mobileSource,
            .event_fn = handleEvent,
        }, self.null_platform.platform());
        return self;
    }

    pub fn destroy(self: *MobileHostApp) void {
        disableAutomation(self);
        std.heap.page_allocator.destroy(self);
    }

    pub fn start(self: *MobileHostApp) anyerror!void {
        try self.embedded.start();
    }

    pub fn frame(self: *MobileHostApp) anyerror!void {
        try self.embedded.frame();
    }

    fn source(self: *MobileHostApp) platform.WebViewSource {
        if (self.asset_root_len > 0) {
            return platform.WebViewSource.assets(.{
                .root_path = self.asset_root[0..self.asset_root_len],
                .entry = if (self.asset_entry_len > 0) self.asset_entry[0..self.asset_entry_len] else "index.html",
                .origin = "zero://app",
                .spa_fallback = true,
            });
        }
        return platform.WebViewSource.html(mobile_html);
    }

    fn handleEvent(context: *anyopaque, runtime_value: *runtime.Runtime, event: runtime.Event) anyerror!void {
        _ = runtime_value;
        const self: *MobileHostApp = @ptrCast(@alignCast(context));
        switch (event) {
            .lifecycle => |lifecycle| switch (lifecycle) {
                .activate => self.activation_count += 1,
                .deactivate => self.deactivation_count += 1,
                else => {},
            },
            .command => |command_event| {
                self.command_count += 1;
                const count = @min(command_event.name.len, max_mobile_command_name_bytes);
                @memcpy(self.last_command_name[0..count], command_event.name[0..count]);
                self.last_command_name[count] = 0;
            },
            .gpu_surface_resized => |resize| {
                if (!std.mem.eql(u8, resize.label, mobile_gpu_surface_label)) return;
                self.mobile_surface_resize_count += 1;
                self.mobile_surface_width = resize.frame.width;
                self.mobile_surface_height = resize.frame.height;
                self.mobile_surface_scale = resize.scale_factor;
            },
            .gpu_surface_input => |input| {
                if (!std.mem.eql(u8, input.label, mobile_gpu_surface_label)) return;
                self.input_count += 1;
                self.last_input_kind = input.kind;
                self.last_input_timestamp_ns = input.timestamp_ns;
                self.last_input_key_len = copyInputText(&self.last_input_key, input.key);
                self.last_input_text_len = copyInputText(&self.last_input_text, input.text);
                self.last_input_composition_cursor = input.composition_cursor;
                self.last_input_modifiers = input.modifiers;
                switch (input.kind) {
                    .pointer_down, .pointer_up, .pointer_cancel, .pointer_move, .pointer_drag, .scroll => {
                        self.touch_count += 1;
                        self.last_touch_id = input.pointer_id;
                        self.last_touch_kind = input.kind;
                        self.last_touch_timestamp_ns = input.timestamp_ns;
                        self.last_touch_x = input.x;
                        self.last_touch_y = input.y;
                        self.last_touch_delta_x = input.delta_x;
                        self.last_touch_delta_y = input.delta_y;
                        self.last_touch_pressure = input.pressure;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

fn mobileSource(context: *anyopaque) anyerror!platform.WebViewSource {
    const self: *MobileHostApp = @ptrCast(@alignCast(context));
    return self.source();
}

pub const mobile_html =
    \\<!doctype html>
    \\<html>
    \\<body style="font-family: system-ui; padding: 2rem;">
    \\  <h1>native-sdk mobile</h1>
    \\  <p>This content is loaded through the native-sdk embedded C ABI.</p>
    \\</body>
    \\</html>
;

pub fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

pub fn recordError(self: anytype, err: anyerror) void {
    self.last_error = err;
}

/// Point the embedded runtime's automation server at `dir` (the desktop
/// equivalent is `-Dautomation=true` + `.zig-cache/native-sdk-automation`;
/// mobile shims pass an absolute path inside the app's data container).
/// The host-pumped frame loop then consumes the `command-<n>.txt` queue
/// and publishes `snapshot.txt` / `accessibility.txt` / `windows.txt`
/// exactly like the desktop runners.
pub fn enableAutomation(self: anytype, dir: []const u8) anyerror!void {
    if (dir.len == 0) return error.InvalidCommand;
    if (dir.len > self.automation_dir.len) return error.WindowSourceTooLarge;
    const allocator = std.heap.page_allocator;
    if (self.automation_io == null) {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        self.automation_io = threaded;
    }
    @memcpy(self.automation_dir[0..dir.len], dir);
    self.automation_dir_len = dir.len;
    self.embedded.runtime.options.automation = automation.Server.init(
        self.automation_io.?.io(),
        self.automation_dir[0..self.automation_dir_len],
        self.embedded.app.name,
    );
}

pub fn disableAutomation(self: anytype) void {
    self.embedded.runtime.options.automation = null;
    self.automation_dir_len = 0;
    if (self.automation_io) |threaded| {
        threaded.deinit();
        std.heap.page_allocator.destroy(threaded);
        self.automation_io = null;
    }
}

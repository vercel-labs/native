const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
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
        self.runtime = runtime.Runtime.init(.{ .platform = platform_value });
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
    last_command_name: [max_mobile_command_name_bytes + 1]u8 = [_]u8{0} ** (max_mobile_command_name_bytes + 1),

    pub fn create() !*MobileHostApp {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(MobileHostApp);
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
        self.last_command_name = [_]u8{0} ** (max_mobile_command_name_bytes + 1);
        self.embedded.initInPlace(.{
            .context = self,
            .name = "zero-native-mobile",
            .source_fn = mobileSource,
            .event_fn = handleEvent,
        }, self.null_platform.platform());
        return self;
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
    \\  <h1>zero-native mobile</h1>
    \\  <p>This content is loaded through the zero-native embedded C ABI.</p>
    \\</body>
    \\</html>
;

pub fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

pub fn recordError(self: *MobileHostApp, err: anyerror) void {
    self.last_error = err;
}

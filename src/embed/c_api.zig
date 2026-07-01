const std = @import("std");
const geometry = @import("geometry");
const types = @import("types.zig");
const host = @import("host.zig");
const conversions = @import("conversions.zig");

const MobileHostApp = host.MobileHostApp;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;
const mobileApp = host.mobileApp;
const recordError = host.recordError;
const mobileSurface = conversions.mobileSurface;
const mobileViewportStateFromSurface = conversions.mobileViewportStateFromSurface;
const mobileGpuFrameStateFromFrame = conversions.mobileGpuFrameStateFromFrame;
const inputSlice = conversions.inputSlice;
const mobileWidgetSemanticsFromNode = conversions.mobileWidgetSemanticsFromNode;
const mobileWidgetTextGeometryFromCanvas = conversions.mobileWidgetTextGeometryFromCanvas;
const mobileWidgetActionKindFromInt = conversions.mobileWidgetActionKindFromInt;

pub fn zero_native_app_create() ?*anyopaque {
    const self = MobileHostApp.create() catch return null;
    return self;
}

pub fn zero_native_app_destroy(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    std.heap.page_allocator.destroy(self);
}

pub fn zero_native_app_start(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.start() catch |err| recordError(self, err);
}

pub fn zero_native_app_activate(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.activate() catch |err| recordError(self, err);
}

pub fn zero_native_app_deactivate(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.deactivate() catch |err| recordError(self, err);
}

pub fn zero_native_app_stop(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.stop() catch |err| recordError(self, err);
}

pub fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.resize(mobileSurface(width, height, scale, surface, .{}, .{})) catch |err| recordError(self, err);
}

pub fn zero_native_app_viewport(
    app: ?*anyopaque,
    width: f32,
    height: f32,
    scale: f32,
    surface: ?*anyopaque,
    safe_top: f32,
    safe_right: f32,
    safe_bottom: f32,
    safe_left: f32,
    keyboard_top: f32,
    keyboard_right: f32,
    keyboard_bottom: f32,
    keyboard_left: f32,
) void {
    const self = mobileApp(app) orelse return;
    self.embedded.resize(mobileSurface(
        width,
        height,
        scale,
        surface,
        geometry.InsetsF.init(safe_top, safe_right, safe_bottom, safe_left),
        geometry.InsetsF.init(keyboard_top, keyboard_right, keyboard_bottom, keyboard_left),
    )) catch |err| recordError(self, err);
}

pub fn zero_native_app_viewport_state(app: ?*anyopaque, out: ?*MobileViewportState) c_int {
    const self = mobileApp(app) orelse return 0;
    const output = out orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    output.* = mobileViewportStateFromSurface(self.embedded.runtime.surface);
    self.last_error = null;
    return 1;
}

pub fn zero_native_app_gpu_frame_state(app: ?*anyopaque, out: ?*MobileGpuFrameState) c_int {
    const self = mobileApp(app) orelse return 0;
    const output = out orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    const frame = self.embedded.gpuFrameState() catch |err| {
        recordError(self, err);
        return 0;
    };
    output.* = mobileGpuFrameStateFromFrame(frame);
    self.last_error = null;
    return 1;
}

pub fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    const self = mobileApp(app) orelse return;
    self.embedded.touch(id, phase, x, y, pressure) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_scroll(app: ?*anyopaque, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) void {
    const self = mobileApp(app) orelse return;
    self.embedded.scroll(id, x, y, delta_x, delta_y) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_key(app: ?*anyopaque, phase: c_int, key: ?[*]const u8, key_len: usize, text: ?[*]const u8, text_len: usize, modifiers_mask: u32) void {
    const self = mobileApp(app) orelse return;
    const key_value = inputSlice(key, key_len) catch |err| {
        recordError(self, err);
        return;
    };
    const text_value = inputSlice(text, text_len) catch |err| {
        recordError(self, err);
        return;
    };
    self.embedded.key(phase, key_value, text_value, modifiers_mask) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_text(app: ?*anyopaque, text: ?[*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    const text_value = inputSlice(text, len) catch |err| {
        recordError(self, err);
        return;
    };
    self.embedded.text(text_value) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_ime(app: ?*anyopaque, kind: c_int, text: ?[*]const u8, len: usize, cursor: isize) void {
    const self = mobileApp(app) orelse return;
    const text_value = inputSlice(text, len) catch |err| {
        recordError(self, err);
        return;
    };
    self.embedded.ime(kind, text_value, cursor) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_command(app: ?*anyopaque, name: ?[*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    const ptr = name orelse {
        recordError(self, error.InvalidCommand);
        return;
    };
    self.embedded.command(ptr[0..len]) catch |err| {
        recordError(self, err);
        return;
    };
    self.last_error = null;
}

pub fn zero_native_app_frame(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.frame() catch |err| recordError(self, err);
}

pub fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    if (len > self.asset_root.len) {
        recordError(self, error.WindowSourceTooLarge);
        return;
    }
    if (len == 0) {
        self.asset_root_len = 0;
        self.last_error = null;
        return;
    }
    @memcpy(self.asset_root[0..len], path[0..len]);
    self.asset_root_len = len;
    self.last_error = null;
}

pub fn zero_native_app_set_asset_entry(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    const self = mobileApp(app) orelse return;
    if (len > self.asset_entry.len) {
        recordError(self, error.WindowSourceTooLarge);
        return;
    }
    if (len == 0) {
        self.asset_entry_len = 0;
        self.last_error = null;
        return;
    }
    @memcpy(self.asset_entry[0..len], path[0..len]);
    self.asset_entry_len = len;
    self.last_error = null;
}

pub fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    const self = mobileApp(app) orelse return 0;
    return self.command_count;
}

pub fn zero_native_app_last_command_name(app: ?*anyopaque) [*:0]const u8 {
    const self = mobileApp(app) orelse return "";
    return @ptrCast(&self.last_command_name);
}

pub fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    const self = mobileApp(app) orelse return "";
    const err = self.last_error orelse return "";
    return @errorName(err);
}

pub fn zero_native_app_widget_semantics_count(app: ?*anyopaque) usize {
    const self = mobileApp(app) orelse return 0;
    const semantics = self.embedded.widgetSemantics() catch return 0;
    return semantics.len;
}

pub fn zero_native_app_widget_semantics_at(app: ?*anyopaque, index: usize, out: ?*MobileWidgetSemantics) c_int {
    const self = mobileApp(app) orelse return 0;
    const output = out orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    const semantics = self.embedded.widgetSemantics() catch |err| {
        recordError(self, err);
        return 0;
    };
    if (index >= semantics.len) {
        recordError(self, error.InvalidCommand);
        return 0;
    }
    output.* = mobileWidgetSemanticsFromNode(semantics, index);
    self.last_error = null;
    return 1;
}

pub fn zero_native_app_widget_semantics_by_id(app: ?*anyopaque, id: u64, out: ?*MobileWidgetSemantics) c_int {
    const self = mobileApp(app) orelse return 0;
    const output = out orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    if (id == 0) {
        recordError(self, error.InvalidCommand);
        return 0;
    }
    const semantics = self.embedded.widgetSemantics() catch |err| {
        recordError(self, err);
        return 0;
    };
    for (semantics, 0..) |node, index| {
        if (node.id != id) continue;
        output.* = mobileWidgetSemanticsFromNode(semantics, index);
        self.last_error = null;
        return 1;
    }
    recordError(self, error.InvalidCommand);
    return 0;
}

pub fn zero_native_app_widget_text_geometry(app: ?*anyopaque, id: u64, out: ?*MobileWidgetTextGeometry) c_int {
    const self = mobileApp(app) orelse return 0;
    const output = out orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    if (id == 0) {
        recordError(self, error.InvalidCommand);
        return 0;
    }
    const geometry_value = self.embedded.widgetTextGeometry(id) catch |err| {
        recordError(self, err);
        return 0;
    };
    output.* = mobileWidgetTextGeometryFromCanvas(id, geometry_value);
    self.last_error = null;
    return 1;
}

pub fn zero_native_app_widget_action(app: ?*anyopaque, request: ?*const MobileWidgetActionRequest) c_int {
    const self = mobileApp(app) orelse return 0;
    const value = request orelse {
        recordError(self, error.InvalidCommand);
        return 0;
    };
    const kind = mobileWidgetActionKindFromInt(value.action) catch |err| {
        recordError(self, err);
        return 0;
    };
    const text_value = inputSlice(value.text, value.text_len) catch |err| {
        recordError(self, err);
        return 0;
    };
    if (kind == .set_selection and value.has_selection == 0) {
        recordError(self, error.InvalidCommand);
        return 0;
    }
    self.embedded.widgetAction(.{
        .id = value.id,
        .action = kind,
        .text = text_value,
        .selection = if (value.has_selection != 0) .{
            .anchor = value.selection_anchor,
            .focus = value.selection_focus,
        } else null,
    }) catch |err| {
        recordError(self, err);
        return 0;
    };
    self.last_error = null;
    return 1;
}

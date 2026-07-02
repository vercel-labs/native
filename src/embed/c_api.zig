//! The embed C ABI, generic over the host that answers it.
//!
//! `MobileCApi(Host)` produces the full `zero_native_app_*` function set
//! for a host type: the fixed WebView shell (`MobileHostApp`, this module's
//! re-exported default) or a user-app canvas host
//! (`ui_host.UiAppHost(AppDef)` in libs built via `addMobileLib`). A host
//! must expose `create`/`destroy`/`start`/`frame`, an `embedded`
//! `EmbeddedApp`, and the error/command/asset bookkeeping fields both
//! hosts share. `exportMobileCApi(Host)` exports every function under its
//! canonical symbol name for a static library root.

const std = @import("std");
const geometry = @import("geometry");
const types = @import("types.zig");
const host = @import("host.zig");
const conversions = @import("conversions.zig");

const MobileHostApp = host.MobileHostApp;
const MobileTextInputState = types.MobileTextInputState;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;
const MobileCanvasPixels = types.MobileCanvasPixels;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const recordError = host.recordError;
const mobileSurface = conversions.mobileSurface;
const mobileViewportStateFromSurface = conversions.mobileViewportStateFromSurface;
const mobileGpuFrameStateFromFrame = conversions.mobileGpuFrameStateFromFrame;
const inputSlice = conversions.inputSlice;
const mobileWidgetSemanticsFromNode = conversions.mobileWidgetSemanticsFromNode;
const mobileWidgetTextGeometryFromCanvas = conversions.mobileWidgetTextGeometryFromCanvas;
const mobileWidgetActionKindFromInt = conversions.mobileWidgetActionKindFromInt;

fn hostApp(comptime Host: type, raw: ?*anyopaque) ?*Host {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

/// Export every `MobileCApi(Host)` function under its own name. Call from
/// a `comptime` block in a static library's root module.
pub fn exportMobileCApi(comptime Host: type) void {
    const Api = MobileCApi(Host);
    inline for (@typeInfo(Api).@"struct".decls) |decl| {
        @export(&@field(Api, decl.name), .{ .name = decl.name });
    }
}

pub fn MobileCApi(comptime Host: type) type {
    return struct {
        pub fn zero_native_app_create() callconv(.c) ?*anyopaque {
            const self = Host.create() catch return null;
            return self;
        }

        pub fn zero_native_app_destroy(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.destroy();
        }

        pub fn zero_native_app_start(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.start() catch |err| recordError(self, err);
        }

        pub fn zero_native_app_activate(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.activate() catch |err| recordError(self, err);
        }

        pub fn zero_native_app_deactivate(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.deactivate() catch |err| recordError(self, err);
        }

        pub fn zero_native_app_stop(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.stop() catch |err| recordError(self, err);
        }

        pub fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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
        ) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.resize(mobileSurface(
                width,
                height,
                scale,
                surface,
                geometry.InsetsF.init(safe_top, safe_right, safe_bottom, safe_left),
                geometry.InsetsF.init(keyboard_top, keyboard_right, keyboard_bottom, keyboard_left),
            )) catch |err| recordError(self, err);
        }

        pub fn zero_native_app_viewport_state(app: ?*anyopaque, out: ?*MobileViewportState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            output.* = mobileViewportStateFromSurface(self.embedded.runtime.surface);
            self.last_error = null;
            return 1;
        }

        pub fn zero_native_app_gpu_frame_state(app: ?*anyopaque, out: ?*MobileGpuFrameState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
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

        /// Focus / IME-intent state after input dispatch: `out.active` is
        /// nonzero while an editable text widget owns focus. Platform shims
        /// key the system keyboard's show/hide on it (UIKit first
        /// responder, Android InputMethodManager).
        pub fn zero_native_app_text_input_state(app: ?*anyopaque, out: ?*MobileTextInputState) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            output.* = self.embedded.textInputState();
            self.last_error = null;
            return 1;
        }

        /// Enable the automation harness inside the embedded runtime,
        /// writing `snapshot.txt` (and consuming `command.txt`) under
        /// `path` — an absolute directory inside the app's data container
        /// on device. The mobile counterpart of the desktop runners'
        /// `-Dautomation=true`.
        pub fn zero_native_app_set_automation_dir(app: ?*anyopaque, path: ?[*]const u8, len: usize) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const dir = inputSlice(path, len) catch |err| {
                recordError(self, err);
                return 0;
            };
            host.enableAutomation(self, dir) catch |err| {
                recordError(self, err);
                return 0;
            };
            self.last_error = null;
            return 1;
        }

        pub fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.touch(id, phase, x, y, pressure) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn zero_native_app_scroll(app: ?*anyopaque, id: u64, x: f32, y: f32, delta_x: f32, delta_y: f32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.embedded.scroll(id, x, y, delta_x, delta_y) catch |err| {
                recordError(self, err);
                return;
            };
            self.last_error = null;
        }

        pub fn zero_native_app_key(app: ?*anyopaque, phase: c_int, key: ?[*]const u8, key_len: usize, text: ?[*]const u8, text_len: usize, modifiers_mask: u32) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_text(app: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_ime(app: ?*anyopaque, kind: c_int, text: ?[*]const u8, len: usize, cursor: isize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_command(app: ?*anyopaque, name: ?[*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_frame(app: ?*anyopaque) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
            self.frame() catch |err| recordError(self, err);
        }

        pub fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_set_asset_entry(app: ?*anyopaque, path: [*]const u8, len: usize) callconv(.c) void {
            const self = hostApp(Host, app) orelse return;
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

        pub fn zero_native_app_last_command_count(app: ?*anyopaque) callconv(.c) usize {
            const self = hostApp(Host, app) orelse return 0;
            return self.command_count;
        }

        pub fn zero_native_app_last_command_name(app: ?*anyopaque) callconv(.c) [*:0]const u8 {
            const self = hostApp(Host, app) orelse return "";
            return @ptrCast(&self.last_command_name);
        }

        pub fn zero_native_app_last_error_name(app: ?*anyopaque) callconv(.c) [*:0]const u8 {
            const self = hostApp(Host, app) orelse return "";
            const err = self.last_error orelse return "";
            return @errorName(err);
        }

        pub fn zero_native_app_widget_semantics_count(app: ?*anyopaque) callconv(.c) usize {
            const self = hostApp(Host, app) orelse return 0;
            const semantics = self.embedded.widgetSemantics() catch return 0;
            return semantics.len;
        }

        pub fn zero_native_app_widget_semantics_at(app: ?*anyopaque, index: usize, out: ?*MobileWidgetSemantics) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
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

        pub fn zero_native_app_widget_semantics_by_id(app: ?*anyopaque, id: u64, out: ?*MobileWidgetSemantics) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
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

        pub fn zero_native_app_widget_text_geometry(app: ?*anyopaque, id: u64, out: ?*MobileWidgetTextGeometry) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
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

        pub fn zero_native_app_widget_action(app: ?*anyopaque, request: ?*const MobileWidgetActionRequest) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
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

        pub fn zero_native_app_render_pixel_size(app: ?*anyopaque, scale: f32, out: ?*MobileCanvasPixels) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const size = self.embedded.runtime.canvasScreenshotPixelSize(1, mobile_gpu_surface_label, renderScale(scale)) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = .{ .width = size.width, .height = size.height, .byte_len = size.byte_len };
            self.last_error = null;
            return 1;
        }

        /// Render the mobile surface's retained canvas scene through the
        /// deterministic CPU reference renderer into the caller's RGBA8
        /// buffer (`zero_native_app_render_pixel_size` gives the byte
        /// length). `scale <= 0` renders at scale 1.
        pub fn zero_native_app_render_pixels(app: ?*anyopaque, scale: f32, pixels: ?[*]u8, pixels_len: usize, out: ?*MobileCanvasPixels) callconv(.c) c_int {
            const self = hostApp(Host, app) orelse return 0;
            const output = out orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const buffer_ptr = pixels orelse {
                recordError(self, error.InvalidCommand);
                return 0;
            };
            const allocator = std.heap.page_allocator;
            const scratch = allocator.alloc(u8, pixels_len) catch |err| {
                recordError(self, err);
                return 0;
            };
            defer allocator.free(scratch);
            const screenshot = self.embedded.runtime.renderCanvasScreenshot(
                1,
                mobile_gpu_surface_label,
                renderScale(scale),
                buffer_ptr[0..pixels_len],
                scratch,
            ) catch |err| {
                recordError(self, err);
                return 0;
            };
            output.* = .{
                .width = screenshot.width,
                .height = screenshot.height,
                .byte_len = screenshot.rgba8.len,
            };
            self.last_error = null;
            return 1;
        }
    };
}

fn renderScale(scale: f32) ?f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

/// The default fixed WebView shell ABI (the host `zig build lib` produces).
const FixedShellApi = MobileCApi(MobileHostApp);

pub const zero_native_app_create = FixedShellApi.zero_native_app_create;
pub const zero_native_app_destroy = FixedShellApi.zero_native_app_destroy;
pub const zero_native_app_start = FixedShellApi.zero_native_app_start;
pub const zero_native_app_activate = FixedShellApi.zero_native_app_activate;
pub const zero_native_app_deactivate = FixedShellApi.zero_native_app_deactivate;
pub const zero_native_app_stop = FixedShellApi.zero_native_app_stop;
pub const zero_native_app_resize = FixedShellApi.zero_native_app_resize;
pub const zero_native_app_viewport = FixedShellApi.zero_native_app_viewport;
pub const zero_native_app_viewport_state = FixedShellApi.zero_native_app_viewport_state;
pub const zero_native_app_gpu_frame_state = FixedShellApi.zero_native_app_gpu_frame_state;
pub const zero_native_app_text_input_state = FixedShellApi.zero_native_app_text_input_state;
pub const zero_native_app_set_automation_dir = FixedShellApi.zero_native_app_set_automation_dir;
pub const zero_native_app_touch = FixedShellApi.zero_native_app_touch;
pub const zero_native_app_scroll = FixedShellApi.zero_native_app_scroll;
pub const zero_native_app_key = FixedShellApi.zero_native_app_key;
pub const zero_native_app_text = FixedShellApi.zero_native_app_text;
pub const zero_native_app_ime = FixedShellApi.zero_native_app_ime;
pub const zero_native_app_command = FixedShellApi.zero_native_app_command;
pub const zero_native_app_frame = FixedShellApi.zero_native_app_frame;
pub const zero_native_app_set_asset_root = FixedShellApi.zero_native_app_set_asset_root;
pub const zero_native_app_set_asset_entry = FixedShellApi.zero_native_app_set_asset_entry;
pub const zero_native_app_last_command_count = FixedShellApi.zero_native_app_last_command_count;
pub const zero_native_app_last_command_name = FixedShellApi.zero_native_app_last_command_name;
pub const zero_native_app_last_error_name = FixedShellApi.zero_native_app_last_error_name;
pub const zero_native_app_widget_semantics_count = FixedShellApi.zero_native_app_widget_semantics_count;
pub const zero_native_app_widget_semantics_at = FixedShellApi.zero_native_app_widget_semantics_at;
pub const zero_native_app_widget_semantics_by_id = FixedShellApi.zero_native_app_widget_semantics_by_id;
pub const zero_native_app_widget_text_geometry = FixedShellApi.zero_native_app_widget_text_geometry;
pub const zero_native_app_widget_action = FixedShellApi.zero_native_app_widget_action;
pub const zero_native_app_render_pixel_size = FixedShellApi.zero_native_app_render_pixel_size;
pub const zero_native_app_render_pixels = FixedShellApi.zero_native_app_render_pixels;

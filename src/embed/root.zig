const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");

const max_mobile_command_name_bytes: usize = 128;
const max_mobile_input_text_bytes: usize = 512;
const max_mobile_asset_root_bytes: usize = platform.max_webview_url_bytes;
const max_mobile_asset_entry_bytes: usize = platform.max_window_source_bytes;
const mobile_gpu_surface_label = "mobile-surface";

pub const MobileWidgetRole = enum(c_int) {
    none = 0,
    group = 1,
    text = 2,
    image = 3,
    button = 4,
    textbox = 5,
    tooltip = 6,
    dialog = 7,
    menu = 8,
    menuitem = 9,
    list = 10,
    listitem = 11,
    row = 12,
    grid = 13,
    gridcell = 14,
    tab = 15,
    checkbox = 16,
    switch_control = 17,
    slider = 18,
    progressbar = 19,
};

pub const MobileWidgetFlag = enum(u32) {
    focused = 1 << 0,
    hovered = 1 << 1,
    pressed = 1 << 2,
    selected = 1 << 3,
    disabled = 1 << 4,
    focusable = 1 << 5,
};

pub const MobileWidgetAction = enum(u32) {
    focus = 1 << 0,
    press = 1 << 1,
    toggle = 1 << 2,
    increment = 1 << 3,
    decrement = 1 << 4,
    set_text = 1 << 5,
    set_selection = 1 << 6,
    select = 1 << 7,
    drag = 1 << 8,
    drop_files = 1 << 9,
};

pub const MobileWidgetActionKind = enum(c_int) {
    focus = 0,
    press = 1,
    toggle = 2,
    increment = 3,
    decrement = 4,
    set_text = 5,
    set_selection = 6,
    set_composition = 7,
    commit_composition = 8,
    cancel_composition = 9,
    select = 10,
    drag = 11,
    drop_files = 12,
};

pub const MobileWidgetSemantics = extern struct {
    id: u64 = 0,
    parent_id: u64 = 0,
    role: c_int = @intFromEnum(MobileWidgetRole.none),
    flags: u32 = 0,
    actions: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    value: f32 = 0,
    has_value: c_int = 0,
    label: ?[*]const u8 = null,
    label_len: usize = 0,
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    text_selection_start: isize = -1,
    text_selection_end: isize = -1,
    text_composition_start: isize = -1,
    text_composition_end: isize = -1,
    grid_row_index: isize = -1,
    grid_column_index: isize = -1,
    grid_row_count: isize = -1,
    grid_column_count: isize = -1,
    list_item_index: isize = -1,
    list_item_count: isize = -1,
    scroll_offset: f32 = 0,
    scroll_viewport_extent: f32 = 0,
    scroll_content_extent: f32 = 0,
    has_scroll: c_int = 0,
};

pub const MobileWidgetTextGeometry = extern struct {
    id: u64 = 0,
    has_caret_bounds: c_int = 0,
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_width: f32 = 0,
    caret_height: f32 = 0,
    has_selection_bounds: c_int = 0,
    selection_x: f32 = 0,
    selection_y: f32 = 0,
    selection_width: f32 = 0,
    selection_height: f32 = 0,
    selection_rect_count: usize = 0,
    has_composition_bounds: c_int = 0,
    composition_x: f32 = 0,
    composition_y: f32 = 0,
    composition_width: f32 = 0,
    composition_height: f32 = 0,
    composition_rect_count: usize = 0,
};

pub const MobileWidgetActionRequest = extern struct {
    id: u64 = 0,
    action: c_int = @intFromEnum(MobileWidgetActionKind.focus),
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    selection_anchor: usize = 0,
    selection_focus: usize = 0,
    has_selection: c_int = 0,
};

pub const MobileViewportState = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    has_surface: c_int = 0,
    safe_top: f32 = 0,
    safe_right: f32 = 0,
    safe_bottom: f32 = 0,
    safe_left: f32 = 0,
    keyboard_top: f32 = 0,
    keyboard_right: f32 = 0,
    keyboard_bottom: f32 = 0,
    keyboard_left: f32 = 0,
    content_x: f32 = 0,
    content_y: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
};

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

const MobileHostApp = struct {
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

    fn create() !*MobileHostApp {
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

const mobile_html =
    \\<!doctype html>
    \\<html>
    \\<body style="font-family: system-ui; padding: 2rem;">
    \\  <h1>zero-native mobile</h1>
    \\  <p>This content is loaded through the zero-native embedded C ABI.</p>
    \\</body>
    \\</html>
;

fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn recordError(self: *MobileHostApp, err: anyerror) void {
    self.last_error = err;
}

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

fn mobileViewportStateFromSurface(surface: platform.Surface) MobileViewportState {
    const content = geometry.RectF.fromSize(surface.size).deflate(combinedMobileViewportInsets(surface));
    return .{
        .width = surface.size.width,
        .height = surface.size.height,
        .scale = surface.scale_factor,
        .has_surface = if (surface.native_handle != null) 1 else 0,
        .safe_top = surface.safe_area_insets.top,
        .safe_right = surface.safe_area_insets.right,
        .safe_bottom = surface.safe_area_insets.bottom,
        .safe_left = surface.safe_area_insets.left,
        .keyboard_top = surface.keyboard_insets.top,
        .keyboard_right = surface.keyboard_insets.right,
        .keyboard_bottom = surface.keyboard_insets.bottom,
        .keyboard_left = surface.keyboard_insets.left,
        .content_x = content.x,
        .content_y = content.y,
        .content_width = content.width,
        .content_height = content.height,
    };
}

fn combinedMobileViewportInsets(surface: platform.Surface) geometry.InsetsF {
    return .{
        .top = @max(surface.safe_area_insets.top, surface.keyboard_insets.top),
        .right = @max(surface.safe_area_insets.right, surface.keyboard_insets.right),
        .bottom = @max(surface.safe_area_insets.bottom, surface.keyboard_insets.bottom),
        .left = @max(surface.safe_area_insets.left, surface.keyboard_insets.left),
    };
}

fn mobileSurface(width: f32, height: f32, scale: f32, surface: ?*anyopaque, safe_area_insets: geometry.InsetsF, keyboard_insets: geometry.InsetsF) platform.Surface {
    return .{
        .size = .{ .width = width, .height = height },
        .scale_factor = scale,
        .safe_area_insets = safe_area_insets,
        .keyboard_insets = keyboard_insets,
        .native_handle = surface,
    };
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

fn mobileTouchKindFromPhase(phase: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (phase) {
        0, 5 => .pointer_down,
        1, 6 => .pointer_up,
        2 => .pointer_drag,
        3 => .pointer_cancel,
        else => error.InvalidTouchPhase,
    };
}

fn mobileKeyKindFromPhase(phase: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (phase) {
        0 => .key_down,
        1 => .key_up,
        else => error.InvalidKeyPhase,
    };
}

fn mobileImeKindFromInt(kind: c_int) anyerror!platform.GpuSurfaceInputKind {
    return switch (kind) {
        0 => .ime_set_composition,
        1 => .ime_commit_composition,
        2 => .ime_cancel_composition,
        else => error.InvalidImeKind,
    };
}

fn mobileModifiersFromMask(mask: u32) platform.ShortcutModifiers {
    return .{
        .primary = (mask & 1) != 0,
        .command = (mask & 2) != 0,
        .control = (mask & 4) != 0,
        .option = (mask & 8) != 0,
        .shift = (mask & 16) != 0,
    };
}

fn mobileWidgetActionKindFromInt(value: c_int) anyerror!runtime.CanvasWidgetAccessibilityActionKind {
    return switch (value) {
        @intFromEnum(MobileWidgetActionKind.focus) => .focus,
        @intFromEnum(MobileWidgetActionKind.press) => .press,
        @intFromEnum(MobileWidgetActionKind.toggle) => .toggle,
        @intFromEnum(MobileWidgetActionKind.increment) => .increment,
        @intFromEnum(MobileWidgetActionKind.decrement) => .decrement,
        @intFromEnum(MobileWidgetActionKind.set_text) => .set_text,
        @intFromEnum(MobileWidgetActionKind.set_selection) => .set_selection,
        @intFromEnum(MobileWidgetActionKind.set_composition) => .set_composition,
        @intFromEnum(MobileWidgetActionKind.commit_composition) => .commit_composition,
        @intFromEnum(MobileWidgetActionKind.cancel_composition) => .cancel_composition,
        @intFromEnum(MobileWidgetActionKind.select) => .select,
        @intFromEnum(MobileWidgetActionKind.drag) => .drag,
        @intFromEnum(MobileWidgetActionKind.drop_files) => .drop_files,
        else => error.InvalidCommand,
    };
}

fn inputSlice(pointer: ?[*]const u8, len: usize) anyerror![]const u8 {
    if (len == 0) return "";
    const value = pointer orelse return error.InvalidCommand;
    return value[0..len];
}

fn copyInputText(buffer: []u8, value: []const u8) usize {
    const count = @min(buffer.len, value.len);
    @memcpy(buffer[0..count], value[0..count]);
    return count;
}

fn mobileWidgetSemanticsFromNode(nodes: []const canvas.WidgetSemanticsNode, index: usize) MobileWidgetSemantics {
    const node = nodes[index];
    const label = mobileOptionalString(node.label);
    const text = mobileOptionalString(node.text_value);
    return .{
        .id = node.id,
        .parent_id = mobileWidgetSemanticParentId(nodes, node.parent_index),
        .role = @intFromEnum(mobileWidgetRole(node.role)),
        .flags = mobileWidgetFlags(node),
        .actions = mobileWidgetActions(node.actions),
        .x = node.bounds.x,
        .y = node.bounds.y,
        .width = node.bounds.width,
        .height = node.bounds.height,
        .value = node.value orelse 0,
        .has_value = if (node.value != null) 1 else 0,
        .label = label.ptr,
        .label_len = label.len,
        .text = text.ptr,
        .text_len = text.len,
        .text_selection_start = mobileTextRangeStart(node.text_selection),
        .text_selection_end = mobileTextRangeEnd(node.text_selection),
        .text_composition_start = mobileTextRangeStart(node.text_composition),
        .text_composition_end = mobileTextRangeEnd(node.text_composition),
        .grid_row_index = mobileOptionalIndex(node.grid_row_index),
        .grid_column_index = mobileOptionalIndex(node.grid_column_index),
        .grid_row_count = mobileOptionalIndex(node.grid_row_count),
        .grid_column_count = mobileOptionalIndex(node.grid_column_count),
        .list_item_index = if (node.list.present) mobileU32Index(node.list.item_index) else -1,
        .list_item_count = if (node.list.present) mobileU32Index(node.list.item_count) else -1,
        .scroll_offset = node.scroll.offset,
        .scroll_viewport_extent = node.scroll.viewport_extent,
        .scroll_content_extent = node.scroll.content_extent,
        .has_scroll = if (node.scroll.present) 1 else 0,
    };
}

fn mobileWidgetTextGeometryFromCanvas(id: canvas.ObjectId, geometry_value: canvas.WidgetTextGeometry) MobileWidgetTextGeometry {
    var value = MobileWidgetTextGeometry{
        .id = id,
        .selection_rect_count = geometry_value.selection_rect_count,
        .composition_rect_count = geometry_value.composition_rect_count,
    };
    if (geometry_value.caret_bounds) |bounds| {
        value.has_caret_bounds = 1;
        value.caret_x = bounds.x;
        value.caret_y = bounds.y;
        value.caret_width = bounds.width;
        value.caret_height = bounds.height;
    }
    if (geometry_value.selection_bounds) |bounds| {
        value.has_selection_bounds = 1;
        value.selection_x = bounds.x;
        value.selection_y = bounds.y;
        value.selection_width = bounds.width;
        value.selection_height = bounds.height;
    }
    if (geometry_value.composition_bounds) |bounds| {
        value.has_composition_bounds = 1;
        value.composition_x = bounds.x;
        value.composition_y = bounds.y;
        value.composition_width = bounds.width;
        value.composition_height = bounds.height;
    }
    return value;
}

fn mobileWidgetSemanticParentId(nodes: []const canvas.WidgetSemanticsNode, parent_index: ?usize) u64 {
    const index = parent_index orelse return 0;
    if (index >= nodes.len) return 0;
    return nodes[index].id;
}

const MobileStringView = struct {
    ptr: ?[*]const u8,
    len: usize,
};

fn mobileOptionalString(value: []const u8) MobileStringView {
    return .{
        .ptr = if (value.len > 0) value.ptr else null,
        .len = value.len,
    };
}

fn mobileWidgetRole(role: canvas.WidgetRole) MobileWidgetRole {
    return switch (role) {
        .none => .none,
        .group => .group,
        .text => .text,
        .image => .image,
        .button => .button,
        .textbox => .textbox,
        .tooltip => .tooltip,
        .dialog => .dialog,
        .menu => .menu,
        .menuitem => .menuitem,
        .list => .list,
        .listitem => .listitem,
        .row => .row,
        .grid => .grid,
        .gridcell => .gridcell,
        .tab => .tab,
        .checkbox => .checkbox,
        .switch_control => .switch_control,
        .slider => .slider,
        .progressbar => .progressbar,
    };
}

fn mobileWidgetFlags(node: canvas.WidgetSemanticsNode) u32 {
    var flags: u32 = 0;
    if (node.state.focused) flags |= @intFromEnum(MobileWidgetFlag.focused);
    if (node.state.hovered) flags |= @intFromEnum(MobileWidgetFlag.hovered);
    if (node.state.pressed) flags |= @intFromEnum(MobileWidgetFlag.pressed);
    if (node.state.selected) flags |= @intFromEnum(MobileWidgetFlag.selected);
    if (node.state.disabled) flags |= @intFromEnum(MobileWidgetFlag.disabled);
    if (node.focusable) flags |= @intFromEnum(MobileWidgetFlag.focusable);
    return flags;
}

fn mobileWidgetActions(actions: canvas.WidgetActions) u32 {
    var flags: u32 = 0;
    if (actions.focus) flags |= @intFromEnum(MobileWidgetAction.focus);
    if (actions.press) flags |= @intFromEnum(MobileWidgetAction.press);
    if (actions.toggle) flags |= @intFromEnum(MobileWidgetAction.toggle);
    if (actions.increment) flags |= @intFromEnum(MobileWidgetAction.increment);
    if (actions.decrement) flags |= @intFromEnum(MobileWidgetAction.decrement);
    if (actions.set_text) flags |= @intFromEnum(MobileWidgetAction.set_text);
    if (actions.set_selection) flags |= @intFromEnum(MobileWidgetAction.set_selection);
    if (actions.select) flags |= @intFromEnum(MobileWidgetAction.select);
    if (actions.drag) flags |= @intFromEnum(MobileWidgetAction.drag);
    if (actions.drop_files) flags |= @intFromEnum(MobileWidgetAction.drop_files);
    return flags;
}

fn mobileOptionalIndex(value: ?usize) isize {
    const index = value orelse return -1;
    if (index > @as(usize, @intCast(std.math.maxInt(isize)))) return std.math.maxInt(isize);
    return @intCast(index);
}

fn mobileU32Index(value: u32) isize {
    return @intCast(value);
}

fn mobileTextRangeStart(range: ?canvas.TextRange) isize {
    const value = range orelse return -1;
    return mobileOptionalIndex(value.start);
}

fn mobileTextRangeEnd(range: ?canvas.TextRange) isize {
    const value = range orelse return -1;
    return mobileOptionalIndex(value.end);
}

fn mobileWidgetSemanticsByIdForTest(app: ?*anyopaque, id: u64) !MobileWidgetSemantics {
    var node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_semantics_by_id(app, id, &node));
    try std.testing.expectEqual(id, node.id);
    return node;
}

fn expectNoMobileWidgetSemanticsByIdForTest(app: ?*anyopaque, id: u64) !void {
    var node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_semantics_by_id(app, id, &node));
}

fn nowNanoseconds() u64 {
    switch (@import("builtin").os.tag) {
        .windows, .wasi => return 0,
        else => {
            var ts: std.posix.timespec = undefined;
            switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
                .SUCCESS => return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec),
                else => return 0,
            }
        },
    }
}

test "embedded app starts and loads source" {
    var null_platform = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    var embedded: EmbeddedApp = undefined;
    embedded.initInPlace(.{
        .context = &state,
        .name = "embedded",
        .source = platform.WebViewSource.html("<p>Embedded</p>"),
    }, null_platform.platform());

    try embedded.start();
    try @import("std").testing.expectEqualStrings("<p>Embedded</p>", null_platform.loaded_source.?.bytes);
}

test "mobile C ABI can load packaged asset source" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("zero://app", source.bytes);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings("index.html", source.asset_options.?.entry);
    try std.testing.expect(source.asset_options.?.spa_fallback);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI can load custom packaged asset entry" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    const asset_entry = "main.html";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_set_asset_entry(app, asset_entry, asset_entry.len);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expect(source.asset_options != null);
    try std.testing.expectEqualStrings(asset_root, source.asset_options.?.root_path);
    try std.testing.expectEqualStrings(asset_entry, source.asset_options.?.entry);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI can reset asset root before startup" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const asset_root = "/tmp/zero-native-mobile-assets";
    zero_native_app_set_asset_root(app, asset_root, asset_root.len);
    zero_native_app_set_asset_root(app, asset_root, 0);
    zero_native_app_start(app);

    const self = mobileApp(app).?;
    const source = self.null_platform.loaded_source.?;
    try std.testing.expectEqual(platform.WebViewSourceKind.html, source.kind);
    try std.testing.expectEqualStrings(mobile_html, source.bytes);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI forwards activation lifecycle through embedded runtime" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    zero_native_app_start(app);
    zero_native_app_activate(app);
    zero_native_app_deactivate(app);

    const self = mobileApp(app).?;
    try std.testing.expectEqual(@as(usize, 1), self.activation_count);
    try std.testing.expectEqual(@as(usize, 1), self.deactivation_count);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI forwards surface resize and touch input" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    var native_surface_token: u8 = 0;
    zero_native_app_resize(app, 390, 844, 3, &native_surface_token);

    const self = mobileApp(app).?;
    try std.testing.expectEqual(@as(usize, 1), self.mobile_surface_resize_count);
    try std.testing.expectEqual(@as(f32, 390), self.mobile_surface_width);
    try std.testing.expectEqual(@as(f32, 844), self.mobile_surface_height);
    try std.testing.expectEqual(@as(f32, 3), self.mobile_surface_scale);

    zero_native_app_viewport(app, 390, 700, 3, &native_surface_token, 47, 0, 34, 0, 0, 0, 144, 0);
    try std.testing.expectEqual(@as(usize, 2), self.mobile_surface_resize_count);
    try std.testing.expectEqual(@as(f32, 390), self.embedded.runtime.surface.size.width);
    try std.testing.expectEqual(@as(f32, 700), self.embedded.runtime.surface.size.height);
    try std.testing.expectEqual(@as(f32, 47), self.embedded.runtime.surface.safe_area_insets.top);
    try std.testing.expectEqual(@as(f32, 34), self.embedded.runtime.surface.safe_area_insets.bottom);
    try std.testing.expectEqual(@as(f32, 144), self.embedded.runtime.surface.keyboard_insets.bottom);

    var viewport: MobileViewportState = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_viewport_state(app, &viewport));
    try std.testing.expectEqual(@as(f32, 390), viewport.width);
    try std.testing.expectEqual(@as(f32, 700), viewport.height);
    try std.testing.expectEqual(@as(f32, 3), viewport.scale);
    try std.testing.expectEqual(@as(c_int, 1), viewport.has_surface);
    try std.testing.expectEqual(@as(f32, 47), viewport.safe_top);
    try std.testing.expectEqual(@as(f32, 34), viewport.safe_bottom);
    try std.testing.expectEqual(@as(f32, 144), viewport.keyboard_bottom);
    try std.testing.expectEqual(@as(f32, 0), viewport.content_x);
    try std.testing.expectEqual(@as(f32, 47), viewport.content_y);
    try std.testing.expectEqual(@as(f32, 390), viewport.content_width);
    try std.testing.expectEqual(@as(f32, 509), viewport.content_height);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_viewport_state(app, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_touch(app, 42, 0, 11, 22, 0.5);
    try std.testing.expectEqual(@as(usize, 1), self.touch_count);
    try std.testing.expectEqual(@as(u64, 42), self.last_touch_id);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_down, self.last_touch_kind);
    try std.testing.expect(self.last_touch_timestamp_ns > 0);
    try std.testing.expectEqual(@as(f32, 11), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 22), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, 0.5), self.last_touch_pressure);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_touch(app, 42, 2, 13, 25, 0.75);
    try std.testing.expectEqual(@as(usize, 2), self.touch_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_drag, self.last_touch_kind);
    try std.testing.expectEqual(@as(f32, 13), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 25), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, 0.75), self.last_touch_pressure);

    zero_native_app_touch(app, 42, 3, 13, 25, 0);
    try std.testing.expectEqual(@as(usize, 3), self.touch_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_cancel, self.last_touch_kind);

    zero_native_app_scroll(app, 42, 15, 26, -2, 18);
    try std.testing.expectEqual(@as(usize, 4), self.touch_count);
    try std.testing.expectEqual(@as(usize, 4), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_touch_kind);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_input_kind);
    try std.testing.expectEqual(@as(u64, 42), self.last_touch_id);
    try std.testing.expectEqual(@as(f32, 15), self.last_touch_x);
    try std.testing.expectEqual(@as(f32, 26), self.last_touch_y);
    try std.testing.expectEqual(@as(f32, -2), self.last_touch_delta_x);
    try std.testing.expectEqual(@as(f32, 18), self.last_touch_delta_y);
    try std.testing.expectEqual(@as(f32, 0), self.last_touch_pressure);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_touch(app, 42, 99, 13, 25, 0);
    try std.testing.expectEqual(@as(usize, 4), self.touch_count);
    try std.testing.expectEqualStrings("InvalidTouchPhase", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI forwards key text and IME input" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const self = mobileApp(app).?;
    zero_native_app_key(app, 0, "enter", "enter".len, "", 0, 17);
    try std.testing.expectEqual(@as(usize, 1), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.key_down, self.last_input_kind);
    try std.testing.expectEqualStrings("enter", self.last_input_key[0..self.last_input_key_len]);
    try std.testing.expect(self.last_input_modifiers.primary);
    try std.testing.expect(self.last_input_modifiers.shift);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_text(app, "é", "é".len);
    try std.testing.expectEqual(@as(usize, 2), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.text_input, self.last_input_kind);
    try std.testing.expectEqualStrings("é", self.last_input_text[0..self.last_input_text_len]);

    zero_native_app_ime(app, 0, "かな", "かな".len, "かな".len);
    try std.testing.expectEqual(@as(usize, 3), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_set_composition, self.last_input_kind);
    try std.testing.expectEqualStrings("かな", self.last_input_text[0..self.last_input_text_len]);
    try std.testing.expectEqual(@as(?usize, "かな".len), self.last_input_composition_cursor);

    zero_native_app_ime(app, 1, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 4), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_commit_composition, self.last_input_kind);

    zero_native_app_ime(app, 2, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.ime_cancel_composition, self.last_input_kind);

    zero_native_app_key(app, 99, "enter", "enter".len, "", 0, 0);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqualStrings("InvalidKeyPhase", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_ime(app, 99, "", 0, -1);
    try std.testing.expectEqual(@as(usize, 5), self.input_count);
    try std.testing.expectEqualStrings("InvalidImeKind", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI exposes GPU widget accessibility semantics" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    zero_native_app_start(app);
    _ = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 180),
    });

    const scroll_children = [_]canvas.Widget{
        .{
            .id = 5,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 0, 28),
            .text = "Top",
        },
        .{
            .id = 6,
            .kind = .button,
            .frame = geometry.RectF.init(0, 88, 0, 28),
            .text = "Bottom",
        },
    };
    const list_children = [_]canvas.Widget{
        .{
            .id = 8,
            .kind = .list_item,
            .text = "Inbox",
        },
        .{
            .id = 9,
            .kind = .list_item,
            .text = "Archive",
        },
    };
    const grid_cells = [_]canvas.Widget{
        .{
            .id = 12,
            .kind = .data_cell,
            .text = "Project",
            .layout = .{ .grow = 1 },
        },
        .{
            .id = 13,
            .kind = .data_cell,
            .text = "Status",
            .layout = .{ .grow = 1 },
        },
    };
    const grid_rows = [_]canvas.Widget{.{
        .id = 11,
        .kind = .data_row,
        .children = &grid_cells,
    }};
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .semantics = .{ .label = "Run report" },
        },
        .{
            .id = 3,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 56, 160, 32),
            .text = "Draft",
            .text_selection = canvas.TextSelection{ .anchor = 1, .focus = 4 },
            .state = .{ .focused = true },
            .semantics = .{ .label = "Report title" },
        },
        .{
            .id = 4,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(12, 96, 120, 48),
            .value = 20,
            .semantics = .{ .label = "Mobile scroll" },
            .children = &scroll_children,
        },
        .{
            .id = 7,
            .kind = .list,
            .frame = geometry.RectF.init(160, 16, 120, 68),
            .text = "Mailboxes",
            .layout = .{ .gap = 4 },
            .children = &list_children,
        },
        .{
            .id = 10,
            .kind = .data_grid,
            .frame = geometry.RectF.init(160, 96, 140, 40),
            .text = "Deployments",
            .layout = .{ .gap = 2 },
            .children = &grid_rows,
        },
    };
    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .stack,
        .children = &children,
        .semantics = .{ .label = "Mobile canvas widgets" },
    }, geometry.RectF.init(0, 0, 320, 180), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);

    try std.testing.expectEqual(@as(usize, 13), zero_native_app_widget_semantics_count(app));

    var root_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_semantics_at(app, 0, &root_node));
    try std.testing.expectEqual(@as(u64, 1), root_node.id);
    try std.testing.expectEqual(@as(u64, 0), root_node.parent_id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.group), root_node.role);
    try std.testing.expectEqualStrings("Mobile canvas widgets", root_node.label.?[0..root_node.label_len]);

    var button_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_semantics_at(app, 1, &button_node));
    try std.testing.expectEqual(@as(u64, 2), button_node.id);
    try std.testing.expectEqual(@as(u64, 1), button_node.parent_id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.button), button_node.role);
    try std.testing.expectEqualStrings("Run report", button_node.label.?[0..button_node.label_len]);
    try std.testing.expect((button_node.flags & @intFromEnum(MobileWidgetFlag.focusable)) != 0);
    try std.testing.expect((button_node.actions & @intFromEnum(MobileWidgetAction.press)) != 0);
    try std.testing.expectEqual(@as(f32, 12), button_node.x);
    try std.testing.expectEqual(@as(f32, 16), button_node.y);
    try std.testing.expectEqual(@as(f32, 96), button_node.width);
    try std.testing.expectEqual(@as(f32, 32), button_node.height);

    var text_node: MobileWidgetSemantics = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_semantics_at(app, 2, &text_node));
    try std.testing.expectEqual(@as(u64, 3), text_node.id);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.textbox), text_node.role);
    try std.testing.expectEqualStrings("Report title", text_node.label.?[0..text_node.label_len]);
    try std.testing.expectEqualStrings("Draft", text_node.text.?[0..text_node.text_len]);
    try std.testing.expectEqual(@as(isize, 1), text_node.text_selection_start);
    try std.testing.expectEqual(@as(isize, 4), text_node.text_selection_end);
    try std.testing.expect((text_node.flags & @intFromEnum(MobileWidgetFlag.focused)) != 0);
    try std.testing.expect((text_node.actions & @intFromEnum(MobileWidgetAction.set_text)) != 0);
    try std.testing.expect((text_node.actions & @intFromEnum(MobileWidgetAction.set_selection)) != 0);

    const scroll_node = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.group), scroll_node.role);
    try std.testing.expectEqual(@as(c_int, 1), scroll_node.has_scroll);
    try std.testing.expectEqual(@as(f32, 20), scroll_node.scroll_offset);
    try std.testing.expectEqual(@as(f32, 48), scroll_node.scroll_viewport_extent);
    try std.testing.expectEqual(@as(f32, 116), scroll_node.scroll_content_extent);
    try std.testing.expect((scroll_node.actions & @intFromEnum(MobileWidgetAction.increment)) != 0);
    try std.testing.expect((scroll_node.actions & @intFromEnum(MobileWidgetAction.decrement)) != 0);

    zero_native_app_scroll(app, 11, 24, 112, 0, 14);
    const scrolled_node = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.scroll, self.last_input_kind);
    try std.testing.expectEqual(@as(u64, 11), self.last_touch_id);
    try std.testing.expectEqual(@as(f32, 14), self.last_touch_delta_y);
    try std.testing.expectEqual(@as(f32, 34), scrolled_node.scroll_offset);
    try std.testing.expectEqual(@as(f32, 48), scrolled_node.scroll_viewport_extent);
    try std.testing.expectEqual(@as(f32, 116), scrolled_node.scroll_content_extent);

    const list_node = try mobileWidgetSemanticsByIdForTest(app, 7);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.list), list_node.role);
    try std.testing.expectEqualStrings("Mailboxes", list_node.label.?[0..list_node.label_len]);
    const archive_node = try mobileWidgetSemanticsByIdForTest(app, 9);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.listitem), archive_node.role);
    try std.testing.expectEqual(@as(u64, 7), archive_node.parent_id);
    try std.testing.expectEqual(@as(isize, 1), archive_node.list_item_index);
    try std.testing.expectEqual(@as(isize, 2), archive_node.list_item_count);
    try std.testing.expect((archive_node.actions & @intFromEnum(MobileWidgetAction.select)) != 0);

    const grid_node = try mobileWidgetSemanticsByIdForTest(app, 10);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.grid), grid_node.role);
    try std.testing.expectEqual(@as(isize, 1), grid_node.grid_row_count);
    try std.testing.expectEqual(@as(isize, 2), grid_node.grid_column_count);
    const status_cell = try mobileWidgetSemanticsByIdForTest(app, 13);
    try std.testing.expectEqual(@intFromEnum(MobileWidgetRole.gridcell), status_cell.role);
    try std.testing.expectEqual(@as(u64, 11), status_cell.parent_id);
    try std.testing.expectEqual(@as(isize, 0), status_cell.grid_row_index);
    try std.testing.expectEqual(@as(isize, 1), status_cell.grid_column_index);
    try std.testing.expectEqual(@as(isize, 1), status_cell.grid_row_count);
    try std.testing.expectEqual(@as(isize, 2), status_cell.grid_column_count);
    try std.testing.expect((status_cell.actions & @intFromEnum(MobileWidgetAction.select)) != 0);

    var text_geometry: MobileWidgetTextGeometry = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_text_geometry(app, 3, &text_geometry));
    try std.testing.expectEqual(@as(u64, 3), text_geometry.id);
    try std.testing.expectEqual(@as(c_int, 0), text_geometry.has_caret_bounds);
    try std.testing.expectEqual(@as(c_int, 1), text_geometry.has_selection_bounds);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.selection_rect_count);
    try std.testing.expect(text_geometry.selection_width > 0);
    try std.testing.expectEqual(@as(c_int, 0), text_geometry.has_composition_bounds);

    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_text_geometry(app, 2, &text_geometry));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_semantics_at(app, 99, &text_node));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    try expectNoMobileWidgetSemanticsByIdForTest(app, 99);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));
    try expectNoMobileWidgetSemanticsByIdForTest(app, 0);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));
    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_semantics_by_id(app, 2, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI dispatches GPU widget accessibility actions" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    zero_native_app_start(app);
    _ = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 360, 220),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(12, 16, 96, 32),
            .text = "Run",
            .command = "widget.run",
            .semantics = .{ .label = "Run report" },
        },
        .{
            .id = 3,
            .kind = .checkbox,
            .frame = geometry.RectF.init(12, 56, 144, 28),
            .text = "Enabled",
        },
        .{
            .id = 4,
            .kind = .slider,
            .frame = geometry.RectF.init(12, 92, 160, 32),
            .value = 0.5,
            .semantics = .{ .label = "Confidence" },
        },
        .{
            .id = 5,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 136, 180, 32),
            .text = "Draft",
            .semantics = .{ .label = "Report title" },
        },
        .{
            .id = 6,
            .kind = .list_item,
            .frame = geometry.RectF.init(210, 16, 120, 32),
            .text = "Inbox",
        },
        .{
            .id = 7,
            .kind = .button,
            .frame = geometry.RectF.init(210, 56, 120, 32),
            .text = "Drag",
            .semantics = .{ .actions = .{ .drag = true } },
        },
        .{
            .id = 8,
            .kind = .button,
            .frame = geometry.RectF.init(210, 96, 120, 32),
            .text = "Drop",
            .semantics = .{ .actions = .{ .drop_files = true } },
        },
    };
    var nodes: [10]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .panel,
        .children = &children,
        .semantics = .{ .label = "Mobile action widgets" },
    }, geometry.RectF.init(0, 0, 360, 220), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);

    var action = MobileWidgetActionRequest{ .id = 2, .action = @intFromEnum(MobileWidgetActionKind.press) };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqual(@as(usize, 1), zero_native_app_last_command_count(app));
    try std.testing.expectEqualStrings("widget.run", std.mem.span(zero_native_app_last_command_name(app)));
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), self.embedded.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_up, self.last_input_kind);
    try std.testing.expectEqual(@as(usize, 0), self.last_input_key_len);

    action = .{ .id = 3, .action = @intFromEnum(MobileWidgetActionKind.toggle) };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    const checkbox = try mobileWidgetSemanticsByIdForTest(app, 3);
    try std.testing.expectEqual(@as(c_int, 1), checkbox.has_value);
    try std.testing.expectEqual(@as(f32, 1), checkbox.value);
    try std.testing.expect((checkbox.flags & @intFromEnum(MobileWidgetFlag.selected)) != 0);

    action = .{ .id = 4, .action = @intFromEnum(MobileWidgetActionKind.increment) };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    const slider = try mobileWidgetSemanticsByIdForTest(app, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), slider.value, 0.001);

    const title = "Hello world";
    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_text),
        .text = title,
        .text_len = title.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    var text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings(title, text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_selection_start);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_selection_end);

    const composition = "!";
    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_composition),
        .text = composition,
        .text_len = composition.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings("Hello world!", text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, @intCast(title.len)), text_field.text_composition_start);
    try std.testing.expectEqual(@as(isize, @intCast(title.len + composition.len)), text_field.text_composition_end);

    action = .{ .id = 5, .action = @intFromEnum(MobileWidgetActionKind.commit_composition) };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqualStrings("Hello world!", text_field.text.?[0..text_field.text_len]);
    try std.testing.expectEqual(@as(isize, -1), text_field.text_composition_start);
    try std.testing.expectEqual(@as(isize, -1), text_field.text_composition_end);

    action = .{
        .id = 5,
        .action = @intFromEnum(MobileWidgetActionKind.set_selection),
        .selection_anchor = 0,
        .selection_focus = 5,
        .has_selection = 1,
    };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    text_field = try mobileWidgetSemanticsByIdForTest(app, 5);
    try std.testing.expectEqual(@as(isize, 0), text_field.text_selection_start);
    try std.testing.expectEqual(@as(isize, 5), text_field.text_selection_end);

    action = .{ .id = 6, .action = @intFromEnum(MobileWidgetActionKind.select) };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    const list_item = try mobileWidgetSemanticsByIdForTest(app, 6);
    try std.testing.expectEqual(@as(c_int, 1), list_item.has_value);
    try std.testing.expectEqual(@as(f32, 1), list_item.value);
    try std.testing.expect((list_item.flags & @intFromEnum(MobileWidgetFlag.selected)) != 0);

    const drag_delta = "6 2";
    action = .{
        .id = 7,
        .action = @intFromEnum(MobileWidgetActionKind.drag),
        .text = drag_delta,
        .text_len = drag_delta.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqual(platform.GpuSurfaceInputKind.pointer_drag, self.last_input_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 276), self.last_touch_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 74), self.last_touch_y, 0.001);

    const drop_paths = "/tmp/mobile-report.csv";
    action = .{
        .id = 8,
        .action = @intFromEnum(MobileWidgetActionKind.drop_files),
        .text = drop_paths,
        .text_len = drop_paths.len,
    };
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("drop:files", self.null_platform.lastWindowEventName());
    try std.testing.expect(std.mem.indexOf(u8, self.null_platform.lastWindowEventDetail(), "\"paths\":[\"/tmp/mobile-report.csv\"]") != null);

    action = .{ .id = 99, .action = @intFromEnum(MobileWidgetActionKind.press) };
    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    action = .{ .id = 5, .action = @intFromEnum(MobileWidgetActionKind.set_selection) };
    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    action = .{ .id = 2, .action = 999 };
    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_widget_action(app, &action));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));
}

test "mobile C ABI dispatches native commands through embedded runtime" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    zero_native_app_command(app, "mobile.refresh", "mobile.refresh".len);
    try std.testing.expectEqual(@as(usize, 1), zero_native_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.refresh", std.mem.span(zero_native_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_command(app, "", 0);
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));

    zero_native_app_command(app, "mobile.open", "mobile.open".len);
    try std.testing.expectEqual(@as(usize, 2), zero_native_app_last_command_count(app));
    try std.testing.expectEqualStrings("mobile.open", std.mem.span(zero_native_app_last_command_name(app)));
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));
}

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const runtime = @import("../runtime/root.zig");
const platform = @import("../platform/root.zig");
const types = @import("types.zig");
const host = @import("host.zig");
const c_api = @import("c_api.zig");
const conversions = @import("conversions.zig");

const MobileWidgetRole = types.MobileWidgetRole;
const MobileWidgetFlag = types.MobileWidgetFlag;
const MobileWidgetAction = types.MobileWidgetAction;
const MobileWidgetActionKind = types.MobileWidgetActionKind;
const MobileWidgetSemantics = types.MobileWidgetSemantics;
const MobileWidgetTextGeometry = types.MobileWidgetTextGeometry;
const MobileWidgetActionRequest = types.MobileWidgetActionRequest;
const MobileViewportState = types.MobileViewportState;
const MobileGpuFrameState = types.MobileGpuFrameState;
const EmbeddedApp = host.EmbeddedApp;
const mobileApp = host.mobileApp;
const mobile_html = host.mobile_html;
const mobile_gpu_surface_label = types.mobile_gpu_surface_label;
const mobileWidgetFlags = conversions.mobileWidgetFlags;
const mobileWidgetActions = conversions.mobileWidgetActions;
const mobileWidgetActionKindFromInt = conversions.mobileWidgetActionKindFromInt;
const zero_native_app_create = c_api.zero_native_app_create;
const zero_native_app_destroy = c_api.zero_native_app_destroy;
const zero_native_app_start = c_api.zero_native_app_start;
const zero_native_app_activate = c_api.zero_native_app_activate;
const zero_native_app_deactivate = c_api.zero_native_app_deactivate;
const zero_native_app_resize = c_api.zero_native_app_resize;
const zero_native_app_viewport = c_api.zero_native_app_viewport;
const zero_native_app_viewport_state = c_api.zero_native_app_viewport_state;
const zero_native_app_gpu_frame_state = c_api.zero_native_app_gpu_frame_state;
const zero_native_app_touch = c_api.zero_native_app_touch;
const zero_native_app_scroll = c_api.zero_native_app_scroll;
const zero_native_app_key = c_api.zero_native_app_key;
const zero_native_app_text = c_api.zero_native_app_text;
const zero_native_app_ime = c_api.zero_native_app_ime;
const zero_native_app_command = c_api.zero_native_app_command;
const zero_native_app_set_asset_root = c_api.zero_native_app_set_asset_root;
const zero_native_app_set_asset_entry = c_api.zero_native_app_set_asset_entry;
const zero_native_app_last_command_count = c_api.zero_native_app_last_command_count;
const zero_native_app_last_command_name = c_api.zero_native_app_last_command_name;
const zero_native_app_last_error_name = c_api.zero_native_app_last_error_name;
const zero_native_app_widget_semantics_count = c_api.zero_native_app_widget_semantics_count;
const zero_native_app_widget_semantics_at = c_api.zero_native_app_widget_semantics_at;
const zero_native_app_widget_semantics_by_id = c_api.zero_native_app_widget_semantics_by_id;
const zero_native_app_widget_text_geometry = c_api.zero_native_app_widget_text_geometry;
const zero_native_app_widget_action = c_api.zero_native_app_widget_action;

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

test "mobile C ABI exposes GPU frame state" {
    const app = zero_native_app_create() orelse return error.TestUnexpectedResult;
    defer zero_native_app_destroy(app);

    const self = mobileApp(app).?;
    self.null_platform.gpu_surfaces = true;
    zero_native_app_start(app);
    const view = try self.embedded.runtime.createView(.{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 390, 844),
    });

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Continue",
            .semantics = .{ .label = "Continue" },
        },
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{
        .id = 1,
        .kind = .panel,
        .children = &children,
        .semantics = .{ .label = "Mobile GPU frame" },
    }, geometry.RectF.init(0, 0, 390, 844), &nodes);
    _ = try self.embedded.runtime.setCanvasWidgetLayout(1, mobile_gpu_surface_label, layout);
    _ = try self.embedded.runtime.emitCanvasWidgetDisplayList(1, mobile_gpu_surface_label, .{});

    try self.embedded.runtime.dispatchPlatformEvent(self.embedded.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .kind = .pointer_down,
        .timestamp_ns = 1_000_000,
        .pointer_id = 9,
        .x = 22,
        .y = 28,
        .pressure = 0.75,
    } });
    try self.embedded.runtime.dispatchPlatformEvent(self.embedded.app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = mobile_gpu_surface_label,
        .size = geometry.SizeF.init(390, 844),
        .scale_factor = 3,
        .frame_index = 7,
        .timestamp_ns = 21_000_000,
        .frame_interval_ns = 8_333_333,
        .nonblank = true,
        .sample_color = 0xff3366ff,
        .status = .ready,
        .vsync = true,
    } });

    var state: MobileGpuFrameState = .{};
    try std.testing.expectEqual(@as(c_int, 1), zero_native_app_gpu_frame_state(app, &state));
    try std.testing.expectEqual(view.id, state.surface_id);
    try std.testing.expectEqual(@as(u64, 1), state.window_id);
    try std.testing.expectEqual(@as(f32, 390), state.width);
    try std.testing.expectEqual(@as(f32, 844), state.height);
    try std.testing.expectEqual(@as(f32, 3), state.scale);
    try std.testing.expectEqual(@as(u64, 7), state.frame_index);
    try std.testing.expectEqual(@as(u64, 21_000_000), state.timestamp_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), state.frame_interval_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000), state.input_timestamp_ns);
    try std.testing.expectEqual(@as(u64, 20_000_000), state.input_latency_ns);
    try std.testing.expectEqual(@as(u64, 8_333_333), state.input_latency_budget_ns);
    try std.testing.expectEqual(@as(usize, 1), state.input_latency_budget_exceeded_count);
    try std.testing.expectEqual(@as(c_int, 0), state.input_latency_budget_ok);
    try std.testing.expectEqual(@as(c_int, 1), state.nonblank);
    try std.testing.expectEqual(@as(u32, 0xff3366ff), state.sample_color);
    try std.testing.expectEqual(@intFromEnum(platform.GpuSurfaceStatus.ready), state.status);
    try std.testing.expectEqual(@as(c_int, 1), state.vsync);
    try std.testing.expect(state.canvas_revision > 0);
    try std.testing.expectEqual(@as(usize, 2), state.widget_node_count);
    try std.testing.expectEqual(@as(usize, 2), state.widget_semantics_count);
    try std.testing.expectEqualStrings("", std.mem.span(zero_native_app_last_error_name(app)));

    try std.testing.expectEqual(@as(c_int, 0), zero_native_app_gpu_frame_state(app, null));
    try std.testing.expectEqualStrings("InvalidCommand", std.mem.span(zero_native_app_last_error_name(app)));
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
            .placeholder = "Report title placeholder",
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
    try std.testing.expectEqualStrings("Report title placeholder", text_node.placeholder.?[0..text_node.placeholder_len]);
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

test "mobile C ABI maps widget state and dismiss action flags" {
    const expanded_node = canvas.WidgetSemanticsNode{
        .id = 1,
        .role = .button,
        .label = "Menu",
        .bounds = geometry.RectF.init(0, 0, 120, 32),
        .state = .{ .expanded = true, .required = true, .read_only = true, .invalid = true },
        .actions = .{ .dismiss = true },
    };
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.expanded)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.collapsed)) == 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.required)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.read_only)) != 0);
    try std.testing.expect((mobileWidgetFlags(expanded_node) & @intFromEnum(MobileWidgetFlag.invalid)) != 0);
    try std.testing.expect((mobileWidgetActions(expanded_node.actions) & @intFromEnum(MobileWidgetAction.dismiss)) != 0);
    try std.testing.expectEqual(runtime.CanvasWidgetAccessibilityActionKind.dismiss, try mobileWidgetActionKindFromInt(@intFromEnum(MobileWidgetActionKind.dismiss)));

    const collapsed_node = canvas.WidgetSemanticsNode{
        .id = 2,
        .role = .button,
        .label = "Menu",
        .bounds = geometry.RectF.init(0, 0, 120, 32),
        .state = .{ .expanded = false },
    };
    try std.testing.expect((mobileWidgetFlags(collapsed_node) & @intFromEnum(MobileWidgetFlag.collapsed)) != 0);
    try std.testing.expect((mobileWidgetFlags(collapsed_node) & @intFromEnum(MobileWidgetFlag.expanded)) == 0);
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

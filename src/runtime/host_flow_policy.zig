//! Copied portable host-flow programs over native-owned facts and capabilities.
const std = @import("std");
const platform = @import("../platform/root.zig");
const api = @import("api.zig");
pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { enqueue, take, enter, turn, error_selection, platform_event, gate, app_event, run, cleanup, journal_enter, journal_exit };
pub const Action = enum(u8) { end, install, lap_start, reserve, start, extensions_start, lifecycle_start, lap_started, scene, load, lap_loaded, startup_dirty, start_log, activate, deactivate, tooltip_reset, lifecycle_activate, lifecycle_deactivate, emit_activate, emit_deactivate, appearance, text_generation, appearance_event, surface, surface_window, surface_layout, surface_emit, surface_dirty, surface_log, capture_open, window_update, window_layout, window_save, window_log, window_close, focus_window, dirty, focus_view, frame, bridge, tray_log, shortcut_event, shortcut_emit, command_dirty, gpu_resize_log, drop_route, drop_widget, drop_event, drop_emit, lifecycle_stop, extensions_stop, mark_stop, stop, stop_log, command_tray_action, command_shortcut, command_native_command, command_menu_command, command_tray_command, command_notification_command, event_timer, event_audio, event_video, event_wake, capability_gpu_surface_frame, capability_gpu_surface_resized, capability_gpu_surface_input, capability_gpu_surface_scroll_driver, capability_context_menu_action, capability_widget_context_menu_action, capability_widget_accessibility_action };
pub const Facts = struct { kind: u8 = 0, a: u8 = 0, b: u8 = 0, count: usize = 0, used: usize = 0, cost: usize = 0, head: usize = 0, delivered: usize = 0 };
pub const Plan = [64]u8;
pub fn plan(callback: *const fn ([]const u8, []u8) usize, stage: Stage, f: Facts) Plan {
    var input: [64]u8 = @splat(0);
    input[0..6].* = .{ 31, 1, @intFromEnum(stage), f.kind, f.a, f.b };
    inline for (.{ f.count, f.used, f.cost, f.head, f.delivered }, 0..) |value, i| std.mem.writeInt(u32, input[8 + i * 4 ..][0..4], @intCast(value), .little);
    var result: Plan = undefined;
    if (callback(&input, &result) != result.len) @panic("invalid compiled host flow size");
    if (!validResult(stage, f, &result)) @panic("invalid compiled host flow result");
    return result;
}
// Reject incompatible typed payload access, unterminated programs and bytes
// outside the response extent before executing any native capability.
pub fn validResult(stage: Stage, f: Facts, result: []const u8) bool {
    if (result.len != 64) return false;
    if (stage == .enqueue) {
        const available = 4194304 - @min(f.used, 4194304);
        const budget = available - @min(f.cost, available);
        return result[0] >= 1 and result[0] <= 3 and std.mem.readInt(u32, result[8..12], .little) <= budget and std.mem.allEqual(u8, result[1..8], 0) and std.mem.allEqual(u8, result[12..], 0);
    }
    if (stage == .platform_event or stage == .app_event or stage == .run or stage == .cleanup or stage == .journal_enter or stage == .journal_exit) {
        var ended = false;
        for (result) |byte| {
            if (byte == 0) {
                ended = true;
                continue;
            }
            if (ended) return false;
            if (stage == .journal_enter and byte == 1 and f.a == 0 or stage == .journal_exit and f.a == 0 or stage == .cleanup and byte == 4 and f.b == 0) return false;
            if (stage == .platform_event) {
                if (byte >= std.meta.fields(Action).len) return false;
                const kind: u8 = switch (@as(Action, @enumFromInt(byte))) {
                    .end => unreachable,
                    .install, .lap_start, .reserve, .start, .extensions_start, .lifecycle_start, .lap_started, .scene, .load, .lap_loaded, .startup_dirty, .start_log => 0,
                    .activate, .lifecycle_activate, .emit_activate => 1,
                    .deactivate, .tooltip_reset, .lifecycle_deactivate, .emit_deactivate => 2,
                    .appearance, .text_generation, .appearance_event => 3,
                    .frame => 4,
                    .lifecycle_stop, .extensions_stop, .mark_stop, .stop, .stop_log => 5,
                    .surface, .surface_window, .surface_layout, .surface_emit, .surface_dirty, .surface_log => 6,
                    .capture_open, .window_update, .window_layout, .window_save, .window_log, .window_close => 7,
                    .focus_window => 8,
                    .focus_view => 9,
                    .dirty => if (f.kind == 8) 8 else 9,
                    .bridge => 10,
                    .tray_log, .command_tray_action => 11,
                    .shortcut_event, .shortcut_emit, .command_shortcut => 12,
                    .command_native_command => 13,
                    .command_menu_command => 14,
                    .command_tray_command => 15,
                    .command_notification_command => 16,
                    .event_timer => 17,
                    .event_wake => 18,
                    .drop_route, .drop_widget, .drop_event, .drop_emit => 19,
                    .command_dirty => if (f.kind == 12) 12 else 19,
                    .capability_gpu_surface_frame => 20,
                    .capability_gpu_surface_resized, .gpu_resize_log => 21,
                    .capability_gpu_surface_input => 22,
                    .capability_gpu_surface_scroll_driver => 23,
                    .capability_context_menu_action => 24,
                    .capability_widget_accessibility_action => 25,
                    .capability_widget_context_menu_action => 26,
                    .event_audio => 27,
                    .event_video => 28,
                };
                if (kind != f.kind) return false;
            } else if (stage == .app_event) {
                if (byte > 5 or byte == 1 and f.kind != 2) return false;
            } else if (byte > (switch (stage) {
                .run => @as(u8, 7),
                .cleanup => 4,
                .journal_enter => 2,
                .journal_exit => 3,
                else => unreachable,
            })) return false;
        }
        return ended;
    }
    const max: u8 = if (stage == .gate and f.kind != 4) 1 else 2;
    return result[0] <= max and (stage != .enter or result[0] != 0) and std.mem.allEqual(u8, result[1..], 0);
}
pub fn gate(callback: *const fn ([]const u8, []u8) usize, kind: u8, a: u8, b: u8) u8 {
    return plan(callback, .gate, .{ .kind = kind, .a = a, .b = b })[0];
}
pub fn eventKind(value: platform.Event) u8 {
    return switch (value) {
        .app_start => 0,
        .app_activated => 1,
        .app_deactivated => 2,
        .appearance_changed => 3,
        .frame_requested => 4,
        .app_shutdown => 5,
        .surface_resized => 6,
        .window_frame_changed => 7,
        .window_focused => 8,
        .view_focused => 9,
        .bridge_message => 10,
        .tray_action => 11,
        .shortcut => 12,
        .native_command => 13,
        .menu_command => 14,
        .tray_command => 15,
        .notification_command => 16,
        .timer => 17,
        .wake => 18,
        .files_dropped => 19,
        .gpu_surface_frame => 20,
        .gpu_surface_resized => 21,
        .gpu_surface_input => 22,
        .gpu_surface_scroll_driver => 23,
        .context_menu_action => 24,
        .widget_accessibility_action => 25,
        .widget_context_menu_action => 26,
        .audio => 27,
        .video => 28,
    };
}
pub fn appKind(value: api.Event) u8 {
    return switch (value) {
        .lifecycle => 0,
        .appearance_changed => 1,
        .command => 2,
        .shortcut => 3,
        .timer => 4,
        .effects_wake => 5,
        .audio => 6,
        .video => 7,
        .files_dropped => 8,
        .gpu_surface_frame => 9,
        .gpu_surface_resized => 10,
        .gpu_surface_input => 11,
        .canvas_widget_pointer => 12,
        .canvas_widget_keyboard => 13,
        .canvas_widget_scroll => 14,
        .canvas_widget_file_drop => 15,
        .canvas_widget_drag => 16,
        .canvas_widget_context_menu => 17,
        .canvas_widget_context_menu_shown => 18,
        .canvas_widget_context_menu_dismissed => 19,
        .canvas_widget_context_menu_request => 20,
        .canvas_widget_dismiss => 21,
        .canvas_widget_context_press => 22,
        .canvas_widget_resize => 23,
        .canvas_widget_change => 24,
        .window_closed => 25,
        .automation_provenance => 26,
    };
}

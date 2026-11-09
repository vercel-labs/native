//! Native capabilities for the compiled snapshot serializer: borrowed values,
//! exact numeric spelling and writer I/O. The compiled program owns traversal,
//! templates, optional fields, ordering and byte escaping.
const std = @import("std");
const geometry = @import("geometry");
const snapshot = @import("snapshot.zig");
const protocol = @import("protocol.zig");
pub const Variant = enum(u8) { full, accessibility, windows };
const Mode = enum(u8) { root, stage, window, view, widget, context_item, command, menu, menu_item, tray, tray_item, segment, chart_value, audio, video, dispatch_error, source };
const Value = union(enum) { empty, bytes: []const u8, unsigned: u64, signed: i64, float32: f32, float64: f64 };
const Slots = struct {
    values: [256]Value = @splat(.empty),
    flags: [256]u8 = @splat(0),
    fn set(self: *Slots, index: usize, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .optional => {
                if (value) |present| {
                    self.set(index, present);
                    self.flags[index] = 1;
                }
            },
            .bool => self.flags[index] = @intFromBool(value),
            .int, .comptime_int => {
                self.values[index] = if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .signed) .{ .signed = @intCast(value) } else .{ .unsigned = @intCast(value) };
                self.flags[index] = @intFromBool(value != 0);
            },
            .float => {
                self.values[index] = if (T == f32) .{ .float32 = value } else .{ .float64 = value };
                self.flags[index] = 1;
            },
            .pointer => {
                self.values[index] = .{ .bytes = value };
                self.flags[index] = @intFromBool(value.len != 0);
            },
            else => @compileError("unsupported snapshot capability value"),
        }
    }
};
const Context = struct { outer: usize = 0, inner: usize = 0 };

pub fn write(input: snapshot.Input, writer: anytype, variant: Variant) !void {
    var slots = Slots{};
    slots.set(0, protocol.fingerprint);
    slots.set(1, input.diagnostics.frame_index);
    slots.set(2, input.diagnostics.command_count);
    slots.set(3, input.diagnostics.runtime_uptime_ns);
    slots.set(4, input.diagnostics.dispatch_error_count);
    slots.set(5, input.diagnostics.dropped_trace_records);
    slots.set(6, input.diagnostics.publisher_pid);
    slots.set(7, input.diagnostics.markup_watch_armed);
    slots.set(8, input.frame_profile != null);
    slots.set(9, input.windows.len + input.views.len + input.widgets.len);
    slots.set(10, input.audio != null);
    slots.set(11, input.video != null);
    slots.set(12, input.source != null);
    try emit(input, writer, variant, .root, &slots, .{});
}

fn emit(input: snapshot.Input, writer: anytype, variant: Variant, mode: Mode, slots: *const Slots, context: Context) anyerror!void {
    var request: [264]u8 = @splat(0);
    request[0..4].* = .{ 29, 1, @intFromEnum(mode), @intFromEnum(variant) };
    @memcpy(request[8..], &slots.flags);
    var program: [16384]u8 = undefined;
    const len = input.serialization_policy.?(&request, &program);
    if (len > program.len) @panic("invalid compiled snapshot program length");
    var at: usize = 0;
    while (at < len) {
        const operation = program[at];
        at += 1;
        switch (operation) {
            0 => {
                if (len - at < 2) @panic("truncated compiled snapshot literal");
                const count = std.mem.readInt(u16, program[at..][0..2], .little);
                at += 2;
                if (count > len - at) @panic("invalid compiled snapshot literal extent");
                try writer.writeAll(program[at..][0..count]);
                at += count;
            },
            1 => {
                if (len - at < 3) @panic("truncated compiled snapshot value");
                const index = std.mem.readInt(u16, program[at..][0..2], .little);
                const format = program[at + 2];
                at += 3;
                if (index >= slots.values.len or format > 5) @panic("invalid compiled snapshot value");
                try writeValue(input, writer, slots.values[index], format);
            },
            2 => {
                if (at == len) @panic("truncated compiled snapshot collection");
                const collection = program[at];
                at += 1;
                try children(input, writer, variant, mode, context, collection);
            },
            else => @panic("invalid compiled snapshot instruction"),
        }
    }
}

fn writeValue(input: snapshot.Input, writer: anytype, value: Value, format: u8) !void {
    if (format == 0 or format == 4 or format == 5) {
        const bytes = switch (value) {
            .bytes => |b| b,
            else => @panic("invalid compiled snapshot byte capability"),
        };
        if (format == 0) return writer.writeAll(bytes);
        var at: usize = 0;
        while (at < bytes.len) {
            const count = @min(bytes.len - at, 256);
            var request: [264]u8 = @splat(0);
            request[0..4].* = .{ 29, 1, if (format == 4) 20 else 21, 0 };
            @memcpy(request[8..][0..count], bytes[at..][0..count]);
            var output: [1536]u8 = undefined;
            const len = input.serialization_policy.?(request[0 .. 8 + count], &output);
            if (len > count * (if (format == 4) @as(usize, 6) else 2)) @panic("invalid compiled snapshot escaped extent");
            try writer.writeAll(output[0..len]);
            at += count;
        }
        return;
    }
    var storage: [512]u8 = undefined;
    var number = std.Io.Writer.fixed(&storage);
    switch (value) {
        .unsigned => |v| switch (format) {
            1 => try number.print("{d}", .{v}),
            2 => try number.print("{x:0>8}", .{v}),
            3 => try number.print("{x:0>16}", .{v}),
            else => unreachable,
        },
        .signed => |v| {
            if (format != 1) @panic("invalid signed snapshot format");
            try number.print("{d}", .{v});
        },
        .float32 => |v| {
            if (format != 1) @panic("invalid floating snapshot format");
            try number.print("{d}", .{v});
        },
        .float64 => |v| {
            if (format != 1) @panic("invalid floating snapshot format");
            try number.print("{d}", .{v});
        },
        else => @panic("invalid compiled snapshot numeric capability"),
    }
    try writer.writeAll(number.buffered());
}

fn children(input: snapshot.Input, writer: anytype, variant: Variant, mode: Mode, context: Context, collection: u8) anyerror!void {
    switch (collection) {
        0 => {
            if (mode != .root) @panic("invalid snapshot stage collection");
            for (input.frame_profile.?.stages, 0..) |_, i| try record(input, writer, variant, .stage, .{ .outer = i });
        },
        1...6, 9 => {
            if (mode != .root) @panic("invalid snapshot root collection");
            const count = switch (collection) {
                1 => input.windows.len,
                2 => input.views.len,
                3 => input.widgets.len,
                4 => input.commands.len,
                5 => input.menus.len,
                6 => input.trays.len,
                9 => input.errors.len,
                else => unreachable,
            };
            const child: Mode = switch (collection) {
                1 => .window,
                2 => .view,
                3 => .widget,
                4 => .command,
                5 => .menu,
                6 => .tray,
                9 => .dispatch_error,
                else => unreachable,
            };
            for (0..count) |i| try record(input, writer, variant, child, .{ .outer = i });
        },
        7, 8, 10 => {
            if (mode != .root) @panic("invalid snapshot optional collection");
            try record(input, writer, variant, switch (collection) {
                7 => .audio,
                8 => .video,
                10 => .source,
                else => unreachable,
            }, .{});
        },
        11 => {
            if (mode != .widget) @panic("invalid snapshot context collection");
            for (input.widgets[context.outer].context_menu, 0..) |_, i| try record(input, writer, variant, .context_item, .{ .outer = context.outer, .inner = i });
        },
        12 => {
            if (mode != .menu) @panic("invalid snapshot menu collection");
            for (input.menus[context.outer].items, 0..) |_, i| try record(input, writer, variant, .menu_item, .{ .outer = context.outer, .inner = i });
        },
        13 => {
            if (mode != .tray) @panic("invalid snapshot tray collection");
            for (input.trays[context.outer].items, 0..) |_, i| try record(input, writer, variant, .tray_item, .{ .outer = context.outer, .inner = i });
        },
        14, 15 => {
            if (mode != .tray_item) @panic("invalid snapshot rich tray collection");
            const item = input.trays[context.outer].items[context.inner];
            const count = if (collection == 14) item.segmented.?.options.len else item.chart.?.values.len;
            for (0..count) |i| try richRecord(input, writer, variant, item, i, collection == 14);
        },
        else => @panic("invalid compiled snapshot collection"),
    }
}

fn record(input: snapshot.Input, writer: anytype, variant: Variant, mode: Mode, context: Context) anyerror!void {
    var s = Slots{};
    switch (mode) {
        .root, .segment, .chart_value => unreachable,
        .stage => {
            const v = input.frame_profile.?.stages[context.outer];
            s.set(0, v.name);
            s.set(1, v.p50_us);
            s.set(2, v.p90_us);
            s.set(3, v.max_us);
            s.set(4, v.count);
        },
        .window => {
            const v = input.windows[context.outer];
            s.set(0, v.id);
            s.set(1, v.title);
            s.set(2, v.bounds.x);
            s.set(3, v.bounds.y);
            s.set(4, v.bounds.width);
            s.set(5, v.bounds.height);
            s.set(6, v.focused);
            s.set(7, input.diagnostics.frame_index);
            s.set(8, input.diagnostics.command_count);
        },
        .view => viewSlots(input, input.views[context.outer], &s),
        .widget => {
            const v = input.widgets[context.outer];
            s.set(0, v.window_id);
            s.set(1, v.view_label);
            s.set(2, v.id);
            s.set(3, v.role);
            s.set(4, v.name);
            s.set(5, v.bounds.x);
            s.set(6, v.bounds.y);
            s.set(7, v.bounds.width);
            s.set(8, v.bounds.height);
            s.set(9, v.focused);
            s.set(10, v.enabled);
            s.set(11, v.parent_id);
            s.set(12, v.value);
            s.set(13, v.text_value);
            s.set(14, v.placeholder);
            s.set(15, v.grid_row_index);
            s.set(16, v.grid_column_index);
            s.set(17, v.grid_row_count);
            s.set(18, v.grid_column_count);
            s.set(19, v.list.present);
            s.set(20, v.list.item_index);
            s.set(21, v.list.item_count);
            s.set(22, v.scroll.present);
            s.set(23, v.scroll.offset);
            s.set(24, v.scroll.viewport_extent);
            s.set(25, v.scroll.content_extent);
            s.set(26, v.virtual_range.present);
            s.set(27, v.virtual_range.start_index);
            s.set(28, v.virtual_range.end_index);
            s.set(29, v.virtual_range.first_visible_index);
            s.set(30, v.virtual_range.last_visible_index);
            s.set(31, v.virtual_range.rendered_count);
            s.set(32, v.focused);
            s.set(33, !v.enabled);
            s.set(34, v.hovered);
            s.set(35, v.pressed);
            s.set(36, v.selected);
            s.set(37, v.expanded != null and v.expanded.?);
            s.set(38, v.expanded != null and !v.expanded.?);
            s.set(39, v.required);
            s.set(40, v.read_only);
            s.set(41, v.invalid);
            s.set(42, v.actions.focus);
            s.set(43, v.actions.press);
            s.set(44, v.actions.toggle);
            s.set(45, v.actions.increment);
            s.set(46, v.actions.decrement);
            s.set(47, v.actions.set_text);
            s.set(48, v.actions.set_selection);
            s.set(49, v.actions.select);
            s.set(50, v.actions.drag);
            s.set(51, v.actions.drop_files);
            s.set(52, v.actions.dismiss);
            s.set(53, v.text_selection != null);
            if (v.text_selection) |range| {
                s.set(54, range.start);
                s.set(55, range.end);
            }
            s.set(56, v.text_composition != null);
            if (v.text_composition) |range| {
                s.set(57, range.start);
                s.set(58, range.end);
            }
            s.set(59, v.context_menu.len != 0);
        },
        .context_item => {
            const v = input.widgets[context.outer].context_menu[context.inner];
            s.set(0, context.inner != 0);
            s.set(1, v.separator);
            s.set(2, v.label);
            s.set(3, v.enabled);
        },
        .command => {
            const v = input.commands[context.outer];
            s.set(0, v.id);
            s.set(1, v.title);
            s.set(2, v.enabled);
            s.set(3, v.checked);
        },
        .menu => {
            const v = input.menus[context.outer];
            s.set(0, v.title);
            s.set(1, v.items.len);
        },
        .menu_item => {
            const v = input.menus[context.outer].items[context.inner];
            s.set(0, v.separator);
            s.set(1, v.label);
            s.set(2, v.command);
            s.set(3, v.enabled);
            s.set(4, v.checked);
            s.set(5, v.key);
            s.set(6, v.modifiers.primary);
            s.set(7, v.modifiers.command);
            s.set(8, v.modifiers.control);
            s.set(9, v.modifiers.option);
            s.set(10, v.modifiers.shift);
        },
        .tray => {
            const v = input.trays[context.outer];
            s.set(0, v.id);
            s.set(1, v.title);
            s.set(2, v.visible);
            s.set(3, v.items.len);
        },
        .tray_item => trayItemSlots(input.trays[context.outer].items[context.inner], &s),
        .audio => {
            const v = input.audio.?;
            s.set(0, v.key);
            s.set(1, v.buffering);
            s.set(2, v.playing);
            s.set(3, v.source);
            s.set(4, v.position_ms);
            s.set(5, v.duration_ms);
            s.set(6, v.spectrum_events);
            s.set(7, v.spectrum_bands);
        },
        .video => {
            const v = input.video.?;
            s.set(0, v.key);
            s.set(1, v.surface);
            s.set(2, v.buffering);
            s.set(3, v.playing);
            s.set(4, v.source);
            s.set(5, v.position_ms);
            s.set(6, v.duration_ms);
            s.set(7, v.width);
            s.set(8, v.height);
            s.set(9, v.looping);
            s.set(10, v.muted);
        },
        .dispatch_error => {
            const v = &input.errors[context.outer];
            s.set(0, v.event());
            s.set(1, v.error_name);
            s.set(2, v.detail());
            s.set(3, v.timestamp_ns);
        },
        .source => {
            const v = input.source.?;
            s.set(0, @tagName(v.kind));
            s.set(1, v.bytes.len);
        },
    }
    try emit(input, writer, variant, mode, &s, context);
}

fn trayItemSlots(v: snapshot.TrayItem, s: *Slots) void {
    s.set(0, v.separator);
    s.set(1, v.id);
    s.set(2, v.segmented != null);
    if (v.segmented) |row| s.set(3, row.options.len);
    s.set(4, v.metric != null);
    if (v.metric) |row| {
        s.set(5, row.primary_text);
        s.set(6, row.secondary_text);
        s.set(7, row.accessibility_label);
    }
    s.set(8, v.chart != null);
    if (v.chart) |row| {
        s.set(9, row.leading_caption);
        s.set(10, row.trailing_summary);
        s.set(11, row.accessibility_label);
        s.set(12, row.min_value);
        s.set(13, row.max_value);
    }
    s.set(14, v.label);
    s.set(15, v.command);
    s.set(16, v.enabled);
    s.set(17, v.detail);
    s.set(18, @tagName(v.role));
    s.set(19, v.key);
    s.set(20, v.modifiers.primary);
    s.set(21, v.modifiers.command);
    s.set(22, v.modifiers.control);
    s.set(23, v.modifiers.option);
    s.set(24, v.modifiers.shift);
}

fn richRecord(input: snapshot.Input, writer: anytype, variant: Variant, item: snapshot.TrayItem, index: usize, segment: bool) anyerror!void {
    var s = Slots{};
    if (segment) {
        const v = item.segmented.?.options[index];
        s.set(0, v.id);
        s.set(1, v.label);
        s.set(2, v.command);
        s.set(3, v.selected);
        s.set(4, v.enabled);
    } else {
        s.set(0, index != 0);
        s.set(1, item.chart.?.values[index]);
    }
    try emit(input, writer, variant, if (segment) .segment else .chart_value, &s, .{});
}

fn viewSlots(input: snapshot.Input, view: @import("../platform/root.zig").ViewInfo, s: *Slots) void {
    s.set(0, view.window_id);
    s.set(1, view.label);
    s.set(2, @tagName(view.kind));
    s.set(3, view.role);
    s.set(4, view.accessibility_label);
    s.set(5, view.text);
    s.set(6, view.frame.x);
    s.set(7, view.frame.y);
    s.set(8, view.frame.width);
    s.set(9, view.frame.height);
    s.set(10, view.layer);
    s.set(11, view.visible);
    s.set(12, view.enabled);
    s.set(13, view.focused);
    s.set(14, view.open);
    s.set(15, view.gpu_size.width);
    s.set(16, view.gpu_size.height);
    s.set(17, view.gpu_scale_factor);
    s.set(18, @tagName(view.gpu_backend));
    s.set(19, @tagName(view.gpu_pixel_format));
    s.set(20, @tagName(view.gpu_present_mode));
    s.set(21, @tagName(view.gpu_alpha_mode));
    s.set(22, @tagName(view.gpu_color_space));
    s.set(23, view.gpu_vsync);
    s.set(24, @tagName(view.gpu_status));
    s.set(25, @tagName(view.gpu_present_path));
    s.set(26, view.gpu_frame_index);
    s.set(27, view.gpu_timestamp_ns);
    s.set(28, view.gpu_frame_interval_ns);
    s.set(29, view.gpu_input_event_count);
    s.set(30, view.gpu_input_timestamp_ns);
    s.set(31, view.gpu_input_latency_ns);
    s.set(32, view.gpu_input_latency_budget_ns);
    s.set(33, view.gpu_input_latency_budget_exceeded_count);
    s.set(34, view.gpu_input_latency_budget_ok);
    s.set(35, view.gpu_first_frame_latency_ns);
    s.set(36, view.gpu_first_frame_latency_budget_ns);
    s.set(37, view.gpu_first_frame_latency_budget_exceeded_count);
    s.set(38, view.gpu_first_frame_latency_budget_ok);
    s.set(39, view.gpu_frame_nonblank);
    s.set(40, view.gpu_occluded);
    s.set(41, view.gpu_sample_color);
    s.set(42, @tagName(view.gpu_present_fallback_reason));
    s.set(43, view.gpu_present_fallback_needed_bytes);
    s.set(44, view.gpu_present_fallback_limit_bytes);
    s.set(45, view.gpu_present_fallback_command_kind);
    s.set(46, view.gpu_present_fallback_frame_count);
    s.set(47, @tagName(view.gpu_present_packet_mode));
    s.set(48, view.gpu_present_patch_bytes);
    s.set(49, view.gpu_present_patch_upsert_count);
    s.set(50, view.gpu_present_patch_evict_count);
    s.set(51, view.gpu_present_retained_command_count);
    s.set(52, view.canvas_revision);
    s.set(53, view.canvas_command_count);
    s.set(54, view.canvas_frame_requires_render);
    s.set(55, view.canvas_frame_full_repaint);
    s.set(56, view.canvas_frame_batch_count);
    s.set(57, view.canvas_frame_encoder_command_count);
    s.set(58, view.canvas_frame_encoder_cache_action_count);
    s.set(59, view.canvas_frame_encoder_bind_pipeline_count);
    s.set(60, view.canvas_frame_encoder_draw_batch_count);
    s.set(61, view.canvas_frame_pipeline_count);
    s.set(62, view.canvas_frame_pipeline_upload_count);
    s.set(63, view.canvas_frame_pipeline_retain_count);
    s.set(64, view.canvas_frame_pipeline_evict_count);
    s.set(65, view.canvas_frame_path_geometry_count);
    s.set(66, view.canvas_frame_path_geometry_vertex_count);
    s.set(67, view.canvas_frame_path_geometry_index_count);
    s.set(68, view.canvas_frame_path_geometry_upload_count);
    s.set(69, view.canvas_frame_path_geometry_retain_count);
    s.set(70, view.canvas_frame_path_geometry_evict_count);
    s.set(71, view.canvas_frame_image_count);
    s.set(72, view.canvas_frame_image_upload_count);
    s.set(73, view.canvas_frame_image_retain_count);
    s.set(74, view.canvas_frame_image_evict_count);
    s.set(75, view.canvas_frame_layer_count);
    s.set(76, view.canvas_frame_layer_opacity_count);
    s.set(77, view.canvas_frame_layer_clip_count);
    s.set(78, view.canvas_frame_layer_transform_count);
    s.set(79, view.canvas_frame_layer_upload_count);
    s.set(80, view.canvas_frame_layer_retain_count);
    s.set(81, view.canvas_frame_layer_evict_count);
    s.set(82, view.canvas_frame_resource_count);
    s.set(83, view.canvas_frame_resource_upload_count);
    s.set(84, view.canvas_frame_resource_retain_count);
    s.set(85, view.canvas_frame_resource_evict_count);
    s.set(86, view.canvas_frame_visual_effect_count);
    s.set(87, view.canvas_frame_visual_effect_shadow_count);
    s.set(88, view.canvas_frame_visual_effect_blur_count);
    s.set(89, view.canvas_frame_visual_effect_upload_count);
    s.set(90, view.canvas_frame_visual_effect_retain_count);
    s.set(91, view.canvas_frame_visual_effect_evict_count);
    s.set(92, view.canvas_frame_glyph_atlas_entry_count);
    s.set(93, view.canvas_frame_glyph_atlas_upload_count);
    s.set(94, view.canvas_frame_glyph_atlas_retain_count);
    s.set(95, view.canvas_frame_glyph_atlas_evict_count);
    s.set(96, view.canvas_frame_text_layout_count);
    s.set(97, view.canvas_frame_text_layout_line_count);
    s.set(98, view.canvas_frame_text_layout_upload_count);
    s.set(99, view.canvas_frame_text_layout_retain_count);
    s.set(100, view.canvas_frame_text_layout_evict_count);
    s.set(101, view.canvas_frame_gpu_packet_command_count);
    s.set(102, view.canvas_frame_gpu_packet_cache_action_count);
    s.set(103, view.canvas_frame_gpu_packet_cached_resource_command_count);
    s.set(104, view.canvas_frame_gpu_packet_unsupported_command_count);
    s.set(105, view.canvas_frame_gpu_packet_representable);
    s.set(106, view.canvas_frame_change_count);
    s.set(107, view.canvas_frame_budget_exceeded_count);
    s.set(108, view.canvas_frame_budget_ok);
    s.set(109, view.widget_node_count);
    s.set(110, input.widget_node_budget);
    s.set(111, view.widget_semantics_count);
    s.set(112, input.widget_semantics_budget);
    s.set(113, view.widget_context_menu_item_count);
    s.set(114, input.widget_context_menu_item_budget);
    s.set(115, view.canvas_frame_text_layout_count);
    s.set(116, input.text_layout_plan_budget);
    s.set(117, view.canvas_frame_text_layout_line_count);
    s.set(118, input.text_layout_line_budget);
    s.set(119, (view.canvas_frame_dirty_bounds orelse geometry.RectF{}).x);
    s.set(120, (view.canvas_frame_dirty_bounds orelse geometry.RectF{}).y);
    s.set(121, (view.canvas_frame_dirty_bounds orelse geometry.RectF{}).width);
    s.set(122, (view.canvas_frame_dirty_bounds orelse geometry.RectF{}).height);
    s.set(123, view.canvas_frame_profile_work_units);
    s.set(124, @tagName(view.canvas_frame_profile_risk));
    s.set(125, view.canvas_frame_profile_surface_area);
    s.set(126, view.canvas_frame_profile_dirty_area);
    s.set(127, view.canvas_frame_profile_dirty_ratio);
    s.set(128, view.widget_revision);
    s.set(129, view.widget_node_count);
    s.set(130, view.widget_semantics_count);
    s.set(131, @tagName(view.cursor));
    s.set(132, view.url);
    s.set(250, view.kind == .gpu_surface);
    s.set(251, view.kind == .webview);
    s.set(252, view.canvas_frame_dirty_bounds != null);
}

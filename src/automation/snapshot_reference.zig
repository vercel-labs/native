//! Independent native text serializer used for reference parity.
const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("snapshot.zig");
const Input = types.Input;
const Widget = types.Widget;
const WidgetActions = types.WidgetActions;
const TextRange = types.TextRange;
pub fn writeText(input: Input, writer: anytype) !void {
    // `protocol=` is the CLI/app handshake: the publishing app
    // stamps ITS baked-in protocol fingerprint so a stale `native`
    // binary (or a stale app) is refused loudly instead of silently
    // driving yesterday's dropbox shape.
    try writer.print("ready=true protocol=0x{x:0>16} frame={d} commands={d} runtime_uptime_ns={d} dispatch_errors={d} dropped_trace_records={d} publisher_pid={d} markup_watch={s}\n", .{
        protocol.fingerprint,
        input.diagnostics.frame_index,
        input.diagnostics.command_count,
        input.diagnostics.runtime_uptime_ns,
        input.diagnostics.dispatch_error_count,
        input.diagnostics.dropped_trace_records,
        input.diagnostics.publisher_pid,
        if (input.diagnostics.markup_watch_armed) "armed" else "off",
    });
    // Per-stage frame timing (`profile on`): rolling p50/p90 in
    // microseconds per pipeline stage, one greppable key per number so
    // harnesses extract them the way the perf script reads gpu_* fields.
    // Stages that recorded nothing yet print zeros with `_n=0`.
    if (input.frame_profile) |profile| {
        try writer.writeAll("frame_profile");
        for (profile.stages) |stage| {
            try writer.print(" {s}_p50_us={d} {s}_p90_us={d} {s}_max_us={d} {s}_n={d}", .{
                stage.name, stage.p50_us,
                stage.name, stage.p90_us,
                stage.name, stage.max_us,
                stage.name, stage.count,
            });
        }
        try writer.writeByte('\n');
    }
    for (input.windows) |window| {
        try writer.print(
            "window @w{d} \"{s}\" bounds=({d},{d} {d}x{d}) focused={any} frame={d} commands={d}\n",
            .{
                window.id,
                window.title,
                window.bounds.x,
                window.bounds.y,
                window.bounds.width,
                window.bounds.height,
                window.focused,
                input.diagnostics.frame_index,
                input.diagnostics.command_count,
            },
        );
    }
    for (input.views) |view| {
        try writer.print(
            "  view @w{d}/{s} kind={s} role=\"{s}\" accessibility_label=\"{s}\" text=\"{s}\" bounds=({d},{d} {d}x{d}) layer={d} visible={any} enabled={any} focused={any} open={any}",
            .{
                view.window_id,
                view.label,
                @tagName(view.kind),
                view.role,
                view.accessibility_label,
                view.text,
                view.frame.x,
                view.frame.y,
                view.frame.width,
                view.frame.height,
                view.layer,
                view.visible,
                view.enabled,
                view.focused,
                view.open,
            },
        );
        if (view.kind == .gpu_surface) {
            try writer.print(" gpu_size={d}x{d} gpu_scale={d} gpu_backend={s} gpu_pixel_format={s} gpu_present_mode={s} gpu_alpha_mode={s} gpu_color_space={s} gpu_vsync={any} gpu_status={s} gpu_present_path={s} gpu_frame={d} gpu_timestamp_ns={d} gpu_frame_interval_ns={d} gpu_input_count={d} gpu_input_timestamp_ns={d} gpu_input_latency_ns={d} gpu_input_latency_budget_ns={d} gpu_input_latency_budget_exceeded={d} gpu_input_latency_budget_ok={any} gpu_first_frame_latency_ns={d} gpu_first_frame_latency_budget_ns={d} gpu_first_frame_latency_budget_exceeded={d} gpu_first_frame_latency_budget_ok={any} gpu_nonblank={any} gpu_occluded={any} gpu_sample=0x{x:0>8}", .{
                view.gpu_size.width,
                view.gpu_size.height,
                view.gpu_scale_factor,
                @tagName(view.gpu_backend),
                @tagName(view.gpu_pixel_format),
                @tagName(view.gpu_present_mode),
                @tagName(view.gpu_alpha_mode),
                @tagName(view.gpu_color_space),
                view.gpu_vsync,
                @tagName(view.gpu_status),
                @tagName(view.gpu_present_path),
                view.gpu_frame_index,
                view.gpu_timestamp_ns,
                view.gpu_frame_interval_ns,
                view.gpu_input_event_count,
                view.gpu_input_timestamp_ns,
                view.gpu_input_latency_ns,
                view.gpu_input_latency_budget_ns,
                view.gpu_input_latency_budget_exceeded_count,
                view.gpu_input_latency_budget_ok,
                view.gpu_first_frame_latency_ns,
                view.gpu_first_frame_latency_budget_ns,
                view.gpu_first_frame_latency_budget_exceeded_count,
                view.gpu_first_frame_latency_budget_ok,
                view.gpu_frame_nonblank,
                view.gpu_occluded,
                view.gpu_sample_color,
            });
            // Packet-fallback telemetry: WHY the last packet attempt
            // fell back to the CPU pixel path (overflow byte math or the
            // offending command kind) plus a running fallback-frame
            // counter that never resets, so oscillation between the two
            // render paths is visible even when the snapshot lands on a
            // healthy frame.
            try writer.print(" present_fallback={s} present_fallback_needed={d} present_fallback_limit={d} present_fallback_command=\"{s}\" present_fallback_frames={d}", .{
                @tagName(view.gpu_present_fallback_reason),
                view.gpu_present_fallback_needed_bytes,
                view.gpu_present_fallback_limit_bytes,
                view.gpu_present_fallback_command_kind,
                view.gpu_present_fallback_frame_count,
            });
            // Incremental-presentation telemetry: whether the last packet
            // present shipped the full command list or a patch against
            // the host's retained dictionary, the patch's bytes and edit
            // counts, and how many commands the host currently retains —
            // the numbers that make "frame cost scales with what changed"
            // observable instead of asserted.
            try writer.print(" present_mode={s} present_patch_bytes={d} present_patch_upserts={d} present_patch_evicts={d} present_retained_commands={d}", .{
                @tagName(view.gpu_present_packet_mode),
                view.gpu_present_patch_bytes,
                view.gpu_present_patch_upsert_count,
                view.gpu_present_patch_evict_count,
                view.gpu_present_retained_command_count,
            });
            try writer.print(" canvas_revision={d} canvas_commands={d} canvas_frame_requires_render={any} canvas_frame_full_repaint={any} canvas_frame_batches={d} canvas_frame_encoder_commands={d} canvas_frame_encoder_cache_actions={d} canvas_frame_encoder_pipeline_binds={d} canvas_frame_encoder_draws={d} canvas_frame_pipelines={d} canvas_frame_pipeline_uploads={d} canvas_frame_pipeline_retains={d} canvas_frame_pipeline_evicts={d}", .{
                view.canvas_revision,
                view.canvas_command_count,
                view.canvas_frame_requires_render,
                view.canvas_frame_full_repaint,
                view.canvas_frame_batch_count,
                view.canvas_frame_encoder_command_count,
                view.canvas_frame_encoder_cache_action_count,
                view.canvas_frame_encoder_bind_pipeline_count,
                view.canvas_frame_encoder_draw_batch_count,
                view.canvas_frame_pipeline_count,
                view.canvas_frame_pipeline_upload_count,
                view.canvas_frame_pipeline_retain_count,
                view.canvas_frame_pipeline_evict_count,
            });
            try writer.print(" canvas_frame_path_geometries={d} canvas_frame_path_vertices={d} canvas_frame_path_indices={d} canvas_frame_path_uploads={d} canvas_frame_path_retains={d} canvas_frame_path_evicts={d} canvas_frame_images={d} canvas_frame_image_uploads={d} canvas_frame_image_retains={d} canvas_frame_image_evicts={d}", .{
                view.canvas_frame_path_geometry_count,
                view.canvas_frame_path_geometry_vertex_count,
                view.canvas_frame_path_geometry_index_count,
                view.canvas_frame_path_geometry_upload_count,
                view.canvas_frame_path_geometry_retain_count,
                view.canvas_frame_path_geometry_evict_count,
                view.canvas_frame_image_count,
                view.canvas_frame_image_upload_count,
                view.canvas_frame_image_retain_count,
                view.canvas_frame_image_evict_count,
            });
            try writer.print(" canvas_frame_layers={d} canvas_frame_opacity_layers={d} canvas_frame_clip_layers={d} canvas_frame_transform_layers={d} canvas_frame_layer_uploads={d} canvas_frame_layer_retains={d} canvas_frame_layer_evicts={d}", .{
                view.canvas_frame_layer_count,
                view.canvas_frame_layer_opacity_count,
                view.canvas_frame_layer_clip_count,
                view.canvas_frame_layer_transform_count,
                view.canvas_frame_layer_upload_count,
                view.canvas_frame_layer_retain_count,
                view.canvas_frame_layer_evict_count,
            });
            try writer.print(" canvas_frame_resources={d} canvas_frame_uploads={d} canvas_frame_retains={d} canvas_frame_evicts={d} canvas_frame_effects={d} canvas_frame_shadows={d} canvas_frame_blurs={d} canvas_frame_effect_uploads={d} canvas_frame_effect_retains={d} canvas_frame_effect_evicts={d}", .{
                view.canvas_frame_resource_count,
                view.canvas_frame_resource_upload_count,
                view.canvas_frame_resource_retain_count,
                view.canvas_frame_resource_evict_count,
                view.canvas_frame_visual_effect_count,
                view.canvas_frame_visual_effect_shadow_count,
                view.canvas_frame_visual_effect_blur_count,
                view.canvas_frame_visual_effect_upload_count,
                view.canvas_frame_visual_effect_retain_count,
                view.canvas_frame_visual_effect_evict_count,
            });
            try writer.print(" canvas_frame_glyphs={d} canvas_frame_glyph_uploads={d} canvas_frame_glyph_retains={d} canvas_frame_glyph_evicts={d} canvas_frame_text_layouts={d} canvas_frame_text_lines={d} canvas_frame_text_uploads={d} canvas_frame_text_retains={d} canvas_frame_text_evicts={d}", .{
                view.canvas_frame_glyph_atlas_entry_count,
                view.canvas_frame_glyph_atlas_upload_count,
                view.canvas_frame_glyph_atlas_retain_count,
                view.canvas_frame_glyph_atlas_evict_count,
                view.canvas_frame_text_layout_count,
                view.canvas_frame_text_layout_line_count,
                view.canvas_frame_text_layout_upload_count,
                view.canvas_frame_text_layout_retain_count,
                view.canvas_frame_text_layout_evict_count,
            });
            try writer.print(" canvas_frame_gpu_packet_commands={d} canvas_frame_gpu_packet_cache_actions={d} canvas_frame_gpu_packet_cached_resources={d} canvas_frame_gpu_packet_unsupported={d} canvas_frame_gpu_packet_representable={any}", .{
                view.canvas_frame_gpu_packet_command_count,
                view.canvas_frame_gpu_packet_cache_action_count,
                view.canvas_frame_gpu_packet_cached_resource_command_count,
                view.canvas_frame_gpu_packet_unsupported_command_count,
                view.canvas_frame_gpu_packet_representable,
            });
            try writer.print(" canvas_frame_changes={d} canvas_frame_budget_exceeded={d} canvas_frame_budget_ok={any}", .{
                view.canvas_frame_change_count,
                view.canvas_frame_budget_exceeded_count,
                view.canvas_frame_budget_ok,
            });
            // Widget budget headroom telemetry (node and context-menu
            // budgets):
            // current retained node/semantics/context-menu-item counts
            // against the per-view budgets, so authors see the cliff
            // coming instead of bisecting overflow by hand. The budgets
            // ride on Input because this module cannot import the
            // runtime's canvas_limits.
            try writer.print(" widget_nodes={d}/{d} widget_semantics={d}/{d} context_menu_items={d}/{d}", .{
                view.widget_node_count,
                input.widget_node_budget,
                view.widget_semantics_count,
                input.widget_semantics_budget,
                view.widget_context_menu_item_count,
                input.widget_context_menu_item_budget,
            });
            // Text-layout plan headroom: the last planned frame's
            // text runs and wrapped lines against the per-frame budgets,
            // so a growing transcript shows the cliff here before a frame
            // dies with TextLayoutPlanListFull/TextLayoutLineListFull (a
            // failed plan also lands in the dispatch-error ring above).
            try writer.print(" text_layout_plans={d}/{d} text_layout_lines={d}/{d}", .{
                view.canvas_frame_text_layout_count,
                input.text_layout_plan_budget,
                view.canvas_frame_text_layout_line_count,
                input.text_layout_line_budget,
            });
            if (view.canvas_frame_dirty_bounds) |dirty| {
                try writer.print(" canvas_frame_dirty=({d},{d} {d}x{d})", .{ dirty.x, dirty.y, dirty.width, dirty.height });
            } else {
                try writer.writeAll(" canvas_frame_dirty=null");
            }
            try writer.print(" canvas_frame_profile_work_units={d} canvas_frame_profile_risk={s} canvas_frame_profile_surface_area={d} canvas_frame_profile_dirty_area={d} canvas_frame_profile_dirty_ratio={d}", .{
                view.canvas_frame_profile_work_units,
                @tagName(view.canvas_frame_profile_risk),
                view.canvas_frame_profile_surface_area,
                view.canvas_frame_profile_dirty_area,
                view.canvas_frame_profile_dirty_ratio,
            });
            try writer.print(" widget_revision={d} widget_nodes={d} widget_semantics={d}", .{
                view.widget_revision,
                view.widget_node_count,
                view.widget_semantics_count,
            });
            try writer.print(" widget_cursor={s}", .{@tagName(view.cursor)});
        }
        if (view.kind == .webview) {
            try writer.print(" url=\"{s}\"", .{view.url});
        }
        try writer.writeByte('\n');
    }
    for (input.widgets) |widget| {
        try writer.print(
            "    widget @w{d}/{s}#{d} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d}) focused={any} enabled={any}",
            .{
                widget.window_id,
                widget.view_label,
                widget.id,
                widget.role,
                widget.name,
                widget.bounds.x,
                widget.bounds.y,
                widget.bounds.width,
                widget.bounds.height,
                widget.focused,
                widget.enabled,
            },
        );
        try writeWidgetParent(widget, writer);
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetTextValue(widget, writer);
        try writeWidgetPlaceholder(widget, writer);
        try writeWidgetGrid(widget, writer);
        try writeWidgetList(widget, writer);
        try writeWidgetScroll(widget, writer);
        try writeWidgetVirtualRange(widget, writer);
        try writeWidgetState(widget, writer);
        try writeWidgetActions(widget.actions, writer);
        try writeWidgetTextRanges(widget, writer);
        try writeWidgetContextMenu(widget, writer);
        try writer.writeByte('\n');
    }
    for (input.commands) |command| {
        try writer.writeAll("command id=");
        try writeQuotedSnapshotText(command.id, writer);
        try writer.writeAll(" title=");
        try writeQuotedSnapshotText(command.title, writer);
        try writer.print(" enabled={any} checked={any}\n", .{ command.enabled, command.checked });
    }
    for (input.menus) |menu| {
        try writer.writeAll("app-menu title=");
        try writeQuotedSnapshotText(menu.title, writer);
        try writer.print(" items={d}\n", .{menu.items.len});
        for (menu.items) |item| {
            if (item.separator) {
                try writer.writeAll("  app-menu-item separator\n");
                continue;
            }
            try writer.writeAll("  app-menu-item label=");
            try writeQuotedSnapshotText(item.label, writer);
            try writer.writeAll(" command=");
            try writeQuotedSnapshotText(item.command, writer);
            try writer.print(" enabled={any} checked={any} key=", .{
                item.enabled,
                item.checked,
            });
            try writeQuotedSnapshotText(item.key, writer);
            try writer.print(" modifiers=(primary={any},command={any},control={any},option={any},shift={any})\n", .{
                item.modifiers.primary,
                item.modifiers.command,
                item.modifiers.control,
                item.modifiers.option,
                item.modifiers.shift,
            });
        }
    }
    for (input.trays) |tray| {
        try writer.print("tray #{d} title=\"{s}\" visible={any} items={d}\n", .{ tray.id, tray.title, tray.visible, tray.items.len });
        for (tray.items) |item| {
            if (item.separator) {
                try writer.writeAll("  tray-item separator\n");
                continue;
            }
            if (item.segmented) |segmented| {
                try writer.print("  tray-item #{d} role=segmented options={d}\n", .{ item.id, segmented.options.len });
                for (segmented.options) |option| {
                    try writer.print("    tray-segment #{d} label=", .{option.id});
                    try writeQuotedSnapshotText(option.label, writer);
                    try writer.writeAll(" command=");
                    try writeQuotedSnapshotText(option.command, writer);
                    try writer.print(" selected={any} enabled={any}\n", .{ option.selected, option.enabled });
                }
                continue;
            }
            if (item.metric) |metric| {
                try writer.print("  tray-item #{d} role=metric primary=", .{item.id});
                try writeQuotedSnapshotText(metric.primary_text, writer);
                try writer.writeAll(" secondary=");
                try writeQuotedSnapshotText(metric.secondary_text, writer);
                try writer.writeAll(" accessibility=");
                try writeQuotedSnapshotText(metric.accessibility_label, writer);
                try writer.writeByte('\n');
                continue;
            }
            if (item.chart) |chart| {
                try writer.print("  tray-item #{d} role=chart caption=", .{item.id});
                try writeQuotedSnapshotText(chart.leading_caption, writer);
                try writer.writeAll(" summary=");
                try writeQuotedSnapshotText(chart.trailing_summary, writer);
                try writer.writeAll(" accessibility=");
                try writeQuotedSnapshotText(chart.accessibility_label, writer);
                try writer.print(" domain=({d},{d}) values=", .{ chart.min_value, chart.max_value });
                for (chart.values, 0..) |value, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writer.print("{d}", .{value});
                }
                try writer.writeByte('\n');
                continue;
            }
            try writer.print("  tray-item #{d} label=\"{s}\" command=\"{s}\" enabled={any} detail=\"{s}\" role={s} key=\"{s}\" modifiers=(primary={any},command={any},control={any},option={any},shift={any})\n", .{
                item.id,
                item.label,
                item.command,
                item.enabled,
                item.detail,
                @tagName(item.role),
                item.key,
                item.modifiers.primary,
                item.modifiers.command,
                item.modifiers.control,
                item.modifiers.option,
                item.modifiers.shift,
            });
        }
    }
    if (input.audio) |audio| {
        try writer.print("audio key={d} state={s} source={s} position_ms={d} duration_ms={d} spectrum_events={d}", .{
            audio.key,
            // Buffering is the honest third state: the transport is not
            // paused, but a stalled stream is not audibly playing either.
            if (audio.buffering) "buffering" else if (audio.playing) "playing" else "paused",
            audio.source,
            audio.position_ms,
            audio.duration_ms,
            audio.spectrum_events,
        });
        // Band bytes print only once analysis has actually delivered —
        // a host that cannot analyze shows `spectrum_events=0` and no
        // bands line noise (honest absence, not a row of fake zeros).
        if (audio.spectrum_events > 0) {
            try writer.print(" spectrum_bands={x}", .{audio.spectrum_bands});
        }
        try writer.print("\n", .{});
    }
    if (input.video) |video| {
        try writer.print("video key={d} surface={d} state={s} source={s} position_ms={d} duration_ms={d} dimensions={d}x{d} loop={any} muted={any}\n", .{
            video.key,
            video.surface,
            // The audio line's honest third state, verbatim.
            if (video.buffering) "buffering" else if (video.playing) "playing" else "paused",
            video.source,
            video.position_ms,
            video.duration_ms,
            video.width,
            video.height,
            video.looping,
            video.muted,
        });
    }
    for (input.errors) |dispatch_error| {
        if (dispatch_error.detail_len > 0) {
            try writer.print("  error event={s} name={s} detail=\"{s}\" timestamp_ns={d}\n", .{
                dispatch_error.event(),
                dispatch_error.error_name,
                dispatch_error.detail(),
                dispatch_error.timestamp_ns,
            });
        } else {
            try writer.print("  error event={s} name={s} timestamp_ns={d}\n", .{
                dispatch_error.event(),
                dispatch_error.error_name,
                dispatch_error.timestamp_ns,
            });
        }
    }
    if (input.source) |source| {
        try writer.print("  source kind={s} bytes={d}\n", .{ @tagName(source.kind), source.bytes.len });
    }
}

pub fn writeA11yText(input: Input, writer: anytype) !void {
    try writer.print("a11y root=@w1 nodes={d}\n", .{input.windows.len + input.views.len + input.widgets.len});
    for (input.windows) |window| {
        try writer.print("@w{d} role=window name=\"{s}\" bounds=({d},{d} {d}x{d})\n", .{
            window.id,
            window.title,
            window.bounds.x,
            window.bounds.y,
            window.bounds.width,
            window.bounds.height,
        });
    }
    for (input.views) |view| {
        const role = if (view.role.len > 0) view.role else @tagName(view.kind);
        const name = if (view.accessibility_label.len > 0) view.accessibility_label else if (view.text.len > 0) view.text else view.label;
        try writer.print("@w{d}/{s} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d})\n", .{
            view.window_id,
            view.label,
            role,
            name,
            view.frame.x,
            view.frame.y,
            view.frame.width,
            view.frame.height,
        });
    }
    for (input.widgets) |widget| {
        try writer.print("@w{d}/{s}#{d} role={s} name=\"{s}\" bounds=({d},{d} {d}x{d})", .{
            widget.window_id,
            widget.view_label,
            widget.id,
            widget.role,
            widget.name,
            widget.bounds.x,
            widget.bounds.y,
            widget.bounds.width,
            widget.bounds.height,
        });
        try writeWidgetParent(widget, writer);
        if (widget.value) |value| try writer.print(" value={d}", .{value});
        try writeWidgetTextValue(widget, writer);
        try writeWidgetGrid(widget, writer);
        try writeWidgetList(widget, writer);
        try writeWidgetScroll(widget, writer);
        try writeWidgetVirtualRange(widget, writer);
        try writeWidgetState(widget, writer);
        try writeWidgetActions(widget.actions, writer);
        try writeWidgetTextRanges(widget, writer);
        try writeWidgetContextMenu(widget, writer);
        try writer.writeByte('\n');
    }
}

/// Catalog values are user-authored but snapshots are line-oriented. Keep
/// each configured command/menu record on exactly one line and preserve its
/// byte identity with JSON-style escapes for delimiters and control bytes.
fn writeQuotedSnapshotText(value: []const u8, writer: anytype) !void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20 or byte == 0x7f) {
                try writer.writeAll("\\u00");
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 0x0f]);
            } else {
                try writer.writeByte(byte);
            },
        }
    }
    try writer.writeByte('"');
}

fn writeWidgetParent(widget: Widget, writer: anytype) !void {
    if (widget.parent_id) |parent_id| try writer.print(" parent=#{d}", .{parent_id});
}

fn writeWidgetTextValue(widget: Widget, writer: anytype) !void {
    if (widget.text_value.len == 0) return;
    try writer.print(" text=\"{s}\"", .{widget.text_value});
}

fn writeWidgetPlaceholder(widget: Widget, writer: anytype) !void {
    if (widget.placeholder.len == 0) return;
    try writer.print(" placeholder=\"{s}\"", .{widget.placeholder});
}

fn writeWidgetGrid(widget: Widget, writer: anytype) !void {
    if (widget.grid_row_index == null and
        widget.grid_column_index == null and
        widget.grid_row_count == null and
        widget.grid_column_count == null) return;

    try writer.writeAll(" grid=[");
    var wrote = false;
    try writeWidgetGridValue("row_index", widget.grid_row_index, &wrote, writer);
    try writeWidgetGridValue("column_index", widget.grid_column_index, &wrote, writer);
    try writeWidgetGridValue("row_count", widget.grid_row_count, &wrote, writer);
    try writeWidgetGridValue("column_count", widget.grid_column_count, &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetGridValue(name: []const u8, value: ?usize, wrote: *bool, writer: anytype) !void {
    const unwrapped = value orelse return;
    if (wrote.*) try writer.writeByte(',');
    try writer.print("{s}={d}", .{ name, unwrapped });
    wrote.* = true;
}

fn writeWidgetList(widget: Widget, writer: anytype) !void {
    if (!widget.list.present) return;
    try writer.print(" list=[index={d},count={d}]", .{ widget.list.item_index, widget.list.item_count });
}

fn writeWidgetScroll(widget: Widget, writer: anytype) !void {
    if (!widget.scroll.present) return;
    try writer.print(" scroll=[offset={d},viewport={d},content={d}]", .{
        widget.scroll.offset,
        widget.scroll.viewport_extent,
        widget.scroll.content_extent,
    });
}

fn writeWidgetVirtualRange(widget: Widget, writer: anytype) !void {
    if (!widget.virtual_range.present) return;
    try writer.print(" virtual=[start={d},end={d},first={d},last={d},rendered={d}]", .{
        widget.virtual_range.start_index,
        widget.virtual_range.end_index,
        widget.virtual_range.first_visible_index,
        widget.virtual_range.last_visible_index,
        widget.virtual_range.rendered_count,
    });
}

fn writeWidgetState(widget: Widget, writer: anytype) !void {
    if (!widget.focused and
        widget.enabled and
        !widget.hovered and
        !widget.pressed and
        !widget.selected and
        widget.expanded == null and
        !widget.required and
        !widget.read_only and
        !widget.invalid) return;
    try writer.writeAll(" state=[");
    var wrote = false;
    try writeWidgetStateFlag(widget.focused, "focused", &wrote, writer);
    try writeWidgetStateFlag(!widget.enabled, "disabled", &wrote, writer);
    try writeWidgetStateFlag(widget.hovered, "hovered", &wrote, writer);
    try writeWidgetStateFlag(widget.pressed, "pressed", &wrote, writer);
    try writeWidgetStateFlag(widget.selected, "selected", &wrote, writer);
    if (widget.expanded) |expanded| {
        try writeWidgetStateFlag(true, if (expanded) "expanded" else "collapsed", &wrote, writer);
    }
    try writeWidgetStateFlag(widget.required, "required", &wrote, writer);
    try writeWidgetStateFlag(widget.read_only, "read_only", &wrote, writer);
    try writeWidgetStateFlag(widget.invalid, "invalid", &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetStateFlag(enabled: bool, name: []const u8, wrote: *bool, writer: anytype) !void {
    if (!enabled) return;
    if (wrote.*) try writer.writeByte(',');
    try writer.writeAll(name);
    wrote.* = true;
}

fn writeWidgetActions(actions: WidgetActions, writer: anytype) !void {
    if (actions.isEmpty()) return;
    try writer.writeAll(" actions=[");
    var wrote = false;
    try writeWidgetAction(actions.focus, "focus", &wrote, writer);
    try writeWidgetAction(actions.press, "press", &wrote, writer);
    try writeWidgetAction(actions.toggle, "toggle", &wrote, writer);
    try writeWidgetAction(actions.increment, "increment", &wrote, writer);
    try writeWidgetAction(actions.decrement, "decrement", &wrote, writer);
    try writeWidgetAction(actions.set_text, "set_text", &wrote, writer);
    try writeWidgetAction(actions.set_selection, "set_selection", &wrote, writer);
    try writeWidgetAction(actions.select, "select", &wrote, writer);
    try writeWidgetAction(actions.drag, "drag", &wrote, writer);
    try writeWidgetAction(actions.drop_files, "drop_files", &wrote, writer);
    try writeWidgetAction(actions.dismiss, "dismiss", &wrote, writer);
    try writer.writeByte(']');
}

fn writeWidgetAction(enabled: bool, name: []const u8, wrote: *bool, writer: anytype) !void {
    if (!enabled) return;
    if (wrote.*) try writer.writeByte(',');
    try writer.writeAll(name);
    wrote.* = true;
}

fn writeWidgetTextRanges(widget: Widget, writer: anytype) !void {
    if (widget.text_selection) |selection| try writer.print(" selection={d}..{d}", .{ selection.start, selection.end });
    if (widget.text_composition) |composition| try writer.print(" composition={d}..{d}", .{ composition.start, composition.end });
}

/// The widget's declared context-menu items: quoted labels in declared
/// order (list position = the `widget-context-menu` item index), bare
/// `separator` for divider slots, `(disabled)` marking items a real
/// menu would grey out.
fn writeWidgetContextMenu(widget: Widget, writer: anytype) !void {
    if (widget.context_menu.len == 0) return;
    try writer.writeAll(" context_menu=[");
    for (widget.context_menu, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        if (item.separator) {
            try writer.writeAll("separator");
            continue;
        }
        try writer.print("\"{s}\"", .{item.label});
        if (!item.enabled) try writer.writeAll("(disabled)");
    }
    try writer.writeByte(']');
}

pub fn writeWindowsText(input: Input, writer: anytype) !void {
    for (input.windows) |window| try writer.print("window @w{d} \"{s}\" focused={any}\n", .{ window.id, window.title, window.focused });
}

const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");
const app_manifest = @import("app_manifest");
const bridge = @import("../bridge/root.zig");
const platform = @import("../platform/root.zig");

pub fn writeWindowJson(window: platform.WindowInfo, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeWindowJsonToWriter(window, &writer);
    return writer.buffered();
}

pub fn writeTrueJson(output: []u8) ![]const u8 {
    return writeBoolJson(true, output);
}

pub fn writeBoolJson(value: bool, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(if (value) "true" else "false");
    return writer.buffered();
}

pub fn writeWebViewOkJson(label: []const u8, window_id: platform.WindowId, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"label\":");
    try json.writeString(&writer, label);
    try writer.print(",\"windowId\":{d}}}", .{window_id});
    return writer.buffered();
}

pub fn writeWebViewJson(webview: anytype, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeWebViewJsonToWriter(webview, &writer);
    return writer.buffered();
}

pub fn writeViewJson(view: platform.ViewInfo, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeViewJsonToWriter(view, &writer);
    return writer.buffered();
}

pub fn writeCommandEventJson(event_value: anytype, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"name\":");
    try json.writeString(&writer, event_value.name);
    try writer.writeAll(",\"source\":");
    try json.writeString(&writer, @tagName(event_value.source));
    try writer.print(",\"windowId\":{d},\"viewLabel\":", .{event_value.window_id});
    try json.writeString(&writer, event_value.view_label);
    try writer.print(",\"trayItemId\":{d}", .{event_value.tray_item_id});
    try writer.writeByte('}');
    return writer.buffered();
}

pub fn writeCommandJsonToWriter(command: app_manifest.Command, writer: anytype) !void {
    try writer.writeAll("{\"id\":");
    try json.writeString(writer, command.id);
    try writer.writeAll(",\"title\":");
    try json.writeString(writer, command.title);
    try writer.print(",\"enabled\":{},\"checked\":{}}}", .{ command.enabled, command.checked });
}

pub fn writeViewJsonToWriter(view: platform.ViewInfo, writer: anytype) !void {
    try writer.print("{{\"id\":{d},\"label\":", .{view.id});
    try json.writeString(writer, view.label);
    try writer.print(",\"windowId\":{d},\"kind\":", .{view.window_id});
    try json.writeString(writer, @tagName(view.kind));
    try writer.writeAll(",\"parent\":");
    if (view.parent) |parent| {
        try json.writeString(writer, parent);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"role\":");
    try json.writeString(writer, view.role);
    try writer.writeAll(",\"accessibilityLabel\":");
    try json.writeString(writer, view.accessibility_label);
    try writer.writeAll(",\"text\":");
    try json.writeString(writer, view.text);
    try writer.writeAll(",\"command\":");
    try json.writeString(writer, view.command);
    try writer.writeAll(",\"url\":");
    try json.writeString(writer, view.url);
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"layer\":{d},\"visible\":{},\"enabled\":{},\"transparent\":{},\"bridge\":{},\"gpuWidth\":{d},\"gpuHeight\":{d},\"gpuScale\":{d},\"gpuFrame\":{d},\"gpuTimestampNs\":{d},\"gpuFrameIntervalNs\":{d},\"gpuInputTimestampNs\":{d},\"gpuInputLatencyNs\":{d},\"gpuInputLatencyBudgetNs\":{d},\"gpuInputLatencyBudgetExceededCount\":{d},\"gpuInputLatencyBudgetOk\":{},\"gpuFirstFrameLatencyNs\":{d},\"gpuFirstFrameLatencyBudgetNs\":{d},\"gpuFirstFrameLatencyBudgetExceededCount\":{d},\"gpuFirstFrameLatencyBudgetOk\":{},\"gpuNonblank\":{},\"gpuSampleColor\":{d},\"gpuBackend\":", .{
        view.frame.x,
        view.frame.y,
        view.frame.width,
        view.frame.height,
        view.layer,
        view.visible,
        view.enabled,
        view.transparent,
        view.bridge_enabled,
        view.gpu_size.width,
        view.gpu_size.height,
        view.gpu_scale_factor,
        view.gpu_frame_index,
        view.gpu_timestamp_ns,
        view.gpu_frame_interval_ns,
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
        view.gpu_sample_color,
    });
    try json.writeString(writer, @tagName(view.gpu_backend));
    try writer.writeAll(",\"gpuPixelFormat\":");
    try json.writeString(writer, @tagName(view.gpu_pixel_format));
    try writer.writeAll(",\"gpuPresentMode\":");
    try json.writeString(writer, @tagName(view.gpu_present_mode));
    try writer.writeAll(",\"gpuAlphaMode\":");
    try json.writeString(writer, @tagName(view.gpu_alpha_mode));
    try writer.writeAll(",\"gpuColorSpace\":");
    try json.writeString(writer, @tagName(view.gpu_color_space));
    try writer.print(",\"gpuVsync\":{}", .{view.gpu_vsync});
    try writer.writeAll(",\"gpuStatus\":");
    try json.writeString(writer, @tagName(view.gpu_status));
    try writer.print(",\"canvasRevision\":{d},\"canvasCommandCount\":{d},\"canvasFrameRequiresRender\":{},\"canvasFrameFullRepaint\":{},\"canvasFrameBatchCount\":{d}", .{
        view.canvas_revision,
        view.canvas_command_count,
        view.canvas_frame_requires_render,
        view.canvas_frame_full_repaint,
        view.canvas_frame_batch_count,
    });
    try writer.print(",\"canvasFrameEncoderCommandCount\":{d},\"canvasFrameEncoderCacheActionCount\":{d},\"canvasFrameEncoderBindPipelineCount\":{d},\"canvasFrameEncoderDrawBatchCount\":{d},\"canvasFramePipelineCount\":{d},\"canvasFramePipelineUploadCount\":{d},\"canvasFramePipelineRetainCount\":{d},\"canvasFramePipelineEvictCount\":{d}", .{
        view.canvas_frame_encoder_command_count,
        view.canvas_frame_encoder_cache_action_count,
        view.canvas_frame_encoder_bind_pipeline_count,
        view.canvas_frame_encoder_draw_batch_count,
        view.canvas_frame_pipeline_count,
        view.canvas_frame_pipeline_upload_count,
        view.canvas_frame_pipeline_retain_count,
        view.canvas_frame_pipeline_evict_count,
    });
    try writer.print(",\"canvasFramePathGeometryCount\":{d},\"canvasFramePathGeometryVertexCount\":{d},\"canvasFramePathGeometryIndexCount\":{d},\"canvasFramePathGeometryUploadCount\":{d},\"canvasFramePathGeometryRetainCount\":{d},\"canvasFramePathGeometryEvictCount\":{d},\"canvasFrameImageCount\":{d},\"canvasFrameImageUploadCount\":{d},\"canvasFrameImageRetainCount\":{d},\"canvasFrameImageEvictCount\":{d}", .{
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
    try writer.print(",\"canvasFrameLayerCount\":{d},\"canvasFrameLayerOpacityCount\":{d},\"canvasFrameLayerClipCount\":{d},\"canvasFrameLayerTransformCount\":{d},\"canvasFrameLayerUploadCount\":{d},\"canvasFrameLayerRetainCount\":{d},\"canvasFrameLayerEvictCount\":{d}", .{
        view.canvas_frame_layer_count,
        view.canvas_frame_layer_opacity_count,
        view.canvas_frame_layer_clip_count,
        view.canvas_frame_layer_transform_count,
        view.canvas_frame_layer_upload_count,
        view.canvas_frame_layer_retain_count,
        view.canvas_frame_layer_evict_count,
    });
    try writer.print(",\"canvasFrameResourceCount\":{d},\"canvasFrameResourceUploadCount\":{d},\"canvasFrameResourceRetainCount\":{d},\"canvasFrameResourceEvictCount\":{d},\"canvasFrameVisualEffectCount\":{d},\"canvasFrameVisualEffectShadowCount\":{d},\"canvasFrameVisualEffectBlurCount\":{d},\"canvasFrameVisualEffectUploadCount\":{d},\"canvasFrameVisualEffectRetainCount\":{d},\"canvasFrameVisualEffectEvictCount\":{d},\"canvasFrameGlyphAtlasEntryCount\":{d},\"canvasFrameGlyphAtlasUploadCount\":{d},\"canvasFrameGlyphAtlasRetainCount\":{d},\"canvasFrameGlyphAtlasEvictCount\":{d}", .{
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
        view.canvas_frame_glyph_atlas_entry_count,
        view.canvas_frame_glyph_atlas_upload_count,
        view.canvas_frame_glyph_atlas_retain_count,
        view.canvas_frame_glyph_atlas_evict_count,
    });
    try writer.print(",\"canvasFrameTextLayoutCount\":{d},\"canvasFrameTextLayoutLineCount\":{d},\"canvasFrameTextLayoutUploadCount\":{d},\"canvasFrameTextLayoutRetainCount\":{d},\"canvasFrameTextLayoutEvictCount\":{d}", .{
        view.canvas_frame_text_layout_count,
        view.canvas_frame_text_layout_line_count,
        view.canvas_frame_text_layout_upload_count,
        view.canvas_frame_text_layout_retain_count,
        view.canvas_frame_text_layout_evict_count,
    });
    try writer.print(",\"canvasFrameGpuPacketCommandCount\":{d},\"canvasFrameGpuPacketCacheActionCount\":{d},\"canvasFrameGpuPacketCachedResourceCommandCount\":{d},\"canvasFrameGpuPacketUnsupportedCommandCount\":{d},\"canvasFrameGpuPacketRepresentable\":{}", .{
        view.canvas_frame_gpu_packet_command_count,
        view.canvas_frame_gpu_packet_cache_action_count,
        view.canvas_frame_gpu_packet_cached_resource_command_count,
        view.canvas_frame_gpu_packet_unsupported_command_count,
        view.canvas_frame_gpu_packet_representable,
    });
    try writer.print(",\"canvasFrameChangeCount\":{d},\"canvasFrameBudgetExceededCount\":{d},\"canvasFrameBudgetOk\":{},\"canvasFrameDirtyBounds\":", .{
        view.canvas_frame_change_count,
        view.canvas_frame_budget_exceeded_count,
        view.canvas_frame_budget_ok,
    });
    try writeOptionalRectJson(view.canvas_frame_dirty_bounds, writer);
    try writer.print(",\"canvasFrameProfileWorkUnits\":{d},\"canvasFrameProfileRisk\":", .{view.canvas_frame_profile_work_units});
    try json.writeString(writer, @tagName(view.canvas_frame_profile_risk));
    try writer.print(",\"canvasFrameProfileSurfaceArea\":{d},\"canvasFrameProfileDirtyArea\":{d},\"canvasFrameProfileDirtyRatio\":{d}", .{
        view.canvas_frame_profile_surface_area,
        view.canvas_frame_profile_dirty_area,
        view.canvas_frame_profile_dirty_ratio,
    });
    try writer.print(",\"widgetRevision\":{d},\"widgetNodeCount\":{d},\"widgetSemanticsCount\":{d},\"cursor\":", .{
        view.widget_revision,
        view.widget_node_count,
        view.widget_semantics_count,
    });
    try json.writeString(writer, @tagName(view.cursor));
    try writer.print(",\"focused\":{},\"open\":{}}}", .{
        view.focused,
        view.open,
    });
}

pub fn writeOptionalRectJson(rect: ?geometry.RectF, writer: anytype) !void {
    if (rect) |value| {
        try writer.print("{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ value.x, value.y, value.width, value.height });
    } else {
        try writer.writeAll("null");
    }
}

pub fn viewInfoFromWebView(webview: anytype) platform.ViewInfo {
    return .{
        .id = webview.id,
        .window_id = webview.window_id,
        .label = webview.label,
        .kind = .webview,
        .parent = webview.parent,
        .frame = webview.frame,
        .layer = webview.layer,
        .visible = webview.open,
        .enabled = true,
        .role = "webview",
        .accessibility_label = "WebView",
        .url = webview.url,
        .transparent = webview.transparent,
        .bridge_enabled = webview.bridge_enabled,
        .focused = webview.focused,
        .open = webview.open,
    };
}

pub fn writeWebViewJsonToWriter(webview: anytype, writer: anytype) !void {
    try writer.writeAll("{\"label\":");
    try json.writeString(writer, webview.label);
    try writer.print(",\"windowId\":{d},\"url\":", .{webview.window_id});
    try json.writeString(writer, webview.url);
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"layer\":{d},\"zoom\":{d},\"transparent\":{},\"bridge\":{},\"focused\":{},\"open\":{}}}", .{
        webview.frame.x,
        webview.frame.y,
        webview.frame.width,
        webview.frame.height,
        webview.layer,
        webview.zoom,
        webview.transparent,
        webview.bridge_enabled,
        webview.focused,
        webview.open,
    });
}

pub fn writeWindowJsonToWriter(window: platform.WindowInfo, writer: anytype) !void {
    try writer.writeAll("{\"id\":");
    try writer.print("{d}", .{window.id});
    try writer.writeAll(",\"label\":");
    try json.writeString(writer, window.label);
    try writer.writeAll(",\"title\":");
    try json.writeString(writer, window.title);
    try writer.writeAll(",\"open\":");
    try writer.writeAll(if (window.open) "true" else "false");
    try writer.writeAll(",\"focused\":");
    try writer.writeAll(if (window.focused) "true" else "false");
    // Alive-but-policy-hidden rides beside open/focused: without it a JS
    // consumer cannot tell a close_policy = "hide" window (open:true,
    // focused:false) from a visible unfocused one.
    try writer.writeAll(",\"hidden\":");
    try writer.writeAll(if (window.hidden) "true" else "false");
    try writer.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"scale\":{d}", .{
        window.frame.x,
        window.frame.y,
        window.frame.width,
        window.frame.height,
        window.scale_factor,
    });
    try writer.writeByte('}');
}

pub fn builtinBridgeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedService => "Native service is not available on this platform",
        error.WindowNotFound => "Window was not found",
        error.WindowLimitReached => "Window limit reached",
        error.DuplicateWindowLabel => "Window id or label already exists",
        error.MissingWindowSource => "Window source is missing",
        error.WindowSourceTooLarge => "Window source is too large",
        error.CreateFailed => "Native view creation failed",
        error.MissingWebViewUrl => "WebView URL is missing",
        error.InvalidWebViewWindowId => "windowId must be a non-negative integer",
        error.CrossWindowWebViewDenied => "WebView windowId must match the calling window",
        error.InvalidWebViewOptions => "WebView options are invalid",
        error.WebViewNotFound => "WebView was not found",
        error.WebViewLayerNotBuilt => "this app was built without the web layer because nothing in app.zon declared web use; add \"webview\" to .capabilities (or a .frontend block / a .shell webview view) and rebuild",
        error.WebViewLimitReached => "WebView limit reached",
        error.DuplicateWebViewLabel => "WebView label already exists",
        error.ReservedWebViewLabel => "WebView label \"main\" is reserved for the startup WebView",
        error.WebViewLabelTooLarge => "WebView label is too large",
        error.WebViewUrlTooLarge => "WebView URL is too large",
        error.UnsupportedChildWebViews => "This backend does not support child WebViews yet",
        error.UnsupportedWebViewBridge => "This backend does not support bridge-enabled child WebViews yet",
        error.UnsupportedMainWebViewFrame => "This backend does not support resizing the main WebView yet",
        error.UnsupportedMainWebViewZoom => "This backend does not support zooming the main WebView yet",
        error.UnsupportedMainWebViewLayer => "This backend does not support changing the main WebView layer",
        error.NavigationDenied => "URL is not allowed by navigation policy",
        error.InvalidExternalUrl => "External URL is invalid",
        error.ExternalUrlTooLarge => "External URL is too large",
        error.InvalidRevealPath => "Reveal path is invalid",
        error.RevealPathTooLarge => "Reveal path is too large",
        error.InvalidRecentDocumentPath => "Recent document path is invalid",
        error.RecentDocumentPathTooLarge => "Recent document path is too large",
        error.InvalidDialogOptions => "Dialog options are invalid",
        error.DialogFieldTooLarge => "Dialog field is too large",
        error.InvalidNotificationOptions => "Notification options are invalid",
        error.NotificationFieldTooLarge => "Notification field is too large",
        error.InvalidClipboardOptions => "Clipboard options are invalid",
        error.ClipboardFieldTooLarge => "Clipboard field is too large",
        error.InvalidCredentialOptions => "Credential options are invalid",
        error.CredentialFieldTooLarge => "Credential field is too large",
        error.CredentialNotFound => "Credential was not found",
        error.InvalidTrayOptions => "Tray options are invalid",
        error.TrayFieldTooLarge => "Tray field is too large",
        error.InvalidPlatformFeature => "Platform feature is invalid",
        error.InvalidWindowOptions => "Window options are invalid",
        error.InvalidCommand => "Command name is invalid",
        error.DuplicateWindowId => "Window id already exists",
        error.InvalidViewOptions => "View options are invalid",
        error.InvalidViewWindowId => "view windowId must be a non-negative integer",
        error.CrossWindowViewDenied => "view windowId must match the calling window",
        error.ViewNotFound => "View was not found",
        error.ViewLimitReached => "View limit reached",
        error.DuplicateViewLabel => "View label already exists",
        error.ViewLabelTooLarge => "View label is too large",
        error.ViewRoleTooLarge => "View role is too large",
        error.ViewAccessibilityLabelTooLarge => "View accessibility label is too large",
        error.ViewTextTooLarge => "View text is too large",
        error.WidgetNodeLimitReached => "Canvas widget node limit reached",
        error.WidgetTextTooLarge => "Canvas widget text is too large",
        error.WidgetSemanticsListFull => "Canvas widget semantics limit reached",
        error.DuplicateWidgetId => "Canvas widget id already exists",
        error.UnsupportedViewKind => "This backend does not support this native view kind yet",
        error.UnsupportedViewFocus => "This backend does not support focusing this native view yet",
        error.NoSpaceLeft => "Native response buffer is too small",
        else => "Native command failed",
    };
}

pub fn builtinBridgeErrorCode(err: anyerror) bridge.ErrorCode {
    return switch (err) {
        error.UnsupportedService,
        error.InvalidWindowOptions,
        error.WindowNotFound,
        error.WindowLimitReached,
        error.DuplicateWindowId,
        error.DuplicateWindowLabel,
        error.MissingWindowSource,
        error.WindowSourceTooLarge,
        error.MissingWebViewUrl,
        error.InvalidWebViewWindowId,
        error.CrossWindowWebViewDenied,
        error.InvalidWebViewOptions,
        error.WebViewNotFound,
        error.WebViewLayerNotBuilt,
        error.WebViewLimitReached,
        error.DuplicateWebViewLabel,
        error.ReservedWebViewLabel,
        error.WebViewLabelTooLarge,
        error.WebViewUrlTooLarge,
        error.UnsupportedChildWebViews,
        error.UnsupportedWebViewBridge,
        error.UnsupportedMainWebViewFrame,
        error.UnsupportedMainWebViewZoom,
        error.UnsupportedMainWebViewLayer,
        error.InvalidCommand,
        error.InvalidViewOptions,
        error.InvalidViewWindowId,
        error.CrossWindowViewDenied,
        error.ViewNotFound,
        error.ViewLimitReached,
        error.DuplicateViewLabel,
        error.ViewLabelTooLarge,
        error.ViewRoleTooLarge,
        error.ViewAccessibilityLabelTooLarge,
        error.ViewTextTooLarge,
        error.UnsupportedViewKind,
        error.UnsupportedViewFocus,
        error.InvalidExternalUrl,
        error.ExternalUrlTooLarge,
        error.InvalidRevealPath,
        error.RevealPathTooLarge,
        error.InvalidRecentDocumentPath,
        error.RecentDocumentPathTooLarge,
        error.InvalidDialogOptions,
        error.DialogFieldTooLarge,
        error.InvalidNotificationOptions,
        error.NotificationFieldTooLarge,
        error.InvalidClipboardOptions,
        error.ClipboardFieldTooLarge,
        error.InvalidCredentialOptions,
        error.CredentialFieldTooLarge,
        error.InvalidTrayOptions,
        error.TrayFieldTooLarge,
        error.InvalidPlatformFeature,
        => .invalid_request,
        error.NavigationDenied => .invalid_request,
        else => .internal_error,
    };
}

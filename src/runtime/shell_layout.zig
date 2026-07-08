const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const validation = @import("validation.zig");

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub const RuntimeShellLayout = struct {
    window_id: platform.WindowId = 1,
    views: [app_manifest.max_shell_views_per_window]app_manifest.ShellView = undefined,
    view_count: usize = 0,
    label_storage: [app_manifest.max_shell_views_per_window][app_manifest.max_view_label_bytes]u8 = undefined,
    parent_storage: [app_manifest.max_shell_views_per_window][app_manifest.max_view_label_bytes]u8 = undefined,

    pub fn viewSlice(self: *const RuntimeShellLayout) []const app_manifest.ShellView {
        return self.views[0..self.view_count];
    }

    pub fn copyViews(self: *RuntimeShellLayout, source: []const app_manifest.ShellView) !void {
        if (source.len > self.views.len) return error.ViewLimitReached;
        for (source, 0..) |view, index| {
            var copied = view;
            copied.label = try copyInto(&self.label_storage[index], view.label);
            copied.parent = if (view.parent) |parent| try copyInto(&self.parent_storage[index], parent) else null;
            copied.role = null;
            copied.accessibility_label = null;
            copied.url = null;
            copied.text = null;
            copied.command = null;
            self.views[index] = copied;
        }
        self.view_count = source.len;
    }
};

const ShellResolvedView = struct {
    label: []const u8 = "",
    kind: app_manifest.ViewKind = .webview,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    absolute_frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    axis: app_manifest.ShellAxis = .row,
};

const ShellParentCursor = struct {
    label: []const u8 = "",
    x: f32 = 8,
    y: f32 = 8,
};

pub const ShellLayout = struct {
    remaining: geometry.RectF,
    fill_rect: geometry.RectF,
    views: [app_manifest.max_shell_views_per_window]ShellResolvedView = undefined,
    view_count: usize = 0,
    parent_cursors: [app_manifest.max_shell_views_per_window]ShellParentCursor = undefined,
    parent_cursor_count: usize = 0,

    pub fn init(window_frame: geometry.RectF, views: []const app_manifest.ShellView) ShellLayout {
        const base = window_frame;
        var fill_rect = base;
        for (views) |view| {
            if (view.parent != null or view.fill) continue;
            const edge = view.edge orelse continue;
            const frame = dockedShellFrame(fill_rect, view, edge);
            consumeShellRect(&fill_rect, edge, frame);
        }
        return .{
            .remaining = base,
            .fill_rect = fill_rect,
        };
    }

    fn frameFor(self: *ShellLayout, view: app_manifest.ShellView) !geometry.RectF {
        const frame = if (view.parent != null)
            try self.parentedFrame(view)
        else if (view.fill)
            self.fillFrame(view)
        else if (view.edge) |edge|
            self.dockedFrame(view, edge)
        else
            explicitShellFrame(view);
        try self.recordView(view, frame);
        return frame;
    }

    fn parentedFrame(self: *ShellLayout, view: app_manifest.ShellView) !geometry.RectF {
        const parent_label = view.parent orelse return error.InvalidViewOptions;
        const parent = self.findView(parent_label) orelse return error.InvalidViewOptions;
        if (parent.kind == .split) return self.splitChildFrame(view, parent);
        return self.stackChildFrame(view, parent);
    }

    fn stackChildFrame(self: *ShellLayout, view: app_manifest.ShellView, parent: ShellResolvedView) geometry.RectF {
        const width = constrainedShellWidth(view, view.width orelse defaultShellViewWidth(view.kind));
        const height = constrainedShellHeight(view, view.height orelse defaultShellViewHeight(view.kind, parent.frame.height));
        const cursor = self.parentCursor(parent);
        const x = view.x orelse switch (parent.axis) {
            .row => cursor.x,
            .column => 8,
        };
        const y = view.y orelse switch (parent.axis) {
            .row => centeredOffset(parent.frame.height, height),
            .column => cursor.y,
        };
        switch (parent.axis) {
            .row => if (view.x == null) {
                cursor.x = x + width + 8;
            },
            .column => if (view.y == null) {
                cursor.y = y + height + 8;
            },
        }
        return geometry.RectF.init(x, y, width, height);
    }

    fn splitChildFrame(self: *ShellLayout, view: app_manifest.ShellView, parent: ShellResolvedView) geometry.RectF {
        const cursor = self.parentCursor(parent);
        const x = view.x orelse switch (parent.axis) {
            .row => cursor.x,
            .column => 0,
        };
        const y = view.y orelse switch (parent.axis) {
            .row => 0,
            .column => cursor.y,
        };
        const remaining_width = @max(parent.frame.width - x, 0);
        const remaining_height = @max(parent.frame.height - y, 0);
        const width = constrainedShellWidth(view, view.width orelse switch (parent.axis) {
            .row => if (view.fill) remaining_width else defaultShellViewWidth(view.kind),
            .column => remaining_width,
        });
        const height = constrainedShellHeight(view, view.height orelse switch (parent.axis) {
            .row => remaining_height,
            .column => if (view.fill) remaining_height else defaultShellViewHeight(view.kind, parent.frame.height),
        });

        switch (parent.axis) {
            .row => cursor.x = @max(cursor.x, x + width),
            .column => cursor.y = @max(cursor.y, y + height),
        }
        return geometry.RectF.init(x, y, width, height);
    }

    fn fillFrame(self: *ShellLayout, view: app_manifest.ShellView) geometry.RectF {
        const width = constrainedShellWidth(view, view.width orelse self.fill_rect.width);
        const height = constrainedShellHeight(view, view.height orelse self.fill_rect.height);
        return geometry.RectF.init(
            view.x orelse self.fill_rect.x,
            view.y orelse self.fill_rect.y,
            width,
            height,
        );
    }

    fn dockedFrame(self: *ShellLayout, view: app_manifest.ShellView, edge: app_manifest.ShellEdge) geometry.RectF {
        const frame = dockedShellFrame(self.remaining, view, edge);
        consumeShellRect(&self.remaining, edge, frame);
        return frame;
    }

    fn recordView(self: *ShellLayout, view: app_manifest.ShellView, frame: geometry.RectF) !void {
        if (self.view_count >= self.views.len) return error.ViewLimitReached;
        var absolute_frame = frame;
        if (view.parent) |parent_label| {
            const parent = self.findView(parent_label) orelse return error.InvalidViewOptions;
            absolute_frame.x += parent.absolute_frame.x;
            absolute_frame.y += parent.absolute_frame.y;
        }
        self.views[self.view_count] = .{
            .label = view.label,
            .kind = view.kind,
            .frame = frame,
            .absolute_frame = absolute_frame,
            .axis = view.axis orelse .row,
        };
        self.view_count += 1;
    }

    pub fn containsView(self: *const ShellLayout, label: []const u8) bool {
        return self.findView(label) != null;
    }

    fn findView(self: *const ShellLayout, label: []const u8) ?ShellResolvedView {
        for (self.views[0..self.view_count]) |view| {
            if (std.mem.eql(u8, view.label, label)) return view;
        }
        return null;
    }

    fn parentCursor(self: *ShellLayout, parent: ShellResolvedView) *ShellParentCursor {
        for (self.parent_cursors[0..self.parent_cursor_count]) |*cursor| {
            if (std.mem.eql(u8, cursor.label, parent.label)) return cursor;
        }
        const index = self.parent_cursor_count;
        const origin: f32 = if (parent.kind == .split) 0 else 8;
        self.parent_cursors[index] = .{ .label = parent.label, .x = origin, .y = origin };
        self.parent_cursor_count += 1;
        return &self.parent_cursors[index];
    }
};

pub fn shellRestorePolicy(policy: app_manifest.WindowRestorePolicy) platform.WindowRestorePolicy {
    return switch (policy) {
        .clamp_to_visible_screen => .clamp_to_visible_screen,
        .center_on_primary => .center_on_primary,
    };
}

pub fn shellTitlebarStyle(style: app_manifest.WindowTitlebarStyle) platform.WindowTitlebarStyle {
    return switch (style) {
        .standard => .standard,
        .hidden_inset => .hidden_inset,
        .hidden_inset_tall => .hidden_inset_tall,
        .chromeless => .chromeless,
    };
}

/// Present-before-show policy for a shell window: a window whose content
/// is a canvas (any `gpu_surface` view) is created ordered-out and shown
/// only after its first canvas frame has completed presentation, so the
/// user never sees a blank window while the first frame renders. Webview
/// windows keep immediate visibility — their engine owns first paint.
pub fn shellWindowShowMode(shell_window: app_manifest.ShellWindow) platform.WindowShowMode {
    for (shell_window.views) |view| {
        if (view.kind == .gpu_surface) return .on_first_present;
    }
    return .immediate;
}

/// Whether loading this scene must materialize the app's webview source
/// into a window's main webview. Only a `main`-labeled webview view needs
/// that; child webviews (a preview pane next to a gpu_surface canvas, an
/// inspector split) are standalone platform webviews created from their
/// own `url`, so a canvas-first app with the default empty source never
/// grows an implicit full-window main webview behind its canvas. Apps
/// that provide a real source keep loading it regardless (their child
/// webviews may reference `zero://` origins served from it).
pub fn sceneNeedsMainWebView(scene: app_manifest.ShellConfig) bool {
    for (scene.windows) |window| {
        for (window.views) |view| {
            if (view.kind == .webview and validation.isMainWebViewLabel(view.label)) return true;
        }
    }
    return false;
}

pub fn shellViewOptions(window_id: platform.WindowId, view: app_manifest.ShellView, layout: *ShellLayout) !platform.ViewOptions {
    const frame = try layout.frameFor(view);
    const resolved = layout.findView(view.label) orelse return error.InvalidViewOptions;
    const platform_frame = if (view.kind == .webview and view.parent != null and validation.isMainWebViewLabel(view.label)) resolved.absolute_frame else frame;
    return .{
        .window_id = window_id,
        .label = view.label,
        .kind = shellViewKind(view.kind),
        .parent = view.parent,
        .frame = platform_frame,
        .layer = view.layer,
        .visible = view.visible,
        .enabled = view.enabled,
        .role = view.role orelse "",
        .accessibility_label = view.accessibility_label orelse "",
        .text = view.text orelse view.role orelse "",
        .command = view.command orelse "",
        .url = view.url orelse "",
        .bridge_enabled = view.kind == .webview,
        .gpu_surface = shellGpuSurfaceOptions(view),
    };
}

fn shellGpuSurfaceOptions(view: app_manifest.ShellView) platform.GpuSurfaceOptions {
    var options = platform.GpuSurfaceOptions{};
    if (view.gpu_backend) |value| options.backend = shellGpuSurfaceBackend(value);
    if (view.gpu_pixel_format) |value| options.pixel_format = shellGpuSurfacePixelFormat(value);
    if (view.gpu_present_mode) |value| options.present_mode = shellGpuSurfacePresentMode(value);
    if (view.gpu_alpha_mode) |value| options.alpha_mode = shellGpuSurfaceAlphaMode(value);
    if (view.gpu_color_space) |value| options.color_space = shellGpuSurfaceColorSpace(value);
    if (view.gpu_vsync) |value| options.vsync = value;
    return options;
}

fn shellGpuSurfaceBackend(value: app_manifest.GpuSurfaceBackend) platform.GpuSurfaceBackend {
    return switch (value) {
        .none => .none,
        .metal => .metal,
        .software => .software,
    };
}

fn shellGpuSurfacePixelFormat(value: app_manifest.GpuSurfacePixelFormat) platform.GpuSurfacePixelFormat {
    return switch (value) {
        .none => .none,
        .bgra8_unorm => .bgra8_unorm,
    };
}

fn shellGpuSurfacePresentMode(value: app_manifest.GpuSurfacePresentMode) platform.GpuSurfacePresentMode {
    return switch (value) {
        .none => .none,
        .timer => .timer,
    };
}

fn shellGpuSurfaceAlphaMode(value: app_manifest.GpuSurfaceAlphaMode) platform.GpuSurfaceAlphaMode {
    return switch (value) {
        .none => .none,
        .@"opaque" => .@"opaque",
        .premultiplied => .premultiplied,
    };
}

fn shellGpuSurfaceColorSpace(value: app_manifest.GpuSurfaceColorSpace) platform.GpuSurfaceColorSpace {
    return switch (value) {
        .none => .none,
        .srgb => .srgb,
        .display_p3 => .display_p3,
    };
}

fn shellViewKind(kind: app_manifest.ViewKind) platform.ViewKind {
    return switch (kind) {
        .webview => .webview,
        .toolbar => .toolbar,
        .titlebar_accessory => .titlebar_accessory,
        .sidebar => .sidebar,
        .statusbar => .statusbar,
        .split => .split,
        .stack => .stack,
        .button => .button,
        .icon_button => .icon_button,
        .list_item => .list_item,
        .checkbox => .checkbox,
        .toggle => .toggle,
        .segmented_control => .segmented_control,
        .text_field => .text_field,
        .search_field => .search_field,
        .label => .label,
        .spacer => .spacer,
        .gpu_surface => .gpu_surface,
        .progress_indicator => .progress_indicator,
    };
}

fn explicitShellFrame(view: app_manifest.ShellView) geometry.RectF {
    return geometry.RectF.init(
        view.x orelse 0,
        view.y orelse 0,
        constrainedShellWidth(view, view.width orelse defaultShellViewWidth(view.kind)),
        constrainedShellHeight(view, view.height orelse defaultShellViewHeight(view.kind, 0)),
    );
}

fn dockedShellFrame(remaining: geometry.RectF, view: app_manifest.ShellView, edge: app_manifest.ShellEdge) geometry.RectF {
    return switch (edge) {
        .top => frame: {
            const width = constrainedShellWidth(view, view.width orelse remaining.width);
            const height = constrainedShellHeight(view, view.height orelse defaultDockHeight(view.kind));
            break :frame geometry.RectF.init(remaining.x, remaining.y, width, height);
        },
        .bottom => frame: {
            const width = constrainedShellWidth(view, view.width orelse remaining.width);
            const height = constrainedShellHeight(view, view.height orelse defaultDockHeight(view.kind));
            break :frame geometry.RectF.init(remaining.x, remaining.y + @max(remaining.height - height, 0), width, height);
        },
        .left => frame: {
            const width = constrainedShellWidth(view, view.width orelse defaultDockWidth(view.kind));
            const height = constrainedShellHeight(view, view.height orelse remaining.height);
            break :frame geometry.RectF.init(remaining.x, remaining.y, width, height);
        },
        .right => frame: {
            const width = constrainedShellWidth(view, view.width orelse defaultDockWidth(view.kind));
            const height = constrainedShellHeight(view, view.height orelse remaining.height);
            break :frame geometry.RectF.init(remaining.x + @max(remaining.width - width, 0), remaining.y, width, height);
        },
    };
}

fn constrainedShellWidth(view: app_manifest.ShellView, width: f32) f32 {
    var result = width;
    if (view.min_width) |min_width| result = @max(result, min_width);
    if (view.max_width) |max_width| result = @min(result, max_width);
    return result;
}

fn constrainedShellHeight(view: app_manifest.ShellView, height: f32) f32 {
    var result = height;
    if (view.min_height) |min_height| result = @max(result, min_height);
    if (view.max_height) |max_height| result = @min(result, max_height);
    return result;
}

fn consumeShellRect(remaining: *geometry.RectF, edge: app_manifest.ShellEdge, frame: geometry.RectF) void {
    switch (edge) {
        .top => {
            remaining.y += frame.height;
            remaining.height = @max(remaining.height - frame.height, 0);
        },
        .bottom => {
            remaining.height = @max(remaining.height - frame.height, 0);
        },
        .left => {
            remaining.x += frame.width;
            remaining.width = @max(remaining.width - frame.width, 0);
        },
        .right => {
            remaining.width = @max(remaining.width - frame.width, 0);
        },
    }
}

fn defaultDockHeight(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .toolbar => 48,
        .titlebar_accessory => 36,
        .statusbar => 28,
        else => defaultShellViewHeight(kind, 0),
    };
}

fn defaultDockWidth(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .sidebar => 240,
        else => defaultShellViewWidth(kind),
    };
}

fn defaultShellViewWidth(kind: app_manifest.ViewKind) f32 {
    return switch (kind) {
        .button, .checkbox, .toggle => 96,
        .icon_button => 32,
        .list_item => 220,
        .segmented_control => 168,
        .label => 160,
        .spacer => 12,
        .progress_indicator => 24,
        .text_field, .search_field => 220,
        .sidebar => 240,
        else => 0,
    };
}

fn defaultShellViewHeight(kind: app_manifest.ViewKind, parent_height: f32) f32 {
    return switch (kind) {
        .button, .icon_button, .checkbox, .toggle, .segmented_control, .list_item => 32,
        .label => 24,
        .spacer => @max(parent_height, 1),
        .progress_indicator => 24,
        .text_field, .search_field => 28,
        .toolbar => 48,
        .titlebar_accessory => 36,
        .statusbar => 28,
        else => 0,
    };
}

fn centeredOffset(parent_height: f32, height: f32) f32 {
    if (parent_height <= height) return 0;
    return (parent_height - height) / 2;
}

pub fn combinedViewportInsets(surface: platform.Surface) geometry.InsetsF {
    return .{
        .top = @max(surface.safe_area_insets.top, surface.keyboard_insets.top),
        .right = @max(surface.safe_area_insets.right, surface.keyboard_insets.right),
        .bottom = @max(surface.safe_area_insets.bottom, surface.keyboard_insets.bottom),
        .left = @max(surface.safe_area_insets.left, surface.keyboard_insets.left),
    };
}

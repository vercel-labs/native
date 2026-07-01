const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const token_model = @import("tokens.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const Color = canvas.Color;
const Affine = canvas.Affine;
const ImageFit = canvas.ImageFit;
const ImageSampling = canvas.ImageSampling;
const TextAlign = text_model.TextAlign;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const CanvasRenderAnimation = canvas.CanvasRenderAnimation;
const BlurTokenRef = token_model.BlurTokenRef;
const MotionDuration = token_model.MotionDuration;
const MotionTokens = token_model.MotionTokens;

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

pub const WidgetKind = enum {
    stack,
    row,
    column,
    grid,
    data_grid,
    table,
    scroll_view,
    list,
    breadcrumb,
    button_group,
    pagination,
    radio_group,
    tabs,
    toggle_group,
    accordion,
    bubble,
    resizable,
    alert,
    card,
    dialog,
    drawer,
    sheet,
    panel,
    popover,
    menu_surface,
    dropdown_menu,
    text,
    icon,
    image,
    avatar,
    badge,
    button,
    toggle_button,
    icon_button,
    select,
    input,
    text_field,
    search_field,
    combobox,
    textarea,
    tooltip,
    menu_item,
    list_item,
    data_row,
    data_cell,
    status_bar,
    segmented_control,
    checkbox,
    radio,
    switch_control,
    toggle,
    slider,
    progress,
    separator,
    skeleton,
    spinner,
};

pub const WidgetCursor = enum {
    arrow,
    pointing_hand,
    text,
    resize_horizontal,
};

pub const WidgetState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    disabled: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    required: bool = false,
    read_only: bool = false,
    invalid: bool = false,
};

pub const WidgetRenderState = struct {
    focused_id: ?ObjectId = null,
    focus_visible_id: ?ObjectId = null,
    hovered_id: ?ObjectId = null,
    pressed_id: ?ObjectId = null,
};

pub const WidgetMainAlignment = enum {
    start,
    center,
    end,
    space_between,
};

pub const WidgetCrossAlignment = enum {
    stretch,
    start,
    center,
    end,
};

pub const WidgetLayoutStyle = struct {
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    grow: f32 = 0,
    main_alignment: WidgetMainAlignment = .start,
    cross_alignment: WidgetCrossAlignment = .stretch,
    clip_content: bool = false,
    columns: usize = 0,
    virtualized: bool = false,
    virtual_item_extent: f32 = 0,
    virtual_overscan: usize = 0,
    min_size: geometry.SizeF = .{},
};

pub const WidgetStyle = struct {
    background: ?Color = null,
    foreground: ?Color = null,
    accent: ?Color = null,
    accent_foreground: ?Color = null,
    border: ?Color = null,
    focus_ring: ?Color = null,
    radius: ?f32 = null,
    stroke_width: ?f32 = null,
};

pub const WidgetVariant = enum {
    default,
    primary,
    secondary,
    outline,
    ghost,
    destructive,
};

pub const WidgetSize = enum {
    default,
    sm,
    lg,
    icon,
};

pub const WidgetRole = enum {
    none,
    group,
    text,
    image,
    button,
    textbox,
    tooltip,
    dialog,
    menu,
    menuitem,
    list,
    listitem,
    row,
    grid,
    gridcell,
    tab,
    checkbox,
    radio,
    switch_control,
    slider,
    progressbar,
};

pub const BuiltinComponentStyle = enum {
    shadcn,
};

pub const BuiltinComponentKind = enum {
    accordion,
    alert,
    avatar,
    badge,
    breadcrumb,
    bubble,
    button,
    button_group,
    card,
    checkbox,
    combobox,
    dialog,
    drawer,
    dropdown_menu,
    input,
    pagination,
    progress,
    radio_group,
    resizable,
    select,
    separator,
    sheet,
    skeleton,
    slider,
    spinner,
    switch_control,
    table,
    tabs,
    textarea,
    toggle,
    toggle_group,
    tooltip,
};

pub const builtin_component_kinds = [_]BuiltinComponentKind{
    .accordion,
    .alert,
    .avatar,
    .badge,
    .breadcrumb,
    .bubble,
    .button,
    .button_group,
    .card,
    .checkbox,
    .combobox,
    .dialog,
    .drawer,
    .dropdown_menu,
    .input,
    .pagination,
    .progress,
    .radio_group,
    .resizable,
    .select,
    .separator,
    .sheet,
    .skeleton,
    .slider,
    .spinner,
    .switch_control,
    .table,
    .tabs,
    .textarea,
    .toggle,
    .toggle_group,
    .tooltip,
};

pub const builtin_component_names = [_][]const u8{
    "Accordion",
    "Alert",
    "Avatar",
    "Badge",
    "Breadcrumb",
    "Bubble",
    "Button",
    "Button Group",
    "Card",
    "Checkbox",
    "Combobox",
    "Dialog",
    "Drawer",
    "Dropdown Menu",
    "Input",
    "Pagination",
    "Progress",
    "Radio Group",
    "Resizable",
    "Select",
    "Separator",
    "Sheet",
    "Skeleton",
    "Slider",
    "Spinner",
    "Switch",
    "Table",
    "Tabs",
    "Textarea",
    "Toggle",
    "Toggle Group",
    "Tooltip",
};

pub const BuiltinComponentDescriptor = struct {
    kind: BuiltinComponentKind,
    name: []const u8,
    root_widget_kind: WidgetKind,
    role: WidgetRole,
    style: BuiltinComponentStyle = .shadcn,
    composite: bool = false,
};

pub fn builtinComponentCount() usize {
    return builtin_component_kinds.len;
}

pub fn builtinComponentName(kind: BuiltinComponentKind) []const u8 {
    return builtin_component_names[@intFromEnum(kind)];
}

pub fn builtinComponentDescriptor(kind: BuiltinComponentKind) BuiltinComponentDescriptor {
    return switch (kind) {
        .accordion => builtinComponent(.accordion, .accordion, .group, true),
        .alert => builtinComponent(.alert, .alert, .group, true),
        .avatar => builtinComponent(.avatar, .avatar, .image, false),
        .badge => builtinComponent(.badge, .badge, .text, false),
        .breadcrumb => builtinComponent(.breadcrumb, .breadcrumb, .group, true),
        .bubble => builtinComponent(.bubble, .bubble, .group, true),
        .button => builtinComponent(.button, .button, .button, false),
        .button_group => builtinComponent(.button_group, .button_group, .group, true),
        .card => builtinComponent(.card, .card, .group, true),
        .checkbox => builtinComponent(.checkbox, .checkbox, .checkbox, false),
        .combobox => builtinComponent(.combobox, .combobox, .textbox, true),
        .dialog => builtinComponent(.dialog, .dialog, .dialog, true),
        .drawer => builtinComponent(.drawer, .drawer, .dialog, true),
        .dropdown_menu => builtinComponent(.dropdown_menu, .dropdown_menu, .menu, true),
        .input => builtinComponent(.input, .input, .textbox, false),
        .pagination => builtinComponent(.pagination, .pagination, .group, true),
        .progress => builtinComponent(.progress, .progress, .progressbar, false),
        .radio_group => builtinComponent(.radio_group, .radio_group, .group, true),
        .resizable => builtinComponent(.resizable, .resizable, .group, true),
        .select => builtinComponent(.select, .select, .button, true),
        .separator => builtinComponent(.separator, .separator, .none, false),
        .sheet => builtinComponent(.sheet, .sheet, .dialog, true),
        .skeleton => builtinComponent(.skeleton, .skeleton, .none, false),
        .slider => builtinComponent(.slider, .slider, .slider, false),
        .spinner => builtinComponent(.spinner, .spinner, .progressbar, false),
        .switch_control => builtinComponent(.switch_control, .switch_control, .switch_control, false),
        .table => builtinComponent(.table, .table, .grid, true),
        .tabs => builtinComponent(.tabs, .tabs, .group, true),
        .textarea => builtinComponent(.textarea, .textarea, .textbox, false),
        .toggle => builtinComponent(.toggle, .toggle_button, .button, false),
        .toggle_group => builtinComponent(.toggle_group, .toggle_group, .group, true),
        .tooltip => builtinComponent(.tooltip, .tooltip, .tooltip, false),
    };
}

fn builtinComponent(
    kind: BuiltinComponentKind,
    root_widget_kind: WidgetKind,
    role: WidgetRole,
    composite: bool,
) BuiltinComponentDescriptor {
    return .{
        .kind = kind,
        .name = builtinComponentName(kind),
        .root_widget_kind = root_widget_kind,
        .role = role,
        .style = .shadcn,
        .composite = composite,
    };
}

pub const WidgetActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,
    dismiss: bool = false,

    pub fn isEmpty(self: WidgetActions) bool {
        return !self.focus and
            !self.press and
            !self.toggle and
            !self.increment and
            !self.decrement and
            !self.set_text and
            !self.set_selection and
            !self.select and
            !self.drag and
            !self.drop_files and
            !self.dismiss;
    }
};

pub const WidgetSemantics = struct {
    role: WidgetRole = .none,
    label: []const u8 = "",
    value: ?f32 = null,
    list_item_index: ?u32 = null,
    list_item_count: ?u32 = null,
    actions: WidgetActions = .{},
    hidden: bool = false,
    focusable: bool = false,
};

pub const Widget = struct {
    id: ObjectId = 0,
    kind: WidgetKind,
    frame: geometry.RectF = .{},
    opacity: f32 = 1,
    transform: Affine = .{},
    backdrop_blur: f32 = 0,
    backdrop_blur_token: ?BlurTokenRef = null,
    text: []const u8 = "",
    placeholder: []const u8 = "",
    text_alignment: TextAlign = .start,
    command: []const u8 = "",
    image_id: ImageId = 0,
    image_src: ?geometry.RectF = null,
    image_fit: ImageFit = .stretch,
    image_sampling: ImageSampling = .linear,
    image_opacity: f32 = 1,
    text_selection: ?TextSelection = null,
    text_composition: ?TextRange = null,
    value: f32 = 0,
    layer: ?i32 = null,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    variant: WidgetVariant = .default,
    size: WidgetSize = .default,
    style: WidgetStyle = .{},
    semantics: WidgetSemantics = .{},
    children: []const Widget = &.{},
};

pub const BuiltinComponentOptions = struct {
    id: ObjectId = 0,
    frame: geometry.RectF = .{},
    opacity: f32 = 1,
    transform: Affine = .{},
    backdrop_blur: f32 = 0,
    backdrop_blur_token: ?BlurTokenRef = null,
    text: []const u8 = "",
    placeholder: []const u8 = "",
    text_alignment: TextAlign = .start,
    command: []const u8 = "",
    image_id: ImageId = 0,
    image_src: ?geometry.RectF = null,
    image_fit: ImageFit = .stretch,
    image_sampling: ImageSampling = .linear,
    image_opacity: f32 = 1,
    text_selection: ?TextSelection = null,
    text_composition: ?TextRange = null,
    value: f32 = 0,
    layer: ?i32 = null,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    variant: ?WidgetVariant = null,
    size: ?WidgetSize = null,
    style: WidgetStyle = .{},
    semantics: WidgetSemantics = .{},
    children: []const Widget = &.{},
};

pub const WidgetCommandPart = struct {
    widget_id: ObjectId,
    slot: ObjectId = 1,
};

pub const BuiltinSurfacePlacementOptions = struct {
    bounds: geometry.RectF,
    preferred_size: geometry.SizeF = .{},
    margin: f32 = 24,
};

pub const BuiltinSurfaceBackdropOptions = struct {
    id: ObjectId = 0,
    frame: geometry.RectF,
    layer: ?i32 = null,
    label: []const u8 = "Surface backdrop",
    background: Color = Color.rgba8(0, 0, 0, 154),
    dismissible: bool = true,
};

pub const BuiltinStatusBarOptions = struct {
    id: ObjectId = 0,
    frame: geometry.RectF,
    text: []const u8 = "",
    layer: ?i32 = null,
    padding: geometry.InsetsF = geometry.InsetsF.symmetric(7, 14),
    background: ?Color = null,
    foreground: ?Color = null,
    border: ?Color = null,
    size: WidgetSize = .sm,
    semantics: WidgetSemantics = .{},
};

pub const BuiltinSurfaceEnterAnimationOptions = struct {
    surface_id: ObjectId,
    frame: geometry.RectF,
    motion: MotionTokens = .{},
    start_ns: u64 = 0,
    duration: MotionDuration = .normal,
    content: []const WidgetCommandPart = &.{},
};

pub fn builtinComponentWidget(kind: BuiltinComponentKind, options: BuiltinComponentOptions) Widget {
    const descriptor = builtinComponentDescriptor(kind);
    return .{
        .id = options.id,
        .kind = descriptor.root_widget_kind,
        .frame = options.frame,
        .opacity = options.opacity,
        .transform = options.transform,
        .backdrop_blur = options.backdrop_blur,
        .backdrop_blur_token = options.backdrop_blur_token,
        .text = options.text,
        .placeholder = options.placeholder,
        .text_alignment = options.text_alignment,
        .command = options.command,
        .image_id = options.image_id,
        .image_src = options.image_src,
        .image_fit = options.image_fit,
        .image_sampling = options.image_sampling,
        .image_opacity = options.image_opacity,
        .text_selection = options.text_selection,
        .text_composition = options.text_composition,
        .value = options.value,
        .layer = options.layer,
        .state = options.state,
        .layout = builtinComponentLayout(kind, options.layout),
        .variant = options.variant orelse builtinComponentDefaultVariant(kind),
        .size = options.size orelse builtinComponentDefaultSize(kind),
        .style = options.style,
        .semantics = builtinComponentSemantics(descriptor, options.semantics),
        .children = options.children,
    };
}

pub fn widgetCommandPartId(part: WidgetCommandPart) ObjectId {
    return widgetPartId(part.widget_id, part.slot);
}

pub fn builtinSurfaceBackdropWidget(options: BuiltinSurfaceBackdropOptions) Widget {
    return .{
        .id = options.id,
        .kind = .panel,
        .frame = options.frame,
        .layer = options.layer,
        .style = .{
            .background = options.background,
            .border = Color.rgba8(0, 0, 0, 0),
            .radius = 0,
            .stroke_width = 0,
        },
        .semantics = .{
            .label = options.label,
            .actions = .{ .dismiss = options.dismissible },
        },
    };
}

pub fn builtinStatusBarWidget(options: BuiltinStatusBarOptions) Widget {
    var semantics = options.semantics;
    if (semantics.role == .none) semantics.role = .text;
    if (semantics.label.len == 0) semantics.label = options.text;

    return .{
        .id = options.id,
        .kind = .status_bar,
        .frame = options.frame,
        .text = options.text,
        .layer = options.layer,
        .layout = .{ .padding = options.padding },
        .size = options.size,
        .style = .{
            .background = options.background,
            .foreground = options.foreground,
            .border = options.border,
        },
        .semantics = semantics,
    };
}

pub fn builtinSurfaceFrame(kind: BuiltinComponentKind, options: BuiltinSurfacePlacementOptions) ?geometry.RectF {
    const bounds = options.bounds.normalized();
    if (bounds.isEmpty()) return null;

    const preferred = builtinSurfacePreferredSize(kind, options.preferred_size) orelse return null;
    return switch (kind) {
        .dialog => centeredBuiltinSurfaceFrame(bounds, preferred, options.margin),
        .drawer => bottomBuiltinSurfaceFrame(bounds, preferred.height),
        .sheet => rightBuiltinSurfaceFrame(bounds, preferred.width),
        else => null,
    };
}

pub fn appendBuiltinSurfaceEnterAnimations(kind: BuiltinComponentKind, options: BuiltinSurfaceEnterAnimationOptions, output: []CanvasRenderAnimation, len: *usize) Error!void {
    if (!builtinSurfaceComponentKind(kind)) return;
    if (options.surface_id == 0) return;
    if (options.motion.durationMs(options.duration) == 0) return;

    if (builtinSurfaceEnterOffset(kind, options.frame)) |offset| {
        try appendBuiltinSurfaceChromeTransformAnimations(
            options,
            output,
            len,
            Affine.translate(offset.dx, offset.dy),
        );
    } else {
        try appendBuiltinSurfaceChromeOpacityAnimations(options, output, len);
    }
    try appendBuiltinSurfaceContentOpacityAnimations(options, output, len);
}

pub fn builtinSurfaceEnterOffset(kind: BuiltinComponentKind, frame: geometry.RectF) ?geometry.OffsetF {
    const normalized = frame.normalized();
    return switch (kind) {
        .drawer => geometry.OffsetF.init(0, normalized.height),
        .sheet => geometry.OffsetF.init(normalized.width, 0),
        .dialog => null,
        else => null,
    };
}

fn builtinSurfaceComponentKind(kind: BuiltinComponentKind) bool {
    return switch (kind) {
        .dialog, .drawer, .sheet => true,
        else => false,
    };
}

const builtin_surface_chrome_slots = [_]ObjectId{ 1, 2, 3 };

fn appendBuiltinSurfaceChromeTransformAnimations(options: BuiltinSurfaceEnterAnimationOptions, output: []CanvasRenderAnimation, len: *usize, from_transform: Affine) Error!void {
    for (builtin_surface_chrome_slots) |slot| {
        try appendBuiltinSurfaceAnimation(output, len, options.motion.animation(.{
            .id = widgetPartId(options.surface_id, slot),
            .start_ns = options.start_ns,
            .duration = options.duration,
            .from_transform = from_transform,
            .to_transform = Affine.identity(),
        }));
    }
}

fn appendBuiltinSurfaceChromeOpacityAnimations(options: BuiltinSurfaceEnterAnimationOptions, output: []CanvasRenderAnimation, len: *usize) Error!void {
    for (builtin_surface_chrome_slots) |slot| {
        try appendBuiltinSurfaceAnimation(output, len, options.motion.animation(.{
            .id = widgetPartId(options.surface_id, slot),
            .start_ns = options.start_ns,
            .duration = options.duration,
            .from_opacity = 0,
            .to_opacity = 1,
        }));
    }
}

fn appendBuiltinSurfaceContentOpacityAnimations(options: BuiltinSurfaceEnterAnimationOptions, output: []CanvasRenderAnimation, len: *usize) Error!void {
    for (options.content) |part| {
        if (part.widget_id == 0) continue;
        try appendBuiltinSurfaceAnimation(output, len, options.motion.animation(.{
            .id = widgetCommandPartId(part),
            .start_ns = options.start_ns,
            .duration = options.duration,
            .from_opacity = 0,
            .to_opacity = 1,
        }));
    }
}

fn appendBuiltinSurfaceAnimation(output: []CanvasRenderAnimation, len: *usize, animation: CanvasRenderAnimation) Error!void {
    if (len.* >= output.len) return error.RenderOverrideListFull;
    output[len.*] = animation;
    len.* += 1;
}

fn builtinSurfacePreferredSize(kind: BuiltinComponentKind, requested: geometry.SizeF) ?geometry.SizeF {
    const defaults = switch (kind) {
        .dialog => geometry.SizeF.init(420, 220),
        .drawer => geometry.SizeF.init(360, 280),
        .sheet => geometry.SizeF.init(320, 420),
        else => return null,
    };
    return geometry.SizeF.init(
        if (std.math.isFinite(requested.width) and requested.width > 0) requested.width else defaults.width,
        if (std.math.isFinite(requested.height) and requested.height > 0) requested.height else defaults.height,
    );
}

fn centeredBuiltinSurfaceFrame(bounds: geometry.RectF, preferred: geometry.SizeF, margin: f32) geometry.RectF {
    const safe_margin = @min(nonNegative(if (std.math.isFinite(margin)) margin else 0), @min(bounds.width, bounds.height) * 0.5);
    const available_width = @max(1, bounds.width - safe_margin * 2);
    const available_height = @max(1, bounds.height - safe_margin * 2);
    const width = @min(preferred.width, available_width);
    const height = @min(preferred.height, available_height);
    return geometry.RectF.init(
        bounds.x + (bounds.width - width) * 0.5,
        bounds.y + (bounds.height - height) * 0.5,
        width,
        height,
    );
}

fn bottomBuiltinSurfaceFrame(bounds: geometry.RectF, preferred_height: f32) geometry.RectF {
    const height = @min(nonNegative(preferred_height), @max(1, bounds.height));
    return geometry.RectF.init(bounds.x, bounds.maxY() - height, @max(1, bounds.width), height);
}

fn rightBuiltinSurfaceFrame(bounds: geometry.RectF, preferred_width: f32) geometry.RectF {
    const width = @min(nonNegative(preferred_width), @max(1, bounds.width));
    return geometry.RectF.init(bounds.maxX() - width, bounds.y, width, @max(1, bounds.height));
}

fn builtinComponentDefaultVariant(kind: BuiltinComponentKind) WidgetVariant {
    return switch (kind) {
        .button => .primary,
        .select => .outline,
        .toggle => .ghost,
        else => .default,
    };
}

fn builtinComponentDefaultSize(kind: BuiltinComponentKind) WidgetSize {
    return switch (kind) {
        .spinner => .sm,
        else => .default,
    };
}

fn builtinComponentSemantics(descriptor: BuiltinComponentDescriptor, semantics: WidgetSemantics) WidgetSemantics {
    var next = semantics;
    if (next.role == .none and descriptor.role != .none) {
        next.role = descriptor.role;
    }
    return next;
}

fn builtinComponentLayout(kind: BuiltinComponentKind, layout: WidgetLayoutStyle) WidgetLayoutStyle {
    if (!widgetLayoutStyleIsDefault(layout)) return layout;

    return switch (kind) {
        .alert,
        .bubble,
        .card,
        => .{
            .padding = geometry.InsetsF.all(16),
            .gap = 12,
            .clip_content = true,
        },
        .accordion,
        .resizable,
        => .{
            .padding = geometry.InsetsF.all(12),
            .gap = 8,
            .clip_content = true,
        },
        .dialog,
        .drawer,
        .sheet,
        => .{
            .padding = geometry.InsetsF.all(20),
            .gap = 16,
            .clip_content = true,
        },
        .dropdown_menu => .{
            .padding = geometry.InsetsF.all(4),
            .gap = 2,
            .clip_content = true,
        },
        .breadcrumb,
        .button_group,
        .pagination,
        .radio_group,
        .tabs,
        .toggle_group,
        => .{
            .gap = 4,
            .cross_alignment = .center,
        },
        .table => .{
            .clip_content = true,
        },
        .textarea => .{
            .min_size = geometry.SizeF.init(160, 80),
        },
        .separator => .{
            .min_size = geometry.SizeF.init(1, 1),
        },
        .skeleton => .{
            .min_size = geometry.SizeF.init(120, 20),
        },
        else => layout,
    };
}

fn widgetLayoutStyleIsDefault(layout: WidgetLayoutStyle) bool {
    return layout.padding.top == 0 and
        layout.padding.right == 0 and
        layout.padding.bottom == 0 and
        layout.padding.left == 0 and
        layout.gap == 0 and
        layout.grow == 0 and
        layout.main_alignment == .start and
        layout.cross_alignment == .stretch and
        !layout.clip_content and
        layout.columns == 0 and
        !layout.virtualized and
        layout.virtual_item_extent == 0 and
        layout.virtual_overscan == 0 and
        layout.min_size.width == 0 and
        layout.min_size.height == 0;
}

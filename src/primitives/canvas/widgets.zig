const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const text_spans_model = @import("text_spans.zig");
const token_model = @import("tokens.zig");
const chart_model = @import("chart.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const Color = canvas.Color;
const Affine = canvas.Affine;
const ImageFit = canvas.ImageFit;
const ImageSampling = canvas.ImageSampling;
const TextAlign = text_model.TextAlign;
const TextOverflow = text_model.TextOverflow;
const TextSpan = text_spans_model.TextSpan;
const TextRange = text_model.TextRange;
const TextSelection = text_model.TextSelection;
const CanvasRenderAnimation = canvas.CanvasRenderAnimation;
const BlurTokenRef = token_model.BlurTokenRef;
const Easing = token_model.Easing;
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
    /// Data chart leaf (line/bar/band series in `Widget.chart`), rendered
    /// through the vector path pipeline with token-driven series colors.
    /// Display-only: not a hit target, so presses fall through to the
    /// nearest pressable ancestor like text and icons. (Structural ids
    /// hash `widgetKindCode`, not declaration order, so placement here
    /// carries no meaning.)
    chart,
    /// Two-pane horizontal splitter: exactly two flow children (the
    /// panes) separated by a builder-synthesized `.split_divider` handle.
    /// `value` is the MODEL-OWNED fraction of the content width the
    /// first pane takes (0 means "unset" and lays out at 0.5); dragging
    /// the divider dispatches a `canvas_widget_resize` event so the
    /// model can own the fraction (`on_resize`), and the runtime keeps
    /// an uncontrolled divider position across rebuilds with the same
    /// source-wins reconcile rule as scroll offsets.
    split,
    /// The draggable divider handle between a `.split`'s panes. Never
    /// authored directly: `Ui.finalizeNode` synthesizes it between the
    /// two panes (both markup engines build through the same builder).
    /// Focusable, `resize_horizontal` cursor, ARIA separator semantics;
    /// arrow keys adjust the parent split's fraction when it holds
    /// focus. `value` mirrors the parent split's fraction.
    split_divider,
    /// Disclosure-tree container (vertical flow like `list`): descendant
    /// widgets carrying `role = .treeitem` form ONE roving keyboard
    /// focus set regardless of nesting depth — Up/Down walk visible
    /// rows, Left collapses (or moves to the parent row), Right expands
    /// (or moves to the first child row), Home/End jump to the edges.
    /// Expansion and selection stay model-owned: rows dispatch their
    /// `on_toggle`/`on_press` Msgs and the view re-renders.
    tree,
    /// Composer-grade grouped input: ONE bordered field (text-input
    /// chrome — fill, border, md radius) whose children flow vertically,
    /// wrapping a multi-line text entry plus an accessory row of controls
    /// inside the same border. The GROUP wears the focus ring when
    /// keyboard focus is on any descendant (focus-within), so the whole
    /// group reads as one field; `Ui.inputGroup` dissolves the inner
    /// textarea's own chrome (the notes editor-pane treatment) so the two
    /// never double-draw. Not a hit target itself: the textarea fills the
    /// group's body, so a click "in the field" IS a click in the textarea.
    input_group,
    /// The media surface leaf: composites a texture PRODUCED OUTSIDE the
    /// widget tree (a video decoder, a camera pipeline, an external
    /// renderer) into the layout like any widget — clipped, z-ordered,
    /// transformed. `image_id` carries the SURFACE id the producer
    /// targets (`Runtime.acquireMediaSurfaceProducer`), a model-owned
    /// u64 in the ImageId value space; 0 is the unbound sentinel, and
    /// usable ids are nonzero values below the reserved namespace bit
    /// (`media_surface_image_id_bit`, refused at acquire).
    /// Display-only like `image` and `chart`: not a hit target, presses
    /// fall through to the nearest pressable ancestor. Texture CONTENTS
    /// are presentation chrome — the deterministic reference renderer
    /// draws the surface's id-derived placeholder instead (see
    /// `ReferenceImage.presentation_only`), so goldens and session
    /// fingerprints never depend on producer output.
    media_surface,
};

/// STABLE code for a widget kind: assigned at birth, never reused or
/// reassigned. This — not the enum's declaration order — is what
/// `structuralId` hashes, so retained widget state, automation targets,
/// and record/replay journals survive any reordering of `WidgetKind`.
/// The codes were frozen from the declaration order at the moment of the
/// switch (which is why they are dense), so every pre-switch structural
/// id is preserved; a NEW kind takes the next unused code regardless of
/// where it sits in the enum. Versioned with the UI document schema
/// (`ui_schema.schema_version`): reassigning a code is a schema-version
/// bump, never a silent edit. A conformance test pins the full table, so
/// a reorder that forgets this function cannot compile into different
/// ids.
pub fn widgetKindCode(kind: WidgetKind) u16 {
    return switch (kind) {
        .stack => 0,
        .row => 1,
        .column => 2,
        .grid => 3,
        .data_grid => 4,
        .table => 5,
        .scroll_view => 6,
        .list => 7,
        .breadcrumb => 8,
        .button_group => 9,
        .pagination => 10,
        .radio_group => 11,
        .tabs => 12,
        .toggle_group => 13,
        .accordion => 14,
        .bubble => 15,
        .resizable => 16,
        .alert => 17,
        .card => 18,
        .dialog => 19,
        .drawer => 20,
        .sheet => 21,
        .panel => 22,
        .popover => 23,
        .menu_surface => 24,
        .dropdown_menu => 25,
        .text => 26,
        .icon => 27,
        .image => 28,
        .avatar => 29,
        .badge => 30,
        .button => 31,
        .toggle_button => 32,
        .icon_button => 33,
        .select => 34,
        .input => 35,
        .text_field => 36,
        .search_field => 37,
        .combobox => 38,
        .textarea => 39,
        .tooltip => 40,
        .menu_item => 41,
        .list_item => 42,
        .data_row => 43,
        .data_cell => 44,
        .status_bar => 45,
        .segmented_control => 46,
        .checkbox => 47,
        .radio => 48,
        .switch_control => 49,
        .toggle => 50,
        .slider => 51,
        .progress => 52,
        .separator => 53,
        .skeleton => 54,
        .spinner => 55,
        .chart => 56,
        .split => 57,
        .split_divider => 58,
        .tree => 59,
        .input_group => 60,
        .media_surface => 61,
    };
}

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
    /// The pointer position while `hovered_id` is a widget that draws
    /// hover-detail chrome (today: `.chart` with `hover_details`), in
    /// the same coordinate space as widget frames. Null everywhere
    /// else — static trees and reference renders never carry one, so
    /// hover chrome renders only under live interaction.
    hover_point: ?geometry.PointF = null,
    /// Disclosure widgets currently MID-TWEEN (the runtime's disclosure
    /// tween is easing their extent). Render needs this for exactly one
    /// asymmetry: a CLOSING item's state already says closed, but its
    /// content must keep painting — clipped to the shrinking frame —
    /// until the conceal lands. Static emission (no runtime) leaves
    /// this empty and closed items skip their content, exactly as
    /// before.
    revealing_disclosure_ids: []const ObjectId = &.{},

    pub fn disclosureRevealing(self: WidgetRenderState, id: ObjectId) bool {
        if (id == 0) return false;
        for (self.revealing_disclosure_ids) |revealing_id| {
            if (revealing_id == id) return true;
        }
        return false;
    }
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

/// Preferred side of an anchored floating widget relative to its anchor.
/// Either side flips to the other when the surface does not fit and the
/// opposite side has more room (the auto-flip contract); the height then
/// clamps to the chosen side's space.
pub const WidgetAnchorPlacement = enum {
    below,
    above,
};

/// Horizontal alignment of an anchored floating widget against its
/// anchor: `start`/`end` align the matching edges; `stretch` also widens
/// the surface to at least the anchor's width (the select-menu look).
/// The x position always clamps into the window.
pub const WidgetAnchorAlignment = enum {
    start,
    end,
    stretch,
};

/// Anchored floating placement (`WidgetLayoutStyle.anchor`): a widget
/// carrying this is a FLOATING surface — the layout pass positions it
/// against its PARENT widget's resolved frame (the anchor) and the
/// window bounds instead of the parent's flow, it consumes no space in
/// the parent (no reflow), and rendering/hit-testing hoist it to a late
/// window-level pass above the rest of the tree, clipped by the window
/// rather than any scroll/clip ancestor. Open state stays model-owned:
/// the surface floats only while the view renders it.
pub const WidgetAnchor = struct {
    placement: WidgetAnchorPlacement = .below,
    alignment: WidgetAnchorAlignment = .start,
    /// Gap in points between the anchor edge and the surface.
    offset: f32 = 4,
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
    /// TOTAL virtual item count for a windowed virtual list: the container
    /// represents this many items even when `children` holds only the
    /// built window (the visible slice plus overscan). Content extent,
    /// scrollbars, and `list_item_count` semantics derive from this count,
    /// not from `children.len`. 0 keeps the legacy contract where
    /// `children` IS the full item set (layout-culled virtualization).
    /// Setting it non-zero also marks the container RUNTIME-SCROLLED (see
    /// `widgetVirtualRuntimeScrolled`): engine wheel/kinetic/keyboard
    /// scrolling and native scroll drivers engage, where legacy
    /// virtualized containers stay model-driven.
    virtual_item_count: usize = 0,
    /// Virtual index of `children[0]` in a windowed virtual list: the
    /// layout pass positions built children at their ABSOLUTE virtual
    /// offsets (`(virtual_first_index + i) * stride`), so a window built
    /// anywhere in the list lands exactly where the full list would put
    /// it. Only meaningful with `virtual_item_count > 0`.
    virtual_first_index: usize = 0,
    /// VARIABLE-extent windowed virtual list (`virtual_total_extent >
    /// 0`): the absolute index of the window's ANCHOR row — the first
    /// visible row at the offset the window was computed for. The
    /// layout pass places the anchor at `virtual_anchor_extent` and
    /// stacks the other built rows around it at their INTRINSIC
    /// heights (downward below, upward above), so the estimate error
    /// of freshly mounted rows surfaces off-screen above the anchor
    /// and never displaces what the user is looking at.
    virtual_anchor_index: usize = 0,
    /// The offset table's leading edge for the anchor row (estimates
    /// patched by measured actuals).
    virtual_anchor_extent: f32 = 0,
    /// Total content extent of a variable-extent windowed virtual list
    /// (estimates + measured corrections + inter-row gaps). Non-zero
    /// selects the variable layout contract and becomes the scroll
    /// content extent (scrollbar, native driver content size, scroll
    /// semantics). 0 keeps every uniform and legacy contract
    /// byte-identical.
    virtual_total_extent: f32 = 0,
    /// Anchored floating placement: non-null makes this widget a floating
    /// surface positioned against its parent (see `WidgetAnchor`).
    anchor: ?WidgetAnchor = null,
    min_size: geometry.SizeF = .{},
    /// Per-axis upper bound; 0 leaves the axis unbounded. An explicit
    /// author size is definite: the ui builder writes `width`/`height`
    /// into both `min_size` and `max_size`, so intrinsic content can
    /// neither shrink nor silently grow the box past it.
    max_size: geometry.SizeF = .{},
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
    /// The quiet-surface knob: `true` removes this widget's HOVER wash —
    /// the pointer resting on it paints no fill. For image-forward
    /// content surfaces (a cover-art tile, a photo card) where the
    /// pointer rests on content rather than a control register; acting
    /// controls (list rows, menu items, buttons, tab triggers) keep
    /// their washes — there the hover fill IS the affordance. Only the
    /// hover channel of the state-fill ladder goes quiet: press and
    /// selection fills, the focus ring, cursor intent, and hit testing
    /// resolve on their own channels and stay exactly as they were.
    quiet_hover: bool = false,
};

pub const WidgetVariant = enum {
    default,
    primary,
    secondary,
    outline,
    ghost,
    destructive,
};

/// Icon slot side for label-bearing controls (`Widget.icon_placement`).
pub const WidgetIconPlacement = enum {
    leading,
    trailing,
};

/// The `size` register. Two axes share it deliberately: the CONTROL
/// scale (`default`/`sm`/`lg`/`icon` — inset, height, and radius steps on
/// buttons, inputs, and the other chrome-bearing controls) and the
/// TYPOGRAPHY rungs (`heading`/`display` — named typography-token steps
/// honored on `.text` widgets only). The markup validator and both
/// engines keep the axes apart with teaching errors (heading/display on
/// a control is rejected); a Zig view that slips one onto a control gets
/// a Debug warning and the default step.
pub const WidgetSize = enum {
    default,
    sm,
    lg,
    icon,
    /// Text leaves only: `TypographyTokens.heading_size` (28 by default).
    heading,
    /// Text leaves only: `TypographyTokens.display_size` (48 by default).
    display,
};

pub const WidgetRole = enum {
    none,
    group,
    text,
    link,
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
    /// Data visualization (the `.chart` widget kind). Platform
    /// accessibility bridges without a chart role expose it as an image
    /// with the chart's summary label.
    chart,
    /// A disclosure tree container (the `.tree` widget kind). Platform
    /// bridges without a tree role expose it as a list.
    tree,
    /// One row of a disclosure tree. Stamping this role on any pressable
    /// row (a panel, a list item) makes it a roving-focus tree row: the
    /// ARIA tree keymap and selection-follows-focus apply. Platform
    /// bridges without a treeitem role expose it as a list item.
    treeitem,
    /// A draggable pane divider (the `.split_divider` widget kind): the
    /// ARIA separator with a value (the split fraction). Platform
    /// bridges without a separator role expose it as a group.
    separator,
};

pub const BuiltinComponentStyle = enum {
    house,
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
    style: BuiltinComponentStyle = .house,
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
        .style = .house,
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

/// One declared context-menu entry carried on a widget (label/enabled/
/// separator only — the typed `Msg` mapping lives in the Ui handler
/// table, keyed by widget id + item index).
pub const WidgetContextMenuItem = struct {
    label: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
};

/// Per-region edge behavior of a scroll container. `.default` follows
/// the `ScrollPhysics.overscroll` design token (off by default: scroll
/// regions pin at their content edges); `.none` and `.rubber_band` pin
/// or bounce this region regardless of the token. Meaningful on scroll
/// containers only — the ui builder and the markup validator keep it
/// off other elements.
pub const WidgetOverscroll = enum {
    default,
    none,
    rubber_band,
};

/// Where a control sits inside a FLUSH button group (`button_group`
/// with gap 0), stamped onto the render-time widget copy by BOTH render
/// walks — never authored, never serialized, never retained. The stamp
/// is what turns three adjacent buttons into one segmented bar: the
/// first segment keeps only its leading corners, the last only its
/// trailing corners, middles square off entirely, and every non-first
/// segment drops its left border so each interior boundary is painted
/// by exactly ONE stroke (two overlapping translucent hairlines — the
/// dark scheme's border register — would composite into a brighter
/// seam than the group's outer edge).
pub const WidgetGroupSegment = enum {
    /// Not a flush-group segment (the default everywhere else).
    none,
    first,
    middle,
    last,
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
    /// Inline styled runs for `.text` widgets. Empty keeps the classic
    /// single-style path byte-identical. When set, `text` should carry the
    /// concatenated plain text (each span's `text` a subslice of it): the
    /// semantics label falls back to it and retained-state copies rebase
    /// span slices onto the copied buffer instead of duplicating bytes.
    /// `Ui.paragraph` maintains this invariant for authors.
    spans: []const TextSpan = &.{},
    placeholder: []const u8 = "",
    /// Vector icon name (built-in registry or an app-registered icon)
    /// drawn INSIDE the widget as part of its own rendering — buttons
    /// and toggle buttons draw it before the label (icon-only when
    /// `text` is empty), icon buttons draw it centered, list items and
    /// menu items draw it as a leading slot — so icon + label stay one
    /// hit target and follow the widget's enabled/disabled tint. Empty
    /// = no icon. Unknown names draw nothing (registration is a
    /// boot-time act; the markup engines and `Ui.icon` validate
    /// built-in names up front).
    icon: []const u8 = "",
    /// Which side of the label the icon sits on, for the label-bearing
    /// icon slots (buttons and toggle buttons): `.leading` is the
    /// default reading-order slot, `.trailing` puts the icon after the
    /// label — the next-page chevron, the open-below affordance.
    /// Icon-only buttons center the glyph regardless.
    icon_placement: WidgetIconPlacement = .leading,
    text_alignment: TextAlign = .start,
    /// Explicit single-line mode for plain `.text` leaves
    /// (`ElementOptions.wrap = false` / markup `wrap="false"`). Plain
    /// leaves paint one line either way (measurement treats them as one
    /// line in both the intrinsic and constrained paths, and paint
    /// agrees); the flag records the author's explicit choice so
    /// tooling and write-back can round-trip it. Span paragraphs
    /// (`spans`) wrap by design and ignore it.
    text_no_wrap: bool = false,
    /// What a single-line text run does with content that does not fit
    /// its frame (`ElementOptions.overflow` / markup `overflow=` on
    /// text leaves): `.ellipsis` (default) elides the tail behind a
    /// trailing U+2026 measured with the same seam paint uses; `.clip`
    /// is the deliberate hard-cut for fixed-format content (a duration
    /// column) where a partial glyph beats losing the format. Wrapped
    /// paragraphs ignore it.
    text_overflow: TextOverflow = .ellipsis,
    /// Source-driven focus request: when this turns ON for a widget —
    /// newly mounted with it set, or the source flips it false→true —
    /// the runtime moves keyboard focus to the widget on the rebuild
    /// that applies it. Holding it true does NOT re-steal focus on
    /// later rebuilds (edge-triggered, like the source-wins control
    /// reconcile), so keyboard-first flows can declare focus in the
    /// view: a note editor that mounts with `autofocus` receives the
    /// keyboard the moment it appears.
    autofocus: bool = false,
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
    /// Modal surfaces (dialog/drawer/sheet) paint a token-driven scrim
    /// (dim + backdrop blur) across the whole tree behind them. False
    /// opts a surface out — for embedding one as an inline PREVIEW
    /// (a component catalog card, a docs specimen) where it is not
    /// actually modal. Ignored on every other kind.
    scrim: bool = true,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    variant: WidgetVariant = .default,
    size: WidgetSize = .default,
    style: WidgetStyle = .{},
    semantics: WidgetSemantics = .{},
    /// App-declared native context menu for this widget (empty = none).
    context_menu: []const WidgetContextMenuItem = &.{},
    /// True when the runtime installed a native scroll driver for this
    /// `.scroll_view`: the engine's drawn scrollbar and kinetic physics
    /// stand down — the OS scroller owns feel and the overlay scroller.
    native_scroll: bool = false,
    /// Per-region edge behavior for scroll containers (`overscroll:` in
    /// the builder, `overscroll=` in markup): `.default` follows the
    /// `ScrollPhysics.overscroll` token (off unless a theme flips it),
    /// `.none` pins scrolling at the content edges, `.rubber_band` lets
    /// this region bounce past them. Honored by both scroll paths — the
    /// engine's wheel/kinetic physics and the native OS scroller.
    overscroll: WidgetOverscroll = .default,
    /// Declared layout-tween duration for `.split` widgets
    /// (`resize_duration:` in the builder, `resize-duration=` in
    /// markup), in milliseconds. Nonzero turns the split's declared
    /// `value` into a TARGET: when a rebuild moves the value, the
    /// runtime keeps the rendered fraction and eases it toward the new
    /// value over this duration — one step per presented frame on the
    /// recorded frame clock, through the same mutation path a divider
    /// drag uses (dirty regions, `on_resize` echoes, reconcile
    /// survival). 0 (the default) keeps the classic snap, so every
    /// existing tree and document behaves exactly as before. Reduced
    /// motion snaps inside the runtime. Ignored on every other kind.
    resize_duration_ms: u32 = 0,
    /// Easing curve of the split layout tween (`resize_easing:` /
    /// `resize-easing=`). Only meaningful with a nonzero
    /// `resize_duration_ms`.
    resize_easing: Easing = .standard,
    /// Enter-from fraction for a FRESHLY MOUNTED `.split` with a
    /// nonzero `resize_duration_ms` (`resize_origin:` in the builder,
    /// `resize-origin=` in markup): the first layout keeps the
    /// children at the declared `value`'s pose but slides the pane
    /// boundary to this fraction, and the runtime tween eases it to
    /// the value from there — a pane that mounts mid-reveal (a sidebar
    /// expanding out of a collapsed state it was unmounted in) slides
    /// in instead of popping. Negative (the default) declares no
    /// origin: mounts land at their value, exactly as before. Ignored
    /// on splits that already have a retained fraction.
    resize_origin: f32 = -1,
    /// Hover-intent show delay for an ANCHORED `.tooltip` widget
    /// (`tooltip_delay:` in the builder, `tooltip-delay=` in markup),
    /// in milliseconds. An anchored tooltip is runtime-owned hover
    /// chrome: it stays hidden until its trigger (the anchor parent's
    /// subtree) has been hovered this long on the recorded frame
    /// clock, shows while the hover holds, and hides when the pointer
    /// leaves — the model never hears hover. 0 shows the instant the
    /// trigger is hovered. Negative (the default) follows the token
    /// default (`ControlMetricTokens.tooltip_show_delay_ms`). Ignored
    /// on every other kind, and on tooltips without an anchor (those
    /// stay static leaves that paint whenever the view renders them).
    tooltip_delay_ms: i32 = -1,
    /// Window-drag surface (`window-drag="true"` / `.window_drag`): a
    /// pointer press that lands here — or falls through plain text /
    /// icons / decorations onto it — moves the WINDOW instead of
    /// pressing a widget, and a double-click zooms per the OS
    /// convention. Interactive children keep working: the press
    /// fall-through walk stops at any press-claiming widget first, so a
    /// button inside a drag header stays a button. The flag makes the
    /// widget a hit target; platforms without a window-drag channel
    /// treat the press as dead space.
    window_drag: bool = false,
    /// Plot data for `.chart` widgets: model-derived series (values,
    /// token colors, kind) plus domain/grid options. The retained tree
    /// copies series and points into per-view storage like text/spans,
    /// bounded by `canvas_limits.max_canvas_widget_chart_*` budgets.
    /// `Ui.chart` downsamples long series before they land here.
    chart: chart_model.ChartData = .{},
    /// Render-walk stamp for flush button-group segments (see
    /// `WidgetGroupSegment`). Derived at emit time from the widget's
    /// position among its group's visible children; `.none` everywhere
    /// authored state lives, so it never participates in retention,
    /// serialization, or equality decisions.
    group_segment: WidgetGroupSegment = .none,
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
    /// Source-driven focus request: when this turns ON for a widget —
    /// newly mounted with it set, or the source flips it false→true —
    /// the runtime moves keyboard focus to the widget on the rebuild
    /// that applies it. Holding it true does NOT re-steal focus on
    /// later rebuilds (edge-triggered, like the source-wins control
    /// reconcile), so keyboard-first flows can declare focus in the
    /// view: a note editor that mounts with `autofocus` receives the
    /// keyboard the moment it appears.
    autofocus: bool = false,
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
    /// See `Widget.scrim`: false embeds a modal surface as an inline
    /// preview without the behind-it dim + blur.
    scrim: bool = true,
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

/// The input-catcher behind a modal surface: a full-bounds panel whose
/// job is the dismiss hit target and the semantics node — VISUALS live
/// elsewhere. The modal chrome itself paints the scrim (the token-driven
/// blur + dim across the whole surface), so the backdrop defaults to a
/// fully transparent fill; a non-default `background` stacks on top of
/// that scrim, for apps that want an additional tinted wash.
pub const BuiltinSurfaceBackdropOptions = struct {
    id: ObjectId = 0,
    frame: geometry.RectF,
    layer: ?i32 = null,
    label: []const u8 = "Surface backdrop",
    background: Color = Color.rgba8(0, 0, 0, 0),
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
        .scrim = options.scrim,
        .state = options.state,
        .layout = builtinComponentLayout(kind, options.size orelse builtinComponentDefaultSize(kind), options.layout),
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

/// How far the TabsList container insets its segmented triggers on
/// every side. Shared with the trigger renderer, which subtracts this
/// from the container radius so the selected segment's corners stay
/// concentric with the container's at every position.
pub const tabs_list_inset: f32 = 3;

/// Ergonomic per-kind layout defaults for the composite surfaces whose
/// house reference carries built-in content spacing, shared by EVERY
/// authoring path — `builtinComponentWidget` and (via the ui builder,
/// which both markup engines build through) `Ui.el` — so a bare `.card`
/// never renders children flush against its border. Consulted only when
/// the author left the relevant layout fields untouched; any explicit
/// spacing wins.
pub fn widgetKindDefaultLayout(kind: WidgetKind, size: WidgetSize) ?WidgetLayoutStyle {
    return switch (kind) {
        // house cards carry 24px of content padding (16 compact).
        .card => .{
            .padding = geometry.InsetsF.all(if (size == .sm) 16 else 24),
            .gap = 12,
            .clip_content = true,
        },
        .alert => .{
            .padding = geometry.InsetsF.all(16),
            .gap = 12,
            .clip_content = true,
        },
        // The chat bubble hugs its message: 10px vertical / 12px
        // horizontal, so one 14px body line closes into a ~40px capsule
        // (the chrome's `radius.lg + 12` arc reads as a full pill on a
        // single line). Children stack inside — no gap axis to default.
        .bubble => .{
            .padding = geometry.InsetsF.init(10, 12, 10, 12),
            .clip_content = true,
        },
        // The house TabsList: one muted rounded container hugging its
        // triggers with `tabs_list_inset` of padding; the active trigger
        // lifts to the surface, so the container itself provides the
        // wash and the triggers need no gap between them.
        .tabs => .{
            .padding = geometry.InsetsF.all(tabs_list_inset),
            .cross_alignment = .center,
        },
        // house accordion items are borderless rows — trigger band and
        // hairline separator are chrome-drawn, so the item carries no
        // inset of its own and content spacing belongs to the content
        // column the author supplies.
        .accordion => null,
        else => null,
    };
}

fn builtinComponentLayout(kind: BuiltinComponentKind, size: WidgetSize, layout: WidgetLayoutStyle) WidgetLayoutStyle {
    if (widgetKindDefaultLayout(builtinComponentDescriptor(kind).root_widget_kind, size)) |defaults| {
        return mergeLayoutDefaults(layout, defaults);
    }

    const defaults: WidgetLayoutStyle = switch (kind) {
        .resizable => .{
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
        // Page cells sit on a 2px rhythm — tighter than the other strips
        // so the row reads as one control with the current page's outline
        // (not gaps) doing the separating.
        .pagination => .{
            .gap = 2,
            .cross_alignment = .center,
        },
        .breadcrumb,
        .button_group,
        .radio_group,
        .toggle_group,
        => .{
            .gap = 4,
            .cross_alignment = .center,
        },
        .accordion => .{
            .clip_content = true,
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
        else => return layout,
    };
    return mergeLayoutDefaults(layout, defaults);
}

/// Fill only the spacing fields the author left untouched from the
/// kind's built-in defaults — PER FIELD, so an explicit gap does not
/// silently strip a container's built-in content padding (a TabsList
/// with a custom trigger gap must keep its hug, or the triggers sit
/// flush against the container's rounded corners) and explicit padding
/// does not strip the default gap or clipping.
fn mergeLayoutDefaults(explicit: WidgetLayoutStyle, defaults: WidgetLayoutStyle) WidgetLayoutStyle {
    var merged = explicit;
    if (explicit.padding.top == 0 and explicit.padding.right == 0 and
        explicit.padding.bottom == 0 and explicit.padding.left == 0)
    {
        merged.padding = defaults.padding;
    }
    if (explicit.gap == 0) merged.gap = defaults.gap;
    if (explicit.cross_alignment == .stretch) merged.cross_alignment = defaults.cross_alignment;
    if (!explicit.clip_content) merged.clip_content = defaults.clip_content;
    if (explicit.min_size.width == 0 and explicit.min_size.height == 0) merged.min_size = defaults.min_size;
    return merged;
}

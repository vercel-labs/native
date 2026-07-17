//! Experimental declarative authoring layer over the retained widget tree.
//!
//! `Ui(Msg)` builds widget trees without hand-assigned object ids, absolute
//! frames, or string command dispatch:
//!
//! - Identity is structural: each widget id is derived from its parent id,
//!   kind, and key (explicit in `each`, sibling index otherwise), so ids stay
//!   stable across rebuilds and keyed reorders without author bookkeeping.
//!   Structural identity is parent-scoped: a keyed item that moves to a
//!   different parent gets a new id. Items that migrate between containers
//!   (board columns, tab pages) should set `global_key`, which pins identity
//!   to (kind, key) independent of position in the tree.
//! - Event handlers are typed `Msg` values collected into a handler table,
//!   so dispatch is compiler-checked instead of string-matched.
//! - Flex layout fields are the authoring default; `frame` is the escape
//!   hatch for absolutely positioned regions.
//!
//! Build failures (arena exhaustion) latch on the builder and surface as an
//! error from `finalize`, keeping view code free of per-node `try`.

const std = @import("std");
const builtin = @import("builtin");
const font_coverage = @import("font_coverage.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const reflect = @import("ui_markup_reflect.zig");
const ui_provenance = @import("ui_provenance.zig");

const ObjectId = canvas.ObjectId;
const Widget = canvas.Widget;
const WidgetKind = canvas.WidgetKind;

const root_id_seed: u64 = 0x5eed_2e70_a11c_e001;
const global_id_seed: u64 = 0x5eed_2e70_a11c_e002;
const zero_id_fallback: ObjectId = 0x9e37_79b9_7f4a_7c15;

const ui_log = std.log.scoped(.zero_canvas_ui);

/// Debug-build diagnostic for `gap` on a stacking container: these kinds
/// give every child the full content box (`widget_layout.zig` routes them
/// through `stackChildFrame`), so the gap silently does nothing and the
/// children land on top of each other. Warn and keep building — shipped
/// apps already carry the mistake, so it must never fail the build.
/// Markup views get the same lesson as a validation/compile error
/// (`ui_markup.stack_container_gap_message`).
fn warnStackContainerGap(kind: WidgetKind, gap: f32) void {
    if (builtin.mode != .Debug) return;
    if (gap == 0 or !canvas.widgetKindStacksChildren(kind)) return;
    ui_log.warn(
        "gap does nothing on {s}: this container layers its children on top of each other - wrap them in a column (or row) inside it for flow, or drop the gap",
        .{@tagName(kind)},
    );
}

/// Debug-build diagnostic for a set `wrap` on anything but a plain text
/// leaf. `ElementOptions.wrap` is text-leaf line policy only — rows and
/// columns never flow-wrap their children (that is the layout system's
/// design: one axis, no reflow), so the option on a container is silently
/// inert and has shipped with comments asserting wrapping that never
/// happened. Warn and keep building — shipped
/// apps already carry the mistake, so it must never fail the build.
/// Markup views get the same lesson as a validation error
/// (`ui_markup.wrap_element_message`).
fn warnInertWrap(kind: WidgetKind, wrap: ?bool) void {
    if (builtin.mode != .Debug) return;
    if (wrap == null) return;
    // Plain text leaves wrap for real; span paragraphs already wrap by
    // design, so the option is redundant there, not a trap.
    if (kind == .text) return;
    ui_log.warn(
        "wrap does nothing on {s}: only plain text leaves take a line policy - put wrap on the text leaf itself, or size the container so content fits (rows and columns never flow-wrap)",
        .{@tagName(kind)},
    );
}

/// Debug-build diagnostic for the typography rungs of the size register
/// (`heading`/`display`) on a widget kind that never reads them: only
/// `.text` leaves resolve those steps to the heading/display typography
/// tokens, so anywhere else the option is dead data rendered at the
/// default control step. Zig views warn instead of failing (the option
/// is inert, not harmful); markup views get the same lesson as a
/// validation/compile error (`ui_markup.text_size_element_message`).
fn warnTextSizeKind(kind: WidgetKind, size: canvas.WidgetSize) void {
    if (builtin.mode != .Debug) return;
    if (kind == .text) return;
    if (size != .heading and size != .display) return;
    ui_log.warn(
        "size .{s} does nothing on {s}: heading and display are typography rungs only text leaves resolve - put the size on the text leaf itself, or use the control scale (sm, lg, icon)",
        .{ @tagName(size), @tagName(kind) },
    );
}

/// Debug-build diagnostic for text the bundled face cannot fully
/// render: the codepoint draws as a tofu box wherever the bundled
/// outlines are the only glyph source — reference screenshots
/// (`automate screenshot`), mobile embeds, provider-less measurement.
/// Markup literals get the same lesson as a validation error; this
/// diagnostic is the net for DYNAMIC strings (model-derived text
/// reaches no static check) and Zig-authored literals. Logs the first
/// uncovered codepoint per text run and keeps building — live macOS
/// rendering falls back through CoreText, so this must never fail an
/// app, and it logs at .debug (the `logAxisChildrenOverflow`
/// precedent) because a .warn inside a test-built view would fail the
/// whole suite for a rendering nit.
fn warnUncoveredText(kind: WidgetKind, text: []const u8) void {
    if (builtin.mode != .Debug) return;
    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return;
        if (index + len > text.len) return;
        const codepoint = std.unicode.utf8Decode(text[index .. index + len]) catch return;
        if (codepoint >= 0x20 and codepoint != 0x7F and !font_coverage.covers(codepoint)) {
            ui_log.debug(
                "{s} text contains \"{s}\" (U+{X:0>4}), outside the bundled font's coverage - it renders as a tofu box on the reference/screenshot and mobile paths; use a vector icon (icon option, <icon name>) or plain words",
                .{ @tagName(kind), text[index .. index + len], codepoint },
            );
            return;
        }
        index += len;
    }
}

/// Debug-build diagnostic for an explicit icon name that resolves
/// nowhere — a bound markup name the model produced, an `app:` reference
/// the app never registered, a Zig `appIcon` typo. The draw path renders
/// the missing-icon fallback (a slashed circle) in its place, so the
/// break is VISIBLE; this warning is the other half of that honesty,
/// naming the value so the fix is one glance. Warn and keep building
/// (the shipped-app rule); literal markup names were already proven at
/// build time and never reach here.
fn warnUnknownIconName(name: []const u8) void {
    if (builtin.mode != .Debug) return;
    if (name.len == 0 or canvas.icons.resolve(name) != null) return;
    ui_log.warn(
        "unknown icon \"{s}\": not a built-in (canvas.icons.known_icon_names) and not registered via canvas.icons.registerAppIcons - the missing-icon fallback (a slashed circle) draws in its place",
        .{name},
    );
}

/// Debug-build diagnostic for `on_dismiss` on a kind the runtime's
/// dismissal machinery never closes: the handler would sit dead. The
/// markup validator teaches the same rule as a hard error; the builder
/// warns and keeps building (the shipped-app rule).
fn warnDismissHandlerKind(kind: WidgetKind) void {
    if (builtin.mode != .Debug) return;
    if (canvas.widgetKindDismissibleSurface(kind)) return;
    ui_log.warn(
        "on_dismiss never fires on {s}: only dismissible surfaces (dialog, drawer, sheet, popover, menu_surface, dropdown_menu) are closed by Escape/click-outside - put it on the surface element",
        .{@tagName(kind)},
    );
}

/// Debug-build diagnostic for `on_resize` on a kind the runtime never
/// resizes: only `split` containers dispatch fraction changes, so the
/// handler would sit dead anywhere else. The markup validator teaches
/// the same rule as a hard error; the builder warns and keeps building
/// (the shipped-app rule).
fn warnResizeHandlerKind(kind: WidgetKind) void {
    if (builtin.mode != .Debug) return;
    if (kind == .split) return;
    ui_log.warn(
        "on_resize never fires on {s}: only split containers dispatch fraction changes - put it on the split element",
        .{@tagName(kind)},
    );
}

pub const UiKey = union(enum) {
    index: usize,
    int: u64,
    str: []const u8,
};

/// Budget for windowed virtual lists per view build (`Ui.virtualList`):
/// each records its request so the app loop can verify window coverage
/// after layout and re-derive the view when the runtime scrolls it.
pub const max_virtual_windows: usize = 8;

/// Runtime scroll state for one windowed virtual list, resolved by the
/// window source during a view build: the CURRENT offset of record
/// (`widget.value` on the retained node — wheel, kinetic, keyboard, and
/// native-driver motion all land there) and the content viewport height
/// the list most recently laid out at.
pub const VirtualWindowState = struct {
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    /// Whether the offset comes from a MOUNTED list's retained state
    /// (false: a fallback the source synthesized for a list it has no
    /// layout for yet). Uniform windows ignore it; the trailing anchor
    /// needs it to tell "first build" (open at the bottom) from "the
    /// user scrolled to offset 0" (stay at the top).
    mounted: bool = false,
};

/// The window source seam: installed on the `Ui` by the app loop before
/// each view build (`UiApp` backs it with the retained widget layout),
/// consulted by `Ui.virtualWindow` per list identity. Returning null
/// means "no runtime state yet" (first build, list not mounted) and
/// falls back to offset 0 at the request's fallback viewport.
pub const VirtualWindowSourceFn = *const fn (context: ?*anyopaque, id: ObjectId) ?VirtualWindowState;

/// The extent-table seam of VARIABLE-extent virtual lists: installed by
/// the app loop next to the window source, it resolves the RETAINED
/// offset table (estimate prefix sums patched by measured actuals) for
/// a list identity — the state that makes scrollbar geometry converge
/// to truth as the user scrolls. Returning null (no source installed,
/// or the app loop's table budget — one per declarable window — is
/// exhausted) drops the build to stateless estimate-only math: still
/// correct within the window, just without cross-frame corrections.
pub const VirtualExtentSourceFn = *const fn (context: ?*anyopaque, id: ObjectId) ?*canvas.VirtualExtentTable;

/// A markup fragment build failure surfaced through the hot-reload seam:
/// the same file:line teaching shape the single-root markup watch reports,
/// so a fragment that reloads into a bad binding degrades identically.
pub const MarkupFragmentDiagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    /// Source file the position refers to; import resolution stamps it so
    /// errors inside imported component files name the right file.
    path: []const u8 = "",
};

/// The app loop's side of the fragment hot-reload seam (Debug dev runs
/// only). `override` answers a compiled fragment's identity key with the
/// watch's reloaded document (`*const ui_markup.MarkupDocument` as
/// `anyopaque` — the engine casts it back; the builder core stays free of
/// markup imports), or null while the fragment matches its compiled
/// baseline. `report` carries a reloaded-but-unbuildable fragment's
/// teaching diagnostic back to the app loop's markup diagnostic channel.
pub const MarkupFragmentHost = struct {
    context: *anyopaque,
    override: *const fn (context: *anyopaque, key: *const anyopaque) ?*const anyopaque,
    report: *const fn (context: *anyopaque, diagnostic: MarkupFragmentDiagnostic) void,
};

/// One windowed virtual list the current build declared: enough for the
/// app loop to re-check the window against the freshly laid-out
/// geometry (a resize or first build can widen the viewport after the
/// window was computed) and to know which scroll regions require a
/// view re-derivation when the runtime scrolls them.
pub const VirtualWindowRecord = struct {
    id: ObjectId = 0,
    item_count: usize = 0,
    item_extent: f32 = 0,
    gap: f32 = 0,
    overscan: usize = 0,
    start_index: usize = 0,
    end_index: usize = 0,
    /// VARIABLE-extent list: the app loop measures this window's
    /// mounted rows after layout and patches the retained offset table
    /// (anchored, so corrections never move visible content).
    variable: bool = false,
    /// Logical index of physical item 0 at build time (prepend-stable
    /// identity for the measure step).
    index_base: u64 = 0,
};

pub const UiHandlerEvent = enum {
    press,
    /// A multi-click press (click_count >= 2 on the release): the
    /// double-click channel. Resolution lives in `msgForPointerClick`:
    /// a double-click release prefers this handler and falls back to
    /// `.press`, so binding it is strictly additive — the first click
    /// of every double-click still dispatches the single-press message
    /// (select, then open/play), the way list selection conventions
    /// expect.
    double_press,
    toggle,
    change,
    submit,
    input,
    scroll,
    context_menu,
    dismiss,
    hold,
    /// Split-fraction changes (divider drag, keyboard adjustment,
    /// assistive increment/decrement), dispatched with the fraction the
    /// runtime already applied — echoing it back into `value` never
    /// fights the split reconcile rule.
    resize,
    /// Approach-the-end of a scroll region (infinite-scroll fetch):
    /// dispatched by the runtime with hysteresis when a user scroll
    /// brings the offset within one viewport of the content end, and
    /// re-armed once the offset retreats past one and a half viewports
    /// (appending items grows the extent, so a fresh batch re-arms the
    /// next approach on its own).
    reach_end,
    /// Approach-the-start counterpart (load-older-history for
    /// tail-anchored transcripts): dispatched with the same hysteresis
    /// when a user scroll brings the offset within one viewport of the
    /// content START, re-armed past one and a half viewports — which
    /// prepending a batch causes on its own, since the offset grows by
    /// the prepended extent to keep the viewport anchored.
    reach_start,
};

/// A color design token referenced by name (the fields of
/// `canvas.ColorTokens`). Markup style attributes (`background="surface"`)
/// parse into these; `finalizeWithTokens` resolves them against live
/// tokens, so themed apps re-resolve on retheme rebuilds.
pub const ColorTokenName = std.meta.FieldEnum(canvas.ColorTokens);

/// A radius design token referenced by name (the fields of
/// `canvas.RadiusTokens`).
pub const RadiusTokenName = std.meta.FieldEnum(canvas.RadiusTokens);

/// Token references for the style a widget should resolve at finalize
/// time. Each maps to the matching `WidgetStyle` field and only applies
/// when the author has not already set that field explicitly
/// (`border_color` maps to `WidgetStyle.border`; the markup attribute is
/// `border-color`, keeping bare `border` free for a future width
/// shorthand).
pub const StyleTokenRefs = struct {
    background: ?ColorTokenName = null,
    foreground: ?ColorTokenName = null,
    accent: ?ColorTokenName = null,
    accent_foreground: ?ColorTokenName = null,
    border_color: ?ColorTokenName = null,
    focus_ring: ?ColorTokenName = null,
    radius: ?RadiusTokenName = null,
};

fn colorTokenValue(colors: canvas.ColorTokens, ref: ColorTokenName) canvas.Color {
    return switch (ref) {
        inline else => |tag| @field(colors, @tagName(tag)),
    };
}

fn radiusTokenValue(radius: canvas.RadiusTokens, ref: RadiusTokenName) f32 {
    return switch (ref) {
        inline else => |tag| @field(radius, @tagName(tag)),
    };
}

/// Resolve token references into concrete style values, keeping any style
/// field the author already set explicitly.
fn applyStyleTokens(style: *canvas.WidgetStyle, refs: StyleTokenRefs, tokens: *const canvas.DesignTokens) void {
    if (refs.background) |ref| {
        if (style.background == null) style.background = colorTokenValue(tokens.colors, ref);
    }
    if (refs.foreground) |ref| {
        if (style.foreground == null) style.foreground = colorTokenValue(tokens.colors, ref);
    }
    if (refs.accent) |ref| {
        if (style.accent == null) style.accent = colorTokenValue(tokens.colors, ref);
    }
    if (refs.accent_foreground) |ref| {
        if (style.accent_foreground == null) style.accent_foreground = colorTokenValue(tokens.colors, ref);
    }
    if (refs.border_color) |ref| {
        if (style.border == null) style.border = colorTokenValue(tokens.colors, ref);
    }
    if (refs.focus_ring) |ref| {
        if (style.focus_ring == null) style.focus_ring = colorTokenValue(tokens.colors, ref);
    }
    if (refs.radius) |ref| {
        if (style.radius == null) style.radius = radiusTokenValue(tokens.radius, ref);
    }
}

pub fn Ui(comptime Msg: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        failed: bool = false,
        /// Window source for `virtualWindow` (see `VirtualWindowSourceFn`):
        /// null outside an app loop, where builds fall back to each
        /// request's `viewport_fallback` at offset 0.
        virtual_window_context: ?*anyopaque = null,
        virtual_window_source: ?VirtualWindowSourceFn = null,
        /// Extent-table source for VARIABLE-extent virtual lists (see
        /// `VirtualExtentSourceFn`): null outside an app loop, where
        /// variable windows compute from estimates alone.
        virtual_extent_context: ?*anyopaque = null,
        virtual_extent_source: ?VirtualExtentSourceFn = null,
        /// The windowed virtual lists this build declared (`virtualList`),
        /// for the app loop's coverage check and scroll re-derivation.
        virtual_window_records: [max_virtual_windows]VirtualWindowRecord = [_]VirtualWindowRecord{.{}} ** max_virtual_windows,
        virtual_window_record_count: usize = 0,
        /// Widget provenance collector (write-back's read half): when set,
        /// the markup engines stamp each built node's source, and
        /// `finalize` feeds the sink one record per markup-authored widget
        /// as it assigns structural ids. Null (the default) costs one
        /// branch per node and captures nothing — builder-only apps and
        /// non-automation runs never pay for it.
        provenance_sink: ?ui_provenance.Sink = null,
        /// Context-menu presentation fallback: when the platform has no
        /// native menu presenter (or presenting failed), the app loop sets
        /// this to the widget whose declared menu should present as an
        /// anchored canvas surface instead. `finalize` synthesizes that
        /// surface — a `dropdown_menu` with `menu_item`/`separator`
        /// children built from the SAME declared items — as an anchored
        /// child of the target, and reports the synthesized ids through
        /// `Tree.context_menu_fallback`. 0 (the default) synthesizes
        /// nothing.
        context_menu_fallback_target: ObjectId = 0,
        /// Set by `finalizeNode` when the fallback target was found and a
        /// surface was synthesized; copied onto the returned `Tree`.
        context_menu_fallback_result: ?Tree.ContextMenuFallback = null,
        /// Markup fragment hot-reload seam (Debug dev runs only): set by
        /// the app loop when the runtime's fragment watch is armed, so a
        /// compiled markup fragment built inline in a Zig view can ask
        /// "did my source change on disk?" and build the reloaded
        /// document through the interpreter instead of its comptime
        /// tree. Null everywhere else — release builds never read it,
        /// and the seam stays untyped (`anyopaque` document pointers)
        /// so the builder core never imports the markup engine.
        markup_fragment_host: ?MarkupFragmentHost = null,

        pub const ElementOptions = struct {
            /// Sibling-scoped identity: the widget id hashes the parent
            /// chain plus this key, so it survives reorders among siblings
            /// but NOT moving to a different parent.
            key: ?UiKey = null,
            /// Parent-independent identity: the widget id hashes only the
            /// kind and this key, so it survives reparenting (e.g. an item
            /// moving between board columns). The author guarantees each
            /// (kind, global_key) pair is unique within the tree.
            global_key: ?UiKey = null,
            frame: geometry.RectF = .{},
            /// Subtree opacity multiplier. 1 is free (no wrap emitted);
            /// values below 1 wrap the widget's commands in an opacity
            /// group; 0 culls painting entirely. Render-only: an
            /// opacity-0 widget still hit-tests at its layout frame, so
            /// pair with `disabled` (or `semantics.hidden`) when fading
            /// out interactive content.
            opacity: f32 = 1,
            /// Render-space affine applied around the widget's emitted
            /// commands (translate for slide, scale comes free). Identity
            /// is free (no wrap emitted). Layout is untouched — siblings
            /// do not reflow — but pointer hit-testing follows the
            /// transform (points are inverse-mapped into widget space),
            /// so a translated widget stays interactive at its rendered
            /// position. Accessibility frames stay at the layout frame.
            /// Pair with `UiApp.Options.animations` for tweening.
            transform: canvas.Affine = .{},
            /// Widget text (text-field contents, initial control labels).
            /// Text-bearing sugar methods (`text`, `button`, ...) override
            /// this with their content argument.
            text: []const u8 = "",
            placeholder: []const u8 = "",
            value: f32 = 0,
            checked: bool = false,
            selected: bool = false,
            /// Disclosure state for tree rows (`role = .treeitem`): null
            /// = a leaf (no disclosure), false = collapsed (Right
            /// expands via `on_toggle`), true = expanded (Left collapses
            /// via `on_toggle`). Model-owned: the view renders child
            /// rows only while expanded.
            expanded: ?bool = null,
            disabled: bool = false,
            /// Image resource reference for image-bearing widgets
            /// (`image`, `icon_button`, `avatar`): a `canvas.ImageId` the
            /// app registered at runtime (`Runtime.registerCanvasImage`,
            /// `fx.registerImageBytes`). 0 — the "no image" sentinel —
            /// keeps the widget on its non-image rendering (an avatar
            /// falls back to initials). For `media_surface` this same
            /// channel carries the SURFACE id its producer targets
            /// (`Runtime.acquireMediaSurfaceProducer`, markup
            /// `surface={binding}`) — the identical model-owned-u64
            /// shape, one bit of the id space apart (see
            /// `canvas.media_surface_image_id_bit`).
            image: canvas.ImageId = 0,
            /// Vector icon name drawn inside icon-bearing controls
            /// (`button`, `toggle_button`, `icon_button`, `list_item`,
            /// `menu_item`): a built-in registry name
            /// (`canvas.icons.known_icon_names`) or an app icon
            /// registered at boot (`canvas.icons.registerAppIcons`).
            /// Buttons and toggle buttons draw the icon before the label
            /// — icon-only when the label is empty — and list/menu items
            /// draw it as a leading slot, always as ONE hit target that
            /// follows the widget's enabled/disabled tint. Empty = no
            /// icon; unknown names draw nothing (a Debug-build warning
            /// names them).
            icon: []const u8 = "",
            /// Icon slot side on the label-bearing controls: `.leading`
            /// (default) draws the icon before the label, `.trailing`
            /// after it — the next-page chevron. Icon-only controls
            /// center the glyph regardless.
            icon_placement: canvas.WidgetIconPlacement = .leading,
            /// Source-driven focus request: when this turns on for the
            /// element (it mounts with the flag set, or the value flips
            /// false→true), the runtime moves keyboard focus to it on
            /// the rebuild that applies it — the TEA way to focus the
            /// editor on note-create or give a keyboard-first app its
            /// first focus. Edge-triggered: holding it true never
            /// re-steals focus from the user. Only focusable widgets
            /// (interactive controls) can take it.
            autofocus: bool = false,
            variant: canvas.WidgetVariant = .default,
            size: canvas.WidgetSize = .default,
            /// Definite width: the widget is exactly this wide (the value
            /// becomes both the min and max bound), so intrinsic content
            /// can neither shrink nor silently overflow the box. 0 keeps
            /// intrinsic sizing. `resizable` treats it as the initial
            /// width only (the drag handle keeps resizing past it).
            width: f32 = 0,
            /// Definite height; same contract as `width`.
            height: f32 = 0,
            /// Width floor WITHOUT the definite-max side of `width`:
            /// the widget may grow past it but never shrink below.
            /// Split panes use it to constrain the divider drag (the
            /// clamp band derives from both panes' floors).
            min_width: f32 = 0,
            grow: f32 = 0,
            gap: f32 = 0,
            padding: f32 = 0,
            main: canvas.WidgetMainAlignment = .start,
            cross: canvas.WidgetCrossAlignment = .stretch,
            /// Line policy for `text` leaves. `true`: word-wrap through
            /// the span paragraph machinery (a single-span paragraph),
            /// wrapping at the width the widget receives and reserving
            /// its real wrapped height in columns. `false` and unset:
            /// honest single-line — the content paints as ONE line
            /// (measurement is single-line either way; paint agrees),
            /// and content that does not fit the frame follows
            /// `overflow` (trailing ellipsis by default), so a
            /// width-constrained title never paints a second line over
            /// the row below.
            wrap: ?bool = null,
            /// Single-line overflow policy for `text` leaves whose
            /// content does not fit the frame: `.ellipsis` (default)
            /// elides the tail behind a trailing U+2026 measured with
            /// the same seam paint uses; `.clip` is the deliberate
            /// hard-cut for fixed-format content (a duration column)
            /// where a partial glyph beats losing the format. Wrapped
            /// paragraphs (`wrap = true`) ignore it.
            overflow: canvas.TextOverflow = .ellipsis,
            /// Horizontal alignment of the widget's text content within
            /// its box: `.text` leaves (plain and wrapped/paragraph),
            /// status bars, and surface titles consume it. Controls that
            /// own their label placement (buttons, badges) ignore it.
            text_alignment: canvas.TextAlign = .start,
            /// Fixed column count for `grid` containers. 0 (the default)
            /// keeps the derived near-square column count.
            columns: usize = 0,
            virtualized: bool = false,
            virtual_item_extent: f32 = 0,
            /// Overscan rows built and laid out beyond the visible range
            /// on each side of a virtualized container (scroll slack
            /// before the next window rebuild lands).
            virtual_overscan: usize = 0,
            /// TOTAL item count for a WINDOWED virtual list (see
            /// `Widget.layout.virtual_item_count`): children are the
            /// built window, content extent and semantics derive from
            /// this count, and the runtime owns the scroll offset.
            /// Prefer the `virtualList` sugar, which stamps this
            /// together with the window's first index and offset.
            virtual_item_count: usize = 0,
            /// Virtual index of the first child in a windowed virtual
            /// list (see `Widget.layout.virtual_first_index`).
            virtual_first_index: usize = 0,
            /// VARIABLE-extent windowed virtual list plumbing (see
            /// `Widget.layout.virtual_anchor_index` /
            /// `virtual_anchor_extent` / `virtual_total_extent`).
            /// Prefer the `virtualList` sugar, which computes all three
            /// from the window's offset table.
            virtual_anchor_index: usize = 0,
            virtual_anchor_extent: f32 = 0,
            virtual_total_extent: f32 = 0,
            /// Marks the element as a WINDOW-drag surface (the hidden
            /// titlebar pattern): pressing its own background — or plain
            /// text/icons inside it — moves the window, and double-click
            /// zooms per the OS convention. Interactive children stay
            /// live: the press fall-through walk claims a button inside
            /// the region before the drag does. macOS-only today;
            /// platforms without the channel treat the press as dead
            /// space.
            window_drag: bool = false,
            /// Edge behavior for scroll containers (`scroll`,
            /// `virtualList`): `.default` follows the
            /// `ScrollPhysics.overscroll` design token — off unless a
            /// theme flips it, so scrolling pins at the content edges
            /// with a clean stop. `.rubber_band` lets THIS region bounce
            /// past its edges (engine physics and the native OS scroller
            /// both honor it); `.none` pins it regardless of the token.
            /// Meaningless on non-scroll elements.
            overscroll: canvas.WidgetOverscroll = .default,
            /// Layout-tween duration in milliseconds for `split`
            /// (markup `resize-duration`): nonzero makes the split's
            /// declared `value` a TARGET — a rebuild that moves it no
            /// longer snaps the panes; the runtime eases the rendered
            /// fraction toward it over this duration, one step per
            /// presented frame on the recorded frame clock, reflowing
            /// both panes exactly as a divider drag would and noting
            /// the same `on_resize` echoes. 0 (the default) keeps the
            /// classic snap. Reduced-motion appearances snap inside
            /// the runtime — apps declare nothing extra.
            resize_duration: u32 = 0,
            /// Easing of the split layout tween (markup
            /// `resize-easing`): a `canvas.Easing` member. Only
            /// meaningful with a nonzero `resize_duration` — the
            /// markup validator rejects easing without a duration as
            /// silently-inert data.
            resize_easing: canvas.Easing = .standard,
            /// Enter-from fraction for a freshly MOUNTED split (markup
            /// `resize-origin`): with a nonzero `resize_duration`, the
            /// split's first layout slides its pane boundary to this
            /// fraction (children keep the declared value's pose) and
            /// the runtime eases it to the value from there — a pane
            /// that mounts mid-reveal slides in instead of popping.
            /// Negative (the default) declares no origin. Only
            /// meaningful with a nonzero `resize_duration`.
            resize_origin: f32 = -1,
            /// Hover-intent show delay for an ANCHORED tooltip (markup
            /// `tooltip-delay`), in milliseconds: the runtime shows the
            /// tooltip only after its trigger has been hovered this
            /// long on the recorded frame clock. 0 shows the instant
            /// the trigger is hovered. Negative (the default) follows
            /// the token default
            /// (`ControlMetricTokens.tooltip_show_delay_ms`). Only
            /// meaningful on a tooltip with `anchor` — the markup
            /// validator rejects it anywhere else as silently-inert
            /// data.
            tooltip_delay: i32 = -1,
            style: canvas.WidgetStyle = .{},
            /// Named token references resolved against design tokens in
            /// `finalizeWithTokens`; explicit `style` values win.
            style_tokens: StyleTokenRefs = .{},
            semantics: canvas.WidgetSemantics = .{},
            /// Anchored floating placement: setting this makes the element
            /// a FLOATING surface positioned against its PARENT's resolved
            /// frame (below/above with auto-flip at the window edges), not
            /// the parent's flow — it consumes no parent space, paints in
            /// a late window-level z-pass above the whole tree, and
            /// escapes every ancestor scroll/clip region. The sanctioned
            /// picker shape: a `stack` wraps the trigger, and the anchored
            /// `dropdown_menu` (rendered only while the model's open flag
            /// is set) is the trigger's sibling inside it. Pair with
            /// `on_dismiss` so Escape/click-outside close model-side.
            anchor: ?canvas.WidgetAnchorPlacement = null,
            /// Horizontal alignment against the anchor (`anchor` only):
            /// `start`/`end` align edges, `stretch` also widens the
            /// surface to at least the anchor's width.
            anchor_alignment: canvas.WidgetAnchorAlignment = .start,
            /// Gap in points between anchor edge and surface (`anchor`
            /// only).
            anchor_offset: f32 = 4,
            on_press: ?Msg = null,
            /// Double-click Msg (builder-only): dispatched on a release
            /// whose click count reached 2, in place of `on_press` for
            /// that release. The FIRST click of the double still
            /// dispatches `on_press` on its own release, so the natural
            /// pairing is select-on-press + act-on-double-press (a list
            /// row that selects on click and opens/plays on double
            /// click). Like `on_press`, binding it makes the element a
            /// hit target and press claimer.
            on_double_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
            /// Dismissal Msg for dismissible surfaces (dialog, drawer,
            /// sheet, popover, menu_surface, dropdown_menu): dispatched
            /// when the user dismisses the surface — Escape, a click
            /// outside it, an automation/accessibility dismiss — so the
            /// MODEL owns the close (clear the open flag in update). The
            /// engine hides the surface immediately as an optimistic
            /// echo; the source tree is truth again on the next rebuild.
            on_dismiss: ?Msg = null,
            /// Approach-end Msg for scroll containers (the
            /// infinite-scroll fetch signal): dispatched when a user
            /// scroll brings the offset within one viewport of the
            /// content end, with hysteresis — it fires once per
            /// approach and re-arms only after the offset retreats (or
            /// the content grows, which appending a batch does), so a
            /// user riding the end of the list never dispatches a
            /// fetch storm. Pair with an `update` that appends a batch;
            /// the runtime never calls into the model itself.
            on_reach_end: ?Msg = null,
            /// Approach-START Msg for scroll containers — the
            /// load-older-history signal for tail-anchored transcripts:
            /// dispatched when a user scroll brings the offset within
            /// one viewport of the content start, with the same
            /// hysteresis contract as `on_reach_end` (fires once per
            /// approach; re-arms past one and a half viewports, which
            /// prepending a batch causes on its own because the offset
            /// grows by the prepended extent to keep the viewport
            /// anchored). Builder-only for now, like the windowed
            /// virtual list itself.
            on_reach_start: ?Msg = null,
            /// Press-and-hold Msg: a pointer held down on this element
            /// for ~350 ms dispatches it (the release then presses
            /// nothing), while a quick click dispatches `on_press` as
            /// usual — the SwiftUI Menu + primaryAction shape. A
            /// secondary click (right/ctrl-click) with no context menu on
            /// the route dispatches it immediately, the desktop
            /// alternative. Like `on_press`, binding it makes the element
            /// a hit target and press claimer.
            on_hold: ?Msg = null,
            /// Message constructor for text edits: called with each
            /// `TextInputEvent` on text-entry widgets. Pair with `inputMsg`.
            on_input: ?InputMsgFn = null,
            /// Message constructor for value changes carrying the new value
            /// (slider steps, accessibility set-value). Pair with `valueMsg`.
            on_value: ?ValueMsgFn = null,
            /// Message constructor for split-fraction changes on a
            /// `split` container: called with the new first-pane
            /// fraction after every user resize — divider drag,
            /// keyboard adjustment on the focused divider, assistive
            /// increment/decrement. Pair with `valueMsg`. The delivered
            /// fraction is the value the runtime already applied, so
            /// echoing it back into `value` on the next rebuild never
            /// fights the split reconcile rule.
            on_resize: ?ValueMsgFn = null,
            /// Message constructor for link presses inside a `paragraph`:
            /// called at build time with each link span's payload, so a
            /// click on the link hotspot dispatches the resulting message
            /// through the ordinary press handler table. Pair with
            /// `linkMsg`.
            on_link: ?LinkMsgFn = null,
            /// Message constructor for scroll offset changes on a scroll
            /// container: called with the post-scroll `ScrollState`
            /// (offset, viewport and content extents) after every
            /// user-driven scroll — wheel, kinetic steps, keyboard, and
            /// accessibility scroll actions. Pair with `scrollMsg`. The
            /// delivered offset is the value the runtime already applied,
            /// so echoing it back into `value` on the next rebuild never
            /// fights the scroll reconcile rule.
            on_scroll: ?ScrollMsgFn = null,
            /// Context menu for this widget: right/ctrl-click (or a touch
            /// long-press) presents these items through the platform's
            /// native menu (macOS `NSMenu`); selecting one dispatches its
            /// `msg`. Deepest declaring widget on the hit route wins. On
            /// hosts without a native presenter the SAME items present as
            /// an anchored canvas surface (the app loop's fallback) — one
            /// authored menu, platform-appropriate presentation. Markup
            /// authors declare this with a `<context-menu>` child element.
            context_menu: []const ContextMenuItem = &.{},
        };

        /// One `ElementOptions.context_menu` entry: the chrome-menu item
        /// shape with a typed message instead of a command string.
        pub const ContextMenuItem = struct {
            label: []const u8 = "",
            msg: ?Msg = null,
            enabled: bool = true,
            separator: bool = false,
        };

        pub const InputMsgFn = *const fn (edit: canvas.TextInputEvent) Msg;
        pub const ValueMsgFn = *const fn (value: f32) Msg;
        pub const LinkMsgFn = *const fn (link: []const u8) Msg;
        pub const ScrollMsgFn = *const fn (scroll: canvas.ScrollState) Msg;

        pub const Node = struct {
            widget: Widget = .{ .kind = .stack },
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            /// Deferred `ElementOptions.wrap`: text content may be
            /// assigned after `el` returns (builder sugar and the markup
            /// engines both do), so the single-span conversion (true)
            /// and the no-wrap stamp (false) happen in `finalizeNode`,
            /// when the text is final.
            wrap: ?bool = null,
            style_tokens: StyleTokenRefs = .{},
            on_press: ?Msg = null,
            on_double_press: ?Msg = null,
            on_toggle: ?Msg = null,
            on_change: ?Msg = null,
            on_submit: ?Msg = null,
            on_dismiss: ?Msg = null,
            on_hold: ?Msg = null,
            on_reach_end: ?Msg = null,
            on_reach_start: ?Msg = null,
            on_input: ?InputMsgFn = null,
            on_value: ?ValueMsgFn = null,
            on_resize: ?ValueMsgFn = null,
            on_scroll: ?ScrollMsgFn = null,
            context_menu: []const ContextMenuItem = &.{},
            nodes: []const Node = &.{},
            /// Markup authoring provenance, stamped by the markup engines
            /// when the builder carries a `provenance_sink`; null for
            /// builder-authored (Zig) nodes, which is itself the honest
            /// answer write-back tooling reports for them.
            source: ?*const ui_provenance.NodeSource = null,
        };

        pub const Handler = struct {
            id: ObjectId,
            event: UiHandlerEvent,
            action: Action,

            pub const Action = union(enum) {
                message: Msg,
                input: InputMsgFn,
                value: ValueMsgFn,
                scroll: ScrollMsgFn,
                /// Per-item context-menu messages, indexed like the
                /// widget's `context_menu` items (null = inert entry:
                /// separator or msg-less item).
                context_menu: []const ?Msg,
            };
        };

        /// Comptime message constructor for `on_input`: `inputMsg(.draft)`
        /// yields a function building `Msg{ .draft = edit }`.
        pub fn inputMsg(comptime tag: std.meta.Tag(Msg)) InputMsgFn {
            return struct {
                fn make(edit: canvas.TextInputEvent) Msg {
                    return @unionInit(Msg, @tagName(tag), edit);
                }
            }.make;
        }

        /// Comptime message constructor for `on_input` over a DECLARED
        /// text-input event union (`ui_markup_reflect.declaredTextInputUnion`
        /// — the transpiled-core shape, where the emitted module declares
        /// its own mirror of `canvas.TextInputEvent` and type identity
        /// cannot cross the emission boundary). The built message carries
        /// the arm's own union value, translated field-for-field from the
        /// runtime event at dispatch: tags map by name, numeric fields widen
        /// the way the payload declares them (i64 or f64), and the event's
        /// text slices ride through unchanged (host-event lifetime — one
        /// dispatch, exactly what `update` gets everywhere else).
        pub fn translatedInputMsg(comptime tag: std.meta.Tag(Msg), comptime Payload: type) InputMsgFn {
            return struct {
                fn caret(comptime D: type, direction: canvas.TextCaretDirection) D {
                    return switch (direction) {
                        inline else => |d| @field(D, @tagName(d)),
                    };
                }

                fn num(comptime N: type, value: usize) N {
                    // Saturating, not @intCast: selection offsets carry a
                    // defined "to the end, whatever the length" sentinel —
                    // select-all synthesizes `set_selection` with
                    // `focus = maxInt(usize)` (events.zig), which every
                    // consumer snaps to its text length (the runtime editor
                    // via snapTextSelection, an elm-mirror core via its own
                    // snap). maxInt(usize) does not fit the declared i64
                    // field class, and panicking on translation killed the
                    // app on the first cmd/ctrl+A (or automation set_text)
                    // in ANY transpiled-core text field. Saturating keeps
                    // the sentinel's meaning — still past any real length,
                    // the core's snap resolves it exactly like the Zig
                    // TextEditState does — and leaves real offsets exact.
                    return if (@typeInfo(N) == .float) @floatFromInt(value) else std.math.lossyCast(N, value);
                }

                fn make(edit: canvas.TextInputEvent) Msg {
                    const payload: Payload = switch (edit) {
                        .insert_text => |inserted| @unionInit(Payload, "insert_text", inserted),
                        .delete_backward => @unionInit(Payload, "delete_backward", {}),
                        .delete_forward => @unionInit(Payload, "delete_forward", {}),
                        .delete_word_backward => @unionInit(Payload, "delete_word_backward", {}),
                        .delete_word_forward => @unionInit(Payload, "delete_word_forward", {}),
                        .clear => @unionInit(Payload, "clear", {}),
                        .move_caret => |move| blk: {
                            const Move = @FieldType(Payload, "move_caret");
                            break :blk @unionInit(Payload, "move_caret", .{
                                .direction = caret(@FieldType(Move, "direction"), move.direction),
                                .extend = move.extend,
                            });
                        },
                        .set_selection => |selection| blk: {
                            const Selection = @FieldType(Payload, "set_selection");
                            break :blk @unionInit(Payload, "set_selection", .{
                                .anchor = num(@FieldType(Selection, "anchor"), selection.anchor),
                                .focus = num(@FieldType(Selection, "focus"), selection.focus),
                            });
                        },
                        .set_composition => |composition| blk: {
                            const Composition = @FieldType(Payload, "set_composition");
                            const Cursor = @typeInfo(@FieldType(Composition, "cursor")).optional.child;
                            break :blk @unionInit(Payload, "set_composition", .{
                                .text = composition.text,
                                .cursor = if (composition.cursor) |cursor| num(Cursor, cursor) else null,
                            });
                        },
                        .commit_composition => @unionInit(Payload, "commit_composition", {}),
                        .cancel_composition => @unionInit(Payload, "cancel_composition", {}),
                    };
                    return @unionInit(Msg, @tagName(tag), payload);
                }
            }.make;
        }

        /// Comptime message constructor for `on_value`: `valueMsg(.confidence)`
        /// yields a function building `Msg{ .confidence = value }`.
        pub fn valueMsg(comptime tag: std.meta.Tag(Msg)) ValueMsgFn {
            return struct {
                fn make(value: f32) Msg {
                    return @unionInit(Msg, @tagName(tag), value);
                }
            }.make;
        }

        /// Comptime message constructor for `on_value`/`on_resize` over a
        /// DECLARED one-number float arm (`ui_markup_reflect.valueArmClass`
        /// — the transpiled-core shape, where the arm's payload is the
        /// emitted `f64` rather than `f32` by identity). The runtime's
        /// applied 0..1 fraction widens exactly at dispatch.
        pub fn translatedValueMsg(comptime tag: std.meta.Tag(Msg), comptime Payload: type) ValueMsgFn {
            return struct {
                fn make(value: f32) Msg {
                    const payload: Payload = @floatCast(value);
                    return @unionInit(Msg, @tagName(tag), payload);
                }
            }.make;
        }

        /// Comptime message constructor for `on_scroll`:
        /// `scrollMsg(.activity_scrolled)` yields a function building
        /// `Msg{ .activity_scrolled = scroll }` from the post-scroll
        /// `canvas.ScrollState`.
        pub fn scrollMsg(comptime tag: std.meta.Tag(Msg)) ScrollMsgFn {
            return struct {
                fn make(scroll_state: canvas.ScrollState) Msg {
                    return @unionInit(Msg, @tagName(tag), scroll_state);
                }
            }.make;
        }

        /// Comptime message constructor for `on_scroll` over a DECLARED
        /// scroll-state record (`ui_markup_reflect.declaredScrollStateRecord`
        /// — the transpiled-core shape, where the emitted module declares
        /// its own mirror of `canvas.ScrollState` and type identity cannot
        /// cross the emission boundary). The built message carries the
        /// arm's own record value, translated field-for-field from the
        /// runtime state at dispatch: fields map by name, and each numeric
        /// field widens the way the payload declares it (exactly into
        /// floats, rounded to the nearest whole number into integers).
        pub fn translatedScrollMsg(comptime tag: std.meta.Tag(Msg), comptime Payload: type) ScrollMsgFn {
            return struct {
                fn num(comptime N: type, value: f32) N {
                    return if (@typeInfo(N) == .float) @floatCast(value) else @intFromFloat(@round(value));
                }

                /// The `canvas.ScrollState` field behind a payload field
                /// name: identical for the canvas spelling, mapped for the
                /// TS SDK spelling (`viewportExtent` — transpiled fields
                /// keep their TS names).
                fn sourceName(comptime name: []const u8) []const u8 {
                    if (@hasField(canvas.ScrollState, name)) return name;
                    inline for (reflect.scroll_state_field_names_ts, 0..) |ts_name, index| {
                        if (comptime std.mem.eql(u8, name, ts_name)) return reflect.scroll_state_field_names[index];
                    }
                    unreachable; // declaredScrollStateRecord admits no other name
                }

                fn make(scroll_state: canvas.ScrollState) Msg {
                    var payload: Payload = undefined;
                    inline for (@typeInfo(Payload).@"struct".fields) |field| {
                        @field(payload, field.name) = num(field.type, @field(scroll_state, sourceName(field.name)));
                    }
                    return @unionInit(Msg, @tagName(tag), payload);
                }
            }.make;
        }

        /// Comptime message constructor for `on_link`: `linkMsg(.open_url)`
        /// yields a function building `Msg{ .open_url = link }`. The link
        /// slice lives in the view arena (or the caller's markdown source),
        /// valid while the tree's handler table is.
        pub fn linkMsg(comptime tag: std.meta.Tag(Msg)) LinkMsgFn {
            return struct {
                fn make(link: []const u8) Msg {
                    return @unionInit(Msg, @tagName(tag), link);
                }
            }.make;
        }

        pub const Tree = struct {
            root: Widget,
            handlers: []const Handler,
            /// Non-null when this build synthesized the anchored
            /// context-menu fallback surface (see
            /// `Ui.context_menu_fallback_target`): the app loop uses the
            /// ids to route item presses through `msgForContextMenu` —
            /// the SAME handler entry native selections resolve — and to
            /// close its open state on dismissal.
            context_menu_fallback: ?ContextMenuFallback = null,

            /// The synthesized context-menu fallback surface's identity.
            pub const ContextMenuFallback = struct {
                /// The widget whose declared `context_menu` presents.
                target_id: ObjectId,
                /// The synthesized anchored `dropdown_menu` surface.
                surface_id: ObjectId,
                /// Synthesized `menu_item` ids, index-aligned with the
                /// target's `context_menu` items; separators hold 0.
                item_ids: []const ObjectId,

                /// The declared-item index a synthesized menu item
                /// dispatches, or null for ids outside this surface.
                pub fn itemIndex(self: ContextMenuFallback, id: ObjectId) ?usize {
                    if (id == 0) return null;
                    for (self.item_ids, 0..) |item_id, index| {
                        if (item_id == id) return index;
                    }
                    return null;
                }
            };

            pub fn msgFor(self: Tree, id: ObjectId, event: UiHandlerEvent) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == event and handler.action == .message) {
                        return handler.action.message;
                    }
                }
                return null;
            }

            /// Typed dispatch for text edits: builds the message through the
            /// widget's `on_input` constructor.
            pub fn msgForTextEdit(self: Tree, id: ObjectId, edit: canvas.TextInputEvent) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .input and handler.action == .input) {
                        return handler.action.input(edit);
                    }
                }
                return null;
            }

            /// Typed dispatch for value changes: builds the message through
            /// the widget's `on_value` constructor.
            pub fn msgForValue(self: Tree, id: ObjectId, value: f32) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .change and handler.action == .value) {
                        return handler.action.value(value);
                    }
                }
                return null;
            }

            /// Typed dispatch for a slider's applied value change (a
            /// pointer rail click or scrub drag): the widget's
            /// `on_value` constructor when bound, else its plain
            /// `on_change` Msg — the same resolution order the keyboard
            /// path's set_value intent uses, so both input families
            /// reach the same handler.
            pub fn msgForChange(self: Tree, id: ObjectId, value: f32) ?Msg {
                if (self.msgForValue(id, value)) |msg| return msg;
                return self.msgFor(id, .change);
            }

            /// Typed dispatch for split-fraction changes: builds the
            /// message through the split's `on_resize` constructor.
            pub fn msgForResize(self: Tree, id: ObjectId, fraction: f32) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .resize and handler.action == .value) {
                        return handler.action.value(fraction);
                    }
                }
                return null;
            }

            /// Typed dispatch for scroll offset changes: builds the message
            /// through the widget's `on_scroll` constructor.
            pub fn msgForScroll(self: Tree, id: ObjectId, scroll_state: canvas.ScrollState) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .scroll and handler.action == .scroll) {
                        return handler.action.scroll(scroll_state);
                    }
                }
                return null;
            }

            /// Typed dispatch for a dismissed floating surface: the
            /// surface's `on_dismiss` message.
            pub fn msgForDismiss(self: Tree, id: ObjectId) ?Msg {
                return self.msgFor(id, .dismiss);
            }

            /// Typed dispatch for a press-and-hold (or menu-less secondary
            /// click): the widget's `on_hold` message.
            pub fn msgForHold(self: Tree, id: ObjectId) ?Msg {
                return self.msgFor(id, .hold);
            }

            /// Typed dispatch for an approach-end signal on a scroll
            /// container: the widget's `on_reach_end` message. The
            /// hysteresis (fire once per approach, re-arm on retreat or
            /// content growth) lives with the dispatcher (`UiApp`).
            pub fn msgForReachEnd(self: Tree, id: ObjectId) ?Msg {
                return self.msgFor(id, .reach_end);
            }

            /// Typed dispatch for an approach-START signal (load older
            /// history): the widget's `on_reach_start` message, with the
            /// same dispatcher-owned hysteresis as reach-end.
            pub fn msgForReachStart(self: Tree, id: ObjectId) ?Msg {
                return self.msgFor(id, .reach_start);
            }

            /// Whether the widget binds an `on_hold` handler (the UiApp
            /// hold-timer arms only for these).
            pub fn hasHoldHandler(self: Tree, id: ObjectId) bool {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .hold) return true;
                }
                return false;
            }

            /// Typed dispatch for a selected context-menu item: the message
            /// declared for the widget's `context_menu[item_index]`.
            pub fn msgForContextMenu(self: Tree, id: ObjectId, item_index: usize) ?Msg {
                for (self.handlers) |handler| {
                    if (handler.id == id and handler.event == .context_menu and handler.action == .context_menu) {
                        const msgs = handler.action.context_menu;
                        if (item_index >= msgs.len) return null;
                        return msgs[item_index];
                    }
                }
                return null;
            }

            pub fn findWidget(self: Tree, id: ObjectId) ?Widget {
                return findWidgetIn(self.root, id);
            }

            /// Typed dispatch for pointer events: a released press over a
            /// widget resolves through the engine's semantic intent model
            /// (press, then toggle, then select) to the matching handler.
            pub fn msgForPointer(self: Tree, target_id: ObjectId, phase: canvas.WidgetPointerPhase) ?Msg {
                if (phase != .up) return null;
                const widget = self.findWidget(target_id) orelse return null;
                const semantic_actions = [_]canvas.WidgetSemanticAction{ .press, .toggle, .select };
                for (semantic_actions) |action| {
                    const intent = canvas.widgetSemanticControlIntent(widget, action) orelse continue;
                    if (self.msgForIntent(target_id, intent)) |msg| return msg;
                }
                return null;
            }

            /// `msgForPointer` with the pointer's click count: a release
            /// whose count reached 2 prefers the widget's `on_double_press`
            /// handler and falls back to the ordinary press resolution
            /// (so a double-click on a widget without the double channel
            /// behaves exactly like two single clicks). This is the
            /// dispatcher the runtime pointer path uses; the two-argument
            /// form stays the single-click entry point.
            pub fn msgForPointerClick(self: Tree, target_id: ObjectId, phase: canvas.WidgetPointerPhase, click_count: u8) ?Msg {
                if (phase == .up and click_count >= 2) {
                    if (self.msgFor(target_id, .double_press)) |msg| return msg;
                }
                return self.msgForPointer(target_id, phase);
            }

            /// Typed dispatch for keyboard events: engine control intents
            /// (activation keys, slider steps) plus enter-to-submit on text
            /// entry widgets.
            pub fn msgForKeyboard(self: Tree, target_id: ObjectId, keyboard: canvas.WidgetKeyboardEvent) ?Msg {
                const widget = self.findWidget(target_id) orelse return null;
                // A list row prefers a bound submit handler on plain
                // Enter: Enter is the row's PRIMARY action (open the
                // record, play the track — the desktop list convention),
                // while Space keeps the select activation below. Only
                // rows that bind `on_submit` take this branch; everything
                // else resolves exactly as before.
                if (widget.kind == .list_item and isSubmitKeyboard(widget, keyboard)) {
                    if (self.msgFor(target_id, .submit)) |msg| return msg;
                }
                if (canvas.widgetKeyboardControlIntent(widget, keyboard)) |intent| {
                    if (self.msgForIntent(target_id, intent)) |msg| return msg;
                }
                if (isSubmitKeyboard(widget, keyboard)) {
                    if (self.msgFor(target_id, .submit)) |msg| return msg;
                }
                if (isTextEntryWidget(widget) and !widget.state.disabled) {
                    // Events routed through the runtime arrive with the
                    // edit the retained editor actually applied STAMPED
                    // onto `keyboard.edit` (the runtime's one derivation
                    // seam — Escape's search-field clear, composition
                    // cancels, and clipboard edits all ride it), and
                    // `textEditEvent()` returns the stamp first. The
                    // local derivation below is the fallback for events
                    // that never crossed the runtime (direct Tree
                    // consumers, tests); the textarea newline mapping
                    // resolves BEFORE it because the generic key mapping
                    // has no Enter case.
                    const edit = if (keyboard.edit != null)
                        keyboard.edit
                    else
                        canvas.widgetKeyboardNewlineTextEditEvent(widget.kind, keyboard) orelse keyboard.textEditEvent();
                    if (edit) |text_edit| {
                        // Single-line kinds sanitize the edit with the
                        // SAME rule the runtime seam applies before
                        // stamping (strip line breaks; suppress inserts
                        // that strip to nothing), so the fallback
                        // derivation for events that never crossed the
                        // runtime can never feed a model mirror bytes
                        // the retained editor would refuse. Stamped
                        // edits are already sanitized and pass through
                        // untouched.
                        if (canvas.sanitizedSingleLineTextInputEvent(widget.kind, text_edit)) |sanitized| {
                            if (self.msgForTextEdit(target_id, sanitized)) |msg| return msg;
                        }
                    }
                }
                return null;
            }

            fn msgForIntent(self: Tree, id: ObjectId, intent: canvas.WidgetControlIntent) ?Msg {
                return switch (intent.kind) {
                    .press => self.msgFor(id, .press),
                    .toggle => self.msgFor(id, .toggle),
                    .select => self.msgFor(id, .press),
                    .set_value => blk: {
                        if (intent.value) |value| {
                            if (self.msgForValue(id, value)) |msg| break :blk msg;
                        }
                        break :blk self.msgFor(id, .change);
                    },
                    .scroll_by, .scroll_to_start, .scroll_to_end => null,
                };
            }
        };

        pub fn init(arena: std.mem.Allocator) Self {
            return .{ .arena = arena };
        }

        pub fn el(self: *Self, kind: WidgetKind, options: ElementOptions, children: anytype) Node {
            if (options.on_dismiss != null) warnDismissHandlerKind(kind);
            if (options.on_resize != null) warnResizeHandlerKind(kind);
            return .{
                .widget = widgetFromOptions(kind, options),
                .key = options.key,
                .global_key = options.global_key,
                .wrap = options.wrap,
                .style_tokens = options.style_tokens,
                .on_press = options.on_press,
                .on_double_press = options.on_double_press,
                .on_toggle = options.on_toggle,
                .on_change = options.on_change,
                .on_submit = options.on_submit,
                .on_dismiss = options.on_dismiss,
                .on_hold = options.on_hold,
                .on_reach_end = options.on_reach_end,
                .on_reach_start = options.on_reach_start,
                .on_input = options.on_input,
                .on_value = options.on_value,
                .on_resize = options.on_resize,
                .on_scroll = options.on_scroll,
                .context_menu = self.dupeContextMenuItems(options.context_menu),
                .nodes = self.childNodes(children),
            };
        }

        /// Lower built `<context-menu>` child nodes into declared items:
        /// a `menu_item` node becomes one item (its text run is the
        /// label, its `on_press` the selection Msg, `disabled` flips
        /// enabled) and a `separator` node keeps its slot as a divider.
        /// Both markup engines build the menu's children through the
        /// ordinary element path — structure tags, interpolation, and
        /// message typing all apply — and lower the result here, so the
        /// item shape is stated once.
        pub fn contextMenuItemsFromNodes(self: *Self, nodes: []const Node) []const ContextMenuItem {
            if (nodes.len == 0) return &.{};
            const items = self.arena.alloc(ContextMenuItem, nodes.len) catch {
                self.failed = true;
                return &.{};
            };
            for (nodes, 0..) |node, index| {
                items[index] = if (node.widget.kind == .separator)
                    .{ .separator = true }
                else
                    .{
                        .label = node.widget.text,
                        .msg = node.on_press,
                        .enabled = !node.widget.state.disabled,
                    };
            }
            return items;
        }

        /// Copy rather than alias: callers pass slices of literals that do
        /// not outlive the expression (same rule as `childNodes`).
        fn dupeContextMenuItems(self: *Self, items: []const ContextMenuItem) []const ContextMenuItem {
            if (items.len == 0) return &.{};
            const copy = self.arena.alloc(ContextMenuItem, items.len) catch {
                self.failed = true;
                return &.{};
            };
            @memcpy(copy, items);
            return copy;
        }

        pub fn row(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.row, options, children);
        }

        pub fn column(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.column, options, children);
        }

        pub fn stack(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.stack, options, children);
        }

        pub fn panel(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.panel, options, children);
        }

        pub fn scroll(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.scroll_view, options, children);
        }

        pub fn list(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.list, options, children);
        }

        /// Options shared by `virtualWindow` and `virtualList` — declare
        /// them once, pass the same value to both calls.
        pub const VirtualListOptions = struct {
            /// Stable list identity: becomes the element's `global_key`
            /// (so the scroll region's structural id survives layout
            /// refactors) and the identity the runtime window source
            /// resolves scroll state by. Unique per (scroll_view,
            /// global_key) pair within the tree.
            id: []const u8,
            /// TOTAL number of items the MODEL holds right now — the
            /// model owns the data; the runtime only ever sees the
            /// count, the fixed extent, and the built window.
            item_count: usize,
            /// Fixed per-item extent in points — the v1 contract:
            /// uniform row heights, so the visible index range, the
            /// content extent, and the scrollbar all derive from
            /// arithmetic instead of measuring 100k unbuilt rows.
            item_extent: f32,
            /// Vertical gap between rows (part of the row stride).
            gap: f32 = 0,
            /// Rows built beyond the visible range on each side: scroll
            /// slack until the next window rebuild lands.
            overscan: usize = 4,
            /// Viewport height assumed when no runtime scroll state
            /// exists for the list yet. Bare builds (plain `finalize`
            /// tests, previews) use it directly; under `UiApp` the
            /// installed window source falls back to the canvas height
            /// instead, so apps normally leave it 0.
            viewport_fallback: f32 = 0,
            width: f32 = 0,
            height: f32 = 0,
            min_width: f32 = 0,
            grow: f32 = 0,
            padding: f32 = 0,
            style: canvas.WidgetStyle = .{},
            style_tokens: StyleTokenRefs = .{},
            /// Container semantics; role defaults to `list`, and the
            /// layout pass stamps each built row's absolute
            /// `list_item_index` against the declared count.
            semantics: canvas.WidgetSemantics = .{},
            /// Optional scroll observation (`scrollMsg` constructor).
            /// NOT required for windowing: the runtime re-derives the
            /// view on scroll for every mounted virtual list on its
            /// own; bind this only when the model wants the offset.
            on_scroll: ?ScrollMsgFn = null,
            /// The infinite-scroll fetch signal (see
            /// `ElementOptions.on_reach_end`).
            on_reach_end: ?Msg = null,
            /// The load-older-history signal (see
            /// `ElementOptions.on_reach_start`) — the tail-anchored
            /// transcript's counterpart to `on_reach_end`.
            on_reach_start: ?Msg = null,
            /// VARIABLE-extent rows: a cheap per-item extent ESTIMATE
            /// (called with `extent_context` and the item's LOGICAL
            /// index, `index_base + physical`). Setting it selects the
            /// variable contract: the window derives from an offset
            /// table of estimate prefix sums that the engine patches
            /// with measured actuals for mounted rows, rows lay out at
            /// their intrinsic heights, and `item_extent` becomes the
            /// fallback estimate only (it may be 0). Estimates should
            /// come from model facts (line counts, attachment
            /// presence) — never from layout; rough is fine, the
            /// measured corrections converge the geometry and the
            /// engine anchors the viewport so corrections never move
            /// visible content.
            extent_estimate: ?canvas.VirtualExtentEstimateFn = null,
            extent_context: ?*const anyopaque = null,
            /// Logical index of physical item 0. DECREASE it by the
            /// prepended count when loading older history (chat
            /// transcripts keyed by sequence number): logical item
            /// identity — row keys, measured extents, the viewport
            /// anchor — survives the prepend, and the engine grows the
            /// scroll offset by the prepended extent so the user keeps
            /// looking at the same rows. Increase it when the head is
            /// truncated (bounded transcripts compacting old rows).
            index_base: u64 = 0,
            /// Which end the list anchors to. `.trailing` is the chat
            /// contract: the first build opens at the bottom, and while
            /// the user sits at the bottom an appended batch keeps the
            /// list pinned there (scrolled away, appends never yank the
            /// viewport). Uniform lists may use it too — `item_extent`
            /// doubles as the estimate.
            anchor: VirtualListAnchor = .leading,
            /// Edge behavior of the list's scroll region (see
            /// `ElementOptions.overscroll`): `.default` follows the
            /// `ScrollPhysics.overscroll` token — off unless a theme
            /// flips it — and `.rubber_band` lets this list bounce past
            /// its edges.
            overscroll: canvas.WidgetOverscroll = .default,
        };

        /// Anchoring contract of a windowed virtual list (see
        /// `VirtualListOptions.anchor`).
        pub const VirtualListAnchor = enum { leading, trailing };

        /// The DATA-WINDOW seam of the windowed virtual list: resolve
        /// which item range this build should materialize. The runtime
        /// owns the viewport math — the installed window source supplies
        /// the retained scroll offset and viewport for the list identity,
        /// and the shared `canvas.virtualListRange` turns them into the
        /// visible index range plus overscan. The MODEL owns the data:
        /// read `range.start_index..range.end_index`, build one keyed
        /// node per item, and hand both to `virtualList`. No callbacks
        /// into the model, no engine-owned copies of the items — the
        /// range is plain data the view reads during build, the same
        /// direction of flow as the chrome and appearance channels.
        pub fn virtualWindow(self: *Self, options: VirtualListOptions) canvas.VirtualListRange {
            const id = globalWidgetId(.scroll_view, .{ .str = options.id });
            const resolved: ?VirtualWindowState = blk: {
                if (self.virtual_window_source) |source| {
                    if (source(self.virtual_window_context, id)) |value| break :blk value;
                }
                break :blk null;
            };
            if (virtualOptionsVariable(options)) return self.virtualWindowVariable(options, id, resolved);
            const state: VirtualWindowState = resolved orelse .{ .offset = 0, .viewport_extent = options.viewport_fallback };
            return canvas.virtualListRange(.{
                .item_count = options.item_count,
                .item_extent = options.item_extent,
                .item_gap = options.gap,
                .viewport_extent = state.viewport_extent,
                .scroll_offset = state.offset,
                .overscan = options.overscan,
            });
        }

        /// Whether the options select the VARIABLE-extent contract: an
        /// estimate fn does, and so does tail anchoring alone (uniform
        /// trailing lists ride the same offset table with `item_extent`
        /// as a constant estimate — the was-at-bottom check needs the
        /// retained previous total).
        fn virtualOptionsVariable(options: VirtualListOptions) bool {
            return options.extent_estimate != null or options.anchor == .trailing;
        }

        /// A user sitting within this many points of the bottom counts
        /// as "at the bottom" for the trailing anchor's stick-on-append
        /// rule (sub-point drift from measured corrections must not
        /// unstick a pinned transcript).
        const trailing_stick_slop: f32 = 1.0;

        /// The variable-extent window computation: resolve the retained
        /// offset table (app loop) or fall back to stateless estimates
        /// (bare builds), consume the table's anchor-preserving offset
        /// delta so corrections and geometry land atomically, apply the
        /// trailing anchor, and derive the window from per-item offsets.
        fn virtualWindowVariable(self: *Self, options: VirtualListOptions, id: ObjectId, resolved: ?VirtualWindowState) canvas.VirtualListRange {
            const state: VirtualWindowState = resolved orelse .{ .offset = 0, .viewport_extent = options.viewport_fallback, .mounted = false };
            const viewport = state.viewport_extent;
            var offset: f32 = state.offset;
            const table: ?*canvas.VirtualExtentTable = blk: {
                if (self.virtual_extent_source) |source| break :blk source(self.virtual_extent_context, id);
                break :blk null;
            };
            var range_options = canvas.VirtualVariableRangeOptions{
                .item_count = options.item_count,
                .gap = options.gap,
                .viewport_extent = viewport,
                .scroll_offset = 0,
                .overscan = options.overscan,
                .index_base = options.index_base,
                .estimate_context = options.extent_context,
                .estimate_fn = options.extent_estimate,
                .uniform_estimate = options.item_extent,
            };
            if (table) |retained| {
                _ = retained.sync(.{
                    .id = id,
                    .item_count = options.item_count,
                    .index_base = options.index_base,
                    .gap = options.gap,
                    .estimate_context = options.extent_context,
                    .estimate_fn = options.extent_estimate,
                    .uniform_estimate = options.item_extent,
                });
                // Corrections and prepends land here, together with the
                // patched offsets below — the anchoring invariant.
                offset += retained.takePendingOffsetDelta();
                const total = retained.totalExtent();
                if (options.anchor == .trailing) {
                    if (!state.mounted) {
                        offset = @max(0, total - viewport);
                    } else if (retained.last_build_total >= 0) {
                        // Was-at-the-bottom re-pin: the RETAINED offset
                        // is compared against the geometry it was
                        // scrolled under (last build's total), so both
                        // appends and measured corrections keep a
                        // pinned transcript pinned — while a viewport
                        // scrolled away is never yanked.
                        const old_max = @max(0, retained.last_build_total - retained.last_build_viewport);
                        if (state.offset >= old_max - trailing_stick_slop) offset = @max(0, total - viewport);
                    }
                }
                retained.last_build_total = total;
                retained.last_build_viewport = viewport;
            } else if (options.anchor == .trailing and !state.mounted) {
                // Stateless first build of a trailing list: open at the
                // estimated bottom (one extra estimate pass — bare-build
                // pricing only; app loops always install a table).
                const probe = canvas.virtualVariableListRange(range_options, null);
                offset = @max(0, probe.content_extent - viewport);
            }
            range_options.scroll_offset = offset;
            const variable = canvas.virtualVariableListRange(range_options, table);
            return .{
                .start_index = variable.start_index,
                .end_index = variable.end_index,
                .first_visible_index = variable.first_visible_index,
                .last_visible_index = variable.last_visible_index,
                // 0 marks the variable contract for `virtualList` (rows
                // stack at intrinsic heights; the table prices the rest).
                .item_extent = 0,
                .item_gap = @max(0, options.gap),
                .scroll_offset = variable.scroll_offset,
                .layout_offset = variable.layout_offset,
                .content_extent = variable.content_extent,
                .before_extent = variable.before_extent,
                .after_extent = variable.after_extent,
                .anchor_extent = variable.anchor_extent,
            };
        }

        /// A WINDOWED virtual list: a runtime-scrolled scroll region
        /// representing `item_count` items of which only `children` —
        /// the rows for the `window` returned by `virtualWindow`, one
        /// keyed node per item — exist in the tree. The runtime owns
        /// the scroll offset (wheel, kinetic, keyboard, and the native
        /// scroll driver, whose scrollbar spans the full virtual
        /// extent); the layout pass places each built row at its
        /// absolute virtual position; and per-item identity rides the
        /// row keys, so engine-owned row state survives scrolling away
        /// and back. Budgets stay viewport-sized: the widget-node cost
        /// is the window, never the dataset.
        pub fn virtualList(self: *Self, options: VirtualListOptions, window: canvas.VirtualListRange, children: anytype) Node {
            var semantics = options.semantics;
            if (semantics.role == .none) semantics.role = .list;
            const variable = virtualOptionsVariable(options);
            const node = self.el(.scroll_view, .{
                .global_key = .{ .str = options.id },
                // Mirror the runtime offset into the source so the flex
                // pass lays the window out at the offset the window was
                // computed for — the same value the scroll reconcile
                // keeps, so source and runtime never fight. (For a
                // variable list this is also the CORRECTION channel: an
                // anchor-preserving offset shift stamps a changed
                // source value, which the reconcile treats as the
                // programmatic scroll it is.)
                .value = window.layout_offset,
                .width = options.width,
                .height = options.height,
                .min_width = options.min_width,
                .grow = options.grow,
                .padding = options.padding,
                .gap = options.gap,
                .virtualized = true,
                .virtual_item_extent = if (variable) 0 else options.item_extent,
                .virtual_overscan = options.overscan,
                .virtual_item_count = options.item_count,
                .virtual_first_index = window.start_index,
                .virtual_anchor_index = if (variable) window.first_visible_index else 0,
                .virtual_anchor_extent = if (variable) window.anchor_extent else 0,
                .virtual_total_extent = if (variable) window.content_extent else 0,
                .style = options.style,
                .style_tokens = options.style_tokens,
                .semantics = semantics,
                .overscroll = options.overscroll,
                .on_scroll = options.on_scroll,
                .on_reach_end = options.on_reach_end,
                .on_reach_start = options.on_reach_start,
            }, children);
            self.recordVirtualWindow(.{
                .id = globalWidgetId(.scroll_view, .{ .str = options.id }),
                .item_count = options.item_count,
                .item_extent = options.item_extent,
                .gap = options.gap,
                .overscan = options.overscan,
                .start_index = window.start_index,
                .end_index = window.start_index + node.nodes.len,
                .variable = variable,
                .index_base = options.index_base,
            });
            return node;
        }

        fn recordVirtualWindow(self: *Self, record: VirtualWindowRecord) void {
            if (self.virtual_window_record_count >= self.virtual_window_records.len) {
                if (builtin.mode == .Debug) {
                    ui_log.warn(
                        "more than {d} virtual lists in one build (canvas.ui_builder.max_virtual_windows) - the excess scrolls but skips the app loop's window coverage check",
                        .{max_virtual_windows},
                    );
                }
                return;
            }
            self.virtual_window_records[self.virtual_window_record_count] = record;
            self.virtual_window_record_count += 1;
        }

        /// The declared virtual windows of this build (`virtualList`
        /// calls), for the app loop.
        pub fn virtualWindows(self: *const Self) []const VirtualWindowRecord {
            return self.virtual_window_records[0..self.virtual_window_record_count];
        }

        /// Two-pane horizontal splitter. Exactly two children (the
        /// panes); `finalize` synthesizes the draggable divider between
        /// them. `value` is the model-owned first-pane fraction (0 lays
        /// out at 0.5); bind `on_resize = valueMsg(.tag)` and echo the
        /// fraction back through `value` for the controlled pattern —
        /// an unbound split keeps its divider position across rebuilds
        /// through the source-wins reconcile, but pane content lays out
        /// at the declared fraction until the model echoes.
        ///
        /// With a nonzero `resize_duration` the declared `value` is a
        /// TARGET instead: a rebuild that moves it eases the rendered
        /// fraction there over that many milliseconds (`resize_easing`
        /// names the curve) instead of snapping — the declarative twin
        /// of `UiApp.Options.layout_tweens`, and the shape markup's
        /// `resize-duration`/`resize-easing` lower to. Reduced motion
        /// snaps inside the runtime.
        pub fn split(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.split, options, children);
        }

        /// Disclosure-tree container: descendant rows carrying
        /// `role = .treeitem` (at any nesting depth) form one roving
        /// keyboard focus set with the ARIA tree keymap — Up/Down walk
        /// visible rows (selection follows focus through each row's
        /// `on_press`), Left collapses or moves to the parent row,
        /// Right expands or moves to the first child row, Home/End jump
        /// to the edges. Expansion is model-owned: expandable rows set
        /// `expanded` and bind `on_toggle`.
        pub fn tree(self: *Self, options: ElementOptions, children: anytype) Node {
            return self.el(.tree, options, children);
        }

        /// The engine renders a status bar's own `text`; it does not lay out
        /// status bar children, so the builder models it as a text leaf.
        pub fn statusBar(self: *Self, options: ElementOptions, status_text: []const u8) Node {
            var node = self.el(.status_bar, options, .{});
            node.widget.text = status_text;
            return node;
        }

        pub fn text(self: *Self, options: ElementOptions, content: []const u8) Node {
            var node = self.el(.text, options, .{});
            node.widget.text = content;
            return node;
        }

        /// A paragraph of inline styled spans (mixed weight/italic/mono/
        /// color/underline/strikethrough/link runs in one wrapped text
        /// block). The spans' bytes are concatenated into an arena buffer
        /// (`widget.text`, the semantics label) and every stored span is
        /// re-sliced into it, so retained-state copies rebase rather than
        /// duplicate. Each link span also grows a hit-area child with
        /// `role = link` semantics; with `options.on_link` set, pressing
        /// it dispatches `on_link(span.link)` through the handler table.
        pub fn paragraph(self: *Self, options: ElementOptions, spans: []const canvas.TextSpan) Node {
            var node = self.el(.text, options, .{});

            var text_len: usize = 0;
            for (spans) |span| text_len += span.text.len;
            const text_bytes = self.arena.alloc(u8, text_len) catch {
                self.failed = true;
                return node;
            };
            const stored = self.arena.dupe(canvas.TextSpan, spans) catch {
                self.failed = true;
                return node;
            };
            var offset: usize = 0;
            for (stored) |*span| {
                @memcpy(text_bytes[offset .. offset + span.text.len], span.text);
                span.text = text_bytes[offset .. offset + span.text.len];
                offset += span.text.len;
            }
            node.widget.text = text_bytes;
            node.widget.spans = stored;

            const link_count = canvas.text_spans.textSpanLinkCount(stored);
            if (link_count == 0) return node;
            const children = self.arena.alloc(Node, link_count) catch {
                self.failed = true;
                return node;
            };
            var child_index: usize = 0;
            for (stored) |span| {
                if (span.link.len == 0) continue;
                children[child_index] = self.el(.text, .{
                    .semantics = .{
                        .role = .link,
                        .label = span.text,
                        .focusable = true,
                    },
                    .on_press = if (options.on_link) |make| make(span.link) else null,
                }, .{});
                child_index += 1;
            }
            node.nodes = children;
            return node;
        }

        pub fn button(self: *Self, options: ElementOptions, label: []const u8) Node {
            var node = self.el(.button, options, .{});
            node.widget.text = label;
            return node;
        }

        pub fn listItem(self: *Self, options: ElementOptions, label: []const u8) Node {
            var node = self.el(.list_item, options, .{});
            node.widget.text = label;
            return node;
        }

        pub fn checkbox(self: *Self, options: ElementOptions) Node {
            return self.el(.checkbox, options, .{});
        }

        /// house-style avatar: a pill-clipped image with an initials
        /// fallback. With `options.image` set to a registered ImageId the
        /// engine clips the image to the avatar circle (`cover` fit);
        /// with no image (0) it renders `initials` centered — so an app
        /// shows initials while the image is loading and keeps them when
        /// the fetch or decode failed, by only writing the id into its
        /// model on successful registration (`fx.registerImageBytes`).
        pub fn avatar(self: *Self, options: ElementOptions, initials: []const u8) Node {
            var node = self.el(.avatar, options, .{});
            node.widget.text = initials;
            node.widget.image_fit = .cover;
            return node;
        }

        /// An image leaf drawing the registered ImageId in
        /// `options.image` (nothing renders while the id is 0 or
        /// unregistered).
        pub fn image(self: *Self, options: ElementOptions) Node {
            return self.el(.image, options, .{});
        }

        /// The media surface leaf (markup `<media-surface surface={id}>`):
        /// composites a texture PRODUCED OUTSIDE the widget tree — a
        /// video decoder, a camera pipeline, an external renderer —
        /// into the layout like any widget. `options.image` carries the
        /// SURFACE id the producer targets
        /// (`Runtime.acquireMediaSurfaceProducer`), a model-owned u64 in
        /// the ImageId value space; 0 draws nothing (the image-leaf
        /// convention). Until the first producer frame arrives, live
        /// hosts show the surface's deterministic id-derived placeholder
        /// — which is also ALL the reference renderer (goldens,
        /// screenshots, replay pixel marks) ever shows, because texture
        /// contents are presentation chrome by policy. Size it like an
        /// image: definite width/height or flex grow (no intrinsic size).
        pub fn mediaSurface(self: *Self, options: ElementOptions) Node {
            return self.el(.media_surface, options, .{});
        }

        /// A built-in vector icon leaf: `name` is one of
        /// `canvas.icons.known_icon_names` (compile error otherwise), so
        /// icon references never rot. Size comes from `options.size` /
        /// explicit width and height (square by default), tint from the
        /// `foreground` style token (`currentColor` in the SVG source).
        pub fn icon(self: *Self, options: ElementOptions, comptime name: []const u8) Node {
            comptime {
                if (canvas.icons.find(name) == null) {
                    @compileError("unknown built-in icon \"" ++ name ++ "\" - see canvas.icons.known_icon_names");
                }
            }
            var node = self.el(.icon, options, .{});
            node.widget.text = name;
            return node;
        }

        /// An icon leaf rendering an APP-REGISTERED vector icon: `name`
        /// must be registered at boot via `canvas.icons.registerAppIcons`
        /// (comptime-parse your SVG with `canvas.svg_icon.parseComptime`).
        /// No compile-time check is possible for runtime registrations —
        /// an unknown name draws the missing-icon fallback (a slashed
        /// circle), with a Debug-build warning naming the value. For
        /// built-in names prefer `icon`, which compile-checks the name.
        pub fn appIcon(self: *Self, options: ElementOptions, name: []const u8) Node {
            // The EXPLICIT icon channel (`Widget.icon`), not `text`: the
            // draw path then owns the honest failure mode above, instead
            // of the historical glyph rendering spelling the raw name in
            // text glyphs.
            var with_icon = options;
            with_icon.icon = name;
            return self.el(.icon, with_icon, .{});
        }

        /// An icon leaf rendering a literal glyph (the pre-vector-icon
        /// behavior, e.g. an emoji or dingbat character): kept for text
        /// glyphs; prefer `icon` for the built-in vector set.
        pub fn iconGlyph(self: *Self, options: ElementOptions, glyph: []const u8) Node {
            var node = self.el(.icon, options, .{});
            node.widget.text = glyph;
            return node;
        }

        pub fn textField(self: *Self, options: ElementOptions) Node {
            return self.el(.text_field, options, .{});
        }

        pub fn separator(self: *Self, options: ElementOptions) Node {
            return self.el(.separator, options, .{});
        }

        /// Flexible empty space between siblings.
        pub fn spacer(self: *Self, grow: f32) Node {
            return self.el(.stack, .{ .grow = grow }, .{});
        }

        pub const ChartOptions = struct {
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            /// Definite plot width/height (same contract as
            /// `ElementOptions.width`/`height`); 0 keeps the intrinsic
            /// sparkline-sized default (160x48), and `grow` flexes.
            width: f32 = 0,
            height: f32 = 0,
            grow: f32 = 0,
            padding: f32 = 0,
            /// Explicit y domain; null derives each side from the data
            /// (bar series force 0 into a derived domain — bars always
            /// have an honest zero baseline).
            y_min: ?f32 = null,
            y_max: ?f32 = null,
            /// Horizontal token-hairline gridlines at even divisions
            /// (0 = none; gridlines are opt-in, never default).
            grid_lines: u8 = 0,
            /// Hairline at the baseline (zero clamped into the domain).
            baseline: bool = false,
            /// Line stroke width override (default 1.5).
            stroke_width: ?f32 = null,
            /// Category labels for the x axis, one per sample index
            /// (label i names sample i). Empty = no x axis; the renderer
            /// reserves a gutter below the plot and thins the labels to
            /// fit the width. Dropped when any series downsamples — the
            /// bucketed indices no longer name the labeled samples.
            x_labels: []const []const u8 = &.{},
            /// Numeric y tick labels (opt-in): domain min, max, and each
            /// gridline value in a measured gutter left of the plot,
            /// muted, deterministically formatted.
            y_labels: bool = false,
            /// Pointer-hover point details (opt-in): hovering snaps to
            /// the nearest sample and floats a card with its label and
            /// every series' value. Interaction-only chrome — static
            /// renders never show it. Presses still fall through.
            hover_details: bool = false,
            /// Role defaults to `chart`; an empty label gets a generated
            /// series summary ("chart: line cpu 60 pts last 0.42; ...")
            /// so automation can assert on the data without pixels, and
            /// `semantics.value` reports the first series' latest point.
            semantics: canvas.WidgetSemantics = .{},
        };

        /// A data chart leaf: line (with optional area fill),
        /// bar, and band series over uniform x steps, drawn through the
        /// vector path pipeline with token-driven colors. Series are
        /// copied into the build arena and DOWNSAMPLED deterministically
        /// to `canvas.max_chart_points_per_series` points (index-bucket
        /// min/max, spikes preserved), so a 10k-point star-history series
        /// renders within the path budget instead of erroring. Axis tick
        /// labels are opt-in (`x_labels`/`y_labels`, drawn muted in
        /// reserved gutters) and hover details opt in per chart. Presses
        /// fall through like text; with `hover_details` the chart is a
        /// hover target only.
        pub fn chart(self: *Self, options: ChartOptions, series: []const canvas.ChartSeries) Node {
            var node = self.el(.chart, .{
                .key = options.key,
                .global_key = options.global_key,
                .width = options.width,
                .height = options.height,
                .grow = options.grow,
                .padding = options.padding,
                .style = .{ .stroke_width = options.stroke_width },
                .semantics = options.semantics,
            }, .{});
            const stored = self.arena.alloc(canvas.ChartSeries, series.len) catch {
                self.failed = true;
                return node;
            };
            var downsampled = false;
            for (series, stored) |source, *entry| {
                entry.* = source;
                entry.values = self.downsampledChartCopy(source.values);
                entry.low = if (source.kind == .band) self.downsampledChartCopy(source.low) else &.{};
                if (entry.values.len != source.values.len) downsampled = true;
            }
            node.widget.chart = .{
                .series = stored,
                .y_min = options.y_min,
                .y_max = options.y_max,
                .grid_lines = options.grid_lines,
                .baseline = options.baseline,
                // Downsampling re-buckets sample indices, so per-sample
                // category labels would name the wrong points: drop them
                // (silence over a lie) — value-scale y labels survive.
                .x_labels = if (downsampled) &.{} else options.x_labels,
                .y_labels = options.y_labels,
                .hover_details = options.hover_details,
            };
            if (node.widget.semantics.label.len == 0) {
                node.widget.semantics.label = self.chartSummary(series);
            }
            return node;
        }

        fn downsampledChartCopy(self: *Self, values: []const f32) []const f32 {
            if (values.len == 0) return &.{};
            const output = self.arena.alloc(f32, canvas.downsampledChartLen(values.len)) catch {
                self.failed = true;
                return &.{};
            };
            return canvas.downsampleChartValues(values, output);
        }

        /// The generated semantics summary describes the SOURCE series
        /// (pre-downsampling counts and the true latest values), so
        /// automation asserts on the data the app handed over.
        fn chartSummary(self: *Self, series: []const canvas.ChartSeries) []const u8 {
            var summary: []const u8 = "chart:";
            for (series, 0..) |entry, index| {
                const name = if (entry.label.len > 0) entry.label else @tagName(entry.kind);
                const joiner: []const u8 = if (index == 0) " " else "; ";
                summary = if (entry.values.len > 0)
                    self.fmt("{s}{s}{s} {d} pts last {d:.2}", .{ summary, joiner, name, entry.values.len, entry.values[entry.values.len - 1] })
                else
                    self.fmt("{s}{s}{s} empty", .{ summary, joiner, name });
            }
            return summary;
        }

        pub const InputGroupOptions = struct {
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            /// Definite group width/height (same contract as
            /// `ElementOptions.width`/`height`); 0 sizes from the entry's
            /// intrinsic height plus the actions row, and `grow` flexes.
            width: f32 = 0,
            height: f32 = 0,
            min_width: f32 = 0,
            grow: f32 = 0,
            /// Group semantics; role defaults to `group` so the whole
            /// field announces as one named unit while the entry and the
            /// accessory controls stay individually reachable.
            semantics: canvas.WidgetSemantics = .{},
        };

        pub const InputGroupActionsOptions = struct {
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            gap: f32 = 6,
        };

        /// Composer-grade grouped input (the house input-group): ONE
        /// bordered field wrapping a multi-line text entry plus an
        /// optional accessory row of controls inside the same border —
        /// the reference composer shape (attach bottom-left, send
        /// bottom-right). The group wears text-input chrome and the
        /// focus ring whenever focus is on any descendant; the entry's
        /// own chrome (fill, border, focus ring) dissolves (the notes
        /// editor-pane treatment) unless the author styled it
        /// explicitly, so the group reads as one field. The entry comes
        /// FIRST (document order is focus order); build the accessory
        /// row with `inputGroupActions`.
        pub fn inputGroup(self: *Self, options: InputGroupOptions, entry: Node, actions: ?Node) Node {
            var semantics = options.semantics;
            if (semantics.role == .none) semantics.role = .group;
            var entry_node = entry;
            dissolveInputGroupEntryChrome(&entry_node);
            // The entry absorbs the group's height: an explicitly sized
            // group grows its text entry, never a gap under the actions.
            if (entry_node.widget.layout.grow == 0) entry_node.widget.layout.grow = 1;
            const child_count: usize = if (actions == null) 1 else 2;
            const nodes = self.arena.alloc(Node, child_count) catch {
                self.failed = true;
                return self.el(.input_group, .{ .semantics = semantics }, .{});
            };
            nodes[0] = entry_node;
            if (actions) |actions_node| nodes[1] = actions_node;
            return self.el(.input_group, .{
                .key = options.key,
                .global_key = options.global_key,
                .width = options.width,
                .height = options.height,
                .min_width = options.min_width,
                .grow = options.grow,
                .semantics = semantics,
            }, .{nodes[0..child_count]});
        }

        /// The input-group's accessory row: leading/trailing controls on
        /// one bottom row INSIDE the group's border (put a
        /// `spacer(1)` between the leading and trailing controls). Insets
        /// keep ghost/icon buttons optically inside the field's own text
        /// inset without double-padding the seam.
        pub fn inputGroupActions(self: *Self, options: InputGroupActionsOptions, children: anytype) Node {
            var node = self.el(.row, .{
                .key = options.key,
                .global_key = options.global_key,
                .gap = options.gap,
                .cross = .center,
            }, children);
            node.widget.layout.padding = .{ .top = 4, .left = 8, .right = 8, .bottom = 8 };
            return node;
        }

        /// Dissolve the entry's control chrome into the group (the notes
        /// editor-pane treatment, structural here): transparent fill,
        /// border, and focus ring — the GROUP draws that chrome — unless
        /// the author styled the field explicitly (style tokens included),
        /// in which case the explicit choice wins.
        fn dissolveInputGroupEntryChrome(node: *Node) void {
            const transparent = canvas.Color.rgba8(0, 0, 0, 0);
            if (node.widget.style.background == null and node.style_tokens.background == null) {
                node.widget.style.background = transparent;
            }
            if (node.widget.style.border == null and node.style_tokens.border_color == null) {
                node.widget.style.border = transparent;
            }
            if (node.widget.style.focus_ring == null and node.style_tokens.focus_ring == null) {
                node.widget.style.focus_ring = transparent;
            }
        }

        /// Visual state of a stepper step, derived from its index against
        /// `StepperOptions.active`.
        pub const StepState = enum { completed, active, pending };

        pub const StepperStep = struct {
            /// Step label ("Work", "Review · round 2").
            label: []const u8,
        };

        pub const StepperOptions = struct {
            /// Index of the active step: earlier steps render completed
            /// (check indicator), later ones pending. An index past the
            /// last step renders every step completed.
            active: usize = 0,
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            grow: f32 = 0,
            /// Row semantics; role defaults to `list` (each step is a
            /// `listitem` carrying its label, state, and position).
            semantics: canvas.WidgetSemantics = .{},
        };

        pub fn stepState(active: usize, index: usize) StepState {
            if (index < active) return .completed;
            if (index == active) return .active;
            return .pending;
        }

        /// Stage stepper (the house stepper conventions: item + indicator +
        /// title joined by separators): a horizontal row of steps whose
        /// completed/active/pending states derive from `options.active`.
        /// Indicators are badges — a check for completed steps, the step
        /// number otherwise — and hairline separators connect the steps.
        /// Display-only: driving `active` belongs to the app model.
        pub fn stepper(self: *Self, options: StepperOptions, steps: []const StepperStep) Node {
            var semantics = options.semantics;
            if (semantics.role == .none) semantics.role = .list;
            const node_count = if (steps.len == 0) 0 else steps.len * 2 - 1;
            const nodes = self.arena.alloc(Node, node_count) catch {
                self.failed = true;
                return self.el(.row, .{ .semantics = semantics }, .{});
            };
            for (steps, 0..) |step, index| {
                nodes[index * 2] = self.stepperStepNode(options.active, index, steps.len, step);
                if (index + 1 < steps.len) {
                    // The connector between steps: a bare separator inside
                    // a row renders as a hairline across the space it grows
                    // into.
                    nodes[index * 2 + 1] = self.el(.separator, .{ .grow = 1 }, .{});
                }
            }
            return self.el(.row, .{
                .key = options.key,
                .global_key = options.global_key,
                .gap = 8,
                .cross = .center,
                .grow = options.grow,
                .semantics = semantics,
            }, .{nodes});
        }

        fn stepperStepNode(self: *Self, active: usize, index: usize, count: usize, step: StepperStep) Node {
            const state = stepState(active, index);
            // Completed steps wear the vector `check` icon — the ✓ text
            // glyph is outside the bundled face's coverage and rendered
            // as tofu on the reference/screenshot paths.
            const indicator = self.el(.badge, .{
                .variant = if (state == .pending) canvas.WidgetVariant.outline else .primary,
                .icon = if (state == .completed) "check" else "",
                .text = if (state == .completed) "" else self.fmt("{d}", .{index + 1}),
            }, .{});
            const label: Node = switch (state) {
                .active => self.paragraph(.{}, &.{.{ .text = step.label, .weight = .bold }}),
                .completed => self.text(.{}, step.label),
                .pending => self.text(.{ .style_tokens = .{ .foreground = .text_muted } }, step.label),
            };
            return self.el(.row, .{
                .key = .{ .int = @intCast(index) },
                .gap = 6,
                .cross = .center,
                .selected = state == .active,
                .semantics = .{
                    .role = .listitem,
                    .label = self.fmt("{s} ({s})", .{ step.label, @tagName(state) }),
                    .list_item_index = @intCast(index),
                    .list_item_count = @intCast(count),
                },
            }, .{ indicator, label });
        }

        pub const TimelineOptions = struct {
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            gap: f32 = 0,
            grow: f32 = 0,
            /// Column semantics; role defaults to `list`.
            semantics: canvas.WidgetSemantics = .{},
        };

        /// Timeline/ledger list (the house timeline conventions: item +
        /// indicator + separator + title/description/meta): a column of
        /// `timelineItem` nodes.
        pub fn timeline(self: *Self, options: TimelineOptions, items: anytype) Node {
            var semantics = options.semantics;
            if (semantics.role == .none) semantics.role = .list;
            return self.el(.column, .{
                .key = options.key,
                .global_key = options.global_key,
                .gap = options.gap,
                .grow = options.grow,
                .semantics = semantics,
            }, items);
        }

        pub const TimelineItemOptions = struct {
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            /// Indicator badge text ("3"); empty (with no `icon`) renders
            /// a small dot. Prefer `icon` for symbols — text glyphs
            /// outside the bundled face render as tofu on the
            /// reference/screenshot paths.
            indicator: []const u8 = "",
            /// Vector icon indicator (registry name, e.g. "check"):
            /// drawn inside the badge with the variant's tint. Wins the
            /// badge's content slot alongside `indicator` text.
            icon: []const u8 = "",
            /// Indicator color variant — map run outcomes here (primary
            /// for done, destructive for errors, outline for stopped, ...).
            variant: canvas.WidgetVariant = .outline,
            title: []const u8,
            /// Wrapped muted preview under the title (step summary).
            description: []const u8 = "",
            /// Muted trailing meta line ("claude · sonnet · 1m 12s").
            meta: []const u8 = "",
            /// Hairline connector from the indicator toward the next item;
            /// authors clear it on the last item.
            connector: bool = true,
            /// Whole-item press: adds a trailing chevron and binds the
            /// press to the item's root, focusable with role `listitem`.
            /// A click anywhere on the item dispatches — presses on the
            /// title/description/meta text fall through to the root
            /// (dragging still selects the text).
            on_press: ?Msg = null,
            selected: bool = false,
        };

        /// One timeline/ledger item: leading status indicator (plus
        /// connector), a title/description/meta content column, and — when
        /// pressable — a trailing chevron with `on_press` bound to the
        /// item's root (presses on the content fall through to it).
        pub fn timelineItem(self: *Self, options: TimelineItemOptions) Node {
            const dot = options.indicator.len == 0 and options.icon.len == 0;
            const indicator = self.el(.badge, .{
                .variant = options.variant,
                .text = options.indicator,
                .icon = options.icon,
                .width = if (dot) 10 else 0,
                .height = if (dot) 10 else 0,
            }, .{});
            const lead = if (options.connector)
                self.el(.column, .{ .cross = .center, .gap = 4 }, .{
                    indicator,
                    self.el(.separator, .{ .grow = 1, .width = 1 }, .{}),
                })
            else
                self.el(.column, .{ .cross = .center }, .{indicator});

            const content_nodes = self.arena.alloc(Node, 3) catch {
                self.failed = true;
                return self.el(.stack, .{}, .{});
            };
            content_nodes[0] = self.paragraph(.{}, &.{.{ .text = options.title, .weight = .bold }});
            var content_len: usize = 1;
            if (options.description.len > 0) {
                content_nodes[content_len] = self.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, options.description);
                content_len += 1;
            }
            if (options.meta.len > 0) {
                content_nodes[content_len] = self.paragraph(.{}, &.{.{ .text = options.meta, .color = .text_muted, .scale = 0.9 }});
                content_len += 1;
            }
            const content = self.el(.column, .{ .grow = 1, .gap = 2 }, .{content_nodes[0..content_len]});

            const item_semantics = canvas.WidgetSemantics{
                .role = .listitem,
                .label = options.title,
                .focusable = options.on_press != null,
            };
            const row_children = self.arena.alloc(Node, 3) catch {
                self.failed = true;
                return self.el(.stack, .{}, .{});
            };
            row_children[0] = lead;
            row_children[1] = content;
            var row_len: usize = 2;
            if (options.on_press != null) {
                row_children[row_len] = self.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "›");
                row_len += 1;
            }
            const row_node = self.el(.row, .{ .gap = 10, .padding = 8 }, .{row_children[0..row_len]});

            // The press binds to the item's root: a bound handler makes
            // the stack a hit target, and presses on the plain
            // title/description/meta text fall through to it (dragging
            // still selects the text). No overlay, no duplicated
            // handlers.
            return self.el(.stack, .{
                .key = options.key,
                .global_key = options.global_key,
                .selected = options.selected,
                .semantics = item_semantics,
                .on_press = options.on_press,
            }, .{row_node});
        }

        pub const NavOptions = struct {
            /// Index of the visible page; out-of-range clamps to the last
            /// page. The app model owns this value (push = increment or
            /// append, pop = decrement) — TEA, no hidden navigation state.
            active: usize = 0,
            /// Keep inactive pages mounted but hidden: they stay laid out
            /// and keep engine-owned state (scroll offsets, text edits)
            /// across swaps, while being excluded from rendering,
            /// hit-testing, focus traversal, and semantics. Off (default)
            /// mounts only the active page — cheapest, but engine-owned
            /// state of unmounted pages is dropped and the app model must
            /// re-derive anything it wants restored.
            retain: bool = false,
            key: ?UiKey = null,
            global_key: ?UiKey = null,
            grow: f32 = 0,
            /// Layout floor for the nav's box, mirroring
            /// `ElementOptions.min_width`. Split panes clamp against their
            /// pane ROOT's `min_size`, and a chat/detail pane commonly
            /// roots in `ui.nav` — this lets the pane declare its own
            /// floor instead of the app stamping
            /// `widget.layout.min_size.width` post-build.
            min_width: f32 = 0,
            /// Container semantics; role defaults to `group`.
            semantics: canvas.WidgetSemantics = .{},
        };

        /// Within-pane navigation stack: shows one of `pages` (index-keyed
        /// by stack position, so page identity — and with it scroll/text
        /// state reconciliation — is stable across swaps). v1 swaps
        /// instantly; there is no built-in push/pop animation. Focus does
        /// not transfer automatically: move it from `update` when changing
        /// pages if the focused widget lives on the outgoing page (hidden
        /// and unmounted pages drop out of focus traversal on their own).
        pub fn nav(self: *Self, options: NavOptions, pages: anytype) Node {
            var semantics = options.semantics;
            if (semantics.role == .none) semantics.role = .group;
            const page_nodes = self.childNodes(pages);
            if (page_nodes.len == 0) {
                return self.el(.stack, .{
                    .key = options.key,
                    .global_key = options.global_key,
                    .grow = options.grow,
                    .min_width = options.min_width,
                    .semantics = semantics,
                }, .{});
            }
            const active = @min(options.active, page_nodes.len - 1);
            const mounted_len = if (options.retain) page_nodes.len else 1;
            const mounted = self.arena.alloc(Node, mounted_len) catch {
                self.failed = true;
                return self.el(.stack, .{ .semantics = semantics }, .{});
            };
            for (mounted, 0..) |*slot, offset| {
                const index = if (options.retain) offset else active;
                slot.* = page_nodes[index];
                // Page identity is its stack position unless the author
                // keyed it: distinct pages must never share a structural id
                // or engine state would bleed between them.
                if (slot.key == null) slot.key = .{ .int = @intCast(index) };
                if (index != active) slot.widget.semantics.hidden = true;
            }
            return self.el(.stack, .{
                .key = options.key,
                .global_key = options.global_key,
                .grow = options.grow,
                .min_width = options.min_width,
                .semantics = semantics,
            }, .{mounted[0..mounted_len]});
        }

        /// Keyed list projection: one node per item, keyed by `key_fn` unless
        /// the item view assigned its own key.
        pub fn each(self: *Self, items: anytype, comptime key_fn: anytype, comptime view_fn: anytype) []const Node {
            const nodes = self.arena.alloc(Node, items.len) catch {
                self.failed = true;
                return &.{};
            };
            for (items, 0..) |*item, index| {
                var node = view_fn(self, item);
                if (node.key == null) node.key = key_fn(item);
                nodes[index] = node;
            }
            return nodes;
        }

        /// Keyed list projection with caller context, for item views that
        /// need surrounding state (Zig has no closures to capture it).
        pub fn eachCtx(self: *Self, context: anytype, items: anytype, comptime key_fn: anytype, comptime view_fn: anytype) []const Node {
            const nodes = self.arena.alloc(Node, items.len) catch {
                self.failed = true;
                return &.{};
            };
            for (items, 0..) |*item, index| {
                var node = view_fn(self, context, item);
                if (node.key == null) node.key = key_fn(item);
                nodes[index] = node;
            }
            return nodes;
        }

        /// Arena-allocated formatted text for widget content.
        pub fn fmt(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(self.arena, format, args) catch {
                self.failed = true;
                return "";
            };
        }

        /// Assign structural ids, materialize widget children, and collect
        /// the typed handler table. Container sizing is measured by the
        /// engine's `intrinsicWidgetSize` at layout time. Style token
        /// references resolve against the default tokens; themed apps use
        /// `finalizeWithTokens`.
        pub fn finalize(self: *Self, node: Node) error{OutOfMemory}!Tree {
            return self.finalizeWithTokens(node, .{});
        }

        /// `finalize` against live design tokens: node `style_tokens`
        /// references (markup `background="surface"`, `radius="md"`, ...)
        /// resolve into concrete `widget.style` values here, unless the
        /// author already set the style field explicitly. `UiApp` calls
        /// this with `effectiveTokens()` on every rebuild, so token refs
        /// re-resolve when the theme changes.
        pub fn finalizeWithTokens(self: *Self, node: Node, tokens: canvas.DesignTokens) error{OutOfMemory}!Tree {
            if (self.failed) return error.OutOfMemory;
            const handler_capacity = countHandlers(node);
            const handlers = try self.arena.alloc(Handler, handler_capacity);
            var handler_len: usize = 0;
            const root_key = node.key orelse UiKey{ .index = 0 };
            var key_trail = ui_provenance.KeyTrail{};
            const root = try self.finalizeNode(node, root_id_seed, root_key, handlers, &handler_len, &tokens, &key_trail);
            return .{
                .root = root,
                .handlers = handlers[0..handler_len],
                .context_menu_fallback = self.context_menu_fallback_result,
            };
        }

        fn finalizeNode(
            self: *Self,
            node: Node,
            parent_id: ObjectId,
            key: UiKey,
            handlers: []Handler,
            handler_len: *usize,
            tokens: *const canvas.DesignTokens,
            key_trail: *ui_provenance.KeyTrail,
        ) error{OutOfMemory}!Widget {
            var widget = node.widget;
            warnUncoveredText(widget.kind, widget.text);
            warnUncoveredText(widget.kind, widget.placeholder);
            warnInertWrap(widget.kind, node.wrap);
            warnTextSizeKind(widget.kind, widget.size);
            applyStyleTokens(&widget.style, node.style_tokens, tokens);
            // Opt-in text wrapping reuses the span paragraph machinery: a
            // wrapped text leaf becomes a single-span paragraph over its
            // own bytes (the span invariant: span text subslices
            // `widget.text`), so wrapping, intrinsic sizing, wrapped
            // height reservation, and rendering are all the existing span
            // path — no forked text pipeline.
            if (node.wrap == true and widget.kind == .text and widget.spans.len == 0 and widget.text.len > 0) {
                const spans = try self.arena.alloc(canvas.TextSpan, 1);
                spans[0] = .{ .text = widget.text };
                widget.spans = spans;
            }
            // An explicit `wrap = false` records the author's single-line
            // choice. Plain leaves paint one line (TextWrap.none) either
            // way, matching the single-line measurement both layout paths
            // already perform; overflow policy (`overflow`, trailing
            // ellipsis by default) decides what happens past the frame.
            // Span paragraphs keep wrapping.
            if (node.wrap == false and widget.kind == .text and widget.spans.len == 0) {
                widget.text_no_wrap = true;
            }
            widget.id = if (node.global_key) |global_key|
                structuralId(global_id_seed, widget.kind, global_key)
            else
                structuralId(parent_id, widget.kind, key);
            // Provenance record (write-back's read half): this is the one
            // point where the markup-stamped source and the just-assigned
            // structural id are both in hand. Explicit keys (loop item
            // identity, author key=/global-key=) join the trail so the
            // record says WHICH iteration of a for-body this widget is;
            // auto index keys carry position, not identity, and stay out.
            const trail_pushed = if (self.provenance_sink != null and (node.global_key != null or node.key != null))
                key_trail.push(provenanceKey(node.global_key orelse key))
            else
                false;
            defer if (trail_pushed) key_trail.pop();
            if (self.provenance_sink) |sink| {
                if (node.source) |source| {
                    sink.record(widget.id, source, key_trail.items(), key_trail.truncated);
                }
            }
            // Typed handlers imply the matching accessibility actions, the
            // same way a stringly `command` does for engine-owned dispatch.
            if (node.on_press != null) widget.semantics.actions.press = true;
            // A double-press handler makes the element pressable too:
            // the double-click's first release must land somewhere, and
            // an element that acts on double click without claiming
            // presses would be unreachable by pointer at all.
            if (node.on_double_press != null) widget.semantics.actions.press = true;
            if (node.on_toggle != null) widget.semantics.actions.toggle = true;
            // A hold handler makes the element pressable (hit target +
            // press claimer), like on_press: the hold gesture starts as a
            // press, and the classic list-row shape (press to open, hold
            // for the menu) pairs the two on one element.
            if (node.on_hold != null) widget.semantics.actions.press = true;
            if (node.on_input != null) widget.semantics.actions.set_text = true;
            if (widget.kind == .slider and (node.on_value != null or node.on_change != null)) {
                widget.semantics.actions.increment = true;
                widget.semantics.actions.decrement = true;
            }
            if (widget.kind == .split and node.nodes.len == 2) {
                // Synthesize the draggable divider between the two panes.
                // Both markup engines build through this finalize, so the
                // handle exists everywhere a split does. Pane keys keep
                // their author-facing indices (0 and 1) so their
                // structural ids never depend on the synthesized child;
                // panes clip their content so the drag's optimistic echo
                // (and a pane narrower than its content) never paints
                // into the neighbor.
                const child_widgets = try self.arena.alloc(Widget, 3);
                child_widgets[0] = try self.finalizeNode(node.nodes[0], widget.id, node.nodes[0].key orelse UiKey{ .index = 0 }, handlers, handler_len, tokens, key_trail);
                child_widgets[1] = splitDividerWidget(widget);
                child_widgets[2] = try self.finalizeNode(node.nodes[1], widget.id, node.nodes[1].key orelse UiKey{ .index = 1 }, handlers, handler_len, tokens, key_trail);
                child_widgets[0].layout.clip_content = true;
                child_widgets[2].layout.clip_content = true;
                widget.children = child_widgets;
            } else if (node.nodes.len > 0) {
                const child_widgets = try self.arena.alloc(Widget, node.nodes.len);
                for (node.nodes, 0..) |child, index| {
                    const child_key = child.key orelse UiKey{ .index = index };
                    child_widgets[index] = try self.finalizeNode(child, widget.id, child_key, handlers, handler_len, tokens, key_trail);
                }
                widget.children = child_widgets;
            }
            appendHandler(handlers, handler_len, widget.id, .press, node.on_press);
            appendHandler(handlers, handler_len, widget.id, .double_press, node.on_double_press);
            appendHandler(handlers, handler_len, widget.id, .toggle, node.on_toggle);
            appendHandler(handlers, handler_len, widget.id, .change, node.on_change);
            appendHandler(handlers, handler_len, widget.id, .submit, node.on_submit);
            appendHandler(handlers, handler_len, widget.id, .dismiss, node.on_dismiss);
            appendHandler(handlers, handler_len, widget.id, .hold, node.on_hold);
            appendHandler(handlers, handler_len, widget.id, .reach_end, node.on_reach_end);
            appendHandler(handlers, handler_len, widget.id, .reach_start, node.on_reach_start);
            if (node.on_input) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .input, .action = .{ .input = make } };
                handler_len.* += 1;
            }
            if (node.on_value) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .change, .action = .{ .value = make } };
                handler_len.* += 1;
            }
            if (node.on_resize) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .resize, .action = .{ .value = make } };
                handler_len.* += 1;
            }
            if (node.on_scroll) |make| {
                handlers[handler_len.*] = .{ .id = widget.id, .event = .scroll, .action = .{ .scroll = make } };
                handler_len.* += 1;
            }
            if (node.context_menu.len > 0) {
                // Split the declared items: labels ride the widget (the
                // runtime builds the platform request from them), messages
                // land in the handler table keyed by item index.
                const items = try self.arena.alloc(canvas.WidgetContextMenuItem, node.context_menu.len);
                const msgs = try self.arena.alloc(?Msg, node.context_menu.len);
                for (node.context_menu, 0..) |item, index| {
                    items[index] = .{
                        .label = item.label,
                        .enabled = item.enabled,
                        .separator = item.separator,
                    };
                    msgs[index] = item.msg;
                }
                widget.context_menu = items;
                handlers[handler_len.*] = .{ .id = widget.id, .event = .context_menu, .action = .{ .context_menu = msgs } };
                handler_len.* += 1;
                // The presentation fallback: on a host without a native
                // menu presenter the app loop names the widget whose
                // declared menu is open, and finalize mounts that menu as
                // an anchored canvas surface — the same items, presented
                // with the anchored-surface machinery (Escape/outside
                // dismissal, late z-pass) instead of the OS menu.
                if (widget.id == self.context_menu_fallback_target) {
                    try self.appendContextMenuFallbackSurface(&widget, node.context_menu);
                }
            }
            return widget;
        }

        /// Synthesize the anchored context-menu fallback surface as a
        /// child of `widget`: a `dropdown_menu` floating below the target
        /// with one `menu_item` per declared item (`separator`s keep
        /// their slots). Items carry press semantics but no handler
        /// entries — the app loop maps their presses through the
        /// target's existing `.context_menu` handler, the same entry a
        /// native selection resolves.
        fn appendContextMenuFallbackSurface(self: *Self, widget: *Widget, declared: []const ContextMenuItem) error{OutOfMemory}!void {
            if (declared.len == 0) return;
            const surface_id = structuralId(widget.id, .dropdown_menu, UiKey{ .str = "context-menu" });
            const item_widgets = try self.arena.alloc(Widget, declared.len);
            const item_ids = try self.arena.alloc(ObjectId, declared.len);
            for (declared, 0..) |item, index| {
                if (item.separator) {
                    item_widgets[index] = .{
                        .kind = .separator,
                        .id = structuralId(surface_id, .separator, UiKey{ .int = @intCast(index) }),
                    };
                    item_ids[index] = 0;
                    continue;
                }
                var item_widget = Widget{
                    .kind = .menu_item,
                    .id = structuralId(surface_id, .menu_item, UiKey{ .int = @intCast(index) }),
                    .text = item.label,
                    .state = .{ .disabled = !item.enabled },
                };
                item_widget.semantics.actions.press = item.enabled;
                item_widgets[index] = item_widget;
                item_ids[index] = item_widget.id;
            }
            var surface = Widget{
                .kind = .dropdown_menu,
                .id = surface_id,
                .semantics = .{ .label = "Context menu" },
                .children = item_widgets,
            };
            surface.layout.anchor = .{ .placement = .below, .alignment = .start };
            const children = try self.arena.alloc(Widget, widget.children.len + 1);
            @memcpy(children[0..widget.children.len], widget.children);
            children[widget.children.len] = surface;
            widget.children = children;
            self.context_menu_fallback_result = .{
                .target_id = widget.id,
                .surface_id = surface_id,
                .item_ids = item_ids,
            };
        }

        fn appendHandler(handlers: []Handler, handler_len: *usize, id: ObjectId, event: UiHandlerEvent, msg: ?Msg) void {
            const value = msg orelse return;
            handlers[handler_len.*] = .{ .id = id, .event = event, .action = .{ .message = value } };
            handler_len.* += 1;
        }

        fn countHandlers(node: Node) usize {
            var total: usize = 0;
            if (node.on_press != null) total += 1;
            if (node.on_double_press != null) total += 1;
            if (node.on_toggle != null) total += 1;
            if (node.on_change != null) total += 1;
            if (node.on_submit != null) total += 1;
            if (node.on_dismiss != null) total += 1;
            if (node.on_hold != null) total += 1;
            if (node.on_reach_end != null) total += 1;
            if (node.on_reach_start != null) total += 1;
            if (node.on_input != null) total += 1;
            if (node.on_value != null) total += 1;
            if (node.on_resize != null) total += 1;
            if (node.on_scroll != null) total += 1;
            if (node.context_menu.len > 0) total += 1;
            for (node.nodes) |child| total += countHandlers(child);
            return total;
        }

        fn childNodes(self: *Self, children: anytype) []const Node {
            const Children = @TypeOf(children);
            if (Children == Node) {
                const nodes = self.arena.alloc(Node, 1) catch {
                    self.failed = true;
                    return &.{};
                };
                nodes[0] = children;
                return nodes;
            }
            if (Children == []const Node or Children == []Node) {
                // Copy rather than alias: callers may pass slices of locals
                // that would not outlive finalize.
                if (children.len == 0) return &.{};
                const nodes = self.arena.alloc(Node, children.len) catch {
                    self.failed = true;
                    return &.{};
                };
                @memcpy(nodes, children);
                return nodes;
            }
            const info = @typeInfo(Children);
            if (info != .@"struct" or !info.@"struct".is_tuple) {
                @compileError("children must be a Node, a []const Node, or a tuple of those");
            }
            var total: usize = 0;
            inline for (children) |child| {
                total += if (@TypeOf(child) == Node) 1 else child.len;
            }
            if (total == 0) return &.{};
            const nodes = self.arena.alloc(Node, total) catch {
                self.failed = true;
                return &.{};
            };
            var index: usize = 0;
            inline for (children) |child| {
                if (@TypeOf(child) == Node) {
                    nodes[index] = child;
                    index += 1;
                } else {
                    for (child) |entry| {
                        nodes[index] = entry;
                        index += 1;
                    }
                }
            }
            return nodes;
        }

        /// The ergonomic per-kind layout defaults
        /// (`canvas.widgetKindDefaultLayout`): a bare `.card` carries
        /// the house content padding, a bare `.tabs` hugs its triggers
        /// like a TabsList. Only padding/gap (and a non-stretch cross
        /// default) apply, each ONLY when the author left that field at
        /// zero — per field, so an explicit trigger gap keeps the
        /// TabsList hug (dropping it leaves triggers flush against the
        /// container's rounded corners) and explicit padding keeps the
        /// default gap. Explicit spacing always wins for its own field.
        fn applyKindDefaultLayout(kind: WidgetKind, options: ElementOptions, layout: *canvas.WidgetLayoutStyle) void {
            const defaults = canvas.widgetKindDefaultLayout(kind, options.size) orelse return;
            if (options.padding == 0) layout.padding = defaults.padding;
            if (options.gap == 0) layout.gap = defaults.gap;
            if (layout.cross_alignment == .stretch and defaults.cross_alignment != .stretch) {
                layout.cross_alignment = defaults.cross_alignment;
            }
        }

        fn widgetFromOptions(kind: WidgetKind, options: ElementOptions) Widget {
            warnStackContainerGap(kind, options.gap);
            warnUnknownIconName(options.icon);
            var widget: Widget = .{
                .kind = kind,
                .frame = options.frame,
                .opacity = options.opacity,
                .transform = options.transform,
                .text = options.text,
                .placeholder = options.placeholder,
                .icon = options.icon,
                .icon_placement = options.icon_placement,
                .text_alignment = options.text_alignment,
                .text_overflow = options.overflow,
                .autofocus = options.autofocus,
                .image_id = options.image,
                .value = options.value,
                .variant = options.variant,
                .size = options.size,
                .state = .{
                    .selected = options.checked or options.selected,
                    .expanded = options.expanded,
                    .disabled = options.disabled,
                },
                .layout = .{
                    .padding = .{
                        .top = options.padding,
                        .right = options.padding,
                        .bottom = options.padding,
                        .left = options.padding,
                    },
                    .gap = options.gap,
                    .grow = options.grow,
                    .main_alignment = options.main,
                    .cross_alignment = options.cross,
                    .columns = options.columns,
                    .anchor = if (options.anchor) |placement| .{
                        .placement = placement,
                        .alignment = options.anchor_alignment,
                        .offset = options.anchor_offset,
                    } else null,
                    .virtualized = options.virtualized,
                    .virtual_item_extent = options.virtual_item_extent,
                    .virtual_overscan = options.virtual_overscan,
                    .virtual_item_count = options.virtual_item_count,
                    .virtual_first_index = options.virtual_first_index,
                    .virtual_anchor_index = options.virtual_anchor_index,
                    .virtual_anchor_extent = options.virtual_anchor_extent,
                    .virtual_total_extent = options.virtual_total_extent,
                    .min_size = .{ .width = @max(options.width, options.min_width), .height = options.height },
                    // Explicit sizes are definite (min AND max). Resizable
                    // is the exception: width documents the initial width
                    // and the engine's drag handle keeps writing larger
                    // frames past it.
                    .max_size = if (kind == .resizable) .{} else .{ .width = options.width, .height = options.height },
                },
                .style = options.style,
                .semantics = options.semantics,
                .window_drag = options.window_drag,
                .overscroll = options.overscroll,
                .resize_duration_ms = options.resize_duration,
                .resize_easing = options.resize_easing,
                .resize_origin = options.resize_origin,
                .tooltip_delay_ms = options.tooltip_delay,
            };
            applyKindDefaultLayout(kind, options, &widget.layout);
            return widget;
        }

        /// The synthesized drag handle between a split's panes: the ARIA
        /// separator, focusable, mirroring the split's disabled state.
        /// Its `value` is stamped with the EFFECTIVE fraction by the
        /// layout pass; the authored value seeds keyboard steps before
        /// the first layout.
        fn splitDividerWidget(split_widget: Widget) Widget {
            return .{
                .kind = .split_divider,
                .id = structuralId(split_widget.id, .split_divider, UiKey{ .str = "divider" }),
                .value = split_widget.value,
                .state = .{ .disabled = split_widget.state.disabled },
                .semantics = .{ .label = "Split divider" },
            };
        }
    };
}

/// The structural id a widget with `global_key` gets, computable without
/// the parent chain: the seam the app loop uses to resolve a windowed
/// virtual list's retained scroll state by its declared identity.
pub fn globalWidgetId(kind: WidgetKind, key: UiKey) ObjectId {
    return structuralId(global_id_seed, kind, key);
}

pub fn uiKey(value: anytype) UiKey {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .pointer => .{ .str = value },
        else => @compileError("uiKey supports integers and byte slices"),
    };
}

/// Per-item key for the Nth node a multi-child `for` body emits. Slot 0
/// keeps the plain item key, so single-node items (the common case, and
/// every pre-multi-child document) produce byte-identical structural ids.
/// Later slots append a 0x1f-separated slot suffix: the same item key
/// still groups the fragment, while same-kind siblings within one item
/// stay distinct. Both markup engines share this, keeping their ids in
/// parity.
pub fn forSlotKey(arena: std.mem.Allocator, base: UiKey, slot: usize) error{OutOfMemory}!UiKey {
    if (slot == 0) return base;
    return switch (base) {
        .index => |value| .{ .str = try std.fmt.allocPrint(arena, "{d}\x1f{d}", .{ value, slot }) },
        .int => |value| .{ .str = try std.fmt.allocPrint(arena, "{d}\x1f{d}", .{ value, slot }) },
        .str => |value| .{ .str = try std.fmt.allocPrint(arena, "{s}\x1f{d}", .{ value, slot }) },
    };
}

/// `UiKey` in the provenance module's std-only mirror, for sink records.
fn provenanceKey(key: UiKey) ui_provenance.Key {
    return switch (key) {
        .index => |value| .{ .index = value },
        .int => |value| .{ .int = value },
        .str => |value| .{ .str = value },
    };
}

fn findWidgetIn(widget: Widget, id: ObjectId) ?Widget {
    if (widget.id == id) return widget;
    for (widget.children) |child| {
        if (findWidgetIn(child, id)) |found| return found;
    }
    return null;
}

fn isTextEntryWidget(widget: Widget) bool {
    // The one text-entry kind set, shared with the ui-app key-fallback
    // gate (`canvas.isWidgetTextEntry`) — one definition is what makes
    // the "typing must stay typing" rule structural instead of assumed.
    return canvas.isWidgetTextEntry(widget);
}

fn isSubmitKeyboard(widget: Widget, keyboard: canvas.WidgetKeyboardEvent) bool {
    if (widget.state.disabled or keyboard.phase != .key_down) return false;
    if (!std.ascii.eqlIgnoreCase(keyboard.key, "enter")) return false;
    return switch (widget.kind) {
        // Single-line entry: plain Enter submits.
        .text_field, .search_field, .input, .combobox => !keyboard.modifiers.hasNavigationModifier(),
        // Multi-line entry: Enter edits (newline), so submit rides the
        // primary chord — cmd+Enter on macOS, ctrl+Enter elsewhere.
        // Shift/alt variants stay free for apps.
        .textarea => keyboard.modifiers.hasCommandModifier() and !keyboard.modifiers.alt and !keyboard.modifiers.shift,
        // List rows: plain Enter is the row's primary action when the
        // app binds `on_submit` (play the track, open the record); the
        // select activation keeps Space. `msgForKeyboard` resolves the
        // preference — this predicate only says Enter QUALIFIES.
        .list_item => !keyboard.modifiers.hasNavigationModifier(),
        else => false,
    };
}

fn structuralId(parent_id: ObjectId, kind: WidgetKind, key: UiKey) ObjectId {
    var hasher = std.hash.Wyhash.init(parent_id);
    // The kind's STABLE code, never its ordinal: reordering `WidgetKind`
    // must never renumber retained ids, automation targets, or journal
    // anchors. The id algorithm (seed, code, key-tag discipline) is part
    // of the versioned document schema (`ui_schema.schema_version`).
    const kind_code: u16 = canvas.widgetKindCode(kind);
    hasher.update(std.mem.asBytes(&kind_code));
    switch (key) {
        .index => |index| {
            hasher.update(&[_]u8{0});
            hasher.update(std.mem.asBytes(&@as(u64, index)));
        },
        .int => |value| {
            hasher.update(&[_]u8{1});
            hasher.update(std.mem.asBytes(&value));
        },
        .str => |value| {
            hasher.update(&[_]u8{2});
            hasher.update(value);
        },
    }
    const value = hasher.final();
    return if (value == 0) zero_id_fallback else value;
}

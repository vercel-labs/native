//! The UI schema registry: ONE authoritative statement of the markup
//! vocabulary, as data.
//!
//! Every parallel list the markup stack used to keep in lockstep by hand —
//! element names, text-leaf names, option attributes, events, the
//! element-scoped predicate sets (hit-target, stacking, dismissible,
//! anchorable, icon-attr), the rendered-text attribute set, and the
//! token/icon vocabularies — is DERIVED from this one registry at comptime
//! (see the derivation section at the bottom). The validator, both markup
//! engines, the contract checker, the LSP, the CLI's did-you-mean, and the
//! canonical binary encoding all consume it, so a vocabulary fact is
//! stated exactly once.
//!
//! Vocabulary is data; judgment stays code. The registry names WHAT exists
//! (elements, their codes, their attribute/event sets, their structural
//! predicates) and, for the composite elements, WHICH named rule hook owns
//! their bespoke validation — but the rules themselves (markdown's closed
//! attribute set, the stepper's step-children shape, ...) remain ordinary
//! Zig in ui_markup.zig, dispatched by hook name. Forcing them into
//! declarative data would breed a worse inner language.
//!
//! Stable codes: every element, attribute, and event carries a u16 code
//! assigned at birth and NEVER reused or reassigned — codes, not names or
//! declaration order, are what serialized documents and hashes reference,
//! so a rename or reorder here can never silently change what persisted
//! artifacts mean. Code 0 is reserved (it marks "no entry" on the wire).
//! New entries take the next unused code regardless of where they sit in
//! the tables; the registry integrity test pins uniqueness.
//!
//! The engine predicates the structural fields mirror
//! (`canvas.widgetKindHitTarget`, `canvas.widgetKindStacksChildren`,
//! `canvas.widgetKindDismissibleSurface`) stay the source of truth for
//! runtime behavior; registry↔engine conformance tests in
//! ui_markup_view_tests.zig hold this data equal to those predicates over
//! every element, so drift is impossible. This module stays std-only (it
//! rides in the `native` CLI and the LSP standalone), which is why widget
//! kinds are referenced by tag NAME here and resolved to `WidgetKind` by
//! the canvas-layer consumers.

const std = @import("std");

/// The UI document schema version: ONE number covering the document shape,
/// the registry's semantics (codes, classes, predicates), and the
/// evaluation semantics — including the structural-id algorithm — because
/// a change to any one changes what a persisted document MEANS. Additive
/// changes (new elements, attributes, events, expression forms under
/// fresh codes) do not bump it: codes are assigned at birth and readers
/// refuse codes they do not know, loudly. Renames, retypes, removals, or
/// evaluation-semantics changes bump it, and persisted artifacts (NSUI
/// documents, journals, serialized contracts) carry it; readers reach
/// older artifacts through document→document migrations, never silent
/// reinterpretation.
pub const schema_version: u16 = 1;

/// Value type-class of an attribute: what shape of value the engines
/// accept for it. `option` values name a Zig enum member (the enum itself
/// is derived from the `ElementOptions` field type, so it cannot be
/// restated here); `binding_only` attributes require one `{binding}` and
/// never take literals (runtime image ids, markdown sources).
pub const ValueClass = enum {
    text,
    number,
    whole,
    flag,
    option,
    key,
    token_color,
    token_radius,
    icon,
    binding_only,
};

/// Which validation surface an attribute belongs to. `option` attributes
/// are the generic per-element set (the validator's known-option list);
/// the others are scoped or structural and validated by their own rules.
pub const AttrGroup = enum {
    /// Generic option attributes every element may carry (subject to the
    /// element-scoped rules): the engines apply the `field`-named
    /// `ElementOptions` member, or their own special handling when
    /// `field` is empty (key, role, label).
    option,
    /// Color style-token references (`background="surface"`).
    style_color,
    /// The radius style-token reference.
    style_radius,
    /// Element-scoped specials with bespoke rules (icon names, avatar
    /// image bindings, anchor placement).
    element,
    /// Composite-element attributes (markdown, stepper, timeline).
    composite,
    /// Structure-tag attributes (`for each`, `if test`, template wiring)
    /// and tooling hints.
    structure,
};

pub const AttrInfo = struct {
    /// Stable code, assigned at birth, never reused. Nonzero.
    code: u16,
    /// Markup attribute name (kebab-case).
    name: []const u8,
    class: ValueClass,
    group: AttrGroup,
    /// `Ui.ElementOptions` field the generic engines set; empty for
    /// attributes the engines handle specially.
    field: []const u8 = "",
    /// Literal values of this attribute render as label text, so the
    /// font-coverage (tofu) guard applies to them.
    rendered_text: bool = false,
};

/// How an event's payload reaches the Msg: `message` events take a tag
/// with an optional `{binding}` payload; the others require a bare tag
/// whose payload the RUNTIME supplies (TextInputEvent, ScrollState, the
/// split fraction).
pub const EventPayload = enum { message, text_input, scroll_state, fraction };

pub const EventInfo = struct {
    /// Stable code, assigned at birth, never reused. Nonzero.
    code: u16,
    /// Event name; the markup attribute is `on-<name>`.
    name: []const u8,
    payload: EventPayload = .message,
    /// The single element name the runtime emits this event for, when the
    /// event is element-scoped (scroll offsets exist only on scroll
    /// containers, fractions only on splits).
    only_on_element: ?[]const u8 = null,
    /// Only dismissible surfaces (the `dismissible` element predicate)
    /// ever receive this event.
    dismissible_only: bool = false,
    /// This handler binds control/text behavior a non-hit-target element
    /// does not have, so it is a dead handler there (press/toggle are
    /// exempt: a bound press handler makes any element pressable).
    dead_on_non_hit_target: bool = false,
};

/// How the accessible-name lint treats an element. The rubric is whether
/// a screen reader user is FULLY BLOCKED without the name:
/// - `control`: an interactive control announced with no name at all
///   cannot be operated blind — a missing name is an ERROR. Name sources:
///   nonblank text content, a nonblank `text` attribute, or `label`.
/// - `editable`: text-entry controls, plus `select` (which shows its
///   placeholder while empty). The accessibility bridges announce the
///   placeholder as the fallback name, so missing BOTH label and
///   placeholder is the ERROR.
/// - `image`: pictorial content. An unnamed image degrades (announced as
///   an unnamed image) but does not block, so a missing alt-equivalent
///   label is a WARNING; an explicit `label=""` marks it decorative.
/// - `none`: layout, decoration, and content whose name IS its text.
pub const A11yNameRule = enum {
    none,
    control,
    editable,
    image,
};

pub const ElementInfo = struct {
    /// Stable code, assigned at birth, never reused. Nonzero.
    code: u16,
    /// Markup element name (kebab-case).
    name: []const u8,
    /// `canvas.WidgetKind` tag name this element lowers to; empty for
    /// composite elements, which lower through their library views or
    /// builder sugar (markdown, stepper, timeline, chart) or are consumed
    /// by a parent composite (step, timeline-item, series).
    widget_kind: []const u8 = "",
    /// Content is a single run of text (with interpolation); no element
    /// children (unless `takes_children` also holds).
    takes_text: bool = false,
    /// Content may ALSO be element children instead of the text run (the
    /// list-row composite): with children the element is a flow container
    /// inside its own chrome, with a text run it draws that label itself,
    /// and mixing the two is a teaching error. Only meaningful alongside
    /// `takes_text`.
    takes_children: bool = false,
    /// The engine hit-tests this element's widget kind. Mirrors
    /// `canvas.widgetKindHitTarget` (conformance-tested).
    hit_target: bool = true,
    /// The widget kind layers children on top of each other (gap can
    /// never space them). Mirrors `canvas.widgetKindStacksChildren`
    /// (conformance-tested).
    stacks_children: bool = false,
    /// The runtime's dismissal machinery (Escape, click outside,
    /// automation dismiss) closes this surface. Mirrors the markup subset
    /// of `canvas.widgetKindDismissibleSurface`.
    dismissible: bool = false,
    /// May float as an anchored surface (`anchor="below"`).
    anchorable: bool = false,
    /// Its `icon` attribute draws an inline vector icon as part of the
    /// element's own rendering (one hit target, one tint).
    icon_attr: bool = false,
    /// What the accessible-name lint requires of this element (see
    /// `A11yNameRule` for the error/warning rubric). Conformance-tested
    /// against the canvas layer's control predicates so an element the
    /// engine treats as an operable control can never skip the lint.
    a11y_name: A11yNameRule = .none,
    /// Named bespoke validation rule for composite elements. The rule's
    /// existence and attachment are registry data; the rule itself stays
    /// code in ui_markup.zig, dispatched by this name.
    rule_hook: ?[]const u8 = null,
};

// --------------------------------------------------------------- elements
//
// Codes 1..53 are the plain elements (assigned at birth in the vocabulary's
// documented grouping); 54 onward are the composites. The grouping comments
// mirror the authoring docs; they carry no meaning — codes do.

pub const elements = [_]ElementInfo{
    // Flex, overlay, and scrolling containers.
    .{ .code = 1, .name = "row", .widget_kind = "row", .hit_target = false },
    .{ .code = 2, .name = "column", .widget_kind = "column", .hit_target = false },
    .{ .code = 3, .name = "stack", .widget_kind = "stack", .hit_target = false, .stacks_children = true },
    .{ .code = 4, .name = "panel", .widget_kind = "panel", .stacks_children = true },
    .{ .code = 5, .name = "scroll", .widget_kind = "scroll_view" },
    .{ .code = 6, .name = "list", .widget_kind = "list", .hit_target = false },
    .{ .code = 7, .name = "grid", .widget_kind = "grid", .hit_target = false },
    .{ .code = 8, .name = "card", .widget_kind = "card", .stacks_children = true },
    .{ .code = 9, .name = "split", .widget_kind = "split", .hit_target = false },
    .{ .code = 10, .name = "tree", .widget_kind = "tree", .hit_target = false },
    // Row containers (children flow along the horizontal main axis).
    .{ .code = 11, .name = "breadcrumb", .widget_kind = "breadcrumb", .hit_target = false },
    .{ .code = 12, .name = "button-group", .widget_kind = "button_group", .hit_target = false },
    .{ .code = 13, .name = "pagination", .widget_kind = "pagination", .hit_target = false },
    .{ .code = 14, .name = "radio-group", .widget_kind = "radio_group", .hit_target = false },
    .{ .code = 15, .name = "tabs", .widget_kind = "tabs", .hit_target = false },
    .{ .code = 16, .name = "toggle-group", .widget_kind = "toggle_group", .hit_target = false },
    // Vertical containers.
    .{ .code = 17, .name = "table", .widget_kind = "table", .hit_target = false },
    .{ .code = 18, .name = "table-row", .widget_kind = "data_row", .hit_target = false },
    .{ .code = 19, .name = "dropdown-menu", .widget_kind = "dropdown_menu", .dismissible = true, .anchorable = true },
    // Overlay/surface containers (title via the text attribute).
    .{ .code = 20, .name = "accordion", .widget_kind = "accordion" },
    .{ .code = 21, .name = "alert", .widget_kind = "alert", .stacks_children = true },
    .{ .code = 22, .name = "bubble", .widget_kind = "bubble", .stacks_children = true },
    .{ .code = 23, .name = "dialog", .widget_kind = "dialog", .stacks_children = true, .dismissible = true },
    .{ .code = 24, .name = "drawer", .widget_kind = "drawer", .stacks_children = true, .dismissible = true },
    .{ .code = 25, .name = "sheet", .widget_kind = "sheet", .stacks_children = true, .dismissible = true },
    .{ .code = 26, .name = "resizable", .widget_kind = "resizable", .stacks_children = true },
    // Text-bearing leaves (label is the element content).
    .{ .code = 27, .name = "text", .widget_kind = "text", .takes_text = true },
    .{ .code = 28, .name = "badge", .widget_kind = "badge", .takes_text = true, .hit_target = false, .icon_attr = true },
    .{ .code = 29, .name = "button", .widget_kind = "button", .takes_text = true, .icon_attr = true, .a11y_name = .control },
    .{ .code = 30, .name = "toggle", .widget_kind = "toggle", .takes_text = true, .a11y_name = .control },
    .{ .code = 31, .name = "list-item", .widget_kind = "list_item", .takes_text = true, .takes_children = true, .icon_attr = true, .a11y_name = .control },
    .{ .code = 32, .name = "menu-item", .widget_kind = "menu_item", .takes_text = true, .icon_attr = true, .a11y_name = .control },
    .{ .code = 33, .name = "status-bar", .widget_kind = "status_bar", .takes_text = true },
    .{ .code = 34, .name = "avatar", .widget_kind = "avatar", .takes_text = true, .hit_target = false, .a11y_name = .image },
    .{ .code = 35, .name = "select", .widget_kind = "select", .takes_text = true, .a11y_name = .editable },
    .{ .code = 36, .name = "switch", .widget_kind = "switch_control", .takes_text = true, .a11y_name = .control },
    .{ .code = 37, .name = "table-cell", .widget_kind = "data_cell", .takes_text = true },
    .{ .code = 38, .name = "toggle-button", .widget_kind = "toggle_button", .takes_text = true, .icon_attr = true, .a11y_name = .control },
    // Tooltip is anchorable: `anchor="above|below"` floats it against
    // its PARENT's frame (the trigger, or the stack wrapping trigger +
    // tooltip), and the RUNTIME owns its visibility — hidden until the
    // hover-intent delay on the trigger fires (see `tooltip-delay`).
    // Without `anchor` it stays the classic static text leaf that
    // paints whenever the view renders it.
    .{ .code = 39, .name = "tooltip", .widget_kind = "tooltip", .takes_text = true, .hit_target = false, .anchorable = true },
    // Value controls and text entry.
    .{ .code = 40, .name = "checkbox", .widget_kind = "checkbox", .a11y_name = .control },
    .{ .code = 41, .name = "radio", .widget_kind = "radio", .a11y_name = .control },
    .{ .code = 42, .name = "slider", .widget_kind = "slider", .a11y_name = .control },
    .{ .code = 43, .name = "progress", .widget_kind = "progress" },
    .{ .code = 44, .name = "text-field", .widget_kind = "text_field", .a11y_name = .editable },
    .{ .code = 45, .name = "search-field", .widget_kind = "search_field", .a11y_name = .editable },
    .{ .code = 46, .name = "textarea", .widget_kind = "textarea", .a11y_name = .editable },
    .{ .code = 47, .name = "input", .widget_kind = "input", .a11y_name = .editable },
    .{ .code = 48, .name = "combobox", .widget_kind = "combobox", .a11y_name = .editable },
    // Plain leaves.
    .{ .code = 49, .name = "separator", .widget_kind = "separator", .hit_target = false },
    .{ .code = 50, .name = "spacer", .widget_kind = "stack", .hit_target = false, .stacks_children = true },
    .{ .code = 51, .name = "skeleton", .widget_kind = "skeleton", .hit_target = false },
    .{ .code = 52, .name = "spinner", .widget_kind = "spinner", .hit_target = false },
    .{ .code = 53, .name = "icon", .widget_kind = "icon", .hit_target = false },
    // Composite elements: bespoke shapes validated by named rule hooks
    // (the hooks live in ui_markup.zig) and built by bespoke builders in
    // both engines. They lower through library views, not a single
    // widget kind.
    .{ .code = 54, .name = "markdown", .rule_hook = "markdown" },
    .{ .code = 55, .name = "stepper", .rule_hook = "stepper" },
    .{ .code = 56, .name = "step", .rule_hook = "step" },
    .{ .code = 57, .name = "timeline", .rule_hook = "timeline" },
    .{ .code = 58, .name = "timeline-item", .rule_hook = "timeline-item" },
    .{ .code = 59, .name = "chart", .rule_hook = "chart" },
    .{ .code = 60, .name = "series", .rule_hook = "series" },
    // Consumed by its parent element: lowers to the parent's declared
    // context-menu items (the platform-menu channel), never to a widget
    // of its own.
    .{ .code = 61, .name = "context-menu", .rule_hook = "context-menu" },
    // The composer-grade grouped input: one bordered field wrapping a
    // textarea plus an optional accessory row (input-group-actions) —
    // the group wears the focus ring, the inner textarea's chrome
    // dissolves. Lowers through `Ui.inputGroup` to the `input_group`
    // widget kind; the actions row is consumed by its parent and lowers
    // to a plain row inside the group's border.
    .{ .code = 62, .name = "input-group", .rule_hook = "input-group" },
    .{ .code = 63, .name = "input-group-actions", .rule_hook = "input-group-actions" },
    // Inline styled run inside a <text> paragraph: consumed by its parent
    // text leaf (lowered into the paragraph's flat span list, never to a
    // widget of its own), exactly like step/series/context-menu. Spans
    // carry weight, mono, italic, scale, underline, and the existing
    // foreground token channel; everything else about the paragraph
    // (wrap, alignment, events, identity) stays on the enclosing text
    // element.
    .{ .code = 64, .name = "span", .rule_hook = "span" },
    // Consumed by its parent bubble (like step/series/context-menu are
    // consumed by theirs): the reaction pill — one small muted capsule
    // docked at the bubble's bottom edge, straddling it the way the
    // reference overlaps reactions on a chat message. Its single text
    // run lowers onto the bubble widget's chrome-text channel and its
    // dock side rides the existing `text-alignment` attribute (default
    // end, the reference's trailing dock), so the element mints ONE
    // code and no attribute codes at all.
    .{ .code = 65, .name = "reactions", .rule_hook = "reactions" },
    // The media surface: a leaf compositing a texture PRODUCED OUTSIDE
    // the widget tree (video decoder, camera preview, an external
    // renderer like mpv) into the layout like any widget. Its `surface`
    // attribute binds the model-owned u64 surface id a producer targets
    // (`Runtime.acquireMediaSurfaceProducer`) — the runtime-image-id
    // binding shape, never a markup literal. Display-only like image
    // and chart (presses fall through); pictorial for the a11y lint.
    .{ .code = 66, .name = "media-surface", .widget_kind = "media_surface", .hit_target = false, .a11y_name = .image },
    // The image leaf: draws a RUNTIME-REGISTERED image by its
    // model-owned u64 ImageId — the id `Cmd.imageLoad` /
    // `fx.loadImage` / `fx.registerImageBytes` registered pixels
    // under. Its `image` attribute is the avatar binding shape exactly
    // (attr 38, scope broadened): one {binding}, never a markup
    // literal; 0 draws nothing (the image-leaf convention — an avatar
    // falls back to initials instead). Display-only like media-surface
    // and chart (presses fall through); pictorial for the a11y lint.
    .{ .code = 67, .name = "image", .widget_kind = "image", .hit_target = false, .a11y_name = .image },
};

// ------------------------------------------------------------- attributes
//
// Codes 1..28 are the generic option attributes (the order is also the
// did-you-mean/completion display order), 29..35 the style-token
// references, 36..41 the element-scoped specials, 42..50 the composite
// attributes, 51..57 the structure/tooling attributes, 58..64 the
// chart composite attributes, and 65 onward later additions under fresh
// codes (grouping comments carry no meaning — codes do).

pub const attrs = [_]AttrInfo{
    .{ .code = 1, .name = "text", .class = .text, .group = .option, .field = "text", .rendered_text = true },
    .{ .code = 2, .name = "placeholder", .class = .text, .group = .option, .field = "placeholder", .rendered_text = true },
    .{ .code = 3, .name = "value", .class = .number, .group = .option, .field = "value", .rendered_text = true },
    .{ .code = 4, .name = "checked", .class = .flag, .group = .option, .field = "checked" },
    .{ .code = 5, .name = "selected", .class = .flag, .group = .option, .field = "selected" },
    .{ .code = 6, .name = "disabled", .class = .flag, .group = .option, .field = "disabled" },
    .{ .code = 7, .name = "variant", .class = .option, .group = .option, .field = "variant" },
    .{ .code = 8, .name = "size", .class = .option, .group = .option, .field = "size" },
    .{ .code = 9, .name = "width", .class = .number, .group = .option, .field = "width" },
    .{ .code = 10, .name = "height", .class = .number, .group = .option, .field = "height" },
    .{ .code = 11, .name = "grow", .class = .number, .group = .option, .field = "grow" },
    .{ .code = 12, .name = "gap", .class = .number, .group = .option, .field = "gap" },
    .{ .code = 13, .name = "padding", .class = .number, .group = .option, .field = "padding" },
    .{ .code = 14, .name = "main", .class = .option, .group = .option, .field = "main" },
    .{ .code = 15, .name = "cross", .class = .option, .group = .option, .field = "cross" },
    .{ .code = 16, .name = "wrap", .class = .flag, .group = .option, .field = "wrap" },
    .{ .code = 17, .name = "key", .class = .key, .group = .option },
    .{ .code = 18, .name = "global-key", .class = .key, .group = .option },
    .{ .code = 19, .name = "text-alignment", .class = .option, .group = .option, .field = "text_alignment" },
    .{ .code = 20, .name = "columns", .class = .whole, .group = .option, .field = "columns" },
    .{ .code = 21, .name = "virtualized", .class = .flag, .group = .option, .field = "virtualized" },
    .{ .code = 22, .name = "virtual-item-extent", .class = .number, .group = .option, .field = "virtual_item_extent" },
    .{ .code = 23, .name = "role", .class = .option, .group = .option },
    .{ .code = 24, .name = "label", .class = .text, .group = .option, .rendered_text = true },
    .{ .code = 25, .name = "autofocus", .class = .flag, .group = .option, .field = "autofocus" },
    .{ .code = 26, .name = "min-width", .class = .number, .group = .option, .field = "min_width" },
    .{ .code = 27, .name = "expanded", .class = .flag, .group = .option, .field = "expanded" },
    .{ .code = 28, .name = "window-drag", .class = .flag, .group = .option, .field = "window_drag" },
    // Color style-token references (`StyleTokenRefs` fields) + radius.
    .{ .code = 29, .name = "background", .class = .token_color, .group = .style_color, .field = "background" },
    .{ .code = 30, .name = "foreground", .class = .token_color, .group = .style_color, .field = "foreground" },
    .{ .code = 31, .name = "accent", .class = .token_color, .group = .style_color, .field = "accent" },
    .{ .code = 32, .name = "accent-foreground", .class = .token_color, .group = .style_color, .field = "accent_foreground" },
    .{ .code = 33, .name = "border-color", .class = .token_color, .group = .style_color, .field = "border_color" },
    .{ .code = 34, .name = "focus-ring", .class = .token_color, .group = .style_color, .field = "focus_ring" },
    .{ .code = 35, .name = "radius", .class = .token_radius, .group = .style_radius },
    // Element-scoped specials.
    .{ .code = 36, .name = "name", .class = .icon, .group = .element },
    .{ .code = 37, .name = "icon", .class = .icon, .group = .element },
    // The runtime-image binding (avatar and image; the validator
    // scopes it): one {binding} to the model-owned u64 ImageId the app
    // registered at runtime — ids are model data, never markup
    // literals; 0 is the no-image sentinel.
    .{ .code = 38, .name = "image", .class = .binding_only, .group = .element },
    .{ .code = 39, .name = "anchor", .class = .option, .group = .element },
    .{ .code = 40, .name = "anchor-alignment", .class = .option, .group = .element },
    .{ .code = 41, .name = "anchor-offset", .class = .number, .group = .element },
    // Composite-element attributes.
    .{ .code = 42, .name = "source", .class = .binding_only, .group = .composite },
    .{ .code = 43, .name = "active", .class = .whole, .group = .composite },
    .{ .code = 44, .name = "title", .class = .text, .group = .composite, .rendered_text = true },
    .{ .code = 45, .name = "description", .class = .text, .group = .composite, .rendered_text = true },
    .{ .code = 46, .name = "meta", .class = .text, .group = .composite, .rendered_text = true },
    .{ .code = 47, .name = "indicator", .class = .text, .group = .composite, .rendered_text = true },
    .{ .code = 48, .name = "connector", .class = .flag, .group = .composite },
    .{ .code = 49, .name = "issue-link-base", .class = .text, .group = .composite },
    .{ .code = 50, .name = "details-expanded", .class = .binding_only, .group = .composite },
    // Structure-tag attributes and tooling hints.
    .{ .code = 51, .name = "each", .class = .text, .group = .structure },
    .{ .code = 52, .name = "as", .class = .text, .group = .structure },
    .{ .code = 53, .name = "test", .class = .flag, .group = .structure },
    .{ .code = 54, .name = "template", .class = .text, .group = .structure },
    .{ .code = 55, .name = "args", .class = .text, .group = .structure },
    .{ .code = 56, .name = "src", .class = .text, .group = .structure },
    .{ .code = 57, .name = "kind", .class = .text, .group = .structure },
    // Chart composite attributes (fresh codes, assigned at birth).
    .{ .code = 58, .name = "values", .class = .binding_only, .group = .composite },
    .{ .code = 59, .name = "y-min", .class = .number, .group = .composite },
    .{ .code = 60, .name = "y-max", .class = .number, .group = .composite },
    .{ .code = 61, .name = "grid-lines", .class = .whole, .group = .composite },
    .{ .code = 62, .name = "baseline", .class = .flag, .group = .composite },
    .{ .code = 63, .name = "stroke-width", .class = .number, .group = .composite },
    .{ .code = 64, .name = "color", .class = .token_color, .group = .composite },
    // Scroll-region edge behavior (scroll only; the validator scopes it).
    .{ .code = 65, .name = "overscroll", .class = .option, .group = .option, .field = "overscroll" },
    // 66: icon-placement briefly collided with 65 during development and
    // was re-minted here at birth, before either landed anywhere
    // serialized.
    .{ .code = 66, .name = "icon-placement", .class = .option, .group = .option, .field = "icon_placement" },
    // Single-line text overflow policy (text leaves only; the validator
    // scopes it): ellipsis (the default) or clip. 67: re-minted at birth
    // from a development-time collision on 66, before landing anywhere
    // serialized.
    .{ .code = 67, .name = "overflow", .class = .option, .group = .option, .field = "overflow" },
    // Inline span attributes (the <span> composite; its rule hook owns
    // the closed set). weight names a text-span weight rung (regular,
    // medium — the semibold rung — or bold); mono selects the mono face;
    // italic slants the run. Span color rides the existing foreground
    // token attribute (code 30), so no fresh code is minted for it.
    .{ .code = 68, .name = "weight", .class = .option, .group = .composite },
    .{ .code = 69, .name = "mono", .class = .flag, .group = .composite },
    .{ .code = 70, .name = "italic", .class = .flag, .group = .composite },
    // Split layout-tween declaration (split only; the validator scopes
    // both). resize-duration in whole milliseconds — 0 (and absent) is
    // today's snap, so every existing document keeps its behavior —
    // makes the split's `value` a TARGET the runtime eases the rendered
    // fraction toward, one step per presented frame. resize-easing names
    // a `canvas.Easing` member (linear, standard, emphasized, spring)
    // and is only meaningful with a nonzero duration (easing without a
    // duration is a teaching error, not silence). Reduced-motion
    // appearances snap inside the runtime; documents declare nothing.
    .{ .code = 71, .name = "resize-duration", .class = .whole, .group = .option, .field = "resize_duration" },
    .{ .code = 72, .name = "resize-easing", .class = .option, .group = .option, .field = "resize_easing" },
    // Chart axis/hover attributes (fresh codes, assigned at birth).
    // x-labels binds a model iterable
    // of strings (one category label per sample, the same resolution
    // set series values use), y-labels flags numeric ticks on,
    // hover-details flags the pointer-hover detail card on.
    .{ .code = 73, .name = "x-labels", .class = .binding_only, .group = .composite },
    .{ .code = 74, .name = "y-labels", .class = .flag, .group = .composite },
    .{ .code = 75, .name = "hover-details", .class = .flag, .group = .composite },
    // The later span additions (the <span> composite; its rule hook
    // owns the closed set): scale and underline. scale multiplies the
    // paragraph's base
    // size — the text element's size rung included — so a 1.5 run inside
    // a heading paragraph draws at heading x 1.5; the engine treats only
    // positive finite multipliers as scaling, so markup requires exactly
    // that. underline is the span model's underline decoration (purely
    // visual, like every span channel).
    .{ .code = 76, .name = "scale", .class = .number, .group = .composite },
    .{ .code = 77, .name = "underline", .class = .flag, .group = .composite },
    // Split enter-from fraction (split only, needs resize-duration; the
    // validator scopes both, mirroring resize-easing): a freshly
    // MOUNTED split slides its pane boundary in from this fraction
    // toward its declared value instead of popping there. Negative
    // (absent) declares no origin, so every existing document keeps
    // its mount-never-animates behavior.
    .{ .code = 78, .name = "resize-origin", .class = .number, .group = .option, .field = "resize_origin" },
    // The quiet-surface knob (`WidgetStyle.quiet_hover`) for
    // image-forward content tiles: opts a pressable element out of the
    // HOVER wash only — press/selection fills, the focus ring, cursor
    // intent, and hit testing keep their own channels. Hit-target
    // elements only (the validator scopes it; anywhere else it would be
    // silently inert). No `field`: the engines apply it to
    // `ElementOptions.style`, not a flat option field.
    .{ .code = 79, .name = "quiet-hover", .class = .flag, .group = .option },
    // Hover-intent show delay for ANCHORED tooltips (tooltip only, and
    // only beside `anchor`; the validator scopes both), in whole
    // milliseconds. The runtime shows an anchored tooltip after its
    // trigger has been hovered this long on the recorded frame clock —
    // 0 shows the instant the trigger is hovered. Negative is
    // unreachable from markup; absent keeps the token default
    // (`ControlMetricTokens.tooltip_show_delay_ms`).
    .{ .code = 80, .name = "tooltip-delay", .class = .whole, .group = .option, .field = "tooltip_delay" },
    // The media-surface producer rendezvous (media-surface only; the
    // validator scopes it): one {binding} to the model-owned u64 surface
    // id a producer targets (`Runtime.acquireMediaSurfaceProducer`) —
    // ids are model data in the runtime-image-id spirit, never markup
    // literals; 0 is the unbound sentinel (the surface draws nothing,
    // like an image leaf with id 0), and usable ids stay below the
    // reserved namespace bit (bit 63), which acquire refuses.
    .{ .code = 81, .name = "surface", .class = .binding_only, .group = .element },
};

// ----------------------------------------------------------------- events

pub const events = [_]EventInfo{
    .{ .code = 1, .name = "press" },
    .{ .code = 2, .name = "toggle" },
    .{ .code = 3, .name = "change", .dead_on_non_hit_target = true },
    .{ .code = 4, .name = "submit", .dead_on_non_hit_target = true },
    .{ .code = 5, .name = "input", .payload = .text_input, .dead_on_non_hit_target = true },
    .{ .code = 6, .name = "scroll", .payload = .scroll_state, .only_on_element = "scroll" },
    .{ .code = 7, .name = "dismiss", .dismissible_only = true },
    .{ .code = 8, .name = "hold" },
    .{ .code = 9, .name = "resize", .payload = .fraction, .only_on_element = "split" },
    .{ .code = 10, .name = "reach-end", .only_on_element = "scroll" },
};

// ------------------------------------------------------- token vocabulary
//
// Token and icon sections reference their live sources: the color/radius
// names mirror the `canvas.ColorTokens`/`canvas.RadiusTokens` field sets
// and the icon names mirror the comptime-parsed `canvas.icons` registry
// (this module stays std-only, so the mirrors are data here and lockstep
// tests in ui_markup_view_tests.zig hold them equal to the live structs).

pub const color_token_names = [_][]const u8{
    "background",   "surface",     "surface_subtle",   "surface_pressed",
    "text",         "text_muted",  "border",           "accent",
    "accent_text",  "destructive", "destructive_text", "success",
    "success_text", "warning",     "warning_text",     "info",
    "info_text",    "focus_ring",  "shadow",           "scrim",
    "disabled",
};

pub const radius_token_names = [_][]const u8{ "sm", "md", "lg", "xl" };

/// The `size` attribute's CONTROL-scale values, accepted on every sized
/// element: the control register of `canvas.WidgetSize`, mirrored as data
/// here (this module stays std-only) with a lockstep test in
/// ui_markup_view_tests.zig holding the mirror equal to the live enum.
pub const control_size_value_names = [_][]const u8{ "default", "sm", "lg", "icon" };

/// The `size` attribute's TYPOGRAPHY rungs, accepted on TEXT elements
/// only: named typography-token steps (heading_size, display_size) above
/// the title rung. A different axis from the control scale — the
/// validator and both engines reject them on controls with a teaching
/// error. Same lockstep test as `control_size_value_names`.
pub const text_size_value_names = [_][]const u8{ "heading", "display" };

pub const icon_names = [_][]const u8{
    "alert",       "archive",       "arrow-down",   "arrow-right",      "arrow-up",
    "check",       "check-circle",  "chevron-down", "chevron-left",     "chevron-right",
    "chevron-up",  "circle-dot",    "clock",        "copy",             "download",
    "edit",        "ellipsis",      "external-link", "eye",             "file-text",
    "folder",      "folder-open",   "git-branch",    "git-merge",       "git-pull-request",
    "info",        "menu",          "moon",          "music",           "panel-left",
    "panel-right", "pause",         "play",          "plus",            "refresh-cw",
    "repeat",      "save",          "search",        "send",            "settings",
    "shuffle",     "skip-back",     "skip-forward",  "sun",             "terminal",
    "trash",       "volume",        "wrench",        "x",               "x-circle",
};

/// The semantic role vocabulary the `role` attribute accepts: the field
/// names of `canvas.WidgetRole`, mirrored as data here (this module stays
/// std-only) with a lockstep test in ui_markup_view_tests.zig holding the
/// mirror equal to the live enum.
pub const role_names = [_][]const u8{
    "none",      "group",       "text",     "link",   "image",
    "button",    "textbox",     "tooltip",  "dialog", "menu",
    "menuitem",  "list",        "listitem", "row",    "grid",
    "gridcell",  "tab",         "checkbox", "radio",  "switch_control",
    "slider",    "progressbar", "chart",    "tree",   "treeitem",
    "separator",
};

/// Roles that promise CHILD STRUCTURE to assistive tech (rows, items,
/// cells, dialog content). Stamping one on an element that provably
/// cannot hold element children (see `elementHoldsChildren`) is role
/// misuse the registry can see: the promise can never be kept.
pub const container_role_names = [_][]const u8{
    "tree", "list", "menu", "grid", "row", "dialog",
};

/// Whether markup can put element children inside this element: text
/// leaves hold a single text run and the icon leaf holds nothing (both
/// enforced by the validator), so a container role there is provably
/// misuse. Other leaves (separator, value controls) structurally accept
/// children, so the lint stays quiet about them.
pub fn elementHoldsChildren(entry: *const ElementInfo) bool {
    if (entry.takes_children) return true;
    if (entry.takes_text) return false;
    return !std.mem.eql(u8, entry.name, "icon");
}

// ---------------------------------------------------------------- lookups

pub fn elementByName(name: []const u8) ?*const ElementInfo {
    for (&elements) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn elementByCode(code: u16) ?*const ElementInfo {
    for (&elements) |*entry| {
        if (entry.code == code) return entry;
    }
    return null;
}

pub fn attrByName(name: []const u8) ?*const AttrInfo {
    for (&attrs) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn attrByCode(code: u16) ?*const AttrInfo {
    for (&attrs) |*entry| {
        if (entry.code == code) return entry;
    }
    return null;
}

pub fn eventByName(name: []const u8) ?*const EventInfo {
    for (&events) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn eventByCode(code: u16) ?*const EventInfo {
    for (&events) |*entry| {
        if (entry.code == code) return entry;
    }
    return null;
}

// ------------------------------------------------------------ derivations
//
// The comptime-derived name lists the rest of the stack consumes. Each is
// a plain array (so `&list` coerces to a slice exactly like the hand-kept
// lists these replace), generated by one bounded comptime pass over the
// registry; the quota guard is explicit so a grown registry fails loudly
// at the derivation, never mysteriously downstream.

const derivation_quota = 40_000;

fn ElementPredicate(comptime field: []const u8) fn (ElementInfo) bool {
    return struct {
        fn includes(entry: ElementInfo) bool {
            return @field(entry, field);
        }
    }.includes;
}

fn plainElement(entry: ElementInfo) bool {
    return entry.rule_hook == null;
}

fn nonHitTargetElement(entry: ElementInfo) bool {
    return plainElement(entry) and !entry.hit_target;
}

fn elementNamesWhere(comptime includes: fn (ElementInfo) bool) [countElements(includes)][]const u8 {
    comptime {
        @setEvalBranchQuota(derivation_quota);
        var names: [countElements(includes)][]const u8 = undefined;
        var index: usize = 0;
        for (elements) |entry| {
            if (!includes(entry)) continue;
            names[index] = entry.name;
            index += 1;
        }
        return names;
    }
}

fn countElements(comptime includes: fn (ElementInfo) bool) usize {
    comptime {
        @setEvalBranchQuota(derivation_quota);
        var count: usize = 0;
        for (elements) |entry| {
            if (includes(entry)) count += 1;
        }
        return count;
    }
}

fn attrNamesWhere(comptime includes: fn (AttrInfo) bool) [countAttrs(includes)][]const u8 {
    comptime {
        @setEvalBranchQuota(derivation_quota);
        var names: [countAttrs(includes)][]const u8 = undefined;
        var index: usize = 0;
        for (attrs) |entry| {
            if (!includes(entry)) continue;
            names[index] = entry.name;
            index += 1;
        }
        return names;
    }
}

fn countAttrs(comptime includes: fn (AttrInfo) bool) usize {
    comptime {
        @setEvalBranchQuota(derivation_quota);
        var count: usize = 0;
        for (attrs) |entry| {
            if (includes(entry)) count += 1;
        }
        return count;
    }
}

fn optionAttr(entry: AttrInfo) bool {
    return entry.group == .option;
}

fn styleColorAttr(entry: AttrInfo) bool {
    return entry.group == .style_color;
}

fn renderedTextAttr(entry: AttrInfo) bool {
    return entry.rendered_text;
}

/// Element names the grammar accepts as plain (non-composite) elements —
/// the validator's element vocabulary and the did-you-mean list.
pub const element_names = elementNamesWhere(plainElement);

/// Elements whose content is a single run of text.
pub const text_leaf_element_names = elementNamesWhere(ElementPredicate("takes_text"));

/// Text-taking elements that ALSO accept element children in place of
/// the text run (the list-row composite).
pub const text_or_children_element_names = elementNamesWhere(ElementPredicate("takes_children"));

/// Elements whose widget kind the engine never hit-tests.
pub const non_hit_target_element_names = elementNamesWhere(nonHitTargetElement);

/// Elements whose widget kind layers its children (gap is dead there).
pub const stack_container_element_names = elementNamesWhere(ElementPredicate("stacks_children"));

/// Elements the runtime's dismissal machinery closes.
pub const dismiss_element_names = elementNamesWhere(ElementPredicate("dismissible"));

/// Elements that may float as anchored surfaces.
pub const anchor_element_names = elementNamesWhere(ElementPredicate("anchorable"));

/// Elements whose `icon` attribute draws an inline vector icon.
pub const icon_attr_element_names = elementNamesWhere(ElementPredicate("icon_attr"));

/// The generic option attributes (the validator's known-attribute set).
pub const option_attr_names = attrNamesWhere(optionAttr);

/// The color style-token attributes.
pub const color_style_attr_names = attrNamesWhere(styleColorAttr);

/// Attributes whose literal values render as label text (tofu guard).
pub const rendered_text_attr_names = attrNamesWhere(renderedTextAttr);

/// The events' markup ATTRIBUTE spellings (`on-<name>`), index-aligned
/// with `events` — the serialized form and the engines restore attribute
/// names from these, so the spelling exists exactly once.
pub const event_attr_names = blk: {
    @setEvalBranchQuota(derivation_quota);
    var names: [events.len][]const u8 = undefined;
    for (events, 0..) |entry, index| {
        names[index] = "on-" ++ entry.name;
    }
    break :blk names;
};

/// The event attribute spelling for a registry event code.
pub fn eventAttrNameByCode(code: u16) ?[]const u8 {
    for (&events, 0..) |*entry, index| {
        if (entry.code == code) return event_attr_names[index];
    }
    return null;
}

/// The event vocabulary (markup attributes are `on-<name>`).
pub const event_names = blk: {
    @setEvalBranchQuota(derivation_quota);
    var names: [events.len][]const u8 = undefined;
    for (events, 0..) |entry, index| {
        names[index] = entry.name;
    }
    break :blk names;
};

/// Markup attribute name → engine field-name pairs, for the engines'
/// generic option application and the style-token table. The pair type is
/// declared here so ui_markup_view.zig and the contract stay one import
/// away from the registry (std-only both ways).
pub const NamePair = struct { markup: []const u8, zig: []const u8 };

fn fieldBackedOption(entry: AttrInfo) bool {
    return entry.group == .option and entry.field.len > 0;
}

fn pairsWhere(comptime includes: fn (AttrInfo) bool) [countAttrs(includes)]NamePair {
    comptime {
        @setEvalBranchQuota(derivation_quota);
        var pairs: [countAttrs(includes)]NamePair = undefined;
        var index: usize = 0;
        for (attrs) |entry| {
            if (!includes(entry)) continue;
            pairs[index] = .{ .markup = entry.name, .zig = entry.field };
            index += 1;
        }
        return pairs;
    }
}

/// Generic option attributes backed by an `ElementOptions` field.
pub const option_field_pairs = pairsWhere(fieldBackedOption);

/// Color style attributes → `StyleTokenRefs` fields.
pub const color_style_field_pairs = pairsWhere(styleColorAttr);

// ---------------------------------------------------------- registry law
//
// Integrity invariants a comptime block enforces at build time (cheaper
// and earlier than a test): codes are nonzero and unique per table, and
// names are unique per table. Reuse of a retired code or a copy-pasted
// duplicate cannot compile.

/// Order-independent fingerprint over a table's (code, name) pairs,
/// sorted by code: reordering a table is free (codes carry the meaning),
/// renumbering or renaming an existing entry is not. Stated once here so
/// the stability test (ui_schema_tests.zig) and the `zig build
/// print-pins` step can never disagree about what a fingerprint is.
pub fn tableFingerprint(comptime Entry: type, entries: []const Entry) u64 {
    var codes: [256]u16 = undefined;
    var names: [256][]const u8 = undefined;
    for (entries, 0..) |entry, index| {
        codes[index] = entry.code;
        names[index] = entry.name;
    }
    // Insertion sort by code (tables are small and this is tooling-only).
    for (1..entries.len) |i| {
        var j = i;
        while (j > 0 and codes[j - 1] > codes[j]) : (j -= 1) {
            std.mem.swap(u16, &codes[j - 1], &codes[j]);
            std.mem.swap([]const u8, &names[j - 1], &names[j]);
        }
    }
    var hasher = std.hash.Wyhash.init(0);
    for (codes[0..entries.len], names[0..entries.len]) |code, name| {
        hasher.update(std.mem.asBytes(&code));
        hasher.update(name);
        hasher.update(&.{0});
    }
    return hasher.final();
}

comptime {
    @setEvalBranchQuota(derivation_quota);
    for (elements, 0..) |entry, index| {
        if (entry.code == 0) @compileError("element code 0 is reserved: " ++ entry.name);
        for (elements[0..index]) |earlier| {
            if (earlier.code == entry.code) @compileError("duplicate element code: " ++ entry.name);
            if (std.mem.eql(u8, earlier.name, entry.name)) @compileError("duplicate element name: " ++ entry.name);
        }
    }
    for (attrs, 0..) |entry, index| {
        if (entry.code == 0) @compileError("attr code 0 is reserved: " ++ entry.name);
        for (attrs[0..index]) |earlier| {
            if (earlier.code == entry.code) @compileError("duplicate attr code: " ++ entry.name);
            if (std.mem.eql(u8, earlier.name, entry.name)) @compileError("duplicate attr name: " ++ entry.name);
        }
    }
    for (events, 0..) |entry, index| {
        if (entry.code == 0) @compileError("event code 0 is reserved: " ++ entry.name);
        for (events[0..index]) |earlier| {
            if (earlier.code == entry.code) @compileError("duplicate event code: " ++ entry.name);
            if (std.mem.eql(u8, earlier.name, entry.name)) @compileError("duplicate event name: " ++ entry.name);
        }
    }
}

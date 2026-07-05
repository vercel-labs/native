//! One-line documentation tables for the closed .zml markup grammar,
//! sourced from skill-data/native-ui/SKILL.md (Elements / Attributes /
//! Expressions / Structure tags tables). Standalone on purpose: the
//! markup LSP serves these as hover/completion docs, and the docs-site
//! component-preview generator (tools/docs_component_previews.zig)
//! dumps them into docs/src/lib/component-vocab.json so the published
//! attribute tables can never drift from the strings editors show.

const std = @import("std");

// ---------------------------------------------------------- documentation
// One-line docs sourced from skill-data/native-ui/SKILL.md (Elements /
// Attributes / Expressions / Structure tags tables).

pub const Doc = struct {
    name: []const u8,
    doc: []const u8,
};

pub const element_docs = [_]Doc{
    .{ .name = "row", .doc = "Flex container; children flow along the horizontal main axis." },
    .{ .name = "column", .doc = "Flex container; children flow along the vertical main axis." },
    .{ .name = "stack", .doc = "Overlay container; children stack on top of each other." },
    .{ .name = "panel", .doc = "Overlay container panel; children stack on top of each other." },
    .{ .name = "card", .doc = "Overlay container card; children stack on top of each other." },
    .{ .name = "scroll", .doc = "Scroll view; wrap multiple children in a single column inside it." },
    .{ .name = "list", .doc = "Vertical stack of items; supports virtualized and virtual-item-extent." },
    .{ .name = "grid", .doc = "Cell grid container." },
    .{ .name = "split", .doc = "Two-pane horizontal splitter with a draggable divider between exactly two element children. value binds the model-owned first-pane fraction (0 lays out at 0.5), on-resize dispatches the applied fraction (echo it back into value), min-width on the panes bounds the drag; gap sets the divider band thickness. Nest splits for more panes." },
    .{ .name = "tree", .doc = "Disclosure-tree container (vertical flow): descendant rows carrying role=\"treeitem\" form one roving keyboard focus set — Up/Down walk visible rows (selection follows focus via each row's on-press), Left collapses or moves to the parent row, Right expands or moves to the first child row, Home/End jump to the edges. Expandable rows bind expanded and on-toggle; the model owns both states." },
    .{ .name = "text", .doc = "Text leaf; content supports {} interpolation. Line policy via wrap: wrap=\"true\" word-wraps, wrap=\"false\" clips to one honest line." },
    .{ .name = "badge", .doc = "Text leaf badge; content supports {} interpolation." },
    .{ .name = "button", .doc = "Text-bearing control; the label is the text content. Dispatch with on-press. icon draws a vector icon inline before the label (icon-only when the content is empty; give it a label) — one hit target, one enabled/disabled tint." },
    .{ .name = "checkbox", .doc = "Value control; bind checked, dispatch with on-toggle." },
    .{ .name = "radio", .doc = "Value control; bind checked or selected, dispatch with on-toggle." },
    .{ .name = "toggle", .doc = "Text-bearing toggle control; the label is the text content." },
    .{ .name = "slider", .doc = "Value control; bind value, dispatch with on-change." },
    .{ .name = "progress", .doc = "Value control; bind value." },
    .{ .name = "text-field", .doc = "Text entry; placeholder and text binding, edits via on-input, enter via on-submit." },
    .{ .name = "search-field", .doc = "Text entry styled for search; edits via on-input." },
    .{ .name = "textarea", .doc = "Multi-line text entry; edits via on-input." },
    .{ .name = "list-item", .doc = "Text-bearing item control; the label is the text content." },
    .{ .name = "menu-item", .doc = "Text-bearing menu control; the label is the text content." },
    .{ .name = "status-bar", .doc = "Status bar text leaf: content only, no children." },
    .{ .name = "separator", .doc = "Separator line: a horizontal rule in a column, a thin vertical divider in a row." },
    .{ .name = "spacer", .doc = "Flexible space; give it a grow." },
    .{ .name = "breadcrumb", .doc = "Row container for a breadcrumb trail; children flow horizontally." },
    .{ .name = "button-group", .doc = "Row container grouping buttons; children flow horizontally." },
    .{ .name = "pagination", .doc = "Row container for pagination controls; children flow horizontally." },
    .{ .name = "radio-group", .doc = "Row container grouping radio controls; children flow horizontally." },
    .{ .name = "tabs", .doc = "Row container for a tab strip; children (buttons with selected) flow horizontally." },
    .{ .name = "toggle-group", .doc = "Row container grouping toggle-buttons; children flow horizontally." },
    .{ .name = "table", .doc = "Vertical table container; children are table-row elements." },
    .{ .name = "table-row", .doc = "Horizontal table row; only allowed inside a table, children are table-cells." },
    .{ .name = "table-cell", .doc = "Table cell text leaf; only allowed inside a table-row, dispatch with on-press." },
    .{ .name = "dropdown-menu", .doc = "Vertical menu surface; children are menu-item elements. anchor=\"below|above\" floats it against its parent (put it beside its trigger in a stack): late z-pass above the whole tree, window-clipped, auto-flipping at the edges. Pair with on-dismiss so Escape/click-outside close model-side." },
    .{ .name = "accordion", .doc = "Surface with a header (text attribute); children show when selected, dispatch with on-toggle." },
    .{ .name = "alert", .doc = "Alert surface; title via the text attribute, children stack inside." },
    .{ .name = "bubble", .doc = "Bubble surface (chat message); children stack inside." },
    .{ .name = "dialog", .doc = "Modal dialog surface rendered in place; title via text, wrap in an if to show conditionally." },
    .{ .name = "drawer", .doc = "Drawer surface rendered in place; title via text, wrap in an if to show conditionally." },
    .{ .name = "sheet", .doc = "Sheet surface rendered in place; title via text, wrap in an if to show conditionally." },
    .{ .name = "resizable", .doc = "Resizable panel with an engine-managed drag handle; width sets the initial width." },
    .{ .name = "avatar", .doc = "Avatar leaf; the text content renders as initials, image takes one {binding} to a runtime-registered ImageId (0 keeps the initials)." },
    .{ .name = "select", .doc = "Select trigger only (no options attribute): content is the current value, placeholder while empty, on-press opens. Compose the options as an ANCHORED dropdown-menu of menu-items under an if, beside the trigger in a stack (anchor=\"below\" + on-dismiss; model-owned open state)." },
    .{ .name = "switch", .doc = "Switch control; label is the text content, bind checked, dispatch with on-toggle." },
    .{ .name = "toggle-button", .doc = "Pressed-state toggle button; label is the text content, dispatch with on-toggle." },
    .{ .name = "tooltip", .doc = "Tooltip text leaf; content supports {} interpolation." },
    .{ .name = "input", .doc = "Single-line text entry; text and placeholder bindings, edits via on-input, enter via on-submit." },
    .{ .name = "combobox", .doc = "Text entry with menu affordance (no options attribute); edits via on-input, open via on-press — compose the options like select's anchored dropdown-menu pattern (filter the for-each source from the model as the user types)." },
    .{ .name = "skeleton", .doc = "Loading placeholder block; size with width and height." },
    .{ .name = "spinner", .doc = "Indeterminate progress spinner leaf." },
    .{ .name = "icon", .doc = "Built-in vector icon leaf: name selects one of the curated built-in stroke icons (comptime-validated), tint via foreground, size with width/height or size." },
    .{ .name = "markdown", .doc = "Renders a markdown string (GFM subset, pipe tables included) as widgets; source is one {binding}, links dispatch on-link (bare URLs autolink), <details> blocks toggle via on-details + details-expanded, #123 refs linkify via issue-link-base." },
    .{ .name = "stepper", .doc = "Stage stepper: step children joined by connectors; active names the current step index (earlier steps render completed, later ones pending)." },
    .{ .name = "step", .doc = "One stepper stage; only allowed inside a stepper, the label is the text content (supports {} interpolation), state derives from the stepper's active index." },
    .{ .name = "timeline", .doc = "Ledger/timeline list container; children are timeline-item elements (for/if work). Takes gap, grow, key, global-key, label." },
    .{ .name = "timeline-item", .doc = "One timeline/ledger item: title (required), description, meta, indicator + variant color the leading badge, connector=\"false\" ends the rail; on-press makes the whole item pressable with a trailing chevron." },
};

pub const structure_docs = [_]Doc{
    .{ .name = "for", .doc = "Structure tag: repeats its element children over each (elements, use, if/else, nested for); requires each and as, key names an item field. A directly following else renders when the iterable is empty." },
    .{ .name = "if", .doc = "Structure tag: renders children when test={binding} or {a == b} is true." },
    .{ .name = "else", .doc = "Structure tag: must directly follow an if (renders when the test is false) or a for (renders when the iterable is empty)." },
    .{ .name = "template", .doc = "Top-level template definition (before the view root): name, optional args, exactly one element child." },
    .{ .name = "use", .doc = "Expands a template in place: template names an earlier definition, other attributes must match its args exactly." },
};

pub const attribute_docs = [_]Doc{
    .{ .name = "text", .doc = "Text value for text-bearing elements; a literal or one {binding}." },
    .{ .name = "placeholder", .doc = "Hint text shown while a text entry is empty." },
    .{ .name = "value", .doc = "Value for slider/progress/text entry; a literal or one {binding}." },
    .{ .name = "checked", .doc = "Checked state for checkbox/toggle; true/false or a {binding}." },
    .{ .name = "selected", .doc = "Selected state; often a {a == b} equality." },
    .{ .name = "disabled", .doc = "Disables the control; true/false or a {binding}." },
    .{ .name = "variant", .doc = "Visual variant: default|primary|secondary|outline|ghost|destructive." },
    .{ .name = "size", .doc = "Control size: default|sm|lg|icon." },
    .{ .name = "width", .doc = "Definite width (plain number): the element is exactly this wide; content neither shrinks nor overflows it. On resizable it is the initial width." },
    .{ .name = "height", .doc = "Definite height (plain number): the element is exactly this tall; content neither shrinks nor overflows it." },
    .{ .name = "grow", .doc = "Flex grow factor; give spacer one." },
    .{ .name = "gap", .doc = "Spacing between children (plain number). Rejected on stacking containers (stack, panel, card, the modal surfaces) — they layer children; put a column (or row) inside for flow." },
    .{ .name = "padding", .doc = "Uniform padding (plain number)." },
    .{ .name = "main", .doc = "Main-axis alignment: start|center|end|space_between." },
    .{ .name = "cross", .doc = "Cross-axis alignment: stretch|start|center|end." },
    .{ .name = "wrap", .doc = "text only: true word-wraps the content at the width the element receives (reserving wrapped height in columns); false is honest single-line - one line, clipped to the element's frame, so a width-constrained title never paints over the row below. Unset measures one line but lets paint re-wrap overflow." },
    .{ .name = "text-alignment", .doc = "Horizontal alignment of text content: start|center|end. Consumed by text (plain and wrapped), status-bar, and surface titles; controls that own their label placement (button, badge) ignore it." },
    .{ .name = "columns", .doc = "grid only: fixed column count (plain number or one {binding}); omit for the derived near-square grid." },
    .{ .name = "virtualized", .doc = "Enable list virtualization (true/false)." },
    .{ .name = "virtual-item-extent", .doc = "Fixed item extent for virtualized lists (plain number)." },
    .{ .name = "key", .doc = "Sibling-scoped identity key; on for, names an item field." },
    .{ .name = "global-key", .doc = "Parent-independent identity: ids survive reparenting between containers." },
    .{ .name = "role", .doc = "Accessibility role (listitem, treeitem, button, ...). treeitem also makes the row part of its tree's roving keyboard focus set." },
    .{ .name = "min-width", .doc = "Width floor (plain number) without width's definite max: the element may grow past it but never shrink below. On split panes it bounds the divider drag." },
    .{ .name = "expanded", .doc = "Tree rows (role=\"treeitem\"): disclosure state (true/false or a {binding}). Omit on leaves; expanded rows collapse on Left, collapsed ones expand on Right, both through on-toggle - the model owns the state." },
    .{ .name = "label", .doc = "Accessible name." },
    .{ .name = "autofocus", .doc = "Focusable controls only: moves keyboard focus to the element when it mounts or when the value turns on (edge-triggered - holding it true never re-steals focus). The TEA way to focus an editor on create." },
    .{ .name = "icon", .doc = "button, toggle-button, list-item, menu-item: built-in vector icon drawn inline (buttons/toggle-buttons before the label, list/menu items as a leading slot; literal name, comptime-validated against canvas.icons.known_icon_names, e.g. save, plus, refresh-cw). Icon-only buttons when the content is empty — add a label. One hit target, one enabled/disabled tint." },
    .{ .name = "window-drag", .doc = "Marks the element as a window-drag surface (the hidden-titlebar pattern): pressing its background - or plain text/icons inside - moves the window; double-click zooms per the OS convention. Buttons and other press-claiming children inside stay clickable. macOS-only; elsewhere the press is dead space." },
    .{ .name = "background", .doc = "Background color token (literal ColorTokens field name: background, surface, surface_subtle, ...)." },
    .{ .name = "foreground", .doc = "Foreground/text color token (literal ColorTokens field name, e.g. text, text_muted, success, warning, info)." },
    .{ .name = "accent", .doc = "Accent color token (literal ColorTokens field name, e.g. accent, destructive, success, warning, info)." },
    .{ .name = "accent-foreground", .doc = "Accent foreground color token (literal ColorTokens field name, e.g. accent_text)." },
    .{ .name = "border-color", .doc = "Border color token (literal ColorTokens field name, e.g. border)." },
    .{ .name = "focus-ring", .doc = "Focus ring color token (literal ColorTokens field name, e.g. focus_ring)." },
    .{ .name = "radius", .doc = "Corner radius token (literal RadiusTokens field name: sm, md, lg, xl)." },
};

pub const template_attr_docs = [_]Doc{
    .{ .name = "name", .doc = "template: the definition's name, referenced by use. icon: the built-in vector icon to draw (literal, comptime-validated against canvas.icons.known_icon_names)." },
    .{ .name = "args", .doc = "template: space-separated arg names use sites must pass (slice bindings iterate, scalars bind as values)." },
    .{ .name = "template", .doc = "use: names an earlier top-level template to expand in place." },
};

pub const for_attr_docs = [_]Doc{
    .{ .name = "each", .doc = "for: Model field, pub decl, or model fn producing the slice to iterate." },
    .{ .name = "as", .doc = "for: name of the loop variable bindings use." },
    .{ .name = "key", .doc = "for: item field that keys identity across reorders." },
};

pub const if_attr_docs = [_]Doc{
    .{ .name = "test", .doc = "if: one {binding} or one {a == b} equality." },
};

pub const markdown_attr_docs = [_]Doc{
    .{ .name = "source", .doc = "markdown: one {binding} producing the markdown text (a []const u8 field or fn; arena fns work). Required." },
    .{ .name = "on-link", .doc = "markdown: bare Msg tag dispatched on link press; its payload is the URL ([]const u8 variant)." },
    .{ .name = "on-details", .doc = "markdown: bare Msg tag dispatched on a <details> summary press; its payload is the block index (usize variant)." },
    .{ .name = "details-expanded", .doc = "markdown: {binding} naming a []const bool iterable of expanded flags, in details-block document order." },
    .{ .name = "issue-link-base", .doc = "markdown: literal URL prefix or one {binding}; '#123' refs become links to base ++ number (ghissue:// or https://github.com/owner/repo/issues/)." },
};

pub const stepper_attr_docs = [_]Doc{
    .{ .name = "active", .doc = "stepper: the active step index (a number or one {binding}); earlier steps render completed, later ones pending. Required." },
    .{ .name = "key", .doc = "Sibling-scoped identity key." },
    .{ .name = "global-key", .doc = "Parent-independent identity: ids survive reparenting between containers." },
    .{ .name = "label", .doc = "Accessible name." },
    .{ .name = "autofocus", .doc = "Focusable controls only: moves keyboard focus to the element when it mounts or when the value turns on (edge-triggered - holding it true never re-steals focus). The TEA way to focus an editor on create." },
};

pub const timeline_attr_docs = [_]Doc{
    .{ .name = "gap", .doc = "Spacing between items (plain number)." },
    .{ .name = "grow", .doc = "Flex grow factor." },
    .{ .name = "key", .doc = "Sibling-scoped identity key." },
    .{ .name = "global-key", .doc = "Parent-independent identity: ids survive reparenting between containers." },
    .{ .name = "label", .doc = "Accessible name." },
    .{ .name = "autofocus", .doc = "Focusable controls only: moves keyboard focus to the element when it mounts or when the value turns on (edge-triggered - holding it true never re-steals focus). The TEA way to focus an editor on create." },
};

pub const timeline_item_attr_docs = [_]Doc{
    .{ .name = "title", .doc = "timeline-item: bold first line (a literal or one {binding}). Required." },
    .{ .name = "description", .doc = "timeline-item: wrapped muted preview under the title (a literal or one {binding})." },
    .{ .name = "meta", .doc = "timeline-item: muted trailing meta line, e.g. \"claude · sonnet · 1m 12s\" (a literal or one {binding})." },
    .{ .name = "indicator", .doc = "timeline-item: leading badge text (\"✓\", a number); empty renders a small dot." },
    .{ .name = "variant", .doc = "timeline-item: indicator color variant (default|primary|secondary|outline|ghost|destructive) - map run outcomes here." },
    .{ .name = "connector", .doc = "timeline-item: false ends the connector rail (set on the last item)." },
    .{ .name = "selected", .doc = "timeline-item: selected state (true/false or a {binding})." },
    .{ .name = "on-press", .doc = "timeline-item: Msg dispatched from anywhere on the item (tag or tag:{payload}); adds a trailing chevron." },
    .{ .name = "key", .doc = "Sibling-scoped identity key; on for, names an item field." },
    .{ .name = "global-key", .doc = "Parent-independent identity: ids survive reparenting between containers." },
};

pub const avatar_attr_docs = [_]Doc{
    .{ .name = "image", .doc = "avatar: one {binding} to a u64 ImageId the app registered at runtime (fx.registerImageBytes); 0 renders the initials fallback." },
};

pub const anchor_attr_docs = [_]Doc{
    .{ .name = "anchor", .doc = "dropdown-menu: floats the surface against its PARENT's frame instead of the flow (literal below or above; either side auto-flips at the window edges). Late z-pass above the whole tree, window-clipped — never cropped by a scroll pane, never reflows siblings. Put the dropdown beside its trigger inside a stack." },
    .{ .name = "anchor-alignment", .doc = "dropdown-menu (with anchor): horizontal alignment against the anchor - start, end, or stretch (stretch also widens the surface to at least the anchor's width, the select-menu look)." },
    .{ .name = "anchor-offset", .doc = "dropdown-menu (with anchor): literal gap in points between the anchor edge and the surface (default 4)." },
};

pub const event_docs = [_]Doc{
    .{ .name = "on-press", .doc = "Dispatch a Msg on press: tag or tag:{payload}. Legal on any element — a bound press handler makes it pressable, and presses on plain text/icons inside it fall through to it (dragging still selects text)." },
    .{ .name = "on-toggle", .doc = "Dispatch a Msg on toggle: tag or tag:{payload}. Hit-target elements only (checkbox, toggle, toggle-button, switch, accordion, ...)." },
    .{ .name = "on-change", .doc = "Dispatch a Msg on change: tag or tag:{payload}. Hit-target elements only (slider, ...)." },
    .{ .name = "on-submit", .doc = "Dispatch a Msg on enter in a text field: tag or tag:{payload}." },
    .{ .name = "on-input", .doc = "Names a Msg variant with canvas.TextInputEvent payload; delivers each text edit." },
    .{ .name = "on-scroll", .doc = "scroll element only: names a Msg variant with canvas.ScrollState payload; delivers the post-scroll offset/viewport/content extents after wheel, kinetic, keyboard, and accessibility scrolls." },
    .{ .name = "on-dismiss", .doc = "Dismissible surfaces only (dialog, drawer, sheet, dropdown-menu): Msg dispatched when Escape or a click outside dismisses the surface, so the MODEL owns the close (clear the open flag in update). The engine hides the surface immediately as an optimistic echo; the source tree wins on the next rebuild." },
    .{ .name = "on-hold", .doc = "Press-and-hold Msg: a pointer held ~350 ms dispatches it and the release then presses nothing; a quick click dispatches on-press as usual. A right/ctrl-click with no context menu on the route dispatches it immediately. Like on-press, binding it makes any element pressable." },
    .{ .name = "on-resize", .doc = "split element only: names a Msg variant with f32 payload; delivers the applied first-pane fraction after every divider drag, keyboard adjustment, and assistive increment/decrement. Echo it back into value - the delivered fraction never fights the reconcile." },
    .{ .name = "on-reach-end", .doc = "scroll element only: Msg (tag or tag:{payload}) dispatched when a user scroll comes within one viewport of the content end - the infinite-scroll fetch signal. Fires once per approach with hysteresis: it re-arms only after the offset retreats past 1.5 viewports, which appending a batch causes on its own by growing the extent." },
};

pub fn elementDoc(name: []const u8) ?[]const u8 {
    if (findDoc(&element_docs, name)) |doc| return doc;
    return findDoc(&structure_docs, name);
}

pub fn attributeDoc(name: []const u8) ?[]const u8 {
    if (findDoc(&attribute_docs, name)) |doc| return doc;
    if (findDoc(&event_docs, name)) |doc| return doc;
    if (findDoc(&for_attr_docs, name)) |doc| return doc;
    if (findDoc(&template_attr_docs, name)) |doc| return doc;
    if (findDoc(&markdown_attr_docs, name)) |doc| return doc;
    if (findDoc(&stepper_attr_docs, name)) |doc| return doc;
    if (findDoc(&timeline_attr_docs, name)) |doc| return doc;
    if (findDoc(&timeline_item_attr_docs, name)) |doc| return doc;
    if (findDoc(&avatar_attr_docs, name)) |doc| return doc;
    if (findDoc(&anchor_attr_docs, name)) |doc| return doc;
    return findDoc(&if_attr_docs, name);
}

fn findDoc(list: []const Doc, name: []const u8) ?[]const u8 {
    for (list) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.doc;
    }
    return null;
}

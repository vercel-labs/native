// Shared between the native compiler (runs in Node) and the runtime (compiled by scriptc).
// CSS is parsed at build time into numeric declarations: { p: property, v: value, u: unit }.

// Every property, in id order: the key its P_ constant names, and the CSS name it serializes as.
// A property's id is its position here, so a branch that adds one inserts a line beside its area's
// slots and nothing is renumbered; several slots may share one CSS name (the border-spacing
// halves, a radius's two axes, and the parameter slots the font size needs).
const PROPS: readonly (readonly [string, string])[] = [
  ["display", "display"],
  ["flex-direction", "flex-direction"],
  ["justify-content", "justify-content"],
  ["align-items", "align-items"],
  ["row-gap", "row-gap"],
  ["column-gap", "column-gap"],
  ["flex-grow", "flex-grow"],
  ["flex-shrink", "flex-shrink"],
  ["flex-basis", "flex-basis"],
  ["width", "width"],
  ["height", "height"],
  ["min-width", "min-width"],
  ["max-width", "max-width"],
  ["min-height", "min-height"],
  ["max-height", "max-height"],
  ["margin-top", "margin-top"],
  ["margin-right", "margin-right"],
  ["margin-bottom", "margin-bottom"],
  ["margin-left", "margin-left"],
  ["padding-top", "padding-top"],
  ["padding-right", "padding-right"],
  ["padding-bottom", "padding-bottom"],
  ["padding-left", "padding-left"],
  ["border-top-width", "border-top-width"],
  ["border-right-width", "border-right-width"],
  ["border-bottom-width", "border-bottom-width"],
  ["border-left-width", "border-left-width"],
  ["border-top-color", "border-top-color"],
  ["border-right-color", "border-right-color"],
  ["border-bottom-color", "border-bottom-color"],
  ["border-left-color", "border-left-color"],
  ["border-top-left-radius", "border-top-left-radius"],
  ["background-color", "background-color"],
  ["color", "color"],
  ["font-size", "font-size"],
  ["font-weight", "font-weight"],
  ["line-height", "line-height"],
  ["text-align", "text-align"],
  ["text-justify", "text-justify"],
  ["cursor", "cursor"],
  ["box-sizing", "box-sizing"],
  ["opacity", "opacity"],
  ["align-self", "align-self"],
  ["overflow", "overflow"],
  ["text-decoration", "text-decoration-line"],
  ["font-style", "font-style"],
  ["position", "position"],
  ["top", "top"],
  ["right", "right"],
  ["bottom", "bottom"],
  ["left", "left"],
  ["font-family", "font-family"],
  ["font-family-list", "font-family"],
  ["white-space", "white-space"],
  ["z-index", "z-index"],
  ["flex-wrap", "flex-wrap"],
  ["align-content", "align-content"],
  ["order", "order"],
  ["vertical-align", "vertical-align"],
  ["table-layout", "table-layout"],
  ["border-collapse", "border-collapse"],
  ["border-spacing-h", "border-spacing"],
  ["border-spacing-v", "border-spacing"],
  ["caption-side", "caption-side"],
  ["empty-cells", "empty-cells"],
  ["content", "content"],
  ["background-image", "background-image"],
  ["background-repeat", "background-repeat"],
  ["background-position", "background-position"],
  ["background-size", "background-size"],
  ["background-origin", "background-origin"],
  ["background-clip", "background-clip"],
  ["background-attachment", "background-attachment"],
  ["list-style-type", "list-style-type"],
  ["list-style-position", "list-style-position"],
  ["list-style-image", "list-style-image"],
  ["outline-style", "outline-style"],
  ["outline-width", "outline-width"],
  ["outline-color", "outline-color"],
  ["outline-offset", "outline-offset"],
  ["border-top-style", "border-top-style"],
  ["border-right-style", "border-right-style"],
  ["border-bottom-style", "border-bottom-style"],
  ["border-left-style", "border-left-style"],
  ["border-top-right-radius", "border-top-right-radius"],
  ["border-bottom-right-radius", "border-bottom-right-radius"],
  ["border-bottom-left-radius", "border-bottom-left-radius"],
  ["border-top-left-radius-y", "border-top-left-radius"],
  ["border-top-right-radius-y", "border-top-right-radius"],
  ["border-bottom-right-radius-y", "border-bottom-right-radius"],
  ["border-bottom-left-radius-y", "border-bottom-left-radius"],
  ["float", "float"],
  ["clear", "clear"],
  ["clip", "clip"],
  ["box-shadow", "box-shadow"],
  ["text-transform", "text-transform"],
  ["letter-spacing", "letter-spacing"],
  ["word-spacing", "word-spacing"],
  ["text-indent", "text-indent"],
  ["tab-size", "tab-size"],
  ["text-overflow", "text-overflow"],
  ["overflow-wrap", "overflow-wrap"],
  ["word-break", "word-break"],
  ["text-shadow", "text-shadow"],
  ["transform", "transform"],
  ["transform-origin", "transform-origin"],
  ["translate", "translate"],
  ["rotate", "rotate"],
  ["scale", "scale"],
  ["object-fit", "object-fit"],
  ["object-position", "object-position"],
  ["image-rendering", "image-rendering"],
  ["image-orientation", "image-orientation"],
  ["aspect-ratio", "aspect-ratio"],
  ["aspect-ratio-auto", "aspect-ratio"],
  ["fixed-font", "font-family"],
  ["medium-based", "font-size"],
  ["fill", "fill"],
  ["stroke", "stroke"],
  ["fill-opacity", "fill-opacity"],
  ["stroke-opacity", "stroke-opacity"],
  ["stroke-width", "stroke-width"],
  ["stroke-linecap", "stroke-linecap"],
  ["stroke-linejoin", "stroke-linejoin"],
  ["fill-rule", "fill-rule"],
  ["app-region", "app-region"],
  ["text-decoration-style", "text-decoration-style"],
  ["text-decoration-color", "text-decoration-color"],
  ["text-decoration-thickness", "text-decoration-thickness"],
  ["underline-offset", "text-underline-offset"],
  ["line-clamp", "line-clamp"],
  ["stroke-dasharray", "stroke-dasharray"],
  ["stroke-dashoffset", "stroke-dashoffset"],
  ["font-feature-settings", "font-feature-settings"],
  ["font-variant-caps", "font-variant-caps"],
  ["font-variant-ligatures", "font-variant-ligatures"],
  ["font-variant-numeric", "font-variant-numeric"],
  ["font-variant-east-asian", "font-variant-east-asian"],
  ["font-variant-position", "font-variant-position"],
  ["font-variant-alternates", "font-variant-alternates"],
  ["font-variation-settings", "font-variation-settings"],
  ["font-synthesis", "font-synthesis"],
  ["font-kerning", "font-kerning"],
  ["font-language-override", "font-language-override"],
  ["font-optical-sizing", "font-optical-sizing"],
  ["font-size-adjust", "font-size-adjust"],
  ["font-stretch", "font-stretch"],
  // font-synthesis longhands: one bit each in P_FONT_SYNTHESIS, kept as 1 (auto) or 0 (none).
  ["font-synthesis-weight", "font-synthesis-weight"],
  ["font-synthesis-style", "font-synthesis-style"],
  ["font-synthesis-small-caps", "font-synthesis-small-caps"],
  ["font-variant-emoji", "font-variant-emoji"],
  ["text-underline-position", "text-underline-position"],
  ["text-decoration-skip-ink", "text-decoration-skip-ink"],
  ["white-space-collapse", "white-space-collapse"],
  ["text-box-trim", "text-box-trim"],
  ["text-box-edge", "text-box-edge"],
  ["initial-letter", "initial-letter"],
  ["alignment-baseline", "alignment-baseline"],
  ["baseline-shift", "baseline-shift"],
  ["dominant-baseline", "dominant-baseline"],
  ["font-palette", "font-palette"],
  ["text-emphasis-style", "text-emphasis-style"],
  ["text-emphasis-color", "text-emphasis-color"],
  ["text-emphasis-position", "text-emphasis-position"],
  ["grid-template-columns", "grid-template-columns"],
  ["grid-template-rows", "grid-template-rows"],
  ["grid-auto-columns", "grid-auto-columns"],
  ["grid-auto-rows", "grid-auto-rows"],
  ["grid-auto-flow", "grid-auto-flow"],
  ["grid-column-start", "grid-column-start"],
  ["grid-column-end", "grid-column-end"],
  ["grid-row-start", "grid-row-start"],
  ["grid-row-end", "grid-row-end"],
  ["justify-items", "justify-items"],
  ["justify-self", "justify-self"],
  ["overflow-x", "overflow-x"],
  ["overflow-y", "overflow-y"],
  ["overflow-clip-margin", "overflow-clip-margin"],
  ["scroll-behavior", "scroll-behavior"],
  ["scroll-snap-type", "scroll-snap-type"],
  ["overscroll-behavior-x", "overscroll-behavior-x"],
  ["overscroll-behavior-y", "overscroll-behavior-y"],
  ["overscroll-behavior-block", "overscroll-behavior-block"],
  ["overscroll-behavior-inline", "overscroll-behavior-inline"],
  ["scrollbar-gutter", "scrollbar-gutter"],
  ["scrollbar-width", "scrollbar-width"],
  ["scrollbar-color", "scrollbar-color"],
  ["scrollbar-color-track", "scrollbar-color"],
  ["scroll-snap-align", "scroll-snap-align"],
  ["scroll-snap-align-inline", "scroll-snap-align"],
  ["scroll-snap-stop", "scroll-snap-stop"],
  ["margin-trim", "margin-trim"],
  ["content-visibility", "content-visibility"],
  ["box-decoration-break", "box-decoration-break"],
  ["scroll-margin-top", "scroll-margin-top"],
  ["scroll-margin-right", "scroll-margin-right"],
  ["scroll-margin-bottom", "scroll-margin-bottom"],
  ["scroll-margin-left", "scroll-margin-left"],
  ["scroll-padding-top", "scroll-padding-top"],
  ["scroll-padding-right", "scroll-padding-right"],
  ["scroll-padding-bottom", "scroll-padding-bottom"],
  ["scroll-padding-left", "scroll-padding-left"],
  ["container-type", "container-type"],
  ["container-name", "container-name"],
  ["grid-template-areas", "grid-template-areas"],
  ["appearance", "appearance"],
  ["accent-color", "accent-color"],
  ["color-scheme", "color-scheme"],
  ["pointer-events", "pointer-events"],
  ["user-select", "user-select"],
  ["transition-property", "transition-property"],
  ["transition-duration", "transition-duration"],
  ["transition-timing-function", "transition-timing-function"],
  ["transition-delay", "transition-delay"],
  ["transition-behavior", "transition-behavior"],
  ["animation-name", "animation-name"],
  ["animation-duration", "animation-duration"],
  ["animation-timing-function", "animation-timing-function"],
  ["animation-delay", "animation-delay"],
  ["animation-iteration-count", "animation-iteration-count"],
  ["animation-direction", "animation-direction"],
  ["animation-fill-mode", "animation-fill-mode"],
  ["animation-play-state", "animation-play-state"],
  ["animation-composition", "animation-composition"],
  ["filter", "filter"],
  ["backdrop-filter", "backdrop-filter"],
  ["mix-blend-mode", "mix-blend-mode"],
  ["isolation", "isolation"],
  ["clip-path", "clip-path"],
  ["mask-image", "mask-image"],
  ["counter-reset", "counter-reset"],
  ["counter-increment", "counter-increment"],
  ["counter-set", "counter-set"],
  ["hyphens", "hyphens"],
  ["text-wrap-mode", "text-wrap-mode"],
  ["text-wrap-style", "text-wrap-style"],
  ["direction", "direction"],
  ["writing-mode", "writing-mode"],
  ["border-image-source", "border-image-source"],
  ["border-image-slice", "border-image-slice"],
  ["border-image-width", "border-image-width"],
  ["border-image-outset", "border-image-outset"],
  ["border-image-repeat", "border-image-repeat"],
  ["background-position-x", "background-position-x"],
  ["background-position-y", "background-position-y"],
  ["mask-repeat", "mask-repeat"],
  ["mask-position", "mask-position"],
  ["mask-size", "mask-size"],
  ["mask-origin", "mask-origin"],
  ["mask-clip", "mask-clip"],
  ["transform-box", "transform-box"],
  ["transform-style", "transform-style"],
  ["block-ellipsis", "block-ellipsis"],
  ["cursor-image", "cursor-image"],
  ["cursor-image-x", "cursor-image-x"],
  ["cursor-image-y", "cursor-image-y"],
  ["contain", "contain"],
  ["visibility", "visibility"],
  ["grid-lanes-direction", "grid-lanes-direction"],
  ["grid-lanes-pack", "grid-lanes-pack"],
  ["fit-tolerance", "fit-tolerance"],
  ["break-before", "break-before"],
  ["break-after", "break-after"],
  ["break-inside", "break-inside"],
  ["orphans", "orphans"],
  ["widows", "widows"],
  ["print-color-adjust", "print-color-adjust"],
  ["page", "page"],
  ["column-count", "column-count"],
  ["column-width", "column-width"],
  ["column-fill", "column-fill"],
  ["column-span", "column-span"],
  ["column-rule-width", "column-rule-width"],
  ["column-rule-style", "column-rule-style"],
  ["column-rule-color", "column-rule-color"],
  ["column-height", "column-height"],
  ["column-wrap", "column-wrap"],
  ["text-orientation", "text-orientation"],
  ["line-break", "line-break"],
  ["text-align-last", "text-align-last"],
  ["text-decoration-inset", "text-decoration-inset"],
  // The second of text-decoration-inset's two values: the inset at the end side. It keeps to the
  // property's CSS name, so the two serialize as one declaration.
  ["text-decoration-inset-end", "text-decoration-inset"],
  ["scroll-marker-group", "scroll-marker-group"],
  ["shape-outside", "shape-outside"],
  ["shape-margin", "shape-margin"],
  ["margin-block-start", "margin-block-start"],
  ["margin-block-end", "margin-block-end"],
  ["margin-inline-start", "margin-inline-start"],
  ["margin-inline-end", "margin-inline-end"],
  ["padding-block-start", "padding-block-start"],
  ["padding-block-end", "padding-block-end"],
  ["padding-inline-start", "padding-inline-start"],
  ["padding-inline-end", "padding-inline-end"],
  ["inset-block-start", "inset-block-start"],
  ["inset-block-end", "inset-block-end"],
  ["inset-inline-start", "inset-inline-start"],
  ["inset-inline-end", "inset-inline-end"],
  ["border-block-start-width", "border-block-start-width"],
  ["border-block-end-width", "border-block-end-width"],
  ["border-inline-start-width", "border-inline-start-width"],
  ["border-inline-end-width", "border-inline-end-width"],
  ["border-block-start-style", "border-block-start-style"],
  ["border-block-end-style", "border-block-end-style"],
  ["border-inline-start-style", "border-inline-start-style"],
  ["border-inline-end-style", "border-inline-end-style"],
  ["border-block-start-color", "border-block-start-color"],
  ["border-block-end-color", "border-block-end-color"],
  ["border-inline-start-color", "border-inline-start-color"],
  ["border-inline-end-color", "border-inline-end-color"],
  ["color-interpolation-filters", "color-interpolation-filters"],
  ["flood-color", "flood-color"],
  ["flood-opacity", "flood-opacity"],
  ["lighting-color", "lighting-color"],
  ["will-change", "will-change"],
  ["shape-image-threshold", "shape-image-threshold"],
  ["background-blend-mode", "background-blend-mode"],
  ["perspective", "perspective"],
  ["perspective-origin", "perspective-origin"],
  ["backface-visibility", "backface-visibility"],
  ["caret-color", "caret-color"],
  ["resize", "resize"],
  ["interactivity", "interactivity"],
  ["touch-action", "touch-action"],
  ["caret-shape", "caret-shape"],
  ["inline-size", "inline-size"],
  ["block-size", "block-size"],
  ["min-inline-size", "min-inline-size"],
  ["min-block-size", "min-block-size"],
  ["max-inline-size", "max-inline-size"],
  ["max-block-size", "max-block-size"],
  ["border-start-start-radius-x", "border-start-start-radius"],
  ["border-start-start-radius-y", "border-start-start-radius"],
  ["border-start-end-radius-x", "border-start-end-radius"],
  ["border-start-end-radius-y", "border-start-end-radius"],
  ["border-end-start-radius-x", "border-end-start-radius"],
  ["border-end-start-radius-y", "border-end-start-radius"],
  ["border-end-end-radius-x", "border-end-end-radius"],
  ["border-end-end-radius-y", "border-end-end-radius"],
  // The scroll insets of the box's own frame: the block pair then the inline pair, which the
  // runtime settles onto the physical sides once it knows the element's axes.
  ["scroll-margin-block-start", "scroll-margin-block-start"],
  ["scroll-margin-block-end", "scroll-margin-block-end"],
  ["scroll-margin-inline-start", "scroll-margin-inline-start"],
  ["scroll-margin-inline-end", "scroll-margin-inline-end"],
  ["scroll-padding-block-start", "scroll-padding-block-start"],
  ["scroll-padding-block-end", "scroll-padding-block-end"],
  ["scroll-padding-inline-start", "scroll-padding-inline-start"],
  ["scroll-padding-inline-end", "scroll-padding-inline-end"],
];

/** Each key's id: its position in PROPS. Keys are unique; a duplicate fails the build at load. */
const IDs = new Map<string, number>();
for (let i = 0; i < PROPS.length; i++) {
  if (IDs.has(PROPS[i][0])) throw new Error(`duplicate property key '${PROPS[i][0]}'`);
  IDs.set(PROPS[i][0], i);
}

/** The CSS name of a property slot, as will-change and computed serialization print it. */
export function propCssName(p: number): string {
  return PROPS[p][1];
}

/** The id of the property name `key` names, or -1 (shorthands and unknown names). */
export function propId(key: string): number {
  const v = IDs.get(key);
  return v === undefined ? -1 : v;
}

/** The id of the property slot `key` names. */
function id(key: string): number {
  const v = IDs.get(key);
  if (v === undefined) throw new Error(`unknown property key '${key}'`);
  return v;
}

// Properties
export const P_DISPLAY = id("display");
export const P_FLEX_DIRECTION = id("flex-direction");
export const P_JUSTIFY_CONTENT = id("justify-content");
export const P_ALIGN_ITEMS = id("align-items");
export const P_ROW_GAP = id("row-gap");
export const P_COLUMN_GAP = id("column-gap");
export const P_FLEX_GROW = id("flex-grow");
export const P_FLEX_SHRINK = id("flex-shrink");
export const P_FLEX_BASIS = id("flex-basis");
export const P_WIDTH = id("width");
export const P_HEIGHT = id("height");
export const P_MIN_WIDTH = id("min-width");
export const P_MAX_WIDTH = id("max-width");
export const P_MIN_HEIGHT = id("min-height");
export const P_MAX_HEIGHT = id("max-height");
export const P_MARGIN_TOP = id("margin-top");
export const P_MARGIN_RIGHT = id("margin-right");
export const P_MARGIN_BOTTOM = id("margin-bottom");
export const P_MARGIN_LEFT = id("margin-left");
export const P_PADDING_TOP = id("padding-top");
export const P_PADDING_RIGHT = id("padding-right");
export const P_PADDING_BOTTOM = id("padding-bottom");
export const P_PADDING_LEFT = id("padding-left");
export const P_BORDER_TOP_WIDTH = id("border-top-width");
export const P_BORDER_RIGHT_WIDTH = id("border-right-width");
export const P_BORDER_BOTTOM_WIDTH = id("border-bottom-width");
export const P_BORDER_LEFT_WIDTH = id("border-left-width");
export const P_BORDER_TOP_COLOR = id("border-top-color");
export const P_BORDER_RIGHT_COLOR = id("border-right-color");
export const P_BORDER_BOTTOM_COLOR = id("border-bottom-color");
export const P_BORDER_LEFT_COLOR = id("border-left-color");
// Corner radii: each corner has a horizontal and a vertical radius, in CSS's
// top-left, top-right, bottom-right, bottom-left order.
export const P_BORDER_TOP_LEFT_RADIUS = id("border-top-left-radius");
export const P_BACKGROUND_COLOR = id("background-color");
export const P_COLOR = id("color");
export const P_FONT_SIZE = id("font-size");
export const P_FONT_WEIGHT = id("font-weight");
export const P_LINE_HEIGHT = id("line-height");
export const P_TEXT_ALIGN = id("text-align");
export const P_CURSOR = id("cursor");
export const P_BOX_SIZING = id("box-sizing");
export const P_OPACITY = id("opacity");
export const P_ALIGN_SELF = id("align-self");
export const P_OVERFLOW = id("overflow");
export const P_TEXT_DECORATION = id("text-decoration");
export const P_FONT_STYLE = id("font-style");
export const P_POSITION = id("position");
export const P_TOP = id("top");
export const P_RIGHT = id("right");
export const P_BOTTOM = id("bottom");
export const P_LEFT = id("left");
export const P_FONT_FAMILY = id("font-family");
/** The row in FONT_FAMILY_LISTS a font-family list fills, + 1; 0 when the list has one family. */
export const P_FONT_FAMILY_LIST = id("font-family-list");
export const P_WHITE_SPACE = id("white-space");
export const P_Z_INDEX = id("z-index");
export const P_FLEX_WRAP = id("flex-wrap");
export const P_ALIGN_CONTENT = id("align-content");
export const P_ORDER = id("order");
export const P_VERTICAL_ALIGN = id("vertical-align");
export const P_TABLE_LAYOUT = id("table-layout");
export const P_BORDER_COLLAPSE = id("border-collapse");
export const P_BORDER_SPACING_H = id("border-spacing-h");
export const P_BORDER_SPACING_V = id("border-spacing-v");
export const P_CAPTION_SIDE = id("caption-side");
export const P_EMPTY_CELLS = id("empty-cells");
export const P_CONTENT = id("content");
// Background layers. Each of these holds an id into its build-time list table (unit U_LIST), or
// -1 for the initial value; the paint code takes layer i of each list, cycling the shorter ones.
export const P_BACKGROUND_IMAGE = id("background-image");
export const P_BACKGROUND_REPEAT = id("background-repeat");
export const P_BACKGROUND_POSITION = id("background-position");
export const P_BACKGROUND_SIZE = id("background-size");
export const P_BACKGROUND_ORIGIN = id("background-origin");
export const P_BACKGROUND_CLIP = id("background-clip");
export const P_BACKGROUND_ATTACHMENT = id("background-attachment");
export const P_LIST_STYLE_TYPE = id("list-style-type");
export const P_LIST_STYLE_POSITION = id("list-style-position");
export const P_LIST_STYLE_IMAGE = id("list-style-image");
export const P_OUTLINE_STYLE = id("outline-style");
export const P_OUTLINE_WIDTH = id("outline-width");
export const P_OUTLINE_COLOR = id("outline-color");
export const P_OUTLINE_OFFSET = id("outline-offset");
export const P_BORDER_TOP_STYLE = id("border-top-style");
export const P_BORDER_RIGHT_STYLE = id("border-right-style");
export const P_BORDER_BOTTOM_STYLE = id("border-bottom-style");
export const P_BORDER_LEFT_STYLE = id("border-left-style");
export const P_BORDER_TOP_RIGHT_RADIUS = id("border-top-right-radius");
export const P_BORDER_BOTTOM_RIGHT_RADIUS = id("border-bottom-right-radius");
export const P_BORDER_BOTTOM_LEFT_RADIUS = id("border-bottom-left-radius");
export const P_BORDER_TOP_LEFT_RADIUS_Y = id("border-top-left-radius-y");
export const P_BORDER_TOP_RIGHT_RADIUS_Y = id("border-top-right-radius-y");
export const P_BORDER_BOTTOM_RIGHT_RADIUS_Y = id("border-bottom-right-radius-y");
export const P_BORDER_BOTTOM_LEFT_RADIUS_Y = id("border-bottom-left-radius-y");
export const P_FLOAT = id("float");
export const P_CLEAR = id("clear");
export const P_CLIP = id("clip");
// box-shadow: a list of shadows, ten numbers each, in the order they were written:
// [offset-x v, u, offset-y v, u, blur v, u, spread v, u, color (-1 is currentColor), inset].
// The paint code resolves the units against the element.
export const P_BOX_SHADOW = id("box-shadow");
// text-transform: none, uppercase, lowercase or capitalize (TT_*).
export const P_TEXT_TRANSFORM = id("text-transform");
// Letter and word spacing: a length, or `normal` (U_NORMAL) for none.
export const P_LETTER_SPACING = id("letter-spacing");
export const P_WORD_SPACING = id("word-spacing");
// The first line's indent: a length, or a percentage of the content box's width.
export const P_TEXT_INDENT = id("text-indent");
// tab-size: how many spaces a tab advances to the next tab stop.
export const P_TAB_SIZE = id("tab-size");
// text-overflow: what is drawn where a clipped line runs past the box (TO_*).
export const P_TEXT_OVERFLOW = id("text-overflow");
// overflow-wrap: whether a line may break inside a word (OW_*).
export const P_OVERFLOW_WRAP = id("overflow-wrap");
// word-break: breaking between any two characters, or none (WB_*).
export const P_WORD_BREAK = id("word-break");
// text-shadow: a list of shadows of the glyphs, in the same table as box-shadow's rows.
export const P_TEXT_SHADOW = id("text-shadow");
// CSS transforms: a transform list row (see shared/css/transforms.ts), or -1 for none; the
// transform origin is a row of [x v, u, y v, u, z v, u]; the individual properties are lists
// of their own, applied before `transform`.
export const P_TRANSFORM = id("transform");
export const P_TRANSFORM_ORIGIN = id("transform-origin");
export const P_TRANSLATE = id("translate");
export const P_ROTATE = id("rotate");
export const P_SCALE = id("scale");
export const P_OBJECT_FIT = id("object-fit");
// object-position holds a row id in the OBJECT_POSITIONS table (unit U_LIST), or -1 for the
// initial 50% 50%.
export const P_OBJECT_POSITION = id("object-position");
export const P_IMAGE_RENDERING = id("image-rendering");
export const P_IMAGE_ORIENTATION = id("image-orientation");
// aspect-ratio: the preferred width/height ratio as one number (0 for none), and whether the
// keyword `auto` came with it (`auto 1 / 2` uses a replaced element's own ratio and falls back
// to the given one).
export const P_ASPECT_RATIO = id("aspect-ratio");
export const P_ASPECT_RATIO_AUTO = id("aspect-ratio-auto");
// 1 when the font family is just the generic `monospace`: browsers give that family a smaller
// `medium` size than every other one, so the value has to travel with the family it belongs to.
export const P_FIXED_FONT = id("fixed-font");
// 1 while the computed font size still rests on `medium` rather than an absolute size: changing
// to the fixed family then scales it from one family's medium size to the other's.
export const P_MEDIUM_BASED = id("medium-based");
// SVG painting. fill and stroke hold a packed colour, PAINT_NONE or PAINT_CURRENT; the two
// opacities multiply the paint's alpha, the width is the stroke's pen, and the last three are
// the pen's cap and join and the fill's rule. SVG makes all of these inherit.
export const P_FILL = id("fill");
export const P_STROKE = id("stroke");
export const P_FILL_OPACITY = id("fill-opacity");
export const P_STROKE_OPACITY = id("stroke-opacity");
export const P_STROKE_WIDTH = id("stroke-width");
export const P_STROKE_LINECAP = id("stroke-linecap");
export const P_STROKE_LINEJOIN = id("stroke-linejoin");
export const P_FILL_RULE = id("fill-rule");
// Which parts of the page drag the window (app-region, from Window Controls Overlay).
export const P_APP_REGION = id("app-region");
// The rest of text-decoration: the lines are the P_TEXT_DECORATION bitmask, and these give the
// line's style, colour (-1 for currentColor), thickness and the underline's offset.
export const P_TEXT_DECORATION_STYLE = id("text-decoration-style");
export const P_TEXT_DECORATION_COLOR = id("text-decoration-color");
export const P_TEXT_DECORATION_THICKNESS = id("text-decoration-thickness");
export const P_UNDERLINE_OFFSET = id("underline-offset");
// How many lines of a block's inline content show before the last one ends in an ellipsis.
export const P_LINE_CLAMP = id("line-clamp");
// The ends of a dash in a stroke's pattern (SVG's stroke-dasharray and stroke-dashoffset).
export const P_STROKE_DASHARRAY = id("stroke-dasharray");
export const P_STROKE_DASHOFFSET = id("stroke-dashoffset");
// font-feature-settings: 1 + the index of its OpenType feature list in FONT_FEATURES, 0 for
// `normal`. The list is a run of `tag=value` pairs joined by semicolons.
export const P_FONT_FEATURE_SETTINGS = id("font-feature-settings");
// The font-variant longhands. Each holds a keyword, or for the ones that take a list, a bitmask
// of the values the list named; the runtime turns them into OpenType features (see
// runtime/style.ts) and font-feature-settings then overrides any tag they share.
export const P_FONT_VARIANT_CAPS = id("font-variant-caps");
export const P_FONT_VARIANT_LIGATURES = id("font-variant-ligatures");
export const P_FONT_VARIANT_NUMERIC = id("font-variant-numeric");
export const P_FONT_VARIANT_EAST_ASIAN = id("font-variant-east-asian");
export const P_FONT_VARIANT_POSITION = id("font-variant-position");
export const P_FONT_VARIANT_ALTERNATES = id("font-variant-alternates");
// font-variation-settings: 1 + the index of its list in FONT_VARIATIONS, 0 for `normal`. The list
// is a run of `tag=value` pairs joined by semicolons, like a feature list, and the host sets each
// axis of the run's font to its value.
export const P_FONT_VARIATION_SETTINGS = id("font-variation-settings");
// font-synthesis: a bit per kind of face the family may synthesize, `none` being 0. All three are
// on to begin with, as browsers do.
export const P_FONT_SYNTHESIS = id("font-synthesis");
export const FSYNTH_WEIGHT = 1;
export const FSYNTH_STYLE = 2;
export const FSYNTH_SMALL_CAPS = 4;
export const FSYNTH_ALL = FSYNTH_WEIGHT | FSYNTH_STYLE | FSYNTH_SMALL_CAPS;
// font-kerning: whether the font's kerning pairs are used. auto and normal leave them on; none
// turns them off, which the run asks of the font as the `kern` feature.
export const P_FONT_KERNING = id("font-kerning");
export const FKERN_AUTO = 0;
export const FKERN_NORMAL = 1;
export const FKERN_NONE = 2;
// font-language-override: `normal`, or a four-letter language tag packed into the value.
export const P_FONT_LANGUAGE_OVERRIDE = id("font-language-override");
// font-optical-sizing: whether a variable font's optical size follows the font size.
export const P_FONT_OPTICAL_SIZING = id("font-optical-sizing");
export const FOPSZ_AUTO = 0;
export const FOPSZ_NONE = 1;
// font-size-adjust: none (-1), or the x-height to font-size ratio to adjust to.
export const P_FONT_SIZE_ADJUST = id("font-size-adjust");
// font-stretch: the width of the face, as a percentage (100 for normal); selects among a family's
// faces by their font-stretch descriptors.
export const P_FONT_STRETCH = id("font-stretch");
// font-synthesis-weight/style/small-caps: whether that kind of face may be synthesized; auto (1)
// or none (0), which the runtime folds into the P_FONT_SYNTHESIS bits the run carries.
export const P_FONT_SYNTHESIS_WEIGHT = id("font-synthesis-weight");
export const P_FONT_SYNTHESIS_STYLE = id("font-synthesis-style");
export const P_FONT_SYNTHESIS_SMALL_CAPS = id("font-synthesis-small-caps");
export const FSYNTH_AUTO = 1;
export const FSYNTH_NONE = 0;
// font-variant-emoji: how emoji characters are presented.
export const P_FONT_VARIANT_EMOJI = id("font-variant-emoji");
// text-underline-position: where an underline sits relative to the text.
export const P_TEXT_UNDERLINE_POSITION = id("text-underline-position");
export const TUP_AUTO = 0;
export const TUP_UNDER = 1;
export const TUP_LEFT = 2;
export const TUP_RIGHT = 3;
export const TUP_FROM_FONT = 4;
// text-decoration-skip-ink: which descenders an underline may pass through.
export const P_TEXT_DECORATION_SKIP_INK = id("text-decoration-skip-ink");
export const TDSI_AUTO = 0;
export const TDSI_NONE = 1;
export const TDSI_ALL = 2;
// white-space-collapse: how white space in the text is collapsed, kept for the computed value.
export const P_WHITE_SPACE_COLLAPSE = id("white-space-collapse");
export const WSC_COLLAPSE = 0;
export const WSC_PRESERVE = 1;
export const WSC_PRESERVE_BREAKS = 2;
export const WSC_PRESERVE_SPACES = 3;
export const WSC_BREAK_SPACES = 4;
// text-box-trim: which of the first and last lines' over/under edges the box trims.
export const P_TEXT_BOX_TRIM = id("text-box-trim");
export const TBT_NONE = 0;
export const TBT_START = 1;
export const TBT_END = 2;
export const TBT_BOTH = 3;
// text-box-edge: the over and under edges, each one of the TBE_* edges.
export const P_TEXT_BOX_EDGE = id("text-box-edge");
export const TBE_TEXT = 0;
export const TBE_CAP = 1;
export const TBE_EX = 2;
export const TBE_ALPHABETIC = 3;
export const TBE_IDEOGRAPHIC = 4;
export const TBE_LEADING = 5;
export const TBE_AUTO = 6;
// initial-letter: 0 for normal, else the size (as a float) packed with the sink (an integer).
export const P_INITIAL_LETTER = id("initial-letter");
// The SVG text baselines, each one of the AB_* values.
export const P_ALIGNMENT_BASELINE = id("alignment-baseline");
export const P_DOMINANT_BASELINE = id("dominant-baseline");
export const AB_AUTO = 0;
export const AB_BASELINE = 1;
export const AB_TEXT_BOTTOM = 2;
export const AB_ALPHABETIC = 3;
export const AB_IDEOGRAPHIC = 4;
export const AB_MIDDLE = 5;
export const AB_CENTRAL = 6;
export const AB_MATHEMATICAL = 7;
export const AB_HANGING = 8;
// baseline-shift: baseline (0), sub or super (1, 2), or a length kept in v/u.
export const P_BASELINE_SHIFT = id("baseline-shift");
export const BS_BASELINE = 0;
export const BS_SUB = 1;
export const BS_SUPER = 2;


export const FVE_NORMAL = 0;
export const FVE_TEXT = 1;
export const FVE_EMOJI = 2;
export const FVE_UNICODE = 3;


// text-emphasis: the mark drawn beside each character. The style is one of the TEXTE_* values,
// the colour a colour id (-1 for currentColor), and the position one of the TEXTE_POS_* values,
// which says whether the mark goes over or under the text and on which side of it.
export const P_TEXT_EMPHASIS_STYLE = id("text-emphasis-style");
export const P_TEXT_EMPHASIS_COLOR = id("text-emphasis-color");
export const P_TEXT_EMPHASIS_POSITION = id("text-emphasis-position");

// border-image: the source image (-1 for `none`, a raster file's id, or -(gradient id + 2) as a
// background layer has), and rows for the slice, width, outset and repeat longhands. A slice row
// holds four (value, unit) pairs then the `fill` flag; a width or outset row four (value, unit)
// pairs; a repeat row the horizontal and vertical keywords.

// border-image-repeat keywords.
export const BI_STRETCH = 0;
export const BI_REPEAT = 1;
export const BI_ROUND = 2;
export const BI_SPACE = 3;
// text-emphasis-style: a mark shape, `filled` (the default) or `open` for the hollow kind. The
// dot is the default shape, so a style that names only `open` is an open dot, as in a browser.
export const TEXTE_NONE = 0;
export const TEXTE_DOT = 1;
export const TEXTE_OPEN_DOT = 2;
export const TEXTE_CIRCLE = 3;
export const TEXTE_OPEN_CIRCLE = 4;
export const TEXTE_DOUBLE_CIRCLE = 5;
export const TEXTE_OPEN_DOUBLE_CIRCLE = 6;
export const TEXTE_TRIANGLE = 7;
export const TEXTE_OPEN_TRIANGLE = 8;
export const TEXTE_SESAME = 9;
export const TEXTE_OPEN_SESAME = 10;

// text-emphasis-position: which side of the text the mark goes on. Horizontal text puts it over
// or under; the side (right or left) only matters for vertical writing, so it is kept for the
// computed value but does not move a mark.
export const TEXTE_POS_OVER_RIGHT = 0;
export const TEXTE_POS_OVER_LEFT = 1;
export const TEXTE_POS_UNDER_RIGHT = 2;
export const TEXTE_POS_UNDER_LEFT = 3;

// text-orientation keywords: mixed stands a run's glyphs up only where the script asks for it,
// upright stands every one up, and sideways turns them all with the line.
export const TO_MIXED = 0;
export const TO_UPRIGHT = 1;
export const TO_SIDEWAYS = 2;

// line-break keywords, from the loosest to the strictest, plus anywhere.
export const LB_AUTO = 0;
export const LB_LOOSE = 1;
export const LB_NORMAL = 2;
export const LB_STRICT = 3;
export const LB_ANYWHERE = 4;

// Grid layout. grid-template-columns and grid-template-rows hold a row id in the GRID_TRACKS
// table (U_LIST), or -1 for none; grid-auto-columns and grid-auto-rows hold one track the same
// way, with -1 standing for `auto`. A placement (grid-column/grid-row start and end) is an
// integer line number with U_NONE (negative counts from the end of the explicit grid), a span
// count with U_SPAN, `auto` (U_AUTO), or a line name with U_NAME (a row id in GRID_PLACEMENTS).
// grid-template-areas holds a row id in GRID_AREA_LISTS, or -1 for `none`.
export const P_GRID_TEMPLATE_COLUMNS = id("grid-template-columns");
export const P_GRID_TEMPLATE_ROWS = id("grid-template-rows");
export const P_GRID_AUTO_COLUMNS = id("grid-auto-columns");
export const P_GRID_AUTO_ROWS = id("grid-auto-rows");
/** grid-auto-flow: row (0), column (1), row dense (2) or column dense (3). */
export const P_GRID_AUTO_FLOW = id("grid-auto-flow");
export const P_GRID_COLUMN_START = id("grid-column-start");
export const P_GRID_COLUMN_END = id("grid-column-end");
export const P_GRID_ROW_START = id("grid-row-start");
export const P_GRID_ROW_END = id("grid-row-end");
export const P_JUSTIFY_ITEMS = id("justify-items");
export const P_JUSTIFY_SELF = id("justify-self");
// The two axes of `overflow` are longhands of their own; the shorthand sets both.
export const P_OVERFLOW_X = id("overflow-x");
export const P_OVERFLOW_Y = id("overflow-y");
// overflow-clip-margin: the visual box a clip measures from, and the margin it grows by. The
// value is a row of [box, length, unit]; see shared/css/properties/box.ts.
export const P_OVERFLOW_CLIP_MARGIN = id("overflow-clip-margin");
// hyphens: whether a word may break at a soft hyphen (`manual`), or at any point the language's
// hyphenation allows (`auto`, HY_*). No hyphenation dictionary ships with this build, so `auto`
// keeps its computed value but breaks where `manual` does; `none` drops the soft hyphens.
export const P_HYPHENS = id("hyphens");
// text-wrap, which is really its two longhands: the mode says whether lines wrap at all, and the
// style whether they are balanced across the block. A white-space that doesn't wrap sets the
// mode too, and the computed text-wrap then says so.
export const P_TEXT_WRAP_MODE = id("text-wrap-mode");
export const P_TEXT_WRAP_STYLE = id("text-wrap-style");
// direction: the side a line of text starts on (`ltr` or `rtl`), which `start` and `end` line up
// with. Bidi reordering isn't done, so text that mixes scripts draws in document order.
export const P_DIRECTION = id("direction");
// writing-mode: only `horizontal-tb` is laid out; the vertical modes aren't supported yet.
export const P_WRITING_MODE = id("writing-mode");
export const P_BORDER_IMAGE_SOURCE = id("border-image-source");
export const P_BORDER_IMAGE_SLICE = id("border-image-slice");
export const P_BORDER_IMAGE_WIDTH = id("border-image-width");
export const P_BORDER_IMAGE_OUTSET = id("border-image-outset");
export const P_BORDER_IMAGE_REPEAT = id("border-image-repeat");
// The background-position longhands: each holds a position row naming its own axis, and -1 while
// the property is unset, so the axis comes from background-position rather than a centred default.
export const P_BACKGROUND_POSITION_X = id("background-position-x");
export const P_BACKGROUND_POSITION_Y = id("background-position-y");
// text-orientation: how the glyphs of a vertical line stand. Only the horizontal modes are laid
// out, so this is kept for the computed value until upright CJK text is drawn.
export const P_TEXT_ORIENTATION = id("text-orientation");
// line-break: how strictly a line may break between CJK characters. Only the strictest breaks are
// taken here — between characters that are never kept together — so the value is kept as written
// and the computed value reports it.
export const P_LINE_BREAK = id("line-break");
// text-align-last: how the last line of a block is aligned, and each line a forced break ends.
// The value is one more than the T_* alignment it names, so 0 is `auto` (follow text-align).
export const P_TEXT_ALIGN_LAST = id("text-align-last");
// text-justify: how the extra space of a justified line is distributed.
export const P_TEXT_JUSTIFY = id("text-justify");
export const TJUST_AUTO = 0;
export const TJUST_INTER_WORD = 1;
export const TJUST_INTER_CHARACTER = 2;
export const TJUST_NONE = 3;
// text-decoration-inset: how far the decoration lines pull back from each end of the text they
// run under: the start inset, and the end one (a length or percentage; `auto` is a length the
// browser's own line metrics choose).
export const P_TEXT_DECORATION_INSET = id("text-decoration-inset");
export const P_TEXT_DECORATION_INSET_END = id("text-decoration-inset-end");
// scroll-marker-group: whether a scroll container generates a marker group box before or after
// itself (CSS Overflow 5), which holds the ::scroll-marker of each of its children.
export const P_SCROLL_MARKER_GROUP = id("scroll-marker-group");

export const SG_NONE = 0;
export const SG_BEFORE = 1;
export const SG_AFTER = 2;
// shape-outside: a row id in CLIP_SHAPES (the basic shapes clip-path takes, with `margin-box` as
// the default reference for a float), or -1 for none; shape-margin grows the shape outward.
export const P_SHAPE_OUTSIDE = id("shape-outside");
export const P_SHAPE_MARGIN = id("shape-margin");
export const PROP_COUNT = PROPS.length;

// The logical sides of the margins, padding and offsets (CSS Logical 1 §4). Which physical side
// each names depends on the element's own writing mode and direction, which are only known once
// its declarations have cascaded, so the runtime resolves them after the cascade rather than the
// compiler resolving them here.
export const P_MARGIN_BLOCK_START = id("margin-block-start");
export const P_MARGIN_BLOCK_END = id("margin-block-end");
export const P_MARGIN_INLINE_START = id("margin-inline-start");
export const P_MARGIN_INLINE_END = id("margin-inline-end");
export const P_PADDING_BLOCK_START = id("padding-block-start");
export const P_PADDING_BLOCK_END = id("padding-block-end");
export const P_PADDING_INLINE_START = id("padding-inline-start");
export const P_PADDING_INLINE_END = id("padding-inline-end");
export const P_INSET_BLOCK_START = id("inset-block-start");
export const P_INSET_BLOCK_END = id("inset-block-end");
export const P_INSET_INLINE_START = id("inset-inline-start");
export const P_INSET_INLINE_END = id("inset-inline-end");
// The logical border sides, in the same four-side order, grouped by the part of the border each
// sets so the runtime can find a side's slot from the part and the side.
export const P_BORDER_BLOCK_START_WIDTH = id("border-block-start-width");
export const P_BORDER_BLOCK_END_WIDTH = id("border-block-end-width");
export const P_BORDER_INLINE_START_WIDTH = id("border-inline-start-width");
export const P_BORDER_INLINE_END_WIDTH = id("border-inline-end-width");
export const P_BORDER_BLOCK_START_STYLE = id("border-block-start-style");
export const P_BORDER_BLOCK_END_STYLE = id("border-block-end-style");
export const P_BORDER_INLINE_START_STYLE = id("border-inline-start-style");
export const P_BORDER_INLINE_END_STYLE = id("border-inline-end-style");
export const P_BORDER_BLOCK_START_COLOR = id("border-block-start-color");
export const P_BORDER_BLOCK_END_COLOR = id("border-block-end-color");
export const P_BORDER_INLINE_START_COLOR = id("border-inline-start-color");
export const P_BORDER_INLINE_END_COLOR = id("border-inline-end-color");
// The logical sizes (CSS Logical 1 §5): a width or height named by the box's own axes.
export const P_INLINE_SIZE = id("inline-size");
export const P_BLOCK_SIZE = id("block-size");
export const P_MIN_INLINE_SIZE = id("min-inline-size");
export const P_MIN_BLOCK_SIZE = id("min-block-size");
export const P_MAX_INLINE_SIZE = id("max-inline-size");
export const P_MAX_BLOCK_SIZE = id("max-block-size");
export const P_BORDER_START_START_RADIUS = id("border-start-start-radius-x");
export const P_BORDER_START_START_RADIUS_Y = id("border-start-start-radius-y");
export const P_BORDER_START_END_RADIUS = id("border-start-end-radius-x");
export const P_BORDER_START_END_RADIUS_Y = id("border-start-end-radius-y");
export const P_BORDER_END_START_RADIUS = id("border-end-start-radius-x");
export const P_BORDER_END_START_RADIUS_Y = id("border-end-start-radius-y");
export const P_BORDER_END_END_RADIUS = id("border-end-end-radius-x");
export const P_BORDER_END_END_RADIUS_Y = id("border-end-end-radius-y");
// The logical scroll insets keep ids of their own; resolveLogicalSides settles them onto the
// physical sides the element's writing mode names, as it does for margins and paddings.
export const P_SCROLL_MARGIN_BLOCK_START = id("scroll-margin-block-start");
export const P_SCROLL_MARGIN_BLOCK_END = id("scroll-margin-block-end");
export const P_SCROLL_MARGIN_INLINE_START = id("scroll-margin-inline-start");
export const P_SCROLL_MARGIN_INLINE_END = id("scroll-margin-inline-end");
export const P_SCROLL_PADDING_BLOCK_START = id("scroll-padding-block-start");
export const P_SCROLL_PADDING_BLOCK_END = id("scroll-padding-block-end");
export const P_SCROLL_PADDING_INLINE_START = id("scroll-padding-inline-start");
export const P_SCROLL_PADDING_INLINE_END = id("scroll-padding-inline-end");

// font-palette: the colour palette a colour font's glyphs take. 0 is `normal` (the font's own
// palette 0), 1 `light` and 2 `dark` (the first palette the font marks for that background, or
// palette 0 when it marks none), and 3 + the id of a name for a palette an @font-palette-values
// rule defines (see FONT_PALETTE_NAMES and FONT_PALETTES).
export const P_FONT_PALETTE = id("font-palette");
export const P_COLOR_INTERPOLATION_FILTERS = id("color-interpolation-filters");
export const P_FLOOD_COLOR = id("flood-color");
export const P_FLOOD_OPACITY = id("flood-opacity");
export const P_LIGHTING_COLOR = id("lighting-color");
export const P_WILL_CHANGE = id("will-change");
export const P_SHAPE_IMAGE_THRESHOLD = id("shape-image-threshold");
export const P_BACKGROUND_BLEND_MODE = id("background-blend-mode");
export const P_PERSPECTIVE = id("perspective");
export const P_PERSPECTIVE_ORIGIN = id("perspective-origin");
export const P_BACKFACE_VISIBILITY = id("backface-visibility");
export const PALETTE_NORMAL = 0;
export const PALETTE_LIGHT = 1;
export const PALETTE_DARK = 2;
export const PALETTE_NAME = 3;
/** The base palette a @font-palette-values rule names: an index, or the light/dark keyword. */
export const PB_INDEX = 0;
export const PB_LIGHT = 1;
export const PB_DARK = 2;

// overflow-clip-margin's visual box: what the clip box is before the margin grows it.
export const OCM_PADDING_BOX = 0;
export const OCM_CONTENT_BOX = 1;
export const OCM_BORDER_BOX = 2;

// scroll-behavior: whether a scroll a script asks for (scrollTo, scrollIntoView and the like)
// jumps there or travels, `smooth`. It inherits, as it does in CSS.
export const P_SCROLL_BEHAVIOR = id("scroll-behavior");
// The insets a scroll stops short by: the margin on the box being brought into view, the padding
// on the container it scrolls in. Four physical sides each, zero unless set.
export const P_SCROLL_MARGIN_TOP = id("scroll-margin-top");
export const P_SCROLL_MARGIN_RIGHT = id("scroll-margin-right");
export const P_SCROLL_MARGIN_BOTTOM = id("scroll-margin-bottom");
export const P_SCROLL_MARGIN_LEFT = id("scroll-margin-left");
export const P_SCROLL_PADDING_TOP = id("scroll-padding-top");
export const P_SCROLL_PADDING_RIGHT = id("scroll-padding-right");
export const P_SCROLL_PADDING_BOTTOM = id("scroll-padding-bottom");
export const P_SCROLL_PADDING_LEFT = id("scroll-padding-left");

// Container queries: `container-type` is one of the CT_* values, and `container-name` an index
// into the CONTAINER_NAMES table (a space-separated list of names), or -1 for none.
export const P_CONTAINER_TYPE = id("container-type");
export const P_CONTAINER_NAME = id("container-name");

// grid-template-areas: a row id in GRID_AREA_LISTS, or -1 for `none`.
export const P_GRID_TEMPLATE_AREAS = id("grid-template-areas");

// appearance: whether the UA draws a control with its own painting (`auto`) or leaves the element
// to the author's box (`none`). A widget keyword (`button`, `textfield` and the rest) paints the
// same as `auto` here, so it is stored as auto.
export const P_APPEARANCE = id("appearance");

// accent-color: the colour a control's lit parts take — a checked box, a range's filled track and
// thumb. -1 is `auto`, the UA's own colour. It inherits, as it does in CSS.
export const P_ACCENT_COLOR = id("accent-color");

// caret-color: the colour a text field's insertion caret is drawn in. -1 is `auto`, which draws it
// in the field's own text colour, and -2 an explicit `currentColor`. It inherits, as in CSS.
export const P_CARET_COLOR = id("caret-color");

// caret-shape: the shape the caret draws — a bar (`auto` means the bar here), a block that covers
// the character it sits on, or an underscore under it.
export const P_CARET_SHAPE = id("caret-shape");
export const CSP_AUTO = 0;
export const CSP_BAR = 1;
export const CSP_BLOCK = 2;
export const CSP_UNDERSCORE = 3;

// resize: which edges the user can drag to resize a box whose overflow scrolls. The bits say which
// edge can move; neither (0) is `none`.
export const P_RESIZE = id("resize");
export const RESIZE_H = 1;
export const RESIZE_V = 2;

// interactivity: `inert` takes the element's subtree out of the pointer's and the tab order's
// reach, as the inert attribute does. Not inherited: an inert box's children are inert through it.
export const P_INTERACTIVITY = id("interactivity");
export const IA_AUTO = 0;
export const IA_INERT = 1;

// touch-action: the gestures a touch on the element may become — panning along an edge, zooming,
// both, or none. The runtime has a pointer and no touchscreen, so the value is read back and has
// no effect; the bits are the gestures it allows.
export const P_TOUCH_ACTION = id("touch-action");
export const TA_AUTO = 0;
export const TA_NONE = 1;
export const TA_PAN_LEFT = 2;
export const TA_PAN_RIGHT = 4;
export const TA_PAN_UP = 8;
export const TA_PAN_DOWN = 16;
export const TA_PINCH_ZOOM = 32;

// color-scheme: which of the UA's own colours the page asks for — one or both of `light` and
// `dark`, kept as bits so a list names both. `normal` is neither, and means light. It inherits.
export const P_COLOR_SCHEME = id("color-scheme");
export const CS_LIGHT = 1;
export const CS_DARK = 2;

// pointer-events: whether the pointer sees an element at all. `none` makes it see-through — the
// pointer reaches whatever is behind it — while a descendant can ask for events again with
// `auto`. The SVG keywords all behave as `auto` here. It inherits, as it does in CSS.
export const P_POINTER_EVENTS = id("pointer-events");

// user-select: whether a press may start a selection in the element. Only `none`, which stops it,
// and `all`, which takes the whole element, differ from `auto` here; the one selection native has
// is a text field's own. It inherits, as it does in CSS.
export const P_USER_SELECT = id("user-select");

// The counter properties: each holds an id into the app's COUNTER_ITEMS table (the lists of
// counters the declaration names), or -1 for none.
export const P_COUNTER_RESET = id("counter-reset");
export const P_COUNTER_INCREMENT = id("counter-increment");
export const P_COUNTER_SET = id("counter-set");

// scroll-snap-type: which axes a scroll container snaps on and whether it must, stored as an
// index into SCROLL_SNAP_TYPE_NAMES.
export const P_SCROLL_SNAP_TYPE = id("scroll-snap-type");
// What a scroll does when it reaches the end of its box: chain to the ancestor (`auto`), keep it
// (`contain`), or refuse to scroll at all (`none`). The logical pair stands for the axes of the
// box's own frame.
export const P_OVERSCROLL_BEHAVIOR_X = id("overscroll-behavior-x");
export const P_OVERSCROLL_BEHAVIOR_Y = id("overscroll-behavior-y");
export const P_OVERSCROLL_BEHAVIOR_BLOCK = id("overscroll-behavior-block");
export const P_OVERSCROLL_BEHAVIOR_INLINE = id("overscroll-behavior-inline");
// The room a scrollbar keeps whether or not it is showing, how wide it is, and its two colours
// (the thumb's slot first; -1 in either is `auto`).
export const P_SCROLLBAR_GUTTER = id("scrollbar-gutter");
export const P_SCROLLBAR_WIDTH = id("scrollbar-width");
export const P_SCROLLBAR_COLOR = id("scrollbar-color");
export const P_SCROLLBAR_COLOR_TRACK = id("scrollbar-color-track");
// Where a snap area lines up in its scrollport, on each axis, and whether a scroll may pass it.
export const P_SCROLL_SNAP_ALIGN = id("scroll-snap-align");
export const P_SCROLL_SNAP_ALIGN_INLINE = id("scroll-snap-align-inline");
export const P_SCROLL_SNAP_STOP = id("scroll-snap-stop");
// Which of a box's children have their margins trimmed against its edge, whether its content is
// laid out at all, and how a box split across fragments paints its borders.
export const P_MARGIN_TRIM = id("margin-trim");
export const P_CONTENT_VISIBILITY = id("content-visibility");
export const P_BOX_DECORATION_BREAK = id("box-decoration-break");

// scroll-snap-type keywords: the first value of each axis's three, then its mandatory and
// proximity spellings one and two after it.
export const SST_NONE = 0;
export const SST_X = 1;
export const SST_Y = 4;
export const SST_BLOCK = 7;
export const SST_INLINE = 10;
export const SST_BOTH = 13;
export const SST_PAIR = 16;

/** The keyword pairs scroll-snap-type takes, by stored value: an axis, then its strictness. */
export const SCROLL_SNAP_TYPE_NAMES: string[] = ["none",
  "x", "x mandatory", "x proximity",
  "y", "y mandatory", "y proximity",
  "block", "block mandatory", "block proximity",
  "inline", "inline mandatory", "inline proximity",
  "both", "both mandatory", "both proximity",
  "pair", "pair mandatory", "pair proximity"];

// scroll-behavior keywords: smooth is the one that travels.
export const SB_AUTO = 0;
export const SB_SMOOTH = 1;
// Transitions and animations. Each value is a row id in the shared animation table (unit
// U_LIST) holding one entry per comma-separated item: transition-property holds property ids
// (-1 is `all`, -2 is `none`), durations and delays are milliseconds, and the timing functions
// are row ids of their own. The initial value of every one of them is -1 with unit U_NONE.
export const P_TRANSITION_PROPERTY = id("transition-property");
export const P_TRANSITION_DURATION = id("transition-duration");
export const P_TRANSITION_TIMING_FUNCTION = id("transition-timing-function");
export const P_TRANSITION_DELAY = id("transition-delay");
// transition-behavior: whether a discrete property (display) transitions at all. The values are
// keywords TBB_*, in a list like the other transition-* longhands.
export const P_TRANSITION_BEHAVIOR = id("transition-behavior");
export const TB_NORMAL = 0;
export const TB_ALLOW_DISCRETE = 1;
export const P_ANIMATION_NAME = id("animation-name");
export const P_ANIMATION_DURATION = id("animation-duration");
export const P_ANIMATION_TIMING_FUNCTION = id("animation-timing-function");
export const P_ANIMATION_DELAY = id("animation-delay");
export const P_ANIMATION_ITERATION_COUNT = id("animation-iteration-count");
export const P_ANIMATION_DIRECTION = id("animation-direction");
export const P_ANIMATION_FILL_MODE = id("animation-fill-mode");
export const P_ANIMATION_PLAY_STATE = id("animation-play-state");
// animation-composition holds a row id in the animation list table (unit U_LIST), one entry per
// animation: 0 replace, 1 add, 2 accumulate (see AC_* in shared/css/anim.ts).
export const P_ANIMATION_COMPOSITION = id("animation-composition");
// `filter` and `backdrop-filter` hold a row id in the filter table (unit U_LIST), with eight
// numbers per function (see shared/css/filters.ts); -1 with unit U_NONE is `none`.
export const P_FILTER = id("filter");
export const P_BACKDROP_FILTER = id("backdrop-filter");
export const P_MIX_BLEND_MODE = id("mix-blend-mode");
export const P_ISOLATION = id("isolation");

// `clip-path` holds a row id in the clip-path table (unit U_LIST), with the shape's numbers in it
// (see shared/css/clip-path.ts); -1 with unit U_NONE is `none`.
export const P_CLIP_PATH = id("clip-path");

// `mask-image` holds what a BG_IMAGES value holds (see runtime/background.ts): -1 is `none`, and a
// gradient is -(its gradient id + 2).
export const P_MASK_IMAGE = id("mask-image");
// The other mask longhands hold the rows a background layer list holds: mask-repeat a BG_REPEAT
// row, mask-position a BG_POSITION one, mask-size a BG_SIZE one, and mask-origin and mask-clip
// the BG_ORIGIN and BG_CLIP ones. -1 with unit U_NONE is the property's initial value.
export const P_MASK_REPEAT = id("mask-repeat");
export const P_MASK_POSITION = id("mask-position");
export const P_MASK_SIZE = id("mask-size");
export const P_MASK_ORIGIN = id("mask-origin");
export const P_MASK_CLIP = id("mask-clip");

// transform-box: the reference box a transform's percentages and its origin resolve against.
// On an HTML box, fill-box, stroke-box and view-box all behave as the border box.
export const P_TRANSFORM_BOX = id("transform-box");

export const TB_CONTENT_BOX = 0;
export const TB_BORDER_BOX = 1;
export const TB_FILL_BOX = 2;
export const TB_STROKE_BOX = 3;
export const TB_VIEW_BOX = 4;

// transform-style: flat (the initial value) or preserve-3d, which makes a 3D rendering context
// whose descendants keep their depth.
export const P_TRANSFORM_STYLE = id("transform-style");

export const TS_FLAT = 0;
export const TS_PRESERVE_3D = 1;

// block-ellipsis: what a `line-clamp`ed box puts at the end of its last line — an ellipsis
// (auto) or nothing (no-ellipsis).
export const P_BLOCK_ELLIPSIS = id("block-ellipsis");

export const BE_AUTO = 0;
export const BE_NO_ELLIPSIS = 1;

// A `cursor: url(…)` image: the IMAGE_FILES id of the file, -1 for none, and the hotspot's
// offset in the image, in px from its top-left. The keyword after the url() is the fallback,
// which P_CURSOR holds.
export const P_CURSOR_IMAGE = id("cursor-image");
export const P_CURSOR_IMAGE_X = id("cursor-image-x");
export const P_CURSOR_IMAGE_Y = id("cursor-image-y");

// contain: the kinds of containment a box asks for, as a bitmask (CSS Containment 1). `strict`
// is size, layout, style and paint; `content` is layout, style and paint.
export const P_CONTAIN = id("contain");

export const CONTAIN_SIZE = 1;
export const CONTAIN_LAYOUT = 2;
export const CONTAIN_STYLE = 4;
export const CONTAIN_PAINT = 8;
/** The level-2 axis sizes: one axis contained, the other not. */
export const CONTAIN_INLINE_SIZE = 16;
export const CONTAIN_BLOCK_SIZE = 32;

// visibility: a box the page lays out but doesn't draw, which a descendant may make visible again.
export const P_VISIBILITY = id("visibility");
// Grid lanes: which axis the lanes stack along, how densely they pack, and how close two lane
// positions must be to count as tied.
export const P_GRID_LANES_DIRECTION = id("grid-lanes-direction");
export const P_GRID_LANES_PACK = id("grid-lanes-pack");
export const P_FIT_TOLERANCE = id("fit-tolerance");
// Fragmentation (CSS Fragmentation and Multicol): parsed and inherited where the spec says, but
// this build lays no fragmented context out yet, so they have no effect.
export const P_BREAK_BEFORE = id("break-before");
export const P_BREAK_AFTER = id("break-after");
export const P_BREAK_INSIDE = id("break-inside");
export const P_ORPHANS = id("orphans");
export const P_WIDOWS = id("widows");
// print-color-adjust: whether a print keeps the colours as they are (`exact`) or lets the device
// spend ink as it likes (`economy`); no effect while there is no print output.
export const P_PRINT_COLOR_ADJUST = id("print-color-adjust");
// page: the named page a box is laid out on in print, or `auto`; stored as a CONTAINER_NAMES
// entry, -1 for auto.
export const P_PAGE = id("page");
// Multi-column layout: how many columns (or how wide), how their content is filled, whether a
// child spans them all, and the rule drawn in the gutters.
export const P_COLUMN_COUNT = id("column-count");
export const P_COLUMN_WIDTH = id("column-width");
export const P_COLUMN_FILL = id("column-fill");
export const P_COLUMN_SPAN = id("column-span");
export const P_COLUMN_RULE_WIDTH = id("column-rule-width");
export const P_COLUMN_RULE_STYLE = id("column-rule-style");
export const P_COLUMN_RULE_COLOR = id("column-rule-color");
// CSS Multicol 2's column sizing: a height each column takes, and whether more columns wrap out
// of the box when its content doesn't fit.
export const P_COLUMN_HEIGHT = id("column-height");
export const P_COLUMN_WRAP = id("column-wrap");

// column-fill keywords.
export const CF_AUTO = 0;
export const CF_BALANCE = 1;
export const CF_BALANCE_ALL = 2;

// column-wrap keywords.
export const CW_AUTO = 0;
export const CW_WRAP = 1;
export const CW_NOWRAP = 2;

// column-span keywords.
export const CS_NONE = 0;
export const CS_ALL = 1;

// break-* keywords (CSS Fragmentation 3, the CSS 2.1 page-break-* aliases included).
export const BK_AUTO = 0;
export const BK_AVOID = 1;
export const BK_AVOID_PAGE = 2;
export const BK_AVOID_COLUMN = 3;
export const BK_AVOID_REGION = 4;
export const BK_PAGE = 5;
export const BK_COLUMN = 6;
export const BK_REGION = 7;
export const BK_LEFT = 8;
export const BK_RIGHT = 9;
export const BK_RECTO = 10;
export const BK_VERSO = 11;

// print-color-adjust keywords.
export const PCA_ECONOMY = 0;
export const PCA_EXACT = 1;

// grid-lanes-direction: the lane axis and its reversal bits; `normal` derives the axis from the
// template, which the parser stores as the auto unit.
export const GL_COLUMN = 0;
export const GL_ROW = 1;
export const GL_FILL_REVERSE = 2; // items fill the stacking axis from its end
export const GL_TRACK_REVERSE = 4; // lanes are numbered from the end

// visibility: hidden and collapse both leave the box unpainted; a table collapses its space.
export const VIS_VISIBLE = 0;
export const VIS_HIDDEN = 1;
export const VIS_COLLAPSE = 2;

// container-type: whether the element is a query container, and for which axes. `inline-size`
// contains the inline axis only, which is what a query on the width needs.
export const CT_NORMAL = 0;
export const CT_SIZE = 1;
export const CT_INLINE_SIZE = 2;

// appearance keywords.
export const AP_AUTO = 0;
export const AP_NONE = 1;

// pointer-events keywords: none is see-through, and every other value behaves as auto.
export const PTR_AUTO = 0;
export const PTR_NONE = 1;

/**
 * The keywords `pointer-events` takes, indexed by the stored value. The SVG ones (`visiblePainted`
 * and the rest) only matter to an SVG picture, which is drawn whole here, so they all hit as `auto`.
 */
export const POINTER_EVENTS_NAMES: string[] = ["auto", "none", "visiblePainted", "visibleFill",
  "visibleStroke", "visible", "painted", "fill", "stroke", "all"];

// user-select keywords.
export const US_AUTO = 0;
export const US_TEXT = 1;
export const US_NONE = 2;
export const US_ALL = 3;

export const USER_SELECT_NAMES: string[] = ["auto", "text", "none", "all"];

/**
 * The keywords `appearance` takes, indexed by the stored value. Only `none` differs in how a
 * control paints: a widget keyword asks for the same UA painting `auto` gets.
 */
export const APPEARANCE_NAMES: string[] = ["auto", "none", "button", "button-bevel", "checkbox",
  "listbox", "menulist", "menulist-button", "meter", "progress-bar", "push-button", "radio",
  "searchfield", "slider-horizontal", "square-button", "textarea", "textfield", "inner-spin-button",
  "media-slider", "media-sliderthumb", "media-volume-slider", "media-volume-sliderthumb",
  "slider-vertical", "base", "base-select"];

// hyphens keywords.
export const HY_NONE = 0;
export const HY_MANUAL = 1;
export const HY_AUTO = 2;

// text-wrap-mode and text-wrap-style keywords.
export const TWM_WRAP = 0;
export const TWM_NOWRAP = 1;
export const TWS_AUTO = 0;
export const TWS_BALANCE = 1;
export const TWS_PRETTY = 2;
export const TWS_STABLE = 3;

// direction keywords.
export const DIR_LTR = 0;
export const DIR_RTL = 1;

// writing-mode: horizontal-tb runs its lines across the page and stacks blocks down it; the
// vertical modes run their lines down the page, with blocks stacking right to left (vertical-rl)
// or left to right (vertical-lr). The sideways modes turn the glyphs with the line.
export const WM_HORIZONTAL_TB = 0;
export const WM_VERTICAL_RL = 1;
export const WM_VERTICAL_LR = 2;
export const WM_SIDEWAYS_RL = 3;
export const WM_SIDEWAYS_LR = 4;

// Properties that inherit from the parent element.
// text-decoration and its longhands aren't inherited: a decoration belongs to the element that
// declares it, and is drawn over the text of its in-flow descendants (the painter walks up to
// them). text-underline-offset does inherit, as CSS says.
export const INHERITED: number[] = [P_COLOR, P_FONT_SIZE, P_FONT_WEIGHT, P_LINE_HEIGHT, P_TEXT_ALIGN, P_CURSOR, P_FONT_STYLE, P_FONT_FAMILY, P_FONT_FAMILY_LIST, P_WHITE_SPACE,
  P_BORDER_COLLAPSE, P_BORDER_SPACING_H, P_BORDER_SPACING_V, P_CAPTION_SIDE, P_EMPTY_CELLS,
  P_LIST_STYLE_TYPE, P_LIST_STYLE_POSITION, P_LIST_STYLE_IMAGE, P_TEXT_TRANSFORM,
  P_LETTER_SPACING, P_WORD_SPACING, P_TEXT_INDENT, P_TAB_SIZE, P_OVERFLOW_WRAP, P_WORD_BREAK, P_TEXT_SHADOW,
  P_IMAGE_ORIENTATION, P_FIXED_FONT, P_MEDIUM_BASED,
  P_UNDERLINE_OFFSET,
  P_FILL, P_STROKE, P_FILL_OPACITY, P_STROKE_OPACITY, P_STROKE_WIDTH, P_STROKE_LINECAP, P_STROKE_LINEJOIN, P_FILL_RULE,
  P_STROKE_DASHARRAY, P_STROKE_DASHOFFSET,
  P_FONT_FEATURE_SETTINGS, P_FONT_VARIANT_CAPS, P_FONT_VARIANT_LIGATURES, P_FONT_VARIANT_NUMERIC,
  P_FONT_VARIANT_EAST_ASIAN, P_FONT_VARIANT_POSITION, P_FONT_VARIANT_ALTERNATES,
  P_FONT_VARIATION_SETTINGS, P_FONT_SYNTHESIS,
  P_TEXT_EMPHASIS_STYLE, P_TEXT_EMPHASIS_COLOR, P_TEXT_EMPHASIS_POSITION,
  P_SCROLL_BEHAVIOR, P_ACCENT_COLOR, P_COLOR_SCHEME, P_POINTER_EVENTS, P_USER_SELECT,
  P_HYPHENS, P_TEXT_WRAP_MODE, P_TEXT_WRAP_STYLE, P_DIRECTION, P_WRITING_MODE,
  P_VISIBILITY, P_ORPHANS, P_WIDOWS, P_PRINT_COLOR_ADJUST,
  P_TEXT_ORIENTATION, P_LINE_BREAK, P_TEXT_ALIGN_LAST, P_TEXT_JUSTIFY, P_TEXT_DECORATION_INSET, P_FONT_PALETTE,
  P_FONT_KERNING, P_FONT_LANGUAGE_OVERRIDE, P_FONT_OPTICAL_SIZING, P_FONT_SIZE_ADJUST,
  P_FONT_STRETCH, P_FONT_SYNTHESIS_WEIGHT, P_FONT_SYNTHESIS_STYLE, P_FONT_SYNTHESIS_SMALL_CAPS,
  P_FONT_VARIANT_EMOJI, P_TEXT_UNDERLINE_POSITION, P_TEXT_DECORATION_SKIP_INK, P_WHITE_SPACE_COLLAPSE,
  P_TEXT_BOX_TRIM, P_DOMINANT_BASELINE,
  P_COLOR_INTERPOLATION_FILTERS, P_FLOOD_COLOR, P_FLOOD_OPACITY, P_LIGHTING_COLOR, P_SHAPE_IMAGE_THRESHOLD,
  P_CARET_COLOR];
// Font families. Custom families come from @font-face and take ids from FF_CUSTOM up, in the
// order the app's font faces are declared.
export const FF_SYSTEM = 0;
export const FF_MONO = 1;
export const FF_SERIF = 2;
// The system's other designs, which the ui-* keywords name: New York (serif), SF Rounded and
// SF Mono. Their ids sit below the families an @font-face declares, so a face's index is its
// family id minus FF_CUSTOM.
export const FF_UI_SERIF = 3;
export const FF_UI_ROUNDED = 4;
export const FF_UI_MONOSPACE = 5;
// `sans-serif` is not the system UI font: a browser draws the generic sans in the system's
// standard sans face (Helvetica on macOS, Arial on Windows and Linux), while `system-ui` names
// the face the system draws its own interface in. The two measure differently, so they get ids
// of their own.
export const FF_SANS = 6;
export const FF_CUSTOM = 7;

// Units
// Units, in id order: the key its U_ constant names. A unit's id is its position here.
const UNITS: readonly string[] = [
  "none",
  "px",
  "pct",
  "vw",
  "vh",
  "em",
  "auto",
  "normal",
  "smaller",
  "larger",
  "list",
  "cover",
  "contain",
  "farthest-corner",
  "closest-side",
  "closest-corner",
  "farthest-side",
  "expr",
  "min-content",
  "max-content",
  "fit-content",
  "medium",
  "from-font",
  "lh",
  "bolder",
  "lighter",
  "span",
  "cqw",
  "cqh",
  "cqi",
  "cqb",
  "cqmin",
  "cqmax",
  "name",
  "safe",
  "unsafe",
  "deg",
  "ex",
  "ch",
  "subgrid",
  "rem",
  "wide",
  "stretch",
];

/** Each unit key's id. Ids are positions, so a new unit inserts a line here. */
const UNIT_IDS = new Map<string, number>();
for (let i = 0; i < UNITS.length; i++) UNIT_IDS.set(UNITS[i], i);

/** The id of the unit `key` names. */
function unit(key: string): number {
  const v = UNIT_IDS.get(key);
  if (v === undefined) throw new Error(`unknown unit key '${key}'`);
  return v;
}

export const U_NONE = unit("none"); // plain number, keyword or color
export const U_PX = unit("px");
export const U_PCT = unit("pct");
export const U_VW = unit("vw");
export const U_VH = unit("vh");
export const U_EM = unit("em");
/** A multiple of the root element's font size. */
export const U_REM = unit("rem");
export const U_AUTO = unit("auto");
export const U_NORMAL = unit("normal"); // the keyword `normal` where its value is font- or layout-dependent
export const U_SMALLER = unit("smaller"); // font-size: smaller, relative to the parent's size
export const U_LARGER = unit("larger"); // font-size: larger, relative to the parent's size
export const U_LIST = unit("list"); // a value that indexes a build-time table of lists (background layers)
export const U_COVER = unit("cover"); // background-size: cover
export const U_CONTAIN = unit("contain"); // background-size: contain
export const U_FARTHEST_CORNER = unit("farthest-corner"); // radial-gradient() size keywords, resolved against the box
export const U_CLOSEST_SIDE = unit("closest-side");
export const U_CLOSEST_CORNER = unit("closest-corner");
export const U_FARTHEST_SIDE = unit("farthest-side");
export const U_EXPR = unit("expr"); // a value that indexes a build-time row of a max()/min()/clamp() expression
export const U_MIN_CONTENT = unit("min-content"); // width/height keywords measured from the box's own content
export const U_MAX_CONTENT = unit("max-content");
export const U_FIT_CONTENT = unit("fit-content"); // max-content squeezed into the space available
export const U_STRETCH = unit("stretch"); // the fill-available sizing keyword (and -webkit-fill-available)
export const U_MEDIUM = unit("medium"); // font-size: medium, whose px size depends on the font family
export const U_FROM_FONT = unit("from-font"); // text-decoration-thickness: from-font, the font's own thickness
export const U_LH = unit("lh"); // the lh unit, the element's used line height (the parent's on line-height)
export const U_BOLDER = unit("bolder"); // font-weight: bolder, relative to the parent's weight
export const U_LIGHTER = unit("lighter"); // font-weight: lighter, relative to the parent's weight
export const U_SPAN = unit("span"); // a grid placement's `span` count
// Container query units, relative to the query container's content box. cqi and cqb are the
// inline and block axes, which are width and height while the page writes left to right.
export const U_CQW = unit("cqw");
export const U_CQH = unit("cqh");
export const U_CQI = unit("cqi");
export const U_CQB = unit("cqb");
export const U_CQMIN = unit("cqmin");
export const U_CQMAX = unit("cqmax");
export const U_NAME = unit("name"); // a grid placement naming a line: v indexes the GRID_PLACEMENTS table
// The overflow position in front of an alignment keyword: `safe` keeps an overflowing box on the
// start edge, `unsafe` lets it overflow both edges. v is the keyword it modifies.
export const U_SAFE = unit("safe");
export const U_UNSAFE = unit("unsafe");
// An angle in a math function's row, in degrees: a rad, grad or turn argument converts to it.
export const U_DEG = unit("deg");
// Font-relative lengths measured from the element's font: `ex` is its x-height and `ch` the
// advance of its zero glyph.
export const U_EX = unit("ex");
export const U_CH = unit("ch");
export const U_SUBGRID = unit("subgrid"); // grid-template-*: subgrid, adopting the parent's tracks in that axis
// A keyframe value that names a CSS-wide keyword: the animation resolves it against the element
// when it applies the frame, since `inherit` reaches for the parent and `initial` for the
// property's own starting value. v is one of the WK_* codes.
export const U_WIDE = unit("wide");
export const WK_INHERIT = 0;
export const WK_INITIAL = 1;
export const WK_UNSET = 2;
export const WK_REVERT = 3;

// Keywords
export const D_BLOCK = 0;
export const D_FLEX = 1;
export const D_NONE = 2;
export const D_INLINE_BLOCK = 3;
export const D_INLINE = 4;
export const D_INLINE_FLEX = 5;
export const D_TABLE = 6;
export const D_INLINE_TABLE = 7;
export const D_TABLE_ROW_GROUP = 8;
export const D_TABLE_HEADER_GROUP = 9;
export const D_TABLE_FOOTER_GROUP = 10;
export const D_TABLE_ROW = 11;
export const D_TABLE_CELL = 12;
export const D_TABLE_COLUMN_GROUP = 13;
export const D_TABLE_COLUMN = 14;
export const D_TABLE_CAPTION = 15;
export const D_LIST_ITEM = 16;
export const D_GRID = 17;
export const D_INLINE_GRID = 18;
// Grid lanes (masonry): one axis is a normal grid track list, the other packs items into the
// shortest lane. See CSS Grid 3.
export const D_GRID_LANES = 19;
export const D_INLINE_GRID_LANES = 20;
// flow-root: a block box that establishes a block formatting context of its own.
export const D_FLOW_ROOT = 21;
/** `display: contents`: the box is not generated; its children take its place in the flow. */
export const D_CONTENTS = 22;

// Grid track sizes, as one track's slot in a GRID_TRACKS row. Every track is a minmax(): a min
// and a max, each seven numbers, [kind, v, u, 0, 0, 0, 0]. A plain `<length>` has the same in
// both, `fr` has GT_AUTO as its min, and GT_FIT_CONTENT's limit is in v (U_AUTO for `auto`).
export const GT_LEN = 0;
export const GT_AUTO = 1;
export const GT_FR = 2;
export const GT_MIN_CONTENT = 3;
export const GT_MAX_CONTENT = 4;
export const GT_FIT_CONTENT = 5;
// An auto-repeating track list. Its slot's v is how many track slots of the repeated list follow
// it in the same row, and GT_AUTO_FIT additionally collapses the copies no item lands in.
export const GT_AUTO_FILL = 6;
export const GT_AUTO_FIT = 7;
// A line's names. The slot's v is how many name ids follow it, and the ids — indexes into the
// GRID_NAMES table — fill GT_NAMES_PER_BLOCK slots of each whole slot block after it. A names
// block sits before the track whose start line it names, or at the end of a list for the line
// after its last track, so a repeated list brings its own names along.
export const GT_NAMES = 8;
export const GRID_TRACK_STRIDE = 14;
export const GT_NAMES_PER_BLOCK = GRID_TRACK_STRIDE - 2;

// grid-auto-flow
export const GF_ROW = 0;
export const GF_COLUMN = 1;
export const GF_ROW_DENSE = 2;
export const GF_COLUMN_DENSE = 3;

// list-style-type keywords. The marker text follows the item's ordinal (see markerText).
export const LST_DISC = 0;
export const LST_CIRCLE = 1;
export const LST_SQUARE = 2;
export const LST_DECIMAL = 3;
export const LST_DECIMAL_LEADING_ZERO = 4;
export const LST_LOWER_ALPHA = 5;
export const LST_UPPER_ALPHA = 6;
export const LST_LOWER_ROMAN = 7;
export const LST_UPPER_ROMAN = 8;
export const LST_NONE = 9;

// list-style-position
export const LSP_OUTSIDE = 0;
export const LSP_INSIDE = 1;

// outline-style keywords: `none`, every border style in BRS_* order (so the painter maps a style
// to its border style by adding one), and `auto`, which paints as a solid ring.
export const OLS_NONE = 0;
export const OLS_SOLID = 1;
export const OLS_DOTTED = 2;
export const OLS_DASHED = 3;
export const OLS_DOUBLE = 4;
export const OLS_GROOVE = 5;
export const OLS_RIDGE = 6;
export const OLS_INSET = 7;
export const OLS_OUTSET = 8;
export const OLS_AUTO = 9;

// border-style keywords, in the order of BORDER_STYLES in shared/css/borders.ts.
export const BRS_NONE = 0;
export const BRS_HIDDEN = 1;
export const BRS_SOLID = 2;
export const BRS_DOTTED = 3;
export const BRS_DASHED = 4;
export const BRS_DOUBLE = 5;
export const BRS_GROOVE = 6;
export const BRS_RIDGE = 7;
export const BRS_INSET = 8;
export const BRS_OUTSET = 9;

export const TL_AUTO = 0;
export const TL_FIXED = 1;

export const BC_SEPARATE = 0;
export const BC_COLLAPSE = 1;

export const CS_TOP = 0;
export const CS_BOTTOM = 1;

export const EC_SHOW = 0;
export const EC_HIDE = 1;

export const FS_NORMAL = 0;
export const FS_ITALIC = 1;

export const TD_NONE = 0;
export const TD_UNDERLINE = 1;
export const TD_LINE_THROUGH = 2;
export const TD_OVERLINE = 4;
// text-decoration-style
export const TDS_SOLID = 0;
export const TDS_DOUBLE = 1;
export const TDS_DOTTED = 2;
export const TDS_DASHED = 3;
export const TDS_WAVY = 4;

export const FD_ROW = 0;
export const FD_COLUMN = 1;
export const FD_ROW_REVERSE = 2;
export const FD_COLUMN_REVERSE = 3;

export const J_START = 0;
export const J_CENTER = 1;
export const J_END = 2;
export const J_SPACE_BETWEEN = 3;
export const J_SPACE_AROUND = 4;
export const J_SPACE_EVENLY = 5;
// justify-content's initial value, `normal`: stretch for a grid's tracks, start for flex lines.
export const J_NORMAL = 6;
// justify-content's physical edges. native lays pages out left to right, so these are `start` and
// `end` in the used layout, but the computed value keeps the keyword the author wrote.
export const J_LEFT = 7;
export const J_RIGHT = 8;
// `flex-start` and `flex-end` mean the same edges, but the computed value keeps the keyword the
// author wrote, so they get ids of their own.
export const J_FLEX_START = 9;
export const J_FLEX_END = 10;
// `stretch`, which behaves as `normal` but keeps its own keyword in the computed value.
export const J_STRETCH = 11;
// The baseline positions of align-content and justify-content, which sit the track set on their
// fallback edges (CSS Align 9.3).
export const J_BASELINE = 13;
export const J_LAST_BASELINE = 14;

// flex-wrap
export const FW_NOWRAP = 0;
export const FW_WRAP = 1;
export const FW_WRAP_REVERSE = 2;

// align-content: the J_* packings, plus stretch
export const AC_STRETCH = 6;
// align-content's initial value. It behaves as stretch, but the computed value keeps `normal`,
// so it needs an id of its own; justify-content's `normal` is J_NORMAL.
export const AC_NORMAL = 12;

export const A_STRETCH = 0;
export const A_START = 1;
export const A_CENTER = 2;
export const A_END = 3;
export const A_AUTO = 4; // align-self only
export const A_NORMAL = 5; // the initial value: stretch, except for a box with a size of its own
// The rest of <self-position>. A page laid out left to right puts self-start and left on the
// start edge, self-end and right on the end edge; the ids differ so the computed value keeps its
// own keyword.
export const A_SELF_START = 6;
export const A_SELF_END = 7;
export const A_LEFT = 8;
export const A_RIGHT = 9;
// The flex edges of <self-position>, kept apart from `start`/`end` for the same reason.
export const A_FLEX_START = 10;
export const A_FLEX_END = 11;
// The baseline positions. `baseline` and `first baseline` are one value, which computes to
// `baseline`; `last baseline` aligns the box's other baseline (CSS Align 3).
export const A_BASELINE = 12;
export const A_LAST_BASELINE = 13;

/** The old webkit spellings of the flex properties name the standard ones (CSS Flexbox 1 §3). */
export const WEBKIT_FLEX_ALIASES = new Set([
  "-webkit-flex", "-webkit-flex-direction", "-webkit-flex-wrap", "-webkit-flex-flow",
  "-webkit-flex-grow", "-webkit-flex-shrink", "-webkit-flex-basis", "-webkit-order",
  "-webkit-align-content", "-webkit-align-items", "-webkit-align-self", "-webkit-justify-content",
]);

// text-align: which edge a line's content starts from. `justify` spreads a line's spaces to both
// edges (text-justify says how), leaving the last line to text-align-last.
export const T_LEFT = 0;
export const T_CENTER = 1;
export const T_RIGHT = 2;
// `start` and `end` line up with the side `direction` says the text starts on.
export const T_START = 3;
export const T_END = 4;
export const T_JUSTIFY = 5;

// The cursor keywords, in the order the host maps them (see host/macos.m). `auto` is default.
export const C_DEFAULT = 0;
export const C_POINTER = 1;
export const C_TEXT = 2;
export const C_CONTEXT_MENU = 3;
export const C_HELP = 4;
export const C_PROGRESS = 5;
export const C_WAIT = 6;
export const C_CELL = 7;
export const C_CROSSHAIR = 8;
export const C_VERTICAL_TEXT = 9;
export const C_ALIAS = 10;
export const C_COPY = 11;
export const C_MOVE = 12;
export const C_NO_DROP = 13;
export const C_NOT_ALLOWED = 14;
export const C_GRAB = 15;
export const C_GRABBING = 16;
export const C_ALL_SCROLL = 17;
export const C_COL_RESIZE = 18;
export const C_ROW_RESIZE = 19;
export const C_N_RESIZE = 20;
export const C_E_RESIZE = 21;
export const C_S_RESIZE = 22;
export const C_W_RESIZE = 23;
export const C_NE_RESIZE = 24;
export const C_NW_RESIZE = 25;
export const C_SE_RESIZE = 26;
export const C_SW_RESIZE = 27;
export const C_EW_RESIZE = 28;
export const C_NS_RESIZE = 29;
export const C_NESW_RESIZE = 30;
export const C_NWSE_RESIZE = 31;
export const C_ZOOM_IN = 32;
export const C_ZOOM_OUT = 33;

export const OV_VISIBLE = 0;
export const OV_HIDDEN = 1;
export const OV_AUTO = 2;
export const OV_SCROLL = 3;
/** `overflow: clip`: clips like hidden, but never scrolls. */
export const OV_CLIP = 4;

// overscroll-behavior keywords: chain to the ancestor (auto, the initial value), keep the scroll
// in the box (contain), or don't scroll the box at all (none).
export const OVS_AUTO = 0;
export const OVS_CONTAIN = 1;
export const OVS_NONE = 2;

// scrollbar-gutter: no room kept (`auto`), room kept on the end edge (`stable`), or on both
// (`stable both-edges`). scrollbar-width: as the platform draws it, thinner, or not at all.
export const SBG_AUTO = 0;
export const SBG_STABLE = 1;
export const SBG_BOTH = 2;
export const SBW_AUTO = 0;
export const SBW_THIN = 1;
export const SBW_NONE = 2;

// scroll-snap-align keywords: which edge of the snap area lines up with the scrollport's.
export const SSA_NONE = 0;
export const SSA_START = 1;
export const SSA_END = 2;
export const SSA_CENTER = 3;
// scroll-snap-stop: whether a scroll may pass this snap area (`normal`) or must stop on it.
export const SSS_NORMAL = 0;
export const SSS_ALWAYS = 1;

// content-visibility: the content is laid out and painted (`visible`), may be skipped while off
// screen (`auto`), or is skipped entirely (`hidden`). box-decoration-break paints a split box as
// one box (`slice`) or as one per fragment (`clone`).
export const CV_VISIBLE = 0;
export const CV_AUTO = 1;
export const CV_HIDDEN = 2;
export const BDB_SLICE = 0;
export const BDB_CLONE = 1;

// margin-trim keywords, as bits: a box trims the edges it names, and may name several.
export const MT_NONE = 0;
export const MT_BLOCK = 1;
export const MT_INLINE = 2;
export const MT_BLOCK_START = 4;
export const MT_BLOCK_END = 8;
export const MT_INLINE_START = 16;
export const MT_INLINE_END = 32;

export const BS_CONTENT = 0;
export const BS_BORDER = 1;

// SVG paint values: -1 is `none`, -2 is `currentColor` (resolved against the element's color),
// -3 and below name a paint server (`url(#id)`): the value is PAINT_URL - the paint URL table
// index, see shared/svg-paint.ts. Anything else is a packed colour. An unpainted `stroke`
// starts as none.
export const PAINT_NONE = -1;
export const PAINT_CURRENT = -2;
export const PAINT_URL = -3;

// stroke-linecap, stroke-linejoin and fill-rule keywords, in the order the host takes them.
export const SLC_BUTT = 0;
export const SLC_ROUND = 1;
export const SLC_SQUARE = 2;
export const SLJ_MITER = 0;
export const SLJ_ROUND = 1;
export const SLJ_BEVEL = 2;
export const ICF_AUTO = 0;
export const ICF_SRGB = 1;
export const ICF_LINEARRGB = 2;
// will-change: the keywords have ids of their own; any other ident is stored as WC_PROPERTY_BASE
// plus the id of the property it names (the propCssName table prints it back).
export const WC_AUTO = 0;
export const WC_CONTENTS = 1;
export const WC_SCROLL_POSITION = 2;
export const WC_PROPERTY_BASE = 1000;
// backface-visibility.
export const BFV_VISIBLE = 0;
export const BFV_HIDDEN = 1;
export const FR_NONZERO = 0;
export const FR_EVENODD = 1;

export const POS_STATIC = 0;
export const POS_RELATIVE = 1;
export const POS_ABSOLUTE = 2;
export const POS_FIXED = 3;
export const POS_STICKY = 4;

// float
export const FL_NONE = 0;
export const FL_LEFT = 1;
export const FL_RIGHT = 2;

// clear
export const CL_NONE = 0;
export const CL_LEFT = 1;
export const CL_RIGHT = 2;
export const CL_BOTH = 3;

// text-overflow keywords.
export const TO_CLIP = 0;
export const TO_ELLIPSIS = 1;

// overflow-wrap keywords.
export const OW_NORMAL = 0;
export const OW_BREAK_WORD = 1;
export const OW_ANYWHERE = 2;

// word-break keywords.
export const WB_NORMAL = 0;
export const WB_BREAK_ALL = 1;
export const WB_KEEP_ALL = 2;
export const WB_BREAK_WORD = 3;

// text-transform keywords.
export const TT_NONE = 0;
export const TT_UPPERCASE = 1;
export const TT_LOWERCASE = 2;
export const TT_CAPITALIZE = 3;

// animation-direction.
export const AD_NORMAL = 0;
export const AD_REVERSE = 1;
export const AD_ALTERNATE = 2;
export const AD_ALTERNATE_REVERSE = 3;

// animation-fill-mode.
export const AF_NONE = 0;
export const AF_FORWARDS = 1;
export const AF_BACKWARDS = 2;
export const AF_BOTH = 3;

// animation-play-state.
export const APS_RUNNING = 0;
export const APS_PAUSED = 1;

// Timing function kinds: the first number of a timing function row. A TF_CUBIC row carries its
// four control points, and a TF_STEPS row its step count and where the jump sits (STEPS_*).
export const TF_LINEAR = 0;
export const TF_EASE = 1;
export const TF_EASE_IN = 2;
export const TF_EASE_OUT = 3;
export const TF_EASE_IN_OUT = 4;
export const TF_CUBIC = 5;
export const TF_STEPS = 6;

export const STEPS_START = 0;
export const STEPS_END = 1;
export const STEPS_NONE = 2;
export const STEPS_BOTH = 3;

// Filter function kinds: the first number of each eight-number group in a filter row.
export const FK_BLUR = 0;
export const FK_BRIGHTNESS = 1;
export const FK_CONTRAST = 2;
export const FK_DROP_SHADOW = 3;
export const FK_GRAYSCALE = 4;
export const FK_HUE_ROTATE = 5;
export const FK_INVERT = 6;
export const FK_OPACITY = 7;
export const FK_SATURATE = 8;
export const FK_SEPIA = 9;
/** A reference filter: `url(#id)`, naming a <filter> in the document (its paint URL index is in a). */
export const FK_URL = 10;

// mix-blend-mode keywords, in the order MIX_BLEND_NAMES lists them in runtime/cssom.ts. The
// order is also the host's CGBlendMode order (see host/macos.m), so a value passes straight
// through to CoreGraphics.
export const MB_NORMAL = 0;
export const MB_MULTIPLY = 1;
export const MB_SCREEN = 2;
export const MB_OVERLAY = 3;
export const MB_DARKEN = 4;
export const MB_LIGHTEN = 5;
export const MB_COLOR_DODGE = 6;
export const MB_COLOR_BURN = 7;
export const MB_HARD_LIGHT = 8;
export const MB_SOFT_LIGHT = 9;
export const MB_DIFFERENCE = 10;
export const MB_EXCLUSION = 11;
export const MB_HUE = 12;
export const MB_SATURATION = 13;
export const MB_COLOR = 14;
export const MB_LUMINOSITY = 15;
export const MB_PLUS_LIGHTER = 16;

// isolation keywords.
export const ISO_AUTO = 0;
export const ISO_ISOLATE = 1;

export const W_NORMAL = 0;
export const W_NOWRAP = 1;
export const W_PRE = 2;
export const W_PRE_WRAP = 3;
export const W_PRE_LINE = 4;
export const W_BREAK_SPACES = 5;

// vertical-align keywords. A length or percentage is a baseline shift instead.
export const VA_BASELINE = 0;
export const VA_SUB = 1;
export const VA_SUPER = 2;
export const VA_TEXT_TOP = 3;
export const VA_TEXT_BOTTOM = 4;
export const VA_MIDDLE = 5;
export const VA_TOP = 6;
export const VA_BOTTOM = 7;

// background-repeat, per axis.
export const BR_REPEAT = 0;
export const BR_NO_REPEAT = 1;
export const BR_SPACE = 2;
export const BR_ROUND = 3;

// background-attachment. A fixed layer is positioned against the viewport; a local one against
// the element's contents, so it moves as the element scrolls.
export const BA_SCROLL = 0;
export const BA_FIXED = 1;
export const BA_LOCAL = 2;

// background-origin and background-clip boxes.
export const BX_BORDER = 0;
export const BX_PADDING = 1;
export const BX_CONTENT = 2;

// The list tables a background layer property points into (see P_BACKGROUND_*). One property can
// hold a comma-separated list of layers; each list is compiled to a flat row of numbers in the
// matching table, and the property's value is that row's id.
export const BG_IMAGE = 0;
export const BG_REPEAT = 1;
export const BG_POSITION = 2;
export const BG_SIZE = 3;
export const BG_ORIGIN = 4;
export const BG_CLIP = 5;
export const BG_ATTACHMENT = 6;
export const BG_KIND_COUNT = 7;

// object-fit keywords: how a replaced element's content is fitted into its own box.
export const OF_FILL = 0;
export const OF_CONTAIN = 1;
export const OF_COVER = 2;
export const OF_NONE = 3;
export const OF_SCALE_DOWN = 4;

// image-rendering: the interpolation the host uses when it scales an image.
// app-region
export const AR_NONE = 0;
export const AR_DRAG = 1;
export const AR_NO_DRAG = 2;

export const IR_AUTO = 0;
export const IR_PIXELATED = 1;
export const IR_CRISP_EDGES = 2;

// image-orientation: whether an image's EXIF orientation is applied when it is loaded.
export const IO_FROM_IMAGE = 0;
export const IO_NONE = 1;

// Pseudo-class state bits
export const S_HOVER = 1;
export const S_ACTIVE = 2;
export const S_FOCUS = 4;
/** Focus the UA shows a ring for: keyboard focus, or any focus of a text field. */
export const S_FOCUS_VISIBLE = 8;
/** An open popover, from showPopover() or a popovertarget invoker. */
export const S_POPOVER_OPEN = 16;
export const S_CHECKED = 32;
export const S_INDETERMINATE = 64;
export const S_DEFAULT = 128;
export const S_DISABLED = 256;
export const S_ENABLED = 512;
export const S_REQUIRED = 1024;
export const S_OPTIONAL = 2048;
export const S_READ_ONLY = 4096;
export const S_READ_WRITE = 8192;
export const S_PLACEHOLDER_SHOWN = 16384;
export const S_VALID = 32768;
export const S_INVALID = 65536;
export const S_IN_RANGE = 131072;
export const S_OUT_OF_RANGE = 262144;
export const S_FOCUS_WITHIN = 524288;
/** The scroll container child a marker group's scrollport starts at. */
export const S_TARGET_CURRENT = 1048576;
/** The root's used color-scheme is dark, which the UA sheet's own dark colours read. */
export const S_SCHEME_DARK = 2097152;

/**
 * The state bits a control's attributes, value and validity decide, and the scroll position one:
 * :focus-within and :target-current. They are derived afresh whenever a style rule or a DOM query
 * asks about them, unlike the input state bits above, which the pointer, keyboard and focus code
 * sets as it happens.
 */
export const S_FORM_STATES = S_CHECKED | S_INDETERMINATE | S_DEFAULT | S_DISABLED | S_ENABLED
  | S_REQUIRED | S_OPTIONAL | S_READ_ONLY | S_READ_WRITE | S_PLACEHOLDER_SHOWN | S_VALID | S_INVALID
  | S_IN_RANGE | S_OUT_OF_RANGE | S_FOCUS_WITHIN | S_TARGET_CURRENT;

/**
 * Pseudo-elements that become real child nodes of their originating element, tagged "#before",
 * "#after", "#marker" and "#placeholder", so the layout, paint and style walks see them as
 * ordinary boxes. A selector's conditions are still tested against the originating element. The
 * placeholder box carries the ::placeholder style and never lays out or paints on its own: the
 * input paints its placeholder text with it.
 */
// Pseudo-element kinds, in id order: the key its PE_ constant names and the node tag the box
// carries. Ids are positions, so a new kind inserts a line here.
const PSEUDOS: readonly (readonly [string, string])[] = [
  ["-none", ""],
  ["-before", "#before"],
  ["-after", "#after"],
  ["-marker", "#marker"],
  ["-placeholder", "#placeholder"],
  ["-backdrop", "#backdrop"],
  ["-first-line", "#first-line"],
  ["-first-letter", "#first-letter"],
  ["-selection", "#selection"],
  ["-highlight", "#highlight"],
  ["-target-text", "#target-text"],
  ["-scroll-marker", "#scroll-marker"],
  ["-scroll-marker-group", "#scroll-marker-group"],
];

const PSEUDO_IDS = new Map<string, number>();
for (let i = 0; i < PSEUDOS.length; i++) PSEUDO_IDS.set(PSEUDOS[i][0], i);

/** The id of the pseudo-element kind `key` names. */
function pseudo(key: string): number {
  const v = PSEUDO_IDS.get(key);
  if (v === undefined) throw new Error(`unknown pseudo key '${key}'`);
  return v;
}

export const PE_NONE = pseudo("-none");
export const PE_BEFORE = pseudo("-before");
export const PE_AFTER = pseudo("-after");
export const PE_MARKER = pseudo("-marker");
export const PE_PLACEHOLDER = pseudo("-placeholder");
/** A modal dialog's backdrop: painted over the viewport, under the dialog, by the top layer. */
export const PE_BACKDROP = pseudo("-backdrop");
/** Style carriers for a block's first formatted line and its first letter; they never lay out. */
export const PE_FIRST_LINE = pseudo("-first-line");
export const PE_FIRST_LETTER = pseudo("-first-letter");
/** Style carrier for the selected text; its rules paint the highlight and its colour. */
export const PE_SELECTION = pseudo("-selection");
/** ::highlight(name): a style carrier for one registered highlight, named in its pseudoName. */
export const PE_HIGHLIGHT = pseudo("-highlight");
/** ::target-text: a style carrier for the text a URL's text fragment names. */
export const PE_TARGET_TEXT = pseudo("-target-text");
/** ::scroll-marker and ::scroll-marker-group: the marker boxes CSS Overflow 5 generates. */
export const PE_SCROLL_MARKER = pseudo("-scroll-marker");
export const PE_SCROLL_MARKER_GROUP = pseudo("-scroll-marker-group");

/** The node tag of each pseudo kind, indexed by PE_* ("" for PE_NONE). */
export const PSEUDO_TAGS: string[] = PSEUDOS.map((p) => p[1]);

// Generated content values that are keywords rather than an item list: `normal` (the initial
// value) and `none` generate no box.
export const CONTENT_NORMAL = -2;
export const CONTENT_NONE = -1;

/**
 * The CSS property name for each property id, in id order. Used to serialize declarations:
 * cssText, getPropertyValue and getComputedStyle.
 */
/** The CSS name each id serializes as, by id. */
export const PROPERTY_NAMES: string[] = PROPS.map((p) => p[1]);

/** The property id for a CSS property name, or -1 when it isn't one native supports. */
export function propertyId(name: string): number {
  // The prefixed spelling of a property this build knows by its unprefixed name, and the old
  // grid names for gap, which are aliases of the box-alignment ones.
  if (name === "-webkit-line-clamp") return P_LINE_CLAMP;
  if (name === "grid-row-gap") return P_ROW_GAP;
  if (name === "grid-column-gap") return P_COLUMN_GAP;
  if (name === "-webkit-appearance") return P_APPEARANCE;
  if (name === "-webkit-app-region") return P_APP_REGION;
  if (name === "-webkit-user-select") return P_USER_SELECT;
  if (name === "-webkit-mask-image") return P_MASK_IMAGE;
  return PROPERTY_NAMES.indexOf(name);
}

// Elements whose default display is inline-block (shrink-to-fit) rather than block.
export const INLINE_TAGS: string[] = ["span", "a", "button", "strong", "b", "em", "i", "code", "small", "label", "img", "embed", "object", "input", "br", "s", "del", "u", "mark", "sub", "sup", "kbd", "abbr", "time", "svg",
  "bdi", "bdo", "wbr", "var", "samp", "cite", "dfn", "q", "data", "ins", "ruby", "rt", "rp", "output", "font", "big", "tt", "strike", "acronym", "nobr"];

// font-variant-caps: one keyword, `normal` being 0.
export const FVC_NORMAL = 0;
export const FVC_SMALL_CAPS = 1;
export const FVC_ALL_SMALL_CAPS = 2;
export const FVC_PETITE_CAPS = 3;
export const FVC_ALL_PETITE_CAPS = 4;
export const FVC_UNICASE = 5;
export const FVC_TITLING_CAPS = 6;
// font-variant-ligatures: a bit per kind, one for on and one for off; neither means the font's
// own default. `none` turns every kind off.
export const FVL_COMMON_ON = 1;
export const FVL_COMMON_OFF = 2;
export const FVL_DISCRETIONARY_ON = 4;
export const FVL_DISCRETIONARY_OFF = 8;
export const FVL_HISTORICAL_ON = 16;
export const FVL_HISTORICAL_OFF = 32;
export const FVL_CONTEXTUAL_ON = 64;
export const FVL_CONTEXTUAL_OFF = 128;
export const FVL_NONE = FVL_COMMON_OFF | FVL_DISCRETIONARY_OFF | FVL_HISTORICAL_OFF | FVL_CONTEXTUAL_OFF;
// font-variant-numeric: pairs of bits name the first and second value of a pair (`lining-nums`
// and `oldstyle-nums` say the same thing two ways), and one bit each for the two keywords that
// stand alone.
export const FVN_LINING = 1;
export const FVN_OLDSTYLE = 2;
export const FVN_PROPORTIONAL = 4;
export const FVN_TABULAR = 8;
export const FVN_DIAGONAL_FRACTIONS = 16;
export const FVN_STACKED_FRACTIONS = 32;
export const FVN_ORDINAL = 64;
export const FVN_SLASHED_ZERO = 128;
// font-variant-east-asian: each a bit of its own; the first six are alternatives.
export const FVE_JIS78 = 1;
export const FVE_JIS83 = 2;
export const FVE_JIS90 = 4;
export const FVE_JIS04 = 8;
export const FVE_SIMPLIFIED = 16;
export const FVE_TRADITIONAL = 32;
export const FVE_FULL_WIDTH = 64;
export const FVE_PROPORTIONAL_WIDTH = 128;
export const FVE_RUBY = 256;
// font-variant-position and font-variant-alternates.
export const FVP_NORMAL = 0;
export const FVP_SUB = 1;
export const FVP_SUPER = 2;
export const FVA_NORMAL = 0;
export const FVA_HISTORICAL_FORMS = 1;

// The kind of property-tree node a display list's push command opens. The host builds its
// transform, clip and effect trees from these, nesting each node under the push that encloses it;
// the push's serial names the element it belongs to.
export const PK_TRANSFORM = 0;
export const PK_PERSPECTIVE = 1;
export const PK_CLIP_RECT = 2;
export const PK_CLIP_POLY = 3;
export const PK_CLIP_ELLIPSE = 4;
export const PK_CLIP_SHAPE = 5;
export const PK_EFFECT = 6;
export const PK_MASK = 7;
/** A scroll container's offset: the transform its content is painted under, and the thumb a
 *  visible scrollbar draws under. A scroll step edits this push rather than repainting. */
export const PK_SCROLL = 8;

/** How long an overlay scrollbar stays drawn after its last scroll, in milliseconds. */
export const SCROLLBAR_VISIBLE_MS = 900;

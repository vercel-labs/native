// The longhand properties a declaration sets. A var() value that turns out to be invalid at
// computed-value time leaves every longhand of its property unset, so the runtime needs to know
// which ones a shorthand covers.

import * as P from "../props.ts";

const SIDE_WIDTH = [P.P_BORDER_TOP_WIDTH, P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_LEFT_WIDTH];
const SIDE_STYLE = [P.P_BORDER_TOP_STYLE, P.P_BORDER_RIGHT_STYLE, P.P_BORDER_BOTTOM_STYLE, P.P_BORDER_LEFT_STYLE];
const SIDE_COLOR = [P.P_BORDER_TOP_COLOR, P.P_BORDER_RIGHT_COLOR, P.P_BORDER_BOTTOM_COLOR, P.P_BORDER_LEFT_COLOR];
const CORNERS = [P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS];
const CORNERS_Y = [P.P_BORDER_TOP_LEFT_RADIUS_Y, P.P_BORDER_TOP_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y];
const SIDES = ["top", "right", "bottom", "left"];

/** Every id a `border` shorthand sets: width, style and color on each of the four sides. */
function allBorderSides(): number[] {
  const out: number[] = [];
  for (let k = 0; k < 4; k++) out.push(SIDE_WIDTH[k], SIDE_STYLE[k], SIDE_COLOR[k]);
  return out;
}

/**
 * The property ids `prop` sets: one for a longhand, every longhand of a shorthand, or null for a
 * property this build doesn't handle.
 */
// A logical border side's width, style and colour ids, block-start and block-end (or inline-
// start and inline-end) in CSS's side order.
const BORDER_BLOCK_SIDES = [
  [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_START_STYLE, P.P_BORDER_BLOCK_START_COLOR],
  [P.P_BORDER_BLOCK_END_WIDTH, P.P_BORDER_BLOCK_END_STYLE, P.P_BORDER_BLOCK_END_COLOR],
];
const BORDER_INLINE_SIDES = [
  [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_START_STYLE, P.P_BORDER_INLINE_START_COLOR],
  [P.P_BORDER_INLINE_END_WIDTH, P.P_BORDER_INLINE_END_STYLE, P.P_BORDER_INLINE_END_COLOR],
];

export function longhandIds(prop: string): number[] | null {
  // The old webkit flex spellings set the same longhands as the standard names.
  if (P.WEBKIT_FLEX_ALIASES.has(prop)) return longhandIds(prop.slice("-webkit-".length));
  // A name that stands for two ids isn't found by propertyId(), which stops at the first.
  if (prop === "border-spacing") return [P.P_BORDER_SPACING_H, P.P_BORDER_SPACING_V];
  if (prop === "aspect-ratio") return [P.P_ASPECT_RATIO, P.P_ASPECT_RATIO_AUTO];
  // Spellings the value compiler accepts that don't name an id of their own.
  if (prop === "word-wrap") return [P.P_OVERFLOW_WRAP];
  const one = P.propertyId(prop);
  if (one >= 0) return [one];
  if (prop === "margin") return [P.P_MARGIN_TOP, P.P_MARGIN_RIGHT, P.P_MARGIN_BOTTOM, P.P_MARGIN_LEFT];
  if (prop === "padding") return [P.P_PADDING_TOP, P.P_PADDING_RIGHT, P.P_PADDING_BOTTOM, P.P_PADDING_LEFT];
  if (prop === "gap") return [P.P_ROW_GAP, P.P_COLUMN_GAP];
  if (prop === "transition") {
    return [P.P_TRANSITION_PROPERTY, P.P_TRANSITION_DURATION, P.P_TRANSITION_TIMING_FUNCTION,
      P.P_TRANSITION_DELAY, P.P_TRANSITION_BEHAVIOR];
  }
  // A layer of `animation` writes its duration, timing, delay, iteration count, direction, fill,
  // play state and name: the order a browser serializes them in.
  if (prop === "animation") {
    return [P.P_ANIMATION_DURATION, P.P_ANIMATION_TIMING_FUNCTION, P.P_ANIMATION_DELAY,
      P.P_ANIMATION_ITERATION_COUNT, P.P_ANIMATION_DIRECTION, P.P_ANIMATION_FILL_MODE,
      P.P_ANIMATION_PLAY_STATE, P.P_ANIMATION_NAME];
  }
  if (prop === "inset") return [P.P_TOP, P.P_RIGHT, P.P_BOTTOM, P.P_LEFT];
  if (prop === "scroll-margin") return [P.P_SCROLL_MARGIN_TOP, P.P_SCROLL_MARGIN_RIGHT, P.P_SCROLL_MARGIN_BOTTOM, P.P_SCROLL_MARGIN_LEFT];
  if (prop === "scroll-padding") return [P.P_SCROLL_PADDING_TOP, P.P_SCROLL_PADDING_RIGHT, P.P_SCROLL_PADDING_BOTTOM, P.P_SCROLL_PADDING_LEFT];
  if (prop === "scroll-margin-block") return [P.P_SCROLL_MARGIN_BLOCK_START, P.P_SCROLL_MARGIN_BLOCK_END];
  if (prop === "scroll-margin-inline") return [P.P_SCROLL_MARGIN_INLINE_START, P.P_SCROLL_MARGIN_INLINE_END];
  if (prop === "scroll-padding-block") return [P.P_SCROLL_PADDING_BLOCK_START, P.P_SCROLL_PADDING_BLOCK_END];
  if (prop === "scroll-padding-inline") return [P.P_SCROLL_PADDING_INLINE_START, P.P_SCROLL_PADDING_INLINE_END];
  if (prop === "overscroll-behavior") return [P.P_OVERSCROLL_BEHAVIOR_X, P.P_OVERSCROLL_BEHAVIOR_Y];
  if (prop === "margin-block") return [P.P_MARGIN_BLOCK_START, P.P_MARGIN_BLOCK_END];
  if (prop === "margin-inline") return [P.P_MARGIN_INLINE_START, P.P_MARGIN_INLINE_END];
  if (prop === "padding-block") return [P.P_PADDING_BLOCK_START, P.P_PADDING_BLOCK_END];
  if (prop === "padding-inline") return [P.P_PADDING_INLINE_START, P.P_PADDING_INLINE_END];
  if (prop === "inset-block") return [P.P_INSET_BLOCK_START, P.P_INSET_BLOCK_END];
  if (prop === "inset-inline") return [P.P_INSET_INLINE_START, P.P_INSET_INLINE_END];
  // A logical border side keeps its own ids too: which physical side it lands on is settled by the
  // element's axes at style time (see resolveLogicalSides in runtime/style.ts).
  const logicalBorder = /^border-(inline|block)(?:-(start|end))?(?:-(width|style|color))?$/.exec(prop);
  if (logicalBorder !== null) {
    const axis = logicalBorder[1] === "block" ? BORDER_BLOCK_SIDES : BORDER_INLINE_SIDES;
    const chosen = logicalBorder[2] === "start" ? [axis[0]] : logicalBorder[2] === "end" ? [axis[1]] : axis;
    const part = logicalBorder[3];
    const out: number[] = [];
    for (const side of chosen) {
      if (part === "width") out.push(side[0]);
      else if (part === "style") out.push(side[1]);
      else if (part === "color") out.push(side[2]);
      else out.push(side[0], side[1], side[2]);
    }
    return out;
  }
  if (prop === "border-width") return SIDE_WIDTH;
  if (prop === "border-style") return SIDE_STYLE;
  if (prop === "border-color") return SIDE_COLOR;
  if (prop === "border") return allBorderSides();
  if (prop.startsWith("border-")) {
    const k = SIDES.indexOf(prop.slice(7));
    if (k >= 0) return [SIDE_WIDTH[k], SIDE_STYLE[k], SIDE_COLOR[k]];
    if (prop === "border-radius") return [...CORNERS, ...CORNERS_Y];
  }
  if (prop === "background") {
    return [P.P_BACKGROUND_COLOR, P.P_BACKGROUND_IMAGE, P.P_BACKGROUND_REPEAT, P.P_BACKGROUND_POSITION,
      P.P_BACKGROUND_SIZE, P.P_BACKGROUND_ORIGIN, P.P_BACKGROUND_CLIP, P.P_BACKGROUND_ATTACHMENT,
      P.P_BACKGROUND_POSITION_X, P.P_BACKGROUND_POSITION_Y];
  }
  if (prop === "overflow") return [P.P_OVERFLOW_X, P.P_OVERFLOW_Y];
  if (prop === "overflow-x") return [P.P_OVERFLOW_X];
  if (prop === "overflow-y") return [P.P_OVERFLOW_Y];
  if (prop === "gap" || prop === "grid-gap") return [P.P_ROW_GAP, P.P_COLUMN_GAP];
  if (prop === "place-content") return [P.P_ALIGN_CONTENT, P.P_JUSTIFY_CONTENT];
  if (prop === "place-items") return [P.P_ALIGN_ITEMS, P.P_JUSTIFY_ITEMS];
  if (prop === "place-self") return [P.P_ALIGN_SELF, P.P_JUSTIFY_SELF];
  if (prop === "grid") {
    return [P.P_GRID_TEMPLATE_ROWS, P.P_GRID_TEMPLATE_COLUMNS, P.P_GRID_TEMPLATE_AREAS,
      P.P_GRID_AUTO_ROWS, P.P_GRID_AUTO_COLUMNS, P.P_GRID_AUTO_FLOW];
  }
  if (prop === "grid-template") return [P.P_GRID_TEMPLATE_ROWS, P.P_GRID_TEMPLATE_COLUMNS, P.P_GRID_TEMPLATE_AREAS];
  if (prop === "flex") return [P.P_FLEX_GROW, P.P_FLEX_SHRINK, P.P_FLEX_BASIS];
  if (prop === "flex-flow") return [P.P_FLEX_DIRECTION, P.P_FLEX_WRAP];
  if (prop === "list-style") return [P.P_LIST_STYLE_TYPE, P.P_LIST_STYLE_POSITION, P.P_LIST_STYLE_IMAGE];
  if (prop === "outline") return [P.P_OUTLINE_STYLE, P.P_OUTLINE_WIDTH, P.P_OUTLINE_COLOR];
  if (prop === "text-decoration") {
    return [P.P_TEXT_DECORATION, P.P_TEXT_DECORATION_STYLE, P.P_TEXT_DECORATION_COLOR, P.P_TEXT_DECORATION_THICKNESS];
  }
  if (prop === "text-emphasis") return [P.P_TEXT_EMPHASIS_STYLE, P.P_TEXT_EMPHASIS_COLOR];
  if (prop === "container") return [P.P_CONTAINER_NAME, P.P_CONTAINER_TYPE];
  if (prop === "text-wrap") return [P.P_TEXT_WRAP_MODE, P.P_TEXT_WRAP_STYLE];
  // `font` sets the five font longhands.
  if (prop === "font") return [P.P_FONT_SIZE, P.P_FONT_WEIGHT, P.P_LINE_HEIGHT, P.P_FONT_STYLE, P.P_FONT_FAMILY];
  if (prop === "font-variant") {
    return [P.P_FONT_VARIANT_CAPS, P.P_FONT_VARIANT_LIGATURES, P.P_FONT_VARIANT_NUMERIC,
      P.P_FONT_VARIANT_EAST_ASIAN, P.P_FONT_VARIANT_POSITION, P.P_FONT_VARIANT_ALTERNATES];
  }
  return null;
}

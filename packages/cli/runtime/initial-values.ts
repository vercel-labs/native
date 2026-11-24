// The initial and inherited tables every computed style starts from: the value and unit each
// property takes before any declaration, and whether it inherits. The animation engine reads them
// for a keyframe that names a CSS-wide keyword.

import * as P from "../shared/props.ts";

export const INITIAL_V: number[] = [];
export const INITIAL_U: number[] = [];
export const INHERITS: boolean[] = [];

function initTables(): void {
  for (let i = 0; i < P.PROP_COUNT; i++) {
    INITIAL_V.push(0);
    INITIAL_U.push(P.U_NONE);
    INHERITS.push(false);
  }
  const set = (p: number, v: number, u: number) => {
    INITIAL_V[p] = v;
    INITIAL_U[p] = u;
  };
  set(P.P_DISPLAY, P.D_BLOCK, P.U_NONE);
  set(P.P_VISIBILITY, P.VIS_VISIBLE, P.U_NONE);
  set(P.P_SCROLL_MARKER_GROUP, P.SG_NONE, P.U_NONE);
  set(P.P_GRID_LANES_DIRECTION, 0, P.U_AUTO);
  set(P.P_GRID_LANES_PACK, 0, P.U_NONE);
  set(P.P_FIT_TOLERANCE, 0, P.U_NORMAL);
  set(P.P_BREAK_BEFORE, P.BK_AUTO, P.U_NONE);
  set(P.P_BREAK_AFTER, P.BK_AUTO, P.U_NONE);
  set(P.P_BREAK_INSIDE, P.BK_AUTO, P.U_NONE);
  set(P.P_ORPHANS, 2, P.U_NONE);
  set(P.P_WIDOWS, 2, P.U_NONE);
  set(P.P_PRINT_COLOR_ADJUST, P.PCA_ECONOMY, P.U_NONE);
  set(P.P_PAGE, -1, P.U_LIST);
  set(P.P_COLUMN_COUNT, 0, P.U_AUTO);
  set(P.P_COLUMN_WIDTH, 0, P.U_AUTO);
  set(P.P_COLUMN_FILL, P.CF_BALANCE, P.U_NONE);
  set(P.P_COLUMN_SPAN, P.CS_NONE, P.U_NONE);
  set(P.P_COLUMN_RULE_WIDTH, 3, P.U_PX);
  set(P.P_COLUMN_RULE_STYLE, P.BRS_NONE, P.U_NONE);
  set(P.P_COLUMN_RULE_COLOR, -1, P.U_NONE);
  set(P.P_COLUMN_HEIGHT, 0, P.U_AUTO);
  set(P.P_COLUMN_WRAP, 0, P.U_NONE);
  set(P.P_FONT_SYNTHESIS, P.FSYNTH_ALL, P.U_NONE);  set(P.P_FONT_KERNING, P.FKERN_AUTO, P.U_NONE);
  set(P.P_FONT_LANGUAGE_OVERRIDE, 0, P.U_NONE);
  set(P.P_FONT_OPTICAL_SIZING, P.FOPSZ_AUTO, P.U_NONE);
  set(P.P_FONT_SIZE_ADJUST, -1, P.U_NONE);
  set(P.P_FONT_STRETCH, 100, P.U_NONE);
  set(P.P_FONT_SYNTHESIS_WEIGHT, P.FSYNTH_AUTO, P.U_NONE);
  set(P.P_FONT_SYNTHESIS_STYLE, P.FSYNTH_AUTO, P.U_NONE);
  set(P.P_FONT_SYNTHESIS_SMALL_CAPS, P.FSYNTH_AUTO, P.U_NONE);
  set(P.P_FONT_VARIANT_EMOJI, P.FVE_NORMAL, P.U_NONE);
  set(P.P_TEXT_UNDERLINE_POSITION, P.TUP_AUTO, P.U_NONE);
  set(P.P_TEXT_DECORATION_SKIP_INK, P.TDSI_AUTO, P.U_NONE);
  set(P.P_WHITE_SPACE_COLLAPSE, P.WSC_COLLAPSE, P.U_NONE);
  set(P.P_TEXT_BOX_TRIM, P.TBT_NONE, P.U_NONE);
  set(P.P_TEXT_BOX_EDGE, P.TBE_AUTO * 16 + P.TBE_AUTO, P.U_NONE);
  set(P.P_ALIGNMENT_BASELINE, P.AB_AUTO, P.U_NONE);
  set(P.P_DOMINANT_BASELINE, P.AB_AUTO, P.U_NONE);
  set(P.P_BASELINE_SHIFT, P.BS_BASELINE, P.U_NONE);

  set(P.P_TEXT_EMPHASIS_COLOR, -1, P.U_NONE);
  set(P.P_ALIGN_ITEMS, P.A_NORMAL, P.U_NONE);
  set(P.P_ALIGN_SELF, P.A_AUTO, P.U_NONE);
  set(P.P_FLEX_SHRINK, 1, P.U_NONE);
  set(P.P_FLEX_BASIS, 0, P.U_AUTO);
  set(P.P_FLEX_WRAP, P.FW_NOWRAP, P.U_NONE);
  set(P.P_ALIGN_CONTENT, P.AC_NORMAL, P.U_NONE);
  set(P.P_JUSTIFY_CONTENT, P.J_NORMAL, P.U_NONE);
  set(P.P_ORDER, 0, P.U_NONE);
  // Grid: no tracks until a template names one, auto-placement in rows, and items stretch.
  set(P.P_GRID_TEMPLATE_COLUMNS, -1, P.U_LIST);
  set(P.P_GRID_TEMPLATE_ROWS, -1, P.U_LIST);
  set(P.P_GRID_AUTO_COLUMNS, -1, P.U_LIST);
  set(P.P_GRID_AUTO_ROWS, -1, P.U_LIST);
  set(P.P_GRID_AUTO_FLOW, P.GF_ROW, P.U_NONE);
  set(P.P_GRID_TEMPLATE_AREAS, -1, P.U_LIST);
  set(P.P_GRID_COLUMN_START, 0, P.U_AUTO);
  set(P.P_GRID_COLUMN_END, 0, P.U_AUTO);
  set(P.P_GRID_ROW_START, 0, P.U_AUTO);
  set(P.P_GRID_ROW_END, 0, P.U_AUTO);
  set(P.P_JUSTIFY_ITEMS, P.A_NORMAL, P.U_NONE);
  set(P.P_JUSTIFY_SELF, P.A_AUTO, P.U_NONE);
  set(P.P_WIDTH, 0, P.U_AUTO);
  set(P.P_HEIGHT, 0, P.U_AUTO);
  set(P.P_MAX_WIDTH, 0, P.U_AUTO);
  set(P.P_MAX_HEIGHT, 0, P.U_AUTO);
  // A scrollbar colour starts at `auto`: -1 in both slots, which paints the platform's grey.
  set(P.P_SCROLLBAR_COLOR, -1, P.U_NONE);
  set(P.P_SCROLLBAR_COLOR_TRACK, -1, P.U_NONE);
  // A gap starts at `normal`: no gutter for a grid or flex container, an em for a multicol one,
  // and the parent's gutters for a subgrid — an explicit `0` is a gutter of its own.
  set(P.P_ROW_GAP, 0, P.U_NORMAL);
  set(P.P_COLUMN_GAP, 0, P.U_NORMAL);
  for (const p of [P.P_MARGIN_TOP, P.P_MARGIN_RIGHT, P.P_MARGIN_BOTTOM, P.P_MARGIN_LEFT, P.P_PADDING_TOP,
    P.P_PADDING_RIGHT, P.P_PADDING_BOTTOM, P.P_PADDING_LEFT,
    P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS,
    P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS, P.P_BORDER_TOP_LEFT_RADIUS_Y,
    P.P_BORDER_TOP_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y,
    P.P_SCROLL_MARGIN_TOP, P.P_SCROLL_MARGIN_RIGHT, P.P_SCROLL_MARGIN_BOTTOM, P.P_SCROLL_MARGIN_LEFT,
    P.P_SCROLL_PADDING_TOP, P.P_SCROLL_PADDING_RIGHT, P.P_SCROLL_PADDING_BOTTOM,
    P.P_SCROLL_PADDING_LEFT]) set(p, 0, P.U_PX);
  // A border width starts at medium, as CSS says; it is used only once the side has a style, so
  // a border is still invisible until one is set (see the used-width zeroing in computeStyles).
  for (const p of [P.P_BORDER_TOP_WIDTH, P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_BOTTOM_WIDTH,
    P.P_BORDER_LEFT_WIDTH]) set(p, 3, P.U_PX);
  set(P.P_MIN_WIDTH, 0, P.U_AUTO);
  set(P.P_MIN_HEIGHT, 0, P.U_AUTO);
  // -1 = currentColor
  for (const p of [P.P_BORDER_TOP_COLOR, P.P_BORDER_RIGHT_COLOR, P.P_BORDER_BOTTOM_COLOR, P.P_BORDER_LEFT_COLOR]) {
    set(p, -1, P.U_NONE);
  }
  set(P.P_BACKGROUND_COLOR, 0, P.U_NONE);
  set(P.P_OBJECT_FIT, P.OF_FILL, P.U_NONE);
  // -1 is the initial 50% 50% position, which needs no row.
  set(P.P_OBJECT_POSITION, -1, P.U_LIST);
  set(P.P_IMAGE_RENDERING, P.IR_AUTO, P.U_NONE);
  set(P.P_IMAGE_ORIENTATION, P.IO_FROM_IMAGE, P.U_NONE);
  // -1 is "no list": the initial value of every background layer longhand.
  for (const p of [P.P_BACKGROUND_IMAGE, P.P_BACKGROUND_REPEAT, P.P_BACKGROUND_POSITION,
    P.P_BACKGROUND_SIZE, P.P_BACKGROUND_ORIGIN, P.P_BACKGROUND_CLIP, P.P_BACKGROUND_ATTACHMENT,
    P.P_BACKGROUND_POSITION_X, P.P_BACKGROUND_POSITION_Y]) set(p, -1, P.U_LIST);
  set(P.P_BOX_SHADOW, -1, P.U_LIST);
  // border-image: -1 is `none`, and -1 in the longhand rows is "no row", whose defaults the
  // painter supplies (a 100% slice, auto widths, no outset, stretch everywhere).
  set(P.P_BORDER_IMAGE_SOURCE, -1, P.U_NONE);
  for (const p of [P.P_BORDER_IMAGE_SLICE, P.P_BORDER_IMAGE_WIDTH, P.P_BORDER_IMAGE_OUTSET,
    P.P_BORDER_IMAGE_REPEAT]) set(p, -1, P.U_LIST);
  set(P.P_COLOR, 0x000000ff, P.U_NONE);
  set(P.P_FONT_SIZE, 0, P.U_MEDIUM);
  // The root's size is `medium`, so it rests on the family's medium size.
  set(P.P_MEDIUM_BASED, 1, P.U_NONE);
  set(P.P_FONT_WEIGHT, 400, P.U_NONE);
  set(P.P_LINE_HEIGHT, 0, P.U_NORMAL);
  set(P.P_OPACITY, 1, P.U_NONE);
  // No filter list, no blending, and no isolation of its own.
  set(P.P_FILTER, -1, P.U_NONE);
  set(P.P_BACKDROP_FILTER, -1, P.U_NONE);
  set(P.P_MIX_BLEND_MODE, P.MB_NORMAL, P.U_NONE);
  set(P.P_ISOLATION, P.ISO_AUTO, P.U_NONE);
  set(P.P_CLIP_PATH, -1, P.U_NONE);
  set(P.P_MASK_IMAGE, -1, P.U_NONE);
  set(P.P_POSITION, P.POS_STATIC, P.U_NONE);
  set(P.P_Z_INDEX, 0, P.U_AUTO);
  // Chrome's initial family is the standard font setting, which is Times (serif) on the desktop
  // unless the user changes it: an unstyled page draws in serif text, not the system sans.
  set(P.P_FONT_FAMILY, P.FF_SERIF, P.U_NONE);
  set(P.P_WHITE_SPACE, P.W_NORMAL, P.U_NONE);
  // `start` is the initial alignment, so a block's text begins at the side its direction names.
  set(P.P_TEXT_ALIGN, P.T_START, P.U_NONE);
  set(P.P_TEXT_TRANSFORM, P.TT_NONE, P.U_NONE);
  set(P.P_LETTER_SPACING, 0, P.U_NORMAL);
  set(P.P_WORD_SPACING, 0, P.U_NORMAL);
  set(P.P_TEXT_INDENT, 0, P.U_PX);
  set(P.P_TAB_SIZE, 8, P.U_NONE);
  set(P.P_TEXT_OVERFLOW, P.TO_CLIP, P.U_NONE);
  set(P.P_TEXT_DECORATION, P.TD_NONE, P.U_NONE);
  // -1 is currentColor, the initial decoration colour.
  set(P.P_TEXT_DECORATION_STYLE, P.TDS_SOLID, P.U_NONE);
  set(P.P_TEXT_DECORATION_COLOR, -1, P.U_NONE);
  set(P.P_TEXT_DECORATION_THICKNESS, 0, P.U_AUTO);
  set(P.P_UNDERLINE_OFFSET, 0, P.U_AUTO);
  set(P.P_OVERFLOW_WRAP, P.OW_NORMAL, P.U_NONE);
  // overflow-clip-margin starts as `0px`: the padding box, not grown.
  set(P.P_OVERFLOW_CLIP_MARGIN, -1, P.U_LIST);
  set(P.P_WORD_BREAK, P.WB_NORMAL, P.U_NONE);
  set(P.P_SCROLL_BEHAVIOR, P.SB_AUTO, P.U_NONE);
  set(P.P_SCROLL_SNAP_TYPE, P.SST_NONE, P.U_NONE);
  // transform-box starts at view-box, as CSS Transforms 1 says. For a CSS layout box that is its
  // border box, so nothing about an HTML box changes; an SVG element resolves the same value
  // against the viewport its user space is measured in.
  set(P.P_TRANSFORM_BOX, P.TB_VIEW_BOX, P.U_NONE);
  set(P.P_APPEARANCE, P.AP_AUTO, P.U_NONE);
  // -1 is `auto`: the UA's own accent colour.
  set(P.P_ACCENT_COLOR, -1, P.U_NONE);
  // -1 is `auto`: the caret is drawn in the field's own text colour.
  set(P.P_CARET_COLOR, -1, P.U_NONE);
  set(P.P_POINTER_EVENTS, P.PTR_AUTO, P.U_NONE);
  set(P.P_USER_SELECT, P.US_AUTO, P.U_NONE);
  set(P.P_HYPHENS, P.HY_MANUAL, P.U_NONE);
  set(P.P_TEXT_WRAP_MODE, P.TWM_WRAP, P.U_NONE);
  set(P.P_TEXT_WRAP_STYLE, P.TWS_AUTO, P.U_NONE);
  set(P.P_DIRECTION, P.DIR_LTR, P.U_NONE);
  set(P.P_WRITING_MODE, P.WM_HORIZONTAL_TB, P.U_NONE);
  set(P.P_TEXT_SHADOW, -1, P.U_LIST);
  // text-decoration-inset starts as auto at both ends: a length the line metrics choose.
  set(P.P_TEXT_DECORATION_INSET, 0, P.U_AUTO);
  set(P.P_TEXT_DECORATION_INSET_END, 0, P.U_AUTO);
  // aspect-ratio starts as `auto`: a replaced element keeps its own ratio, and nothing else has one.
  set(P.P_ASPECT_RATIO, 0, P.U_NONE);
  set(P.P_ASPECT_RATIO_AUTO, 1, P.U_NONE);
  // Transition and animation lists start unset; -1 with unit U_NONE stands for each property's
  // initial value (see initialItem() in shared/css/anim.ts).
  for (const p of [P.P_TRANSITION_PROPERTY, P.P_TRANSITION_DURATION, P.P_TRANSITION_TIMING_FUNCTION,
    P.P_TRANSITION_DELAY, P.P_TRANSITION_BEHAVIOR, P.P_ANIMATION_NAME, P.P_ANIMATION_DURATION, P.P_ANIMATION_TIMING_FUNCTION,
    P.P_ANIMATION_DELAY, P.P_ANIMATION_ITERATION_COUNT, P.P_ANIMATION_DIRECTION,
    P.P_ANIMATION_FILL_MODE, P.P_ANIMATION_PLAY_STATE]) set(p, -1, P.U_NONE);
  set(P.P_TABLE_LAYOUT, P.TL_AUTO, P.U_NONE);
  set(P.P_BORDER_COLLAPSE, P.BC_SEPARATE, P.U_NONE);
  set(P.P_BORDER_SPACING_H, 0, P.U_PX);
  set(P.P_BORDER_SPACING_V, 0, P.U_PX);
  set(P.P_CAPTION_SIDE, P.CS_TOP, P.U_NONE);
  set(P.P_VERTICAL_ALIGN, P.VA_BASELINE, P.U_NONE);
  set(P.P_EMPTY_CELLS, P.EC_SHOW, P.U_NONE);
  // The initial `content: normal` generates nothing; `none` hides a pseudo-element.
  set(P.P_CONTENT, P.CONTENT_NORMAL, P.U_NONE);
  set(P.P_LIST_STYLE_TYPE, P.LST_DISC, P.U_NONE);
  set(P.P_LIST_STYLE_POSITION, P.LSP_OUTSIDE, P.U_NONE);
  set(P.P_LIST_STYLE_IMAGE, 0, P.U_AUTO);
  // An outline is off until its style says otherwise; its width is `medium`, its color the text
  // color, which the -1 sentinel stands for.
  set(P.P_OUTLINE_STYLE, P.OLS_NONE, P.U_NONE);
  set(P.P_OUTLINE_WIDTH, 3, P.U_PX);
  set(P.P_OUTLINE_COLOR, -1, P.U_NONE);
  set(P.P_OUTLINE_OFFSET, 0, P.U_PX);
  // SVG paint: a black fill, no stroke, a one-pixel pen with butt caps and miter joins, and the
  // nonzero fill rule. `color` is already initialised, and `currentColor` resolves against it.
  set(P.P_FILL, 0x000000ff, P.U_NONE);
  set(P.P_STROKE, P.PAINT_NONE, P.U_NONE);
  set(P.P_FILL_OPACITY, 1, P.U_NONE);
  // The SVG filter properties: auto interpolation, a black flood, no light's colour named yet.
  set(P.P_COLOR_INTERPOLATION_FILTERS, P.ICF_AUTO, P.U_NONE);
  set(P.P_FLOOD_COLOR, 0x000000ff, P.U_NONE);
  set(P.P_FLOOD_OPACITY, 1, P.U_NONE);
  set(P.P_LIGHTING_COLOR, 0xffffffff, P.U_NONE);
  set(P.P_WILL_CHANGE, -1, P.U_LIST);
  set(P.P_SHAPE_IMAGE_THRESHOLD, 0, P.U_NONE);
  set(P.P_BACKGROUND_BLEND_MODE, P.MB_NORMAL, P.U_NONE);
  set(P.P_PERSPECTIVE, -1, P.U_NONE);
  set(P.P_PERSPECTIVE_ORIGIN, -1, P.U_LIST);
  set(P.P_BACKFACE_VISIBILITY, P.BFV_VISIBLE, P.U_NONE);
  set(P.P_STROKE_OPACITY, 1, P.U_NONE);
  set(P.P_STROKE_WIDTH, 1, P.U_PX);
  set(P.P_STROKE_LINECAP, P.SLC_BUTT, P.U_NONE);
  set(P.P_STROKE_LINEJOIN, P.SLJ_MITER, P.U_NONE);
  set(P.P_FILL_RULE, P.FR_NONZERO, P.U_NONE);
  set(P.P_STROKE_DASHARRAY, -1, P.U_NONE);
  set(P.P_STROKE_DASHOFFSET, 0, P.U_PX);
  // Container queries: an element is no container until it says so, and names none.
  set(P.P_SHAPE_OUTSIDE, -1, P.U_NONE);
  set(P.P_SHAPE_MARGIN, 0, P.U_PX);
  set(P.P_CONTAINER_TYPE, P.CT_NORMAL, P.U_NONE);
  set(P.P_CONTAINER_NAME, -1, P.U_NONE);
  // No counters until a declaration names one (an id into the app's counter lists).
  set(P.P_COUNTER_RESET, -1, P.U_NONE);
  set(P.P_COUNTER_INCREMENT, -1, P.U_NONE);
  set(P.P_COUNTER_SET, -1, P.U_NONE);
  set(P.P_TOP, 0, P.U_AUTO);
  set(P.P_RIGHT, 0, P.U_AUTO);
  set(P.P_BOTTOM, 0, P.U_AUTO);
  set(P.P_LEFT, 0, P.U_AUTO);
  for (const p of P.INHERITED) INHERITS[p] = true;
}
initTables();

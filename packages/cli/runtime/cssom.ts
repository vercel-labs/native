// The inline style object (el.style and the style="" attribute) and getComputedStyle, as a
// subset of CSSStyleDeclaration. Values are parsed with the compiler's own value parser
// (shared/css/), so a script-set declaration and a style attribute compile alike.

import { document, Element, Node, ShadowRoot } from "./dom.ts";
import { highlights } from "./highlights.ts";
import * as P from "../shared/props.ts";
import { WC_LIST_AUTO, WC_LIST_CONTENTS, WC_LIST_SCROLL_POSITION, willChangeRows } from "../shared/css/willchange.ts";
import { BORDER_STYLES } from "../shared/css/borders.ts";
import { contentCss } from "../shared/css/content.ts";
import { compileValue, parseDeclarationBlock } from "../shared/css/declarations.ts";
import { canonicalSystemColors, hasDeferredCurrentColor, hasLightDark, hasModernColor, hasTextImage, withSystemColors } from "../shared/css/colors.ts";
import { longhandIds } from "../shared/css/shorthands.ts";
import { clipPathText } from "../shared/css/clip-path.ts";
import { parseCounterStyle } from "../shared/css/counter-styles.ts";
import { customPropertyName, hasVar, validDeclarationValue } from "../shared/css/vars.ts";
import { registerCustomProperty, registeredProperty } from "./registered.ts";
import { GENERIC_FAMILIES } from "../shared/css/types.ts";
import type { Decl, FontContext } from "../shared/css/types.ts";
import { dirty, invalidateStyle, invalidateStyleOf } from "./invalidation.ts";
import { animationTick } from "./animation.ts";
import { flushLayoutHook } from "./layout-flush-hook.ts";
import {
  computeStyles, featureSpec, logicalPhysicalProp, paletteName, registerFeatureSpec, registerPaletteName,
  registerVariationSpec, tables, variationSpec,
} from "./style.ts";
import { inlineImageId } from "./images.ts";
import { backgroundAxisText, bg, registerGradient, registerRow, rowOf } from "./background.ts";
import { clipText } from "../shared/css/clip.ts";
import { positionText } from "../shared/css/position.ts";
import { dashText } from "../shared/css/dasharray.ts";
import { exprText } from "../shared/css/length-exprs.ts";
import { clipMarginRows } from "../shared/css/properties/box.ts";
import { viewport } from "./viewport.ts";
import { rowLength } from "./layout/box-model.ts";
import { registerShadow, shadowList } from "./shadows.ts";
import { areaList, lineNamesText, nameText, placementRow, registerAreaList, registerPlacement, registerTrackList, registerTrackName, trackList } from "./grid.ts";
import type { TrackSize } from "./grid.ts";
import { registerBorderImageRow } from "./border-image.ts";
import { paintUrlAt, registerPaintUrl } from "./svg-paint.ts";
import { filterList, registerFilter } from "./filters.ts";
import { listCss, lengthText as sharedLengthText, originRows, transformRows } from "../shared/css/transforms.ts";
import { hasTransform, individualCss, originCss, transformCss } from "./transform.ts";
import { getSheetContent, setSheetFonts } from "./sheets.ts";
import { setHintFonts } from "./hints.ts";
import { ANIMATION_LONGHANDS, TRANSITION_LONGHANDS, animValueText, itemText, valueList } from "../shared/css/anim.ts";

/** One declaration held by el.style: the property it sets, and its value and unit. */
export interface InlineDecl {
  p: number;
  v: number;
  u: number;
  important: boolean;
  /**
   * Set instead of a value for a declaration kept as text: a custom property (--x), or a value
   * that uses var(). `p` is -1 there, and the declaration is compiled when the element's style
   * is computed (see runtime/style.ts).
   */
  prop?: string;
  value?: string;
}

/**
 * Font family lookup for a value parsed at runtime: the generic families, then @font-face ones,
 * then the families the build left to the system, which the host opened by name on mount.
 */
class RuntimeFonts {
  family(name: string): number {
    const generic = GENERIC_FAMILIES[name];
    if (generic !== undefined) return generic;
    const i = tables.fontFamilies.indexOf(name);
    if (i >= 0) return P.FF_CUSTOM + i;
    const named = tables.fontInstalledFamilies.indexOf(name);
    if (named >= 0) return P.FF_CUSTOM + tables.fontFamilies.length + named;
    // A family this page never named: it can still be one the system has, but the host has not
    // opened it, so the text falls back to the system font as an unknown family does.
    return P.FF_SYSTEM;
  }

  // A family name the build didn't know may be one the system has, so a list keeps it rather
  // than dropping through to the next one; a missing face falls back when the text is drawn.
  available(name: string): boolean {
    return name !== "";
  }

  /**
   * An image URL is resolved at build time, against the page the style attribute is written in;
   * the runtime has no build directory, so it looks the URL up in the table of URLs the compiler
   * recorded. A URL that isn't there (one a script invented) has no image.
   */
  image(url: string, _line: number, _col: number): number {
    return inlineImageId(url);
  }

  background(kind: number, row: number[]): number {
    return registerRow(kind, row);
  }

  /** A gradient an inline style names is registered with the paint code, like its layer rows,
   *  with its text so CSSOM can read the image back. */
  gradient(encoded: string, source: string = ""): number {
    return registerGradient(encoded, source);
  }

  /**
   * A feature or variation list is registered with the app's font runs, so a value that only
   * comes together when its var() is substituted still reaches the host.
   */
  features(spec: string): number {
    return registerFeatureSpec(spec);
  }

  variations(spec: string): number {
    return registerVariationSpec(spec);
  }

  /** A palette name an inline or script-set value uses; a name with no rule still gets an id. */
  palette(name: string): number {
    return registerPaletteName(name);
  }

  /** The row of a font-family list's ids, registering it like a build-time list. */
  familyList(ids: number[]): number {
    const key = ids.join(",");
    const at = tables.fontFamilyLists.indexOf(key);
    if (at >= 0) return at;
    tables.fontFamilyLists.push(key);
    return tables.fontFamilyLists.length - 1;
  }

  shadow(row: number[]): number {
    return registerShadow(row);
  }

  borderImage(row: number[]): number {
    return registerBorderImageRow(row);
  }

  /** A paint server a fill/stroke names: the table of them grows with each new id. */
  paint(url: string): number {
    return registerPaintUrl(url);
  }

  tracks(row: number[]): number {
    return registerTrackList(row);
  }

  /** A container name list joins the table the build filled, as a runtime sheet's content does. */
  containerNames(list: string): number {
    const i = tables.containerNames.indexOf(list);
    if (i >= 0) return i;
    tables.containerNames.push(list);
    return tables.containerNames.length - 1;
  }

  trackName(name: string): number {
    return registerTrackName(name);
  }

  placement(row: number[]): number {
    return registerPlacement(row);
  }

  areaList(row: number[]): number {
    return registerAreaList(row);
  }

  filter(row: number[]): number {
    return registerFilter(row);
  }
}

const fonts: FontContext = new RuntimeFonts();
// Runtime style sheets and presentation-attribute hints parse their values with the same font and
// image contexts inline styles use.
setSheetFonts(fonts);
setHintFonts(fonts);

// ---------------------------------------------------------------------------
// Serializing a numeric value back to CSS

const DISPLAY_NAMES = ["block", "flex", "none", "inline-block", "inline", "inline-flex", "table", "inline-table",
  "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell", "table-column-group",
  "table-column", "table-caption", "list-item", "grid", "inline-grid", "grid-lanes", "inline-grid-lanes",
  "flow-root", "contents"];
const AUTO_FLOW_NAMES = ["row", "column", "row dense", "column dense"];
const OBJECT_FIT_NAMES = ["fill", "contain", "cover", "none", "scale-down"];
const IMAGE_RENDERING_NAMES = ["auto", "pixelated", "crisp-edges"];
const APP_REGION_NAMES = ["none", "drag", "no-drag"];
const IMAGE_ORIENTATION_NAMES = ["from-image", "none"];
const LIST_STYLE_TYPE_NAMES = ["disc", "circle", "square", "decimal", "decimal-leading-zero", "lower-alpha",
  "upper-alpha", "lower-roman", "upper-roman", "none"];
const LIST_STYLE_POSITION_NAMES = ["outside", "inside"];
const OUTLINE_STYLE_NAMES = ["none", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset", "auto"];
const FLEX_DIRECTION_NAMES = ["row", "column", "row-reverse", "column-reverse"];
const FLEX_WRAP_NAMES = ["nowrap", "wrap", "wrap-reverse"];
// align-content and justify-content share the ids of the packings; the empty slots are the
// keywords that only the other property takes.
const ALIGN_CONTENT_NAMES = ["start", "center", "end", "space-between", "space-around", "space-evenly", "stretch",
  "", "", "flex-start", "flex-end", "", "normal", "baseline", "last baseline"];
const JUSTIFY_NAMES = ["start", "center", "end", "space-between", "space-around", "space-evenly",
  "normal", "left", "right", "flex-start", "flex-end", "stretch", "", "baseline", "last baseline"];
const ALIGN_NAMES = ["stretch", "start", "center", "end", "auto", "normal", "self-start", "self-end",
  "left", "right", "flex-start", "flex-end", "baseline", "last baseline"];
const TEXT_ALIGN_NAMES = ["left", "center", "right", "start", "end", "justify"];
const TEXT_JUSTIFY_NAMES = ["auto", "inter-word", "inter-character", "none"];
const DIRECTION_NAMES = ["ltr", "rtl"];
const TEXT_ORIENTATION_NAMES = ["mixed", "upright", "sideways"];
const LINE_BREAK_NAMES = ["auto", "loose", "normal", "strict", "anywhere"];
const WRITING_MODE_NAMES = ["horizontal-tb", "vertical-rl", "vertical-lr", "sideways-rl", "sideways-lr"];
const CURSOR_NAMES = ["default", "pointer", "text", "context-menu", "help", "progress", "wait", "cell",
  "crosshair", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab", "grabbing",
  "all-scroll", "col-resize", "row-resize", "n-resize", "e-resize", "s-resize", "w-resize",
  "ne-resize", "nw-resize", "se-resize", "sw-resize", "ew-resize", "ns-resize", "nesw-resize",
  "nwse-resize", "zoom-in", "zoom-out"];
const OVERFLOW_NAMES = ["visible", "hidden", "auto", "scroll", "clip"];
const OVERSCROLL_NAMES = ["auto", "contain", "none"];
const SCROLLBAR_GUTTER_NAMES = ["auto", "stable", "stable both-edges"];
const SCROLLBAR_WIDTH_NAMES = ["auto", "thin", "none"];
const SNAP_ALIGN_NAMES = ["none", "start", "end", "center"];
const SNAP_STOP_NAMES = ["normal", "always"];
const CONTENT_VISIBILITY_NAMES = ["visible", "auto", "hidden"];
const BOX_DECORATION_BREAK_NAMES = ["slice", "clone"];
const BOX_SIZING_NAMES = ["content-box", "border-box"];
const POSITION_NAMES = ["static", "relative", "absolute", "fixed", "sticky"];
const WHITE_SPACE_NAMES = ["normal", "nowrap", "pre", "pre-wrap", "pre-line", "break-spaces"];
const TEXT_TRANSFORM_NAMES = ["none", "uppercase", "lowercase", "capitalize"];
const TEXT_OVERFLOW_NAMES = ["clip", "ellipsis"];
const OVERFLOW_WRAP_NAMES = ["normal", "break-word", "anywhere"];
const WORD_BREAK_NAMES = ["normal", "break-all", "keep-all", "break-word"];
const SCROLL_BEHAVIOR_NAMES = ["auto", "smooth"];
const HYPHENS_NAMES = ["none", "manual", "auto"];
const TEXT_WRAP_MODE_NAMES = ["wrap", "nowrap"];
const TEXT_WRAP_STYLE_NAMES = ["auto", "balance", "pretty", "stable"];
const DECORATION_STYLE_NAMES = ["solid", "double", "dotted", "dashed", "wavy"];
const EMPHASIS_STYLE_NAMES = ["none", "dot", "open dot", "circle", "open circle", "double-circle",
  "open double-circle", "triangle", "open triangle", "sesame", "open sesame"];
const EMPHASIS_POSITION_NAMES = ["over", "over left", "under", "under left"];
const FONT_STYLE_NAMES = ["normal", "italic"];
const VERTICAL_ALIGN_NAMES = ["baseline", "sub", "super", "text-top", "text-bottom", "middle", "top", "bottom"];
const FLOAT_NAMES = ["none", "left", "right"];
const MIX_BLEND_NAMES = ["normal", "multiply", "screen", "overlay", "darken", "lighten", "color-dodge",
  "color-burn", "hard-light", "soft-light", "difference", "exclusion", "hue", "saturation", "color",
  "luminosity", "plus-lighter"];
const ISOLATION_NAMES = ["auto", "isolate"];
const CLEAR_NAMES = ["none", "left", "right", "both"];
const CONTAINER_TYPE_NAMES = ["normal", "size", "inline-size"];

// A corner's horizontal and vertical radius ids, in CSS's corner order, and their property
// names. `border-radius` writes each corner as a pair: "10px" or "10px 20px".
const RADIUS_CORNERS: number[][] = [
  [P.P_BORDER_TOP_LEFT_RADIUS, P.P_BORDER_TOP_LEFT_RADIUS_Y],
  [P.P_BORDER_TOP_RIGHT_RADIUS, P.P_BORDER_TOP_RIGHT_RADIUS_Y],
  [P.P_BORDER_BOTTOM_RIGHT_RADIUS, P.P_BORDER_BOTTOM_RIGHT_RADIUS_Y],
  [P.P_BORDER_BOTTOM_LEFT_RADIUS, P.P_BORDER_BOTTOM_LEFT_RADIUS_Y],
];
// The logical corner names, by the corner formula's index: 0 block-start/inline-start,
// 1 block-start/inline-end, 2 block-end/inline-start, 3 block-end/inline-end.
const LOGICAL_CORNER_NAMES = ["border-start-start-radius", "border-start-end-radius", "border-end-start-radius", "border-end-end-radius"];

const RADIUS_NAMES = ["border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius"];

/** Which corner a radius property belongs to, or -1 when it isn't one. */
function cornerOf(p: number): number {
  for (let k = 0; k < RADIUS_CORNERS.length; k++) {
    if (RADIUS_CORNERS[k][0] === p || RADIUS_CORNERS[k][1] === p) return k;
  }
  return -1;
}

/** Whether a property is a corner's vertical radius, which serializes with its horizontal one. */
function isRadiusY(p: number): boolean {
  for (let k = 0; k < RADIUS_CORNERS.length; k++) if (RADIUS_CORNERS[k][1] === p) return true;
  return false;
}

const VISIBILITY_NAMES = ["visible", "hidden", "collapse"];
const BREAK_NAMES = ["auto", "avoid", "avoid-page", "avoid-column", "avoid-region", "page", "column",
  "region", "left", "right", "recto", "verso"];
const COLUMN_FILL_NAMES = ["auto", "balance", "balance-all"];

/** touch-action's canonical text: the keyword when one stands alone, else the gestures in the
 *  order browsers print them. */
function touchActionText(v: number): string {
  if (v === P.TA_AUTO) return "auto";
  if (v === P.TA_NONE) return "none";
  const pan = P.TA_PAN_LEFT | P.TA_PAN_RIGHT | P.TA_PAN_UP | P.TA_PAN_DOWN;
  if ((v & pan) === pan && (v & P.TA_PINCH_ZOOM) !== 0) return "manipulation";
  const parts: string[] = [];
  const x = v & (P.TA_PAN_LEFT | P.TA_PAN_RIGHT);
  if (x === (P.TA_PAN_LEFT | P.TA_PAN_RIGHT)) parts.push("pan-x");
  else if (x !== 0) parts.push(x === P.TA_PAN_LEFT ? "pan-left" : "pan-right");
  const y = v & (P.TA_PAN_UP | P.TA_PAN_DOWN);
  if (y === (P.TA_PAN_UP | P.TA_PAN_DOWN)) parts.push("pan-y");
  else if (y !== 0) parts.push(y === P.TA_PAN_UP ? "pan-up" : "pan-down");
  if ((v & P.TA_PINCH_ZOOM) !== 0) parts.push("pinch-zoom");
  return parts.join(" ");
}

function keyword(names: string[], v: number): string {
  return v >= 0 && v < names.length ? names[v] : "";
}

/**
 * A font-feature-settings value as CSS writes it: `"liga" 0, "smcp", "tnum"`.
 */
function featureText(id: number): string {
  return listText(featureSpec(id));
}

/** A tag list as CSS writes it: `"wdth" 80, "wght" 700`; `normal` for an empty one. The tags come
 *  back in the alphabet's order, and a value of 1 is the one a tag alone stands for. The list is
 *  stored as `tag=value` pairs joined by semicolons, which the host parses as well. */
function listText(spec: string): string {
  if (spec === "") return "normal";
  const tags: string[] = [];
  const values: string[] = [];
  for (const pair of spec.split(";")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    tags.push(pair.slice(0, eq));
    values.push(pair.slice(eq + 1));
  }
  if (tags.length === 0) return "normal";
  const order: number[] = [];
  for (let i = 0; i < tags.length; i++) order.push(i);
  order.sort((a, b) => (tags[a] < tags[b] ? -1 : tags[a] > tags[b] ? 1 : 0));
  const out: string[] = [];
  for (const i of order) {
    out.push(values[i] === "1" ? '"' + tags[i] + '"' : '"' + tags[i] + '" ' + values[i]);
  }
  return out.join(", ");
}

/** A font-variation-settings value as CSS writes it, from the list the compile stored. */
function variationText(id: number): string {
  return listText(variationSpec(id));
}

/** font-synthesis: the kinds of face the family may draw in, in the order browsers write them. */
function synthesisText(mask: number): string {
  if (mask === 0) return "none";
  if (mask === P.FSYNTH_ALL) return "weight style small-caps";
  const out: string[] = [];
  if ((mask & P.FSYNTH_WEIGHT) !== 0) out.push("weight");
  if ((mask & P.FSYNTH_STYLE) !== 0) out.push("style");
  if ((mask & P.FSYNTH_SMALL_CAPS) !== 0) out.push("small-caps");
  return out.join(" ");
}

const VARIANT_CAPS_NAMES = ["normal", "small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps"];
const VARIANT_POSITION_NAMES = ["normal", "sub", "super"];
const VARIANT_ALTERNATES_NAMES = ["normal", "historical-forms"];

/** font-variant-ligatures: the keywords the mask names, in CSS's order. */
function variantLigaturesText(mask: number): string {
  if (mask === 0) return "normal";
  if (mask === P.FVL_NONE) return "none";
  const out: string[] = [];
  if ((mask & P.FVL_COMMON_ON) !== 0) out.push("common-ligatures");
  else if ((mask & P.FVL_COMMON_OFF) !== 0) out.push("no-common-ligatures");
  if ((mask & P.FVL_DISCRETIONARY_ON) !== 0) out.push("discretionary-ligatures");
  else if ((mask & P.FVL_DISCRETIONARY_OFF) !== 0) out.push("no-discretionary-ligatures");
  if ((mask & P.FVL_HISTORICAL_ON) !== 0) out.push("historical-ligatures");
  else if ((mask & P.FVL_HISTORICAL_OFF) !== 0) out.push("no-historical-ligatures");
  if ((mask & P.FVL_CONTEXTUAL_ON) !== 0) out.push("contextual");
  else if ((mask & P.FVL_CONTEXTUAL_OFF) !== 0) out.push("no-contextual");
  return out.length === 0 ? "normal" : out.join(" ");
}

/** font-variant-numeric: the keywords the mask names, in CSS's order. */
function variantNumericText(mask: number): string {
  if (mask === 0) return "normal";
  const out: string[] = [];
  if ((mask & P.FVN_LINING) !== 0) out.push("lining-nums");
  else if ((mask & P.FVN_OLDSTYLE) !== 0) out.push("oldstyle-nums");
  if ((mask & P.FVN_PROPORTIONAL) !== 0) out.push("proportional-nums");
  else if ((mask & P.FVN_TABULAR) !== 0) out.push("tabular-nums");
  if ((mask & P.FVN_DIAGONAL_FRACTIONS) !== 0) out.push("diagonal-fractions");
  else if ((mask & P.FVN_STACKED_FRACTIONS) !== 0) out.push("stacked-fractions");
  if ((mask & P.FVN_ORDINAL) !== 0) out.push("ordinal");
  if ((mask & P.FVN_SLASHED_ZERO) !== 0) out.push("slashed-zero");
  return out.length === 0 ? "normal" : out.join(" ");
}

/** font-variant-east-asian: the keywords the mask names, in CSS's order. */
function variantEastAsianText(mask: number): string {
  if (mask === 0) return "normal";
  const out: string[] = [];
  if ((mask & P.FVE_JIS78) !== 0) out.push("jis78");
  else if ((mask & P.FVE_JIS83) !== 0) out.push("jis83");
  else if ((mask & P.FVE_JIS90) !== 0) out.push("jis90");
  else if ((mask & P.FVE_JIS04) !== 0) out.push("jis04");
  else if ((mask & P.FVE_SIMPLIFIED) !== 0) out.push("simplified");
  else if ((mask & P.FVE_TRADITIONAL) !== 0) out.push("traditional");
  if ((mask & P.FVE_FULL_WIDTH) !== 0) out.push("full-width");
  else if ((mask & P.FVE_PROPORTIONAL_WIDTH) !== 0) out.push("proportional-width");
  if ((mask & P.FVE_RUBY) !== 0) out.push("ruby");
  return out.length === 0 ? "normal" : out.join(" ");
}

/** The font-stretch keyword a percentage stands for, or the percentage's own text. */
function stretchKeyword(pct: number): string {
  const names: [number, string][] = [
    [50, "ultra-condensed"], [62.5, "extra-condensed"], [75, "condensed"], [87.5, "semi-condensed"],
    [100, "normal"], [112.5, "semi-expanded"], [125, "expanded"], [150, "extra-expanded"], [200, "ultra-expanded"],
  ];
  for (const [v, name] of names) if (v === pct) return name;
  return numberText(pct) + "%";
}

/** A number as CSS writes it: no exponent, and no trailing zeros. */
function numberText(n: number): string {
  const r = Math.round(n * 1000) / 1000;
  return r === 0 ? "0" : String(r);
}

function lengthText(v: number, u: number): string {
  if (u === P.U_PCT) return numberText(v) + "%";
  if (u === P.U_VW) return numberText(v) + "vw";
  if (u === P.U_VH) return numberText(v) + "vh";
  if (u === P.U_EM) return numberText(v) + "em";
  if (u === P.U_REM) return numberText(v) + "rem";
  if (u === P.U_NONE) return numberText(v);
  return numberText(v) + "px";
}

/**
 * overflow-clip-margin as CSS: the visual box, which a padding box leaves out, then the length,
 * which a zero leaves out. With neither to say it is "0px". A computed value resolves em, vw,
 * vh and calc() against the element; a specified one reads as it was written.
 */
function clipMarginCss(el: Node, v: number, u: number, computed: boolean): string {
  let box = P.OCM_PADDING_BOX;
  let lv = 0;
  let lu = P.U_PX;
  if (u === P.U_LIST && v >= 0) {
    const row = clipMarginRows.row(v);
    if (row !== null && row.length >= 3) {
      box = row[0];
      lv = row[1];
      lu = row[2];
    }
  }
  let text = box === P.OCM_CONTENT_BOX ? "content-box" : box === P.OCM_BORDER_BOX ? "border-box" : "";
  if (lv !== 0) {
    let len: string;
    if (!computed) len = sharedLengthText(lv, lu);
    else {
      // em, the viewport units, the cq units and calc() all resolve against this element.
      const px = rowLength(el, lv, lu);
      len = Number.isNaN(px) ? sharedLengthText(lv, P.U_PX) : sharedLengthText(px, P.U_PX);
    }
    text = text === "" ? len : text + " " + len;
  }
  return text === "" ? "0px" : text;
}

/** A packed 0xRRGGBBAA color, as rgb() or rgba(), the way browsers serialize colors. */
export function colorText(c: number): string {
  const r = (c >>> 24) & 255;
  const g = (c >>> 16) & 255;
  const b = (c >>> 8) & 255;
  const a = c & 255;
  if (a === 255) return "rgb(" + String(r) + ", " + String(g) + ", " + String(b) + ")";
  return "rgba(" + String(r) + ", " + String(g) + ", " + String(b) + ", " + numberText(a / 255) + ")";
}

/**
 * A box-alignment keyword. `flex-start` and `flex-end` are flow-relative, so their computed value
 * is the flow one: browsers serialize it as flow-start and flow-end, and keep the flex spelling
 * only in a specified value (CSS Box Alignment 4, CSSOM).
 */
function alignKeyword(names: string[], v: number, flexStart: number, flexEnd: number, computed: boolean): string {
  if (computed && v === flexStart) return "flow-start";
  if (computed && v === flexEnd) return "flow-end";
  return keyword(names, v);
}

function familyText(id: number): string {
  if (id >= P.FF_CUSTOM) {
    const i = id - P.FF_CUSTOM;
    if (i < tables.fontFamilies.length) return tables.fontFamilies[i];
  }
  if (id === P.FF_MONO) return "monospace";
  if (id === P.FF_SERIF) return "serif";
  if (id === P.FF_UI_SERIF) return "ui-serif";
  if (id === P.FF_UI_ROUNDED) return "ui-rounded";
  if (id === P.FF_UI_MONOSPACE) return "ui-monospace";
  if (id === P.FF_SANS) return "sans-serif";
  return "sans-serif";
}

/**
 * A numeric declaration as CSS text. `currentColor` resolves the border color sentinel (-1);
 * pass -1 to serialize it as the keyword, as an inline declaration does.
 */
/** The runtime's reader of a background layer list's text, registered by the mount that brings the
 *  painter and this module together (they can't import each other: style.ts closes the cycle). */
let bgTextHook: ((el: Node, p: number) => string | null) | null = null;

export function setBgTextHook(fn: (el: Node, p: number) => string | null): void {
  bgTextHook = fn;
}

export function valueText(p: number, v: number, u: number, currentColor: number, computed: boolean = false): string {
  if (u === P.U_NORMAL) {
    // Chrome reports word-spacing's `normal` as 0px in the computed value; letter-spacing keeps
    // the keyword.
    if (computed && p === P.P_WORD_SPACING) return "0px";
    return "normal";
  }
  if (u === P.U_AUTO) {
    // The initial max-width, max-height and list-style-image are `none`, which the compiler
    // also stores as auto.
    if (p === P.P_MAX_WIDTH || p === P.P_MAX_HEIGHT || p === P.P_MAX_INLINE_SIZE || p === P.P_MAX_BLOCK_SIZE ||
      p === P.P_LIST_STYLE_IMAGE) return "none";
    if (p === P.P_GRID_LANES_DIRECTION) return "normal";
    return "auto";
  }
  if (u === P.U_FROM_FONT) return "from-font";
  if (u === P.U_STRETCH) return "stretch";
  // An overflow position keeps its keyword in front of the position it modifies.
  if (u === P.U_SAFE) return "safe " + valueText(p, v, P.U_NONE, currentColor, computed);
  if (u === P.U_UNSAFE) return "unsafe " + valueText(p, v, P.U_NONE, currentColor, computed);
  const anim = animValueText(p, v, u);
  if (anim !== null) return anim;
  switch (p) {
    case P.P_DISPLAY: return keyword(DISPLAY_NAMES, v);
    case P.P_VISIBILITY: return keyword(VISIBILITY_NAMES, v);
    case P.P_GRID_LANES_DIRECTION: {
      let t = v & P.GL_ROW ? "row" : "column";
      if (v & P.GL_FILL_REVERSE) t += " fill-reverse";
      if (v & P.GL_TRACK_REVERSE) t += " track-reverse";
      return t;
    }
    case P.P_GRID_LANES_PACK: return v !== 0 ? "dense" : "normal";
    case P.P_BREAK_BEFORE:
    case P.P_BREAK_AFTER: return keyword(BREAK_NAMES, v);
    case P.P_COLUMN_COUNT: return numberText(v);
    case P.P_COLUMN_FILL: return keyword(COLUMN_FILL_NAMES, v);
    case P.P_COLUMN_SPAN: return v === P.CS_ALL ? "all" : "none";
    case P.P_COLUMN_WRAP: return v === P.CW_WRAP ? "wrap" : v === P.CW_NOWRAP ? "nowrap" : "auto";
    case P.P_COLUMN_RULE_STYLE: return keyword(BORDER_STYLES, v);
    case P.P_BREAK_INSIDE: {
      const k = keyword(BREAK_NAMES, v);
      return k.startsWith("avoid") || k === "auto" ? k : "auto";
    }
    case P.P_ORPHANS:
    case P.P_WIDOWS: return numberText(v);
    case P.P_PRINT_COLOR_ADJUST: return v === P.PCA_EXACT ? "exact" : "economy";
    case P.P_PAGE: return v < 0 || v >= tables.containerNames.length ? "auto" : tables.containerNames[v];
    case P.P_FLEX_DIRECTION: return keyword(FLEX_DIRECTION_NAMES, v);
    case P.P_FLEX_WRAP: return keyword(FLEX_WRAP_NAMES, v);
    case P.P_ALIGN_CONTENT: return alignKeyword(ALIGN_CONTENT_NAMES, v, P.J_FLEX_START, P.J_FLEX_END, computed);
    case P.P_JUSTIFY_CONTENT: return alignKeyword(JUSTIFY_NAMES, v, P.J_FLEX_START, P.J_FLEX_END, computed);
    case P.P_ALIGN_ITEMS: return alignKeyword(ALIGN_NAMES, v, P.A_FLEX_START, P.A_FLEX_END, computed);
    case P.P_ALIGN_SELF:
      return v === P.A_AUTO ? "auto" : alignKeyword(ALIGN_NAMES, v, P.A_FLEX_START, P.A_FLEX_END, computed);
    case P.P_JUSTIFY_ITEMS:
      return alignKeyword(ALIGN_NAMES, v === P.A_STRETCH ? P.A_STRETCH : v, P.A_FLEX_START, P.A_FLEX_END, computed);
    case P.P_JUSTIFY_SELF:
      return v === P.A_AUTO ? "auto" : alignKeyword(ALIGN_NAMES, v, P.A_FLEX_START, P.A_FLEX_END, computed);
    case P.P_GRID_AUTO_FLOW: return keyword(AUTO_FLOW_NAMES, v);
    case P.P_GRID_TEMPLATE_COLUMNS:
    case P.P_GRID_TEMPLATE_ROWS:
    case P.P_GRID_AUTO_COLUMNS:
    case P.P_GRID_AUTO_ROWS:
      // `subgrid` adopts the parent's tracks in that axis; it has no track list of its own, and
      // the names it writes line up with the parent's lines.
      if (u === P.U_SUBGRID) {
        const names = lineNamesText(v);
        return names === "" ? "subgrid" : "subgrid " + names;
      }
      return u === P.U_LIST ? trackText(v) : "none";
    case P.P_OVERSCROLL_BEHAVIOR_X:
    case P.P_OVERSCROLL_BEHAVIOR_Y:
    case P.P_OVERSCROLL_BEHAVIOR_BLOCK:
    case P.P_OVERSCROLL_BEHAVIOR_INLINE: return keyword(OVERSCROLL_NAMES, v);
    case P.P_SCROLLBAR_GUTTER: return keyword(SCROLLBAR_GUTTER_NAMES, v);
    case P.P_SCROLLBAR_WIDTH: return keyword(SCROLLBAR_WIDTH_NAMES, v);
    case P.P_SCROLLBAR_COLOR:
    case P.P_SCROLLBAR_COLOR_TRACK: return v < 0 ? "auto" : colorText(v);
    case P.P_SCROLL_SNAP_ALIGN:
    case P.P_SCROLL_SNAP_ALIGN_INLINE: return keyword(SNAP_ALIGN_NAMES, v);
    case P.P_SCROLL_SNAP_STOP: return keyword(SNAP_STOP_NAMES, v);
    case P.P_CONTENT_VISIBILITY: return keyword(CONTENT_VISIBILITY_NAMES, v);
    case P.P_BOX_DECORATION_BREAK: return keyword(BOX_DECORATION_BREAK_NAMES, v);
    case P.P_MARGIN_TRIM: {
      // The keywords are bits, and print in the order the grammar lists them.
      if (v === P.MT_NONE) return "none";
      const names: string[] = [];
      if ((v & P.MT_BLOCK) !== 0) names.push("block");
      if ((v & P.MT_INLINE) !== 0) names.push("inline");
      if ((v & P.MT_BLOCK_START) !== 0) names.push("block-start");
      if ((v & P.MT_BLOCK_END) !== 0) names.push("block-end");
      if ((v & P.MT_INLINE_START) !== 0) names.push("inline-start");
      if ((v & P.MT_INLINE_END) !== 0) names.push("inline-end");
      return names.join(" ");
    }
    case P.P_GRID_TEMPLATE_AREAS: {
      if (u !== P.U_LIST) return "none";
      const list = areaList(v);
      if (list === null) return "none";
      let rows = 0, cols = 0;
      for (const a of list) {
        rows = Math.max(rows, a.rowEnd - 1);
        cols = Math.max(cols, a.colEnd - 1);
      }
      const cells: string[][] = [];
      for (let r = 0; r < rows; r++) {
        const line: string[] = [];
        for (let c = 0; c < cols; c++) line.push(".");
        cells.push(line);
      }
      for (const a of list) {
        for (let r = a.rowStart - 1; r < a.rowEnd - 1; r++) {
          for (let c = a.colStart - 1; c < a.colEnd - 1; c++) cells[r][c] = a.name;
        }
      }
      const parts: string[] = [];
      for (const line of cells) parts.push('"' + line.join(" ") + '"');
      return parts.join(" ");
    }
    case P.P_GRID_COLUMN_START:
    case P.P_GRID_COLUMN_END:
    case P.P_GRID_ROW_START:
    case P.P_GRID_ROW_END:
      if (u === P.U_SPAN) return "span " + numberText(v);
      if (u === P.U_AUTO) return "auto";
      if (u === P.U_NAME) {
        const ref = placementRow(v);
        if (ref === null) return "auto";
        // The count comes first, and a count of one is what a name on its own means.
        if (ref.span) return ref.count > 1 ? `span ${ref.count} ${ref.name}` : "span " + ref.name;
        return ref.count === 0 ? ref.name : `${ref.count} ${ref.name}`;
      }
      return numberText(v);
    case P.P_TEXT_ALIGN: return keyword(TEXT_ALIGN_NAMES, v);
    case P.P_TEXT_JUSTIFY: return keyword(TEXT_JUSTIFY_NAMES, v);
    case P.P_DIRECTION: return keyword(DIRECTION_NAMES, v);
    case P.P_TEXT_ORIENTATION: return keyword(TEXT_ORIENTATION_NAMES, v);
    case P.P_TEXT_ALIGN_LAST: return v === 0 ? "auto" : keyword(TEXT_ALIGN_NAMES, v - 1);
    case P.P_FONT_PALETTE:
      if (v === P.PALETTE_LIGHT) return "light";
      if (v === P.PALETTE_DARK) return "dark";
      if (v >= P.PALETTE_NAME) return paletteName(v - P.PALETTE_NAME) || "normal";
      return "normal";
    case P.P_LINE_BREAK: return keyword(LINE_BREAK_NAMES, v);
    case P.P_WRITING_MODE: return keyword(WRITING_MODE_NAMES, v);
    case P.P_CURSOR: return keyword(CURSOR_NAMES, v);
    case P.P_OVERFLOW:
    case P.P_OVERFLOW_X:
    case P.P_OVERFLOW_Y:
      return keyword(OVERFLOW_NAMES, v);
    case P.P_BOX_SIZING: return keyword(BOX_SIZING_NAMES, v);
    case P.P_POSITION: return keyword(POSITION_NAMES, v);
    case P.P_FLOAT: return keyword(FLOAT_NAMES, v);
    case P.P_CLEAR: return keyword(CLEAR_NAMES, v);
    case P.P_WHITE_SPACE: return keyword(WHITE_SPACE_NAMES, v);
    case P.P_TEXT_TRANSFORM: return keyword(TEXT_TRANSFORM_NAMES, v);
    case P.P_TEXT_OVERFLOW: return keyword(TEXT_OVERFLOW_NAMES, v);
    case P.P_OVERFLOW_WRAP: return keyword(OVERFLOW_WRAP_NAMES, v);
    case P.P_WORD_BREAK: return keyword(WORD_BREAK_NAMES, v);
    case P.P_SCROLL_BEHAVIOR: return keyword(SCROLL_BEHAVIOR_NAMES, v);
    case P.P_SCROLL_SNAP_TYPE: return keyword(P.SCROLL_SNAP_TYPE_NAMES, v);
    case P.P_APPEARANCE: return keyword(P.APPEARANCE_NAMES, v);
    case P.P_ACCENT_COLOR: return v < 0 ? "auto" : colorText(v);
    case P.P_CARET_COLOR: return v === -1 ? "auto" : colorText(v === -2 ? currentColor : v);
    case P.P_CARET_SHAPE:
      return v === P.CSP_BAR ? "bar" : v === P.CSP_BLOCK ? "block" : v === P.CSP_UNDERSCORE ? "underscore" : "auto";
    case P.P_RESIZE:
      return v === 0 ? "none"
        : v === (P.RESIZE_H | P.RESIZE_V) ? "both"
        : v === P.RESIZE_H ? "horizontal" : "vertical";
    case P.P_INTERACTIVITY: return v === P.IA_INERT ? "inert" : "auto";
    case P.P_TOUCH_ACTION: return touchActionText(v);
    case P.P_POINTER_EVENTS: return keyword(P.POINTER_EVENTS_NAMES, v);
    case P.P_USER_SELECT: return keyword(P.USER_SELECT_NAMES, v);
    case P.P_HYPHENS: return keyword(HYPHENS_NAMES, v);
    case P.P_TEXT_WRAP_MODE: return keyword(TEXT_WRAP_MODE_NAMES, v);
    case P.P_TEXT_WRAP_STYLE: return keyword(TEXT_WRAP_STYLE_NAMES, v);
    case P.P_TEXT_DECORATION: {
      if (v === P.TD_NONE) return "none";
      const lines: string[] = [];
      if (v & P.TD_UNDERLINE) lines.push("underline");
      if (v & P.TD_OVERLINE) lines.push("overline");
      if (v & P.TD_LINE_THROUGH) lines.push("line-through");
      return lines.join(" ");
    }
    case P.P_TEXT_DECORATION_STYLE: return keyword(DECORATION_STYLE_NAMES, v);
    case P.P_TEXT_EMPHASIS_STYLE: return keyword(EMPHASIS_STYLE_NAMES, v);
    case P.P_TEXT_EMPHASIS_POSITION: return keyword(EMPHASIS_POSITION_NAMES, v);
    case P.P_FONT_STYLE: return keyword(FONT_STYLE_NAMES, v);
    case P.P_FONT_FAMILY: return familyText(v);
    case P.P_VERTICAL_ALIGN:
      if (u === P.U_NONE) return keyword(VERTICAL_ALIGN_NAMES, v);
      return u === P.U_EXPR ? exprText(v) : lengthText(v, u);
    case P.P_LIST_STYLE_TYPE:
      // A negative value is -2 - the index of an @counter-style rule's name.
      if (v < -1) {
        const at = -2 - v;
        return at >= 0 && at < tables.counterStyleNames.length ? tables.counterStyleNames[at] : "decimal";
      }
      return keyword(LIST_STYLE_TYPE_NAMES, v);
    case P.P_SHAPE_OUTSIDE: return u === P.U_LIST ? clipPathText(v) : "none";
    case P.P_SHAPE_MARGIN: return lengthText(v, u);
    case P.P_COLOR_INTERPOLATION_FILTERS: return ["auto", "sRGB", "linearRGB"][v] ?? "auto";
    case P.P_FLOOD_COLOR:
    case P.P_LIGHTING_COLOR: return colorText(v);
    case P.P_FLOOD_OPACITY: return numberText(v);
    case P.P_SHAPE_IMAGE_THRESHOLD: return numberText(v);
    case P.P_BACKGROUND_BLEND_MODE: return keyword(MIX_BLEND_NAMES, v);
    case P.P_PERSPECTIVE: return v < 0 ? "none" : lengthText(v, u);
    case P.P_PERSPECTIVE_ORIGIN: return u === P.U_LIST && v >= 0 ? positionText(v) : "50% 50%";
    case P.P_BACKFACE_VISIBILITY: return v === P.BFV_HIDDEN ? "hidden" : "visible";
    case P.P_WILL_CHANGE: return u === P.U_LIST ? willChangeText(v) : "auto";
    case P.P_LIST_STYLE_POSITION: return keyword(LIST_STYLE_POSITION_NAMES, v);
    case P.P_OUTLINE_STYLE: return keyword(OUTLINE_STYLE_NAMES, v);
    case P.P_BORDER_TOP_STYLE:
    case P.P_BORDER_RIGHT_STYLE:
    case P.P_BORDER_BOTTOM_STYLE:
    case P.P_BORDER_LEFT_STYLE:
    case P.P_BORDER_BLOCK_START_STYLE:
    case P.P_BORDER_BLOCK_END_STYLE:
    case P.P_BORDER_INLINE_START_STYLE:
    case P.P_BORDER_INLINE_END_STYLE:
      return keyword(BORDER_STYLES, v);
    case P.P_FONT_WEIGHT:
    case P.P_OPACITY:
    case P.P_FLEX_GROW:
    case P.P_FLEX_SHRINK:
    case P.P_Z_INDEX:
    case P.P_ORDER:
      return numberText(v);
    case P.P_LINE_HEIGHT: return u === P.U_NONE ? numberText(v) : lengthText(v, u);
    case P.P_TAB_SIZE: return numberText(v);
    case P.P_LINE_CLAMP: return v > 0 ? numberText(v) : "none";
    case P.P_BLOCK_ELLIPSIS: return v === P.BE_NO_ELLIPSIS ? "no-ellipsis" : "auto";
    case P.P_TRANSFORM_BOX: return ["content-box", "border-box", "fill-box", "stroke-box", "view-box"][v] ?? "border-box";
    case P.P_FONT_FEATURE_SETTINGS: return featureText(v);
    case P.P_FONT_VARIATION_SETTINGS: return variationText(v);
    case P.P_FONT_SYNTHESIS: return synthesisText(v);
    case P.P_FONT_KERNING: return ["auto", "normal", "none"][v] ?? "auto";
    case P.P_FONT_OPTICAL_SIZING: return v === P.FOPSZ_NONE ? "none" : "auto";
    case P.P_FONT_LANGUAGE_OVERRIDE: {
      if (v === 0) return "normal";
      let tag = "";
      for (let i = 3; i >= 0; i--) tag = String.fromCharCode(Math.floor(v / Math.pow(256, i)) % 256) + tag;
      return '"' + tag + '"';
    }
    case P.P_FONT_SIZE_ADJUST: return v < 0 ? "none" : numberText(v);
    case P.P_FONT_SYNTHESIS_WEIGHT:
    case P.P_FONT_SYNTHESIS_STYLE:
    case P.P_FONT_SYNTHESIS_SMALL_CAPS:
    case P.P_FONT_VARIANT_EMOJI:
      if (p === P.P_FONT_VARIANT_EMOJI) return ["normal", "text", "emoji", "unicode"][v] ?? "normal";
      return v !== 0 ? "auto" : "none";
    case P.P_FONT_SIZE:
      if (u === P.U_MEDIUM) return "medium";
      if (u === P.U_SMALLER) return "smaller";
      if (u === P.U_LARGER) return "larger";
      return lengthText(v, u);
    case P.P_FONT_STRETCH:
      return u === P.U_PCT ? numberText(v) + "%" : stretchKeyword(v);
    case P.P_TEXT_UNDERLINE_POSITION: return ["auto", "under", "left", "right", "from-font"][v] ?? "auto";
    case P.P_TEXT_DECORATION_SKIP_INK: return ["auto", "none", "all"][v] ?? "auto";
    case P.P_TEXT_BOX_TRIM: return ["none", "trim-start", "trim-end", "trim-both"][v] ?? "none";
    case P.P_TEXT_BOX_EDGE: {
      const names = ["text", "cap", "ex", "alphabetic", "ideographic", "leading", "auto"];
      const over = names[Math.floor(v / 16)] ?? "auto";
      const under = names[v % 16] ?? "auto";
      if (over === "auto" && under === "auto") return "auto";
      return over === under ? over : over + " " + under;
    }
    case P.P_INITIAL_LETTER: {
      if (v === 0) return "normal";
      const sink = v % 10000;
      const size = (v - sink) / 10000;
      return numberText(size) + (sink !== 1 ? " " + sink : "");
    }
    case P.P_ALIGNMENT_BASELINE:
    case P.P_DOMINANT_BASELINE:
      return ["auto", "baseline", "text-bottom", "alphabetic", "ideographic", "middle", "central",
        "mathematical", "hanging"][v] ?? "auto";
    case P.P_BASELINE_SHIFT:
      if (v === P.BS_SUB) return "sub";
      if (v === P.BS_SUPER) return "super";
      if (v === 0 && u === P.U_NONE) return "baseline";
      return lengthText(v, u);
    case P.P_WHITE_SPACE_COLLAPSE:
      return ["collapse", "preserve", "preserve-breaks", "preserve-spaces", "break-spaces"][v] ?? "collapse";
    case P.P_FONT_VARIANT_CAPS: return keyword(VARIANT_CAPS_NAMES, v);
    case P.P_FONT_VARIANT_LIGATURES: return variantLigaturesText(v);
    case P.P_FONT_VARIANT_NUMERIC: return variantNumericText(v);
    case P.P_FONT_VARIANT_EAST_ASIAN: return variantEastAsianText(v);
    case P.P_FONT_VARIANT_POSITION: return keyword(VARIANT_POSITION_NAMES, v);
    case P.P_FONT_VARIANT_ALTERNATES: return keyword(VARIANT_ALTERNATES_NAMES, v);
    case P.P_CLIP: return u === P.U_LIST ? clipText(v) : "auto";
    case P.P_TRANSFORM:
    case P.P_TRANSLATE:
    case P.P_ROTATE:
    case P.P_SCALE: {
      if (v < 0) return "none";
      const row = transformRows.row(v);
      return row === null ? "none" : listCss(row);
    }
    case P.P_TRANSFORM_ORIGIN: {
      const row = v < 0 ? null : originRows.row(v);
      return row === null || row.length < 4
        ? "50% 50%"
        : sharedLengthText(row[0], row[1]) + " " + sharedLengthText(row[2], row[3]);
    }
    case P.P_OBJECT_FIT: return keyword(OBJECT_FIT_NAMES, v);
    case P.P_OBJECT_POSITION: return u === P.U_LIST && v >= 0 ? positionText(v) : "50% 50%";
    // The x and y longhands hold a position row list too; the id is not a length.
    case P.P_BACKGROUND_POSITION_X:
    case P.P_BACKGROUND_POSITION_Y:
      return u === P.U_LIST && v >= 0 ? backgroundAxisText(v, p === P.P_BACKGROUND_POSITION_Y) : "";
    case P.P_IMAGE_RENDERING: return keyword(IMAGE_RENDERING_NAMES, v);
    case P.P_APP_REGION: return keyword(APP_REGION_NAMES, v);
    case P.P_IMAGE_ORIENTATION: return keyword(IMAGE_ORIENTATION_NAMES, v);
    case P.P_CONTAINER_TYPE: return keyword(CONTAINER_TYPE_NAMES, v);
    case P.P_CONTAINER_NAME: return containerNameText(v);
    case P.P_MIX_BLEND_MODE: return keyword(MIX_BLEND_NAMES, v);
    case P.P_ISOLATION: return keyword(ISOLATION_NAMES, v);
    case P.P_CLIP_PATH: return u === P.U_LIST && v >= 0 ? clipPathText(v) : "none";
    // A mask image is held in its encoded form, which this text can't rebuild; the value is
    // there for the paint code. `none` is the initial value and serializes as itself.
    // A mask image list has no computed text yet; an unset one is `none`. The value is a row id
    // when there is a list, and -1 with U_NONE when there is none (see runtime/mask.ts).
    case P.P_MASK_IMAGE: return u === P.U_LIST ? "" : "none";
    // A filter list is serialized against the element, since drop-shadow resolves currentColor;
    // see filterText.
    case P.P_FILTER:
    case P.P_BACKDROP_FILTER:
      return v < 0 ? "none" : "";
    case P.P_COLOR:
    case P.P_BACKGROUND_COLOR:
    case P.P_BORDER_TOP_COLOR:
    case P.P_BORDER_RIGHT_COLOR:
    case P.P_BORDER_BOTTOM_COLOR:
    case P.P_BORDER_LEFT_COLOR:
    case P.P_BORDER_BLOCK_START_COLOR:
    case P.P_BORDER_BLOCK_END_COLOR:
    case P.P_BORDER_INLINE_START_COLOR:
    case P.P_BORDER_INLINE_END_COLOR:
    case P.P_OUTLINE_COLOR:
    case P.P_COLUMN_RULE_COLOR:
    case P.P_TEXT_DECORATION_COLOR:
    case P.P_TEXT_EMPHASIS_COLOR:
      return v < 0 ? colorText(currentColor < 0 ? 0 : currentColor) : colorText(v);
    case P.P_STROKE_DASHARRAY: return u === P.U_LIST ? dashText(v) : "none";
    case P.P_STROKE_DASHOFFSET: return lengthText(v, u);
    case P.P_FILL:
    case P.P_STROKE:
      if (v === P.PAINT_NONE) return "none";
      if (v === P.PAINT_CURRENT) return "currentColor";
      return v < 0 ? colorText(currentColor < 0 ? 0 : currentColor) : colorText(v);
    // A background longhand with no layer list keeps its initial value, which CSS names in words;
    // a list's own text isn't rebuilt here yet.
    case P.P_BACKGROUND_IMAGE:
    case P.P_BACKGROUND_POSITION:
    case P.P_BACKGROUND_SIZE:
    case P.P_BACKGROUND_REPEAT:
    case P.P_BACKGROUND_ORIGIN:
    case P.P_BACKGROUND_CLIP:
    case P.P_BACKGROUND_ATTACHMENT:
      if (v < 0) {
        return p === P.P_BACKGROUND_IMAGE ? "none"
          : p === P.P_BACKGROUND_POSITION ? "0% 0%"
            : p === P.P_BACKGROUND_SIZE ? "auto"
              : p === P.P_BACKGROUND_REPEAT ? "repeat"
                : p === P.P_BACKGROUND_ORIGIN ? "padding-box"
                  : p === P.P_BACKGROUND_CLIP ? "border-box" : "scroll";
      }
      return lengthText(v, u);
    default:
      return u === P.U_EXPR ? exprText(v) : lengthText(v, u);
  }
}

/** One side of a track's minmax() as CSS text. */
/** One will-change row as CSS text; the keywords print before the property names. */
function willChangeText(id: number): string {
  const row = willChangeRows.row(id);
  if (row === null) return "auto";
  const parts: string[] = [];
  for (const entry of row) {
    if (entry === WC_LIST_AUTO) parts.push("auto");
    else if (entry === WC_LIST_CONTENTS) parts.push("contents");
    else if (entry === WC_LIST_SCROLL_POSITION) parts.push("scroll-position");
    else parts.push(P.propCssName(entry));
  }
  return parts.length === 0 ? "auto" : parts.join(", ");
}

function trackSizeText(s: TrackSize): string {
  if (s.kind === P.GT_LEN) return lengthText(s.v, s.u);
  if (s.kind === P.GT_AUTO) return "auto";
  if (s.kind === P.GT_FR) return numberText(s.v) + "fr";
  if (s.kind === P.GT_MIN_CONTENT) return "min-content";
  if (s.kind === P.GT_MAX_CONTENT) return "max-content";
  return s.u === P.U_AUTO ? "fit-content(auto)" : "fit-content(" + lengthText(s.v, s.u) + ")";
}

/** A grid track list as CSS text: `none`, or each track, a plain size standing for its own
 * minmax() (the way browsers print one). */
function trackText(id: number): string {
  const tracks = trackList(id);
  if (tracks === null) return "none";
  let out = "";
  for (const t of tracks) {
    // A bare `<flex>` is minmax(auto, <flex>), which browsers print as the factor alone.
    const a = t.min.kind === P.GT_AUTO && t.max.kind === P.GT_FR ? trackSizeText(t.max) : trackSizeText(t.min);
    const b = trackSizeText(t.max);
    if (out !== "") out += " ";
    out += a === b ? a : "minmax(" + a + ", " + b + ")";
  }
  return out;
}

/** A `box-shadow` value as CSS text: `none`, or the shadows as color, offsets, blur, spread and
 * `inset`, in the order browsers serialize them. */
function shadowText(el: Node, id: number): string {
  const list = shadowList(el, id);
  if (list.length === 0) return "none";
  let s = "";
  for (const sh of list) {
    if (s !== "") s += ", ";
    const color = sh.color < 0 ? el.sv[P.P_COLOR] : sh.color;
    s += colorText(color) + " " + lengthText(sh.dx, P.U_PX) + " " + lengthText(sh.dy, P.U_PX) +
      " " + lengthText(sh.blur, P.U_PX) + " " + lengthText(sh.spread, P.U_PX) + (sh.inset ? " inset" : "");
  }
  return s;
}

/** One text-shadow list as CSS: color, offsets and blur (no spread or `inset`). */
function textShadowText(el: Node, id: number): string {
  const list = shadowList(el, id);
  if (list.length === 0) return "none";
  let s = "";
  for (const sh of list) {
    if (s !== "") s += ", ";
    const color = sh.color < 0 ? el.sv[P.P_COLOR] : sh.color;
    s += colorText(color) + " " + lengthText(sh.dx, P.U_PX) + " " + lengthText(sh.dy, P.U_PX) +
      " " + lengthText(sh.blur, P.U_PX);
  }
  return s;
}

/**
 * A `filter` or `backdrop-filter` value as CSS text: `none`, or the functions in order. Each
 * length is reported in px, and drop-shadow's colour first, as browsers serialize them.
 */
function filterText(el: Node, id: number): string {
  const list = filterList(el, id);
  if (list.length === 0) return "none";
  let s = "";
  for (const op of list) {
    if (s !== "") s += " ";
    switch (op.kind) {
      case P.FK_BLUR:
        s += "blur(" + lengthText(op.a, P.U_PX) + ")";
        break;
      case P.FK_BRIGHTNESS:
        s += "brightness(" + numberText(op.a) + ")";
        break;
      case P.FK_CONTRAST:
        s += "contrast(" + numberText(op.a) + ")";
        break;
      case P.FK_GRAYSCALE:
        s += "grayscale(" + numberText(op.a) + ")";
        break;
      case P.FK_HUE_ROTATE:
        s += "hue-rotate(" + numberText((op.a * 180) / Math.PI) + "deg)";
        break;
      case P.FK_INVERT:
        s += "invert(" + numberText(op.a) + ")";
        break;
      case P.FK_OPACITY:
        s += "opacity(" + numberText(op.a) + ")";
        break;
      case P.FK_SATURATE:
        s += "saturate(" + numberText(op.a) + ")";
        break;
      case P.FK_SEPIA:
        s += "sepia(" + numberText(op.a) + ")";
        break;
      case P.FK_DROP_SHADOW: {
        const color = op.color < 0 ? el.sv[P.P_COLOR] : op.color;
        s += "drop-shadow(" + colorText(color) + " " + lengthText(op.dx, P.U_PX) + " " +
          lengthText(op.dy, P.U_PX) + " " + lengthText(op.blur, P.U_PX) + ")";
        break;
      }
      case P.FK_URL:
        s += "url(#" + (paintUrlAt(op.a) ?? "") + ")";
        break;
      default:
        break;
    }
  }
  return s;
}

/**
 * The computed value of `content` for an element or its generated box: strings quoted, and each
 * attr() resolved from the element the content was generated for.
 */
function contentValue(el: Element, v: number): string {
  if (v === P.CONTENT_NORMAL) return "normal";
  if (v < 0 || v >= tables.contentItems.length) return "none";
  const origin = el.pseudoKind !== P.PE_NONE ? el.parentElement : el;
  return contentCss(tables.contentItems[v], (name) => (origin !== null ? origin.getAttribute(name) : null));
}

/** A container name list as CSS writes it: the names separated by spaces, or `none`. */
function containerNameText(v: number): string {
  if (v < 0 || v >= tables.containerNames.length) return "none";
  return tables.containerNames[v];
}

/** The longhand property ids a shorthand sets, or null when it isn't one native handles. */
function shorthandIds(name: string): number[] | null {
  if (name === "margin") return [P.P_MARGIN_TOP, P.P_MARGIN_RIGHT, P.P_MARGIN_BOTTOM, P.P_MARGIN_LEFT];
  if (name === "padding") return [P.P_PADDING_TOP, P.P_PADDING_RIGHT, P.P_PADDING_BOTTOM, P.P_PADDING_LEFT];
  if (name === "inset") return [P.P_TOP, P.P_RIGHT, P.P_BOTTOM, P.P_LEFT];
  if (name === "animation") {
    return [P.P_ANIMATION_DURATION, P.P_ANIMATION_TIMING_FUNCTION, P.P_ANIMATION_DELAY,
      P.P_ANIMATION_ITERATION_COUNT, P.P_ANIMATION_DIRECTION, P.P_ANIMATION_FILL_MODE,
      P.P_ANIMATION_PLAY_STATE, P.P_ANIMATION_NAME];
  }
  if (name === "border-top") return [P.P_BORDER_TOP_WIDTH, P.P_BORDER_TOP_STYLE, P.P_BORDER_TOP_COLOR];
  if (name === "border-right") return [P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_RIGHT_STYLE, P.P_BORDER_RIGHT_COLOR];
  if (name === "border-bottom") return [P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_BOTTOM_STYLE, P.P_BORDER_BOTTOM_COLOR];
  if (name === "border-left") return [P.P_BORDER_LEFT_WIDTH, P.P_BORDER_LEFT_STYLE, P.P_BORDER_LEFT_COLOR];
  // `border` writes each side's width, style and colour, in that order per side.
  if (name === "border") {
    return [P.P_BORDER_TOP_WIDTH, P.P_BORDER_TOP_STYLE, P.P_BORDER_TOP_COLOR,
      P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_RIGHT_STYLE, P.P_BORDER_RIGHT_COLOR,
      P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_BOTTOM_STYLE, P.P_BORDER_BOTTOM_COLOR,
      P.P_BORDER_LEFT_WIDTH, P.P_BORDER_LEFT_STYLE, P.P_BORDER_LEFT_COLOR];
  }
  // A logical shorthand sets its start and end longhands, which the runtime settles on the
  // element's own axes.
  if (name === "margin-block") return [P.P_MARGIN_BLOCK_START, P.P_MARGIN_BLOCK_END];
  if (name === "margin-inline") return [P.P_MARGIN_INLINE_START, P.P_MARGIN_INLINE_END];
  if (name === "padding-block") return [P.P_PADDING_BLOCK_START, P.P_PADDING_BLOCK_END];
  if (name === "padding-inline") return [P.P_PADDING_INLINE_START, P.P_PADDING_INLINE_END];
  if (name === "inset-block") return [P.P_INSET_BLOCK_START, P.P_INSET_BLOCK_END];
  if (name === "inset-inline") return [P.P_INSET_INLINE_START, P.P_INSET_INLINE_END];
  // A logical border side writes its width, style and colour longhands; the axis form writes
  // both sides of the axis.
  if (name === "border-block-start") return [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_START_STYLE, P.P_BORDER_BLOCK_START_COLOR];
  if (name === "border-block-end") return [P.P_BORDER_BLOCK_END_WIDTH, P.P_BORDER_BLOCK_END_STYLE, P.P_BORDER_BLOCK_END_COLOR];
  if (name === "border-inline-start") return [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_START_STYLE, P.P_BORDER_INLINE_START_COLOR];
  if (name === "border-inline-end") return [P.P_BORDER_INLINE_END_WIDTH, P.P_BORDER_INLINE_END_STYLE, P.P_BORDER_INLINE_END_COLOR];
  if (name === "border-block-width") return [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_END_WIDTH];
  if (name === "border-block-style") return [P.P_BORDER_BLOCK_START_STYLE, P.P_BORDER_BLOCK_END_STYLE];
  if (name === "border-block-color") return [P.P_BORDER_BLOCK_START_COLOR, P.P_BORDER_BLOCK_END_COLOR];
  if (name === "border-inline-width") return [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_END_WIDTH];
  if (name === "border-inline-style") return [P.P_BORDER_INLINE_START_STYLE, P.P_BORDER_INLINE_END_STYLE];
  if (name === "border-inline-color") return [P.P_BORDER_INLINE_START_COLOR, P.P_BORDER_INLINE_END_COLOR];
  if (name === "border-block") {
    return [P.P_BORDER_BLOCK_START_WIDTH, P.P_BORDER_BLOCK_START_STYLE, P.P_BORDER_BLOCK_START_COLOR,
      P.P_BORDER_BLOCK_END_WIDTH, P.P_BORDER_BLOCK_END_STYLE, P.P_BORDER_BLOCK_END_COLOR];
  }
  if (name === "border-inline") {
    return [P.P_BORDER_INLINE_START_WIDTH, P.P_BORDER_INLINE_START_STYLE, P.P_BORDER_INLINE_START_COLOR,
      P.P_BORDER_INLINE_END_WIDTH, P.P_BORDER_INLINE_END_STYLE, P.P_BORDER_INLINE_END_COLOR];
  }
  if (name === "border-width") return [P.P_BORDER_TOP_WIDTH, P.P_BORDER_RIGHT_WIDTH, P.P_BORDER_BOTTOM_WIDTH, P.P_BORDER_LEFT_WIDTH];
  if (name === "border-color") return [P.P_BORDER_TOP_COLOR, P.P_BORDER_RIGHT_COLOR, P.P_BORDER_BOTTOM_COLOR, P.P_BORDER_LEFT_COLOR];
  if (name === "border-style") return [P.P_BORDER_TOP_STYLE, P.P_BORDER_RIGHT_STYLE, P.P_BORDER_BOTTOM_STYLE, P.P_BORDER_LEFT_STYLE];
  if (name === "border-radius") {
    const ids: number[] = [];
    for (const c of RADIUS_CORNERS) {
      ids.push(c[0], c[1]);
    }
    return ids;
  }
  if (name === "gap" || name === "grid-gap") return [P.P_ROW_GAP, P.P_COLUMN_GAP];
  if (name === "overflow") return [P.P_OVERFLOW_X, P.P_OVERFLOW_Y];
  if (name === "overflow-x") return [P.P_OVERFLOW_X];
  if (name === "overflow-y") return [P.P_OVERFLOW_Y];
  if (name === "container") return [P.P_CONTAINER_NAME, P.P_CONTAINER_TYPE];
  if (name === "place-content") return [P.P_ALIGN_CONTENT, P.P_JUSTIFY_CONTENT];
  if (name === "place-items") return [P.P_ALIGN_ITEMS, P.P_JUSTIFY_ITEMS];
  if (name === "place-self") return [P.P_ALIGN_SELF, P.P_JUSTIFY_SELF];
  if (name === "grid") {
    return [P.P_GRID_TEMPLATE_ROWS, P.P_GRID_TEMPLATE_COLUMNS, P.P_GRID_AUTO_ROWS, P.P_GRID_AUTO_COLUMNS, P.P_GRID_AUTO_FLOW];
  }
  if (name === "grid-template") return [P.P_GRID_TEMPLATE_ROWS, P.P_GRID_TEMPLATE_COLUMNS];
  if (name === "background") return [P.P_BACKGROUND_COLOR];
  if (name === "flex") return [P.P_FLEX_GROW, P.P_FLEX_SHRINK, P.P_FLEX_BASIS];
  if (name === "list-style") return [P.P_LIST_STYLE_TYPE, P.P_LIST_STYLE_POSITION, P.P_LIST_STYLE_IMAGE];
  if (name === "outline") return [P.P_OUTLINE_STYLE, P.P_OUTLINE_WIDTH, P.P_OUTLINE_COLOR];
  if (name === "text-decoration") {
    return [P.P_TEXT_DECORATION, P.P_TEXT_DECORATION_STYLE, P.P_TEXT_DECORATION_COLOR, P.P_TEXT_DECORATION_THICKNESS];
  }
  if (name === "text-emphasis") return [P.P_TEXT_EMPHASIS_STYLE, P.P_TEXT_EMPHASIS_COLOR];
  if (name === "text-wrap") return [P.P_TEXT_WRAP_MODE, P.P_TEXT_WRAP_STYLE];
  if (name === "font-synthesis") {
    return [P.P_FONT_SYNTHESIS_WEIGHT, P.P_FONT_SYNTHESIS_STYLE, P.P_FONT_SYNTHESIS_SMALL_CAPS];
  }
  if (name === "font") {
    return [P.P_FONT_STYLE, P.P_FONT_WEIGHT, P.P_FONT_STRETCH, P.P_FONT_SIZE, P.P_LINE_HEIGHT, P.P_FONT_FAMILY];
  }
  if (name === "font-variant") {
    return [P.P_FONT_VARIANT_CAPS, P.P_FONT_VARIANT_LIGATURES, P.P_FONT_VARIANT_NUMERIC,
      P.P_FONT_VARIANT_EAST_ASIAN, P.P_FONT_VARIANT_POSITION, P.P_FONT_VARIANT_ALTERNATES];
  }
  if (name === "grid-column") return [P.P_GRID_COLUMN_START, P.P_GRID_COLUMN_END];
  if (name === "grid-row") return [P.P_GRID_ROW_START, P.P_GRID_ROW_END];
  if (name === "grid-area") return [P.P_GRID_ROW_START, P.P_GRID_COLUMN_START, P.P_GRID_ROW_END, P.P_GRID_COLUMN_END];
  if (name === "transition") return TRANSITION_LONGHANDS;
  if (name === "animation") return ANIMATION_LONGHANDS;
  return null;
}

/** One, two or four values for a box shorthand: equal pairs collapse, as CSS serializes them. */
function boxText(texts: string[], four: boolean): string {
  if (texts.length === 1) return texts[0];
  const t = texts[0];
  const r = texts[1];
  const b = four ? texts[2] : texts[0];
  const l = four ? texts[3] : texts[1];
  if (four && t === r && t === b && t === l) return t;
  if (t === b && r === l) return t + " " + r;
  return texts.join(" ");
}

// ---------------------------------------------------------------------------

/**
 * The style object a script reads and writes: an element's inline declarations, or the computed
 * style getComputedStyle() hands out. The declarations themselves are a `StyleDeclaration`; a
 * script gets that declaration's named-property view (see styleView), which is a Proxy rather
 * than a class instance, so the type a page names is this structural one. Its index signature is
 * the named-property half: `style["margin-left"]` and `style[prop]` name a property too.
 */
export interface CSSStyleDeclaration {
  [key: string]: any;
  cssText: string;
  readonly length: number;
  item(index: number): string;
  getPropertyValue(name: string): string;
  setProperty(name: string, value: any, priority?: string): void;
  removeProperty(name: string): string;
}

export class StyleDeclaration {
  get [Symbol.toStringTag](): string { return "StyleDeclaration"; }
  private el: Element;
  /** A computed style is read-only and serialized from the element's computed values. */
  private computed: boolean;
  /** The named-property view a script sees (see styleView), made on first use. */
  view: any = null;
  /** The inline declarations, in the order they were set. Unused for a computed style. */
  decls: InlineDecl[] = [];
  /** Whether a style attribute exists, which browsers create at the first write. */
  present = false;

  constructor(el: Element, computed: boolean) {
    this.el = el;
    this.computed = computed;
  }

  get length(): number {
    return this.computed ? P.PROP_COUNT : this.decls.length;
  }
  /** The property name at `index`, for iterating a declaration block. */
  item(index: number): string {
    if (this.computed) return index >= 0 && index < P.PROP_COUNT ? P.PROPERTY_NAMES[index] : "";
    if (index < 0 || index >= this.decls.length) return "";
    const d = this.decls[index];
    return d.prop === undefined ? P.PROPERTY_NAMES[d.p] : d.prop;
  }

  get cssText(): string {
    if (this.computed) return "";
    let s = "";
    for (const d of this.decls) {
      if (d.prop !== undefined) {
        // A declaration kept as text serializes as written.
        if (s !== "") s += " ";
        s += d.prop + ": " + (d.value === undefined ? "" : d.value) + (d.important ? " !important" : "") + ";";
        continue;
      }
      // A corner's vertical radius is written with its horizontal one.
      // A corner's vertical radius and a decoration inset's end value are written with their
      // partner, not as properties of their own.
      if (isRadiusY(d.p) || d.p === P.P_TEXT_DECORATION_INSET_END) continue;
      if (s !== "") s += " ";
      const corner = cornerOf(d.p);
      let text = d.p === P.P_BOX_SHADOW ? shadowText(this.el, d.v)
        : d.p === P.P_TEXT_SHADOW ? textShadowText(this.el, d.v)
          : d.p === P.P_OVERFLOW_CLIP_MARGIN ? clipMarginCss(this.el, d.v, d.u, false)
            : d.p === P.P_FILTER || d.p === P.P_BACKDROP_FILTER ? filterText(this.el, d.v)
            : valueText(d.p, d.v, d.u, -1);
      if (corner >= 0) {
        const y = this.longhand(RADIUS_CORNERS[corner][1]);
        if (y !== "" && y !== text) text += " " + y;
      }
      s += P.PROPERTY_NAMES[d.p] + ": " + text + (d.important ? " !important" : "") + ";";
    }
    return s;
  }
  set cssText(text: string) {
    this.setBlock(text);
  }

  getPropertyValue(name: string): string {
    // A computed style is a live view: a read settles the pending style work and brings the
    // transitions and animations to the current time, as a browser's read does.
    if (this.computed) flushComputedStyle(this.el);
    const written = name.trim();
    // A custom property name is case-sensitive and never a longhand this build knows.
    if (written.startsWith("--")) {
      const custom = customPropertyName(written);
      return custom === null ? "" : this.customValue(custom);
    }
    // The old webkit flex spellings read back the standard property's value.
    const lower = written.toLowerCase();
    const prop = P.WEBKIT_FLEX_ALIASES.has(lower) ? lower.slice("-webkit-".length) : lower;
    const ids = shorthandIds(prop);
    if (ids !== null) return this.shorthand(prop, ids);
    const logicalCorner = LOGICAL_CORNER_NAMES.indexOf(prop);
    if (logicalCorner >= 0) {
      // An inline declaration reads back as written, before any writing mode has been applied.
      if (!this.computed) {
        const x = this.longhand(P.P_BORDER_START_START_RADIUS + logicalCorner * 2);
        const y = this.longhand(P.P_BORDER_START_START_RADIUS + logicalCorner * 2 + 1);
        if (x === "") return "";
        return y === "" || y === x ? x : x + " " + y;
      }
      const wm = this.el.sv[P.P_WRITING_MODE];
      const vertical = wm !== P.WM_HORIZONTAL_TB;
      const rtl = this.el.sv[P.P_DIRECTION] === P.DIR_RTL;
      const vlr = wm === P.WM_VERTICAL_LR || wm === P.WM_SIDEWAYS_LR;
      const blockStart = logicalCorner < 2;
      const start = (logicalCorner & 1) === 0;
      let top: boolean;
      let left: boolean;
      if (!vertical) {
        top = blockStart;
        left = rtl ? !start : start;
      } else {
        top = start;
        left = vlr ? blockStart : !blockStart;
      }
      return this.cornerText(top ? (left ? 0 : 1) : (left ? 3 : 2));
    }
    const corner = RADIUS_NAMES.indexOf(prop);
    if (corner >= 0) return this.cornerText(corner);
    // A template with an `auto-fill` or `auto-fit` repeat prints the tracks the last layout
    // resolved it to, since how many copies fit is only known once the box has been laid out.
    if (prop === "grid-template-columns" || prop === "grid-template-rows") {
      const id = P.propertyId(prop);
      if (id >= 0 && this.el.su[id] === P.U_LIST) {
        const list = trackList(this.el.sv[id]);
        const repeats = list !== null && list.some((t) => t.repeat !== undefined);
        const used = prop === "grid-template-columns" ? this.el.gridUsedCols : this.el.gridUsedRows;
        if (repeats && used.length > 0) {
          return used.map((px) => numberText(Math.round(px * 100) / 100) + "px").join(" ");
        }
      }
    }
    // One property, two slots: the block and inline alignments print as one pair.
    if (prop === "scroll-snap-align") {
      const block = this.longhand(P.P_SCROLL_SNAP_ALIGN);
      const inline = this.longhand(P.P_SCROLL_SNAP_ALIGN_INLINE);
      return block === inline ? block : block + " " + inline;
    }
    // One property, two slots: the thumb colour and the track colour print as one pair.
    if (prop === "scrollbar-color") {
      const thumb = this.longhand(P.P_SCROLLBAR_COLOR);
      if (thumb === "" || thumb === "auto") return thumb;
      return thumb + " " + this.longhand(P.P_SCROLLBAR_COLOR_TRACK);
    }
    const p = P.propertyId(prop);
    if (p < 0) return "";
    return this.longhand(p);
  }

  /** A custom property's value: computed, or as set inline. */
  private customValue(prop: string): string {
    if (this.computed) {
      const cprops = this.el.cprops;
      if (cprops === null) return "";
      const v = cprops.get(prop);
      return v === undefined ? "" : v;
    }
    for (let i = this.decls.length - 1; i >= 0; i--) {
      const d = this.decls[i];
      if (d.prop === prop) return d.value === undefined ? "" : d.value;
    }
    return "";
  }

  // The parameters are DOMString in the CSSOM, so a script may pass anything and it is converted
  // rather than refused: null is the empty string ([LegacyNullToEmptyString]) and any other value
  // is stringified, leaving a missing value as the invalid text "undefined" that a browser
  // ignores. The WPT interpolation harness calls setProperty(property, undefined) that way.
  setProperty(name: any, value: any, priority?: any): void {
    if (this.computed) return;
    const written = String(name).trim();
    if (written === "") return;
    // A custom property name is case-sensitive and may be written with escapes; every other
    // property name isn't.
    let prop = written.startsWith("--") ? customPropertyName(written) ?? "" : written.toLowerCase();
    if (P.WEBKIT_FLEX_ALIASES.has(prop)) prop = prop.slice("-webkit-".length);
    if (prop === "") return;
    const text = (value === null ? "" : String(value)).trim();
    if (text === "") {
      this.removeProperty(prop);
      return;
    }
    const prio = priority === undefined || priority === null ? "" : String(priority);
    this.setDeclaration(prop, text, prio.trim().toLowerCase() === "important");
  }

  removeProperty(name: string): string {
    if (this.computed) return "";
    const written = name.trim();
    let prop = written.startsWith("--") ? customPropertyName(written) ?? "" : written.toLowerCase();
    if (P.WEBKIT_FLEX_ALIASES.has(prop)) prop = prop.slice("-webkit-".length);
    if (prop === "") return "";
    const old = this.getPropertyValue(prop);
    if (prop.startsWith("--")) {
      let removed = false;
      for (let i = this.decls.length - 1; i >= 0; i--) {
        if (this.decls[i].prop === prop) {
          this.decls.splice(i, 1);
          removed = true;
        }
      }
      if (removed) invalidateStyleOf(this.el);
      return old;
    }
    const ids = shorthandIds(prop);
    if (ids !== null) {
      let removed = this.dropText(prop, ids);
      for (const p of ids) removed = this.removeId(p) || removed;
      if (removed) invalidateStyleOf(this.el);
      return old;
    }
    const corner = RADIUS_NAMES.indexOf(prop);
    if (corner >= 0) {
      let removed = this.dropText(prop, RADIUS_CORNERS[corner]);
      removed = this.removeId(RADIUS_CORNERS[corner][0]) || removed;
      removed = this.removeId(RADIUS_CORNERS[corner][1]) || removed;
      if (removed) invalidateStyleOf(this.el);
      return old;
    }
    const p = P.propertyId(prop);
    if (p < 0) return "";
    const drop = p === P.P_TEXT_DECORATION_INSET ? [p, P.P_TEXT_DECORATION_INSET_END] : [p];
    const removed = this.dropText(prop, drop);
    let any = false;
    for (const id of drop) any = this.removeId(id) || any;
    if (any || removed) {
      invalidateStyleOf(this.el);
      return old;
    }
    return "";
  }

  /** Replaces the whole block from a style attribute text; a script can also set cssText. */
  setBlock(text: string): void {
    if (this.computed) return;
    this.decls = [];
    this.present = true;
    for (const d of parseDeclarationBlock(text, fonts, undefined, getSheetContent())) {
      for (const c of d.decls) {
        if (c.prop !== undefined) this.putText(c.prop, c.value === undefined ? "" : c.value, d.important);
        else this.put(c.p, c.v, c.u, d.important);
      }
    }
    invalidateStyleOf(this.el);
  }

  /** Drops every declaration, for removeAttribute("style"), leaving the attribute absent. */
  clear(): void {
    if (this.computed) return;
    if (this.decls.length === 0 && !this.present) return;
    this.decls = [];
    this.present = false;
    invalidateStyleOf(this.el);
  }

  private setDeclaration(prop: string, value: string, important: boolean): void {
    // Writing the value a declaration already holds, at the same priority, changes nothing: a
    // virtual list re-applies the same height to every mounted row each frame.
    if (!this.computed && this.present && this.getPropertyValue(prop) === value) {
      const id = prop.startsWith("--") ? -1 : P.propertyId(prop);
      let prior = "";
      for (let i = this.decls.length - 1; i >= 0; i--) {
        const d = this.decls[i];
        if (d.prop === prop || (id >= 0 && d.prop === undefined && d.p === id)) {
          if (d.important) prior = "important";
          break;
        }
      }
      if (prior === (important ? "important" : "")) return;
    }
    // A system colour's value depends on the element's color-scheme, so a value that names one is
    // held as text too, with the keyword spelled the way CSS serializes it — the computed value
    // resolves the colour, while style.color and cssText show the name.
    const canonical = prop.startsWith("--") ? value : canonicalSystemColors(prop, value);
    // A custom property, or a value that uses one: held as text, compiled when the element's
    // custom properties are known.
    const textImage = prop === "background-image" && hasTextImage(value);
    if (prop.startsWith("--") || hasVar(value) || hasLightDark(value) || hasDeferredCurrentColor(value) || hasModernColor(prop, value) || textImage || canonical !== value) {
      // A value that isn't a <declaration-value> is a parse error: the declaration is dropped.
      if (validDeclarationValue(canonical)) {
        this.putText(prop, canonical, important);
        invalidateStyleOf(this.el);
      }
      return;
    }
    const out: Decl[] = [];
    const err = compileValue(prop, value, out, fonts, undefined, getSheetContent());
    // An invalid value leaves the property as it was, as in a browser.
    if (err !== null) return;
    for (const d of out) {
      // A CSS-wide keyword compiles to a declaration kept as text, which the style pass resolves
      // against the parent and the initial value once it has the property's longhands in hand.
      if (d.prop !== undefined) this.putText(d.prop, d.value === undefined ? "" : d.value, important);
      else this.put(d.p, d.v, d.u, important);
    }
    if (out.length > 0) invalidateStyleOf(this.el, true, this.compositesOnly(out));
  }

  /**
   * Whether this write only changes how the element composites: every declaration it made is
   * transform, translate, rotate, scale or opacity, and the transform-likes leave the containing
   * block the element already makes in place — a box that had no transform would move the
   * positioned descendants when it gained one, which is a layout. A frame that changes only these
   * updates the recorded layer instead of repainting the page, the way an animation of the same
   * properties does.
   */
  private compositesOnly(out: Decl[]): boolean {
    for (const d of out) {
      if (d.prop !== undefined) return false; // kept as text: it resolves to something unknown
      if (d.p === P.P_OPACITY) continue;
      if (d.p !== P.P_TRANSFORM && d.p !== P.P_TRANSLATE && d.p !== P.P_ROTATE && d.p !== P.P_SCALE)
        return false;
      if (!hasTransform(this.el)) return false;
    }
    return true;
  }

  private put(p: number, v: number, u: number, important: boolean): void {
    this.present = true;
    // A declaration written for this property name replaces the text one left behind by a
    // var() value of the same property.
    const name = P.PROPERTY_NAMES[p];
    for (let i = this.decls.length - 1; i >= 0; i--) {
      const d = this.decls[i];
      if (d.prop !== undefined && d.prop === name) this.decls.splice(i, 1);
    }
    for (const d of this.decls) {
      if (d.p === p) {
        d.v = v;
        d.u = u;
        d.important = important;
        return;
      }
    }
    this.decls.push({ p, v, u, important });
  }

  /**
   * Sets a declaration kept as text. It replaces a numeric declaration of the same property, and
   * a shorthand replaces every longhand it covers, as a shorthand declaration does.
   */
  private putText(prop: string, value: string, important: boolean): void {
    this.present = true;
    const ids = longhandIds(prop);
    for (let i = this.decls.length - 1; i >= 0; i--) {
      const d = this.decls[i];
      if (d.prop !== undefined) {
        // A text declaration for the same name is replaced; one for a shorthand that covers a
        // longhand of this declaration is left where it is, so the later one still wins.
        if (d.prop === prop) this.decls.splice(i, 1);
        continue;
      }
      if (ids !== null && ids.indexOf(d.p) >= 0) this.decls.splice(i, 1);
    }
    this.decls.push({ p: -1, v: 0, u: 0, important, prop, value });
  }

  /** Removes the text declarations that set one of `ids` (or are written as `name`). */
  private dropText(name: string, ids: number[]): boolean {
    let removed = false;
    for (let i = this.decls.length - 1; i >= 0; i--) {
      const d = this.decls[i];
      if (d.prop === undefined) continue;
      let covers = d.prop === name;
      if (!covers) {
        const theirs = longhandIds(d.prop);
        if (theirs !== null) for (const p of ids) if (theirs.indexOf(p) >= 0) covers = true;
      }
      if (covers) {
        this.decls.splice(i, 1);
        removed = true;
      }
    }
    return removed;
  }

  private removeId(p: number): boolean {
    for (let i = 0; i < this.decls.length; i++) {
      if (this.decls[i].p === p) {
        this.decls.splice(i, 1);
        return true;
      }
    }
    return false;
  }

  /** A shorthand's value from its longhands, or "" when some of them aren't set. */
  private shorthand(name: string, ids: number[]): string {
    if (!this.computed) {
      // A var() value of the shorthand itself is reported as written.
      for (let i = this.decls.length - 1; i >= 0; i--) {
        const d = this.decls[i];
        if (d.prop === name) return d.value === undefined ? "" : d.value;
      }
    }
    if (name === "border-radius") return this.radiusText();
    // `transition` and `animation` write their lists layer by layer, cycling the shorter ones.
    if (name === "transition" || name === "animation") return this.listShorthand(ids);
    const texts: string[] = [];
    for (const p of ids) {
      const t = this.longhand(p);
      if (t === "") return "";
      texts.push(t);
    }
    if (name === "margin" || name === "padding" || name === "inset" || name === "border-width" || name === "border-color" || name === "border-style" || name === "border-radius") {
      return boxText(texts, name !== "border-radius");
    }
    // A logical border side reads width, style, colour, as the shorthand was written; an axis
    // form writes both sides as one value when they agree.
    if (name === "border-block-start" || name === "border-block-end" || name === "border-inline-start" || name === "border-inline-end") {
      return texts[0] + " " + texts[1] + " " + texts[2];
    }
    if (name === "border-block-width" || name === "border-block-style" || name === "border-block-color" ||
      name === "border-inline-width" || name === "border-inline-style" || name === "border-inline-color") {
      return texts[0] === texts[1] ? texts[0] : texts[0] + " " + texts[1];
    }
    if (name === "border-block" || name === "border-inline") {
      const start = texts[0] + " " + texts[1] + " " + texts[2];
      const end = texts[3] + " " + texts[4] + " " + texts[5];
      return start === end ? start : start + " " + end;
    }
    if (name === "border-top" || name === "border-right" || name === "border-bottom" || name === "border-left") {
      return texts[0] + " " + texts[1] + " " + texts[2];
    }
    if (name === "border") {
      const side = texts[0] + " " + texts[1] + " " + texts[2];
      for (let k = 3; k < 12; k += 3) {
        if (texts[k] + " " + texts[k + 1] + " " + texts[k + 2] !== side) return "";
      }
      return side;
    }
    if (name === "gap") return boxText(texts, false);
    // A logical shorthand writes its start value, and the end one only when they differ.
    if (name === "margin-block" || name === "margin-inline" || name === "padding-block" ||
      name === "padding-inline" || name === "inset-block" || name === "inset-inline") {
      return texts[0] === texts[1] ? texts[0] : texts[0] + " " + texts[1];
    }
    // overflow serializes both keywords only when the axes differ, as the browser does.
    if (name === "overflow") return texts[0] === texts[1] ? texts[0] : texts[0] + " " + texts[1];
    // `container` writes its names, then the type after a slash.
    if (name === "container") return texts[0] + " / " + texts[1];
    if (name === "flex" || name === "list-style") return texts.join(" ");
    if (name === "font-synthesis") {
      const kinds = ["weight", "style", "small-caps"];
      const parts: string[] = [];
      for (let i = 0; i < kinds.length; i++) if (texts[i] !== "none") parts.push(kinds[i]);
      return parts.length === 0 ? "none" : parts.join(" ");
    }
    // `font` writes the parts that differ from their initial values, then the size (with a line
    // height after a slash when it isn't normal) and the family, as a browser serializes it.
    if (name === "font") {
      const parts: string[] = [];
      if (texts[0] !== "normal") parts.push(texts[0]);
      if (texts[1] !== "400") parts.push(texts[1]);
      // The shorthand writes a stretch percentage as its keyword, and leaves normal out.
      const st = texts[2];
      let stretch = "normal";
      if (st !== "") {
        if (st.endsWith("%")) {
          // A percentage that is no keyword stops the shorthand serializing at all.
          stretch = stretchKeyword(Number(st.slice(0, -1)));
          if (stretch.endsWith("%")) return "";
        } else {
          stretch = st;
        }
      }
      if (stretch !== "normal") parts.push(stretch);
      const size = texts[3] === "" ? "0px" : texts[3];
      parts.push(texts[4] === "normal" ? size : size + " / " + texts[4]);
      parts.push(texts[5]);
      return parts.join(" ");
    }
    // A variant is the longhands that aren't normal, in the order browsers serialize them:
    // ligatures, caps, alternates, numeric, east-asian and position last.
    if (name === "font-variant") {
      const order = [1, 0, 5, 2, 3, 4];
      const parts: string[] = [];
      for (const k of order) if (texts[k] !== "normal") parts.push(texts[k]);
      return parts.length === 0 ? "normal" : parts.join(" ");
    }
    // The emphasis shorthand is the mark, then the colour it draws in.
    if (name === "text-emphasis") return texts[0] + " " + texts[1];
    // A grid placement prints its sides separated by slashes: `1 / span 2`.
    if (name === "grid-column" || name === "grid-row" || name === "grid-area") return texts.join(" / ");
    // A place-* shorthand writes both axes only when they differ.
    if (name === "place-content" || name === "place-items" || name === "place-self") {
      return texts[0] === texts[1] ? texts[0] : texts[0] + " " + texts[1];
    }
    // text-wrap says the mode only when it doesn't wrap, and then the style if it isn't auto.
    if (name === "text-wrap") {
      if (texts[1] === "auto") return texts[0];
      return texts[0] === "nowrap" ? texts[0] + " " + texts[1] : texts[1];
    }
    // Outlines serialize in CSS's order: color, style, width.
    if (name === "outline") return texts[2] + " " + texts[0] + " " + texts[1];
    // A decoration writes its line, then the thickness, style and colour that aren't initial, in
    // that order, as a browser does.
    if (name === "text-decoration") {
      const parts = [texts[0]];
      if (texts[3] !== "auto") parts.push(texts[3]);
      if (texts[1] !== "solid") parts.push(texts[1]);
      const current = this.computed ? this.el.sv[P.P_TEXT_DECORATION_COLOR] < 0 : texts[2].toLowerCase() === "currentcolor";
      if (!current) parts.push(texts[2]);
      return parts.join(" ");
    }
    return texts[0];
  }

  /** The raw items of a list property set on this object; empty when it isn't set. */
  private listItems(p: number): number[] {
    if (this.computed) return valueList(p, this.el.sv[p], this.el.su[p]);
    for (const d of this.decls) if (d.p === p) return valueList(p, d.v, d.u);
    return [];
  }

  /** A list shorthand: one space-separated group per layer, the shorter lists cycling. */
  private listShorthand(ids: number[]): string {
    const lists: number[][] = [];
    let layers = 0;
    for (const p of ids) {
      const items = this.listItems(p);
      if (items.length === 0) return "";
      lists.push(items);
      if (items.length > layers) layers = items.length;
    }
    let out = "";
    for (let i = 0; i < layers; i++) {
      if (i > 0) out += ", ";
      for (let k = 0; k < ids.length; k++) {
        if (k > 0) out += " ";
        const items = lists[k];
        out += itemText(ids[k], items[i % items.length]);
      }
    }
    return out;
  }

  /** One corner's radius: "10px", or "10px 20px" when the vertical radius differs. */
  private cornerText(corner: number): string {
    const x = this.longhand(RADIUS_CORNERS[corner][0]);
    const y = this.longhand(RADIUS_CORNERS[corner][1]);
    if (x === "" || y === "") return "";
    return x === y ? x : x + " " + y;
  }

  /** `border-radius`: the four corners, with a slash-separated list when an axis's radii differ. */
  private radiusText(): string {
    const hx: string[] = [];
    const vy: string[] = [];
    for (const c of RADIUS_CORNERS) {
      const x = this.longhand(c[0]);
      const y = this.longhand(c[1]);
      if (x === "" || y === "") return "";
      hx.push(x);
      vy.push(y);
    }
    let elliptical = false;
    for (let k = 0; k < 4; k++) if (hx[k] !== vy[k]) elliptical = true;
    return elliptical ? boxText(hx, true) + " / " + boxText(vy, true) : boxText(hx, true);
  }

  /** One longhand's value from this object: computed, or as set inline. */
  private longhand(p: number): string {
    if (!this.computed) {
      // A var() value of the property itself is reported as written.
      const name = P.PROPERTY_NAMES[p];
      for (let i = this.decls.length - 1; i >= 0; i--) {
        const d = this.decls[i];
        if (d.prop !== undefined && d.prop === name) return d.value === undefined ? "" : d.value;
      }
    }
    // A computed position axis falls back to the background-position row when the longhand
    // doesn't set it; an unset one is 0% (left/top), as the initial value says.
    if ((p === P.P_BACKGROUND_POSITION_X || p === P.P_BACKGROUND_POSITION_Y) && this.computed) {
      const vertical = p === P.P_BACKGROUND_POSITION_Y;
      const own = this.el.sv[p];
      if (this.el.su[p] === P.U_LIST && own >= 0) return backgroundAxisText(own, vertical);
      const pos = this.el.sv[P.P_BACKGROUND_POSITION];
      if (this.el.su[P.P_BACKGROUND_POSITION] === P.U_LIST && pos >= 0) return backgroundAxisText(pos, vertical);
      return "0%";
    }
    // content is a generated-content list, which needs the element attr() reads from.
    if (p === P.P_CONTENT) return contentValue(this.el, this.computed ? this.el.sv[p] : this.declValue(p));
    if (p === P.P_BOX_SHADOW) {
      if (this.computed) return shadowText(this.el, this.el.sv[p]);
      for (const d of this.decls) if (d.p === p) return shadowText(this.el, d.v);
      return "";
    }
    if (p === P.P_TEXT_SHADOW) {
      if (this.computed) return textShadowText(this.el, this.el.sv[p]);
      for (const d of this.decls) if (d.p === p) return textShadowText(this.el, d.v);
      return "";
    }
    if (p === P.P_FILTER || p === P.P_BACKDROP_FILTER) {
      if (this.computed) return filterText(this.el, this.el.sv[p]);
      for (const d of this.decls) if (d.p === p) return filterText(this.el, d.v);
      return "";
    }
    // The computed transform is the matrix it resolves to, as browsers report it; the specified
    // one is the function list as written, which is what a read of style.transform answers.
    if (p === P.P_TRANSFORM) {
      if (this.computed) return transformCss(this.el);
      for (const d of this.decls) if (d.p === p) return valueText(d.p, d.v, d.u, -1);
      return "";
    }
    if (p === P.P_TRANSFORM_ORIGIN) {
      // A computed origin is resolved against the laid out box; an inline one is reported as
      // written, like every other inline declaration.
      if (this.computed) return originCss(this.el);
      for (const d of this.decls) if (d.p === p) return valueText(d.p, d.v, d.u, -1);
      return "";
    }
    // The individual transform properties compute with their relative lengths resolved, keeping
    // percentages, as browsers report them: `translate` of calc(0.25rem * 4) reads back "16px".
    if (p === P.P_TRANSLATE || p === P.P_ROTATE || p === P.P_SCALE) {
      if (this.computed) return individualCss(this.el, p);
      for (const d of this.decls) if (d.p === p) return valueText(d.p, d.v, d.u, -1);
      return "";
    }
    if (p === P.P_OVERFLOW_CLIP_MARGIN) {
      if (this.computed) return clipMarginCss(this.el, this.el.sv[p], this.el.su[p], true);
      for (const d of this.decls) if (d.p === p) return clipMarginCss(this.el, d.v, d.u, false);
      return "";
    }
    // text-decoration-inset writes its two values as one declaration, and drops the second when
    // both sides share it.
    if (p === P.P_TEXT_DECORATION_INSET) {
      let a: number[] = [0, P.U_AUTO];
      let b: number[] = [0, P.U_AUTO];
      if (this.computed) {
        a = [this.el.sv[p], this.el.su[p]];
        b = [this.el.sv[P.P_TEXT_DECORATION_INSET_END], this.el.su[P.P_TEXT_DECORATION_INSET_END]];
      } else {
        let sawA = false;
        for (const d of this.decls) {
          if (d.p === p) { a = [d.v, d.u]; sawA = true; }
          else if (d.p === P.P_TEXT_DECORATION_INSET_END) b = [d.v, d.u];
        }
        if (!sawA) return "";
      }
      const first = valueText(p, a[0], a[1], -1);
      if (a[0] === b[0] && a[1] === b[1]) return first;
      return first + " " + valueText(p, b[0], b[1], -1);
    }
    // A computed font size is a length, not the keyword it was declared with: `medium` has already
    // been resolved to this family's size (13px for `monospace`, 16px otherwise).
    if (p === P.P_FONT_SIZE && this.computed && this.el.su[p] === P.U_MEDIUM) {
      return lengthText(this.el.sv[p], P.U_PX);
    }
    if (this.computed) {
      // A logical side shares its computed value with the physical side its axes name, so the
      // read comes from that side's slot rather than the logical one, which is only a record of
      // the declaration the cascade saw.
      const physical = logicalPhysicalProp(this.el, p);
      const q = physical >= 0 ? physical : p;
      // A modern colour function's computed value is its own form, not the packed colour.
      const form = this.el.colorForm !== null ? this.el.colorForm.get(q) : undefined;
      if (form !== undefined) return form;
      // A background layer list's text comes from its row, which only the painter's tables know.
      if (bgTextHook !== null) {
        const bgText = bgTextHook(this.el, q);
        if (bgText !== null) return bgText;
      }
      return valueText(q, this.el.sv[q], this.el.su[q], this.el.sv[P.P_COLOR], true);
    }
    // An inline value reads back as it was written: the last declaration naming the property,
    // whether it compiled to numbers or is kept as text (a var() value, a CSS-wide keyword).
    for (let i = this.decls.length - 1; i >= 0; i--) {
      const d = this.decls[i];
      if (d.prop !== undefined) {
        if (P.propertyId(d.prop) === p) return d.value === undefined ? "" : d.value;
        continue;
      }
      if (d.p === p) return valueText(p, d.v, d.u, -1);
    }
    return "";
  }

  /** A value set inline: the last declaration for the property, or -1 when unset. */
  private declValue(p: number): number {
    for (const d of this.decls) if (d.p === p) return d.v;
    return -1;
  }

  // --- camelCase properties ---------------------------------------------------

  get display(): string { return this.getPropertyValue('display'); }
  get visibility(): string { return this.getPropertyValue('visibility'); }
  set visibility(value: string) { this.setProperty('visibility', value); }
  set display(value: string) { this.setProperty('display', value); }

  get flexDirection(): string { return this.getPropertyValue('flex-direction'); }
  set flexDirection(value: string) { this.setProperty('flex-direction', value); }

  get justifyContent(): string { return this.getPropertyValue('justify-content'); }
  set justifyContent(value: string) { this.setProperty('justify-content', value); }

  get alignItems(): string { return this.getPropertyValue('align-items'); }
  set alignItems(value: string) { this.setProperty('align-items', value); }

  get rowGap(): string { return this.getPropertyValue('row-gap'); }
  set rowGap(value: string) { this.setProperty('row-gap', value); }

  get columnGap(): string { return this.getPropertyValue('column-gap'); }
  set columnGap(value: string) { this.setProperty('column-gap', value); }

  get flexGrow(): string { return this.getPropertyValue('flex-grow'); }
  set flexGrow(value: string) { this.setProperty('flex-grow', value); }

  get flexShrink(): string { return this.getPropertyValue('flex-shrink'); }
  set flexShrink(value: string) { this.setProperty('flex-shrink', value); }

  get flexBasis(): string { return this.getPropertyValue('flex-basis'); }
  set flexBasis(value: string) { this.setProperty('flex-basis', value); }

  get flexWrap(): string { return this.getPropertyValue('flex-wrap'); }
  set flexWrap(value: string) { this.setProperty('flex-wrap', value); }

  get alignContent(): string { return this.getPropertyValue('align-content'); }
  set alignContent(value: string) { this.setProperty('align-content', value); }

  get gridTemplateColumns(): string { return this.getPropertyValue('grid-template-columns'); }
  set gridTemplateColumns(value: string) { this.setProperty('grid-template-columns', value); }

  get gridTemplateRows(): string { return this.getPropertyValue('grid-template-rows'); }
  set gridTemplateRows(value: string) { this.setProperty('grid-template-rows', value); }

  get gridAutoColumns(): string { return this.getPropertyValue('grid-auto-columns'); }
  set gridAutoColumns(value: string) { this.setProperty('grid-auto-columns', value); }

  get gridAutoRows(): string { return this.getPropertyValue('grid-auto-rows'); }
  set gridAutoRows(value: string) { this.setProperty('grid-auto-rows', value); }

  get gridAutoFlow(): string { return this.getPropertyValue('grid-auto-flow'); }
  set gridAutoFlow(value: string) { this.setProperty('grid-auto-flow', value); }

  get gridTemplateAreas(): string { return this.getPropertyValue('grid-template-areas'); }
  set gridTemplateAreas(value: string) { this.setProperty('grid-template-areas', value); }

  get gridColumn(): string { return this.getPropertyValue('grid-column'); }
  set gridColumn(value: string) { this.setProperty('grid-column', value); }

  get gridRow(): string { return this.getPropertyValue('grid-row'); }
  set gridRow(value: string) { this.setProperty('grid-row', value); }

  get gridColumnStart(): string { return this.getPropertyValue('grid-column-start'); }
  set gridColumnStart(value: string) { this.setProperty('grid-column-start', value); }

  get gridColumnEnd(): string { return this.getPropertyValue('grid-column-end'); }
  set gridColumnEnd(value: string) { this.setProperty('grid-column-end', value); }

  get gridRowStart(): string { return this.getPropertyValue('grid-row-start'); }
  set gridRowStart(value: string) { this.setProperty('grid-row-start', value); }

  get gridRowEnd(): string { return this.getPropertyValue('grid-row-end'); }
  set gridRowEnd(value: string) { this.setProperty('grid-row-end', value); }

  get gridArea(): string { return this.getPropertyValue('grid-area'); }
  set gridArea(value: string) { this.setProperty('grid-area', value); }

  get justifyItems(): string { return this.getPropertyValue('justify-items'); }
  set justifyItems(value: string) { this.setProperty('justify-items', value); }

  get justifySelf(): string { return this.getPropertyValue('justify-self'); }
  set justifySelf(value: string) { this.setProperty('justify-self', value); }

  get placeContent(): string { return this.getPropertyValue('place-content'); }
  set placeContent(value: string) { this.setProperty('place-content', value); }

  get placeItems(): string { return this.getPropertyValue('place-items'); }
  set placeItems(value: string) { this.setProperty('place-items', value); }

  get placeSelf(): string { return this.getPropertyValue('place-self'); }
  set placeSelf(value: string) { this.setProperty('place-self', value); }

  get order(): string { return this.getPropertyValue('order'); }
  set order(value: string) { this.setProperty('order', value); }

  get width(): string { return this.getPropertyValue('width'); }
  set width(value: string) { this.setProperty('width', value); }

  get height(): string { return this.getPropertyValue('height'); }
  set height(value: string) { this.setProperty('height', value); }

  get minWidth(): string { return this.getPropertyValue('min-width'); }
  set minWidth(value: string) { this.setProperty('min-width', value); }

  get maxWidth(): string { return this.getPropertyValue('max-width'); }
  set maxWidth(value: string) { this.setProperty('max-width', value); }

  get minHeight(): string { return this.getPropertyValue('min-height'); }
  set minHeight(value: string) { this.setProperty('min-height', value); }

  get maxHeight(): string { return this.getPropertyValue('max-height'); }
  set maxHeight(value: string) { this.setProperty('max-height', value); }

  get marginTop(): string { return this.getPropertyValue('margin-top'); }
  set marginTop(value: string) { this.setProperty('margin-top', value); }

  get marginRight(): string { return this.getPropertyValue('margin-right'); }
  set marginRight(value: string) { this.setProperty('margin-right', value); }

  get marginBottom(): string { return this.getPropertyValue('margin-bottom'); }
  set marginBottom(value: string) { this.setProperty('margin-bottom', value); }

  get marginLeft(): string { return this.getPropertyValue('margin-left'); }
  set marginLeft(value: string) { this.setProperty('margin-left', value); }

  get paddingTop(): string { return this.getPropertyValue('padding-top'); }
  set paddingTop(value: string) { this.setProperty('padding-top', value); }

  get paddingRight(): string { return this.getPropertyValue('padding-right'); }
  set paddingRight(value: string) { this.setProperty('padding-right', value); }

  get paddingBottom(): string { return this.getPropertyValue('padding-bottom'); }
  set paddingBottom(value: string) { this.setProperty('padding-bottom', value); }

  get paddingLeft(): string { return this.getPropertyValue('padding-left'); }
  set paddingLeft(value: string) { this.setProperty('padding-left', value); }

  get borderTopWidth(): string { return this.getPropertyValue('border-top-width'); }
  set borderTopWidth(value: string) { this.setProperty('border-top-width', value); }

  get borderRightWidth(): string { return this.getPropertyValue('border-right-width'); }
  set borderRightWidth(value: string) { this.setProperty('border-right-width', value); }

  get borderBottomWidth(): string { return this.getPropertyValue('border-bottom-width'); }
  set borderBottomWidth(value: string) { this.setProperty('border-bottom-width', value); }

  get borderLeftWidth(): string { return this.getPropertyValue('border-left-width'); }
  set borderLeftWidth(value: string) { this.setProperty('border-left-width', value); }

  get borderTopColor(): string { return this.getPropertyValue('border-top-color'); }
  set borderTopColor(value: string) { this.setProperty('border-top-color', value); }

  get borderRightColor(): string { return this.getPropertyValue('border-right-color'); }
  set borderRightColor(value: string) { this.setProperty('border-right-color', value); }

  get borderBottomColor(): string { return this.getPropertyValue('border-bottom-color'); }
  set borderBottomColor(value: string) { this.setProperty('border-bottom-color', value); }

  get borderLeftColor(): string { return this.getPropertyValue('border-left-color'); }
  set borderLeftColor(value: string) { this.setProperty('border-left-color', value); }

  get borderRadius(): string { return this.getPropertyValue('border-radius'); }
  set borderRadius(value: string) { this.setProperty('border-radius', value); }

  get borderTopLeftRadius(): string { return this.getPropertyValue('border-top-left-radius'); }
  set borderTopLeftRadius(value: string) { this.setProperty('border-top-left-radius', value); }

  get borderTopRightRadius(): string { return this.getPropertyValue('border-top-right-radius'); }
  set borderTopRightRadius(value: string) { this.setProperty('border-top-right-radius', value); }

  get borderBottomRightRadius(): string { return this.getPropertyValue('border-bottom-right-radius'); }
  set borderBottomRightRadius(value: string) { this.setProperty('border-bottom-right-radius', value); }

  get borderBottomLeftRadius(): string { return this.getPropertyValue('border-bottom-left-radius'); }
  set borderBottomLeftRadius(value: string) { this.setProperty('border-bottom-left-radius', value); }

  get backgroundColor(): string { return this.getPropertyValue('background-color'); }
  set backgroundColor(value: string) { this.setProperty('background-color', value); }

  get color(): string { return this.getPropertyValue('color'); }
  set color(value: string) { this.setProperty('color', value); }

  get fontSize(): string { return this.getPropertyValue('font-size'); }
  set fontSize(value: string) { this.setProperty('font-size', value); }

  get fontWeight(): string { return this.getPropertyValue('font-weight'); }
  set fontWeight(value: string) { this.setProperty('font-weight', value); }

  get lineHeight(): string { return this.getPropertyValue('line-height'); }
  set lineHeight(value: string) { this.setProperty('line-height', value); }

  get textAlign(): string { return this.getPropertyValue('text-align'); }
  set textAlign(value: string) { this.setProperty('text-align', value); }

  get textJustify(): string { return this.getPropertyValue('text-justify'); }
  set textJustify(value: string) { this.setProperty('text-justify', value); }

  get direction(): string { return this.getPropertyValue('direction'); }
  set direction(value: string) { this.setProperty('direction', value); }

  get writingMode(): string { return this.getPropertyValue('writing-mode'); }
  set writingMode(value: string) { this.setProperty('writing-mode', value); }

  get textTransform(): string { return this.getPropertyValue('text-transform'); }
  set textTransform(value: string) { this.setProperty('text-transform', value); }

  get letterSpacing(): string { return this.getPropertyValue('letter-spacing'); }
  set letterSpacing(value: string) { this.setProperty('letter-spacing', value); }

  get wordSpacing(): string { return this.getPropertyValue('word-spacing'); }
  set wordSpacing(value: string) { this.setProperty('word-spacing', value); }

  get textIndent(): string { return this.getPropertyValue('text-indent'); }
  set textIndent(value: string) { this.setProperty('text-indent', value); }

  get tabSize(): string { return this.getPropertyValue('tab-size'); }
  set tabSize(value: string) { this.setProperty('tab-size', value); }

  get textOverflow(): string { return this.getPropertyValue('text-overflow'); }
  set textOverflow(value: string) { this.setProperty('text-overflow', value); }

  get overflowWrap(): string { return this.getPropertyValue('overflow-wrap'); }
  set overflowWrap(value: string) { this.setProperty('overflow-wrap', value); }

  get wordBreak(): string { return this.getPropertyValue('word-break'); }
  set wordBreak(value: string) { this.setProperty('word-break', value); }
  get hyphens(): string { return this.getPropertyValue('hyphens'); }
  set hyphens(value: string) { this.setProperty('hyphens', value); }
  get textWrap(): string { return this.getPropertyValue('text-wrap'); }
  set textWrap(value: string) { this.setProperty('text-wrap', value); }
  get textWrapMode(): string { return this.getPropertyValue('text-wrap-mode'); }
  set textWrapMode(value: string) { this.setProperty('text-wrap-mode', value); }
  get textWrapStyle(): string { return this.getPropertyValue('text-wrap-style'); }
  set textWrapStyle(value: string) { this.setProperty('text-wrap-style', value); }

  get textShadow(): string { return this.getPropertyValue('text-shadow'); }
  set textShadow(value: string) { this.setProperty('text-shadow', value); }

  get cursor(): string { return this.getPropertyValue('cursor'); }
  set cursor(value: string) { this.setProperty('cursor', value); }

  get boxSizing(): string { return this.getPropertyValue('box-sizing'); }
  set boxSizing(value: string) { this.setProperty('box-sizing', value); }

  get opacity(): string { return this.getPropertyValue('opacity'); }
  set opacity(value: string) { this.setProperty('opacity', value); }

  get alignSelf(): string { return this.getPropertyValue('align-self'); }
  set alignSelf(value: string) { this.setProperty('align-self', value); }

  get overflow(): string { return this.getPropertyValue('overflow'); }
  set overflow(value: string) { this.setProperty('overflow', value); }

  get textDecoration(): string { return this.getPropertyValue('text-decoration'); }
  set textDecoration(value: string) { this.setProperty('text-decoration', value); }

  get fontStyle(): string { return this.getPropertyValue('font-style'); }
  set fontStyle(value: string) { this.setProperty('font-style', value); }

  get position(): string { return this.getPropertyValue('position'); }
  set position(value: string) { this.setProperty('position', value); }

  get top(): string { return this.getPropertyValue('top'); }
  set top(value: string) { this.setProperty('top', value); }

  get right(): string { return this.getPropertyValue('right'); }
  set right(value: string) { this.setProperty('right', value); }

  get bottom(): string { return this.getPropertyValue('bottom'); }
  set bottom(value: string) { this.setProperty('bottom', value); }

  get left(): string { return this.getPropertyValue('left'); }
  set left(value: string) { this.setProperty('left', value); }

  get fontFamily(): string { return this.getPropertyValue('font-family'); }
  set fontFamily(value: string) { this.setProperty('font-family', value); }

  get fontFeatureSettings(): string { return this.getPropertyValue('font-feature-settings'); }
  set fontFeatureSettings(value: string) { this.setProperty('font-feature-settings', value); }

  get fontVariationSettings(): string { return this.getPropertyValue('font-variation-settings'); }
  set fontVariationSettings(value: string) { this.setProperty('font-variation-settings', value); }

  get fontSynthesis(): string { return this.getPropertyValue('font-synthesis'); }
  set fontSynthesis(value: string) { this.setProperty('font-synthesis', value); }

  get fontKerning(): string { return this.getPropertyValue('font-kerning'); }
  set fontKerning(value: string) { this.setProperty('font-kerning', value); }

  get fontLanguageOverride(): string { return this.getPropertyValue('font-language-override'); }
  set fontLanguageOverride(value: string) { this.setProperty('font-language-override', value); }

  get fontOpticalSizing(): string { return this.getPropertyValue('font-optical-sizing'); }
  set fontOpticalSizing(value: string) { this.setProperty('font-optical-sizing', value); }

  get fontSizeAdjust(): string { return this.getPropertyValue('font-size-adjust'); }
  set fontSizeAdjust(value: string) { this.setProperty('font-size-adjust', value); }

  get fontStretch(): string { return this.getPropertyValue('font-stretch'); }
  set fontStretch(value: string) { this.setProperty('font-stretch', value); }

  get fontSynthesisWeight(): string { return this.getPropertyValue('font-synthesis-weight'); }
  set fontSynthesisWeight(value: string) { this.setProperty('font-synthesis-weight', value); }

  get fontSynthesisStyle(): string { return this.getPropertyValue('font-synthesis-style'); }
  set fontSynthesisStyle(value: string) { this.setProperty('font-synthesis-style', value); }

  get fontSynthesisSmallCaps(): string { return this.getPropertyValue('font-synthesis-small-caps'); }
  set fontSynthesisSmallCaps(value: string) { this.setProperty('font-synthesis-small-caps', value); }

  get fontVariantEmoji(): string { return this.getPropertyValue('font-variant-emoji'); }
  set fontVariantEmoji(value: string) { this.setProperty('font-variant-emoji', value); }

  get textUnderlinePosition(): string { return this.getPropertyValue('text-underline-position'); }
  set textUnderlinePosition(value: string) { this.setProperty('text-underline-position', value); }

  get textDecorationSkipInk(): string { return this.getPropertyValue('text-decoration-skip-ink'); }
  set textDecorationSkipInk(value: string) { this.setProperty('text-decoration-skip-ink', value); }

  get whiteSpaceCollapse(): string { return this.getPropertyValue('white-space-collapse'); }
  set whiteSpaceCollapse(value: string) { this.setProperty('white-space-collapse', value); }

  get textBoxTrim(): string { return this.getPropertyValue('text-box-trim'); }
  set textBoxTrim(value: string) { this.setProperty('text-box-trim', value); }

  get textBoxEdge(): string { return this.getPropertyValue('text-box-edge'); }
  set textBoxEdge(value: string) { this.setProperty('text-box-edge', value); }

  get initialLetter(): string { return this.getPropertyValue('initial-letter'); }
  set initialLetter(value: string) { this.setProperty('initial-letter', value); }

  get alignmentBaseline(): string { return this.getPropertyValue('alignment-baseline'); }
  set alignmentBaseline(value: string) { this.setProperty('alignment-baseline', value); }

  get baselineShift(): string { return this.getPropertyValue('baseline-shift'); }
  set baselineShift(value: string) { this.setProperty('baseline-shift', value); }

  get dominantBaseline(): string { return this.getPropertyValue('dominant-baseline'); }
  set dominantBaseline(value: string) { this.setProperty('dominant-baseline', value); }

  get fontPalette(): string { return this.getPropertyValue('font-palette'); }
  set fontPalette(value: string) { this.setProperty('font-palette', value); }

  get fontVariant(): string { return this.getPropertyValue('font-variant'); }
  set fontVariant(value: string) { this.setProperty('font-variant', value); }

  get fontVariantCaps(): string { return this.getPropertyValue('font-variant-caps'); }
  set fontVariantCaps(value: string) { this.setProperty('font-variant-caps', value); }

  get fontVariantLigatures(): string { return this.getPropertyValue('font-variant-ligatures'); }
  set fontVariantLigatures(value: string) { this.setProperty('font-variant-ligatures', value); }

  get fontVariantNumeric(): string { return this.getPropertyValue('font-variant-numeric'); }
  set fontVariantNumeric(value: string) { this.setProperty('font-variant-numeric', value); }

  get fontVariantEastAsian(): string { return this.getPropertyValue('font-variant-east-asian'); }
  set fontVariantEastAsian(value: string) { this.setProperty('font-variant-east-asian', value); }

  get fontVariantPosition(): string { return this.getPropertyValue('font-variant-position'); }
  set fontVariantPosition(value: string) { this.setProperty('font-variant-position', value); }

  get fontVariantAlternates(): string { return this.getPropertyValue('font-variant-alternates'); }
  set fontVariantAlternates(value: string) { this.setProperty('font-variant-alternates', value); }

  get whiteSpace(): string { return this.getPropertyValue('white-space'); }
  set whiteSpace(value: string) { this.setProperty('white-space', value); }

  get zIndex(): string { return this.getPropertyValue('z-index'); }
  set zIndex(value: string) { this.setProperty('z-index', value); }

  get appearance(): string { return this.getPropertyValue('appearance'); }
  set appearance(value: string) { this.setProperty('appearance', value); }

  get accentColor(): string { return this.getPropertyValue('accent-color'); }
  set accentColor(value: string) { this.setProperty('accent-color', value); }

  get caretColor(): string { return this.getPropertyValue('caret-color'); }
  set caretColor(value: string) { this.setProperty('caret-color', value); }

  get caretShape(): string { return this.getPropertyValue('caret-shape'); }
  set caretShape(value: string) { this.setProperty('caret-shape', value); }

  get resize(): string { return this.getPropertyValue('resize'); }
  set resize(value: string) { this.setProperty('resize', value); }

  get interactivity(): string { return this.getPropertyValue('interactivity'); }
  set interactivity(value: string) { this.setProperty('interactivity', value); }
  get touchAction(): string { return this.getPropertyValue('touch-action'); }
  set touchAction(value: string) { this.setProperty('touch-action', value); }

  get pointerEvents(): string { return this.getPropertyValue('pointer-events'); }
  set pointerEvents(value: string) { this.setProperty('pointer-events', value); }

  get userSelect(): string { return this.getPropertyValue('user-select'); }
  set userSelect(value: string) { this.setProperty('user-select', value); }

  /** The prefixed spelling of `user-select`, the same property. */
  get webkitUserSelect(): string { return this.getPropertyValue('-webkit-user-select'); }
  set webkitUserSelect(value: string) { this.setProperty('-webkit-user-select', value); }

  get verticalAlign(): string { return this.getPropertyValue('vertical-align'); }
  set verticalAlign(value: string) { this.setProperty('vertical-align', value); }

  get content(): string { return this.getPropertyValue('content'); }
  set content(value: string) { this.setProperty('content', value); }

  get listStyleType(): string { return this.getPropertyValue('list-style-type'); }
  set listStyleType(value: string) { this.setProperty('list-style-type', value); }

  get listStylePosition(): string { return this.getPropertyValue('list-style-position'); }
  set listStylePosition(value: string) { this.setProperty('list-style-position', value); }

  get listStyleImage(): string { return this.getPropertyValue('list-style-image'); }
  set listStyleImage(value: string) { this.setProperty('list-style-image', value); }

  get listStyle(): string { return this.getPropertyValue('list-style'); }
  set listStyle(value: string) { this.setProperty('list-style', value); }

  get outlineStyle(): string { return this.getPropertyValue('outline-style'); }
  set outlineStyle(value: string) { this.setProperty('outline-style', value); }

  get outlineWidth(): string { return this.getPropertyValue('outline-width'); }
  set outlineWidth(value: string) { this.setProperty('outline-width', value); }

  get outlineColor(): string { return this.getPropertyValue('outline-color'); }
  set outlineColor(value: string) { this.setProperty('outline-color', value); }

  get outlineOffset(): string { return this.getPropertyValue('outline-offset'); }
  set outlineOffset(value: string) { this.setProperty('outline-offset', value); }

  get outline(): string { return this.getPropertyValue('outline'); }
  set outline(value: string) { this.setProperty('outline', value); }

  get margin(): string { return this.getPropertyValue('margin'); }
  set margin(value: string) { this.setProperty('margin', value); }

  get padding(): string { return this.getPropertyValue('padding'); }
  set padding(value: string) { this.setProperty('padding', value); }

  get inset(): string { return this.getPropertyValue('inset'); }
  set inset(value: string) { this.setProperty('inset', value); }

  get border(): string { return this.getPropertyValue('border'); }
  set border(value: string) { this.setProperty('border', value); }

  get borderTop(): string { return this.getPropertyValue('border-top'); }
  set borderTop(value: string) { this.setProperty('border-top', value); }

  get borderRight(): string { return this.getPropertyValue('border-right'); }
  set borderRight(value: string) { this.setProperty('border-right', value); }

  get borderBottom(): string { return this.getPropertyValue('border-bottom'); }
  set borderBottom(value: string) { this.setProperty('border-bottom', value); }

  get borderLeft(): string { return this.getPropertyValue('border-left'); }
  set borderLeft(value: string) { this.setProperty('border-left', value); }

  get borderWidth(): string { return this.getPropertyValue('border-width'); }
  set borderWidth(value: string) { this.setProperty('border-width', value); }

  get borderStyle(): string { return this.getPropertyValue('border-style'); }
  set borderStyle(value: string) { this.setProperty('border-style', value); }

  get borderColor(): string { return this.getPropertyValue('border-color'); }
  set borderColor(value: string) { this.setProperty('border-color', value); }

  get boxShadow(): string { return this.getPropertyValue('box-shadow'); }
  set boxShadow(value: string) { this.setProperty('box-shadow', value); }

  get filter(): string { return this.getPropertyValue('filter'); }
  set filter(value: string) { this.setProperty('filter', value); }

  get backdropFilter(): string { return this.getPropertyValue('backdrop-filter'); }
  set backdropFilter(value: string) { this.setProperty('backdrop-filter', value); }

  get mixBlendMode(): string { return this.getPropertyValue('mix-blend-mode'); }
  set mixBlendMode(value: string) { this.setProperty('mix-blend-mode', value); }

  get isolation(): string { return this.getPropertyValue('isolation'); }
  set isolation(value: string) { this.setProperty('isolation', value); }

  get clipPath(): string { return this.getPropertyValue('clip-path'); }
  set clipPath(value: string) { this.setProperty('clip-path', value); }

  get transform(): string { return this.getPropertyValue('transform'); }
  set transform(value: string) { this.setProperty('transform', value); }

  get transformOrigin(): string { return this.getPropertyValue('transform-origin'); }
  set transformOrigin(value: string) { this.setProperty('transform-origin', value); }

  get translate(): string { return this.getPropertyValue('translate'); }
  set translate(value: string) { this.setProperty('translate', value); }

  get rotate(): string { return this.getPropertyValue('rotate'); }
  set rotate(value: string) { this.setProperty('rotate', value); }

  get scale(): string { return this.getPropertyValue('scale'); }
  set scale(value: string) { this.setProperty('scale', value); }

  get background(): string { return this.getPropertyValue('background'); }
  set background(value: string) { this.setProperty('background', value); }

  get maskImage(): string { return this.getPropertyValue('mask-image'); }
  set maskImage(value: string) { this.setProperty('mask-image', value); }

  get maskRepeat(): string { return this.getPropertyValue('mask-repeat'); }
  set maskRepeat(value: string) { this.setProperty('mask-repeat', value); }

  get maskPosition(): string { return this.getPropertyValue('mask-position'); }
  set maskPosition(value: string) { this.setProperty('mask-position', value); }

  get maskSize(): string { return this.getPropertyValue('mask-size'); }
  set maskSize(value: string) { this.setProperty('mask-size', value); }

  get maskOrigin(): string { return this.getPropertyValue('mask-origin'); }
  set maskOrigin(value: string) { this.setProperty('mask-origin', value); }

  get maskClip(): string { return this.getPropertyValue('mask-clip'); }
  set maskClip(value: string) { this.setProperty('mask-clip', value); }

  get mask(): string { return this.getPropertyValue('mask'); }
  set mask(value: string) { this.setProperty('mask', value); }
  get backgroundImage(): string { return this.getPropertyValue('background-image'); }
  set backgroundImage(value: string) { this.setProperty('background-image', value); }

  get backgroundRepeat(): string { return this.getPropertyValue('background-repeat'); }
  set backgroundRepeat(value: string) { this.setProperty('background-repeat', value); }

  get backgroundAttachment(): string { return this.getPropertyValue('background-attachment'); }
  set backgroundAttachment(value: string) { this.setProperty('background-attachment', value); }

  get backgroundPosition(): string { return this.getPropertyValue('background-position'); }
  set backgroundPosition(value: string) { this.setProperty('background-position', value); }

  get backgroundSize(): string { return this.getPropertyValue('background-size'); }
  set backgroundSize(value: string) { this.setProperty('background-size', value); }

  get backgroundOrigin(): string { return this.getPropertyValue('background-origin'); }
  set backgroundOrigin(value: string) { this.setProperty('background-origin', value); }

  get backgroundClip(): string { return this.getPropertyValue('background-clip'); }
  set backgroundClip(value: string) { this.setProperty('background-clip', value); }

  get objectFit(): string { return this.getPropertyValue('object-fit'); }
  set objectFit(value: string) { this.setProperty('object-fit', value); }

  get objectPosition(): string { return this.getPropertyValue('object-position'); }
  set objectPosition(value: string) { this.setProperty('object-position', value); }

  get imageRendering(): string { return this.getPropertyValue('image-rendering'); }
  set imageRendering(value: string) { this.setProperty('image-rendering', value); }

  get imageOrientation(): string { return this.getPropertyValue('image-orientation'); }
  set imageOrientation(value: string) { this.setProperty('image-orientation', value); }

  get container(): string { return this.getPropertyValue('container'); }
  set container(value: string) { this.setProperty('container', value); }

  get containerType(): string { return this.getPropertyValue('container-type'); }
  set containerType(value: string) { this.setProperty('container-type', value); }

  get containerName(): string { return this.getPropertyValue('container-name'); }
  set containerName(value: string) { this.setProperty('container-name', value); }

  get gap(): string { return this.getPropertyValue('gap'); }
  set gap(value: string) { this.setProperty('gap', value); }

  get flex(): string { return this.getPropertyValue('flex'); }
  set flex(value: string) { this.setProperty('flex', value); }

  get font(): string { return this.getPropertyValue('font'); }
  set font(value: string) { this.setProperty('font', value); }

  get overflowX(): string { return this.getPropertyValue('overflow-x'); }
  set overflowX(value: string) { this.setProperty('overflow-x', value); }

  get overflowY(): string { return this.getPropertyValue('overflow-y'); }
  set overflowY(value: string) { this.setProperty('overflow-y', value); }

  get scrollBehavior(): string { return this.getPropertyValue('scroll-behavior'); }
  set scrollBehavior(value: string) { this.setProperty('scroll-behavior', value); }

  get overscrollBehaviorX(): string { return this.getPropertyValue('overscroll-behavior-x'); }
  set overscrollBehaviorX(value: string) { this.setProperty('overscroll-behavior-x', value); }
  get overscrollBehaviorY(): string { return this.getPropertyValue('overscroll-behavior-y'); }
  set overscrollBehaviorY(value: string) { this.setProperty('overscroll-behavior-y', value); }
  get overscrollBehaviorBlock(): string { return this.getPropertyValue('overscroll-behavior-block'); }
  set overscrollBehaviorBlock(value: string) { this.setProperty('overscroll-behavior-block', value); }
  get overscrollBehaviorInline(): string { return this.getPropertyValue('overscroll-behavior-inline'); }
  set overscrollBehaviorInline(value: string) { this.setProperty('overscroll-behavior-inline', value); }
  get scrollbarGutter(): string { return this.getPropertyValue('scrollbar-gutter'); }
  set scrollbarGutter(value: string) { this.setProperty('scrollbar-gutter', value); }
  get scrollbarWidth(): string { return this.getPropertyValue('scrollbar-width'); }
  set scrollbarWidth(value: string) { this.setProperty('scrollbar-width', value); }
  get scrollbarColor(): string { return this.getPropertyValue('scrollbar-color'); }
  set scrollbarColor(value: string) { this.setProperty('scrollbar-color', value); }
  get scrollSnapAlign(): string { return this.getPropertyValue('scroll-snap-align'); }
  set scrollSnapAlign(value: string) { this.setProperty('scroll-snap-align', value); }
  get scrollSnapStop(): string { return this.getPropertyValue('scroll-snap-stop'); }
  set scrollSnapStop(value: string) { this.setProperty('scroll-snap-stop', value); }
  get marginTrim(): string { return this.getPropertyValue('margin-trim'); }
  set marginTrim(value: string) { this.setProperty('margin-trim', value); }
  get contentVisibility(): string { return this.getPropertyValue('content-visibility'); }
  set contentVisibility(value: string) { this.setProperty('content-visibility', value); }
  get boxDecorationBreak(): string { return this.getPropertyValue('box-decoration-break'); }
  set boxDecorationBreak(value: string) { this.setProperty('box-decoration-break', value); }

  // The insets a scroll stops short by, on the box brought into view and on the container.
  get scrollMarginTop(): string { return this.getPropertyValue('scroll-margin-top'); }
  set scrollMarginTop(value: string) { this.setProperty('scroll-margin-top', value); }
  get scrollMarginRight(): string { return this.getPropertyValue('scroll-margin-right'); }
  set scrollMarginRight(value: string) { this.setProperty('scroll-margin-right', value); }
  get scrollMarginBottom(): string { return this.getPropertyValue('scroll-margin-bottom'); }
  set scrollMarginBottom(value: string) { this.setProperty('scroll-margin-bottom', value); }
  get scrollMarginLeft(): string { return this.getPropertyValue('scroll-margin-left'); }
  set scrollMarginLeft(value: string) { this.setProperty('scroll-margin-left', value); }
  get scrollPaddingTop(): string { return this.getPropertyValue('scroll-padding-top'); }
  set scrollPaddingTop(value: string) { this.setProperty('scroll-padding-top', value); }
  get scrollPaddingRight(): string { return this.getPropertyValue('scroll-padding-right'); }
  set scrollPaddingRight(value: string) { this.setProperty('scroll-padding-right', value); }
  get scrollPaddingBottom(): string { return this.getPropertyValue('scroll-padding-bottom'); }
  set scrollPaddingBottom(value: string) { this.setProperty('scroll-padding-bottom', value); }
  get scrollPaddingLeft(): string { return this.getPropertyValue('scroll-padding-left'); }
  set scrollPaddingLeft(value: string) { this.setProperty('scroll-padding-left', value); }
  get scrollMarginBlockStart(): string { return this.getPropertyValue('scroll-margin-block-start'); }
  set scrollMarginBlockStart(value: string) { this.setProperty('scroll-margin-block-start', value); }
  get scrollMarginBlockEnd(): string { return this.getPropertyValue('scroll-margin-block-end'); }
  set scrollMarginBlockEnd(value: string) { this.setProperty('scroll-margin-block-end', value); }
  get scrollMarginInlineStart(): string { return this.getPropertyValue('scroll-margin-inline-start'); }
  set scrollMarginInlineStart(value: string) { this.setProperty('scroll-margin-inline-start', value); }
  get scrollMarginInlineEnd(): string { return this.getPropertyValue('scroll-margin-inline-end'); }
  set scrollMarginInlineEnd(value: string) { this.setProperty('scroll-margin-inline-end', value); }
  get scrollPaddingBlockStart(): string { return this.getPropertyValue('scroll-padding-block-start'); }
  set scrollPaddingBlockStart(value: string) { this.setProperty('scroll-padding-block-start', value); }
  get scrollPaddingBlockEnd(): string { return this.getPropertyValue('scroll-padding-block-end'); }
  set scrollPaddingBlockEnd(value: string) { this.setProperty('scroll-padding-block-end', value); }
  get scrollPaddingInlineStart(): string { return this.getPropertyValue('scroll-padding-inline-start'); }
  set scrollPaddingInlineStart(value: string) { this.setProperty('scroll-padding-inline-start', value); }
  get scrollPaddingInlineEnd(): string { return this.getPropertyValue('scroll-padding-inline-end'); }
  set scrollPaddingInlineEnd(value: string) { this.setProperty('scroll-padding-inline-end', value); }

  get textDecorationLine(): string { return this.getPropertyValue('text-decoration-line'); }
  set textDecorationLine(value: string) { this.setProperty('text-decoration-line', value); }

  get textDecorationStyle(): string { return this.getPropertyValue('text-decoration-style'); }
  set textDecorationStyle(value: string) { this.setProperty('text-decoration-style', value); }

  get textDecorationColor(): string { return this.getPropertyValue('text-decoration-color'); }
  set textDecorationColor(value: string) { this.setProperty('text-decoration-color', value); }

  get textDecorationThickness(): string { return this.getPropertyValue('text-decoration-thickness'); }
  set textDecorationThickness(value: string) { this.setProperty('text-decoration-thickness', value); }

  get textUnderlineOffset(): string { return this.getPropertyValue('text-underline-offset'); }
  set textUnderlineOffset(value: string) { this.setProperty('text-underline-offset', value); }

  get textEmphasis(): string { return this.getPropertyValue('text-emphasis'); }
  set textEmphasis(value: string) { this.setProperty('text-emphasis', value); }

  get textEmphasisStyle(): string { return this.getPropertyValue('text-emphasis-style'); }
  set textEmphasisStyle(value: string) { this.setProperty('text-emphasis-style', value); }

  get textEmphasisColor(): string { return this.getPropertyValue('text-emphasis-color'); }
  set textEmphasisColor(value: string) { this.setProperty('text-emphasis-color', value); }

  get textEmphasisPosition(): string { return this.getPropertyValue('text-emphasis-position'); }
  set textEmphasisPosition(value: string) { this.setProperty('text-emphasis-position', value); }

  get lineClamp(): string { return this.getPropertyValue('line-clamp'); }
  set lineClamp(value: string) { this.setProperty('line-clamp', value); }

  get webkitLineClamp(): string { return this.getPropertyValue('-webkit-line-clamp'); }
  set webkitLineClamp(value: string) { this.setProperty('-webkit-line-clamp', value); }

  get borderTopStyle(): string { return this.getPropertyValue('border-top-style'); }
  set borderTopStyle(value: string) { this.setProperty('border-top-style', value); }

  get borderRightStyle(): string { return this.getPropertyValue('border-right-style'); }
  set borderRightStyle(value: string) { this.setProperty('border-right-style', value); }

  get borderBottomStyle(): string { return this.getPropertyValue('border-bottom-style'); }
  set borderBottomStyle(value: string) { this.setProperty('border-bottom-style', value); }

  get borderLeftStyle(): string { return this.getPropertyValue('border-left-style'); }
  set borderLeftStyle(value: string) { this.setProperty('border-left-style', value); }

  // The rest of the properties this build parses: tables, a float and its clear, the shape a clip
  // leaves, an element's aspect ratio, the SVG paint properties and the regions that drag a window.
  // A property native doesn't parse has no accessor, so naming one is a type error, as the top of
  // the runtime's DOM says.

  get tableLayout(): string { return this.getPropertyValue('table-layout'); }
  set tableLayout(value: string) { this.setProperty('table-layout', value); }

  get borderCollapse(): string { return this.getPropertyValue('border-collapse'); }
  set borderCollapse(value: string) { this.setProperty('border-collapse', value); }

  get borderSpacing(): string { return this.getPropertyValue('border-spacing'); }
  set borderSpacing(value: string) { this.setProperty('border-spacing', value); }

  get captionSide(): string { return this.getPropertyValue('caption-side'); }
  set captionSide(value: string) { this.setProperty('caption-side', value); }

  get emptyCells(): string { return this.getPropertyValue('empty-cells'); }
  set emptyCells(value: string) { this.setProperty('empty-cells', value); }

  get float(): string { return this.getPropertyValue('float'); }
  set float(value: string) { this.setProperty('float', value); }

  // `clear` has no accessor here: the name is the declaration's own clear(), which drops every
  // declaration, so the property is read and written with getPropertyValue() and setProperty().

  get clip(): string { return this.getPropertyValue('clip'); }
  set clip(value: string) { this.setProperty('clip', value); }

  get aspectRatio(): string { return this.getPropertyValue('aspect-ratio'); }
  set aspectRatio(value: string) { this.setProperty('aspect-ratio', value); }

  get fill(): string { return this.getPropertyValue('fill'); }
  set fill(value: string) { this.setProperty('fill', value); }

  get fillOpacity(): string { return this.getPropertyValue('fill-opacity'); }
  set fillOpacity(value: string) { this.setProperty('fill-opacity', value); }

  get fillRule(): string { return this.getPropertyValue('fill-rule'); }
  set fillRule(value: string) { this.setProperty('fill-rule', value); }

  get stroke(): string { return this.getPropertyValue('stroke'); }
  set stroke(value: string) { this.setProperty('stroke', value); }

  get strokeOpacity(): string { return this.getPropertyValue('stroke-opacity'); }
  set strokeOpacity(value: string) { this.setProperty('stroke-opacity', value); }

  get strokeWidth(): string { return this.getPropertyValue('stroke-width'); }
  set strokeWidth(value: string) { this.setProperty('stroke-width', value); }

  get strokeLinecap(): string { return this.getPropertyValue('stroke-linecap'); }
  set strokeLinecap(value: string) { this.setProperty('stroke-linecap', value); }

  get strokeLinejoin(): string { return this.getPropertyValue('stroke-linejoin'); }
  set strokeLinejoin(value: string) { this.setProperty('stroke-linejoin', value); }

  get strokeDasharray(): string { return this.getPropertyValue('stroke-dasharray'); }
  set strokeDasharray(value: string) { this.setProperty('stroke-dasharray', value); }

  get strokeDashoffset(): string { return this.getPropertyValue('stroke-dashoffset'); }
  set strokeDashoffset(value: string) { this.setProperty('stroke-dashoffset', value); }

  get overflowClipMargin(): string { return this.getPropertyValue('overflow-clip-margin'); }
  set overflowClipMargin(value: string) { this.setProperty('overflow-clip-margin', value); }

  get appRegion(): string { return this.getPropertyValue('app-region'); }
  set appRegion(value: string) { this.setProperty('app-region', value); }

  /** The prefixed spelling of `appearance`, the same property. */
  get webkitAppearance(): string { return this.getPropertyValue('-webkit-appearance'); }
  set webkitAppearance(value: string) { this.setProperty('-webkit-appearance', value); }

  // The rest of the properties this build parses, named the way a script writes them. They are
  // written out rather than derived at run time because scriptc has no lowering for a computed
  // accessor on a class (issue 40), and because an accessor is what makes an unparsed property a
  // build error; tests/props.ts fails when a property has no accessor here.

  get transitionProperty(): string { return this.getPropertyValue('transition-property'); }
  set transitionProperty(value: string) { this.setProperty('transition-property', value); }

  get transitionDuration(): string { return this.getPropertyValue('transition-duration'); }
  set transitionDuration(value: string) { this.setProperty('transition-duration', value); }

  get transitionTimingFunction(): string { return this.getPropertyValue('transition-timing-function'); }
  set transitionTimingFunction(value: string) { this.setProperty('transition-timing-function', value); }

  get transitionDelay(): string { return this.getPropertyValue('transition-delay'); }
  set transitionDelay(value: string) { this.setProperty('transition-delay', value); }

  get transitionBehavior(): string { return this.getPropertyValue('transition-behavior'); }
  set transitionBehavior(value: string) { this.setProperty('transition-behavior', value); }

  get animation(): string { return this.getPropertyValue('animation'); }
  set animation(value: string) { this.setProperty('animation', value); }

  get animationName(): string { return this.getPropertyValue('animation-name'); }
  set animationName(value: string) { this.setProperty('animation-name', value); }

  get animationDuration(): string { return this.getPropertyValue('animation-duration'); }
  set animationDuration(value: string) { this.setProperty('animation-duration', value); }

  get animationTimingFunction(): string { return this.getPropertyValue('animation-timing-function'); }
  set animationTimingFunction(value: string) { this.setProperty('animation-timing-function', value); }

  get animationDelay(): string { return this.getPropertyValue('animation-delay'); }
  set animationDelay(value: string) { this.setProperty('animation-delay', value); }

  get animationIterationCount(): string { return this.getPropertyValue('animation-iteration-count'); }
  set animationIterationCount(value: string) { this.setProperty('animation-iteration-count', value); }

  get animationDirection(): string { return this.getPropertyValue('animation-direction'); }
  set animationDirection(value: string) { this.setProperty('animation-direction', value); }

  get animationFillMode(): string { return this.getPropertyValue('animation-fill-mode'); }
  set animationFillMode(value: string) { this.setProperty('animation-fill-mode', value); }

  get animationPlayState(): string { return this.getPropertyValue('animation-play-state'); }
  set animationPlayState(value: string) { this.setProperty('animation-play-state', value); }

  get counterReset(): string { return this.getPropertyValue('counter-reset'); }
  set counterReset(value: string) { this.setProperty('counter-reset', value); }

  get counterIncrement(): string { return this.getPropertyValue('counter-increment'); }
  set counterIncrement(value: string) { this.setProperty('counter-increment', value); }

  get counterSet(): string { return this.getPropertyValue('counter-set'); }
  set counterSet(value: string) { this.setProperty('counter-set', value); }

  get borderImageSource(): string { return this.getPropertyValue('border-image-source'); }
  set borderImageSource(value: string) { this.setProperty('border-image-source', value); }

  get borderImageSlice(): string { return this.getPropertyValue('border-image-slice'); }
  set borderImageSlice(value: string) { this.setProperty('border-image-slice', value); }

  get borderImageWidth(): string { return this.getPropertyValue('border-image-width'); }
  set borderImageWidth(value: string) { this.setProperty('border-image-width', value); }

  get borderImageOutset(): string { return this.getPropertyValue('border-image-outset'); }
  set borderImageOutset(value: string) { this.setProperty('border-image-outset', value); }

  get borderImageRepeat(): string { return this.getPropertyValue('border-image-repeat'); }
  set borderImageRepeat(value: string) { this.setProperty('border-image-repeat', value); }

  get backgroundPositionX(): string { return this.getPropertyValue('background-position-x'); }
  set backgroundPositionX(value: string) { this.setProperty('background-position-x', value); }

  get backgroundPositionY(): string { return this.getPropertyValue('background-position-y'); }
  set backgroundPositionY(value: string) { this.setProperty('background-position-y', value); }

  get transformBox(): string { return this.getPropertyValue('transform-box'); }
  set transformBox(value: string) { this.setProperty('transform-box', value); }

  get transformStyle(): string { return this.getPropertyValue('transform-style'); }
  set transformStyle(value: string) { this.setProperty('transform-style', value); }

  get blockEllipsis(): string { return this.getPropertyValue('block-ellipsis'); }
  set blockEllipsis(value: string) { this.setProperty('block-ellipsis', value); }

  get cursorImage(): string { return this.getPropertyValue('cursor-image'); }
  set cursorImage(value: string) { this.setProperty('cursor-image', value); }

  get cursorImageX(): string { return this.getPropertyValue('cursor-image-x'); }
  set cursorImageX(value: string) { this.setProperty('cursor-image-x', value); }

  get cursorImageY(): string { return this.getPropertyValue('cursor-image-y'); }
  set cursorImageY(value: string) { this.setProperty('cursor-image-y', value); }

  get contain(): string { return this.getPropertyValue('contain'); }
  set contain(value: string) { this.setProperty('contain', value); }

  get gridLanesDirection(): string { return this.getPropertyValue('grid-lanes-direction'); }
  set gridLanesDirection(value: string) { this.setProperty('grid-lanes-direction', value); }

  get gridLanesPack(): string { return this.getPropertyValue('grid-lanes-pack'); }
  set gridLanesPack(value: string) { this.setProperty('grid-lanes-pack', value); }

  get fitTolerance(): string { return this.getPropertyValue('fit-tolerance'); }
  set fitTolerance(value: string) { this.setProperty('fit-tolerance', value); }

  get breakBefore(): string { return this.getPropertyValue('break-before'); }
  set breakBefore(value: string) { this.setProperty('break-before', value); }

  get breakAfter(): string { return this.getPropertyValue('break-after'); }
  set breakAfter(value: string) { this.setProperty('break-after', value); }

  get breakInside(): string { return this.getPropertyValue('break-inside'); }
  set breakInside(value: string) { this.setProperty('break-inside', value); }

  get orphans(): string { return this.getPropertyValue('orphans'); }
  set orphans(value: string) { this.setProperty('orphans', value); }

  get widows(): string { return this.getPropertyValue('widows'); }
  set widows(value: string) { this.setProperty('widows', value); }

  get printColorAdjust(): string { return this.getPropertyValue('print-color-adjust'); }
  set printColorAdjust(value: string) { this.setProperty('print-color-adjust', value); }

  get page(): string { return this.getPropertyValue('page'); }
  set page(value: string) { this.setProperty('page', value); }

  get columnCount(): string { return this.getPropertyValue('column-count'); }
  set columnCount(value: string) { this.setProperty('column-count', value); }

  get columnWidth(): string { return this.getPropertyValue('column-width'); }
  set columnWidth(value: string) { this.setProperty('column-width', value); }

  get columnFill(): string { return this.getPropertyValue('column-fill'); }
  set columnFill(value: string) { this.setProperty('column-fill', value); }

  get columnSpan(): string { return this.getPropertyValue('column-span'); }
  set columnSpan(value: string) { this.setProperty('column-span', value); }

  get columnRuleWidth(): string { return this.getPropertyValue('column-rule-width'); }
  set columnRuleWidth(value: string) { this.setProperty('column-rule-width', value); }

  get columnRuleStyle(): string { return this.getPropertyValue('column-rule-style'); }
  set columnRuleStyle(value: string) { this.setProperty('column-rule-style', value); }

  get columnRuleColor(): string { return this.getPropertyValue('column-rule-color'); }
  set columnRuleColor(value: string) { this.setProperty('column-rule-color', value); }

  get columnHeight(): string { return this.getPropertyValue('column-height'); }
  set columnHeight(value: string) { this.setProperty('column-height', value); }

  get columnWrap(): string { return this.getPropertyValue('column-wrap'); }
  set columnWrap(value: string) { this.setProperty('column-wrap', value); }

  get textOrientation(): string { return this.getPropertyValue('text-orientation'); }
  set textOrientation(value: string) { this.setProperty('text-orientation', value); }

  get lineBreak(): string { return this.getPropertyValue('line-break'); }
  set lineBreak(value: string) { this.setProperty('line-break', value); }

// The logical border sides, as the style object names them.
  get borderBlockStartWidth(): string { return this.getPropertyValue('border-block-start-width'); }
  set borderBlockStartWidth(value: string) { this.setProperty('border-block-start-width', value); }
  get borderBlockEndWidth(): string { return this.getPropertyValue('border-block-end-width'); }
  set borderBlockEndWidth(value: string) { this.setProperty('border-block-end-width', value); }
  get borderInlineStartWidth(): string { return this.getPropertyValue('border-inline-start-width'); }
  set borderInlineStartWidth(value: string) { this.setProperty('border-inline-start-width', value); }
  get borderInlineEndWidth(): string { return this.getPropertyValue('border-inline-end-width'); }
  set borderInlineEndWidth(value: string) { this.setProperty('border-inline-end-width', value); }
  get borderBlockStartStyle(): string { return this.getPropertyValue('border-block-start-style'); }
  set borderBlockStartStyle(value: string) { this.setProperty('border-block-start-style', value); }
  get borderBlockEndStyle(): string { return this.getPropertyValue('border-block-end-style'); }
  set borderBlockEndStyle(value: string) { this.setProperty('border-block-end-style', value); }
  get borderInlineStartStyle(): string { return this.getPropertyValue('border-inline-start-style'); }
  set borderInlineStartStyle(value: string) { this.setProperty('border-inline-start-style', value); }
  get borderInlineEndStyle(): string { return this.getPropertyValue('border-inline-end-style'); }
  set borderInlineEndStyle(value: string) { this.setProperty('border-inline-end-style', value); }
  get borderBlockStartColor(): string { return this.getPropertyValue('border-block-start-color'); }
  set borderBlockStartColor(value: string) { this.setProperty('border-block-start-color', value); }
  get borderBlockEndColor(): string { return this.getPropertyValue('border-block-end-color'); }
  set borderBlockEndColor(value: string) { this.setProperty('border-block-end-color', value); }
  get borderInlineStartColor(): string { return this.getPropertyValue('border-inline-start-color'); }
  set borderInlineStartColor(value: string) { this.setProperty('border-inline-start-color', value); }
  get borderInlineEndColor(): string { return this.getPropertyValue('border-inline-end-color'); }
  set borderInlineEndColor(value: string) { this.setProperty('border-inline-end-color', value); }

  // The logical sizes, as the style object names them.
  get inlineSize(): string { return this.getPropertyValue('inline-size'); }
  set inlineSize(value: string) { this.setProperty('inline-size', value); }
  get blockSize(): string { return this.getPropertyValue('block-size'); }
  set blockSize(value: string) { this.setProperty('block-size', value); }
  get minInlineSize(): string { return this.getPropertyValue('min-inline-size'); }
  set minInlineSize(value: string) { this.setProperty('min-inline-size', value); }
  get minBlockSize(): string { return this.getPropertyValue('min-block-size'); }
  set minBlockSize(value: string) { this.setProperty('min-block-size', value); }
  get maxInlineSize(): string { return this.getPropertyValue('max-inline-size'); }
  set maxInlineSize(value: string) { this.setProperty('max-inline-size', value); }
  get maxBlockSize(): string { return this.getPropertyValue('max-block-size'); }
  set maxBlockSize(value: string) { this.setProperty('max-block-size', value); }
  // The logical corners, as the style object names them.
  get borderStartStartRadius(): string { return this.getPropertyValue('border-start-start-radius'); }
  set borderStartStartRadius(value: string) { this.setProperty('border-start-start-radius', value); }
  get borderStartEndRadius(): string { return this.getPropertyValue('border-start-end-radius'); }
  set borderStartEndRadius(value: string) { this.setProperty('border-start-end-radius', value); }
  get borderEndStartRadius(): string { return this.getPropertyValue('border-end-start-radius'); }
  set borderEndStartRadius(value: string) { this.setProperty('border-end-start-radius', value); }
  get borderEndEndRadius(): string { return this.getPropertyValue('border-end-end-radius'); }
  set borderEndEndRadius(value: string) { this.setProperty('border-end-end-radius', value); }
  get marginBlockStart(): string { return this.getPropertyValue('margin-block-start'); }
  set marginBlockStart(value: string) { this.setProperty('margin-block-start', value); }

  get marginBlockEnd(): string { return this.getPropertyValue('margin-block-end'); }
  set marginBlockEnd(value: string) { this.setProperty('margin-block-end', value); }

  get marginInlineStart(): string { return this.getPropertyValue('margin-inline-start'); }
  set marginInlineStart(value: string) { this.setProperty('margin-inline-start', value); }

  get marginInlineEnd(): string { return this.getPropertyValue('margin-inline-end'); }
  set marginInlineEnd(value: string) { this.setProperty('margin-inline-end', value); }

  get paddingBlockStart(): string { return this.getPropertyValue('padding-block-start'); }
  set paddingBlockStart(value: string) { this.setProperty('padding-block-start', value); }

  get paddingBlockEnd(): string { return this.getPropertyValue('padding-block-end'); }
  set paddingBlockEnd(value: string) { this.setProperty('padding-block-end', value); }

  get paddingInlineStart(): string { return this.getPropertyValue('padding-inline-start'); }
  set paddingInlineStart(value: string) { this.setProperty('padding-inline-start', value); }

  get paddingInlineEnd(): string { return this.getPropertyValue('padding-inline-end'); }
  set paddingInlineEnd(value: string) { this.setProperty('padding-inline-end', value); }

  get insetBlockStart(): string { return this.getPropertyValue('inset-block-start'); }
  set insetBlockStart(value: string) { this.setProperty('inset-block-start', value); }

  get insetBlockEnd(): string { return this.getPropertyValue('inset-block-end'); }
  set insetBlockEnd(value: string) { this.setProperty('inset-block-end', value); }

  get insetInlineStart(): string { return this.getPropertyValue('inset-inline-start'); }
  set insetInlineStart(value: string) { this.setProperty('inset-inline-start', value); }

  get insetInlineEnd(): string { return this.getPropertyValue('inset-inline-end'); }
  set insetInlineEnd(value: string) { this.setProperty('inset-inline-end', value); }

  get animationComposition(): string { return this.getPropertyValue('animation-composition'); }
  set animationComposition(value: string) { this.setProperty('animation-composition', value); }
  get colorInterpolationFilters(): string { return this.getPropertyValue('color-interpolation-filters'); }
  set colorInterpolationFilters(value: string) { this.setProperty('color-interpolation-filters', value); }

  get floodColor(): string { return this.getPropertyValue('flood-color'); }
  set floodColor(value: string) { this.setProperty('flood-color', value); }

  get floodOpacity(): string { return this.getPropertyValue('flood-opacity'); }
  set floodOpacity(value: string) { this.setProperty('flood-opacity', value); }

  get lightingColor(): string { return this.getPropertyValue('lighting-color'); }
  set lightingColor(value: string) { this.setProperty('lighting-color', value); }

  get willChange(): string { return this.getPropertyValue('will-change'); }
  set willChange(value: string) { this.setProperty('will-change', value); }

  get shapeImageThreshold(): string { return this.getPropertyValue('shape-image-threshold'); }
  set shapeImageThreshold(value: string) { this.setProperty('shape-image-threshold', value); }

  get backgroundBlendMode(): string { return this.getPropertyValue('background-blend-mode'); }
  set backgroundBlendMode(value: string) { this.setProperty('background-blend-mode', value); }

  get perspective(): string { return this.getPropertyValue('perspective'); }
  set perspective(value: string) { this.setProperty('perspective', value); }

  get perspectiveOrigin(): string { return this.getPropertyValue('perspective-origin'); }
  set perspectiveOrigin(value: string) { this.setProperty('perspective-origin', value); }

  get backfaceVisibility(): string { return this.getPropertyValue('backface-visibility'); }
  set backfaceVisibility(value: string) { this.setProperty('backface-visibility', value); }

  get textAlignLast(): string { return this.getPropertyValue('text-align-last'); }
  set textAlignLast(value: string) { this.setProperty('text-align-last', value); }
  get colorScheme(): string { return this.getPropertyValue('color-scheme'); }
  set colorScheme(value: string) { this.setProperty('color-scheme', value); }

  get textDecorationInset(): string { return this.getPropertyValue('text-decoration-inset'); }
  set textDecorationInset(value: string) { this.setProperty('text-decoration-inset', value); }

  get scrollMarkerGroup(): string { return this.getPropertyValue('scroll-marker-group'); }
  set scrollMarkerGroup(value: string) { this.setProperty('scroll-marker-group', value); }

  get shapeOutside(): string { return this.getPropertyValue('shape-outside'); }
  set shapeOutside(value: string) { this.setProperty('shape-outside', value); }

  get shapeMargin(): string { return this.getPropertyValue('shape-margin'); }
  set shapeMargin(value: string) { this.setProperty('shape-margin', value); }
  // The transition shorthand: a script writes it as CSS does, and the four longhands it sets are
  // what the declaration keeps and reads back.
  get transition(): string { return this.getPropertyValue('transition'); }
  set transition(value: string) { this.setProperty('transition', value); }

  get scrollSnapType(): string { return this.getPropertyValue('scroll-snap-type'); }
  set scrollSnapType(value: string) { this.setProperty('scroll-snap-type', value); }
}

/**
 * The CSS property name a key of a declaration's view stands for: a custom property as written,
 * a camelCase name in its hyphenated spelling, or else a name the declaration knows — a property
 * or a shorthand over some of them. Null when the key is no property at all, which leaves the
 * declaration's own member to answer it. A script asks for the same few keys over and over, so
 * the answer is kept by key ("" stands for null).
 */
const NAMED_KEYS = new Map<string, string>();

function namedProperty(key: string): string | null {
  const hit = NAMED_KEYS.get(key);
  if (hit !== undefined) return hit === "" ? null : hit;
  let name: string | null;
  // The DOM's alias for `float`, since `float` was a reserved word when it was chosen.
  if (key === "cssFloat") name = "float";
  else if (key.startsWith("--")) name = key;
  else {
    const dashed = /[A-Z]/.test(key) ? key.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase()) : key;
    name = longhandIds(dashed) !== null ? dashed : null;
  }
  NAMED_KEYS.set(key, name === null ? "" : name);
  return name;
}

/**
 * The named-property view of a declaration, the way a browser's CSSStyleDeclaration answers to a
 * property name a script computes: `style["margin-left"]`, `style.marginLeft`, `style.cssFloat`,
 * `getComputedStyle(el)[prop]`. The declaration's own members (`cssText`, `length`, the methods)
 * answer as they are; every other name is looked up as the property it spells. One view is made
 * per declaration and kept on it, so a read costs a field and a trap.
 */
export function styleView(decl: StyleDeclaration): CSSStyleDeclaration {
  const made = decl.view;
  if (made !== null) return made;
  // The proxy stands in front of an empty object rather than the declaration itself: the traps
  // capture the declaration and answer for it (scriptc has no Proxy over a class instance).
  const view: any = new Proxy({} as any, {
    get(_t: any, key: string): any {
      const named = typeof key === "string" ? namedProperty(key) : null;
      if (named !== null) return decl.getPropertyValue(named);
      // The declaration's own members, each acting on the declaration the view was made for.
      if (key === "cssText") return decl.cssText;
      if (key === "length") return decl.length;
      if (key === "item") return (index: number) => decl.item(index);
      if (key === "getPropertyValue") return (name: string) => decl.getPropertyValue(name);
      if (key === "setProperty") return (name: string, value: any, priority?: any) => decl.setProperty(name, value, priority);
      if (key === "removeProperty") return (name: string) => decl.removeProperty(name);
      if (key === "getPropertyPriority") return () => "";
      if (key === "toString") return () => decl.cssText;
      return undefined;
    },
    set(_t: any, key: string, value: any): any {
      if (key === "cssText") {
        decl.setBlock(value === null || value === undefined ? "" : String(value));
        return true;
      }
      const named = typeof key === "string" ? namedProperty(key) : null;
      if (named !== null) decl.setProperty(named, value);
      return true;
    },
    has(_t: any, key: string): any {
      if (typeof key === "string" && namedProperty(key) !== null) return true;
      return key === "cssText" || key === "length" || key === "item" ||
        key === "getPropertyValue" || key === "setProperty" || key === "removeProperty";
    },
    deleteProperty(_t: any, key: string): any {
      const named = typeof key === "string" ? namedProperty(key) : null;
      if (named !== null) decl.removeProperty(named);
      return true;
    },
  });
  decl.view = view;
  return view;
}

/**
 * The computed style of an element, for the properties native supports. Style work that is
 * pending is done first, so a read right after setting a style sees the new value, as in a
 * browser. A pseudo-element argument ("::before"/":before", "::after"/":after", "::marker")
 * reads the generated box; without one, the element's own style.
 */
export function getComputedStyle(el: Element, pseudo: any = ""): CSSStyleDeclaration {
  flushComputedStyle(el);
  const kind = pseudoKindOf(pseudo === null || pseudo === undefined ? "" : String(pseudo));
  if (kind !== P.PE_NONE) {
    const box = pseudoBox(el, kind);
    if (box !== null) return styleView(box.computedStyle);
  }
  return styleView(el.computedStyle);
}

/**
 * A read of a computed value forces the pending style and layout, as a browser's does, and brings
 * the transitions and animations to the current time: a script at load reads the colours and
 * sizes the page has now, an animated value included.
 */
function flushComputedStyle(el: Element): void {
  if (el.isConnected) flushLayoutHook();
  // The tick runs first: a value that moved may leave the style pass below with an inherited
  // change to hand down.
  animationTick();
  if (dirty.style) {
    let root: any = el;
    // A shadow tree s element has no parentElement — its parent is the root — so the walk to the
    // page goes on through the host, and the pass styles the whole page rather than that element
    // alone as if it were the document root.
    for (;;) {
      const parent = root.parentElement;
      if (parent !== null) { root = parent; continue; }
      const up = root.parentNode;
      if (up instanceof ShadowRoot) { root = up.host; continue; }
      break;
    }
    // A detached tree isn't the page's, so reading it leaves the page's own style work pending;
    // clearing the flag here would skip it and paint stale styles. The flag goes before the
    // pass, so a request made during it (a moved inherited animation value) stays.
    if (root === document.documentElement) dirty.style = false;
    computeStyles(root, null);
  }
}

/** The PE_* kind a getComputedStyle pseudo argument names, or PE_NONE. */
function pseudoKindOf(pseudo: string): number {
  const name = pseudo.trim().toLowerCase();
  if (name === "::before" || name === ":before") return P.PE_BEFORE;
  if (name === "::after" || name === ":after") return P.PE_AFTER;
  if (name === "::marker" || name === ":marker") return P.PE_MARKER;
  if (name === "::placeholder") return P.PE_PLACEHOLDER;
  if (name === "::first-line" || name === ":first-line") return P.PE_FIRST_LINE;
  if (name === "::first-letter" || name === ":first-letter") return P.PE_FIRST_LETTER;
  if (name === "::selection") return P.PE_SELECTION;
  if (name === "::backdrop") return P.PE_BACKDROP;
  if (name === "::target-text") return P.PE_TARGET_TEXT;
  return P.PE_NONE;
}

/** The element's generated box (a pseudo child) of one kind, or null when it has none. */
function pseudoBox(el: Element, kind: number): Element | null {
  for (const c of el.kids) if (c.pseudoKind === kind && c instanceof Element) return c;
  return null;
}

// ---------------------------------------------------------------------------
// The CSS object: feature detection and escaping

/** Splits a condition on a top-level ` and `/` or `, outside parentheses and strings. */
function splitCondition(text: string, word: string): string[] {
  const sep = " " + word + " ";
  const out: string[] = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote !== "") {
      if (ch === "\\") i++;
      else if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0 && text.startsWith(sep, i)) {
      out.push(text.slice(start, i));
      i += sep.length - 1;
      start = i + 1;
    }
  }
  out.push(text.slice(start));
  return out;
}

/** Whether a condition text holds: a declaration in parentheses, with and/or/not around it. */
function supportsCondition(text: string): boolean {
  const t = text.trim();
  if (t === "") return false;
  if (t.toLowerCase().startsWith("not ")) return !supportsCondition(t.slice(4));
  const any = splitCondition(t, "or");
  if (any.length > 1) {
    for (const p of any) if (supportsCondition(p)) return true;
    return false;
  }
  const all = splitCondition(t, "and");
  if (all.length > 1) {
    for (const p of all) if (!supportsCondition(p)) return false;
    return true;
  }
  if (t.startsWith("(") && t.endsWith(")")) {
    const inner = t.slice(1, t.length - 1).trim();
    const colon = inner.indexOf(":");
    if (colon < 0) return supportsCondition(inner);
    return supportsDeclaration(inner.slice(0, colon), inner.slice(colon + 1));
  }
  // A lone declaration needs no parentheses: CSS.supports("display: flex") asks the same
  // question as the two-argument form, as browsers answer it.
  const colon = t.indexOf(":");
  if (colon >= 0) return supportsDeclaration(t.slice(0, colon), t.slice(colon + 1));
  // selector() asks whether a selector parses; the build-time parser isn't here, and no
  // supported condition needs it.
  return false;
}

/** Whether an `@counter-style` rule's text defines a style, as the same parser decides. */
function supportsCounterStyleRule(text: string): boolean {
  const m = /^@counter-style\s+([-_a-zA-Z\u0080-\uffff][-_a-zA-Z0-9\u0080-\uffff]*)\s*\{([\s\S]*)\}\s*$/.exec(text);
  if (m === null) return false;
  return typeof parseCounterStyle(m[1], m[2]) !== "string";
}

/** Whether one declaration compiles with the same parser the build uses. */
function supportsDeclaration(prop: string, value: string): boolean {
  const name = prop.trim();
  const lower = name.toLowerCase();
  // A custom property takes any declaration value, as its grammar is "<declaration-value>".
  if (lower.startsWith("--")) return customPropertyName(name) !== null && validDeclarationValue(value);
  const text = value.trim();
  if (lower === "" || text === "") return false;
  // A var() substitutes before the value is parsed, so the declaration is valid for now; a system
  // colour resolves through one at computed-value time, so it is valid the same way.
  if (hasVar(text) || hasLightDark(text) || hasDeferredCurrentColor(text) || withSystemColors(lower, text) !== text) return true;
  const out: Decl[] = [];
  return compileValue(lower, text, out) === null && out.length > 0;
}

const CSS_IDENT_START = /[a-zA-Z_\u0080-￿]/;

/**
 * The CSS object a script reads: feature detection over the same value parser the build uses,
 * `CSS.escape` for building selectors out of strings, and `CSS.registerProperty` for the
 * custom properties a page wants typed as non-inheriting or given an initial value.
 */
export const CSS = {
  /** The named highlights a page registers, which ::highlight() rules style. */
  highlights: highlights,

  supports(prop: string, value?: string): boolean {
    if (value === undefined) {
      // The one-argument form asks whether a whole condition or at-rule parses.
      const text = prop.trim();
      if (/^@counter-style\b/i.test(text)) return supportsCounterStyleRule(text);
      return supportsCondition(prop);
    }
    // The two-argument form names a property outright, so a name padded with spaces isn't one.
    // (In a condition's declaration a value may have spaces, and only that form is trimmed.)
    if (prop !== prop.trim()) return false;
    return supportsDeclaration(prop, value);
  },

  /** Escapes `text` as a CSS identifier, as the CSSOM's serialize-an-identifier does. */
  escape(text: string): string {
    let out = "";
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      const code = text.charCodeAt(i);
      if (code === 0) {
        out += "�";
        continue;
      }
      const leadingDigit = i === 0 && code >= 0x30 && code <= 0x39;
      const afterMinus = i === 1 && code >= 0x30 && code <= 0x39 && text.charCodeAt(0) === 0x2d;
      if ((code >= 1 && code <= 0x1f) || code === 0x7f || leadingDigit || afterMinus) {
        out += "\\" + code.toString(16) + " ";
        continue;
      }
      if (i === 0 && code === 0x2d && text.length === 1) {
        out += "\\-";
        continue;
      }
      if (code >= 0x80 || code === 0x2d || code === 0x5f || (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) {
        out += ch;
        continue;
      }
      out += "\\" + ch;
    }
    return out;
  },

  registerProperty(descriptor: { name: string; syntax?: string; inherits?: boolean; initialValue?: string }): void {
    const name = descriptor.name;
    if (customPropertyName(name) === null) throw new Error("SyntaxError: '" + name + "' is not a custom property name");
    if (registeredProperty(name) !== null) throw new Error("InvalidModificationError: '" + name + "' is already registered");
    const syntax = descriptor.syntax === undefined ? "*" : descriptor.syntax;
    const initial = descriptor.initialValue === undefined ? null : descriptor.initialValue;
    registerCustomProperty(name, syntax, descriptor.inherits === true, initial);
    invalidateStyle();
  },
};


// Compiled app tables, mounting them as a DOM, and the style/layout/paint frame pipeline.

import { DocumentType, HTMLElement, adoptImageSource, adoptMediaSource, HTMLInputElement, HTMLCanvasElement, HTMLTemplateElement, Node, ProcessingInstruction, Text, adoptDeclarativeIn, document, dirty, elementNamespace, invalidateStyle, newElementFor, setElementNamespace, setFocus, resetInput, pendingScrollIntoView, deliverResizeObservers, resetSelection, clearTopLayer, type Listener, type Event } from "../dom.ts";
import { setDocumentMode } from "../quirk.ts";
import { setPageCharset } from "../dom.ts";
import { clearPaintDamage, layoutEpoch, stateUsage, takeStyleRoots, paintMarkTrace } from "../invalidation.ts";
import { computeStyles, restyleSubtree, containerStale, disableCompiledSheet, resetCompiledText, setCompiledSheetOff, resetCounterStyles, resetDeviceMetrics, resetDisabledSheets, resetAppendedSubtreeCheck, refreshTextRunDependence, setFontFeatures, setFontPalettes, setFontVariations, tables, takeStartingDirty } from "../style.ts";
import { absolutePosition, layoutRoot, viewport, scrollIntoView, snapAfterLayout } from "../layout.ts";
import { resetMeasureCache } from "../layout/box-model.ts";
import { resetBreakCache } from "../layout/inline.ts";
import { resetMetricsCache } from "../layout/text.ts";
import { installGeometryQueries } from "../layout/geometry.ts";
import { paintRoot, paintRootDamage, paintRootReference, paintState, valueRangeGeometry } from "../paint.ts";
import { backgroundLonghandText } from "../background.ts";
import { setBgTextHook } from "../cssom.ts";
import { closeSelectPopup } from "../select-popup.ts";
import { resetHighlights } from "../highlights.ts";
import { readTargetText, resetTargetText } from "../target-text.ts";
import { axDirty, axGeometryDirty, flushAx, resetAx } from "../ax-tree.ts";
import { deliverIntersectionObservers } from "../intersection.ts";
import { hostBundleDir, hostRegisterFont, hostRegisterFontLocal, hostRegisterFontNamed, hostResetFonts } from "../host.ts";
import { firstFramePainted } from "./frame-ready.ts";
import { compositeDamage, compositeFrame, pendingDamageRects, pendingElements, resetCompositeDamage } from "../compositor.ts";
import { addBackdropDamage, addDamageRects, markDamageFull } from "../paint-damage.ts";
import { bg, resetRuntimeRows } from "../background.ts";
import { setBorderImageRows } from "../border-image.ts";
import { clipRows } from "../../shared/css/clip.ts";
import { clipPathRows } from "../../shared/css/clip-path.ts";
import { positionRows } from "../../shared/css/position.ts";
import { willChangeRows } from "../../shared/css/willchange.ts";
import { dashRows } from "../../shared/css/dasharray.ts";
import { exprRows } from "../../shared/css/length-exprs.ts";
import { originRows, transformRows } from "../../shared/css/transforms.ts";
import { clipMarginRows } from "../../shared/css/properties/box.ts";
import { shadowRows } from "../../shared/css/shadows.ts";
import { gridTracks } from "../grid.ts";
import { filterTables } from "../filters.ts";
import { animKeyframes, animNames, animRows } from "../../shared/css/anim.ts";
import { animationTick, flushAnimationEvents, resetAnimations, resetKeyframes } from "../animation.ts";
import { setImageBase, setImageFiles, setInlineImages, setSvgImages } from "../images.ts";
import { setFetchBase } from "../fetch.ts";
import { setStoreAppName } from "../sqlite.ts";
import { assetPath, assetRoot, setAssetRoot } from "../assets.ts";
import { setPaintUrls } from "../svg-paint.ts";
import * as P from "../../shared/props.ts";
import { pointer } from "./pointer.ts";
import { clearSmoothScrolls } from "./smooth.ts";
import { clearAdopted, refreshSheet, setSheetLiveSink } from "../sheets.ts";
import { applyWindowEnvironment, clearAllTimers, window, reportUnhandledRejection } from "../window.ts";
import { clearLiveCollections, clearLiveRanges, setValueRangeGeometryHook } from "../dom.ts";
import { resetAccessibleProperties } from "../a11y.ts";
import { clearRegistrations, registerCustomProperty } from "../registered.ts";
import { setFlushLayoutHook } from "../layout-flush-hook.ts";
import { audioFrameHook } from "../audio-hook.ts";
import { endFrame, frameClock, frameTimes } from "../frame-times.ts";
import { hostDamageReference, hostLayerCount } from "../host.ts";
import { beginDamageFrame, computeDamage, damage, damageVerify, endDamageFrame } from "../paint-damage.ts";

// The offset queries read layout through the dom module, so they are wired in once every module
// is up, before the app's first frame.
installGeometryQueries();

/** The compiled app, filled in by the generated boot module. */
export interface AppTables {
  /** The app's files were copied into a bundle beside the executable, and the paths in the
   *  tables are relative to it. */
  bundled?: boolean;
  /** The page was XHTML, so its document is an XML one (createCDATASection works on it). */
  xmlDocument?: boolean;
  title: string;
  width: number;
  height: number;
  /** The document mode the doctype selects: 0 no-quirks, 1 quirks, 2 limited-quirks. */
  quirks: number;
  /** The encoding the page's own markup declares (a meta charset), lowercased. */
  charset?: string;
  ruleClasses: string[][];
  ruleStates: number[];
  /** True for a rule whose declarations set a custom property (or hold a var()). */
  ruleCustoms?: boolean[];
  ruleNthStart: number[][];
  ruleNthEnd: number[][];
  /** The "of S" filter of each :nth-child() condition ("" for none). */
  ruleNthStartOf?: string[][];
  ruleNthEndOf?: string[][];
  ruleAttrs: string[][];
  /** :lang() ranges on each rule's subject compound. */
  ruleLang?: string[][];
  ruleNots: string[][];
  /** :not() arguments that are complex selectors. */
  ruleNotSels?: string[][];
  ruleHas: string[][];
  /** True for a rule whose subject compound is :empty. */
  ruleEmpty?: boolean[];
  /** True for each ancestor link whose compound is :empty. */
  chainEmpty?: boolean[][];
  /** True for a rule whose subject is :root. */
  ruleRoot: boolean[];
  ruleDir: number[];
  ruleDecls: number[][];
  ruleImportant: boolean[];
  /** True for a rule from the UA sheet, whose declarations a revert rolls back to. */
  ruleUa?: boolean[];
  /** The will-change list rows. */
  willChangeLists?: number[][];
  rulePseudo: number[];
  /** The author sheet each rule came from (-1 for the UA sheet); see sheets.ts's live sheets. */
  ruleSheet?: number[];
  /** The sheet each <style> or stylesheet <link> node hosts, or -1. */
  nodeSheet?: number[];
  /** The media condition each sheet carries (a media attribute), or "". */
  sheetMedia?: string[];
  /** Whether each sheet starts out disabled (a link disabled attribute). */
  sheetDisabled?: boolean[];
  /** The @media condition a rule is inside, or "" outside any; re-tested on resize. */
  ruleMedia: string[];
  /** The @container condition a rule is inside, or ""; tested against ancestor containers. */
  ruleContainer: string[];
  /** The @scope prelude each rule sits in, or "". */
  ruleScope: string[];
  /** True for a rule inside @starting-style. */
  ruleStarting: boolean[];
  /** Elements a @starting-style rule styles (their first computed state is the starting one). */
  startingNodes: boolean[];
  /** True for a presentation-attribute slot, filled from the element's attributes (hints.ts). */
  ruleHints: boolean[];
  /** Container name lists, space-separated, by container-name value id. */
  containerNames: string[];
  /** max()/min()/clamp() expression rows and clip rectangles, by value id. */
  lengthExprs: number[][];
  clipRects: number[][];
  clipShapes: number[][];
  objectPositions: number[][];
  /** stroke-dasharray patterns, by value id (see shared/css/dasharray.ts). */
  dashArrays: number[][];
  /** Grid track lists: fourteen numbers per track (a minmax()'s min and max slots). */
  gridTracks: number[][];
  /** Grid line and area names, and the placement and area rows that point into them. */
  gridNames: string[];
  gridPlacements: number[][];
  gridAreaLists: number[][];
  chainComb: number[][];
  chainTag: string[][];
  chainId: string[][];
  chainClasses: string[][][];
  chainStates: number[][];
  chainNthStart: number[][][];
  chainNthEnd: number[][][];
  /** The "of S" filter of each ancestor's :nth-child() conditions. */
  chainNthStartOf?: string[][][];
  chainNthEndOf?: string[][][];
  chainAttrs: string[][][];
  /** :lang() ranges on each ancestor link's compound. */
  chainLang?: string[][][];
  /** :dir(ltr|rtl) conditions on ancestor compounds: 1 for ltr, 2 for rtl, 0 for none. */
  chainDir?: number[][];
  chainNots: string[][][];
  chainNotSels?: string[][][];
  chainHas: string[][][];
  /** :root conditions on ancestor compounds. */
  chainRoot: boolean[][];
  chainStateMask: number;
  tags: string[];
  ids: string[];
  attrs: string[][];
  classes: string[][];
  /** style="" attributes as written; parsed into el.style when mounted. */
  style: string[];
  parents: number[];
  text: string[];
  rules: number[][];
  states: number[];
  /** The highlight a ::highlight() carrier stands for, or "" for every other node. */
  pseudoNames: string[];
  inline: boolean[];
  /** Per node, an index into imageFiles for an <img>, or -1. */
  nodeImages: number[];
  imageFiles: string[];
  /** The IMAGE_FILES entries that are SVG files, and the draw program compiled from each. */
  svgImageFiles: number[];
  svgImagePrograms: string[];
  /** The page's directory, which a runtime image URL resolves against. */
  imageBase: string;
  /** The public directory a dev build's site-root URLs resolve against; "" in a bundled app. */
  siteBase: string;
  windowOptions: string;
  /** The image URLs style="" attributes name, and their imageFiles entries. */
  imageUrls: string[];
  imageUrlFiles: number[];
  /** The paint servers fill/stroke name with url(#id), indexed by a paint value. */
  svgPaintUrls: string[];
  dynTags: string[];
  dynIds: string[];
  dynRules: number[];
  dynPseudo: number[];
  /** The item lists behind `content`, decoded when a pseudo-element's style is computed. */
  contentItems: string[];
  /** The counter lists behind counter-reset/-increment/-set. */
  counterItems: string[];
  /** The @counter-style rules, as encoded rows, and the names list-style-type can give one. */
  counterStyles: string[];
  counterStyleNames: string[];
  /** @font-face families, in FF_CUSTOM id order, for runtime values that name them. */
  fontFamilies: string[];
  /** Families a font-family list named that the build has no face for, in id order after the
   *  @font-face families: the host is asked for each by name on mount. */
  fontInstalledFamilies: string[];
  /** The ordered family ids of each font-family list, joined by commas. */
  fontFamilyLists: string[];
  /** One file per face, with the family it belongs to, its weight range (low * 1024 + high) and
   *  style (1 for italic), registered on mount. */
  fontFiles: string[];
  /** The `local()` names each face's src gives before its file, joined by NUL; "" for none. */
  fontFaceLocals: string[];
  fontFaceFamilies: number[];
  fontFaceWeights: number[];
  fontFaceStyles: number[];
  /** Each face's unicode-range as `lo-hi` pairs joined by commas; "" covers everything. */
  fontFaceRanges: string[];
  /** Each face's own OpenType feature settings and font-stretch percentage. */
  fontFaceFeatures: string[];
  fontFaceStretches: number[];
  fontFaceAscents: number[];
  fontFaceDescents: number[];
  fontFaceLineGaps: number[];
  /** Per face: its CPAL palette count and light/dark indices (-1 for none), three numbers each. */
  fontFacePalettes: number[];
  /** The names the page's @font-palette-values rules give palettes, in id order. */
  fontPaletteNames: string[];
  /** Each @font-palette-values rule, encoded (see shared/props.ts P_FONT_PALETTE). */
  fontPalettes: string[];
  /** Background layer lists: each row holds the layers of one declaration, flattened. */
  bgImages: number[][];
  gradientTexts: string[];
  bgRepeats: number[][];
  bgPositions: number[][];
  bgSizes: number[][];
  bgOrigins: number[][];
  bgClips: number[][];
  bgAttachments: number[][];
  /** border-image longhand rows: slice, width, outset and repeat values (see P.BORDER_IMAGE_*). */
  borderImageRows: number[][];
  /** Background gradient images, encoded by shared/css/gradients.ts (see BG_IMAGES values). */
  gradients: string[];
  /** The font-feature-settings lists: `tag=value` pairs joined by semicolons. */
  fontFeatures: string[];
  /** The font-variation-settings lists: `tag=value` pairs joined by semicolons. */
  fontVariations: string[];
  /** box-shadow lists: ten numbers per shadow in each row. */
  shadows: number[][];
  /** filter and backdrop-filter lists: eight numbers per function in each row. */
  filters: number[][];
  /** Transition and animation list rows, including their timing functions. */
  animRows: number[][];
  /** @keyframes blocks: [name id, offset, property, value, unit, ...], one per row. */
  animKeyframes: number[][];
  /** The names animation-name and @keyframes use, in id order. */
  animNames: string[];
  /** Transform lists and transform-origin rows (see shared/css/transforms.ts). */
  transformLists: number[][];
  transformOrigins: number[][];
  /** overflow-clip-margin rows (see shared/css/properties/box.ts). */
  clipMargins: number[][];
  /** Declarations kept as text: custom properties and var() values (see shared/css/vars.ts). */
  textDeclProps: string[];
  textDeclValues: string[];
  /** Custom properties registered with @property, registered on mount (runtime/registered.ts). */
  propertyNames: string[];
  propertySyntaxes: string[];
  propertyInherits: boolean[];
  /** Each registration's initial value, or "" for the guaranteed-invalid one. */
  propertyInitials: string[];
}

export const config = { title: "", width: 800, height: 600, windowOptions: "" };

/** The nodes the mounted page is built from, by table index, for its inline handlers to find. */
let pageNodes: Node[] = [];

/**
 * Attaches one inline handler attribute to the element its table index names, as that element's
 * `on<type>` handler: the listener a page's `onclick="…"` compiles to. Generated code calls this
 * after the mount and before the page's scripts, which is when a browser would have parsed the
 * attribute; the element's `onclick` property then reports the handler, and clearing it detaches.
 */
export function attachHandler(index: number, type: string, fn: (this: any, event: any) => any): void {
  const node = pageNodes[index];
  if (node === undefined) return;
  // <body onload> is one of the window's own handler attributes: the event comes from the window,
  // and `this` inside the handler is the window, as in a browser.
  if (node === document.body && type === "load") {
    window.addEventListener("load", function (event: Event): void {
      if (fn.call(window, event) === false) event.preventDefault();
    });
    return;
  }
  // A handler that returns false cancels the event, as an attribute handler's does. The wrapper is
  // typed concretely so scriptc can compile it statically: its parameters would otherwise be `any`,
  // which the generated handler code never needs.
  const handler = function (this: Node, event: Event): void {
    if (fn.call(this, event) === false) event.preventDefault();
  };
  if (node instanceof HTMLElement) node.setEventHandler(type, handler as Listener);
}

/**
 * The nodes created from the compiled tables, in table order, when a dev build asked mount() to
 * keep them. A release build leaves this null, so it neither allocates the list nor holds the
 * nodes a second time; the dev runtime uses it to update the live page in place (see dev.ts).
 */
export const devKeep: { nodes: Node[] | null } = { nodes: null };

/** Asks the next mount() to keep its compiled nodes, for a dev build's live updates. */
export function keepCompiledNodes(): void {
  devKeep.nodes = [];
}

/**
 * Points the style and rendering tables at `t`. The DOM built from the tables is separate, so a
 * dev build can apply recompiled tables to the page it already has.
 */
export function applyTables(t: AppTables): void {
  config.title = t.title;
  setStoreAppName(t.title);
  resetDisabledSheets();
  resetAppendedSubtreeCheck();
  tables.ruleClasses = t.ruleClasses;
  tables.ruleStates = t.ruleStates;
  tables.ruleCustoms = t.ruleCustoms === undefined ? [] : t.ruleCustoms;
  tables.ruleNthStart = t.ruleNthStart;
  tables.ruleNthEnd = t.ruleNthEnd;
  tables.ruleNthStartOf = t.ruleNthStartOf === undefined ? [] : t.ruleNthStartOf;
  tables.ruleNthEndOf = t.ruleNthEndOf === undefined ? [] : t.ruleNthEndOf;
  tables.ruleAttrs = t.ruleAttrs;
  tables.ruleLang = t.ruleLang === undefined ? [] : t.ruleLang;
  tables.ruleNots = t.ruleNots;
  tables.ruleNotSels = t.ruleNotSels === undefined ? [] : t.ruleNotSels;
  tables.ruleHas = t.ruleHas;
  tables.ruleEmpty = t.ruleEmpty === undefined ? [] : t.ruleEmpty;
  tables.ruleRoot = t.ruleRoot;
  tables.ruleDir = t.ruleDir;
  tables.ruleDecls = t.ruleDecls;
  tables.ruleImportant = t.ruleImportant;
  tables.rulePseudo = t.rulePseudo;
  tables.ruleSheet = t.ruleSheet === undefined ? [] : t.ruleSheet;
  tables.nodeSheet = t.nodeSheet === undefined ? [] : t.nodeSheet;
  tables.sheetMedia = t.sheetMedia === undefined ? [] : t.sheetMedia;
  tables.sheetDisabled = t.sheetDisabled === undefined ? [] : t.sheetDisabled;
  tables.ruleMedia = t.ruleMedia;
  tables.ruleContainer = t.ruleContainer === undefined ? [] : t.ruleContainer;
  tables.ruleScope = t.ruleScope === undefined ? [] : t.ruleScope;
  tables.ruleStarting = t.ruleStarting === undefined ? [] : t.ruleStarting;
  tables.ruleUa = t.ruleUa === undefined ? [] : t.ruleUa;
  tables.willChangeLists = t.willChangeLists === undefined ? [] : t.willChangeLists;
  willChangeRows.load(tables.willChangeLists);
  tables.ruleHint = t.ruleHints === undefined ? [] : t.ruleHints;
  tables.containerNames = t.containerNames === undefined ? [] : t.containerNames;
  tables.chainComb = t.chainComb;
  tables.chainTag = t.chainTag;
  tables.chainId = t.chainId;
  tables.chainClasses = t.chainClasses;
  tables.chainStates = t.chainStates;
  tables.chainNthStart = t.chainNthStart;
  tables.chainNthEnd = t.chainNthEnd;
  tables.chainNthStartOf = t.chainNthStartOf === undefined ? [] : t.chainNthStartOf;
  tables.chainNthEndOf = t.chainNthEndOf === undefined ? [] : t.chainNthEndOf;
  tables.chainAttrs = t.chainAttrs;
  tables.chainLang = t.chainLang === undefined ? [] : t.chainLang;
  tables.chainDir = t.chainDir === undefined ? [] : t.chainDir;
  tables.chainNots = t.chainNots;
  tables.chainNotSels = t.chainNotSels === undefined ? [] : t.chainNotSels;
  tables.chainHas = t.chainHas;
  tables.chainEmpty = t.chainEmpty === undefined ? [] : t.chainEmpty;
  tables.chainRoot = t.chainRoot;
  tables.chainStateMask = t.chainStateMask;
  // Which state bits a control's change could restyle: a rule's own states, and the states its
  // ancestors' compounds ask about (see noteControlChange in dom.ts).
  let stateMask = 0;
  for (const s of t.ruleStates) stateMask |= s;
  for (const row of t.chainStates) for (const s of row) stateMask |= s;
  stateUsage.mask = stateMask;
  tables.dynTags = t.dynTags;
  tables.dynIds = t.dynIds;
  tables.dynRules = t.dynRules;
  tables.dynPseudo = t.dynPseudo;
  tables.contentItems = t.contentItems;
  tables.counterItems = t.counterItems;
  tables.counterStyles = t.counterStyles;
  tables.counterStyleNames = t.counterStyleNames;
  tables.fontFamilies = t.fontFamilies;
  tables.fontInstalledFamilies = t.fontInstalledFamilies;
  tables.fontFamilyLists = t.fontFamilyLists;
  tables.fontFaceRanges = t.fontFaceRanges;
  tables.fontFaceFeatures = t.fontFaceFeatures;
  tables.fontFaceStretches = t.fontFaceStretches;
  tables.fontFaceAscents = t.fontFaceAscents;
  tables.fontFaceDescents = t.fontFaceDescents;
  tables.fontFaceLineGaps = t.fontFaceLineGaps;
  tables.textDeclProps = t.textDeclProps;
  tables.textDeclValues = t.textDeclValues;
  // The compile cache names rows of the tables above, which a new page replaces.
  resetCompiledText();
  bg.images = t.bgImages;
  bg.gradientTexts = t.gradientTexts;
  bg.repeats = t.bgRepeats;
  bg.positions = t.bgPositions;
  bg.sizes = t.bgSizes;
  bg.origins = t.bgOrigins;
  bg.clips = t.bgClips;
  bg.attachments = t.bgAttachments;
  // Rows and gradients the last page's inline styles registered point into that page's tables.
  resetRuntimeRows();
  setBorderImageRows(t.borderImageRows);
  exprRows.load(t.lengthExprs);
  clipRows.load(t.clipRects);
  clipPathRows.load(t.clipShapes);
  transformRows.load(t.transformLists);
  originRows.load(t.transformOrigins);
  clipMarginRows.load(t.clipMargins);
  positionRows.load(t.objectPositions);
  dashRows.load(t.dashArrays);
  bg.gradients = t.gradients;
  setFontFeatures(t.fontFeatures);
  setFontVariations(t.fontVariations);
  setFontPalettes(t.fontPaletteNames, t.fontPalettes, t.fontFacePalettes,
    t.fontFaceFamilies, t.fontFaceWeights, t.fontFaceStyles);
  shadowRows.load(t.shadows);
  gridTracks.rows = t.gridTracks;
  gridTracks.names = t.gridNames;
  gridTracks.placements = t.gridPlacements;
  gridTracks.areaLists = t.gridAreaLists;
  filterTables.rows = t.filters;
  animRows.load(t.animRows);
  animKeyframes.load(t.animKeyframes);
  animNames.load(t.animNames);
  resetKeyframes();
  setImageFiles(t.imageFiles);
  setSvgImages(t.svgImageFiles, t.svgImagePrograms);
  // A bundled app keeps its files at paths relative to the bundle the host found at startup, and
  // a URL a script builds resolves against that same directory; an unbundled (dev) build names
  // absolute build-time paths.
  const bundled = t.bundled === true;
  const site = bundled ? "" : t.siteBase ?? "";
  setImageBase(bundled ? "" : t.imageBase, bundled, site);
  setFetchBase(bundled ? assetRoot() : t.imageBase, site);
  setInlineImages(t.imageUrls, t.imageUrlFiles);
  setPaintUrls(t.svgPaintUrls);
  // A <link disabled> starts out of the cascade: the build compiled its rules, so they
  // stand down as soon as the tables are in place.
  for (let i = 0; i < tables.sheetDisabled.length; i++) {
    if (tables.sheetDisabled[i]) setCompiledSheetOff(i, true);
  }
  // Whether a text edit can change a selector's answer is a property of these tables.
  refreshTextRunDependence();
}

/** One node of a compiled table: a text run, a text field, a canvas, or an element. */
export function createNode(t: AppTables, i: number): Node {
  const tag = t.tags[i];
  // A processing instruction's tag names its target (`#pi:xml-stylesheet`): the compiler keeps
  // the target that way so a static one is the same node one a script would insert.
  if (tag.startsWith("#pi:")) return new ProcessingInstruction(tag.slice(4), t.text[i]);
  if (tag.startsWith("#doctype:")) {
    const parts = t.text[i].split("\u0000");
    return new DocumentType(tag.slice(9), parts.length > 0 ? parts[0] : "", parts.length > 1 ? parts[1] : "");
  }
  // A text run is a text node of its own, as it is in a browser.
  if (tag === "#text") return new Text(t.text[i]);
  const el = newElementFor(tag, t.ids[i], t.text[i], t.rules[i], t.states[i], t.inline[i]);
  // A <style> carries the index of the sheet the build compiled from its text, so a script that
  // disables the sheet can take exactly those rules out of the cascade (style.ts).
  const sheetIndex = t.nodeSheet?.[i] ?? -1;
  if (sheetIndex >= 0) el.sheetIndex = sheetIndex;
  return el;
}

/** The attributes, classes, inline style and image of table node `i`, applied to its element. */
export function initNode(t: AppTables, i: number, el: Node): void {
  if (!(el instanceof HTMLElement)) return;
  const image = t.nodeImages[i];
  if (image >= 0 && image < t.imageFiles.length) el.imagePath = t.imageFiles[image];
  el.pseudoName = t.pseudoNames[i];
  const attrs = t.attrs[i];
  for (let k = 0; k + 1 < attrs.length; k += 2) el.setAttribute(attrs[k], attrs[k + 1]);
  for (const c of t.classes[i]) el.classList.add(c);
  if (t.style[i] !== "") el.setAttribute("style", t.style[i]);
  // An <img> takes its source from the src just set, and starts loading.
  adoptImageSource(el);
  adoptMediaSource(el);
}

/** The face at index `i`: its file, local() names, family id, weight range and style (1 for italic). */
export function fontFace(t: AppTables, i: number): { path: string; locals: string[]; family: number; lo: number; hi: number; style: number; ranges: string; features: string; stretch: number } {
  const weights = i < t.fontFaceWeights.length ? t.fontFaceWeights[i] : 400 * 1024 + 400;
  const locals = i < t.fontFaceLocals.length ? t.fontFaceLocals[i] : "";
  return {
    path: t.fontFiles[i],
    locals: locals === "" ? [] : locals.split("\u0000"),
    family: i < t.fontFaceFamilies.length ? t.fontFaceFamilies[i] : 0,
    lo: Math.floor(weights / 1024),
    hi: weights % 1024,
    style: i < t.fontFaceStyles.length ? t.fontFaceStyles[i] : 0,
    ranges: i < t.fontFaceRanges.length ? t.fontFaceRanges[i] : "",
    features: i < t.fontFaceFeatures.length ? t.fontFaceFeatures[i] : "",
    stretch: i < t.fontFaceStretches.length ? t.fontFaceStretches[i] : 100,
  };
}

/**
 * Registers one face with the host: a font the system already has when the rule's src named one
 * and it is there, and otherwise the file the compiler found, each with the family, weight range
 * and style it covers. A face with neither (a src whose only name the system lacks) registers
 * nothing, and the family falls back to the system font.
 */
export function registerFontFace(t: AppTables, i: number): void {
  const face = fontFace(t, i);
  for (const name of face.locals) {
    if (hostRegisterFontLocal(name, face.family, face.lo, face.hi, face.style, face.ranges, face.features, face.stretch) !== 0) return;
  }
  if (face.path !== "") hostRegisterFont(assetPath(face.path), face.family, face.lo, face.hi, face.style, face.ranges, face.features, face.stretch);
}

/**
 * Registers the app's @font-face faces with the host, one per face, each with its family, weight
 * range and style: the host picks among a family's faces for the text it draws.
 */
export function registerFontFaces(t: AppTables): void {
  // The last page's faces took family ids from its own tables; this page's start again at zero,
  // and so do the caches keyed by those ids.
  hostResetFonts();
  layoutEpoch.n++;
  resetMeasureCache();
  resetBreakCache();
  resetDeviceMetrics();
  resetMetricsCache();
  for (let i = 0; i < t.fontFiles.length; i++) registerFontFace(t, i);
  // The families the build left to the system sit after the @font-face ones, which is the face
  // index the host takes (a family id is FF_CUSTOM plus its index). A name the machine doesn't
  // have registers nothing, and the text falls back to the system font as it did before.
  for (let i = 0; i < t.fontInstalledFamilies.length; i++) {
    hostRegisterFontNamed(t.fontInstalledFamilies[i], t.fontFamilies.length + i);
  }
}

/**
 * Registers the custom properties the app's @property rules declare, the way
 * CSS.registerProperty() would: the style engine then gives each its initial value where nothing
 * sets it, and lets it inherit only when the rule says so.
 */
export function registerProperties(t: AppTables): void {
  for (let i = 0; i < t.propertyNames.length; i++) {
    const initial = t.propertyInitials[i];
    registerCustomProperty(t.propertyNames[i], t.propertySyntaxes[i], t.propertyInherits[i],
      initial === "" ? null : initial);
  }
}

/** The width, height and title, and the options text, a window was opened with (NATIVE_WINDOW_*). */
function applyWindowEnvironmentOverrides(): void {
  const width = process.env.NATIVE_WINDOW_WIDTH;
  if (width !== undefined && width !== "") config.width = Math.max(0, Math.round(Number(width)));
  const height = process.env.NATIVE_WINDOW_HEIGHT;
  if (height !== undefined && height !== "") config.height = Math.max(0, Math.round(Number(height)));
  const title = process.env.NATIVE_WINDOW_TITLE;
  if (title !== undefined && title !== "") config.title = title;
  const options = process.env.NATIVE_WINDOW_OPTIONS;
  if (options !== undefined && options !== "") {
    config.windowOptions = config.windowOptions === "" ? options : config.windowOptions + ";" + options;
  }
}

let rejectionListener = false;

export function mount(t: AppTables): void {
  // A rejection nothing handled is reported and the page keeps running, as in a browser.
  if (!rejectionListener) {
    rejectionListener = true;
    process.on("unhandledRejection", (reason: unknown) => reportUnhandledRejection(reason));
  }
  // A bundled app's tables name its files relative to the bundle, and the host knows where the
  // executable put them (the .app's Resources on macOS, the directory beside it elsewhere). This
  // happens before any table that names a file is read.
  if (t.bundled === true) hostBundleDir((dir) => setAssetRoot(dir));
  // A page is parsed before it is interactive: scripts run while the document is still loading.
  document.readyState = "loading";
  config.width = t.width;
  config.windowOptions = t.windowOptions;
  config.height = t.height;
  // A window the app opened carries its own size, title, position and options, which stand in
  // for the page's native-window ones; its route is the address the page starts at.
  applyWindowEnvironment();
  applyWindowEnvironmentOverrides();
  setDocumentMode(t.quirks);
  setPageCharset(t.charset === undefined ? "UTF-8" : t.charset);
  viewport.w = config.width;
  viewport.h = config.height;
  applyTables(t);
  document.xmlDocument = t.xmlDocument === true;
  registerFontFaces(t);
  document.fonts.setFaces(t.fontFamilies);
  registerProperties(t);

  const els: Node[] = [];
  for (let i = 0; i < t.tags.length; i++) {
    const el = createNode(t, i);
    initNode(t, i, el);
    // A <style> the build compiled is already in the page's rules, so the cascade doesn't apply
    // its runtime sheet; the sheet is still parsed, though, for the CSSOM a script reads.
    if (el.localName === "style") {
      el.compiledSheet = true;
      refreshSheet(el);
    }
    // A @starting-style rule styles the element's first state only (see runtime/style.ts).
    if (t.startingNodes !== undefined && t.startingNodes[i] === true) el.starting = true;
    const parent = t.parents[i];
    if (parent >= 0) {
      // A <template>'s markup lives in its content fragment, not in its children.
      const holder: Node = els[parent] instanceof HTMLTemplateElement
        ? (els[parent] as HTMLTemplateElement).content : els[parent];
      el.parentNode = holder;
      holder.kids.push(el);
      // A compiled marker belongs to the list item that generates it, and a compiled
      // ::placeholder box to the field that reads its style.
      if (el instanceof HTMLElement && el.pseudoKind === P.PE_MARKER) {
        (els[parent] as HTMLElement).markerPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_BEFORE) {
        (els[parent] as HTMLElement).beforePseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_AFTER) {
        (els[parent] as HTMLElement).afterPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_PLACEHOLDER) {
        (els[parent] as HTMLElement).placeholderPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_BACKDROP) {
        (els[parent] as HTMLElement).backdropPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_FIRST_LINE) {
        (els[parent] as HTMLElement).firstLinePseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_FIRST_LETTER) {
        (els[parent] as HTMLElement).firstLetterPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_SELECTION) {
        (els[parent] as HTMLElement).selectionPseudo = el;
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_HIGHLIGHT) {
        (els[parent] as HTMLElement).highlightPseudos.push(el);
      } else if (el instanceof HTMLElement && el.pseudoKind === P.PE_TARGET_TEXT) {
        (els[parent] as HTMLElement).targetTextPseudo = el;
      }
    }
    els.push(el);
  }
  // Inline SVG is a namespace of its own: elements under an <svg> take the SVG namespace, as a
  // browser's DOM gives them (selectors such as `svg|rect` ask for it).
  const SVG_NS = "http://www.w3.org/2000/svg";
  for (let i = 0; i < els.length; i++) {
    const p = t.parents[i];
    const parentSvg = p >= 0 && elementNamespace(els[p]) === SVG_NS;
    const el = els[i];
    if (el.isElementNode && (el.localName === "svg" || parentSvg)) setElementNamespace(el, SVG_NS);
  }
  const kept = devKeep.nodes;
  if (kept !== null) {
    kept.length = 0;
    for (const el of els) kept.push(el);
  }
  // The doctype nodes a build emits come first in the table; the root element follows them and
  // the doctype nodes belong to the document beside it.
  document.kids = [];
  let rootIdx = 0;
  while (rootIdx < els.length && t.tags[rootIdx].startsWith("#doctype:")) {
    els[rootIdx].parentNode = document;
    document.kids.push(els[rootIdx]);
    rootIdx++;
  }
  const rootEl = els[rootIdx] as HTMLElement;
  document.documentElement = rootEl;
  document.headEl = null;
  rootEl.parentNode = document;
  document.kids.push(rootEl);
  for (const el of els) if (el.tagName === "BODY" && el instanceof HTMLElement) document.body = el;
  pageNodes = els;
  // A page's own <template shadowrootmode> makes its host's shadow root, as HTML parsing does.
  adoptDeclarativeIn(document.documentElement);
  // A script that takes a compiled <style> over through the CSSOM finds its node here, so the
  // rules the build compiled from that sheet can stand down (see sheets.ts, style.ts).
  setSheetLiveSink((owner: any) => {
    const at = pageNodes.indexOf(owner);
    if (at >= 0) disableCompiledSheet(at);
  });
  document.titleText = t.title;
  invalidateStyle();
  // The fragment the app was opened with names a stretch of text to paint as the target.
  readTargetText();
}

// ---------------------------------------------------------------------------
// Frame pipeline

/** Runs any pending style, layout and paint work. */
export function renderFrame(): void {
  frame();
  if (process.env.NATIVE_DUMP !== undefined) dumpTree(document.body !== null ? document.body : document.documentElement, 0);
}

/**
 * Paints the page as its tree stands now, without touching the frame clock or the animation
 * state: the caller is about to read the pixels (a snapshot), and the display list it reads must
 * be this page's, whatever a previous page left in it and whichever dirty flags are set.
 */
export function paintPage(): void {
  // A snapshot paints the page as it stands, so a subtree a change restyled is styled first.
  styleSubtrees(takeStyleRoots());
  paintRoot(document.documentElement);
  dirty.paint = false;
  clearPaintDamage();
}

/**
 * Styles the subtrees a change reached, each against its parent's current style: the answer for a
 * class, attribute or inline style write on a page whose rules can't see past one element (see
 * subtreeRestylesAlone). An element another root contains is skipped, since that root's pass
 * styles it.
 */
function styleSubtrees(roots: Node[]): void {
  if (roots.length === 0) return;
  // A change may name the same element several times (a class, a style and a child list all on
  // one row), so the list is unique before anything is styled.
  const pending = new Set<Node>();
  const unique: Node[] = [];
  for (const r of roots) {
    if (pending.has(r)) continue;
    pending.add(r);
    unique.push(r);
  }
  const done = new Set<Node>();
  for (const r of unique) {
    if (done.has(r) || !r.isConnected) continue;
    let covered = false;
    for (let p = r.parentNode; p !== null; p = p.parentNode) {
      if (pending.has(p)) { covered = true; break; }
    }
    if (covered) continue;
    const parent = r.parentNode;
    if (parent === null) continue;
    restyleSubtree(r, parent.nodeType === 1 ? parent : null);
    done.add(r);
  }
}

function dumpTree(el: Node, depth: number): void {
  const p = absolutePosition(el);
  let s = "";
  for (let i = 0; i < depth; i++) s += "  ";
  let frags = "";
  for (let i = 0; i < el.fragKind.length; i++) {
    frags += ` [k${el.fragKind[i]} L${el.fragLine[i]} ${r2(el.fragX[i])},${r2(el.fragTop[i])} w${r2(el.fragW[i])}]`;
  }
  let bl = "";
  for (const b of el.lineBaseline) bl += ` ${r2(b)}`;
  console.log(`${s}${el.localName} ${r2(p[0])},${r2(p[1])} ${r2(el.w)}x${r2(el.h)}` +
    ` cb ${r2(el.contentW)}x${r2(el.contentH)} lines ${el.lines.length} baseline${bl}${frags}`);
  for (const c of el.kids) dumpTree(c, depth + 1);
}

function r2(v: number): number {
  return Math.round(v * 100) / 100;
}

/** Clears per-page interaction state, so another compiled page can be mounted (WPT runner). */
export function resetPage(): void {
  // Sheets a page adopted belong to it alone; the next page starts without them, and so do the
  // custom properties its @property rules and its scripts registered, and the faces its
  // @font-face rules registered with the host.
  hostResetFonts();
  // A document that just loaded has nothing selected and nothing on top of it; the last page's
  // selection and top-layer entries would still point at nodes that are gone.
  resetSelection();
  clearTopLayer();
  closeSelectPopup();
  resetAx();
  resetAccessibleProperties();
  resetHighlights();
  resetTargetText();
  clearAdopted();
  clearLiveCollections();
  clearLiveRanges();
  clearRegistrations();
  resetCounterStyles();
  setFocus(null);
  // The next page's own focus decisions start with no interaction behind them.
  resetInput();
  pointer.hovered = [];
  pointer.pressed = null;
  pointer.down = false;
  pendingScrollIntoView.el = null;
  // A smooth scroll of the old page has no boxes left to move.
  clearSmoothScrolls();
  resetAnimations();
  // A browser gives each page its own event loop and window: the last page's timers, frames and
  // listeners die with it, and the document it listened on starts over.
  clearAllTimers();
  window.reset();
  document.listeners.clear();
  // The WPT runner reads a testharness page's result off the window. The last page's result must
  // not stand in for this one's, so a page that reports nothing is not credited with it.
  (window as unknown as { __nativeTestharness?: string }).__nativeTestharness = undefined;
}

export function frame(): void {
  const started = frameClock();
  // A layout that moves boxes moves the accessibility tree with them.
  const moves = dirty.layout || dirty.style;
  flushStyleAndLayout();
  // Sizes and positions are final for this frame, so the observers hear about them after the
  // layout pass.
  deliverResizeObservers();
  deliverIntersectionObservers();
  const root = document.documentElement;
  if (dirty.paint || dirty.layout || dirty.style) {
    const painted = frameClock();
    beginDamageFrame();
    computeDamage();
    if (!damage.full) {
      // Animations changing in this frame too: their old and new boxes join the text damage.
      const extra = pendingDamageRects();
      if (extra === null) markDamageFull("composite-overflow");
      else {
        // What the animation moved may sit inside a backdrop filter's box, whose filter region
        // the damage has to cover too.
        addBackdropDamage(extra, pendingElements(), []);
        if (!addDamageRects(extra)) markDamageFull("composite-overflow");
      }
    }
    if (damage.full) {
      paintRoot(root);
    } else {
      if (damageVerify.on) {
        paintRootReference(root);
        hostDamageReference(viewport.w, viewport.h);
      }
      paintRootDamage(root, damage.rects);
    }
    if (frameTimes.on) {
      frameTimes.paint += performance.now() - painted;
      frameTimes.layers = hostLayerCount();
      frameTimes.damaged = damage.limited;
      frameTimes.damageRects = damage.rects.length;
      frameTimes.damageArea = damage.limited ? rectsArea(damage.rects) : viewport.w * viewport.h;
      frameTimes.damageReason = damage.reason;
    }
    endDamageFrame();
    dirty.paint = false;
    clearPaintDamage();
    if (paintMarkTrace.on && paintMarkTrace.counts.size > 0) {
      let line = "";
      for (const [k, v] of paintMarkTrace.counts) line += (line === "" ? "" : " ") + k + "=" + v;
      console.error("native: paintmarks " + line);
      paintMarkTrace.counts.clear();
    }
  } else if (dirty.composite) {
    // Only transforms and opacities moved: update the layers the host already holds. A layer the
    // last paint didn't record (a transform that just appeared, an opacity group that started or
    // ended) can't be answered that way — and neither can any of them when the host has no
    // compositor — so the regions those boxes cover are painted instead of the whole page.
    const painted = frameClock();
    // A backdrop filter's box has to repaint where the animation inside it changed: the moving
    // elements name what is inside, and compositeFrame clears the list.
    const moving = pendingElements().slice();
    const moved = pendingDamageRects();
    if (moved !== null && compositeFrame()) {
      axGeometryDirty();
      if (frameTimes.on) {
        frameTimes.paint += performance.now() - painted;
        frameTimes.layers = hostLayerCount();
        frameTimes.damaged = compositeDamage.usedRegion;
        frameTimes.damageRects = compositeDamage.rects.length;
        frameTimes.damageArea = compositeDamage.usedRegion ? rectsArea(compositeDamage.rects) : viewport.w * viewport.h;
        frameTimes.damageReason = "composite";
      }
    } else if (moved !== null) {
      beginDamageFrame();
      // A change inside a backdrop filter's box repaints the filter's region around it.
      addBackdropDamage(moved, moving, []);
      damage.full = false;
      damage.limited = true;
      damage.reason = "composite";
      damage.rects = moved;
      paintRootDamage(root, moved);
      endDamageFrame();
      dirty.paint = false;
      clearPaintDamage();
      axGeometryDirty();
      if (frameTimes.on) {
        frameTimes.paint += performance.now() - painted;
        frameTimes.layers = hostLayerCount();
        frameTimes.damaged = true;
        frameTimes.damageRects = moved.length;
        frameTimes.damageArea = rectsArea(moved);
        frameTimes.damageReason = "composite";
      }
    } else {
      paintRoot(root);
      axGeometryDirty();
      if (frameTimes.on) {
        frameTimes.paint += performance.now() - painted;
        frameTimes.layers = hostLayerCount();
        frameTimes.damaged = false;
        frameTimes.damageRects = 0;
        frameTimes.damageArea = viewport.w * viewport.h;
        frameTimes.damageReason = "composite-full";
      }
    }
  }
  // transitionend and the animation events go out once the frame they belong to is painted.
  flushAnimationEvents();
  // The host's next accessibility query sees the page as this frame left it.
  if (moves) axDirty();
  flushAx();
  // A finished audio source reports it on the frame, as a browser dispatches "ended" from its
  // audio thread's work rather than inside the script that started it.
  audioFrameHook();
  // A scroll step or animation may have added to the next frame's compositor damage already.
  resetCompositeDamage();
  endFrame(started);
  firstFramePainted();
}

/** The area a damaged frame paints, in CSS px². */
function rectsArea(rects: number[][]): number {
  let area = 0;
  for (const r of rects) area += r[2] * r[3];
  return area;
}

/**
 * Computes styles and lays the page out if either is out of date, as the start of a frame does.
 * The DOM calls this before a read that needs current boxes, as elementFromPoint() forces layout
 * in a browser.
 */
export function flushStyleAndLayout(): void {
  // A read made during a flush (a custom element's callback, say) finds the work already in
  // flight rather than starting a second pass over the same tree.
  if (flushingLayout) return;
  flushingLayout = true;
  try {
    flushStyleAndLayoutInner();
  } finally {
    flushingLayout = false;
  }
}

/** True while a style-and-layout flush runs, so a read made inside it doesn't re-enter. */
let flushingLayout = false;

function flushStyleAndLayoutInner(): void {
  const root = document.documentElement;
  let t = frameClock();
  // The subtrees a localised change restyled; a page pass covers them, so it takes priority.
  const roots = takeStyleRoots();
  if (dirty.style) {
    // Cleared first, so a style pass that asks for another (a moved inherited animation value)
    // leaves the request standing for the next frame.
    dirty.style = false;
    computeStyles(root, null);
  } else if (roots.length > 0) {
    styleSubtrees(roots);
  }
  // A @starting-style first state gave way to the real one: compute that now, so the transition
  // from the starting values starts before the tick below moves it.
  if (takeStartingDirty()) computeStyles(root, null);
  if (frameTimes.on) frameTimes.style += performance.now() - t;
  // Transitions and animations move values between the cascade and layout.
  t = frameClock();
  animationTick();
  if (frameTimes.on) frameTimes.anim += performance.now() - t;
  t = frameClock();
  if (dirty.style) {
    // An inherited value moved, so the subtree takes the new one before it is laid out.
    dirty.style = false;
    computeStyles(root, null);
  }
  if (frameTimes.on) frameTimes.style += performance.now() - t;
  if (dirty.layout) {
    t = frameClock();
    layoutRoot(root);
    // A container query reads the size layout gives its container, and its answer can change that
    // very layout: run the two again until the sizes the queries saw are the sizes layout made.
    for (let pass = 0; pass < 2 && containerStale(root); pass++) {
      computeStyles(root, null);
      layoutRoot(root);
    }
    dirty.layout = false;
    // A layout can move a snap position, and the boxes a scroll is snapped to take the scroll
    // with them: this is where a container lands on its first snap position too.
    snapAfterLayout(root);
    const target = pendingScrollIntoView.el;
    if (target !== null) {
      pendingScrollIntoView.el = null;
      scrollIntoView(target, pendingScrollIntoView.block, pendingScrollIntoView.inline, pendingScrollIntoView.behavior);
    }
    // The scroll just made may have moved a marker group's :target-current, which asks for the
    // style work again; give that pass the frame it belongs to rather than the next one.
    if (dirty.style) {
      dirty.style = false;
      computeStyles(root, null);
      layoutRoot(root);
    }
    if (frameTimes.on) frameTimes.layout += performance.now() - t;
  }
}

setFlushLayoutHook(flushStyleAndLayout);
// CSSOM reads a background layer list’s text from the painter’s tables; the painter can’t import
// the CSSOM module itself without closing an import cycle through style.ts.
setBgTextHook(backgroundLonghandText);
setValueRangeGeometryHook(valueRangeGeometry);

// native front end: HTML + CSS -> a static node table with build-time cascade.
//
// What happens at build time (and so never at runtime):
//   - HTML parsing, entity decoding, whitespace collapsing
//   - CSS parsing and value parsing (colors, lengths, keywords -> numbers)
//   - selector matching for every tag/#id part of every selector
//   - specificity sorting and merging of unconditional rules per element
//   - dead rule elimination (rules no element can ever match, or none a script can bring to life)
// What's left for runtime: class and :hover/:active checks for conditional rules,
// inheritance, layout, and paint.

import { readFileSync, existsSync, writeFileSync, mkdirSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { Diagnostics } from "./diagnostics.ts";
import { TABLE_FIELDS } from "./fields.ts";
import { documentMode, doctypeOf, pageCharset, parseHtml, findAll, textOf, type HElement, type HNode } from "./html.ts";
import { genericFamily } from "../shared/css/types.ts";
import { parseCss, compileDeclarations, scanFontFaces, scanFontFeatureValues, scanPaletteValues, fontPalettes, scanNamespaces, setSelectorNamespaces, GENERIC_FAMILIES, COMB_CHILD, ATTR_SEP, encodeCompound, compoundStates, type CssRule, type Selector, type Decl, type ChainLink, type Compound, type FontContext, type ContentContext, type FontFaceDecl, type FontPaletteDecl, type KeyframesContext, type PropertyRule, type CounterStyleContext, fontFileWeight } from "./css.ts";
import { UA_CSS } from "./ua.ts";
import { isModuleText } from "./scripts.ts";
import { LayerRegistry } from "./css/layers.ts";
import * as P from "../shared/props.ts";
import { urlsInText } from "../shared/css/colors.ts";
import { exprRows } from "../shared/css/length-exprs.ts";
import { clipRows } from "../shared/css/clip.ts";
import { willChangeRows } from "../shared/css/willchange.ts";
import { clipPathRows } from "../shared/css/clip-path.ts";
import { originRows, transformRows } from "../shared/css/transforms.ts";
import { clipMarginRows } from "../shared/css/properties/box.ts";
import { positionRows } from "../shared/css/position.ts";
import { dashRows } from "../shared/css/dasharray.ts";
import { animKeyframes, animNames, animRows, wideCode } from "../shared/css/anim.ts";
import { longhandIds } from "../shared/css/shorthands.ts";
import { shadowRows } from "../shared/css/shadows.ts";
import type { AppTables } from "../runtime/app/mount.ts";
import { compileSvgImage } from "./svg-image.ts";
import type { AssetBundle } from "./bundle.ts";

/**
 * Every field of AppTables, with the name gen.ts exports it under. gen.ts and the dev data
 * file are two renderings of the same values, so the boot module and the dev reload read the
 * tables through this one list.
 */

/** One classic script the page runs, in document order: an external file or inline text. */
export interface ScriptFile {
  /** Absolute path of an external <script src>, or null for an inline <script>. */
  path: string | null;
  /** The code: the file's contents, or the inline script's text. */
  text: string;
  line: number;
  col: number;
  /** The script element's place among the page's <script> elements, for document.currentScript. */
  order: number;
  /**
   * Whether it is a module script (type="module", or a source with its own imports and exports).
   * A module keeps its declarations to itself; a classic script's are the page's, shared with the
   * scripts after it and with the page's handler attributes.
   */
  module: boolean;
}

/**
 * Whether a `<script>` holds code. An absent or empty type is the classic default; a type naming a
 * JavaScript MIME type or `module` is code; anything else (an import map, a template block) is
 * data for the page, which HTML does not run and which must not be compiled as a script.
 */
function isScriptCode(el: HElement): boolean {
  const type = el.attrs.get("type");
  if (type === undefined) return true;
  const t = type.trim().toLowerCase();
  if (t === "" || t === "module") return true;
  return t === "text/javascript" || t === "application/javascript" || t === "text/ecmascript" ||
    t === "application/ecmascript" || t === "text/jscript" || t === "text/livescript" ||
    t === "application/x-javascript";
}

/** True when the script element names type="module". */
function isModuleAttr(el: HElement): boolean {
  const type = el.attrs.get("type");
  return type !== undefined && type.trim().toLowerCase() === "module";
}

/** An inline event handler attribute (`onclick="…"`), compiled as a listener on its element. */
export interface HandlerAttribute {
  /** The node table index of the element that carries the attribute. */
  node: number;
  /** The event type: the attribute name without its "on". */
  type: string;
  /** The handler's code, as the attribute has it. */
  code: string;
  line: number;
  col: number;
}

/**
 * One @font-face: a family, the file its rule loads, and the weight range and style it covers.
 * A family may have several faces; the host picks the one nearest the text's weight, matching
 * style first.
 */
export interface FontFace {
  family: string;
  /** Where the runtime loads the face from: the bundle's copy, or the build-time file if the
   *  build isn't bundled. */
  path: string;
  /** The file on disk the build reads (its metrics, palettes and weight). */
  source: string;
  /** The `local()` names to try, in order, before the file — the system may already have one. */
  locals: string[];
  weightLo: number;
  weightHi: number;
  italic: boolean;
  /** The `unicode-range` the face covers, as `lo-hi` pairs joined by commas; "" for all. */
  ranges: string;
  /** The face's own OpenType feature settings, `tag=value` pairs joined by semicolons; "" none. */
  features: string;
  /** The `font-stretch` the face covers, as a percentage (100 for normal). */
  stretch: number;
  /** ascent-, descent- and line-gap-override as fractions of the font size; -1 for normal. */
  ascent: number;
  descent: number;
  lineGap: number;
}

export interface CompiledApp {
  title: string;
  width: number;
  height: number;
  scripts: ScriptFile[]; // classic scripts in document order
  handlers: HandlerAttribute[]; // inline event handler attributes, in document order
  inlineScripts: string[]; // only with ignoreScripts
  scriptSrcs: string[]; // only with ignoreScripts
  genSource: string; // contents of gen.ts
  /** The same tables as plain data, for a dev build's runtime reload (see runtime/app/dev.ts). */
  tables: AppTables;
  fonts: FontFace[]; // @font-face faces, one per file
  images: string[]; // image files referenced by <img> and backgrounds, in table order
  ids: string[]; // the ids the page's elements carry, in tree order (named access on the window)
  stats: {
    elements: number; rules: number; rulesDropped: number; conditionalRules: number; dynamicSelectors: number;
    staticChains: number; runtimeChains: number;
  };
}

interface OutNode {
  tag: string; // "#text" for text nodes
  id: string;
  attrs: string[]; // flat [name, value, ...] for attributes other than id/class/style
  style: string; // the style="" attribute as written; the runtime parses it into el.style
  classes: string[];
  parent: number;
  text: string;
  rules: number[];
  states: number; // which pseudo states affect this element's style
  pseudoName?: string; // for a ::highlight() carrier, the highlight's name
}

interface OutRule {
  /** True for a rule holding only "!important" declarations, which the runtime applies last. */
  important: boolean;
  /** True when the rule sets a custom property, or a value with var() in it. */
  customs: boolean;
  /** The origin the rule came from ("ua", "author" or "inline"); revert rolls back to the UA's. */
  origin: string;
  classes: string[];
  states: number;
  /** The subject compound is :root, which the runtime tests against the document's root element. */
  root: boolean;
  /** The subject compound is :dir(ltr|rtl): 1 for ltr, 2 for rtl, 0 when it doesn't ask. */
  dir: number;
  /** Every state bit that changes whether this rule applies, including inside :not(). */
  stateMask: number;
  nthStart: number[];
  nthEnd: number[];
  /** The "of S" filter of each :nth-child() condition, aligned with the triplets ("" for none). */
  nthStartOf: string[];
  nthEndOf: string[];
  attrs: string[];
  /** :lang() ranges on the subject compound (empty for none). */
  lang: string[];
  nots: Compound[];
  /** :not() arguments that are complex selectors, matched as selectors of their own. */
  notSels: string[];
  /** The @scope prelude the rule sits in ("" for none), checked against the element's ancestors. */
  scope: string;
  /** True for a rule inside @starting-style, which styles only the element's first state. */
  starting: boolean;
  /** :has() arguments on the subject compound, each a relative selector (see Compound.has). */
  has: string[];
  /** The subject compound is :empty: no child elements and no text. */
  empty: boolean;
  /** :has() arguments on each ancestor link of the chain. */
  chainHas: string[][];
  /** True for each ancestor link whose compound is :empty. */
  chainEmpty: boolean[];
  chain: ChainLink[];
  decls: number[];
  /**
   * PE_BEFORE, PE_AFTER, PE_MARKER or PE_PLACEHOLDER when the rule targets a pseudo-element: its
   * conditions are then tested against the element that generates the pseudo, the rule's parent
   * at runtime.
   */
  pseudo: number;
  /** The @media condition the rule is inside, or "" outside any: the runtime tests it per frame. */
  media: string;
  /** The @container condition the rule is inside, or "": the runtime tests ancestor containers. */
  container: string;
}

const INLINE_TAGS = new Set(P.INLINE_TAGS);
/** The name of an inline event handler attribute: "on" and a lowercase event name. */
const IN_HANDLER_NAME = /^on[a-z]+$/;
/** Elements a page keeps in its DOM but never draws: their subtrees aren't laid out, and a script
 *  can still find them by id, so they become nodes with their text and no child nodes. */
const LEAF_TAGS = new Set(["script", "style", "link", "meta", "title", "base"]);
/** Elements whose content isn't part of the document: nothing inside them is a node at all. */

/** Balanced text between the parenthesis at `open` and its match, or null. */
function parenBody(text: string, open: number): string | null {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "(") depth++;
    else if (text[i] === ")") {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return null;
}

/**
 * A sheet's text with its leading @import rules inlined. Each imported sheet is wrapped in the
 * layer, @supports condition and @media query its @import names, in that order, so the ordinary
 * at-rule parsing puts its rules where the cascade wants them. A sheet already being imported
 * (a cycle) is skipped, and a missing one is reported.
 */
function inlineImports(text: string, absFile: string, relFile: string, root: string,
  diags: Diagnostics, chain: string[], depth: number, collect?: (file: string) => void): string {
  if (depth > 16) return text;
  let out = "";
  let rest = text;
  for (;;) {
    const m = /^(?:\s|\/\*[\s\S]*?\*\/)*@import\s+/i.exec(rest);
    if (m === null) break;
    const start = m[0].length;
    const semi = rest.indexOf(";", start);
    if (semi < 0) {
      diags.warn(relFile, 1, 1, "@import without a semicolon; ignored");
      break;
    }
    const prelude = rest.slice(start, semi).trim();
    rest = rest.slice(semi + 1);
    const u = /^(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)|"([^"]*)"|'([^']*)')/i.exec(prelude);
    if (u === null) {
      diags.warn(relFile, 1, 1, `@import '${prelude}' isn't understood; ignored`);
      continue;
    }
    const href = u[1] ?? u[2] ?? u[3] ?? u[4] ?? u[5] ?? "";
    let tail = prelude.slice(u[0].length).trim();
    let layer: string | null = null;
    if (/^layer\b/i.test(tail)) {
      const l = /^layer\s*(?:\(([^)]*)\))?/i.exec(tail);
      layer = l === null ? "" : (l[1] ?? "").trim();
      tail = tail.slice(l === null ? 5 : l[0].length).trim();
    }
    let supports: string | null = null;
    if (/^supports\s*\(/i.test(tail)) {
      const open = tail.indexOf("(");
      const body = parenBody(tail, open);
      if (body !== null) {
        supports = body.trim();
        tail = tail.slice(open + 1 + body.length + 1).trim();
      }
    }
    const media = tail;
    const target = href.startsWith("/") && root !== "" ? join(root, href) : join(dirname(absFile), href.split(/[?#]/)[0]);
    if (chain.indexOf(target) >= 0) {
      diags.note(relFile, 1, 1, `@import '${href}' imports itself; ignored`);
      continue;
    }
    if (!existsSync(target)) {
      diags.warn(relFile, 1, 1, `@import '${href}' not found; ignored`);
      continue;
    }
    const imported = readFileSync(target, "utf8");
    if (collect !== undefined) collect(target);
    let inner = inlineImports(imported, target, relative(process.cwd(), target), root, diags, [...chain, target], depth + 1, collect);
    if (media !== "") inner = `@media ${media} { ${inner} }`;
    if (supports !== null) inner = `@supports (${supports}) { ${inner} }`;
    if (layer !== null) inner = layer === "" ? `@layer { ${inner} }` : `@layer ${layer} { ${inner} }`;
    out += inner + "\n";
  }
  return out + rest;
}

const SKIP_TAGS = new Set(["noscript"]);
const UNSUPPORTED_TAGS: Record<string, string> = {
  iframe: "iframes aren't supported",
};

export interface CompileOptions {
  /** Directory that site-root URLs ("/css/support/x.css") resolve against. */
  root?: string;
  /** The app's public directory, whose files a build copies to the bundle's root. A dev build
   *  (one with no bundle) records it in the tables, so a runtime URL under the root resolves
   *  against it. */
  publicDir?: string;
  /** Don't compile scripts; just report them in `inlineScripts` / `scriptSrcs` (WPT runner). */
  ignoreScripts?: boolean;
  /** Give the page the runner's testharness API in place of /resources/testharness.js, and leave
   *  testharnessreport.js out (the runner reads the outcome itself). */
  testharness?: boolean;
  /** Source text of everything the app's scripts import, transitively. Elements a package
   *  builds are invisible to the build otherwise: their tags and class names have to count
   *  as possible, and their DOM calls make the tree dynamic. */
  scriptDependencies?: (scripts: { path: string | null; text: string }[]) => string[];
  /** The files the app's images, fonts and sheets name, collected so the build can copy them
   *  beside the executable and reference them there. Without one, the tables name the files
   *  where the build found them (a dev build, or the web-platform-test runner). */
  bundle?: AssetBundle;
}

/** The file extension each image MIME type a data: URL can carry is written with. */
const DATA_IMAGE_EXTENSIONS: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/jpg": ".jpg",
  "image/gif": ".gif",
  "image/webp": ".webp",
  "image/svg+xml": ".svg",
  "image/avif": ".avif",
  "image/bmp": ".bmp",
  "image/x-icon": ".ico",
  "image/vnd.microsoft.icon": ".ico",
};

/** The file extension each font MIME type a data: URL can carry is written with. */
const DATA_FONT_EXTENSIONS: Record<string, string> = {
  "font/woff2": ".woff2",
  "font/woff": ".woff",
  "font/ttf": ".ttf",
  "font/otf": ".otf",
  "application/font-woff": ".woff",
  "application/x-font-woff": ".woff",
  "application/x-font-ttf": ".ttf",
  "application/x-font-opentype": ".otf",
  "application/vnd.ms-opentype": ".otf",
};
/**
 * The elements a script's JSX creates: the intrinsic tags it writes, and whether a component (or
 * a tag the build can't read) could make others. JSX is compiled into createElement() calls, so a
 * script that has any creates elements the build's static tree doesn't hold. Comments are
 * skipped; a `<` that could open a tag is followed by the name and then white space, `/` or `>`,
 * and isn't part of a type argument (`Array<T>` has the name against the previous word).
 */
function jsxElements(src: string): { tags: string[]; any: boolean; unknown: boolean } {
  let text = "";
  for (let i = 0; i < src.length; i++) {
    if (src[i] === "/" && src[i + 1] === "/") {
      const end = src.indexOf("\n", i + 2);
      i = end < 0 ? src.length : end;
      continue;
    }
    if (src[i] === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      i = end < 0 ? src.length : end + 1;
      continue;
    }
    text += src[i];
  }
  const tags: string[] = [];
  let any = false;
  let unknown = false;
  const tag = /<([A-Za-z][\w$.:-]*)/g;
  for (let m = tag.exec(text); m !== null; m = tag.exec(text)) {
    const after = text[m.index + m[0].length] ?? "";
    if (after !== "" && !/[\s/>]/.test(after)) continue;
    // `Array<T>` and `useState<Foo>` are type arguments, not elements.
    if (/[\w$]/.test(text[m.index - 1] ?? "")) continue;
    any = true;
    const name = m[1];
    if (/^[a-z]/.test(name) && !name.includes(".")) tags.push(name.toLowerCase());
    // A component, a member expression or a namespaced tag can render anything.
    else unknown = true;
  }
  // A script compiled before native reads it creates elements through the jsx runtime instead.
  if (/\bjsx(?:s|DEV)?\s*\(/.test(text)) {
    any = true;
    for (const m of text.matchAll(/\bjsx(?:s|DEV)?\s*\(\s*(["'`])([\w-]+)\1/g)) tags.push(m[2].toLowerCase());
    if (/\bjsx(?:s|DEV)?\s*\(\s*[^"'`\s]/.test(text)) unknown = true;
  }
  return { tags, any, unknown };
}

export function compileApp(htmlPath: string, diags: Diagnostics, options: CompileOptions = {}): CompiledApp {
  const appDir = dirname(htmlPath);
  const resolveUrl = (href: string) =>
    href.startsWith("/") && options.root ? join(options.root, href) : join(appDir, href.split(/[?#]/)[0]);
  const inlineScripts: string[] = [];
  /** Counts <script> elements as the document is scanned, for document.currentScript. */
  let scriptOrder = 0;
  const scriptSrcs: string[] = [];
  const rel = (p: string) => relative(process.cwd(), p) || p;
  const htmlFile = rel(htmlPath);
  const doc = parseHtml(readFileSync(htmlPath, "utf8"), htmlFile, diags);
  // Value rows are process-wide tables the parser registers into; each app starts its own.
  exprRows.load([]);
  clipRows.load([]);
  willChangeRows.load([]);
  clipPathRows.load([]);
  transformRows.load([]);
  originRows.load([]);
  clipMarginRows.load([]);
  positionRows.load([]);
  dashRows.load([]);
  animRows.load([]);
  animKeyframes.load([]);
  animNames.load([]);

  const dataImagePath = (url: string): string | null => {
    const m = /^data:([^,]*),(.*)$/is.exec(url);
    if (m === null) return null;
    const params = m[1].split(";").map((p) => p.trim().toLowerCase());
    if (params.indexOf("base64") < 0) return null;
    const ext = DATA_IMAGE_EXTENSIONS[params[0]];
    if (ext === undefined) return null;
    let bytes: Buffer;
    try {
      bytes = Buffer.from(m[2], "base64");
    } catch {
      return null;
    }
    if (bytes.length === 0) return null;
    const dir = join(tmpdir(), "native-images");
    const target = join(dir, createHash("sha1").update(url).digest("hex").slice(0, 20) + ext);
    if (!existsSync(target)) {
      mkdirSync(dir, { recursive: true });
      writeFileSync(target, bytes);
    }
    return target;
  };

  const dataFontPath = (url: string): string | null => {
    const m = /^data:([^,]*),(.*)$/is.exec(url);
    if (m === null) return null;
    const params = m[1].split(";").map((p) => p.trim().toLowerCase());
    if (params.indexOf("base64") < 0) return null;
    const ext = DATA_FONT_EXTENSIONS[params[0]];
    if (ext === undefined) return null;
    let bytes: Buffer;
    try {
      bytes = Buffer.from(m[2], "base64");
    } catch {
      return null;
    }
    if (bytes.length === 0) return null;
    const dir = join(tmpdir(), "htmlc-fonts");
    const target = join(dir, createHash("sha1").update(url).digest("hex").slice(0, 20) + ext);
    if (!existsSync(target)) {
      mkdirSync(dir, { recursive: true });
      writeFileSync(target, bytes);
    }
    return target;
  };

  // --- Images --------------------------------------------------------------
  // Like @font-face, a referenced file is resolved at build time, against the page (or the
  // site root when the URL starts with "/"); the runtime and host only ever see file paths.
  // Apps aren't bundled yet, so the path is the build-time location (see docs/supported.md).
  const images: string[] = [];
  const imageIds = new Map<string, number>();
  // An SVG file is compiled into a draw program the runtime rasterizes; a raster file is left for
  // the host to decode. Both are IMAGE_FILES entries.
  const svgImageFiles: number[] = [];
  const svgImagePrograms: string[] = [];
  // A value held as text — a style attribute, or a declaration whose text the runtime compiles —
  // resolves its url() where the style is computed, and the runtime has no build root to resolve
  // a URL against: it looks the text up in IMAGE_URLS. Every image the build resolves is recorded
  // here for it, whichever context asked for it.
  const inlineUrls: string[] = [];
  const inlineUrlFiles = new Map<string, number>();
  const recordInlineUrl = (url: string, id: number): void => {
    if (inlineUrlFiles.has(url)) return;
    inlineUrlFiles.set(url, id);
    inlineUrls.push(url);
  };
  const registerImage = (url: string, base: string, file: string, line: number, col: number): number => {
    const raw = url.trim();
    if (raw === "") return -1;
    // A data: image carries its own bytes; they are written out once so the runtime and the host
    // see a path like they do for every other image.
    const inline = /^data:/i.test(raw) ? dataImagePath(raw) : null;
    if (/^data:/i.test(raw) && inline === null) {
      diags.warn(file, line, col, "data: image URL isn't a base64 image this build can decode");
      return -1;
    }
    if (/^https?:/i.test(raw) || raw.startsWith("//")) {
      diags.warn(file, line, col, `remote image '${raw}' can't be loaded`);
      return -1;
    }
    const clean = raw.split(/[?#]/)[0];
    const target = inline !== null ? inline : clean.startsWith("/") && options.root ? join(options.root, clean) : join(base, clean);
    if (!existsSync(target)) { diags.warn(file, line, col, `image '${raw}' not found`); return -1; }
    const hit = imageIds.get(target);
    if (hit !== undefined) {
      recordInlineUrl(raw, hit);
      return hit;
    }
    const id = images.length;
    // The runtime reads the file from the bundle when there is one; a data: image's temporary
    // file gets a stable name there.
    const stored = options.bundle === undefined ? target
      : options.bundle.add(target, inline === null ? undefined : "_data/" + target.slice(target.lastIndexOf("/") + 1));
    images.push(stored);
    imageIds.set(target, id);
    recordInlineUrl(raw, id);
    if (/\.svg$/i.test(target)) {
      const img = compileSvgImage(target, diags);
      if (img !== null) {
        svgImageFiles.push(id);
        svgImagePrograms.push(img.program);
      }
    }
    return id;
  };
  /**
   * Records a srcset's candidates in the bundle. Only the source the build picks is drawn today,
   * so these files are not IMAGE_FILES entries; collecting them means an app's srcset candidates
   * are in its bundle if selection arrives, and a script that sets one as an image's src finds it.
   */
  const collectSrcset = (list: string, base: string): void => {
    if (options.bundle === undefined) return;
    for (const candidate of list.split(",")) {
      const url = candidate.trim().split(/\s+/)[0] ?? "";
      if (url === "" || /^data:/i.test(url) || /^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith("//")) continue;
      const clean = url.split(/[?#]/)[0];
      const target = clean.startsWith("/") && options.root ? join(options.root, clean) : join(base, clean);
      if (existsSync(target)) options.bundle.add(target);
    }
  };

  // --- Background layer lists ----------------------------------------------
  // Each layer longhand's value is a row id in one of these tables; identical lists share a row.
  // Each kind's table is a list of rows; a row holds the kind's values for every layer.
  const bgRows: number[][][] = [];
  for (let k = 0; k < P.BG_KIND_COUNT; k++) bgRows.push([]);
  const bgIds: Map<string, number>[] = [];
  for (let k = 0; k < P.BG_KIND_COUNT; k++) bgIds.push(new Map());
  const registerBackground = (kind: number, row: number[]): number => {
    const key = row.join(",");
    const hit = bgIds[kind].get(key);
    if (hit !== undefined) return hit;
    const id = bgRows[kind].length;
    bgRows[kind].push(row);
    bgIds[kind].set(key, id);
    return id;
  };

  // --- border-image longhands ----------------------------------------------
  // A border-image slice, width, outset or repeat value points into this table; identical rows
  // share an id, like the background lists above.
  const borderImageRows: number[][] = [];
  const borderImageIds = new Map<string, number>();
  const registerBorderImage = (row: number[]): number => {
    const key = row.join(",");
    const hit = borderImageIds.get(key);
    if (hit !== undefined) return hit;
    const id = borderImageRows.length;
    borderImageRows.push(row);
    borderImageIds.set(key, id);
    return id;
  };

  // --- Gradient images -----------------------------------------------------
  // A gradient layer's value points into one table of encoded gradients (see
  // shared/css/gradients.ts); identical gradients share an entry.
  const gradients: string[] = [];
  // The CSS text of each, in the same order: the encoding is the painter's, and CSSOM reads a
  // gradient image back from this.
  const gradientTexts: string[] = [];
  const gradientIds = new Map<string, number>();
  const registerGradient = (encoded: string, source: string = ""): number => {
    const hit = gradientIds.get(encoded);
    if (hit !== undefined) {
      if (gradientTexts[hit] === "") gradientTexts[hit] = source;
      return hit;
    }
    const id = gradients.length;
    gradients.push(encoded);
    gradientTexts.push(source);
    gradientIds.set(encoded, id);
    return id;
  };

  // --- OpenType feature lists -----------------------------------------------
  // A font-feature-settings value points into this table; each entry is the list's `tag=value`
  // pairs joined by semicolons, in the order the declaration wrote them. The host turns it into
  // the feature settings of the text that names it.
  const features: string[] = [];
  const featureIds = new Map<string, number>();
  const registerFeatures = (spec: string): number => {
    const hit = featureIds.get(spec);
    if (hit !== undefined) return hit;
    const id = features.length;
    features.push(spec);
    featureIds.set(spec, id);
    return id;
  };
  // A font-variation-settings value points into this table the same way, each entry a list of
  // axis tags and their values; the host sets the axes on the font of the text that names it.
  const variations: string[] = [];
  const variationIds = new Map<string, number>();
  const registerVariations = (spec: string): number => {
    const hit = variationIds.get(spec);
    if (hit !== undefined) return hit;
    const id = variations.length;
    variations.push(spec);
    variationIds.set(spec, id);
    return id;
  };

  // The ordered families of a font-family list, in FONT_FAMILY_LISTS: the runtime walks a list
  // when its first face covers only some characters (a unicode-range face).
  const familyLists: string[] = [];
  const familyListIds = new Map<string, number>();
  const registerFamilyList = (ids: number[]): number => {
    const key = ids.join(",");
    const hit = familyListIds.get(key);
    if (hit !== undefined) return hit;
    const id = familyLists.length;
    familyLists.push(key);
    familyListIds.set(key, id);
    return id;
  };

  // --- box-shadow lists -----------------------------------------------------
  // The value of `box-shadow` is a row id in this table; each row holds ten numbers per shadow.
  // The animation engine mixes lists into it too, so the table is shared (shared/css/shadows.ts).
  const registerShadow = (row: number[]): number => shadowRows.register(row);

  // --- grid track lists -----------------------------------------------------
  // A grid-template-columns (or -rows) value is a row id in this table: fourteen numbers per
  // track, the min and max slots of its minmax() (see shared/props.ts).
  const gridTrackRows: number[][] = [];
  const gridTrackIds = new Map<string, number>();
  const registerTrackList = (row: number[]): number => {
    const key = row.join(",");
    const hit = gridTrackIds.get(key);
    if (hit !== undefined) return hit;
    const id = gridTrackRows.length;
    gridTrackRows.push(row);
    gridTrackIds.set(key, id);
    return id;
  };

  // --- grid line names, named placements and named areas --------------------
  // Line and area names share one table; a placement names a line, an area list names the areas
  // its strings hold. A placement row is [name id, occurrence count, span flag]; an area list row
  // is a count and then, per area, its name id and the four lines it spans.
  const gridNames: string[] = [];
  const gridNameIds = new Map<string, number>();
  const registerTrackName = (name: string): number => {
    const hit = gridNameIds.get(name);
    if (hit !== undefined) return hit;
    const id = gridNames.length;
    gridNames.push(name);
    gridNameIds.set(name, id);
    return id;
  };
  const placementRows: number[][] = [];
  const placementIds = new Map<string, number>();
  const registerPlacement = (row: number[]): number => {
    const key = row.join(",");
    const hit = placementIds.get(key);
    if (hit !== undefined) return hit;
    const id = placementRows.length;
    placementRows.push(row);
    placementIds.set(key, id);
    return id;
  };
  const areaListRows: number[][] = [];
  const areaListIds = new Map<string, number>();
  const registerAreaList = (row: number[]): number => {
    const key = row.join(",");
    const hit = areaListIds.get(key);
    if (hit !== undefined) return hit;
    const id = areaListRows.length;
    areaListRows.push(row);
    areaListIds.set(key, id);
    return id;
  };
  // --- filter lists ---------------------------------------------------------
  // `filter` and `backdrop-filter` hold a row id in this table; each row holds eight numbers per
  // filter function (see shared/css/filters.ts).
  const filterRows: number[][] = [];
  const filterIds = new Map<string, number>();
  const registerFilter = (row: number[]): number => {
    const key = row.join(",");
    const hit = filterIds.get(key);
    if (hit !== undefined) return hit;
    const id = filterRows.length;
    filterRows.push(row);
    filterIds.set(key, id);
    return id;
  };

  // --- Collect head info, stylesheets and scripts -------------------------
  let title = "native app";
  let width = 800;
  let windowOptions = "";
  let height = 600;
  // A sheet's <style> or <link> element, so a script that disables or re-media-queries the sheet
  // can reach the rules the build compiled from it; the element's media condition ("" for none),
  // which the runtime tests on every style pass; and whether the element starts out disabled.
  const sheets: { text: string; file: string; line: number; col: number; node: HElement | null; media: string; disabled: boolean }[] = [];
  const scripts: ScriptFile[] = [];
  const handlers: HandlerAttribute[] = [];
  const scriptText: string[] = [];

  const all = findAll(doc, () => true);
  for (const el of all) {
    // An inline event handler is script too: what it does to the DOM decides whether a selector
    // can start matching after the build, and the classes it names must stay possible. A page
    // built with ignoreScripts never runs its handlers, so they don't count there.
    if (!options.ignoreScripts) {
      for (const [name, value] of el.attrs) {
        if (name.length > 2 && name.startsWith("on") && value !== "") scriptText.push(value);
      }
    }
    if (el.tag === "title") title = textOf(el).trim() || title;
    if (el.tag === "meta" && el.attrs.get("name") === "native-window") {
      const content = el.attrs.get("content") ?? "";
      const w = /width\s*=\s*(\d+)/.exec(content);
      const h = /height\s*=\s*(\d+)/.exec(content);
      if (w) width = parseInt(w[1], 10);
      if (h) height = parseInt(h[1], 10);
      windowOptions = parseWindowOptions(content, (msg) => diags.warn(htmlFile, el.line, el.col, msg));
    }
    if (el.tag === "link" && (el.attrs.get("rel") ?? "").split(/\s+/).includes("stylesheet")) {
      const href = el.attrs.get("href");
      if (!href) continue;
      // The build only reads local files. A browser carries on when a stylesheet can't be
      // fetched, so a remote one is a warning and the page is styled without it; any family it
      // would have defined falls back like any other unavailable font.
      if (/^data:/i.test(href)) {
        diags.warn(htmlFile, el.line, el.col, "data: stylesheet URLs aren't supported yet");
        continue;
      }
      if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("//")) {
        diags.warn(htmlFile, el.line, el.col, `remote stylesheet '${href}' can't be loaded`);
        continue;
      }
      const p = resolveUrl(href);
      if (!existsSync(p)) {
        diags.error(htmlFile, el.line, el.col, `stylesheet '${href}' not found`);
        continue;
      }
      // The sheet's rules are compiled in, but the file travels with the app all the same: the
      // build collects every file the page links.
      if (options.bundle !== undefined) options.bundle.copy(p);
      sheets.push({
        text: readFileSync(p, "utf8"), file: rel(p), line: 1, col: 1, node: el,
        media: el.attrs.get("media") ?? "", disabled: el.attrs.has("disabled"),
      });
    }
    if (el.tag === "style") {
      sheets.push({
        text: textOf(el), file: htmlFile, line: el.line, col: el.col, node: el,
        media: el.attrs.get("media") ?? "", disabled: false,
      });
    }
    if (el.tag === "script") scriptOrder++;
    // A data block (an import map, a template) is not a script: it doesn't run, and its text isn't
    // JavaScript. The order still counts it, since currentScript indexes the page's script tags.
    if (el.tag === "script" && !isScriptCode(el)) continue;
    if (el.tag === "script" && options.ignoreScripts) {
      const src = el.attrs.get("src");
      if (src) scriptSrcs.push(src);
      else if (textOf(el).trim()) inlineScripts.push(scriptBody(textOf(el)));
      continue;
    }
    if (el.tag === "script") {
      const src = el.attrs.get("src");
      if (!src) {
        // An inline classic script is compiled like an external one, in document order.
        const text = scriptBody(textOf(el));
        if (text.trim() === "") continue;
        scripts.push({
          path: null, text, line: el.line, col: el.col, order: scriptOrder - 1,
          module: isModuleAttr(el),
        });
        scriptText.push(text);
        continue;
      }
      if (options.testharness && /(^|\/)testharnessreport\.js$/.test(src)) continue;
      // The test driver's accessibility queries are answered by runtime/a11y.ts (see the shim),
      // and its WebDriver plumbing has nothing to talk to here.
      if (options.testharness && /(^|\/)testdriver(-vendor|-actions)?\.js$/.test(src)) continue;
      if (options.testharness && /(^|\/)testharness\.js$/.test(src)) {
        const shim = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "testharness.js"), "utf8");
        scripts.push({ path: null, text: shim, line: 1, col: 1, order: scriptOrder - 1, module: false });
        scriptText.push(shim);
        continue;
      }
      if (/^https?:/.test(src)) {
        diags.error(htmlFile, el.line, el.col, `remote script '${src}' can't be compiled`, "vendor it and import it from your entry file");
        continue;
      }
      const p = resolveUrl(src);
      if (!existsSync(p)) {
        diags.error(htmlFile, el.line, el.col, `script '${src}' not found`);
        continue;
      }
      const text = scriptBody(readFileSync(p, "utf8"));
      // A source with imports or exports is a module whatever the attribute says, as it must be
      // to compile at all.
      scripts.push({
        path: p, text, line: el.line, col: el.col, order: scriptOrder - 1,
        module: isModuleAttr(el) || isModuleText(text),
      });
      scriptText.push(text);
    }
  }
  if (options.scriptDependencies) {
    for (const text of options.scriptDependencies(scripts.map((s) => ({ path: s.path, text: s.text })))) {
      scriptText.push(text);
    }
  }

  // --- Fonts ---------------------------------------------------------------
  // @font-face rules are registered before any declaration is compiled: a family can be used
  // before the rule that defines it, or in a different style sheet.
  const fonts: FontFace[] = [];
  // A family's id is its first appearance: the faces of one family share it, and the host picks
  // among them by the weight and style the text asks for.
  const familyIds = new Map<string, number>();
  // A family a font-family list names that the build has no @font-face for is left to the system:
  // the runtime asks the host for it by name, and the family falls back to the system font when
  // the machine has no such face. Its id follows the @font-face families'.
  const installedFamilies: string[] = [];
  const installedIds = new Map<string, number>();
  const registerFace = (f: FontFaceDecl, file: string, base: string) => {
    if (f.error !== undefined) { diags.warn(file, f.line, f.col, f.error); return; }
    if (f.dropped) return;
    if (f.family === "") { diags.warn(file, f.line, f.col, "@font-face has no font-family"); return; }
    if (f.sources.length === 0) { diags.warn(file, f.line, f.col, `@font-face for '${f.family}' has no url() or local() in src`); return; }
    // A src list names the same face in several places, and the first source that can be used is
    // the one the face takes. A local() names a font the system already has, which only the
    // running app can look up, so the names before the first file that loads travel with the face
    // and the host tries them in order before falling back to the file.
    const locals: string[] = [];
    let target = "";
    let fromData = false;
    let why = "";
    for (const s of f.sources) {
      // A local() naming one of the system's private faces (a name starting with a dot) resolves
      // nothing in a browser, so the face falls to its next source.
      if (s.local !== null) { if (s.local !== "" && !s.local.startsWith(".")) locals.push(s.local); continue; }
      const url = s.url ?? "";
      if (/^data:/i.test(url)) {
        const inline = dataFontPath(url);
        if (inline === null) { why = why || "@font-face data: URL isn't a font this build can decode"; continue; }
        target = inline;
        fromData = true;
        break;
      }
      if (/^https?:/i.test(url) || url.startsWith("//")) { why = `@font-face remote font '${url}' can't be loaded`; continue; }
      const p = url.startsWith("/") && options.root
        ? join(options.root, url.split(/[?#]/)[0])
        : join(base, url.split(/[?#]/)[0]);
      if (existsSync(p)) { target = p; break; }
      why = `@font-face font '${url}' not found`;
    }
    if (target === "" && locals.length === 0) { diags.warn(file, f.line, f.col, why || "@font-face has no src"); return; }
    const same = fonts.find((x) => x.family === f.family && x.weightLo === f.weightLo &&
      x.weightHi === f.weightHi && x.italic === f.italic && x.ranges === f.ranges &&
      x.stretch === f.stretch && x.ascent === f.ascent && x.descent === f.descent && x.lineGap === f.lineGap);
    if (same !== undefined) {
      diags.note(file, f.line, f.col, `@font-face '${f.family}' already has a face for this weight and style; this one is ignored`);
      return;
    }
    if (!familyIds.has(f.family)) familyIds.set(f.family, familyIds.size);
    // A face whose descriptor left the weight to the file takes the file's own OS/2 weight, so a
    // bold file registered without a descriptor is not emboldened again.
    const lo = f.weightAuto && target !== "" ? fontFileWeight(target) : f.weightLo;
    const hi = f.weightAuto && target !== "" ? lo : f.weightHi;
    const path = target === "" ? ""
      : options.bundle !== undefined ? options.bundle.add(target, fromData ? "_data/" + basename(target) : undefined)
      : target;
    fonts.push({ family: f.family, path, source: target, locals, weightLo: lo, weightHi: hi, italic: f.italic, ranges: f.ranges, features: f.features, stretch: f.stretch, ascent: f.ascent, descent: f.descent, lineGap: f.lineGap });
  };
  // A sheet's @import rules are inlined once, before any scan, so a face, palette or namespace an
  // imported sheet declares is the page's, as it is in a browser. The parse below reads the same
  // text.
  for (const sheet of sheets) {
    const abs = sheet.file === htmlFile ? htmlPath : join(process.cwd(), sheet.file);
    sheet.text = inlineImports(sheet.text, abs, sheet.file, options.root ?? "", diags, [abs], 0,
      options.bundle === undefined ? undefined : (file) => options.bundle!.copy(file));
  }
  for (const sheet of sheets) {
    const base = sheet.file === htmlFile ? appDir : dirname(join(process.cwd(), sheet.file));
    for (const face of scanFontFaces(sheet.text)) registerFace(face, sheet.file, base);
  }
  // @font-palette-values rules are registered the same way, before any declaration is compiled.
  // A rule's font-family names resolve to family ids once the declarations have registered every
  // family they use, so the rules are kept and written into the tables at the end.
  const palettes: FontPaletteDecl[] = [];
  for (const sheet of sheets) {
    for (const rule of scanPaletteValues(sheet.text)) {
      if (rule.error !== undefined) { diags.warn(sheet.file, rule.line, rule.col, rule.error); continue; }
      palettes.push(rule);
    }
  }
  // A palette name's id is its first rule's position among the names. The last rule with the
  // name and a matching font-family wins at style time.
  const paletteNames: string[] = [];
  const paletteIds = new Map<string, number>();
  for (const p of palettes) {
    if (!paletteIds.has(p.name)) { paletteIds.set(p.name, paletteNames.length); paletteNames.push(p.name); }
  }
  // The paint servers a fill/stroke names with url(#id), in first-use order: a declaration holds
  // an index into this table, so the runtime can find the server by its id (see
  // shared/svg-paint.ts). Every declaration in the app shares the table.
  const svgPaintUrls: string[] = [];
  const svgPaintIds = new Map<string, number>();
  const registerPaintUrl = (url: string): number => {
    const hit = svgPaintIds.get(url);
    if (hit !== undefined) return hit;
    const id = svgPaintUrls.length;
    svgPaintUrls.push(url);
    svgPaintIds.set(url, id);
    return id;
  };
  // The container-name lists, in first-use order: a declaration holds an index into this table,
  // which the runtime compares against an @container query's name.
  const containerNameRows: string[] = [];
  const containerNameIds = new Map<string, number>();
  const registerContainerNames = (list: string): number => {
    const hit = containerNameIds.get(list);
    if (hit !== undefined) return hit;
    const id = containerNameRows.length;
    containerNameRows.push(list);
    containerNameIds.set(list, id);
    return id;
  };
  // The family names, in id order: a face's index in FONT_FILES is also its index in the three
  // face tables below.
  const familyNames: string[] = [];
  for (const name of familyIds.keys()) familyNames.push(name);
  // A value context resolves the resources a declaration names against the style sheet it came
  // from: an image URL and a background list row both belong to the whole app, but a relative
  // path is read from the sheet's own directory, like @font-face.
  // @font-feature-values aliases are page-wide: collect them before any sheet's values compile.
  const featureValueSpecs = new Map<string, string>();
  for (const sheet of sheets) {
    for (const [k, v] of scanFontFeatureValues(sheet.text)) featureValueSpecs.set(k, v);
  }
  const contextFor = (base: string, file: string): FontContext => ({
    family: (name, quoted = false) => {
      // A quoted name is a family name whatever it spells: `"fantasy"` is not the fantasy keyword.
      if (!quoted) {
        const generic = genericFamily(name);
        if (generic !== undefined) return generic;
      }
      const id = familyIds.get(name);
      if (id !== undefined) return P.FF_CUSTOM + id;
      // A name starting with a dot is one of the system's private faces (`.SF NS Mono`,
      // `.AppleSystemUIFont`): browsers refuse to open those from a font-family, and only a
      // local() source inside @font-face may name one.
      if (name.startsWith(".")) return P.FF_SYSTEM;
      // Any other name may be a family the system has; the runtime resolves it with the host.
      const named = installedIds.get(name);
      if (named !== undefined) return P.FF_CUSTOM + familyNames.length + named;
      installedIds.set(name, installedFamilies.length);
      installedFamilies.push(name);
      return P.FF_CUSTOM + familyNames.length + installedFamilies.length - 1;
    },
    // A name the build can't check is still a family the system may have, so the list keeps it
    // rather than dropping through to the next one: a missing face falls back at draw time.
    available: (name) => genericFamily(name) !== undefined || name !== "",
    features: registerFeatures,
    variations: registerVariations,
    palette: (name) => paletteIds.get(name) ?? -1,
    familyList: registerFamilyList,
    image: (url, line, col) => registerImage(url, base, file, line, col),
    background: registerBackground,
    borderImage: registerBorderImage,
    gradient: registerGradient,
    shadow: registerShadow,
    paint: registerPaintUrl,
    tracks: registerTrackList,
    featureValue: (kind: string, name: string) => featureValueSpecs.get(kind + "|" + name.toLowerCase()) ?? null,
    containerNames: registerContainerNames,
    trackName: registerTrackName,
    placement: registerPlacement,
    areaList: registerAreaList,
    filter: registerFilter,
  });
  const pageContext = contextFor(appDir, htmlFile);
  const rules: CssRule[] = [];
  // The item lists behind `content`, in first-use order (see shared/css/content.ts), and the
  // counter lists behind counter-reset/-increment/-set.
  const contentItems: string[] = [];
  const contentIds = new Map<string, number>();
  const counterItems: string[] = [];
  const counterIds = new Map<string, number>();
  const internRow = (list: string[], ids: Map<string, number>, encoded: string): number => {
    const hit = ids.get(encoded);
    if (hit !== undefined) return hit;
    const id = list.length;
    list.push(encoded);
    ids.set(encoded, id);
    return id;
  };
  const contentContext: ContentContext = {
    item: (encoded) => internRow(contentItems, contentIds, encoded),
    counter: (encoded) => internRow(counterItems, counterIds, encoded),
  };
  const styleContext: FontContext = {
    family: pageContext.family,
    available: pageContext.available,
    features: pageContext.features,
    variations: pageContext.variations,
    image: (url, line, col) => pageContext.image(url, line, col),
    background: pageContext.background,
    gradient: pageContext.gradient,
    shadow: pageContext.shadow,
    paint: registerPaintUrl,
    tracks: pageContext.tracks,
    containerNames: registerContainerNames,
    trackName: pageContext.trackName,
    placement: pageContext.placement,
    areaList: pageContext.areaList,
    filter: pageContext.filter,
  };
  // Custom properties the sheets register with @property, in the order they are declared.
  const props: PropertyRule[] = [];
  // The @counter-style rules, as the rows the runtime reads back, and the names one may name, in
  // first-use order. A later rule for the same name wins when the runtime registers them.
  const counterStyleRows: string[] = [];
  const counterStyleNames: string[] = [];
  const counterStyleIds = new Map<string, number>();
  const counterStylesContext: CounterStyleContext = {
    style: (encoded) => {
      counterStyleRows.push(encoded);
    },
    name: (name) => {
      const lower = name.toLowerCase();
      const hit = counterStyleIds.get(lower);
      if (hit !== undefined) return hit;
      const id = counterStyleNames.length;
      counterStyleNames.push(lower);
      counterStyleIds.set(lower, id);
      return id;
    },
  };
  // A list-style-type or counter() that names an @counter-style rule registers the name here.
  contentContext.counterStyle = (name: string): number => counterStylesContext.name(name);
  // The @keyframes rules, by name: a rule replaces what an earlier one of the same name had,
  // and a block replaces an earlier one at the same offset.
  const keyframeBlocks = new Map<string, Map<number, number[]>>();
  const keyframesContext: KeyframesContext = {
    rule: (name) => {
      keyframeBlocks.set(name, new Map());
    },
    block: (name, offset, decls) => {
      let blocks = keyframeBlocks.get(name);
      if (blocks === undefined) {
        blocks = new Map();
        keyframeBlocks.set(name, blocks);
      }
      // A property declared twice in one block keeps its last value, as in any other rule.
      const row: number[] = [];
      const put = (p: number, v: number, u: number): void => {
        for (let k = 0; k + 2 < row.length; k += 3) {
          if (row[k] === p) {
            row[k + 1] = v;
            row[k + 2] = u;
            return;
          }
        }
        row.push(p, v, u);
      };
      for (const d of decls) {
        if (d.p < 0) {
          // A CSS-wide keyword: the frame carries the keyword and resolves it against the
          // element when the animation applies it (see U_WIDE).
          const ids = longhandIds(d.prop === undefined ? "" : d.prop);
          if (ids === null) continue;
          const code = wideCode(d.value === undefined ? "" : d.value);
          for (const p of ids) put(p, code, P.U_WIDE);
          continue;
        }
        put(d.p, d.v, d.u);
      }
      blocks.set(offset, row);
    },
  };
  rules.push(...parseCss(UA_CSS, "<ua>", diags, "ua", undefined, undefined, null, props));
  // Cascade layers span the document's author style sheets, and their order follows the order the
  // sheets are parsed in, which is the order they appear in the document.
  // @namespace prefixes are page-wide while the sheets parse; an undeclared prefix is an
  // invalid selector, as CSS says.
  const namespaces = new Map<string, string>();
  for (const sheet of sheets) for (const [k, v] of scanNamespaces(sheet.text)) namespaces.set(k, v);
  setSelectorNamespaces(namespaces.size === 0 ? null : namespaces);
  const layers = new LayerRegistry();
  // Which sheet each parsed rule came from, for a sheet a script edits at runtime: the compiled
  // copies of its rules have to stand down when the script takes the sheet over.
  const ruleSheet = new Map<CssRule, number>();
  for (let si = 0; si < sheets.length; si++) {
    const sheet = sheets[si];
    const base = sheet.file === htmlFile ? appDir : dirname(join(process.cwd(), sheet.file));
    const abs = sheet.file === htmlFile ? htmlPath : join(process.cwd(), sheet.file);
    const text = sheet.text;
    const parsed = parseCss(text, sheet.file, diags, "author", contextFor(base, sheet.file), contentContext, layers, props, keyframesContext, counterStylesContext);
    for (const r of parsed) ruleSheet.set(r, si);
    rules.push(...parsed);
  }
  // Each block becomes one row: [name id, offset, property, value, unit, ...], the offsets in
  // order so the engine can step through them.
  for (const name of Array.from(keyframeBlocks.keys())) {
    const blocks = keyframeBlocks.get(name);
    if (blocks === undefined) continue;
    const offsets = Array.from(blocks.keys()).sort((a, b) => a - b);
    if (offsets.length === 0) {
      // A @keyframes with no block of its own still defines an animation: one that exists, moves
      // nothing and reports itself through getAnimations().
      animKeyframes.register([animNames.register(name), -1]);
      continue;
    }
    for (const offset of offsets) {
      const decls = blocks.get(offset);
      if (decls === undefined) continue;
      const row: number[] = [animNames.register(name), offset];
      for (const n of decls) row.push(n);
      animKeyframes.register(row);
    }
  }
  const layerOrder = layers.order();

  // --- Build the node table ------------------------------------------------
  // As in HTML parsing, <html> and <body> are implied when the markup leaves them out.
  let htmlEl = doc.children.find((c): c is HElement => c.kind === "element" && c.tag === "html");
  if (!htmlEl) {
    htmlEl = { kind: "element", tag: "html", attrs: new Map(), children: doc.children, line: 1, col: 1 };
  }
  if (!htmlEl.children.some((c) => c.kind === "element" && c.tag === "body")) {
    const body: HElement = {
      kind: "element", tag: "body", attrs: new Map(),
      children: htmlEl.children.filter((c) => !(c.kind === "element" && c.tag === "head")), line: 1, col: 1,
    };
    htmlEl.children = [...htmlEl.children.filter((c) => c.kind === "element" && c.tag === "head"), body];
  }
  const nodes: OutNode[] = [];
  /** The node index each <style> element's sheet is mounted at (see the NODE_SHEET table). */
  const sheetNodeIndex = new Map<HElement, number>();
  const sourceEls: (HElement | null)[] = [];
  const nodeImages: number[] = [];
  /** Presentational hints: HTML width/height attributes, below any author rule in the cascade. */
  const hints: Decl[][] = [];
  /**
   * Elements that keep a slot for presentation attributes a script can change (SVG's). The slot's
   * declarations are filled at runtime from the attributes the element carries then, so changing
   * one restyles the element (see runtime/hints.ts).
   */
  const hintSlots: boolean[] = [];
  /** Each table's cellpadding attribute, applied to the cells it owns after the tree is built. */
  const tablePadding = new Map<number, string | undefined>();
  const staticClasses = new Set<string>();

  /** The pseudo-element a node tag stands for, or PE_NONE. */
  const nodePseudo = (tag: string): number =>
    tag === P.PSEUDO_TAGS[P.PE_BEFORE] ? P.PE_BEFORE
      : tag === P.PSEUDO_TAGS[P.PE_AFTER] ? P.PE_AFTER
      : tag === P.PSEUDO_TAGS[P.PE_MARKER] ? P.PE_MARKER
      : tag === P.PSEUDO_TAGS[P.PE_PLACEHOLDER] ? P.PE_PLACEHOLDER
      : tag === P.PSEUDO_TAGS[P.PE_BACKDROP] ? P.PE_BACKDROP
      : tag === P.PSEUDO_TAGS[P.PE_FIRST_LINE] ? P.PE_FIRST_LINE
      : tag === P.PSEUDO_TAGS[P.PE_FIRST_LETTER] ? P.PE_FIRST_LETTER
      : tag === P.PSEUDO_TAGS[P.PE_SELECTION] ? P.PE_SELECTION
      : tag === P.PSEUDO_TAGS[P.PE_HIGHLIGHT] ? P.PE_HIGHLIGHT
      : tag === P.PSEUDO_TAGS[P.PE_TARGET_TEXT] ? P.PE_TARGET_TEXT : P.PE_NONE;

  /**
   * Could a rule style this element's ::before, ::after or ::marker? The box is generated for
   * any such rule, not only one with `content`: a ::before or ::after is hidden when its content
   * ends up none, and getComputedStyle() then still reports the pseudo-element's own style.
   */
  const hasPseudoRule = (el: HElement, kind: number, name: string | null = null): boolean => {
    const id = el.attrs.get("id") ?? "";
    const classes = (el.attrs.get("class") ?? "").split(/\s+/).filter(Boolean);
    const isRoot = el === htmlEl;
    return rules.some((r) => r.selectors.some((s) => s.pseudo === kind &&
      (name === null || s.pseudoName === name) &&
      (s.tagNs !== undefined || s.tag === null || s.tag === el.tag) && (s.id === null || s.id === id) && (!s.root || isRoot) &&
      s.classes.every((c) => classes.includes(c))));
  };

  /** A child node for generated content. It carries no attributes: its style is all rules. */
  const addPseudo = (parent: number, kind: number, name: string = "") => {
    nodes.push({ tag: P.PSEUDO_TAGS[kind], id: "", attrs: [], style: "", classes: [], parent, text: "", rules: [], states: 0, pseudoName: name });
    sourceEls.push(null);
    nodeImages.push(-1);
    hints.push([]);
    hintSlots.push(false);
  };

  /** The ::highlight() names the style sheets use, in the order the rules name them. */
  const highlightNames: string[] = [];
  for (const r of rules) {
    for (const s of r.selectors) {
      if (s.pseudo === P.PE_HIGHLIGHT && s.pseudoName !== "" && highlightNames.indexOf(s.pseudoName) < 0) {
        highlightNames.push(s.pseudoName);
      }
    }
  }
  /** A node for an element whose content is never laid out (`<script>`, `<style>`, `<head>`'s
   *  metadata): its text is kept on the node itself, so `textContent` reads it, and no child nodes
   *  are made. It still takes part in the cascade, where the UA sheet hides it. */
  const addLeaf = (el: HElement, parent: number): number => {
    const idx = nodes.length;
    // A <style>, or a <link rel=stylesheet>, hosts a sheet a script can reach through the CSSOM.
    if (el.tag === "style") sheetNodeIndex.set(el, idx);
    else if (el.tag === "link" && (el.attrs.get("rel") ?? "").split(/\s+/).includes("stylesheet")) sheetNodeIndex.set(el, idx);
    const attrs: string[] = [];
    for (const [k, v] of el.attrs) if (k !== "id" && k !== "class" && k !== "style") attrs.push(k, v);
    const flatText = (node: HNode): string =>
      node.kind === "text" ? node.text : node.kind === "pi" ? "" : node.children.map(flatText).join("");
    nodes.push({
      tag: el.tag, id: el.attrs.get("id") ?? "", attrs, style: el.attrs.get("style") ?? "", classes: [],
      parent, text: el.children.map(flatText).join(""), rules: [], states: 0,
    });
    sourceEls.push(el);
    nodeImages.push(-1);
    hints.push([]);
    hintSlots.push(false);
    return idx;
  };

  // A namespace prefix ("<svg:svg>", as XHTML tests write it) names the same element.
  const addEl = (el: HElement, parent: number, inSvg: boolean = false, parentEl: HElement | null = null): number => {
    const idx = nodes.length;
    const localTag = el.tag.slice(el.tag.lastIndexOf(":") + 1);
    const isSvg = inSvg || localTag === "svg";
    const classes = (el.attrs.get("class") ?? "").split(/\s+/).filter(Boolean);
    classes.forEach((c) => staticClasses.add(c));
    const attrs: string[] = [];
    for (const [k, v] of el.attrs) if (k !== "id" && k !== "class" && k !== "style") attrs.push(k, v);
    nodes.push({
      tag: el.tag, id: el.attrs.get("id") ?? "", attrs, style: el.attrs.get("style") ?? "", classes,
      parent, text: "", rules: [], states: 0,
    });
    const hintDecls: Decl[] = [];
    nodeImages.push(-1);
    if (el.tag === "img" || el.tag === "embed" || el.tag === "object") {
      // An <embed>'s src and an <object>'s data name the picture the element is replaced by,
      // just as an <img>'s src does; without one an <object> keeps its fallback content. A
      // <picture> picks its image from its first <source srcset>, so that is what its <img> shows.
      let src = el.tag === "object" ? el.attrs.get("data") : el.attrs.get("src");
      if (src === undefined && el.tag === "img" && parentEl !== null && parentEl.tag === "picture") {
        for (const sibling of parentEl.children) {
          if (sibling.kind !== "element" || sibling.tag !== "source") continue;
          const list = sibling.attrs.get("srcset");
          if (list === undefined) continue;
          const first = list.split(",")[0].trim().split(/\s+/)[0];
          if (first !== "") { src = first; break; }
        }
      }
      if (src !== undefined) nodeImages[idx] = registerImage(src, appDir, htmlFile, el.line, el.col);
      // Every candidate of an <img>'s srcset travels with the app, even though the build draws
      // only one source today (see collectSrcset).
      const list = el.attrs.get("srcset");
      if (list !== undefined) collectSrcset(list, appDir);
      const w = dimensionAttr(el.attrs.get("width"));
      const h = dimensionAttr(el.attrs.get("height"));
      if (w !== null) hintDecls.push({ p: P.P_WIDTH, v: w.v, u: w.u });
      if (h !== null) hintDecls.push({ p: P.P_HEIGHT, v: h.v, u: h.u });
    }
    // An <audio> or <video> source is copied into the app's bundle, where the runtime's fetch()
    // resolves the src again; a data: URL carries its own bytes and a remote one can't be read.
    if (el.tag === "audio" || el.tag === "video") {
      const src = el.attrs.get("src");
      if (src !== undefined && src !== "" && !/^data:/i.test(src) && !/^https?:/i.test(src) && !src.startsWith("//")) {
        const clean = src.split(/[?#]/)[0];
        const target = clean.startsWith("/") && options.root ? join(options.root, clean) : join(appDir, clean);
        if (!existsSync(target)) diags.warn(htmlFile, el.line, el.col, `media '${src}' not found`);
        else if (options.bundle !== undefined) options.bundle.add(target);
      }
    }
    // HTML presentational attributes on tables and cells, compiled through the ordinary value
    // parser so they mean exactly what the equivalent CSS declaration would.
    const hint = (css: string) => hintDecls.push(...compileDeclarations(css, () => [el.line, el.col], htmlFile, diags, pageContext));
    if (el.tag === "table") {
      const cs = dimensionAttr(el.attrs.get("cellspacing"));
      if (cs !== null && cs.u === P.U_PX) {
        hint(`border-spacing: ${cs.v}px`);
      }
      const bd = dimensionAttr(el.attrs.get("border"));
      if (bd !== null && bd.u === P.U_PX) hint(`border: ${bd.v}px solid #808080`);
      const cp = el.attrs.get("cellpadding");
      if (cp !== undefined) tablePadding.set(idx, cp);
    }
    if (el.tag === "td" || el.tag === "th" || el.tag === "table") {
      const w = dimensionAttr(el.attrs.get("width"));
      const h = dimensionAttr(el.attrs.get("height"));
      if (w !== null) hintDecls.push({ p: P.P_WIDTH, v: w.v, u: w.u });
      if (h !== null) hintDecls.push({ p: P.P_HEIGHT, v: h.v, u: h.u });
    }
    // A column's width attribute sizes the grid column it applies to (HTML §4.9.11), and the
    // cells of every row in it take that width; a <colgroup>'s does the same for its columns.
    if (el.tag === "col" || el.tag === "colgroup") {
      const w = dimensionAttr(el.attrs.get("width"));
      if (w !== null) hintDecls.push({ p: P.P_WIDTH, v: w.v, u: w.u });
    }
    // SVG inside the document: its presentation attributes are zero-specificity declarations,
    // below any author rule, which is exactly where the cascade above puts hints. A script can
    // change any of them, so the element keeps a slot in the cascade for them and the runtime
    // fills it from the attributes the element carries (runtime/hints.ts) — the build writes no
    // values here.
    if (isSvg) hintSlots[idx] = true;
    hints.push(hintDecls);
    if (el.tag === "input" && !["text", "password", "search", "email", "url", "tel", "number", "checkbox", "radio", "range", "hidden", "button", "submit", "reset", "color", "date", "month", "week", "time", "datetime-local", ""].includes((el.attrs.get("type") ?? "").toLowerCase())) {
      diags.warn(htmlFile, el.line, el.col, `<input type="${el.attrs.get("type")}"> isn't supported yet; it renders as a text field`);
    }
    sourceEls.push(el);
    // A <source> only selects for its <picture>: its candidates are assets of the page even if
    // this build's picture support picks only the first one.
    if (el.tag === "source") {
      const list = el.attrs.get("srcset");
      if (list !== undefined) collectSrcset(list, appDir);
    }
    if (UNSUPPORTED_TAGS[localTag]) diags.warn(htmlFile, el.line, el.col, `<${localTag}>: ${UNSUPPORTED_TAGS[localTag]}`);
    // An inline handler attribute is a listener on this element, with its code compiled into the
    // app: `this` is the element and `event` the event, as the HTML event handler processing has
    // it. A page built with ignoreScripts doesn't run its handlers, so none are compiled there.
    if (!options.ignoreScripts) {
      for (const [k, v] of el.attrs) {
        if (k.length > 2 && k.startsWith("on") && IN_HANDLER_NAME.test(k) && v.trim() !== "") {
          handlers.push({ node: idx, type: k.slice(2), code: v, line: el.line, col: el.col });
        }
      }
    }

    const kids = el.children.filter((c) => !(c.kind === "element" && SKIP_TAGS.has(c.tag)));
    // Generated content: a ::before or ::after rule that could apply here becomes a real child
    // node, so layout, paint and hit testing handle it like any other box. The cascade decides
    // whether it stays visible (a content of none hides it).
    const before = hasPseudoRule(el, P.PE_BEFORE);
    const after = hasPseudoRule(el, P.PE_AFTER);
    // Every list item has a marker box, whether a ::marker rule styles it or not; the UA sheet
    // makes <li> a list item.
    const marker = localTag === "li" || hasPseudoRule(el, P.PE_MARKER);
    if (marker) addPseudo(idx, P.PE_MARKER);
    if (before) addPseudo(idx, P.PE_BEFORE);
    // A text field's ::placeholder carries the style its placeholder text is drawn with. The box
    // itself never lays out or paints; the field reads the style when it draws the text.
    const placeholder = (localTag === "input" || localTag === "textarea") && hasPseudoRule(el, P.PE_PLACEHOLDER);
    if (placeholder) addPseudo(idx, P.PE_PLACEHOLDER);
    // A dialog's ::backdrop is painted by the top layer, never in the flow; the UA sheet gives it
    // display: none so that it takes no room here.
    const backdrop = localTag === "dialog" && hasPseudoRule(el, P.PE_BACKDROP);
    if (backdrop) addPseudo(idx, P.PE_BACKDROP);
    // ::first-line and ::first-letter are style carriers: their boxes never lay out.
    const firstLine = hasPseudoRule(el, P.PE_FIRST_LINE);
    if (firstLine) addPseudo(idx, P.PE_FIRST_LINE);
    const firstLetter = hasPseudoRule(el, P.PE_FIRST_LETTER);
    if (firstLetter) addPseudo(idx, P.PE_FIRST_LETTER);
    // ::target-text styles the stretch a text fragment names; its box never lays out.
    const targetText = hasPseudoRule(el, P.PE_TARGET_TEXT);
    if (targetText) addPseudo(idx, P.PE_TARGET_TEXT);

    // ::selection is a style carrier too: the text painter reads the colours selected text takes.
    const selection = hasPseudoRule(el, P.PE_SELECTION);
    if (selection) addPseudo(idx, P.PE_SELECTION);
    // Each ::highlight(name) that styles this element gets a carrier of its own, named, so the
    // painter can read the colours that highlight paints the element's text in.
    for (const nm of highlightNames) if (hasPseudoRule(el, P.PE_HIGHLIGHT, nm)) addPseudo(idx, P.PE_HIGHLIGHT, nm);
    const texts = kids.filter((c) => c.kind === "text" && collapse(c.text).trim() !== "");
    const elems = kids.filter((c) => c.kind === "element");
    // The ::first-line and ::first-letter carriers never lay out, so text can still stay the
    // element's own: the own-text painter is what applies their style.
    const onlyText = kids.every((k) => k.kind === "text");
    if (texts.length > 0 && elems.length === 0 && onlyText && !before && !after && !marker && !placeholder && !backdrop) {
      // Pure text content: store it on the element (the common case: <h1>Title</h1>). The text
      // is kept as written; the runtime collapses or preserves its whitespace according to
      // `white-space`.
      nodes[idx].text = kids.map((k) => (k.kind === "text" ? k.text : "")).join("");
      return idx;
    }
    // Whitespace between inline content is significant ("<b>a</b> <i>b</i>"); between
    // blocks it isn't. The runtime collapses spaces across runs and at line edges.
    for (const k of kids) {
      if (k.kind === "element") {
        if (LEAF_TAGS.has(k.tag)) addLeaf(k, idx);
        else addEl(k, idx, isSvg, el);
        continue;
      }
      if (k.kind === "pi") {
        // A processing instruction is a node of the DOM but no box: the runtime makes it from
        // the tag's target and the text, as parseFragment does for one a script inserts.
        nodes.push({ tag: "#pi:" + k.target, id: "", attrs: [], style: "", classes: [], parent: idx, text: k.data, rules: [], states: 0 });
        sourceEls.push(null);
        nodeImages.push(-1);
        hints.push([]);
        hintSlots.push(false);
        continue;
      }
      // Whitespace-only text is kept: with a preserving `white-space` it is content (and
      // collapses away harmlessly otherwise).
      if (k.text === "") continue;
      nodes.push({ tag: "#text", id: "", attrs: [], style: "", classes: [], parent: idx, text: k.text, rules: [], states: 0 });
      sourceEls.push(null);
      nodeImages.push(-1);
      hints.push([]);
      hintSlots.push(false);
    }
    if (after) addPseudo(idx, P.PE_AFTER);
    return idx;
  };

  // The index of the document element. The doctype is a node of the document too and stands
  // first, so the root isn't node 0: a :root selector has to find the <html> element itself.
  let rootIdx = -1;
  if (!htmlEl) {
    diags.error(htmlFile, 1, 1, "no <html> element found");
  } else {
    // The page's doctype is a node of the document too, ahead of the root element.
    const dt = doctypeOf(readFileSync(htmlPath, "utf8"));
    if (dt !== null) {
      nodes.push({ tag: "#doctype:" + dt.name, id: "", attrs: [], style: "", classes: [], parent: -1,
        text: dt.publicId + "\u0000" + dt.systemId, rules: [], states: 0 });
      sourceEls.push(null);
      nodeImages.push(-1);
      hints.push([]);
      hintSlots.push(false);
    }
    rootIdx = nodes.length;
    addEl(htmlEl, -1);
  }
  if (!nodes.some((n) => n.tag === "body")) diags.error(htmlFile, 1, 1, "no <body> element found");
  if (scripts.length === 0 && !options.ignoreScripts) diags.note(htmlFile, 1, 1, "no <script> found; the app will be static");

  // cellpadding applies to every cell the table owns (not those of a nested table).
  for (const [tableIdx, value] of tablePadding) {
    if (value === undefined) continue;
    const pad = dimensionAttr(value);
    if (pad === null || pad.u !== P.U_PX) continue;
    const decls = compileDeclarations(`padding: ${pad.v}px`, () => [1, 1], htmlFile, diags, pageContext);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].tag !== "td" && nodes[i].tag !== "th") continue;
      let p = nodes[i].parent;
      while (p >= 0 && nodes[p].tag !== "table") p = nodes[p].parent;
      if (p === tableIdx) hints[i].push(...decls);
    }
  }

  // --- Cascade --------------------------------------------------------------
  // Classes that can ever be present: static ones plus any string literal in the scripts
  // (a conservative stand-in for classList.add("x") analysis). Same for tags a script can make,
  // which decide whether runtime selector matching is needed at all and, when it is, which rules
  // it has to be able to match.
  const possibleClasses = new Set(staticClasses);
  const possibleTags = new Set<string>();
  /** A script makes elements the build never saw, so the runtime selector table is needed. */
  let runtimeElements = false;
  /** A script can make a tag the build cannot name (a variable tag, or markup it can't read),
   *  so any tag may turn up and every rule has to be able to match it. */
  let unknownTags = false;
  let cloned = false;
  for (const src of scriptText) {
    // Class-like tokens inside any string literal: "item", "check on", `label ${x}`. Markup in a
    // literal also names the tags it can make.
    for (const m of src.matchAll(/"([^"\n]*)"|'([^'\n]*)'|`([^`]*)`/g)) {
      const text = m[1] ?? m[2] ?? m[3];
      for (const tok of text.split(/[^\w-]+/)) if (tok) possibleClasses.add(tok);
      for (const t of text.matchAll(/<\s*([a-zA-Z][\w-]*)/g)) possibleTags.add(t[1].toLowerCase());
    }
    // createElement("div") names its tag; a call whose tag the build cannot read (a variable, or
    // createElement reached some other way) can make any tag.
    let literalCalls = 0;
    for (const m of src.matchAll(/createElement\s*\(\s*["'`]([\w-]+)["'`]/g)) {
      possibleTags.add(m[1].toLowerCase());
      literalCalls++;
    }
    if ((src.match(/createElement/g)?.length ?? 0) > literalCalls) unknownTags = true;
    // A clone copies the tags of the tree; a parsed markup string names its own tags when the
    // text is a literal, but a variable, a spliced template or a DOMParser can make any element.
    if (/\bcloneNode\b/.test(src)) cloned = true;
    if (/createElement|cloneNode|DOMParser|\.(?:innerHTML|outerHTML)\s*\+?=|insertAdjacentHTML\s*\(/.test(src)) {
      runtimeElements = true;
    }
    if (/\.(?:innerHTML|outerHTML)\s*\+?=\s*[^"'`\s]/.test(src)) unknownTags = true;
    if (/insertAdjacentHTML\s*\(\s*[^,]*,\s*[^"'`\s]/.test(src)) unknownTags = true;
    if (/\bDOMParser\b/.test(src)) unknownTags = true;
    if (/\b(?:innerHTML|outerHTML|insertAdjacentHTML)\b/.test(src) && /`[^`]*\$\{/.test(src)) unknownTags = true;
    // JSX renders elements the build never sees, and a component can render any tag.
    const jsx = jsxElements(src);
    for (const t of jsx.tags) possibleTags.add(t);
    if (jsx.any) runtimeElements = true;
    if (jsx.unknown) unknownTags = true;
  }
  // If no script restructures the tree, ancestor relationships are fixed at build time.
  const treeIsStatic = !scriptText.some((src) =>
    /\b(appendChild|append|prepend|insertBefore|removeChild|remove|replaceChildren|replaceWith|createElement)\s*\(/.test(src));
  // A script can give an element a class or an id the build never saw: a class built from a
  // variable or a hash (`"p-" + n`), `className = value`, `setAttribute("class", value)`. None of
  // those names are string literals the analysis above can see, so once a script may touch an
  // element's classes, attributes or id, no rule can be dropped for matching nothing statically
  // and every class or id condition is left to the runtime, which sees the real value.
  const markupMayChange = scriptText.some((src) =>
    /\b(classList|className|setAttribute|removeAttribute|toggleAttribute|dataset)\b|\.\s*(id|className)\s*=/.test(src));
  // A clone carries a tag from the tree, and once a script may change an element's classes or id
  // the runtime re-resolves that element's rules from the selector table, so every tag the tree
  // holds has to be matchable there too.
  if (cloned || markupMayChange) for (const n of nodes) if (!n.tag.startsWith("#")) possibleTags.add(n.tag);
  if (unknownTags) possibleTags.add("*");

  const compoundMatchesStatic = (c: ChainLink, n: OutNode, idx: number) =>
    (!c.tag || c.tag === n.tag) && (!c.id || c.id === n.id) && (!c.root || idx === rootIdx);
  /** Evaluates an ancestor chain against the static tree (only for tag/#id/:root compounds). */
  const chainMatchesStatic = (chain: ChainLink[], k: number, idx: number): boolean => {
    if (k === chain.length) return true;
    let a = nodes[idx].parent;
    while (a >= 0) {
      if (compoundMatchesStatic(chain[k], nodes[a], a) && chainMatchesStatic(chain, k + 1, a)) return true;
      if (chain[k].comb === COMB_CHILD) return false;
      a = nodes[a].parent;
    }
    return false;
  };
  const chainIsStatic = (chain: ChainLink[]) =>
    treeIsStatic && !markupMayChange && chain.every((c) => c.classes.length === 0 && c.states === 0 &&
      c.nthStart.length === 0 && c.nthEnd.length === 0 && c.attrs.length === 0 && c.nots.length === 0 &&
      (c.lang === undefined || c.lang.length === 0) && (c.notSels === undefined || c.notSels.length === 0) &&
      (c.dir ?? 0) === 0 && c.has.length === 0 && c.comb <= COMB_CHILD);
  const plausible = (sel: Selector) => markupMayChange ||
    (sel.classes.every((c) => possibleClasses.has(c)) && sel.chain.every((l) => l.classes.every((c) => possibleClasses.has(c))));
  let staticChains = 0;
  let chainStates = 0;

  interface Candidate { sel: Selector; rule: CssRule; decls: Decl[]; important: boolean; rank: number; hint?: boolean }
  const used = new Set<CssRule>();
  const outRules: OutRule[] = [];
  /** Elements that a @starting-style rule styles: only they have a first-state pass. */
  const startingNodes: boolean[] = [];
  const ruleKey = new Map<string, number>();
  /** Rule ids of the presentation-attribute slots the runtime fills from the element (hints.ts). */
  const hintRuleIds = new Set<number>();
  let conditionalRules = 0;

  /** The sheet each compiled rule came from (-1 for the UA sheet or a hint slot). */
  const ruleSheetOf: number[] = [];
  const intern = (r: OutRule, sheet: number = -1): number => {
    // The sheet is part of a rule's identity: the same declarations from two sheets are two
    // rules, since a script can disable one sheet and leave the other in force.
    const body = JSON.stringify(r);
    const key = sheet < 0 ? body : "s" + sheet + "|" + body;
    let id = ruleKey.get(key);
    if (id === undefined) {
      id = outRules.length;
      outRules.push(r);
      ruleKey.set(key, id);
      ruleSheetOf.push(sheet);
      if (r.classes.length > 0 || r.states !== 0 || r.chain.length > 0 || r.attrs.length > 0 ||
        r.nots.length > 0 || r.has.length > 0 || r.empty || r.chainEmpty.some((e) => e) ||
        r.chainHas.some((h) => h.length > 0) ||
        r.nthStart.length > 0 || r.nthEnd.length > 0 || r.media !== "" || r.container !== "") conditionalRules++;
      chainStates |= r.stateMask;
      for (const l of r.chain) chainStates |= compoundStates(l);
    }
    return id;
  };

  // A custom property or a var() value has no numeric form until style time, when the element's
  // custom properties are known; it is stored as text instead, behind a negative declaration id:
  // [-1 - id, 0, 0] where id indexes TEXT_DECL_PROPS / TEXT_DECL_VALUES.
  const textDeclProps: string[] = [];
  const textDeclValues: string[] = [];
  const textDeclIds = new Map<string, number>();
  const textDecl = (prop: string, value: string): number => {
    const key = prop + "\u0000" + value;
    let id = textDeclIds.get(key);
    if (id === undefined) {
      // A value held as text may still name an image. The runtime resolves those by URL, so a data:
      // image among them is registered here, where its bytes can be written out.
      for (const url of urlsInText(value)) if (/^data:/i.test(url)) styleContext.image(url, 1, 1);
      id = textDeclProps.length;
      textDeclProps.push(prop);
      textDeclValues.push(value);
      textDeclIds.set(key, id);
    }
    return -1 - id;
  };

  const flatten = (decls: Decl[]): number[] =>
    decls.flatMap((d) => d.prop === undefined ? [d.p, d.v, d.u] : [textDecl(d.prop, d.value!), 0, 0]);

  const outRule = (sel: Selector, decls: Decl[], important: boolean, media: string, container: string,
    scope: string, starting: boolean, origin: string): OutRule => ({
    important, origin, classes: sel.classes, states: sel.states, stateMask: compoundStates(sel), root: sel.root, dir: sel.dir ?? 0,
    nthStart: sel.nthStart, nthEnd: sel.nthEnd,
    nthStartOf: sel.nthStartOf ?? [], nthEndOf: sel.nthEndOf ?? [],
    attrs: sel.attrs, lang: sel.lang ?? [], nots: sel.nots, notSels: sel.notSels ?? [],
    empty: sel.empty === true, chainEmpty: sel.chain.map((l) => l.empty === true),
    has: sel.has, chainHas: sel.chain.map((l) => l.has),
    chain: sel.chain, decls: flatten(decls), pseudo: sel.pseudo, media, container, scope, starting,
    customs: decls.some((d) => d.prop !== undefined && d.prop.startsWith("--")),
  });

  // Cascade order is importance first, then origin (reversed for important declarations),
  // then cascade layer, then specificity, then source order. A rule's declarations are split by
  // importance, since a single rule can mix both and important notes sort after all normal ones.
  const band = (origin: string, important: boolean): number =>
    important ? (origin === "ua" ? 5 : origin === "inline" ? 4 : 3)
      : (origin === "ua" ? 0 : origin === "inline" ? 2 : 1);
  // Within the author origin, a later layer outranks an earlier one for normal declarations, and
  // the rule is reversed for important ones; unlayered rules sit in an implicit final layer, so
  // they beat every layer normally and lose to every layer when important.
  const layerRank = (l: number, important: boolean): number =>
    l < 0 ? (important ? 0 : layerOrder.count)
      : important ? layerOrder.count - layerOrder.key[l] : layerOrder.key[l];
  // The bands are wide enough that a layer position never reaches the next importance band, and
  // specificity (ids*10000 + classes*100 + types) never reaches the next layer.
  const rankOf = (rule: CssRule, important: boolean, spec: number): number =>
    band(rule.origin, important) * 1e13 + layerRank(rule.layer, important) * 1e8 + spec;
  const partsOf = (decls: Decl[]): { decls: Decl[]; important: boolean }[] => {
    const normal: Decl[] = [];
    const important: Decl[] = [];
    for (const d of decls) (d.important === true ? important : normal).push(d);
    const out: { decls: Decl[]; important: boolean }[] = [];
    if (normal.length > 0) out.push({ decls: normal, important: false });
    if (important.length > 0) out.push({ decls: important, important: true });
    // A rule whose declarations all failed to compile still counts as matched, so that the
    // dead-rule note stays quiet; the empty part emits nothing.
    if (out.length === 0) out.push({ decls: [], important: false });
    return out;
  };

  // A node's unconditional declarations merge into as few baked rules as the cascade allows, but
  // a merged run belongs to one sheet (see below), which costs a rule per sheet per node. Only a
  // page with a script can reach a sheet through the CSSOM at all, so a build that compiles no
  // script keeps the compact one-rule-per-node form.
  const sheetRuns = !options.ignoreScripts && sheets.length > 1 &&
    (scripts.length > 0 || handlers.length > 0 || scriptText.length > 0);
  nodes.forEach((node, i) => {
    if (node.tag === "#text") return;
    // A pseudo-element's rules match the element that generates it: its tag, id and chain
    // conditions all describe that element, never the generated box.
    const pseudo = nodePseudo(node.tag);
    const at = pseudo === P.PE_NONE ? i : node.parent;
    if (at < 0) return;
    const origin = nodes[at];
    const src = sourceEls[at]!;
    const cands: Candidate[] = [];
    for (const rule of rules) {
      const parts = partsOf(rule.decls);
      for (const sel of rule.selectors) {
        if (sel.pseudo !== pseudo) continue;
        // :host and ::slotted name a shadow tree's own sheet; a document's sheet has no host to
        // style, so its rules match nothing there.
        if (sel.host === true || sel.slotted === true) continue;
        // A ::highlight() carrier takes the rules of its own name only.
        if (pseudo === P.PE_HIGHLIGHT && sel.pseudoName !== node.pseudoName) continue;
        if (sel.tag && sel.tagNs === undefined && sel.tag !== origin.tag) continue;
        if (sel.root && at !== rootIdx) continue;
        if (!markupMayChange && sel.id !== null && sel.id !== origin.id) continue;
        if (!plausible(sel)) continue;
        let s = sel;
        // The element's id is fixed statically, but a script may change it (or give one to an
        // element that had none), so an id condition becomes a runtime [id] test instead of a
        // build-time decision, and an element whose id doesn't match yet still gets the rule.
        if (markupMayChange && sel.id !== null) {
          s = { ...sel, id: null, attrs: [...sel.attrs, "id" + ATTR_SEP + "=" + ATTR_SEP + sel.id] };
        }
        if (sel.chain.length > 0 && chainIsStatic(sel.chain)) {
          // Resolved now: the rule either applies to this element unconditionally or not at all.
          if (!chainMatchesStatic(sel.chain, 0, at)) continue;
          s = { ...sel, chain: [] };
          staticChains++;
        }
        // This element is the document element — the guard above asked — so its :root condition
        // is decided here too.
        if (s.root) s = { ...s, root: false };
        for (const part of parts) {
          cands.push({
            sel: s, rule, decls: part.decls, important: part.important,
            rank: rankOf(rule, part.important, sel.specificity),
          });
        }
      }
    }
    // Presentational hints (an <img>'s width/height attributes): author origin with zero
    // specificity, before every author rule, as the HTML rendering section defines them.
    const hintDecls = hints[at];
    if (pseudo === P.PE_NONE && hintDecls.length > 0) {
      const sel: Selector = { tag: null, id: null, root: false, classes: [], states: 0, nthStart: [], nthEnd: [], attrs: [], nots: [], has: [], chain: [], specificity: 0, pseudo: P.PE_NONE, pseudoName: "", text: "[attrs]" };
      const hintRule: CssRule = { selectors: [], decls: hintDecls, order: -1, origin: "author", file: htmlFile, line: src.line, col: src.col, media: "", layer: -1, container: "", scope: "", starting: false };
      cands.push({ sel, rule: hintRule, decls: hintDecls, important: false, rank: rankOf(hintRule, false, 0) });
    }
    // The slot an SVG element keeps for its presentation attributes: it sits where a hint does
    // in the cascade, zero specificity below the author rules, and holds no declarations of its
    // own (the runtime fills them from the attributes the element carries at the time).
    if (pseudo === P.PE_NONE && hintSlots[at]) {
      const sel: Selector = { tag: null, id: null, root: false, classes: [], states: 0, nthStart: [], nthEnd: [], attrs: [], nots: [], has: [], chain: [], specificity: 0, pseudo: P.PE_NONE, pseudoName: "", text: "[attrs]" };
      const slotRule: CssRule = { selectors: [], decls: [], order: -1, origin: "author", file: htmlFile, line: src.line, col: src.col, media: "", layer: -1, container: "", scope: "", starting: false };
      cands.push({ sel, rule: slotRule, decls: [], important: false, rank: rankOf(slotRule, false, 0), hint: true });
    }

    // The style="" attribute is reported on here, then parsed again by the runtime, which owns
    // the inline declarations so that scripts can change them (see runtime/cssom.ts).
    if (pseudo === P.PE_NONE && node.style !== "") {
      compileDeclarations(node.style, () => [src.line, src.col], htmlFile, diags, styleContext, contentContext);
    }
    cands.sort((a, b) => a.rank - b.rank || a.rule.order - b.rule.order);
    if (cands.some((c) => c.rule.starting)) startingNodes[at] = true;

    // Merge runs of unconditional rules into one baked rule; keep conditional ones separate.
    // Each emitted rule holds only normal or only important declarations, so the runtime can
    // apply the important ones after the inline style, as the cascade requires.
    let pending: Decl[] = [];
    let pendingImportant = false;
    // The origin the pending declarations came from: a merged rule belongs to one origin only,
    // so a revert inside it rolls back to the UA sheet rather than to itself.
    let pendingOrigin = "author";
    // The sheet the pending declarations came from: a merged rule belongs to one sheet only, so
    // a script that disables a sheet through the CSSOM can take every rule it carried out of the
    // cascade (style.ts) without touching another sheet's declarations in the same node.
    let pendingSheet = -1;
    const flush = () => {
      if (pending.length === 0) return;
      // Keyed by property id; a text declaration (a custom property, or a var() value) is keyed
      // by the property name it was written for.
      // A property declared twice keeps its last value, and the merged run keeps the place that
      // last declaration had: a keyword held as text and a later value of the same property can
      // otherwise swap order (`all: initial` and a following `color`).
      const merged = new Map<number | string, Decl>();
      const lastAt = new Map<number | string, number>();
      for (let i = 0; i < pending.length; i++) {
        const d = pending[i];
        const key = d.prop === undefined ? d.p : "t:" + d.prop;
        merged.set(key, d);
        lastAt.set(key, i);
      }
      const mergedDecls = [...merged.keys()]
        .sort((a, b) => (lastAt.get(a) as number) - (lastAt.get(b) as number))
        .map((k) => merged.get(k) as Decl);
      node.rules.push(intern({
        important: pendingImportant, origin: pendingOrigin, classes: [], states: 0, stateMask: 0, root: false, dir: 0, empty: false, chainEmpty: [], nthStart: [], nthEnd: [],
        nthStartOf: [], nthEndOf: [], attrs: [], lang: [], nots: [], notSels: [], has: [], chainHas: [], chain: [], decls: flatten(mergedDecls),
        customs: mergedDecls.some((d) => d.prop !== undefined && d.prop.startsWith("--")),
        pseudo, media: "", container: "", scope: "", starting: false,
      }, pendingSheet));
      pending = [];
    };
    for (const c of cands) {
      used.add(c.rule);
      if (c.hint === true) {
        flush();
        const slot = intern(outRule(c.sel, [], false, "", "", "", false, "author"));
        hintRuleIds.add(slot);
        node.rules.push(slot);
        continue;
      }
      if (c.decls.length === 0) continue;
      const sheet = sheetRuns ? ruleSheet.get(c.rule) ?? -1 : -1;
      if (c.rule.media === "" && c.rule.container === "" && c.rule.scope === "" && !c.rule.starting && c.sel.classes.length === 0 && c.sel.states === 0 && c.sel.chain.length === 0 &&
        c.sel.attrs.length === 0 && c.sel.nots.length === 0 && c.sel.has.length === 0 &&
        (c.sel.lang === undefined || c.sel.lang.length === 0) &&
        (c.sel.notSels === undefined || c.sel.notSels.length === 0) && (c.sel.dir ?? 0) === 0 &&
        c.sel.nthStart.length === 0 && c.sel.nthEnd.length === 0 && c.sel.empty !== true) {
        if (pending.length > 0 && (c.important !== pendingImportant || c.rule.origin !== pendingOrigin || sheet !== pendingSheet)) flush();
        pendingImportant = c.important;
        pendingOrigin = c.rule.origin;
        pendingSheet = sheet;
        pending.push(...c.decls);
      } else {
        flush();
        // Pseudo rules are tested at runtime against the element they belong to, so that is
        // where the state bits have to be tracked.
        origin.states |= compoundStates(c.sel);
        node.rules.push(intern(outRule(c.sel, c.decls, c.important, c.rule.media, c.rule.container, c.rule.scope, c.rule.starting, c.rule.origin), sheet));
      }
    }
    flush();
  });

  // Selector table for elements created at runtime: every rule that a tag a script can make may
  // match, in cascade order. Emitted when the scripts can create elements, and whenever a script
  // may change an existing element's classes or id (markupMayChange), because then a selector the
  // build could not match statically may still start matching at runtime.
  const dynTags: string[] = [];
  const dynIds: string[] = [];
  const dynRules: number[] = [];
  const dynPseudo: number[] = [];
  // A scroll container's marker boxes are made at style time, not by the build, so the rules that
  // style them have to be in the dynamic table even on a page with no scripts.
  const scrollMarkerRules = rules.some((r) => r.selectors.some((s) =>
    s.pseudo === P.PE_SCROLL_MARKER || s.pseudo === P.PE_SCROLL_MARKER_GROUP));
  if (runtimeElements || markupMayChange || scrollMarkerRules) {
    const dyn: Candidate[] = [];
    for (const rule of rules) {
      const parts = partsOf(rule.decls);
      for (const sel of rule.selectors) {
        if (sel.host === true || sel.slotted === true) continue;
        // A marker box is made by the style pass, not by the build or a script, so its rules stay
        // even when no element in the tree could carry them yet.
        const generated = sel.pseudo === P.PE_SCROLL_MARKER || sel.pseudo === P.PE_SCROLL_MARKER_GROUP;
        // A tag neither the tree nor a script can make can never match anything.
        if (!generated && sel.tag && sel.tagNs === undefined && !possibleTags.has(sel.tag) && !possibleTags.has("*")) continue;
        if (!generated && sel.id && !possibleClasses.has(sel.id) && !markupMayChange) continue;
        if (!plausible(sel)) continue;
        for (const part of parts) {
          dyn.push({
            sel, rule, decls: part.decls, important: part.important,
            rank: rankOf(rule, part.important, sel.specificity),
          });
        }
      }
    }
    dyn.sort((a, b) => a.rank - b.rank || a.rule.order - b.rule.order);
    for (const c of dyn) {
      used.add(c.rule);
      if (c.decls.length === 0) continue;
      dynTags.push(c.sel.tag ?? "");
      dynIds.push(c.sel.id ?? "");
      dynRules.push(intern(outRule(c.sel, c.decls, c.important, c.rule.media, c.rule.container, c.rule.scope, c.rule.starting, c.rule.origin), ruleSheet.get(c.rule) ?? -1));
      dynPseudo.push(c.sel.pseudo);
    }
  }

  let rulesDropped = 0;
  for (const rule of rules) {
    if (rule.origin !== "author" || used.has(rule)) continue;
    rulesDropped++;
    diags.note(rule.file, rule.line, rule.col,
      `rule '${rule.selectors.map((s) => s.text).join(", ")}' matches no element and was removed`);
  }

  // --- Emit -------------------------------------------------------------------
  // While the gen.ts lines are built, table() records each value so the same data can be written
  // for a dev build, where the runtime reloads it without compiling.
  emittedTables = new Map();
  // A name registered twice keeps its place in the order and the last rule's descriptors.
  const byName = new Map<string, PropertyRule>();
  for (const r of props) byName.set(r.name, r);
  const propRegs = [...byName.values()];
  // The palettes each @font-face file declares, and the rules that name author palettes. A rule's
  // families resolve to the same family values the declarations use, so the runtime can compare
  // them with an element's font-family directly.
  const facePalettes: number[] = [];
  for (const f of fonts) {
    const p = f.source === "" ? [0, -1, -1] : fontPalettes(f.source);
    facePalettes.push(p[0], p[1], p[2]);
  }
  const paletteRows = palettes.map((p) => {
    const families = p.families.map((name) => pageContext.family(name)).join(",");
    const colors = p.colors.map((c) => `${c.index}=${c.color.toString(16).padStart(8, "0")}`).join(",");
    return `${paletteIds.get(p.name) ?? 0}\u0000${families}\u0000${p.baseKind}\u0000${p.base}\u0000${colors}`;
  });
  // Which sheet each <style> node hosts, so a script that edits that sheet's rules can have the
  // rules the build compiled from it stand down (see sheets.ts and style.ts).
  const nodeSheet: number[] = [];
  for (let i = 0; i < nodes.length; i++) nodeSheet.push(-1);
  for (let si = 0; si < sheets.length; si++) {
    const el = sheets[si].node;
    const n = el === null ? -1 : sheetNodeIndex.get(el) ?? -1;
    if (n >= 0 && n < nodeSheet.length) nodeSheet[n] = si;
  }
  // A build copies the public directory into the bundle's root, so a bundled app's root URLs
  // resolve against the bundle; a dev build has no bundle, and its root URLs resolve here.
  const siteBase = options.bundle !== undefined ? "" : options.publicDir ?? "";
  const genSource = [
    "// Generated by native. Do not edit.",
    `export const TITLE: string = ${JSON.stringify(title)};`,
    `export const WIDTH: number = ${width};`,
    `export const HEIGHT: number = ${height};`,
    `export const WINDOW_OPTIONS: string = ${JSON.stringify(windowOptions)};`,
    `export const XML_DOCUMENT: boolean = ${/\.xht(ml)?$/i.test(htmlPath) ? "true" : "false"};`,
    `export const QUIRKS: number = ${documentMode(readFileSync(htmlPath, "utf8"))};`,
    `export const CHARSET: string = ${JSON.stringify(pageCharset(readFileSync(htmlPath, "utf8")))};`,
    "// The page's directory: a URL a script sets at runtime (an Image's src) resolves against it,",
    "// as a markup <img src> did at build time. A bundled app leaves it empty: its URLs resolve",
    "// against the bundle, which keeps the app's own layout.",
    `export const IMAGE_BASE: string = ${JSON.stringify(options.bundle !== undefined ? "" : appDir)};`,
    "// The public directory a dev build's root URLs (\"/cover.png\") resolve against; empty in a",
    "// bundled app, whose root is the bundle itself.",
    `export const SITE_BASE: string = ${JSON.stringify(siteBase)};`,
    "// True when the build copied the app's files beside the executable, so the paths in the",
    "// tables and a script's own URLs are relative to the bundle the host locates at startup.",
    `export const BUNDLED: boolean = ${options.bundle !== undefined ? "true" : "false"};`,
    table("RULE_CLASSES", "string[][]", outRules.map((r) => r.classes), true),
    table("RULE_STATES", "number[]", outRules.map((r) => r.states)),
    "// True for a rule whose declarations set a custom property (or hold a var()).",
    table("RULE_CUSTOMS", "boolean[]", outRules.map((r) => r.customs)),
    "// :root conditions, tested against the document's root element.",
    table("RULE_ROOT", "boolean[]", outRules.map((r) => r.root)),
    "// :dir(ltr|rtl) conditions: 1 for ltr, 2 for rtl, 0 for none.",
    table("RULE_DIR", "number[]", outRules.map((r) => r.dir ?? 0)),
    "// :nth-child() conditions: [A, B, ofType] counted from the start or from the end.",
    table("RULE_NTH_START", "number[][]", outRules.map((r) => r.nthStart)),
    table("RULE_NTH_END", "number[][]", outRules.map((r) => r.nthEnd)),
    "// The \"of S\" filter of each :nth-child() condition, aligned with the triplets (\"\" for none).",
    table("RULE_NTH_START_OF", "string[][]", outRules.map((r) => r.nthStartOf)),
    table("RULE_NTH_END_OF", "string[][]", outRules.map((r) => r.nthEndOf)),
    "// Attribute conditions: \"name\\u0002op[flag]\\u0002value\" (an empty op = present).",
    table("RULE_ATTRS", "string[][]", outRules.map((r) => r.attrs)),
    "// :lang() ranges on the subject compound.",
    table("RULE_LANG", "string[][]", outRules.map((r) => r.lang)),
    "// :not() conditions, each an encoded compound the element must not match.",
    table("RULE_NOTS", "string[][]", outRules.map((r) => r.nots.map(encodeCompound))),
    "// :not() arguments that are complex selectors, each matched as a selector of its own.",
    table("RULE_NOT_SELS", "string[][]", outRules.map((r) => r.notSels)),
    "// :has() conditions, each a relative selector: combinator, \\u0003, then the selector's text.",
    table("RULE_HAS", "string[][]", outRules.map((r) => r.has)),
    "// :empty conditions on the subject compound.",
    table("RULE_EMPTY", "boolean[]", outRules.map((r) => r.empty)),
    "// Ancestor/sibling chains (nearest first) for rules with combinators.",
    table("RULE_CHAIN_COMB", "number[][]", outRules.map((r) => r.chain.map((l) => l.comb))),
    table("RULE_CHAIN_TAG", "string[][]", outRules.map((r) => r.chain.map((l) => l.tag ?? ""))),
    table("RULE_CHAIN_ID", "string[][]", outRules.map((r) => r.chain.map((l) => l.id ?? ""))),
    table("RULE_CHAIN_CLASSES", "string[][][]", outRules.map((r) => r.chain.map((l) => l.classes))),
    table("RULE_CHAIN_STATES", "number[][]", outRules.map((r) => r.chain.map((l) => l.states))),
    table("RULE_CHAIN_NTH_START", "number[][][]", outRules.map((r) => r.chain.map((l) => l.nthStart))),
    table("RULE_CHAIN_NTH_END", "number[][][]", outRules.map((r) => r.chain.map((l) => l.nthEnd))),
    table("RULE_CHAIN_NTH_START_OF", "string[][][]", outRules.map((r) => r.chain.map((l) => l.nthStartOf ?? []))),
    table("RULE_CHAIN_NTH_END_OF", "string[][][]", outRules.map((r) => r.chain.map((l) => l.nthEndOf ?? []))),
    table("RULE_CHAIN_ATTRS", "string[][][]", outRules.map((r) => r.chain.map((l) => l.attrs))),
    table("RULE_CHAIN_LANG", "string[][][]", outRules.map((r) => r.chain.map((l) => l.lang ?? []))),
    "// :dir(ltr|rtl) conditions on ancestor compounds: 1 for ltr, 2 for rtl, 0 for none.",
    table("RULE_CHAIN_DIR", "number[][]", outRules.map((r) => r.chain.map((l) => l.dir ?? 0))),
    table("RULE_CHAIN_NOTS", "string[][][]", outRules.map((r) => r.chain.map((l) => l.nots.map(encodeCompound)))),
    table("RULE_CHAIN_NOT_SELS", "string[][][]", outRules.map((r) => r.chain.map((l) => l.notSels ?? []))),
    table("RULE_CHAIN_HAS", "string[][][]", outRules.map((r) => r.chainHas)),
    "// :empty conditions on each ancestor compound.",
    table("CHAIN_EMPTY", "boolean[][]", outRules.map((r) => r.chainEmpty)),
    "// :root conditions on ancestor compounds.",
    table("RULE_CHAIN_ROOT", "boolean[][]", outRules.map((r) => r.chain.map((l) => l.root))),
    `export const CHAIN_STATES: number = ${chainStates};`,
    "// Rules holding !important declarations, which the runtime applies after inline styles.",
    table("RULE_IMPORTANT", "boolean[]", outRules.map((r) => r.important)),
    table("RULE_UA", "boolean[]", outRules.map((r) => r.origin === "ua")),
    "// PE_BEFORE/PE_AFTER for rules that style generated content; their conditions test the parent.",
    table("RULE_PSEUDO", "number[]", outRules.map((r) => r.pseudo)),
    "// The author sheet each rule came from (-1 for the UA sheet), and each <style> or",
    "// stylesheet <link> node's sheet, so a script can disable, re-media-query or edit a sheet",
    "// and have the rules the build compiled from it follow.",
    table("RULE_SHEET", "number[]", ruleSheetOf),
    table("NODE_SHEET", "number[]", nodeSheet),
    "// Each sheet's media condition (empty for none) and whether it starts disabled: the",
    "// media and disabled attributes of a <style> or a stylesheet <link> gate its rules.",
    table("SHEET_MEDIA", "string[]", sheets.map((s) => s.media)),
    table("SHEET_DISABLED", "boolean[]", sheets.map((s) => s.disabled)),
    "// The @media condition each rule is inside, or \"\"; the runtime re-tests it on every resize.",
    table("RULE_MEDIA", "string[]", outRules.map((r) => r.media)),
    "// The @container condition each rule is inside, or \"\"; tested against ancestor containers.",
    table("RULE_CONTAINER", "string[]", outRules.map((r) => r.container)),
    table("RULE_SCOPE", "string[]", outRules.map((r) => r.scope)),
    table("RULE_STARTING", "boolean[]", outRules.map((r) => r.starting)),
    table("STARTING_NODES", "boolean[]", nodes.map((_, i) => startingNodes[i] === true)),
    "// Presentation-attribute slots: the runtime fills a slot's declarations from the attributes",
    "// the element carries, so a script's setAttribute() restyles it (see runtime/hints.ts).",
    table("RULE_HINTS", "boolean[]", outRules.map((_, i) => hintRuleIds.has(i))),
    "// Container name lists, space-separated in written order; container-name holds a row id.",
    table("CONTAINER_NAMES", "string[]", containerNameRows),
    "// Rows behind max()/min()/clamp() lengths and clip: rect() rectangles (see shared/css/).",
    table("LENGTH_EXPRS", "number[][]", exprRows.all()),
    table("CLIP_RECTS", "number[][]", clipRows.all()),
    table("WILL_CHANGE_LISTS", "number[][]", willChangeRows.all()),
    "// The shapes clip-path takes (see shared/css/clip-path.ts).",
    table("CLIP_SHAPES", "number[][]", clipPathRows.all()),
    "// Transform lists and transform-origin rows (see shared/css/transforms.ts).",
    table("TRANSFORM_LISTS", "number[][]", transformRows.all()),
    table("TRANSFORM_ORIGINS", "number[][]", originRows.all()),
    "// overflow-clip-margin rows: a visual box, a length and its unit (see shared/css/properties/box.ts).",
    table("OVERFLOW_CLIP_MARGINS", "number[][]", clipMarginRows.all()),
    "// Rows behind object-position (see shared/css/position.ts).",
    table("OBJECT_POSITIONS", "number[][]", positionRows.all()),
    "// stroke-dasharray patterns (see shared/css/dasharray.ts).",
    table("DASH_ARRAYS", "number[][]", dashRows.all()),
    table("RULE_DECLS", "number[][]", outRules.map((r) => r.decls), true),
    "// Declarations kept as text (a custom property, or a var() value); RULE_DECLS names them",
    "// with a negative property id, -1 - index (see shared/css/vars.ts).",
    table("TEXT_DECL_PROPS", "string[]", textDeclProps),
    table("TEXT_DECL_VALUES", "string[]", textDeclValues),
    "// Custom properties registered with @property: the name, its syntax, whether it inherits,",
    "// and the initial value it takes where nothing sets it (\"\" for the guaranteed-invalid one).",
    table("PROPERTY_NAMES", "string[]", propRegs.map((p) => p.name)),
    table("PROPERTY_SYNTAXES", "string[]", propRegs.map((p) => p.syntax)),
    table("PROPERTY_INHERITS", "boolean[]", propRegs.map((p) => p.inherits)),
    table("PROPERTY_INITIALS", "string[]", propRegs.map((p) => p.initialValue ?? "")),
    table("NODE_TAGS", "string[]", nodes.map((n) => n.tag)),
    table("NODE_IDS", "string[]", nodes.map((n) => n.id)),
    table("NODE_ATTRS", "string[][]", nodes.map((n) => n.attrs)),
    table("NODE_CLASSES", "string[][]", nodes.map((n) => n.classes)),
    "// style=\"\" attributes as written, parsed into el.style when the page mounts.",
    table("NODE_STYLE", "string[]", nodes.map((n) => n.style)),
    table("NODE_PARENTS", "number[]", nodes.map((n) => n.parent)),
    table("NODE_TEXT", "string[]", nodes.map((n) => n.text)),
    table("NODE_RULES", "number[][]", nodes.map((n) => n.rules)),
    table("NODE_STATES", "number[]", nodes.map((n) => n.states)),
    "// The highlight a ::highlight() carrier stands for, or \"\" for every other pseudo box.",
    table("NODE_PSEUDO_NAMES", "string[]", nodes.map((n) => n.pseudoName ?? "")),
    table("NODE_INLINE", "boolean[]", nodes.map((n) => INLINE_TAGS.has(n.tag))),
    "// An <img>'s entry in IMAGE_FILES, or -1 for no image or one that couldn't be loaded.",
    table("NODE_IMAGES", "number[]", nodeImages),
    table("IMAGE_FILES", "string[]", images),
    "// The SVG files among IMAGE_FILES (as indices) and the draw programs compiled from them.",
    table("SVG_IMAGE_FILES", "number[]", svgImageFiles),
    table("SVG_IMAGE_PROGRAMS", "string[]", svgImagePrograms),
    "// The image URLs a style=\"\" attribute names, and their IMAGE_FILES entries: the runtime",
    "// looks a URL up here when it parses the attribute (see runtime/cssom.ts).",
    table("IMAGE_URLS", "string[]", inlineUrls),
    table("IMAGE_URL_FILES", "number[]", inlineUrls.map((u) => inlineUrlFiles.get(u) ?? -1)),
    "// The paint servers fill/stroke name with url(#id); a paint value indexes this table.",
    table("SVG_PAINT_URLS", "string[]", svgPaintUrls),
    table("DYN_TAGS", "string[]", dynTags),
    table("DYN_IDS", "string[]", dynIds),
    table("DYN_RULES", "number[]", dynRules),
    table("DYN_PSEUDO", "number[]", dynPseudo),
    "// Generated content item lists, decoded by the runtime (see shared/css/content.ts).",
    table("CONTENT_ITEMS", "string[]", contentItems),
    "// Counter lists behind counter-reset/-increment/-set, decoded by the runtime.",
    table("COUNTER_ITEMS", "string[]", counterItems),
    table("FONT_FAMILIES", "string[]", familyNames),
    "// Families named by font-family that the build has no @font-face for, in id order after the",
    "// families above: the runtime asks the host for each by name.",
    table("FONT_INSTALLED_FAMILIES", "string[]", installedFamilies),
    "// The ordered family ids of each font-family list, joined by commas.",
    table("FONT_FAMILY_LISTS", "string[]", familyLists),
    table("FONT_FILES", "string[]", fonts.map((f) => f.path)),
    "// The local() names each face's src gives before its file, joined by NUL: the host takes the",
    "// first the system has, and the file when it has none.",
    table("FONT_FACE_LOCALS", "string[]", fonts.map((f) => f.locals.join("\u0000"))),
    "// The face each FONT_FILES entry belongs to, its weight range packed as low * 1024 + high, and",
    "// 1 when it is italic: a family can have one face per weight range and style.",
    table("FONT_FACE_FAMILIES", "number[]", fonts.map((f) => familyIds.get(f.family) ?? 0)),
    table("FONT_FACE_WEIGHTS", "number[]", fonts.map((f) => f.weightLo * 1024 + f.weightHi)),
    table("FONT_FACE_STYLES", "number[]", fonts.map((f) => (f.italic ? 1 : 0))),
    "// Each face's unicode-range as `lo-hi` pairs joined by commas; \"\" covers everything.",
    table("FONT_FACE_RANGES", "string[]", fonts.map((f) => f.ranges)),
    "// Each face's own OpenType feature settings and font-stretch percentage.",
    table("FONT_FACE_FEATURES", "string[]", fonts.map((f) => f.features)),
    table("FONT_FACE_STRETCHES", "number[]", fonts.map((f) => f.stretch)),
    "// Each face's ascent, descent and line-gap overrides as fractions of the font size, or -1.",
    table("FONT_FACE_ASCENTS", "number[]", fonts.map((f) => f.ascent)),
    table("FONT_FACE_DESCENTS", "number[]", fonts.map((f) => f.descent)),
    table("FONT_FACE_LINE_GAPS", "number[]", fonts.map((f) => f.lineGap)),
    "// Per FONT_FILES face: the CPAL palette count and the first light and dark palette indices,",
    "// or 0 and -1 for a file with no CPAL table (a bitmap emoji font).",
    table("FONT_FACE_PALETTES", "number[]", facePalettes),
    "// The names the page's @font-palette-values rules give palettes, in id order.",
    table("FONT_PALETTE_NAMES", "string[]", paletteNames),
    "// Each @font-palette-values rule: name id, family ids, base kind, base index, overrides.",
    table("FONT_PALETTES", "string[]", paletteRows),
    "// Background layer lists, one table per longhand; a value indexes a row of layers.",
    table("BG_IMAGES", "number[][]", bgRows[P.BG_IMAGE]),
    table("BG_REPEATS", "number[][]", bgRows[P.BG_REPEAT]),
    table("BG_POSITIONS", "number[][]", bgRows[P.BG_POSITION]),
    table("BG_SIZES", "number[][]", bgRows[P.BG_SIZE]),
    table("BG_ORIGINS", "number[][]", bgRows[P.BG_ORIGIN]),
    table("BG_CLIPS", "number[][]", bgRows[P.BG_CLIP]),
    table("BG_ATTACHMENTS", "number[][]", bgRows[P.BG_ATTACHMENT]),
    "// border-image longhand rows: the slice, width, outset and repeat a declaration gave.",
    table("BORDER_IMAGE_ROWS", "number[][]", borderImageRows),
    "// Gradient images the background layers name, decoded by the runtime (shared/css/gradients.ts).",
    table("GRADIENTS", "string[]", gradients),
    table("GRADIENT_TEXTS", "string[]", gradientTexts),
    "// The font-feature-settings lists: `tag=value` pairs joined by semicolons.",
    table("FONT_FEATURES", "string[]", features),
    "// The font-variation-settings lists: `tag=value` pairs joined by semicolons.",
    table("FONT_VARIATIONS", "string[]", variations),
    "// box-shadow and text-shadow lists: ten numbers per shadow in each row.",
    table("SHADOWS", "number[][]", shadowRows.all()),
    "// Grid track lists: fourteen numbers per track, a minmax()'s min and max slots.",
    table("GRID_TRACKS", "number[][]", gridTrackRows),
    "// The names a grid line, placement or area writes, and the rows that point into them.",
    table("GRID_NAMES", "string[]", gridNames),
    table("GRID_PLACEMENTS", "number[][]", placementRows),
    table("GRID_AREA_LISTS", "number[][]", areaListRows),
    table("FILTERS", "number[][]", filterRows),
    "// Transition and animation lists, and the timing functions they name (see shared/css/anim.ts).",
    table("ANIM_ROWS", "number[][]", animRows.all()),
    "// @counter-style rules, as the rows the runtime reads back, and the names they are known by.",
    table("COUNTER_STYLES", "string[]", counterStyleRows),
    table("COUNTER_STYLE_NAMES", "string[]", counterStyleNames),
    "// @keyframes blocks: [name id, offset, property, value, unit, ...], one row per block.",
    table("ANIM_KEYFRAMES", "number[][]", animKeyframes.all()),
    table("ANIM_NAMES", "string[]", animNames.all()),
    "",
  ].join("\n");
  const tables = { title, width, height, windowOptions, imageBase: options.bundle !== undefined ? "" : appDir,
    siteBase, bundled: options.bundle !== undefined,
    xmlDocument: /\.xht(ml)?$/i.test(htmlPath),
    quirks: documentMode(readFileSync(htmlPath, "utf8")),
    charset: pageCharset(readFileSync(htmlPath, "utf8")) } as AppTables;
  const data = tables as unknown as Record<string, unknown>;
  const scalars = new Set(["TITLE", "WIDTH", "HEIGHT", "WINDOW_OPTIONS", "IMAGE_BASE", "SITE_BASE", "BUNDLED", "XML_DOCUMENT", "QUIRKS", "CHARSET"]);
  for (const [field, name] of TABLE_FIELDS) {
    if (scalars.has(name)) continue;
    if (name === "CHAIN_STATES") {
      data[field] = chainStates;
      continue;
    }
    const value = emittedTables.get(name);
    if (value === undefined) throw new Error(`native: gen.ts table ${name} was not emitted`);
    data[field] = value;
  }
  emittedTables = null;

  return {
    title, width, height, scripts, handlers, genSource, tables, inlineScripts, scriptSrcs, fonts, images,
    ids: nodes.map((n) => n.id).filter((id) => id !== ""),
    stats: {
      elements: nodes.length, rules: outRules.length, rulesDropped, conditionalRules, dynamicSelectors: dynRules.length,
      staticChains, runtimeChains: outRules.filter((r) => r.chain.length > 0).length,
    },
  };
}

function collapse(s: string): string {
  return s.replace(/[ \t\n\r\f]+/g, " ");
}

/** The window's look from `<meta name="native-window">`, as `key=value` pairs joined by `;` for
 *  the host: titlebar=default|hidden|hidden-inset|transparent, min-width, min-height and
 *  resizable=yes|no. Width and height are read separately. */
export function parseWindowOptions(content: string, warn: (msg: string) => void): string {
  const out: string[] = [];
  for (const part of content.split(",")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const key = part.slice(0, eq).trim().toLowerCase();
    const value = part.slice(eq + 1).trim().toLowerCase();
    if (key === "width" || key === "height") continue;
    if (key === "titlebar") {
      if (["default", "hidden", "hidden-inset", "transparent"].includes(value)) out.push(`titlebar=${value}`);
      else warn(`native-window: unknown titlebar '${value}' (supported: default, hidden, hidden-inset, transparent)`);
    } else if (key === "min-width" || key === "min-height") {
      if (/^\d+$/.test(value)) out.push(`${key}=${value}`);
      else warn(`native-window: ${key} takes a number of CSS pixels, not '${value}'`);
    } else if (key === "resizable") {
      if (value === "yes" || value === "no") out.push(`resizable=${value}`);
      else warn(`native-window: resizable takes yes or no, not '${value}'`);
    } else {
      warn(`native-window: unknown option '${key}' (supported: width, height, titlebar, min-width, min-height, resizable)`);
    }
  }
  return out.join(";");
}

/**
 * A script's own text, without the wrappers that carry it through markup. An XHTML page (an
 * .xht file served as application/xhtml+xml) can put its script in a CDATA section, and a page
 * that still wants to be read by very old browsers wraps the script in an HTML comment. Both
 * are markup, not script: the browser hands the script only what they enclose.
 */
function scriptBody(text: string): string {
  let s = text;
  s = s.replace(/^\s*\/\*\s*<!\[CDATA\[\s*\*\/\s*/, "");
  s = s.replace(/^\s*(?:\/\/)?\s*<!\[CDATA\[\s*(?:\/\/)?/, "");
  s = s.replace(/^\s*(?:\/\/)?\s*<!--\s*/, "");
  s = s.replace(/\s*(?:\/\/)?\s*\]\]>\s*\*\/\s*$/, "");
  s = s.replace(/\s*(?:\/\/|\/\*)?\s*\]\]>\s*$/, "");
  s = s.replace(/\s*(?:\/\/)?\s*-->\s*$/, "");
  return s;
}

/** An HTML dimension attribute (width/height on <img>): a non-negative number, optionally %. */
function dimensionAttr(value: string | undefined): { v: number; u: number } | null {
  if (value === undefined) return null;
  const m = /^\s*(\d+(?:\.\d+)?)\s*(%|px)?\s*$/i.exec(value);
  if (!m) return null;
  return { v: parseFloat(m[1]), u: m[2] === "%" ? P.U_PCT : P.U_PX };
}

/** Values of the gen.ts tables emitted during the current compileApp() call, by export name. */
let emittedTables: Map<string, unknown> | null = null;

/** One table as a literal, recorded for the dev data file as well. */
function table(name: string, type: string, values: unknown[], perLine: boolean = false): string {
  emittedTables?.set(name, values);
  const items = values.map((v) => JSON.stringify(v));
  const lit = perLine ? "[\n" + items.map((s) => "  " + s + ",").join("\n") + (items.length > 0 ? "\n" : "") + "]"
    : "[" + items.join(", ") + "]";
  return `export const ${name}: ${type} = ${lit};`;
}

export type { HNode };

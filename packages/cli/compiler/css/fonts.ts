// @font-face scanning, which only the compiler needs. The font properties themselves live in
// shared/css/fonts.ts, where the runtime can use them too.

import { locator } from "../diagnostics.ts";
import { splitDeclarations } from "../../shared/css/declarations.ts";
import { splitFamilies } from "../../shared/css/fonts.ts";
import { hasVar } from "../../shared/css/vars.ts";
import { parseColor } from "../../shared/css/colors.ts";
import * as P from "../../shared/props.ts";
import { GENERIC_FAMILIES } from "../../shared/css/types.ts";
export { firstFamily } from "../../shared/css/fonts.ts";
import { findClose, findOpen } from "./parse.ts";
import { openSync, readSync, closeSync } from "node:fs";

/** One entry of a `src` descriptor: `local("Name")` or `url("file")`, in the order given. */
export interface FaceSource {
  local: string | null;
  url: string | null;
}

/**
 * A parsed @font-face rule: the family name it defines, the sources its `src` names in order, and
 * the weight range and style it covers. One family may have several rules, one per face.
 */
export interface FontFaceDecl {
  family: string;
  sources: FaceSource[];
  /** The CSS weight range the face covers, as `font-weight` gives it (a value or a range). */
  weightLo: number;
  weightHi: number;
  /** True when the descriptor was absent or `auto`, so the file's own weight decides. */
  weightAuto: boolean;
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
  line: number;
  col: number;
  dropped?: boolean;
  /** Why the rule defines nothing, when a descriptor wasn't understood. */
  error?: string;
}

/** A font-weight descriptor: `normal`, `bold`, a number, or a range. Null when invalid. */
function faceWeight(text: string | undefined): [number, number] | null {
  if (text === undefined) return [400, 400];
  const t = text.trim().toLowerCase();
  if (t === "normal") return [400, 400];
  // `auto` is the initial value: a static face covers the regular weight, and a variable one
  // covers whatever its default instance takes (CSS Fonts 4 §4.5). Without reading the file's
  // fvar table here, the face is taken as regular — which is what a static font gives.
  if (t === "auto") return [400, 400];
  if (t === "bold") return [700, 700];
  const m = /^(\d+(?:\.\d+)?)(?:\s+(\d+(?:\.\d+)?))?$/.exec(t);
  if (!m) return null;
  const lo = Number(m[1]);
  const hi = m[2] !== undefined ? Number(m[2]) : lo;
  // CSS keeps a weight in 1..1000, and a reversed range is invalid.
  if (!(lo >= 1 && lo <= 1000 && hi >= lo && hi <= 1000)) return null;
  return [lo, hi];
}

/**
 * Every source a `src` descriptor names, in the order it lists them: a `local()` font the system
 * already has, or a `url()`. The `format()` and `tech()` hints after a source say nothing about
 * whether it can be used, so they are skipped.
 */
function faceSources(text: string): FaceSource[] {
  const out: FaceSource[] = [];
  const re = /\b(url|local)\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/gi;
  let m = re.exec(text);
  while (m !== null) {
    const value = (m[2] ?? m[3] ?? m[4] ?? "").trim();
    out.push(m[1].toLowerCase() === "local" ? { local: value, url: null } : { local: null, url: value });
    m = re.exec(text);
  }
  return out;
}

/** A metric-override descriptor as a fraction of the font size; -1 for `normal` or an invalid one. */
function metricOverride(text: string | undefined): number {
  if (text === undefined) return -1;
  const t = text.trim().toLowerCase();
  if (t === "normal") return -1;
  const m = /^(\d+(?:\.\d+)?)%$/.exec(t);
  return m !== null ? Number(m[1]) / 100 : -1;
}

/** The stretch keywords, as the percentages CSS Fonts 4 gives them. */
const STRETCH_PERCENT: Record<string, number> = {
  "ultra-condensed": 50, "extra-condensed": 62.5, condensed: 75, "semi-condensed": 87.5,
  normal: 100, "semi-expanded": 112.5, expanded: 125, "extra-expanded": 150, "ultra-expanded": 200,
};

/** The `font-stretch` a face covers as a percentage; a descriptor that doesn't parse is ignored. */
function faceStretch(text: string | undefined): number {
  if (text === undefined) return 100;
  const t = text.trim().toLowerCase();
  const named = STRETCH_PERCENT[t];
  if (named !== undefined) return named;
  const m = /^(\d+(?:\.\d+)?)%$/.exec(t);
  return m !== null ? Number(m[1]) : 100;
}

/** The `font-feature-settings` a face asks for, as `tag=value` pairs joined by semicolons. */
function faceFeatures(text: string | undefined): string {
  if (text === undefined) return "";
  const values = new Map<string, number>();
  for (const part of text.split(",")) {
    const m = /^\s*"([^"]{1,4})"(?:\s+(\S+))?\s*$/.exec(part);
    if (m === null || m[1].length !== 4) return "";
    const v = m[2];
    let n = 1;
    if (v !== undefined) {
      if (v === "on") n = 1;
      else if (v === "off") n = 0;
      else if (/^\d+$/.test(v)) n = Number(v);
      else return "";
    }
    values.set(m[1], n);
  }
  const out: string[] = [];
  for (const [tag, v] of values) out.push(tag + "=" + v);
  return out.join(";");
}

/**
 * A `unicode-range` descriptor: comma-separated `U+XXXX`, `U+XXXX-YYYY` or wildcard
 * `U+4??` ranges, as canonical `lo-hi` pairs joined by commas. "" means the face covers every
 * character; a descriptor that doesn't parse is ignored, which leaves the face covering all.
 */
function unicodeRanges(text: string | undefined): string {
  if (text === undefined || text.trim() === "") return "";
  const out: string[] = [];
  for (const part of text.split(",")) {
    const m = /^u\+([0-9a-f?]{1,6})(?:-([0-9a-f]{1,6}))?$/.exec(part.trim().toLowerCase());
    if (m === null) return "";
    const lo = parseInt(m[1].replace(/\?/g, "0"), 16);
    const hi = m[2] !== undefined ? parseInt(m[2], 16) : parseInt(m[1].replace(/\?/g, "f"), 16);
    if (lo > hi || hi > 0x10ffff) return "";
    out.push(lo === hi ? String(lo) : `${lo}-${hi}`);
  }
  return out.join(",");
}

/** Font faces are registered before any declaration is
 * compiled, because a family may be used before the rule that defines it (or in another sheet).
 */
export function scanFontFaces(src: string): FontFaceDecl[] {
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  src = src.replace(/<!\[CDATA\[/g, (m) => " ".repeat(m.length)).replace(/\]\]>/g, (m) => " ".repeat(m.length));
  const loc = locator(src);
  const out: FontFaceDecl[] = [];
  let at = src.indexOf("@");
  while (at >= 0) {
    const m = /^@([\w-]+)/.exec(src.slice(at));
    const name = (m ? m[1] : "").toLowerCase();
    const open = findOpen(src, at);
    if (name !== "font-face" || open >= src.length) {
      at = src.indexOf("@", at + 1);
      continue;
    }
    const close = findClose(src, open);
    const desc = new Map<string, string>();
    for (const d of splitDeclarations(src.slice(open + 1, close))) {
      const c = d.text.indexOf(":");
      if (c > 0) desc.set(d.text.slice(0, c).trim().toLowerCase(), d.text.slice(c + 1).trim());
    }
    const rawFamily = desc.get("font-family") ?? "";
    const rawSrc = desc.get("src") ?? "";
    const family = splitFamilies(rawFamily)[0] ?? "";
    const [line, col] = loc(at);
    // var() has no meaning in an @font-face descriptor: the descriptor is invalid, and a rule
    // without a family defines nothing.
    if (hasVar(rawFamily)) {
      out.push({ family: "", sources: [], weightLo: 400, weightHi: 400, weightAuto: false, italic: false, ranges: "", features: "", stretch: 100, ascent: -1, descent: -1, lineGap: -1, line, col, dropped: true });
      at = src.indexOf("@", close + 1);
      continue;
    }
    const range = faceWeight(desc.get("font-weight"));
    if (range === null) {
      const bad = (desc.get("font-weight") ?? "").trim();
      out.push({
        family, sources: [], weightLo: 400, weightHi: 400, weightAuto: false, italic: false, ranges: "", features: "", stretch: 100, ascent: -1, descent: -1, lineGap: -1, line, col, dropped: true,
        error: `@font-face has an invalid font-weight '${bad}'`,
      });
      at = src.indexOf("@", close + 1);
      continue;
    }
    // `italic` and `oblique` (with or without an angle) both take the italic face.
    const style = (desc.get("font-style") ?? "").trim().toLowerCase();
    const rawWeight = (desc.get("font-weight") ?? "").trim().toLowerCase();
    out.push({
      family, sources: hasVar(rawSrc) ? [] : faceSources(rawSrc), weightLo: range[0], weightHi: range[1],
      weightAuto: rawWeight === "" || rawWeight === "auto",
      italic: style === "italic" || style.startsWith("oblique"),
      ranges: unicodeRanges(desc.get("unicode-range")),
      features: faceFeatures(desc.get("font-feature-settings")),
      stretch: faceStretch(desc.get("font-stretch")),
      ascent: metricOverride(desc.get("ascent-override")),
      descent: metricOverride(desc.get("descent-override")),
      lineGap: metricOverride(desc.get("line-gap-override")), line, col,
    });
    at = src.indexOf("@", close + 1);
  }
  return out;
}

/** The named alternatives an `@font-feature-values` rule declares, as `kind|name` → feature spec. */
export function scanFontFeatureValues(src: string): Map<string, string> {
  const out = new Map<string, string>();
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  const block = (from: number): number => {
    const open = src.indexOf("{", from);
    if (open < 0) return -1;
    let depth = 0;
    for (let i = open; i < src.length; i++) {
      if (src[i] === "{") depth++;
      else if (src[i] === "}") {
        depth--;
        if (depth === 0) return i;
      }
    }
    return -1;
  };
  let at = src.indexOf("@font-feature-values");
  while (at >= 0) {
    const end = block(at);
    if (end < 0) break;
    const body = src.slice(at, end + 1);
    // Each inner at-rule names the kind of alternative; its declarations alias names to integers.
    const inner = /@([\w-]+)\s*\{([^}]*)\}/g;
    let m: RegExpExecArray | null;
    while ((m = inner.exec(body)) !== null) {
      const kind = m[1].toLowerCase();
      const tag = kind === "styleset" ? "ss" : kind === "character-variant" ? "cv"
        : kind === "swash" ? "swsh" : kind === "ornaments" ? "ornm"
          : kind === "annotation" ? "nalt" : kind === "stylistic" ? "salt" : "";
      if (tag === "") continue;
      for (const decl of m[2].split(";")) {
        const c = decl.indexOf(":");
        if (c <= 0) continue;
        const name = decl.slice(0, c).trim().toLowerCase();
        const values = decl.slice(c + 1).trim().split(/\s+/).filter((v) => /^\d+$/.test(v));
        if (name === "" || values.length === 0) continue;
        // A set kind indexes the feature (ss04, cv04); the others set its value.
        const spec = tag === "ss" || tag === "cv"
          ? values.map((v) => tag + v.padStart(2, "0") + "=1").join(";")
          : tag + "=" + values[0];
        out.set(kind + "|" + name, spec);
      }
    }
    at = src.indexOf("@font-feature-values", end + 1);
  }
  return out;
}
/**
 * One palette colour a @font-palette-values rule overrides: a palette entry index and the
 * colour, packed as RGBA in a 32-bit number (see shared/css/colors.ts).
 */
export interface PaletteColorDecl {
  index: number;
  color: number;
}

/**
 * A parsed @font-palette-values rule: the name it gives a palette, the families it applies to,
 * the palette it starts from and the colours it overrides.
 */
export interface FontPaletteDecl {
  /** The dashed ident after the at-keyword, as written. */
  name: string;
  /** The `font-family` descriptor's family names, in order. */
  families: string[];
  /** The base palette: PB_INDEX with an index, or PB_LIGHT/PB_DARK. */
  baseKind: number;
  base: number;
  colors: PaletteColorDecl[];
  line: number;
  col: number;
  /** Why the rule defines nothing, when a descriptor wasn't understood; it is then ignored. */
  error?: string;
}

/** A `base-palette` descriptor: `light`, `dark` or a whole number; null when invalid. */
function basePalette(text: string | undefined): { kind: number; index: number } | null {
  if (text === undefined) return { kind: P.PB_INDEX, index: 0 };
  const t = text.trim().toLowerCase();
  if (t === "light") return { kind: P.PB_LIGHT, index: 0 };
  if (t === "dark") return { kind: P.PB_DARK, index: 0 };
  if (/^\d+$/.test(t)) return { kind: P.PB_INDEX, index: Number(t) };
  return null;
}

/**
 * An `override-colors` descriptor: comma-separated `<index> <color>` pairs. Only absolute
 * colours are allowed, so a relative colour or currentColor makes the descriptor invalid, and
 * when an index appears twice the last colour wins.
 */
function overrideColors(text: string): PaletteColorDecl[] | null {
  const out: PaletteColorDecl[] = [];
  const seen = new Map<number, number>();
  for (const part of text.split(",")) {
    const m = /^\s*(\d+)\s+(.+?)\s*$/.exec(part);
    if (m === null) return null;
    const color = parseColor(m[2]);
    if (color === null) return null;
    seen.set(Number(m[1]), color);
  }
  for (const [index, color] of seen) out.push({ index, color });
  return out;
}

/**
 * Finds @font-palette-values rules in a style sheet. Like @font-face, they are registered before
 * any declaration is compiled: a value can use a palette the page defines after it, or in
 * another sheet.
 */
export function scanPaletteValues(src: string): FontPaletteDecl[] {
  src = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  const loc = locator(src);
  const out: FontPaletteDecl[] = [];
  let at = src.indexOf("@");
  while (at >= 0) {
    const m = /^@([\w-]+)/.exec(src.slice(at));
    const kind = (m ? m[1] : "").toLowerCase();
    const open = findOpen(src, at);
    if (kind !== "font-palette-values" || open >= src.length) {
      at = src.indexOf("@", at + 1);
      continue;
    }
    const close = findClose(src, open);
    const prelude = src.slice(at + m![0].length, open).trim();
    const desc = new Map<string, string>();
    for (const d of splitDeclarations(src.slice(open + 1, close))) {
      const c = d.text.indexOf(":");
      if (c > 0) desc.set(d.text.slice(0, c).trim().toLowerCase(), d.text.slice(c + 1).trim());
    }
    const [line, col] = loc(at);
    const name = prelude;
    // The rule needs a dashed ident and a font-family descriptor; a generic family in the list is
    // a syntax error, so the rule defines nothing.
    const named = /^--[-_a-zA-Z0-9]+$/.test(name) && !hasVar(prelude);
    const rawFamily = desc.get("font-family");
    const families = rawFamily === undefined ? [] : splitFamilies(rawFamily);
    const base = basePalette(desc.get("base-palette"));
    const rawOverrides = desc.get("override-colors");
    const colors = rawOverrides === undefined ? [] : overrideColors(rawOverrides);
    let error: string | undefined;
    if (!named) error = `@font-palette-values has an invalid name '${name}'`;
    else if (families.length === 0) error = `@font-palette-values '${name}' has no font-family`;
    else if (families.some((f) => GENERIC_FAMILIES[f] !== undefined)) {
      error = `@font-palette-values '${name}' names a generic font family`;
    } else if (base === null) {
      error = `@font-palette-values '${name}' has an invalid base-palette '${desc.get("base-palette")}'`;
    } else if (colors === null) {
      error = `@font-palette-values '${name}' has an override-colors that isn't a list of an index and an absolute colour`;
    }
    out.push({
      name, families, baseKind: base ? base.kind : P.PB_INDEX, base: base ? base.index : 0,
      colors: colors ?? [], line, col, error,
    });
    at = src.indexOf("@", close + 1);
  }
  return out;
}

/** The weight a font file declares in OS/2 usWeightClass, or 400 when it has none. */
export function fontFileWeight(path: string): number {
  let fd = -1;
  try {
    fd = openSync(path, "r");
    const head = Buffer.alloc(12);
    if (readSync(fd, head, 0, 12, 0) !== 12) return 400;
    if (head.toString("latin1", 0, 4) === "ttcf") return 400;
    const numTables = head.readUInt16BE(4);
    const dir = Buffer.alloc(16 * numTables);
    if (readSync(fd, dir, 0, dir.length, 12) !== dir.length) return 400;
    for (let i = 0; i < numTables; i++) {
      if (dir.toString("latin1", i * 16, i * 16 + 4) !== "OS/2") continue;
      const at = dir.readUInt32BE(i * 16 + 8);
      const field = Buffer.alloc(2);
      if (readSync(fd, field, 0, 2, at + 4) !== 2) return 400;
      const w = field.readUInt16BE(0);
      return w >= 1 && w <= 1000 ? w : 400;
    }
    return 400;
  } catch {
    return 400;
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

/**
 * The palettes a font file's CPAL table declares, as [count, light index, dark index]; light and
 * dark are -1 when the font marks no palette for that background, and count is 0 when the file
 * has no CPAL table at all (a bitmap emoji font, say). CPAL version 1 stores a type for each
 * palette (1 light, 2 dark); version 0 stores none, so both keywords fall back to palette 0.
 */
export function fontPalettes(path: string): [number, number, number] {
  let fd = -1;
  try {
    fd = openSync(path, "r");
    const head = Buffer.alloc(12);
    if (readSync(fd, head, 0, 12, 0) !== 12) return [0, -1, -1];
    // Only a plain sfnt file here: a font collection's faces would each need their own tables.
    if (head.toString("latin1", 0, 4) === "ttcf") return [0, -1, -1];
    const numTables = head.readUInt16BE(4);
    const dir = Buffer.alloc(16 * numTables);
    if (readSync(fd, dir, 0, dir.length, 12) !== dir.length) return [0, -1, -1];
    let cpal = -1;
    for (let i = 0; i < numTables; i++) {
      if (dir.toString("latin1", i * 16, i * 16 + 4) === "CPAL") {
        cpal = dir.readUInt32BE(i * 16 + 8);
        break;
      }
    }
    if (cpal < 0) return [0, -1, -1];
    const header = Buffer.alloc(12);
    if (readSync(fd, header, 0, 12, cpal) !== 12) return [0, -1, -1];
    const version = header.readUInt16BE(0);
    const count = header.readUInt16BE(4);
    if (count === 0) return [0, -1, -1];
    if (version < 1) return [count, -1, -1];
    // The version-1 header follows the palette record indices, and the type array is an offset
    // from the start of the CPAL table.
    const rest = Buffer.alloc(2 * count + 12);
    if (readSync(fd, rest, 0, rest.length, cpal + 12) !== rest.length) return [count, -1, -1];
    const typesOffset = rest.readUInt32BE(2 * count);
    if (typesOffset === 0) return [count, -1, -1];
    // The type array holds one UInt32 per palette, with no count of its own.
    const types = Buffer.alloc(4 * count);
    if (readSync(fd, types, 0, types.length, cpal + typesOffset) !== types.length) {
      return [count, -1, -1];
    }
    let light = -1, dark = -1;
    for (let i = 0; i < count; i++) {
      const type = types.readUInt32BE(i * 4);
      if (light < 0 && (type & 1) !== 0) light = i;
      if (dark < 0 && (type & 2) !== 0) dark = i;
    }
    return [count, light, dark];
  } catch {
    return [0, -1, -1];
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

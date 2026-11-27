// Canvas 2D: the drawing half of a <canvas>. Each context owns a bitmap in the host; the page
// paints that bitmap wherever the element sits. Only the API's own state (styles, fonts, the
// transform) lives here; the path, the clip and the pixels live in the host.
//
// The canvas state stack is kept here rather than in CoreGraphics because a restore also has to
// put back what the host holds outside the graphics state (the fill and stroke styles, the font,
// the pen). After a host restore, this class re-applies the restored state in one go.

import { parseColor } from "../shared/css/colors.ts";
import { FF_SANS } from "../shared/props.ts";
import { invalidatePaint, markPaintDirty } from "./invalidation.ts";
import type { HTMLCanvasElement, HTMLImageElement, Node } from "./dom.ts";
import {
  hostCanvasCreate, hostCanvasResize, hostCanvasSave, hostCanvasRestore, hostCanvasSetTransform,
  hostCanvasSetAlpha, hostCanvasSetComposite, hostCanvasSetLineWidth, hostCanvasSetLineCap,
  hostCanvasSetLineJoin, hostCanvasSetFillColor, hostCanvasSetStrokeColor, hostCanvasSetFillGradient,
  hostCanvasSetStrokeGradient, hostCanvasSetFont, hostCanvasSetFilter, hostCanvasBeginPath,
  hostCanvasMoveTo, hostCanvasLineTo,
  hostCanvasQuadraticTo, hostCanvasBezierTo, hostCanvasClosePath, hostCanvasArc, hostCanvasArcTo,
  hostCanvasRect, hostCanvasFill, hostCanvasStroke, hostCanvasClip, hostCanvasFillRect,
  hostCanvasStrokeRect, hostCanvasClearRect, hostCanvasFillText, hostCanvasStrokeText,
  hostMeasureText, hostTextMetrics, hostFontAscent, hostFontDescent,
  hostCanvasGetImageData, hostCanvasPutImageData, hostCanvasDrawImage, hostCanvasDrawCanvas,
} from "./host.ts";

// globalCompositeOperation names, in the order the host's blend mode table has them.
const COMPOSITES: string[] = [
  "source-over", "lighter", "copy", "destination-out",
  "multiply", "screen", "overlay", "darken", "lighten", "xor",
  "source-in", "source-out", "source-atop", "destination-in", "destination-atop", "destination-over",
];

const BLACK = 0x000000ff;

/**
 * A gradient is an immutable definition — a kind, a gradient line and a stop list — that a
 * context hands to the host when it paints with it. Keeping it here rather than in the host is
 * what lets a dropped gradient free its native pieces: scriptc reclaims this object, and the
 * host only ever holds the definition of the style the canvas is painting with now.
 */
export class CanvasGradient {
  get [Symbol.toStringTag](): string { return "CanvasGradient"; }
  /** 0 for a linear gradient, 1 for a radial one. */
  private readonly kind: number;
  /** The gradient line: x0, y0, x1, y1 for a linear one, x0, y0, r0, x1, y1, r1 for a radial. */
  private readonly line: number[];
  /** Stop colours (packed 0xRRGGBBAA) and offsets, kept sorted by offset. */
  private colors: number[] = [];
  private offsets: number[] = [];
  /** Bumped when a stop changes, so a context knows to send the definition again. */
  version = 0;

  constructor(kind: number, line: number[]) {
    this.kind = kind;
    this.line = line;
  }

  addColorStop(offset: number, color: string): void {
    const c = parseColor(color);
    const v = c === null ? BLACK : c;
    const at = Math.max(0, Math.min(1, offset));
    // Keep the stops sorted; a stop at the same offset replaces the earlier one.
    let i = 0;
    for (; i < this.offsets.length; i++) {
      if (at === this.offsets[i]) {
        this.colors[i] = v;
        this.version++;
        return;
      }
      if (at < this.offsets[i]) break;
    }
    this.offsets.splice(i, 0, at);
    this.colors.splice(i, 0, v);
    this.version++;
  }

  /** The host's text form: "l;x0,y0,x1,y1" or "r;x0,y0,r0,x1,y1,r1", then ";colour,offset" per stop. */
  definition(): string {
    let s = (this.kind === 0 ? "l;" : "r;") + this.line.join(",");
    for (let i = 0; i < this.offsets.length; i++) s += ";" + this.colors[i] + "," + this.offsets[i];
    return s;
  }
}

export class TextMetrics {
  get [Symbol.toStringTag](): string { return "TextMetrics"; }
  /** How far the run advances from where it starts. */
  readonly width: number;
  /** The ink's bounds around the start of the run: negative left is ink reaching left of it. */
  readonly actualBoundingBoxLeft: number;
  readonly actualBoundingBoxRight: number;
  readonly actualBoundingBoxAscent: number;
  readonly actualBoundingBoxDescent: number;
  /** The font's own ascent and descent: the box every run in it sits in, ink or not. */
  readonly fontBoundingBoxAscent: number;
  readonly fontBoundingBoxDescent: number;
  /** The baselines a run can be aligned to, each a distance above (negative: below) the alphabetic
   *  one; the hanging baseline sits at 70% of the font size, as a browser's does. */
  readonly hangingBaseline: number;
  readonly alphabeticBaseline: number = 0;
  readonly ideographicBaseline: number;

  constructor(m: number[], size: number) {
    this.width = m[0];
    this.actualBoundingBoxLeft = m[1];
    this.actualBoundingBoxRight = m[2];
    this.actualBoundingBoxAscent = m[3];
    this.actualBoundingBoxDescent = m[4];
    this.fontBoundingBoxAscent = m[5];
    this.fontBoundingBoxDescent = m[6];
    this.hangingBaseline = 0.7 * size;
    this.ideographicBaseline = -m[6];
  }
}

/** A rect of pixels: a byte an RGBA channel, straight (not premultiplied), rows top down. */
export class ImageData {
  get [Symbol.toStringTag](): string { return "ImageData"; }
  readonly width: number;
  readonly height: number;
  readonly data: Uint8ClampedArray;
  readonly colorSpace: string = "srgb";

  /** `new ImageData(width, height)` or `new ImageData(width, height, data)`, as the DOM spells
   *  the size-first form. */
  constructor(width: number, height: number, data?: Uint8ClampedArray);
  /** `new ImageData(data, width)` (the height follows from the data) or
   *  `new ImageData(data, width, height)`, the form a page converting pixels back from a canvas
   *  writes. */
  constructor(data: Uint8ClampedArray, width: number, height?: number);
  constructor(a: number | Uint8ClampedArray, b: number, c?: Uint8ClampedArray | number) {
    if (typeof a === "number") {
      this.width = a;
      this.height = b;
      this.data = c instanceof Uint8ClampedArray ? c : new Uint8ClampedArray(a * b * 4);
      return;
    }
    const height = typeof c === "number" ? c : b === 0 ? 0 : Math.floor(a.length / 4 / b);
    if (a.length !== b * height * 4)
      throw new Error("IndexSizeError: the data length does not match the ImageData size");
    this.width = b;
    this.height = height;
    this.data = a;
  }
}

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Pixel bytes as base64, the one way a buffer crosses to the host: an FFI string is the only
 *  bytes a call can carry, and a pixel buffer isn't text. */
function base64Pixels(bytes: Uint8ClampedArray): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += BASE64.charAt(a >> 2);
    out += BASE64.charAt(((a & 3) << 4) | (b >> 4));
    out += i + 1 < bytes.length ? BASE64.charAt(((b & 15) << 2) | (c >> 6)) : "=";
    out += i + 2 < bytes.length ? BASE64.charAt(c & 63) : "=";
  }
  return out;
}

/** A count of pixels, or the whole number a fraction of one names: toward zero, as a long is. */
function whole(v: number): number { return v < 0 ? -Math.floor(-v) : Math.floor(v); }

/** The seven numbers hostTextMetrics packs, as the doubles they are. */
function unpackMetrics(bytes: Uint8Array): number[] {
  const raw = new Uint8Array(56);
  for (let i = 0; i < 56 && i < bytes.length; i++) raw[i] = bytes[i];
  const doubles = new Float64Array(raw.buffer);
  const out: number[] = [];
  for (let i = 0; i < 7; i++) out.push(doubles[i]);
  return out;
}

/** One level of the canvas state stack. */
class ContextState {
  m: number[] = [1, 0, 0, 1, 0, 0];
  fill: string | CanvasGradient = "#000000";
  stroke: string | CanvasGradient = "#000000";
  alpha = 1;
  composite = 0;
  lineWidth = 1;
  cap = 0;
  join = 0;
  fontSize = 10;
  fontWeight = 400;
  // How text is placed relative to its point: the drawing state's own, though the host never sees
  // it (the painter offsets each run before the call).
  textAlign = "start";
  textBaseline = "alphabetic";
  /** The filter string as set, and the definition packed for the host. */
  filterText = "none";
  filter = "";
}

/** [a, b, c, d, e, f] under the canvas convention: x' = a*x + c*y + e, y' = b*x + d*y + f. */
function multiply(a: number[], b: number[]): number[] {
  return [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ];
}

/** The CSS font string's size, and the weight packed for the host's font cache. */
function parseFont(font: string): number[] {
  let size = 10;
  const px = font.indexOf("px");
  if (px > 0) {
    let s = px - 1;
    while (s >= 0 && "0123456789.".indexOf(font[s]) >= 0) s--;
    const n = parseFloat(font.slice(s + 1, px));
    if (Number.isFinite(n) && n > 0) size = n;
  }
  let weight = 400;
  let italic = 0;
  for (const token of font.split(" ")) {
    const t = token.toLowerCase();
    if (t === "bold" || t === "bolder") weight = 700;
    else if (t === "lighter") weight = 300;
    else if (t === "italic" || t === "oblique") italic = 1000;
    else if (/^[0-9]+$/.test(t)) weight = parseInt(t, 10);
  }
  // Font family ids match the rest of the runtime: 0 system, 1 monospace, 2 serif, FF_SANS the
  // generic sans.
  let family = 0;
  const families = px >= 0 ? font.slice(px + 2) : font;
  if (families.indexOf("monospace") >= 0) family = 1;
  else if (families.indexOf("serif") >= 0 && families.indexOf("sans-serif") < 0) family = 2;
  else {
    // `sans-serif`, when no system-ui keyword comes before it, is the system's standard sans
    // (Helvetica on macOS): a different face from the system UI font a browser draws by name.
    const sans = families.indexOf("sans-serif");
    const system = ["system-ui", "-apple-system", "ui-sans-serif", "blinkmacsystemfont"]
      .map((name) => families.indexOf(name))
      .filter((at) => at >= 0)
      .sort((a, b) => a - b)[0] ?? -1;
    if (sans >= 0 && (system < 0 || sans < system)) family = FF_SANS;
  }
  return [size, weight + italic + family * 10000];
}

// The CSS filter functions the canvas knows, in the order the host's FILTER_* kinds count them:
// a function's kind is its index here plus one.
const FILTER_NAMES: string[] = [
  "blur", "brightness", "contrast", "saturate", "grayscale", "sepia", "hue-rotate", "invert", "opacity",
];

/**
 * One filter function's argument, as the number the host takes: a percentage is a fraction, an
 * angle is degrees, and a length is pixels. NaN when the argument isn't one the function accepts.
 */
function filterArgument(kind: number, arg: string): number {
  let text = arg;
  let scale = 1;
  const n = arg.length;
  if (n > 1 && text[n - 1] === "%") {
    text = text.slice(0, n - 1);
    scale = 0.01;
    // blur takes a length, never a percentage; hue-rotate an angle.
    if (kind === 1 || kind === 7) return NaN;
  } else if (n > 4 && text.slice(n - 4) === "grad" && kind === 7) {
    text = text.slice(0, n - 4);
    scale = 0.9;
  } else if (n > 2 && text.slice(n - 2) === "px") {
    if (kind === 7) return NaN;
    text = text.slice(0, n - 2);
  } else if (n > 3 && text.slice(n - 3) === "deg" && kind === 7) {
    text = text.slice(0, n - 3);
  } else if (n > 3 && text.slice(n - 3) === "rad" && kind === 7) {
    text = text.slice(0, n - 3);
    scale = 180 / Math.PI;
  } else if (n > 4 && text.slice(n - 4) === "turn" && kind === 7) {
    text = text.slice(0, n - 4);
    scale = 360;
  }
  if (text.length === 0) return NaN;
  const value = Number(text);
  if (!Number.isFinite(value)) return NaN;
  return value * scale;
}

/**
 * The CSS filter string as the host takes it: "kind arg" per function, ';' between them, and "" for
 * none. Null when the string holds something that isn't a filter this canvas knows, which leaves the
 * property as it was, as a browser does.
 */
function parseFilter(value: string): string | null {
  const text = value.trim().toLowerCase();
  if (text === "none") return "";
  let out = "";
  let i = 0;
  while (i < text.length) {
    while (i < text.length && (text[i] === " " || text[i] === "\t" || text[i] === "\n" || text[i] === "\r")) i++;
    if (i >= text.length) break;
    const open = text.indexOf("(", i);
    if (open < 0) return null;
    const name = text.slice(i, open).trim();
    const close = text.indexOf(")", open + 1);
    if (close < 0) return null;
    const kind = FILTER_NAMES.indexOf(name);
    if (kind < 0) return null;
    const arg = filterArgument(kind + 1, text.slice(open + 1, close).trim());
    if (!Number.isFinite(arg) || arg < 0) return null;
    out += (out.length > 0 ? ";" : "") + (kind + 1) + " " + arg;
    i = close + 1;
  }
  return out.length > 0 ? out : null;
}

/** One corner's radii for roundRect: an x radius and a y radius. */
export interface RoundRectRadius {
  x: number;
  y: number;
}

/**
 * What roundRect accepts for its radii: one number for every corner, one point, or a list of one
 * to four of either. The union is named because a parameter whose type spells out
 * `Array<number | RoundRectRadius>` inline can't be given a bare point at compile time.
 */
export type RoundRectRadii = number | RoundRectRadius | Array<number | RoundRectRadius>;

export class CanvasRenderingContext2D {
  get [Symbol.toStringTag](): string { return "CanvasRenderingContext2D"; }
  /** The host bitmap; paint draws it wherever the element is. */
  readonly hostId: number;
  /** The canvas element the context draws on, so a draw damages that box rather than the page. */
  canvasEl: Node | null = null;
  private width = 0;
  private height = 0;

  private m: number[] = [1, 0, 0, 1, 0, 0];
  private fillValue: string | CanvasGradient = "#000000";
  private strokeValue: string | CanvasGradient = "#000000";
  /** The gradient the host's fill and stroke styles hold, and its version when it was sent. */
  private sentFill: CanvasGradient | null = null;
  private sentFillVersion = -1;
  private sentStroke: CanvasGradient | null = null;
  private sentStrokeVersion = -1;
  private alpha = 1;
  private composite = 0;
  private penWidth = 1;
  private cap = 0;
  private join = 0;
  private fontSize = 10;
  private fontWeight = 400;
  private filterText = "none";
  private filterDef = "";
  private stack: ContextState[] = [];

  textAlign = "start";
  textBaseline = "alphabetic";

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.hostId = hostCanvasCreate(width, height);
  }

  /** A draw changed what the canvas shows: its own box needs painting again, not the page. */
  private touched(): void {
    if (this.canvasEl !== null) markPaintDirty(this.canvasEl);
    else invalidatePaint();
  }

  /** Setting width or height resets the canvas to a blank slate, as on the web. */
  resize(width: number, height: number): void {
    this.width = width;
    this.height = height;
    hostCanvasResize(this.hostId, width, height);
    this.stack = [];
    this.m = [1, 0, 0, 1, 0, 0];
    this.fillValue = "#000000";
    this.strokeValue = "#000000";
    this.sentFill = this.sentStroke = null;
    this.alpha = 1;
    this.composite = 0;
    this.penWidth = 1;
    this.cap = 0;
    this.join = 0;
    this.fontSize = 10;
    this.fontWeight = 400;
    this.filterText = "none";
    this.filterDef = "";
    this.textAlign = "start";
    this.textBaseline = "alphabetic";
    hostCanvasSetTransform(this.hostId, 1, 0, 0, 1, 0, 0);
    hostCanvasSetFillColor(this.hostId, BLACK);
    hostCanvasSetStrokeColor(this.hostId, BLACK);
    hostCanvasSetAlpha(this.hostId, 1);
    hostCanvasSetComposite(this.hostId, 0);
    hostCanvasSetLineWidth(this.hostId, 1);
    hostCanvasSetLineCap(this.hostId, 0);
    hostCanvasSetLineJoin(this.hostId, 0);
    hostCanvasSetFont(this.hostId, 10, 400);
    hostCanvasSetFilter(this.hostId, "");
  }

  // --- State ---------------------------------------------------------------

  get fillStyle(): string | CanvasGradient {
    return this.fillValue;
  }
  set fillStyle(value: string | CanvasGradient) {
    this.fillValue = value;
    if (typeof value === "string") {
      this.sentFill = null;
      const c = parseColor(value);
      hostCanvasSetFillColor(this.hostId, c === null ? BLACK : c);
    } else {
      this.sendFill(value);
    }
  }

  private sendFill(g: CanvasGradient): void {
    hostCanvasSetFillGradient(this.hostId, g.definition());
    this.sentFill = g;
    this.sentFillVersion = g.version;
  }

  private sendStroke(g: CanvasGradient): void {
    hostCanvasSetStrokeGradient(this.hostId, g.definition());
    this.sentStroke = g;
    this.sentStrokeVersion = g.version;
  }

  /** Sends a gradient style again when its stops changed since the host last heard of it. */
  private syncGradients(): void {
    const f = this.fillValue;
    if (typeof f !== "string" && (f !== this.sentFill || f.version !== this.sentFillVersion)) this.sendFill(f);
    const s = this.strokeValue;
    if (typeof s !== "string" && (s !== this.sentStroke || s.version !== this.sentStrokeVersion)) this.sendStroke(s);
  }

  get strokeStyle(): string | CanvasGradient {
    return this.strokeValue;
  }
  set strokeStyle(value: string | CanvasGradient) {
    this.strokeValue = value;
    if (typeof value === "string") {
      this.sentStroke = null;
      const c = parseColor(value);
      hostCanvasSetStrokeColor(this.hostId, c === null ? BLACK : c);
    } else {
      this.sendStroke(value);
    }
  }

  get globalAlpha(): number {
    return this.alpha;
  }
  set globalAlpha(value: number) {
    this.alpha = Math.max(0, Math.min(1, value));
    hostCanvasSetAlpha(this.hostId, this.alpha);
  }

  get globalCompositeOperation(): string {
    return COMPOSITES[this.composite];
  }
  set globalCompositeOperation(value: string) {
    const i = COMPOSITES.indexOf(value);
    this.composite = i < 0 ? 0 : i;
    hostCanvasSetComposite(this.hostId, this.composite);
  }

  get lineWidth(): number {
    return this.penWidth;
  }
  set lineWidth(value: number) {
    this.penWidth = value > 0 ? value : 1;
    hostCanvasSetLineWidth(this.hostId, this.penWidth);
  }

  get lineCap(): string {
    return this.cap === 1 ? "round" : this.cap === 2 ? "square" : "butt";
  }
  set lineCap(value: string) {
    this.cap = value === "round" ? 1 : value === "square" ? 2 : 0;
    hostCanvasSetLineCap(this.hostId, this.cap);
  }

  get lineJoin(): string {
    return this.join === 1 ? "round" : this.join === 2 ? "bevel" : "miter";
  }
  set lineJoin(value: string) {
    this.join = value === "round" ? 1 : value === "bevel" ? 2 : 0;
    hostCanvasSetLineJoin(this.hostId, this.join);
  }

  get font(): string {
    return `${this.fontSize}px sans-serif`;
  }
  set font(value: string) {
    const parts = parseFont(value);
    this.fontSize = parts[0];
    this.fontWeight = parts[1];
    hostCanvasSetFont(this.hostId, this.fontSize, this.fontWeight);
  }

  /** The CSS filter string drawing operations go through; "none" for no filter. */
  get filter(): string {
    return this.filterText;
  }
  set filter(value: string) {
    const def = parseFilter(value);
    if (def === null) return;
    // The property reads back the filter as CSS serializes it: lowercased, trimmed.
    this.filterText = value.trim().toLowerCase();
    this.filterDef = def;
    hostCanvasSetFilter(this.hostId, def);
  }

  save(): void {
    const s = new ContextState();
    s.m = this.m.slice();
    s.fill = this.fillValue;
    s.stroke = this.strokeValue;
    s.alpha = this.alpha;
    s.composite = this.composite;
    s.lineWidth = this.penWidth;
    s.cap = this.cap;
    s.join = this.join;
    s.fontSize = this.fontSize;
    s.fontWeight = this.fontWeight;
    s.textAlign = this.textAlign;
    s.textBaseline = this.textBaseline;
    s.filterText = this.filterText;
    s.filter = this.filterDef;
    this.stack.push(s);
    hostCanvasSave(this.hostId);
  }

  restore(): void {
    const n = this.stack.length;
    if (n === 0) return;
    const s = this.stack[n - 1];
    this.stack.splice(n - 1, 1);
    hostCanvasRestore(this.hostId);
    // The graphics state is back; the styles and the font the host keeps beside it are not.
    this.m = s.m;
    hostCanvasSetTransform(this.hostId, s.m[0], s.m[1], s.m[2], s.m[3], s.m[4], s.m[5]);
    this.fillValue = s.fill;
    this.strokeValue = s.stroke;
    if (typeof s.fill === "string") {
      this.sentFill = null;
      const c = parseColor(s.fill);
      hostCanvasSetFillColor(this.hostId, c === null ? BLACK : c);
    } else {
      this.sendFill(s.fill);
    }
    if (typeof s.stroke === "string") {
      this.sentStroke = null;
      const c = parseColor(s.stroke);
      hostCanvasSetStrokeColor(this.hostId, c === null ? BLACK : c);
    } else {
      this.sendStroke(s.stroke);
    }
    this.alpha = s.alpha;
    hostCanvasSetAlpha(this.hostId, s.alpha);
    this.composite = s.composite;
    hostCanvasSetComposite(this.hostId, s.composite);
    this.penWidth = s.lineWidth;
    hostCanvasSetLineWidth(this.hostId, s.lineWidth);
    this.cap = s.cap;
    hostCanvasSetLineCap(this.hostId, s.cap);
    this.join = s.join;
    hostCanvasSetLineJoin(this.hostId, s.join);
    this.fontSize = s.fontSize;
    this.fontWeight = s.fontWeight;
    hostCanvasSetFont(this.hostId, s.fontSize, s.fontWeight);
    this.textAlign = s.textAlign;
    this.textBaseline = s.textBaseline;
    this.filterText = s.filterText;
    this.filterDef = s.filter;
    hostCanvasSetFilter(this.hostId, s.filter);
  }

  // --- Transforms ----------------------------------------------------------

  private setMatrix(m: number[]): void {
    this.m = m;
    hostCanvasSetTransform(this.hostId, m[0], m[1], m[2], m[3], m[4], m[5]);
  }

  translate(x: number, y: number): void {
    this.setMatrix(multiply(this.m, [1, 0, 0, 1, x, y]));
  }
  scale(x: number, y: number): void {
    this.setMatrix(multiply(this.m, [x, 0, 0, y, 0, 0]));
  }
  rotate(angle: number): void {
    const c = Math.cos(angle), s = Math.sin(angle);
    this.setMatrix(multiply(this.m, [c, s, -s, c, 0, 0]));
  }
  transform(a: number, b: number, c: number, d: number, e: number, f: number): void {
    this.setMatrix(multiply(this.m, [a, b, c, d, e, f]));
  }
  setTransform(a: number, b: number, c: number, d: number, e: number, f: number): void {
    this.setMatrix([a, b, c, d, e, f]);
  }
  resetTransform(): void {
    this.setMatrix([1, 0, 0, 1, 0, 0]);
  }

  // --- Paths ---------------------------------------------------------------

  beginPath(): void {
    hostCanvasBeginPath(this.hostId);
  }
  closePath(): void {
    hostCanvasClosePath(this.hostId);
  }
  moveTo(x: number, y: number): void {
    hostCanvasMoveTo(this.hostId, x, y);
  }
  lineTo(x: number, y: number): void {
    hostCanvasLineTo(this.hostId, x, y);
  }
  quadraticCurveTo(cpx: number, cpy: number, x: number, y: number): void {
    hostCanvasQuadraticTo(this.hostId, cpx, cpy, x, y);
  }
  bezierCurveTo(c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void {
    hostCanvasBezierTo(this.hostId, c1x, c1y, c2x, c2y, x, y);
  }
  arc(x: number, y: number, radius: number, start: number, end: number, counterclockwise: boolean = false): void {
    hostCanvasArc(this.hostId, x, y, radius, start, end, counterclockwise ? 1 : 0);
  }
  arcTo(x1: number, y1: number, x2: number, y2: number, radius: number): void {
    hostCanvasArcTo(this.hostId, x1, y1, x2, y2, radius);
  }
  rect(x: number, y: number, w: number, h: number): void {
    hostCanvasRect(this.hostId, x, y, w, h);
  }
  /**
   * Adds a closed rounded rectangle to the path. `radii` is one radius for every corner, a point
   * for one corner, or a list of one to four of either, spread over the corners the way
   * border-radius spreads them: one value for all four, two for top-left/bottom-right then
   * top-right/bottom-left, three for top-left, top-right/bottom-left, bottom-right, and four for
   * top-left, top-right, bottom-right, bottom-left. A radius is measured in x and y, so a corner
   * can be elliptical. Radii too large for the sides shrink by one factor until they fit, and a
   * negative width or height draws the same rounded rectangle flipped.
   */
  roundRect(x: number, y: number, w: number, h: number, radii: RoundRectRadii = 0): void {
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) return;
    // A single radius or point is a list of one.
    let list: Array<number | RoundRectRadius>;
    if (typeof radii === "number") list = [radii];
    else if (Array.isArray(radii)) list = radii;
    else list = [radii];
    if (list.length < 1 || list.length > 4) {
      throw new Error("RangeError: the radii of roundRect take one to four values, not " + list.length);
    }
    const pairs: number[][] = [];
    for (const value of list) {
      let rx = 0, ry = 0;
      if (typeof value === "number") {
        if (!Number.isFinite(value)) return;
        rx = value;
        ry = value;
      } else {
        rx = value.x === undefined ? 0 : value.x;
        ry = value.y === undefined ? 0 : value.y;
        if (!Number.isFinite(rx) || !Number.isFinite(ry)) return;
      }
      if (rx < 0 || ry < 0) throw new Error("RangeError: a radius of roundRect can't be negative");
      pairs.push([rx, ry]);
    }
    // The corners in path order — top-left, top-right, bottom-right, bottom-left — each as its
    // own pair, so the scaling below can't feed back into another corner.
    const copy = (at: number): number[] => [pairs[at][0], pairs[at][1]];
    const tl = copy(0);
    const tr = copy(pairs.length === 1 ? 0 : 1);
    const br = copy(pairs.length < 3 ? 0 : 2);
    const bl = copy(pairs.length === 1 ? 0 : pairs.length === 4 ? 3 : 1);
    if (w < 0) {
      x += w;
      w = -w;
    }
    if (h < 0) {
      y += h;
      h = -h;
    }
    // Radii that would overlap across a side shrink together, by the tightest factor.
    let scale = 1;
    const fit = (sum: number, side: number): void => {
      if (sum > side && sum > 0) scale = Math.min(scale, side / sum);
    };
    fit(tl[0] + tr[0], w);
    fit(bl[0] + br[0], w);
    fit(tl[1] + bl[1], h);
    fit(tr[1] + br[1], h);
    if (scale < 1) {
      for (const corner of [tl, tr, br, bl]) {
        corner[0] *= scale;
        corner[1] *= scale;
      }
    }
    if (tl[0] + tr[0] + br[0] + bl[0] + tl[1] + tr[1] + br[1] + bl[1] === 0) {
      this.rect(x, y, w, h);
      return;
    }
    // One corner's quarter arc around its centre, from one edge to the next; a corner with no
    // extent in one direction is that straight segment instead.
    const corner = (cx: number, cy: number, rx: number, ry: number, from: number, to: number): void => {
      if (rx > 0 && ry > 0) this.ellipse(cx, cy, rx, ry, 0, from, to, false);
      else this.lineTo(cx + rx, cy);
    };
    const QUARTER = Math.PI / 2;
    this.moveTo(x + tl[0], y);
    this.lineTo(x + w - tr[0], y);
    corner(x + w - tr[0], y + tr[1], tr[0], tr[1], -QUARTER, 0);
    this.lineTo(x + w, y + h - br[1]);
    corner(x + w - br[0], y + h - br[1], br[0], br[1], 0, QUARTER);
    this.lineTo(x + bl[0], y + h);
    corner(x + bl[0], y + h - bl[1], bl[0], bl[1], QUARTER, Math.PI);
    this.lineTo(x, y + tl[1]);
    corner(x + tl[0], y + tl[1], tl[0], tl[1], Math.PI, Math.PI + QUARTER);
    this.closePath();
  }
  /** An ellipse is the unit circle under a scale, which the path records like any other transform. */
  ellipse(x: number, y: number, rx: number, ry: number, rotation: number, start: number, end: number, counterclockwise: boolean = false): void {
    if (rx < 0 || ry < 0) return;
    const m = this.m;
    this.translate(x, y);
    this.rotate(rotation);
    this.scale(rx, ry);
    hostCanvasArc(this.hostId, 0, 0, 1, start, end, counterclockwise ? 1 : 0);
    this.setMatrix(m);
  }

  fill(rule: string = "nonzero"): void {
    this.syncGradients();
    hostCanvasFill(this.hostId, rule === "evenodd" ? 1 : 0);
    this.touched();
  }
  stroke(): void {
    this.syncGradients();
    hostCanvasStroke(this.hostId);
    this.touched();
  }
  clip(rule: string = "nonzero"): void {
    hostCanvasClip(this.hostId, rule === "evenodd" ? 1 : 0);
  }

  // --- Rectangles ----------------------------------------------------------

  fillRect(x: number, y: number, w: number, h: number): void {
    this.syncGradients();
    hostCanvasFillRect(this.hostId, x, y, w, h);
    this.touched();
  }
  strokeRect(x: number, y: number, w: number, h: number): void {
    this.syncGradients();
    hostCanvasStrokeRect(this.hostId, x, y, w, h);
    this.touched();
  }
  clearRect(x: number, y: number, w: number, h: number): void {
    hostCanvasClearRect(this.hostId, x, y, w, h);
    this.touched();
  }

  // --- Pixels --------------------------------------------------------------

  /** A blank ImageData of the given size in device pixels, for filling in and putting back. */
  createImageData(sw: number, sh: number): ImageData {
    const w = whole(sw), h = whole(sh);
    if (w < 0 || h < 0) throw new Error("IndexSizeError: an ImageData can't have a negative size");
    return new ImageData(w, h);
  }

  /** The bitmap's pixels in the rect (in device pixels) as straight RGBA: what the canvas holds
   *  now, with the parts of the rect outside it transparent. The transform doesn't apply. */
  getImageData(sx: number, sy: number, sw: number, sh: number): ImageData {
    const w = whole(sw), h = whole(sh);
    if (w < 0 || h < 0) throw new Error("IndexSizeError: a rect of getImageData can't be negative");
    if (w > 16384 || h > 16384) throw new Error("IndexSizeError: a rect of getImageData is too big");
    let raw = new Uint8Array(w * h * 4);
    hostCanvasGetImageData(this.hostId, sx, sy, w, h, (bytes) => {
      for (let i = 0; i < bytes.length && i < raw.length; i++) raw[i] = bytes[i];
    });
    return new ImageData(w, h, new Uint8ClampedArray(raw.buffer));
  }

  /** Draws an image or another canvas into the bitmap: the source rect (in the source's own
   *  pixels) scaled into the destination rect, as the DOM's drawImage does. Both sources are
   *  blitted by the host, so the context transform, globalAlpha and composite mode apply. */
  drawImage(image: HTMLImageElement | HTMLCanvasElement, dx: number, dy: number): void;
  drawImage(image: HTMLImageElement | HTMLCanvasElement, dx: number, dy: number, dw: number, dh: number): void;
  drawImage(image: HTMLImageElement | HTMLCanvasElement, sx: number, sy: number, sw: number, sh: number,
    dx: number, dy: number, dw: number, dh: number): void;
  drawImage(image: HTMLImageElement | HTMLCanvasElement, a: number, b: number, c?: number, d?: number,
    e?: number, f?: number, g?: number, h?: number): void {
    const source = image as unknown as {
      decodedImageId?: () => number; naturalWidth?: number; naturalHeight?: number;
      width?: number; height?: number; getContext?: (kind: "2d") => CanvasRenderingContext2D | null;
    };
    const isImage = typeof source.decodedImageId === "function";
    const srcW = isImage ? (source.naturalWidth ?? 0) : (source.width ?? 0);
    const srcH = isImage ? (source.naturalHeight ?? 0) : (source.height ?? 0);
    let sx = 0, sy = 0, sw = srcW, sh = srcH, dx = 0, dy = 0, dw = srcW, dh = srcH;
    if (h === undefined) {
      // drawImage(image, dx, dy) or drawImage(image, dx, dy, dw, dh).
      if (d === undefined) { dw = srcW; dh = srcH; } else { dw = c ?? srcW; dh = d ?? srcH; }
      dx = a; dy = b;
    } else {
      sx = a; sy = b; sw = c ?? srcW; sh = d ?? srcH; dx = e ?? 0; dy = f ?? 0; dw = g ?? 0; dh = h ?? 0;
    }
    if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
    if (isImage) {
      const id = source.decodedImageId!();
      if (id >= 0) hostCanvasDrawImage(this.hostId, id, dx, dy, dw, dh, sx, sy, sw, sh, 1);
      this.touched();
      return;
    }
    // A canvas source is blitted from its own bitmap by the host.
    const from = source.getContext === undefined ? null : source.getContext("2d");
    if (from === null) return;
    hostCanvasDrawCanvas(this.hostId, from.hostId, dx, dy, dw, dh, sx, sy, sw, sh, 1);
    this.touched();
  }

  /** Writes pixels into the bitmap at (dx, dy), device pixels, replacing what is there: the
   *  transform, the clip and globalAlpha don't apply, as a browser's putImageData doesn't either.
   *  The dirty rect picks the part of the image to write, in the image's own coordinates. */
  putImageData(data: ImageData, dx: number, dy: number, dirtyX: number = 0, dirtyY: number = 0,
    dirtyWidth: number = data.width, dirtyHeight: number = data.height): void {
    const x0 = Math.max(0, whole(dirtyX));
    const y0 = Math.max(0, whole(dirtyY));
    const x1 = Math.min(data.width, whole(dirtyX) + whole(dirtyWidth));
    const y1 = Math.min(data.height, whole(dirtyY) + whole(dirtyHeight));
    if (x1 <= x0 || y1 <= y0) return;
    const w = x1 - x0, h = y1 - y0;
    const pixels = new Uint8ClampedArray(w * h * 4);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const from = ((y + y0) * data.width + (x + x0)) * 4;
        const to = (y * w + x) * 4;
        pixels[to] = data.data[from];
        pixels[to + 1] = data.data[from + 1];
        pixels[to + 2] = data.data[from + 2];
        pixels[to + 3] = data.data[from + 3];
      }
    }
    hostCanvasPutImageData(this.hostId, dx + x0, dy + y0, w, h, base64Pixels(pixels));
    this.touched();
  }

  // --- Text ----------------------------------------------------------------

  private textWidth(text: string): number {
    return hostMeasureText(text, this.fontSize, this.fontWeight, 0, 0);
  }

  measureText(text: string): TextMetrics {
    let m: number[] = [0, 0, 0, 0, 0, 0, 0];
    hostTextMetrics(text, this.fontSize, this.fontWeight, 0, 0, (bytes) => { m = unpackMetrics(bytes); });
    return new TextMetrics(m, this.fontSize);
  }

  private alignOffset(width: number): number {
    if (this.textAlign === "center") return -width / 2;
    if (this.textAlign === "right" || this.textAlign === "end") return -width;
    return 0;
  }

  private baselineOffset(): number {
    const ascent = hostFontAscent(this.fontSize, this.fontWeight);
    const descent = hostFontDescent(this.fontSize, this.fontWeight);
    if (this.textBaseline === "top" || this.textBaseline === "hanging") return ascent;
    if (this.textBaseline === "middle") return (ascent - descent) / 2;
    if (this.textBaseline === "bottom" || this.textBaseline === "ideographic") return -descent;
    return 0;
  }

  fillText(text: string, x: number, y: number, maxWidth: number = 0): void {
    this.syncGradients();
    const tx = x + this.alignOffset(this.textWidth(text));
    hostCanvasFillText(text, this.hostId, tx, y + this.baselineOffset(), maxWidth);
    this.touched();
  }
  strokeText(text: string, x: number, y: number, maxWidth: number = 0): void {
    this.syncGradients();
    const tx = x + this.alignOffset(this.textWidth(text));
    hostCanvasStrokeText(text, this.hostId, tx, y + this.baselineOffset(), maxWidth);
    this.touched();
  }

  // --- Gradients -----------------------------------------------------------

  createLinearGradient(x0: number, y0: number, x1: number, y1: number): CanvasGradient {
    return new CanvasGradient(0, [x0, y0, x1, y1]);
  }
  createRadialGradient(x0: number, y0: number, r0: number, x1: number, y1: number, r1: number): CanvasGradient {
    return new CanvasGradient(1, [x0, y0, Math.max(0, r0), x1, y1, Math.max(0, r1)]);
  }
}

/** Turns a canvas's pixel dimensions into the host-side bitmap of a new context. */
export function createContext(width: number, height: number): CanvasRenderingContext2D {
  return new CanvasRenderingContext2D(width, height);
}

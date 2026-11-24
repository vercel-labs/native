// SVG geometry: what the runtime's inline painter and the compiler's SVG-image compiler both
// need. Attributes are read through a getter, so a runtime Element and a build-time parsed
// element are the same source; everything here is in user units and free of any paint state.
//
// A path is a flat list of operations in the element's own user space:
//   1 x y            move to
//   2 x y            line to
//   3 cx cy x y      quadratic curve to
//   4 c1x c1y c2x c2y x y   cubic curve to
//   5                close

/** Reads an attribute's raw string, or null when the element doesn't have it. */
export type AttrGet = (name: string) => string | null;

/** The tag without a namespace prefix ("svg:path" is a path). */
export function localName(tag: string): string {
  const cut = tag.lastIndexOf(":");
  return cut < 0 ? tag : tag.slice(cut + 1);
}

export function num(raw: string | null): number {
  if (raw === null) return 0;
  const n = parseFloat(raw);
  return Number.isFinite(n) ? n : 0;
}

/** Splits a list of numbers on commas and white space. */
export function numList(s: string): number[] {
  const out: number[] = [];
  for (const part of s.trim().split(/[\s,]+/)) {
    if (part === "") continue;
    out.push(parseFloat(part));
  }
  return out;
}

/**
 * A geometry attribute in user units: a bare number is user units, a percentage resolves against
 * `base`, and an absolute CSS unit measures its physical length (SVG 2 lets an element's lengths
 * use them, as a browser's do). Anything else reads as zero, as an unreadable length does.
 */
export function attrLen(get: AttrGet, name: string, base: number): number {
  const raw = get(name);
  if (raw === null) return 0;
  const m = /^\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)\s*(%|px|in|cm|mm|pt|pc|q)?\s*$/.exec(raw);
  if (m === null) return 0;
  const v = parseFloat(m[1]);
  const unit = m[2];
  if (unit === "%") return (v / 100) * base;
  if (unit === undefined) return v;
  return v * ABSOLUTE_UNITS[unit];
}

// ---------------------------------------------------------------------------
// Matrices: [a, b, c, d, e, f], as x' = a*x + c*y + e, y' = b*x + d*y + f

export const IDENTITY: number[] = [1, 0, 0, 1, 0, 0];

/** The point (x, y) through the matrix m. */
export function applyPoint(m: number[], x: number, y: number): number[] {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

/** The inverse of m, or the identity when m doesn't invert (a zero scale). */
export function invert(m: number[]): number[] {
  const det = m[0] * m[3] - m[1] * m[2];
  if (!(det !== 0) || !Number.isFinite(det)) return IDENTITY;
  return [m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
    (m[2] * m[5] - m[3] * m[4]) / det, (m[1] * m[4] - m[0] * m[5]) / det];
}

export function mul(a: number[], b: number[]): number[] {
  return [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ];
}

/**
 * The matrix of a `transform` attribute, its functions applied left to right. The attribute's
 * grammar is SVG's own (CSS Transforms 1, the SVG syntax): its numbers are user units, so a CSS
 * unit or a percentage makes the value invalid, and an invalid value leaves the element
 * untransformed, as browsers do.
 */
export function parseTransform(src: string): number[] {
  let m = IDENTITY;
  let i = 0;
  const n = src.length;
  while (i < n) {
    while (i < n && (src[i] === "," || /\s/.test(src[i]))) i++;
    if (i >= n) break;
    let j = i;
    while (j < n && /[a-zA-Z]/.test(src[j])) j++;
    if (j === i) return IDENTITY;
    const name = src.slice(i, j).toLowerCase();
    i = j;
    while (i < n && /\s/.test(src[i])) i++;
    if (src[i] !== "(") return IDENTITY;
    const close = src.indexOf(")", i + 1);
    if (close < 0) return IDENTITY;
    const args = strictNumbers(src.slice(i + 1, close));
    if (args === null) return IDENTITY;
    const t = transformFor(name, args);
    if (t === null) return IDENTITY;
    m = mul(m, t);
    i = close + 1;
  }
  return m;
}

/** A transform function's argument list, or null when any argument isn't a plain number. An
 *  empty argument (a doubled or trailing comma) makes the list invalid too. */
function strictNumbers(text: string): number[] | null {
  const out: number[] = [];
  const n = text.length;
  let i = 0;
  const skip = (): number => {
    const start = i;
    while (i < n && /\s/.test(text[i])) i++;
    return i - start;
  };
  skip();
  if (i >= n) return null;
  for (;;) {
    const m = /^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.exec(text.slice(i));
    if (m === null) return null;
    out.push(parseFloat(m[0]));
    i += m[0].length;
    const ws = skip();
    if (i >= n) return out;
    if (text[i] === ",") {
      i++;
      skip();
      if (i >= n) return null; // a trailing comma has an empty argument after it
      continue;
    }
    // Anything but a comma has to have been white space, or the number carries a unit.
    if (ws === 0) return null;
  }
}

function transformFor(name: string, a: number[]): number[] | null {
  switch (name) {
    case "matrix":
      return a.length === 6 ? [a[0], a[1], a[2], a[3], a[4], a[5]] : null;
    case "translate":
      return a.length === 1 || a.length === 2 ? [1, 0, 0, 1, a[0], a.length > 1 ? a[1] : 0] : null;
    case "scale":
      return a.length === 1 || a.length === 2 ? [a[0], 0, 0, a.length > 1 ? a[1] : a[0], 0, 0] : null;
    case "rotate": {
      // One angle, or the angle and the point it turns about: two arguments are not a transform.
      if (a.length !== 1 && a.length !== 3) return null;
      const r = a[0] * Math.PI / 180;
      const c = Math.cos(r), s = Math.sin(r);
      const rot = [c, s, -s, c, 0, 0];
      if (a.length === 3) return mul(mul([1, 0, 0, 1, a[1], a[2]], rot), [1, 0, 0, 1, -a[1], -a[2]]);
      return rot;
    }
    case "skewx":
      return a.length === 1 ? [1, 0, Math.tan(a[0] * Math.PI / 180), 1, 0, 0] : null;
    case "skewy":
      return a.length === 1 ? [1, Math.tan(a[0] * Math.PI / 180), 0, 1, 0, 0] : null;
    default:
      return null;
  }
}

/**
 * A `transform-origin` attribute as its [x, y] in user space, or null when it can't be read (an
 * empty or invalid value leaves the SVG default origin, 0 0). A length may carry a CSS unit, and
 * a percentage or a keyword is of `box` — the viewport for the default transform-box, or the
 * element's object bounding box for fill-box. One value means the other is the box's center.
 */
export function parseSvgOrigin(src: string, box: readonly number[]): number[] | null {
  const parts = src.trim().split(/\s+/).filter((t) => t !== "");
  if (parts.length === 0 || parts.length > 3) return null;
  const w = box[2];
  const h = box[3];
  let xText = parts[0];
  let yText = parts.length > 1 ? parts[1] : "";
  const k0 = positionKind(parts[0]);
  const k1 = parts.length > 1 ? positionKind(parts[1]) : "none";
  if (parts.length === 1 && k0 === "vertical") {
    // A single vertical keyword names y; x stays centered.
    xText = "center";
    yText = parts[0];
  } else if (parts.length > 1 && k0 === "vertical" && k1 === "vertical") {
    return null;
  } else if (parts.length > 1 && k0 === "vertical") {
    // A vertical keyword first needs a horizontal keyword (or center) second: `top 100%` has no
    // meaning as a two-value position, so the whole attribute is invalid.
    if (k1 !== "horizontal" && k1 !== "center") return null;
    xText = parts[1];
    yText = parts[0];
  } else if (parts.length > 1 && k0 === "center" && k1 === "horizontal") {
    // `center left` names the horizontal component second.
    xText = parts[1];
    yText = parts[0];
  }
  const x = originPart(xText, true, w);
  const y = yText === "" ? h / 2 : originPart(yText, false, h);
  if (x === null || y === null) return null;
  return [box[0] + x, box[1] + y];
}

/** Which axis a transform-origin component names by keyword, if any. */
function positionKind(text: string): string {
  const low = text.toLowerCase();
  if (low === "left" || low === "right") return "horizontal";
  if (low === "top" || low === "bottom") return "vertical";
  if (low === "center") return "center";
  return "none";
}

const ABSOLUTE_UNITS: Record<string, number> = { px: 1, in: 96, cm: 96 / 2.54, mm: 96 / 25.4, pt: 96 / 72, pc: 16, q: 96 / 101.6 };

/** One `transform-origin` component: a keyword, a percentage of `base`, a length with a unit, or
 *  a bare number in user units. */
function originPart(text: string, horizontal: boolean, base: number): number | null {
  const low = text.toLowerCase();
  if (low === "center") return base / 2;
  if (horizontal && low === "left") return 0;
  if (horizontal && low === "right") return base;
  if (!horizontal && low === "top") return 0;
  if (!horizontal && low === "bottom") return base;
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(%|px|in|cm|mm|pt|pc|q)?$/.exec(low);
  if (m === null) return null;
  const v = parseFloat(m[1]);
  const unit = m[2];
  if (unit === "%") return (v / 100) * base;
  if (unit === undefined) return v;
  return v * ABSOLUTE_UNITS[unit];
}

// ---------------------------------------------------------------------------
// viewBox and preserveAspectRatio

/** The root's viewBox as [minX, minY, width, height], or null when it has none. */
export function parseViewBox(get: AttrGet): number[] | null {
  const raw = get("viewbox");
  if (raw === null) return null;
  const v = numList(raw);
  if (v.length < 4 || !(v[2] > 0) || !(v[3] > 0)) return null;
  return [v[0], v[1], v[2], v[3]];
}

/** An alignment keyword's number: 0 for `none`, then xMin/xMid/xMax × yMin/yMid/yMax. */
export const PAR_NONE = 0;
const ALIGNS = ["none", "xminymin", "xmidymin", "xmaxymin", "xminymid", "xmidymid", "xmaxymid",
  "xminymax", "xmidymax", "xmaxymax"];

/** `preserveAspectRatio` as its alignment (see PAR_NONE) and whether it slices. */
export function parseAspectRatio(par: string | null): [number, boolean] {
  let align = 5; // xMidYMid
  let slice = false;
  if (par !== null) {
    const parts = par.trim().toLowerCase().split(/\s+/);
    let i = 0;
    if (parts.length > 0 && parts[0] === "defer") i = 1;
    if (i < parts.length && parts[i] !== "") {
      const a = ALIGNS.indexOf(parts[i]);
      if (a >= 0) align = a;
    }
    for (const p of parts) if (p === "slice") slice = true;
  }
  return [align, slice];
}

/**
 * The matrix taking viewBox units to the viewport's CSS px: the uniform (or, for `none`, the
 * non-uniform) scale preserveAspectRatio asks for, then the alignment offset.
 */
export function viewMatrix(view: number[], w: number, h: number, align: number, slice: boolean): number[] {
  const sx = w / view[2];
  const sy = h / view[3];
  if (align === PAR_NONE) {
    return [sx, 0, 0, sy, -view[0] * sx, -view[1] * sy];
  }
  const s = slice ? Math.max(sx, sy) : Math.min(sx, sy);
  const freeX = w - view[2] * s;
  const freeY = h - view[3] * s;
  const i = align - 1;
  const ax = i % 3; // 0 xMin, 1 xMid, 2 xMax
  const ay = Math.floor(i / 3); // 0 yMin, 1 yMid, 2 yMax
  const tx = ax === 0 ? 0 : ax === 2 ? freeX : freeX / 2;
  const ty = ay === 0 ? 0 : ay === 2 ? freeY : freeY / 2;
  return [s, 0, 0, s, tx - view[0] * s, ty - view[1] * s];
}

// ---------------------------------------------------------------------------
// Paths

const KAPPA = 0.5522847498307936;

export function moveTo(ops: number[], x: number, y: number): void {
  ops.push(1, x, y);
}
export function lineTo(ops: number[], x: number, y: number): void {
  ops.push(2, x, y);
}
export function curveTo(ops: number[], c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void {
  ops.push(4, c1x, c1y, c2x, c2y, x, y);
}
export function closePath(ops: number[]): void {
  ops.push(5);
}

/** A full ellipse as four cubic arcs, starting at its right-most point. */
export function ellipsePath(cx: number, cy: number, rx: number, ry: number): number[] {
  const ops: number[] = [];
  const kx = rx * KAPPA, ky = ry * KAPPA;
  moveTo(ops, cx + rx, cy);
  curveTo(ops, cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
  curveTo(ops, cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
  curveTo(ops, cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
  curveTo(ops, cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
  closePath(ops);
  return ops;
}

/** A rect, with the corner radii SVG takes from rx and ry (clamped to half the sides). */
export function rectPath(x: number, y: number, w: number, h: number, rxIn: number, ryIn: number): number[] {
  const ops: number[] = [];
  let rx = rxIn, ry = ryIn;
  if (rx === 0 && ry === 0) {
    moveTo(ops, x, y);
    lineTo(ops, x + w, y);
    lineTo(ops, x + w, y + h);
    lineTo(ops, x, y + h);
    closePath(ops);
    return ops;
  }
  rx = Math.min(Math.abs(rx), w / 2);
  ry = Math.min(Math.abs(ry), h / 2);
  const kx = rx * KAPPA, ky = ry * KAPPA;
  moveTo(ops, x + rx, y);
  lineTo(ops, x + w - rx, y);
  curveTo(ops, x + w - rx + kx, y, x + w, y + ry - ky, x + w, y + ry);
  lineTo(ops, x + w, y + h - ry);
  curveTo(ops, x + w, y + h - ry + ky, x + w - rx + kx, y + h, x + w - rx, y + h);
  lineTo(ops, x + rx, y + h);
  curveTo(ops, x + rx - kx, y + h, x, y + h - ry + ky, x, y + h - ry);
  lineTo(ops, x, y + ry);
  curveTo(ops, x, y + ry - ky, x + rx - kx, y, x + rx, y);
  closePath(ops);
  return ops;
}

/** The path a basic shape draws, in its own user space; an empty list for anything else. */
export function shapePath(name: string, get: AttrGet, vw: number, vh: number): number[] {
  switch (name) {
    case "rect": {
      const w = attrLen(get, "width", vw);
      const h = attrLen(get, "height", vh);
      if (!(w > 0) || !(h > 0)) return [];
      const rawRx = get("rx");
      const rawRy = get("ry");
      let rx = rawRx === null ? NaN : attrLen(get, "rx", vw);
      let ry = rawRy === null ? NaN : attrLen(get, "ry", vh);
      if (Number.isNaN(rx) && Number.isNaN(ry)) rx = ry = 0;
      else if (Number.isNaN(rx)) rx = ry;
      else if (Number.isNaN(ry)) ry = rx;
      return rectPath(attrLen(get, "x", vw), attrLen(get, "y", vh), w, h, rx, ry);
    }
    case "circle": {
      const r = attrLen(get, "r", Math.sqrt((vw * vw + vh * vh) / 2));
      if (!(r > 0)) return [];
      return ellipsePath(attrLen(get, "cx", vw), attrLen(get, "cy", vh), r, r);
    }
    case "ellipse": {
      const rx = attrLen(get, "rx", vw);
      const ry = attrLen(get, "ry", vh);
      if (!(rx > 0) || !(ry > 0)) return [];
      return ellipsePath(attrLen(get, "cx", vw), attrLen(get, "cy", vh), rx, ry);
    }
    case "line": {
      const ops: number[] = [];
      moveTo(ops, attrLen(get, "x1", vw), attrLen(get, "y1", vh));
      lineTo(ops, attrLen(get, "x2", vw), attrLen(get, "y2", vh));
      return ops;
    }
    case "polyline":
    case "polygon": {
      const raw = get("points");
      if (raw === null) return [];
      const v = numList(raw);
      const ops: number[] = [];
      for (let i = 0; i + 1 < v.length; i += 2) {
        if (i === 0) moveTo(ops, v[0], v[1]);
        else lineTo(ops, v[i], v[i + 1]);
      }
      if (name === "polygon") closePath(ops);
      return ops;
    }
    case "path": {
      const d = get("d");
      return d === null ? [] : pathData(d);
    }
    default:
      return [];
  }
}

/** The operations of a path `d` attribute, in user space. */
export function pathData(d: string): number[] {
  const ops: number[] = [];
  let i = 0;
  // The numbers are read one at a time: a flag in an arc is a single digit and may butt up
  // against the next number ("a1 1 0 011 1"), so splitting on separators isn't enough.
  const skip = (): void => {
    while (i < d.length && (d[i] === "," || /\s/.test(d[i]))) i++;
  };
  const readNumber = (): number => {
    skip();
    let j = i;
    if (d[j] === "+" || d[j] === "-") j++;
    while (j < d.length && d[j] >= "0" && d[j] <= "9") j++;
    if (d[j] === ".") {
      j++;
      while (j < d.length && d[j] >= "0" && d[j] <= "9") j++;
    }
    if (d[j] === "e" || d[j] === "E") {
      let k = j + 1;
      if (d[k] === "+" || d[k] === "-") k++;
      if (d[k] >= "0" && d[k] <= "9") {
        while (k < d.length && d[k] >= "0" && d[k] <= "9") k++;
        j = k;
      }
    }
    const raw = d.slice(i, j);
    i = j;
    const n = parseFloat(raw);
    return Number.isFinite(n) ? n : 0;
  };
  const readFlag = (): number => {
    skip();
    const c = d[i];
    i++;
    return c === "1" ? 1 : 0;
  };

  let cmd = "";
  let cx = 0, cy = 0; // the current point
  let sx = 0, sy = 0; // the subpath's start
  let lastCx = 0, lastCy = 0; // the last cubic's second control point, for S
  let lastQx = 0, lastQy = 0; // the last quadratic's control point, for T
  let lastWasCubic = false, lastWasQuad = false;

  // Applies one command's worth of arguments, reading them from the stream.
  const apply = (name: string): void => {
    const rel = name === name.toLowerCase() && name !== "z" && name !== "Z";
    const up = name.toUpperCase();
    if (up === "M") {
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      sx = cx;
      sy = cy;
      moveTo(ops, cx, cy);
    } else if (up === "L") {
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      lineTo(ops, cx, cy);
    } else if (up === "H") {
      cx = rel ? cx + readNumber() : readNumber();
      lineTo(ops, cx, cy);
    } else if (up === "V") {
      cy = rel ? cy + readNumber() : readNumber();
      lineTo(ops, cx, cy);
    } else if (up === "C") {
      const x1 = rel ? cx + readNumber() : readNumber();
      const y1 = rel ? cy + readNumber() : readNumber();
      const x2 = rel ? cx + readNumber() : readNumber();
      const y2 = rel ? cy + readNumber() : readNumber();
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      curveTo(ops, x1, y1, x2, y2, cx, cy);
      lastCx = x2;
      lastCy = y2;
      lastWasCubic = true;
      lastWasQuad = false;
    } else if (up === "S") {
      const x1 = lastWasCubic ? 2 * cx - lastCx : cx;
      const y1 = lastWasCubic ? 2 * cy - lastCy : cy;
      const x2 = rel ? cx + readNumber() : readNumber();
      const y2 = rel ? cy + readNumber() : readNumber();
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      curveTo(ops, x1, y1, x2, y2, cx, cy);
      lastCx = x2;
      lastCy = y2;
      lastWasCubic = true;
      lastWasQuad = false;
    } else if (up === "Q") {
      const qx = rel ? cx + readNumber() : readNumber();
      const qy = rel ? cy + readNumber() : readNumber();
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      ops.push(3, qx, qy, cx, cy);
      lastQx = qx;
      lastQy = qy;
      lastWasQuad = true;
      lastWasCubic = false;
    } else if (up === "T") {
      const qx = lastWasQuad ? 2 * cx - lastQx : cx;
      const qy = lastWasQuad ? 2 * cy - lastQy : cy;
      cx = rel ? cx + readNumber() : readNumber();
      cy = rel ? cy + readNumber() : readNumber();
      ops.push(3, qx, qy, cx, cy);
      lastQx = qx;
      lastQy = qy;
      lastWasQuad = true;
      lastWasCubic = false;
    } else if (up === "A") {
      const rx = Math.abs(readNumber());
      const ry = Math.abs(readNumber());
      const rotation = readNumber();
      const large = readFlag();
      const sweep = readFlag();
      const x = rel ? cx + readNumber() : readNumber();
      const y = rel ? cy + readNumber() : readNumber();
      arcTo(ops, cx, cy, rx, ry, rotation, large, sweep, x, y);
      cx = x;
      cy = y;
      lastWasCubic = false;
      lastWasQuad = false;
    } else if (up === "Z") {
      closePath(ops);
      cx = sx;
      cy = sy;
      lastWasCubic = false;
      lastWasQuad = false;
    }
  };

  while (i < d.length) {
    skip();
    if (i >= d.length) break;
    const c = d[i];
    if (/[a-zA-Z]/.test(c)) {
      cmd = c;
      i++;
    } else if (cmd === "") {
      break; // numbers with no command: the path stops there
    }
    const up = cmd.toUpperCase();
    if (up === "Z") {
      apply(cmd);
      cmd = "";
      continue;
    }
    apply(cmd);
    // A moveto's further pairs are linetos; any other command repeats until the next letter.
    if (up === "M") cmd = cmd === "m" ? "l" : "L";
  }
  return ops;
}

/** Appends an elliptical arc from (x1, y1) to (x2, y2) as cubic curves (SVG 1.1 F.6.5). */
function arcTo(ops: number[], x1: number, y1: number, rxIn: number, ryIn: number, rotation: number,
  large: number, sweep: number, x2: number, y2: number): void {
  let rx = Math.abs(rxIn), ry = Math.abs(ryIn);
  if (rx === 0 || ry === 0 || (x1 === x2 && y1 === y2)) {
    lineTo(ops, x2, y2);
    return;
  }
  const phi = rotation * Math.PI / 180;
  const cos = Math.cos(phi), sin = Math.sin(phi);
  const dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
  const x1p = cos * dx + sin * dy;
  const y1p = -sin * dx + cos * dy;
  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    const s = Math.sqrt(lambda);
    rx *= s;
    ry *= s;
  }
  const sign = large !== sweep ? 1 : -1;
  const rx2 = rx * rx, ry2 = ry * ry;
  const numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
  const denom = rx2 * y1p * y1p + ry2 * x1p * x1p;
  const co = sign * Math.sqrt(Math.max(0, numerator / denom));
  const cxp = co * rx * y1p / ry;
  const cyp = -co * ry * x1p / rx;
  const cx = cos * cxp - sin * cyp + (x1 + x2) / 2;
  const cy = sin * cxp + cos * cyp + (y1 + y2) / 2;
  const angle = (ux: number, uy: number, vx: number, vy: number): number => {
    const dot = ux * vx + uy * vy;
    const len = Math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    const a = Math.acos(Math.max(-1, Math.min(1, len === 0 ? 1 : dot / len)));
    return ux * vy - uy * vx < 0 ? -a : a;
  };
  const ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
  const vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
  const start = angle(1, 0, ux, uy);
  let delta = angle(ux, uy, vx, vy);
  if (sweep === 0 && delta > 0) delta -= 2 * Math.PI;
  else if (sweep !== 0 && delta < 0) delta += 2 * Math.PI;
  // Each piece spans at most a quarter turn; a cubic approximates one that well.
  const steps = Math.max(1, Math.ceil(Math.abs(delta) / (Math.PI / 2)));
  const step = delta / steps;
  for (let k = 0; k < steps; k++) {
    const a0 = start + k * step;
    const a1 = a0 + step;
    const t = 4 / 3 * Math.tan(step / 4);
    const p0x = Math.cos(a0), p0y = Math.sin(a0);
    const p1x = Math.cos(a1), p1y = Math.sin(a1);
    const c1x = p0x - t * p0y, c1y = p0y + t * p0x;
    const c2x = p1x + t * p1y, c2y = p1y - t * p1x;
    // The ellipse's axes then the rotation, back in the path's own space.
    const map = (ex: number, ey: number): number[] => [
      cos * ex * rx - sin * ey * ry + cx,
      sin * ex * rx + cos * ey * ry + cy,
    ];
    const c1 = map(c1x, c1y), c2 = map(c2x, c2y), p = map(p1x, p1y);
    curveTo(ops, c1[0], c1[1], c2[0], c2[1], p[0], p[1]);
  }
}

/** Where a path is replayed: the host's canvas calls, or anything else shaped like them. */
export interface PathSink {
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  quadraticTo(cx: number, cy: number, x: number, y: number): void;
  bezierTo(c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void;
  close(): void;
}

/** Replays a path's operations into `sink`. */
export function emitPath(ops: number[], sink: PathSink): void {
  let i = 0;
  while (i < ops.length) {
    const kind = ops[i];
    if (kind === 1) {
      sink.moveTo(ops[i + 1], ops[i + 2]);
      i += 3;
    } else if (kind === 2) {
      sink.lineTo(ops[i + 1], ops[i + 2]);
      i += 3;
    } else if (kind === 3) {
      sink.quadraticTo(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4]);
      i += 5;
    } else if (kind === 4) {
      sink.bezierTo(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6]);
      i += 7;
    } else {
      sink.close();
      i += 1;
    }
  }
}

/**
 * A length attribute whose numbers are all bare, written with a px unit: SVG's attribute grammar
 * reads `stroke-width="6"` as six user units, where CSS wants a length. Null when the value is
 * anything else (a percentage, a px length, a calc()), which the CSS parser reads as it is.
 */
export function svgLengths(text: string): string | null {
  const s = text.trim();
  if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[\s,]+[-+]?(?:\d+\.?\d*|\.\d+))*$/.test(s)) return null;
  const out: string[] = [];
  for (const token of s.split(/[\s,]+/)) out.push(token + "px");
  return out.join(" ");
}

/** A path's operations with `m` applied to every point, for an affine matrix. */
export function transformOps(ops: number[], m: number[]): number[] {
  const out: number[] = [];
  const x = (v: number, w: number): number => m[0] * v + m[2] * w + m[4];
  const y = (v: number, w: number): number => m[1] * v + m[3] * w + m[5];
  let i = 0;
  while (i < ops.length) {
    const kind = ops[i];
    out.push(kind);
    if (kind === 1 || kind === 2) {
      out.push(x(ops[i + 1], ops[i + 2]), y(ops[i + 1], ops[i + 2]));
      i += 3;
    } else if (kind === 3) {
      out.push(x(ops[i + 1], ops[i + 2]), y(ops[i + 1], ops[i + 2]),
        x(ops[i + 3], ops[i + 4]), y(ops[i + 3], ops[i + 4]));
      i += 5;
    } else if (kind === 4) {
      out.push(x(ops[i + 1], ops[i + 2]), y(ops[i + 1], ops[i + 2]),
        x(ops[i + 3], ops[i + 4]), y(ops[i + 3], ops[i + 4]),
        x(ops[i + 5], ops[i + 6]), y(ops[i + 5], ops[i + 6]));
      i += 7;
    } else {
      i += 1;
    }
  }
  return out;
}

// Gradient images: `linear-gradient()`, `radial-gradient()` and `conic-gradient()`, compiled at
// build time into one compact string that the runtime decodes when it paints the layer (see
// runtime/gradient.ts).
//
// The encoding is fields joined by "|", with ":" inside a field:
//   L|angle|space|hue|<stop>|<stop>...       an angle in CSS degrees (0 = to top, clockwise), or
//                                            C<x>:<y> for a corner, worked out from the box
//   R|shape|rx|ry|cx|cy|space|hue|<stop>...  shape 1 = circle, 0 = ellipse; radii and the centre
//                                            are <value>:<unit> (the centre also :<edge>)
//   C|angle|cx|cy|space|hue|<stop>...        the angle the turn starts at, and the centre the turn
//                                            is around (conic-gradient)
//   space / hue                              the colour space the stops interpolate in, and the
//                                            hue arc there (see shared/css/colors.ts)
//   RL|… / RR|… / RC|…                       the repeating forms, whose stops tile along the line
//   stop                                     <colour>:<value>:<unit>, an empty value for a stop
//                                            whose position the gradient line fixes up; the colour
//                                            is `c` for currentColor
//   h:<value>:<unit>                         a colour hint: the position at which two stops are
//                                            half mixed
import * as P from "../props.ts";
import { CS_SRGB, HUE_SHORTER, gradientHueId, gradientSpaceId, parseColor, polarSpace } from "./colors.ts";
import { calcAngle, parseLength } from "./declarations.ts";
import { splitValue } from "./fonts.ts";

export type GradientResult = { encoded: string; source?: string } | { error: string };

/** Splits on top-level commas, so a colour's `rgb(...)` stays in one piece. */
function splitTopLevel(value: string): string[] {
  const out: string[] = [];
  let depth = 0, quote = "", cur = "";
  for (const ch of value) {
    if (quote !== "") {
      cur += ch;
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur.trim());
      cur = "";
    } else cur += ch;
  }
  if (cur.trim() !== "") out.push(cur.trim());
  return out;
}

/** One colour stop: a packed colour and an optional position (its unit is U_NONE without one). */
interface Stop { color: number; v: number; u: number }

/** A stop list entry for a colour hint: a position at which the stops either side are half mixed. */
const HINT = -1;
/** A stop whose colour is `currentColor`, resolved against the element when it is painted. */
const CURRENT = -2;

/** The colour word of a stop: a packed colour, currentColor, or null. */
function stopColor(word: string): number | null {
  if (word.toLowerCase() === "currentcolor") return CURRENT;
  return parseColor(word);
}

/** A CSS angle's size in degrees, or null when the token isn't an angle. A calc() of angles is
 *  folded at build time first. */
function angleDegrees(token: string): number | null {
  const t = token.trim().toLowerCase();
  const m = /^([-+]?(?:\d+\.?\d*|\.\d+))(deg|grad|rad|turn)$/.exec(t);
  if (!m) {
    const rad = calcAngle(t);
    return rad === null ? null : (rad * 180) / Math.PI;
  }
  const n = parseFloat(m[1]);
  if (m[2] === "grad") return (n * 360) / 400;
  if (m[2] === "rad") return (n * 180) / Math.PI;
  if (m[2] === "turn") return n * 360;
  return n;
}

/**
 * A stop position: a percentage or length (in the units the gradient line resolves), or, in a
 * conic gradient, an angle, which is a share of the full turn.
 */
function positionOf(word: string, angles: boolean): { v: number; u: number } | null {
  if (angles) {
    const a = angleDegrees(word);
    if (a !== null) return { v: a / 3.6, u: P.U_PCT };
  }
  const l = parseLength(word, false);
  return l === null ? null : { v: l.v, u: l.u };
}

/** A stop's fields, or null when the token isn't a colour with up to two positions. */
function parseStop(token: string, angles = false): Stop[] | null {
  const words = splitValue(token);
  if (words.length === 0) return null;
  const color = stopColor(words[0]);
  if (color === null) return null;
  if (words.length > 3) return null;
  const positions = words.slice(1);
  if (positions.length === 0) return [{ color, v: 0, u: P.U_NONE }];
  const stops: Stop[] = [];
  for (const pos of positions) {
    const p = positionOf(pos, angles);
    if (p === null) return null;
    stops.push({ color, v: p.v, u: p.u });
  }
  // A stop with two positions is a hard band: the same colour at both.
  return stops;
}

/** A colour hint: a bare position between two colour stops, or null for any other token. */
function parseHint(token: string, angles: boolean): Stop | null {
  const words = splitValue(token);
  if (words.length !== 1) return null;
  const p = positionOf(words[0], angles);
  return p === null ? null : { color: HINT, v: p.v, u: p.u };
}

/** The stop list entries a token adds: a colour (once or twice), or a colour hint. */
function stopEntries(token: string, angles: boolean): Stop[] | null {
  const parsed = parseStop(token, angles);
  if (parsed !== null) return parsed;
  const hint = parseHint(token, angles);
  return hint === null ? null : [hint];
}

function encodeStops(stops: Stop[]): string | null {
  let colors = 0;
  for (const s of stops) if (s.color !== HINT) colors++;
  if (colors < 2) return null;
  // A position is a percentage of the gradient line or a length along it; an empty field means
  // the gradient line's stop fixup decides it.
  const field = (s: Stop): string => {
    if (s.color === HINT) return `h:${s.v}:${s.u}`;
    const c = s.color === CURRENT ? "c" : String(s.color);
    if (s.u === P.U_NONE) return `${c}::${s.u}`;
    return `${c}:${s.v}:${s.u}`;
  };
  return stops.map(field).join("|");
}

/**
 * A linear gradient's direction, as an encoded field: a CSS angle in degrees, or `C<x>:<y>` for a
 * corner such as `to bottom right`, whose angle depends on the box's shape and so is worked out
 * when the layer is painted. The angle is 0 pointing up, 90 to the right, clockwise.
 */
function directionOf(token: string): string | null {
  const a = angleDegrees(token);
  if (a !== null) return `${a}`;
  const w = token.trim().toLowerCase();
  if (!w.startsWith("to ")) return null;
  const sides = w.slice(3).trim().split(/\s+/);
  let x = 0, y = 0;
  for (const s of sides) {
    if (s === "left") x = -1;
    else if (s === "right") x = 1;
    else if (s === "top") y = -1;
    else if (s === "bottom") y = 1;
    else return null;
  }
  if (x === 0 && y === 0) return null;
  if (x !== 0 && y !== 0) return `C${x}:${y}`;
  // to top = 0deg, to right = 90deg, to bottom = 180deg, to left = 270deg.
  return `${(Math.atan2(x, -y) * (180 / Math.PI) + 360) % 360}`;
}

/** A position for a radial gradient's centre: a value, its unit, and whether it measures from
 * the far edge. `left`/`right`/`top`/`bottom`/`center` are their percentage equivalents. */
function centreOf(tokens: string[]): { v: number; u: number; edge: number }[] | null {
  const pct = (v: number, edge = 0) => ({ v, u: P.U_PCT, edge });
  const key = (t: string): { v: number; u: number; edge: number } | null => {
    if (t === "left") return pct(0);
    if (t === "right") return pct(0, 1);
    if (t === "top") return pct(0);
    if (t === "bottom") return pct(0, 1);
    if (t === "center") return pct(50);
    const l = parseLength(t, false);
    return l === null ? null : { v: l.v, u: l.u, edge: 0 };
  };
  if (tokens.length === 0) return [pct(50), pct(50)];
  if (tokens.length > 2) return null;
  const a = key(tokens[0]);
  if (a === null) return null;
  if (tokens.length === 1) {
    // One value is the horizontal position; the vertical one stays centred.
    if (tokens[0] === "top" || tokens[0] === "bottom") return [pct(50), a];
    return [a, pct(50)];
  }
  const b = key(tokens[1]);
  if (b === null) return null;
  // Two values: horizontal first, but `top left` style pairs are written either way round.
  const firstVertical = tokens[0] === "top" || tokens[0] === "bottom";
  return firstVertical ? [b, a] : [a, b];
}

/** One radial size keyword or length, as the encoding's value:unit field. */
function radialSize(token: string): { v: number; u: number } | null {
  const w = token.toLowerCase();
  if (w === "farthest-corner") return { v: 0, u: P.U_FARTHEST_CORNER };
  if (w === "closest-side") return { v: 0, u: P.U_CLOSEST_SIDE };
  if (w === "closest-corner") return { v: 0, u: P.U_CLOSEST_CORNER };
  if (w === "farthest-side") return { v: 0, u: P.U_FARTHEST_SIDE };
  const l = parseLength(token, false);
  return l === null ? null : { v: l.v, u: l.u };
}

/**
 * A gradient's colour interpolation method: `in <space>` and an optional `<hue> hue`. The tokens
 * start at `in`; `end` is the first token after the method.
 */
function interpolationAt(tokens: string[], at: number): { space: number; hue: number; end: number } | string | null {
  if (tokens[at] === undefined || tokens[at].toLowerCase() !== "in") return null;
  const name = tokens[at + 1];
  const space = name === undefined ? null : gradientSpaceId(name);
  if (space === null) return `unsupported gradient colour space '${name ?? ""}'`;
  let hue = HUE_SHORTER;
  let end = at + 2;
  if (tokens.length > end) {
    const method = gradientHueId(tokens[end]);
    if (method === null || tokens[end + 1] === undefined || tokens[end + 1].toLowerCase() !== "hue") {
      return `unsupported gradient colour interpolation '${tokens.slice(at).join(" ")}'`;
    }
    // Only a polar space has a hue arc to bend; CSS rejects the method on the others.
    if (!polarSpace(space)) return `unsupported gradient hue interpolation on '${name}'`;
    hue = method;
    end += 2;
  }
  if (tokens.length > end) return `unsupported gradient colour interpolation '${tokens.slice(at).join(" ")}'`;
  return { space, hue, end };
}

function linearGradient(args: string[]): GradientResult {
  let direction = "180"; // to bottom, the initial direction
  let space = CS_SRGB, hue = HUE_SHORTER;
  let i = 0;
  const first = args[0] === undefined ? "" : args[0];
  const d = directionOf(first);
  if (d !== null) {
    direction = d;
    i = 1;
  } else if (first !== "" && parseStop(first) === null) {
    // The prelude, `to right in oklab` say: a direction and/or an interpolation method, in either
    // order, before the first colour stop.
    const words = splitValue(first);
    i = 1;
    const at = words.findIndex((w) => w.toLowerCase() === "in");
    const dirWords = at < 0 ? words : words.slice(0, at);
    if (at >= 0) {
      const cim = interpolationAt(words, at);
      if (typeof cim === "string") return { error: cim };
      if (cim !== null) {
        space = cim.space;
        hue = cim.hue;
      }
    }
    if (dirWords.length > 0) {
      const dir = directionOf(dirWords.join(" "));
      if (dir === null) return { error: `unsupported linear-gradient() direction '${first}'` };
      direction = dir;
    } else if (at < 0) {
      return { error: `unsupported linear-gradient() direction '${first}'` };
    }
  }
  const stops: Stop[] = [];
  for (; i < args.length; i++) {
    const parsed = stopEntries(args[i], false);
    if (parsed === null) return { error: `unsupported gradient colour stop '${args[i]}'` };
    for (const s of parsed) stops.push(s);
  }
  const encoded = encodeStops(stops);
  if (encoded === null) return { error: "a gradient needs at least two colour stops" };
  return { encoded: `L|${direction}|${space}|${hue}|${encoded}` };
}

function radialGradient(args: string[]): GradientResult {
  // The prelude (shape, size, position) runs up to the first colour stop.
  let shape = 0; // ellipse, the initial shape
  let size: { v: number; u: number }[] = [];
  let at: string[] = [];
  let i = 0;
  const isStop = (t: string) => {
    const w = splitValue(t);
    return w.length > 0 && stopColor(w[0]) !== null;
  };
  const prelude: string[] = [];
  for (; i < args.length && !isStop(args[i]); i++) {
    for (const word of splitValue(args[i])) prelude.push(word);
  }
  // A colour interpolation method may sit anywhere in the prelude; take it out before the rest
  // is read as the shape, size and centre.
  let space = CS_SRGB, hue = HUE_SHORTER;
  const inAt = prelude.findIndex((w) => w.toLowerCase() === "in");
  if (inAt >= 0) {
    const cim = interpolationAt(prelude, inAt);
    if (typeof cim === "string") return { error: cim };
    if (cim !== null) {
      space = cim.space;
      hue = cim.hue;
      prelude.splice(inAt, cim.end - inAt);
    }
  }
  // `at` splits the prelude: everything before it sizes the gradient, after it is the centre.
  for (let k = 0; k < prelude.length; k++) {
    const w = prelude[k].toLowerCase();
    if (w === "circle") shape = 1;
    else if (w === "ellipse") shape = 0;
    else if (w === "at") { at = prelude.slice(k + 1); break; }
    else {
      const s = radialSize(prelude[k]);
      if (s === null) return { error: `unsupported radial-gradient() '${prelude[k]}'` };
      size.push(s);
    }
  }
  let rx: { v: number; u: number };
  let ry: { v: number; u: number };
  if (size.length === 0) {
    rx = { v: 0, u: P.U_FARTHEST_CORNER };
    ry = rx;
  } else if (size.length === 1) {
    if (shape === 1) {
      rx = size[0];
      ry = size[0];
    } else if (size[0].u !== P.U_FARTHEST_CORNER && size[0].u !== P.U_CLOSEST_SIDE &&
      size[0].u !== P.U_CLOSEST_CORNER && size[0].u !== P.U_FARTHEST_SIDE && size[0].u !== P.U_AUTO) {
      // One explicit length for an ellipse is its horizontal radius; the vertical one follows
      // the box's aspect, which a browser derives from the default farthest-corner ellipse.
      return { error: "one length for an ellipse needs an explicit vertical radius too" };
    } else {
      rx = size[0];
      ry = size[0];
    }
  } else {
    rx = size[0];
    ry = size[1];
  }
  const centre = centreOf(at);
  if (centre === null) return { error: "unsupported radial-gradient() position" };
  const stops: Stop[] = [];
  for (; i < args.length; i++) {
    const parsed = stopEntries(args[i], false);
    if (parsed === null) return { error: `unsupported gradient colour stop '${args[i]}'` };
    for (const s of parsed) stops.push(s);
  }
  const encoded = encodeStops(stops);
  if (encoded === null) return { error: "a gradient needs at least two colour stops" };
  const c = centre;
  const rxField = `${rx.v}:${rx.u}`;
  const ryField = `${ry.v}:${ry.u}`;
  const cx = `${c[0].v}:${c[0].u}:${c[0].edge}`;
  const cy = `${c[1].v}:${c[1].u}:${c[1].edge}`;
  return { encoded: `R|${shape}|${rxField}|${ryField}|${cx}|${cy}|${space}|${hue}|${encoded}` };
}

/**
 * A conic gradient: a turn around a centre, starting at `from <angle>` (0 = up, clockwise), with
 * stops that are shares of the turn. The stops go through the same parser as the other kinds, so
 * an angle there is a share of the turn too, and a bare position is a colour hint.
 */
function conicGradient(args: string[]): GradientResult {
  let angle = 0; // from 0deg, pointing up
  let at: string[] = [];
  let i = 0;
  const isStop = (t: string) => {
    const w = splitValue(t);
    return w.length > 0 && stopColor(w[0]) !== null;
  };
  // The prelude (`from <angle>`, `at <position>`) runs up to the first colour stop.
  const prelude: string[] = [];
  for (; i < args.length && !isStop(args[i]); i++) {
    for (const word of splitValue(args[i])) prelude.push(word);
  }
  let space = CS_SRGB, hue = HUE_SHORTER;
  const inAt = prelude.findIndex((w) => w.toLowerCase() === "in");
  if (inAt >= 0) {
    const cim = interpolationAt(prelude, inAt);
    if (typeof cim === "string") return { error: cim };
    if (cim !== null) {
      space = cim.space;
      hue = cim.hue;
      prelude.splice(inAt, cim.end - inAt);
    }
  }
  for (let k = 0; k < prelude.length; k++) {
    const w = prelude[k].toLowerCase();
    if (w === "from") {
      const a = angleDegrees(prelude[k + 1] === undefined ? "" : prelude[k + 1]);
      if (a === null) return { error: `unsupported conic-gradient() angle '${prelude[k + 1] ?? ""}'` };
      angle = a;
      k++;
    } else if (w === "at") {
      at = prelude.slice(k + 1);
      break;
    } else {
      return { error: `unsupported conic-gradient() '${prelude[k]}'` };
    }
  }
  const centre = centreOf(at);
  if (centre === null) return { error: "unsupported conic-gradient() position" };
  const stops: Stop[] = [];
  for (; i < args.length; i++) {
    const parsed = stopEntries(args[i], true);
    if (parsed === null) return { error: `unsupported gradient colour stop '${args[i]}'` };
    for (const s of parsed) stops.push(s);
  }
  const encoded = encodeStops(stops);
  if (encoded === null) return { error: "a gradient needs at least two colour stops" };
  const cx = `${centre[0].v}:${centre[0].u}:${centre[0].edge}`;
  const cy = `${centre[1].v}:${centre[1].u}:${centre[1].edge}`;
  return { encoded: `C|${angle}|${cx}|${cy}|${space}|${hue}|${encoded}` };
}

/** The encoded form of a gradient image token, or null when the token isn't a gradient. */
export function gradientImage(token: string): GradientResult | null {
  const m = /^(repeating-)?(linear|radial|conic)-gradient\(([\s\S]*)\)$/i.exec(token.trim());
  if (m === null) return null;
  const args = splitTopLevel(m[3]);
  const kind = m[2].toLowerCase();
  const r = kind === "linear" ? linearGradient(args) : kind === "radial" ? radialGradient(args) : conicGradient(args);
  if ("error" in r) return r;
  // A repeating gradient carries the same geometry; the runtime tiles its stops along the line.
  // The token's own text travels too: the encoding keeps the painter's numbers, not the words
  // (`repeating-`, a default direction written out), and CSSOM reads the image back from them.
  return { encoded: m[1] !== undefined ? `R${r.encoded}` : r.encoded, source: gradientCss(token.trim()) ?? token.trim() };
}

// ---------------------------------------------------------------------------
// The computed text of a gradient

/** A packed colour as the rgb()/rgba() text a computed gradient writes its stops in. */
function colourCss(c: number): string {
  const r = (c >>> 24) & 255, g = (c >>> 16) & 255, b = (c >>> 8) & 255, a = c & 255;
  if (a === 255) return "rgb(" + String(r) + ", " + String(g) + ", " + String(b) + ")";
  return "rgba(" + String(r) + ", " + String(g) + ", " + String(b) + ", " + String(Math.round((a / 255) * 1000) / 1000) + ")";
}

/** One stop as Chrome reads it back: its colour resolved, then the positions it names. */
function stopCss(token: string): string | null {
  const t = token.trim();
  if (t === "") return null;
  let i = 0;
  while (i < t.length && !/\s/.test(t[i])) {
    if (t[i] === "(") {
      let depth = 0;
      for (; i < t.length; i++) {
        if (t[i] === "(") depth++;
        else if (t[i] === ")") {
          depth--;
          if (depth === 0) { i++; break; }
        }
      }
      break;
    }
    i++;
  }
  const word = t.slice(0, i).trim();
  const rest = t.slice(i).trim();
  if (word.toLowerCase() === "currentcolor") return rest === "" ? "currentcolor" : "currentcolor " + rest;
  const c = parseColor(word);
  if (c === null) return null;
  return colourCss(c) + (rest === "" ? "" : " " + rest);
}

/**
 * A gradient the way CSSOM reads it back: its stops' colours resolved to rgb(), the prelude as
 * written except a radial's default centre, which Chrome leaves out. Null when the text isn't a
 * gradient this build understands.
 */
export function gradientCss(value: string): string | null {
  const m = /^([a-z-]+gradient)\(([\s\S]*)\)$/i.exec(value.trim());
  if (m === null) return null;
  const name = m[1].toLowerCase();
  const args = splitTopLevel(m[2]).map((a) => a.trim());
  const prelude: string[] = [];
  let at = 0;
  while (at < args.length && stopCss(args[at]) === null) prelude.push(args[at++]);
  const stops: string[] = [];
  for (; at < args.length; at++) {
    const s = stopCss(args[at]);
    if (s === null) return null;
    stops.push(s);
  }
  if (stops.length < 2) return null;
  let head = prelude.join(" ");
  if (name.indexOf("radial") >= 0) {
    // The default centre is left out, whether or not an interpolation method follows it.
    head = head.replace(/\s*at\s+50%\s+50%(?=\s+in\s|$)/, "").trim();
  }
  return name + "(" + (head === "" ? "" : head + ", ") + stops.join(", ") + ")";
}

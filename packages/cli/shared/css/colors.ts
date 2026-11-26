// Color parsing, packed as 0xRRGGBBAA. Colors are first read as unpremultiplied sRGB components
// in 0..1 so that color-mix() can interpolate them in any of the spaces it names; the packed
// 8-bit form is what the rest of native stores.


// ---------------------------------------------------------------------------
// Colors, packed as 0xRRGGBBAA

// The named colors of CSS Color 4 §6.1, and `transparent`. A name outside this table is invalid,
// not a feature native lacks.
const NAMED_COLORS: Record<string, string> = {
  aliceblue: "#f0f8ff", antiquewhite: "#faebd7", aqua: "#00ffff", aquamarine: "#7fffd4", azure: "#f0ffff",
  beige: "#f5f5dc", bisque: "#ffe4c4", black: "#000000", blanchedalmond: "#ffebcd", blue: "#0000ff",
  blueviolet: "#8a2be2", brown: "#a52a2a", burlywood: "#deb887", cadetblue: "#5f9ea0", chartreuse: "#7fff00",
  chocolate: "#d2691e", coral: "#ff7f50", cornflowerblue: "#6495ed", cornsilk: "#fff8dc", crimson: "#dc143c",
  cyan: "#00ffff", darkblue: "#00008b", darkcyan: "#008b8b", darkgoldenrod: "#b8860b", darkgray: "#a9a9a9",
  darkgreen: "#006400", darkgrey: "#a9a9a9", darkkhaki: "#bdb76b", darkmagenta: "#8b008b", darkolivegreen: "#556b2f",
  darkorange: "#ff8c00", darkorchid: "#9932cc", darkred: "#8b0000", darksalmon: "#e9967a", darkseagreen: "#8fbc8f",
  darkslateblue: "#483d8b", darkslategray: "#2f4f4f", darkslategrey: "#2f4f4f", darkturquoise: "#00ced1",
  darkviolet: "#9400d3", deeppink: "#ff1493", deepskyblue: "#00bfff", dimgray: "#696969", dimgrey: "#696969",
  dodgerblue: "#1e90ff", firebrick: "#b22222", floralwhite: "#fffaf0", forestgreen: "#228b22", fuchsia: "#ff00ff",
  gainsboro: "#dcdcdc", ghostwhite: "#f8f8ff", gold: "#ffd700", goldenrod: "#daa520", gray: "#808080",
  green: "#008000", greenyellow: "#adff2f", grey: "#808080", honeydew: "#f0fff0", hotpink: "#ff69b4",
  indianred: "#cd5c5c", indigo: "#4b0082", ivory: "#fffff0", khaki: "#f0e68c", lavender: "#e6e6fa",
  lavenderblush: "#fff0f5", lawngreen: "#7cfc00", lemonchiffon: "#fffacd", lightblue: "#add8e6", lightcoral: "#f08080",
  lightcyan: "#e0ffff", lightgoldenrodyellow: "#fafad2", lightgray: "#d3d3d3", lightgreen: "#90ee90", lightgrey: "#d3d3d3",
  lightpink: "#ffb6c1", lightsalmon: "#ffa07a", lightseagreen: "#20b2aa", lightskyblue: "#87cefa", lightslategray: "#778899",
  lightslategrey: "#778899", lightsteelblue: "#b0c4de", lightyellow: "#ffffe0", lime: "#00ff00", limegreen: "#32cd32",
  linen: "#faf0e6", magenta: "#ff00ff", maroon: "#800000", mediumaquamarine: "#66cdaa", mediumblue: "#0000cd",
  mediumorchid: "#ba55d3", mediumpurple: "#9370db", mediumseagreen: "#3cb371", mediumslateblue: "#7b68ee",
  mediumspringgreen: "#00fa9a", mediumturquoise: "#48d1cc", mediumvioletred: "#c71585", midnightblue: "#191970",
  mintcream: "#f5fffa", mistyrose: "#ffe4e1", moccasin: "#ffe4b5", navajowhite: "#ffdead", navy: "#000080",
  oldlace: "#fdf5e6", olive: "#808000", olivedrab: "#6b8e23", orange: "#ffa500", orangered: "#ff4500",
  orchid: "#da70d6", palegoldenrod: "#eee8aa", palegreen: "#98fb98", paleturquoise: "#afeeee", palevioletred: "#db7093",
  papayawhip: "#ffefd5", peachpuff: "#ffdab9", peru: "#cd853f", pink: "#ffc0cb", plum: "#dda0dd",
  powderblue: "#b0e0e6", purple: "#800080", rebeccapurple: "#663399", red: "#ff0000", rosybrown: "#bc8f8f",
  royalblue: "#4169e1", saddlebrown: "#8b4513", salmon: "#fa8072", sandybrown: "#f4a460", seagreen: "#2e8b57",
  seashell: "#fff5ee", sienna: "#a0522d", silver: "#c0c0c0", skyblue: "#87ceeb", slateblue: "#6a5acd",
  slategray: "#708090", slategrey: "#708090", snow: "#fffafa", springgreen: "#00ff7f", steelblue: "#4682b4",
  tan: "#d2b48c", teal: "#008080", thistle: "#d8bfd8", tomato: "#ff6347", turquoise: "#40e0d0",
  violet: "#ee82ee", wheat: "#f5deb3", white: "#ffffff", whitesmoke: "#f5f5f5", yellow: "#ffff00",
  yellowgreen: "#9acd32", transparent: "#00000000",
};

export function pack(r: number, g: number, b: number, a: number): number {
  const c = (x: number) => Math.max(0, Math.min(255, Math.round(x)));
  return ((c(r) << 24) | (c(g) << 16) | (c(b) << 8) | c(a)) >>> 0;
}

/** An sRGB color: gamma-encoded components and alpha, each in 0..1, not premultiplied. */
interface Rgba { r: number; g: number; b: number; a: number }

export function parseColor(value: string): number | null {
  const c = parseColorRgba(value);
  return c === null ? null : pack(c.r * 255, c.g * 255, c.b * 255, c.a * 255);
}

function parseColorRgba(value: string): Rgba | null {
  const s = value.trim().toLowerCase().replace(/\s+/g, " ");
  const named = NAMED_COLORS[s];
  if (named !== undefined) return parseColorRgba(named);
  if (s[0] === "#") {
    const h = s.slice(1);
    if (!/^[0-9a-f]+$/.test(h)) return null;
    if (h.length === 3 || h.length === 4) {
      const d = [...h].map((x) => parseInt(x + x, 16));
      return { r: d[0] / 255, g: d[1] / 255, b: d[2] / 255, a: (d[3] ?? 255) / 255 };
    }
    if (h.length === 6 || h.length === 8) {
      const d = [0, 2, 4, 6].map((k) => (k < h.length ? parseInt(h.slice(k, k + 2), 16) : 255));
      return { r: d[0] / 255, g: d[1] / 255, b: d[2] / 255, a: d[3] / 255 };
    }
    return null;
  }
  if (s.startsWith("color-mix(")) return parseColorMix(s);
  const relative = splitRelative(s);
  if (relative !== null) return parseRelativeColor(relative.fn, relative.origin, relative.rest);
  const cc = /^contrast-color\((.*)\)$/.exec(s);
  if (cc !== null) {
    // The algorithm is the UA's; black or white, whichever contrasts more with the color given.
    const inner = parseColorRgba(cc[1].trim());
    if (inner === null) return null;
    const luminance = 0.2126 * srgbToLinear(inner.r) + 0.7152 * srgbToLinear(inner.g) + 0.0722 * srgbToLinear(inner.b);
    return luminance > 0.4 ? { r: 0, g: 0, b: 0, a: 1 } : { r: 1, g: 1, b: 1, a: 1 };
  }
  const h = /^hsla?\((.*)\)$/.exec(s);
  if (h) {
    const parts = h[1].split(/[\s,/]+/).filter(Boolean);
    if (parts.length < 3 || parts.length > 4) return null;
    const hue = isNone(parts[0]) ? 0 : ((parseFloat(parts[0]) % 360) + 360) % 360;
    // CSS clamps saturation and lightness to 0..100% at parse time; a hue wraps.
    const sat = isNone(parts[1]) ? 0 : Math.max(0, Math.min(100, parseFloat(parts[1]))) / 100;
    const light = isNone(parts[2]) ? 0 : Math.max(0, Math.min(100, parseFloat(parts[2]))) / 100;
    const a = parts[3] === undefined ? 1 : alphaOf(parts[3]);
    if ([hue, sat, light, a].some((x) => x === null || !Number.isFinite(x))) return null;
    const c = (1 - Math.abs(2 * light - 1)) * sat;
    const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
    const m0 = light - c / 2;
    const seg = Math.floor(hue / 60) % 6;
    const rgb = seg === 0 ? [c, x, 0] : seg === 1 ? [x, c, 0] : seg === 2 ? [0, c, x]
      : seg === 3 ? [0, x, c] : seg === 4 ? [x, 0, c] : [c, 0, x];
    return { r: rgb[0] + m0, g: rgb[1] + m0, b: rgb[2] + m0, a: a as number };
  }
  const hw = /^hwb\((.*)\)$/.exec(s);
  if (hw) {
    const parts = hw[1].split(/[\s,/]+/).filter(Boolean);
    if (parts.length < 3 || parts.length > 4) return null;
    const hue = isNone(parts[0]) ? 0 : ((parseFloat(parts[0]) % 360) + 360) % 360;
    // Whiteness and blackness are clamped to 0..100% at parse time.
    const w = isNone(parts[1]) ? 0 : Math.max(0, Math.min(100, parseFloat(parts[1]))) / 100;
    const bl = isNone(parts[2]) ? 0 : Math.max(0, Math.min(100, parseFloat(parts[2]))) / 100;
    const a = parts[3] === undefined ? 1 : alphaOf(parts[3]);
    if ([hue, w, bl, a].some((x) => x === null || !Number.isFinite(x))) return null;
    const rgb = hwbToRgb(hue, w, bl);
    return { r: rgb[0], g: rgb[1], b: rgb[2], a: a as number };
  }
  const m = /^rgba?\((.*)\)$/.exec(s);
  if (m) {
    const parts = m[1].split(/[\s,/]+/).filter(Boolean);
    if (parts.length < 3 || parts.length > 4) return null;
    // A channel is a number in 0..255, or a percentage of 255.
    const ch = (x: string) => (isNone(x) ? 0 : x.endsWith("%") ? parseFloat(x) / 100 : parseFloat(x) / 255);
    const r = ch(parts[0]), g = ch(parts[1]), b = ch(parts[2]);
    const a = parts[3] === undefined ? 1 : alphaOf(parts[3]);
    if ([r, g, b, a].some((x) => x === null || !Number.isFinite(x))) return null;
    return { r, g, b, a: a as number };
  }
  const lab = /^(oklch|oklab|lch|lab)\((.*)\)$/.exec(s);
  if (lab) return parseLab(lab[1], lab[2]);
  const fn = /^color\((.*)\)$/.exec(s);
  if (fn) return parseColorFn(fn[1]);
  return null;
}

// --- relative colours -------------------------------------------------------

/** The channel names a relative colour function exposes, or null when it has none. */
function relativeChannelNames(fn: string, space: string): string[] | null {
  switch (fn) {
    case "rgb": return ["r", "g", "b"];
    case "hsl": return ["h", "s", "l"];
    case "hwb": return ["h", "w", "b"];
    case "lab": case "oklab": return ["l", "a", "b"];
    case "lch": case "oklch": return ["l", "c", "h"];
    case "color":
      return space === "xyz" || space === "xyz-d50" || space === "xyz-d65"
        ? ["x", "y", "z"] : ["r", "g", "b"];
    default: return null;
  }
}

/**
 * `fn(from <origin colour> <channels> [/ <alpha>])`, with the function name normalized to the
 * longhand spelling. The origin is one token: a colour function with its own parentheses, or a
 * bare name.
 */
function splitRelative(s: string): { fn: string; origin: string; rest: string } | null {
  const m = /^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\s+/.exec(s);
  if (m === null || !s.endsWith(")")) return null;
  const body = s.slice(m[0].length, s.length - 1);
  let i = 0, depth = 0;
  for (; i < body.length; i++) {
    const c = body[i];
    if (c === "(") depth++;
    else if (c === ")") { if (depth > 0) depth--; }
    else if (depth === 0 && (c === " " || c === "\t")) break;
  }
  const origin = body.slice(0, i).trim();
  const rest = body.slice(i).trim();
  if (origin === "" || rest === "") return null;
  const fn = m[1] === "rgba" ? "rgb" : m[1] === "hsla" ? "hsl" : m[1];
  return { fn, origin, rest };
}

/** The origin colour's own coordinates in the function's space, as CSS text for each channel. */
function relativeCoords(fn: string, c: Rgba): string[] | null {
  switch (fn) {
    case "rgb": return [formNumber(c.r * 255), formNumber(c.g * 255), formNumber(c.b * 255)];
    case "hsl": {
      const q = hslOf(c);
      return [formNumber(q[0]), formNumber(q[1] * 100) + "%", formNumber(q[2] * 100) + "%"];
    }
    case "hwb": {
      const q = hwbOf(c);
      return [formNumber(q[0]), formNumber(q[1] * 100) + "%", formNumber(q[2] * 100) + "%"];
    }
    case "lab": {
      const q = srgbToLab(c);
      return [formNumber(q[0]), formNumber(q[1]), formNumber(q[2])];
    }
    case "lch": {
      const q = polar(srgbToLab(c));
      return [formNumber(q[0]), formNumber(q[1]), formNumber(q[2])];
    }
    case "oklab": {
      const q = srgbToOklab(c);
      return [formNumber(q[0]), formNumber(q[1]), formNumber(q[2])];
    }
    case "oklch": {
      const q = polar(srgbToOklab(c));
      return [formNumber(q[0]), formNumber(q[1]), formNumber(q[2])];
    }
    // A color() function's channels are the origin's coordinates in that space; an identity set
    // is the origin colour itself, which is the only form handled without the space's inverse.
    default: return null;
  }
}

/**
 * A relative colour (CSS Color 5): its channels name the origin colour's coordinates, so the
 * identity set is the origin colour itself. Any other simple set is rebuilt as the same function
 * over those coordinates and parsed again.
 */
function parseRelativeColor(fn: string, originText: string, rest: string): Rgba | null {
  const origin = parseColorRgba(originText);
  if (origin === null) return null;
  let space = "";
  if (fn === "color") {
    const at = rest.indexOf(" ");
    if (at < 0) return null;
    space = rest.slice(0, at).trim();
    rest = rest.slice(at + 1).trim();
  }
  let alphaText: string | null = null;
  const slash = rest.indexOf("/");
  if (slash >= 0) {
    alphaText = rest.slice(slash + 1).trim();
    rest = rest.slice(0, slash).trim();
  }
  const names = relativeChannelNames(fn, space);
  if (names === null) return null;
  const toks = rest.split(/\s+/).filter((t) => t !== "");
  if (toks.length !== 3) return null;
  const alpha = alphaText === null || alphaText === "alpha" ? origin.a : alphaOf(alphaText);
  if (alpha === null) return null;
  if (toks[0] === names[0] && toks[1] === names[1] && toks[2] === names[2]) {
    return { ...origin, a: alpha };
  }
  const coords = relativeCoords(fn, origin);
  if (coords === null) return null;
  const picked: string[] = [];
  for (let k = 0; k < 3; k++) {
    const at = names.indexOf(toks[k]);
    if (at >= 0) picked.push(coords[at]);
    else if (/^[-+]?(\d+\.?\d*|\.\d+)%?$/.test(toks[k])) picked.push(toks[k]);
    else return null;
  }
  const text = fn + "(" + (fn === "color" ? space + " " : "") + picked.join(" ") +
    (alpha !== 1 ? " / " + formNumber(alpha) : "") + ")";
  return parseColorRgba(text);
}

// --- color() -----------------------------------------------------------------

/**
 * `color(<space> c1 c2 c3 [/ alpha])`, converted to sRGB the way a browser draws it on an sRGB
 * surface: each space's gamma is undone, its matrix takes the channels to XYZ, and XYZ D65 maps
 * to linear sRGB, whose transfer function and clipping finish the job. ProPhoto's white point is
 * D50, so its XYZ takes the same Bradford adaptation lab() does; XYZ is not clamped to 0..1 the
 * way the RGB spaces are (CSS Color 4 clamps their channels before converting).
 */
function parseColorFn(inner: string): Rgba | null {
  const slash = inner.indexOf("/");
  const main = slash < 0 ? inner : inner.slice(0, slash);
  const alpha = slash < 0 ? 1 : alphaOf(inner.slice(slash + 1).trim());
  if (alpha === null) return null;
  const parts = main.trim().split(/[\s,]+/).filter(Boolean);
  if (parts.length !== 4) return null;
  const space = parts[0].toLowerCase();
  const ch: number[] = [];
  for (let i = 1; i <= 3; i++) {
    const t = parts[i];
    if (isNone(t)) {
      ch.push(0);
      continue;
    }
    const v = parseFloat(t);
    if (!Number.isFinite(v)) return null;
    ch.push(t.endsWith("%") ? v / 100 : v);
  }
  const lin = colorToLinearSrgb(space, ch[0], ch[1], ch[2]);
  if (lin === null) return null;
  return { r: clamp01(linearToSrgb(lin[0])), g: clamp01(linearToSrgb(lin[1])), b: clamp01(linearToSrgb(lin[2])), a: alpha };
}

/** A linear channel put back through its space's transfer function (the inverse of gammaOf). */
function rec2020Gamma(c: number): number {
  const A = 1.09929682680944, B = 0.018053968510807;
  return Math.abs(c) < B * 4.5 ? c / 4.5 : Math.sign(c) * Math.pow((Math.abs(c) + A - 1) / A, 1 / 0.45);
}

/** `color()`'s channels as linear-light sRGB, or null for an unknown space. */
function colorToLinearSrgb(space: string, c0: number, c1: number, c2: number): [number, number, number] | null {
  const clampRgb = (x: number): number => clamp01(x);
  let X: number, Y: number, Z: number;
  switch (space) {
    case "srgb": {
      const r = srgbToLinear(clampRgb(c0)), g = srgbToLinear(clampRgb(c1)), b = srgbToLinear(clampRgb(c2));
      return [r, g, b];
    }
    case "srgb-linear": {
      const r = clampRgb(c0), g = clampRgb(c1), b = clampRgb(c2);
      return [r, g, b];
    }
    case "display-p3": {
      const r = srgbToLinear(clampRgb(c0)), g = srgbToLinear(clampRgb(c1)), b = srgbToLinear(clampRgb(c2));
      X = 0.4865709486482162 * r + 0.26566769316909306 * g + 0.1982172852343625 * b;
      Y = 0.2289745640697488 * r + 0.6917385218365064 * g + 0.079286914093745 * b;
      Z = 0.0 * r + 0.04511338185890264 * g + 1.043944368900976 * b;
      break;
    }
    case "display-p3-linear": {
      // The same primaries as display-p3, with its transfer function already undone.
      const r = clampRgb(c0), g = clampRgb(c1), b = clampRgb(c2);
      X = 0.4865709486482162 * r + 0.26566769316909306 * g + 0.1982172852343625 * b;
      Y = 0.2289745640697488 * r + 0.6917385218365064 * g + 0.079286914093745 * b;
      Z = 0.0 * r + 0.04511338185890264 * g + 1.043944368900976 * b;
      break;
    }
    case "a98-rgb": {
      const gamma = (c: number): number => Math.sign(c) * Math.pow(Math.abs(clampRgb(c)), 563 / 256);
      const r = gamma(c0), g = gamma(c1), b = gamma(c2);
      X = 0.5766690429101305 * r + 0.1855582379065463 * g + 0.1882286462349947 * b;
      Y = 0.29734497525053605 * r + 0.6273635662554661 * g + 0.07529145849399788 * b;
      Z = 0.02703136138641234 * r + 0.07068885253582723 * g + 0.9913375368376388 * b;
      break;
    }
    case "prophoto-rgb": {
      const Et = 16 / 512;
      const gamma = (c: number): number => {
        const v = clampRgb(c);
        return Math.abs(v) <= Et ? v / 16 : Math.sign(v) * Math.pow(Math.abs(v), 1.8);
      };
      const r = gamma(c0), g = gamma(c1), b = gamma(c2);
      const x = 0.7977604896723027 * r + 0.13518583717574031 * g + 0.0313493495815248 * b;
      const y = 0.2880711282292934 * r + 0.7118432178101014 * g + 0.00008565396060525902 * b;
      const z = 0.0 * r + 0.0 * g + 0.8251046025104601 * b;
      // D50 to D65, the Bradford adaptation lab() uses.
      X = 0.9554734215 * x - 0.0230984549 * y + 0.0632592432 * z;
      Y = -0.0283697093 * x + 1.0099953981 * y + 0.0210414412 * z;
      Z = 0.0123140149 * x - 0.0205076493 * y + 1.3303659262 * z;
      break;
    }
    case "rec2020": {
      const r = rec2020Gamma(clampRgb(c0)), g = rec2020Gamma(clampRgb(c1)), b = rec2020Gamma(clampRgb(c2));
      X = 0.6369580483012914 * r + 0.14461690358620832 * g + 0.1688809751641721 * b;
      Y = 0.2627002120112671 * r + 0.6779980715188708 * g + 0.05930171646986196 * b;
      Z = 0.0 * r + 0.028072693049087428 * g + 1.060985057710791 * b;
      break;
    }
    case "xyz":
    case "xyz-d65":
      X = c0; Y = c1; Z = c2;
      break;
    case "xyz-d50": {
      X = 0.9554734215 * c0 - 0.0230984549 * c1 + 0.0632592432 * c2;
      Y = -0.0283697093 * c0 + 1.0099953981 * c1 + 0.0210414412 * c2;
      Z = 0.0123140149 * c0 - 0.0205076493 * c1 + 1.3303659262 * c2;
      break;
    }
    default:
      return null;
  }
  return [
    3.2409699419 * X - 1.5373831776 * Y - 0.4986107603 * Z,
    -0.9692436363 * X + 1.8759675015 * Y + 0.0415550574 * Z,
    0.0556300797 * X - 0.2039769589 * Y + 1.0569715142 * Z,
  ];
}

/** An alpha component: a number in 0..1, or a percentage of it. Null when it doesn't parse. */
function alphaOf(t: string): number | null {
  if (isNone(t)) return 0;
  const v = parseFloat(t);
  if (!Number.isFinite(v)) return null;
  return Math.max(0, Math.min(1, t.endsWith("%") ? v / 100 : v));
}

/** A hue: a number of degrees, or a deg/grad/rad/turn angle. Null when it doesn't parse. */
function hueOf(t: string): number | null {
  const m = /^(-?[\d.]+(?:e[+-]?\d+)?)(deg|grad|rad|turn)?$/.exec(t);
  if (m === null) return null;
  const v = parseFloat(m[1]);
  const unit = m[2] ?? "deg";
  const deg = unit === "grad" ? v * 0.9 : unit === "rad" ? (v * 180) / Math.PI : unit === "turn" ? v * 360 : v;
  return ((deg % 360) + 360) % 360;
}

/** A component written as `none`: CSS Color 4's missing component, which paints as zero. */
function isNone(t: string): boolean {
  return t.trim().toLowerCase() === "none";
}

/** A number that may be a percentage of `scale`. Null when it doesn't parse. */
function numOrPct(t: string, scale: number): number | null {
  const v = parseFloat(t);
  if (!Number.isFinite(v)) return null;
  return t.endsWith("%") ? (v / 100) * scale : v;
}

/**
 * oklab(), oklch(), lab() and lch(): the components are converted to sRGB through XYZ where the
 * function names a CIE space. `lab` and `lch` use the D50 white point, as the spec defines them,
 * and the conversion makes up for the difference with sRGB's D65.
 */
function parseLab(fn: string, inner: string): Rgba | null {
  const slash = inner.indexOf("/");
  let main = inner;
  if (slash >= 0) main = inner.slice(0, slash);
  main = main.trim();
  let alpha: number | null = 1;
  if (slash >= 0) alpha = alphaOf(inner.slice(slash + 1).trim());
  if (alpha === null) return null;
  const parts = main.split(/[\s,]+/).filter(Boolean);
  if (parts.length !== 3) return null;
  const polar = fn === "oklch" || fn === "lch";
  const ok = fn === "oklab" || fn === "oklch";
  const L = isNone(parts[0]) ? 0 : numOrPct(parts[0], ok ? 1 : 100);
  if (L === null) return null;
  // Lightness is clamped to its space's range, where the ends are white and black; a and b (or
  // chroma) are not clamped, and a colour out of the display's gamut is clipped to it.
  const light = Math.max(0, Math.min(ok ? 1 : 100, L));
  let a: number | null, b: number | null;
  if (polar) {
    const C = isNone(parts[1]) ? 0 : numOrPct(parts[1], ok ? 0.4 : 150);
    const H = isNone(parts[2]) ? 0 : hueOf(parts[2]);
    if (C === null || H === null) return null;
    const rad = (H * Math.PI) / 180;
    a = C * Math.cos(rad);
    b = C * Math.sin(rad);
  } else {
    a = isNone(parts[1]) ? 0 : numOrPct(parts[1], ok ? 0.4 : 125);
    b = isNone(parts[2]) ? 0 : numOrPct(parts[2], ok ? 0.4 : 125);
    if (a === null || b === null) return null;
  }
  const rgb = ok ? oklabToSrgb(light, a, b) : labToSrgb(light, a, b);
  const ends = lightnessExtreme(light, ok ? 1 : 100, alpha);
  if (ends !== null) return ends;
  return { r: clamp01(rgb[0]), g: clamp01(rgb[1]), b: clamp01(rgb[2]), a: alpha };
}

// --- Color space conversions -------------------------------------------------

const clamp01 = (x: number): number => Math.max(0, Math.min(1, x));

/**
 * Lightness at the ends of its range is white or black whatever the other components say: CSS
 * Color 4 gives lab(100 150 20) and lch(100% 110 60) the colour of white, and browsers paint it
 * so. Everywhere else a colour sRGB can't show is clipped to the display's gamut, which is what
 * Chrome does with color(display-p3 1 0 0) on an sRGB display.
 */
function lightnessExtreme(light: number, max: number, a: number): Rgba | null {
  if (light >= max) return { r: 1, g: 1, b: 1, a };
  if (light <= 0) return { r: 0, g: 0, b: 0, a };
  return null;
}

function srgbToLinear(c: number): number {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function linearToSrgb(c: number): number {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

/** OKLab to linear-light sRGB (Björn Ottosson's matrices). */
function oklabToLinear(L: number, a: number, b: number): [number, number, number] {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

function linearToOklab(r: number, g: number, b: number): [number, number, number] {
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

function oklabToSrgb(L: number, a: number, b: number): [number, number, number] {
  const [r, g, bl] = oklabToLinear(L, a, b);
  return [linearToSrgb(r), linearToSrgb(g), linearToSrgb(bl)];
}

function srgbToOklab(c: Rgba): [number, number, number] {
  return linearToOklab(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
}

const D50: [number, number, number] = [0.96422, 1.0, 0.82521];
const LAB_EPS = 216 / 24389;
const LAB_KAPPA = 24389 / 27;

/** CIE Lab (D50) to linear-light sRGB. */
function labToLinear(L: number, a: number, b: number): [number, number, number] {
  const fy = (L + 16) / 116;
  const fx = fy + a / 500;
  const fz = fy - b / 200;
  const f = (t: number): number => {
    const t3 = t * t * t;
    return t3 > LAB_EPS ? t3 : (116 * t - 16) / LAB_KAPPA;
  };
  const x = f(fx) * D50[0], y = f(fy) * D50[1], z = f(fz) * D50[2];
  // Bradford chromatic adaptation from D50 to D65.
  const X = 0.9554734215 * x - 0.0230984549 * y + 0.0632592432 * z;
  const Y = -0.0283697093 * x + 1.0099953981 * y + 0.0210414412 * z;
  const Z = 0.0123140149 * x - 0.0205076493 * y + 1.3303659262 * z;
  return [
    3.2409699419 * X - 1.5373831776 * Y - 0.4986107603 * Z,
    -0.9692436363 * X + 1.8759675015 * Y + 0.0415550574 * Z,
    0.0556300797 * X - 0.2039769589 * Y + 1.0569715142 * Z,
  ];
}

function labToSrgb(L: number, a: number, b: number): [number, number, number] {
  const [r, g, bl] = labToLinear(L, a, b);
  return [linearToSrgb(r), linearToSrgb(g), linearToSrgb(bl)];
}

function srgbToLab(c: Rgba): [number, number, number] {
  const r = srgbToLinear(c.r), g = srgbToLinear(c.g), b = srgbToLinear(c.b);
  // Linear sRGB to XYZ D65: the exact inverse of the matrix labToLinear ends with. (It used to
  // carry that matrix's rows instead, so a lab() mix came out wildly negative.)
  const X = 0.4123907993 * r + 0.3575843394 * g + 0.1804807884 * b;
  const Y = 0.2126390059 * r + 0.7151686788 * g + 0.0721923154 * b;
  const Z = 0.0193308187 * r + 0.1191947798 * g + 0.9505321522 * b;
  // D65 to D50, the inverse of the adaptation above.
  const x = 1.0479298208 * X + 0.0229467933 * Y - 0.0501922295 * Z;
  const y = 0.0296278157 * X + 0.9904344846 * Y - 0.0170738250 * Z;
  const z = -0.0092430582 * X + 0.0150551449 * Y + 0.7518742900 * Z;
  const f = (t: number): number => (t > LAB_EPS ? Math.cbrt(t) : (LAB_KAPPA * t + 16) / 116);
  const fx = f(x / D50[0]), fy = f(y / D50[1]), fz = f(z / D50[2]);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

// --- color-mix() -------------------------------------------------------------

/** Splits on commas that are not inside parentheses or strings. */
function splitArgs(s: string): string[] {
  const out: string[] = [];
  let depth = 0, start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === "," && depth === 0) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  }
  out.push(s.slice(start));
  return out;
}

/** Interpolates hue along the shorter arc, which is the default. */
function mixHue(h1: number, h2: number, t: number): number {
  const d = ((h2 - h1 + 540) % 360) - 180;
  return ((h1 + d * t) % 360 + 360) % 360;
}

function polar(lab: [number, number, number]): [number, number, number] {
  const [L, a, b] = lab;
  const h = ((Math.atan2(b, a) * 180) / Math.PI + 360) % 360;
  return [L, Math.hypot(a, b), h];
}

/**
 * color-mix(in <space>, <color> [<percentage>], <color> [<percentage>]). The colors are mixed
 * premultiplied by their alpha, and a hue follows the shorter arc. Spaces: srgb, srgb-linear,
 * oklab, oklch, lab, lch (and their aliases as spelled in the spec).
 */
/** A color-mix() interpolated in its space: the components there, in that space's own numbers. */
interface MixResult {
  space: string;
  comps: [number, number, number];
  alpha: number;
}

/**
 * color-mix()'s weight per side and the alpha-weighted share each side takes, from `in <space>`
 * and the two colour arguments. Null when the value isn't a well-formed mix of two colours.
 */
function mixEnds(s: string): { space: string; e1: Rgba; e2: Rgba; w1: number; w2: number; alpha: number } | null {
  const inner = s.slice("color-mix(".length, s.length - 1);
  const args = splitArgs(inner);
  if (args.length !== 3) return null;
  const first = args[0].trim();
  if (!first.startsWith("in ")) return null;
  const space = first.slice(3).trim().split(/\s+/)[0];
  const parsed = [args[1], args[2]].map((raw) => {
    // CSS allows a percentage to follow a colour function's `)` with no space between them, and
    // Tailwind's opacity utilities write it that way ("oklch(…)15%"); give the split below the
    // space it looks for.
    const t = raw.trim().replace(/\)(-?[\d.]+%)$/, ") $1");
    const m = /^(.*?)(?:\s+(-?[\d.]+%))?$/.exec(t);
    if (m === null) return null;
    const color = parseColorRgba(m[1]);
    if (color === null) return null;
    return { color, pct: m[2] === undefined ? null : parseFloat(m[2]) / 100 };
  });
  const e1 = parsed[0], e2 = parsed[1];
  if (e1 === null || e2 === null) return null;
  const q1 = e1.pct, q2 = e2.pct;
  let p1: number, p2: number;
  if (q1 === null && q2 === null) { p1 = 0.5; p2 = 0.5; }
  else if (q1 === null) { p2 = q2 as number; p1 = 1 - p2; }
  else if (q2 === null) { p1 = q1; p2 = 1 - p1; }
  else { p1 = q1; p2 = q2; }
  const sum = p1 + p2;
  if (!(sum > 0)) return null;
  p1 /= sum;
  p2 /= sum;
  const a1 = e1.color.a, a2 = e2.color.a;
  const alpha = a1 * p1 + a2 * p2;
  if (alpha === 0) return { space, e1: { r: 0, g: 0, b: 0, a: 0 }, e2: { r: 0, g: 0, b: 0, a: 0 }, w1: 0, w2: 0, alpha: 0 };
  return { space, e1: e1.color, e2: e2.color, w1: (a1 * p1) / alpha, w2: (a2 * p2) / alpha, alpha };
}

/** A color-mix() interpolated in its own space, its components in that space's numbers. */
function mixInSpace(s: string): MixResult | null {
  const ends = mixEnds(s);
  if (ends === null) return null;
  const { space, e1, e2, w1, w2, alpha } = ends;
  const mix = (c1: number, c2: number): number => c1 * w1 + c2 * w2;
  switch (space) {
    case "srgb":
      return { space, comps: [mix(e1.r, e2.r), mix(e1.g, e2.g), mix(e1.b, e2.b)], alpha };
    case "srgb-linear":
      return {
        space,
        comps: [
          mix(srgbToLinear(e1.r), srgbToLinear(e2.r)),
          mix(srgbToLinear(e1.g), srgbToLinear(e2.g)),
          mix(srgbToLinear(e1.b), srgbToLinear(e2.b)),
        ],
        alpha,
      };
    case "oklab":
    case "oklch": {
      const c1 = srgbToOklab(e1), c2 = srgbToOklab(e2);
      if (space === "oklab") return { space, comps: [mix(c1[0], c2[0]), mix(c1[1], c2[1]), mix(c1[2], c2[2])], alpha };
      const l1 = polar(c1), l2 = polar(c2);
      return { space, comps: [mix(l1[0], l2[0]), mix(l1[1], l2[1]), mixHue(l1[2], l2[2], w2)], alpha };
    }
    case "lab":
    case "lch": {
      const c1 = srgbToLab(e1), c2 = srgbToLab(e2);
      if (space === "lab") return { space, comps: [mix(c1[0], c2[0]), mix(c1[1], c2[1]), mix(c1[2], c2[2])], alpha };
      const l1 = polar(c1), l2 = polar(c2);
      return { space, comps: [mix(l1[0], l2[0]), mix(l1[1], l2[1]), mixHue(l1[2], l2[2], w2)], alpha };
    }
    default:
      return null;
  }
}

/** A color-mix() and the sRGB colour it paints. */
function parseColorMix(s: string): Rgba | null {
  const mix = mixInSpace(s);
  if (mix === null) return null;
  const [c0, c1, c2] = mix.comps;
  let out: [number, number, number];
  switch (mix.space) {
    case "srgb":
      out = [c0, c1, c2];
      break;
    case "srgb-linear":
      out = [linearToSrgb(c0), linearToSrgb(c1), linearToSrgb(c2)];
      break;
    case "oklab":
      out = oklabToSrgb(c0, c1, c2);
      break;
    case "oklch":
      out = oklabToSrgb(c0, c1 * Math.cos((c2 * Math.PI) / 180), c1 * Math.sin((c2 * Math.PI) / 180));
      break;
    case "lab":
      out = labToSrgb(c0, c1, c2);
      break;
    case "lch":
      out = labToSrgb(c0, c1 * Math.cos((c2 * Math.PI) / 180), c1 * Math.sin((c2 * Math.PI) / 180));
      break;
    default:
      return null;
  }
  return { r: clamp01(out[0]), g: clamp01(out[1]), b: clamp01(out[2]), a: mix.alpha };
}

/** The canonical computed serialization of a color-mix(): its result in the space it mixed in. */
export function colorMixForm(value: string): string | null {
  const s = value.trim().toLowerCase().replace(/\s+/g, " ");
  if (!s.startsWith("color-mix(") || !s.endsWith(")")) return null;
  const mix = mixInSpace(s);
  if (mix === null) return null;
  const [c0, c1, c2] = mix.comps;
  let out: string;
  switch (mix.space) {
    case "srgb":
    case "srgb-linear":
      out = "color(" + mix.space + " " + formNumber(c0) + " " + formNumber(c1) + " " + formNumber(c2);
      break;
    case "lab":
    case "oklab":
      out = mix.space + "(" + formNumber(c0) + " " + formNumber(c1) + " " + formNumber(c2);
      break;
    case "lch":
    case "oklch":
      // An achromatic mix has no hue to name, and CSS writes that as `none`.
      out = mix.space + "(" + formNumber(c0) + " " + formNumber(c1) + " " +
        (Math.abs(c1) < 1e-6 ? "none" : formNumber(c2));
      break;
    default:
      return null;
  }
  if (mix.alpha !== 1) out += " / " + formNumber(mix.alpha);
  return out + ")";
}

// --- Gradient colour interpolation -------------------------------------------
//
// CSS Images 4 gradients interpolate their stops in a named colour space, which Tailwind v4
// writes as `in oklab`. The spaces are numbered for the encoded gradient string; the ones this
// build can convert to and from interpolate there, and a space whose conversion it doesn't carry
// interpolates the sRGB colours instead, so the gradient still paints the colours it names.

export const CS_SRGB = 0;
export const CS_SRGB_LINEAR = 1;
export const CS_OKLAB = 2;
export const CS_OKLCH = 3;
export const CS_LAB = 4;
export const CS_LCH = 5;
export const CS_HSL = 6;
export const CS_HWB = 7;

/** Whether a space enters interpolation in polar form, so its hue has an arc to take. */
export function polarSpace(space: number): boolean {
  return space === CS_OKLCH || space === CS_LCH || space === CS_HSL || space === CS_HWB;
}

/** A `<color-interpolation-method>`'s colour space name as its number, or null when unknown. */
export function gradientSpaceId(name: string): number | null {
  switch (name.toLowerCase()) {
    case "srgb": return CS_SRGB;
    case "srgb-linear": return CS_SRGB_LINEAR;
    case "oklab": return CS_OKLAB;
    case "oklch": return CS_OKLCH;
    case "lab": return CS_LAB;
    case "lch": return CS_LCH;
    case "hsl": return CS_HSL;
    case "hwb": return CS_HWB;
    // Valid spaces this build has no conversion for: interpolating their sRGB colours is an
    // approximation, but it keeps a gradient with one painting.
    case "display-p3": case "a98-rgb": case "prophoto-rgb":
    case "rec2020": case "xyz": case "xyz-d50": case "xyz-d65":
      return CS_SRGB;
    default: return null;
  }
}

export const HUE_SHORTER = 0;
export const HUE_LONGER = 1;
export const HUE_INCREASING = 2;
export const HUE_DECREASING = 3;

/** The hue interpolation method a name stands for, or null when it isn't one. */
export function gradientHueId(name: string): number | null {
  switch (name.toLowerCase()) {
    case "shorter": return HUE_SHORTER;
    case "longer": return HUE_LONGER;
    case "increasing": return HUE_INCREASING;
    case "decreasing": return HUE_DECREASING;
    default: return null;
  }
}

/** Interpolates a hue along the arc the method names. */
function blendHue(h1: number, h2: number, t: number, method: number): number {
  let d: number;
  switch (method) {
    case HUE_LONGER:
      d = ((h2 - h1 + 540) % 360) - 180;
      d = d > 0 ? d - 360 : d + 360;
      break;
    case HUE_INCREASING:
      d = ((h2 - h1) % 360 + 360) % 360;
      break;
    case HUE_DECREASING:
      d = ((h2 - h1) % 360 - 360) % 360;
      break;
    default:
      d = ((h2 - h1 + 540) % 360) - 180;
  }
  return ((h1 + d * t) % 360 + 360) % 360;
}

function hslOf(c: Rgba): [number, number, number] {
  const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number;
  if (max === c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0);
  else if (max === c.g) h = (c.b - c.r) / d + 2;
  else h = (c.r - c.g) / d + 4;
  return [h * 60, s, l];
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const hn = ((h % 360) + 360) % 360;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((hn / 60) % 2) - 1));
  const m = l - c / 2;
  let r = 0, g = 0, b = 0;
  if (hn < 60) { r = c; g = x; }
  else if (hn < 120) { r = x; g = c; }
  else if (hn < 180) { g = c; b = x; }
  else if (hn < 240) { g = x; b = c; }
  else if (hn < 300) { r = x; b = c; }
  else { r = c; b = x; }
  return [r + m, g + m, b + m];
}

function hwbOf(c: Rgba): [number, number, number] {
  const h = hslOf(c)[0];
  const w = Math.min(c.r, c.g, c.b), bl = 1 - Math.max(c.r, c.g, c.b);
  return [h, w, bl];
}

function hwbToRgb(h: number, w: number, bl: number): [number, number, number] {
  if (w + bl >= 1) {
    const g = w / (w + bl);
    return [g, g, g];
  }
  const [r, gr, b] = hslToRgb(h, 1, 0.5);
  const scale = 1 - w - bl;
  return [r * scale + w, gr * scale + w, b * scale + w];
}

/**
 * Two packed sRGB colours mixed `t` of the way from the first to the second in `space`, with a
 * polar space's hue following `hueMethod`. Alpha is premultiplied, as CSS mixes colours, and the
 * result is packed sRGB.
 */
export function interpolateColor(c0: number, c1: number, t: number, space: number, hueMethod: number): number {
  const a0 = (c0 & 255) / 255, a1 = (c1 & 255) / 255;
  const alpha = a0 * (1 - t) + a1 * t;
  if (!(alpha > 0)) return 0;
  // Premultiplied interpolation weighs each side by the alpha it brings to the mix.
  const p0 = (a0 * (1 - t)) / alpha, p1 = (a1 * t) / alpha;
  const e0: Rgba = { r: ((c0 >>> 24) & 255) / 255, g: ((c0 >>> 16) & 255) / 255, b: ((c0 >>> 8) & 255) / 255, a: a0 };
  const e1: Rgba = { r: ((c1 >>> 24) & 255) / 255, g: ((c1 >>> 16) & 255) / 255, b: ((c1 >>> 8) & 255) / 255, a: a1 };
  const mix = (x: number, y: number): number => x * p0 + y * p1;
  let out: [number, number, number];
  switch (space) {
    case CS_SRGB_LINEAR:
      out = [linearToSrgb(mix(srgbToLinear(e0.r), srgbToLinear(e1.r))),
        linearToSrgb(mix(srgbToLinear(e0.g), srgbToLinear(e1.g))),
        linearToSrgb(mix(srgbToLinear(e0.b), srgbToLinear(e1.b)))];
      break;
    case CS_OKLAB:
    case CS_OKLCH: {
      const l0 = srgbToOklab(e0), l1 = srgbToOklab(e1);
      if (space === CS_OKLAB) {
        out = oklabToSrgb(mix(l0[0], l1[0]), mix(l0[1], l1[1]), mix(l0[2], l1[2]));
      } else {
        const q0 = polar(l0), q1 = polar(l1);
        const h = blendHue(q0[2], q1[2], p1, hueMethod) * (Math.PI / 180);
        const C = mix(q0[1], q1[1]);
        out = oklabToSrgb(mix(q0[0], q1[0]), C * Math.cos(h), C * Math.sin(h));
      }
      break;
    }
    case CS_LAB:
    case CS_LCH: {
      const l0 = srgbToLab(e0), l1 = srgbToLab(e1);
      if (space === CS_LAB) {
        out = labToSrgb(mix(l0[0], l1[0]), mix(l0[1], l1[1]), mix(l0[2], l1[2]));
      } else {
        const q0 = polar(l0), q1 = polar(l1);
        const h = blendHue(q0[2], q1[2], p1, hueMethod) * (Math.PI / 180);
        const C = mix(q0[1], q1[1]);
        out = labToSrgb(mix(q0[0], q1[0]), C * Math.cos(h), C * Math.sin(h));
      }
      break;
    }
    case CS_HSL: {
      const q0 = hslOf(e0), q1 = hslOf(e1);
      out = hslToRgb(blendHue(q0[0], q1[0], p1, hueMethod), mix(q0[1], q1[1]), mix(q0[2], q1[2]));
      break;
    }
    case CS_HWB: {
      const q0 = hwbOf(e0), q1 = hwbOf(e1);
      out = hwbToRgb(blendHue(q0[0], q1[0], p1, hueMethod), mix(q0[1], q1[1]), mix(q0[2], q1[2]));
      break;
    }
    default:
      out = [mix(e0.r, e1.r), mix(e0.g, e1.g), mix(e0.b, e1.b)];
  }
  return pack(clamp01(out[0]) * 255, clamp01(out[1]) * 255, clamp01(out[2]) * 255, alpha * 255);
}

// ---------------------------------------------------------------------------
// System colours
//
// A system colour names a colour of the platform rather than a value the page writes: Canvas is
// the page's background, CanvasText its text, ButtonFace a button's, and the deprecated CSS Color
// 3 names are aliases of these. Which value one has depends on the color-scheme the element is
// drawn in, so a keyword is compiled to the var() that names it, and the runtime resolves that
// custom property where the element's scheme is known (see runtime/system-colors.ts).

/** The system colours of CSS Color 4, and the deprecated names, as the name each resolves through. */
export const SYSTEM_COLOR_NAMES: Record<string, string> = {
  canvas: "canvas", canvastext: "canvastext", linktext: "linktext", visitedtext: "visitedtext",
  activetext: "activetext", buttonface: "buttonface", buttontext: "buttontext",
  buttonborder: "buttonborder", field: "field", fieldtext: "fieldtext", highlight: "highlight",
  highlighttext: "highlighttext", selecteditem: "selecteditem", selecteditemtext: "selecteditemtext",
  mark: "mark", marktext: "marktext", graytext: "graytext", accentcolor: "accentcolor",
  accentcolortext: "accentcolortext", appworkspace: "appworkspace", scrollbar: "scrollbar",
  // CSS Color 3's deprecated names, each the colour of the system colour it now names. They are
  // what the deprecated-sameas tests in WPT compare, one pair at a time.
  activeborder: "buttonborder", activecaption: "canvas", background: "canvas",
  buttonhighlight: "buttonface", buttonshadow: "buttonface", captiontext: "canvastext",
  inactiveborder: "buttonborder", inactivecaption: "canvas", inactivecaptiontext: "graytext",
  infobackground: "canvas", infotext: "canvastext", menu: "canvas", menutext: "canvastext",
  threeddarkshadow: "buttonborder", threedface: "buttonface", threedhighlight: "buttonborder",
  threedlightshadow: "buttonborder", threedshadow: "buttonborder", window: "canvas",
  windowframe: "buttonborder", windowtext: "canvastext",
};

/** The custom property a system colour resolves through. */
export const SYSTEM_COLOR_PREFIX = "--native-sys-";

/** The properties that can carry a colour, where a system colour's name is the colour it means.
 *  Anywhere else the word is a name — a font family called Canvas, a keyframes called Window — and
 *  has to stay one. */
const COLOR_SHORTHANDS: Set<string> = new Set([
  "color", "background", "background-image", "border", "border-top", "border-right",
  "border-bottom", "border-left", "border-block", "border-inline", "border-block-start",
  "border-block-end", "border-inline-start", "border-inline-end", "outline", "text-decoration",
  "text-emphasis", "column-rule", "box-shadow", "text-shadow", "filter", "fill", "stroke",
  "text-stroke", "scrollbar-color",
]);

/** Whether a property's value can take a colour, so a system colour's name in it is a colour. */
export function mayTakeColor(prop: string): boolean {
  const name = prop.toLowerCase();
  return name.endsWith("-color") || COLOR_SHORTHANDS.has(name);
}

/**
 * A value with every system colour it names replaced by the var() that resolves it. Strings and
 * url() aren't looked in, and a custom property's name keeps its own spelling.
 */
export function withSystemColors(prop: string, value: string): string {
  return mapSystemColors(prop, value, (name) => "var(" + SYSTEM_COLOR_PREFIX + name + ")");
}

/**
 * A value with each system colour keyword spelled the way CSS serializes it: its canonical name,
 * lowercased, so a deprecated alias reads back as the colour it means (`Window` as `canvas`). The
 * declaration keeps this text, so style.color and cssText show the keyword rather than the var()
 * the computed value resolves through.
 */
export function canonicalSystemColors(prop: string, value: string): string {
  return mapSystemColors(prop, value, (name) => name);
}

/** Rewrites the system colour keywords a value names, in colour positions only. */
function mapSystemColors(prop: string, value: string, replace: (name: string) => string): string {
  if (!mayTakeColor(prop)) return value;
  let out = "";
  for (let i = 0; i < value.length; ) {
    const c = value[i];
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < value.length && value[j] !== c) j += value[j] === "\\" ? 2 : 1;
      out += value.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    // A url() names a file, not a colour.
    if ((c === "u" || c === "U") && /^url\(/i.test(value.slice(i, i + 4))) {
      let j = i + 4;
      let depth = 1;
      while (j < value.length && depth > 0) {
        if (value[j] === "(") depth++;
        else if (value[j] === ")") depth--;
        j++;
      }
      out += value.slice(i, j);
      i = j;
      continue;
    }
    // A name a custom property is spelled with (`--canvas`) is its own, not a colour.
    if (/[A-Za-z_]/.test(c) && !(i > 0 && /[\w$-]/.test(value[i - 1]))) {
      let j = i + 1;
      while (j < value.length && /[\w-]/.test(value[j])) j++;
      const word = value.slice(i, j);
      const name = SYSTEM_COLOR_NAMES[word.toLowerCase()];
      out += name === undefined ? word : replace(name);
      i = j;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

// ---------------------------------------------------------------------------
// light-dark()
//
// `light-dark(a, b)` is the colour a page asks for in each color-scheme. Like a system colour it
// can only be resolved where the element's scheme is known, so a declaration naming one is held as
// text and the chosen branch is substituted when the style is computed.

/** Whether a value names light-dark(), which only the element's color-scheme can finish. */
export function hasLightDark(value: string): boolean {
  return /(^|[^\w-])light-dark\(/i.test(value);
}

/**
 * A value with every light-dark() replaced by the branch its element's scheme asks for. The rest of
 * the value stays as written, and a call that isn't a well-formed pair is left for the parser to
 * reject, as an invalid colour is.
 */
export function resolveLightDark(prop: string, value: string, dark: boolean): string {
  if (!mayTakeColor(prop) || !hasLightDark(value)) return value;
  let out = "";
  for (let i = 0; i < value.length; ) {
    const m = /^light-dark\(/i.exec(value.slice(i));
    if (m === null || (i > 0 && /[\w-]/.test(value[i - 1]))) {
      out += value[i];
      i++;
      continue;
    }
    // Find the matching close parenthesis and split its arguments at the top-level comma.
    let depth = 1;
    let j = i + m[0].length;
    let comma = -1;
    for (; j < value.length && depth > 0; j++) {
      const c = value[j];
      if (c === '"' || c === "'") {
        let k = j + 1;
        while (k < value.length && value[k] !== c) k += value[k] === "\\" ? 2 : 1;
        j = k;
      } else if (c === "(") depth++;
      else if (c === ")") depth--;
      else if (c === "," && depth === 1 && comma < 0) comma = j;
    }
    if (comma < 0 || depth !== 0) {
      out += value[i];
      i++;
      continue;
    }
    const a = resolveLightDark(prop, value.slice(i + m[0].length, comma).trim(), dark);
    const b = resolveLightDark(prop, value.slice(comma + 1, j - 1).trim(), dark);
    out += dark ? b : a;
    i = j;
  }
  return out;
}


// ---------------------------------------------------------------------------
// currentColor inside a colour function

/**
 * Whether a value names currentColor where the keyword can't be folded into a number at build
 * time: inside color-mix() or light-dark(), or as the origin of a relative colour, where it waits
 * for the element's own colour.
 */
export function hasDeferredCurrentColor(value: string): boolean {
  if (!/(^|[^\w-])currentcolor\b/i.test(value)) return false;
  if (/(^|[^\w-])(color-mix|light-dark)\(/i.test(value)) return true;
  if (/(^|[^\w-])contrast-color\(/i.test(value)) return true;
  return /(^|[^\w-])(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\b/i.test(value);
}

/** A value with currentColor spelled as the element's own colour, for a function that needs one. */
export function resolveCurrentColor(value: string, colour: string): string {
  return value.replace(/(^|[^\w-])currentcolor\b/gi, (_m: string, pre: string) => pre + colour);
}

// ---------------------------------------------------------------------------
// The computed form of a modern colour
//
// A legacy colour computes to rgb(): hsl(120 50% 50%) reads back "rgb(64, 191, 64)". The colour
// functions of CSS Color 4 keep their own space: lab(50% 40 -30) computes to "lab(50 40 -30)" and
// oklch(58.5% 0.233 277.117) to "oklch(0.585 0.233 277.117)". A declaration naming one is held as
// text, and the form is what its computed value serializes as.

/** Whether a value names a colour function whose computed value keeps its own space. */
export function hasModernColor(prop: string, value: string): boolean {
  return mayTakeColor(prop) && /(^|[^\w-])(lab|lch|oklab|oklch|color|color-mix)\(/i.test(value);
}

/** A number the way Chrome writes it in a colour function: up to six decimals, no trailing zeros. */
function formNumber(n: number): string {
  if (!Number.isFinite(n)) return "0";
  const s = n.toFixed(6).replace(/\.0*$/, "").replace(/(\.\d*?)0+$/, "$1");
  return s === "-0" ? "0" : s;
}

/** Splits `a b c / alpha` at the top-level slash. */
function splitAlpha(inner: string): [string, string | null] {
  let depth = 0;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "/" && depth === 0) return [inner.slice(0, i), inner.slice(i + 1).trim()];
  }
  return [inner, null];
}

/**
 * The canonical computed serialization of a modern colour function, or null when the value is one
 * a mix or a relative colour has to resolve first, or a legacy colour that serializes as rgb().
 */
export function modernColorForm(value: string): string | null {
  const s = value.trim().toLowerCase().replace(/\s+/g, " ");
  if (s.startsWith("color-mix(")) return colorMixForm(s);
  const lab = /^(lab|lch|oklab|oklch)\(([^()]*)\)$/.exec(s);
  if (lab !== null) return labColorForm(lab[1], lab[2]);
  const fn = /^color\(([^()]*)\)$/.exec(s);
  if (fn !== null) return colorFunctionForm(fn[1]);
  return null;
}

function labColorForm(fn: string, inner: string): string | null {
  const ok = fn === "oklab" || fn === "oklch";
  const polar = fn === "lch" || fn === "oklch";
  const [main, alphaText] = splitAlpha(inner);
  const parts = main.split(/[\s,]+/).filter(Boolean);
  if (parts.length !== 3) return null;
  const raw = isNone(parts[0]) ? 0 : numOrPct(parts[0], ok ? 1 : 100);
  if (raw === null) return null;
  // Lightness is clamped to its space's range, as the colour itself is: Chrome reads lab(150 150
  // 20) back as lab(100 150 20).
  const L = Math.max(0, Math.min(ok ? 1 : 100, raw));
  // A percentage of chroma or of a or b is a share of the 100%-reference the space defines.
  const c1 = isNone(parts[1]) ? 0 : numOrPct(parts[1], polar ? (ok ? 0.4 : 150) : ok ? 0.4 : 125);
  const c2 = polar
    ? (isNone(parts[2]) ? 0 : hueOf(parts[2]))
    : (isNone(parts[2]) ? 0 : numOrPct(parts[2], ok ? 0.4 : 125));
  if (c1 === null || c2 === null) return null;
  let out = fn + "(" + formNumber(L) + " " + formNumber(c1) + " " + formNumber(c2);
  const a = alphaText === null ? 1 : alphaOf(alphaText);
  if (a === null) return null;
  if (a !== 1) out += " / " + formNumber(a);
  return out + ")";
}

function colorFunctionForm(inner: string): string | null {
  const [main, alphaText] = splitAlpha(inner);
  const parts = main.trim().split(/\s+/).filter(Boolean);
  if (parts.length !== 4) return null;
  const space = parts[0];
  if (!/^[a-z0-9-]+$/.test(space)) return null;
  const ch: string[] = [];
  for (let i = 1; i <= 3; i++) {
    const t = parts[i];
    if (isNone(t)) {
      ch.push("none");
      continue;
    }
    const v = parseFloat(t);
    if (!Number.isFinite(v)) return null;
    ch.push(formNumber(t.endsWith("%") ? v / 100 : v));
  }
  let out = "color(" + space + " " + ch.join(" ");
  const a = alphaText === null ? 1 : alphaOf(alphaText);
  if (a === null) return null;
  if (a !== 1) out += " / " + formNumber(a);
  return out + ")";
}

// ---------------------------------------------------------------------------
// The computed form of a background image
//
// A background-image a page sets through CSSOM or a text declaration is held as text, and its
// computed value reads back as that image: a url() in the quotes CSS serializes it in, or the
// function as written with its colours resolved.

/** Whether a background-image value is one whose text is its computed form (a url() or none). */
/** The url() arguments a declaration's text names, unquoted. */
export function urlsInText(text: string): string[] {
  const out: string[] = [];
  const re = /url\(\s*(['"]?)([^'")]*)\1\s*\)/gi;
  for (let m = re.exec(text); m !== null; m = re.exec(text)) out.push(m[2].trim());
  return out;
}

export function hasTextImage(value: string): boolean {
  const s = value.trim();
  // One image only: a layer list is compiled from its rows, which the painter serializes back.
  return /^url\(\s*(['"]?)[^()]*\1\s*\)$/i.test(s) || /^none$/i.test(s) || /^[a-z-]+gradient\(/i.test(s);
}

/** The computed serialization of a background-image value, or null when it has no text form. */
export function imageForm(value: string): string | null {
  const s = value.trim();
  if (s === "") return null;
  // One url() only: a list of them is a layer list, which the painter's rows serialize.
  const url = /^url\(\s*(['"]?)([^()]*)\1\s*\)$/i.exec(s);
  if (url !== null) return "url(" + JSON.stringify(url[2]) + ")";
  if (/^none$/i.test(s)) return "none";
  return null;
}

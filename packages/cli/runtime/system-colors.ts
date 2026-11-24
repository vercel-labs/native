// The colours CSS's system colours name, in each color-scheme. A page writes `Canvas`,
// `ButtonFace` or `Highlight`; the declaration parser turns the keyword into the var() that names
// the custom property here (see shared/css/colors.ts), and the style engine resolves it with the
// element's scheme. The values are the ones Chrome computes on a Mac — read from Chrome with
// getComputedStyle in both schemes — so a page that mixes system colours with the UA's own element
// colours stays consistent.
//
// Highlight and SelectedItem are the colours Chrome paints a selection with: a translucent blue
// over the text, darker in the dark scheme, with black text on it.

const LIGHT: Record<string, number> = {
  canvas: 0xffffffff,
  canvastext: 0x000000ff,
  linktext: 0x0000eeff,
  visitedtext: 0x551a8bff,
  activetext: 0xff0000ff,
  buttonface: 0xefefefff,
  buttontext: 0x000000ff,
  buttonborder: 0x767676ff,
  field: 0xffffffff,
  fieldtext: 0x000000ff,
  mark: 0xffff00ff,
  marktext: 0x000000ff,
  graytext: 0x767676ff,
  accentcolor: 0x0075ffff,
  accentcolortext: 0xffffffff,
  appworkspace: 0xffffffff,
  scrollbar: 0xffffffff,
  highlight: 0x80bcfe99,
  highlighttext: 0x000000ff,
  selecteditem: 0xb3d7ffff,
  selecteditemtext: 0x000000ff,
};

const DARK: Record<string, number> = {
  canvas: 0x121212ff,
  canvastext: 0xffffffff,
  linktext: 0x9e9effff,
  visitedtext: 0xd0adf0ff,
  activetext: 0xff9e9eff,
  buttonface: 0x6b6b6bff,
  buttontext: 0xffffffff,
  buttonborder: 0xffffffff,
  field: 0x3b3b3bff,
  fieldtext: 0xffffffff,
  mark: 0xffff00ff,
  marktext: 0x000000ff,
  graytext: 0x8c8c8cff,
  accentcolor: 0x0075ffff,
  accentcolortext: 0xffffffff,
  appworkspace: 0x121212ff,
  scrollbar: 0x121212ff,
  highlight: 0xb3d7ffcc,
  highlighttext: 0x000000ff,
  selecteditem: 0x99c8ffff,
  selecteditemtext: 0x3b3b3bff,
};

/** A packed 0xRRGGBBAA colour as CSS text the parser reads back. */
export function colorText(c: number): string {
  const r = (c >>> 24) & 255;
  const g = (c >>> 16) & 255;
  const b = (c >>> 8) & 255;
  const a = c & 255;
  return a === 255
    ? "rgb(" + String(r) + ", " + String(g) + ", " + String(b) + ")"
    : "rgba(" + String(r) + ", " + String(g) + ", " + String(b) + ", " + String(Math.round((a / 255) * 1000) / 1000) + ")";
}

/** The text of each colour already resolved, so a style pass doesn't rebuild it per element. */
const TEXTS = new Map<string, string>();

/** The packed colour of one system colour in a scheme, or null for a name this build doesn't know. */
export function systemColorValue(name: string, dark: boolean): number | null {
  const v = (dark ? DARK : LIGHT)[name];
  return v === undefined ? null : v;
}

/** The CSS text of one system colour in a scheme, or null for a name this build doesn't know. */
export function systemColorText(name: string, dark: boolean): string | null {
  const key = (dark ? "d:" : "l:") + name;
  const hit = TEXTS.get(key);
  if (hit !== undefined) return hit;
  const packed = systemColorValue(name, dark);
  if (packed === null) return null;
  const text = colorText(packed);
  TEXTS.set(key, text);
  return text;
}

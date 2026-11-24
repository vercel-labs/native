// Presentation attributes a script can change. SVG's fill, stroke, opacity, font and so on stand
// in for declarations below every author rule, and a script reaches them with setAttribute() —
// not with el.style, which is where a browser's `arc.style.stroke = …` would go. The build leaves
// every SVG element a slot in the cascade (see compiler/compile.ts), and each style pass fills the
// slot from the attributes the element carries at the time, so the attribute's current value is
// the one the cascade sees. A style="" declaration still beats it, as it beats any hint.
//
// The declarations are compiled with the same value parser a style attribute uses, so a value
// means the same thing either way; the only difference is SVG's attribute grammar, where a bare
// number is user units (a px length) rather than a parse error.

import { compileValue } from "../shared/css/declarations.ts";
import { svgLengths } from "../shared/svg.ts";
import type { Decl, FontContext } from "../shared/css/types.ts";
import type { Element } from "./dom.ts";

/** The attributes that paint an SVG element, as zero-specificity declarations. */
const PAINT_ATTRS: string[] = ["fill", "stroke", "color", "fill-opacity", "stroke-opacity", "opacity",
  "stroke-linecap", "stroke-linejoin", "fill-rule", "stroke-dasharray", "stroke-dashoffset",
  "font-family", "font-weight", "font-style"];

/** Attributes whose bare numbers are user units: the CSS parser wants a length. */
const LENGTH_ATTRS: string[] = ["stroke-width", "stroke-dasharray", "stroke-dashoffset", "font-size"];

/** The value parser's font and image context, given by the style object that owns it. */
let fonts: FontContext | null = null;

export function setHintFonts(f: FontContext): void {
  fonts = f;
}

/** The declarations the element's presentation attributes stand for, in the order they apply. */
export function hintDecls(el: Element): Decl[] {
  if (!el.hintStale && el.hintDecls !== null) return el.hintDecls;
  const out: Decl[] = [];
  const f = fonts;
  if (f !== null) {
    const add = (name: string, text: string): void => {
      const value = text.trim();
      if (value !== "") compileValue(name, value, out, f);
    };
    for (const name of PAINT_ATTRS) {
      const v = el.getAttribute(name);
      if (v !== null) add(name, v);
    }
    for (const name of LENGTH_ATTRS) {
      const v = el.getAttribute(name);
      if (v !== null) add(name, svgLengths(v) ?? v);
    }
    // The root's width and height attributes size its box, as an image's do; without them the
    // replaced-box rules give it the SVG default of 300 by 150. XHTML writes the root with its
    // namespace prefix (`<svg:svg>`), so the prefix doesn't count as part of the name.
    const tag = el.localName;
    if (tag.slice(tag.lastIndexOf(":") + 1) === "svg") {
      for (const name of ["width", "height"]) {
        const v = el.getAttribute(name);
        if (v !== null) add(name, svgLengths(v) ?? v);
      }
    }
  }
  el.hintDecls = out;
  el.hintStale = false;
  return out;
}

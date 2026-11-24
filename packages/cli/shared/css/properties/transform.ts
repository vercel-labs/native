// CSS transforms: `transform`, `transform-origin` and the individual `translate`, `rotate` and
// `scale` properties. Each value becomes a row of the shared tables in ../transforms.ts; the
// runtime builds the matrix once the element's border box is known.

import * as P from "../../props.ts";
import { originRows, parseTransformList, parseTransformOrigin, transformRows } from "../transforms.ts";
import { kw } from "../declarations.ts";
import type { Decl } from "../types.ts";

/** Registers a transform list row as the value of `p`; -1 stands for `none`. */
function listDecl(p: number, row: number[] | null, value: string, prop: string, out: Decl[]): string | null {
  if (row === null) return `unsupported value '${value}' for '${prop}'`;
  out.push({ p, v: transformRows.register(row), u: P.U_LIST });
  return null;
}

/** `translate`, `rotate` and `scale` take the value of their like-named function. */
function individual(prop: string, value: string, p: number, out: Decl[]): string | null {
  const v = value.trim().toLowerCase();
  if (v === "none") {
    out.push({ p, v: -1, u: P.U_LIST });
    return null;
  }
  const parts = v.split(/\s+/).filter((s) => s !== "");
  let call = "";
  // A third value is the plane's depth, which is the 3d function with the two-value one's
  // coordinates in front of it.
  if (prop === "translate") {
    call = parts.length === 3 ? `translate3d(${parts.join(", ")})` : `translate(${parts.join(", ")})`;
  } else if (prop === "scale") {
    call = parts.length === 3 ? `scale3d(${parts.join(", ")})` : `scale(${parts.join(", ")})`;
  } else if (parts.length === 2 && (parts[0] === "x" || parts[0] === "y" || parts[0] === "z")) {
    // rotate: [x|y|z] <angle>, the axis naming the function that rotates about it.
    call = `${parts[0] === "z" ? "rotate" : "rotate" + parts[0]}(${parts[1]})`;
  } else if (parts.length === 4) {
    // rotate: <number>{3} <angle>, the vector naming the axis.
    call = `rotate3d(${parts.join(", ")})`;
  } else {
    call = `rotate(${v})`;
  }
  const row = parseTransformList(call);
  if (row === null) return `unsupported value '${value}' for '${prop}'`;
  return listDecl(p, row, value, prop, out);
}

export function transformProperty(prop: string, value: string, out: Decl[]): string | null | undefined {
  switch (prop) {
    case "transform": {
      const v = value.trim();
      if (v.toLowerCase() === "none") {
        out.push({ p: P.P_TRANSFORM, v: -1, u: P.U_LIST });
        return null;
      }
      return listDecl(P.P_TRANSFORM, parseTransformList(v), v, prop, out);
    }
    case "transform-origin": {
      const row = parseTransformOrigin(value);
      if (row === null) return `unsupported value '${value}' for 'transform-origin'`;
      out.push({ p: P.P_TRANSFORM_ORIGIN, v: originRows.register(row), u: P.U_LIST });
      return null;
    }
    case "translate":
      return individual(prop, value, P.P_TRANSLATE, out);
    case "rotate":
      return individual(prop, value, P.P_ROTATE, out);
    case "scale":
      return individual(prop, value, P.P_SCALE, out);
    case "transform-box":
      return kw(prop, value, {
        "content-box": P.TB_CONTENT_BOX, "border-box": P.TB_BORDER_BOX, "fill-box": P.TB_FILL_BOX,
        "stroke-box": P.TB_STROKE_BOX, "view-box": P.TB_VIEW_BOX,
      }, P.P_TRANSFORM_BOX, out);
    case "transform-style": {
      const r = kw(prop, value, { flat: P.TS_FLAT, "preserve-3d": P.TS_PRESERVE_3D }, P.P_TRANSFORM_STYLE, out);
      if (r !== null || P.TS_PRESERVE_3D !== out[out.length - 1].v) return r;
      // The value is kept, but the painter has no 3D rendering context to put it in.
      return "note: preserve-3d renders flat; 3D rendering contexts aren't supported yet";
    }
    case "will-change":
      // A hint to the renderer only: there is nothing to composite, so it changes nothing.
      return null;
  }
  return undefined;
}

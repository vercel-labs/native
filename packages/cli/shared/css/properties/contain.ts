// CSS containment: container-type, container-name and the container shorthand. Returns undefined
// for a property this module doesn't handle.

import * as P from "../../props.ts";
import { kw } from "../declarations.ts";
import type { Decl, FontContext } from "../types.ts";

// Words a container name can't be: the shorthands and keywords of the property itself.
const RESERVED = ["none", "default", "and", "or", "not", "auto"];

/**
 * The names a container-name value lists, in order, or null when the value isn't a list of
 * custom identifiers. A repeated name is kept once, as the shorthand's grammar dedupes them.
 */
function nameList(value: string): string[] | null {
  const words = value.trim().split(/\s+/);
  const out: string[] = [];
  for (const w of words) {
    if (!/^-?[A-Za-z_][A-Za-z0-9_-]*$/.test(w) || RESERVED.indexOf(w.toLowerCase()) >= 0) return null;
    if (out.indexOf(w) < 0) out.push(w);
  }
  return out.length > 0 ? out : null;
}

/**
 * The declarations a container-name value makes. The names go into the CONTAINER_NAMES table, so
 * a rule's query and the element's own value compare as indexes rather than as text.
 */
function containerName(value: string, out: Decl[], fonts?: FontContext): string | null {
  if (value.trim().toLowerCase() === "none") {
    out.push({ p: P.P_CONTAINER_NAME, v: -1, u: P.U_NONE });
    return null;
  }
  const names = nameList(value);
  if (names === null) return `invalid container name in '${value}'`;
  const id = fonts === undefined || fonts.containerNames === undefined ? -1 : fonts.containerNames(names.join(" "));
  if (id < 0) return "container-name needs a style sheet to name it; the declaration is ignored";
  out.push({ p: P.P_CONTAINER_NAME, v: id, u: P.U_LIST });
  return null;
}

const TYPES: Record<string, number> = { normal: P.CT_NORMAL, size: P.CT_SIZE, "inline-size": P.CT_INLINE_SIZE };

/** `contain`: the kinds of containment a box asks for, as a bitmask. */
const CONTAIN_KINDS: Record<string, number> = {
  size: P.CONTAIN_SIZE, layout: P.CONTAIN_LAYOUT, style: P.CONTAIN_STYLE, paint: P.CONTAIN_PAINT,
  "inline-size": P.CONTAIN_INLINE_SIZE, "block-size": P.CONTAIN_BLOCK_SIZE,
};
const CONTAIN_ALL = P.CONTAIN_SIZE | P.CONTAIN_LAYOUT | P.CONTAIN_STYLE | P.CONTAIN_PAINT;
const CONTAIN_CONTENT = P.CONTAIN_LAYOUT | P.CONTAIN_STYLE | P.CONTAIN_PAINT;

function containValue(value: string): number | string {
  let mask = 0;
  for (const tok of value.trim().toLowerCase().split(/\s+/).filter((t) => t !== "")) {
    if (tok === "none") {
      if (mask !== 0) return `invalid value '${value}' for 'contain'`;
      continue;
    }
    if (tok === "strict") mask |= CONTAIN_ALL;
    else if (tok === "content") mask |= CONTAIN_CONTENT;
    else if (CONTAIN_KINDS[tok] !== undefined) mask |= CONTAIN_KINDS[tok];
    else return `unsupported contain '${value}' (none, strict, content, size, layout, style or paint)`;
  }
  return mask;
}

export function containProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null | undefined {
  switch (prop) {
    case "contain": {
      const mask = containValue(value);
      if (typeof mask === "string") return mask;
      out.push({ p: P.P_CONTAIN, v: mask, u: P.U_NONE });
      return null;
    }
    case "container-type":
      return kw(prop, value, TYPES, P.P_CONTAINER_TYPE, out);
    case "container-name":
      return containerName(value, out, fonts);
    case "container": {
      // `container: <name> [ / <type> ]?`: without the slash the value only names the container,
      // which leaves its type at the initial `normal`, as in a browser.
      const slash = value.indexOf("/");
      const names = slash < 0 ? value : value.slice(0, slash);
      const type = slash < 0 ? null : value.slice(slash + 1);
      const decls: Decl[] = [];
      if (names.trim() !== "") {
        const err = containerName(names, decls, fonts);
        if (err !== null) return err;
      } else decls.push({ p: P.P_CONTAINER_NAME, v: -1, u: P.U_NONE });
      if (type === null || type.trim() === "") {
        if (type !== null) return `invalid value '${value}' for 'container'`;
        decls.push({ p: P.P_CONTAINER_TYPE, v: P.CT_NORMAL, u: P.U_NONE });
      } else {
        const err = kw("container-type", type.trim(), TYPES, P.P_CONTAINER_TYPE, decls);
        if (err !== null) return err;
      }
      for (const d of decls) out.push(d);
      return null;
    }
    default:
      return undefined;
  }
}

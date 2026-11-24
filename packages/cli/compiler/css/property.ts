// The `@property` rule: a custom property registered with a syntax, whether it inherits, and the
// initial value it takes where nothing sets it (CSS Properties and Values 1, §2).
//
// The registration is checked here, at build time, because a rule that gets it wrong is ignored
// whole: an invalid rule must not leave a half-registered property behind. The descriptors go to
// the runtime as a table, and the runtime registers them the way CSS.registerProperty() would.

import { fitsSyntax, stringToken } from "../../shared/css/syntax.ts";
import { splitTopLevel } from "./selectors.ts";
import type { PropertyRule } from "./types.ts";

/**
 * Reads the block of an `@property` rule: its name from the prelude and its descriptors. Returns
 * the registration, or the reason the rule is invalid and so ignored.
 */
export function parsePropertyRule(prelude: string, body: string): { rule: PropertyRule | null; why: string } {
  const name = prelude.trim();
  if (!name.startsWith("--") || name.length < 3 || /[\s,{}()]/.test(name)) {
    return { rule: null, why: `'${name}' isn't a custom property name` };
  }
  let syntax: string | null = null;
  let inherits: boolean | null = null;
  let initialValue: string | null = null;
  let hasInitial = false;
  for (const part of splitTopLevel(body, ";")) {
    const text = part.trim();
    if (text === "") continue;
    const colon = text.indexOf(":");
    if (colon < 0) return { rule: null, why: `'${text}' isn't a descriptor` };
    const prop = text.slice(0, colon).trim().toLowerCase();
    const value = text.slice(colon + 1).trim();
    if (prop === "syntax") {
      const s = stringToken(value);
      if (s === null) return { rule: null, why: "syntax takes a string" };
      syntax = s;
    } else if (prop === "inherits") {
      const v = value.toLowerCase();
      if (v !== "true" && v !== "false") return { rule: null, why: "'inherits' takes true or false" };
      inherits = v === "true";
    } else if (prop === "initial-value") {
      // The last descriptor of a name wins, and an empty one is invalid.
      hasInitial = true;
      initialValue = value;
    }
  }
  if (syntax === null) return { rule: null, why: "it sets no syntax" };
  if (inherits === null) return { rule: null, why: "it sets no inherits" };
  if (!hasInitial) {
    // Only the universal syntax may leave the initial value out; the property is then
    // guaranteed-invalid until something sets it.
    if (syntax !== "*") return { rule: null, why: `syntax '${syntax}' needs an initial-value` };
  } else if (initialValue === "" || !fitsSyntax(syntax, initialValue as string)) {
    return { rule: null, why: `initial-value doesn't match syntax '${syntax}'` };
  }
  return { rule: { name, syntax, inherits, initialValue: hasInitial ? (initialValue as string) : null }, why: "" };
}

// CSS Box Alignment values, shared by flex and grid: the position and distribution keywords, the
// `safe`/`unsafe` overflow position that may front a position keyword, and the baseline positions.

import * as P from "../../props.ts";
import { splitValue } from "../fonts.ts";
import type { Decl } from "../types.ts";

/**
 * A box's own alignment keywords (CSS Align 4, <self-position>). native lays pages out left to
 * right, so self-start and left sit on the start edge, self-end and right on the end edge; the
 * ids stay apart so the computed value keeps the keyword the author wrote.
 */
export const SELF_POSITION: Record<string, number> = {
  start: P.A_START, "flex-start": P.A_FLEX_START, "self-start": P.A_SELF_START, left: P.A_LEFT,
  center: P.A_CENTER,
  end: P.A_END, "flex-end": P.A_FLEX_END, "self-end": P.A_SELF_END, right: P.A_RIGHT,
};

/** The positions a track set packs to (CSS Align 5, <content-position>). */
export const CONTENT_POSITION: Record<string, number> = {
  start: P.J_START, "flex-start": P.J_FLEX_START, center: P.J_CENTER, end: P.J_END, "flex-end": P.J_FLEX_END,
};

/** The distributions that spread a track set out (CSS Align 5, <content-distribution>). */
export const CONTENT_DISTRIBUTION: Record<string, number> = {
  "space-between": P.J_SPACE_BETWEEN, "space-around": P.J_SPACE_AROUND, "space-evenly": P.J_SPACE_EVENLY,
};

/** The baseline positions align-content and justify-content take. */
export const CONTENT_BASELINE: Record<string, number> = {
  baseline: P.J_BASELINE, "first baseline": P.J_BASELINE, "last baseline": P.J_LAST_BASELINE,
};

/** The baseline positions: `baseline` and `first baseline` are one value, `last baseline` the
 *  other. `baseline` computes to `baseline`, so the two spellings of the first one share an id. */
export const BASELINE_POSITION: Record<string, number> = {
  baseline: P.A_BASELINE, "first baseline": P.A_BASELINE, "last baseline": P.A_LAST_BASELINE,
};

/** The keywords `align-items` takes; `self` adds `auto`. */
export const ITEMS_WORDS: Record<string, number> = {
  normal: P.A_NORMAL, stretch: P.A_STRETCH, ...SELF_POSITION, ...BASELINE_POSITION,
};

export const SELF_WORDS: Record<string, number> = { ...ITEMS_WORDS, auto: P.A_AUTO };

// What a property rejects even though the keyword exists in the family: `auto` is a self value
// only, and the physical edges belong to the inline axis alone. A browser drops such a
// declaration, which is what an invalid value gets.
export const NO_INVALID: readonly string[] = [];
export const NO_AUTO: readonly string[] = ["auto"];
export const ITEMS_INVALID: readonly string[] = ["auto", "left", "right"];
export const SELF_INVALID: readonly string[] = ["left", "right"];
export const CONTENT_INVALID: readonly string[] = ["auto", "left", "right"];

/**
 * One alignment value. An overflow position may front a position keyword (`safe center`), and it
 * is stored in the value's unit so the computed value keeps it. A value mixing one with anything
 * else is invalid CSS, which a browser drops.
 */
export function alignValue(prop: string, value: string, words: Record<string, number>,
  positions: Record<string, number>, invalid: readonly string[], p: number, out: Decl[], allowLegacy: boolean = false): string | null {
  const parts = value.trim().split(/\s+/);
  let u = P.U_NONE;
  let at = 0;
  // justify-items also takes the webkit `legacy` prefix (CSS Align 4). Its inheritance rules
  // aren't modeled, but the position it carries is the same one, and `legacy` alone behaves as
  // `normal`, which is what a browser reports for it too.
  if (allowLegacy && parts[0] === "legacy") {
    if (parts.length === 1) {
      out.push({ p, v: P.A_NORMAL, u: P.U_NONE });
      return null;
    }
    at = 1;
  }
  if (parts[0] === "safe") {
    u = P.U_SAFE;
    at = 1;
  } else if (parts[0] === "unsafe") {
    u = P.U_UNSAFE;
    at = 1;
  }
  // What is left is one keyword, or the two words of a `first baseline` / `last baseline`.
  const rest = parts.slice(at);
  if (rest.length === 0 || rest.length > 2) return `invalid value '${value}' for '${prop}'`;
  if (rest.length === 2 && !(rest[1] === "baseline" && (rest[0] === "first" || rest[0] === "last"))) {
    return `invalid value '${value}' for '${prop}'`;
  }
  const word = rest.join(" ");
  // A keyword the property doesn't take is invalid, not a feature native lacks, so it is dropped
  // the way a browser drops it — including an overflow position with no position after it, and a
  // keyword that belongs to a neighbouring property in the family.
  if (word === "safe" || word === "unsafe" || invalid.includes(word)) {
    return `invalid value '${value}' for '${prop}'`;
  }
  // The baseline positions are two words. The hyphenated spelling some style sheets carry is
  // invalid CSS, not a feature this build lacks, so the declaration is dropped as a browser
  // drops it.
  if (word === "first-baseline" || word === "last-baseline") {
    return `invalid value '${value}' for '${prop}'`;
  }
  const v = words[word];
  if (v === undefined) return `unsupported value '${value}' for '${prop}'`;
  if (u !== P.U_NONE && positions[word] === undefined) return `invalid value '${value}' for '${prop}'`;
  out.push({ p, v, u });
  return null;
}

/**
 * The one or two values a `place-*` shorthand writes — the block-axis one, then the inline-axis
 * one, which defaults to the first. A single value may carry an overflow position (`safe center`),
 * and so may the first of two (`safe center end`).
 */
export function placeValues(text: string): [string, string] | null {
  const parts = splitValue(text.trim());
  const one = valueAt(parts, 0);
  if (one === null) return null;
  if (one.at === parts.length) return [one.value, one.value];
  const two = valueAt(parts, one.at);
  if (two === null || two.at !== parts.length) return null;
  return [one.value, two.value];
}

/** One alignment value of a `place-*` shorthand: an optional overflow position, then a position
 *  keyword — where `first baseline` and `last baseline` make a value of two words. */
function valueAt(parts: string[], at: number): { value: string; at: number } | null {
  let value = "";
  if (parts[at] === "safe" || parts[at] === "unsafe") {
    value = parts[at] + " ";
    at++;
  }
  if ((parts[at] === "first" || parts[at] === "last") && parts[at + 1] === "baseline") {
    return { value: value + parts[at] + " baseline", at: at + 2 };
  }
  if (parts[at] === undefined) return null;
  return { value: value + parts[at], at: at + 1 };
}

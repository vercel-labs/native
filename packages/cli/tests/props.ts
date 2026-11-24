// The ids in shared/props.ts are positions in one table each (properties, units, pseudo kinds),
// so nothing is renumbered by hand. Check that every constant still names its slot, that the
// tables have no gaps or duplicates (a duplicate property key throws at import, which fails this
// file the same way), and that the ranges the layout relies on stay consecutive.
//   node tests/props.ts

import { readFileSync } from "node:fs";
import * as P from "../shared/props.ts";

// Ids whose constant name isn't simply the property name in CAPS_WITH_UNDERSCORES.
const ALIASES: Record<string, string> = {
  P_BORDER_SPACING_H: "border-spacing",
  P_BORDER_SPACING_V: "border-spacing",
  // The ratio and its `auto` keyword are one CSS property.
  P_ASPECT_RATIO_AUTO: "aspect-ratio",
  // Each corner has a horizontal and a vertical radius, but one CSS name between them.
  P_BORDER_TOP_LEFT_RADIUS_Y: "border-top-left-radius",
  P_BORDER_TOP_RIGHT_RADIUS_Y: "border-top-right-radius",
  P_BORDER_BOTTOM_RIGHT_RADIUS_Y: "border-bottom-right-radius",
  P_BORDER_BOTTOM_LEFT_RADIUS_Y: "border-bottom-left-radius",
  // A logical corner has the same pair of radii, named by its block and inline sides.
  P_BORDER_START_START_RADIUS_Y: "border-start-start-radius",
  P_BORDER_START_END_RADIUS_Y: "border-start-end-radius",
  P_BORDER_END_START_RADIUS_Y: "border-end-start-radius",
  P_BORDER_END_END_RADIUS_Y: "border-end-end-radius",
  // `text-decoration` is a shorthand over the line, style, colour and thickness, so this id
  // carries the one longhand that isn't a property of its own name.
  P_TEXT_DECORATION: "text-decoration-line",
  // text-decoration-inset's start and end values are one property, so the end slot keeps its name.
  P_TEXT_DECORATION_INSET_END: "text-decoration-inset",
  P_UNDERLINE_OFFSET: "text-underline-offset",
  // Companions of font-family and font-size, which carry the state those two need to resolve a
  // size that rests on the font family's medium size.
  P_FIXED_FONT: "font-family",
  P_MEDIUM_BASED: "font-size",
  // The row of the whole font-family list, beside the first family's own slot.
  P_FONT_FAMILY_LIST: "font-family",
  // The thumb colour and the track colour are one property, which prints as one pair.
  P_SCROLLBAR_COLOR_TRACK: "scrollbar-color",
  // The block and inline alignments are one property, which prints as one pair.
  P_SCROLL_SNAP_ALIGN_INLINE: "scroll-snap-align",
};

const problems: string[] = [];
const ids = Object.entries(P).filter(([k, v]) => /^P_[A-Z0-9_]+$/.test(k) && typeof v === "number") as [string, number][];
const seen = new Map<number, string>();
for (const [key, id] of ids) {
  if (seen.has(id)) problems.push(`${key} and ${seen.get(id)} share id ${id}`);
  seen.set(id, key);
  if (id < 0 || id >= P.PROP_COUNT) problems.push(`${key} = ${id} is outside 0..PROP_COUNT-1 (${P.PROP_COUNT - 1})`);
  const expected = ALIASES[key] ?? key.slice(2).toLowerCase().replace(/_/g, "-");
  const actual = P.PROPERTY_NAMES[id];
  if (actual !== expected) problems.push(`PROPERTY_NAMES[${id}] is ${JSON.stringify(actual)}, expected "${expected}" for ${key}`);
}
for (let id = 0; id < P.PROP_COUNT; id++) if (!seen.has(id)) problems.push(`no P_ constant has id ${id}`);
if (P.PROPERTY_NAMES.length !== P.PROP_COUNT) problems.push(`PROPERTY_NAMES has ${P.PROPERTY_NAMES.length} names for PROP_COUNT ${P.PROP_COUNT}`);

// Units: ids must be dense and unique, and the container-query units must stay consecutive in
// CQW, CQH, CQI, CQB, CQMIN, CQMAX order, which every `u >= U_CQW && u <= U_CQMAX` test assumes.
const unitIds = Object.entries(P).filter(([k, v]) => /^U_[A-Z0-9_]+$/.test(k) && typeof v === "number") as [string, number][];
const seenUnit = new Map<number, string>();
for (const [key, id] of unitIds) {
  if (seenUnit.has(id)) problems.push(`${key} and ${seenUnit.get(id)} share unit id ${id}`);
  seenUnit.set(id, key);
}
for (let id = 0; id < unitIds.length; id++) if (!seenUnit.has(id)) problems.push(`no U_ constant has unit id ${id}`);
const cq = [P.U_CQW, P.U_CQH, P.U_CQI, P.U_CQB, P.U_CQMIN, P.U_CQMAX];
if (cq.some((v, i) => v !== P.U_CQW + i)) problems.push(`the cq units are not consecutive from U_CQW: ${cq.join(",")}`);

// Pseudo kinds: ids dense and unique, and the tag table sized to match.
const peIds = Object.entries(P).filter(([k, v]) => /^PE_[A-Z0-9_]+$/.test(k) && typeof v === "number") as [string, number][];
const seenPe = new Map<number, string>();
for (const [key, id] of peIds) {
  if (seenPe.has(id)) problems.push(`${key} and ${seenPe.get(id)} share pseudo id ${id}`);
  seenPe.set(id, key);
}
for (let id = 0; id < peIds.length; id++) if (!seenPe.has(id)) problems.push(`no PE_ constant has pseudo id ${id}`);
if (P.PSEUDO_TAGS.length !== peIds.length) problems.push(`PSEUDO_TAGS has ${P.PSEUDO_TAGS.length} tags for ${peIds.length} kinds`);
if (P.PSEUDO_TAGS[P.PE_BEFORE] !== "#before") problems.push(`PSEUDO_TAGS[PE_BEFORE] is ${JSON.stringify(P.PSEUDO_TAGS[P.PE_BEFORE])}`);

// Every property the build parses answers to its camelCase name on a CSSStyleDeclaration, so a
// script reads and writes it the way a browser's style object does. `clear` is the one exception:
// the name is the declaration's own clear(), which drops every declaration.
const cssom = readFileSync(new URL("../runtime/cssom.ts", import.meta.url), "utf8");
const camel = (name: string): string => name.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
const noAccessor: string[] = [];
for (const name of P.PROPERTY_NAMES) {
  if (name === "clear") continue;
  const c = camel(name);
  if (!new RegExp(`get ${c}\\b`).test(cssom) || !new RegExp(`set ${c}\\b`).test(cssom)) noAccessor.push(name);
}
if (noAccessor.length > 0) problems.push(`no camelCase accessor in runtime/cssom.ts for: ${noAccessor.join(", ")}`);

if (problems.length > 0) {
  console.log("FAIL property ids and names:");
  for (const p of problems) console.log("  " + p);
  process.exit(1);
}
console.log(`ok   ${P.PROP_COUNT} property ids have matching names`);
console.log(`ok   ${unitIds.length} unit ids and ${peIds.length} pseudo ids are dense and ordered`);
console.log("\nall passed");

// A :has() argument carries a combinator separator and, for the relative `:is()` case, a subject
// marker. Specificity and state collection must see through both markers.
//   npm test

import { parseSelector, compoundStates } from "../shared/css/selectors.ts";
import * as P from "../shared/props.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const spec = (text: string): number => {
  const list = parseSelector(text);
  return list === null ? -1 : list[0].specificity;
};
const states = (text: string): number => {
  const list = parseSelector(text);
  return list === null ? 0 : compoundStates(list[0]);
};

// #t (10000) + the :has() argument's .a .b (20); the marker must not hide the argument.
check(":has() specificity survives the subject marker", spec("#t:has(> :is(.a .b))") === 10200, String(spec("#t:has(> :is(.a .b))")));
check(":has() with a plain argument still counts", spec("#t:has(.a .b)") === 10200, String(spec("#t:has(.a .b)")));

// The :hover inside the marked argument is still a state the element depends on.
check(":has() state survives the subject marker", (states("#s:has(> :is(.a:hover .b))") & P.S_HOVER) !== 0, String(states("#s:has(> :is(.a:hover .b))")));
check(":has() plain state still counts", (states("#s:has(.a:hover)") & P.S_HOVER) !== 0, String(states("#s:has(.a:hover)")));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

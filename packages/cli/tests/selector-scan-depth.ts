// A nested :where()/:is() argument is scanned and expanded once, not once per pass: nesting with
// an "of S" filter must cost linear time, not exponential.
//   npm test

import { parseSelector, setSelectorNamespaces } from "../shared/css/selectors.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check(":is(.a, :visited) keeps .a", (parseSelector(":is(.a, :visited)", true) ?? []).length === 1);
check(":where(.a) parses", parseSelector(":where(.a)", true) !== null);
check(":nth-child(2n of .a) parses", parseSelector(":nth-child(2n of .a)", true) !== null);

// A malformed item is dropped by every browser and adds no weight; a valid one that matches
// nothing here keeps its own.
const spec = (text: string): number => {
  const list = parseSelector(text, true);
  return list === null || list.length === 0 ? -1 : list[0].specificity;
};
check("a malformed :is() item weighs nothing", spec(":is(#id:nth-child(foo), .a)") === 100, String(spec(":is(#id:nth-child(foo), .a)")));
check("a :visited item keeps its weight", spec(":is(#x:visited, .a)") === 10100, String(spec(":is(#x:visited, .a)")));
// A valid item that matches nothing (an empty nested list) still weighs what it says, and a DOM
// selector's :visited inside :not() is valid there, so the item is kept.
const list = parseSelector(":is(#id:is(), .a)", true) ?? [];
check("an empty nested list keeps the item's weight", list.length === 1 && list[0].specificity === 10000, JSON.stringify(list.map((x) => x.specificity)));
const kept = parseSelector(":is(#id:not(:visited), .a)", true) ?? [];
check(":not(:visited) stays valid in a DOM selector", kept.length === 2 && kept[0].specificity === 10100, JSON.stringify(kept.map((x) => x.specificity)));

// Flag-like argument names never read as parser flags: the cache key keeps them apart.
const tags = (parseSelector(":is(p, q, nd, sd, ps)", true) ?? []).map((x) => x.tag).join(",");
check("flag-like names scan as names", tags === "p,q,nd,sd,ps", tags);

// The scan cache follows the namespace prefixes a sheet declares, never an older set.
setSelectorNamespaces(new Map([["", "http://www.w3.org/2000/svg"]]));
const svg = parseSelector("a", false);
check("a sheet's default namespace reaches the scan", svg !== null && svg[0].tagNs === "http://www.w3.org/2000/svg", JSON.stringify(svg));
setSelectorNamespaces(null);
const plain = parseSelector("a", false);
check("a new set of prefixes reads the same text anew", plain !== null && plain[0].tagNs === undefined, JSON.stringify(plain));

// 64 levels of :where(:nth-child(1 of …)): linear work, well under a second; the repeated-scan
// shape took seconds by depth 20.
let deep = ":visited";
for (let i = 0; i < 64; i++) deep = `:where(:nth-child(1 of ${deep}))`;
const started = performance.now();
parseSelector(deep, true);
const ms = performance.now() - started;
check(`64 nested arguments parse in ${ms.toFixed(1)}ms`, ms < 1000, `${ms.toFixed(1)}ms`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

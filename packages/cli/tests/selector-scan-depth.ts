// A nested :where()/:is() argument is scanned and expanded once, not once per pass: nesting with
// an "of S" filter must cost linear time, not exponential.
//   npm test

import { parseSelector } from "../shared/css/selectors.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check(":is(.a, :visited) keeps .a", (parseSelector(":is(.a, :visited)", true) ?? []).length === 1);
check(":where(.a) parses", parseSelector(":where(.a)", true) !== null);
check(":nth-child(2n of .a) parses", parseSelector(":nth-child(2n of .a)", true) !== null);

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

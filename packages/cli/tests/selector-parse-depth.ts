// A deeply nested selector argument is read a bounded number of times, and its specificity is
// taken from that one parse: nested :not()/:is() arguments made empty by :visited must not cost
// exponential time.
//   npm test

import { parseSelector } from "../shared/css/selectors.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const spec = (text: string): number => {
  const list = parseSelector(text, true);
  return list === null || list.length === 0 ? -1 : list[0].specificity;
};
check(":not(:visited div) weighs 101", spec(":not(:visited div)") === 101, String(spec(":not(:visited div)")));
check(":nth-child(1 of :visited) weighs 200", spec(":nth-child(1 of :visited)") === 200, String(spec(":nth-child(1 of :visited)")));
check(":not(.a div) weighs 101", spec(":not(.a div)") === 101, String(spec(":not(.a div)")));

// 64 nested :not(:is(…)) levels around a :visited argument: linear work, well under a second on
// any machine; the exponential shape took minutes at this depth.
let deep = ":visited";
for (let i = 0; i < 64; i++) deep = `:not(:is(${deep}))`;
const started = performance.now();
parseSelector(deep, true);
const ms = performance.now() - started;
check(`64 nested arguments parse in ${ms.toFixed(1)}ms`, ms < 1000, `${ms.toFixed(1)}ms`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

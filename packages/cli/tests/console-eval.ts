// The inspector console's expression evaluator (compiler/console-eval.ts), which stands in for
// node:vm so the native executable's console answers what the Node-run CLI's did.

import { evaluateExpression } from "../compiler/console-eval.ts";

const el: Record<string, unknown> = { id: "x", children: [1, 2, 3], querySelector: (s: string) => ({ textContent: "hi " + s }) };
const scope = {
  document: { title: "Counter", body: el, querySelector: (s: string) => (s === "#none" ? null : el) },
  Math: { max: (...xs: unknown[]) => Math.max(...xs.map(Number)) },
  calls: 0,
  bump: () => {
    scope.calls++;
    return true;
  },
};

const cases: [string, unknown][] = [
  ["1 + 2 * 3", 7],
  ["2 ** 3 ** 2", 512],
  ["(1, 2)", 2],
  ["document.title", "Counter"],
  ["document.title.length > 3 ? 'long' : 'short'", "long"],
  ["document.querySelector('#a').querySelector('b').textContent", "hi b"],
  ["document.querySelector('#none')?.id", undefined],
  ["document.body.children.length", 3],
  ["document.body.children[1]", 2],
  ["document['title']", "Counter"],
  ["Math.max(1, 5, 3)", 5],
  ["'abc'.toUpperCase()", "ABC"],
  ["\"a\\tb\"", "a\tb"],
  ["null ?? 'd'", "d"],
  ["0 || 'e'", "e"],
  ["1 && document.title", "Counter"],
  ["typeof foo", "undefined"],
  ["typeof document.title", "string"],
  ["1 == '1'", true],
  ["null == undefined", true],
  ["-(3) + +'4'", 1],
  ["!0", true],
  ["document.title.split('o').join('-')", "C-unter"],
  ["false && bump()", false],
  ["true ? 1 : bump()", 1],
];
let failed = 0;
for (const [expression, want] of cases) {
  let got: unknown;
  try {
    got = evaluateExpression(expression, scope);
  } catch (err) {
    got = `threw ${(err as Error).message}`;
  }
  if (JSON.stringify(got) === JSON.stringify(want)) console.log(`ok   ${expression}`);
  else {
    failed++;
    console.log(`FAIL ${expression}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
}
if (scope.calls !== 0) {
  failed++;
  console.log(`FAIL a branch that isn't taken ran ${scope.calls} call(s)`);
}
for (const [expression, message] of [
  ["foo", "foo is not defined"],
  ["document.querySelector('#none').id", "Cannot read properties of null (reading 'id')"],
  ["a = 1", "unexpected character '='"],
  ["new Date()", "'new' is not supported in the console"],
] as const) {
  try {
    evaluateExpression(expression, scope);
    failed++;
    console.log(`FAIL ${expression}: evaluated`);
  } catch (err) {
    if ((err as Error).message === message) console.log(`ok   ${expression} throws`);
    else {
      failed++;
      console.log(`FAIL ${expression}: threw ${(err as Error).message}, want ${message}`);
    }
  }
}
if (failed > 0) {
  console.log(`${failed} failed`);
  process.exit(1);
}
console.log("all passed");

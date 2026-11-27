// The inspector console's expression evaluator: the boundary around it.
//
// The evaluator reads the values the inspector exposes (the snapshot's DOM views, getComputedStyle,
// the console and a few JSON/Math functions) and calls the functions among them. An object literal
// that names `__proto__`, an inherited read of `constructor`, or a call of a function that happens
// to sit on a value must not lead back to the host realm's Function constructor; the compiled CLI
// runs this evaluator, so it is the boundary there. A Node run keeps a separate boundary (a fresh
// vm realm in a Node child, console-isolated.ts), which the second half of this file checks.
//
//   npm test
//
// It is written so it can run on a checkout from before the hardening too: the failing cases then
// show what the boundary used to allow (that is the regression it guards).

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const evaluator = await import("../compiler/console-eval.ts") as {
  evaluateExpression: (expression: string, scope: { [name: string]: unknown }) => unknown;
  registerConsoleFunction?: (value: unknown) => void;
};
const evaluate = evaluator.evaluateExpression;
const register = evaluator.registerConsoleFunction ?? ((): void => {});

/** Evaluates and reports either the value or the message of what it threw. */
function run(expression: string): { value?: unknown; error?: string } {
  try {
    return { value: evaluate(expression, scope) };
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) };
  }
}

// The scope the inspector builds: a document view with own methods and getters, getComputedStyle,
// a console, JSON and Math. Everything the console may call is registered.
const logs: string[] = [];
const view: { [name: string]: unknown } = {
  nodeId: 1,
  getAttribute: (name: string): string | null => (name === "id" ? "box" : null),
  getBoundingClientRect: () => ({ x: 0, y: 0, width: 10, height: 10 }),
  querySelector: () => view,
  querySelectorAll: () => [view],
  matches: () => true,
};
Object.defineProperty(view, "textContent", { get: () => "hello" });
const inherited = Object.create({ secret: "inherited" }) as { [name: string]: unknown };
inherited.own = "own";
const plainFunction = (): string => "ran";
const unregistered = { fn: plainFunction };
const documentView: { [name: string]: unknown } = {
  title: "T",
  body: view,
  documentElement: view,
  querySelector: () => view,
  querySelectorAll: () => [view],
  getElementById: () => view,
};
const getComputedStyle = (): { getPropertyValue: (name: string) => string } => {
  const style = { getPropertyValue: (name: string): string => (name === "color" ? "rgb(1, 2, 3)" : "") };
  register(style.getPropertyValue);
  return style;
};
const scope: { [name: string]: unknown } = {
  document: documentView,
  getComputedStyle,
  console: { log: (...args: unknown[]) => { logs.push(args.map(String).join(" ")); return undefined; } },
  JSON: { stringify: (value: unknown) => JSON.stringify(value), parse: (text: unknown) => JSON.parse(String(text)) },
  Math: { abs: (x: unknown) => Math.abs(Number(x)), max: (...xs: unknown[]) => Math.max(...xs.map(Number)) },
  inherited,
  unregistered,
  plainFunction,
};
register(getComputedStyle);
register(scope.console !== null && typeof scope.console === "object" ? (scope.console as { log: unknown }).log : undefined);
register((scope.JSON as { stringify: unknown }).stringify);
register((scope.JSON as { parse: unknown }).parse);
for (const name of ["abs", "max"]) register((scope.Math as { [n: string]: unknown })[name]);
for (const name of ["getAttribute", "getBoundingClientRect", "querySelector", "querySelectorAll", "matches"]) register(view[name]);
for (const name of ["querySelector", "querySelectorAll", "getElementById"]) register(documentView[name]);

// --- Reflection is not part of what the console exposes -------------------------------------
const protoLiteral = run("({__proto__: getComputedStyle})");
check("an object literal cannot name __proto__", protoLiteral.error !== undefined && /does not expose '__proto__'/.test(protoLiteral.error), protoLiteral.error ?? `built an object`);
const protoChain = run("({__proto__: getComputedStyle}).constructor('return typeof process')()");
check("a prototype-bearing literal cannot reach the host Function constructor",
  protoChain.error !== undefined && protoChain.value !== "object", protoChain.error ?? `reached ${String(protoChain.value)}`);
const setter = run("({__proto__: console.log}).constructor('return typeof process')()");
check("a literal pointed at an exposed host function cannot reach process", setter.error !== undefined || setter.value !== "object", setter.error ?? `reached ${String(setter.value)}`);
const inheritedConstructor = run("getComputedStyle.constructor('return typeof process')()");
check("an exposed function's constructor is not readable",
  inheritedConstructor.error !== undefined && /does not expose 'constructor'/.test(inheritedConstructor.error), inheritedConstructor.error ?? `reached ${String(inheritedConstructor.value)}`);
const objectConstructor = run("({a: 1}).constructor('return typeof process')()");
check("a literal's constructor is not readable",
  objectConstructor.error !== undefined && /does not expose 'constructor'/.test(objectConstructor.error), objectConstructor.error ?? `reached ${String(objectConstructor.value)}`);
const viewConstructor = run("document.querySelector('#box').constructor('return typeof process')()");
check("a DOM view's constructor is not readable",
  viewConstructor.error !== undefined && /does not expose 'constructor'/.test(viewConstructor.error), viewConstructor.error ?? `reached ${String(viewConstructor.value)}`);

// --- Only own properties are read, and only exposed functions are called ----------------------
const inheritedRead = run("inherited.secret");
check("an inherited property is not readable", inheritedRead.value === undefined, String(inheritedRead.value));
const ownRead = run("inherited.own");
check("an own property is readable", ownRead.value === "own", String(ownRead.value));
const unregisteredCall = run("unregistered.fn()");
check("a function that is not exposed is not callable",
  unregisteredCall.error !== undefined && /only calls the functions it exposes/.test(unregisteredCall.error), unregisteredCall.error ?? `ran and returned ${String(unregisteredCall.value)}`);
const bareFunctionCall = run("plainFunction()");
check("a bare function value that is not exposed is not callable",
  bareFunctionCall.error !== undefined && /only calls the functions it exposes/.test(bareFunctionCall.error), bareFunctionCall.error ?? `ran and returned ${String(bareFunctionCall.value)}`);

// --- The console still reads the page and its exposed functions ------------------------------
const domRead = run("document.querySelector('#box').getAttribute('id')");
check("the console reads the snapshot's DOM", domRead.value === "box", String(domRead.value));
const styleRead = run("getComputedStyle().getPropertyValue('color')");
check("getComputedStyle still answers", styleRead.value === "rgb(1, 2, 3)", String(styleRead.value));
const textRead = run("document.body.textContent");
check("a getter the inspector defined still answers", textRead.value === "hello", String(textRead.value));
const logged = run("console.log('hello from the console')");
check("console.log still logs", logged.error === undefined && logs.includes("hello from the console"), JSON.stringify(logs));
const stringMethod = run("'abc'.toUpperCase()");
check("string methods still work", stringMethod.value === "ABC", String(stringMethod.value));
const arrayMethod = run("[1, 2].join('-')");
check("array methods still work", arrayMethod.value === "1-2", String(arrayMethod.value));
const mathCall = run("Math.abs(-2)");
check("Math still works", mathCall.value === 2, String(mathCall.value));
const literalRead = run("({a: 1, b: 'two'}).b");
check("object literals still work", literalRead.value === "two", String(literalRead.value));

// --- A Node run keeps its own isolated boundary ---------------------------------------------
interface IsolatedConsole {
  evaluateConsole: (snapshotJson: string, expression: string) => string;
}
let isolated: IsolatedConsole | null = null;
try {
  isolated = await import("../compiler/console-isolated.ts") as IsolatedConsole;
} catch {
  isolated = null;
}
if (isolated === null) {
  console.log("skip the Node-run isolation checks: this checkout has no isolated console module yet");
} else {
  const dir = mkdtempSync(join(tmpdir(), "console-isolated-"));
  void dir;
  const snapshot = JSON.stringify({
    title: "T", width: 200, height: 100, time: 0, root: 1,
    nodes: [
      { id: 1, parent: 0, type: 9, name: "#document", attrs: [], text: "", pseudo: null, rect: null, box: null, scroll: null, styles: {}, pseudos: [], children: [2] },
      { id: 2, parent: 1, type: 1, name: "body", attrs: [["id", "box"]], text: "", pseudo: null, rect: [0, 0, 10, 10], box: null, scroll: null, styles: { color: "rgb(1, 2, 3)" }, pseudos: [], children: [] },
    ],
    layers: [], frames: [],
  });
  const answer = (expression: string): { value?: { value?: unknown }; exception?: string } => {
    const raw = JSON.parse(isolated!.evaluateConsole(snapshot, expression)) as { answer?: { value?: { value?: unknown }; exception?: string } };
    return raw.answer ?? {};
  };
  const escaped = answer("({__proto__: getComputedStyle}).constructor('return typeof process')()");
  check("Node run: the prototype-bearing literal does not reach process", escaped.exception !== undefined || escaped.value?.value === "undefined", JSON.stringify(escaped));
  const dom = answer("document.querySelector('#box').getAttribute('id')");
  check("Node run: the console reads the snapshot's DOM", dom.value?.value === "box", JSON.stringify(dom));
  const processType = answer("typeof process");
  check("Node run: process is not defined in the console", processType.value?.value === "undefined", JSON.stringify(processType));
}

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall console evaluator hardening checks passed");

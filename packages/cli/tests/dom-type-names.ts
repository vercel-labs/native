// A page that names DOM classes in its own annotations, and a framework whose declarations name
// the same classes from the browser's DOM library: one type has to answer both. A name a file
// uses only as a type is left to the program's type world, so a ref callback and an event
// target typed by the framework's declarations are the same type the page writes; a name the
// file uses as a value (instanceof) is still the runtime's own class.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head>
<body><div id="root"></div><script type="module" src="app.ts"></script></body></html>`;

// The app writes the browser's DOM class names, as an app ported from the web does, and passes
// one to a framework whose declarations type it with the browser's library.
const APP = `
import { mount, onInput } from "fw";
import { isDiv } from "./value";
const callback = (el: HTMLDialogElement | null) => { if (el !== null) console.log(el.open); };
mount(null, callback);
onInput((event: InputEvent) => {
  const field = event.target as HTMLInputElement;
  field.value = "typed";
  console.log(field.value);
});
console.log("valued " + String(isDiv));
`;

const VALUE = `
export const isDiv = document.createElement("div") instanceof HTMLElement;
`;

// A package whose declarations reference the browser's DOM library, as Preact's and React's do.
const FRAMEWORK = {
  "package.json": JSON.stringify({
    name: "fw", version: "1.0.0", type: "module",
    exports: { ".": { types: "./index.d.ts", import: "./index.js" } },
  }),
  "index.d.ts": `/// <reference lib="dom" />
export interface Marker { id: string }
export type Ref<T> = ((el: T | null) => void) | null;
export declare function mount(el: HTMLDialogElement | null, ref: Ref<HTMLDialogElement>): void;
export declare function onInput(callback: (event: InputEvent) => void): void;
`,
  "index.js": `
export function mount(el, ref) { if (typeof ref === "function") ref(el); }
export function onInput(callback) { document.addEventListener("input", callback); }
`,
};

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-dom-type-names-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
writeFileSync(join(dir, "value.ts"), VALUE);
writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({
  compilerOptions: { strict: true, lib: ["ES2022", "DOM"] },
}));
for (const [path, text] of Object.entries(FRAMEWORK)) {
  const p = join(dir, "node_modules", "fw", path);
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, text);
}

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
check("the page builds with the browser's DOM types", b.status === 0, b.stderr.slice(-1600));

const build = join(dir, ".native", "src");
const app = existsSync(join(build, "app.ts")) ? readFileSync(join(build, "app.ts"), "utf8") : "";
const value = existsSync(join(build, "value.ts")) ? readFileSync(join(build, "value.ts"), "utf8") : "";

check("a class the page only names as a type is not imported",
  !/import\s*\{[^}]*HTMLDialogElement/.test(app) && !/import\s*\{[^}]*HTMLInputElement/.test(app),
  app.split("\n")[0] ?? "");
check("the values the page uses are still imported",
  /import\s*\{[^}]*HTMLElement/.test(value) && /import\s*\{[^}]*document/.test(value),
  value.split("\n")[0] ?? "");

if (b.status === 0) {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
  check("the built page runs", r.status === 0, r.stderr.slice(-600));
  check("the value use answered at run time", r.stdout.trim() === "valued true", r.stdout.trim());
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

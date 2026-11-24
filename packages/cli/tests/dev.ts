// The dev runtime's in-place updates, mounted headlessly. The native host is replaced by a stub
// of no-op functions, so this runs on any platform; the macOS window test is out/MAC-TEST.md.
//
//   node tests/dev.ts

import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import type { HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement } from "../runtime/dom.ts";

/** The host module's functions, as no-ops: mounting the DOM needs none of them to do work. */
function stubHost(dir: string): string {
  const source = readFileSync(new URL("../runtime/host.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/export declare function (\w+)/g)].map((m) => m[1]);
  const file = join(dir, "host-stub.mjs");
  // Constants (modifier bits and the like) are copied as they are written.
  const consts = [...source.matchAll(/^export const (\w+) = ([^;\n]+);/gm)].map((m) => `export const ${m[1]} = ${m[2]};`);
  writeFileSync(file, [...names.map((name) => `export function ${name}() { return 0; }`), ...consts].join("\n"));
  return pathToFileURL(file).href;
}

const dir = mkdtempSync(join(tmpdir(), "native-dev-"));
const hostStub = stubHost(dir);
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context) as { url: string };
    if (resolved.url.endsWith("/runtime/host.ts")) return { url: hostStub, shortCircuit: true };
    return resolved;
  },
});

const { compileApp } = await import("../compiler/compile.ts");
const { Diagnostics } = await import("../compiler/diagnostics.ts");
const { writeDevData } = await import("../compiler/build.ts");
const { document, Event } = await import("../runtime/dom.ts");
const { mountDev } = await import("../runtime/app/dev.ts");
const { frame } = await import("../runtime/app/mount.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** Waits for a reload to land, up to a second. */
async function until(ok: () => boolean): Promise<boolean> {
  for (let i = 0; i < 50; i++) {
    if (ok()) return true;
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 20));
  }
  return ok();
}

const appDir = join(dir, "app");
mkdirSync(appDir, { recursive: true });
process.env.NATIVE_DEV_TABLES = join(appDir, ".native", "dev.json");
process.env.NATIVE_DEV_STATE = join(appDir, ".native", "dev-state.json");
process.env.NATIVE_DEV_CTL = join(appDir, ".native", "dev.ctl");
process.env.NATIVE_DEV_READY = join(appDir, ".native", "dev-ready");

function compile(html: string) {
  writeFileSync(join(appDir, "index.html"), html);
  const diags = new Diagnostics();
  const app = compileApp(join(appDir, "index.html"), diags);
  if (diags.errorCount > 0) throw new Error(diags.format(false));
  return app;
}

const page = (heading: string, boxClass: string, extra: string): string => `<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Dev</title><style>.a { color: red } .b { color: blue }</style></head>
  <body>
    <div id="box" class="${boxClass}"><h1>${heading}</h1>${extra}</div>
    <input id="field">
    <textarea id="notes">old</textarea>
    <select id="pick"><option value="a">A</option><option value="b">B</option></select>
    <button id="b">press</button>
  </body>
</html>`;

const v1 = compile(page("Hello", "a", ""));
writeDevData(appDir, v1);
// A relaunched executable finds the state the previous one saved before it exited.
writeFileSync(process.env.NATIVE_DEV_STATE!, JSON.stringify({
  inputs: ["field", "restored", "0", "notes", "saved", "0", "pick", "b", "0"],
  scroll: [],
  focus: "field",
  caret: "6,7",
}));
mountDev(v1.tables);
frame();
check("the dev build reports its first frame", existsSync(process.env.NATIVE_DEV_READY!) && Number(readFileSync(process.env.NATIVE_DEV_READY!, "utf8")) > 0);

const box = document.getElementById("box");
const heading = document.querySelector("h1");
const field = document.getElementById("field") as HTMLInputElement | null;
const button = document.getElementById("b");
check("the page mounts from the dev data", box !== null && heading !== null && field !== null && button !== null);
check("the markup builds the text", heading !== null && heading.textContent === "Hello");
check("the relaunch restores the saved value", field!.value === "restored", field!.value);
check("the relaunch restores focus and the caret", document.activeElement === field && field!.selectionStart === 6 && field!.selectionEnd === 7);
const notes = document.getElementById("notes") as HTMLTextAreaElement | null;
const pick = document.getElementById("pick") as HTMLSelectElement | null;
check("the relaunch restores a textarea's value", notes !== null && notes.value === "saved", notes?.value);
check("the relaunch restores a select's value", pick !== null && pick.value === "b", pick?.value);
// The caret is painted at caretEnd, so a restored selection has to move it too.
check("the caret is drawn at the restored selection", field!.caretEnd === 7, String(field!.caretEnd));
field!.setSelectionRange(2, 2);
check("setSelectionRange moves the caret", field!.caretEnd === 2, String(field!.caretEnd));
field!.setSelectionRange(6, 6);

// What a script does at startup: listeners on elements it looked up, and typed input.
let presses = 0;
button!.addEventListener("click", () => presses++);
field!.value = "typed";
button!.dispatchEvent(new Event("click"));
check("the listener runs before a reload", presses === 1);

// --- A style and text edit: the same nodes stay on the page --------------------------------

const v2 = compile(page("Hello again", "b", ""));
writeDevData(appDir, v2);
await until(() => heading!.textContent === "Hello again");

check("a style edit keeps the element", document.getElementById("box") === box);
check("the class comes from the new tables", box!.classList.value === "b", box!.classList.value);
check("a text edit updates in place", heading!.textContent === "Hello again", heading!.textContent);
check("the listener still runs", button!.parentNode !== null);
button!.dispatchEvent(new Event("click"));
check("the typed value is kept", field!.value === "typed", field!.value);
check("the listener still leaves the page alone", presses === 2);

// --- A structural edit: one element is added, and the rest keep their identity --------------

const v3 = compile(page("Hello again", "b", '<span id="s">new</span>'));
writeDevData(appDir, v3);
await until(() => document.getElementById("s") !== null);

check("an added element appears", document.getElementById("s") !== null);
check("its siblings are the same nodes", document.getElementById("box") === box && document.querySelector("h1") === heading);
check("the script's element and listener survive", document.getElementById("b") === button);
button!.dispatchEvent(new Event("click"));
check("the restored value survived too", field!.value === "typed" && presses === 3);

// --- A removal: the removed node leaves the tree, the others stay ---------------------------

const v4 = compile(page("Hello again", "b", ""));
writeDevData(appDir, v4);
await until(() => document.getElementById("s") === null);

check("the removed element is gone", document.getElementById("s") === null);
check("the remaining nodes are the same objects", document.getElementById("box") === box && document.querySelector("h1") === heading);
check("the field keeps its value", field!.value === "typed");

console.log(failed === 0 ? "all passed" : `${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

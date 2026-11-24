// The clipboard: navigator.clipboard's async API, the copy, cut and paste events with the
// DataTransfer they carry, document.execCommand, and the system pasteboard behind them. Runs are
// headless, so NATIVE_PASTEBOARD keeps the clipboard in files the test owns and checks.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300">
<style>
  body { margin: 0; }
  #word { position: absolute; left: 250px; top: 100px; margin: 0; }
  #field { position: absolute; left: 250px; top: 140px; width: 120px; }
  #btn-clip { position: absolute; left: 250px; top: 60px; width: 100px; height: 24px; }
</style></head>
<body>
<p id="word">alpha</p>
<input id="field"><button id="btn-clip">clip</button>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const field = document.getElementById("field") as HTMLInputElement;
const btn = document.getElementById("btn-clip") as HTMLElement;

// The async clipboard API, driven by a click so a paste test's own clipboard survives.
btn.addEventListener("click", async () => {
  await navigator.clipboard.writeText("written");
  log("readtext " + (await navigator.clipboard.readText()));
  await navigator.clipboard.write([new ClipboardItem({ "text/plain": "plain", "text/html": "<b>bold</b>" })]);
  const items = await navigator.clipboard.read();
  log("items " + items.length + " " + items[0].types.join(","));
  log("html " + (await (await items[0].getType("text/html")).text()));
  log("after " + (await navigator.clipboard.readText()));
});

// What the events carry: the copy and cut of a selection, the paste of a field.
document.addEventListener("copy", (e) => {
  const dt = (e as ClipboardEvent).clipboardData as DataTransfer;
  log("copyevent " + (dt === null ? "<null>" : dt.getData("text/plain")));
});
document.addEventListener("cut", (e) => {
  const dt = (e as ClipboardEvent).clipboardData as DataTransfer;
  log("cutevent " + (dt === null ? "<null>" : dt.getData("text/plain")));
});
field.addEventListener("paste", (e) => {
  const dt = (e as ClipboardEvent).clipboardData as DataTransfer;
  log("pasteevent " + dt.types.join(",") + "|" + dt.getData("text/plain") + "|" + dt.getData("text/html"));
});

// document.execCommand: Shift-Enter copies, Alt-Enter cuts, Ctrl-Enter pastes, all in the field.
field.addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  if (e.shiftKey) {
    e.preventDefault();
    log("execcopy " + document.execCommand("copy") + " field [" + field.value + "]");
  } else if (e.altKey) {
    e.preventDefault();
    log("execcut " + document.execCommand("cut") + " field [" + field.value + "]");
  } else if (e.ctrlKey) {
    e.preventDefault();
    log("execpaste " + document.execCommand("paste") + " field [" + field.value + "]");
  }
});
log("supported " + document.queryCommandSupported("copy") + " " + document.queryCommandSupported("animate"));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-clipboard-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const board = join(dir, "pasteboard.txt");
const boardHtml = board + ".html";

/** Runs the app with these steps, starting from a clipboard holding what `seed` says. */
function run(name: string, steps: string, seed: { text?: string; html?: string } = {}): string[] {
  writeFileSync(board, seed.text === undefined ? "" : seed.text);
  if (seed.html === undefined) rmSync(boardHtml, { force: true });
  else writeFileSync(boardHtml, seed.html);
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps, NATIVE_PASTEBOARD: board };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`${name} failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

function expect(name: string, got: string[], want: string[]): void {
  for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
  check(`${name}: log lines (${want.length})`, got.length === want.length, `got ${got.length}`);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    check(`${name}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
  }
}

// 1. The async API, and a copy from the page's selection.
expect("api", run("api run", [
  "click #btn-clip",
  "wait 50",
  "dblclick #word",
  "key Meta+Copy",
  "wait 50",
].join(" | ")), [
  "supported true false",
  "readtext written",
  "items 1 text/plain,text/html",
  "html <b>bold</b>",
  "after plain",
  "copyevent alpha",
]);
const copied = readFileSync(board, "utf8");
check("copy wrote the pasteboard", copied === "alpha", `got ${JSON.stringify(copied)}`);
check("copy dropped the old markup", !existsSync(boardHtml));

// 2. A paste into a field, from a clipboard holding text and markup.
expect("paste", run("paste run", [
  "click #field",
  "type AB",
  "key Meta+Paste",
  "print #field",
  "wait 50",
].join(" | "), { text: "PASTED", html: "<i>it</i>" }), [
  "supported true false",
  "pasteevent text/plain,text/html|PASTED|<i>it</i>",
  "ABPASTED",
]);

// 3. document.execCommand copies, cuts and pastes a field's selection.
expect("execCommand", run("command run", [
  "click #field",
  "type abcdef",
  "key Meta+SelectAll",
  "key Shift+Enter",
  "key Alt+Enter",
  "key Ctrl+Enter",
  "print #field",
  "wait 50",
].join(" | ")), [
  "supported true false",
  "copyevent abcdef",
  "execcopy true field [abcdef]",
  "cutevent abcdef",
  "execcut true field []",
  "pasteevent text/plain|abcdef|",
  "execpaste true field [abcdef]",
  "abcdef",
]);
const cut = readFileSync(board, "utf8");
check("cut left the text on the pasteboard", cut === "abcdef", `got ${JSON.stringify(cut)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

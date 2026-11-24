// IME composition in a text field: the marked text an input method shows, the events a page sees
// around it, and what commits, cancels, a selection replacement and a blur leave in the value.
// The steps drive the same functions the host's composition events call, so the runtime path is
// the one a real input method takes on macOS.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=420, height=320"><style>
body { margin: 0; font: 16px monospace; }
input, textarea { display: block; width: 200px; }
</style></head><body>
<input id="q">
<textarea id="t"></textarea>
<input id="s" value="hello">
<input id="pw" type="password">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const q = document.getElementById("q") as HTMLInputElement;
const t = document.getElementById("t") as HTMLTextAreaElement;
const s = document.getElementById("s") as HTMLInputElement;
const pw = document.getElementById("pw") as HTMLInputElement;
function watch(el: HTMLInputElement | HTMLTextAreaElement): void {
  el.addEventListener("compositionstart", (e: any) => log(el.id + " compositionstart [" + e.data + "]"));
  el.addEventListener("compositionupdate", (e: any) => log(el.id + " compositionupdate [" + e.data + "]"));
  el.addEventListener("compositionend", (e: any) => log(el.id + " compositionend [" + e.data + "]"));
  el.addEventListener("input", (e: any) => log(el.id + " input " + e.inputType + " " + e.isComposing + " [" + el.value + "]"));
  el.addEventListener("keydown", (e: any) => log(el.id + " keydown " + e.key + " " + e.isComposing));
}
watch(q);
watch(t);
watch(s);
watch(pw);
s.addEventListener("click", () => s.setSelectionRange(1, 3));
`;

const STEPS = [
  "click #q",
  "compose k",
  "print #q",
  "type x",
  "print #q",
  "compose こ",
  "commit こ",
  "print #q",
  "selection #q",
  "compose a",
  "cancelcompose",
  "print #q",
  "compose b",
  "key Escape",
  "print #q",
  "compose c",
  "key Enter",
  "print #q",
  "click #t",
  "compose a",
  "commit あ",
  "print #t",
  "click #s",
  "wait 20",
  "compose X",
  "print #s",
  "commit Y",
  "print #s",
  "selection #s",
  "click #q",
  "compose z",
  "click #t",
  "print #q",
  "click #pw",
  "compose p",
  "commit パ",
  "print #pw",
  "selection #pw",
].join(" | ");

const EXPECTED = [
  "q compositionstart [k]",
  "q compositionupdate [k]",
  "q input insertCompositionText true [k]",
  "k",
  "q keydown x true",
  "k",
  "q compositionupdate [こ]",
  "q input insertCompositionText true [こ]",
  "q compositionend [こ]",
  "q input insertFromComposition false [こ]",
  "こ",
  "sel 1,1",
  "q compositionstart [a]",
  "q compositionupdate [a]",
  "q input insertCompositionText true [こa]",
  "q compositionend []",
  "q input deleteCompositionText false [こ]",
  "こ",
  "q compositionstart [b]",
  "q compositionupdate [b]",
  "q input insertCompositionText true [こb]",
  "q keydown Escape true",
  "q compositionend []",
  "q input deleteCompositionText false [こ]",
  "こ",
  "q compositionstart [c]",
  "q compositionupdate [c]",
  "q input insertCompositionText true [こc]",
  "q keydown Enter true",
  "q compositionend [c]",
  "q input insertFromComposition false [こc]",
  "こc",
  "t compositionstart [a]",
  "t compositionupdate [a]",
  "t input insertCompositionText true [a]",
  "t compositionend [あ]",
  "t input insertFromComposition false [あ]",
  "あ",
  "s compositionstart [X]",
  "s compositionupdate [X]",
  "s input insertCompositionText true [hXlo]",
  "hXlo",
  "s compositionend [Y]",
  "s input insertFromComposition false [hYlo]",
  "hYlo",
  "sel 2,2",
  "q compositionstart [z]",
  "q compositionupdate [z]",
  "q input insertCompositionText true [こcz]",
  "q compositionend [z]",
  "q input insertFromComposition false [こcz]",
  "こcz",
  "pw compositionstart [p]",
  "pw compositionupdate [p]",
  "pw input insertCompositionText true [p]",
  "pw compositionend [パ]",
  "pw input insertFromComposition false [パ]",
  "パ",
  "sel 1,1",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-composition-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: STEPS };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

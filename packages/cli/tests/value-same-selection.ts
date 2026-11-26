// Writing a field's value with the text it already holds changes nothing, and in particular
// leaves the caret where the page put it, as a browser does. A controlled field depends on it: a
// framework rewrites a field's value after every keystroke, so a setter that moved the caret to
// the end would send each following character to the end of the field.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=200">
<style>body { margin: 8px; } input, textarea { display: block; width: 240px; margin-bottom: 8px; }</style>
</head><body>
<input id="i" type="text" value="hello">
<textarea id="t">hello</textarea>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const i = document.getElementById("i") as HTMLInputElement;
const t = document.getElementById("t") as HTMLTextAreaElement;
// The same text written back keeps the caret at 2 in both fields.
i.setSelectionRange(2, 2);
i.value = i.value;
t.value = "hello";
t.setSelectionRange(2, 2);
t.value = t.value;
// A controlled field's framework rewrites the value on every input event.
t.addEventListener("input", () => { t.value = t.value; });
t.focus();
t.setSelectionRange(2, 2);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-value-same-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
console.log("ok   builds");

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 0 | selection #i | selection #t | type x | type y | print #t | selection #t",
  },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.split("\n").slice(0, -1);
const want = ["sel 2,2", "sel 2,2", "hexyllo", "sel 4,4"];
check("the caret survives a same-value write, and typing stays at the caret", JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}`);

if (failed > 0) {
  console.error(`${failed} check(s) failed`);
  process.exit(1);
}
console.log("all checks passed");

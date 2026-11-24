// A focused <textarea> edits its own text: typing inserts at the caret, Enter is a newline,
// Backspace and Delete cut around it, the arrows and Home/End walk the lines, and every edit sends
// input. Chrome's answers on the same keys are the expectations here.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200"><style>
body { margin: 0; font: 13px monospace; }
#t { width: 200px; display: block; }
#p { width: 200px; display: block; }
</style></head><body>
<textarea id="t">ab
cd</textarea>
<textarea id="p" rows="2"></textarea>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const t = document.getElementById("t") as HTMLTextAreaElement;
t.addEventListener("input", () => log("input " + JSON.stringify(t.value) + " " + t.selectionStart + "," + t.selectionEnd));
// A browser puts the caret at 0 when a never-focused textarea takes focus, and setting the value
// of the focused field then puts the caret after it (Chrome, measured).
t.focus();
t.value = "ab\\ncd";
log("start " + JSON.stringify(t.value) + " " + t.selectionStart + "," + t.selectionEnd);
log("focused " + String(document.activeElement === t));

// A second field with four lines in two rows, for the pointer and the line keys.
const p = document.getElementById("p") as HTMLTextAreaElement;
p.value = "abc\\ndef\\nghi\\njkl";
p.addEventListener("pointerup", () => log("caret " + p.selectionStart + "," + p.selectionEnd));
p.addEventListener("keyup", () => log("key " + p.selectionStart + " " + Math.round(p.scrollTop)));
`;

const STEPS = [
  // Typing inserts at the caret, which the value left at the end.
  { steps: "key X | key Y", want: [
    'input "ab\\ncdX" 6,6',
    'input "ab\\ncdXY" 7,7',
  ] },
  // Enter makes a newline where the caret is, and typing carries on after it.
  { steps: "key Enter | key Z", want: [
    'input "ab\\ncd\\n" 6,6',
    'input "ab\\ncd\\nZ" 7,7',
  ] },
  // Home takes the caret to the start of its line; Backspace there cuts the newline before it.
  { steps: "key Home | key Backspace", want: [
    'input "abcd" 2,2',
  ] },
  // Arrows and Home/End move the caret without editing, so they send no input.
  { steps: "key ArrowLeft | key Home | key End", want: [] },
  // Delete with the caret at the end has nothing to cut.
  { steps: "key Delete", want: [] },
  // A typed run sends one input per character.
  { steps: "type hi", want: [
    'input "ab\\ncdh" 6,6',
    'input "ab\\ncdhi" 7,7',
  ] },
  // Shift+Home selects the line's text, and typing replaces it.
  { steps: "key Shift+Home | type Z", want: [
    'input "ab\\nZ" 4,4',
  ] },
  // The pointer puts the caret where it is (Chrome: point offsets within the line), and a drag
  // takes the selection with it. #p starts at y=36, its first line's text at y≈39.
];

// The field's own steps run after a press, so the caret logs come from the pointer listeners.
const POINTER: { steps: string; want: string[] }[] = [
  { steps: "clickat 5 46", want: ["caret 0,0"] },
  { steps: "clickat 100 46", want: ["caret 3,3"] },
  { steps: "clickat 5 61", want: ["caret 4,4"] },
  { steps: "dragat 100 46 5 61", want: ["caret 3,4"] },
  // Two downs put the caret on the third line, which scrolls it into view. Chrome reports 13 here;
  // its line box is 15.33px against our integer 15, so the same rule lands one pixel lower.
  // Each ArrowDown is a press and a release; the field hears the keyup after the caret moved.
  { steps: "clickat 5 46 | key ArrowDown | key ArrowDown | selection #p | scrolltop #p",
    want: ["caret 0,0", "key 4 0", "key 8 12", "sel 8,8", "12"] },
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-textarea-edit-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

const base = run("");
// A caret index into "ab\ncd": 0 a, 1 b, 2 the newline, 3 c, 4 d, 5 the end.
for (const line of base) console.log(`     got ${JSON.stringify(line)}`);
check("the field starts with the caret after its text", base[0] === 'start "ab\\ncd" 5,5', base[0]);
check("focus lands on the field", base[1] === "focused true", base[1]);

for (const { steps, want } of POINTER) {
  const got = run(steps).slice(2);
  for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
  check(`${steps} (${want.length} lines)`, got.length === want.length, `got ${got.length}: ${got.join(" | ")}`);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    check(`${steps}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
  }
}

for (const { steps, want } of STEPS) {
  const got = run(steps).slice(2);
  check(`${steps} (${want.length} lines)`, got.length === want.length, `got ${got.length}: ${got.join(" | ")}`);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    check(`${steps}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

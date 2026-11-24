// The form state pseudo-classes: :checked, :default, :indeterminate, :disabled, :enabled,
// :required, :optional, :read-only, :read-write, :placeholder-shown, :valid, :invalid,
// :in-range, :out-of-range and :focus-within. Their state comes from a control's attributes,
// value and validity rather than from input events, so this checks that a rule sees the control
// as it is when the style is asked for: through a sibling or ancestor selector, through a DOM
// query, and through a sheet added at runtime.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
label, input, div { color: rgb(0, 0, 0); }
#agree:checked + #agree-label { color: rgb(1, 0, 0); }
#def:default { color: rgb(2, 0, 0); }
#go:default { color: rgb(3, 0, 0); }
#ind:indeterminate { color: rgb(4, 0, 0); }
fieldset:disabled input { color: rgb(5, 0, 0); }
#off:enabled { color: rgb(6, 0, 0); }
#req:required { color: rgb(7, 0, 0); }
#opt:optional { color: rgb(8, 0, 0); }
#rw:read-write { color: rgb(9, 0, 0); }
#ro:read-only { color: rgb(10, 0, 0); }
#ph:placeholder-shown { color: rgb(11, 0, 0); }
#ok:valid { color: rgb(12, 0, 0); }
#bad:invalid { color: rgb(13, 0, 0); }
#inr:in-range { color: rgb(14, 0, 0); }
#out:out-of-range { color: rgb(15, 0, 0); }
#wrap:focus-within { color: rgb(16, 0, 0); }
#dark:not(:checked) + #dark-label { color: rgb(17, 0, 0); }
</style></head><body>
<form id="f">
  <input id="agree" type="checkbox"><label id="agree-label">agree</label>
  <input id="def" type="checkbox" checked>
  <input id="ind" type="checkbox">
  <input id="off" type="text">
  <input id="req" type="text" required>
  <input id="opt" type="text">
  <input id="rw" type="text">
  <input id="ro" type="text" readonly>
  <input id="ph" type="text" placeholder="name">
  <input id="ok" type="text" required value="x">
  <input id="bad" type="text" required>
  <input id="inr" type="number" min="0" max="10" value="5">
  <input id="out" type="number" min="0" max="10" value="50">
  <button id="go">go</button>
</form>
<fieldset id="fs" disabled><input id="inside" type="text"></fieldset>
<div id="wrap"><input id="wrapped" type="text"></div>
<input id="dark" type="checkbox"><label id="dark-label">dark</label>
<input id="dyn" type="checkbox"><label id="dyn-label">dyn</label>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;
const color = (id: string): string => getComputedStyle(byId(id)).color;

const agree = byId("agree") as HTMLInputElement;
const ind = byId("ind") as HTMLInputElement;
const off = byId("off") as HTMLInputElement;
const fs = byId("fs");
const inside = byId("inside") as HTMLInputElement;
const ph = byId("ph") as HTMLInputElement;
const dark = byId("dark") as HTMLInputElement;
const dyn = byId("dyn") as HTMLInputElement;
const wrapped = byId("wrapped") as HTMLInputElement;

// --- a state a script sets restyles a sibling through the compiled rule
log("label " + color("agree-label"));
agree.checked = true;
log("checked " + color("agree-label"));
agree.checked = false;
log("unchecked " + color("agree-label"));

// --- the checked attribute and a form's first submit button are :default
log("default " + color("def") + " " + color("go"));

// --- a checkbox a script put between the two states
log("ind before " + ind.matches(":indeterminate"));
ind.indeterminate = true;
log("indeterminate " + color("ind") + " " + ind.matches(":indeterminate"));

// --- a disabled fieldset disables the controls in it, and taking it away enables them again
log("fieldset " + color("inside") + " " + inside.matches(":disabled") + " " + inside.matches(":enabled"));
fs.removeAttribute("disabled");
log("fieldset off " + color("inside") + " " + inside.matches(":disabled"));
log("off enabled " + color("off") + " " + off.matches(":enabled"));

// --- required and optional
log("required " + color("req") + " " + color("opt"));

// --- a text field is writable unless it is read-only
log("read " + color("rw") + " " + color("ro"));

// --- the placeholder a field shows while it is empty
log("placeholder " + color("ph") + " " + ph.matches(":placeholder-shown"));
ph.value = "x";
log("filled " + color("ph") + " " + ph.matches(":placeholder-shown"));

// --- required fields with and without a value
log("valid " + color("ok") + " invalid " + color("bad"));

// --- a number field's value against its min and max
log("range " + color("inr") + " " + color("out"));

// --- a state inside :not()
log("not checked " + color("dark-label"));
dark.checked = true;
log("dark checked " + color("dark-label"));

// --- focus inside an element
log("within " + color("wrap"));
wrapped.focus();
log("focused within " + color("wrap") + " " + byId("wrap").matches(":focus-within"));

// --- the same states through DOM queries
log("queries checked " + document.querySelectorAll(":checked").length +
  " required " + document.querySelectorAll(":required").length +
  " invalid " + document.querySelectorAll(":invalid").length +
  " out of range " + document.querySelectorAll(":out-of-range").length);

// --- a sheet added at runtime matches a control that changes afterwards
const sheet = new CSSStyleSheet();
sheet.replaceSync("#dyn:checked + #dyn-label { color: rgb(20, 0, 0); }");
document.adoptedStyleSheets = [sheet];
log("runtime before " + color("dyn-label"));
dyn.checked = true;
log("runtime checked " + color("dyn-label"));

// --- an element a script made, outside the page
const made = document.createElement("input") as HTMLInputElement;
made.setAttribute("type", "checkbox");
made.checked = true;
log("made " + made.matches(":checked") + " " + made.matches(":enabled") + " " +
  made.matches(":default") + " " + made.matches(":indeterminate"));
`;

const EXPECTED_LOG = [
  "label rgb(0, 0, 0)",
  "checked rgb(1, 0, 0)",
  "unchecked rgb(0, 0, 0)",
  "default rgb(2, 0, 0) rgb(3, 0, 0)",
  "ind before false",
  "indeterminate rgb(4, 0, 0) true",
  "fieldset rgb(5, 0, 0) true false",
  "fieldset off rgb(0, 0, 0) false",
  "off enabled rgb(6, 0, 0) true",
  "required rgb(7, 0, 0) rgb(8, 0, 0)",
  "read rgb(9, 0, 0) rgb(10, 0, 0)",
  "placeholder rgb(11, 0, 0) true",
  "filled rgb(0, 0, 0) false",
  "valid rgb(12, 0, 0) invalid rgb(13, 0, 0)",
  "range rgb(14, 0, 0) rgb(15, 0, 0)",
  "not checked rgb(17, 0, 0)",
  "dark checked rgb(0, 0, 0)",
  "within rgb(0, 0, 0)",
  "focused within rgb(16, 0, 0) true",
  "queries checked 2 required 3 invalid 3 out of range 1",
  "runtime before rgb(0, 0, 0)",
  "runtime checked rgb(20, 0, 0)",
  "made true true false false",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-form-css-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

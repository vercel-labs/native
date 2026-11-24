// The date and time fields: the value syntaxes of date, month, week, time and datetime-local, the
// segments a user edits with the keyboard, min/max/step validation, valueAsDate and valueAsNumber,
// the input and change events, and the calendar popup the field's button opens.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=500"><style>
body { margin: 0; font: 16px sans-serif; background: #ffffff; }
#cover { position: absolute; left: 0; top: 30px; width: 400px; height: 470px; background: #ff0000; }
input { position: absolute; left: 10px; font-size: 16px; width: 220px; z-index: 1; }
#d { top: 10px; }
#t { top: 48px; }
#m { top: 86px; }
#w { top: 124px; }
#dt { top: 162px; }
#pick { top: 200px; }
</style></head><body>
<div id="cover"></div>
<input type="date" id="d" value="2024-05-03">
<input type="time" id="t" value="13:45">
<input type="month" id="m" value="2024-05">
<input type="week" id="w" value="2024-W20">
<input type="datetime-local" id="dt" value="2024-05-15T13:45">
<input type="date" id="pick">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function mk(type: string): HTMLInputElement { const el = document.createElement("input"); el.type = type; return el; }
function vad(el: HTMLInputElement): string { const v = el.valueAsDate; return v === null ? "null" : String(v.getTime()); }
function val(el: HTMLInputElement): string { return "[" + el.value + "]"; }

// The value syntaxes: a value that isn't one the type accepts becomes nothing.
const a = mk("date"); a.value = "2024-02-30"; log("invalid date " + val(a));
a.value = "2016-02-29"; log("leap date " + val(a));
const b = mk("month"); b.value = "13-06"; log("invalid month " + val(b));
b.value = "20133-12"; log("long year " + val(b));
const c = mk("week"); c.value = "2014-W53"; log("week 53 of 52 " + val(c));
c.value = "2015-W53"; log("week 53 of 53 " + val(c));
const e = mk("time"); e.value = "24:00"; log("invalid time " + val(e));
e.value = "12:00:00.001"; log("time fraction " + val(e));
const f = mk("datetime-local");
f.value = "2014-01-01 11:11:11.111";
log("datetime space " + val(f));
f.value = "2014-01-01 00:00:00.000";
log("datetime zeros " + val(f));

// valueAsNumber: milliseconds, except a month's count of months.
const g = mk("date"); g.value = "2019-12-10"; log("date number " + g.valueAsNumber);
const h = mk("month"); h.value = "2019-12"; log("month number " + h.valueAsNumber);
const i = mk("week"); i.value = "2019-W50"; log("week number " + i.valueAsNumber);
const j = mk("time"); j.value = "12:00"; log("time number " + j.valueAsNumber);
const k = mk("datetime-local"); k.value = "2019-12-10T12:00"; log("datetime number " + k.valueAsNumber);
const n1 = mk("date"); log("empty number " + String(n1.valueAsNumber));

// valueAsNumber writes.
const l = mk("date"); l.valueAsNumber = 0; log("date from 0 " + val(l));
const m = mk("month"); m.valueAsNumber = -1; log("month from -1 " + val(m));
const n = mk("week"); n.valueAsNumber = 0; log("week from 0 " + val(n));
const o = mk("time"); o.valueAsNumber = -3600000; log("time from -1h " + val(o));
const p = mk("datetime-local"); p.valueAsNumber = 1575979200000; log("datetime from ms " + val(p));

// valueAsDate reads the day, the week's Monday, the month's first day or the time of day.
const q = mk("date"); q.value = "2019-12-10"; log("date date " + vad(q));
const r = mk("month"); r.value = "2019-12"; log("month date " + vad(r));
const s = mk("week"); s.value = "2019-W50"; log("week date " + vad(s));
const t = mk("time"); t.value = "12:00"; log("time date " + vad(t));
const u = mk("datetime-local"); u.value = "2019-12-10T12:00";
log("datetime date " + vad(u) + " same " + String(u.valueAsDate === null));
try { u.valueAsDate = new Date(0); } catch (err) { log("datetime date write threw"); }

// A date field has no variable-length selection.
const v = mk("month"); v.value = "2024-05";
log("selection " + String(v.selectionStart) + " " + String(v.selectionEnd) + " " + String(v.selectionDirection));
try { v.setSelectionRange(0, 0); } catch (err) { log("selection threw"); }

// Stepping: by a day, a month, a week, or the field's own step.
const w1 = mk("date"); w1.value = "2024-05-03"; w1.stepUp(); log("date step up " + val(w1));
w1.stepDown(2); log("date step down " + val(w1));
const w2 = mk("month"); w2.value = "2024-05"; w2.stepUp(); log("month step " + val(w2));
const w3 = mk("week"); w3.value = "2024-W20"; w3.stepUp(); log("week step " + val(w3));
const w4 = mk("time"); w4.step = "0.001"; w4.value = "12:00"; w4.stepUp(); log("time fine step " + val(w4));
const w5 = mk("date"); w5.stepUp(); log("empty step has value " + String(w5.value !== ""));
const w6 = mk("date"); w6.step = "any";
try { w6.stepUp(); } catch (err) { log("any step threw"); }
const w7 = mk("text");
try { w7.stepUp(); } catch (err) { log("text step threw"); }

// min, max and step constraints.
const x1 = mk("date"); x1.min = "2024-06-01"; x1.value = "2024-05-03";
log("under " + String(x1.validity.rangeUnderflow) + " " + String(x1.validity.valid));
const x2 = mk("date"); x2.max = "2024-01-01"; x2.value = "2024-05-03";
log("over " + String(x2.validity.rangeOverflow) + " " + String(x2.validity.valid));
const x3 = mk("date"); x3.min = "2024-01-01"; x3.step = "3"; x3.value = "2024-01-02";
log("step mismatch " + String(x3.validity.stepMismatch) + " " + String(x3.validity.valid));
const x4 = mk("time"); x4.min = "01:01:01.001"; x4.max = "12:12:12.012"; x4.step = "600";
log("attrs [" + x4.min + "] [" + x4.max + "] [" + x4.step + "]");

// The live fields send input and change when a user edits them.
const d = document.getElementById("d") as HTMLInputElement;
const pick = document.getElementById("pick") as HTMLInputElement;
for (const el of [d, pick]) {
  el.addEventListener("input", () => log(el.id + " input " + el.value));
  el.addEventListener("change", () => log(el.id + " change " + el.value));
}
window.addEventListener("load", () => {
  const r = d.getBoundingClientRect();
  log("d box " + r.left + "," + r.top + "," + r.width + "," + r.height);
  log("ready");
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-date-input-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string, snapshot = ""): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
  if (snapshot !== "") env.NATIVE_SNAPSHOT = snapshot;
  else delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

function has(name: string, out: string[], line: string): void {
  check(name, out.indexOf(line) >= 0, `no line ${JSON.stringify(line)}\n     got: ${JSON.stringify(out)}`);
}

const base = run("print body");
const want = [
  "invalid date []",
  "leap date [2016-02-29]",
  "invalid month []",
  "long year [20133-12]",
  "week 53 of 52 []",
  "week 53 of 53 [2015-W53]",
  "invalid time []",
  "time fraction [12:00:00.001]",
  "datetime space [2014-01-01T11:11:11.111]",
  "datetime zeros [2014-01-01T00:00]",
  "date number 1575936000000",
  "month number 599",
  "week number 1575849600000",
  "time number 43200000",
  "datetime number 1575979200000",
  "empty number NaN",
  "date from 0 [1970-01-01]",
  "month from -1 [1969-12]",
  "week from 0 [1970-W01]",
  "time from -1h [23:00]",
  "datetime from ms [2019-12-10T12:00]",
  "date date 1575936000000",
  "month date 1575158400000",
  "week date 1575849600000",
  "time date 43200000",
  "datetime date null same true",
  "datetime date write threw",
  "selection null null null",
  "selection threw",
  "date step up [2024-05-04]",
  "date step down [2024-05-02]",
  "month step [2024-06]",
  "week step [2024-W21]",
  "time fine step [12:00:00.001]",
  "empty step has value true",
  "any step threw",
  "text step threw",
  "under true false",
  "over true false",
  "step mismatch true false",
  "attrs [01:01:01.001] [12:12:12.012] [600]",
  "ready",
];
for (const line of want) has(`value model: ${line}`, base, line);
check("no page errors", base.filter((l) => l.indexOf("RUNTIME") >= 0).length === 0, JSON.stringify(base));

// Typing fills the segments: month, then day, then year, and Enter sends change.
const typed = run("click #pick | key Home | type 05152025 | key Enter | print body");
has("typed value", typed, "pick input 2025-05-15");
has("typed change", typed, "pick change 2025-05-15");

// The arrows step the edited segment, and Backspace clears it.
const stepped = run("click #d | key Home | key ArrowUp | key ArrowRight | key ArrowUp | print body");
has("stepped month", stepped, "d input 2024-06-03");
has("stepped day", stepped, "d input 2024-06-04");
const cleared = run("click #d | key Home | type 06 | key Backspace | print body");
check("backspace clears the value", cleared.filter((l) => l === "d input ").length >= 1, JSON.stringify(cleared));

// The button opens the calendar over the page, and a day click picks it.
const picked = run("clickat 216 19 | clickat 144 169 | print body");
has("picker input", picked, "d input 2024-05-15");
has("picker change", picked, "d change 2024-05-15");

// The calendar covers the red box behind the field; the map's inside is white, the page beside it red.
const shot = join(dir, "picker.png");
const openOut = run("clickat 216 19", shot);
check("picker run", openOut.length > 0);
const img = decodePng(shot);
function pixel(x: number, y: number): number[] {
  const at = (y * img.w + x) * 4;
  return [img.rgba[at], img.rgba[at + 1], img.rgba[at + 2], img.rgba[at + 3]];
}
const inside = pixel(500, 120); // (250, 60) CSS px, in the calendar's header
check("calendar paints over the page", inside[0] > 240 && inside[1] > 240 && inside[2] > 240, JSON.stringify(inside));
const outside = pixel(700, 120); // (350, 60), right of the 272px popup
check("page shows beside the calendar", outside[0] > 240 && outside[1] < 20 && outside[2] < 20, JSON.stringify(outside));

// Escape closes it again, and the page shows through.
const closed = join(dir, "closed.png");
run("clickat 216 19 | key Escape", closed);
const img2 = decodePng(closed);
function pixel2(x: number, y: number): number[] {
  const at = (y * img2.w + x) * 4;
  return [img2.rgba[at], img2.rgba[at + 1], img2.rgba[at + 2], img2.rgba[at + 3]];
}
const after = pixel2(500, 120);
check("escape closes the calendar", after[0] > 240 && after[1] < 20 && after[2] < 20, JSON.stringify(after));

// A read-only date field keeps its value through the keyboard.
const roPage = PAGE.replace('<input type="date" id="pick">', '<input type="date" id="pick" readonly value="1970-01-01">');
writeFileSync(join(dir, "index.html"), roPage);
const roExe = join(dir, "ro");
const roBuild = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", roExe], { encoding: "utf8" });
if (roBuild.status !== 0) throw new Error(`readonly build failed\n${roBuild.stderr}`);
const ro = spawnSync(roExe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "click #pick | key Home | key ArrowDown | key Enter | print body" },
});
const roOut = ro.stdout.split("\n").slice(0, -1);
check("readonly keeps its value", roOut.indexOf("pick change 1970-01-01") < 0 && roOut.some((l) => l === "ready"),
  JSON.stringify(roOut));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

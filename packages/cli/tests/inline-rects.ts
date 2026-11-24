// Regression tests for getBoundingClientRect and getClientRects on inline boxes: an inline box
// reports one rect per run of content per line (a line break and a nested inline box split it),
// each the box's font box plus its vertical padding and border, with its margins left out, and
// the bounding rect is the union of those. Every expected line was taken from Chrome.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=900"><style>
body { margin: 0; width: 200px; font-family: system-ui; font-size: 16px; }
</style></head><body>
<div style="line-height:normal"><span id="a">x</span></div>
<div style="line-height:30px"><span id="b">x</span></div>
<div style="line-height:10px"><span id="c">x</span></div>
<div style="font-size:30px;line-height:normal"><span id="d">x</span></div>
<div><span id="e" style="padding:3px;border:1px solid #000;margin:2px">x</span></div>
<div><span id="f"></span></div>
<div><span id="g">one</span> <span id="h">two</span></div>
<div><span id="i">ab<span id="j">cd</span>ef</span></div>
<div><span id="k">x y</span></div>
<div style="display:none"><span id="n">x</span></div>
<div><span id="m1" style="margin:0 5px">m</span></div>
<div><span id="p1">a<span id="ib" style="display:inline-block;width:20px;height:10px;margin:3px"></span>b</span></div>
<div style="width:60px"><span id="w1">inline span across lines</span></div>
<div style="height:50px"></div>
<div id="col" style="width:100px;height:20px;margin-top:-100px;background:#ddd"><span><div style="margin-top:100px;height:5px"></div></span></div>
<script src="app.ts"></script>
</body></html>`;

// The rects are laid out by the first frame, so every read happens from inside a later one.
const SCRIPT = `
const out: string[] = [];
function n(v: number): number { return Math.round(v * 100) / 100; }
function rects(e: Element): string {
  const list = e.getClientRects();
  const parts: string[] = [];
  for (let i = 0; i < list.length; i++) parts.push([list[i].left, list[i].top, list[i].width, list[i].height].map(n).join(","));
  return parts.join(" | ");
}
function line(id: string): void {
  const e = document.getElementById(id) as Element;
  const r = e.getBoundingClientRect();
  out.push(id + " bcr=" + [r.left, r.top, r.width, r.height].map(n).join(",") + " rects=" + rects(e));
}
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    for (const id of ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "n", "m1", "p1", "ib", "w1", "col"]) line(id);
    const lone = document.createElement("span");
    out.push("detached=" + n(lone.getBoundingClientRect().width) + " " + lone.getClientRects().length);
    for (const s of out) console.log(s);
  });
});
`;

// The lines Chrome prints for the same page and script.
const EXPECTED_LOG: [string, string][] = [
  ["an inline box's rect is its font box, not its line height", "a bcr=0,0,8.08,18 rects=0,0,8.08,18"],
  ["a taller line box leaves the rect where it is", "b bcr=0,24,8.08,18 rects=0,24,8.08,18"],
  ["a shorter line box doesn't clip the rect", "c bcr=0,44,8.08,18 rects=0,44,8.08,18"],
  ["a larger font makes a taller rect", "d bcr=0,58,14.45,35 rects=0,58,14.45,35"],
  ["padding and border grow the rect, margins stay out", "e bcr=2,89,16.08,26 rects=2,89,16.08,26"],
  ["an empty inline box reports one empty rect at the top of its line",
    "f bcr=0,111,0,0 rects=0,111,0,0"],
  ["an inline box beside another starts at its own text", "g bcr=0,111,27,18 rects=0,111,27,18"],
  ["a space before it belongs to neither", "h bcr=31.19,111,26.41,18 rects=31.19,111,26.41,18"],
  ["a nested inline box splits the outer box into runs",
    "i bcr=0,129,50.5,18 rects=0,129,18.03,18 | 18.03,129,18.16,18 | 36.19,129,14.31,18"],
  ["the nested box reports its own run", "j bcr=18.03,129,18.16,18 rects=18.03,129,18.16,18"],
  ["a space inside the box is part of its rect", "k bcr=0,147,20.64,18 rects=0,147,20.64,18"],
  ["a display:none inline box has no rects", "n bcr=0,0,0,0 rects="],
  ["a margin moves the rect but not its width", "m1 bcr=5,165,13.61,18 rects=5,165,13.61,18"],
  ["an inline-block inside the box doesn't split its rect", "p1 bcr=0,184,44.03,18 rects=0,184,44.03,18"],
  ["the inline-block reports its own border box", "ib bcr=11.52,186,20,10 rects=11.52,186,20,10"],
  ["a wrapped inline box reports one rect per line",
    "w1 bcr=0,202,47.81,72 rects=0,202,37.89,18 | 0,220,35.06,18 | 0,238,47.81,18 | 0,256,33.3,18"],
  // The empty inline box in this box records a fragment, but it is on no line, so it must not
  // stop the child's margin collapsing through the box's own negative top margin.
  ["an inline box around a block leaves the box's margins collapsing through",
    "col bcr=0,324,100,20 rects=0,324,100,20"],
  ["a detached element has no rects", "detached=0 0"],
];

function buildAndRun(): string {
  const dir = mkdtempSync(join(tmpdir(), "native-inline-rects-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png"), NATIVE_STEPS: "frame | frame" },
  });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return `${r.stdout}${r.stderr}`;
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const out = buildAndRun();
const lines = out.split("\n");

// Chrome's glyph advances and ours can differ in the last hundredth of a pixel, which a rect
// carries into its position and width, so numbers are compared within that distance. What a
// line reports — the id, its bounding rect, and how many rects it has — must match exactly.
const TOL = 0.03;

interface Measured {
  id: string;
  nums: number[][];
}

function parseLine(line: string): Measured | null {
  const m = /^(\S+) bcr=([-\d.,]*) rects=(.*)$/.exec(line);
  if (m === null) return null;
  const nums = (s: string): number[] => (s === "" ? [] : s.split(",").map(Number));
  return { id: m[1], nums: [nums(m[2]), ...(m[3] === "" ? [] : m[3].split(" | ").map(nums))] };
}

function sameRect(got: number[], want: number[]): boolean {
  if (got.length !== want.length) return false;
  for (let i = 0; i < want.length; i++) {
    if (!(Math.abs(got[i] - want[i]) <= TOL)) return false;
  }
  return true;
}

function checkRect(label: string, want: string): void {
  const expected = parseLine(want);
  if (expected === null) {
    check(label, lines.includes(want), `want line "${want}"`);
    return;
  }
  const at = lines.findIndex((l) => parseLine(l)?.id === expected.id);
  if (at < 0) {
    check(label, false, `no line for "${expected.id}"`);
    return;
  }
  const got = parseLine(lines[at]) as Measured;
  let ok = got.nums.length === expected.nums.length;
  for (let i = 0; ok && i < expected.nums.length; i++) ok = sameRect(got.nums[i], expected.nums[i]);
  check(label, ok, `want "${want}", got "${lines[at]}"`);
}

EXPECTED_LOG.forEach(([name, want]) => checkRect(name, want));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

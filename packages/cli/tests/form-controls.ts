// The controls the UA draws: a checkbox's box, a radio's dot and a range's track and thumb.
// Sizes, margins and colours come from the widget, `accent-color` recolours the lit parts,
// `appearance: none` hands the box to the author, and a click ticks a box (alone, through its
// label, or unchecking the rest of its radio group) and sends the events it should.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = w * bpp + 1;
  const out = new Uint8Array(w * h * bpp);
  let prev = new Uint8Array(w * bpp);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * stride];
    const line = raw.subarray(y * stride + 1, y * stride + 1 + w * bpp);
    const cur = new Uint8Array(w * bpp);
    for (let x = 0; x < w * bpp; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

// Each control sits where the script says it does, so a pixel sample names one of them. The
// controls a click test drives sit out of the way in a clipped box of their own.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; background: #fff; }
#cb, #cbc, #r1, #r2, #rg, #rgc, #none, #lab { position: absolute; margin: 0; }
#cb { left: 20px; top: 20px; }
#cbc { left: 60px; top: 20px; }
#r1 { left: 100px; top: 20px; }
#r2 { left: 140px; top: 20px; }
#lab { left: 180px; top: 20px; width: 40px; height: 20px; }
#rg { left: 20px; top: 60px; }
#rgc { left: 20px; top: 100px; accent-color: #ff0000; }
#none { left: 20px; top: 140px; appearance: none; background: #00ff00; }
#probe { position: absolute; left: 260px; top: 170px; width: 1px; height: 1px; overflow: hidden; }
#flow { position: absolute; left: 200px; top: 60px; }
</style></head><body>
<input type="checkbox" id="cb">
<input type="checkbox" id="cbc" checked>
<input type="radio" id="r1" name="g">
<input type="radio" id="r2" name="g" checked>
<input type="range" id="rg">
<input type="range" id="rgc" value="100">
<input type="checkbox" id="none">
<label id="lab" for="cli"></label>
<div id="probe">
<input type="checkbox" id="cli">
<input type="checkbox" id="cbc2">
<input type="checkbox" id="cbc3">
<input type="checkbox" id="none2">
<input type="radio" id="g1" name="gg">
<input type="radio" id="g2" name="gg" checked>
<input type="checkbox" id="off" disabled>
<input type="range" id="rgn">
<input type="hidden" id="hid">
</div>
<div id="flow"><input type="checkbox" id="ua"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const cli = document.getElementById("cli") as HTMLInputElement;
const cbc2 = document.getElementById("cbc2") as HTMLInputElement;
const cbc3 = document.getElementById("cbc3") as HTMLInputElement;
const none2 = document.getElementById("none2") as HTMLInputElement;
const g1 = document.getElementById("g1") as HTMLInputElement;
const g2 = document.getElementById("g2") as HTMLInputElement;
const off = document.getElementById("off") as HTMLInputElement;
const lab = document.getElementById("lab")!;
const rgn = document.getElementById("rgn") as HTMLInputElement;

// A box sends "input" then "change" on each tick, and its own click comes first.
for (const el of [cli, cbc2, g1, g2, off]) {
  const name = el.id;
  el.addEventListener("click", () => log(name + " click " + el.checked));
  el.addEventListener("input", () => log(name + " input " + el.checked));
  el.addEventListener("change", () => log(name + " change " + el.checked));
}
cli.click();
log("ticked " + cli.checked);
cli.click();
log("unticked " + cli.checked);
g1.click();
log("radio " + g1.checked + " " + g2.checked);
g1.click();
log("radio again " + g1.checked + " " + g2.checked);
lab.click();
log("label " + cli.checked);
off.click();
log("disabled " + off.checked);
cbc2.indeterminate = true;
cbc2.click();
log("indeterminate " + cbc2.checked + " " + cbc2.indeterminate);
none2.click();
log("none " + none2.checked);

rgn.valueAsNumber = 25;
log("range " + rgn.value + " " + rgn.valueAsNumber);
rgn.value = "150";
log("clamped " + rgn.valueAsNumber);
rgn.setAttribute("step", "10");
rgn.value = "37";
log("stepped " + rgn.valueAsNumber);
rgn.valueAsNumber = NaN;
log("nan " + rgn.valueAsNumber);
rgn.setAttribute("step", "any");
rgn.value = "37.5";
log("any " + rgn.valueAsNumber);
rgn.removeAttribute("step");
rgn.setAttribute("min", "10");
rgn.value = "";
log("default " + rgn.valueAsNumber);
try {
  cli.valueAsNumber = 3;
  log("text number no throw");
} catch (e) {
  log("text number " + (e as Error).message.split(":")[0]);
}

requestAnimationFrame(() => requestAnimationFrame(() => {
  for (const id of ["cb", "cbc", "r1", "r2", "rg", "rgc", "none", "hid"]) {
    const el = document.getElementById(id)!;
    const r = el.getBoundingClientRect();
    log(id + " " + r.left + "," + r.top + " " + r.width + "x" + r.height);
  }
  const ua = document.getElementById("ua") as HTMLInputElement;
  const ur = ua.getBoundingClientRect();
  log("ua " + ur.width + "x" + ur.height + " margin=" + getComputedStyle(ua).margin);
  log("appearance " + getComputedStyle(cbc3).appearance + " " + getComputedStyle(cbc3).accentColor);
}));
`;

const EXPECTED_LOG = [
  "cli click false",
  "cli input true",
  "cli change true",
  "ticked true",
  "cli click true",
  "cli input false",
  "cli change false",
  "unticked false",
  "g1 click false",
  "g1 input true",
  "g1 change true",
  "radio true false",
  "g1 click true",
  "radio again true false",
  "cli click false",
  "cli input true",
  "cli change true",
  "label true",
  "disabled false",
  "cbc2 click false",
  "cbc2 input true",
  "cbc2 change true",
  "indeterminate true false",
  "none true",
  "range 25 25",
  "clamped 100",
  "stepped 40",
  "nan 50",
  "any 37.5",
  "default 55",
  "text number InvalidStateError",
  "cb 20,20 13x13",
  "cbc 60,20 13x13",
  "r1 100,20 13x13",
  "r2 140,20 13x13",
  "rg 20,60 129x16",
  "rgc 20,100 129x16",
  "none 20,140 13x13",
  "hid 0,0 0x0",
  "ua 13x13 margin=3px 4px",
  "appearance auto auto",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-form-controls-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame", NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED_LOG.length})`, got.length === EXPECTED_LOG.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED_LOG.length); i++) {
  check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
}

const img = decodePng(png);
// The snapshot is 2 device px per CSS px; the helpers take CSS coordinates.
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};
const WHITE = [255, 255, 255];
const ACCENT = [0, 117, 255];
const RED = [255, 0, 0];
const EDGE = [118, 118, 118];
const TRACK = [239, 239, 239];
const GREEN = [0, 255, 0];

// #cb at (20,20): a 13px box with a hairline edge around white. The script ticked and unticked it,
// so it ends the run empty.
check("an empty box has a white inside", near(26, 26, WHITE), `got ${rgb(26, 26)}`);
check("an empty box has an edge", near(20.4, 26, EDGE), `got ${rgb(20.4, 26)}`);

// #cbc at (60,20): ticked, so the box is the accent colour and the tick is white.
check("a ticked box is filled with the accent", near(71.5, 21.5, ACCENT), `got ${rgb(71.5, 21.5)}`);
check("a ticked box draws its tick", near(67.75, 26.5, WHITE), `got ${rgb(67.75, 26.5)}`);

// #r1 at (100,20): an empty radio, its inside white and its edge the same hairline.
check("an empty radio is white inside", near(106.5, 26.5, WHITE), `got ${rgb(106.5, 26.5)}`);
check("an empty radio has an edge", near(100.6, 26.5, EDGE), `got ${rgb(100.6, 26.5)}`);

// #r2 at (140,20): the chosen radio is an accent ring, a white gap and an accent dot.
check("a chosen radio has an accent ring", near(152.5, 26.5, ACCENT), `got ${rgb(152.5, 26.5)}`);
check("a chosen radio has a white gap", near(151, 26.5, WHITE), `got ${rgb(151, 26.5)}`);
check("a chosen radio has an accent dot", near(146.5, 26.5, ACCENT), `got ${rgb(146.5, 26.5)}`);

// #rg at (20,60), 129 by 16 and half way along: the track's passed part and the thumb are accent,
// the part ahead of the thumb the track's own grey.
check("a range fills the track up to its thumb", near(40, 69, ACCENT), `got ${rgb(40, 69)}`);
check("a range's thumb is at its value", near(84.5, 68, ACCENT), `got ${rgb(84.5, 68)}`);
check("a range leaves the track ahead unfilled", near(140, 69, TRACK), `got ${rgb(140, 69)}`);

// #rgc at (20,100) with accent-color: #ff0000 and value 100, which puts the thumb at the right end.
check("accent-color colours the passed track", near(40, 109, RED), `got ${rgb(40, 109)}`);
check("accent-color colours the thumb", near(141, 108, RED), `got ${rgb(141, 108)}`);

// #none at (20,140): appearance: none draws no box, so the author's green background is all there is.
check("appearance: none paints the author's background", near(26, 146, GREEN), `got ${rgb(26, 146)}`);
check("appearance: none draws no edge", near(20.4, 146, GREEN), `got ${rgb(20.4, 146)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

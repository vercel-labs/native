// Regression tests for selectors that only start (or stop) matching after a script changes the
// markup. A rule matched nothing at build time must not be dropped when a script may add a
// class or an id later, and a rule that matched statically must stop applying when the script
// takes the class or id away.   npm test

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

// Each div is 20 CSS px tall and the snapshot is 2 device px per CSS px, so div i covers
// device rows [40i, 40i + 40).
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=300"><style>
body { margin: 0; }
div { height: 20px; background: #000000; }
/* Nothing has these conditions at build time: only the script below creates them. */
body.changed div#target { background: #ff0000; }
#late { background: #00ff00; }
.p-7 { background: #0000ff; }
/* These match at build time, and the script takes the condition away. */
#waslate { background: #ff00ff; }
#gone.on { background: #00ffff; }
/* :has(): one rule per relative combinator, plus one whose argument the script brings to life. */
#h-desc:has(.kid) { background: #ffff00; }
#h-child:has(> .directkid) { background: #00ff00; }
#h-adj:has(+ .after) { background: #ff8800; }
#h-gen:has(~ .later) { background: #8800ff; }
#h-dyn:has(.latekid) { background: #ff0000; }
</style></head><body>
<div id="target"></div>
<div id="setter"></div>
<div id="concat"></div>
<div id="waslate"></div>
<div id="gone" class="on"></div>
<div id="h-desc"><span class="kid">x</span></div>
<div id="h-child"><span class="directkid">x</span></div>
<div id="h-adj"></div>
<div class="after"></div>
<div id="h-gen"></div>
<div id="h-none"><span class="other">x</span></div>
<div class="later"></div>
<div id="h-dyn"><span id="dynkid">x</span></div>
<script>
  var n = 7;
  document.body.classList.add("changed");
  document.getElementById("setter").id = "late";
  document.getElementById("concat").className = "p-" + n;
  document.getElementById("waslate").id = "other";
  document.getElementById("gone").classList.remove("on");
  document.getElementById("dynkid").classList.add("latekid");
</script>
</body></html>`;

// Expected background of each div, in document order.
const EXPECTED: [string, string][] = [
  ["a class added to an ancestor after the build applies the rule", "255,0,0"],
  ["an id assigned at runtime applies the rule", "0,255,0"],
  ["a class built by concatenation applies the rule", "0,0,255"],
  ["an id taken away at runtime stops the rule", "0,0,0"],
  ["a class removed at runtime stops the rule", "0,0,0"],
  ["a descendant :has() argument matches", "255,255,0"],
  ["a child :has() argument matches", "0,255,0"],
  ["an adjacent-sibling :has() argument matches", "255,136,0"],
  ["the element a :has() rule names no combinator for is untouched", "0,0,0"],
  ["a general-sibling :has() argument matches", "136,0,255"],
  ["a :has() with no match leaves the element alone", "0,0,0"],
  ["the sibling a :has() argument names is untouched", "0,0,0"],
  ["a class added at runtime makes :has() match", "255,0,0"],
];

function buildAndShoot(html: string): { img: Image; stderr: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-dynamic-"));
  writeFileSync(join(dir, "index.html"), html);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), stderr: b.stderr };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, stderr } = buildAndShoot(PAGE);
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(100, 40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});
check("no rule is reported as matching no element", !/matches no element/.test(stderr), stderr.trim());

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

// ::target-text: the stretch a text fragment names, painted where it falls — the first match of
// the fragment's start, with the end, prefix and suffix the directive gives.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=40"><style>
body { margin: 0; font: 20px monospace; }
p { margin: 0; }
::target-text { background-color: rgb(0, 128, 0); color: rgb(255, 0, 0); }
</style></head><body><p id="p">Hello brave world</p></body></html>`;

// Without a rule the page paints the browser's own pale yellow over the fragment's text.
const PLAIN_PAGE = PAGE.replace("::target-text { background-color: rgb(0, 128, 0); color: rgb(255, 0, 0); }", "");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-target-text-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

/** Renders the page with `directive` as the app's text fragment, returning the snapshot. */
function shot(directive: string): ReturnType<typeof decodePng> {
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_TARGET_TEXT: directive },
  });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return decodePng(png);
}

const plainDir = mkdtempSync(join(tmpdir(), "native-target-text-plain-"));
writeFileSync(join(plainDir, "index.html"), PLAIN_PAGE);
const plainExe = join(plainDir, "app");
const pb = spawnSync("node", ["compiler/cli.ts", "build", plainDir, "-o", plainExe], { encoding: "utf8" });
if (pb.status !== 0) throw new Error(`build failed\n${pb.stderr}`);

/** The x extent of the pixels matching `pick`, in the snapshot's own (2x) pixels. */
function extent(image: ReturnType<typeof decodePng>, pick: (r: number, g: number, b: number) => boolean): number[] {
  let lo = -1, hi = -1, count = 0;
  for (let y = 0; y < image.h; y++) {
    for (let x = 0; x < image.w; x++) {
      const o = (y * image.w + x) * 4;
      if (!pick(image.rgba[o], image.rgba[o + 1], image.rgba[o + 2])) continue;
      count++;
      if (lo < 0 || x < lo) lo = x;
      if (x > hi) hi = x;
    }
  }
  return [lo, hi, count];
}

const green = (r: number, g: number, b: number): boolean => g > 90 && r < 60 && b < 60;
// Monospace at 20px: "Hello brave world" puts "brave" at 72px and runs to 132px.
const near = (x: number, want: number): boolean => Math.abs(x - want) <= 6;

const first = shot("brave");
const one = extent(first, green);
check("the fragment's text paints", one[2] > 100, `${one[2]} green pixels`);
check("it starts where the text appears", one[0] >= 0 && near(one[0] / 2, 72), `x ${one[0] / 2}`);
check("it ends after that text", near(one[1] / 2, 132), `x ${one[1] / 2}`);

// A start and an end name one stretch, spaces and all.
const two = extent(shot("Hello%20,brave"), green);
check("start and end name one stretch", two[2] > one[2] && near(two[0] / 2, 0) && near(two[1] / 2, 132),
  `x ${two[0] / 2}..${two[1] / 2}, ${two[2]} pixels`);

// A prefix and a suffix narrow the match: "rave" with "b" before it and a space after.
const three = extent(shot("b-,rave,-%20"), green);
check("prefix and suffix narrow the match", three[2] > 0 && near(three[0] / 2, 84) && near(three[1] / 2, 132),
  `x ${three[0] / 2}..${three[1] / 2}, ${three[2]} pixels`);

// The same start with the wrong prefix matches nothing.
const none = extent(shot("zz-,rave"), green);
check("a prefix the text doesn't have matches nothing", none[2] === 0, `${none[2]} green pixels`);

// A page with no rule paints the browser's pale yellow.
const png = join(plainDir, "out.png");
const pr = spawnSync(plainExe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_TARGET_TEXT: "brave" },
});
if (pr.status !== 0) throw new Error(`render failed\n${pr.stderr}`);
const yellow = extent(decodePng(png), (r, g, b) => r > 200 && g > 190 && b < 150);
check("with no rule the text fragment paints pale yellow", yellow[2] > 100 &&
  near(yellow[0] / 2, 72) && near(yellow[1] / 2, 132), `x ${yellow[0] / 2}..${yellow[1] / 2}, ${yellow[2]} pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

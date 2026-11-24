// Cascade layers: rules in a later layer beat rules in an earlier one, unlayered rules beat every
// layer (and lose to every layer when important), and a layer's own rules come after its
// sublayers. Each div in the page gets its background from the rules below, one per case.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// Each div is 20 CSS px tall and the snapshot is 2 device px per CSS px, so div i covers
// device rows [40i, 40i + 40).
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; }
div { height: 20px; }

@layer early { #one { background: #ff0000; } }
@layer late { .one { background: #00ff00; } }

@layer base { #two { background: #ff0000; } }
.two { background: #0000ff; }

@layer first { .three { background: #ff0000 !important; } }
@layer second { #three { background: #00ff00 !important; } }

@layer base { #four { background: #00ff00 !important; } }
.four { background: #ff0000 !important; }

@layer zeta, alpha;
@layer alpha { #five { background: #00ff00; } }
@layer zeta { .five { background: #ff0000; } }

@layer outer {
  #six { background: #ff0000; }
  @layer inner { .six { background: #00ff00; } }
}

@layer outer {
  @layer one { #seven { background: #ff0000; } }
  @layer two { .seven { background: #00ff00; } }
}

@layer { #eight { background: #ff0000; } }
@layer { .eight { background: #00ff00; } }

@layer single { #nine { background: #ff0000; } .nine { background: #00ff00; } }
</style></head><body>
<div class="one" id="one"></div>
<div class="two" id="two"></div>
<div class="three" id="three"></div>
<div class="four" id="four"></div>
<div class="five" id="five"></div>
<div class="six" id="six"></div>
<div class="seven" id="seven"></div>
<div class="eight" id="eight"></div>
<div class="nine" id="nine"></div>
</body></html>`;

const EXPECTED: [string, string][] = [
  ["1: a later layer beats an earlier one despite specificity", "0,255,0"],
  ["2: an unlayered rule beats a more specific layered one", "0,0,255"],
  ["3: important declarations reverse the layer order", "255,0,0"],
  ["4: an unlayered important rule loses to a layered one", "0,255,0"],
  ["5: a @layer order statement fixes the order", "0,255,0"],
  ["6: a layer's own rules come after its sublayers", "255,0,0"],
  ["7: sublayers keep their declaration order", "0,255,0"],
  ["8: a later anonymous layer beats an earlier one", "0,255,0"],
  ["9: specificity still decides inside one layer", "255,0,0"],
];

const dir = mkdtempSync(join(tmpdir(), "native-layers-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build doesn't report @layer as unsupported", !/@layer is not supported/.test(`${b.stdout}${b.stderr}`));

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(100, 40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

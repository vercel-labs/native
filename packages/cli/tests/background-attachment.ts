// background-attachment: local layers ride along with the element's contents. The same striped
// gradient is painted in two scroll boxes, one `scroll` and one `local`; after both scroll by
// half a stripe, only the local one shows the next stripe at its top.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
html, body { margin: 0; }
.box { position: absolute; top: 20px; width: 100px; height: 100px; overflow: auto;
  background-image: repeating-linear-gradient(to bottom, #ff0000 0px, #ff0000 10px, #0000ff 10px, #0000ff 20px); }
#scroll { left: 20px; background-attachment: scroll; }
#local { left: 160px; background-attachment: local; }
.tall { height: 200px; }
</style></head><body>
<div class="box" id="scroll"><div class="tall"></div></div>
<div class="box" id="local"><div class="tall"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const scroll = document.getElementById("scroll")!;
const local = document.getElementById("local")!;
// The scroll boxes only have their laid-out heights after the first frame, so the scroll
// happens in the second: until then a scrollTop would be clamped against zero content.
requestAnimationFrame(() => {
  scroll.scrollTop = 10;
  local.scrollTop = 10;
  console.log("scrolled " + scroll.scrollTop + " " + local.scrollTop);
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-bg-attachment-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
// The snapshot is taken at the display's backing scale: two image pixels per CSS pixel here.
const k = img.w / 400;
const px = (x: number, y: number): string => {
  const o = (Math.round(y * k) * img.w + Math.round(x * k)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};

// Stripe 1 is red (content y 0..10), stripe 2 blue (10..20). A box scrolled 10px down shows
// content y = 10 at its top edge, which is the blue stripe's first row.
check("a scroll layer stays put while the content scrolls", px(60, 25) === "255,0,0", `got ${px(60, 25)}`);
check("a local layer scrolls with the content", px(210, 25) === "0,0,255", `got ${px(210, 25)}`);
// Lower down, half a stripe further: scroll is still red (content y 55 is stripe 6, red),
// local shows content y 65, which is blue.
check("a scroll layer keeps its own stripes", px(60, 95) === "0,0,255", `got ${px(60, 95)}`);
check("a local layer keeps the stripes' phase", px(210, 95) === "255,0,0", `got ${px(210, 95)}`);

// Both boxes really scrolled, or the checks below would pass without the layer moving.
check("both boxes scrolled by ten pixels",
  r.stdout.includes("scrolled 10 10"), JSON.stringify(r.stdout));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

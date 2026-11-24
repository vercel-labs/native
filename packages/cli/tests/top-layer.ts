// The top layer: a modal dialog paints above the whole page, with its ::backdrop filling the
// viewport under it, and an open popover paints above the dialog.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; }
#cover { position: absolute; left: 0; top: 0; width: 200px; height: 200px; background: #0000ff; }
#dlg { width: 100px; height: 60px; border: 0; padding: 0; background: #00aa00; color: #ffffff; }
#pop { position: fixed; left: 80px; top: 90px; right: auto; bottom: auto; margin: 0; border: 0; padding: 0; width: 40px; height: 20px; background: #ff0000; }
</style></head><body>
<div id="cover"></div>
<dialog id="dlg">hi</dialog>
<div id="pop" popover>p</div>
<script>
document.getElementById("dlg")!.showModal();
</script>
</body></html>`;

const SCRIPT_POPOVER = `document.getElementById("pop")!.showPopover();`;

function buildAndRun(extra: string): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-top-layer-"));
  writeFileSync(join(dir, "index.html"), PAGE.replace("showModal();", `showModal(); ${extra}`));
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

/** Runs a page on its own with `steps`, returning what it printed. */
function runPage(page: string, steps: string): string {
  const dir = mkdtempSync(join(tmpdir(), "native-top-layer-page-"));
  writeFileSync(join(dir, "index.html"), page);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout;
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function pixels(img: Image): (x: number, y: number) => number[] {
  // The snapshot is 2 device px per CSS px; the helpers take CSS coordinates.
  return (x, y) => {
    const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
    return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
  };
}
const near = (p: number[], c: number[], tol: number): boolean =>
  Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;

{
  const { img } = buildAndRun("");
  const rgb = pixels(img);
  // The dialog is 100x60, centred by inset: 0; margin: auto, and it paints over the blue cover.
  check("a modal dialog paints above the page", near(rgb(100, 100), [0, 170, 0], 12), `got ${rgb(100, 100)}`);
  // The ::backdrop is rgba(0, 0, 0, 0.1) over the blue cover, everywhere the dialog isn't.
  check("a modal dialog's backdrop covers the viewport", near(rgb(10, 100), [0, 0, 230], 12), `got ${rgb(10, 100)}`);
  check("the backdrop reaches the corner", near(rgb(193, 193), [0, 0, 230], 12), `got ${rgb(193, 193)}`);
}

{
  const { img } = buildAndRun(SCRIPT_POPOVER);
  const rgb = pixels(img);
  // The popover is 40x20, centred, and it belongs to the top layer too, above the dialog.
  check("an open popover paints above a modal dialog", near(rgb(100, 100), [255, 0, 0], 12), `got ${rgb(100, 100)}`);
}

{
  // An open popover takes Chrome's place: as big as its content wants, centred in the viewport by
  // its auto margins, rather than stretched across it.
  const PLACE_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 20px monospace; }
</style></head><body>
<div popover id="p">Hello brave new world</div>
<script>
const p = document.getElementById("p");
p.showPopover();
requestAnimationFrame(() => {
  const r = p.getBoundingClientRect();
  console.log("place " + Math.round(r.left) + " " + Math.round(r.top) + " " +
    Math.round(r.width) + " " + Math.round(r.height));
});
</script>
</body></html>`;
  const out = runPage(PLACE_PAGE, "frame 0|frame 16");
  const line = out.split("\n").find((l) => l.startsWith("place ")) ?? "";
  const [l, t, w, h] = line.slice(6).split(" ").map(Number);
  check("an open popover is as big as its content", w > 0 && w < 300 && h > 0 && h < 200,
    `size ${w}x${h}`);
  check("an open popover is centred in the viewport",
    Math.abs(l - (300 - w) / 2) <= 1 && Math.abs(t - (200 - h) / 2) <= 1, `at ${l},${t}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

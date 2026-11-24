// A page whose button text changes must look the same as a page built with that text from the
// start: a restyle and relayout has to reach the same boxes the first layout did.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, type Image } from "./png.ts";

const style = `
button { height: 34px; padding: 0 14px; border: none; background: #4f46e5; color: #fff; }
`;

/** The page, with `first` as the first button's text and `script` after the buttons. */
const page = (first: string, script: string): string => `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=100"><style>
body { margin: 8px; }${style}
</style></head><body>
<button id="b">${first}</button><button>Resend invite</button>
${script}
</body></html>`;

// The click replaces the button's text; the second button keeps it, so a line that re-aligns
// around the changed button shows up too. Neither button needs a script in the reference page.
const CLICK = `<script type="module">
document.getElementById("b")!.addEventListener("click", () => { document.getElementById("b")!.textContent = "Sent"; });
</script>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-relayout-"));

/** Builds and renders one page, returning its snapshot. */
function render(name: string, html: string, steps: string): Image {
  const app = join(dir, name);
  mkdirSync(app);
  writeFileSync(join(app, "index.html"), html);
  const exe = join(app, "exe");
  const b = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(app, "out.png");
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps },
  });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return decodePng(png);
}

// The changed page is clicked before its snapshot; the reference page is built with the text the
// click leaves behind, so the two must paint the same pixels.
const changed = render("changed", page("Resend invite", CLICK), "click #b");
const fresh = render("fresh", page("Sent", ""), "");
check(`${changed.w}x${changed.h} snapshot`, changed.w === fresh.w && changed.h === fresh.h,
  `fresh is ${fresh.w}x${fresh.h}`);
let differ = 0;
const n = Math.min(changed.rgba.length, fresh.rgba.length);
for (let i = 0; i < n; i += 4) {
  if (changed.rgba[i] !== fresh.rgba[i] || changed.rgba[i + 1] !== fresh.rgba[i + 1] ||
    changed.rgba[i + 2] !== fresh.rgba[i + 2]) differ++;
}
// A button with no background or text would match a blank page for free, so the reference's
// painted area is checked to be there at all: the indigo background of two buttons.
let indigo = 0;
for (let i = 0; i < fresh.rgba.length; i += 4) {
  if (fresh.rgba[i] === 0x4f && fresh.rgba[i + 1] === 0x46 && fresh.rgba[i + 2] === 0xe5) indigo++;
}
check("the reference page paints its buttons", indigo > 1000, `${indigo} indigo pixels`);
check("a button after a text change paints as a fresh build does", differ === 0, `${differ} pixels differ`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

// Text is shaped with the font's kerning, as Chrome shapes it: a run's width is the width of the
// shaped glyphs, the same number wrapping uses. The expected widths below were measured in Chrome
// on Linux at deviceScaleFactor 2 with --font-render-hinting=none (whose unhinted advances are the
// ones the hosts draw with) from the bundled tests/fixtures/inter-regular.ttf, whose kern pairs
// make "AVATAR" 5.6px narrower at 12px than the sum of its glyph advances. The last three check
// that the face fontconfig resolves for the default sans, not a built-in stand-in, is measured.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");

const RUNS: [string, number, string, number][] = [
  ["avatar12", 12, "AVATAR Wave To.", 100.40625],
  ["arch12", 12, "architecture.md", 89.234375],
  ["read12", 12, "README.md", 71.25],
  ["open12", 12, "Open file", 51.234375],
  ["line12", 12, "AVATAR Wave To. architecture.md README.md Open file", 322.234375],
  ["avatar13", 13, "AVATAR Wave To.", 108.78125],
  ["arch13", 13, "architecture.md", 96.671875],
  ["read13", 13, "README.md", 77.1875],
  ["open13", 13, "Open file", 55.515625],
  ["line13", 13, "AVATAR Wave To. architecture.md README.md Open file", 349.09375],
  ["avatar14", 14, "AVATAR Wave To.", 117.140625],
  ["arch14", 14, "architecture.md", 104.109375],
  ["read14", 14, "README.md", 83.125],
  ["open14", 14, "Open file", 59.78125],
  ["line14", 14, "AVATAR Wave To. architecture.md README.md Open file", 375.9375],
  ["avatar24", 24, "AVATAR Wave To.", 200.8125],
  ["arch24", 24, "architecture.md", 178.453125],
  ["read24", 24, "README.md", 142.5],
  ["open24", 24, "Open file", 102.46875],
  ["line24", 24, "AVATAR Wave To. architecture.md README.md Open file", 644.46875],
  // font-kerning: none is the sum of the same glyph advances, without the kern feature.
  ["nokernAvatar14", 14, "AVATAR Wave To.", 123.71875],
  ["nokernArch14", 14, "architecture.md", 104.703125],
  ["nokernOpen14", 14, "Open file", 59.78125],
  ["nokernAvatar24", 24, "AVATAR Wave To.", 212.078125],
  ["nokernArch24", 24, "architecture.md", 179.484375],
];

// The same checks for the default sans, which the host used to measure with its built-in
// Helvetica tables while drawing DejaVu Sans. These are Chrome's widths for DejaVu Sans 2.37; a
// machine whose sans-serif is another font skips them.
const SANS_RUNS: [string, number, string, number][] = [
  ["sansAvatar14", 14, "AVATAR Wave To.", 118.890625],
  ["sansArch14", 14, "architecture.md", 111.6875],
  ["sansOpen14", 14, "Open file", 63.171875],
];

const PROBES = RUNS.map(([id, size, text]) =>
  `<span class="probe" id="${id}" style="font-size: ${size}px${
    id.startsWith("nokern") ? "; font-kerning: none" : ""}">${text}</span>`).join("\n") + "\n" +
  SANS_RUNS.map(([id, size, text]) =>
    `<span class="probe" id="${id}" style="font-family: sans-serif; font-size: ${size}px">${text}</span>`).join("\n");

// 118px fits the kerned "AVATAR Wave To." at 14px (117.14) but not the unkerned one (123.72), so
// the line wraps exactly when the kern feature is ignored.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
@font-face { font-family: KernFace; src: url("inter-regular.ttf"); }
body { margin: 0; font-family: KernFace; font-size: 14px; }
.probe { position: absolute; left: 0; top: -2000px; display: inline-block; white-space: pre; width: max-content; }
.wrapbox { width: 118px; margin: 8px 0 0 8px; }
.wrapbox span { white-space: normal; }
</style></head><body>
${PROBES}
<div class="wrapbox" id="wrapauto"><span id="autoText">AVATAR Wave To.</span></div>
<div class="wrapbox" id="wrapnone" style="font-kerning: none"><span id="noneText">AVATAR Wave To.</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
// The boxes are laid out by the first frame, so the reads happen in a later one.
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const probes = document.querySelectorAll(".probe");
    for (let i = 0; i < probes.length; i++) {
      console.log((probes[i] as HTMLElement).id + "=" + probes[i].getBoundingClientRect().width);
    }
    console.log("autolines=" + document.getElementById("autoText")!.getClientRects().length);
    console.log("nonelines=" + document.getElementById("noneText")!.getClientRects().length);
  });
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-text-kerning-"));
copyFileSync(join(FIXTURES, "inter-regular.ttf"), join(dir, "inter-regular.ttf"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);
const out = `${r.stdout}\n${r.stderr}`;
// The default sans's expected widths are DejaVu Sans's. Another system font is a different run
// of the same checks, so the sans checks only run where fontconfig resolves that family.
const fan = spawnSync("fc-match", ["--format=%{family}", "sans-serif"], { encoding: "utf8" });
const hasDejaVuSans = fan.status === 0 && fan.stdout.includes("DejaVu Sans");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

for (const [id, , text, want] of RUNS) {
  const match = out.match(new RegExp(`^${id}=([0-9.]+)$`, "m"));
  const got = match ? Number(match[1]) : NaN;
  check(`${id} "${text}" is ${want}px, Chrome's width`, Math.abs(got - want) <= 0.5,
    `got ${Number.isFinite(got) ? got.toFixed(3) : "nothing"}, want ${want}`);
}
for (const [id, , text, want] of SANS_RUNS) {
  if (!hasDejaVuSans) {
    console.log(`ok   ${id} "${text}" is skipped (sans-serif is not DejaVu Sans here)`);
    continue;
  }
  const match = out.match(new RegExp(`^${id}=([0-9.]+)$`, "m"));
  const got = match ? Number(match[1]) : NaN;
  check(`${id} "${text}" is ${want}px, Chrome's width`, Math.abs(got - want) <= 0.5,
    `got ${Number.isFinite(got) ? got.toFixed(3) : "nothing"}, want ${want}`);
}
check("kerned text stays on one line in a box that only fits its kerned width", out.includes("autolines=1"),
  out.match(/autolines=.*/)?.[0] ?? "no line count");
check("font-kerning: none lets the same text wrap", out.includes("nonelines=2"),
  out.match(/nonelines=.*/)?.[0] ?? "no line count");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

// Markup a script assigns to an <svg> with innerHTML is parsed in the SVG namespace, as a browser
// parses it: its <pattern> and the <rect> that fills with it become SVG elements, so the fill
// attribute reaches the cascade and the pattern paints. A fragment parsed without its context
// makes HTML elements instead, whose fill attribute is ignored and whose background stays empty
// (Relay's dotted background was assigned this way).
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=170"><style>
body { margin: 0; background: #000000; }
svg { position: absolute; left: 0; width: 220px; height: 70px; }
#static { top: 0; }
#runtime { top: 85px; }
</style></head><body>
<svg id="static" viewBox="0 0 220 70">
  <defs><pattern id="red" width="20" height="20" patternUnits="userSpaceOnUse">
    <circle cx="2" cy="2" r="2" fill="#ff0000"/>
  </pattern></defs>
  <rect width="220" height="70" fill="url(#red)"/>
</svg>
<svg id="runtime" viewBox="0 0 220 70"></svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const svg = document.getElementById("runtime") as HTMLElement;
svg.innerHTML = '<defs><pattern id="green" width="20" height="20" patternUnits="userSpaceOnUse">' +
  '<circle cx="2" cy="2" r="2" fill="#00ff00"/></pattern></defs>' +
  '<rect width="220" height="70" fill="url(#green)"/>';
const rect = svg.querySelector("rect");
console.log("ns=" + (rect === null ? "none" : rect.namespaceURI));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-pattern-innerhtml-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS coordinates (cx, cy), as [r, g, b]; the snapshot is 2 device px per CSS px. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

const BLACK = [0, 0, 0], RED = [255, 0, 0], GREEN = [0, 255, 0];
const near = (got: number[], want: number[], tol = 6): boolean => got.every((g, i) => Math.abs(g - want[i]) <= tol);
const ns = /^ns=(.*)$/m.exec(r.stdout);

// The markup in the page already proves the pattern painter; this is the control.
check("a pattern in markup paints its tile", near(at(2, 2), RED), `got ${at(2, 2).join(",")}`);
check("a pattern leaves the space between tiles clear", near(at(12, 12), BLACK), `got ${at(12, 12).join(",")}`);

// Markup assigned with innerHTML is SVG, not HTML, so its pattern fills too.
check("markup assigned to an <svg> is in the SVG namespace",
  ns !== null && ns[1] === "http://www.w3.org/2000/svg", ns === null ? "no namespace logged" : ns[1]);
check("a pattern assigned with innerHTML paints its tile", near(at(2, 87), GREEN), `got ${at(2, 87).join(",")}`);
check("the assigned pattern leaves the space between tiles clear", near(at(12, 97), BLACK), `got ${at(12, 97).join(",")}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall runtime SVG pattern checks passed");

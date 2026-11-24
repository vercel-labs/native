// cursor: url() images with a hotspot, and the keyword fallback they end in.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { encodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=300"><style>
body { margin: 0; }
#img { position: absolute; left: 0; top: 0; width: 100px; height: 100px; background: #ff0000;
  cursor: url(cursor.png) 4 4, text; }
#grab { position: absolute; left: 100px; top: 0; width: 100px; height: 100px; background: #00aa00;
  cursor: grab; }
#nothere { position: absolute; left: 0; top: 100px; width: 100px; height: 100px; background: #0000ff;
  cursor: url(missing.png) 2 2, not-allowed; }
/* Keywords macOS has no cursor for: the host draws one. */
#wait { position: absolute; left: 100px; top: 100px; width: 100px; height: 100px; background: #aa0000; cursor: wait; }
#move { position: absolute; left: 200px; top: 100px; width: 100px; height: 100px; background: #00aaaa; cursor: move; }
#zoom { position: absolute; left: 0; top: 200px; width: 100px; height: 100px; background: #aaaa00; cursor: zoom-in; }
#all { position: absolute; left: 100px; top: 200px; width: 100px; height: 100px; background: #aa00aa; cursor: all-scroll; }
#help { position: absolute; left: 200px; top: 200px; width: 100px; height: 100px; background: #00aa55; cursor: help; }
</style></head><body>
<div id="img"></div>
<div id="grab"></div>
<div id="nothere"></div>
<div id="wait"></div>
<div id="move"></div>
<div id="zoom"></div>
<div id="all"></div>
<div id="help"></div>
<script>
for (const id of ["img", "grab", "nothere", "wait", "move", "zoom", "all", "help"]) {
  console.log(id + "=" + getComputedStyle(document.getElementById(id)!).cursor);
}
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-cursor-"));
writeFileSync(join(dir, "index.html"), PAGE);
// A 16x16 cursor image: a black square with a white corner, so its hotspot is visible if a real
// cursor were shown.
writeFileSync(join(dir, "cursor.png"), encodePng(16, 16, (x, y) => (y < 4 ? [255, 255, 255, 255] : [0, 0, 0, 255])));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// Hovering each box drives the host cursor: the image one, the keyword one, and the keyword the
// missing image falls back to. A broken FFI call would fail the run.
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "hover #img|hover #grab|hover #nothere|hover #wait|hover #move|hover #zoom|hover #all|hover #help|hover #img" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const lines = r.stdout.split("\n");
check("an image cursor falls back to its keyword in the computed value", lines.includes("img=text"),
  JSON.stringify(lines.filter((l) => l.startsWith("img="))));
check("a keyword cursor computes as itself", lines.includes("grab=grab"),
  JSON.stringify(lines.filter((l) => l.startsWith("grab="))));
check("a missing image cursor computes as its keyword", lines.includes("nothere=not-allowed"),
  JSON.stringify(lines.filter((l) => l.startsWith("nothere="))));
check("the cursor value itself is supported", !/unsupported cursor/.test(b.stderr), b.stderr.trim());
// The keywords macOS can't show take a cursor drawn by the host; hovering them must reach the
// host without failing, and each one still computes as its keyword.
const drawn: [string, string][] = [["wait", "wait"], ["move", "move"], ["zoom", "zoom-in"],
  ["all", "all-scroll"], ["help", "help"]];
for (const [id, value] of drawn) {
  check(`hovering a ${value} box reaches the host and computes as itself`, lines.includes(`${id}=${value}`),
    JSON.stringify(lines.filter((l) => l.includes("="))));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

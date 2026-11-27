// The compositor's Metal shaders reach the app as a precompiled library. Whatever way the build
// makes it (xcrun's Metal toolchain, or capture-shaders on a Mac that only has the compiler), the
// library must carry every fragment function shaders.metal declares: a missing one is a pipeline
// the app can't build, and the pass it draws silently never runs.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

if (process.platform !== "darwin") {
  ok("skipped: the Metal shaders are built on macOS only", true);
  console.log("\nall passed");
  process.exit(0);
}

const source = readFileSync(join(import.meta.dirname, "..", "host", "compositor", "shaders.metal"), "utf8");
const fragments: string[] = [];
for (const m of source.matchAll(/fragment\s+float4\s+(\w+)\s*\(/g)) fragments.push(m[1]);
ok("shaders.metal declares the compositor's fragments", fragments.length > 0, fragments.join(", "));

const dir = mkdtempSync(join(tmpdir(), "native-metal-capture-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=120, height=80">
<style>html, body { margin: 0; width: 120px; height: 80px; background: #123456; }</style>
</head><body><p style="font: 12px sans-serif; color: #fff">shaders</p></body></html>`);
writeFileSync(join(dir, "app.ts"), "// static page\n");

const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", join(dir, "app")], { encoding: "utf8" });
ok("the page builds", build.status === 0, build.stderr.slice(-400));
const metallib = join(dir, ".native", "native-metal-shaders.metallib");
if (!existsSync(metallib)) {
  ok("the build made a precompiled shader library", false);
} else {
  const bytes = readFileSync(metallib);
  ok("the library has the compositor's quad fragment", bytes.includes("quad_fragment"), `${bytes.length} bytes`);
  for (const name of fragments) {
    if (name === "quad_fragment") continue;
    ok(`the library has ${name}`, bytes.includes(name), `${bytes.length} bytes`);
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

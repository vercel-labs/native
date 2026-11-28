// The compositor's Metal shaders reach the app as a precompiled library. Whatever way the build
// makes it (xcrun's Metal toolchain, or capture-shaders on a Mac that only has the compiler), the
// library must carry every vertex, fragment and kernel function shaders.metal declares: a missing
// one is a pipeline the app can't build, and the pass it draws silently never runs.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` (${detail})`}`);
}

if (process.platform !== "darwin") {
  ok("skipped: the Metal shaders are built on macOS only", true);
  console.log("\nall passed");
  process.exit(0);
}

const compositor = join(import.meta.dirname, "..", "host", "compositor");
const source = readFileSync(join(compositor, "shaders.metal"), "utf8");

/** Every entry point the source declares, in the order the file has them. */
function declarations(text: string): { kind: string; name: string }[] {
  const out: { kind: string; name: string }[] = [];
  for (const m of text.matchAll(/^[ \t]*vertex\s+\w+\s+(\w+)\s*\(/gm)) out.push({ kind: "vertex", name: m[1] });
  for (const m of text.matchAll(/^[ \t]*fragment\s+\w+\s+(\w+)\s*\(/gm)) out.push({ kind: "fragment", name: m[1] });
  for (const m of text.matchAll(/^[ \t]*kernel\s+void\s+(\w+)\s*\(/gm)) out.push({ kind: "kernel", name: m[1] });
  return out;
}

const declared = declarations(source);
ok("shaders.metal declares the compositor's entry points", declared.length > 1,
   declared.map((d) => d.name).join(", "));
ok("shaders.metal declares a vertex and a fragment",
   declared.some((d) => d.kind === "vertex") && declared.some((d) => d.kind === "fragment"),
   declared.map((d) => `${d.kind} ${d.name}`).join(", "));

// What the app carries: a build on this Mac makes the library the way the build does here.
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
  for (const { kind, name } of declared) {
    ok(`the library has the ${kind} ${name}`, bytes.includes(name), `${bytes.length} bytes`);
  }
}

// The capture helper itself: the functions a build has to carry are the ones a pipeline names,
// so a function no pipeline names still has to reach the library, and one that pairs with
// nothing has to fail the capture rather than being left out.
const helper = join(dir, "capture-shaders");
const cc = spawnSync("clang", ["-fobjc-arc", "-O2", "-Wall", "-framework", "Metal", "-framework", "Foundation",
                               join(compositor, "capture-shaders.m"), "-o", helper], { encoding: "utf8" });
ok("capture-shaders builds", cc.status === 0, cc.stderr.slice(-400));
if (cc.status === 0) {
  const extra = [
    "test_extra_fragment",
    "test_extra_vertex",
    "test_extra_kernel",
  ];
  writeFileSync(join(dir, "extra.metal"), `${source}
fragment float4 test_extra_fragment(VOut in [[stage_in]]) { return float4(in.uv.x, 0.0f, 0.0f, 1.0f); }
vertex VOut test_extra_vertex(uint vid [[vertex_id]]) { VOut o; o.pos = float4(0.0f); o.uv = float2(vid & 1); return o; }
kernel void test_extra_kernel(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = 1.0f; }
`);
  const captured = spawnSync(helper, [join(dir, "extra.metal"), join(dir, "extra.metallib")], { encoding: "utf8" });
  ok("capture-shaders takes a source whose functions no manifest pipeline names",
     captured.status === 0, captured.stderr.slice(-400));
  if (captured.status === 0) {
    const bytes = readFileSync(join(dir, "extra.metallib"));
    for (const { name } of declarations(source)) {
      ok(`the captured library has ${name}`, bytes.includes(name), `${bytes.length} bytes`);
    }
    for (const name of extra) {
      ok(`the captured library has ${name}, which no pipeline names`, bytes.includes(name), `${bytes.length} bytes`);
    }
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

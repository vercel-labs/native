// A `<style>` inside a shadow root styles that tree and nothing else.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<div id="host"><p id="light">light</p></div>
<p id="outside">outside</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const host = document.getElementById("host")!;
const root = host.attachShadow({ mode: "open" });
root.innerHTML = '<style>p { color: rgb(1, 2, 3); }</style><slot></slot><p id="inner">inner</p>';
const inner = root.querySelector("#inner")!;
const light = document.getElementById("light")!;
const outside = document.getElementById("outside")!;
console.log("OUT inner=" + getComputedStyle(inner).color
  + " light=" + getComputedStyle(light).color
  + " outside=" + getComputedStyle(outside).color);
`;

const dir = mkdtempSync(join(tmpdir(), "native-shadow-scope-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
check("the shadow tree's own <style> styles its elements", got.includes("inner=rgb(1, 2, 3)"), got);
check("it leaves the light tree alone", got.includes("light=rgb(0, 0, 0)"), got);
check("it leaves the page alone", got.includes("outside=rgb(0, 0, 0)"), got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

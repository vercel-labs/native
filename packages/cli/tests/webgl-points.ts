// WebGL points take their size from gl_PointSize, as WebGL always does (a core GL context only
// does with GL_PROGRAM_POINT_SIZE on), and the blend constants with the values 0 and 1 exist.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=100, height=100">
<style>body { margin: 0; } canvas { display: block; }</style></head>
<body><canvas id="c" width="100" height="100"></canvas><p id="o"></p><script type="module" src="app.ts"></script></body></html>`;

const APP = `const canvas = document.getElementById("c") as HTMLCanvasElement;
const gl = canvas.getContext("webgl2")!;
function shader(type: number, src: string): WebGLShader {
  const s = gl.createShader(type)!;
  gl.shaderSource(s, src);
  gl.compileShader(s);
  return s;
}
const p = gl.createProgram()!;
gl.attachShader(p, shader(gl.VERTEX_SHADER, "#version 300 es\\nvoid main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); gl_PointSize = 40.0; }"));
gl.attachShader(p, shader(gl.FRAGMENT_SHADER, "#version 300 es\\nprecision highp float; out vec4 o; void main() { o = vec4(1.0, 0.0, 0.0, 1.0); }"));
gl.linkProgram(p);
gl.useProgram(p);
gl.enable(gl.BLEND);
gl.blendFunc(gl.ONE, gl.ZERO);
gl.clearColor(0, 0, 0, 1);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.POINTS, 0, 1);
document.getElementById("o")!.textContent = [gl.ZERO, gl.ONE, gl.NONE, gl.NO_ERROR, gl.getError()].join(" ");
`;

let failed = 0;
function ok(name: string, cond: boolean): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-webgl-points-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "print #o", NATIVE_SNAPSHOT: png } });
ok("the constants are 0 1 0 0 with no GL error", r.stdout.trim() === "0 1 0 0 0");
const img = decodePng(png);
const scale = img.w / 100;
const at = (x: number, y: number): number[] => {
  const i = (Math.round(y * scale) * img.w + Math.round(x * scale)) * 4;
  return [img.rgba[i], img.rgba[i + 1], img.rgba[i + 2]];
};
ok("the point's centre is drawn", at(50, 50)[0] > 200);
ok("a 40px point reaches 15px from its centre", at(65, 50)[0] > 200 && at(50, 35)[0] > 200);
ok("and stops before 25px", at(75, 50)[0] < 50);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");

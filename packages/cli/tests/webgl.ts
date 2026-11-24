// WebGL 2: a probe app drives the context API directly (attributes, parameters, framebuffer
// round-trips, shader logs, one indexed-free draw), then the spinning cube example is built and its
// snapshot is checked for the clear colour, the lit faces, the HUD, and the spin.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { deflateSync } from "node:zlib";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const dir = mkdtempSync(join(tmpdir(), "native-webgl-"));
mkdirSync(join(dir, "bin"));

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function build(appDir: string, name: string): string {
  const exe = join(dir, "bin", name);
  const r = spawnSync("node", ["compiler/cli.ts", "build", appDir, "-o", exe], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`build of ${appDir} failed\n${r.stderr}`);
  return exe;
}

interface Run {
  out: string[];
  img: Image;
}

// The snapshot is 2 device px per CSS px, so `cx, cy` are CSS pixels inside the window.
function run(exe: string, name: string, steps: string, env: NodeJS.ProcessEnv = {}): Run {
  const png = join(dir, `${name}.png`);
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps, ...env },
  });
  if (r.status !== 0) throw new Error(`run ${name} failed (exit ${r.status})\n${r.stderr}`);
  const out = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
  return { out, img: decodePng(png) };
}

function pixel(img: Image, cx: number, cy: number): number[] {
  const o = (cy * 2 * img.w + cx * 2) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function same(a: Image, b: Image): boolean {
  if (a.w !== b.w || a.h !== b.h) return false;
  for (let i = 0; i < a.rgba.length; i++) if (a.rgba[i] !== b.rgba[i]) return false;
  return true;
}

// --- The probe app ----------------------------------------------------------------------------
//
// One page with one 64x64 canvas: it checks the context's own answers, then draws a green triangle
// over half a blue clear so the snapshot can show the canvas bitmap the host copies out of GL.

const probe = join(dir, "probe");
// A 2x2 RGBA PNG: red, green over blue, white, which is what the probe uploads as a texture.
function quadPng(): Buffer {
  const raw = Buffer.from([
    0, 255, 0, 0, 255, 0, 255, 0, 255,
    0, 0, 0, 255, 255, 255, 255, 255, 255,
  ]);
  const table: number[] = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table.push(c >>> 0);
  }
  const crc = (data: Buffer): number => {
    let c = 0xffffffff;
    for (const b of data) c = table[(c ^ b) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Buffer): Buffer => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, "ascii");
    const sum = Buffer.alloc(4);
    sum.writeUInt32BE(crc(Buffer.concat([head.subarray(4), data])), 0);
    return Buffer.concat([head, data, sum]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(2, 0);
  ihdr.writeUInt32BE(2, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

const probeApp = `
const canvas = document.getElementById("gl") as HTMLCanvasElement;
canvas.width = 64;
canvas.height = 64;
const gl = canvas.getContext("webgl2", { alpha: false, depth: true, antialias: false })!;

console.log(\`instance \${gl instanceof WebGL2RenderingContext}\`);
const attrs = gl.getContextAttributes();
console.log(\`attributes \${attrs.alpha} \${attrs.depth} \${attrs.stencil} \${attrs.antialias}\`);
const version = gl.getParameter(gl.VERSION) as string;
console.log(\`version \${version.startsWith("WebGL 2.0 (") && version.endsWith(")")}\`);
const maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE) as number;
console.log(\`maxtexture \${maxTexture >= 2048}\`);
console.log(\`size \${gl.drawingBufferWidth}x\${gl.drawingBufferHeight}\`);
console.log(\`lost \${gl.isContextLost()}\`);

const px = new Uint8Array(4);
gl.clearColor(0.25, 0.5, 0.75, 1);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`clear \${px[0]} \${px[1]} \${px[2]} \${px[3]}\`);

// A texture-backed framebuffer takes its own clear, and binding framebuffer 0 goes back to the
// canvas's default.
const texture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, texture);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
const framebuffer = gl.createFramebuffer()!;
gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
console.log(\`complete \${gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE}\`);
gl.clearColor(1, 0, 0, 1);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`target \${px[0]} \${px[1]} \${px[2]}\`);
gl.bindFramebuffer(gl.FRAMEBUFFER, null);
gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`back \${px[0]} \${px[1]} \${px[2]}\`);

// A broken shader reports it, and says why.
const broken = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(broken, "#version 300 es\\nvoid main() { nope }");
gl.compileShader(broken);
const compiled = gl.getShaderParameter(broken, gl.COMPILE_STATUS) as boolean;
console.log(\`broken \${compiled} \${gl.getShaderInfoLog(broken).length > 0}\`);

// A program's reflection: one attribute, one uniform.
const vertexShader = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(vertexShader, "#version 300 es\\nin vec2 aPos;\\nvoid main() { gl_Position = vec4(aPos, 0.0, 1.0); }");
gl.compileShader(vertexShader);
const fragmentShader = gl.createShader(gl.FRAGMENT_SHADER)!;
gl.shaderSource(fragmentShader, "#version 300 es\\nprecision highp float;\\nuniform vec3 uColor;\\nout vec4 o;\\nvoid main() { o = vec4(uColor, 1.0); }");
gl.compileShader(fragmentShader);
const program = gl.createProgram()!;
gl.attachShader(program, vertexShader);
gl.attachShader(program, fragmentShader);
gl.linkProgram(program);
const uniform = gl.getActiveUniform(program, 0)!;
const attribute = gl.getActiveAttrib(program, 0)!;
const linked = gl.getProgramParameter(program, gl.LINK_STATUS) as boolean;
console.log(\`linked \${linked} \${uniform.name} \${uniform.type === gl.FLOAT_VEC3} \${attribute.name}\`);

// GL's origin is bottom-left: the triangle covers the lower-left half, so the snapshot's lower
// half is green and its upper half is still the blue clear.
gl.useProgram(program);
gl.uniform3f(gl.getUniformLocation(program, "uColor"), 0.0, 1.0, 0.0);
// A bool uniform arrives as a boolean and WebGL's IDL converts it; a null location is a no-op,
// so this only has to compile and run.
gl.uniform1i(null, true);
const vertexArray = gl.createVertexArray()!;
gl.bindVertexArray(vertexArray);
const buffer = gl.createBuffer()!;
gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1]), gl.STATIC_DRAW);
const position = gl.getAttribLocation(program, "aPos");
gl.enableVertexAttribArray(position);
gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
gl.clearColor(0.25, 0.5, 0.75, 1);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(8, 8, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`drawn \${px[0]} \${px[1]} \${px[2]}\`);
gl.readPixels(56, 56, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`undrawn \${px[0]} \${px[1]} \${px[2]}\`);

// Immutable storage and a half-float sub-image, the shape three.js uploads its data textures
// with: the array is a Uint16Array, not bytes.
const storageTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, storageTexture);
gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 1, 1);
gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 1, 1, gl.RGBA, gl.HALF_FLOAT, new Uint16Array(4));
console.log(\`storage \${gl.getError()}\`);

// The extension set three.js asks for: what this GL 4.1 context can really back, and nothing for
// the rest. Anisotropic filtering is a real GL extension, and its pname reaches the driver.
const supported = gl.getSupportedExtensions();
console.log(\`extensions \${supported.indexOf("EXT_color_buffer_float") >= 0 && supported.indexOf("EXT_color_buffer_half_float") >= 0 && supported.indexOf("OES_texture_float_linear") >= 0 && supported.indexOf("EXT_texture_filter_anisotropic") >= 0 && supported.indexOf("WEBGL_compressed_texture_astc") < 0}\`);
const anisotropy = gl.getExtension("EXT_texture_filter_anisotropic");
gl.bindTexture(gl.TEXTURE_2D, storageTexture);
gl.texParameterf(gl.TEXTURE_2D, anisotropy.TEXTURE_MAX_ANISOTROPY_EXT, 8);
console.log(\`anisotropy \${gl.getParameter(anisotropy.MAX_TEXTURE_MAX_ANISOTROPY_EXT)} \${gl.getExtension("WEBGL_lose_context") === null} \${gl.getError()}\`);

// The two capabilities behind those names, shown rather than assumed: a 32F framebuffer is
// complete, and filtering a 32F texture with LINEAR reads the midpoint of its two texels.
const floatTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, floatTexture);
gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA32F, 2, 1);
gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 2, 1, gl.RGBA, gl.FLOAT, new Float32Array([0, 0, 0, 1, 1, 1, 1, 1]));
const floatTarget = gl.createFramebuffer()!;
gl.bindFramebuffer(gl.FRAMEBUFFER, floatTarget);
gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, floatTexture, 0);
console.log(\`floatbuffer \${gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE}\`);
gl.bindFramebuffer(gl.FRAMEBUFFER, null);

const filterTarget = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, filterTarget);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 4, 4, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
const filterFramebuffer = gl.createFramebuffer()!;
gl.bindFramebuffer(gl.FRAMEBUFFER, filterFramebuffer);
gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, filterTarget, 0);
const filterVs = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(filterVs, "#version 300 es\\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }");
gl.compileShader(filterVs);
const filterFs = gl.createShader(gl.FRAGMENT_SHADER)!;
gl.shaderSource(filterFs, "#version 300 es\\nprecision highp float;\\nuniform sampler2D uTex;\\nout vec4 o;\\nvoid main() { o = texture(uTex, vec2(0.5, 0.5)); }");
gl.compileShader(filterFs);
const filterProgram = gl.createProgram()!;
gl.attachShader(filterProgram, filterVs);
gl.attachShader(filterProgram, filterFs);
gl.linkProgram(filterProgram);
gl.useProgram(filterProgram);
gl.bindTexture(gl.TEXTURE_2D, floatTexture);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.viewport(0, 0, 4, 4);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`filtered \${px[0]}\`);
gl.bindFramebuffer(gl.FRAMEBUFFER, null);
gl.viewport(0, 0, 64, 64);

// A markup <img> uploaded in the same turn its script runs, before any load event could land: the
// pixels the host decoded as it answered are there, so the texture holds the picture. A texture
// left without data by the upload samples as black.
const markup = document.getElementById("pic") as HTMLImageElement;
const markupTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, markupTexture);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, markup);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
const markupVs = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(markupVs, "#version 300 es\\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }");
gl.compileShader(markupVs);
const markupFs = gl.createShader(gl.FRAGMENT_SHADER)!;
gl.shaderSource(markupFs, "#version 300 es\\nprecision highp float;\\nuniform sampler2D uTex;\\nout vec4 o;\\nvoid main() { o = texture(uTex, gl_FragCoord.xy / 2.0); }");
gl.compileShader(markupFs);
const markupProgram = gl.createProgram()!;
gl.attachShader(markupProgram, markupVs);
gl.attachShader(markupProgram, markupFs);
gl.linkProgram(markupProgram);
gl.useProgram(markupProgram);
gl.bindFramebuffer(gl.FRAMEBUFFER, filterFramebuffer);
gl.viewport(0, 0, 2, 2);
gl.drawArrays(gl.TRIANGLES, 0, 3);
const markOut = new Uint8Array(16);
gl.readPixels(0, 0, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, markOut);
gl.bindFramebuffer(gl.FRAMEBUFFER, null);
gl.viewport(0, 0, 64, 64);
const markTexels: string[] = [];
for (let i = 0; i < 4; i++) markTexels.push(\`\${markOut[i * 4]},\${markOut[i * 4 + 1]},\${markOut[i * 4 + 2]}\`);
console.log(\`markuptex \${markTexels.join(" ")}\`);

// A depth texture a shadow map is built from: DEPTH_ATTACHMENT makes the render target complete,
// and TEXTURE_COMPARE_MODE turns the sampler into the compare mode three.js's shadow shaders use.
const depthTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, depthTexture);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, 2, 2, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL);
const depthFramebuffer = gl.createFramebuffer()!;
gl.bindFramebuffer(gl.FRAMEBUFFER, depthFramebuffer);
gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, depthTexture, 0);
console.log(\`depth \${gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE}\`);
gl.clearDepth(0.5);
gl.clear(gl.DEPTH_BUFFER_BIT);

// Sample it the way a shadow lookup does: a fragment at depth 0.25 is in front of the depth
// cleared to 0.5 (LEQUAL keeps it), one at 0.75 is behind and is shadowed.
const shadowVs = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(shadowVs, "#version 300 es\\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }");
gl.compileShader(shadowVs);
const shadowFs = gl.createShader(gl.FRAGMENT_SHADER)!;
gl.shaderSource(shadowFs, "#version 300 es\\nprecision highp float;\\nuniform sampler2DShadow uShadow;\\nuniform float uRef;\\nout vec4 o;\\nvoid main() { float lit = texture(uShadow, vec3(0.5, 0.5, uRef)); o = vec4(lit, lit, lit, 1.0); }");
gl.compileShader(shadowFs);
const shadowProgram = gl.createProgram()!;
gl.attachShader(shadowProgram, shadowVs);
gl.attachShader(shadowProgram, shadowFs);
gl.linkProgram(shadowProgram);
console.log(\`shadowlink \${gl.getProgramParameter(shadowProgram, gl.LINK_STATUS)} \${gl.getProgramInfoLog(shadowProgram).length === 0}\`);
gl.useProgram(shadowProgram);
gl.bindFramebuffer(gl.FRAMEBUFFER, filterFramebuffer);
gl.viewport(0, 0, 4, 4);
gl.uniform1f(gl.getUniformLocation(shadowProgram, "uRef"), 0.25);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`shadowlit \${px[0]}\`);
gl.uniform1f(gl.getUniformLocation(shadowProgram, "uRef"), 0.75);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`shadowed \${px[0]}\`);

// Back to the canvas: the attachment list three.js sets whenever it returns from a render
// target, with BACK for the default framebuffer.
gl.bindFramebuffer(gl.FRAMEBUFFER, null);
gl.drawBuffers([gl.BACK]);
console.log(\`drawbuffers \${gl.getError()}\`);
gl.viewport(0, 0, 64, 64);

// A 2D canvas uploaded as a texture, the shape three.js's CanvasTexture uploads: the canvas is
// filled red and the full-screen sampler reads its centre.
const paint = document.createElement("canvas");
paint.width = 2;
paint.height = 2;
const pen = paint.getContext("2d")!;
pen.fillStyle = "#ff0000";
pen.fillRect(0, 0, 2, 2);
const canvasTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, canvasTexture);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, paint);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.useProgram(filterProgram);
gl.clearColor(0, 0, 1, 1);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(32, 32, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`canvastex \${px[0]} \${px[1]} \${px[2]}\`);

// The same pixels as ImageData.
const pixelsIn = pen.getImageData(0, 0, 2, 2);
const dataTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, dataTexture);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, pixelsIn);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(32, 32, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`imagedata \${px[0]} \${px[1]} \${px[2]}\`);

// UNPACK_FLIP_Y_WEBGL swaps the rows of an ImageData upload: a 1x2 texture holding red over
// blue reads red at v=0.25 with the option off, and blue with it on. (The API ignores the
// unpack options for ArrayBufferView uploads, so the source here is ImageData.)
const flipVs = gl.createShader(gl.VERTEX_SHADER)!;
gl.shaderSource(flipVs, "#version 300 es\\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }");
gl.compileShader(flipVs);
const flipFs = gl.createShader(gl.FRAGMENT_SHADER)!;
gl.shaderSource(flipFs, "#version 300 es\\nprecision highp float;\\nuniform sampler2D uTex;\\nuniform float uV;\\nout vec4 o;\\nvoid main() { o = texture(uTex, vec2(0.5, uV)); }");
gl.compileShader(flipFs);
const flipProgram = gl.createProgram()!;
gl.attachShader(flipProgram, flipVs);
gl.attachShader(flipProgram, flipFs);
gl.linkProgram(flipProgram);
gl.useProgram(flipProgram);
const flipTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, flipTexture);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
const rows = new ImageData(1, 2, new Uint8ClampedArray([255, 0, 0, 255, 0, 0, 255, 255]));
gl.uniform1f(gl.getUniformLocation(flipProgram, "uV"), 0.25);
gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, rows);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(32, 16, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`flipoff \${px[0]} \${px[1]} \${px[2]}\`);
gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, rows);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(32, 16, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`flipon \${px[0]} \${px[1]} \${px[2]}\`);
gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);

// UNPACK_PREMULTIPLY_ALPHA_WEBGL scales the colour by alpha on an ImageData upload.
const alphaTexture = gl.createTexture()!;
gl.bindTexture(gl.TEXTURE_2D, alphaTexture);
gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE,
              new ImageData(1, 1, new Uint8ClampedArray([255, 0, 0, 128])));
gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.useProgram(filterProgram);
gl.clear(gl.COLOR_BUFFER_BIT);
gl.drawArrays(gl.TRIANGLES, 0, 3);
gl.readPixels(32, 32, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
console.log(\`premult \${px[0]} \${px[1]} \${px[2]}\`);

// WEBGL_debug_renderer_info names the driver behind the context.
const debugInfo = gl.getExtension("WEBGL_debug_renderer_info");
const unmasked = debugInfo === null ? "" : gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL) as string;
console.log(\`debuginfo \${debugInfo !== null} \${unmasked.length > 0}\`);

// An image element loaded at runtime, then uploaded as a texture. The load lands on a later
// turn of the loop, so the snapshot waits for it and its lines come last.
const image = document.createElement("img");
image.addEventListener("load", () => {
  console.log(\`image \${image.width}x\${image.height} \${image.complete} \${image.naturalWidth}x\${image.naturalHeight}\`);
  // The 2x2 image holds red, green (top row) over blue, white. Rendering 2x2 pixels with the
  // full-screen triangle samples each texel at its centre, so the readback is the texture itself.
  const imageTexture = gl.createTexture()!;
  gl.bindTexture(gl.TEXTURE_2D, imageTexture);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, 2, 2);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  const imageVs = gl.createShader(gl.VERTEX_SHADER)!;
  gl.shaderSource(imageVs, "#version 300 es\\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }");
  gl.compileShader(imageVs);
  const imageFs = gl.createShader(gl.FRAGMENT_SHADER)!;
  gl.shaderSource(imageFs, "#version 300 es\\nprecision highp float;\\nuniform sampler2D uTex;\\nout vec4 o;\\nvoid main() { o = texture(uTex, gl_FragCoord.xy / 2.0); }");
  gl.compileShader(imageFs);
  const imageProgram = gl.createProgram()!;
  gl.attachShader(imageProgram, imageVs);
  gl.attachShader(imageProgram, imageFs);
  gl.linkProgram(imageProgram);
  gl.useProgram(imageProgram);

  function readImage(texture: WebGLTexture): string {
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.bindFramebuffer(gl.FRAMEBUFFER, filterFramebuffer);
    gl.viewport(0, 0, 2, 2);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    const out = new Uint8Array(16);
    gl.readPixels(0, 0, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, out);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, 64, 64);
    const texels: string[] = [];
    for (let i = 0; i < 4; i++) texels.push(\`\${out[i * 4]},\${out[i * 4 + 1]},\${out[i * 4 + 2]}\`);
    return texels.join(" ");
  }

  // A texture's default unpack state flips the rows, which is why an image is upright on screen:
  // row 0 of the texture is the image's bottom row.
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  gl.bindTexture(gl.TEXTURE_2D, imageTexture);
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, image);
  console.log(\`flipped \${readImage(imageTexture)} \${gl.getError()}\`);
  // The whole-image upload, into a texture of its own: the short form sizes the texture itself.
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
  const imageTexture2 = gl.createTexture()!;
  gl.bindTexture(gl.TEXTURE_2D, imageTexture2);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, image);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  console.log(\`upright \${readImage(imageTexture2)} \${gl.getError()}\`);
});
image.src = "quad.png";

// A drag on the canvas, the input an orbit camera is built from: the pointer events come in
// order, with the button held between down and up.
const drags: string[] = [];
canvas.addEventListener("pointerdown", (e) => { drags.push(\`down \${e.clientX} \${e.clientY} \${e.buttons} \${e.pointerType}\`); });
canvas.addEventListener("pointermove", (e) => { drags.push(\`move \${e.clientX} \${e.clientY} \${e.buttons}\`); });
canvas.addEventListener("pointerup", (e) => { drags.push(\`up \${e.clientX} \${e.clientY} \${e.buttons}\`); console.log(\`drag \${drags.join(" | ")}\`); });

// Scissored clears paint the four quadrants, so the snapshot can check each channel through the
// readback path. GL's origin is bottom-left; the canvas bitmap it becomes is y-down.
gl.enable(gl.SCISSOR_TEST);
const quadrant: number[][] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [0.25, 0.5, 0.75, 1]];
for (let i = 0; i < 4; i++) {
  gl.scissor((i % 2) * 32, (i < 2 ? 1 : 0) * 32, 32, 32);
  gl.clearColor(quadrant[i][0], quadrant[i][1], quadrant[i][2], quadrant[i][3]);
  gl.clear(gl.COLOR_BUFFER_BIT);
}
gl.disable(gl.SCISSOR_TEST);
console.log(\`error \${gl.getError()}\`);
`;

const probeHtml = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="native-window" content="width=320, height=240">
<title>WebGL probe</title>
<style>
html, body { margin: 0; height: 100%; background: #ffffff; }
#gl { position: absolute; left: 0; top: 0; width: 64px; height: 64px; }
</style>
</head>
<!-- The image the probe uploads is named here too, so the build puts it in the bundle; the
     script's own Image element reads the same file through the bundle's root. This markup element
     is the one the script uploads in the same turn it runs, before its load lands. -->
<body><canvas id="gl" width="64" height="64"></canvas><img id="pic" src="quad.png" alt="" style="display: none"><script src="app.ts"></script></body>
</html>
`;
mkdirSync(probe);
writeFileSync(join(probe, "index.html"), probeHtml);
writeFileSync(join(probe, "app.ts"), probeApp);
writeFileSync(join(probe, "quad.png"), quadPng());

const probeRun = run(build(probe, "probe"), "probe", "frame 0 | drag #gl 10 6");
const probeWant = [
  "instance true",
  "attributes false true false false",
  "version true",
  "maxtexture true",
  "size 64x64",
  "lost false",
  "clear 64 128 191 255",
  "complete true",
  "target 255 0 0",
  "back 64 128 191",
  "broken false true",
  "linked true uColor true aPos",
  "drawn 0 255 0",
  "undrawn 64 128 191",
  "storage 0",
  "extensions true",
  "anisotropy 16 true 0",
  "floatbuffer true",
  "filtered 128",
  "markuptex 255,0,0 0,255,0 0,0,255 255,255,255",
  "depth true",
  "shadowlink true true",
  "shadowlit 255",
  "shadowed 0",
  "drawbuffers 0",
  "canvastex 255 0 0",
  "imagedata 255 0 0",
  "flipoff 255 0 0",
  "flipon 0 0 255",
  "premult 128 0 0",
  "debuginfo true true",
  "error 0",
  "image 2x2 true 2x2",
  "flipped 0,0,255 255,255,255 255,0,0 0,255,0 0",
  "upright 255,0,0 0,255,0 0,0,255 255,255,255 0",
  "drag down 32 32 1 mouse | move 37 35 1 | move 42 38 1 | up 42 38 0",
];
check("the WebGL 2 API answers as it should", JSON.stringify(probeRun.out) === JSON.stringify(probeWant),
  `got ${JSON.stringify(probeRun.out)}`);

// The four scissored clears reach the page as they were, at 2 device px per CSS px; the rest of the
// page is untouched.
const quadrants = [
  ["red", 16, 16, "255,0,0"],
  ["green", 48, 16, "0,255,0"],
  ["blue", 16, 48, "0,0,255"],
  ["mixed", 48, 48, "64,128,191"],
];
for (const q of quadrants) {
  const got = pixel(probeRun.img, q[1] as number, q[2] as number);
  check(`the ${q[0]} quadrant is painted into the page`, got.join(",") === q[3], `got ${got.join(",")}`);
}
const outside = pixel(probeRun.img, 200, 100);
check("the rest of the page is untouched", outside.join(",") === "255,255,255", `got ${outside.join(",")}`);

// --- The cube example -------------------------------------------------------------------------

const cube = build("../../examples/webgl-cube", "cube");
const still = run(cube, "cube-still", "frame 0", { NATIVE_REDUCED_MOTION: "1" });
const later = run(cube, "cube-later", "frame 2000", { NATIVE_REDUCED_MOTION: "1" });

check("the cube example prints its HUD", run(cube, "cube-hud", "print #hud").out.join("|") === "WEBGL2 · SPINNING LIT CUBE");

const background = "11,16,34";
check("the clear colour fills the window", pixel(still.img, 4, 4).join(",") === background,
  `got ${pixel(still.img, 4, 4).join(",")}`);
check("the cube is not clipped by the window", pixel(still.img, 4, 280).join(",") === background
  && pixel(still.img, 876, 280).join(",") === background);

const top = pixel(still.img, 440, 190);
check("the top face catches the light", top[1] > top[0] + 40 && top[1] > top[2] + 40, `got ${top.join(",")}`);
const front = pixel(still.img, 440, 330);
check("the front face is shaded", front[0] > front[1] + 20 && front[2] > front[1] + 20, `got ${front.join(",")}`);

// The cube owns a good part of the middle of the window, and none of the corners.
let filled = 0;
let total = 0;
for (let cy = 20; cy < 480; cy += 4) {
  for (let cx = 20; cx < 860; cx += 4) {
    total++;
    if (pixel(still.img, cx, cy).join(",") !== background) filled++;
  }
}
const share = filled / total;
check("the cube is framed in the middle of the window", share > 0.08 && share < 0.3, `fills ${(share * 100).toFixed(1)}%`);

check("reduced motion holds the cube still", same(still.img, later.img));
const spinA = run(cube, "cube-spin-a", "frame 0", { NATIVE_REDUCED_MOTION: "0" });
const spinB = run(cube, "cube-spin-b", "frame 1000", { NATIVE_REDUCED_MOTION: "0" });
check("the cube spins over time", !same(spinA.img, spinB.img));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

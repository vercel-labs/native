// Chrome parity: run an example in a browser and in the native app, then compare what the two
// painted. The app is served over loopback because Chrome refuses to load module scripts from a
// file URL; a TypeScript entry is bundled for the browser with the esbuild the CLI already
// depends on, so the page Chrome renders is the app, not the markup before its scripts run.

import { createRequire } from "node:module";
import { createServer } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { deflateSync } from "node:zlib";

const require = createRequire(join(import.meta.dirname, "..", "..", "..", "packages", "cli", "package.json"));

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".mp3": "audio/mpeg",
  ".webm": "video/webm",
  ".wasm": "application/wasm",
};

/** Chrome, from CHROME_BIN, the gate's own download directory, or an installed browser. */
export function findChrome(out) {
  const fromDownload = findBinary(join(out, "browsers"));
  const candidates = [
    process.env.CHROME_BIN,
    fromDownload,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  for (const c of candidates) if (existsSync(c)) return c;
  return null;
}

/** A Chrome executable under a `@puppeteer/browsers` install directory, if one was downloaded. */
function findBinary(dir, depth = 8) {
  if (!existsSync(dir) || depth === 0) return null;
  for (const entry of readdirSafe(dir)) {
    const path = join(dir, entry);
    let stat;
    try {
      stat = require("node:fs").statSync(path);
    } catch {
      continue;
    }
    if (stat.isFile() && ["chrome", "chrome.exe", "chrome-headless-shell", "chrome-headless-shell.exe", "Google Chrome for Testing", "Google Chrome for Testing.exe"].includes(entry)) return path;
    if (stat.isDirectory()) {
      const found = findBinary(path, depth - 1);
      if (found !== null) return found;
    }
  }
  return null;
}

/** Copy a directory's files into another, skipping the named entries and any symlink. */
function copyTree(src, dst, skip) {
  const fs = require("node:fs");
  for (const name of readdirSafe(src)) {
    if (skip.has(name)) continue;
    const from = join(src, name);
    const to = join(dst, name);
    let stat;
    try {
      stat = fs.lstatSync(from);
    } catch {
      continue;
    }
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) {
      fs.mkdirSync(to, { recursive: true });
      copyTree(from, to, skip);
    } else if (stat.isFile()) {
      fs.copyFileSync(from, to);
    }
  }
}

function readdirSafe(dir) {
  try {
    return require("node:fs").readdirSync(dir);
  } catch {
    return [];
  }
}

/**
 * The page to show Chrome: the example's own index.html with its TypeScript entry bundled for the
 * browser. Returns the HTML written into `workDir`, and how the page was prepared.
 */
async function preparePage(exampleDir, workDir) {
  let html = readFileSync(join(exampleDir, "index.html"), "utf8");
  const bundleName = "gate-app.js";
  const extern = /<script([^>]*)\ssrc=["']([^"']+\.(?:tsx?|jsx?|mjs))["']([^>]*)><\/script>/i.exec(html);
  let bundle;
  let replaceWith = null;
  if (extern !== null) {
    const isModule = /type=["']module["']/.test(`${extern[1]} ${extern[3]}`);
    try {
      bundle = await buildForBrowser(join(exampleDir, extern[2]), join(workDir, bundleName));
    } catch (err) {
      return { html, mode: "static", error: describe(err) };
    }
    replaceWith = [extern[0], `<script${isModule ? "" : ""} src="${bundleName}"></script>`];
  } else {
    // A page with its script inline (canvas) still needs it bundled: the inline source is written
    // as the entry, so TypeScript the browser can't parse compiles the way the native build does.
    const inline = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/i.exec(html);
    if (inline === null) return { html, mode: "static" };
    try {
      writeFileSync(join(workDir, "gate-entry.ts"), inline[1]);
      bundle = await buildForBrowser(join(workDir, "gate-entry.ts"), join(workDir, bundleName));
    } catch (err) {
      return { html, mode: "static", error: describe(err) };
    }
    replaceWith = [inline[0], `<script src="${bundleName}"></script>`];
  }
  html = html.replace(replaceWith[0], replaceWith[1]);
  return { html, mode: bundle.mode };
}

function describe(err) {
  const detail = (err?.errors ?? []).map((e) => `${e.text} ${e.location?.file ?? ""}:${e.location?.line ?? ""}`).join("; ");
  return String(detail || err?.message || err).replace(/\s+/g, " ").slice(0, 300);
}

async function buildForBrowser(entry, outfile) {
  // The path is imported as a file URL: a bare Windows path (C:\...) is not a valid module
  // specifier for the ESM loader.
  const { build } = await import(pathToFileURL(require.resolve("esbuild")).href);
  entry = resolve(entry);
  outfile = resolve(outfile);
  await build({
    entryPoints: [entry],
    outfile,
    bundle: true,
    format: "iife",
    target: "chrome120",
    jsx: "automatic",
    loader: { ".tsx": "tsx", ".ts": "ts", ".jsx": "jsx", ".js": "js" },
    logLevel: "silent",
    absWorkingDir: require("node:path").dirname(entry),
    define: { "process.env.NODE_ENV": '"production"' },
  });
  return { mode: "classic" };
}

/**
 * A screenshot of the example as Chrome paints it at `size` (CSS pixels) times `scale`, with
 * animations at their start, which is the frame a native run's first `frame 0` step paints. The
 * page is loaded from disk with its entry bundled as one classic script, so nothing depends on a
 * server: Chrome will not navigate to a loopback address in a sandbox without a network service.
 */
export async function chromeShot(chrome, exampleDir, { width, height, scale, outPng, virtualTimeMs = 300 }) {
  const work = mkdtempSync(join(tmpdir(), "gate-chrome-"));
  try {
    // The whole app, assets and public files included, so the browser sees what the bundle holds.
    copyTree(resolve(exampleDir), work, new Set(["node_modules", ".native", ".git"]));
    const page = await preparePage(resolve(exampleDir), work);
    writeFileSync(join(work, "index.html"), page.html);
    // Chrome will not make a window narrower than 500 CSS px: a narrower page is laid out 500
    // wide and the shot is still saved at the requested size, so the page is cropped and every
    // run of text lands where the 500-wide layout put it. The page gets the viewport it asks for
    // inside an iframe of its own size, which the screenshot then captures exactly.
    let target = join(work, "index.html");
    if (width < 500) {
      writeFileSync(
        join(work, "wrapper.html"),
        `<!doctype html><html><body style="margin:0;overflow:hidden;background:#000">` +
          `<iframe src="index.html" scrolling="no" style="border:0;display:block;width:${width}px;height:${height}px"></iframe>` +
          `</body></html>`,
      );
      target = join(work, "wrapper.html");
    }
    const r = require("node:child_process").spawnSync(chrome, [
      "--headless=new",
      // Headless Chrome ships without a GPU; ask ANGLE for its software rasterizer so the page's
      // WebGL 2 context exists, which is what the WebGL and three.js examples draw with.
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--hide-scrollbars",
      "--no-first-run",
      "--no-default-browser-check",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--no-proxy-server",
      "--allow-file-access-from-files",
      `--user-data-dir=${join(work, ".chrome")}`,
      `--force-device-scale-factor=${scale}`,
      `--window-size=${width},${height}`,
      `--virtual-time-budget=${virtualTimeMs}`,
      `--screenshot=${resolve(outPng)}`,
      pathToFileURL(target).href,
    ], { encoding: "utf8", timeout: 90_000, maxBuffer: 32 * 1024 * 1024 });
    return { ok: existsSync(outPng), status: r.status, stderr: (r.stderr ?? "").slice(-2000), ...page };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/** Decode a PNG's RGBA pixels, whatever its colour type and filters. */
export function decodePng(path) {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  let depth = 8;
  let colour = 6;
  let palette = null;
  let trns = null;
  const idat = [];
  while (i + 8 <= b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      depth = data[8];
      colour = data[9];
    } else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    i += 12 + len;
  }
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colour];
  const bpp = Math.ceil((channels * depth) / 8);
  const stride = Math.ceil((w * channels * depth) / 8);
  const raw = require("node:zlib").inflateSync(Buffer.concat(idat));
  const out = new Uint8Array(w * h * 4);
  const line = Buffer.alloc(stride);
  const prev = Buffer.alloc(stride);
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const filter = raw[pos++];
    raw.copy(line, 0, pos, pos + stride);
    pos += stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? line[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      line[x] = v & 0xff;
    }
    for (let x = 0; x < w; x++) {
      const at = y * w * 4 + x * 4;
      if (colour === 6) {
        out[at] = line[x * 4];
        out[at + 1] = line[x * 4 + 1];
        out[at + 2] = line[x * 4 + 2];
        out[at + 3] = line[x * 4 + 3];
      } else if (colour === 2) {
        out[at] = line[x * 3];
        out[at + 1] = line[x * 3 + 1];
        out[at + 2] = line[x * 3 + 2];
        out[at + 3] = 255;
      } else if (colour === 0) {
        out[at] = out[at + 1] = out[at + 2] = line[x];
        out[at + 3] = 255;
      } else if (colour === 3) {
        const k = line[x] * 3;
        out[at] = palette[k];
        out[at + 1] = palette[k + 1];
        out[at + 2] = palette[k + 2];
        out[at + 3] = trns !== null && line[x] < trns.length ? trns[line[x]] : 255;
      } else if (colour === 4) {
        out[at] = out[at + 1] = out[at + 2] = line[x * 2];
        out[at + 3] = line[x * 2 + 1];
      }
    }
    line.copy(prev);
  }
  return { w, h, rgba: out };
}

/** How much two snapshots differ: the share of pixels equal within `delta`, and the mean delta. */
export function diffImages(a, b, delta) {
  const w = Math.min(a.w, b.w);
  const h = Math.min(a.h, b.h);
  let same = 0;
  let sum = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * a.w + x) * 4;
      const j = (y * b.w + x) * 4;
      const d = Math.max(
        Math.abs(a.rgba[i] - b.rgba[j]),
        Math.abs(a.rgba[i + 1] - b.rgba[j + 1]),
        Math.abs(a.rgba[i + 2] - b.rgba[j + 2]),
        Math.abs(a.rgba[i + 3] - b.rgba[j + 3]),
      );
      sum += d;
      if (d <= delta) same++;
    }
  }
  const total = w * h;
  return { width: w, height: h, identical: same / total, meanDelta: sum / total };
}

/** Write a diff image: differing pixels in red over a faded copy of the native snapshot. */
export function writeDiff(a, b, delta, path) {
  const w = Math.min(a.w, b.w);
  const h = Math.min(a.h, b.h);
  const rows = [];
  for (let y = 0; y < h; y++) {
    const row = Buffer.alloc(w * 4 + 1);
    row[0] = 0;
    for (let x = 0; x < w; x++) {
      const i = (y * a.w + x) * 4;
      const j = (y * b.w + x) * 4;
      const d = Math.max(
        Math.abs(a.rgba[i] - b.rgba[j]),
        Math.abs(a.rgba[i + 1] - b.rgba[j + 1]),
        Math.abs(a.rgba[i + 2] - b.rgba[j + 2]),
      );
      const at = 1 + x * 4;
      if (d > delta) {
        row[at] = 220;
        row[at + 1] = 38;
        row[at + 2] = 38;
        row[at + 3] = 255;
      } else {
        row[at] = a.rgba[i] * 0.25 + 191;
        row[at + 1] = a.rgba[i + 1] * 0.25 + 191;
        row[at + 2] = a.rgba[i + 2] * 0.25 + 191;
        row[at + 3] = 255;
      }
    }
    rows.push(row);
  }
  writeFileSync(path, png(w, h, Buffer.concat(rows)));
}

function png(w, h, raw) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

let table = null;
function crc32(buf) {
  if (table === null) {
    table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (const byte of buf) c = table[(c ^ byte) & 0xff] ^ (c >>> 8);
  return c ^ 0xffffffff;
}

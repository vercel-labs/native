#!/usr/bin/env node
// Install unchanged, integrity-pinned upstream payloads into an atomic cache.
// Target packs are installed up front so subsequent builds work offline.
import fs from "node:fs";
import { promises as fsp } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { installedRelease, nativeManifestName, nativeTargetName, releaseConfiguration, toolchainPackageDirectory } from "./scriptc_toolchain.mjs";

function transientDownloadError(error) {
  for (let cause = error, depth = 0; cause && depth < 8; cause = cause.cause, depth++) {
    if (["ECONNRESET", "ETIMEDOUT", "ECONNREFUSED", "EPIPE", "ENETUNREACH", "EHOSTUNREACH", "EAI_AGAIN", "UND_ERR_CONNECT_TIMEOUT", "UND_ERR_SOCKET", "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT", "ERR_STREAM_PREMATURE_CLOSE"].includes(cause.code) || cause.name === "TimeoutError" || cause.name === "AbortError") return true;
  }
  return error instanceof TypeError && error.message === "fetch failed" && !error.cause;
}

// Toolchain assets are large — 130 to 160 MB per host release in scriptc
// 0.4.11 — so a fixed two-minute budget fails ordinary slower connections.
// The budget is generous and configurable; the stall guard is what catches a
// dead transfer quickly without punishing a slow but healthy one.
export const DEFAULT_DOWNLOAD_TIMEOUT_MS = 15 * 60_000;
export const DEFAULT_STALL_TIMEOUT_MS = 60_000;

function positiveMilliseconds(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) throw new Error(`${name} must be a positive number of milliseconds`);
  return number;
}

export function downloadTimeouts(env = process.env) {
  const timeout = env.NATIVE_SDK_SCRIPTC_DOWNLOAD_TIMEOUT_MS;
  const stall = env.NATIVE_SDK_SCRIPTC_DOWNLOAD_STALL_MS;
  return {
    timeoutMs: timeout === undefined || timeout === "" ? DEFAULT_DOWNLOAD_TIMEOUT_MS : positiveMilliseconds(timeout, "NATIVE_SDK_SCRIPTC_DOWNLOAD_TIMEOUT_MS"),
    stallMs: stall === undefined || stall === "" ? DEFAULT_STALL_TIMEOUT_MS : positiveMilliseconds(stall, "NATIVE_SDK_SCRIPTC_DOWNLOAD_STALL_MS"),
  };
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "unknown size";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

function formatDuration(ms) {
  return ms >= 1000 ? `${Math.round(ms / 1000)}s` : `${Math.round(ms)} ms`;
}

function downloadTimeoutError(asset, { attempt, received, elapsedMs, timeoutMs, stallMs, stalled }) {
  const total = asset.bytes === undefined ? "" : ` of ${formatBytes(asset.bytes)}`;
  const reason = stalled
    ? `stalled for ${formatDuration(stallMs)} with no data`
    : `timed out after ${formatDuration(elapsedMs)}`;
  return new Error(
    `scriptc toolchain download ${reason}: ${asset.url} (${formatBytes(received)}${total} received on attempt ${attempt}). ` +
    "Check your network connection or proxy, then run `npm run toolchain:install` in packages/core, " +
    "or reinstall @native-sdk/cli with install scripts enabled. " +
    `To allow more time, set NATIVE_SDK_SCRIPTC_DOWNLOAD_TIMEOUT_MS (currently ${timeoutMs} ms) ` +
    `or NATIVE_SDK_SCRIPTC_DOWNLOAD_STALL_MS (currently ${stallMs} ms).`,
  );
}

export async function downloadVerified(asset, output, options = {}) {
  const url = new URL(asset.url);
  if (url.protocol !== "https:") throw new Error("toolchain assets require HTTPS");
  const algorithm = asset.sha256 ? "sha256" : "sha512";
  const expected = asset.sha256 ?? asset.integrity?.replace(/^sha512-/, "");
  if (!expected || (!asset.sha256 && !asset.integrity.startsWith("sha512-"))) throw new Error("toolchain asset has no supported digest");
  const fallback = downloadTimeouts(options.env);
  const timeoutMs = options.timeoutMs === undefined ? fallback.timeoutMs : positiveMilliseconds(options.timeoutMs, "timeoutMs");
  const stallMs = options.stallTimeoutMs === undefined ? fallback.stallMs : positiveMilliseconds(options.stallTimeoutMs, "stallTimeoutMs");
  // Retry transport failures within the asset budget. Each attempt owns a new
  // stream and hash; corrupt bytes are never retried.
  const deadline = Date.now() + timeoutMs;
  for (let attempt = 1; attempt <= 4; attempt++) {
    let owned = false, retryable = false, received = 0, stalled = false;
    const controller = new AbortController();
    let lastActivity = Date.now();
    const watchdog = setInterval(() => {
      const now = Date.now();
      if (now >= deadline) controller.abort();
      else if (now - lastActivity >= stallMs) { stalled = true; controller.abort(); }
    }, Math.max(50, Math.min(1000, stallMs, Math.max(1, deadline - Date.now()))));
    try {
      const response = await (options.fetch ?? fetch)(asset.url, { signal: controller.signal });
      if (!response.ok || !response.body) {
        retryable = [408, 429, 500, 502, 503, 504].includes(response.status);
        await response.body?.cancel().catch(() => {});
        throw new Error(`cannot download ${asset.url}: HTTP ${response.status}`);
      }
      const handle = await fsp.open(output, "wx", 0o600);
      owned = true;
      const hash = createHash(algorithm);
      let bytes = 0;
      try {
        const body = Readable.fromWeb(response.body);
        body.on("data", chunk => {
          bytes += chunk.length; received = bytes; lastActivity = Date.now(); hash.update(chunk);
          options.progress?.({ url: asset.url, bytes, total: asset.bytes, attempt });
        });
        await pipeline(body, handle.createWriteStream(), { signal: controller.signal });
      } finally { await handle.close(); }
      const digest = hash.digest(asset.sha256 ? "hex" : "base64");
      if (digest !== expected || (asset.bytes !== undefined && bytes !== asset.bytes)) throw new Error(`toolchain checksum or size mismatch: ${asset.url}`);
      options.progress?.({ url: asset.url, bytes, total: asset.bytes, attempt, complete: true });
      return { bytes, digest };
    } catch (error) {
      if (owned) await fsp.rm(output, { force: true });
      const timedOut = controller.signal.aborted && (stalled || Date.now() >= deadline);
      const failure = timedOut
        ? downloadTimeoutError(asset, { attempt, received, elapsedMs: timeoutMs - Math.max(0, deadline - Date.now()), timeoutMs, stallMs, stalled })
        : error;
      const backoff = 1000 * 2 ** (attempt - 1);
      const retry = timedOut ? stalled : (retryable || transientDownloadError(error));
      if (!retry || attempt === 4 || Date.now() + backoff >= deadline) throw failure;
      await (options.sleep ?? sleep)(backoff);
    } finally { clearInterval(watchdog); }
  }
}

export async function extractVerified(archive, destination, options = {}) {
  const { x } = await import("tar");
  await fsp.mkdir(destination, { recursive: true });
  const strip = options.strip ?? 0;
  let violation;
  await x({
    file: archive, cwd: destination, strip, strict: true, preservePaths: false,
    filter(name, entry) {
      const normalized = name.replace(/^\.\//, "");
      if (path.posix.isAbsolute(normalized) || /[\\\0]/.test(normalized) || normalized.split("/").includes("..") || /^[A-Za-z]:/.test(normalized)) {
        violation ??= new Error(`unsafe toolchain archive path: ${name}`);
        return false;
      }
      if (!["File", "Directory", "ExtendedHeader", "GlobalExtendedHeader"].includes(entry.type)) {
        violation ??= new Error(`unsupported toolchain archive entry: ${entry.type}`);
        return false;
      }
      return options.prefix === undefined || normalized === options.prefix || normalized.startsWith(options.prefix + "/");
    },
  });
  if (violation) throw violation;
}

function readJson(file) { return JSON.parse(fs.readFileSync(file, "utf8")); }
function requireVersion(directory, version, expectedName) {
  const pkg = readJson(path.join(directory, "package.json"));
  if (pkg.version !== version || (expectedName && pkg.name !== expectedName)) throw new Error(`incorrect toolchain package identity: ${directory}`);
}

function verifyPack(directory, version, abi) {
  requireVersion(directory, version);
  const pack = readJson(path.join(directory, "runtime-pack.json"));
  if (pack.version !== version || pack.runtime_abi.version !== abi) throw new Error(`runtime ABI or version mismatch: ${directory}`);
  // Verify every declared object, bitcode, archive and license path before
  // publishing the installation, including targets not runnable on this host.
  const walk = value => {
    if (!value || typeof value !== "object") return;
    if (typeof value.path === "string") {
      const relative = value.path;
      if (path.isAbsolute(relative) || relative.split(/[\\/]/).includes("..")) throw new Error("runtime artifact escapes its pack");
      const raw = fs.readFileSync(path.join(directory, relative));
      if ((value.size !== undefined && raw.length !== value.size) || (value.sha256 && createHash("sha256").update(raw).digest("hex") !== value.sha256)) throw new Error(`runtime artifact mismatch: ${relative}`);
    }
    for (const child of Object.values(value)) walk(child);
  };
  walk(pack);
}

/// Progress for the long release download: one line per 10% on a pipe, a
/// carriage-returned percentage on a terminal. A silent `npm install` looks
/// hung on a slow connection, which is the other half of the reported issue.
export function defaultProgress(version) {
  const tty = process.stderr.isTTY === true;
  let lastBucket = -1, lastAt = 0;
  return ({ bytes, total, complete }) => {
    const percent = total ? Math.floor((bytes / total) * 100) : null;
    if (complete) {
      // The last data report already printed 100%; only close the terminal
      // line, and report a final size when the total is unknown.
      if (tty) process.stderr.write("\n");
      else if (percent === null) process.stderr.write(`Installing scriptc ${version}: ${formatBytes(bytes)}\n`);
      return;
    }
    const bucket = percent === null ? Math.floor(bytes / (16 * 1024 * 1024)) : Math.floor(percent / 10);
    const now = Date.now();
    if (bucket === lastBucket || (tty && now - lastAt < 200)) return;
    lastBucket = bucket; lastAt = now;
    const totalText = total ? ` / ${formatBytes(total)}` : "";
    const percentText = percent === null ? "" : ` (${percent}%)`;
    const line = `Installing scriptc ${version}: ${formatBytes(bytes)}${totalText}${percentText}`;
    process.stderr.write(tty ? `\r${line}` : `${line}\n`);
  };
}

export async function installScriptc(origin = new URL("../package.json", import.meta.url), options = {}) {
  const config = releaseConfiguration(origin, options);
  if (config === null) throw new Error("SDK manifest does not select a release toolchain");
  try { installedRelease(origin, options); return config; } catch { /* install or repair */ }
  // Each installer has its own staging directory. Concurrent installs never
  // expose partial payloads or remove another installer's temporary files.
  await fsp.mkdir(path.dirname(config.root), { recursive: true });
  const staging = config.root + ".install-" + randomUUID();
  await fsp.mkdir(staging, { mode: 0o700 });
  const modules = path.join(staging, "api", "node_modules");
  const scope = path.join(modules, "@scriptc");
  const releaseRoot = path.join(staging, "release");
  const downloaded = [];
  const progress = options.progress === false ? undefined : (options.progress ?? defaultProgress(config.release.version));
  const acquire = async (asset, destination, extraction = {}) => {
    const archive = path.join(staging, "asset-" + randomUUID() + ".tar.gz");
    try {
      const result = await downloadVerified(asset, archive, { ...options, progress });
      await extractVerified(archive, destination, extraction);
      downloaded.push({ url: asset.url, ...result });
    } finally { await fsp.rm(archive, { force: true }); }
  };
  try {
    console.error(`Installing scriptc ${config.release.version} for ${config.host}`);
    await acquire(config.release.releases[config.host], releaseRoot);
    const nativeManifestPath = path.join(releaseRoot, "bin", nativeManifestName(config.host));
    const nativeManifest = readJson(nativeManifestPath);
    if (nativeManifest.compiler_version !== config.release.version || nativeManifest.target !== nativeTargetName(config.host)) throw new Error("native compiler release identity mismatch");
    for (const [key, asset] of Object.entries(config.release.packages)) {
      const directory = toolchainPackageDirectory(modules, key, asset);
      await acquire(asset, directory, { strip: 1 });
      requireVersion(directory, asset.version, asset.name);
    }
    // Matching API dependencies are copied from the verified host release;
    // their package identities remain upstream's and their contents unchanged.
    await fsp.mkdir(scope, { recursive: true });
    await fsp.cp(path.join(releaseRoot, "lib", "runtime-sources"), path.join(scope, "runtime"), { recursive: true });
    await fsp.cp(path.join(releaseRoot, "lib", "llvm"), path.join(scope, "llvm-" + config.host), { recursive: true });
    // The TypeScript 7 checker the compiler shells out to. Its platform
    // package ships in the host release beside LLVM; the `tsc-ts` launcher
    // package is one of the npm packages above, and the compiler locates the
    // platform executable through it.
    if (config.release.tscTsVersion !== undefined) {
      await fsp.cp(path.join(releaseRoot, "lib", "tsc-ts"), path.join(modules, "@tsc-ts", config.host), { recursive: true });
      const tscTsPlatform = readJson(path.join(modules, "@tsc-ts", config.host, "package.json"));
      if (tscTsPlatform.name !== "@tsc-ts/" + config.host || tscTsPlatform.version !== config.release.tscTsVersion) throw new Error("tsc-ts checker package version mismatch");
    }
    const nativeTypescript = readJson(path.join(releaseRoot, "lib", "typescript", "package.json"));
    if (nativeTypescript.version !== config.release.typescriptNativeVersion || !nativeTypescript.name.startsWith("@typescript/typescript-")) throw new Error("native TypeScript parser version mismatch");
    await fsp.cp(path.join(releaseRoot, "lib", "typescript"), path.join(modules, ...nativeTypescript.name.split("/")), { recursive: true });
    requireVersion(path.join(scope, "runtime"), config.release.version, "@scriptc/runtime");
    requireVersion(path.join(scope, "llvm-" + config.host), config.release.version);
    for (const [target, asset] of Object.entries(config.release.releases)) {
      const packRoot = path.join(scope, "runtime-" + target);
      if (target === config.host) await fsp.cp(path.join(releaseRoot, "lib", "runtime-" + target), packRoot, { recursive: true });
      else await acquire(asset, packRoot, { prefix: "lib/runtime-" + target, strip: 3 });
    }
    const packs = fs.readdirSync(scope).filter(name => name.startsWith("runtime-"));
    for (const name of packs) verifyPack(path.join(scope, name), config.release.version, config.release.runtimeAbi);
    // Extend the upstream relocatable manifest with the complete matching
    // target packs. Keep the original manifest alongside it for provenance.
    await fsp.copyFile(nativeManifestPath, path.join(releaseRoot, "bin", "scriptc.upstream.json"));
    nativeManifest.runtime_packs = packs.map(name => ({ target: nativeTargetName(name.slice("runtime-".length)), path: "../../api/node_modules/@scriptc/" + name }));
    await fsp.writeFile(nativeManifestPath, JSON.stringify(nativeManifest, null, 2) + "\n");
    const probe = spawnSync(path.join(releaseRoot, "bin", process.platform === "win32" ? "scriptc.exe" : "scriptc"), ["-v"], { encoding: "utf8" });
    if (probe.status !== 0 || probe.stdout.trim() !== config.release.version) throw new Error("native compiler executable reports another release");
    const receipt = { schemaVersion: 1, version: config.release.version, host: config.host, manifestSha256: config.identity, complete: true, runtimeAbi: config.release.runtimeAbi, runtimePacks: packs, downloaded };
    await fsp.writeFile(path.join(staging, "installed.json"), JSON.stringify(receipt, null, 2) + "\n");
    try { await fsp.rename(staging, config.root); }
    catch (error) {
      // A concurrent successful install wins. A corrupt existing directory
      // needs explicit removal instead of overwriting a possibly active build.
      try { installedRelease(origin, options); } catch { throw error; }
    }
    installedRelease(origin, options);
    return config;
  } finally { await fsp.rm(staging, { recursive: true, force: true }); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await installScriptc(); }
  catch (error) { console.error(`scriptc installation failed: ${error.message}`); process.exitCode = 1; }
}

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
import { installedRelease, nativeManifestName, nativeTargetName, releaseConfiguration } from "./scriptc_toolchain.mjs";

export async function downloadVerified(asset, output, options = {}) {
  const url = new URL(asset.url);
  if (url.protocol !== "https:") throw new Error("toolchain assets require HTTPS");
  const algorithm = asset.sha256 ? "sha256" : "sha512";
  const expected = asset.sha256 ?? asset.integrity?.replace(/^sha512-/, "");
  if (!expected || (!asset.sha256 && !asset.integrity.startsWith("sha512-"))) throw new Error("toolchain asset has no supported digest");
  const hash = createHash(algorithm);
  const response = await (options.fetch ?? fetch)(asset.url, { signal: AbortSignal.timeout(120_000) });
  if (!response.ok || !response.body) throw new Error(`cannot download ${asset.url}: HTTP ${response.status}`);
  const body = Readable.fromWeb(response.body);
  let bytes = 0;
  body.on("data", chunk => { bytes += chunk.length; hash.update(chunk); });
  try {
    await pipeline(body, fs.createWriteStream(output, { flags: "wx", mode: 0o600 }));
    const digest = hash.digest(asset.sha256 ? "hex" : "base64");
    if (digest !== expected || (asset.bytes !== undefined && bytes !== asset.bytes)) throw new Error(`toolchain checksum or size mismatch: ${asset.url}`);
    return { bytes, digest };
  } catch (error) {
    await fsp.rm(output, { force: true });
    throw error;
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
  const acquire = async (asset, destination, extraction = {}) => {
    const archive = path.join(staging, "asset-" + randomUUID() + ".tar.gz");
    try {
      const result = await downloadVerified(asset, archive, options);
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
      const directory = path.join(modules, ...(key === "compiler" ? ["@scriptc", "compiler"] : key.startsWith("runtime-") ? ["@scriptc", key] : [key]));
      await acquire(asset, directory, { strip: 1 });
      requireVersion(directory, asset.version, asset.name);
    }
    // Matching API dependencies are copied from the verified host release;
    // their package identities remain upstream's and their contents unchanged.
    await fsp.mkdir(scope, { recursive: true });
    await fsp.cp(path.join(releaseRoot, "lib", "runtime-sources"), path.join(scope, "runtime"), { recursive: true });
    await fsp.cp(path.join(releaseRoot, "lib", "llvm"), path.join(scope, "llvm-" + config.host), { recursive: true });
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

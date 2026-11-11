// Resolve the SDK's exact release installation without downloading at build
// time. Compiler overrides and older SDK package fixtures keep their own route.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

export function scriptcVersion(manifest) {
  const pin = manifest.nativeToolchain?.scriptc ?? manifest.dependencies?.scriptc;
  if (typeof pin !== "string" || !/^\d+\.\d+\.\d+$/.test(pin)) throw new Error("SDK manifest has no exact scriptc version");
  return pin;
}

export function hostRelease(options = {}) {
  const platform = options.platform ?? process.platform;
  const arch = options.arch ?? process.arch;
  if (!['x64', 'arm64'].includes(arch)) throw new Error(`unsupported scriptc host: ${platform}-${arch}`);
  if (platform === "darwin") return `darwin-${arch}`;
  // Windows ARM64 can run the published x64 compiler through OS emulation.
  // Native library target admission remains the compiler's responsibility.
  if (platform === "win32") return "win32-x64-msvc";
  if (platform === "linux") {
    const libc = options.libc ?? (process.report.getReport().header.glibcVersionRuntime ? "gnu" : "musl");
    if (!['gnu', 'musl'].includes(libc)) throw new Error(`unsupported Linux libc: ${libc}`);
    return `linux-${arch}-${libc}`;
  }
  throw new Error(`unsupported scriptc host: ${platform}-${arch}`);
}

export function nativeTargetName(distribution) {
  return distribution.replace(/^darwin-/, "macos-").replace(/^win32-/, "windows-");
}

export function nativeManifestName(host) {
  return host.startsWith("win32-") ? "scriptc.exe.json" : "scriptc.json";
}

export function toolchainPackageDirectory(modules, key, asset) {
  return path.join(modules, ...(asset.name.startsWith("@scriptc/") ? asset.name.split("/") : [key]));
}

export function coreManifestPath(origin) {
  let directory = path.dirname(origin instanceof URL || origin.startsWith("file:") ? fileURLToPath(origin) : origin);
  for (;;) {
    const candidate = path.join(directory, "package.json");
    if (fs.existsSync(candidate)) return candidate;
    const parent = path.dirname(directory);
    if (parent === directory) throw new Error("cannot locate the SDK package manifest");
    directory = parent;
  }
}

export function releaseConfiguration(origin, options = {}) {
  const packagePath = coreManifestPath(origin);
  const manifest = JSON.parse(fs.readFileSync(packagePath, "utf8"));
  if (!manifest.nativeToolchain) return null;
  const manifestPath = path.join(path.dirname(packagePath), "scripts", "scriptc-toolchain.json");
  const raw = fs.readFileSync(manifestPath);
  const release = JSON.parse(raw);
  if (release.schemaVersion !== 1 || release.version !== scriptcVersion(manifest)) throw new Error("scriptc release manifest disagrees with the SDK pin");
  const identity = createHash("sha256").update(raw).digest("hex");
  const env = options.env ?? process.env;
  const cache = env.NATIVE_SDK_SCRIPTC_CACHE ?? path.join(os.homedir(), ".native", "toolchains", "scriptc");
  const host = hostRelease(options);
  if (!release.releases[host]) throw new Error(`scriptc ${release.version} has no ${host} release`);
  const root = path.join(cache, release.version, host, identity.slice(0, 16));
  return { packagePath, manifestPath, release, identity, root, host };
}

export function installedRelease(origin, options = {}) {
  const config = releaseConfiguration(origin, options);
  if (config === null) return null;
  let receipt;
  try { receipt = JSON.parse(fs.readFileSync(path.join(config.root, "installed.json"), "utf8")); }
  catch { throw new Error(`scriptc ${config.release.version} is not installed; run npm run toolchain:install in packages/core, or reinstall @native-sdk/cli with install scripts enabled`); }
  if (receipt.manifestSha256 !== config.identity || receipt.host !== config.host || receipt.version !== config.release.version || !receipt.complete) {
    throw new Error("scriptc installation is incomplete or belongs to another release");
  }
  const packs = [...Object.keys(config.release.releases).map(target => "runtime-" + target), ...Object.keys(config.release.packages).filter(name => name.startsWith("runtime-"))].sort();
  if (receipt.runtimeAbi !== config.release.runtimeAbi || !Array.isArray(receipt.runtimePacks) || JSON.stringify([...receipt.runtimePacks].sort()) !== JSON.stringify(packs)) {
    throw new Error("scriptc installation has an incomplete runtime pack inventory");
  }
  const modules = path.join(config.root, "api", "node_modules");
  for (const [key, asset] of Object.entries(config.release.packages)) {
    const directory = toolchainPackageDirectory(modules, key, asset);
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
    if (pkg.name !== asset.name || pkg.version !== asset.version) throw new Error(`scriptc installation has an incorrect package identity: ${key}`);
  }
  for (const name of [`release/bin/${nativeManifestName(config.host)}`, `release/bin/scriptc${config.host.startsWith("win32-") ? ".exe" : ""}`, "api/node_modules/@scriptc/compiler/dist/index.js", "api/node_modules/@scriptc/compiler/surface-manifest.json", "api/node_modules/typescript/package.json", "api/node_modules/typescript5/package.json", ...(config.release.tscTsVersion ? ["api/node_modules/tsc-ts/package.json", `api/node_modules/@tsc-ts/${config.host}/lib/${config.host.startsWith("win32-") ? "tsc-ts.exe" : "tsc-ts"}`] : []), ...(config.release.packages.types ? ["api/node_modules/@scriptc/types/index.d.ts"] : []), ...(config.release.packages.threads ? ["api/node_modules/@scriptc/threads/index.d.ts", "api/node_modules/@scriptc/threads/index.js"] : []), ...packs.map(name => `api/node_modules/@scriptc/${name}/runtime-pack.json`)]) {
    if (!fs.statSync(path.join(config.root, name), { throwIfNoEntry: false })?.isFile()) throw new Error(`scriptc installation is missing ${name}`);
  }
  if (config.release.tscTsVersion) {
    const tscTs = JSON.parse(fs.readFileSync(path.join(modules, "@tsc-ts", config.host, "package.json"), "utf8"));
    if (tscTs.name !== "@tsc-ts/" + config.host || tscTs.version !== config.release.tscTsVersion) throw new Error("scriptc installation has an incorrect tsc-ts checker identity");
  }
  for (const name of packs) {
    const pack = JSON.parse(fs.readFileSync(path.join(modules, "@scriptc", name, "runtime-pack.json"), "utf8"));
    if (pack.version !== config.release.version || pack.runtime_abi?.version !== config.release.runtimeAbi) throw new Error(`scriptc installation has an incompatible runtime pack: ${name}`);
  }
  return config;
}

export function compilerApiEntry(origin, options = {}) {
  const config = installedRelease(origin, options);
  return config === null
    ? createRequire(origin).resolve("@scriptc/compiler")
    : path.join(config.root, "api", "node_modules", "@scriptc", "compiler", "dist", "index.js");
}

export function compilerSurfacePath(origin, options = {}) {
  const config = installedRelease(origin, options);
  if (config) return path.join(config.root, "api", "node_modules", "@scriptc", "compiler", "surface-manifest.json");
  return path.join(path.dirname(coreManifestPath(origin)), "node_modules", "@scriptc", "compiler", "surface-manifest.json");
}

// Preserve the package import's provenance inside isolated compilation trees.
// Only declarations from the checked, exact release enter the source graph.
export function stageContractTypes(destination, origin, options = {}) {
  const config = installedRelease(origin, options);
  if (!config?.release.packages.types) return;
  fs.cpSync(path.join(config.root, "api", "node_modules", "@scriptc", "types"),
    path.join(destination, "node_modules", "@scriptc", "types"), { recursive: true });
}

// The runtime pack a target links, named the way the installed release's
// compiler manifest lists it (`runtime_packs[].target`). The build graph
// states Zig triples; the compiler's own target table names its packs:
// x86_64 is `x64`, aarch64 `arm64`, Android and iOS are platforms of their
// own, and both Windows ABIs link the one x64 COFF pack. Null when the
// triple names no pack the release carries.
export function runtimePackTargetName(triple) {
  const [rawArch, rawOs, rawAbi = ""] = triple.split("-");
  const architecture = { x86_64: "x64", aarch64: "arm64", wasm32: "wasm32" }[rawArch];
  const os = rawOs?.split(".")[0];
  // A glibc floor rides the ABI (`gnu.2.34`); the pack is chosen by ABI alone.
  const abi = rawAbi.split(".")[0];
  if (architecture === undefined || os === undefined) return null;
  if (os === "linux") {
    if (abi.startsWith("android")) return `android-${architecture}`;
    return abi === "gnu" || abi === "musl" ? `linux-${architecture}-${abi}` : null;
  }
  if (os === "macos") return `macos-${architecture}`;
  if (os === "ios") return `${abi === "simulator" ? "ios-simulator" : "ios"}-${architecture}`;
  if (os === "windows") return `windows-${architecture}-msvc`;
  if (os === "wasi") return `wasm32-wasi`;
  return null;
}

// The runtime unit that completes a library archive. scriptc 0.4.11's
// library flavors select their objects from a fixed table that omits the
// declaration-adoption runtime (`scr_decl_adopt.c`), while the compiler still
// lowers an adopting cast of a dynamic value to `scr_dyn_adoptable` and
// `scr_dyn_adopt_shared` calls — so a compiled core whose facade adopts a
// shared declaration carries undefined symbols from the start, and every
// link against its archive fails. The pack ships that unit for its executable
// flavors; it is plain runtime state, shared with the plain library flavors
// (the threaded library flavors compile their exception state per instance
// instead, which is why only the plain ones can take it), and it is compiled
// for the same target from the same sources. So the archive gains the pack's
// own prebuilt unit rather than a stub. A release whose library flavor lists
// the unit itself needs nothing, and the mobile packs — library-only — ship
// no executable flavor to take it from; both cases return null.
export function libraryAdoptionUnit(directory, pack, optimization = "release") {
  const library = pack.flavors?.[optimization === "dev" ? "library-dev" : "library-release"];
  if (!Array.isArray(library?.runtime_units)) return null;
  if (library.runtime_units.some((unit) => unit.source === "scr_decl_adopt.c")) return null;
  const companion = pack.flavors?.[optimization === "dev" ? "dev" : "release"];
  const unit = (companion?.runtime_units ?? [])
    .find((entry) => entry.source === "scr_decl_adopt.c" && entry.predicate !== false);
  // The worker build of the same unit keeps exception state per worker; the
  // archive is one instance, so it takes the default variant.
  const variant = (unit?.variants ?? []).find((candidate) =>
    candidate.when?.workers !== true && !(candidate.defines ?? []).includes("SCR_WORKERS") &&
    typeof candidate.path === "string");
  if (variant === undefined) return null;
  const object = path.join(directory, variant.path);
  if (!fs.statSync(object, { throwIfNoEntry: false })?.isFile()) return null;
  return { member: path.basename(variant.path), object, sha256: variant.sha256, size: variant.size };
}

// Add the adoption unit a compiled core archive is missing (libraryAdoptionUnit)
// with the build's own zig ar — the archiver scriptc itself assembles library
// archives with, which preserves the archive's object format and rewrites its
// symbol index. The caller passes the profile the compile ran under (its
// optimization selects the library flavor), and the target triple when the
// build knows one; a host-only compile links the host pack. Returns the added
// member, or null when the archive needs nothing (or the installation knows no
// pack for the target, leaving the compile's own archive as it stands).
export function completeLibraryArchive(archive, options = {}) {
  if (!fs.statSync(archive, { throwIfNoEntry: false })?.isFile()) return null;
  const config = releaseConfiguration(options.origin, options);
  if (config === null) return null;
  const target = options.targetPlatform === undefined ? nativeTargetName(config.host) : runtimePackTargetName(options.targetPlatform);
  if (target === null) return null;
  // A compiler override can build against a release this SDK never installed;
  // then there is no pack to complete the archive from.
  const nativeManifestPath = path.join(config.root, "release", "bin", nativeManifestName(config.host));
  if (!fs.statSync(nativeManifestPath, { throwIfNoEntry: false })?.isFile()) return null;
  const nativeManifest = JSON.parse(fs.readFileSync(nativeManifestPath, "utf8"));
  const registered = (nativeManifest.runtime_packs ?? []).find((entry) => entry.target === target);
  if (registered === undefined) return null;
  const directory = path.resolve(path.join(config.root, "release", "bin"), registered.path);
  if (!fs.statSync(path.join(directory, "runtime-pack.json"), { throwIfNoEntry: false })?.isFile()) return null;
  const pack = JSON.parse(fs.readFileSync(path.join(directory, "runtime-pack.json"), "utf8"));
  const profile = options.profile === undefined ? {} : JSON.parse(fs.readFileSync(options.profile, "utf8"));
  const unit = libraryAdoptionUnit(directory, pack, options.optimization ?? profile.optimization);
  if (unit === null) return null;
  const bytes = fs.readFileSync(unit.object);
  if ((unit.size !== undefined && bytes.length !== unit.size) ||
    (unit.sha256 !== undefined && createHash("sha256").update(bytes).digest("hex") !== unit.sha256)) {
    throw new Error(`the installed scriptc runtime pack's ${unit.member} does not match its manifest — reinstall the pinned toolchain`);
  }
  const ar = options.ar ?? ((arArgs) => spawnSync(options.zigExe ?? "zig", ["ar", ...arArgs], { encoding: "utf8" }));
  const appended = ar(["rcs", archive, unit.object]);
  if (appended.status !== 0 || appended.error !== undefined) {
    // Leave the compile's own archive in place rather than failing every
    // build of a core that never adopts a shared declaration.
    console.error(`could not add scriptc's ${unit.member} to ${path.basename(archive)} (${appended.error ?? appended.stderr ?? `exit ${appended.status}`}) — a core that adopts a shared declaration will not link until the toolchain is complete`);
    return null;
  }
  return unit.member;
}

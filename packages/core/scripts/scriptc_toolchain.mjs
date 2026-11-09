// Resolve the SDK's exact release installation without downloading at build
// time. Compiler overrides and older SDK package fixtures keep their own route.
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
  for (const name of [`release/bin/${nativeManifestName(config.host)}`, `release/bin/scriptc${config.host.startsWith("win32-") ? ".exe" : ""}`, "api/node_modules/@scriptc/compiler/dist/index.js", "api/node_modules/@scriptc/compiler/surface-manifest.json", "api/node_modules/typescript/package.json", "api/node_modules/typescript5/package.json", ...(config.release.packages.types ? ["api/node_modules/@scriptc/types/index.d.ts"] : []), ...(config.release.packages.threads ? ["api/node_modules/@scriptc/threads/index.d.ts", "api/node_modules/@scriptc/threads/index.js"] : []), ...packs.map(name => `api/node_modules/@scriptc/${name}/runtime-pack.json`)]) {
    if (!fs.statSync(path.join(config.root, name)).isFile()) throw new Error(`scriptc installation is missing ${name}`);
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

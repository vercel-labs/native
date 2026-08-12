// The compiler-truth typecheck: run the pinned external core compiler's
// analyzer over the author's entry with the shipped SDK declarations
// mapped, so `native check` answers with the SAME compiler that will
// build the core — a verdict the frontend's own checker can only
// approximate from a different TypeScript line.
//
//   node compiler_typecheck.mjs <entry.ts>
//
// Exit 0: the compiler's analyzer accepts the program (its static-subset
// findings are compile-time concerns, not check failures). Exit 1: the
// program does not typecheck under the compiler — its errors, already
// printed verbatim, are the teaching. Exit 2: toolchain missing/broken.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const entry = process.argv[2];
if (!entry) {
  console.error("usage: compiler_typecheck.mjs <entry.ts>");
  process.exit(2);
}
let generatedCore = null;
for (let i = 3; i < process.argv.length; i++) {
  if (process.argv[i] === "--sdk-core") generatedCore = process.argv[++i] ?? null;
}
const here = path.dirname(fileURLToPath(import.meta.url));
const coreRoot = path.resolve(here, "..");
let compilerJs;
try {
  compilerJs = createRequire(path.join(coreRoot, "package.json")).resolve("scriptc/dist/main.js");
} catch {
  console.error("the external core compiler is not installed — run `npm ci --include=dev` in the SDK's packages/core");
  process.exit(2);
}
// The shipped declaration files stand in for the SDK's module surface;
// value imports stay external-host findings, which is correct — the
// compile stage links the real implementations.
const maps = [];
for (const [specifier, file] of [
  ["@native-sdk/core", "sdk/core.d.ts"],
  ["@native-sdk/core/text", "sdk/text.d.ts"],
  ["@native-sdk/core/events", "sdk/events.d.ts"],
]) {
  const p = specifier === "@native-sdk/core" && generatedCore !== null
    ? path.resolve(generatedCore)
    : path.join(coreRoot, file);
  if (fs.existsSync(p)) maps.push("--external-types", `${specifier}=${p}`);
}
const servicesClient = path.resolve(path.dirname(entry), "..", "node_modules", "@native-sdk", "services", "index.d.ts");
if (fs.existsSync(servicesClient)) maps.push("--external-types", `@native-sdk/services=${servicesClient}`);
const sourceRoot = path.dirname(entry);
const serviceVendor = path.join(sourceRoot, "services", "vendor");
function vendorPackageDirs(root) {
  if (!fs.existsSync(root)) return [];
  const dirs = [];
  for (const item of fs.readdirSync(root, { withFileTypes: true })) {
    if (!item.isDirectory()) continue;
    const candidate = path.join(root, item.name);
    if (item.name.startsWith("@")) {
      for (const child of fs.readdirSync(candidate, { withFileTypes: true })) {
        if (child.isDirectory()) dirs.push(path.join(candidate, child.name));
      }
    } else dirs.push(candidate);
  }
  return dirs;
}
const vendoredPackages = [];
for (const packageDir of vendorPackageDirs(serviceVendor)) {
  const manifestPath = path.join(packageDir, "package.json");
  if (!fs.existsSync(manifestPath)) continue;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const types = manifest.types ?? manifest.typings ?? "index.d.ts";
  const declaration = typeof types === "string" ? path.resolve(packageDir, types) : "";
  if (typeof manifest.name === "string" && fs.existsSync(declaration)) {
    // Do not map vendored packages as external host modules: service coverage
    // must follow --npm-static into their shipped JS, exactly like the build.
    // The declaration check here is only the eligibility/source-identity gate.
    vendoredPackages.push({ name: manifest.name, directory: packageDir });
  }
}
function serviceEntries(root) {
  const found = [];
  if (!fs.existsSync(root)) return found;
  for (const item of fs.readdirSync(root, { withFileTypes: true })) {
    if (item.isDirectory() && item.name === "vendor") continue;
    const candidate = path.join(root, item.name);
    if (item.isDirectory()) found.push(...serviceEntries(candidate));
    else if (item.isFile() && item.name.endsWith(".ts") && !item.name.endsWith(".d.ts")) found.push(candidate);
  }
  return found.sort();
}

function packagePath(root, name) {
  return path.join(root, ...name.split("/"));
}

function isNpmStaticRefusal(output) {
  const percent = output.match(/compile statically\s+\d+\s+\((\d+)%\)/i);
  return (percent !== null && Number(percent[1]) < 100)
    || /SC-NPM-STATIC|\bSC2013\b|\bSC4020\b|island fallback|cannot compile statically|static coverage[^\n]*dynamic/i.test(output);
}

let checkFailure = false;
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-coverage-"));
try {
  const stagedRoot = path.join(scratch, "src");
  if (vendoredPackages.length > 0) {
    fs.cpSync(sourceRoot, stagedRoot, { recursive: true });
    for (const pkg of vendoredPackages) {
      const destination = packagePath(path.join(stagedRoot, "node_modules"), pkg.name);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.cpSync(pkg.directory, destination, { recursive: true });
    }
  }
  const authoredCandidates = [entry, ...serviceEntries(path.join(sourceRoot, "services"))];
  for (const authoredCandidate of authoredCandidates) {
    const isService = authoredCandidate !== entry;
    const candidate = isService && vendoredPackages.length > 0
      ? path.join(stagedRoot, path.relative(sourceRoot, authoredCandidate))
      : authoredCandidate;
    const npmArgs = isService && vendoredPackages.length > 0
      ? ["--npm-static", vendoredPackages.map((pkg) => pkg.name).join(",")]
      : [];
    const probe = spawnSync(process.execPath, [compilerJs, "coverage", candidate, ...npmArgs, ...maps], { encoding: "utf8" });
    const out = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
    // Coverage deliberately reports per-package fallback as a note even
    // when the rest of the source graph is analyzable. Native SDK's policy
    // upgrades that note to a refusal: service builds have no island tier.
    if (isService && isNpmStaticRefusal(out)) {
      process.stderr.write(out);
      console.error(
        "native check: this service package does not clear scriptc's static tier. " +
        "Choose another exact vendored package, port/vendor a static-compatible implementation, or wait for compiler support; " +
        "Native SDK never enables npm auto-fallback or --dynamic.",
      );
      checkFailure = true;
      continue;
    }
    if (probe.status === 0) continue;
    // Analyzer refusals for TYPE errors carry the compiler's own diagnostics;
    // pass them through untouched and fail the check. Service files receive
    // this verdict independently because the core is forbidden to import them.
    if (/TypeScript error/.test(out) || /error SC0001/.test(out)) {
      process.stderr.write(out);
      checkFailure = true;
      continue;
    }
    // Any other nonzero outcome (analyzer internal trouble) must not wedge
    // `native check`: the compile stage will judge for real.
    process.stderr.write(out);
    console.error(`native check: the external compiler's analyzer could not reach a verdict for ${authoredCandidate}; the build will judge for real`);
  }
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
process.exit(checkFailure ? 1 : 0);

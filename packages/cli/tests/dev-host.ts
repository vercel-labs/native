// The cached dev host: its key covers the SDK's own sources and not the app's, its globals
// module holds every runtime global, and it is built once and shared.
//
//   node tests/dev-host.ts

import { appendFileSync, chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
// The cache directory is this run's own, so the host build starts cold once and then is found.
process.env["NATIVE_CACHE_DIR"] = mkdtempSync(join(process.env["TMPDIR"] ?? "/tmp", "native-dev-host-cache-"));

const {
  DEV_HOST_VERSION, PREBUILT_SCHEMA, devGlobalsSource, devHostDir, devHostKey, devHostLibc,
  devHostSourceDigest, ensureDevHost, forgetDevHostKey, libnodePack, libnodeAbiIdentity,
  prebuiltPackageName, readPrebuiltHost,
} = await import("../compiler/dev-host.ts");
const { GLOBALS } = await import("../compiler/globals.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// ---------------------------------------------------------------------------
// The key covers the SDK, not the app

const appDir = mkdtempSync(join(process.env["TMPDIR"] ?? "/tmp", "native-dev-host-app-"));
mkdirSync(appDir, { recursive: true });
writeFileSync(join(appDir, "index.html"), "<!doctype html><html><body></body></html>");
writeFileSync(join(appDir, "app.ts"), "export const answer = 42;\n");
const before = devHostKey();

// An app file is no input of the host: the host holds no app code.
writeFileSync(join(appDir, "app.ts"), "export const answer = 43;\n");
check("an app file does not change the key", devHostKey() === before);

// A runtime file is: the host compiles the whole runtime.
const runtimeFile = join(ROOT, "runtime", "animation.ts");
const original = readFileSync(runtimeFile);
try {
  appendFileSync(runtimeFile, "\n// dev host key test\n");
  forgetDevHostKey();
  check("a runtime file changes the key", devHostKey() !== before);
} finally {
  writeFileSync(runtimeFile, original);
  forgetDevHostKey();
}
check("the key returns to its value", devHostKey() === before);

// ---------------------------------------------------------------------------
// The globals module

const globals = devGlobalsSource(devHostDir());
check("every listed global is exported", GLOBALS.flatMap((entry) => entry.values).every((name) => globals.names.includes(name)),
  GLOBALS.flatMap((entry) => entry.values).filter((name) => !globals.names.includes(name)).slice(0, 4).join(", "));
check("a class listed among the types is exported too", ["Window", "NodeList", "XMLHttpRequest"].every((name) => globals.names.includes(name)),
  ["Window", "NodeList", "XMLHttpRequest"].filter((name) => !globals.names.includes(name)).join(", "));
check("a class no global names is exported for its table", globals.names.includes("DOMTokenList"));
check("no type-only name is exported", !["ValidityStateFlags", "DocumentEventMap", "EventInit", "WindowEventMap"].some((name) => globals.names.includes(name)),
  ["ValidityStateFlags", "DocumentEventMap", "EventInit", "WindowEventMap"].filter((name) => globals.names.includes(name)).join(", "));
check("the globals module binds values as local consts", globals.source.includes("export const document ="),
  "document is missing");
check("the globals module exports the handler attach", globals.source.includes("attachHandler"));

// ---------------------------------------------------------------------------
// Every platform the release pipeline builds has a package name, and no other does

check("darwin arm64 and x64 name a package",
  prebuiltPackageName("darwin", "arm64", null) === "@native-sdk/dev-host-darwin-arm64" &&
  prebuiltPackageName("darwin", "x64", null) === "@native-sdk/dev-host-darwin-x64");
check("linux arm64 and x64 on glibc name a package",
  prebuiltPackageName("linux", "arm64", "glibc") === "@native-sdk/dev-host-linux-arm64" &&
  prebuiltPackageName("linux", "x64", "glibc") === "@native-sdk/dev-host-linux-x64");
check("win32 x64 names a package", prebuiltPackageName("win32", "x64", null) === "@native-sdk/dev-host-win32-x64");
check("a musl Linux and an unknown platform ship none",
  prebuiltPackageName("linux", "x64", "musl") === null && prebuiltPackageName("freebsd", "x64", null) === null);

// ---------------------------------------------------------------------------
// A shipped prebuilt host answers only for the SDK it was built from

if (libnodePack() === null) {
  console.log("ok   (skipped) the prebuilt host lookup: no libnode pack for this platform");
} else {
  const prebuiltDir = mkdtempSync(join(process.env["TMPDIR"] ?? "/tmp", "native-dev-host-package-"));
  const prebuiltName = prebuiltPackageName() ?? "@native-sdk/dev-host-test";
  function prebuiltManifest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      schema: PREBUILT_SCHEMA,
      version: "0.0.0-test",
      sdk: devHostSourceDigest(ROOT),
      libnodeAbi: libnodeAbiIdentity(),
      devHostVersion: DEV_HOST_VERSION,
      platform: process.platform,
      arch: process.arch,
      libc: devHostLibc(),
      executable: "host",
      bytes: 1,
      ...overrides,
    };
  }
  function writePrebuilt(manifest: Record<string, unknown>): void {
    writeFileSync(join(prebuiltDir, "host"), "x");
    if (process.platform !== "win32") chmodSync(join(prebuiltDir, "host"), 0o755);
    writeFileSync(join(prebuiltDir, "host.json"), JSON.stringify(manifest));
  }
  writePrebuilt(prebuiltManifest());
  check("a matching prebuilt host is accepted", readPrebuiltHost(prebuiltDir, prebuiltName) !== null);
  writePrebuilt(prebuiltManifest({ sdk: "0".repeat(64) }));
  check("another SDK's prebuilt host is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest({ libnodeAbi: "0:0" }));
  check("another libnode ABI is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest({ devHostVersion: DEV_HOST_VERSION + 1 }));
  check("another host version is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest({ bytes: 2 }));
  check("a truncated executable is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest({ executable: "../host" }));
  check("a path outside the package is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest({ schema: "native.dev-host.v0" }));
  check("an older manifest schema is refused", readPrebuiltHost(prebuiltDir, prebuiltName) === null);
  writePrebuilt(prebuiltManifest());
  check("the accepted manifest names this SDK", readPrebuiltHost(prebuiltDir, prebuiltName)?.manifest.sdk === devHostSourceDigest(ROOT));
}

// ---------------------------------------------------------------------------
// Build once, share

const pack = libnodePack();
if (pack === null) {
  console.log("ok   (skipped) the host build: no libnode pack for this platform");
} else {
  const first = await ensureDevHost((message) => console.log(`  ${message}`), { prebuilt: false });
  check("the first call builds the host", first.built === true);
  check("the build answers the cache's own executable", first.executable.startsWith(devHostDir()));
  check("a build is not a prebuilt host", first.prebuilt === false);
  const started = performance.now();
  const second = await ensureDevHost((message) => console.log(`  ${message}`), { prebuilt: false });
  const ms = performance.now() - started;
  check("a second call reuses the build", second.built === false);
  check("a second call answers in under 50ms", ms < 50, `${ms.toFixed(1)}ms`);
  // The host holds no app code, so every app answers with the same executable.
  check("every app shares the host", second.executable === first.executable);
}

process.exit(failed === 0 ? 0 : 1);

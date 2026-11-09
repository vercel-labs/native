import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { test } from "node:test";
import { downloadVerified, extractVerified } from "../scripts/install_scriptc.mjs";
import { hostRelease, installedRelease, nativeManifestName, nativeTargetName, releaseConfiguration, scriptcVersion, stageContractTypes } from "../scripts/scriptc_toolchain.mjs";

test("host selection preserves desktop distributions and explicit libc", () => {
  for (const arch of ["x64", "arm64"]) {
    assert.equal(hostRelease({ platform: "darwin", arch }), `darwin-${arch}`);
    for (const libc of ["gnu", "musl"]) assert.equal(hostRelease({ platform: "linux", arch, libc }), `linux-${arch}-${libc}`);
  }
  assert.equal(hostRelease({ platform: "win32", arch: "arm64" }), "win32-x64-msvc");
  assert.equal(nativeTargetName("darwin-arm64"), "macos-arm64");
  assert.equal(nativeTargetName("darwin-x64"), "macos-x64");
  assert.equal(nativeTargetName("win32-x64-msvc"), "windows-x64-msvc");
  assert.equal(nativeTargetName("linux-arm64-musl"), "linux-arm64-musl");
  assert.equal(nativeManifestName("darwin-arm64"), "scriptc.json");
  assert.equal(nativeManifestName("win32-x64-msvc"), "scriptc.exe.json");
  assert.throws(() => hostRelease({ platform: "linux", arch: "x64", libc: "unknown" }));
  assert.throws(() => scriptcVersion({ nativeToolchain: { scriptc: "^0.2.7" } }));
});

test("partial downloads and integrity mismatches never leave an asset", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-integrity-"));
  try {
    const payload = Buffer.from("verified payload");
    const sha256 = createHash("sha256").update(payload).digest("hex");
    const asset = { url: "https://example.com/release.tar.gz", sha256, bytes: payload.length };
    const file = path.join(root, "asset");
    await downloadVerified(asset, file, { fetch: async () => new Response(payload) });
    assert.deepEqual(fs.readFileSync(file), payload);
    fs.unlinkSync(file);
    await assert.rejects(downloadVerified(asset, file, { fetch: async () => new Response("corrupt") }), /checksum or size/);
    assert.equal(fs.existsSync(file), false);
    const broken = new ReadableStream({ start(controller) { controller.enqueue(payload); controller.error(new Error("interrupted")); } });
    await assert.rejects(downloadVerified(asset, file, { fetch: async () => new Response(broken) }), /interrupted/);
    assert.equal(fs.existsSync(file), false);
    await assert.rejects(downloadVerified({ ...asset, url: "http://example.com/release" }, file), /HTTPS/);
    await assert.rejects(downloadVerified(asset, file, { fetch: async () => new Response(null, { status: 404 }) }), /HTTP 404/);
    assert.equal(fs.existsSync(file), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("transient fetch and HTTP failures retry within a bounded verified download", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-retry-"));
  try {
    const payload = Buffer.from("verified after transport recovery");
    const sha256 = createHash("sha256").update(payload).digest("hex");
    const asset = { url: "https://example.com/release.tar.gz", sha256, bytes: payload.length };
    for (const status of [408, 429, 500, 502, 503, 504, null]) {
      const file = path.join(root, "asset");
      let attempts = 0, cancelled = 0;
      const delays: number[] = [];
      const result = await downloadVerified(asset, file, {
        sleep: async (ms: number) => { delays.push(ms); },
        fetch: async (_url: string, { signal }: { signal: AbortSignal }) => {
          assert.ok(signal instanceof AbortSignal);
          if (++attempts < 3) {
            if (status === null) throw new TypeError("fetch failed", { cause: Object.assign(new Error("reset"), { code: "ECONNRESET" }) });
            return new Response(new ReadableStream({ cancel() { cancelled++; } }), { status });
          }
          return new Response(payload);
        },
      });
      assert.deepEqual(result, { bytes: payload.length, digest: sha256 });
      assert.equal(attempts, 3); assert.deepEqual(delays, [1000, 2000]);
      assert.equal(cancelled, status === null ? 0 : 2);
      assert.deepEqual(fs.readFileSync(file), payload); fs.unlinkSync(file);
    }
    let attempts = 0;
    const delays: number[] = [];
    await assert.rejects(downloadVerified(asset, path.join(root, "asset"), {
      sleep: async (ms: number) => { delays.push(ms); },
      fetch: async () => { attempts++; throw new TypeError("fetch failed"); },
    }), /fetch failed/);
    assert.equal(attempts, 4); assert.deepEqual(delays, [1000, 2000, 4000]);
    assert.equal(fs.existsSync(path.join(root, "asset")), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("slow transfers retain the complete asset budget while retries share the remaining time", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-budget-"));
  const originalNow = Date.now, originalTimeout = AbortSignal.timeout;
  try {
    const payload = Buffer.from("verified slow transfer");
    const asset = { url: "https://example.com/release.tar.gz", sha256: createHash("sha256").update(payload).digest("hex"), bytes: payload.length };
    const file = path.join(root, "asset");
    let now = 0, attempts = 0;
    const timeouts: number[] = [];
    Date.now = () => now;
    AbortSignal.timeout = ms => { timeouts.push(ms); return originalTimeout(ms); };
    await downloadVerified(asset, file, {
      sleep: async (ms: number) => { now += ms; },
      fetch: async () => {
        now += 45_000;
        if (++attempts === 1) throw Object.assign(new Error("temporary reset"), { code: "ECONNRESET" });
        return new Response(payload);
      },
    });
    assert.deepEqual(timeouts, [120_000, 74_000]);
    assert.equal(attempts, 2); assert.equal(now, 91_000);
    assert.deepEqual(fs.readFileSync(file), payload); fs.unlinkSync(file);
    now = 0; attempts = 0; timeouts.length = 0;
    await assert.rejects(downloadVerified(asset, file, {
      sleep: async () => { assert.fail("exhausted budget must stop before backoff"); },
      fetch: async () => { attempts++; now = 119_800; throw Object.assign(new Error("budget exhausted"), { code: "ECONNRESET" }); },
    }), /budget exhausted/);
    assert.equal(attempts, 1); assert.deepEqual(timeouts, [120_000]);
    assert.equal(fs.existsSync(file), false);
  } finally {
    Date.now = originalNow; AbortSignal.timeout = originalTimeout;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a failed response body is discarded before a fresh stream and hash are admitted", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-stream-retry-"));
  try {
    const payload = Buffer.from("fresh complete asset");
    const integrity = "sha512-" + createHash("sha512").update(payload).digest("base64");
    const asset = { url: "https://example.com/release.tar.gz", integrity, bytes: payload.length };
    const file = path.join(root, "asset");
    let attempts = 0, pulls = 0;
    const result = await downloadVerified(asset, file, {
      sleep: async () => { assert.equal(fs.existsSync(file), false); },
      fetch: async () => {
        if (++attempts === 2) return new Response(payload);
        return new Response(new ReadableStream({ pull(controller) {
          if (++pulls === 1) controller.enqueue(Buffer.from("superseded prefix"));
          else controller.error(Object.assign(new Error("body interrupted"), { code: "ECONNRESET" }));
        } }));
      },
    });
    assert.equal(attempts, 2); assert.equal(result.digest, integrity.slice(7));
    assert.equal(result.bytes, payload.length); assert.deepEqual(fs.readFileSync(file), payload);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("permanent errors and corrupt assets stop immediately and preserve unrelated output files", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-no-retry-"));
  try {
    const payload = Buffer.from("expected asset");
    const asset = { url: "https://example.com/release.tar.gz", sha256: createHash("sha256").update(payload).digest("hex"), bytes: payload.length };
    const file = path.join(root, "asset");
    for (const outcome of [400, 401, 403, 404, "certificate", "corrupt", "size", "exists"]) {
      let attempts = 0;
      if (outcome === "exists") fs.writeFileSync(file, "unrelated existing bytes");
      await assert.rejects(downloadVerified(outcome === "size" ? { ...asset, bytes: payload.length + 1 } : asset, file, {
        sleep: async () => { assert.fail("permanent failures must not retry"); },
        fetch: async () => {
          attempts++;
          if (typeof outcome === "number") return new Response(null, { status: outcome });
          if (outcome === "certificate") throw new TypeError("fetch failed", { cause: Object.assign(new Error("untrusted certificate"), { code: "CERT_HAS_EXPIRED" }) });
          return new Response(outcome === "corrupt" ? "corrupt" : payload);
        },
      }));
      assert.equal(attempts, 1);
      if (outcome === "exists") { assert.equal(fs.readFileSync(file, "utf8"), "unrelated existing bytes"); fs.unlinkSync(file); }
      else assert.equal(fs.existsSync(file), false);
    }
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

// Construct a real tar header so traversal and links reach the extractor,
// rather than being sanitized away by an archive-writing library first.
function tarMember(name: string, type = "0", payload = Buffer.from("contents")): Buffer {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100);
  header.write("0000644\0", 100);
  header.write("0000000\0", 108);
  header.write("0000000\0", 116);
  header.write(payload.length.toString(8).padStart(11, "0") + "\0", 124);
  header.write("00000000000\0", 136);
  header.fill(32, 148, 156);
  header.write(type, 156);
  if (type !== "0") header.write("../outside", 157);
  header.write("ustar\0", 257);
  header.write("00", 263);
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  header.write(checksum.toString(8).padStart(6, "0") + "\0 ", 148);
  return gzipSync(Buffer.concat([header, payload, Buffer.alloc((512 - payload.length % 512) % 512), Buffer.alloc(1024)]));
}

test("release extraction rejects traversal and link entries", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-extract-"));
  try {
    const archive = path.join(root, "test.tar.gz");
    for (const [name, type] of [["../outside", "0"], ["/outside", "0"], ["C:/outside", "0"], ["safe/link", "2"], ["safe/link", "1"]]) {
      fs.writeFileSync(archive, tarMember(name, type));
      await assert.rejects(extractVerified(archive, path.join(root, "out")), /unsafe|unsupported/);
    }
    fs.writeFileSync(archive, tarMember("./lib/runtime-test/package.json"));
    await extractVerified(archive, path.join(root, "valid"), { prefix: "lib/runtime-test", strip: 3 });
    assert.equal(fs.readFileSync(path.join(root, "valid", "package.json"), "utf8"), "contents");
    assert.equal(fs.existsSync(path.join(root, "outside")), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("an installation receipt cannot admit a different pin or partial cache", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-cache-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ nativeToolchain: { scriptc: "0.2.7" } }));
    const manifestPath = path.join(root, "scripts", "scriptc-toolchain.json");
    fs.writeFileSync(manifestPath, JSON.stringify({ schemaVersion: 1, version: "0.2.7", releases: { "linux-x64-gnu": {} } }));
    const options = { platform: "linux", arch: "x64", libc: "gnu", env: { NATIVE_SDK_SCRIPTC_CACHE: path.join(root, "cache") } };
    const origin = path.join(root, "package.json");
    const config = releaseConfiguration(origin, options)!;
    fs.mkdirSync(config.root, { recursive: true });
    fs.writeFileSync(path.join(config.root, "installed.json"), JSON.stringify({ manifestSha256: config.identity, host: config.host, version: "0.2.7", complete: false }));
    assert.throws(() => installedRelease(origin, options), /incomplete/);
    fs.writeFileSync(manifestPath, JSON.stringify({ schemaVersion: 1, version: "0.2.6" }));
    assert.throws(() => installedRelease(origin, options), /disagrees/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("a completed receipt still requires the compiler and every target pack", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-inventory-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ nativeToolchain: { scriptc: "0.2.7" } }));
    fs.writeFileSync(path.join(root, "scripts", "scriptc-toolchain.json"), JSON.stringify({ schemaVersion: 1, version: "0.2.7", runtimeAbi: 8, releases: { "linux-x64-gnu": {}, "win32-x64-msvc": {} }, packages: {} }));
    const options = { platform: "linux", arch: "x64", libc: "gnu", env: { NATIVE_SDK_SCRIPTC_CACHE: path.join(root, "cache") } };
    const origin = path.join(root, "package.json");
    const config = releaseConfiguration(origin, options)!;
    fs.mkdirSync(config.root, { recursive: true });
    const receipt = { manifestSha256: config.identity, host: config.host, version: "0.2.7", complete: true, runtimeAbi: 8, runtimePacks: ["runtime-linux-x64-gnu"] };
    const receiptPath = path.join(config.root, "installed.json");
    fs.writeFileSync(receiptPath, JSON.stringify(receipt));
    assert.throws(() => installedRelease(origin, options), /incomplete runtime pack inventory/);
    receipt.runtimePacks.push("runtime-win32-x64-msvc");
    fs.writeFileSync(receiptPath, JSON.stringify(receipt));
    // A receipt alone cannot turn a failed installation into a usable one.
    assert.throws(() => installedRelease(origin, options));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("completed installations reject mixed runtime ABIs and missing contract or thread modules", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-matching-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ nativeToolchain: { scriptc: "0.3.2" } }));
    fs.writeFileSync(path.join(root, "scripts", "scriptc-toolchain.json"), JSON.stringify({
      schemaVersion: 1, version: "0.3.2", runtimeAbi: 20,
      releases: { "linux-x64-gnu": {} },
      packages: {
        compiler: { name: "@scriptc/compiler", version: "0.3.2" },
        types: { name: "@scriptc/types", version: "0.3.2" },
        threads: { name: "@scriptc/threads", version: "0.3.2" },
        typescript5: { name: "typescript", version: "5.9.3" },
      },
    }));
    const origin = path.join(root, "package.json");
    const options = { platform: "linux", arch: "x64", libc: "gnu", env: { NATIVE_SDK_SCRIPTC_CACHE: path.join(root, "cache") } };
    const config = releaseConfiguration(origin, options)!;
    const put = (name: string, value: unknown = {}) => {
      const file = path.join(config.root, name);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, JSON.stringify(value));
      return file;
    };
    put("installed.json", { manifestSha256: config.identity, host: config.host, version: "0.3.2", complete: true, runtimeAbi: 20, runtimePacks: ["runtime-linux-x64-gnu"] });
    for (const [key, name, version] of [["compiler", "@scriptc/compiler", "0.3.2"], ["types", "@scriptc/types", "0.3.2"], ["threads", "@scriptc/threads", "0.3.2"], ["typescript5", "typescript", "5.9.3"]]) {
      put(`api/node_modules/${name.startsWith("@scriptc/") ? name : key}/package.json`, { name, version });
    }
    for (const file of ["release/bin/scriptc.json", "release/bin/scriptc", "api/node_modules/@scriptc/compiler/dist/index.js", "api/node_modules/@scriptc/compiler/surface-manifest.json", "api/node_modules/typescript/package.json", "api/node_modules/@scriptc/types/index.d.ts", "api/node_modules/@scriptc/threads/index.d.ts", "api/node_modules/@scriptc/threads/index.js"]) put(file);
    const pack = put("api/node_modules/@scriptc/runtime-linux-x64-gnu/runtime-pack.json", { version: "0.3.2", runtime_abi: { version: 20 } });
    assert.equal(installedRelease(origin, options)!.root, config.root);
    const declarations = path.join(config.root, "api/node_modules/@scriptc/types/index.d.ts");
    fs.writeFileSync(declarations, "export type Int32 = number;\n");
    const stage = path.join(root, "isolated-stage");
    stageContractTypes(stage, origin, options);
    assert.equal(fs.readFileSync(path.join(stage, "node_modules/@scriptc/types/index.d.ts"), "utf8"), fs.readFileSync(declarations, "utf8"));
    assert.equal(JSON.parse(fs.readFileSync(path.join(stage, "node_modules/@scriptc/types/package.json"), "utf8")).version, "0.3.2");
    assert.deepEqual(fs.readdirSync(path.join(stage, "node_modules/@scriptc")), ["types"]);
    for (const incompatible of [{ version: "0.3.0", runtime_abi: { version: 14 } }, { version: "0.3.2", runtime_abi: { version: 14 } }, { version: "0.3.0", runtime_abi: { version: 20 } }]) {
      fs.writeFileSync(pack, JSON.stringify(incompatible));
      assert.throws(() => installedRelease(origin, options), /incompatible runtime pack/);
      assert.throws(() => stageContractTypes(path.join(root, "refused-stage"), origin, options), /incompatible runtime pack/);
      assert.equal(fs.existsSync(path.join(root, "refused-stage")), false);
    }
    fs.writeFileSync(pack, JSON.stringify({ version: "0.3.2", runtime_abi: { version: 20 } }));
    for (const name of ["types/index.d.ts", "threads/index.js"]) {
      const file = path.join(config.root, "api/node_modules/@scriptc", name);
      fs.unlinkSync(file);
      assert.throws(() => installedRelease(origin, options));
      put(`api/node_modules/@scriptc/${name}`);
    }
    put("api/node_modules/@scriptc/threads/package.json", { name: "@scriptc/threads", version: "0.2.9" });
    assert.throws(() => installedRelease(origin, options), /incorrect package identity: threads/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

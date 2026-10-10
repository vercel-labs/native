import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { test } from "node:test";
import { downloadVerified, extractVerified } from "../scripts/install_scriptc.mjs";
import { hostRelease, installedRelease, releaseConfiguration, scriptcVersion } from "../scripts/scriptc_toolchain.mjs";

test("host selection preserves desktop distributions and explicit libc", () => {
  for (const arch of ["x64", "arm64"]) {
    assert.equal(hostRelease({ platform: "darwin", arch }), `darwin-${arch}`);
    for (const libc of ["gnu", "musl"]) assert.equal(hostRelease({ platform: "linux", arch, libc }), `linux-${arch}-${libc}`);
  }
  assert.equal(hostRelease({ platform: "win32", arch: "arm64" }), "win32-x64-msvc");
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

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { emitProfile, type ProfileInput } from "./emit_profile.ts";

assert.ok(process.argv[2], "run with the compiled corewire path (zig build test-corewire-profile)");
const corewire = path.resolve(process.argv[2]);
const fixtures = new URL("../../tests/sidecar/", import.meta.url);
function fixture(name: string) {
  return JSON.parse(fs.readFileSync(new URL(`${name}_fixture.contract.json`, fixtures), "utf8"));
}
function withWork(run: (dir: string) => void) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-profile-test-"));
  try { run(dir); } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function currentContract(name: string) {
  const input = fixture(name);
  // The mirror fixtures predate facade metadata. Supply those independent
  // facts for CLI tests; they do not affect the profile projection.
  for (const table of [input.types.structs, input.types.enums, input.types.unions]) {
    for (const type of table) {
      if (!type.name.startsWith("Msg_") && !type.name.startsWith("TextInputEvent_")) type.origin ??= path.basename(input.entry);
    }
  }
  for (const arm of input.msg.arms) {
    if (["bytes", "number", "bool", "enum", "text_input"].includes(arm.payload.kind)) arm.member ??= "value";
  }
  for (const type of input.types.unions) {
    for (const arm of type.arms) {
      if (arm.payload.kind !== "void") arm.member ??= "value";
    }
  }
  return input;
}
function invoke(dir: string, input: ProfileInput, extra: string[] = []) {
  fs.writeFileSync(path.join(dir, "contract.json"), JSON.stringify(input));
  const result = spawnSync(corewire, ["--sidecar", "contract.json", ...extra], { cwd: dir, encoding: "utf8" });
  assert.ifError(result.error);
  assert.equal(result.signal, null, result.stderr);
  return result;
}

// Captured from the Zig emitter before its removal. These files pin export
// ordering, ABI signatures, integer classes, policy text, and JSON spelling.
for (const name of ["integer", "markup", "wide_msg"]) {
  test(`${name}: Node and the compiled generator match the original profile bytes`, () => withWork(dir => {
    const expected = fs.readFileSync(new URL(`profiles/${name}.json`, fixtures), "utf8");
    assert.equal(emitProfile(fixture(name), "core_facade.ts", "release").output, expected);
    const result = invoke(dir, currentContract(name), ["--profile", "profile.json", "--optimization", "release"]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(dir, "profile.json"), "utf8"), expected);
  }));
}

test("relative entries, Unicode, escaping, optimization, and empty integer slots agree", () => withWork(dir => {
  const input = currentContract("wide_msg");
  input.abi.prefix = "other_";
  input.has_subscriptions = true;
  input.types.structs[0].fields[0].type.kind = "f64";
  input.integer_slots = [];
  // Quotes/control characters are legal filenames on POSIX, not Windows.
  const entry = process.platform === "win32" ? "café-🧪.ts" : 'café-🧪-"-\t-\b-\f.ts';
  for (const optimization of ["", "dev", "release"]) {
    const extra = ["--profile", path.join(dir, "profile.json"), "--facade", path.join(dir, entry)];
    if (optimization) extra.push("--optimization", optimization);
    const result = invoke(dir, input, extra);
    assert.equal(result.status, 0, result.stderr);
    const output = fs.readFileSync(path.join(dir, "profile.json"), "utf8");
    assert.equal(output, emitProfile(input, entry, optimization).output);
    const profile = JSON.parse(output);
    assert.equal(profile.entry, entry);
    assert.equal(profile.optimization, optimization || undefined);
    assert.equal(profile.sidecar.subscriptions_export, "coreSubscriptions");
    assert.deepEqual(profile.sidecar.integer_slots, []);
    assert.equal(profile.abi.init_symbol, "other_init");
  }
}));

test("f64 projection reaches both the compiled profile and effective sidecar", () => withWork(dir => {
  const input = currentContract("integer");
  const result = invoke(dir, input, ["--profile", "profile.json", "--effective-sidecar", "effective.json", "--f64-slot", "Model.count"]);
  assert.equal(result.status, 0, result.stderr);
  const effective = JSON.parse(fs.readFileSync(path.join(dir, "effective.json"), "utf8"));
  const output = fs.readFileSync(path.join(dir, "profile.json"), "utf8");
  assert.equal(output, emitProfile(effective, "core_facade.ts", "").output);
  assert.ok(!JSON.parse(output).sidecar.integer_slots.some((slot: { slot: string }) => slot.slot === "Model.count"));
}));

test("both attestation refusals preserve existing outputs and appear in check mode", () => withWork(dir => {
  const input = currentContract("wide_msg");
  input.deterministic = false;
  input.async_free = false;
  const expected = emitProfile(input, "core_facade.ts", "");
  assert.deepEqual(expected.diagnostics.map(d => d.path), ["deterministic", "async_free"]);
  assert.equal(expected.output, "");
  for (const file of ["profile.json", "core_facade.ts", "mirror.zig", "effective.json"]) fs.writeFileSync(path.join(dir, file), "keep");
  for (const extra of [
    ["--check"],
    ["--profile", "profile.json", "--facade", "core_facade.ts", "--out", "mirror.zig", "--effective-sidecar", "effective.json"],
  ]) {
    const result = invoke(dir, input, extra);
    assert.equal(result.status, 1, result.stderr);
    for (const diagnostic of expected.diagnostics) assert.ok(result.stderr.includes(diagnostic.message));
  }
  for (const file of ["profile.json", "core_facade.ts", "mirror.zig", "effective.json"]) assert.equal(fs.readFileSync(path.join(dir, file), "utf8"), "keep");
  assert.ok(!fs.readdirSync(dir).some(file => file.endsWith(".corewire-tmp")));
}));

test("policy text obeys compiler limits and conditional channel signatures are complete", () => {
  const input = fixture("wide_msg");
  input.abi.exports.push("command_msg", "frame_msg", "key_msg", "pinch_msg", "drop_msg");
  const profile = JSON.parse(emitProfile(input, "core_facade.ts", "release").output);
  const channels = profile.exports.filter((entry: { export: string }) => entry.export.endsWith("_msg"));
  assert.deepEqual(channels.map((entry: { export: string; params: string[] }) => [entry.export, entry.params]), [
    ["abi_command_msg", ["bytes"]],
    ["abi_frame_msg", ["f64", "f64", "f64", "f64"]],
    ["abi_key_msg", ["bytes", "u8", "u8", "u8", "u8"]],
    ["abi_pinch_msg", ["f64", "bytes", "u32", "f64", "f64", "f64"]],
    ["abi_drop_msg", ["bytes"]],
  ]);
  const texts = [
    ...Object.values(profile.determinism.teachings), ...Object.values(profile.determinism.remediations),
    ...profile.determinism.fences.map((f: { teaching: string }) => f.teaching),
  ] as string[];
  assert.equal(profile.determinism.fences.length, 13);
  for (const text of texts) {
    assert.ok(Buffer.byteLength(text) <= 512);
    assert.doesNotMatch(text, /[\x00-\x09\x0b-\x1f]/);
  }
});

test("compiled profiles preserve the optional Native primary and window view signatures", () => withWork(dir => {
  const input = currentContract("wide_msg");
  input.abi.exports.push("native_view", "native_window_view", "native_radio_policy", "native_tabs_policy", "native_tree_policy", "native_list_policy", "native_menu_policy", "native_toggle_policy", "native_accordion_policy", "native_slider_policy", "native_split_policy");
  const result = invoke(dir, input, ["--profile", "profile.json", "--out", "mirror.zig"]);
  assert.equal(result.status, 0, result.stderr);
  const output = fs.readFileSync(path.join(dir, "profile.json"), "utf8");
  assert.equal(output, emitProfile(input, "core_facade.ts", "").output);
  const profile = JSON.parse(output);
  assert.deepEqual(profile.exports.at(-11), { export: "native_view", symbol: input.abi.prefix + "native_view", params: [], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-10), { export: "native_window_view", symbol: input.abi.prefix + "native_window_view", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-9), { export: "native_radio_policy", symbol: input.abi.prefix + "native_radio_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-8), { export: "native_tabs_policy", symbol: input.abi.prefix + "native_tabs_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-7), { export: "native_tree_policy", symbol: input.abi.prefix + "native_tree_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-6), { export: "native_list_policy", symbol: input.abi.prefix + "native_list_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-5), { export: "native_menu_policy", symbol: input.abi.prefix + "native_menu_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-4), { export: "native_toggle_policy", symbol: input.abi.prefix + "native_toggle_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-3), { export: "native_accordion_policy", symbol: input.abi.prefix + "native_accordion_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-2), { export: "native_slider_policy", symbol: input.abi.prefix + "native_slider_policy", params: ["bytes"], returns: "bytes" });
  assert.deepEqual(profile.exports.at(-1), { export: "native_split_policy", symbol: input.abi.prefix + "native_split_policy", params: ["bytes"], returns: "bytes" });
  const mirror = fs.readFileSync(path.join(dir, "mirror.zig"), "utf8");
  assert.match(mirror, /pub fn nativeSplitPolicy\(request:/);
  assert.match(mirror, /pub fn nativeSliderPolicy\(request:/);
  assert.match(mirror, /pub fn nativeAccordionPolicy\(request:/);
  assert.match(mirror, /pub fn nativeTogglePolicy\(request:/);
  assert.match(mirror, /pub fn nativeMenuPolicy\(request:/);
  assert.match(mirror, /pub fn nativeListPolicy\(request:/);
  assert.match(mirror, /pub fn nativeTreePolicy\(request:/);
  assert.match(mirror, /pub fn nativeTabsPolicy\(request:/);
  assert.match(mirror, /pub fn nativeRadioPolicy\(request:/);
  assert.match(mirror, /pub fn nativeView\(arena:/);
  assert.match(mirror, /pub fn nativeViewEvent\(envelope: \[\]const u8, arena: std.mem.Allocator\)/);
  assert.match(mirror, /pub fn nativeWindowView\(label: \[\]const u8, arena: std.mem.Allocator\)/);
  assert.match(mirror, /abi\.native_window_view\(label.ptr, label.len, &ptr, &len\)/);
  assert.ok(!mirror.includes('const nscfCommitted'));
}));

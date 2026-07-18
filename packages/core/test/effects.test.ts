// End-to-end effects gate: transpile a Cmd-bearing core, build it against
// the rt kernel, and drive the real dispatch cycle — update → commit →
// consume cmd bytes → frameReset — asserting the exact effect log the
// versioned Cmd wire format (rt.cmd_format_version) prescribes.
// Skipped when no zig toolchain is on PATH.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transpile } from "./helpers.ts";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

const core = `
import { Cmd } from "@native-sdk/core";

export interface Model { readonly count: number; readonly saved: number; }

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "save" }
  | { readonly kind: "stamp" }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "ship" }
  | { readonly kind: "open_player" }
  | { readonly kind: "open_cjk" }
  | { readonly kind: "quit" };

export function initialModel(): Model {
  return { count: 0, saved: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return { ...model, count: model.count + 1 };
    case "save": return [{ ...model, saved: model.count }, Cmd.persist()];
    case "stamp": return [model, Cmd.now("tick")];
    case "tick": return { ...model, count: msg.at };
    case "ship": return [model, Cmd.batch([Cmd.persist(), Cmd.host("beep", model.count, 2)])];
    case "open_player": return [model, Cmd.showWindow("player")];
    case "open_cjk": return [model, Cmd.showWindow("播放器")];
    case "quit": return [model, Cmd.quitApp()];
  }
}
`;

// Drives the emitted core exactly the way a host does: the cmd bytes are
// frame-arena resident, so each dispatch commits the model, copies the cmd
// bytes into the host-side effect log, and only then resets the frame.
const harness = `
const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;
var g_effects: [256]u8 = undefined;
var g_effects_len: usize = 0;

fn dispatch(msg: core.Msg) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    const start = g_effects_len;
    @memcpy(g_effects[start..][0..r.cmd.len], r.cmd);
    g_effects_len += r.cmd.len;
    rt.frameReset();
    return g_effects[start..g_effects_len];
}

test "cmd bytes flow through update -> commit -> effect log" {
    // v3 is additive: the v1/v2 op records asserted below are
    // byte-identical under the bumped version.
    try std.testing.expectEqual(@as(u32, 3), rt.cmd_format_version);

    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();

    // Bare model return: no effect bytes, model still commits.
    const add = dispatch(.add);
    try std.testing.expectEqual(@as(usize, 0), add.len);
    try std.testing.expectEqual(@as(f64, 1), g_model.count);

    // persist: [op 0x01]; the tuple's model slot commits too.
    const save = dispatch(.save);
    try std.testing.expectEqualSlices(u8, &.{0x01}, save);
    try std.testing.expectEqual(@as(f64, 1), g_model.saved);

    // now: [op 0x02][msg_tag], tag = declaration-order index of .tick.
    const stamp = dispatch(.stamp);
    const tick_tag: u8 = @intFromEnum(std.meta.Tag(core.Msg).tick);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, tick_tag }, stamp);

    // The requested timestamp comes back as a plain Msg.
    const tick = dispatch(.{ .tick = 42 });
    try std.testing.expectEqual(@as(usize, 0), tick.len);
    try std.testing.expectEqual(@as(f64, 42), g_model.count);

    // batch = concatenation: persist ++ host("beep", 42, 2).
    var expected: [24]u8 = undefined;
    expected[0] = 0x01;
    expected[1] = 0x03;
    expected[2] = 4;
    @memcpy(expected[3..7], "beep");
    expected[7] = 2;
    std.mem.writeInt(u64, expected[8..16], @bitCast(@as(f64, 42)), .little);
    std.mem.writeInt(u64, expected[16..24], @bitCast(@as(f64, 2)), .little);
    const ship = dispatch(.ship);
    try std.testing.expectEqualSlices(u8, &expected, ship);

    // window_show: [op 0x10][label_len][label] — the declared window
    // label, exactly the Zig tier's fx.showWindow address.
    const open_player = dispatch(.open_player);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 6, 'p', 'l', 'a', 'y', 'e', 'r' }, open_player);

    // A multibyte label's length prefix counts UTF-8 BYTES, not
    // characters: three CJK characters are nine bytes on the wire.
    const open_cjk = dispatch(.open_cjk);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 9 } ++ "\\xe6\\x92\\xad\\xe6\\x94\\xbe\\xe5\\x99\\xa8", open_cjk);

    // quit_app: [op 0x11], no payload.
    const quit = dispatch(.quit);
    try std.testing.expectEqualSlices(u8, &.{0x11}, quit);

    // The accumulated host-side log is every dispatch's bytes in order.
    try std.testing.expectEqual(@as(usize, 1 + 2 + 24 + 8 + 11 + 1), g_effects_len);
}
`;

test("effect log through the real dispatch cycle", { skip: !hasZig, timeout: 300_000 }, () => {
  const result = transpile(core);
  const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
  assert.equal(result.ok, true, `transpile failed\n${result.typeErrors.join("\n")}\n${details}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-effects-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    fs.writeFileSync(path.join(work, "core.zig"), result.zig!);
    fs.writeFileSync(path.join(work, "harness.zig"), harness);
    try {
      execFileSync("zig", ["test", "harness.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`effects harness failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

test("named ops: wire bytes through the real dispatch cycle", { skip: !hasZig, timeout: 300_000 }, () => {
  const result = transpile(coreNamedOps);
  const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
  assert.equal(result.ok, true, `transpile failed\n${result.typeErrors.join("\n")}\n${details}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-effects-named-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    fs.writeFileSync(path.join(work, "core.zig"), result.zig!);
    fs.writeFileSync(path.join(work, "harness.zig"), harnessNamedOps);
    try {
      execFileSync("zig", ["test", "harness.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`named-ops harness failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------- v2

// The v2 surface end to end: init command from initialModel's boot pair,
// bytes/record host payloads, keyed routed requests, cancel, and the
// declarative subscription channel — each asserted against the exact wire
// layout rt.zig documents, through the real dispatch cycle.
const coreV2 = `
import { Cmd, Sub, asciiBytes } from "@native-sdk/core";

export interface Model { readonly running: boolean; readonly data: Uint8Array; readonly errs: number; }

export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "save"; readonly gain: number }
  | { readonly kind: "reload" }
  | { readonly kind: "abort" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array }
  | { readonly kind: "tick"; readonly at: number };

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    { running: true, data: new Uint8Array(0), errs: 0 },
    Cmd.request("store.read", asciiBytes("boot.bin"), { key: "boot", ok: "loaded", err: "failed" }),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "toggle": return { ...model, running: !model.running };
    case "save": return [model, Cmd.host("cfg.save", { gain: msg.gain, on: model.running, tag: asciiBytes("v2") })];
    case "reload": return [model, Cmd.request("store.read", model.data, { key: "load", ok: "loaded", err: "failed" })];
    case "abort": return [model, Cmd.batch([Cmd.cancel("load"), Cmd.host("blob.put", asciiBytes("bye"))])];
    case "loaded": return { ...model, data: msg.body };
    case "failed": return { ...model, errs: model.errs + 1 };
    case "tick": return model;
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.running) return Sub.none;
  return Sub.timer("tick", 250, "tick");
}
`;

const harnessV2 = `
const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;

fn dispatch(msg: core.Msg, log: []u8) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(log[0..r.cmd.len], r.cmd);
    const out = log[0..r.cmd.len];
    rt.frameReset();
    return out;
}

fn expectRecord(bytes: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "v2 wire: init command, payloads, routing, cancel, subscriptions" {
    try std.testing.expectEqual(@as(u32, 3), rt.cmd_format_version);

    var log: [512]u8 = undefined;

    // Boot: initialModel returns the pair-result; the init command is a
    // keyed routed request per the documented request layout.
    rt.resetAll();
    const boot = core.initialModel();
    g_model = core.commitModelRoot(boot.model);
    var init_cmd: [512]u8 = undefined;
    @memcpy(init_cmd[0..boot.cmd.len], boot.cmd);
    const init_bytes = init_cmd[0..boot.cmd.len];
    rt.frameReset();
    const loaded_tag: u8 = @intFromEnum(std.meta.Tag(core.Msg).loaded);
    const failed_tag: u8 = @intFromEnum(std.meta.Tag(core.Msg).failed);
    var expect_init: std.ArrayList(u8) = .empty;
    defer expect_init.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try expect_init.append(a, 0x05); // request
    try expect_init.append(a, 10);
    try expect_init.appendSlice(a, "store.read");
    try expect_init.append(a, 4);
    try expect_init.appendSlice(a, "boot");
    try expect_init.append(a, loaded_tag);
    try expect_init.append(a, failed_tag);
    try expect_init.appendSlice(a, &.{ 8, 0, 0, 0 });
    try expect_init.appendSlice(a, "boot.bin");
    try expectRecord(init_bytes, expect_init.items);

    // The routed result comes back as an ordinary Msg (host builds the ok
    // arm with the result bytes); the model absorbs it with no effects.
    const done = dispatch(.{ .loaded = "hello" }, &log);
    try std.testing.expectEqual(@as(usize, 0), done.len);
    try std.testing.expectEqualSlices(u8, "hello", g_model.data);

    // host record payload: fields sorted by TS name (gain, on, tag) —
    // f64 LE, bool byte, u32-length-prefixed bytes.
    const save = dispatch(.{ .save = 1.5 }, &log);
    var expect_save: std.ArrayList(u8) = .empty;
    defer expect_save.deinit(a);
    try expect_save.append(a, 0x04); // host_bytes
    try expect_save.append(a, 8);
    try expect_save.appendSlice(a, "cfg.save");
    try expect_save.appendSlice(a, &.{ 15, 0, 0, 0 }); // 8 + 1 + 4 + 2
    var gain_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &gain_le, @bitCast(@as(f64, 1.5)), .little);
    try expect_save.appendSlice(a, &gain_le);
    try expect_save.append(a, 1); // on = running = true
    try expect_save.appendSlice(a, &.{ 2, 0, 0, 0 });
    try expect_save.appendSlice(a, "v2");
    try expectRecord(save, expect_save.items);

    // The error arm routes too, as a plain Msg.
    const failed = dispatch(.{ .failed = "nope" }, &log);
    try std.testing.expectEqual(@as(usize, 0), failed.len);
    try std.testing.expectEqual(@as(i64, 1), g_model.errs);

    // batch = concatenation: cancel then a bytes-payload host command.
    const abort = dispatch(.abort, &log);
    var expect_abort: std.ArrayList(u8) = .empty;
    defer expect_abort.deinit(a);
    try expect_abort.append(a, 0x06); // cancel
    try expect_abort.append(a, 4);
    try expect_abort.appendSlice(a, "load");
    try expect_abort.append(a, 0x04); // host_bytes
    try expect_abort.append(a, 8);
    try expect_abort.appendSlice(a, "blob.put");
    try expect_abort.appendSlice(a, &.{ 3, 0, 0, 0 });
    try expect_abort.appendSlice(a, "bye");
    try expectRecord(abort, expect_abort.items);

    // Subscriptions: descriptors derived from the committed model, timer
    // record per the documented layout; Sub.none is the empty slice.
    const tick_tag: u8 = @intFromEnum(std.meta.Tag(core.Msg).tick);
    const subs = core.subscriptions(g_model);
    var expect_subs: std.ArrayList(u8) = .empty;
    defer expect_subs.deinit(a);
    try expect_subs.append(a, 0x01); // timer
    try expect_subs.append(a, 4);
    try expect_subs.appendSlice(a, "tick");
    var every_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &every_le, @bitCast(@as(f64, 250)), .little);
    try expect_subs.appendSlice(a, &every_le);
    try expect_subs.append(a, tick_tag);
    try expectRecord(subs, expect_subs.items);
    rt.frameReset();

    _ = dispatch(.toggle, &log);
    const paused = core.subscriptions(g_model);
    try std.testing.expectEqual(@as(usize, 0), paused.len);
    rt.frameReset();
}
`;

// ------------------------------------------------------------- named ops

// The slice-C surface: named engine ops (readFile/writeFile/fetch/
// clipboardWrite/clipboardRead) and the one-shot delay, asserted against
// the exact additive wire records rt.zig documents.
const coreNamedOps = `
import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model { readonly code: number; readonly data: Uint8Array; readonly saved: boolean; readonly errs: number; readonly firedAt: number; }

export type Msg =
  | { readonly kind: "boot" }
  | { readonly kind: "save" }
  | { readonly kind: "get" }
  | { readonly kind: "share" }
  | { readonly kind: "paste" }
  | { readonly kind: "later" }
  | { readonly kind: "halt" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "wrote" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "fired"; readonly at: number }
  | { readonly kind: "failed"; readonly why: Uint8Array };

export function initialModel(): Model {
  return { code: -1, data: new Uint8Array(0), saved: false, errs: 0, firedAt: -1 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "boot": return [model, Cmd.readFile(asciiBytes("store.bin"), { key: "load", ok: "loaded", err: "failed" })];
    case "save": return [model, Cmd.writeFile(asciiBytes("store.bin"), model.data, { key: "save", ok: "wrote", err: "failed" })];
    case "get": return [model, Cmd.fetch({ url: asciiBytes("https://x.test/q"), method: "POST", headers: { "x-tag": "7", authorization: model.data, accept: "text/plain" }, body: model.data, timeoutMs: 5000 }, { key: "get", ok: "fetched", err: "failed" })];
    case "share": return [model, Cmd.clipboardWrite(model.data)];
    case "paste": return [model, Cmd.clipboardRead({ ok: "loaded", err: "failed" })];
    case "later": return [model, Cmd.delay("boom", 250, "fired")];
    case "halt": return [model, Cmd.cancel("boom")];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return { ...model, saved: true };
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return { ...model, firedAt: msg.at };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`;

const harnessNamedOps = `
const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;

fn dispatch(msg: core.Msg, log: []u8) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    @memcpy(log[0..r.cmd.len], r.cmd);
    const out = log[0..r.cmd.len];
    rt.frameReset();
    return out;
}

fn appendRoutedHead(list: *std.ArrayList(u8), a: std.mem.Allocator, op: u8, key: []const u8, ok: u8, err: u8) !void {
    try list.append(a, op);
    try list.append(a, @intCast(key.len));
    try list.appendSlice(a, key);
    try list.append(a, ok);
    try list.append(a, err);
}

fn appendLong(list: *std.ArrayList(u8), a: std.mem.Allocator, bytes: []const u8) !void {
    var len_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_le, @intCast(bytes.len), .little);
    try list.appendSlice(a, &len_le);
    try list.appendSlice(a, bytes);
}

test "named-op wire records match the documented additive layout" {
    try std.testing.expectEqual(@as(u32, 3), rt.cmd_format_version);
    const a = std.testing.allocator;
    var log: [512]u8 = undefined;

    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();

    const loaded: u8 = @intFromEnum(std.meta.Tag(core.Msg).loaded);
    const wrote: u8 = @intFromEnum(std.meta.Tag(core.Msg).wrote);
    const fetched: u8 = @intFromEnum(std.meta.Tag(core.Msg).fetched);
    const fired: u8 = @intFromEnum(std.meta.Tag(core.Msg).fired);
    const failed: u8 = @intFromEnum(std.meta.Tag(core.Msg).failed);

    // read_file [0x07][key][ok][err][path u32-len].
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(a);
    try appendRoutedHead(&expect, a, 0x07, "load", loaded, failed);
    try appendLong(&expect, a, "store.bin");
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.boot, &log));

    // Absorb bytes so save/get carry a real payload.
    _ = dispatch(.{ .loaded = "abc" }, &log);

    // write_file [0x08][key][ok][err][path u32-len][bytes u32-len].
    expect.clearRetainingCapacity();
    try appendRoutedHead(&expect, a, 0x08, "save", wrote, failed);
    try appendLong(&expect, a, "store.bin");
    try appendLong(&expect, a, "abc");
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.save, &log));

    // The payload-less ok arm flows back as a plain void Msg.
    _ = dispatch(.wrote, &log);
    try std.testing.expect(g_model.saved);

    // fetch [0x09][key][ok][err][method][timeout u32][url u32-len]
    //       [count]([name u8-len][value u32-len])*[body u32-len] —
    //       headers in TS-field-name sort order (accept < authorization
    //       < x-tag). The authorization VALUE is runtime bytes
    //       (model.data, "abc" here): it rides the same length-prefixed
    //       value field a literal does — no layout change.
    expect.clearRetainingCapacity();
    try appendRoutedHead(&expect, a, 0x09, "get", fetched, failed);
    try expect.append(a, 1); // POST
    try expect.appendSlice(a, &.{ 0x88, 0x13, 0, 0 }); // 5000 LE
    try appendLong(&expect, a, "https://x.test/q");
    try expect.append(a, 3);
    try expect.append(a, 6);
    try expect.appendSlice(a, "accept");
    try appendLong(&expect, a, "text/plain");
    try expect.append(a, 13);
    try expect.appendSlice(a, "authorization");
    try appendLong(&expect, a, "abc");
    try expect.append(a, 5);
    try expect.appendSlice(a, "x-tag");
    try appendLong(&expect, a, "7");
    try appendLong(&expect, a, "abc");
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.get, &log));

    // The two-field ok record: number field takes the status, bytes
    // field the body.
    _ = dispatch(.{ .fetched = .{ .status = 404, .body = "nope" } }, &log);
    try std.testing.expectEqual(@as(f64, 404), g_model.code);
    try std.testing.expectEqualSlices(u8, "nope", g_model.data);

    // clip_write [0x0A][bytes u32-len].
    expect.clearRetainingCapacity();
    try expect.append(a, 0x0A);
    try appendLong(&expect, a, "nope");
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.share, &log));

    // clip_read [0x0B][key(empty)][ok][err].
    expect.clearRetainingCapacity();
    try appendRoutedHead(&expect, a, 0x0B, "", loaded, failed);
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.paste, &log));

    // delay [0x0C][key][after_ms f64 LE][tag].
    expect.clearRetainingCapacity();
    try expect.append(a, 0x0C);
    try expect.append(a, 4);
    try expect.appendSlice(a, "boom");
    var ms_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &ms_le, @bitCast(@as(f64, 250)), .little);
    try expect.appendSlice(a, &ms_le);
    try expect.append(a, fired);
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.later, &log));

    // cancel reuses the existing 0x06 record unchanged.
    expect.clearRetainingCapacity();
    try expect.append(a, 0x06);
    try expect.append(a, 4);
    try expect.appendSlice(a, "boom");
    try std.testing.expectEqualSlices(u8, expect.items, dispatch(.halt, &log));

    // The delay arm is the same number-payload shape timers use.
    _ = dispatch(.{ .fired = 250 }, &log);
    try std.testing.expectEqual(@as(f64, 250), g_model.firedAt);
}
`;

test("v2 effects: wire bytes through the real dispatch cycle", { skip: !hasZig, timeout: 300_000 }, () => {
  const result = transpile(coreV2);
  const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
  assert.equal(result.ok, true, `transpile failed\n${result.typeErrors.join("\n")}\n${details}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-effects-v2-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    fs.writeFileSync(path.join(work, "core.zig"), result.zig!);
    fs.writeFileSync(path.join(work, "harness.zig"), harnessV2);
    try {
      execFileSync("zig", ["test", "harness.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`v2 effects harness failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------ streams

// The streaming ops end to end: spawn line/collect records (argv elements,
// stdin, the no-line sentinel) and the audio play/ctl records — each
// asserted against the exact wire layout rt.zig documents, through the real
// dispatch cycle.
const coreStreams = `
import { Cmd, asciiBytes } from "@native-sdk/core";

export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";

export interface Model { readonly lines: number; readonly out: Uint8Array; readonly code: number; readonly errs: number; readonly pos: number; }

export type Msg =
  | { readonly kind: "sample" }
  | { readonly kind: "copy" }
  | { readonly kind: "halt" }
  | { readonly kind: "play" }
  | { readonly kind: "stream" }
  | { readonly kind: "drive" }
  | { readonly kind: "line"; readonly text: Uint8Array }
  | { readonly kind: "done"; readonly code: number }
  | { readonly kind: "sampled"; readonly code: number; readonly output: Uint8Array }
  | { readonly kind: "audio_evt"; readonly state: AudioState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };

export function initialModel(): Model {
  return { lines: 0, out: new Uint8Array(0), code: -1, errs: 0, pos: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "sample": return [model, Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("-axo")], { key: "ps", line: "line", exit: "done", err: "failed" })];
    case "copy": return [model, Cmd.spawn([asciiBytes("/usr/bin/pbcopy")], { key: "copy", stdin: model.out, collect: true, exit: "sampled", err: "failed" })];
    case "halt": return [model, Cmd.cancel("ps")];
    case "play": return [model, Cmd.audioPlay("track", { path: asciiBytes("a.mp3") }, { event: "audio_evt" })];
    case "stream": return [model, Cmd.audioPlay("track", { url: asciiBytes("https://c.test/a.mp3"), cachePath: asciiBytes("cache/a"), expectedBytes: 4096 }, { event: "audio_evt" })];
    case "drive": return [model, Cmd.batch([Cmd.audioPause("track"), Cmd.audioSeek("track", 45000), Cmd.audioSetVolume("track", 0.25), Cmd.audioStop("track")])];
    case "line": return { ...model, lines: model.lines + 1, out: msg.text };
    case "done": return { ...model, code: msg.code };
    case "sampled": return { ...model, code: msg.code, out: msg.output };
    case "audio_evt": return { ...model, pos: msg.positionMs };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`;

const harnessStreams = `
const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;

fn dispatch(msg: core.Msg, log: *std.ArrayList(u8)) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    const start = log.items.len;
    log.appendSlice(std.testing.allocator, r.cmd) catch @panic("oom");
    rt.frameReset();
    return log.items[start..];
}

fn tagOf(comptime arm: []const u8) u8 {
    return @intFromEnum(@field(std.meta.Tag(core.Msg), arm));
}

fn expectLong(bytes: []const u8, at: *usize, expected: []const u8) !void {
    const len = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), len);
    try std.testing.expectEqualStrings(expected, bytes[at.* + 4 ..][0..expected.len]);
    at.* += 4 + expected.len;
}

test "spawn and audio wire records match rt.zig's documented layout" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);

    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();

    // spawn, line mode: [0x0D][key][line][exit][err][mode 0][argc]
    // [arg len u32 LE][arg]* [stdin len u32 LE][stdin].
    const sample = dispatch(.sample, &log);
    try std.testing.expectEqual(@as(u8, 0x0D), sample[0]);
    try std.testing.expectEqual(@as(u8, 2), sample[1]);
    try std.testing.expectEqualStrings("ps", sample[2..4]);
    try std.testing.expectEqual(tagOf("line"), sample[4]);
    try std.testing.expectEqual(tagOf("done"), sample[5]);
    try std.testing.expectEqual(tagOf("failed"), sample[6]);
    try std.testing.expectEqual(@as(u8, 0), sample[7]); // lines
    try std.testing.expectEqual(@as(u8, 2), sample[8]); // argc
    var at: usize = 9;
    try expectLong(sample, &at, "/bin/ps");
    try expectLong(sample, &at, "-axo");
    try expectLong(sample, &at, ""); // no stdin
    try std.testing.expectEqual(sample.len, at);

    // Feed the stream's arms as plain Msgs: lines repeat, the exit code
    // lands in the single-number arm.
    _ = dispatch(.{ .line = "cpu 40" }, &log);
    _ = dispatch(.{ .line = "cpu 7" }, &log);
    _ = dispatch(.{ .done = 0 }, &log);
    try std.testing.expectEqual(@as(@TypeOf(g_model.lines), 2), g_model.lines);
    try std.testing.expectEqual(@as(@TypeOf(g_model.code), 0), g_model.code);

    // spawn, collect mode: no line arm (0xFF sentinel), mode byte 1,
    // the model's bytes as stdin.
    const copy = dispatch(.copy, &log);
    try std.testing.expectEqual(@as(u8, 0x0D), copy[0]);
    try std.testing.expectEqual(@as(u8, 4), copy[1]);
    try std.testing.expectEqualStrings("copy", copy[2..6]);
    try std.testing.expectEqual(rt.spawn_no_line_tag, copy[6]);
    try std.testing.expectEqual(tagOf("sampled"), copy[7]);
    try std.testing.expectEqual(tagOf("failed"), copy[8]);
    try std.testing.expectEqual(@as(u8, 1), copy[9]); // collect
    try std.testing.expectEqual(@as(u8, 1), copy[10]); // argc
    at = 11;
    try expectLong(copy, &at, "/usr/bin/pbcopy");
    try expectLong(copy, &at, "cpu 7"); // stdin = model.out
    try std.testing.expectEqual(copy.len, at);

    // The collect exit record arm takes { code, output } by type.
    _ = dispatch(.{ .sampled = .{ .code = 1, .output = "PID CPU" } }, &log);
    try std.testing.expectEqual(@as(@TypeOf(g_model.code), 1), g_model.code);
    try std.testing.expectEqualStrings("PID CPU", g_model.out);

    // cancel rides the shared record: [0x06][key_len][key].
    const halt = dispatch(.halt, &log);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x06, 2, 'p', 's' }, halt);

    // audio_play, local path: [0x0E][key][event_tag][path][url][cache]
    // [expected f64 LE].
    const play = dispatch(.play, &log);
    try std.testing.expectEqual(@as(u8, 0x0E), play[0]);
    try std.testing.expectEqual(@as(u8, 5), play[1]);
    try std.testing.expectEqualStrings("track", play[2..7]);
    try std.testing.expectEqual(tagOf("audio_evt"), play[7]);
    at = 8;
    try expectLong(play, &at, "a.mp3");
    try expectLong(play, &at, "");
    try expectLong(play, &at, "");
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(std.mem.readInt(u64, play[at..][0..8], .little))));
    try std.testing.expectEqual(play.len, at + 8);

    // audio_play, streamed url with cache + expected size.
    const stream = dispatch(.stream, &log);
    at = 8;
    try expectLong(stream, &at, "");
    try expectLong(stream, &at, "https://c.test/a.mp3");
    try expectLong(stream, &at, "cache/a");
    try std.testing.expectEqual(@as(f64, 4096), @as(f64, @bitCast(std.mem.readInt(u64, stream[at..][0..8], .little))));

    // The event arm round-trips as a plain Msg (the six-field record).
    _ = dispatch(.{ .audio_evt = .{ .state = .position, .positionMs = 1500, .durationMs = 183000, .playing = true, .buffering = false, .bands = "" } }, &log);
    try std.testing.expectEqual(@as(@TypeOf(g_model.pos), 1500), g_model.pos);

    // audio_ctl batch: pause(0), seek(3, 45000), volume(4, 0.25),
    // stop(2) — verb bytes in declaration order, values f64 LE.
    const drive = dispatch(.drive, &log);
    const ctl_len = 2 + 5 + 1 + 8; // op + key + verb + value
    try std.testing.expectEqual(@as(usize, ctl_len * 4), drive.len);
    const verbs = [_]u8{ 0, 3, 4, 2 };
    const values = [_]f64{ 0, 45000, 0.25, 0 };
    for (verbs, values, 0..) |verb, value, i| {
        const record = drive[i * ctl_len ..][0..ctl_len];
        try std.testing.expectEqual(@as(u8, 0x0F), record[0]);
        try std.testing.expectEqual(@as(u8, 5), record[1]);
        try std.testing.expectEqualStrings("track", record[2..7]);
        try std.testing.expectEqual(verb, record[7]);
        try std.testing.expectEqual(value, @as(f64, @bitCast(std.mem.readInt(u64, record[8..16], .little))));
    }
}
`;

test("streaming ops: wire bytes through the real dispatch cycle", { skip: !hasZig, timeout: 300_000 }, () => {
  const result = transpile(coreStreams);
  const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
  assert.equal(result.ok, true, `transpile failed\n${result.typeErrors.join("\n")}\n${details}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-effects-streams-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    fs.writeFileSync(path.join(work, "core.zig"), result.zig!);
    fs.writeFileSync(path.join(work, "harness.zig"), harnessStreams);
    try {
      execFileSync("zig", ["test", "harness.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`streaming-ops harness failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------- images

// Cmd.imageLoad end to end: the numeric-id record against the exact wire
// layout rt.zig documents, the five-field result arm (the echoed id
// included) round-tripping as a plain Msg, the source variants (local
// path, url with cache), and the numeric-id image_cancel record.
const coreImages = `
import { Cmd, asciiBytes } from "@native-sdk/core";

export type ImageState =
  | "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed"
  | "tls_failed" | "protocol_failed" | "timed_out" | "http_status"
  | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full";

export interface Model { readonly cover: number; readonly w: number; readonly h: number; readonly errs: number; }

export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "load_url" }
  | { readonly kind: "drop" }
  | { readonly kind: "image_done"; readonly id: number; readonly state: ImageState; readonly width: number; readonly height: number; readonly status: number };

export function initialModel(): Model {
  return { cover: 0, w: 0, h: 0, errs: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.imageLoad(7, { path: asciiBytes("art/cover.png") }, { event: "image_done" })];
    case "load_url": return [model, Cmd.imageLoad(model.cover + 8, { url: asciiBytes("https://c.test/a.png"), cachePath: asciiBytes("cache/a.png"), expectedBytes: 2048 }, { event: "image_done" })];
    case "drop": return [model, Cmd.imageCancel(model.cover)];
    case "image_done":
      if (msg.state === "loaded") return { ...model, cover: msg.id, w: msg.width, h: msg.height };
      return { ...model, errs: model.errs + 1 };
  }
}
`;

const harnessImages = `
const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

var g_model: *const core.Model = undefined;

fn dispatch(msg: core.Msg, log: *std.ArrayList(u8)) []const u8 {
    const r = core.update(g_model, msg);
    g_model = core.commitModelRoot(r.model);
    const start = log.items.len;
    log.appendSlice(std.testing.allocator, r.cmd) catch @panic("oom");
    rt.frameReset();
    return log.items[start..];
}

fn tagOf(comptime arm: []const u8) u8 {
    return @intFromEnum(@field(std.meta.Tag(core.Msg), arm));
}

fn expectLong(bytes: []const u8, at: *usize, expected: []const u8) !void {
    const len = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), len);
    try std.testing.expectEqualStrings(expected, bytes[at.* + 4 ..][0..expected.len]);
    at.* += 4 + expected.len;
}

test "image_load wire records match rt.zig's documented layout" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);

    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();

    // image_load, local path: [0x12][id f64 LE][event_tag][path][url]
    // [cache][expected f64 LE].
    const load = dispatch(.load, &log);
    try std.testing.expectEqual(@as(u8, 0x12), load[0]);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(std.mem.readInt(u64, load[1..9], .little))));
    try std.testing.expectEqual(tagOf("image_done"), load[9]);
    var at: usize = 10;
    try expectLong(load, &at, "art/cover.png");
    try expectLong(load, &at, "");
    try expectLong(load, &at, "");
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(std.mem.readInt(u64, load[at..][0..8], .little))));
    try std.testing.expectEqual(load.len, at + 8);

    // The result arm round-trips as a plain Msg (the five-field record,
    // state matched by member name; the echoed id is what the model
    // adopts on "loaded").
    _ = dispatch(.{ .image_done = .{ .id = 7, .state = .loaded, .width = 640, .height = 480, .status = 200 } }, &log);
    try std.testing.expectEqual(@as(@TypeOf(g_model.w), 640), g_model.w);
    try std.testing.expectEqual(@as(@TypeOf(g_model.h), 480), g_model.h);
    try std.testing.expectEqual(@as(@TypeOf(g_model.cover), 7), g_model.cover);

    // image_load, url with cache + expected size; the id is a model
    // EXPRESSION (ids are model data) — 7 + 8 = 15 on the wire.
    const stream = dispatch(.load_url, &log);
    try std.testing.expectEqual(@as(u8, 0x12), stream[0]);
    try std.testing.expectEqual(@as(f64, 15), @as(f64, @bitCast(std.mem.readInt(u64, stream[1..9], .little))));
    at = 10;
    try expectLong(stream, &at, "");
    try expectLong(stream, &at, "https://c.test/a.png");
    try expectLong(stream, &at, "cache/a.png");
    try std.testing.expectEqual(@as(f64, 2048), @as(f64, @bitCast(std.mem.readInt(u64, stream[at..][0..8], .little))));

    // A failure class routes the same arm; the model counts it.
    _ = dispatch(.{ .image_done = .{ .id = 15, .state = .decode_failed, .width = 0, .height = 0, .status = 0 } }, &log);
    try std.testing.expectEqual(@as(@TypeOf(g_model.errs), 1), g_model.errs);

    // image_cancel: [0x13][id f64 LE] — the id is a model expression
    // (the adopted cover, 7).
    const drop = dispatch(.drop, &log);
    try std.testing.expectEqual(@as(u8, 0x13), drop[0]);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(std.mem.readInt(u64, drop[1..9], .little))));
    try std.testing.expectEqual(@as(usize, 9), drop.len);
}
`;

test("image loads: wire bytes through the real dispatch cycle", { skip: !hasZig, timeout: 300_000 }, () => {
  const result = transpile(coreImages);
  const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
  assert.equal(result.ok, true, `transpile failed\n${result.typeErrors.join("\n")}\n${details}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-effects-images-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    fs.writeFileSync(path.join(work, "core.zig"), result.zig!);
    fs.writeFileSync(path.join(work, "harness.zig"), harnessImages);
    try {
      execFileSync("zig", ["test", "harness.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`image-load harness failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

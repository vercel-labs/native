import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "@typescript/old";
import { NativeApp, type NativeWidget } from "../testing/index.ts";

const pkg = dirname(dirname(fileURLToPath(import.meta.url)));

test("the public native testing API typechecks with Node 24 types", () => {
  const program = ts.createProgram([join(pkg, "testing/index.ts")], {
    noEmit: true, strict: true, exactOptionalPropertyTypes: true,
    target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.NodeNext,
    types: ["node"], typeRoots: [join(pkg, "node_modules/@types")],
  });
  assert.deepEqual(ts.getPreEmitDiagnostics(program).map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")), []);
});

test("a host that never replies times out and is reaped", async () => {
  // Node with piped stdin waits for EOF. It cannot speak the test protocol.
  await assert.rejects(NativeApp.start({ executable: process.execPath, timeoutMs: 100 }), /timed out/);
});

test("missing executables report spawn failures without hanging", async () => {
  await assert.rejects(NativeApp.start({ executable: join(tmpdir(), "native-test-host-does-not-exist") }), /ENOENT/);
});

test("physical pointer input preserves exact identities, phase and modifier metadata", async () => {
  const root = mkdtempSync(join(tmpdir(), "native-pointer-host-"));
  const host = join(root, "host.mjs");
  writeFileSync(host, `#!${process.execPath}
import { createInterface } from 'node:readline';
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.op === 'close') {
    process.stdout.write(JSON.stringify({ protocol: 1, closed: true }) + '\\n');
    break;
  }
  process.stdout.write(JSON.stringify({ protocol: 1, snapshot: {
    fingerprint: 'request', widgets: [], model: request,
  } }) + '\\n');
}
`, { mode: 0o755 });
  const widget = { id: "18446744073709551615", view: "main", window: 7,
    bounds: { x: 10, y: 20, width: 80, height: 40 } } as NativeWidget;
  let app: NativeApp | undefined;
  try {
    app = await NativeApp.start({ executable: host });
    const point = { x: -2.5, y: 603.25 }, delta = { x: -4.25, y: 8.5 };
    for (const pointerId of ["0", "9007199254740993", "9223372036854775808", "18446744073709551615"]) {
      for (const phase of ["move", "down", "drag", "up", "cancel"] as const) {
        const snapshot = await app.pointer(widget, phase, point, delta, { pointerId, button: 1, shift: true });
        assert.deepEqual(snapshot.model, { op: "input", view: "main", window: 7,
          input: `pointer_${phase}`, x: point.x, y: point.y, delta_x: delta.x, delta_y: delta.y,
          shift: true, pointer_id: pointerId, button: 1 });
      }
      assert.deepEqual((await app.hover(widget, point, { pointerId })).model, {
        op: "input", view: "main", window: 7, input: "pointer_move", x: point.x, y: point.y,
        delta_x: 0, delta_y: 0, shift: false, pointer_id: pointerId, button: 0,
      });
      assert.deepEqual((await app.wheel(widget, -30, 4, { pointerId, button: 1, shift: true })).model, {
        op: "input", view: "main", window: 7, input: "scroll", x: 50, y: 40,
        delta_x: 4, delta_y: -30, pointer_id: pointerId, button: 1, shift: true,
      });
    }
    assert.equal((await app.pointer(widget, "down", point)).model.pointer_id, "0");
    assert.deepEqual((await app.wheel(widget, 9)).model, {
      op: "input", view: "main", window: 7, input: "scroll", x: 50, y: 40,
      delta_x: 0, delta_y: 9, pointer_id: "0", button: 0, shift: false,
    });
    for (const pointerId of ["", "-1", "+1", "1.0", "1e3", "1\n", " 1", "18446744073709551616"]) {
      assert.throws(() => app!.hover(widget, point, { pointerId }), /Invalid native identity/);
      assert.throws(() => app!.wheel(widget, 1, 0, { pointerId }), /Invalid native identity/);
    }
    assert.throws(() => app!.hover(widget, point, { button: 2 as 0 }), /pointer button/);
    assert.throws(() => app!.wheel(widget, 1, 0, { button: 2 as 0 }), /pointer button/);
    assert.throws(() => app!.hover(widget, { x: NaN, y: 0 }), /finite pointer/);
    assert.throws(() => app!.pointer(widget, "drag", point, { x: 0, y: Infinity }), /finite pointer/);
    assert.throws(() => app!.wheel(widget, Infinity), /finite wheel/);
    assert.throws(() => app!.wheel(widget, 0, NaN), /finite wheel/);
  } finally {
    await app?.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("installed-layout test discovery loads TS and propagates assertion failures", () => {
  const root = mkdtempSync(join(tmpdir(), "native-testing-"));
  try {
    const sdk = join(root, "node_modules/sdk/packages/core");
    const tests = join(root, "app/tests");
    mkdirSync(join(sdk, "scripts"), { recursive: true });
    mkdirSync(join(sdk, "node_modules/@typescript"), { recursive: true });
    mkdirSync(tests, { recursive: true });
    cpSync(join(pkg, "scripts/run_native_tests.mjs"), join(sdk, "scripts/run_native_tests.mjs"));
    cpSync(join(pkg, "testing"), join(sdk, "testing"), { recursive: true });
    symlinkSync(join(pkg, "node_modules/@typescript/old"), join(sdk, "node_modules/@typescript/old"), "junction");
    const entry = join(tests, "interaction.test.ts");
    const run = () => spawnSync(process.execPath, [
      join(pkg, "../../build/ts_run.mjs"), join(sdk, "scripts/run_native_tests.mjs"), "unused-host", tests,
    ], { encoding: "utf8", timeout: 10000 });
    writeFileSync(entry, `
import test from 'node:test';
import assert from 'node:assert/strict';
import { findWidget, type NativeSnapshot } from '@native-sdk/core/testing';
test('typed SDK import under node_modules', () => {
  const snapshot = { widgets: [] } as unknown as NativeSnapshot;
  assert.throws(() => findWidget(snapshot, { role: 'button', name: '+' }), /found 0/);
});
`);
    const pass = run();
    assert.equal(pass.status, 0, pass.stdout + pass.stderr);
    writeFileSync(entry, `import test from 'node:test'; import assert from 'node:assert/strict'; test('failure', () => assert.fail('expected test failure'));`);
    const fail = run();
    assert.equal(fail.status, 1, fail.stdout + fail.stderr);
    assert.match(fail.stdout + fail.stderr, /expected test failure/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

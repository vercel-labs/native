import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "@typescript/old";
import { NativeApp } from "../testing/index.ts";

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

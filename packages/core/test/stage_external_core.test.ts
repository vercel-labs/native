// The external-core stager, held to its contract on a CRLF checkout.
//
// The stager splits its inputs on "\n" and makes line-shaped decisions
// about them. On a Windows checkout (Git for Windows ships
// core.autocrlf=true) every one of those lines keeps a trailing CR, so a
// `$`-anchored terminator or an exact-equality compare quietly stops
// matching. That failure mode is not a crash: transform 4's `skipping`
// flag latches on at the first alias it means to drop and never clears,
// so the rest of the static @native-sdk/core restatement — Cmd and Sub
// among it — never reaches the stage. The app then fails its external
// compile with "Module './sdk/core.ts' has no exported member 'Cmd'",
// pointing at the SDK rather than at the stager that truncated it.
//
// These cases pin both halves: the staged surface survives past a dropped
// alias under either line ending, the dedupe those transforms exist for
// still happens, and CRLF staging agrees with LF staging line for line —
// the property that lets the compiled-core batteries keep pinning staged
// bytes against the transpiler lane.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const stager = path.join(pkg, "scripts", "stage_external_core.mjs");

// An author source carrying the folded Bytes alias transform 3 removes.
const AUTHOR_CORE = [
  'import { Cmd } from "@native-sdk/core";',
  'import { type AudioState } from "@native-sdk/core/events";',
  "export type Uint8Array = Uint8Array;",
  'export type AppMsg = { readonly kind: "tick" };',
  "export const boot = Cmd;",
].join("\n");

const SDK_EVENTS = ['export type AudioState = "loaded" | "failed";'].join("\n");
const SDK_TEXT = ['export type TextState = "ready";'].join("\n");

// The static restatement. AudioState is declared by the staged events
// module too, so transform 4 drops it here — and everything below it must
// still survive. It is spelled on ONE line, ending in `;`: that is the
// case a CRLF split misreads as an unterminated multi-line alias.
const STATIC_CORE = [
  "export type Msgish = { readonly kind: string };",
  'export type AudioState = "loaded" | "position" | "failed";',
  "export const Cmd = {",
  "  none: 0,",
  "};",
  "export type Sub = { readonly sub: string };",
].join("\n");

/** Stage a fixture whose every file uses `eol`, and return what landed. */
function stage(eol: string) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "stage-external-core-"));
  const write = (rel: string, body: string) => {
    const at = path.join(root, rel);
    fs.mkdirSync(path.dirname(at), { recursive: true });
    fs.writeFileSync(at, body.replaceAll("\n", eol));
    return at;
  };

  write("src/core.ts", AUTHOR_CORE);
  write("sdk/text.ts", SDK_TEXT);
  write("sdk/events.ts", SDK_EVENTS);
  const staticCore = write("static/core.ts", STATIC_CORE);
  const facade = write("gen/core_facade.ts", "export const facade = 1;\n");
  const profile = write("gen/profile.json", '{"entry":"core_facade.ts"}\n');
  const out = path.join(root, "stage");

  execFileSync(process.execPath, [
    stager,
    "--src", path.join(root, "src"),
    "--sdk", path.join(root, "sdk"),
    "--static", staticCore,
    "--facade", facade,
    "--profile", profile,
    "--out", out,
  ]);

  return {
    core: fs.readFileSync(path.join(out, "sdk", "core.ts"), "utf8"),
    author: fs.readFileSync(path.join(out, "core.ts"), "utf8"),
  };
}

for (const [label, eol] of [["LF", "\n"], ["CRLF", "\r\n"]] as const) {
  test(`${label}: the static surface survives past a deduped alias`, () => {
    const { core } = stage(eol);
    // The regression: everything below the dropped alias used to vanish.
    assert.match(core, /export const Cmd = \{/);
    assert.match(core, /export type Sub = /);
  });

  test(`${label}: transform 4 still drops the duplicated alias`, () => {
    const { core } = stage(eol);
    // events.ts owns AudioState; exactly one declaration site may survive.
    assert.ok(!/^export type AudioState =/m.test(core), "AudioState should be deduped out");
    assert.match(core, /export type Msgish = /);
  });

  test(`${label}: transform 3 still folds the Bytes alias away`, () => {
    const { author } = stage(eol);
    assert.ok(
      !/^export type Uint8Array = Uint8Array;\r?$/m.test(author),
      "the folded Uint8Array alias should be dropped",
    );
    assert.match(author, /export type AppMsg = /);
  });
}

test("CRLF staging agrees with LF staging line for line", () => {
  const lf = stage("\n");
  const crlf = stage("\r\n");
  const normalize = (s: string) => s.replaceAll("\r\n", "\n");
  assert.equal(normalize(crlf.core), normalize(lf.core));
  assert.equal(normalize(crlf.author), normalize(lf.author));
});

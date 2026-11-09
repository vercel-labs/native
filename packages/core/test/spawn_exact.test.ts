import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { Cmd, asciiBytes } from "../sdk/core.ts";
import { checkFile } from "../src/frontend.ts";
import { check } from "./helpers.ts";
import type { Msg } from "../../../tests/ts-core/spawn-exact/core.ts";

const fixture = new URL("../../../tests/ts-core/spawn-exact/core.ts", import.meta.url);
test("exact subprocess fixture admits complete independently routed line and exit arms", () => {
  const result = checkFile(fixture.pathname, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, result.typeErrors.join("\n") || result.diagnostics.map(d => d.message).join("\n"));
  const contract = JSON.parse(result.contract!);
  for (const name of ["first_line", "second_line", "first_exit", "second_exit"]) {
    const arm = contract.msg.arms.find((arm: { name: string }) => arm.name === name);
    const record = contract.types.structs.find((record: { name: string }) => record.name === arm.payload.name);
    assert.deepEqual(record.fields.map((f: { name: string }) => f.name), name.endsWith("line")
      ? ["key", "line", "truncated", "droppedBefore"]
      : ["key", "code", "reason", "droppedLines", "output", "outputTruncated", "stderrTail", "stderrTruncated"]);
  }
});
test("exact subprocess routes reject missing loss fields and narrowed exit vocabulary", () => {
  const source = fs.readFileSync(fixture, "utf8");
  for (const candidate of [
    source.replaceAll("readonly droppedBefore: number", "readonly droppedBefore: boolean"),
    source.replaceAll("readonly stderrTail: Uint8Array", "readonly stderrTail: number"),
    source.replaceAll("readonly key: Uint8Array", "readonly key: number"),
    source.replace(' | "spawn_failed"', ""),
  ]) {
    const result = check(candidate);
    assert.equal(result.ok, false);
    assert.ok(result.typeErrors.length > 0 || result.diagnostics.length > 0);
  }
});
test("exact subprocess factories preserve native identities and optional routes", () => {
  const key = asciiBytes("18446744073709551615"), stdin = new Uint8Array([0, 255, 10]);
  const argv = [asciiBytes("program"), asciiBytes("arg")];
  assert.deepEqual(Cmd.spawnEventsExact<Msg>(key, argv, { stdin, line: "first_line", exit: "second_exit" }), {
    op: "spawn_events_exact", key, argv, stdin, lineKind: "first_line", exitKind: "second_exit", collect: false,
  });
  assert.deepEqual(Cmd.spawnEventsExact<Msg>(key, [], { collect: true, line: "first_line", exit: "first_exit" }), {
    op: "spawn_events_exact", key, argv: [], stdin: new Uint8Array(0), lineKind: "", exitKind: "first_exit", collect: true,
  });
  assert.deepEqual(Cmd.cancelExact(key), { op: "cancel_exact", key });
});

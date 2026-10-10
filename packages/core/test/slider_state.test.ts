import test from "node:test";
import assert from "node:assert/strict";
import { check, checkFiles, ruleIds } from "./helpers.ts";

const source = `
import { Cmd } from "@native-sdk/core";
import type { SliderState } from "@native-sdk/core/events";
export interface Model { readonly fraction: number; }
export type SampleMsg = { readonly kind: "sample"; readonly fraction: number } | { readonly kind: "idle" };
export type Msg = { readonly kind: "sample"; readonly fraction: number } | { readonly kind: "idle" } | { readonly kind: "increment" };
export function initialModel(): Model { return { fraction: 0 }; }
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  return [msg.kind === "sample" ? { fraction: msg.fraction } : model, Cmd.none];
}
export function sliderStateMsg(model: Model, sliders: readonly SliderState[]): SampleMsg | null {
  const first = sliders[0];
  return first === undefined ? null : { kind: "sample", fraction: first.value };
}
`;

test("retained slider channel preserves exact identity and complete state-only dispatch shape", () => {
  const result = check(source, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, result.typeErrors.join("\n") || result.diagnostics.map(d => d.message).join("\n"));
  const contract = JSON.parse(result.contract!);
  const record = contract.types.structs.find((r: { name: string }) => r.name === "SliderState");
  assert.deepEqual(record.fields.map((f: { name: string }) => f.name), ["id", "label", "value"]);
  assert.ok(contract.model_unbound.includes("sliderStateMsg"));
});

test("slider channel rejects wrong records, whole Msg and mismatched subset payloads", () => {
  const inert = source.replace('  const first = sliders[0];\n  return first === undefined ? null : { kind: "sample", fraction: first.value };', '  return null;');
  for (const candidate of [
    inert.replace("sliders: readonly SliderState[]", "sliders: Uint8Array"),
    inert.replace("): SampleMsg | null", "): Msg | null"),
    inert.replace('export type SampleMsg = { readonly kind: "sample"; readonly fraction: number }', 'export type SampleMsg = { readonly kind: "increment"; readonly fraction: number }'),
  ]) assert.ok(ruleIds(check(candidate)).includes("NS1033"));
});

test("slider state entry wiring rejects imported declarations and re-exports", () => {
  const at = source.indexOf("export function sliderStateMsg");
  const entry = source.slice(0, at);
  const helper = `import type { Model, SampleMsg } from "./core.ts";
import type { SliderState } from "@native-sdk/core/events";
${source.slice(at)}`;
  for (const wiring of [
    'import { sliderStateMsg } from "./helper.ts";',
    'export { sliderStateMsg } from "./helper.ts";',
  ]) {
    const result = checkFiles({ "core.ts": entry + wiring, "helper.ts": helper }, { contractEntry: "src/core.ts" });
    assert.deepEqual(result.typeErrors, []);
    assert.equal(result.ok, false);
    assert.ok(ruleIds(result).includes("NS1014"));
  }
});

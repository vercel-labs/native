import test from "node:test";
import assert from "node:assert/strict";
import { check, ruleIds, withTempModule } from "./helpers.ts";
import { checkFile } from "../src/frontend.ts";

const source = `
import type { CanvasIconDefinition } from "@native-sdk/core/events";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "reset" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  return { count: msg.kind === "add" ? model.count + 1 : 0 };
}
export function canvasIcons(model: Model): readonly CanvasIconDefinition[] { return []; }
`;

test("canvas icon declarations retain the canonical vector records and boot binding", () => {
  const result = withTempModule(source, entry => checkFile(entry, { contractEntry: "src/core.ts" }));
  assert.equal(result.ok, true, result.diagnostics.map(d => d.message).join("\n"));
  const contract = JSON.parse(result.contract!);
  assert.ok(contract.model_unbound.includes("canvasIcons"));
  assert.ok(contract.model_helpers.some((h: { name: string }) => h.name === "canvasIcons"));
  const icon = contract.types.structs.find((r: { name: string }) => r.name === "CanvasIconDefinition");
  assert.deepEqual(icon.fields.map((f: { name: string }) => f.name), ["name", "viewBox", "elements", "shapes"]);
  const shape = contract.types.structs.find((r: { name: string }) => r.name === "CanvasIconShape");
  assert.deepEqual(shape.fields.map((f: { name: string }) => f.name), ["start", "count", "fill", "stroke", "strokeWidth", "linecap", "linejoin"]);
});

test("canvas icon hooks teach mismatched parameters and lookalike declarations", () => {
  for (const candidate of [
    source.replace("canvasIcons(model: Model)", "canvasIcons(model: Model, index: number)"),
    source.replace("canvasIcons(model: Model)", "canvasIcons(model: CanvasIconDefinition)"),
    source.replace("readonly CanvasIconDefinition[] { return []; }", "CanvasIconDefinition | null { return null; }"),
    source.replace('import type { CanvasIconDefinition } from "@native-sdk/core/events";', "export interface CanvasIconDefinition { readonly name: Uint8Array; }"),
  ]) assert.ok(ruleIds(check(candidate)).includes("NS1033"));
});

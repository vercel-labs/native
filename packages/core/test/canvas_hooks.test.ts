import test from "node:test";
import assert from "node:assert/strict";
import { check, checkOnly, ruleIds } from "./helpers.ts";

const source = `
import { asciiBytes } from "@native-sdk/core";
import type { CanvasChromeCommand, CanvasChromeContext, CanvasFrameEvent, CanvasAnimation, ThemeState } from "@native-sdk/core/events";
export interface Model { readonly count: number; }
export type Payload = { readonly value: Uint8Array };
export type Msg = { readonly kind: "observed"; readonly payload: Payload } | { readonly kind: "noop" };
export type FrameResult = { readonly kind: "observed"; readonly payload: Payload } | { readonly kind: "noop" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model { return model; }
export function canvasFrameMsg(model: Model, frame: CanvasFrameEvent): FrameResult | null {
  return { kind: "observed", payload: { value: frame.timestampNs } };
}
export function canvasChrome(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  return [{ kind: "rect", id: asciiBytes("18446744073709551615"), rect: { x: 0, y: 0, width: context.width, height: context.height }, fill: { kind: "color", color: context.background } }];
}
export function canvasAnimations(model: Model): readonly CanvasAnimation[] { return []; }
export function themeState(model: Model): ThemeState { return { highContrast: false, reduceMotion: true }; }
`;

test("canonical canvas hooks carry complete records with fractional numeric ABI and exact bytes", () => {
  const result = check(source, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, result.diagnostics.map(d => d.message).join("\n") || result.typeErrors.join("\n"));
  const contract = JSON.parse(result.contract!);
  assert.deepEqual(contract.model_helpers.map((h: { name: string }) => h.name), ["canvasFrameMsg", "canvasChrome", "canvasAnimations", "themeState"]);
  assert.deepEqual(contract.model_unbound.slice().sort(), ["canvasFrameMsg", "canvasChrome", "canvasAnimations", "themeState"].sort());
  for (const name of ["CanvasFrameEvent", "CanvasChromeContext", "CanvasColor", "CanvasRect", "CanvasAnimation", "CanvasTransform"]) {
    const record = contract.types.structs.find((r: { name: string }) => r.name === name);
    assert.ok(record, name);
    for (const field of record.fields) assert.notEqual(field.type.kind, "i64", `${name}.${field.name}`);
  }
  const frame = contract.types.structs.find((r: { name: string }) => r.name === "CanvasFrameEvent");
  assert.deepEqual(frame.fields.filter((f: { type: { kind: string } }) => f.type.kind === "bytes").map((f: { name: string }) => f.name), ["timestampNs", "intervalNs", "workUnits", "commands", "batches"]);
  assert.equal(new Set(contract.integer_slots.map((slot: { slot: string }) => slot.slot)).size, contract.integer_slots.length);
  const theme = contract.types.structs.find((r: { name: string }) => r.name === "ThemeState");
  for (const name of ["highContrast", "reduceMotion"]) assert.deepEqual(theme.fields.find((f: { name: string }) => f.name === name).type, { kind: "optional", inner: { kind: "bool" } });
});

test("canvas hook signatures refuse a full dispatch union, mismatched subset and competing frame channel", () => {
  for (const candidate of [
    source.replace("CanvasFrameEvent): FrameResult | null", "CanvasFrameEvent): Msg | null"),
    source.replace('export type FrameResult = { readonly kind: "observed"; readonly payload: Payload }', 'export type FrameResult = { readonly kind: "unknown"; readonly payload: Payload }').replace('return { kind: "observed", payload:', 'return { kind: "unknown", payload:'),
    source + '\nexport function frameMsg(model: Model, frame: { readonly width: number; readonly height: number; readonly timestampMs: number; readonly intervalMs: number }): Msg | null { return null; }',
    source.replace("CanvasChromeContext): readonly CanvasChromeCommand[]", "CanvasFrameEvent): readonly CanvasChromeCommand[]"),
  ]) assert.ok(ruleIds(checkOnly(candidate)).includes("NS1033"));
});

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { checkFile } from "../src/frontend.ts";
import { check, ruleIds } from "./helpers.ts";

const fixture = new URL("../../../tests/ts-core/boot-images/core.ts", import.meta.url);
const source = fs.readFileSync(fixture, "utf8");
test("boot image results retain the complete native capability and dedicated dispatch ABI", () => {
  const result = checkFile(fixture.pathname, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, result.typeErrors.join("\n") || result.diagnostics.map(d => d.message).join("\n"));
  const contract = JSON.parse(result.contract!);
  const record = contract.types.structs.find((r: { name: string }) => r.name === "BootImageResult");
  assert.deepEqual(record.fields.map((f: { name: string }) => f.name), ["id", "registered", "width", "height", "errorName"]);
  assert.ok(contract.model_unbound.includes("bootImageMsg"));
  assert.ok(contract.model_helpers.some((h: { name: string }) => h.name === "bootImageMsg"));
});
test("boot image hook teaches wrong model, missing fields, whole Msg and mismatched dispatch payloads", () => {
  const inert = source.replace('  if (result.id.length === 2 && result.id[0] === 52 && result.id[1] === 49) return null;\n  return { kind: "image", id: result.id, registered: result.registered, width: result.width, height: result.height, errorName: result.errorName };', '  return null;');
  for (const candidate of [
    inert.replace("bootImageMsg(model: Model", "bootImageMsg(model: BootImageResult"),
    inert.replace("result: BootImageResult): ImageMsg", "result: Uint8Array): ImageMsg"),
    inert.replace("): ImageMsg | null", "): Msg | null"),
    inert.replace('export type ImageMsg =\n  | { readonly kind: "image"; readonly id: Uint8Array', 'export type ImageMsg =\n  | { readonly kind: "image"; readonly id: number'),
  ]) assert.ok(ruleIds(check(candidate)).includes("NS1033"));
});
test("boot image hook cannot be renamed into app entry wiring", () => {
  const result = check(source.replace("export function bootImageMsg", "function imageHook").replace("export function reportCount", "export { imageHook as bootImageMsg };\nexport function reportCount"));
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some(d => d.message.includes("renamed export")));
});

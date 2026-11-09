import test from "node:test";
import assert from "node:assert/strict";
import { withTempModule } from "./helpers.ts";
import { ts, TypedAst, createSubsetProgram } from "../src/typed_ast.ts";
import { TypeTable } from "../src/types.ts";
import { IntInference } from "../src/infer.ts";

function returnKind(condition: string, fallback = "0", prelude = ""): string {
  return withTempModule(`
${prelude}
export interface Model { readonly value: number; }
export type Msg = { readonly kind: "keep" } | { readonly kind: "clear" };
export function initialModel(): Model { return { value: 0 }; }
export function update(model: Model, msg: Msg): Model { return model; }
export function bounded(model: Model, value: number): number {
  return ${condition} ? Math.trunc(value) : ${fallback};
}
`, entry => {
    const program = createSubsetProgram(entry);
    const file = program.getSourceFile(entry)!;
    const tast = new TypedAst(program), table = new TypeTable(tast, file);
    const inference = new IntInference(tast, table, file);
    const helper = file.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === "bounded")!;
    return inference.classOfDecl(helper)!;
  });
}

test("only a positive finite safe truncation branch supplies a whole source", () => {
  assert.equal(returnKind("value > 0 && value <= 4294967295"), "i64");
  assert.equal(returnKind("(value >= 1 && value < 128) && value === Math.trunc(value)"), "i64");
  for (const condition of [
    "value >= 0 && value < 128", // retains negative zero
    "value > 0", // infinity remains possible
    "value < 128", // negative infinity remains possible
    "value > 0 && value <= 9007199254740992", // not safely representable
    "value > 0 && value <= Infinity",
    "value > 0 || value < 128",
    "value > 0 && value < 128 && (++value > 0)",
    "value > 0 && value < 128 && mutate(value)",
  ]) {
    assert.equal(returnKind(condition, "0", "function mutate(value: number): boolean { return value > 0; }"), "f64", condition);
  }
  assert.equal(returnKind("value > 0 && value < 128", "0.5"), "f64");
  assert.equal(returnKind("value > 0 && value < 128", "-0"), "f64");
  assert.equal(returnKind("value > 0 && value < 128", "0", "const Math = { trunc: (value: number): number => value / 2 };"), "f64");
});

test("fround preserves fractional, nonfinite and negative-zero sources", () => {
  for (const value of ["model.value", "0.1", "-0", "Infinity", "NaN"]) {
    withTempModule(`
export interface Model { readonly value: number; }
export type Msg = { readonly kind: "keep" } | { readonly kind: "clear" };
export function initialModel(): Model { return { value: 0 }; }
export function update(model: Model, msg: Msg): Model { return model; }
export function rounded(model: Model): number { return Math.fround(${value}); }
`, entry => {
      const program = createSubsetProgram(entry);
      const file = program.getSourceFile(entry)!;
      const tast = new TypedAst(program), table = new TypeTable(tast, file);
      const inference = new IntInference(tast, table, file);
      const helper = file.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === "rounded")!;
      assert.equal(inference.classOfDecl(helper), "f64", value);
    });
  }
});

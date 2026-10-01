import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "@typescript/old";
import { compileView, type ViewContract } from "../src/view_frontend.ts";

const contract: ViewContract = {
  model: "Model", types: { structs: [{ name: "Model", fields: [
    { name: "count", type: { kind: "i64" } }, { name: "tickCount", type: { kind: "i64" } },
    { name: "stampedMs", type: { kind: "f64" } }, { name: "ticking", type: { kind: "bool" } },
    { name: "status", type: { kind: "bytes" } },
  ] }] },
  model_helpers: [{ name: "total", params: [], returns: { kind: "i64" } }],
  msg: { arms: ["load", "loaded", "failed", "increment", "decrement", "reset", "toggle_ticking", "stamp", "stamped", "tick"].map(name => ({ name, payload: { kind: ["loaded", "failed"].includes(name) ? "bytes" : ["stamped", "tick"].includes(name) ? "number" : "void" } })) },
};
const source = readFileSync(new URL("../../../tests/native-driver/src/app.native", import.meta.url), "utf8");
const evaluate = (markup: string) => {
  const generated = compileView(markup, contract);
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const model = { count: 7, tickCount: 3, ticking: true, stampedMs: -1 };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(js, { exports, TextEncoder, nscfCommitted: model, total: (m: typeof model) => m.count + m.tickCount });
  return { model, view: () => JSON.parse(new TextDecoder().decode(exports.native_view!())) };
};

test("the counter frontend typechecks", () => {
  const program = ts.createProgram([new URL("../src/view_frontend.ts", import.meta.url).pathname], {
    noEmit: true, strict: true, target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.NodeNext,
  });
  assert.deepEqual(ts.getPreEmitDiagnostics(program).map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")), []);
});

test("counter view reads the committed TypeScript model, helpers and canonical event tags", () => {
  const { model, view } = evaluate(source);
  const initial = view();
  assert.equal(initial.format, 1);
  assert.equal(initial.nodes.length, 14);
  assert.equal(initial.nodes[0].end, 14);
  assert.ok(initial.nodes.some((n: any) => n.text === "total: 10 | press Stamp for a timestamp"));
  assert.equal(initial.nodes.find((n: any) => n.text === "+").press, 3);
  assert.equal(initial.nodes.find((n: any) => n.kind === "switch_control").toggle, 6);
  assert.equal(initial.nodes.find((n: any) => n.kind === "switch_control").checked, true);
  model.count = -2; model.stampedMs = 12345; model.ticking = false;
  const changed = view();
  assert.ok(changed.nodes.some((n: any) => n.text === "total: 1 | stamped: 12345ms"));
  assert.equal(changed.nodes.find((n: any) => n.kind === "switch_control").checked, false);
  assert.deepEqual(changed.nodes.map((n: any) => [n.kind, n.end]), initial.nodes.map((n: any) => [n.kind, n.end]));
});

test("literal Unicode, entities, keyed nodes and conditional splicing survive view encoding", () => {
  const { model, view } = evaluate('<column><!-- comment --><if test="{count > 0}"><text key="label">café ☃ &amp; {count}</text><button on-press="reset">Reset</button></if><else><text>empty</text></else></column>');
  assert.equal(view().nodes[1].text, "café ☃ & 7");
  assert.equal(view().nodes[1].key, "label");
  assert.equal(view().nodes.length, 3);
  model.count = 0;
  assert.equal(view().nodes.length, 2);
  assert.equal(view().nodes[1].text, "empty");
});

test("unsupported or malformed markup fails with source location before compilation", () => {
  const cases = [
    ['<input/>', /unsupported element/], ['<text unknown="1"/>', /unsupported attribute/],
    ['<constructor/>', /unsupported element/],
    ['<text>{missing}</text>', /unsupported scalar binding/], ['<text>{status}</text>', /unsupported scalar binding/],
    ['<text>{count.constructor}</text>', /unsupported expression/], ['<text>{count; process.exit()}</text>', /unsupported expression/],
    ['<switch checked="{count}"/>', /expected boolean/], ['<button on-press="loaded"/>', /void Msg/],
    ['<text on-press="reset"/>', /unsupported on text/], ['<else/>', /unsupported element/],
    ['<column><else/></column>', /immediately follow if/], ['<text>unclosed', /unclosed/],
    ['<text></button>', /expected <\/text>/], ['<text/><text/>', /exactly one root/],
    ['<text key="a" key="b"/>', /duplicate attribute/], ['<text>{count</text>', /unbalanced/],
    ['<text>&broken;</text>', /unsupported entity/], ['<column>' + '<column>'.repeat(65), /64 levels/],
    ['<column main="space_around"/>', /unsupported main/], ['<text key="1"/>', /literal strings/],
    ['<text>{' + '('.repeat(129) + 'count' + ')'.repeat(129) + '}</text>', /128 tokens/],
  ] as const;
  for (const [markup, pattern] of cases) {
    assert.throws(() => compileView(markup, contract), error => error instanceof Error && /app.native:\d+:\d+/.test(error.message) && pattern.test(error.message), markup);
  }
});

test("compiled view wiring rejects authored name collisions", () => {
  const conflicting = { ...contract, model_helpers: [...contract.model_helpers, { name: "native_view", params: [], returns: { kind: "i64" } }] };
  assert.throws(() => compileView(source, conflicting), /collides with compiled view wiring/);
});

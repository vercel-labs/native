// A development compile records where every view node was authored: its
// file, UTF-8 byte span, line and byte column, and the <use> sites that
// placed it. The compiled view and the development evaluator report the
// same attribution.
import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import { compileViewProgram, type ViewContract, type ViewSource } from "../src/view_frontend.ts";
import { encodeViewProgram } from "../src/view_program.ts";
import { viewReloadFacade, viewReloadIdentity } from "../src/view_reload.ts";
import { wyhash } from "../src/wyhash.ts";
import * as textLibrary from "../sdk/text.ts";

const strip = (source: string) => stripTypeScriptTypes(source, { mode: "transform" })
  .replace(/^import \{([^}]*)\} from ("[^"]+");$/gm, (_all, names: string, spec: string) => `const {${names.replace(/ as /g, ": ")}} = require(${spec});`)
  .replace(/^export /gm, "");

const contract: ViewContract = {
  model: "Model",
  types: {
    structs: [
      { name: "Model", fields: [{ name: "title", type: { kind: "bytes" } }, { name: "items", type: { kind: "slice", elem: { kind: "node", name: "Item" } } }] },
      { name: "Item", fields: [{ name: "id", type: { kind: "i64" } }, { name: "label", type: { kind: "bytes" } }] },
    ],
  },
  model_helpers: [],
  msg: { arms: [{ name: "add", payload: { kind: "void" } }] },
};

const app = `<import src="components/card.native"/>
<column gap="4">
  <text>Café {title}</text>
  <use template="card" heading="Hé"><text>slotted</text></use>
  <for each="items" as="item" key="id"><text>{item.label}</text></for>
</column>
`;
const card = `<template name="card" args="heading">
  <row><text>{heading}</text><slot/></row>
</template>
`;
const sources = new Map([["app.native", app], ["components/card.native", card]]);

interface Records { nodes: { text?: string; textBytes?: number[]; kind?: string }[]; sources: number[]; sourceTable: ViewSource[]; sourceFiles: { path: string; hash: string }[] }
const textOf = (node: Records["nodes"][number]): string => node.textBytes ? Buffer.from(node.textBytes).toString() : node.text ?? "";

function views(): { compiled: () => Records; evaluated: () => Records } {
  const { text, program, virtual } = compileViewProgram(app, contract, { sources }, [], undefined, true);
  const identity = viewReloadIdentity(contract, { windows: [], virtual });
  const source = strip(text) + strip(viewReloadFacade(contract, identity)) +
    "\nglobalThis.native_view = native_view; globalThis.native_dev_view_prepare = native_dev_view_prepare;\n";
  const enc = (value: string) => new TextEncoder().encode(value);
  const context: Record<string, any> = {
    TextEncoder, TextDecoder, DataView, Uint8Array, Math, Number, String, Array, JSON, Error, Map,
    nscfCommitted: { title: enc("Draft"), items: [{ id: 7, label: enc("seven") }, { id: 9, label: enc("nine") }] },
    nscfPackMsg: (msg: unknown) => enc(JSON.stringify(msg)),
    require: () => textLibrary,
  };
  context.globalThis = context;
  runInNewContext(source, context);
  const read = (): Records => JSON.parse(new TextDecoder().decode(context.native_view()));
  return {
    compiled: read,
    evaluated: () => {
      assert.equal(new TextDecoder().decode(context.native_dev_view_prepare(encodeViewProgram(program, identity))), "");
      return read();
    },
  };
}

/** The UTF-8 site of the element starting at `marker` in `text`. */
function siteOf(text: string, marker: string, file: string, close: string) {
  const at = text.indexOf(marker); assert.ok(at >= 0, marker);
  const end = text.indexOf(close, at) + close.length;
  const lineStart = text.lastIndexOf("\n", at - 1) + 1;
  return {
    file, start: Buffer.byteLength(text.slice(0, at)), end: Buffer.byteLength(text.slice(0, end)),
    line: text.slice(0, at).split("\n").length, column: Buffer.byteLength(text.slice(lineStart, at)) + 1,
  };
}

const sourceOf = (records: Records, text: string): ViewSource => {
  const index = records.nodes.findIndex(node => textOf(node) === text);
  assert.ok(index >= 0, text);
  return records.sourceTable[records.sources[index]!]!;
};

for (const backend of ["compiled", "evaluated"] as const) test(`${backend} views attribute every node to its authored source`, () => {
  const records = views()[backend]();
  assert.equal(records.sources.length, records.nodes.length);
  // The files the view names, root first, hashed as the compiler read them.
  const hash = (text: string) => wyhash(0n, new TextEncoder().encode(text)).toString(16).padStart(16, "0");
  assert.deepEqual(records.sourceFiles, [{ path: "", hash: hash(app) }, { path: "components/card.native", hash: hash(card) }]);
  assert.ok(records.sources.every(index => index >= 0 && index < records.sourceTable.length));
  const use = siteOf(app, `<use template="card"`, "", "</use>");
  assert.deepEqual(records.sourceTable[records.sources[0]!], { ...siteOf(app, "<column", "", "</column>"), chain: [] });
  // UTF-8 offsets: "é" is two bytes, so later spans move by bytes, not characters.
  assert.deepEqual(sourceOf(records, "Café Draft"), { ...siteOf(app, "<text>Café", "", "</text>"), chain: [] });
  // A template node names its definition and the <use> that placed it.
  assert.deepEqual(sourceOf(records, "Hé"), { ...siteOf(card, "<text>{heading}", "components/card.native", "</text>"), chain: [use] });
  const row = records.nodes.findIndex(node => node.kind === "row");
  assert.deepEqual(records.sourceTable[records.sources[row]!], { ...siteOf(card, "<row>", "components/card.native", "</row>"), chain: [use] });
  // Slot content reports the consumer's site and chain.
  assert.deepEqual(sourceOf(records, "slotted"), { ...siteOf(app, "<text>slotted", "", "</text>"), chain: [] });
  // Every row of a loop names the loop body's element.
  const body = { ...siteOf(app, "<text>{item.label}", "", "</text>"), chain: [] };
  assert.deepEqual(sourceOf(records, "seven"), body);
  assert.deepEqual(sourceOf(records, "nine"), body);
});

test("the evaluator reports the attribution the compiled view reports", () => {
  const both = views();
  assert.deepEqual(both.evaluated(), both.compiled());
});

test("release compiles carry no attribution", () => {
  const { text } = compileViewProgram(app, contract, { sources }, []);
  assert.doesNotMatch(text, /nscvSource|sourceTable/);
});

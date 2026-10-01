import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "@typescript/old";
import { compileView, compileViewBundle, type ViewContract } from "../src/view_frontend.ts";
import { checkFile } from "../src/frontend.ts";

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
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model, total: (m: typeof model) => m.count + m.tickCount,
    nscfPackMsg: (msg: { kind: string }) => Uint8Array.of(1, contract.msg.arms.findIndex(arm => arm.name === msg.kind)) });
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
  assert.equal(initial.format, 2);
  assert.equal(initial.nodes.length, 14);
  assert.equal(initial.nodes[0].end, 14);
  assert.ok(initial.nodes.some((n: any) => n.text === "total: 10 | press Stamp for a timestamp"));
  assert.deepEqual(initial.nodes.find((n: any) => n.text === "+").press, [1, 3]);
  assert.deepEqual(initial.nodes.find((n: any) => n.kind === "switch_control").toggle, [1, 6]);
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
    ['<textarea/>', /unsupported element/], ['<text unknown="1"/>', /unsupported attribute/],
    ['<constructor/>', /unsupported element/],
    ['<text>{missing}</text>', /unknown binding/], ['<text>{count.constructor}</text>', /unsupported field/], ['<text>{count; process.exit()}</text>', /unsupported expression/],
    ['<switch checked="{count}"/>', /expected boolean/], ['<button on-press="loaded"/>', /scalar Msg payload/],
    ['<text on-press="reset"/>', /unsupported on text/], ['<else/>', /unsupported element/],
    ['<column><else/></column>', /immediately follow if/], ['<text>unclosed', /unclosed/],
    ['<text></button>', /expected <\/text>/], ['<text/><text/>', /exactly one root/],
    ['<text key="a" key="b"/>', /duplicate attribute/], ['<text>{count</text>', /unbalanced/],
    ['<text>&broken;</text>', /unsupported entity/], ['<column>' + '<column>'.repeat(65), /64 levels/],
    ['<column main="space_around"/>', /unsupported main/], ['<text key="{stampedMs}"/>', /integers or strings/],
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

const kanbanPath = new URL("../../../examples/kanban/src/core.ts", import.meta.url).pathname;
const checked = checkFile(kanbanPath, { contractEntry: "core_facade.ts" });
assert.equal(checked.ok, true, JSON.stringify(checked.diagnostics) + checked.typeErrors.join("\n"));
const kanbanContract: ViewContract = JSON.parse(checked.contract!);
const board = readFileSync(new URL("../../../examples/kanban/src/app.native", import.meta.url), "utf8");
const component = readFileSync(new URL("../../../examples/kanban/src/components/board-column.native", import.meta.url), "utf8");
const sources = new Map([["components/board-column.native", component]]);

test("the shipping Kanban view expands templates, record lists, bytes, enums and payload events", () => {
  const generated = compileView(board, kanbanContract, { sources });
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const card = { id: 42, title: new TextEncoder().encode("café ☃"), ticketNumber: 1841, assignee: "openai", avatarId: 1 };
  const model = { chromeLeading: 0, headerHeight: 44, todoScroll: 23, doingScroll: 0, doneScroll: 0 };
  const exports: { native_view?: () => Uint8Array } = {};
  const messages: unknown[] = [];
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model,
    todoCards: () => [card], doingCards: () => [], doneCards: () => [],
    nscfPackMsg: (msg: unknown) => { messages.push(msg); return Uint8Array.of(1, 1); } });
  const view = () => JSON.parse(new TextDecoder().decode(exports.native_view!()));
  const nodes = view().nodes;
  assert.equal(nodes.filter((n: any) => n.label === "Todo").length, 1);
  assert.equal(nodes.find((n: any) => n.kind === "scroll").value, 23);
  assert.equal(nodes.find((n: any) => n.role === "listitem").globalKeyInt, 42);
  assert.ok(nodes.some((n: any) => n.text === "café ☃"));
  assert.ok(nodes.some((n: any) => n.text === "NAT-1841"));
  assert.equal(nodes.find((n: any) => n.kind === "avatar").label, "OpenAI agent");
  assert.deepEqual(JSON.parse(JSON.stringify(messages[1])), { kind: "card_dropped", sourceId: 42, phase: 0, x: 0, y: 0, viewWidth: 0, viewHeight: 0 });
  card.assignee = "claude"; card.id = -7;
  assert.equal(view().nodes.find((n: any) => n.kind === "avatar").label, "Claude agent");
  card.id = Number.MAX_SAFE_INTEGER + 1;
  assert.throws(view, /exact integer/);
});

test("keyed iteration stamps every emitted sibling and respects explicit identities", () => {
  const generated = compileView('<column><for each="cards" as="c" key="id"><text>{c.title}</text><text>second</text><text key="own">third</text></for></column>', kanbanContract);
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const model = { cards: [{ id: 3, title: new TextEncoder().encode("three") }, { id: 1, title: new Uint8Array() }] };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  const nodes = JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes;
  assert.deepEqual(nodes.slice(1).map((n: any) => [n.keyInt ?? n.key, n.keySlot ?? 0]), [[3, 0], [3, 1], ["own", 0], [1, 0], [1, 1], ["own", 0]]);
});

test("imports, templates, loop paths and event shapes refuse ambiguous or unsafe input", () => {
  const cases = [
    ['<import src="../secret.native"/><text/>', /escapes/],
    ['<import src="missing.native"/><text/>', /missing imported/],
    ['<use template="missing"/>', /unknown template/],
    ['<slot/>', /slot requires/],
    ['<column><for each="nextId" as="c" key="id"><text/></for></column>', /list binding/],
    ['<column><for each="cards" as="c" key="constructor"><text/></for></column>', /unsupported field/],
    ['<row on-drag="add:{nextId}"/>', /six-field drag/],
    ['<scroll on-scroll="add"/>', /ScrollState/],
    ['<row on-drag="card_dropped:{nextId + 1}"/>', /unsupported binding path/],
    ['<for each="cards" as="c" key="id"><if test="{c.assignee == \'unknown\'}"><text/></if></for>', /invalid operands/],
  ] as const;
  for (const [markup, pattern] of cases) assert.throws(() => compileView(markup, kanbanContract), pattern);
  assert.throws(() => compileView('<import src="cycle.native"/><text/>', kanbanContract, { sources: new Map([["cycle.native", '<import src="app.native"/>']]) }), /cyclic/);
  assert.throws(() => compileView('<template name="cycle"><use template="cycle"/></template><use template="cycle"/>', kanbanContract), /recursive/);
  assert.throws(() => compileView(board, kanbanContract, { sources: new Map([["components/board-column.native", component.replace("{c.title}", "{c.missing}")]]) }), /components\/board-column.native:\d+:\d+.*unsupported field/);
});

test("scalar and byte event payloads bind the authored Msg member", () => {
  const payloadContract: ViewContract = { ...contract, msg: { arms: [
    { name: "loaded", member: "bytes", payload: { kind: "bytes" } },
    { name: "choose", member: "id", payload: { kind: "number", class: "i64" } },
  ] } };
  const generated = compileView('<column><button on-press="loaded:{status}"/><button on-press="choose:{count}"/></column>', payloadContract);
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const model = { count: 7, status: Uint8Array.of(0, 255, 128) };
  const exports: { native_view?: () => Uint8Array } = {}, messages: any[] = [];
  runInNewContext(js, { exports, TextEncoder, nscfCommitted: model, nscfPackMsg: (msg: any) => { messages.push(msg); return Uint8Array.of(1, 0); } });
  exports.native_view!();
  assert.equal(messages[0].kind, "loaded");
  assert.deepEqual(Array.from(messages[0].bytes), [0, 255, 128]);
  assert.equal(messages[1].kind, "choose");
  assert.equal(messages[1].id, 7);
  assert.throws(() => compileView('<button on-press="choose:{ticking}"/>', payloadContract), /matching scalar Msg payload/);
});

const feedContract: ViewContract = JSON.parse(checkFile(new URL("../../../examples/service-feed-reader/src/core.ts", import.meta.url).pathname, { contractEntry: "core_facade.ts" }).contract!);
const feedMarkup = readFileSync(new URL("../../../examples/service-feed-reader/src/app.native", import.meta.url), "utf8");

test("the complete feed view uses native input constructors and committed service records", () => {
  const generated = compileView(feedMarkup, feedContract);
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const bytes = (text: string) => new TextEncoder().encode(text);
  const model = { url: bytes("https://example.com/café"), items: [{ title: bytes("日本語"), link: bytes("https://example.com/1") }], feedTitle: bytes("Feed"), reason: bytes("failure"), phase: "ready" };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model, loading: () => model.phase === "loading", ready: () => model.phase === "ready", failed: () => model.phase === "failed", itemSummary: () => bytes("1 of 1 items"), nscfPackMsg: (msg: { kind: string }) => Uint8Array.of(1, feedContract.msg.arms.findIndex(arm => arm.name === msg.kind)) });
  const view = () => JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes;
  const input = view().find((node: any) => node.kind === "input");
  assert.equal(input.text, "https://example.com/café");
  assert.equal(input.input, feedContract.msg.arms.findIndex(arm => arm.name === "url_edit"));
  assert.deepEqual(input.submit, [1, feedContract.msg.arms.findIndex(arm => arm.name === "refresh")]);
  assert.ok(view().some((node: any) => node.text === "日本語" && node.wrap));
  assert.ok(view().some((node: any) => node.key === "https://example.com/1"));
  model.phase = "loading";
  assert.ok(view().some((node: any) => node.kind === "badge"));
  model.phase = "failed";
  assert.ok(view().some((node: any) => node.foreground === "destructive"));
});

test("text event bindings reject malformed unions and mismatched widgets at build time", () => {
  for (const markup of ['<input on-input="refresh"/>', '<input on-input="url_edit:{url}"/>', '<text on-input="url_edit"/>', '<panel wrap="true"/>', '<text placeholder="hint"/>', '<input size="heading"/>', '<input text="{url}">duplicate</input>']) {
    assert.throws(() => compileView(markup, feedContract), /app.native:\d+:\d+/);
  }
  const inputUnion = feedContract.types.unions!.find(item => item.name === "TextInputEvent")!;
  for (const arms of [inputUnion.arms!.slice(1), inputUnion.arms!.map(arm => arm.name === "insert_text" ? { ...arm, payload: { kind: "bool" } } : arm)]) {
    const broken = { ...feedContract, types: { ...feedContract.types, unions: [{ ...inputUnion, arms }] } };
    assert.throws(() => compileView('<input on-input="url_edit"/>', broken), /TextInputEvent/);
  }
});


test("window bundle shares helpers, routes exact labels, and preserves independent model views", () => {
  const sources = new Map([["components/value.native", '<template name="value"><text>{count}</text></template>']]);
  const window = { label: "café", entry: "feed.native", source: '<import src="components/value.native"/><column><use template="value"/><button on-press="increment">Bump</button></column>', sources };
  const generated = compileViewBundle('<text>{count}</text>', contract, {}, [window, { ...window, label: "other" }]);
  assert.equal(generated.match(/type NscViewNode/g)?.length, 1);
  assert.equal(generated.match(/function nscvInteger/g)?.length, 1);
  const exports: { native_view?: () => Uint8Array; native_window_view?: (label: Uint8Array) => Uint8Array } = {};
  const model = { count: 7 };
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }),
    { exports, TextEncoder, nscfCommitted: model, nscfPackMsg: () => Uint8Array.of(1, 3) });
  const view = (label: string) => JSON.parse(new TextDecoder().decode(exports.native_window_view!(new TextEncoder().encode(label))));
  const first = view("café");
  assert.equal(first.nodes[1].text, "7");
  assert.deepEqual(first.nodes[2].press, [1, 3]);
  model.count = 8;
  assert.equal(view("other").nodes[1].text, "8");
  assert.equal(JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes[0].text, "8");
  assert.equal(first.nodes[1].text, "7");
  for (const label of ["", "missing", "café\0", "caf"]) assert.throws(() => view(label), /unknown compiled window/);
  assert.throws(() => exports.native_window_view!(Uint8Array.of(0xff)), /unknown compiled window/);
  assert.throws(() => compileViewBundle('<text/>', contract, {}, [window, window]), /duplicate window label/);
  assert.throws(() => compileViewBundle('<text/>', contract, {}, [{ ...window, label: "../bad" }]), /invalid/);
  assert.throws(() => compileViewBundle('<text/>', contract, {}, [{ ...window, source: '<import src="../app.native"/><text/>' }]), /escapes/);
  assert.throws(() => compileViewBundle('<text/>', contract, {}, [{ ...window, source: '<unsupported/>' }]), /feed.native:1:1/);
});

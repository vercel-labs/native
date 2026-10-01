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

test("the view frontend and portable components typecheck", () => {
  const program = ts.createProgram(["view_frontend.ts", "view_components.ts"].map(name => new URL(`../src/${name}`, import.meta.url).pathname), {
    noEmit: true, strict: true, target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.NodeNext,
    types: ["node"], typeRoots: [new URL("../node_modules/@types", import.meta.url).pathname],
  });
  assert.deepEqual(ts.getPreEmitDiagnostics(program).map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")), []);
});

test("mixer sliders route applied float values separately from static change messages", () => {
  const file = new URL("../../../examples/slider-policy/src/core.ts", import.meta.url).pathname;
  const checked = checkFile(file, { contractEntry: "core_facade.ts" });
  assert.equal(checked.ok, true, JSON.stringify(checked.diagnostics) + checked.typeErrors.join("\n"));
  const mixerContract: ViewContract = JSON.parse(checked.contract!);
  const markup = readFileSync(new URL("../../../examples/slider-policy/src/app.native", import.meta.url), "utf8");
  const generated = compileView(markup, mixerContract);
  const exports: { native_view?: () => Uint8Array } = {};
  const model = { profile: 0, master: 0.35, preview: 0.5, locked: false, empty: false, changes: 0, trimChanges: 0, refreshes: 0 };
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: model,
    masterPercent: () => 35, previewPercent: () => 50, trimSourcePercent: () => 25,
    tracks: () => [{ id: 1, title: new TextEncoder().encode("Acoustic café"), value: 0.25, disabled: false }],
    nscfPackMsg: (msg: { kind: string }) => Uint8Array.of(1, mixerContract.msg.arms.findIndex(arm => arm.name === msg.kind)),
  });
  const nodes = JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes;
  const sliders = nodes.filter((node: { kind: string }) => node.kind === "slider");
  assert.equal(sliders.length, 3);
  assert.equal(sliders[0].valueChange, mixerContract.msg.arms.findIndex(arm => arm.name === "master_changed"));
  assert.equal(sliders[1].valueChange, mixerContract.msg.arms.findIndex(arm => arm.name === "preview_changed"));
  assert.deepEqual(sliders[2].change, [1, mixerContract.msg.arms.findIndex(arm => arm.name === "trim_changed")]);
  assert.equal(sliders[0].change, undefined); assert.equal(sliders[2].valueChange, undefined);
  assert.equal(sliders[2].label, "Acoustic café");
  const invalid: ViewContract = { ...mixerContract, msg: { ...mixerContract.msg, arms: [...mixerContract.msg.arms,
    { name: "integer_gain", member: "count", payload: { kind: "number", class: "i64" } }] } };
  for (const source of ['<slider on-change="integer_gain"/>', '<slider on-change="master_changed:{master}"/>',
    '<slider on-press="refresh"/>', '<slider on-toggle="refresh"/>', '<slider on-input="refresh"/>',
    '<slider placeholder="Level"/>', '<slider checked="true"/>', '<slider role="treeitem"/>', '<slider><text>Child</text></slider>']) {
    assert.throws(() => compileView(source, invalid), /compiled TypeScript view:/, source);
  }
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

const pipelinePath = new URL("../../../examples/pipeline/src/core.ts", import.meta.url).pathname;
const pipelineChecked = checkFile(pipelinePath, { contractEntry: "core_facade.ts" });
assert.equal(pipelineChecked.ok, true, JSON.stringify(pipelineChecked.diagnostics) + pipelineChecked.typeErrors.join("\n"));
const pipelineContract: ViewContract = JSON.parse(pipelineChecked.contract!);

test("portable pipeline components reject malformed structure and noninteger stages", () => {
  const cases = [
    ['<stepper/>', /requires active/],
    ['<stepper active="1.5"/>', /requires an integer/],
    ['<stepper active="0"><text>wrong</text></stepper>', /step text leaves/],
    ['<stepper active="0"><step key="x">wrong</step></stepper>', /step text leaves/],
    ['<stepper active="0"><step><text>wrong</text></step></stepper>', /step text leaves/],
    ['<stepper active="0" gap="1"/>', /unsupported stepper attribute/],
    ['<stepper active="0"><slot/></stepper>', /slot requires/],
    ['<timeline-item/>', /requires title/],
    ['<timeline-item title="x"><text/></timeline-item>', /requires title/],
    ['<timeline-item title="x" on-toggle="reset"/>', /unsupported timeline-item attribute/],
    ['<timeline-item title="{active}"/>', /requires text/],
  ] as const;
  for (const [markup, pattern] of cases) assert.throws(() => compileView(markup, pipelineContract), pattern);
});

test("portable stepper owns state, primitive composition and accessible positions", () => {
  const generated = compileView('<stepper active="{active}" label="Stages"><step>Plan</step><step>Review café</step><step>Ship</step></stepper>', pipelineContract);
  assert.ok(generated.includes("function nscvStepper"));
  const model = { active: 1 };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, nscfCommitted: model });
  const view = () => JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes as any[];
  const nodes = view();
  assert.equal(nodes.length, 12);
  assert.equal(nodes[0].role, "list");
  assert.deepEqual(nodes.filter(n => n.role === "listitem").map(n => [n.label, n.selected, n.listItemIndex, n.listItemCount]), [
    ["Plan (completed)", false, 0, 3], ["Review café (active)", true, 1, 3], ["Ship (pending)", false, 2, 3],
  ]);
  assert.equal(nodes[2].icon, "check");
  assert.equal(nodes[7].spanWeight, "bold");
  assert.equal(nodes[11].foreground, "text_muted");
  model.active = 5;
  assert.ok(view().filter(n => n.kind === "badge").every(n => n.icon === "check"));
  model.active = -1;
  assert.equal(view()[1].label, "Plan (active)");
  model.active = 0.5;
  assert.throws(view, /exact integer/);
});

test("portable component expansion enforces the shared native node budget", () => {
  const markup = '<column>' + '<stepper active="0"><step>a</step><step>b</step><step>c</step></stepper>'.repeat(90) + '</column>';
  const generated = compileView(markup, pipelineContract);
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  assert.throws(() => exports.native_view!(), /1024 nodes/);
});

test("radio markup preserves native checked state and canonical change handlers", () => {
  const { view } = evaluate('<column><radio-group label="Delivery"><radio checked="true" on-change="reset">Standard</radio><radio disabled="true">Unavailable</radio></radio-group></column>');
  assert.equal(view().nodes[1].kind, "radio_group");
  assert.equal(view().nodes[1].label, "Delivery");
  assert.equal(view().nodes[2].kind, "radio");
  assert.equal(view().nodes[2].checked, true);
  assert.deepEqual(view().nodes[2].change, [1, 5]);
  assert.throws(() => compileView('<radio-group><radio>Missing label</radio></radio-group>', contract), /requires a label/);
  assert.throws(() => compileView('<button on-change="reset">Invalid</button>', contract), /unsupported on button/);
});

test("tabs lower only direct button triggers after structural expansion", () => {
  const { view } = evaluate('<column><tabs label="Workspace"><if test="{count > 0}"><button selected="true" on-press="reset">Overview</button></if><segmented-control disabled="true" icon="settings">Settings</segmented-control><column><button>Nested</button></column></tabs><button>Outside</button></column>');
  const nodes = view().nodes;
  assert.equal(nodes[1].kind, "tabs");
  assert.equal(nodes[2].kind, "segmented_control");
  assert.equal(nodes[2].selected, true);
  assert.deepEqual(nodes[2].press, [1, 5]);
  assert.equal(nodes[3].disabled, true);
  assert.equal(nodes[3].icon, "settings");
  assert.equal(nodes[5].kind, "button");
  assert.equal(nodes[6].kind, "button");
});

test("tree rows preserve disclosure, logical levels and canonical row handlers", () => {
  const { model, view } = evaluate('<tree label="Folders"><panel role="treeitem" label="Source" expanded="{ticking}" tree-level="{count}" selected="true" on-press="reset" on-toggle="reset"><text>Source</text></panel><panel role="treeitem" label="Leaf" tree-level="65535" on-press="reset"><text>Leaf</text></panel></tree>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "tree");
  assert.equal(nodes[1].role, "treeitem");
  assert.equal(nodes[1].expanded, true);
  assert.equal(nodes[1].treeLevel, 7);
  assert.deepEqual(nodes[1].press, [1, 5]);
  assert.deepEqual(nodes[1].toggle, [1, 5]);
  assert.equal(nodes[3].expanded, undefined);
  assert.equal(nodes[3].treeLevel, 65535);
  model.ticking = false; assert.equal(view().nodes[1].expanded, false);
  for (const invalid of [-1, 65536, 0.5]) { model.count = invalid; assert.throws(view, /tree-level requires an integer/); }
  assert.throws(() => compileView('<panel expanded="true"/>', contract), /requires role=treeitem/);
  assert.throws(() => compileView('<panel tree-level="1"/>', contract), /requires role=treeitem/);
  assert.throws(() => compileView('<radio role="treeitem"/>', contract), /treeitem requires column, row or panel/);
  assert.throws(() => compileView('<button role="tree"/>', contract), /tree role requires a generic container/);
  assert.throws(() => compileView('<radio-group role="tree" label="Invalid"/>', contract), /tree role requires a generic container/);
});

test("list rows preserve leaf text, composed children, selection and press envelopes", () => {
  const { view } = evaluate('<column><list label="Work"><list-item icon="folder" selected="true" on-press="reset">Inbox</list-item><list-item label="Review" disabled="true" on-press="increment"><column><text>Review</text><text>Details</text></column></list-item><list label="Nested"><list-item>Saved</list-item></list></list></column>');
  const nodes = view().nodes;
  assert.equal(nodes[1].kind, "list");
  assert.equal(nodes[2].kind, "list_item");
  assert.equal(nodes[2].text, "Inbox");
  assert.equal(nodes[2].selected, true);
  assert.equal(nodes[2].icon, "folder");
  assert.deepEqual(nodes[2].press, [1, 5]);
  assert.equal(nodes[3].end, 7);
  assert.equal(nodes[3].text, "");
  assert.equal(nodes[3].disabled, true);
  assert.equal(nodes[7].kind, "list");
  assert.throws(() => compileView('<list-item>Mixed<text>child</text></list-item>', contract), /mixed content/);
  assert.throws(() => compileView('<list>Mixed</list>', contract), /mixed content/);
  assert.throws(() => compileView('<list-item on-toggle="reset"/>', contract), /unsupported on list-item/);
  assert.throws(() => compileView('<list-item role="treeitem"/>', contract), /compiled treeitem requires/);
  assert.throws(() => compileView('<list role="tree"/>', contract), /tree role requires/);
});

test("menu views preserve anchored picker composition and canonical dismissal", () => {
  const { view } = evaluate('<stack><select text="{status}" placeholder="Choose" on-press="increment"/><dropdown-menu anchor="above" anchor-alignment="stretch" anchor-offset="6" on-dismiss="reset" label="Choices"><menu-item icon="folder" selected="true" on-press="reset">Inbox</menu-item><separator/><menu-item disabled="true" on-press="increment">Unavailable</menu-item></dropdown-menu></stack>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "stack");
  assert.equal(nodes[1].kind, "select");
  assert.equal(nodes[1].placeholder, "Choose");
  assert.deepEqual(nodes[1].press, [1, 3]);
  assert.equal(nodes[2].kind, "dropdown_menu");
  assert.equal(nodes[2].anchor, "above");
  assert.equal(nodes[2].anchorAlignment, "stretch");
  assert.equal(nodes[2].anchorOffset, 6);
  assert.deepEqual(nodes[2].dismiss, [1, 5]);
  assert.equal(nodes[3].kind, "menu_item");
  assert.equal(nodes[3].selected, true);
  assert.equal(nodes[3].icon, "folder");
  assert.equal(nodes[4].kind, "separator");
  assert.equal(nodes[5].disabled, true);
  assert.throws(() => compileView('<button on-dismiss="reset"/>', contract), /unsupported on button/);
  assert.throws(() => compileView('<panel anchor="below"/>', contract), /requires dropdown-menu/);
  assert.throws(() => compileView('<dropdown-menu anchor-alignment="stretch"/>', contract), /requires anchor/);
  assert.throws(() => compileView('<dropdown-menu anchor="below" anchor-offset="{count}"/>', contract), /finite literal number/);
  assert.throws(() => compileView('<dropdown-menu anchor="sideways"/>', contract), /unsupported anchor/);
  assert.throws(() => compileView('<menu-item>Mixed<text>child</text></menu-item>', contract), /mixed content/);
  assert.throws(() => compileView('<menu-item role="treeitem"/>', contract), /compiled treeitem requires/);
});


test("toggle groups preserve independent toggles, model selection and toggle envelopes", () => {
  const { view } = evaluate('<toggle-group gap="6" label="Theme"><toggle-button selected="true" icon="sun" on-toggle="reset">Light</toggle-button><toggle-button disabled="true" on-toggle="increment">Unavailable</toggle-button><toggle-button>Bold</toggle-button></toggle-group>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "toggle_group");
  assert.equal(nodes[0].label, "Theme");
  assert.equal(nodes[1].kind, "toggle_button");
  assert.equal(nodes[1].selected, true);
  assert.equal(nodes[1].icon, "sun");
  assert.deepEqual(nodes[1].toggle, [1, 5]);
  assert.equal(nodes[2].disabled, true);
  assert.deepEqual(nodes[2].toggle, [1, 3]);
  assert.equal(nodes[3].toggle, undefined);
  assert.throws(() => compileView('<toggle-group on-toggle="reset"/>', contract), /unsupported on toggle-group/);
  assert.throws(() => compileView('<toggle-button on-change="reset"/>', contract), /unsupported on toggle-button/);
  assert.throws(() => compileView('<toggle-button>Mixed<text>child</text></toggle-button>', contract), /mixed content/);
  assert.throws(() => compileView('<toggle-button role="treeitem"/>', contract), /compiled treeitem requires/);
});

test("accordion headers preserve nested content, expansion and toggle envelopes", () => {
  const { view } = evaluate('<accordion text="Account café" selected="true" on-toggle="reset"><column gap="8"><text>Profile</text><button on-press="increment">Apply</button><accordion text="Nested" on-toggle="reset"><text>Tip</text></accordion></column></accordion>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "accordion");
  assert.equal(nodes[0].text, "Account café");
  assert.equal(nodes[0].selected, true);
  assert.deepEqual(nodes[0].toggle, [1, 5]);
  assert.equal(nodes[0].end, nodes.length);
  assert.equal(nodes[4].kind, "accordion");
  assert.equal(nodes[4].end, 6);
  assert.throws(() => compileView('<accordion text="Section" on-press="reset"/>', contract), /unsupported on accordion/);
  assert.throws(() => compileView('<accordion text="Section" on-change="reset"/>', contract), /unsupported on accordion/);
  assert.throws(() => compileView('<accordion text="Section" placeholder="Help"/>', contract), /placeholder requires/);
  assert.throws(() => compileView('<accordion text="Section">Mixed<text>child</text></accordion>', contract), /mixed content/);
  assert.throws(() => compileView('<accordion text="Section" role="treeitem"/>', contract), /compiled treeitem requires/);
});

test("checkable controls preserve labels, initial state and toggle envelopes", () => {
  const { view } = evaluate('<column><checkbox text="Product café" checked="true" on-toggle="reset"/><switch checked="false" on-toggle="increment">Sync</switch><toggle checked="true" disabled="true">Compact</toggle></column>');
  const nodes = view().nodes;
  assert.equal(nodes[1].kind, "checkbox");
  assert.equal(nodes[1].text, "Product café");
  assert.equal(nodes[1].checked, true);
  assert.deepEqual(nodes[1].toggle, [1, 5]);
  assert.equal(nodes[2].kind, "switch_control");
  assert.equal(nodes[2].checked, false);
  assert.deepEqual(nodes[2].toggle, [1, 3]);
  assert.equal(nodes[3].kind, "toggle");
  assert.equal(nodes[3].disabled, true);
  for (const kind of ["checkbox", "switch", "toggle"]) {
    assert.throws(() => compileView(`<${kind} on-press="reset"/>`, contract), /unsupported on/);
    assert.throws(() => compileView(`<${kind} on-change="reset"/>`, contract), /unsupported on/);
    assert.throws(() => compileView(`<${kind} placeholder="Help"/>`, contract), /placeholder requires/);
    assert.throws(() => compileView(`<${kind}>Mixed<text>child</text></${kind}>`, contract), /mixed content/);
    assert.throws(() => compileView(`<${kind} role="treeitem"/>`, contract), /compiled treeitem requires/);
  }
});

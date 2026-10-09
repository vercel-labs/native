import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext as runView } from "node:vm";
import * as textLibrary from "../sdk/text.ts";
import ts from "@typescript/old";
import { compileView, compileViewBundle, type ViewContract } from "../src/view_frontend.ts";
import { checkFile } from "../src/frontend.ts";

const runInNewContext = (code: string, context: Record<string, unknown>) => runView(code, {
  ...context,
  require: (name: string) => {
    assert.equal(name, "@native-sdk/core/text");
    return textLibrary;
  },
});

// Semantic assertions apply the native consumer's raw-byte precedence.
// Wire assertions below inspect the unmodified JSON separately.
function decodedView(bytes: Uint8Array): any {
  const value = JSON.parse(new TextDecoder().decode(bytes));
  const visit = (item: any): void => {
    if (!item || typeof item !== "object") return;
    if (Array.isArray(item)) { item.forEach(visit); return; }
    for (const field of ["text", "label", "placeholder", "icon"]) if (item[field + "Bytes"] !== undefined) {
      item[field] = new TextDecoder().decode(new Uint8Array(item[field + "Bytes"]));
      delete item[field + "Bytes"];
    }
    Object.values(item).forEach(visit);
  };
  visit(value); return value;
}

const contract: ViewContract = {
  model: "Model", types: { structs: [{ name: "Model", fields: [
    { name: "count", type: { kind: "i64" } }, { name: "tickCount", type: { kind: "i64" } },
    { name: "stampedMs", type: { kind: "f64" } }, { name: "ticking", type: { kind: "bool" } },
    { name: "status", type: { kind: "bytes" } },
  ] }] },
  model_helpers: [{ name: "total", params: [], returns: { kind: "i64" } }],
  msg: { arms: ["load", "loaded", "failed", "increment", "decrement", "reset", "toggle_ticking", "stamp", "stamped", "tick"].map(name => ({ name, payload: { kind: ["loaded", "failed"].includes(name) ? "bytes" : ["stamped", "tick"].includes(name) ? "number" : "void" } })) },
};

test("compiled audit type names receive the wiring collision diagnostic", () => {
  for (const name of ["NscAuditNode", "NscAuditDescendant", "NscAuditFinding", "nscvWidgetAudits"]) {
    const conflicting = { ...contract, types: { ...contract.types, structs: [...contract.types.structs, { name, fields: [] }] } };
    assert.throws(() => compileView("<column />", conflicting), /collides with compiled view wiring/);
  }
});
const source = readFileSync(new URL("../../../tests/native-driver/src/app.native", import.meta.url), "utf8");
const evaluate = (markup: string) => {
  const generated = compileView(markup, contract);
  const js = ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const model = { count: 7, tickCount: 3, ticking: true, stampedMs: -1, status: new TextEncoder().encode("Café\nnotes") };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model, total: (m: typeof model) => m.count + m.tickCount,
    nscfPackMsg: (msg: { kind: string }) => Uint8Array.of(1, contract.msg.arms.findIndex(arm => arm.name === msg.kind)) });
  return { model, view: () => decodedView(exports.native_view!()), wire: () => JSON.parse(new TextDecoder().decode(exports.native_view!())) };
};

test("compiled views retain byte-valued standalone and inline icon names", () => {
  const value = evaluate('<column><icon name="{status}"/><button icon="{status}" on-press="increment">Play</button></column>');
  value.model.status = new TextEncoder().encode("app:wave");
  const first = value.wire().nodes;
  assert.deepEqual(first[1].textBytes, [97, 112, 112, 58, 119, 97, 118, 101]);
  assert.deepEqual(first[2].iconBytes, first[1].textBytes);
  assert.equal(value.view().nodes[2].icon, "app:wave");
  value.model.status = new Uint8Array([112, 0, 255]);
  const second = value.wire().nodes;
  assert.deepEqual(second[1].textBytes, [112, 0, 255]);
  assert.deepEqual(second[2].iconBytes, [112, 0, 255]);
  assert.deepEqual(first[2].iconBytes, [97, 112, 112, 58, 119, 97, 118, 101]);
  assert.throws(() => compileView('<icon name="{count}"/>', contract), /requires text/);
  assert.throws(() => compileView('<button icon="{count}"/>', contract), /requires text/);
});

test("compiled list selection preserves change envelopes and semantic theme tokens", () => {
  const value = evaluate('<list role="list"><list-item background="accent" foreground="success" border-color="warning" focus-ring="info" on-change="increment" selected="true">Selected</list-item></list>');
  const nodes = value.view().nodes;
  assert.equal(nodes[0].role, "list");
  assert.equal(nodes[1].selected, true);
  assert.deepEqual(nodes[1].change, [1, contract.msg.arms.findIndex(arm => arm.name === "increment")]);
  assert.deepEqual([nodes[1].background, nodes[1].foreground, nodes[1].borderColor, nodes[1].focusRing], ["accent", "success", "warning", "info"]);
  assert.doesNotThrow(() => compileView('<panel role="treeitem" on-change="increment"/>', contract));
  assert.throws(() => compileView('<text on-change="increment"/>', contract), /unsupported/);
  assert.throws(() => compileView('<panel background="unknown"/>', contract), /unsupported/);
});

test("compiled tables, bubbles and indicators preserve native authoring channels", () => {
  const value = evaluate(`<column>
    <table><table-row global-key="{count}" selected="true" on-press="increment">
      <table-cell width="80" text-alignment="end" on-press="reset">{status}</table-cell>
    </table-row></table>
    <bubble variant="primary" radius="xl"><text>Message</text><reactions>{status}</reactions></bubble>
    <progress value="{count}"/><skeleton width="48" height="14"/><spinner/>
    <list-item quiet-hover="{ticking}" accent="success" accent-foreground="success_text" on-change="reset">Album</list-item>
    <button icon="chevron-right" icon-placement="trailing">Next</button>
    <combobox text="{status}" placeholder="Search" on-press="increment"/>
  </column>`);
  const nodes = value.view().nodes;
  assert.deepEqual(nodes.map((node: any) => node.kind), ["column", "table", "data_row", "data_cell", "bubble", "text", "progress", "skeleton", "spinner", "list_item", "button", "combobox"]);
  assert.equal(nodes[2].globalKeyInt, 7);
  assert.equal(nodes[2].selected, true);
  assert.deepEqual(nodes[2].press, [1, 3]);
  assert.equal(nodes[3].text, "Café\nnotes");
  assert.equal(nodes[3].textAlignment, "end");
  assert.deepEqual(nodes[3].press, [1, 5]);
  assert.equal(nodes[4].end, 6);
  assert.equal(nodes[4].text, "Café\nnotes");
  assert.equal(nodes[4].textAlignment, "end");
  assert.equal(nodes[4].radius, "xl");
  assert.equal(nodes[6].value, 7);
  assert.equal(nodes[9].quietHover, true);
  assert.equal(nodes[9].accent, "success");
  assert.equal(nodes[9].accentForeground, "success_text");
  assert.equal(nodes[10].iconPlacement, "trailing");
  assert.equal(nodes[11].text, "Café\nnotes");
  value.model.ticking = false;
  assert.equal(value.view().nodes[9].quietHover, false);
  for (const markup of ['<row quiet-hover="true"/>', '<bubble text="ignored"/>', '<bubble><reactions on-press="reset">Yes</reactions></bubble>', '<panel><reactions>Yes</reactions></panel>', '<bubble><reactions>A</reactions><reactions>B</reactions></bubble>', '<button icon-placement="unknown"/>'])
    assert.throws(() => compileView(markup, contract), /compiled TypeScript view/);
});

test("word boolean operators retain precedence and generic press and toggle envelopes", () => {
  const value = evaluate('<column><if test="{not ticking or count == 7 and tickCount == 3}"><text on-press="reset" on-toggle="increment">Ready</text></if></column>');
  assert.equal(value.view().nodes.length, 2);
  assert.deepEqual(value.view().nodes[1].press, [1, 5]);
  assert.deepEqual(value.view().nodes[1].toggle, [1, 3]);
  value.model.count = 8;
  assert.equal(value.view().nodes.length, 1);
  value.model.ticking = false;
  assert.equal(value.view().nodes.length, 2);
  assert.throws(() => compileView('<text selected="{not count}"/>', contract), /requires boolean/);
});

test("compiled Markdown accepts complete byte presentation bindings and rejects invalid shapes", () => {
  const input: ViewContract = { ...contract, types: { structs: [
    { name: "Model", fields: [
      { name: "body", type: { kind: "bytes" } }, { name: "issue", type: { kind: "bytes" } },
      { name: "expanded", type: { kind: "slice", elem: { kind: "bool" } } },
      { name: "images", type: { kind: "slice", elem: { kind: "node", name: "ResolvedImage" } } },
    ] },
    { name: "ResolvedImage", fields: [
      { name: "source", type: { kind: "bytes" } }, { name: "image", type: { kind: "i64" } },
      { name: "width", type: { kind: "f64" } }, { name: "height", type: { kind: "f64" } },
    ] },
  ] }, model_helpers: [], msg: { arms: [
    { name: "open_url", member: "url", payload: { kind: "bytes" } },
    { name: "toggle_details", member: "index", payload: { kind: "number" } },
    { name: "reset", payload: { kind: "void" } },
  ] } };
  const markup = '<markdown source="{body}" on-link="open_url" on-details="toggle_details" details-expanded="{expanded}" issue-link-base="{issue}" images="{images}" />';
  const model = { body: new Uint8Array([65, 0, 255]), issue: new Uint8Array([105, 58, 255]), expanded: [false, true], images: [{ source: new Uint8Array([97]), image: 4294967297, width: 10.25, height: 20.5 }] };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView(markup, input), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  const first = decodedView(exports.native_view!()).nodes[0];
  assert.equal(first.kind, "markdown"); assert.equal(first.markdownLink, 0); assert.equal(first.markdownDetails, 1);
  assert.ok(first.markdownRecipe.includes(255));
  model.body = new TextEncoder().encode("<details>\n<summary>More</summary>\nbody\n</details>");
  const collapsed = decodedView(exports.native_view!()).nodes[0].markdownRecipe;
  model.expanded[0] = true;
  assert.notDeepEqual(decodedView(exports.native_view!()).nodes[0].markdownRecipe, collapsed);
  assert.doesNotThrow(() => compileView(markup.replace('{issue}', 'literal://'), input));
  assert.doesNotThrow(() => compileView('<markdown source="{body}"/>', input));
  for (const invalid of [
    '<markdown/>', '<markdown source="literal"/>', '<markdown source="{expanded}"/>',
    '<markdown source="{body}">text</markdown>', '<markdown source="{body}"><text/></markdown>',
    '<markdown source="{body}" width="10"/>', '<markdown source="{body}" source="{body}"/>',
    markup.replace('details-expanded="{expanded}"', 'details-expanded="{body}"'),
    markup.replace('images="{images}"', 'images="{expanded}"'),
    markup.replace('issue-link-base="{issue}"', 'issue-link-base="{expanded}"'),
    markup.replace('on-link="open_url"', 'on-link="reset"'),
    markup.replace('on-details="toggle_details"', 'on-details="open_url"'),
    markup.replace('on-details="toggle_details"', 'on-details="toggle_details:{body}"'),
  ]) assert.throws(() => compileView(invalid, input), /compiled TypeScript view/);
  const invalidImages: ViewContract = { ...input, types: { structs: [input.types.structs[0]!, { name: "ResolvedImage", fields: input.types.structs[1]!.fields.filter(field => field.name !== "height") }] } };
  assert.throws(() => compileView(markup, invalidImages), /images requires/);
});

test("compiled views reject repeated virtual attributes before binding checks", () => {
  for (const markup of [
    '<virtual-window id="rows" id="again" />',
    '<virtual-list grow="1" grow="2" />',
  ]) assert.throws(() => compileView(markup, contract), /duplicate attribute/);
});

test("windowed row queries consume complete viewport facts without materializing other rows", () => {
  const rangeNames = ["start_index", "end_index", "first_visible_index", "last_visible_index", "item_extent", "item_gap", "scroll_offset", "layout_offset", "content_extent", "before_extent", "after_extent", "anchor_extent"];
  const input: ViewContract = { ...contract, types: { structs: [...contract.types.structs,
    { name: "VirtualListRange", fields: rangeNames.map((name, index) => ({ name, type: { kind: index < 4 ? "i64" : "f64" } })) },
    { name: "Post", fields: [{ name: "id", type: { kind: "i64" } }] },
  ] }, model_helpers: [
    { name: "estimate", params: [{ kind: "i64" }], returns: { kind: "f64" } },
    { name: "rows", params: [{ kind: "value", name: "VirtualListRange" }], returns: { kind: "slice", elem: { kind: "value", name: "Post" } } },
  ] };
  const markup = '<virtual-window id="posts" as="window" item-count="{count}" extent-estimate="estimate" overscan="2"><column><virtual-list window="window" each="rows" as="post" grow="1" on-reach-end="load"><list-item key="{post.id}">{post.id}</list-item></virtual-list><status-bar>{window.first_visible_index}–{window.last_visible_index} at {window.scroll_offset}</status-bar></column></virtual-window>';
  const exports: Record<string, (...args: Uint8Array[]) => Uint8Array> = {};
  const calls: Record<string, number>[] = [];
  let rowsResult = [{ id: 7 }, { id: 8 }];
  runInNewContext(ts.transpile(compileView(markup, input), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: { count: 100000 },
    rows: (_model: unknown, range: Record<string, number>) => { calls.push(range); return rowsResult; },
    nscfPackMsg: () => Uint8Array.of(1, 0),
  });
  const video = new Uint8Array(20); video[0] = 1;
  const label = new Uint8Array(0);
  const requests = decodedView(exports.native_virtual_requests!(label, video));
  assert.equal(calls.length, 0);
  assert.deepEqual(requests, { format: 1, requests: [{ id: "posts", itemCount: 100000, itemExtent: 0, gap: 0, overscan: 2, viewportFallback: 0, indexBase: 0, trailing: false, estimateHelper: 0 }] });
  const numbers = [7, 9, 7, 8, 0, 1.25, 190.5, 191.75, 800000.25, 150.125, 799610.5, 180.75];
  const context = new Uint8Array(104), wire = new DataView(context.buffer);
  wire.setUint32(0, 1, true); wire.setUint32(4, 1, true);
  numbers.forEach((number, index) => wire.setFloat64(8 + index * 8, number, true));
  const tree = decodedView(exports.native_virtual_view!(label, context, video));
  assert.deepEqual(Object.fromEntries(rangeNames.map((name, index) => [name, calls[0]![name]])), Object.fromEntries(rangeNames.map((name, index) => [name, numbers[index]])));
  assert.equal(tree.nodes.filter((node: { kind: string }) => node.kind === "list_item").length, 2);
  assert.equal(tree.nodes[1].virtualWindow, 0);
  assert.deepEqual(tree.nodes[1].reachEnd, [1, 0]);
  assert.equal(tree.nodes.at(-1).text, "7–8 at 190.5");
  assert.throws(() => exports.native_virtual_view!(label, context.subarray(0, 103), video), /invalid virtual window context/);
  wire.setFloat64(8, 7.5, true);
  assert.throws(() => exports.native_virtual_view!(label, context, video), /invalid virtual window range/);
  wire.setFloat64(8, 7, true); rowsResult = [{ id: 7 }];
  assert.throws(() => exports.native_virtual_view!(label, context, video), /different item count/);
  assert.throws(() => compileView(markup.replace('key="{post.id}"', ""), input), /keyed root/);
});

test("hold envelopes preserve borrowed text and coexist with ordinary press handlers", () => {
  const input: ViewContract = { ...contract, msg: { arms: [
    { name: "held", member: "text", payload: { kind: "bytes" } },
    { name: "pressed", payload: { kind: "void" } },
  ] } };
  const model = { status: new TextEncoder().encode("Café\0日本") };
  const exports: { native_view?: () => Uint8Array } = {};
  const generated = compileView('<button on-press="pressed" on-hold="held:{status}">Card</button>', input);
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: model,
    nscfPackMsg: (msg: { kind: string; text?: Uint8Array }) => new Uint8Array([1, msg.kind === "held" ? 0 : 1, ...msg.text ?? []]),
  });
  const view = decodedView(exports.native_view!()).nodes[0];
  assert.deepEqual(view.hold, [1, 0, ...model.status]);
  assert.deepEqual(view.press, [1, 1]);
  model.status = new TextEncoder().encode("changed");
  assert.deepEqual(decodedView(exports.native_view!()).nodes[0].hold, [1, 0, ...model.status]);
  assert.throws(() => compileView('<button on-hold="held">Card</button>', input), /matching scalar/);
  assert.throws(() => compileView('<button on-hold="unknown">Card</button>', input), /event/);
});

test("hold coordination preserves cancellation, release suppression and missing-tree behavior", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  assert.deepEqual([...policy(new Uint8Array([19, 0, 4]))], [6]); // First down arms.
  assert.deepEqual([...policy(new Uint8Array([19, 0, 1]))], [3]); // New down cancels the previous timer.
  assert.deepEqual([...policy(new Uint8Array([19, 1, 3]))], [10]); // A fired hold consumes release.
  assert.deepEqual([...policy(new Uint8Array([19, 1, 1]))], [3]); // Early release cancels.
  assert.deepEqual([...policy(new Uint8Array([19, 2, 1]))], [0]); // Missing view leaves the gesture pending.
  assert.deepEqual([...policy(new Uint8Array([19, 2, 9]))], [16]);
  assert.deepEqual([...policy(new Uint8Array([19, 2, 11]))], [0]); // Repeated timer never dispatches twice.
  assert.deepEqual([...policy(new Uint8Array([19, 3, 1]))], [3]); // Drag takeover cancels.
  for (const bytes of [[19], [19, 0], [19, 0, 0, 0], [19, 4, 0], [19, 0, 16]])
    assert.throws(() => policy(new Uint8Array(bytes)), /press hold/);
});

test("the view frontend and compiled portable component bundle typecheck", () => {
  const options: ts.CompilerOptions = {
    noEmit: true, strict: true, target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.NodeNext,
    types: ["node"], typeRoots: [new URL("../node_modules/@types", import.meta.url).pathname],
  };
  // Production joins these policies in one module before compiling the view.
  const bundlePath = new URL("../src/view_components_typecheck.ts", import.meta.url).pathname;
  const bundle = ["view_components.ts", "runtime_policy.ts", "scalar_text.ts", "glyph_atlas.ts", "registered_font.ts", "vector_effects.ts", "text_run_layout.ts", "text_query_layout.ts", "text_span_queries.ts", "text_measurement_cache.ts", "text_document_width.ts", "paragraph_layout.ts", "control_appearance.ts", "component_construction.ts", "widget_motion.ts", "component_composition.ts", "code_content.ts", "chart_content.ts", "markdown_content.ts", "widget_audits.ts", "widget_routing.ts", "widget_changes.ts", "widget_paint.ts", "widget_presentation.ts", "widget_paint_walk.ts", "control_geometry.ts", "control_content.ts", "surface_recipes.ts", "widget_metrics.ts", "intrinsic_measure.ts", "measurement_coordination.ts", "flow_measurement.ts", "layout_coordination.ts", "render_coordination.ts", "control_commands.ts", "control_payloads.ts", "control_primitives.ts", "leaf_plans.ts", "chart_plans.ts", "indicator_plans.ts", "effect_plans.ts", "stream_policy.ts"]
    .map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
  const host = ts.createCompilerHost(options);
  const readSource = host.getSourceFile.bind(host);
  host.getSourceFile = (name, languageVersion, onError, fresh) => name === bundlePath
    ? ts.createSourceFile(name, bundle, languageVersion, true)
    : readSource(name, languageVersion, onError, fresh);
  const program = ts.createProgram([new URL("../src/view_frontend.ts", import.meta.url).pathname, bundlePath], options, host);
  assert.deepEqual(ts.getPreEmitDiagnostics(program).map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")), []);
});

test("editable no-wrap code lowers to owned textarea metadata and bounded line numbers", () => {
  const { model, view } = evaluate('<code source="{status}" language=" TS " editable="true" wrap="false" line-numbers="{ticking}" label="Draft"/>');
  let node = view().nodes[0];
  assert.equal(node.kind, "textarea"); assert.equal(node.codeLanguage, "typescript");
  assert.equal(node.codeLineDigits, 1); assert.equal(node.text, "Café\nnotes");
  model.status = new TextEncoder().encode("x\n".repeat(9));
  assert.equal(view().nodes[0].codeLineDigits, 2);
  model.status = new TextEncoder().encode("x\n".repeat(10000));
  assert.equal(view().nodes[0].codeLineDigits, 5);
  model.status = new TextEncoder().encode("x\n".repeat(10001));
  assert.equal(view().nodes[0].codeLineDigits, 0);
  model.ticking = false; model.status = new TextEncoder().encode("x");
  assert.equal(view().nodes[0].codeLineDigits, 0);
  for (const markup of [
    '<code source="{status}" editable="{ticking}" wrap="false"/>',
    '<code source="{status}" wrap="{ticking}"/>',
    '<code source="{count}" editable="true" wrap="false"/>',
    '<code source="{status}" language="unknown" editable="true" wrap="false"/>',
    '<code source="{status}" editable="true" wrap="false" disabled="true"/>',
    '<code source="{status}" editable="true" wrap="false"><text>child</text></code>',
  ]) assert.throws(() => compileView(markup, contract), /compiled TypeScript view/);
});

test("compiled code accepts read-only and wrapped presentation with exact source bytes", () => {
  for (const editable of [false, true]) for (const wrap of [false, true]) {
    const { model, wire } = evaluate(`<code source="{status}" language="tsx" editable="${editable}" wrap="${wrap}" line-numbers="true" added-lines="1,128" height="120" width="320"/>`);
    model.status = new Uint8Array([0, 255, 192, 175, 10]);
    const node = wire().nodes[0];
    assert.deepEqual(node.textBytes, [...model.status]);
    assert.equal(node.codeLanguage, "tsx");
    if (editable && !wrap) { assert.equal(node.kind, "textarea"); assert.equal(node.codeLineDigits, 1); }
    else { assert.equal(node.kind, "code"); assert.equal(node.codeEditable, editable); assert.equal(node.codeNumbered, true); assert.equal(node.wrap, wrap); assert.equal(node.codeLineDigits, undefined); }
    assert.deepEqual(node.codeAddedLines, [1, 128]);
    model.status = new TextEncoder().encode("x\n".repeat(129));
    assert.equal(wire().nodes[0].codeAddedLines === undefined, !editable);
  }
  assert.throws(() => compileView('<code source="{status}" on-input="increment"/>', contract), /read-only/);
});

test("compiled indentation requests preserve the shared text library's file convention", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const source = new TextEncoder().encode("\tcafé\n    日本");
  const request = new Uint8Array(8 + source.length), data = new DataView(request.buffer);
  request[0] = 11; request.set(source, 8);
  data.setUint32(4, 1, true); assert.equal(exports.native_text_policy!(request)[0], 0);
  data.setUint32(4, source.length, true); assert.equal(exports.native_text_policy!(request)[0], 4);
  data.setUint32(4, 0xffffffff, true); assert.equal(exports.native_text_policy!(request)[0], 4);
  request[2] = 1; assert.throws(() => exports.native_text_policy!(request), /indentation request/);
  assert.throws(() => exports.native_text_policy!(new Uint8Array([11])), /indentation request/);
});

test("clipboard requests preserve source ranges, exact huge offsets and validation", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const source = new TextEncoder().encode("aé🙂\r\nz");
  const request = new Uint8Array(24 + source.length), data = new DataView(request.buffer);
  request[0] = 12; request[1] = 1; data.setUint32(4, source.length, true); request.set(source, 24);
  data.setBigUint64(8, 6n, true); data.setBigUint64(16, 2n, true);
  const result = () => {
    const bytes = exports.native_text_policy!(request), out = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return [out.getUint32(0, true), out.getUint32(4, true), out.getUint32(8, true)];
  };
  assert.deepEqual(result(), [3, 1, 3]);
  data.setBigUint64(8, 0xffffffffffffffffn, true); data.setBigUint64(16, 0n, true);
  assert.deepEqual(result(), [3, 0, source.length]);
  data.setBigUint64(16, 9007199254740992n, true); assert.deepEqual(result(), [2, 0, 0]);
  request[1] = 0; assert.deepEqual(result(), [2, 0, 0]);
  request[2] = 1; assert.throws(result, /clipboard request/); request[2] = 0;
  data.setUint32(4, source.length + 1, true); assert.throws(result, /clipboard budget/);
  assert.throws(() => exports.native_text_policy!(new Uint8Array([12])), /clipboard request/);
});

test("editor boundary requests preserve Escape precedence and closed picker routing", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const intent = (kind: number, phase: number, bits: number, key: number, text = 0, composition = 0, expanded = 0) =>
    [...exports.native_text_policy!(new Uint8Array([14, kind, phase, bits, key, text, composition, expanded]))];
  assert.deepEqual(intent(0, 0, 0, 1, 1, 1), [2, 0]);
  assert.deepEqual(intent(2, 0, 0, 1, 1, 1), [2, 0]);
  assert.deepEqual(intent(2, 0, 0, 1, 1), [3, 0]);
  assert.deepEqual(intent(1, 0, 0, 1, 1), [1, 0]);
  assert.deepEqual(intent(0, 0, 0, 2), [0, 0]);
  assert.deepEqual(intent(1, 0, 1, 2), [4, 1]);
  assert.deepEqual(intent(2, 0, 0, 3), [5, 0]);
  assert.deepEqual(intent(3, 0, 1, 3), [0, 1]);
  assert.deepEqual(intent(3, 0, 1, 3, 0, 0, 1), [5, 1]);
  for (const bits of [1, 2, 4, 8, 15]) assert.equal(intent(2, 0, bits, 1)[0], 0);
  for (const phase of [1, 2]) assert.equal(intent(2, phase, 0, 1, 0, 1)[0], 0);
  assert.equal(intent(1, 0, 0, 2, 1)[0], 0);
  for (const request of [[14], [14, 4, 0, 0, 0, 0, 0, 0], [14, 0, 3, 0, 0, 0, 0, 0],
    [14, 0, 0, 16, 0, 0, 0, 0], [14, 0, 0, 0, 4, 0, 0, 0], [14, 0, 0, 0, 0, 2, 0, 0],
    [14, 0, 0, 0, 0, 0, 2, 0], [14, 0, 0, 0, 0, 0, 0, 2]]) {
    assert.throws(() => exports.native_text_policy!(new Uint8Array(request)), /editor boundary request/);
  }
});

test("editor shortcut requests preserve primary modifiers and refuse malformed input", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const shortcut = (mode: number, phase: number, bits: number, key: number) => [...exports.native_text_policy!(new Uint8Array([13, mode, phase, bits, key]))];
  for (const bits of [2, 8, 10]) {
    assert.deepEqual(shortcut(0, 0, bits, 1), [1]);
    assert.deepEqual(shortcut(0, 0, bits, 2), [2]);
    assert.deepEqual(shortcut(0, 0, bits, 3), [3]);
    assert.deepEqual(shortcut(0, 0, bits | 1, 3), [0]);
    assert.deepEqual(shortcut(0, 0, bits | 4, 1), [0]);
  }
  assert.deepEqual(shortcut(1, 0, 8, 4), [1]);
  assert.deepEqual(shortcut(1, 0, 9, 4), [2]);
  assert.deepEqual(shortcut(1, 0, 10, 4), [1]);
  assert.deepEqual(shortcut(1, 0, 2, 4), [0]);
  assert.deepEqual(shortcut(1, 0, 12, 4), [0]);
  for (const phase of [1, 2]) for (const mode of [0, 1]) assert.deepEqual(shortcut(mode, phase, 8, mode === 0 ? 1 : 4), [0]);
  for (const request of [[13], [13, 0, 0, 8, 1, 0], [13, 2, 0, 8, 1], [13, 0, 3, 8, 1], [13, 0, 0, 16, 1], [13, 0, 0, 8, 5]])
    assert.throws(() => exports.native_text_policy!(new Uint8Array(request)), /editor shortcut request/);
});

test("compiled code diff specs support literal and byte bindings and reject invalid annotations", () => {
  const { model, view } = evaluate('<code source="{status}" editable="true" wrap="false" added-lines="{status}" removed-lines="128, 127" line-numbers="true"/>');
  model.status = new TextEncoder().encode("2-4, 7, 3");
  let node = view().nodes[0];
  assert.deepEqual(node.codeAddedLines, [2, 3, 4, 7]); assert.deepEqual(node.codeRemovedLines, [128, 127]);
  assert.equal(node.text, "2-4, 7, 3"); assert.equal(node.codeLineDigits, 1);
  model.status = new TextEncoder().encode(" +1__2 ");
  assert.deepEqual(view().nodes[0].codeAddedLines, [12]);
  for (const spec of ["0", "129", "1-129", "1,,2", "128", "126-128"]) {
    model.status = new TextEncoder().encode(spec);
    assert.throws(view, /code diff/, spec);
  }
  const empty = evaluate('<code source="{status}" editable="true" wrap="false" added-lines=" \n" removed-lines=""/>').view().nodes[0];
  assert.equal(empty.codeAddedLines, undefined); assert.equal(empty.codeRemovedLines, undefined);
  assert.throws(() => compileView('<code source="{status}" editable="true" wrap="false" added-lines="{count}"/>', contract), /added-lines requires one text binding/);
  assert.throws(() => compileView('<textarea added-lines="1"/>', contract), /unsupported attribute added-lines/);
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
  const nodes = decodedView(exports.native_view!()).nodes;
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
    '<slider on-input="refresh"/>',
    '<slider placeholder="Level"/>', '<slider checked="true"/>', '<slider role="treeitem"/>', '<slider><text>Child</text></slider>']) {
    assert.throws(() => compileView(source, invalid), /compiled TypeScript view:/, source);
  }
});

test("split panes preserve float resize channels, minimum widths and structural pane counts", () => {
  const floatContract: ViewContract = { ...contract, msg: { arms: [...contract.msg.arms,
    { name: "resized", member: "fraction", payload: { kind: "number", class: "f64" } },
    { name: "integer_resize", member: "count", payload: { kind: "number", class: "i64" } }] } };
  const render = (markup: string) => {
    const exports: { native_view?: () => Uint8Array } = {};
    runInNewContext(ts.transpile(compileView(markup, floatContract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
      exports, TextEncoder, TextDecoder, nscfCommitted: { count: 2, ticking: true }, nscfPackMsg: () => Uint8Array.of(1, 5),
    });
    return decodedView(exports.native_view!()).nodes;
  };
  const nodes = render('<split value="0.35" on-resize="resized" gap="12" resize-duration="180" resize-easing="linear" resize-origin="0.2"><column min-width="150"><text>First</text></column><if test="{ticking}"><column min-width="220"/></if><else><column/></else></split>');
  assert.equal(nodes[0].resize, floatContract.msg.arms.findIndex(arm => arm.name === "resized"));
  assert.equal(nodes[0].resizeDuration, 180); assert.equal(nodes[0].resizeEasing, "linear"); assert.equal(nodes[0].resizeOrigin, 0.2);
  assert.deepEqual(nodes.filter((node: any) => node.kind === "column").map((node: any) => node.minWidth), [150, 220]);
  assert.equal(nodes.filter((node: any) => node.kind === "split_divider").length, 0);
  for (const markup of ['<split on-resize="integer_resize"><column/><column/></split>', '<split on-resize="reset"><column/><column/></split>',
    '<split on-resize="resized:{count}"><column/><column/></split>', '<column on-resize="resized"/>',
    '<column resize-duration="180"/>', '<split resize-easing="linear"><column/><column/></split>',
    '<split resize-duration="0" resize-origin="0.2"><column/><column/></split>', '<split resize-duration="180" resize-origin="1.1"><column/><column/></split>']) {
    assert.throws(() => compileView(markup, floatContract), /compiled TypeScript view:/);
  }
  for (const markup of ['<split><column/></split>', '<split><column/><column/><column/></split>',
    '<split><column/><if test="{count < 0}"><column/></if></split>']) assert.throws(() => render(markup), /exactly two panes/);
  assert.throws(() => render('<split resize-duration="0.5"><column/><column/></split>'), /resize-duration/);
});

test("scroll views preserve two-axis grants, offsets, overscroll and closed enum bindings", () => {
  const scrollContract: ViewContract = { ...contract, types: { ...contract.types,
    structs: [{ name: "Model", fields: [...contract.types.structs[0]!.fields,
      { name: "axes", type: { kind: "enum", name: "ScrollAxes" } },
      { name: "edges", type: { kind: "enum", name: "ScrollEdges" } }] }],
    enums: [{ name: "ScrollAxes", members: ["vertical", "horizontal", "both"] },
      { name: "ScrollEdges", members: ["default", "none", "rubber_band"] }],
  } };
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<scroll axis="{axes}" overscroll="{edges}" value="25.5" value-x="45.25"><column/></scroll>', scrollContract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: { axes: "both", edges: "rubber_band" },
  });
  const root = decodedView(exports.native_view!()).nodes[0];
  assert.equal(root.axis, "both"); assert.equal(root.overscroll, "rubber_band");
  assert.equal(root.value, 25.5); assert.equal(root.valueX, 45.25);
  for (const markup of ['<column axis="both"/>', '<column overscroll="none"/>', '<column value-x="3"/>',
    '<scroll axis="diagonal"/>', '<scroll overscroll="bounce"/>', '<scroll value-x="3"/>',
    '<scroll axis="vertical" value-x="3"/>', '<scroll axis="{edges}"/>', '<scroll overscroll="{axes}"/>']) {
    assert.throws(() => compileView(markup, scrollContract), /compiled TypeScript view:/, markup);
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
    ['<unsupported-surface/>', /unsupported element/], ['<text unknown="1"/>', /unsupported attribute/],
    ['<constructor/>', /unsupported element/],
    ['<text>{missing}</text>', /unknown binding/], ['<text>{count.constructor}</text>', /unsupported field/], ['<text>{count; process.exit()}</text>', /unsupported expression/],
    ['<switch checked="{count}"/>', /expected boolean/], ['<button on-press="loaded"/>', /scalar Msg payload/],
    ['<else/>', /unsupported element/],
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
  const view = () => decodedView(exports.native_view!());
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
  const nodes = decodedView(exports.native_view!()).nodes;
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
  const view = () => decodedView(exports.native_view!()).nodes;
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
  for (const markup of ['<input on-input="refresh"/>', '<input on-input="url_edit:{url}"/>', '<text on-input="url_edit"/>', '<panel wrap="true"/>', '<text placeholder="hint"/>', '<input size="heading"/>', '<input size="display"/>', '<input text="{url}">duplicate</input>']) {
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
  const view = (label: string) => decodedView(exports.native_window_view!(new TextEncoder().encode(label)));
  const first = view("café");
  assert.equal(first.nodes[1].text, "7");
  assert.deepEqual(first.nodes[2].press, [1, 3]);
  model.count = 8;
  assert.equal(view("other").nodes[1].text, "8");
  assert.equal(decodedView(exports.native_view!()).nodes[0].text, "8");
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
  const view = () => decodedView(exports.native_view!()).nodes as any[];
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

test("composed labels and timeline fields preserve malformed UTF-8 and NUL bytes", () => {
  const markup = '<column><input-group label="{status}"><textarea>{status}</textarea></input-group>' +
    '<stepper active="{count}" label="{status}"><step>Start {status}</step></stepper>' +
    '<timeline label="{status}"><timeline-item title="{status}" description="{status}" meta="{status}" indicator="{status}"/></timeline></column>';
  const exports: { native_view?: () => Uint8Array } = {};
  const model = { count: 0, status: Uint8Array.of(65, 0, 255, 192, 66) };
  runInNewContext(ts.transpile(compileView(markup, contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }),
    { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  const wire = () => JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes as any[];
  const nodes = wire();
  const raw = [...model.status];
  assert.deepEqual(nodes[1].labelBytes, raw);
  assert.deepEqual(nodes[3].labelBytes, raw);
  assert.deepEqual(nodes[4].labelBytes, [...new TextEncoder().encode("Start "), ...raw, ...new TextEncoder().encode(" (active)")]);
  assert.deepEqual(nodes[6].textBytes, [...new TextEncoder().encode("Start "), ...raw]);
  assert.deepEqual(nodes[7].labelBytes, raw);
  assert.deepEqual(nodes[8].labelBytes, raw);
  assert.deepEqual(nodes.filter(n => n.textBytes !== undefined && n.kind === "text").slice(-3).map(n => n.textBytes), [raw, raw, raw]);
  assert.deepEqual(nodes.find(n => n.kind === "badge" && n.textBytes !== undefined).textBytes, raw);
  model.status = new Uint8Array(0);
  const empty = wire();
  assert.equal(empty.filter(n => n.wrap || n.spanScale !== undefined).length, 0);
  assert.equal(empty.find(n => n.kind === "badge" && n.textBytes !== undefined).width, 10);
  assert.deepEqual(nodes[8].labelBytes, raw);
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
  assert.throws(() => compileView('<radio role="treeitem"/>', contract), /treeitem requires column, row, panel or list-item/);
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
  assert.doesNotThrow(() => compileView('<list-item on-toggle="reset"/>', contract));
  const treeitem = evaluate('<list-item role="treeitem" expanded="false" tree-level="2" on-toggle="reset">Work</list-item>').view().nodes[0];
  assert.equal(treeitem.role, "treeitem"); assert.equal(treeitem.expanded, false);
  assert.equal(treeitem.treeLevel, 2); assert.deepEqual(treeitem.toggle, [1, 5]);
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
  assert.doesNotThrow(() => compileView('<toggle-group on-toggle="reset"/>', contract));
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
  assert.doesNotThrow(() => compileView('<accordion text="Section" on-press="reset"/>', contract));
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
    assert.doesNotThrow(() => compileView(`<${kind} on-press="reset"/>`, contract));
    assert.throws(() => compileView(`<${kind} on-change="reset"/>`, contract), /unsupported on/);
    assert.throws(() => compileView(`<${kind} placeholder="Help"/>`, contract), /placeholder requires/);
    assert.throws(() => compileView(`<${kind}>Mixed<text>child</text></${kind}>`, contract), /mixed content/);
    assert.throws(() => compileView(`<${kind} role="treeitem"/>`, contract), /compiled treeitem requires/);
  }
});

test("resizable markup keeps stacking children, initial sizing and disabled state", () => {
  const { view } = evaluate('<resizable width="260" min-width="100" height="{count}" disabled="{ticking}" label="Notes"><column gap="8"><text>Research</text></column></resizable>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "resizable");
  assert.equal(nodes[0].width, 260);
  assert.equal(nodes[0].minWidth, 100);
  assert.equal(nodes[0].height, 7);
  assert.equal(nodes[0].disabled, true);
  assert.equal(nodes[0].end, 3);
  assert.equal(nodes[1].gap, 8);
  for (const markup of ['<resizable gap="8"/>', '<resizable on-resize="stamped"/>',
    '<resizable resize-duration="100"/>', '<resizable>Mixed<text>child</text></resizable>']) {
    assert.throws(() => compileView(markup, contract), /compiled TypeScript view:/, markup);
  }
});


test("textarea preserves multiline values, input/submit channels and bound Enter policy", () => {
  const { view } = evaluate('<textarea width="420" height="180" text="{status}" placeholder="Write" label="Note" submit-on-enter="{ticking}" disabled="{ticking}" on-submit="increment"/>');
  const node = view().nodes[0];
  assert.equal(node.kind, "textarea"); assert.equal(node.width, 420); assert.equal(node.height, 180);
  assert.equal(node.text, "Café\nnotes");
  const compiled = compileView('<textarea text="{url}" on-input="url_edit" on-submit="refresh"/>', feedContract);
  assert.match(compiled, new RegExp(`input: ${feedContract.msg.arms.findIndex(arm => arm.name === "url_edit")}`));
  assert.equal(node.submitOnEnter, true); assert.equal(node.disabled, true); assert.equal(node.placeholder, "Write");
  assert.deepEqual(node.submit, [1, contract.msg.arms.findIndex(arm => arm.name === "increment")]);
  for (const markup of ['<input submit-on-enter="true"/>', '<textarea submit-on-enter="1"/>',
    '<textarea><text>Child</text></textarea>'])
    assert.throws(() => compileView(markup, contract), /compiled TypeScript view:/);
});

test("retained text reducer preserves CRLF caret stops and refuses whole over-capacity edits", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<input/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const source = new TextEncoder().encode("é\r\nx"), inserted = new TextEncoder().encode("🙂");
  const request = new Uint8Array(40 + source.length + inserted.length), data = new DataView(request.buffer);
  request[0] = 4; request[1] = 8; request[2] = 1;
  data.setUint32(8, source.length, true); data.setUint32(12, 3, true); data.setUint32(16, 3, true);
  request.set(source, 40);
  const movement = exports.native_text_policy!(request.subarray(0, 40 + source.length));
  assert.equal(movement.length, 24); // zero-capacity navigation borrows the original text
  assert.deepEqual(Array.from(new Uint32Array(movement.buffer)), [3, 4, 4, 0, 0, 0]);
  request[1] = 0; data.setUint32(12, 0, true); data.setUint32(16, 2, true); request.set(inserted, 40 + source.length);
  data.setUint32(36, 6, true);
  assert.deepEqual(Array.from(exports.native_text_policy!(request)), [0, 0, 0, 0]);
  data.setUint32(36, 7, true);
  const replacement = exports.native_text_policy!(request);
  assert.deepEqual(Array.from(new Uint32Array(replacement.buffer, 0, 6)), [1, 4, 4, 0, 0, 0]);
  assert.equal(new TextDecoder().decode(replacement.subarray(24)), "🙂\r\nx");
  request[1] = 13; assert.throws(() => exports.native_text_policy!(request), /invalid text reducer request/);
  request[1] = 0; data.setUint32(8, 512 * 1024 + 1, true);
  assert.throws(() => exports.native_text_policy!(request), /invalid text reducer budget/);
});

test("text rebuild policy distinguishes replacements, echoes and exact 64-bit selections", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const request = new Uint8Array(40), data = new DataView(request.buffer);
  request[0] = 5; request[1] = 1; // unchanged uncontrolled source
  const policy = () => Array.from(exports.native_text_policy!(request));
  assert.deepEqual(policy(), [7]);
  request[1] = 0; assert.deepEqual(policy(), [0]); // replacement
  request[2] = 1; assert.deepEqual(policy(), [6]); // source echoes local bytes
  request[4] = 1; request[5] = 3;
  data.setBigUint64(8, 9007199254740992n, true); data.setBigUint64(24, 9007199254740992n, true);
  data.setBigUint64(16, 2n, true); data.setBigUint64(32, 2n, true);
  assert.deepEqual(policy(), [10]); // legacy offsets-only selection echo
  data.setBigUint64(24, 9007199254740993n, true); assert.deepEqual(policy(), [2]);
  data.setBigUint64(24, 9007199254740992n, true);
  request[4] = 5; assert.deepEqual(policy(), [2]); // first explicit downstream
  request[6] = 3; assert.deepEqual(policy(), [10]); // unchanged source affinity
  request[4] = 1; assert.deepEqual(policy(), [2]); // explicit upstream change
  request[4] = 2; assert.deepEqual(policy(), [2]); // source composition without selection
  request[3] = 1; assert.throws(policy, /invalid text reconcile request/);
  request[3] = 0; request[6] = 4; assert.throws(policy, /invalid text reconcile request/);
  assert.throws(() => exports.native_text_policy!(request.subarray(0, 39)), /invalid text reconcile request/);
});

test("compiled text input prepares composition and sanitizes before UTF-8 paste limits", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<input/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const prepare = (text: string, mode: number, singleLine: boolean, available = 0, cursor: number | null = null) => {
    const bytes = new TextEncoder().encode(text), request = new Uint8Array(16 + bytes.length), data = new DataView(request.buffer);
    request.set([6, mode, singleLine ? 1 : 0, cursor === null ? 0 : 1]);
    data.setUint32(4, cursor === null ? 0 : cursor, true); data.setUint32(8, available, true); request.set(bytes, 16);
    const result = exports.native_text_policy!(request), header = new DataView(result.buffer, result.byteOffset, result.byteLength);
    const flags = header.getUint32(0, true), length = header.getUint32(8, true);
    return { flags, cursor: header.getUint32(4, true), text: Array.from(flags & 2 ? bytes.subarray(0, length) : result.subarray(12)) };
  };
  const bytes = (s: string) => Array.from(new TextEncoder().encode(s));
  assert.deepEqual(prepare("a\r\nbc", 2, true, 3), { flags: 1, cursor: 0, text: bytes("abc") });
  assert.deepEqual(prepare("a\r\nbc", 2, false, 3), { flags: 11, cursor: 0, text: bytes("a\r\n") });
  assert.deepEqual(prepare("a\né🙂", 2, true, 4), { flags: 9, cursor: 0, text: bytes("aé") });
  assert.deepEqual(prepare("é🙂", 2, true, 3), { flags: 11, cursor: 0, text: bytes("é") });
  assert.deepEqual(prepare("\r\n", 2, true, 0), { flags: 0, cursor: 0, text: [] });
  assert.deepEqual(prepare("", 0, true), { flags: 3, cursor: 0, text: [] });
  assert.deepEqual(prepare("a\r\né", 1, true, 0, 3), { flags: 5, cursor: 1, text: bytes("aé") });
  assert.deepEqual(prepare("\r\n", 1, true), { flags: 1, cursor: 0, text: [] });
  assert.throws(() => prepare("x", 2, true, 512 * 1024 + 1), /invalid text input arguments/);
  assert.throws(() => prepare("x", 0, true, 0, 1), /invalid text input arguments/);
});

test("history replay preserves minimal edits, stale refusal and exact selection witnesses", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const request = new Uint8Array(70), data = new DataView(request.buffer);
  request[0] = 7; request[3] = 2;
  const selection = (at: number, anchor: bigint, focus = anchor) => {
    data.setBigUint64(at, anchor, true); data.setBigUint64(at + 8, focus, true);
  };
  data.setUint32(56, 1, true); data.setUint32(64, 2, true); request.set(new TextEncoder().encode("é"), 68);
  selection(8, 3n); selection(24, 1n); selection(40, 3n);
  const policy = () => exports.native_text_policy!(request);
  assert.equal(policy()[0], 4); // Undo one UTF-8 codepoint via Backspace.
  request[4] = 1; assert.equal(policy()[0], 4); // The fast path ignores current affinity.
  request[4] = 2; let result = policy(); assert.equal(result[0], 6);
  assert.equal(new DataView(result.buffer).getBigUint64(16, true), 3n);
  request[4] = 0; request[2] = 1; request[3] = 1; selection(8, 1n);
  assert.equal(policy()[0], 3); // Redo borrows the inserted bytes.
  request[1] = 1; request[3] = 2; selection(40, 0xfffffffffffffff0n, 0xfffffffffffffff1n);
  result = policy(); assert.equal(result[0], 6);
  assert.equal(new DataView(result.buffer).getBigUint64(8, true), 0xfffffffffffffff0n);
  assert.equal(new DataView(result.buffer).getBigUint64(16, true), 0xfffffffffffffff1n);
  selection(8, 0xfffffffffffffff0n, 0xfffffffffffffff1n); assert.equal(policy()[0], 2);
  request[1] = 2; assert.equal(policy()[0], 2);
  request[4] = 4; assert.equal(policy()[0], 0); // Affinity is part of completion.
  request[4] = 5; assert.equal(policy()[0], 2);
  request[1] = 1; request[3] = 0; assert.equal(policy()[0], 1);
  request[1] = 2; assert.equal(policy()[0], 0); // A refused edit never commits.
  request[5] = 1; assert.throws(policy, /invalid text history request/);
  request[5] = 0; data.setUint32(64, 524289, true); assert.throws(policy, /invalid text history budget/);
});

test("history deltas keep complete UTF-8 and CRLF context, including empty preedit", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const delta = (before: string, after: string, range?: [number, number, number]) => {
    const a = new TextEncoder().encode(before), b = new TextEncoder().encode(after);
    const request = new Uint8Array(24 + a.length + b.length), data = new DataView(request.buffer);
    request[0] = 8; request[1] = range ? 1 : 0; request[2] = range ? 1 : 0;
    data.setUint32(4, a.length, true); data.setUint32(8, b.length, true);
    if (range) range.forEach((offset, i) => data.setUint32(12 + i * 4, offset, true));
    request.set(a, 24); request.set(b, 24 + a.length);
    return Array.from(new Uint32Array(exports.native_text_policy!(request).buffer));
  };
  assert.deepEqual(delta("aéz", "aêz"), [1, 1, 3, 3]); // shared UTF-8 lead
  assert.deepEqual(delta("aéz", "aĩz"), [1, 1, 3, 3]); // shared continuation suffix
  assert.deepEqual(delta("a\rz", "a\r\nz"), [1, 1, 2, 3]);
  assert.deepEqual(delta("a\nz", "a\r\nz"), [1, 1, 2, 3]);
  assert.deepEqual(delta("same", "same"), [0, 0, 0, 0]);
  assert.deepEqual(delta("a\r\nz", "a\r\nz", [1, 1, 1]), [1, 1, 1, 1]);
  assert.deepEqual(delta("a\rz", "a\rz", [2, 2, 2]), [1, 1, 2, 2]);
  assert.deepEqual(delta("a\nz", "a\nz", [1, 1, 1]), [1, 1, 2, 2]);
  assert.throws(() => delta("a", "b", [1, 0, 0]), /invalid text history composition range/);
  const invalid = new Uint8Array(24); invalid[0] = 8; invalid[3] = 1;
  assert.throws(() => exports.native_text_policy!(invalid), /invalid text history delta request/);
  invalid[3] = 0; new DataView(invalid.buffer).setUint32(4, 524289, true);
  assert.throws(() => exports.native_text_policy!(invalid), /invalid text history delta budget/);
});

test("composition history keeps active no-ops and finalizes within the shared byte budget", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const request = new Uint8Array(24), data = new DataView(request.buffer);
  request[0] = 9;
  const plan = (active: boolean, matches: boolean, args: number[]) => {
    request[1] = active ? 1 : 0; request[2] = matches ? 1 : 0;
    args.forEach((value, i) => data.setUint32(4 + i * 4, value, true));
    return Array.from(new Uint32Array(exports.native_text_policy!(request).buffer));
  };
  // Preserve a prefix and suffix while previews grow, shrink and return to
  // the original bytes; matching active bytes still belong to the transaction.
  assert.deepEqual(plan(true, false, [1, 6, 8, 15, 32]), [1, 14, 13]);
  assert.deepEqual(plan(true, false, [1, 6, 8, 2, 32]), [1, 1, 0]);
  assert.deepEqual(plan(true, true, [1, 6, 8, 8, 32]), [1, 7, 6]);
  assert.deepEqual(plan(false, true, [1, 6, 8, 8, 32]), [2, 7, 6]);
  assert.deepEqual(plan(false, false, [1, 6, 8, 8, 32]), [3, 7, 6]); // same length, different hash
  assert.deepEqual(plan(false, true, [1, 6, 8, 9, 32]), [3, 8, 7]);
  assert.deepEqual(plan(true, false, [1, 6, 8, 15, 18]), [0, 0, 0]);
  assert.deepEqual(plan(true, false, [1, 8, 8, 15, 32]), [0, 0, 0]);
  assert.deepEqual(plan(true, false, [1, 6, 8, 1, 32]), [0, 0, 0]);
  assert.deepEqual(plan(true, false, [4294967295, 1, 8, 8, 32]), [0, 0, 0]);
  assert.deepEqual(plan(true, false, [0, 0, 0, 524288, 524288]), [1, 524288, 524288]);
  request[3] = 1;
  assert.throws(() => exports.native_text_policy!(request), /invalid text composition history request/);
  request[3] = 0; data.setUint32(20, 524289, true);
  assert.throws(() => exports.native_text_policy!(request), /invalid text composition history budget/);
});

test("history timelines select nearest editor boundaries and refuse stale forks", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<textarea/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  // Bits: target, kind, applied, provisional, before matches, after matches.
  const plan = (entries: number[]) => {
    const request = new Uint8Array(8 + entries.length), data = new DataView(request.buffer);
    request[0] = 10; data.setUint32(4, entries.length, true); request.set(entries, 8);
    return Array.from(new Uint32Array(exports.native_text_policy!(request).buffer));
  };
  assert.deepEqual(plan([]), [1, 0, 0]);
  assert.deepEqual(plan([63 & ~1]), [1, 0, 0]); // unrelated editor
  assert.deepEqual(plan([7 | 32, 3 | 16]), [7, 1, 2]);
  assert.deepEqual(plan([7 | 32, 7, 3 | 16]), [4, 2, 3]); // nearest Undo is stale
  assert.deepEqual(plan([3, 3 | 16]), [0, 0, 1]); // earliest Redo wins
  assert.deepEqual(plan([7 | 32, 1, 3 | 16]), [6, 1, 3]); // wrong kind retires timeline
  assert.deepEqual(plan([7 | 32, 3 | 8 | 16, 3 | 16]), [6, 1, 3]); // provisional excluded
  assert.deepEqual(plan([7 | 32, 3]), [3, 1, 2]); // applied boundary owns fork matching
  const full = Array<number>(128).fill(7 | 32); full[60] = 3 | 16;
  assert.deepEqual(plan(full), [7, 128, 61]);
  const invalid = new Uint8Array(8); invalid[0] = 10; invalid[1] = 1;
  assert.throws(() => exports.native_text_policy!(invalid), /invalid text history timeline request/);
  invalid[1] = 0; new DataView(invalid.buffer).setUint32(4, 129, true);
  assert.throws(() => exports.native_text_policy!(invalid), /invalid text history timeline count/);
  assert.throws(() => plan([64]), /invalid text history timeline entry/);
});


test("shared keyboard controls validate requests across every specialized callback", () => {
  const exports: Record<string, (request: Uint8Array) => Uint8Array> = {};
  runInNewContext(ts.transpile(compileView('<button on-press="increment">Go</button>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  for (const name of ["text", "radio", "tabs", "tree", "list", "menu", "toggle", "accordion", "slider", "split", "resizable", "scroll"]) {
    const policy = exports[`native_${name}_policy`]!;
    const intent = (kind: number, key: number, flags = 0, expanded = 0) => [...policy(Uint8Array.of(15, kind, key, flags, expanded))];
    assert.deepEqual(intent(1, 1), [1, 1]);
    assert.deepEqual(intent(0, 2, 48), [1, 1]);
    assert.deepEqual(intent(0, 2, 16), [0, 0]);
    assert.deepEqual(intent(9, 2), [2, 2]);
    assert.deepEqual(intent(12, 1), [3, 4]);
    assert.deepEqual(intent(12, 1, 8), [3, 5]);
    assert.deepEqual(intent(3, 4), [1, 1]);
    assert.deepEqual(intent(4, 3, 0, 2), [0, 0]);
    assert.deepEqual(intent(1, 1, 1), [3, 4]);
    assert.deepEqual(intent(1, 5, 1, 2), [2, 2]);
    assert.deepEqual(intent(1, 6, 3, 1), [3, 4]);
    assert.deepEqual(intent(10, 7, 4), [3, 4]);
    assert.deepEqual(intent(10, 7), [0, 0]);
    assert.deepEqual(intent(15, 1, 48), [4, 0]);
    assert.deepEqual(intent(17, 1, 48), [0, 0]);
    assert.deepEqual(intent(17, 1, 64), [4, 0]);
    for (const request of [[15], [15, 0, 0, 0, 0, 0], [15, 22, 0, 0, 0], [15, 0, 9, 0, 0], [15, 0, 0, 128, 0], [15, 0, 0, 0, 3]])
      assert.throws(() => policy(new Uint8Array(request)), /keyboard control request/);
  }
});

test("shared semantic controls preserve grants and selectable press precedence", () => {
  const exports: Record<string, (request: Uint8Array) => Uint8Array> = {};
  runInNewContext(ts.transpile(compileView('<button on-press="increment">Go</button>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  for (const name of ["text", "radio", "tabs", "tree", "list", "menu", "toggle", "accordion", "slider", "split", "resizable", "scroll"]) {
    const policy = exports[`native_${name}_policy`]!;
    const intent = (kind: number, action: number, grants: number, tree = 0) => [...policy(Uint8Array.of(16, kind, action, grants, tree))];
    assert.deepEqual(intent(1, 0, 1), [1, 1]);
    assert.deepEqual(intent(6, 0, 2), [0, 0]);
    assert.deepEqual(intent(6, 1, 2), [2, 2]);
    assert.deepEqual(intent(12, 0, 5), [3, 5]);
    assert.deepEqual(intent(12, 0, 1), [1, 1]);
    assert.deepEqual(intent(0, 0, 5, 1), [3, 5]);
    assert.deepEqual(intent(0, 0, 5), [1, 1]);
    assert.deepEqual(intent(10, 2, 4), [3, 4]);
    assert.deepEqual(intent(10, 2, 5), [3, 5]);
    assert.deepEqual(intent(10, 2, 1), [0, 0]);
    assert.deepEqual(intent(15, 3, 8), [4, 0]);
    assert.deepEqual(intent(17, 4, 16), [4, 0]);
    assert.deepEqual(intent(16, 3, 8), [0, 0]);
    assert.deepEqual(intent(15, 3, 16), [0, 0]);
    for (const request of [[16], [16, 0, 0, 0, 0, 0], [16, 22, 0, 0, 0], [16, 0, 5, 0, 0], [16, 0, 0, 32, 0], [16, 0, 0, 0, 2]])
      assert.throws(() => policy(new Uint8Array(request)), /semantic control request/);
  }
});

test("semantic action derivation keeps defaults, authored actions and focusability distinct", () => {
  const exports: Record<string, (request: Uint8Array) => Uint8Array> = {};
  runInNewContext(ts.transpile(compileView('<button on-press="increment">Go</button>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  for (const name of ["text", "radio", "tabs", "tree", "list", "menu", "toggle", "accordion", "slider", "split", "resizable", "scroll"]) {
    const policy = exports[`native_${name}_policy`]!;
    const actions = (kind: number, flags = 0, authored = 0) => {
      const result = policy(new Uint8Array([17, kind, 0, flags, authored & 255, authored >>> 8]));
      return [result[0]! | result[1]! << 8, result[2]! | result[3]! << 8, result[4]];
    };
    assert.deepEqual(actions(0), [0, 0, 0]);
    assert.deepEqual(actions(0, 8, 2), [3, 1, 0]); // authored focusable, default not focusable
    assert.deepEqual(actions(0, 4 | 16), [131, 131, 1]); // any tree row
    assert.deepEqual(actions(31), [3, 3, 1]);
    assert.deepEqual(actions(48), [129, 129, 1]);
    assert.deepEqual(actions(48, 16), [131, 131, 1]);
    assert.deepEqual(actions(38, 2), [67, 99, 1]); // read-only retains selection and press
    assert.deepEqual(actions(16), [256, 256, 0]);
    assert.deepEqual(actions(58), [281, 281, 1]);
    assert.deepEqual(actions(62), [1, 1, 1]); // terminal is focusable without text actions
    assert.deepEqual(actions(40), [1024, 1024, 0]);
    assert.deepEqual(actions(0, 0, 2047), [2047, 0, 0]);
    assert.deepEqual(actions(0, 2, 2047), [2015, 0, 0]);
    assert.deepEqual(actions(38, 31, 2047), [0, 0, 0]);
    for (const request of [[17], [17, 0, 0, 0, 0], [17, 0, 0, 0, 0, 0, 0],
      [17, 63, 0, 0, 0, 0], [17, 0, 1, 0, 0, 0], [17, 0, 0, 32, 0, 0], [17, 0, 0, 0, 0, 8]])
      assert.throws(() => policy(new Uint8Array(request)), /semantic actions request/);
  }
});

test("shared step intents preserve raw boundary actions, axis facts and callback ownership", () => {
  const exports: Record<string, (request: Uint8Array) => Uint8Array> = {};
  runInNewContext(ts.transpile(compileView('<button on-press="increment">Go</button>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder });
  const line = (extent: number) => Math.max(24, Math.fround(Math.fround(extent) * Math.fround(0.35)));
  const page = (extent: number) => Math.max(line(extent), Math.fround(Math.fround(extent) * Math.fround(0.85)));
  for (const name of ["text", "radio", "tabs", "tree", "list", "menu", "toggle", "accordion", "slider", "split", "resizable", "scroll"]) {
    const policy = exports[`native_${name}_policy`]!;
    const intent = (kind: number, mode: number, key: number, flags = 0, value = 0.95) => {
      const request = new Uint8Array(17), args = new DataView(request.buffer);
      request.set([18, kind, mode, key, flags]);
      args.setFloat32(5, value, true); args.setFloat32(9, 333.3, true); args.setFloat32(13, 155.5, true);
      const before = request.slice(), result = policy(request), out = new DataView(result.buffer, result.byteOffset, result.byteLength);
      assert.deepEqual(request, before);
      assert.equal(result.length, 16); assert.equal(result[2], 0); assert.equal(result[3], 0);
      return [result[0], result[1], out.getFloat32(4, true), out.getFloat32(8, true), out.getFloat32(12, true)];
    };
    assert.deepEqual(intent(15, 0, 6, 1, 1), [1, 1, 1, 0, 0]); // raw step advertises increment at the clamp
    assert.deepEqual(intent(15, 0, 7, 0, 0), [1, 0, 0, 0, 0]);
    assert.deepEqual(intent(15, 1, 0, 0, 1), [1, 1, 1, 0, 0]);
    assert.deepEqual(intent(15, 2, 0, 0, 0), [1, 2, 0, 0, 0]);
    assert.deepEqual(intent(16, 0, 3), [0, 0, 0, 0, 0]); // split leaves vertical arrows to focus routing
    assert.deepEqual(intent(16, 1, 0), [0, 0, 0, 0, 0]);
    assert.deepEqual(intent(18, 0, 6, 4), [2, 1, 0, line(333.3), 0]);
    assert.deepEqual(intent(18, 0, 6, 6), [2, 1, 0, 0, line(155.5)]); // virtualized regions stay vertical
    assert.deepEqual(intent(18, 0, 5, 8), [2, 2, 0, -line(333.3), 0]);
    assert.deepEqual(intent(18, 0, 10, 8), [2, 1, 0, 0, page(155.5)]);
    assert.deepEqual(intent(18, 1, 0, 24), [2, 1, 0, page(333.3), 0]);
    assert.deepEqual(intent(18, 1, 0, 26), [2, 1, 0, 0, page(155.5)]);
    assert.deepEqual(intent(19, 1, 0, 24), [2, 1, 0, 0, page(155.5)]);
    assert.deepEqual(intent(0, 3, 9, 4), [2, 2, 0, 0, -page(155.5)]); // public scroll helper on any widget
    assert.deepEqual(intent(18, 0, 7), [3, 2, 0, 0, 0]);
    assert.deepEqual(intent(18, 0, 8), [4, 1, 0, 0, 0]);
    assert.deepEqual(intent(18, 0, 1), [0, 0, 0, 0, 0]);
    const retained = policy(new Uint8Array([18, 18, 0, 7, 0, ...new Uint8Array(12)]));
    intent(15, 0, 6); assert.deepEqual([...retained], [3, 2, ...new Uint8Array(14)]);
    for (const request of [new Uint8Array([18]), new Uint8Array(16).fill(18), new Uint8Array(18).fill(18),
      new Uint8Array([18, 22, 0, 0, 0, ...new Uint8Array(12)]), new Uint8Array([18, 0, 4, 0, 0, ...new Uint8Array(12)]),
      new Uint8Array([18, 0, 0, 11, 0, ...new Uint8Array(12)]), new Uint8Array([18, 0, 0, 0, 32, ...new Uint8Array(12)]),
      new Uint8Array([18, 0, 0, 0, 12, ...new Uint8Array(12)])])
      assert.throws(() => policy(request), /step control request/);
  }
});


test("focus return preserves immediate anchors, old-tree ancestry and null shielding", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!, none = 65535;
  type Node = { flags: number; parent: number };
  const request = (nodes: Node[], subject: number, mode: number) => {
    const bytes = new Uint8Array(6 + nodes.length * 3), data = new DataView(bytes.buffer);
    bytes[0] = 22; bytes[1] = mode; data.setUint16(2, nodes.length, true); data.setUint16(4, subject, true);
    nodes.forEach((n, i) => { const at = 6 + i * 3; bytes[at] = n.flags; data.setUint16(at + 1, n.parent, true); });
    return bytes;
  };
  const reference = (nodes: Node[], subject: number, mode: number) => {
    let surface = subject;
    if (mode === 1 && subject !== none) {
      surface = nodes[subject]!.parent;
      while (surface !== none && (nodes[surface]!.flags & 6) !== 6) surface = nodes[surface]!.parent;
    }
    if (surface === none || !(nodes[surface]!.flags & 2)) return none;
    const anchor = nodes[surface]!.parent;
    if (anchor === none) return none;
    if (nodes[anchor]!.flags & 1) return anchor;
    const child = nodes.findIndex((n, i) => i !== surface && n.parent === anchor && !!(n.flags & 1));
    return child < 0 ? none : child;
  };
  const compare = (nodes: Node[], subject: number, mode: number) => {
    const result = policy(request(nodes, subject, mode)); assert.equal(result.length, 2);
    const actual = new DataView(result.buffer, result.byteOffset, result.byteLength).getUint16(0, true);
    assert.equal(actual, reference(nodes, subject, mode)); return actual;
  };
  const rows = [{flags:0,parent:none},{flags:1,parent:0},{flags:6,parent:0},{flags:1,parent:2},{flags:1,parent:0}];
  assert.equal(compare(rows, 2, 0), 1); assert.equal(compare(rows, 3, 1), 1);
  assert.equal(compare([{flags:1,parent:none},...rows.slice(1)],2,0),0);
  // A focusable grandchild is not an immediate sibling fallback.
  assert.equal(compare([{flags:0,parent:none},{flags:0,parent:0},{flags:1,parent:1},{flags:6,parent:0},{flags:1,parent:3}],4,1),none);
  // The nearest anchored dismissible surface shields an outer return target.
  assert.equal(compare([{flags:1,parent:none},{flags:6,parent:0},{flags:0,parent:1},{flags:6,parent:2},{flags:1,parent:3}],4,1),none);
  for (let variant = 0; variant < 128; variant++) {
    const nodes: Node[] = [];
    for (let i = 0; i < 32; i++) nodes.push({flags:(variant * 3 + i * 5) & 7,parent:i===0 ? none : (variant * 7 + i * 3) % i});
    for (let subject = 0; subject < nodes.length; subject++) for (const mode of [0,1]) compare(nodes,subject,mode);
    compare(nodes,none,0); compare(nodes,none,1);
  }
  compare([],none,0);
  compare(Array.from({length:1024},(_,i)=>({flags: i===0 ? 1 : 6,parent:i===0 ? none : i-1})),1023,1);
  const valid=request(rows,3,1), copied=policy(valid); policy(request([],none,0)); assert.deepEqual([...copied],[...policy(valid)]);
  for (let length=0;length<valid.length;length++) assert.throws(()=>policy(valid.subarray(0,length)),/policy|focus return/);
  for (const mutate of [
    (b:Uint8Array)=>{b[1]=2;},(b:Uint8Array)=>{b[2]=1;b[3]=4;},(b:Uint8Array)=>{b[4]=32;},
    (b:Uint8Array)=>{b[6]=8;},(b:Uint8Array)=>{b[7]=0;b[8]=0;},(b:Uint8Array)=>{b[10]=1;b[11]=0;},
  ]) {const bad=valid.slice();mutate(bad);assert.throws(()=>policy(bad),/focus return/);}
  assert.throws(()=>policy(new Uint8Array([...valid,0])),/focus return/);
});

test("surface scopes preserve shielding, visibility, paint order and menu ownership", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!, none = 65535;
  type Node = { flags: number; parent: number; layer: number };
  const node = (flags: number, parent = none, layer = 0): Node => ({ flags, parent, layer });
  const request = (nodes: Node[], scope: number) => {
    const bytes = new Uint8Array(4 + nodes.length * 7), data = new DataView(bytes.buffer);
    bytes[0] = 21; bytes[1] = scope; data.setUint16(2, nodes.length, true);
    nodes.forEach((n, i) => { const at = 4 + i * 7; bytes[at] = n.flags; data.setUint16(at + 1, n.parent, true); data.setInt32(at + 3, n.layer, true); });
    return bytes;
  };
  // Independent reference follows the native per-query walks/scans.
  const reference = (nodes: Node[], scope: number): number[] => {
    const inScope = (i: number) => { const kind = nodes[i]!.flags & 3; return kind !== 0 && (scope === 0 || scope === 1 && kind !== 3 || scope === 2 && kind === 2); };
    const top = (indices: number[]) => indices.reduce((a, b) => a === none || nodes[a]!.layer < nodes[b]!.layer || nodes[a]!.layer === nodes[b]!.layer && a < b ? b : a, none);
    const indices = nodes.map((_, i) => i);
    const child = (anchor: number) => top(indices.filter(i => nodes[i]!.parent === anchor && (nodes[i]!.flags & 12) === 8 && inScope(i)));
    const hidden = (i: number) => { for (let at = i; at !== none; at = nodes[at]!.parent) if (nodes[at]!.flags & 4) return true; return false; };
    const target = (i: number) => {
      for (let at = i; at !== none; at = nodes[at]!.parent) {
        const bits = nodes[at]!.flags;
        if ((bits & 3) !== 0 && (bits & 4) === 0) return inScope(at) ? at : none;
        const owned = child(at); if (owned !== none) return owned;
      }
      return none;
    };
    return [top(indices.filter(i => (nodes[i]!.flags & 8) !== 0 && inScope(i) && !hidden(i))), ...indices.flatMap(i => {
      const direct = child(i), sibling = nodes[i]!.parent === none ? none : child(nodes[i]!.parent);
      return [direct, target(i), scope !== 2 ? none : direct !== none ? direct : sibling === i ? none : sibling];
    })];
  };
  const compare = (nodes: Node[], scope: number) => {
    const result = policy(request(nodes, scope));
    assert.equal(result.length, 2 + nodes.length * 6);
    const data = new DataView(result.buffer, result.byteOffset, result.byteLength);
    assert.deepEqual(Array.from({ length: result.length / 2 }, (_, i) => data.getUint16(i * 2, true)), reference(nodes, scope));
    return result;
  };
  const coexist = [node(0), node(0, 0), node(10, 0, -2147483648), node(11, 0, 2147483647), node(1, 0), node(0, 4)];
  for (const scope of [0, 1, 2]) compare(coexist, scope);
  assert.equal(new DataView(compare(coexist, 2).buffer).getUint16(2 + 5 * 6 + 2, true), none); // Popover shields outer menu.
  const concealed = [node(4), node(10, 0), node(11, 0)];
  assert.equal(new DataView(compare(concealed, 2).buffer).getUint16(0, true), none);
  assert.equal(new DataView(compare(concealed, 2).buffer).getUint16(2, true), 1); // Child lookup checks its own visibility.
  for (let variant = 0; variant < 192; variant++) {
    const nodes: Node[] = [node(variant & 4)];
    for (let i = 1; i < 32; i++) nodes.push(node((variant * 13 + i * 7) & 15, (variant * 5 + i * 3) % i, [0, -1, 1, -2147483648, 2147483647][(variant + i) % 5]!));
    for (const scope of [0, 1, 2]) compare(nodes, scope);
  }
  compare([], 0);
  compare(Array.from({ length: 1024 }, (_, i) => node(10, i === 0 ? none : i - 1, i)), 2);
  const valid = request(coexist, 0), copied = policy(valid);
  compare(concealed, 2); assert.deepEqual([...copied], [...policy(valid)]);
  for (let length = 0; length < valid.length; length++) assert.throws(() => policy(valid.subarray(0, length)), /policy|surface scope/);
  for (const mutate of [
    (b: Uint8Array) => { b[1] = 3; },
    (b: Uint8Array) => { b[2] = 1; b[3] = 4; },
    (b: Uint8Array) => { b[4] = 16; },
    (b: Uint8Array) => { b[5] = 0; b[6] = 0; },
    (b: Uint8Array) => { b[12] = 1; b[13] = 0; },
  ]) { const bad = valid.slice(); mutate(bad); assert.throws(() => policy(bad), /surface scope/); }
  assert.throws(() => policy(new Uint8Array([...valid, 0])), /surface scope/);
});

test("Tab traversal preserves wrapping, nested radio stops, logical entries and scope traps", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const none = 65535;
  type Node = { flags: number; parent: number; depth: number; surface: number };
  const node = (flags: number, parent = none, depth = 0, surface = none): Node => ({ flags, parent, depth, surface });
  const request = (nodes: Node[], current = none, backward = false) => {
    const bytes = new Uint8Array(6 + nodes.length * 7), data = new DataView(bytes.buffer);
    bytes[0] = 20; bytes[1] = +backward; data.setUint16(2, nodes.length, true); data.setUint16(4, current, true);
    nodes.forEach((n, i) => { const at = 6 + i * 7; bytes[at] = n.flags; data.setUint16(at + 1, n.depth, true); data.setUint16(at + 3, n.parent, true); data.setUint16(at + 5, n.surface, true); });
    return bytes;
  };
  const choose = (nodes: Node[], current = none, backward = false) => new DataView(policy(request(nodes, current, backward)).buffer).getUint16(0, true);
  const flat = [node(3), node(0), node(3)];
  assert.equal(choose(flat), 0); assert.equal(choose(flat, none, true), 2);
  assert.equal(choose(flat, 0), 2); assert.equal(choose(flat, 2), 0); assert.equal(choose(flat, 0, true), 2);
  assert.equal(choose([node(3)], 0), none);
  assert.equal(choose([node(3, none, 0, 0)], 0), 0);
  assert.equal(choose([node(3, none, 0, 0)], 0, true), 0);
  assert.equal(choose([]), none);
  const full = Array.from({ length: 1024 }, () => node(3));
  assert.equal(choose(full, 1023), 0); assert.equal(choose(full, 0, true), 1023);

  // Outer entry is after the inner scope, but its authored stop stays first.
  const nested = [node(0), node(8, 0, 1), node(7, 1, 2), node(8, 1, 2), node(23, 3, 3), node(23, 1, 2), node(3, 0, 1)];
  assert.equal(choose(nested), 5); assert.equal(choose(nested, 5), 4);
  assert.equal(choose(nested, 4), 6); assert.equal(choose(nested, 6, true), 4);
  assert.equal(choose(nested, 4, true), 5);
  nested[5]!.flags = 22; // Selected entry is logical but clipped.
  assert.equal(choose(nested), 5); assert.equal(choose(nested, 5), 4);
  nested[5]!.flags = 20; // Selected entry is disabled: use the first logical radio.
  assert.equal(choose(nested), 2);
  nested[2]!.flags = 6; // No visible outer stop: skip it, keep the inner group.
  assert.equal(choose(nested), 4);

  const trapped = [node(0), node(0, 0, 1, 1), node(8, 1, 2, 1), node(7, 2, 3, 1), node(23, 2, 3, 1)];
  assert.equal(choose(trapped, 4), 4); assert.equal(choose(trapped, 4, true), 4);
  const owned = policy(request(flat));
  policy(request(nested)); assert.deepEqual([...owned], [0, 0]);
  const valid = request(nested);
  for (let n = 0; n < valid.length; n++) assert.throws(() => policy(valid.subarray(0, n)), /policy|Tab focus/);
  for (const mutation of [
    (b: Uint8Array) => { b[1] = 2; },
    (b: Uint8Array) => { b[2] = 1; b[3] = 4; },
    (b: Uint8Array) => { b[4] = 254; b[5] = 0; },
    (b: Uint8Array) => { b[6] = 32; },
    (b: Uint8Array) => { b[6] = 12; },
    (b: Uint8Array) => { b[9] = 0; b[10] = 0; },
    (b: Uint8Array) => { b[11] = 254; b[12] = 0; },
  ]) { const bad = valid.slice(); mutation(bad); assert.throws(() => policy(bad), /Tab focus/); }
  assert.throws(() => policy(new Uint8Array([...valid, 0])), /Tab focus/);
});

test("tooltip bindings preserve last-mounted ownership, hidden-independent discovery and granted survival", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<stack><button/><tooltip anchor="above">Hint</tooltip></stack>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const query = (nodes: readonly (readonly [number, number])[], owner: number, tooltip = 65535, mode = 0, eligibility = 0): number => {
    const wire = new Uint8Array(9 + nodes.length * 3);
    wire.set([23, mode, nodes.length & 255, nodes.length >>> 8, owner & 255, owner >>> 8, tooltip & 255, tooltip >>> 8, eligibility]);
    nodes.forEach(([anchored, parent], i) => wire.set([anchored, parent & 255, parent >>> 8], 9 + i * 3));
    const result = policy(wire); assert.equal(result.length, 2);
    return result[0]! | result[1]! << 8;
  };
  const nodes: readonly (readonly [number, number])[] = [[0, 65535], [0, 0], [1, 0], [1, 0], [0, 1], [1, 1], [0, 0]];
  assert.equal(query(nodes, 1), 5); // Direct child wins over later sibling.
  assert.equal(query(nodes, 4), 5); // Fallback to parent's child.
  assert.equal(query(nodes, 6), 3); // Last mounted, independent of paint order or hidden stamps.
  assert.equal(query(nodes, 3), 3); // Tooltip subjects preserve the native self-binding fallback.
  assert.equal(query(nodes, 1, 3, 1, 3), 65535); // A displaced tooltip loses its binding.
  assert.equal(query(nodes, 1, 5, 1, 1), 5);
  assert.equal(query(nodes, 1, 5, 2, 1), 65535);
  assert.equal(query(nodes, 1, 5, 2, 2), 5);
  assert.equal(query(nodes, 1, 5, 1, 2), 65535);
  assert.equal(query(nodes, 1, 4, 1, 3), 65535);
  assert.equal(query(nodes, 65535), 65535);
  assert.equal(query([], 65535), 65535);
  const capacity = Array.from({ length: 1024 }, (_, i) => [i === 1023 ? 1 : 0, i === 0 ? 65535 : 0] as const);
  assert.equal(query(capacity, 1), 1023);
  assert.throws(() => query([...capacity, [0, 0]], 1), /tooltip binding table/);
  for (const wire of [[23], [23, 3, 0, 0, 255, 255, 255, 255, 0], [23, 0, 0, 0, 0, 0, 255, 255, 0],
    [23, 0, 0, 0, 255, 255, 0, 0, 0], [23, 0, 0, 0, 255, 255, 255, 255, 4],
    [23, 0, 1, 0, 0, 0, 255, 255, 0, 2, 255, 255],
    [23, 0, 1, 0, 0, 0, 255, 255, 0, 1, 0, 0],
    [23, 0, 1, 0, 0, 0, 255, 255, 0]])
    assert.throws(() => policy(new Uint8Array(wire)), /tooltip binding/);
});

test("compiled tooltips retain anchored delay overrides and static visibility", () => {
  const { model, view } = evaluate('<stack><button>Run</button><tooltip key="hint" anchor="above" anchor-alignment="end" anchor-offset="8" tooltip-delay="{count}">Hint {count}</tooltip><tooltip>Static hint</tooltip></stack>');
  assert.deepEqual(view().nodes[2], { end: 3, kind: "tooltip", text: "Hint 7", key: "hint", anchor: "above", anchorAlignment: "end", anchorOffset: 8, tooltipDelay: 7 });
  assert.deepEqual(view().nodes[3], { end: 4, kind: "tooltip", text: "Static hint" });
  for (const value of [0, 2147483647]) { model.count = value; assert.equal(view().nodes[2].tooltipDelay, value); }
  for (const value of [-1, 1.5, 2147483648, NaN, Infinity]) {
    model.count = value; assert.throws(view, /tooltip delay/);
  }
  for (const source of ['<button tooltip-delay="0"/>', '<tooltip tooltip-delay="0"/>', '<tooltip anchor="above" tooltip-delay="-1"/>',
    '<tooltip anchor="above" tooltip-delay="1.5"/>', '<tooltip anchor="above" tooltip-delay="2147483648"/>',
    '<tooltip anchor="above" tooltip-delay="{stampedMs}"/>', '<tooltip><text>Mixed</text></tooltip>', '<badge anchor="above"/>'])
    assert.throws(() => compileView(source, contract), /compiled TypeScript view/);
  assert.equal(evaluate('<tooltip anchor="below" tooltip-delay="0">Instant</tooltip>').view().nodes[0].tooltipDelay, 0);
  assert.equal(evaluate('<tooltip anchor="below" tooltip-delay="007">Leading zero</tooltip>').view().nodes[0].tooltipDelay, 7);
  assert.equal(evaluate('<tooltip anchor="below">Default</tooltip>').view().nodes[0].tooltipDelay, undefined);
});

test("tooltip intent isolates keyboard holds, dismissal and pointer conversation resets", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<tooltip anchor="above">Hint</tooltip>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const intent = (cause: number, facts: number) => Array.from(policy(new Uint8Array([24, cause, facts])));
  assert.deepEqual(intent(0, 4 | 64), [4 | 16 | 64]); // Keyboard arrival.
  assert.deepEqual(intent(0, 1 | 4 | 8 | 16 | 64), [1 | 4 | 16]); // Pointer-to-focus handover, no repaint.
  assert.deepEqual(intent(0, 1 | 2 | 4), [2 | 64]); // Inactive reveal still releases old hold.
  assert.deepEqual(intent(0, 1 | 4), [0]); // Inactive focus leaves pointer-owned hint alone.
  assert.deepEqual(intent(1, 1 | 2), [1 | 2 | 8 | 16 | 64]);
  assert.deepEqual(intent(2, 4 | 16 | 32), [1 | 8 | 32]); // Armed-only activation spends standing intent.
  assert.deepEqual(intent(2, 1 | 2 | 4), [0]); // Unrelated activation.
  assert.deepEqual(intent(3, 1 | 2), [2 | 64]); // Programmatic focus releases keyboard hold only.
  assert.deepEqual(intent(3, 1), [0]);
  assert.deepEqual(intent(4, 0), [1 | 2 | 8 | 16]); // Blur resets even stale empty-slot registers.
  assert.deepEqual(intent(5, 1 | 2), [1 | 8 | 16]); // Pointer departure preserves keyboard hold.
  assert.deepEqual(intent(5, 1), [1 | 2 | 8 | 16 | 64]);
  assert.deepEqual(intent(6, 1 | 2 | 4 | 8 | 16 | 32), [1 | 2 | 16 | 32 | 64]); // Escape preserves warmth.
  assert.deepEqual(intent(6, 4 | 16 | 32), [1]); // Armed-only dismissal preserves keyboard provenance.
  assert.deepEqual(intent(6, 8 | 16 | 32), [1 | 2 | 16 | 32]); // Zero-ID dismissal clears stale slots.
  for (const bytes of [[24], [24, 0], [24, 0, 0, 0], [24, 7, 0], [24, 0, 128], [24, 255, 255]])
    assert.throws(() => policy(new Uint8Array(bytes)), /tooltip intent request/);
});


test("tooltip pointer policy preserves warmth boundaries, content holds and frame ordering", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<tooltip anchor="above">Hint</tooltip>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const action = (cause: number, facts: number) => Array.from(policy(new Uint8Array([25, cause, facts & 255, facts >> 8])));
  assert.deepEqual(action(0, 4 | 256), [8]); // Cold arrival arms.
  assert.deepEqual(action(0, 4 | 256 | 512), [4]); // Zero delay reveals.
  assert.deepEqual(action(0, 4 | 256 | 1024), [4]); // Earned warmth reveals.
  assert.deepEqual(action(0, 1 | 4 | 256 | 2048), [2 | 4]); // Sweep hides, then warm-shows.
  assert.deepEqual(action(0, 1 | 4 | 256 | 1024), [2 | 8]); // Zero warmth overwrites old warmth.
  assert.deepEqual(action(0, 1 | 2 | 4 | 256), [8]); // Focus hold survives until dwell promotion.
  assert.deepEqual(action(0, 1 | 4 | 64 | 256 | 512), [0]); // Content shields underlying trigger.
  assert.deepEqual(action(0, 1 | 128), [0]); // Honest transit holds on leave.
  assert.deepEqual(action(0, 1 | 4 | 128), [2]); // Other trigger ends transit, even inactive.
  assert.deepEqual(action(0, 16), [1]); // Departing armed target cancels dwell.
  assert.deepEqual(action(1, 0), [1]); // Empty stale slot clears transit.
  assert.deepEqual(action(1, 1 | 2 | 16), [1]); // Pointer never races keyboard hold.
  assert.deepEqual(action(1, 1 | 4 | 16), [1 | 2]); // Owner reseeds apex and clears grace.
  assert.deepEqual(action(1, 1 | 8 | 16), [1 | 2]); // Content reseeds apex.
  assert.deepEqual(action(1, 1 | 16), [4]); // Safe travel renews grace.
  assert.deepEqual(action(1, 1), [8]); // Motion away hides with warmth.
  assert.deepEqual(action(2, 2 | 8), [1]); // Suppression disarms before expiry.
  assert.deepEqual(action(2, 1 | 2 | 8), [2]); // Transit expiry commits before promotion.
  assert.deepEqual(action(2, 1 | 2 | 4 | 8), [0]); // Focus hold ignores transit deadline.
  assert.deepEqual(action(3, 1), [0]);
  assert.deepEqual(action(3, 3), [1]); // Exact deadline promotes.
  assert.deepEqual(action(4, 0), [0]); // Reconcile preserves stale empty slots.
  assert.deepEqual(action(4, 1 | 8), [1 | 2]); // Content holds without transit.
  assert.deepEqual(action(4, 1), [8]); // Moved content hides immediately.
  assert.deepEqual(action(4, 1 | 2), [0]); // Keyboard hold is untouched.
  for (const bytes of [[25], [25, 0, 0], [25, 0, 0, 0, 0], [25, 5, 0, 0],
    [25, 0, 0, 16], [25, 1, 32, 0], [25, 2, 16, 0], [25, 3, 4, 0], [25, 4, 16, 0]])
    assert.throws(() => policy(new Uint8Array(bytes)), /tooltip pointer/);
});


test("tooltip reconciliation selects fresh stages and rejects malformed facts", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<tooltip anchor="above">Hint</tooltip>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const action = (stage: number, facts: number) => Array.from(policy(new Uint8Array([26, stage, facts])));
  for (const stage of [0, 5]) {
    assert.deepEqual(action(stage, 0), [0]); assert.deepEqual(action(stage, 1), [1]);
  }
  for (let phase = 0; phase < 6; phase++) {
    assert.deepEqual(action(1, phase), [phase === 0 || phase === 2 ? 1 : 0]);
    assert.deepEqual(action(3, phase), [phase === 1 ? 1 : 0]);
  }
  for (let facts = 0; facts < 4; facts++) assert.deepEqual(action(11, facts), [facts === 0 ? 0 : 1]);
  assert.deepEqual(action(2, 5), [1]); // Release reprocesses only after travel hid the pointer tooltip.
  assert.deepEqual(action(2, 7), [0]); assert.deepEqual(action(2, 1), [0]);
  assert.deepEqual(action(4, 0), [0]); assert.deepEqual(action(4, 2), [2]);
  assert.deepEqual(action(4, 3), [1]); // Live wheel point wins over a stale stored position.
  assert.deepEqual(action(6, 1), [1]); assert.deepEqual(action(6, 6), [1]);
  assert.deepEqual(action(6, 2), [0]); assert.deepEqual(action(6, 4), [0]);
  for (const stage of [7, 8]) for (let facts = 0; facts < 4; facts++)
    assert.deepEqual(action(stage, facts), [facts === 3 ? 1 : 0]);
  for (let facts = 0; facts < 16; facts++) assert.deepEqual(action(9, facts), [facts === 15 ? 1 : 0]);
  assert.deepEqual(action(10, 3), [1]); assert.deepEqual(action(10, 5), [1]);
  assert.deepEqual(action(10, 13), [0]); assert.deepEqual(action(10, 11), [1]);
  assert.deepEqual(action(10, 2), [0]);
  for (const bytes of [[26], [26, 0], [26, 0, 0, 0], [26, 12, 0], [26, 0, 2],
    [26, 1, 6], [26, 3, 6], [26, 11, 4], [26, 2, 8], [26, 4, 4], [26, 6, 8], [26, 7, 4], [26, 8, 4], [26, 9, 16], [26, 10, 16]])
    assert.throws(() => policy(new Uint8Array(bytes)), /tooltip reconciliation/);
});

test("tooltip presentation preserves authored nodes and asymmetric stale slots", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<tooltip anchor="above">Hint</tooltip>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const request = new Uint8Array(20);
  request.set([27, 0, 16, 0]);
  for (let index = 0; index < 16; index++) request[4 + index] = index;
  assert.deepEqual(Array.from(policy(request)), [0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1]);
  assert.deepEqual(Array.from(policy(new Uint8Array([27, 0, 0, 0]))), []);
  for (const stage of [1, 2]) {
    for (const facts of [0, 2, 3]) assert.deepEqual(Array.from(policy(new Uint8Array([27, stage, facts]))), [0]);
  }
  assert.deepEqual(Array.from(policy(new Uint8Array([27, 1, 1]))), [5]); // Dead arm clears warmth, retaining transit.
  assert.deepEqual(Array.from(policy(new Uint8Array([27, 2, 1]))), [14]); // Dead shown slot retains any surviving arm.
  const full = new Uint8Array(1028);
  full.set([27, 0, 0, 4]); full.fill(15, 4);
  assert.deepEqual(Array.from(policy(full)), Array(1024).fill(1));
  for (const bytes of [[27], [27, 0], [27, 0, 0], [27, 3, 0], [27, 0, 1, 0],
    [27, 0, 0, 0, 0], [27, 0, 1, 4, 0], [27, 0, 1, 0, 16], [27, 1, 4], [27, 2, 4], [27, 1, 0, 0]])
    assert.throws(() => policy(new Uint8Array(bytes)), /tooltip presentation/);
});

test("surface dismissal preserves trigger shielding and post-return cleanup", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<tooltip anchor="below">Hint</tooltip>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const action = (stage: number, facts: number) => Array.from(policy(new Uint8Array([28, stage, facts])));
  for (let facts = 0; facts < 4; facts++) assert.deepEqual(action(0, facts), [facts === 1 ? 1 : 0]);
  for (let facts = 0; facts < 16; facts++)
    assert.deepEqual(action(1, facts), [(facts & 1) === 0 && (facts & 14) !== 14 ? 1 : 0]);
  assert.deepEqual(action(2, 0), [0]); assert.deepEqual(action(2, 1), [1]);
  assert.deepEqual(action(3, 0), [0]); // Returned ring lives outside the surface.
  assert.deepEqual(action(3, 1), [3]); // A surviving internal ring spends keyboard provenance.
  assert.deepEqual(action(3, 2), [12]); // Hover cleanup also restores the arrow cursor.
  assert.deepEqual(action(3, 4), [16]); assert.deepEqual(action(3, 7), [31]);
  const request = new Uint8Array(36);
  request.set([28, 4, 32, 0]);
  for (let index = 0; index < 32; index++) request[4 + index] = index % 2;
  assert.deepEqual(Array.from(policy(request)), Array.from({ length: 32 }, (_, index) => index % 2 === 0 ? 1 : 0));
  assert.deepEqual(Array.from(policy(new Uint8Array([28, 4, 0, 0]))), []);
  for (const bytes of [[28], [28, 4, 0], [28, 5, 0], [28, 0, 4], [28, 1, 16], [28, 2, 2],
    [28, 3, 8], [28, 0, 0, 0], [28, 4, 33, 0], [28, 4, 1, 0], [28, 4, 1, 0, 2]])
    assert.throws(() => policy(new Uint8Array(bytes)), /surface dismissal/);
});


test("pointer intent owns phase selection, focus provenance and consumed retirement", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button>Pointer</button>', contract),
    { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const action = (stage: number, phase: number, facts: number, kind = 0) =>
    Array.from(policy(new Uint8Array([29, stage, phase, facts, kind & 255, kind >>> 8])));
  for (let phase = 0; phase < 6; phase++) for (let facts = 0; facts < 8; facts++) {
    const proven = (facts & 1) !== 0;
    let expected: number[];
    switch (phase) {
      case 0: expected = [3, 0, 3, (facts & 2) === 0 ? 7 : proven ? 6 : 0]; break;
      case 1: expected = [2, 2, 2, proven ? 6 : 0]; break;
      case 2: expected = [3, 0, 3, proven ? 6 : 0]; break;
      case 3: expected = [3, 1, 3, proven ? ((facts & 4) !== 0 ? 6 : 24) : 0]; break;
      case 4: expected = [1, 1, 1, proven ? 24 : 0]; break;
      default: expected = [0, 0, 0, proven ? 2 : 0];
    }
    assert.deepEqual(action(1, phase, facts), expected);
    assert.deepEqual(action(4, phase, facts), [proven && (phase === 4 || phase === 3 && (facts & 4) === 0) ? 24 : 0]);
  }
  for (let phase = 0; phase < 6; phase++) for (let facts = 0; facts < 4; facts++) for (let kind = 0; kind <= 62; kind++) {
    const present = (facts & 1) !== 0;
    assert.deepEqual(action(0, phase, facts, kind), [phase === 1 ?
      12 | (present && (facts & 2) !== 0 ? 1 : 0) | (present && (kind >= 35 && kind <= 39 || kind === 62) ? 2 : 0) : 0]);
  }
  for (let facts = 0; facts < 16; facts++) assert.deepEqual(action(3, 0, facts), [
    (facts !== 0 ? 1 : 0) | ((facts & 8) !== 0 ? 2 : 0) | ((facts & 7) !== 0 ? 4 : 0)]);
  for (let phase = 0; phase < 6; phase++) for (let present = 0; present < 2; present++)
    assert.deepEqual(action(2, phase, present), [phase !== 4 && present !== 0 ? 1 : 0]);
  for (let facts = 0; facts < 4; facts++) assert.deepEqual(action(5, 0, facts), [facts !== 0 ? 1 : 0]);
  for (const request of [[29], [29, 0, 1, 0, 0], [29, 6, 0, 0, 0, 0], [29, 0, 6, 0, 0, 0],
    [29, 0, 1, 4, 0, 0], [29, 0, 1, 0, 63, 0], [29, 1, 0, 8, 0, 0], [29, 1, 0, 0, 1, 0],
    [29, 2, 0, 2, 0, 0], [29, 3, 1, 0, 0, 0], [29, 3, 0, 16, 0, 0], [29, 4, 0, 8, 0, 0],
    [29, 5, 1, 0, 0, 0], [29, 5, 0, 4, 0, 0], [29, 5, 0, 0, 0, 0, 0]])
    assert.throws(() => policy(new Uint8Array(request)), /pointer intent/);
});

test("command strings preserve literal and bound text beside message handlers", () => {
  const { model, view } = evaluate('<column><button command="run.café" on-press="increment">Run</button><list-item command="{status}"/><text command="ignored"/><button command=""/></column>');
  const first = view();
  assert.equal(first.nodes[1].command, "run.café");
  assert.deepEqual(first.nodes[1].press, [1, 3]);
  assert.equal(first.nodes[2].command, "Café\nnotes");
  assert.equal(first.nodes[3].command, "ignored");
  assert.equal(first.nodes[4].command, "");
  model.status = new TextEncoder().encode("choose.日本");
  assert.equal(view().nodes[2].command, "choose.日本");
  assert.equal(first.nodes[2].command, "Café\nnotes");
  assert.throws(() => compileView('<button command="{count}"/>', contract), /command requires text/);
});

test("command policy validates requests and distinguishes raw hits, claiming bounds and canonical keys", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const call = (stage: number, phase: number, key: number, facts: number, kind: number) => [...policy(new Uint8Array([30, stage, phase, key, facts, kind & 255, kind >> 8]))];
  assert.deepEqual(call(1, 1, 0, 4, 34), [1]);
  assert.deepEqual(call(1, 3, 0, 5, 34), [0]);
  assert.deepEqual(call(1, 3, 0, 5, 31), [1]);
  assert.deepEqual(call(1, 3, 0, 4, 31), [0]);
  assert.deepEqual(call(1, 3, 0, 11, 42), [1]);
  assert.deepEqual(call(1, 3, 0, 9, 42), [0]);
  assert.deepEqual(call(2, 0, 3, 0, 38), [1]);
  assert.deepEqual(call(2, 0, 3, 2, 38), [0]);
  assert.deepEqual(call(2, 0, 3, 4, 38), [0]);
  assert.deepEqual(call(2, 0, 2, 6, 38), [1]);
  assert.deepEqual(call(2, 0, 1, 1, 31), [0]);
  for (const bytes of [[30], [30, 0, 0, 0, 0, 31], [30, 0, 0, 0, 0, 31, 0, 0], [30, 3, 0, 0, 0, 31, 0], [30, 0, 1, 0, 0, 31, 0], [30, 0, 0, 1, 0, 31, 0], [30, 0, 0, 0, 1, 31, 0], [30, 1, 6, 0, 0, 31, 0], [30, 1, 0, 1, 0, 31, 0], [30, 1, 0, 0, 16, 31, 0], [30, 2, 3, 0, 0, 31, 0], [30, 2, 0, 5, 0, 31, 0], [30, 2, 0, 0, 8, 31, 0], [30, 0, 0, 0, 0, 63, 0], [30, 0, 0, 0, 0, 0, 1]])
    assert.throws(() => policy(new Uint8Array(bytes)), /command activation/);
});


test("click sequence policy preserves continuation counts, primary chain rules and three-click saturation", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  for (let phase = 0; phase < 6; phase++) for (let previous = 0; previous <= 3; previous++) for (let facts = 0; facts < 256; facts++) {
    const expected = phase === 1 ? (facts & 1) === 0 ? [1, 0] : [2, previous > 0 && facts === 255 ? Math.min(previous + 1, 3) : 1] : phase === 2 || phase === 3 ? [3, Math.max(previous, 1)] : [0, 0];
    assert.deepEqual([...policy(new Uint8Array([31, phase, previous, facts]))], expected);
  }
  for (const request of [[31], [31, 1, 1], [31, 1, 1, 255, 0], [31, 6, 0, 0], [31, 1, 4, 255]])
    assert.throws(() => policy(new Uint8Array(request)), /click sequence/);
});


test("selection press policy preserves text, group and terminal release precedence", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  for (let phase = 0; phase < 6; phase++) for (let kind = 0; kind <= 62; kind++) for (let facts = 0; facts < 128; facts++) {
    let expected = (facts & 1) !== 0;
    if (phase === 3 && (facts & 2) !== 0) {
      if (kind === 62 && (facts & 64) !== 0) expected = false;
      if (kind === 26 && (facts & 4) !== 0 && ((facts & 24) === 24 || (facts & 32) !== 0)) expected = false;
    }
    assert.deepEqual([...policy(new Uint8Array([32, phase, facts, kind, 0]))], [expected ? 1 : 0]);
  }
  for (const request of [[32], [32, 3, 0, 26], [32, 3, 0, 26, 0, 0], [32, 6, 0, 26, 0], [32, 3, 128, 26, 0], [32, 3, 0, 63, 0], [32, 3, 0, 0, 1]])
    assert.throws(() => policy(new Uint8Array(request)), /selection press/);
});

test("compiled keyboard participation preserves quiet plain rows and explicit ring entry", () => {
  const generated = compileView('<button on-press="increment">Run</button>', contract);
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  for (let stage = 0; stage < 2; stage++) for (let kind = 0; kind <= 62; kind++) for (let facts = 0; facts < 16; facts++) {
    const expected = kind === 42 && (facts & 8) === 0 && (facts & 4) !== 0 && (facts & 2) === 0 && (stage === 1 || (facts & 1) !== 0);
    assert.deepEqual([...policy(new Uint8Array([33, stage, facts, kind, 0]))], [expected ? 1 : 0]);
  }
  for (const request of [[33], [33, 0, 0, 42], [33, 0, 0, 42, 0, 0], [33, 2, 0, 42, 0], [33, 0, 16, 42, 0], [33, 0, 0, 63, 0], [33, 0, 0, 42, 1]])
    assert.throws(() => policy(new Uint8Array(request)), /keyboard participation/);
});


test("keyboard focus coordinator owns traversal ordering, modifiers, retries and provenance", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const decide = (stage: number, a = 0, b = 0, c = 0, kind = 63, parent = 63, target = 63, facts = 0) => {
    const output = policy(new Uint8Array([34, stage, a, b, c, kind, parent, target, facts & 255, facts >> 8]));
    assert.equal(output.length, 1); return output[0];
  };
  for (let phase = 0; phase < 3; phase++) for (let key = 0; key < 8; key++) for (let modifiers = 0; modifiers < 32; modifiers++) for (let owners = 0; owners < 4; owners++) {
    let expected = 0;
    if (phase === 0) {
      if (key === 1 && (owners & 1) === 0 && !((owners & 2) !== 0 && modifiers === 0)) expected = modifiers & 1 ? 2 : 1;
      if (key > 1 && (modifiers & 30) === 0) {
        if (key < 4 && modifiers === 0) expected = key + 1;
        if (key >= 4) expected = key + 1;
      }
    }
    assert.equal(decide(0, phase, key, modifiers, 63, 63, 63, owners), expected);
    for (let held = 0; held < 2; held++) assert.equal(decide(1, phase, key, 0, 63, 63, 63, held), phase < 2 && key === 1 && held ? (phase === 1 ? 2 : 1) : 0);
  }
  for (let parent = 0; parent < 64; parent++) for (let kind = 0; kind < 63; kind++) {
    const buttons = [8, 9, 10].includes(parent), toggles = [9, 13].includes(parent);
    assert.equal(decide(3, 0, 0, 0, kind, parent), [41, 42, 44, 46, 48].includes(kind) || ([31, 33].includes(kind) && buttons) || (kind === 32 && toggles) ? 1 : 0);
    for (let direction = 0; direction < 6; direction++) {
      const horizontal = direction === 2 || direction === 3, vertical = direction === 4 || direction === 5;
      const h = (buttons && [31, 33].includes(kind)) || (parent === 13 && kind === 32) || (parent === 12 && kind === 46);
      const v = (parent === 7 && kind === 42) || ([24, 25].includes(parent) && kind === 41);
      assert.equal(decide(2, direction, 0, 0, kind, parent), (h && horizontal) || (v && vertical) ? (direction === 2 || direction === 4 ? 1 : 2) : 0);
      for (let facts = 0; facts < 16; facts++) {
        const allowed = kind === 44 || (kind === 48 ? ((facts & 6) !== 0 ? (facts & 10) === 10 : (facts & 1) !== 0) :
          (facts & 1) !== 0 && (([41, 42].includes(kind) && vertical) || (kind === 46 && horizontal) || ([31, 33].includes(kind) && buttons && horizontal) || (kind === 32 && toggles && horizontal)));
        assert.equal(decide(4, direction, 0, 0, kind, parent, kind, facts), allowed ? 1 : 0);
        assert.equal(decide(4, direction, 0, 0, kind, parent, (kind + 1) % 63, facts), 0);
      }
    }
  }
  // Every transition is observable: queries are selected here, not by the executor.
  const cases = [
    [1, 0, 0, 1], [2, 0, 0, 1], [3, 0, 64, 9], [4, 0, 64, 9], [8, 0, 64, 8],
    [8, 0, 192, 0], [8, 1, 1, 2], [8, 1, 0, 0], [1, 2, 2, 7], [1, 2, 4, 3], [1, 2, 0, 7],
    [1, 3, 1, 4], [1, 3, 9, 5], [1, 4, 2, 7], [1, 4, 0, 5], [1, 5, 1, 6], [1, 5, 9, 0],
    [1, 6, 0, 7], [1, 7, 2, 17], [1, 7, 514, 18], [1, 7, 512, 0],
    [8, 8, 1, 14], [8, 8, 0, 11], [3, 9, 1, 14], [3, 9, 0, 10],
    [3, 10, 1, 14], [3, 10, 3109, 15], [3, 10, 33, 0], [3, 10, 0, 0],
    [8, 11, 1, 14], [8, 11, 0, 12], [8, 12, 0, 13], [8, 12, 1, 14],
    [8, 13, 4097, 14], [8, 13, 1, 0], [8, 14, 2, 17], [8, 14, 0, 0],
    [8, 15, 0, 16], [8, 15, 2, 17], [8, 16, 3077, 15], [8, 16, 3085, 0], [8, 16, 3093, 0], [8, 16, 1029, 0],
  ];
  for (const [intent, action, facts, next] of cases) assert.equal(decide(5, intent, action, 0, (facts & 32) !== 0 ? 48 : 31, 63, 63, facts), next);
  for (let facts = 0; facts < 8; facts++) for (let visible = 0; visible < 2; visible++) {
    assert.equal(decide(6, visible, 0, 0, 63, 63, 63, facts), (facts & 3) === 3 ? 0 : 1 | (visible && (facts & 4) !== 0 ? 6 : 0));
    assert.equal(decide(8, 0, 0, 0, 63, 63, 63, facts), facts === 7 ? 1 : 0);
    assert.equal(decide(9, 0, 0, 0, 63, 63, 63, facts), facts === 7 ? 1 : 0);
  }
  for (let intent = 0; intent < 9; intent++) for (let match = 0; match < 2; match++) assert.equal(decide(7, intent, 0, 0, 63, 63, 63, match), intent === 1 || intent === 2 || match ? 1 : 0);
  for (const bytes of [[34], [34, 11, 0, 0, 0, 63, 63, 63, 0, 0], [34, 0, 3, 0, 0, 63, 63, 63, 0, 0],
    [34, 0, 0, 8, 0, 63, 63, 63, 0, 0], [34, 0, 0, 0, 32, 63, 63, 63, 0, 0], [34, 4, 6, 0, 0, 0, 0, 0, 0, 0],
    [34, 5, 9, 0, 0, 63, 63, 63, 0, 0], [34, 5, 0, 19, 0, 63, 63, 63, 0, 0], [34, 5, 0, 0, 0, 64, 63, 63, 0, 0],
    [34, 6, 2, 0, 0, 63, 63, 63, 0, 0], [34, 8, 0, 0, 0, 63, 63, 63, 8, 0]]) assert.throws(() => policy(new Uint8Array(bytes)), /keyboard focus/);
});

test("compiled generic groups preserve sibling traversal, logical list targets and authoring", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const query = (operation: number, kind: number, parentKind: number, records: number[][]) => {
    const request = new Uint8Array([34, 10, operation, kind, parentKind, 0, 0, records.length, 0, ...records.flat()]);
    const result = exports.native_text_policy!(request); assert.equal(result.length, 2); return result[0] | result[1] << 8;
  };
  for (let flags = 0; flags < 8; flags++) for (let operation = 0; operation < 4; operation++) for (const kind of [31, 32, 33, 41, 42, 44, 46]) {
    const records = [[255, 255, 0, 0], [0, 0, kind, flags], [0, 0, kind, 7], [0, 0, kind, 5], [1, 0, kind, 7], [0, 0, (kind + 1) % 63, 7]];
    for (const parent of [7, 9, 63]) {
      const logical = operation < 2 && kind === 42 && parent === 7;
      let expected = 65535, previous = 65535, seen = false;
      for (let i = 0; i < records.length; i++) {
        const [p, high, k, f] = records[i]; if (p !== 0 || high !== 0 || k !== kind || !(f & (logical ? 4 : 1))) continue;
        if (operation === 2) { expected = i; break; }
        if (operation === 3) { expected = i; continue; }
        if (seen) { expected = i; break; }
        if (f & 2) { if (operation === 0) { expected = previous; break; } seen = true; } else previous = i;
      }
      assert.equal(query(operation, kind, parent, records), expected);
    }
  }
  for (const tag of ["button-group", "breadcrumb", "pagination"]) {
    const { view } = evaluate(`<${tag} gap="4"><button on-press="increment">First</button><button disabled="true">Unavailable</button><button on-press="increment">Last</button></${tag}>`);
    const nodes = view().nodes; assert.equal(nodes[0].kind, tag.replaceAll("-", "_")); assert.equal(nodes[0].end, 4); assert.equal(nodes[0].gap, 4); assert.equal(nodes[2].disabled, true);
    assert.throws(() => compileView(`<${tag}>mixed<button/></${tag}>`, contract), /mixed content/);
  }
  for (const bytes of [[34, 10], [34, 10, 4, 31, 9, 0, 0, 0, 0], [34, 10, 0, 63, 9, 0, 0, 0, 0], [34, 10, 0, 31, 64, 0, 0, 0, 0], [34, 10, 0, 31, 9, 0, 0, 1, 0], [34, 10, 0, 31, 9, 0, 0, 1, 0, 0, 0, 64, 0], [34, 10, 0, 31, 9, 0, 0, 1, 0, 0, 0, 31, 8]]) assert.throws(() => exports.native_text_policy!(new Uint8Array(bytes)), /keyboard group/);
});


test("drag coordination owns capture, slop, orphan cancellation and message delivery", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const request = (stage: number, phase: number, facts: number, dx = 0, dy = 0, modifiers = 0) => {
    const bytes = new Uint8Array(16); bytes.set([35, stage, phase, facts, modifiers]);
    const view = new DataView(bytes.buffer); view.setFloat32(8, dx, true); view.setFloat32(12, dy, true); return bytes;
  };
  const decide = (stage: number, phase: number, facts: number, dx = 0, dy = 0, modifiers = 0) => [...policy(request(stage, phase, facts, dx, dy, modifiers))];
  for (let phase = 0; phase <= 4; phase++) for (let facts = 0; facts < 8; facts++) {
    const expected = phase === 0 ? (facts & 1 ? 0 : 1) : phase === 4 || !(facts & 2) ? 0 : !(facts & 1) && phase !== 1 ? 2 : facts & 5 ? 3 | (facts & 1 ? 16 : 0) : 0;
    assert.deepEqual(decide(0, phase, facts), [expected]);
  }
  const deltas = [0, 5.999999523162842, 6, -6, 6.000000476837158, -5.999999523162842, Infinity, -Infinity, NaN];
  for (const dx of deltas) for (const dy of deltas) {
    const crossed = Math.abs(dx) >= 6 || Math.abs(dy) >= 6;
    assert.deepEqual(decide(4, 4, 0, dx, dy), [crossed ? 1 : 0]);
    for (let phase = 1; phase <= 3; phase++) for (let facts = 0; facts < 8; facts++) {
      const expected = !(facts & 2) ? ((facts & 5) === 5 ? 5 : 4) | (facts & 1 ? 32 : 0) : !(facts & 1) && !crossed ? 6 : phase === 1 ? 7 | (facts & 1 ? 0 : 64) : 8;
      assert.deepEqual(decide(1, phase, facts, dx, dy), [expected]);
    }
    for (let phase = 1; phase <= 3; phase++) for (let source = 0; source <= 1; source++)
      assert.deepEqual(decide(5, phase, source, dx, dy), [!source || phase === 1 && !crossed ? 0 : phase === 1 ? 1 : 2]);
  }
  for (let phase = 0; phase <= 4; phase++) for (let key = 0; key <= 1; key++) for (let mods = 0; mods < 32; mods++)
    assert.deepEqual(decide(2, phase, key, 0, 0, mods), [phase === 0 && key === 1 && mods === 0 ? 1 : 0]);
  for (let phase = 1; phase <= 3; phase++) for (let facts = 0; facts < 16; facts++) {
    const template = facts & 1 ? 1 : (facts & 12) === 12 ? 2 : 0, size = facts & 2 ? 4 : facts & 4 ? 8 : 0;
    assert.deepEqual(decide(6, phase, facts), [phase === 1 ? (facts & 3) === 3 ? 5 : 0 : !template ? facts & 4 ? 32 : 0 : size ? template | size : 0]);
  }
  for (let phase = 1; phase <= 3; phase++) for (let facts = 0; facts < 4; facts++)
    assert.deepEqual(decide(7, phase, facts), [phase === 1 ? facts & 1 ? 3 : 0 : (facts & 1) | (facts & 2 ? 4 : 0)]);
  for (let facts = 0; facts < 16; facts++) assert.deepEqual(decide(8, 4, facts), [facts === 15 ? 1 : 0]);
  assert.deepEqual(decide(3, 4, 1), [3]); assert.deepEqual(decide(3, 4, 0), [0]);
  for (const offset of [1, 2, 3, 4, 5, 6, 7]) {
    const bytes = request(1, 1, 3); bytes[offset] = 255;
    assert.throws(() => policy(bytes), /drag coordination/);
  }
  for (const bytes of [new Uint8Array(0), new Uint8Array([35]), new Uint8Array(15), new Uint8Array(17), request(1, 0, 0), request(1, 4, 0), request(4, 4, 1)])
    assert.throws(() => policy(bytes), /drag coordination|text policy/);
  const retained = policy(request(0, 0, 0)); for (let i = 0; i < 100; i++) policy(request(1, 1, 3, 8)); assert.deepEqual([...retained], [1]);
});


test("hover coordination preserves exact identity set diffs, edge order, retries and owned results", () => {
  const exports: { native_text_policy?: (request: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView('<button/>', contract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports });
  const policy = exports.native_text_policy!;
  const plan = (same: boolean, mirror: bigint[], standing: bigint[]) => {
    const input = new Uint8Array(6 + 8 * (mirror.length + standing.length)); input.set([36, 1, same ? 1 : 0, mirror.length, standing.length, 0]);
    const bytes = new DataView(input.buffer); [...mirror, ...standing].forEach((id, index) => bytes.setBigUint64(6 + index * 8, id, true));
    const retained = standing.map(id => same ? mirror.indexOf(id) : -1);
    const leaves = mirror.map((id, index) => ({ id, index })).reverse().filter(({ id }) => !same || !standing.includes(id)).map(({ index }) => index);
    const expected = [same && mirror.length === standing.length && retained.every((index, position) => index === position) ? 1 : 0, retained.includes(-1) ? 1 : 0, leaves.length,
      ...retained.map(index => index < 0 ? 255 : index), ...leaves, ...Array(mirror.length - leaves.length).fill(255)];
    const output = policy(input); assert.deepEqual([...output], expected); return output;
  };
  const ids = [0n, 1n, 9007199254740992n, 9007199254740993n, 0xffffffffffffffffn, 0xfffffffffffffffen];
  for (let mask = 0; mask < 64; mask++) for (let next = 0; next < 64; next++) for (const same of [false, true]) {
    const mirror = ids.filter((_, i) => mask & 1 << i), standing = ids.filter((_, i) => next & 1 << i).reverse(); plan(same, mirror, standing);
  }
  const deep = Array.from({ length: 32 }, (_, i) => 0xffffffffffffffffn - BigInt(i));
  const retained = plan(true, deep, deep); plan(true, deep, deep.slice().reverse()); plan(false, deep, deep);
  plan(true, [], []); assert.equal(retained[0], 1);
  const decide = (stage: number, facts: number, a = 0, b = 0) => policy(new Uint8Array([36, stage, a, b, facts, 0]))[0];
  for (let facts = 0; facts < 16; facts++) {
    assert.equal(decide(0, facts), (facts & 3) !== 3 ? 0 : facts & 4 ? 2 : facts & 8 ? 0 : 1);
    assert.equal(decide(2, facts), (facts & 13) === 13 && !(facts & 2) ? 1 : 0);
    assert.equal(decide(5, facts), facts & 1 ? 0 : facts & 2 ? 1 : (facts & 12) === 12 ? 2 : 3);
    assert.equal(decide(6, facts), !(facts & 1) ? 0 : !(facts & 2) ? 1 : (facts & 12) !== 12 ? 2 : 3);
  }
  for (let facts = 0; facts < 4; facts++) {
    assert.equal(decide(3, facts), facts === 2 ? 1 : 0); assert.equal(decide(8, facts), facts === 1 ? 1 : 0);
    for (let context = 0; context < 2; context++) for (let outcome = 0; outcome < 3; outcome++) assert.equal(decide(4, facts, context, outcome), outcome === 0 ? 1 : outcome === 2 ? 4 : context === 1 ? 2 : facts === 0 ? 3 : 0);
  }
  for (let pass = 0; pass <= 64; pass++) for (let progress = 0; progress < 2; progress++) assert.equal(decide(9, progress, pass), pass < 64 && progress ? 1 : 0);
  for (let len = 0; len <= 32; len++) for (let from = 0; from <= len; from++) {
    const flags = Array.from({ length: len }, (_, i) => i % 3 === 0 ? 1 : 0), kept = flags.map((flag, i) => ({ flag, i })).filter(({ flag, i }) => i < from || !flag).map(({ i }) => i);
    assert.deepEqual([...policy(new Uint8Array([36, 7, from, len, 0, 0, ...flags]))], [kept.length, ...kept, ...Array(len - kept.length).fill(255)]);
  }
  for (const bytes of [[36], [36, 10, 0, 0, 0, 0], [36, 0, 1, 0, 0, 0], [36, 0, 0, 0, 16, 0], [36, 0, 0, 0, 0, 1], [36, 1, 2, 0, 0, 0], [36, 1, 0, 33, 0, 0], [36, 1, 0, 1, 0, 0], [36, 4, 2, 0, 0, 0], [36, 4, 0, 3, 0, 0], [36, 7, 1, 0, 0, 0], [36, 7, 0, 1, 0, 0, 2], [36, 9, 65, 0, 1, 0]]) assert.throws(() => policy(new Uint8Array(bytes)), /hover/);
  assert.equal(retained[0], 1);
});

test("compiled hover handlers preserve typed byte envelopes on nested keyed listeners", () => {
  const input: ViewContract = { ...contract, msg: { arms: [
    { name: "enter", payload: { kind: "void" } }, { name: "leave", member: "text", payload: { kind: "bytes" } },
  ] } };
  const model = { status: new TextEncoder().encode("Café\0日本"), count: 1 };
  const exports: { native_view?: () => Uint8Array } = {};
  const generated = compileView('<panel key="{count}" on-hover-enter="enter" on-hover-leave="leave:{status}"><button on-hover-enter="enter">Nested</button></panel>', input);
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: model, nscfPackMsg: (msg: { kind: string; text?: Uint8Array }) => new Uint8Array([1, msg.kind === "enter" ? 0 : 1, ...msg.text ?? []]),
  });
  const view = () => decodedView(exports.native_view!()).nodes;
  assert.deepEqual(view()[0].hoverLeave, [1, 1, ...model.status]); assert.deepEqual(view()[0].hoverEnter, [1, 0]); assert.deepEqual(view()[1].hoverEnter, [1, 0]);
  model.status = new TextEncoder().encode("Rebound"); assert.deepEqual(view()[0].hoverLeave, [1, 1, ...model.status]);
  assert.throws(() => compileView('<panel on-hover-leave="leave"/>', input), /matching scalar/);
});


test("compiled modals retain nested content, width constraints, captions and dismiss envelopes", () => {
  for (const kind of ["dialog", "drawer", "sheet"]) {
    const { model, view } = evaluate(`<${kind} text="{status}" width="{count}" height="220" min-width="4" max-width="420" on-dismiss="reset"><column><button on-press="increment">Close</button></column></${kind}>`);
    let nodes = view().nodes;
    assert.deepEqual(nodes, [
      { end: 3, kind, text: "Café\nnotes", width: 7, height: 220, minWidth: 4, maxWidth: 420, dismiss: [1, 5] },
      { end: 3, kind: "column", text: "" },
      { end: 3, kind: "button", text: "Close", press: [1, 3] },
    ]);
    model.count = 12; model.status = new TextEncoder().encode("Changed");
    nodes = view().nodes;
    assert.equal(nodes[0].width, 12); assert.equal(nodes[0].text, "Changed");
    assert.throws(() => compileView(`<${kind} on-dismiss="missing"/>`, contract), /event/);
    assert.throws(() => compileView(`<${kind} text="{count}"/>`, contract), /requires text/);
  }
  assert.throws(() => compileView('<button on-dismiss="reset"/>', contract), /unsupported/);
});


test("compiled grids preserve dynamic columns, virtual extents, and owned nested records", () => {
  const { model, view } = evaluate('<grid columns="{count}" virtualized="{ticking}" virtual-item-extent="40" gap="8" value="{stampedMs}"><button on-press="increment">Café</button></grid>');
  const first = view(); assert.equal(first.nodes[0].kind, "grid"); assert.equal(first.nodes[0].columns, 7);
  assert.equal(first.nodes[0].virtualized, true); assert.equal(first.nodes[0].virtualItemExtent, 40);
  assert.equal(first.nodes[0].value, -1); assert.equal(first.nodes[0].end, 2); assert.equal(first.nodes[1].text, "Café");
  model.count = 3; model.ticking = false; const next = view(); assert.equal(next.nodes[0].columns, 3); assert.equal(next.nodes[0].virtualized, false);
  assert.equal(first.nodes[0].columns, 7); model.count = -1; assert.throws(view, /grid columns/);
  for (const attr of ['columns="2"', 'virtualized="true"', 'virtual-item-extent="40"']) assert.throws(() => compileView(`<row ${attr}/>`, contract), /requires grid/);
});


test("content surfaces preserve captions child boundaries explicit spacing and activation envelopes", () => {
  for (const kind of ["card", "alert"]) {
    const { model, view } = evaluate(`<${kind} text="{status}" width="360" min-width="120" max-width="420" padding="0" variant="destructive" on-press="increment"><column gap="6"><text wrap="true">Description</text><if test="{ticking}"><text>Extra content</text></if></column></${kind}>`);
    let nodes = view().nodes;
    assert.equal(nodes.length, 4); assert.equal(nodes[0].kind, kind); assert.equal(nodes[0].text, "Café\nnotes");
    assert.equal(nodes[0].end, 4); assert.equal(nodes[1].end, 4); assert.equal(nodes[2].end, 3);
    assert.equal(nodes[0].padding, 0); assert.equal(nodes[0].width, 360); assert.equal(nodes[0].minWidth, 120); assert.equal(nodes[0].maxWidth, 420); assert.equal(nodes[0].variant, "destructive");
    assert.deepEqual(nodes[0].press, [1, 3]);
    model.ticking = false; model.status = new TextEncoder().encode("New caption"); nodes = view().nodes;
    assert.equal(nodes.length, 3); assert.equal(nodes[0].end, 3); assert.equal(nodes[0].text, "New caption");
    const empty = evaluate(`<${kind}/>`).view().nodes[0]; assert.equal(empty.text, ""); assert.equal(empty.end, 1); assert.equal(empty.padding, undefined);
    assert.equal(evaluate(`<${kind}>Inline café</${kind}>`).view().nodes[0].text, "Inline café");
    assert.throws(() => compileView(`<${kind}>Caption<text>Body</text></${kind}>`, contract), /mixed content/);
    assert.doesNotThrow(() => compileView(`<${kind} on-toggle="increment"/>`, contract));
    assert.throws(() => compileView(`<${kind} on-dismiss="increment"/>`, contract), /unsupported/);
  }
});

test("unkeyed enum filters preserve structural identities and dispatch typed enum payloads", () => {
  const c: ViewContract = {
    model: "Model", types: { structs: [{ name: "Model", fields: [
      { name: "filters", type: { kind: "slice", elem: { kind: "enum", name: "Filter" } } },
      { name: "filter", type: { kind: "enum", name: "Filter" } },
      { name: "other", type: { kind: "enum", name: "Other" } },
    ] }], enums: [{ name: "Filter", members: ["all", "active"] }, { name: "Other", members: ["all", "active"] }] },
    model_helpers: [], msg: { arms: [{ name: "set_filter", member: "filter", payload: { kind: "scalar", type: { kind: "enum", name: "Filter" } } }] },
  };
  const markup = '<radio-group label="Filter"><for each="filters" as="f"><radio checked="{f == filter}" on-toggle="set_filter:{f}">{f}</radio></for></radio-group>';
  const js = ts.transpile(compileView(markup, c), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS });
  const model = { filters: ["all", "active", "all"], filter: "active" }, messages: unknown[] = [];
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(js, { exports, TextEncoder, TextDecoder, nscfCommitted: model,
    nscfPackMsg: (msg: unknown) => { messages.push(msg); return Uint8Array.of(1, 1); } });
  const nodes = decodedView(exports.native_view!()).nodes;
  assert.deepEqual(nodes.slice(1).map((n: any) => [n.text, n.checked]), [["all", false], ["active", true], ["all", false]]);
  assert.ok(nodes.slice(1).every((n: any) => n.key === undefined && n.keyInt === undefined && n.keySlot === undefined));
  assert.deepEqual(JSON.parse(JSON.stringify(messages)), [{ kind: "set_filter", filter: "all" }, { kind: "set_filter", filter: "active" }, { kind: "set_filter", filter: "all" }]);
  model.filters = [];
  assert.equal(decodedView(exports.native_view!()).nodes.length, 1);
  assert.throws(() => compileView(markup.replace("f == filter", "f == other"), c), /invalid operands/);
  assert.throws(() => compileView(markup.replace("set_filter:{f}", "set_filter:{other}"), c), /matching scalar/);
  assert.throws(() => compileView(markup.replace('as="f"', 'as="f" key=""'), c), /for requires/);
});

test("inline paragraphs preserve ordered runs, native whitespace, identity and styles", () => {
  const { view } = evaluate('<text key="readout" size="display" text-alignment="end" label="Result">  Value <span mono="true" weight="medium" italic="true" underline="true" scale="1.5" foreground="accent">{status}</span>. <span weight="bold">done</span>  </text>');
  const tree = view();
  assert.equal(tree.nodes.length, 1);
  const node = tree.nodes[0];
  assert.equal(node.textAlignment, "end");
  assert.equal(node.key, "readout");
  assert.deepEqual(node.spans, [
    { text: "Value" }, { text: " " },
    { text: "Café\nnotes", monospace: true, weight: "medium", italic: true, underline: true, scale: 1.5, color: "accent" },
    { text: "." }, { text: " " }, { text: "done", weight: "bold" },
  ]);
  assert.equal(node.end, 1);
  assert.equal(node.text, "");
  assert.deepEqual(evaluate('<text><span>a</span><!-- comment whitespace --><span>b</span></text>').view().nodes[0].spans, [{ text: "a" }, { text: "b" }]);
  assert.deepEqual(evaluate('<text><span>a</span> \n <span>b</span></text>').view().nodes[0].spans, [{ text: "a" }, { text: " " }, { text: "b" }]);
});

test("inline paragraph misuse is rejected at its authoring boundary", () => {
  for (const markup of [
    '<span>outside</span>', '<text><button>child</button></text>',
    '<text><span><span>nested</span></span></text>', '<text><span>a<!--comment-->b</span></text>', '<text><span/></text>',
    '<text><span key="run">x</span></text>', '<text><span on-press="reset">x</span></text>',
    '<text><span weight="heavy">x</span></text>', '<text><span foreground="invalid">x</span></text>',
    '<text><span scale="0">x</span></text>', '<text><span scale="-1">x</span></text>',
    '<text><span scale="NaN">x</span></text>', '<text><span scale="{status}">x</span></text>',
    '<text wrap="true"><span>x</span></text>', '<text overflow="clip"><span>x</span></text>',
    '<text text-alignment="right">x</text>',
  ]) assert.throws(() => compileView(markup, contract), undefined, markup);
  const { model, view } = evaluate('<text><span scale="{count}">x</span></text>');
  assert.equal(view().nodes[0].spans[0].scale, 7);
  model.count = 0;
  assert.throws(view, /positive finite/);
});

test("text entry border tokens preserve the authored surface blend", () => {
  const node = evaluate('<input background="background" border-color="background" />').view().nodes[0];
  assert.equal(node.borderColor, "background");
  assert.throws(() => compileView('<input border-color="invalid" />', contract), /unsupported border-color/);
});


test("context-menu metadata retains typed dispatch, disabled rows and structural children", () => {
  const { model, view } = evaluate('<list-item label="Task"><text>Content</text><context-menu><menu-item on-press="increment" disabled="{ticking}">Toggle</menu-item><separator/><menu-item on-press="reset">Reset</menu-item></context-menu></list-item>');
  let nodes = view().nodes;
  assert.equal(nodes.length, 2); assert.equal(nodes[0].end, 2);
  assert.equal(nodes[1].text, "Content");
  assert.deepEqual(nodes[0].contextMenu, [
    { label: "Toggle", enabled: false, separator: false, press: [1, 3] },
    { label: "", enabled: true, separator: true },
    { label: "Reset", enabled: true, separator: false, press: [1, 5] },
  ]);
  model.ticking = false; assert.equal(view().nodes[0].contextMenu[0].enabled, true);
  for (const markup of [
    '<list-item><context-menu/><context-menu/></list-item>',
    '<list-item><context-menu><menu-item>Missing handler</menu-item></context-menu></list-item>',
    '<column><context-menu><menu-item on-press="increment">Wrong host</menu-item></context-menu></column>',
    '<list-item><context-menu><button>Wrong</button></context-menu></list-item>',
    '<list-item><context-menu><menu-item on-press="unknown">Wrong</menu-item></context-menu></list-item>',
    '<list-item><context-menu><separator on-press="increment"/></context-menu></list-item>',
    `<list-item><context-menu>${'<menu-item>Row</menu-item>'.repeat(33)}</context-menu></list-item>`,
  ]) assert.throws(() => compileView(markup, contract), /compiled TypeScript view/);
});

test("compiled text-field retains its native kind rather than the input composite identity", () => {
  const { view } = evaluate('<text-field text="{status}" placeholder="Task" on-submit="increment"/>');
  assert.equal(view().nodes[0].kind, "text_field");
  assert.deepEqual(view().nodes[0].submit, [1, 3]);
});

test("model-derived variants stay within the closed widget vocabulary", () => {
  const input: ViewContract = { ...contract, types: { ...contract.types, enums: [{ name: "Variant", members: ["primary", "secondary"] }] }, model_helpers: [{ name: "variant", params: [], returns: { kind: "enum", name: "Variant" } }] };
  assert.match(compileView('<button variant="{variant}"/>', input), /variant:/);
  assert.throws(() => compileView('<button variant="{status}"/>', input), /variant/);
  assert.throws(() => compileView('<button variant="{variant}"/>', { ...input, types: { ...input.types, enums: [{ name: "Variant", members: ["primary", "unknown"] }] } }), /variant/);
});

test("playback context builds owned house chrome independently for primary and secondary windows", () => {
  const markup = '<video src="{status}" controls="true" grow="1" label="Clip"/>';
  const generated = compileViewBundle(markup, contract, {}, [{ label: "player", source: markup }]);
  const exports: { native_view?: () => Uint8Array; native_media_view?: (bytes: Uint8Array) => Uint8Array; native_media_window_view?: (label: Uint8Array, bytes: Uint8Array) => Uint8Array } = {};
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, TextDecoder, nscfCommitted: { status: new TextEncoder().encode("clip.mp4") } });
  const context = (flags: number, position: number, duration: number) => {
    const result = new Uint8Array(20); result[0] = 1; result[1] = flags;
    const data = new DataView(result.buffer); data.setFloat64(4, position, true); data.setFloat64(12, duration, true); return result;
  };
  const read = (bytes: Uint8Array) => decodedView(bytes).nodes;
  const live = context(7, 3_723_000, 7_325_000);
  const primary = read(exports.native_media_view!(live));
  assert.deepEqual(read(exports.native_media_window_view!(new TextEncoder().encode("player"), live)), primary);
  assert.equal(primary[0].videoSrc, "clip.mp4"); assert.equal(primary[0].zeroIntrinsic, true); assert.equal(primary[0].clipContent, true);
  assert.equal(primary[1].label, "Clip"); assert.equal(primary[1].image, 0x0001766964656f5f);
  assert.equal(primary[3].label, "Pause"); assert.equal(primary[3].videoControl, "toggle"); assert.equal(primary[3].disabled, false);
  assert.equal(primary[4].text, "1:02:03"); assert.equal(primary[6].text, "2:02:05");
  assert.equal(primary[5].value, Math.fround(3_723_000 / 7_325_000)); assert.equal(primary[5].videoControl, "scrub");
  const complete = read(exports.native_media_view!(context(9, 60000, 60000)));
  assert.equal(complete[3].label, "Play"); assert.equal(complete[5].disabled, true);
  assert.equal(read(exports.native_view!())[3].disabled, true); // No context leaked from either window.
  live.fill(255); assert.equal(primary[4].text, "1:02:03");
  for (const bytes of [new Uint8Array(), new Uint8Array(19), context(16, 0, 0), context(0, -1, 0), context(0, NaN, 0), context(0, 0, Infinity), context(0, .5, 0)])
    assert.throws(() => exports.native_media_view!(bytes), /playback/);
  const bad = context(0, 0, 0); bad[2] = 1; assert.throws(() => exports.native_media_view!(bad), /playback/);
});

test("bare media surfaces and dynamic icons preserve their binding types", () => {
  const input: ViewContract = { ...contract, types: { ...contract.types, enums: [{ name: "PlayIcon", members: ["pause", "play"] }], structs: [{ name: "Model", fields: [{ name: "surface", type: { kind: "i64" } }, { name: "icon", type: { kind: "enum", name: "PlayIcon" } }] }] } };
  const code = compileView('<row><media-surface surface="{surface}" grow="1" label="Frames"/><button icon="{icon}"/></row>', input);
  const exports: { native_view?: () => Uint8Array } = {};
  const model = { surface: 0x7601, icon: "pause" };
  runInNewContext(ts.transpile(code, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  const nodes = decodedView(exports.native_view!()).nodes;
  assert.equal(nodes[1].kind, "media_surface"); assert.equal(nodes[1].image, 0x7601); assert.equal(nodes[2].icon, "pause");
  assert.throws(() => compileView('<button surface="{surface}"/>', input), /requires media-surface/);
  assert.throws(() => compileView('<button icon="{count}"/>', contract), /requires text/);
});

test("compiled empty-list branches preserve keyed rows and outer scope across transitions", () => {
  const c: ViewContract = { ...contract, types: { ...contract.types, structs: [{ name: "Model", fields: [...contract.types.structs[0]!.fields, { name: "rows", type: { kind: "slice", elem: { kind: "node", name: "Row" } } }] }, { name: "Row", fields: [{ name: "id", type: { kind: "i64" } }, { name: "title", type: { kind: "bytes" } }] }] } };
  const model = { rows: [] as { id: number; title: Uint8Array }[], status: new TextEncoder().encode("No notes") };
  const exports: { native_view?: () => Uint8Array } = {};
  const markup = '<column><for each="rows" key="id" as="row"><list-item>{row.title}</list-item></for><else><text>{status}</text></else></column>';
  runInNewContext(ts.transpile(compileView(markup, c), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  const view = () => decodedView(exports.native_view!());
  assert.equal(view().nodes[1].text, "No notes");
  model.rows.push({ id: 7, title: new TextEncoder().encode("Café") });
  const occupied = view(); assert.equal(occupied.nodes.length, 2); assert.equal(occupied.nodes[1].text, "Café"); assert.equal(occupied.nodes[1].keyInt, 7);
  model.rows.length = 0; assert.equal(view().nodes[1].text, "No notes");
  assert.throws(() => compileView(markup.replace('<else>', '<else label="bad">'), c), /else accepts/);
  assert.throws(() => compileView('<column><text/><else/></column>', c), /immediately follow/);
});

test("compiled Notes conditions and context menus retain native text truthiness and owned dispatch", () => {
  const markup = '<panel on-press="reset" background="scrim"><if test="{status}"><text-field autofocus="true" focus-ring="background"/></if><else><icon name="folder"/></else><context-menu><if test="{status}"><menu-item on-press="reset">Copy</menu-item></if><else><menu-item on-press="increment">Restore</menu-item></else></context-menu></panel>';
  const { model, view } = evaluate(markup);
  let current = view(); assert.equal(current.nodes[0].background, "scrim");
  assert.equal(current.nodes[1].kind, "text_field"); assert.equal(current.nodes[1].autofocus, true); assert.equal(current.nodes[1].focusRing, "background");
  assert.equal(current.nodes[0].contextMenu[0].label, "Copy"); assert.deepEqual(current.nodes[0].contextMenu[0].press, [1, 5]);
  model.status = new Uint8Array(); const empty = view();
  assert.equal(empty.nodes[1].kind, "icon"); assert.equal(empty.nodes[1].text, "folder"); assert.equal(empty.nodes[1].icon, undefined);
  assert.equal(empty.nodes[0].contextMenu[0].label, "Restore"); assert.deepEqual(empty.nodes[0].contextMenu[0].press, [1, 3]);
  assert.equal(current.nodes[0].contextMenu[0].label, "Copy");
  assert.throws(() => compileView('<button autofocus="true"/>', contract), /text-entry/);
  assert.throws(() => compileView('<text-field focus-ring="unknown"/>', contract), /unsupported focus-ring/);
});

test("compiled byte text retains malformed UTF-8 NUL labels placeholders menus and span bytes", () => {
  const markup = '<column><text>{status}</text><text><span>{status}</span></text><text-field text="{status}" label="{status}" placeholder="{status}"/><list-item label="{status}"><text>{status}</text><context-menu><menu-item on-press="reset">{status}</menu-item></context-menu></list-item></column>';
  const { model, wire } = evaluate(markup);
  const input = new Uint8Array([0xff, 0xc3, 0x00, 0x78]); model.status = input;
  const nodes = wire().nodes;
  assert.deepEqual(nodes[1].textBytes, [...input]);
  assert.deepEqual(nodes[2].spans[0].textBytes, [...input]);
  assert.deepEqual(nodes[3].textBytes, [...input]);
  assert.deepEqual(nodes[3].labelBytes, [...input]);
  assert.deepEqual(nodes[3].placeholderBytes, [...input]);
  assert.deepEqual(nodes[4].labelBytes, [...input]);
  assert.deepEqual(nodes[4].contextMenu[0].labelBytes, [...input]);
  input.fill(0); wire();
  assert.deepEqual(nodes[1].textBytes, [0xff, 0xc3, 0x00, 0x78]);
});

test("terminal records preserve byte-named PTY ownership and full state dispatch", () => {
  const input: ViewContract = { ...contract,
    types: { structs: [...contract.types.structs,
      { name: "TerminalState", fields: ["scrollback", "history", "cols", "rows"].map(name => ({ name, type: { kind: "i64" as const } })) }] },
    msg: { arms: [{ name: "terminal_changed", member: "state", payload: { kind: "record", name: "TerminalState" } }] } };
  const generated = compileView('<terminal pty="{status}" scrollback="{count}" on-terminal="terminal_changed" autofocus="true" label="Shell"/>', input);
  const exports: { native_view?: () => Uint8Array } = {};
  const key = new Uint8Array([115, 104, 255, 0]);
  runInNewContext(ts.transpile(generated, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: { status: key, count: 4294967295 },
  });
  const node = decodedView(exports.native_view!()).nodes[0];
  assert.deepEqual(node.ptyBytes, [...key]);
  assert.equal(node.scrollback, 4294967295);
  assert.equal(node.terminal, 0);
  assert.equal(node.autofocus, true);
  for (const markup of [
    '<text pty="{status}">Wrong</text>', '<terminal pty="literal"/>',
    '<terminal pty="{ticking}"/>', '<text scrollback="2">Wrong</text>',
    '<text on-terminal="terminal_changed">Wrong</text>', '<terminal on-terminal="load"/>',
  ]) assert.throws(() => compileView(markup, input));
});

test("windowed templates secondary windows and malformed contexts preserve declaration ownership", () => {
  const names = ["start_index", "end_index", "first_visible_index", "last_visible_index", "item_extent", "item_gap", "scroll_offset", "layout_offset", "content_extent", "before_extent", "after_extent", "anchor_extent"];
  const input: ViewContract = { ...contract, types: { structs: [...contract.types.structs,
    { name: "Range", fields: names.map((name, i) => ({ name, type: { kind: i < 4 ? "i64" : "f64" } })) },
    { name: "Row", fields: [{ name: "id", type: { kind: "i64" } }] },
  ] }, model_helpers: [{ name: "rows", params: [{ kind: "value", name: "Range" }], returns: { kind: "slice", elem: { kind: "value", name: "Row" } } }] };
  const list = '<virtual-list window="range" each="rows" as="row"><list-item key="{row.id}">{row.id}</list-item></virtual-list>';
  const template = `<template name="rows-view" args="range"><column>${list}<status-bar>{range.content_extent}</status-bar></column></template>`;
  const markup = `${template}<virtual-window id="one" as="window" item-count="2" item-extent="20"><use template="rows-view" range="{window}"/></virtual-window>`;
  const exports: Record<string, (...args: Uint8Array[]) => Uint8Array> = {};
  runInNewContext(ts.transpile(compileViewBundle(markup, input, {}, [{ label: "second", source: markup.replace('id="one"', 'id="two"') }]), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), {
    exports, TextEncoder, TextDecoder, nscfCommitted: {}, rows: (_: unknown, range: Record<string, number>) => Array.from({ length: range.end_index - range.start_index }, (_, i) => ({ id: i + range.start_index })), nscfPackMsg: () => Uint8Array.of(1, 0),
  });
  const video = new Uint8Array(20); video[0] = 1;
  const label = new TextEncoder().encode("second"), context = new Uint8Array(104), wire = new DataView(context.buffer);
  wire.setUint32(0, 1, true); wire.setUint32(4, 1, true);
  [0, 2, 0, 1, 20, 0, 0, 0, 40, 0, 0, 20].forEach((n, i) => wire.setFloat64(8 + 8 * i, n, true));
  assert.equal(decodedView(exports.native_virtual_requests!(label, video)).requests[0].id, "two");
  assert.equal(decodedView(exports.native_virtual_view!(label, context, video)).nodes[4].text, "40");
  for (const [offset, value] of [[8, NaN], [16, Infinity], [24, .5], [32, -1], [40, NaN], [96, Infinity]]) {
    const invalid = context.slice(); new DataView(invalid.buffer).setFloat64(offset!, value!, true);
    assert.throws(() => exports.native_virtual_view!(label, invalid, video), /invalid virtual window/);
  }
  for (const count of [0, 2, 9]) {
    const invalid = context.slice(); new DataView(invalid.buffer).setUint32(4, count, true);
    assert.throws(() => exports.native_virtual_view!(label, invalid, video), /invalid virtual window context/);
  }
  for (const body of ['<text>missing</text>', `<column>${list}${list}</column>`]) {
    const code = compileView(`<virtual-window id="one" as="range" item-count="2" item-extent="20">${body}</virtual-window>`, input);
    const bad: Record<string, (...args: Uint8Array[]) => Uint8Array> = {};
    runInNewContext(ts.transpile(code, { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports: bad, TextEncoder, TextDecoder, nscfCommitted: {}, rows: () => [{ id: 0 }, { id: 1 }] });
    assert.throws(() => bad.native_virtual_view!(new Uint8Array(), context, video), /virtual window/);
  }
  for (const attr of ['overscroll="wrong"', 'background="wrong"', 'radius="wrong"']) assert.throws(() => compileView(markup.replace('<virtual-list ', `<virtual-list ${attr} `), input));
});


test("explicit focusable state remains a typed boolean in compiled widget data", () => {
  const { model, view } = evaluate('<list-item focusable="{ticking}" role="listitem" label="Row">Row</list-item>');
  assert.equal(view().nodes[0].focusable, true);
  model.ticking = false;
  assert.equal(view().nodes[0].focusable, false);
  assert.throws(() => compileView('<list-item focusable="{count}">Row</list-item>', contract), /boolean/);
});


test("grouped input compiles owned entry and action records with stable keys and event envelopes", () => {
  const { view, wire } = evaluate('<input-group key="composer" label="Compose" width="360" height="160" grow="1"><textarea text="{status}" label="Draft" border-color="accent" on-submit="reset"/><input-group-actions key="actions"><button on-press="increment">Attach</button><spacer grow="1"/><if test="{ticking}"><button on-press="reset">Stop</button></if><else><button on-press="increment">Send</button></else></input-group-actions></input-group>');
  const nodes = view().nodes;
  assert.equal(nodes[0].kind, "input_group"); assert.equal(nodes[0].key, "composer"); assert.equal(nodes[0].width, 360);
  assert.equal(nodes[1].kind, "textarea"); assert.equal(nodes[1].borderColor, "accent"); assert.equal(nodes[1].text, "Café\nnotes");
  assert.deepEqual(nodes[1].submit, [1, 5]); assert.equal(nodes[2].kind, "input_group_actions"); assert.equal(nodes[2].gap, 6);
  assert.equal(nodes[2].key, "actions"); assert.equal(nodes.at(-1).text, "Stop"); assert.deepEqual(nodes.at(-1).press, [1, 5]);
  assert.deepEqual(wire().nodes[1].textBytes, [...new TextEncoder().encode("Café\nnotes")]);
  assert.equal(evaluate('<input-group><textarea/><input-group-actions gap="0"/></input-group>').view().nodes[2].gap, 0);
});

test("grouped input rejects invalid structure and preserves the native compound attribute surface", () => {
  for (const markup of [
    '<input-group/>', '<input-group><button/></input-group>',
    '<input-group><textarea/><textarea/></input-group>',
    '<input-group><input-group-actions/><textarea/></input-group>',
    '<input-group><textarea/><input-group-actions/><button/></input-group>',
  ]) assert.throws(() => compileView(markup, contract), /requires a textarea/);
  assert.throws(() => compileView('<input-group-actions><button/></input-group-actions>', contract), /requires an input-group parent/);
  assert.throws(() => compileView('<input-group padding="1"><textarea/></input-group>', contract), /unsupported input-group attribute/);
  assert.throws(() => compileView('<input-group><textarea/><input-group-actions label="bad"/></input-group>', contract), /unsupported input-group-actions attribute/);
});

const chartContract: ViewContract = { ...contract, types: { structs: [{ name: "Model", fields: [
  { name: "samples", type: { kind: "slice", elem: { kind: "f64" } } },
  { name: "labels", type: { kind: "slice", elem: { kind: "bytes" } } },
  { name: "caption", type: { kind: "bytes" } },
] }] } };
const evaluateChart = (markup: string, model: unknown) => {
  const exports: { native_view?: () => Uint8Array } = {};
  runInNewContext(ts.transpile(compileView(markup, chartContract), { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.CommonJS }), { exports, TextEncoder, TextDecoder, nscfCommitted: model });
  return JSON.parse(new TextDecoder().decode(exports.native_view!())).nodes;
};
test("compiled charts retain raw labels signed zero and nonfinite words while lowering area and axes", () => {
  const model = { samples: [1.005, -0, NaN, Infinity, -Infinity], labels: [new Uint8Array([0, 255]), new Uint8Array([65])], caption: new Uint8Array([67, 0, 255]) };
  const nodes = evaluateChart('<chart height="120" grid-lines="3" baseline="true" y-labels="true" hover-details="true" x-labels="{labels}" y-min="-3" stroke-width="2.5"><series kind="area" values="{samples}" label="{caption}" color="info"/></chart>', model);
  assert.equal(nodes.length, 1);
  const node = nodes[0]; assert.equal(node.kind, "chart"); assert.equal(node.chartGridLines, 3);
  assert.equal(node.chartBaseline, true); assert.equal(node.chartYLabels, true); assert.equal(node.chartHoverDetails, true);
  assert.equal(node.chartYMin, 0xc0400000); assert.equal(node.chartStrokeWidth, 0x40200000);
  assert.deepEqual(node.chartXLabels, [[0, 255], [65]]);
  assert.deepEqual(node.chartSeries, [{ kind: "line", fill: true, color: "info", label: [67, 0, 255], values: [0x3f80a3d7, 0x80000000, 0x7fc00000, 0x7f800000, 0xff800000] }]);
  assert.deepEqual(node.labelBytes, [99,104,97,114,116,58,32,67,0,255,...new TextEncoder().encode(" 5 pts last -inf")]);
});
test("compiled charts downsample long arrays retain authored summaries and discard rebucketed x labels", () => {
  const model = { samples: Array.from({ length: 10000 }, (_, i) => i), labels: [new Uint8Array([65])], caption: new Uint8Array([0, 255]) };
  const node = evaluateChart('<chart label="{caption}" x-labels="{labels}"><series values="{samples}"/></chart>', model)[0];
  assert.equal(node.chartSeries[0].values.length, 256); assert.deepEqual(node.chartXLabels, []); assert.deepEqual(node.labelBytes, [0, 255]);
  const summary = evaluateChart('<chart><series values="{samples}"/></chart>', model)[0];
  assert.equal(new TextDecoder().decode(new Uint8Array(summary.labelBytes)), "chart: line 10000 pts last 9999.00");
});
test("compiled charts reject incorrect channels child placement and untyped arrays", () => {
  for (const markup of [
    '<chart/>', '<series values="{samples}"/>', '<chart><text>data</text></chart>',
    '<chart on-press="load"><series values="{samples}"/></chart>',
    '<chart><series kind="band" values="{samples}"/></chart>',
    '<chart><series values="{caption}"/></chart>', '<chart x-labels="{samples}"><series values="{samples}"/></chart>',
    '<chart><series values="{samples}" color="oops"/></chart>', '<chart><series values="{samples}" low="{samples}"/></chart>',
  ]) assert.throws(() => compileView(markup, chartContract));
  for (const grid of ["-1", "256", "0.5"]) assert.throws(() => evaluateChart(`<chart grid-lines="${grid}"><series values="{samples}"/></chart>`, { samples: [], labels: [], caption: new Uint8Array(0) }));
});

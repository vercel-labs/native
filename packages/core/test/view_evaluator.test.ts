// The development view evaluator must produce exactly the records the
// release view produces. For every example app, compile its views once,
// then evaluate the printed release TypeScript and the encoded program over
// the same model states, video states and virtual-window contexts.
import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import path from "node:path";
import { register, stripTypeScriptTypes } from "node:module";
import { pathToFileURL } from "node:url";
import { runInNewContext } from "node:vm";
import { checkFile } from "../src/frontend.ts";
import { compileViewProgram, type ViewContract } from "../src/view_frontend.ts";
import { appViewSources } from "../src/view_sources.ts";
import { encodeViewProgram, type ViewProgram } from "../src/view_program.ts";
import { viewBridgeIdentity, viewBridgeSource } from "../src/view_bridge.ts";
import * as textLibrary from "../sdk/text.ts";

register(new URL("../src/devhost_resolver.mjs", import.meta.url), { data: {} });

const examples = new URL("../../../examples/", import.meta.url).pathname;
const evaluatorSource = fs.readFileSync(new URL("../src/view_evaluator.ts", import.meta.url), "utf8");
// The realm is a classic script: imports become requires and exports plain declarations.
const strip = (source: string) => stripTypeScriptTypes(source, { mode: "transform" })
  .replace(/^import \{([^}]*)\} from ("[^"]+");$/gm, (_all, names: string, spec: string) => `const {${names.replace(/ as /g, ": ")}} = require(${spec});`)
  .replace(/^export /gm, "");

type Context = Record<string, any>;

/** Release and development views evaluated side by side in one realm, so
 * both call the very same portable builders. */
function realm(text: string, program: ViewProgram, contract: ViewContract, core: Record<string, unknown>): Context {
  const identity = viewBridgeIdentity(contract, evaluatorSource);
  const source = strip(text) + strip(viewBridgeSource(contract, identity)) + strip(evaluatorSource) +
    "\nglobalThis.nscvdPrepare = nscvdPrepare; globalThis.nscvdView = nscvdView;" +
    "\nglobalThis.nscvMainView = nscvMainView; globalThis.nscvEmptyVideo = nscvEmptyVideo;" +
    "\nif (typeof nscvWindowView === 'function') globalThis.nscvWindowView = nscvWindowView;" +
    "\nif (typeof nscvVirtualView === 'function') globalThis.nscvVirtualView = nscvVirtualView;\n";
  const helpers: Record<string, unknown> = {};
  for (const helper of contract.model_helpers) if (typeof core[helper.name] === "function") helpers[helper.name] = core[helper.name];
  const context: Context = {
    TextEncoder, TextDecoder, DataView, Uint8Array, Math, Number, String, Array, JSON, Error, Map,
    nscfCommitted: undefined,
    // Both views share this packer, so message literals compare structurally.
    nscfPackMsg: (msg: unknown) => new TextEncoder().encode(JSON.stringify(msg)),
    require: (name: string) => {
      assert.equal(name, "@native-sdk/core/text");
      return textLibrary;
    },
    ...helpers,
  };
  context.globalThis = context;
  runInNewContext(source, context);
  const refused = context.nscvdPrepare(encodeViewProgram(program, identity));
  assert.equal(refused, "", "the evaluator refused the program");
  return context;
}

const decode = (bytes: Uint8Array) => JSON.parse(new TextDecoder().decode(bytes));

/** Model states: boot, then every message that needs no payload, applied in order. */
function modelStates(core: Record<string, any>, contract: ViewContract): unknown[] {
  const boot = core.initialModel();
  let model = Array.isArray(boot) ? boot[0] : boot?.model ?? boot;
  const states = [model];
  for (const arm of contract.msg.arms) {
    if ((arm.payload as { kind: string }).kind !== "void" || states.length > 24) continue;
    try {
      const next = core.update(model, { kind: arm.name });
      model = Array.isArray(next) ? next[0] : next?.model ?? next;
      states.push(model);
    } catch {
      // Some messages are only meaningful after an effect result; skip them.
    }
  }
  return states;
}

const playing = { active: true, playing: true, buffering: false, completed: false, positionMs: 1234, durationMs: 98765 };

/** One fabricated layout per request, identical for both views. */
function virtualContext(requests: any[]) {
  return {
    requestsOnly: false, requests: [],
    ranges: requests.map((request: any) => {
      const end = Math.min(request.itemCount, 12);
      return { start_index: 0, end_index: end, first_visible_index: 0, last_visible_index: Math.max(0, end - 1), item_extent: request.itemExtent || 48,
        item_gap: request.gap, scroll_offset: 0, layout_offset: 0, content_extent: request.itemCount * (request.itemExtent || 48), before_extent: 0, after_extent: 0, anchor_extent: 0 };
    }),
    consumed: [],
  };
}

const apps = fs.readdirSync(examples).filter(app => fs.existsSync(path.join(examples, app, "src/core.ts"))).sort();
for (const app of apps) test(`development views match release views: ${app}`, async (t) => {
  const src = path.join(examples, app, "src");
  const { sources, windows } = appViewSources(src);
  if (fs.existsSync(path.join(src, "services")) || fs.existsSync(path.join(src, "schema"))) return t.skip("needs generated service or schema modules");
  const result = checkFile(path.join(src, "core.ts"), { contractEntry: "src/core.ts", windowViews: windows.map(window => window.label) });
  assert.ok(result.ok && result.contract, `${app}: core check failed`);
  const contract = JSON.parse(result.contract!) as ViewContract;
  const { text, program } = compileViewProgram(sources.get("app.native")!, contract, { sources }, windows);
  const core = await import(pathToFileURL(path.join(src, "core.ts")).href);
  const view = realm(text, program, contract, core);
  const virtual = /export function native_virtual_requests\(/.test(text);
  let compared = 0;
  for (const model of modelStates(core, contract)) {
    view.nscfCommitted = model;
    for (const video of [view.nscvEmptyVideo(), playing]) {
      const roots: { label: string; release: (ctx?: unknown) => Uint8Array }[] = [{ label: "", release: (ctx) => view.nscvMainView(video, ctx) }];
      for (const window of windows) roots.push({ label: window.label, release: (ctx) => view.nscvWindowView === undefined || ctx !== undefined ? view.nscvVirtualView(new TextEncoder().encode(window.label), video, ctx) : view.nscvWindowView(new TextEncoder().encode(window.label), video) });
      for (const root of roots) {
        const label = new TextEncoder().encode(root.label);
        if (!virtual) {
          assert.deepEqual(decode(view.nscvdView(label, video, undefined)), decode(root.release()), `${app} ${root.label || "main"} view`);
          compared++;
          continue;
        }
        const requestsOnly = { requestsOnly: true, requests: [], ranges: [], consumed: [] };
        const requests = decode(root.release({ ...requestsOnly, requests: [] }));
        assert.deepEqual(decode(view.nscvdView(label, video, { ...requestsOnly, requests: [] })), requests, `${app} ${root.label || "main"} virtual requests`);
        const context = () => virtualContext(requests.requests);
        assert.deepEqual(decode(view.nscvdView(label, video, context())), decode(root.release(context())), `${app} ${root.label || "main"} virtual view`);
        compared += 2;
      }
    }
  }
  assert.ok(compared > 0);
});

test("development view programs are refused unless they were compiled for this build", () => {
  const contract: ViewContract = { model: "Model", types: { structs: [{ name: "Model", fields: [{ name: "count", type: { kind: "i64" } }] }] }, model_helpers: [], msg: { arms: [{ name: "reset", payload: { kind: "void" } }, { name: "bump", payload: { kind: "void" } }] } };
  const { text, program } = compileViewProgram('<text>{count}</text>', contract, {}, []);
  const view = realm(text, program, contract, {});
  view.nscfCommitted = { count: 7 };
  const good = view.nscvdView(new Uint8Array(0), view.nscvEmptyVideo(), undefined);
  const identity = viewBridgeIdentity(contract, evaluatorSource);
  const encoded = encodeViewProgram(program, identity);
  const other = encodeViewProgram(compileViewProgram('<text>other</text>', contract, {}, []).program, "another build");
  assert.match(view.nscvdPrepare(other), /compiled for a different build of this app; rebuild the app/);
  assert.match(view.nscvdPrepare(encoded.subarray(0, encoded.length - 3)), /truncated|trailing|unknown/);
  assert.match(view.nscvdPrepare(Uint8Array.of(1, 2, 3, 4)), /not a development view program/);
  const future = encoded.slice(); future[4] = 2;
  assert.match(view.nscvdPrepare(future), /format is not supported by this build; rebuild the app/);
  // A refused program leaves the last good one active.
  assert.deepEqual(decode(view.nscvdView(new Uint8Array(0), view.nscvEmptyVideo(), undefined)), decode(good));
  assert.equal(decode(good).nodes[0].text, "7");
});

test("the evaluator writes every view node field the portable builders declare", () => {
  const declared = fs.readFileSync(new URL("../src/view_components.ts", import.meta.url), "utf8").match(/type NscViewNode = \{([\s\S]*?)\};/)![1]!;
  const fields = [...declared.matchAll(/(\w+)\??:/g)].map(match => match[1]);
  const written = [...evaluatorSource.slice(evaluatorSource.indexOf("function nscvdSetNode(")).split("\n}\n")[0]!.matchAll(/case "(\w+)": node\.\1 = /g)].map(match => match[1]);
  assert.deepEqual(written, fields);
});

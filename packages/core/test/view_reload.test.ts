// Markup reload for compiled views: the development exports, the update
// file the watcher writes, and the watcher's decisions over a session.
import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import { compileViewBundle, compileViewProgram, type ViewContract } from "../src/view_frontend.ts";
import { appViewSources } from "../src/view_sources.ts";
import { encodeViewProgram } from "../src/view_program.ts";
import {
  compileViewReload, encodeViewUpdate, viewReloadFacade, viewReloadIdentity, viewUpdateFile, viewUpdateKind, writeAtomically,
} from "../src/view_reload.ts";
import { watchViews } from "../src/view_reload_watch.ts";
import * as textLibrary from "../sdk/text.ts";

const strip = (source: string) => stripTypeScriptTypes(source, { mode: "transform" })
  .replace(/^import \{([^}]*)\} from ("[^"]+");$/gm, (_all, names: string, spec: string) => `const {${names.replace(/ as /g, ": ")}} = require(${spec});`)
  .replace(/^export /gm, "");

const contract: ViewContract = {
  model: "Model",
  types: { structs: [{ name: "Model", fields: [{ name: "count", type: { kind: "i64" } }] }] },
  model_helpers: [],
  msg: { arms: [{ name: "bump", payload: { kind: "void" } }] },
};
const shape = { windows: [], virtual: false };

function tempApp(markup: string): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "view-reload-"));
  fs.mkdirSync(path.join(root, "src"));
  fs.writeFileSync(path.join(root, "src/app.native"), markup);
  return root;
}

/** A development build's view code, as the stager appends it to the facade. */
function developmentCore(markup: string): Record<string, any> {
  const { text, virtual } = compileViewProgram(markup, contract, {}, [], undefined, true);
  const source = strip(text) + strip(viewReloadFacade(contract, viewReloadIdentity(contract, { windows: [], virtual }))) +
    "\nglobalThis.native_view = native_view; globalThis.native_dev_view_prepare = native_dev_view_prepare; globalThis.native_dev_view_reset = native_dev_view_reset;\n";
  const context: Record<string, any> = {
    TextEncoder, TextDecoder, DataView, Uint8Array, Math, Number, String, Array, JSON, Error, Map,
    nscfCommitted: { count: 7 },
    nscfPackMsg: (msg: unknown) => new TextEncoder().encode(JSON.stringify(msg)),
    require: () => textLibrary,
  };
  context.globalThis = context;
  runInNewContext(source, context);
  return context;
}

const texts = (bytes: Uint8Array): string[] => JSON.parse(new TextDecoder().decode(bytes)).nodes.map((node: { text: string }) => node.text).filter((text: string) => text);

test("release view text is unchanged; development exports only add the active-program branch", () => {
  const markup = '<column><text>{count}</text><button on-press="bump">Bump</button></column>';
  const release = compileViewProgram(markup, contract, {}, []).text;
  assert.equal(release, compileViewBundle(markup, contract, {}, []));
  const development = compileViewProgram(markup, contract, {}, [], undefined, true).text;
  // Development adds only the active-program branch to the exports and the
  // source attribution (its marks, its list and the records' extra fields).
  const body = (text: string) => text.split("\n").filter(line => !line.startsWith("export function native_") && !line.includes("nscvSource") &&
    !line.startsWith("return new TextEncoder().encode(")).join("\n");
  assert.equal(body(development), body(release));
  assert.match(development, /export function native_view\(\): Uint8Array \{ const nscvVideo = nscvEmptyVideo\(\); if \(nscvdActive\(\)\) return nscvdView\(/);
  assert.doesNotMatch(release, /nscvd/);
});

test("a prepared program replaces the compiled view until reset, and a refused one changes nothing", () => {
  const app = tempApp('<column><text>{count}</text><button on-press="bump">Bump</button></column>');
  const core = developmentCore(fs.readFileSync(path.join(app, "src/app.native"), "utf8"));
  const before = texts(core.native_view());
  assert.deepEqual(before, ["7", "Bump"]);
  fs.writeFileSync(path.join(app, "src/app.native"), '<column><text>Count {count}</text><button on-press="bump">Add one</button></column>');
  const edited = compileViewReload(appViewSources(path.join(app, "src")), path.join(app, "src"), contract, shape);
  assert.equal(edited.kind, "program");
  assert.equal(new TextDecoder().decode(core.native_dev_view_prepare(edited.kind === "program" ? edited.program : new Uint8Array(0))), "");
  assert.deepEqual(texts(core.native_view()), ["Count 7", "Add one"]);
  // A reloaded view still reports where its nodes were authored.
  const reloaded = JSON.parse(new TextDecoder().decode(core.native_view()));
  assert.equal(reloaded.sources.length, reloaded.nodes.length);
  assert.equal(reloaded.sourceFiles[0].path, "");
  core.nscfCommitted = { count: 8 };
  assert.deepEqual(texts(core.native_view()), ["Count 8", "Add one"]);
  // A program for another build is refused; the edited view stays.
  const foreign = compileViewReload(appViewSources(path.join(app, "src")), path.join(app, "src"), contract, { windows: ["settings"], virtual: false });
  assert.equal(foreign.kind, "diagnostic");
  const other = compileViewProgram("<text>other</text>", contract, {}, []);
  assert.match(new TextDecoder().decode(core.native_dev_view_prepare(encodeViewProgram(other.program, "another build"))), /rebuild the app/);
  assert.deepEqual(texts(core.native_view()), ["Count 8", "Add one"]);
  assert.equal(core.native_dev_view_reset().length, 0);
  assert.deepEqual(texts(core.native_view()), ["8", "Bump"]);
});

test("an update names its session and carries the digest of its body", () => {
  const body = Uint8Array.of(1, 2, 3, 250);
  const update = encodeViewUpdate(0x0123456789abcdefn, viewUpdateKind.program, body);
  const view = new DataView(update.buffer);
  assert.equal(new TextDecoder().decode(update.subarray(0, 4)), "NSDV");
  assert.equal(view.getUint32(4, true), 1);
  assert.equal(view.getBigUint64(8, true), 0x0123456789abcdefn);
  assert.equal(update[16], 0);
  assert.deepEqual(update.subarray(17, 49), new Uint8Array(createHash("sha256").update(body).digest()));
  assert.equal(view.getUint32(49, true), 4);
  assert.deepEqual(update.subarray(53), body);
});

test("an atomic write leaves only the finished file", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "view-reload-"));
  writeAtomically(path.join(dir, viewUpdateFile), Uint8Array.of(1));
  writeAtomically(path.join(dir, viewUpdateFile), Uint8Array.of(2, 3));
  assert.deepEqual(fs.readdirSync(dir), [viewUpdateFile]);
  assert.deepEqual([...fs.readFileSync(path.join(dir, viewUpdateFile))], [2, 3]);
});

interface Update { session: bigint; kind: number; body: Buffer }
function readUpdate(dir: string): Update {
  const bytes = fs.readFileSync(path.join(dir, viewUpdateFile));
  const body = bytes.subarray(53);
  assert.equal(bytes.readUInt32LE(49), body.length);
  assert.deepEqual(bytes.subarray(17, 49), createHash("sha256").update(body).digest());
  return { session: bytes.readBigUInt64LE(8), kind: bytes[16]!, body };
}
function announce(dir: string, session: string): void {
  writeAtomically(path.join(dir, "build.json"), new TextEncoder().encode(JSON.stringify({ format: 1, session, contract })));
}

test("the watcher reports edits for the announced session only, and returns to the compiled view", () => {
  const app = tempApp("<text>{count}</text>");
  const src = path.join(app, "src"), dir = path.join(app, ".native/dev");
  fs.mkdirSync(dir, { recursive: true });
  const watch = watchViews(src, dir);
  // Nothing happens until the app announces its session.
  fs.writeFileSync(path.join(src, "app.native"), "<text>Edited {count}</text>");
  assert.equal(watch.poll(), false);
  assert.equal(fs.existsSync(path.join(dir, viewUpdateFile)), false);
  // An edit made while the app was building reaches it as soon as it announces.
  announce(dir, "00000000000000aa");
  assert.equal(watch.poll(), true);
  let update = readUpdate(dir);
  assert.equal(update.session, 0xaan);
  assert.equal(update.kind, viewUpdateKind.program);
  assert.equal(watch.poll(), false);
  // A broken edit is a diagnostic located like `native check` locates it.
  fs.writeFileSync(path.join(src, "app.native"), "<text>{missing}</text>");
  assert.equal(watch.poll(), true);
  update = readUpdate(dir);
  assert.equal(update.kind, viewUpdateKind.diagnostic);
  const line = update.body.readUInt32LE(0), column = update.body.readUInt32LE(4), pathLen = update.body.readUInt32LE(8);
  assert.equal(update.body.subarray(12, 12 + pathLen).toString(), "src/app.native");
  assert.deepEqual([line, column], [1, 1]);
  assert.match(update.body.subarray(16 + pathLen).toString(), /compiled TypeScript view: .*missing/);
  // Back to the source the build compiled: the compiled view serves again.
  fs.writeFileSync(path.join(src, "app.native"), "<text>{count}</text>");
  assert.equal(watch.poll(), true);
  update = readUpdate(dir);
  assert.equal(update.kind, viewUpdateKind.compiled);
  assert.equal(update.body.length, 0);
  // A relaunch announces a new session; the current edit is sent again for it.
  fs.writeFileSync(path.join(src, "app.native"), "<text>Again {count}</text>");
  announce(dir, "00000000000000bb");
  assert.equal(watch.poll(), true);
  update = readUpdate(dir);
  assert.equal(update.session, 0xbbn);
  assert.equal(update.kind, viewUpdateKind.program);
});

test("adding a window view needs a rebuild", () => {
  const app = tempApp("<text>{count}</text>");
  const src = path.join(app, "src"), dir = path.join(app, ".native/dev");
  fs.mkdirSync(dir, { recursive: true });
  const watch = watchViews(src, dir);
  announce(dir, "0000000000000001");
  assert.equal(watch.poll(), false);
  fs.mkdirSync(path.join(src, "windows"));
  fs.writeFileSync(path.join(src, "windows/settings.native"), "<text>Settings</text>");
  assert.equal(watch.poll(), true);
  const update = readUpdate(dir);
  assert.equal(update.kind, viewUpdateKind.diagnostic);
  assert.match(update.body.toString(), /needs a rebuild; restart native dev/);
});

test("the identity changes with the views a build exports", () => {
  assert.notEqual(viewReloadIdentity(contract, shape), viewReloadIdentity(contract, { windows: ["settings"], virtual: false }));
  assert.notEqual(viewReloadIdentity(contract, shape), viewReloadIdentity(contract, { windows: [], virtual: true }));
  assert.equal(viewReloadIdentity(contract, shape), viewReloadIdentity(JSON.parse(JSON.stringify(contract)), { windows: [], virtual: false }));
});

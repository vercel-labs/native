// The inspector's data side: the snapshot an app answers with (DOM, styles, boxes, layers) and
// the request files the dev command's server writes. The native host is a stub, so this runs on
// any platform.
//
//   node tests/inspect.ts

import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

/** The host module's functions, as no-ops: a snapshot needs none of them to do work. */
function stubHost(dir: string): string {
  const source = readFileSync(new URL("../runtime/host.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/export declare function (\w+)/g)].map((m) => m[1]);
  const file = join(dir, "host-stub.mjs");
  const consts = [...source.matchAll(/^export const (\w+) = ([^;\n]+);/gm)].map((m) => `export const ${m[1]} = ${m[2]};`);
  writeFileSync(file, [...names.map((name) => `export function ${name}() { return 0; }`), ...consts].join("\n"));
  return pathToFileURL(file).href;
}

const dir = mkdtempSync(join(tmpdir(), "native-inspect-"));
const hostStub = stubHost(dir);
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context) as { url: string };
    if (resolved.url.endsWith("/runtime/host.ts")) return { url: hostStub, shortCircuit: true };
    return resolved;
  },
});

const { compileApp } = await import("../compiler/compile.ts");
const { Diagnostics } = await import("../compiler/diagnostics.ts");
const { mount } = await import("../runtime/app/mount.ts");
const { snapshotPage, startInspector } = await import("../runtime/app/inspect.ts");
const { devHighlight } = await import("../runtime/paint.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const appDir = join(dir, "app");
mkdirSync(appDir, { recursive: true });
const html = [
  "<!doctype html>",
  "<html>",
  "  <head><title>Inspector</title><style>#box { padding: 4px 8px; }</style></head>",
  "  <body>",
  "    <div id=\"box\" style=\"transform: translateX(10px); width: 120px; height: 40px\">",
  "      <button id=\"b\">Press</button>",
  "    </div>",
  "    <div id=\"w\" style=\"will-change: transform; width: 10px; height: 10px\"></div>",
  "  </body>",
  "</html>",
].join("\n");
writeFileSync(join(appDir, "index.html"), html);
const diags = new Diagnostics();
const app = compileApp(join(appDir, "index.html"), diags);
check("the page compiles", diags.errorCount === 0, diags.format(false));
mount(app.tables);

const snap = snapshotPage();
const byId = new Map(snap.nodes.map((node) => [node.id, node]));
const root = byId.get(snap.root);
check("the tree starts at the document", root !== undefined && root.type === 9 && root.name === "#document", JSON.stringify(root));
const htmlEl = snap.nodes.find((node) => node.type === 1 && node.name === "html");
check("the document has the page element", htmlEl !== undefined && root !== undefined && root.children.indexOf(htmlEl.id) >= 0);
const button = snap.nodes.find((node) => node.type === 1 && node.name === "button");
check("the button is in the tree", button !== undefined && button.id > 0);
const text = button === undefined ? undefined : byId.get(button.children[0]);
check("its text is a child node", text !== undefined && text.type === 3 && text.text === "Press", text === undefined ? "no child" : text.text);
check("a computed style is there", button !== undefined && button.styles.display !== "", button?.styles.display);
check("the box model reads the padding", button !== undefined && button.box !== null && button.box.padding[0] >= 0, JSON.stringify(button?.box));
check("the snapshot has the page's size", snap.width > 0 && snap.height > 0, `${snap.width}x${snap.height}`);

const box = snap.nodes.find((node) => node.type === 1 && node.id !== htmlEl?.id && node.attrs.some(([name, value]) => name === "id" && value === "box"));
check("a transformed element is a layer", snap.layers.some((layer) => layer.id === box?.id && layer.reason.indexOf("transform") >= 0), JSON.stringify(snap.layers));
check("the root is the first layer", snap.layers.length > 0 && snap.layers[0].depth === 0);
const will = snap.nodes.find((node) => node.type === 1 && node.attrs.some(([name, value]) => name === "id" && value === "w"));
check("will-change asks for a layer", snap.layers.some((layer) => layer.id === will?.id && layer.reason.indexOf("will-change") >= 0), JSON.stringify(snap.layers));

// --- The request files the dev command's inspector writes --------------------------------

const inspectDir = join(dir, "inspect");
startInspector(inspectDir);
mkdirSync(inspectDir, { recursive: true });

async function ask(id: number, body: { [key: string]: unknown }): Promise<any> {
  const request = join(inspectDir, `req-${id}.json`);
  writeFileSync(request, JSON.stringify({ id, op: body.op, ...body }));
  for (let i = 0; i < 100; i++) {
    const answer = join(inspectDir, `res-${id}.json`);
    if (existsSync(answer)) return JSON.parse(readFileSync(answer, "utf8"));
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 10));
  }
  throw new Error(`request ${id} went unanswered`);
}

const snapshotAnswer = await ask(1, { op: "snapshot" });
check("a snapshot request is answered", snapshotAnswer.ok === true && snapshotAnswer.result.nodes.length > 0);
const queryAnswer = await ask(2, { op: "query", selector: "#box" });
check("a query finds the element", queryAnswer.ok === true && queryAnswer.result === box?.id, String(queryAnswer.result));
const styleAnswer = await ask(3, { op: "style", nodeId: button?.id ?? 0 });
check("a style request answers the properties", styleAnswer.ok === true && styleAnswer.result.display === button?.styles.display);
const boxAnswer = await ask(4, { op: "box", nodeId: box?.id ?? 0 });
check("a box request answers the padding", boxAnswer.ok === true && boxAnswer.result.box.padding[1] === 8, JSON.stringify(boxAnswer.result));
const highlightAnswer = await ask(5, { op: "highlight", nodeId: box?.id ?? 0 });
check("a highlight sets the overlay", highlightAnswer.ok === true && devHighlight.box !== null, JSON.stringify(highlightAnswer));
const clearAnswer = await ask(6, { op: "clear" });
check("a clear removes it", clearAnswer.ok === true && devHighlight.box === null);
const badAnswer = await ask(7, { op: "no-such-op" });
check("an unknown request is answered empty", badAnswer.ok === true && badAnswer.result === null);

console.log(failed === 0 ? "all passed" : `${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

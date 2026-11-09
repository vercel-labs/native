#!/usr/bin/env node
// Check a TypeScript app's markup against its core: compile every view
// exactly as the build does (src/app.native plus src/windows/*.native,
// against the frontend's core contract), then report model state and Msg
// kinds no view uses.
//
//   view_check.ts --contract <core.contract.json> --src <app src dir>
//
// Diagnostics go to stderr in the markup checker's format. stdout carries
// one JSON line, {"errors":N,"warnings":N}, for the caller's summary and
// --strict promotion.
//
// Exit codes: 0 checked (see stdout for the verdict); 2 usage.

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { compileViewBundle, type ViewContract, type ViewUsage } from "./view_frontend.ts";
import { appViewSources } from "./view_sources.ts";

interface Ref { kind: string; name?: string; elem?: Ref }
interface CheckContract extends ViewContract {
  model_unbound?: string[];
  msg: ViewContract["msg"] & { unbound?: string[] };
}

export interface ViewCheckResult {
  readonly error: string | null;
  readonly warnings: readonly string[];
}

/// Compile the app's views beside `contract` and lint unused model state.
/// `srcLabel` prefixes diagnostic paths (the views' paths are relative to
/// the source directory).
export function checkAppViews(contract: CheckContract, srcDir: string, srcLabel = "src"): ViewCheckResult {
  const { sources, windows } = appViewSources(srcDir);
  const root = sources.get("app.native");
  if (root === undefined) return { error: `${srcLabel}/app.native: error: a TypeScript app needs a root view at ${srcLabel}/app.native`, warnings: [] };
  const usage: ViewUsage = { model: new Set(), msg: new Set() };
  // The compiler names files relative to each view's own import root:
  // src/ for the root view, src/windows/ for a secondary window. Compile
  // each view on its own so a failure is reported under the right root,
  // then the whole bundle once for the checks that span views.
  const compile = (run: () => void, root: string): string | null => {
    try {
      run();
      return null;
    } catch (err) {
      if (!(err instanceof Error)) throw err;
      return locate(err.message, root);
    }
  };
  const error = compile(() => compileViewBundle(root, contract, { sources }, [], usage), srcLabel) ??
    windows.reduce<string | null>((found, window) => found ?? compile(() =>
      compileViewBundle(window.source, contract, { entry: window.entry, sources: window.sources }, [], usage), `${srcLabel}/windows`), null) ??
    compile(() => compileViewBundle(root, contract, { sources }, windows), srcLabel);
  return error ? { error, warnings: [] } : { error: null, warnings: unusedState(contract, usage) };
}

/// "app.native:3:5: compiled TypeScript view: …" becomes
/// "src/app.native:3:5: error: compiled TypeScript view: …", where the
/// prefix is the import root the compiler resolved the file against.
function locate(message: string, importRoot: string): string {
  const located = /^([^:\n]+\.native):(\d+):(\d+): ([\s\S]*)$/.exec(message);
  if (located) return `${importRoot}/${located[1]}:${located[2]}:${located[3]}: error: ${located[4]}`;
  return `error: ${message}`;
}

/// The entry exports the generated launcher wires to host channels (theme,
/// status items, windows, canvas chrome, …). A model helper with one of
/// these names feeds the host, never markup. Kept equal to the frontend
/// checker's entry-only export set by test/view_check.test.ts.
export const entryChannelExports: ReadonlySet<string> = new Set([
  "update", "initialModel", "subscriptions", "migrate",
  "commandMsg", "keyMsg", "frameMsg", "pinchMsg", "dropMsg", "appearanceMsg", "chromeMsg", "envMsgs", "themePack", "themeState", "tokenOverrides", "statusItem", "statusItems", "windows", "webPanes", "layoutTweens", "canvasIcons", "canvasChrome", "canvasChromeSuffix", "canvasAnimations", "canvasFrameMsg", "bootImageMsg", "sliderStateMsg",
  "viewUnbound", "modelUnbound", "msgUnbound",
]);

/// One warning per top-level Model field, zero-argument model helper and
/// Msg kind that no view binds or dispatches, minus the `viewUnbound`
/// opt-outs and the host-channel helpers. Model-only state is legitimate,
/// so these are warnings.
export function unusedState(contract: CheckContract, usage: ViewUsage): string[] {
  const warnings: string[] = [];
  const modelUnbound = new Set(contract.model_unbound ?? []);
  const msgUnbound = new Set(contract.msg.unbound ?? []);
  const fields = contract.types.structs.find(item => item.name === contract.model)?.fields ?? [];
  for (const field of fields) {
    if (usage.model.has(field.name) || modelUnbound.has(field.name)) continue;
    const type = field.type as Ref;
    if (type.kind === "slice" && type.elem?.kind !== "u8") {
      warnings.push(`model list "${field.name}" (${typeText(type)}) is never iterated in markup - use it with for each, or list it in viewUnbound if only update or effect logic reads it`);
    } else if (["node", "value", "record"].includes(type.kind)) {
      warnings.push(`model field "${field.name}" (${typeText(type)}) has no markup binding into any of its fields - bind one, or list it in viewUnbound if only update or effect logic reads it`);
    } else {
      warnings.push(`model field "${field.name}" (${typeText(type)}) is never bound in markup - bind it, or list it in viewUnbound if only update or effect logic reads it`);
    }
  }
  for (const helper of contract.model_helpers) {
    if (helper.params.length !== 0 || usage.model.has(helper.name) || modelUnbound.has(helper.name) || entryChannelExports.has(helper.name)) continue;
    warnings.push(`model helper "${helper.name}" (returns ${typeText(helper.returns as Ref)}) is never bound in markup - bind it, remove it, or list it in viewUnbound if only update or effect logic calls it`);
  }
  for (const arm of contract.msg.arms) {
    if (usage.msg.has(arm.name) || msgUnbound.has(arm.name)) continue;
    warnings.push(`Msg kind "${arm.name}" is never dispatched from markup - wire it to an on-* event, or list it in viewUnbound if only update, subscriptions or effects send it`);
  }
  return warnings;
}

function typeText(ref: Ref): string {
  switch (ref.kind) {
    case "i64": case "f64": case "u64": case "u32": case "i32": case "number": return "number";
    case "bool": return "boolean";
    case "bytes": case "string": return "string";
    case "slice": return ref.elem ? `${typeText(ref.elem)}[]` : "array";
    default: return ref.name ?? ref.kind;
  }
}

function main(argv: readonly string[]): number {
  let contractPath: string | null = null;
  let srcDir: string | null = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--contract") contractPath = argv[++i] ?? null;
    else if (argv[i] === "--src") srcDir = argv[++i] ?? null;
    else {
      console.error(`view_check: unknown argument ${argv[i]}`);
      return 2;
    }
  }
  if (!contractPath || !srcDir) {
    console.error("usage: view_check.ts --contract <core.contract.json> --src <app src dir>");
    return 2;
  }
  const contract = JSON.parse(fs.readFileSync(contractPath, "utf8")) as CheckContract;
  const result = checkAppViews(contract, srcDir, path.relative(process.cwd(), srcDir).split(path.sep).join("/") || ".");
  if (result.error) console.error(result.error);
  for (const warning of result.warnings) console.error(`warning: ${warning}`);
  process.stdout.write(JSON.stringify({ errors: result.error ? 1 : 0, warnings: result.warnings.length }) + "\n");
  return 0;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}

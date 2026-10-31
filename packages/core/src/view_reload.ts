/** The development view loop's build-time half. A Debug app built for view
 * reload stages the development evaluator beside its compiled views; while
 * `native dev` runs, a watcher recompiles the app's markup with the same view
 * compiler the build uses and hands the running app one update file:
 *
 *   magic "NSDV", u32 format, u64 session, u8 kind, sha256(body), u32 length, body
 *
 * `kind` is a view program (0), a markup diagnostic (1), or a return to the
 * compiled view (2). The update names the app session it was compiled for,
 * so an update left over from another launch is never applied, and its
 * digest lets the app refuse a partial or damaged file. The watcher writes
 * it with a rename, so the app sees either the previous update or the next.
 */
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { compileViewProgram, type ViewContract } from "./view_frontend.ts";
import type { AppViewSources } from "./view_sources.ts";
import { encodeViewProgram } from "./view_program.ts";
import { viewBridgeIdentity, viewBridgeSource } from "./view_bridge.ts";
import { checkAppViews } from "./view_check.ts";

const evaluatorSource = fs.readFileSync(new URL("./view_evaluator.ts", import.meta.url), "utf8");
const programSource = fs.readFileSync(new URL("./view_program.ts", import.meta.url), "utf8");

export const viewUpdateFile = "view.update";
export const viewBuildFile = "build.json";
export const viewUpdateFormat = 1;
export const viewUpdateKind = { program: 0, diagnostic: 1, compiled: 2 } as const;

/** The views a build exports. A program can only replace views the build
 * already serves, so a change to this shape needs a rebuild.
 */
export interface ViewShape { readonly windows: readonly string[]; readonly virtual: boolean }

/** Names the build a program can run in: the contract, the evaluator and
 * program format, and the exported views.
 */
export function viewReloadIdentity(contract: ViewContract, shape: ViewShape): string {
  return viewBridgeIdentity(contract, [evaluatorSource, programSource, JSON.stringify(shape)].join("\0"));
}

/** The development evaluator, its per-app bridge and the two development
 * exports, appended to a core facade compiled with development views.
 */
export function viewReloadFacade(contract: ViewContract, identity: string): string {
  return "\n" + viewBridgeSource(contract, identity) + evaluatorSource +
    "\n/** Attribute the view nodes in [start, end) that no inner element claimed to `source`. */\n" +
    "function nscvSourceMark(sources: number[], start: number, end: number, source: number): void {\n" +
    "  while (sources.length < end) sources.push(-1);\n" +
    "  for (let i = start; i < end; i++) if (sources[i]! < 0) sources[i] = source;\n" +
    "}\n" +
    "\n/** Activate a changed view program. Empty when it is active, else why it was refused; the last good view stays. */\n" +
    "export function native_dev_view_prepare(program: Uint8Array): Uint8Array { return new TextEncoder().encode(nscvdPrepare(program)); }\n" +
    "/** Serve the compiled views again. */\n" +
    "export function native_dev_view_reset(): Uint8Array { nscvdReset(); return new Uint8Array(0); }\n";
}

export interface ViewDiagnostic { readonly path: string; readonly line: number; readonly column: number; readonly message: string }

export type ViewReloadResult =
  | { readonly kind: "program"; readonly program: Uint8Array }
  | { readonly kind: "diagnostic"; readonly diagnostic: ViewDiagnostic };

/** Compile `views` (read from `srcDir`) exactly as the build does, for a
 * build whose views have `shape`. `srcLabel` prefixes diagnostic paths.
 */
export function compileViewReload(views: AppViewSources, srcDir: string, contract: ViewContract, shape: ViewShape, srcLabel = "src"): ViewReloadResult {
  const { sources, windows } = views;
  const root = sources.get("app.native");
  if (root === undefined) return { kind: "diagnostic", diagnostic: { path: `${srcLabel}/app.native`, line: 0, column: 0, message: "a TypeScript app needs a root view" } };
  let compiled: ReturnType<typeof compileViewProgram>;
  try {
    // A development compile: the program carries where each node was
    // authored, so provenance and write-back keep working after a reload.
    compiled = compileViewProgram(root, contract, { sources }, windows, undefined, true);
  } catch (err) {
    if (!(err instanceof Error)) throw err;
    // The checker compiles each view against its own import root, so its
    // message names the file the way `native check` does.
    return { kind: "diagnostic", diagnostic: parseDiagnostic(checkAppViews(contract, srcDir, srcLabel).error ?? `error: ${err.message}`) };
  }
  const current: ViewShape = { windows: windows.map(window => window.label), virtual: compiled.virtual };
  if (JSON.stringify(current) !== JSON.stringify(shape)) {
    return { kind: "diagnostic", diagnostic: { path: "", line: 0, column: 0, message: "adding or removing a window view or a virtual window needs a rebuild; restart native dev to apply this change" } };
  }
  return { kind: "program", program: encodeViewProgram(compiled.program, viewReloadIdentity(contract, shape)) };
}

/** The shape of `views`, or null when they do not compile. */
export function viewShapeOf(views: AppViewSources, contract: ViewContract): ViewShape | null {
  const { sources, windows } = views;
  const root = sources.get("app.native");
  if (root === undefined) return null;
  try {
    return { windows: windows.map(window => window.label), virtual: compileViewProgram(root, contract, { sources }, windows).virtual };
  } catch {
    return null;
  }
}

/** "src/app.native:3:5: error: compiled TypeScript view: …" */
function parseDiagnostic(text: string): ViewDiagnostic {
  const located = /^([^:\n]+\.native):(\d+):(\d+): error: ([\s\S]*)$/.exec(text);
  if (located) return { path: located[1]!, line: Number(located[2]), column: Number(located[3]), message: located[4]! };
  return { path: "", line: 0, column: 0, message: text.replace(/^error: /, "") };
}

/** A hash of every markup file the build compiles, paths included. */
export function viewSourcesDigest(views: AppViewSources): string {
  const hash = createHash("sha256");
  for (const [name, source] of [...views.sources].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
    hash.update(name).update("\0").update(source).update("\0");
  }
  return hash.digest("hex");
}

export function encodeViewUpdate(session: bigint, kind: number, body: Uint8Array): Uint8Array {
  const out = new Uint8Array(53 + body.length);
  const view = new DataView(out.buffer);
  out.set([78, 83, 68, 86], 0);
  view.setUint32(4, viewUpdateFormat, true);
  view.setBigUint64(8, session, true);
  out[16] = kind;
  out.set(createHash("sha256").update(body).digest(), 17);
  view.setUint32(49, body.length, true);
  out.set(body, 53);
  return out;
}

export function encodeViewDiagnostic(diagnostic: ViewDiagnostic): Uint8Array {
  const pathBytes = new TextEncoder().encode(diagnostic.path), message = new TextEncoder().encode(diagnostic.message);
  const out = new Uint8Array(16 + pathBytes.length + message.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, diagnostic.line, true);
  view.setUint32(4, diagnostic.column, true);
  view.setUint32(8, pathBytes.length, true);
  out.set(pathBytes, 12);
  view.setUint32(12 + pathBytes.length, message.length, true);
  out.set(message, 16 + pathBytes.length);
  return out;
}

/** Replace `file` in one step, so a reader never sees a partial write. */
export function writeAtomically(file: string, bytes: Uint8Array): void {
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(temporary, bytes);
  fs.renameSync(temporary, file);
}

/** What a running app announces in `build.json` when view reload is armed. */
export interface ViewBuild { readonly session: bigint; readonly contract: ViewContract }

export function readViewBuild(dir: string): ViewBuild | null {
  let text: string;
  try {
    text = fs.readFileSync(path.join(dir, viewBuildFile), "utf8");
  } catch {
    return null;
  }
  const parsed = JSON.parse(text) as { format?: number; session?: string; contract?: ViewContract };
  if (parsed.format !== viewUpdateFormat || typeof parsed.session !== "string" || !/^[0-9a-f]{16}$/.test(parsed.session) || !parsed.contract) {
    throw new Error(`${path.join(dir, viewBuildFile)} was written by a different SDK version; rebuild the app`);
  }
  return { session: BigInt("0x" + parsed.session), contract: parsed.contract };
}

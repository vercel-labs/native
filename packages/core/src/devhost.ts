#!/usr/bin/env node
// The core-logic dev harness: run a TypeScript app core under node with a
// virtual host — the fastest behavioral loop for update/effects work. This
// is NOT a renderer: no window, no markup, no pixels (`native dev` runs the
// real app). What it gives you is the dispatch cycle at conversation speed:
//
//   node devhost.ts src/core.ts                 # interactive (NDJSON on stdin)
//   node devhost.ts src/core.ts --script msgs.ndjson
//
// Input, one JSON object per line:
//   {"kind":"add"}                       dispatch a Msg (payload fields ride
//                                        along; {"$bytes":"text"} values
//                                        become Uint8Array)
//   {"advance": 500}                     advance the virtual clock 500ms,
//                                        firing due Sub timers and Cmd.delay
//                                        one-shots in time order
//   {"restart": true}                    simulate a new process boot; an
//                                        in-memory Cmd.persist snapshot restores
//                                        through the configured boot route
//
// Transcript, one line per fact:
//   model <json>                         the committed model after a dispatch
//                                        (Uint8Array fields as {"$bytes":...})
//   cmd <op> <details>                   an effect the dispatch requested
//   sub arm|re-arm|cancel <key>          subscription reconciliation by key
//   fire <key> -> <kind> @ <ms>          a virtual timer fired (dispatched)
//
// Virtual-host semantics match the compiled core's (node = native; the
// SDK's ts-core e2e batteries pin the native side over real archives):
//   - Cmd.now dispatches its arm immediately at the current virtual time;
//   - Sub.timer reconciles by key after every commit (new key or changed
//     interval arms, missing key cancels), each fire dispatching the named
//     arm with the virtual time;
//   - Cmd.delay arms a one-shot; re-issuing a live key re-arms from now
//     (the debounce discipline), Cmd.cancel drops it;
//   - timer/now/delay arms carry exactly one number payload field (pinned
//     by tsc), so the harness constructs them shape-directed without
//     needing the field's name.
// Cmd.persist snapshots the committed model in virtual-host memory and typed
// app services execute directly through their generated contract. Other
// effects (files, fetch, clipboard, notifications, spawn, audio, raw host
// commands) are printed as `cmd ...` and NOT performed — feed their result
// back yourself as an ordinary Msg line. Results remain plain messages.

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { register } from "node:module";
import { pathToFileURL } from "node:url";
import os from "node:os";
import crypto from "node:crypto";
import { Worker } from "node:worker_threads";
import { installTextMethods } from "./text_polyfill.ts";
import { checkFile, formatDiagnostic } from "./frontend.ts";
import { DevhostJournalWriter, readDevhostJournal, requestKeyBase } from "./devhost_journal.mjs";

interface Cmdish {
  readonly op: string;
  readonly [field: string]: unknown;
}

function usage(): never {
  console.error("usage: devhost.ts <core.ts> [--script <msgs.ndjson>]");
  console.error("core-logic loop only (update/effects under a virtual host) - not a renderer;");
  console.error("run the real app with `native dev`.");
  process.exit(2);
}

const args = process.argv.slice(2);
let entry: string | null = null;
let script: string | null = null;
let persistOk: string | null = null;
let persistNone: string | null = null;
let persistErr: string | null = null;
let journalRecordArg: string | null = null;
let journalReplayArg: string | null = null;
let canvasLabel = "canvas";
let windowWidth = 800;
let windowHeight = 600;
let appName: string | null = null;
const servicePackages: { name: string; version: string; content_hash: string }[] = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--script") script = args[++i] ?? null;
  else if (args[i] === "--persist-ok") persistOk = args[++i] ?? null;
  else if (args[i] === "--persist-none") persistNone = args[++i] ?? null;
  else if (args[i] === "--persist-err") persistErr = args[++i] ?? null;
  else if (args[i] === "--record-journal") journalRecordArg = args[++i] ?? null;
  else if (args[i] === "--replay-journal") journalReplayArg = args[++i] ?? null;
  else if (args[i] === "--canvas-label") canvasLabel = args[++i] ?? canvasLabel;
  else if (args[i] === "--window-width") windowWidth = Number(args[++i]);
  else if (args[i] === "--window-height") windowHeight = Number(args[++i]);
  else if (args[i] === "--app-name") appName = args[++i] ?? null;
  else if (args[i] === "--service-package") {
    const [name, version, content_hash] = (args[++i] ?? "").split("|");
    if (!name || !version || !/^[0-9a-f]{64}$/.test(content_hash ?? "")) usage();
    servicePackages.push({ name, version, content_hash });
  }
  else if (args[i] === "--help" || args[i] === "-h") usage();
  else if (!args[i].startsWith("-")) entry = args[i];
  else usage();
}
if (!entry) usage();
if (!Number.isFinite(windowWidth) || windowWidth <= 0 || !Number.isFinite(windowHeight) || windowHeight <= 0) usage();
const journalRecordPath = process.env.NATIVE_SDK_SESSION_RECORD ?? journalRecordArg;
const journalReplayPath = process.env.NATIVE_SDK_SESSION_REPLAY ?? journalReplayArg;
if (journalRecordPath && journalReplayPath) throw new Error("record and replay cannot be armed together");
const persistRouteCount = [persistOk, persistNone, persistErr].filter((route) => route !== null).length;
if (persistRouteCount !== 0 && persistRouteCount !== 3) usage();
let checked: ReturnType<typeof checkFile> | null = null;
if ((persistOk !== null && persistNone !== null && persistErr !== null) || fs.existsSync(path.join(path.dirname(path.resolve(entry)), "services"))) {
  // Type information is erased by the time this module imports the app core.
  // Run the frontend inside the watched process so every node --watch restart
  // revalidates manifest-owned routes against the newly edited Msg union.
  checked = checkFile(entry, {
    capabilities: persistOk === null ? [] : ["persist"],
    persistRoutes: persistOk !== null && persistNone !== null && persistErr !== null ? { ok: persistOk, none: persistNone, err: persistErr } : undefined,
    servicesContract: true,
    servicePackages,
  });
  for (const error of checked.typeErrors) console.error(error);
  for (const diagnostic of checked.diagnostics) console.error(formatDiagnostic(diagnostic));
  for (const warning of checked.warnings) console.error(formatDiagnostic(warning, "warning"));
  if (!checked.ok) process.exit(1);
}

// The resolver hook maps "@native-sdk/core" onto this package's own SDK
// module (app trees carry no node_modules for bare resolution to find),
// and the byte-text methods (s.toUpperCase(), s.split(sep), ...) install
// on Uint8Array.prototype before the core loads — locale-free simple
// case tables, the semantics the compiled core carries natively.
installTextMethods();
const devScratch = fs.mkdtempSync(path.join(os.tmpdir(), "native-services-dev-"));
const servicesClientPath = path.join(devScratch, "services.gen.ts");
if (checked?.servicesClient) {
  fs.writeFileSync(servicesClientPath, checked.servicesClient);
  const editorDir = path.join(path.dirname(path.dirname(path.resolve(entry))), "node_modules", "@native-sdk", "services");
  fs.mkdirSync(editorDir, { recursive: true });
  const sourcePrefix = path.relative(editorDir, path.dirname(path.resolve(entry))).split(path.sep).join("/");
  fs.writeFileSync(path.join(editorDir, "index.ts"), checked.servicesClient.replaceAll('from "./', `from "${sourcePrefix}/`));
  fs.writeFileSync(path.join(editorDir, "package.json"), `${JSON.stringify({
    name: "@native-sdk/services",
    private: true,
    type: "module",
    types: "./index.ts",
    exports: { ".": { types: "./index.ts", default: "./index.ts" } },
  }, null, 2)}\n`);
}

function packageRuntimeEntry(packageName: string): string {
  const packageRoot = path.join(path.dirname(path.resolve(entry!)), "services", "vendor", ...packageName.split("/"));
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8")) as Record<string, unknown>;
  let target: unknown = manifest.module ?? manifest.main ?? "index.js";
  const exportsField = manifest.exports;
  if (typeof exportsField === "string") target = exportsField;
  else if (exportsField && typeof exportsField === "object") {
    const rootExport = (exportsField as Record<string, unknown>)["."] ?? exportsField;
    if (typeof rootExport === "string") target = rootExport;
    else if (rootExport && typeof rootExport === "object") {
      const choices = rootExport as Record<string, unknown>;
      target = choices.import ?? choices.node ?? choices.default ?? target;
    }
  }
  if (typeof target !== "string") throw new Error(`cannot resolve the runtime entry of vendored service package ${packageName}`);
  return pathToFileURL(path.resolve(packageRoot, target)).href;
}

function verifyDevPackage(packageEntry: { name: string; version: string; content_hash: string }): void {
  const packageRoot = path.join(path.dirname(path.resolve(entry!)), "services", "vendor", ...packageEntry.name.split("/"));
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8")) as { name?: string; version?: string };
  if (manifest.name !== packageEntry.name || manifest.version !== packageEntry.version) {
    throw new Error(`vendored ${packageEntry.name} is ${manifest.name ?? "?"}@${manifest.version ?? "?"}, expected ${packageEntry.name}@${packageEntry.version}`);
  }
  const files: { rel: string; absolute: string }[] = [];
  const walk = (current: string, prefix = ""): void => {
    for (const item of fs.readdirSync(current, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${item.name}` : item.name;
      const absolute = path.join(current, item.name);
      if (item.isSymbolicLink()) throw new Error(`vendored package contains a symlink: ${rel}`);
      if (item.isDirectory()) walk(absolute, rel);
      else if (item.isFile()) files.push({ rel, absolute });
    }
  };
  walk(packageRoot);
  files.sort((a, b) => a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0);
  const hash = crypto.createHash("sha256");
  hash.update("native-sdk.service-package.v1\0");
  for (const file of files) {
    const bytes = fs.readFileSync(file.absolute);
    const size = Buffer.alloc(8);
    size.writeBigUInt64LE(BigInt(bytes.length));
    hash.update(file.rel); hash.update("\0"); hash.update(size); hash.update(bytes);
  }
  const actual = hash.digest("hex");
  if (actual !== packageEntry.content_hash) throw new Error(`vendored ${packageEntry.name}@${packageEntry.version} hashes to ${actual}, expected ${packageEntry.content_hash}`);
}

for (const packageEntry of servicePackages) verifyDevPackage(packageEntry);

const resolverData = {
  servicesClientUrl: checked?.servicesClient ? pathToFileURL(servicesClientPath).href : null,
  servicePackages: Object.fromEntries(servicePackages.map((packageEntry) => [packageEntry.name, packageRuntimeEntry(packageEntry.name)])),
};
register(new URL("./devhost_resolver.mjs", import.meta.url), { data: resolverData });

interface ServiceTypeRef {
  readonly kind: string;
  readonly name?: string;
  readonly inner?: ServiceTypeRef;
  readonly elem?: ServiceTypeRef;
}
interface ServiceOperationRuntime {
  readonly name: string;
  readonly module: string;
  readonly export: string;
  readonly request: ServiceTypeRef;
  readonly result: ServiceTypeRef;
  readonly deadline_ms: number | null;
  readonly cancellable: boolean;
  readonly stream: { readonly chunk: ServiceTypeRef; readonly in_flight: number } | null;
}
const serviceContract = checked?.servicesContract ? JSON.parse(checked.servicesContract) as {
  operations: ServiceOperationRuntime[];
  types: { records: { name: string; fields: { name: string; type: ServiceTypeRef }[] }[]; enums: { name: string; members: string[] }[]; unions: { name: string; arms: { name: string; fields: { name: string; type: ServiceTypeRef }[] }[] }[] };
} : null;
const serviceOperations = new Map(serviceContract?.operations.map((operation) => [operation.name, operation]) ?? []);

const mod = await import(pathToFileURL(path.resolve(entry)).href);
if (typeof mod.initialModel !== "function" || typeof mod.update !== "function") {
  console.error(`${entry} is not an app core: it must export initialModel() and update(model, msg)`);
  process.exit(1);
}

// ---------------------------------------------------------- transcript i/o

const decoder = new TextDecoder();
const encoder = new TextEncoder();

function jsonable(value: unknown): unknown {
  if (value instanceof Uint8Array) return { $bytes: decoder.decode(value) };
  if (Array.isArray(value)) return value.map(jsonable);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = jsonable(v);
    return out;
  }
  return value;
}

function revive(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(revive);
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if (typeof record.$bytes === "string" && Object.keys(record).length === 1) {
      return encoder.encode(record.$bytes);
    }
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(record)) out[k] = revive(v);
    return out;
  }
  return value;
}

function say(line: string): void {
  process.stdout.write(line + "\n");
}

// --------------------------------------------------------- the virtual host

let now = 0;
/// Armed repeating timers (Sub.timer), by key.
const timers = new Map<string, { everyMs: number; msgKind: string; nextAt: number }>();
/// Armed one-shots (Cmd.delay), by key.
const delays = new Map<string, { msgKind: string; at: number }>();
const serviceChannels = new Map<number, string>();
/// Process-local Tier-1 store. `structuredClone` preserves Uint8Array and
/// nested model data without making the app own a serialization format.
let persistedModel: unknown | null = null;

/// Timer/now/delay arms carry exactly one number payload field (tsc pins
/// the shape), so a proxy that answers every non-kind read with the
/// timestamp IS the arm value — no field name needed.
function timestampMsg(kind: string, atMs: number): unknown {
  return new Proxy(
    { kind },
    {
      get: (target, prop) => (prop === "kind" ? kind : atMs),
      has: () => true,
    },
  );
}

function bytesMsg(kind: string, bytes: Uint8Array): unknown {
  return new Proxy(
    { kind },
    {
      get: (_target, prop) => (prop === "kind" ? kind : bytes),
      has: () => true,
    },
  );
}

function valueMsg(kind: string, value: unknown): unknown {
  return new Proxy({ kind }, { get: (_target, prop) => prop === "kind" ? kind : value, has: () => true });
}

class ServiceReader {
  at = 0;
  readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; }
  take(length: number): Uint8Array {
    if (this.at + length > this.bytes.length) throw new Error("truncated service value");
    const value = this.bytes.subarray(this.at, this.at + length);
    this.at += length;
    return value;
  }
  u8(): number { return this.take(1)[0]; }
  u32(): number { const b = this.take(4); return (b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24) >>> 0; }
  f64(): number { const b = this.take(8); return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true); }
  i64(): number { const b = this.take(8); const v = new DataView(b.buffer, b.byteOffset, 8); return v.getUint32(0, true) + v.getInt32(4, true) * 4294967296; }
}

function decodeServiceValue(type: ServiceTypeRef, reader: ServiceReader): unknown {
  switch (type.kind) {
    case "bool": { const value = reader.u8(); if (value > 1) throw new Error("invalid service boolean"); return value === 1; }
    case "f64": return reader.f64();
    case "i64": return reader.i64();
    case "bytes": return reader.take(reader.u32());
    case "optional": { const present = reader.u8(); if (present === 0) return null; if (present !== 1) throw new Error("invalid service optional"); return decodeServiceValue(type.inner!, reader); }
    case "slice": { const count = reader.u32(); return Array.from({ length: count }, () => decodeServiceValue(type.elem!, reader)); }
    case "record": {
      const record = serviceContract!.types.records.find((candidate) => candidate.name === type.name)!;
      return Object.fromEntries(record.fields.map((field) => [field.name, decodeServiceValue(field.type, reader)]));
    }
    case "enum": {
      const enumType = serviceContract!.types.enums.find((candidate) => candidate.name === type.name)!;
      const value = enumType.members[reader.u32()];
      if (value === undefined) throw new Error("invalid service enum");
      return value;
    }
    case "union": {
      const unionType = serviceContract!.types.unions.find((candidate) => candidate.name === type.name)!;
      const arm = unionType.arms[reader.u8()];
      if (!arm) throw new Error("invalid service union");
      return { kind: arm.name, ...Object.fromEntries(arm.fields.map((field) => [field.name, decodeServiceValue(field.type, reader)])) };
    }
    default: throw new Error(`unsupported service type ${type.kind}`);
  }
}

function serviceErrorBytes(error: unknown): Uint8Array {
  if (error && typeof error === "object") {
    const value = error as { kind?: unknown; name?: unknown; message?: unknown };
    const kind = typeof value.kind === "string" ? value.kind : typeof value.name === "string" ? value.name : "service_error";
    const message = typeof value.message === "string" ? value.message : "service operation threw";
    return encoder.encode(JSON.stringify({ kind, message }));
  }
  return encoder.encode(JSON.stringify({ kind: "service_error", message: "service operation threw" }));
}

function serviceU32(value: number): Uint8Array {
  return new Uint8Array([value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255]);
}

function concatService(parts: readonly Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}

function encodeServiceValue(type: ServiceTypeRef, value: unknown): Uint8Array {
  switch (type.kind) {
    case "bool": return new Uint8Array([value ? 1 : 0]);
    case "f64": { const out = new Uint8Array(8); new DataView(out.buffer).setFloat64(0, value as number, true); return out; }
    case "i64": {
      const out = new Uint8Array(8); const view = new DataView(out.buffer); const number = value as number; const base = 4294967296;
      let low = number % base; if (low < 0) low += base;
      view.setUint32(0, low, true); view.setInt32(4, Math.floor(number / base), true); return out;
    }
    case "bytes": return concatService([serviceU32((value as Uint8Array).length), value as Uint8Array]);
    case "optional": return value === null ? new Uint8Array([0]) : concatService([new Uint8Array([1]), encodeServiceValue(type.inner!, value)]);
    case "slice": return concatService([serviceU32((value as unknown[]).length), ...(value as unknown[]).map((item) => encodeServiceValue(type.elem!, item))]);
    case "record": {
      const record = serviceContract!.types.records.find((candidate) => candidate.name === type.name)!;
      return concatService(record.fields.map((field) => encodeServiceValue(field.type, (value as Record<string, unknown>)[field.name])));
    }
    case "enum": {
      const enumType = serviceContract!.types.enums.find((candidate) => candidate.name === type.name)!;
      return serviceU32(enumType.members.indexOf(value as string));
    }
    case "union": {
      const unionType = serviceContract!.types.unions.find((candidate) => candidate.name === type.name)!;
      const record = value as Record<string, unknown>;
      const index = unionType.arms.findIndex((arm) => arm.name === record.kind);
      const arm = unionType.arms[index];
      return concatService([new Uint8Array([index]), ...arm.fields.map((field) => encodeServiceValue(field.type, record[field.name]))]);
    }
    default: throw new Error(`unsupported service type ${type.kind}`);
  }
}

function channelMsg(kind: string, key: number, state: "data" | "closed", bytes = new Uint8Array(0)): unknown {
  return { kind, key, state, bytes, droppedPending: 0, droppedTotal: 0 };
}

interface ServiceTask {
  readonly id: number;
  readonly cmd: Cmdish;
  readonly operation: ServiceOperationRuntime;
  readonly request: unknown;
  readonly channelKey: number | null;
  readonly channelEvent: string | null;
  readonly cancelFlag: Int32Array;
  readonly engineIndex: number;
  deadlineTimer: ReturnType<typeof setTimeout> | null;
  hardTimer: ReturnType<typeof setTimeout> | null;
  cancelled: boolean;
  timedOut: boolean;
  responseDelivered: boolean;
  chunks: number;
}

const cooperativeCancelGraceMs = 100;
const serviceQueue: ServiceTask[] = [];
const serviceTasksByKey = new Map<string, ServiceTask>();
const serviceIdleWaiters: (() => void)[] = [];
const serviceRequestSlots: (ServiceTask | null)[] = Array.from({ length: 16 }, () => null);
let activeService: ServiceTask | null = null;
let serviceWorker: Worker | null = null;
let serviceWorkerReady = false;
let serviceRestart: Promise<void> | null = null;
let nextServiceId = 1;
let journalWriter: DevhostJournalWriter | null = null;

function releaseServiceSlot(task: ServiceTask): void {
  if (serviceRequestSlots[task.engineIndex] === task) serviceRequestSlots[task.engineIndex] = null;
}

function closeServiceChannel(task: ServiceTask): void {
  if (task.channelKey === null || task.channelEvent === null) return;
  if (serviceChannels.has(task.channelKey)) {
    if (journalWriter) { journalWriter.channel(task.channelKey, "closed"); journalWriter.wake(); }
    dispatch(channelMsg(task.channelEvent, task.channelKey, "closed"));
  }
  serviceChannels.delete(task.channelKey);
}

function serviceKey(task: ServiceTask): string | null {
  return typeof task.cmd.key === "string" && task.cmd.key.length > 0 ? task.cmd.key : null;
}

function removeServiceKey(task: ServiceTask): void {
  const key = serviceKey(task);
  if (key !== null && serviceTasksByKey.get(key) === task) serviceTasksByKey.delete(key);
}

function settleServiceWaiters(): void {
  if (activeService || serviceQueue.length > 0 || serviceRestart) return;
  for (const resolve of serviceIdleWaiters.splice(0)) resolve();
}

function waitForServicesIdle(): Promise<void> {
  if (!activeService && serviceQueue.length === 0 && !serviceRestart) return Promise.resolve();
  return new Promise((resolve) => serviceIdleWaiters.push(resolve));
}

function serviceFailure(task: ServiceTask, bytes: Uint8Array): void {
  if (task.responseDelivered) return;
  task.responseDelivered = true;
  if (journalWriter) { journalWriter.host(task.engineIndex, false, bytes); journalWriter.wake(); }
  releaseServiceSlot(task);
  dispatch(bytesMsg(task.cmd.errKind as string, bytes));
}

function serviceSuccess(task: ServiceTask, result: unknown): void {
  if (task.responseDelivered) return;
  task.responseDelivered = true;
  const wireResult = task.operation.result.kind === "bytes" ? result as Uint8Array : encodeServiceValue(task.operation.result, result);
  if (journalWriter) { journalWriter.host(task.engineIndex, true, wireResult); journalWriter.wake(); }
  releaseServiceSlot(task);
  if (task.cmd.typedService === true) dispatch(valueMsg(task.cmd.okKind as string, result));
  else dispatch(bytesMsg(
    task.cmd.okKind as string,
    task.operation.result.kind === "bytes" ? result as Uint8Array : encodeServiceValue(task.operation.result, result),
  ));
}

function finishService(task: ServiceTask, message: { type: "result" | "error"; result?: unknown; error?: unknown; elapsed: number }): void {
  if (activeService !== task) return;
  if (task.deadlineTimer) clearTimeout(task.deadlineTimer);
  if (task.hardTimer) clearTimeout(task.hardTimer);
  say(`service ${task.operation.name} ${message.type === "result" ? "ok" : "err"} ${message.elapsed.toFixed(3)}ms`);
  if (task.timedOut) {
    serviceFailure(task, encoder.encode(JSON.stringify({ kind: "timeout", message: "service request timed out" })));
  } else if (!task.cancelled) {
    if (message.type === "result") serviceSuccess(task, message.result);
    else serviceFailure(task, serviceErrorBytes(message.error));
  }
  closeServiceChannel(task);
  removeServiceKey(task);
  activeService = null;
  startNextService();
}

function stopWorkerFor(task: ServiceTask): void {
  if (activeService !== task) return;
  if (task.deadlineTimer) clearTimeout(task.deadlineTimer);
  if (task.hardTimer) clearTimeout(task.hardTimer);
  if (task.timedOut) serviceFailure(task, encoder.encode(JSON.stringify({ kind: "timeout", message: "service request timed out" })));
  closeServiceChannel(task);
  removeServiceKey(task);
  activeService = null;
  const worker = serviceWorker;
  serviceWorker = null;
  serviceWorkerReady = false;
  if (worker) {
    worker.removeAllListeners();
    serviceRestart = worker.terminate().then(() => undefined, () => undefined).finally(() => {
      serviceRestart = null;
      startNextService();
      settleServiceWaiters();
    });
  } else startNextService();
}

function requestServiceStop(task: ServiceTask, timeout: boolean): void {
  if (activeService !== task) return;
  if (timeout) task.timedOut = true;
  else {
    task.cancelled = true;
    releaseServiceSlot(task);
  }
  Atomics.store(task.cancelFlag, 0, 1);
  if (!timeout && task.operation.stream !== null && !task.responseDelivered) {
    serviceFailure(task, encoder.encode("cancelled"));
    closeServiceChannel(task);
  }
  if (!task.hardTimer) task.hardTimer = setTimeout(() => stopWorkerFor(task), cooperativeCancelGraceMs);
}

function makeServiceWorker(): Worker {
  const appRoot = path.dirname(path.dirname(path.resolve(entry!)));
  const worker = new Worker(new URL("./devhost_service_worker.mjs", import.meta.url), {
    workerData: {
      resolverData,
      operations: serviceContract!.operations.map((operation) => ({
        ...operation,
        absoluteModule: path.resolve(appRoot, operation.module),
      })),
    },
  });
  worker.on("message", (message: { id?: number; type: string; chunk?: unknown; result?: unknown; error?: unknown; elapsed?: number }) => {
    if (message.type === "ready") {
      serviceWorkerReady = true;
      startNextService();
      return;
    }
    const task = activeService;
    if (!task || message.id !== task.id) return;
    if (message.type === "chunk") {
      if (!task.cancelled && !task.timedOut && task.channelKey !== null && task.channelEvent !== null && serviceChannels.has(task.channelKey)) {
        task.chunks += 1;
        const bytes = encodeServiceValue(task.operation.stream!.chunk, message.chunk);
        if (journalWriter) { journalWriter.channel(task.channelKey, "data", bytes); journalWriter.wake(); }
        dispatch(channelMsg(task.channelEvent, task.channelKey, "data", bytes));
      }
      return;
    }
    if (message.type === "result" || message.type === "error") {
      finishService(task, { type: message.type, result: message.result, error: message.error, elapsed: message.elapsed ?? 0 });
    }
  });
  const failed = (): void => {
    const task = activeService;
    serviceWorker = null;
    serviceWorkerReady = false;
    if (!task) return;
    if (!task.cancelled && !task.timedOut) serviceFailure(task, encoder.encode(JSON.stringify({ kind: "service_host", message: "service worker exited" })));
    else if (task.timedOut) serviceFailure(task, encoder.encode(JSON.stringify({ kind: "timeout", message: "service request timed out" })));
    closeServiceChannel(task);
    removeServiceKey(task);
    releaseServiceSlot(task);
    activeService = null;
    startNextService();
  };
  worker.once("error", failed);
  // `process.exit(0)` inside an allowed service is still an unexpected host
  // loss when a request is active. Intentional termination removes these
  // listeners first.
  worker.once("exit", () => { if (worker === serviceWorker) failed(); });
  return worker;
}

function startNextService(): void {
  if (activeService || serviceRestart || serviceQueue.length === 0) {
    settleServiceWaiters();
    return;
  }
  if (journalReplayPath) return;
  if (!serviceWorker) serviceWorker = makeServiceWorker();
  if (!serviceWorkerReady) return;
  const task = serviceQueue.shift()!;
  activeService = task;
  if (task.operation.deadline_ms !== null) {
    task.deadlineTimer = setTimeout(() => requestServiceStop(task, true), task.operation.deadline_ms);
  }
  serviceWorker.postMessage({
    id: task.id,
    name: task.operation.name,
    request: task.request,
    cancelBuffer: task.cancelFlag.buffer,
  });
}

function enqueueService(cmd: Cmdish, operation: ServiceOperationRuntime, request: unknown, channelKey: number | null, channelEvent: string | null): boolean {
  const key = typeof cmd.key === "string" && cmd.key.length > 0 ? cmd.key : null;
  if (key !== null && serviceTasksByKey.has(key)) {
    dispatch(bytesMsg(cmd.errKind as string, encoder.encode("rejected")));
    return false;
  }
  const engineIndex = serviceRequestSlots.findIndex((slot) => slot === null);
  if (engineIndex < 0) {
    dispatch(bytesMsg(cmd.errKind as string, encoder.encode(JSON.stringify({ kind: "service_host", message: "more than 16 service requests are live" }))));
    return false;
  }
  const task: ServiceTask = {
    id: nextServiceId++, cmd, operation, request, channelKey, channelEvent,
    cancelFlag: new Int32Array(new SharedArrayBuffer(4)),
    engineIndex,
    deadlineTimer: null, hardTimer: null, cancelled: false, timedOut: false, responseDelivered: false, chunks: 0,
  };
  serviceRequestSlots[engineIndex] = task;
  if (key !== null) serviceTasksByKey.set(key, task);
  serviceQueue.push(task);
  return true;
}

function cancelService(key: string): boolean {
  const task = serviceTasksByKey.get(key);
  if (!task) return false;
  const queued = serviceQueue.indexOf(task);
  if (queued >= 0) {
    serviceQueue.splice(queued, 1);
    task.cancelled = true;
    if (task.operation.stream !== null) {
      serviceFailure(task, encoder.encode("cancelled"));
      closeServiceChannel(task);
    }
    removeServiceKey(task);
    releaseServiceSlot(task);
    settleServiceWaiters();
  } else requestServiceStop(task, false);
  return true;
}

function performCmd(cmd: Cmdish): void {
  switch (cmd.op) {
    case "none":
      return;
    case "batch":
      for (const inner of cmd.cmds as Cmdish[]) performCmd(inner);
      return;
    case "now":
      say(`cmd now -> ${cmd.msgKind} @ ${now}`);
      dispatch(timestampMsg(cmd.msgKind as string, now));
      return;
    case "delay": {
      const key = cmd.key as string;
      const rearmed = delays.has(key);
      delays.set(key, { msgKind: cmd.msgKind as string, at: now + (cmd.afterMs as number) });
      say(`cmd delay ${rearmed ? "re-arm" : "arm"} ${key} +${cmd.afterMs}ms -> ${cmd.msgKind}`);
      return;
    }
    case "cancel": {
      const key = cmd.key as string;
      if (delays.delete(key)) {
        say(`cmd cancel ${key} (delay dropped)`);
      } else if (cancelService(key)) {
        say(`cmd cancel ${key} (service cancellation requested)`);
      } else {
        say(`cmd cancel ${key} (not performed here - a live request or buffered named op drops silently; a live spawn or streaming fetch ends loudly, err arm "cancelled")`);
      }
      return;
    }
    case "persist":
      try {
        persistedModel = structuredClone(model);
        say("cmd persist (stored in virtual host memory)");
      } catch {
        say("cmd persist rejected by virtual host");
        if (persistErr) dispatch(bytesMsg(persistErr, encoder.encode("rejected")));
      }
      return;
    case "channel_open": {
      const channelKey = cmd.key as number;
      const eventKind = cmd.eventKind as string;
      if (!Number.isSafeInteger(channelKey) || channelKey < 1 || serviceChannels.has(channelKey)) {
        dispatch(channelMsg(eventKind, Number.isSafeInteger(channelKey) && channelKey >= 1 ? channelKey : 0, "rejected"));
        return;
      }
      serviceChannels.set(channelKey, eventKind);
      say(`cmd channel_open key=${channelKey} event=${eventKind}`);
      return;
    }
    case "channel_close": {
      const channelKey = cmd.key as number;
      const event = serviceChannels.get(channelKey);
      if (event) dispatch(channelMsg(event, channelKey, "closed"));
      serviceChannels.delete(channelKey);
      return;
    }
    case "request": {
      const operation = serviceOperations.get(cmd.name as string);
      if (!operation) break;
      try {
        const reader = new ServiceReader(cmd.payload as Uint8Array);
        let channelKey: number | null = null;
        let channelEvent: string | null = null;
        if (operation.stream !== null) {
          channelKey = reader.f64();
          channelEvent = serviceChannels.get(channelKey) ?? null;
          if (!channelEvent) throw new Error("streaming service request has no open channel");
        }
        const request = operation.request.kind === "none"
          ? undefined
          : operation.request.kind === "bytes"
            ? reader.take(reader.bytes.length - reader.at)
            : decodeServiceValue(operation.request, reader);
        if (reader.at !== reader.bytes.length) throw new Error("trailing service request bytes");
        if (enqueueService(cmd, operation, request, channelKey, channelEvent)) startNextService();
      } catch (error) {
        say(`service ${operation.name} err 0.000ms`);
        dispatch(bytesMsg(cmd.errKind as string, serviceErrorBytes(error)));
      }
      return;
    }
    case "service_stream_request": {
      const operation = serviceOperations.get(cmd.name as string);
      if (!operation || operation.stream === null) break;
      const eventKind = cmd.eventKind as string;
      const requestedChannelKey = cmd.channelKey as number;
      try {
        const reader = new ServiceReader(cmd.payload as Uint8Array);
        const payloadChannelKey = reader.f64();
        const representable = Number.isSafeInteger(requestedChannelKey) && requestedChannelKey >= 1;
        if (!representable || payloadChannelKey !== requestedChannelKey) {
          dispatch(channelMsg(eventKind, representable ? requestedChannelKey : 0, "rejected"));
          dispatch(bytesMsg(cmd.errKind as string, encoder.encode("rejected")));
          return;
        }
        if (serviceChannels.has(requestedChannelKey)) {
          dispatch(channelMsg(eventKind, requestedChannelKey, "rejected"));
          dispatch(bytesMsg(cmd.errKind as string, encoder.encode("rejected")));
          return;
        }
        const request = operation.request.kind === "none"
          ? undefined
          : operation.request.kind === "bytes"
            ? reader.take(reader.bytes.length - reader.at)
            : decodeServiceValue(operation.request, reader);
        if (reader.at !== reader.bytes.length) throw new Error("trailing service request bytes");
        if (!enqueueService(cmd, operation, request, requestedChannelKey, eventKind)) return;
        serviceChannels.set(requestedChannelKey, eventKind);
        say(`cmd channel_open key=${requestedChannelKey} event=${eventKind}`);
        startNextService();
      } catch (error) {
        say(`service ${operation.name} err 0.000ms`);
        dispatch(bytesMsg(cmd.errKind as string, serviceErrorBytes(error)));
      }
      return;
    }
    case "show_notification": {
      const details = Object.entries(cmd)
        .filter(([k]) => k !== "op")
        .map(([k, v]) => `${k}=${JSON.stringify(jsonable(v))}`)
        .join(" ");
      say(`cmd ${cmd.op} ${details}`.trimEnd() + " (not performed by the virtual host; no result Msg)");
      return;
    }
    default: {
      // Every other effect is the host's job; print the request and let
      // the author feed the result back as an ordinary Msg line.
      const details = Object.entries(cmd)
        .filter(([k]) => k !== "op")
        .map(([k, v]) => `${k}=${JSON.stringify(jsonable(v))}`)
        .join(" ");
      say(`cmd ${cmd.op} ${details}`.trimEnd() + " (not performed - feed the result back as a Msg line)");
      return;
    }
  }
}

function reconcileSubs(): void {
  if (typeof mod.subscriptions !== "function") return;
  const declared = new Map<string, { everyMs: number; msgKind: string }>();
  const collect = (sub: Cmdish): void => {
    if (sub.op === "timer") {
      declared.set(sub.key as string, { everyMs: sub.everyMs as number, msgKind: sub.msgKind as string });
    } else if (sub.op === "batch") {
      for (const inner of sub.subs as Cmdish[]) collect(inner);
    }
  };
  collect(mod.subscriptions(model) as Cmdish);
  for (const [key, spec] of declared) {
    const active = timers.get(key);
    if (!active) {
      timers.set(key, { ...spec, nextAt: now + spec.everyMs });
      say(`sub arm ${key} every ${spec.everyMs}ms -> ${spec.msgKind}`);
    } else if (active.everyMs !== spec.everyMs || active.msgKind !== spec.msgKind) {
      timers.set(key, { ...spec, nextAt: now + spec.everyMs });
      say(`sub re-arm ${key} every ${spec.everyMs}ms -> ${spec.msgKind}`);
    }
  }
  for (const key of [...timers.keys()]) {
    if (!declared.has(key)) {
      timers.delete(key);
      say(`sub cancel ${key}`);
    }
  }
}

function advance(ms: number): void {
  const deadline = now + ms;
  for (;;) {
    // The earliest due fire wins; ties go to timers in arm order.
    let dueAt = Infinity;
    let fire: (() => void) | null = null;
    for (const [key, timer] of timers) {
      if (timer.nextAt <= deadline && timer.nextAt < dueAt) {
        dueAt = timer.nextAt;
        fire = () => {
          timer.nextAt += timer.everyMs;
          say(`fire ${key} -> ${timer.msgKind} @ ${now}`);
          dispatch(timestampMsg(timer.msgKind, now));
        };
      }
    }
    for (const [key, delay] of delays) {
      if (delay.at <= deadline && delay.at < dueAt) {
        dueAt = delay.at;
        fire = () => {
          delays.delete(key);
          say(`fire ${key} -> ${delay.msgKind} @ ${now}`);
          dispatch(timestampMsg(delay.msgKind, now));
        };
      }
    }
    if (!fire) break;
    now = dueAt;
    fire();
  }
  now = deadline;
}

// ------------------------------------------------------------ the dispatch

let model: unknown = null;
journalWriter = journalRecordPath ? new DevhostJournalWriter(
  journalRecordPath,
  appName ?? path.basename(path.dirname(path.dirname(path.resolve(entry)))),
  canvasLabel,
  windowWidth,
  windowHeight,
) : null;
if (journalWriter) {
  journalWriter.appStart();
  journalWriter.installFrame(canvasLabel, windowWidth, windowHeight);
}
boot();

function boot(): void {
  const booted = mod.initialModel();
  const [first, cmd] = Array.isArray(booted) ? booted : [booted, null];
  const restored = persistedModel !== null;
  model = restored ? structuredClone(persistedModel) : first;
  say(`model ${JSON.stringify(jsonable(model))}`);
  if (cmd) performCmd(cmd as Cmdish);
  reconcileSubs();
  const route = restored ? persistOk : persistNone;
  if (route) dispatch({ kind: route });
}

function dispatch(msg: unknown): void {
  const result = mod.update(model, msg);
  const [next, cmd] = Array.isArray(result) ? result : [result, null];
  model = next;
  say(`model ${JSON.stringify(jsonable(model))}`);
  if (cmd) performCmd(cmd as Cmdish);
  reconcileSubs();
}

function handleLine(raw: string): void {
  const line = raw.trim();
  if (line.length === 0 || line.startsWith("#")) return;
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    console.error(`not JSON: ${line}`);
    return;
  }
  const record = parsed as Record<string, unknown>;
  if (typeof record.command === "string") {
    if (typeof mod.commandMsg !== "function") throw new Error("journalable dev-host commands require the core to export commandMsg(name)");
    const msg = mod.commandMsg(record.command);
    if (msg === null || msg === undefined) throw new Error(`commandMsg refused ${record.command}`);
    dispatch(msg);
    if (journalWriter) journalWriter.menuCommand(record.command);
    return;
  }
  if (typeof record.advance === "number") {
    advance(record.advance);
    return;
  }
  if (record.restart === true) {
    timers.clear();
    delays.clear();
    say("restart virtual host");
    boot();
    return;
  }
  if (typeof record.kind !== "string") {
    console.error(`neither a Msg ({"kind": ...}) nor {"advance": ms}: ${line}`);
    return;
  }
  if (journalWriter) throw new Error("session recording accepts {\"command\":\"...\"} inputs, not direct Msg values, so the journal can replay through the packaged platform boundary");
  dispatch(revive(parsed));
}

function replayServiceEffect(effect: { kind: number; key: bigint; payload: Uint8Array; code: number; dropped: number; channelKind: number; channelDroppedTotal: number }): void {
  if (effect.kind === 9) {
    const index = Number(effect.key - requestKeyBase);
    const task = Number.isSafeInteger(index) && index >= 0 && index < serviceRequestSlots.length ? serviceRequestSlots[index] : null;
    if (!task) throw new Error(`session replay has no pending service request for engine key ${effect.key}`);
    const queued = serviceQueue.indexOf(task);
    if (queued >= 0) serviceQueue.splice(queued, 1);
    if (effect.code === 0) {
      const result = task.operation.result.kind === "bytes"
        ? effect.payload
        : decodeServiceValue(task.operation.result, new ServiceReader(effect.payload));
      say(`service ${task.operation.name} replay ok`);
      serviceSuccess(task, result);
    } else {
      say(`service ${task.operation.name} replay err`);
      serviceFailure(task, effect.payload);
    }
    removeServiceKey(task);
    return;
  }
  if (effect.kind === 12) {
    const key = Number(effect.key);
    const event = serviceChannels.get(key);
    if (!event) throw new Error(`session replay has no open service channel ${key}`);
    const state = effect.channelKind === 0 ? "data" : "closed";
    dispatch({ kind: event, key, state, bytes: effect.payload, droppedPending: effect.dropped, droppedTotal: effect.channelDroppedTotal });
    if (effect.channelKind !== 0) serviceChannels.delete(key);
    return;
  }
  throw new Error(
    `native dev --core replays typed-service host/channel records only; this journal contains effect kind ${effect.kind}. Use native automate replay for full-runtime recordings.`,
  );
}

function replaySession(): void {
  const pending: { kind: number; key: bigint; payload: Uint8Array; code: number; dropped: number; channelKind: number; channelDroppedTotal: number }[] = [];
  for (const record of readDevhostJournal(journalReplayPath!)) {
    if (record.type === "effect") {
      pending.push(record);
      continue;
    }
    for (const effect of pending.splice(0)) replayServiceEffect(effect);
    if (record.tag === 14) {
      if (typeof mod.commandMsg !== "function") throw new Error("this recorded menu command requires the core to export commandMsg(name)");
      const msg = mod.commandMsg(record.name);
      if (msg === null || msg === undefined) throw new Error(`commandMsg refused recorded command ${record.name}`);
      dispatch(msg);
    }
  }
  if (pending.length > 0) throw new Error("session journal ends with undrained effect results");
  if (serviceQueue.length > 0 || activeService) throw new Error("session journal ended before every service request received its recorded result");
}

async function waitForServiceChunk(): Promise<void> {
  const deadline = performance.now() + 5_000;
  while ((!activeService || activeService.chunks === 0) && performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  if (!activeService || activeService.chunks === 0) throw new Error("timed out waiting for a streaming service chunk");
}

if (journalReplayPath) {
  replaySession();
  fs.rmSync(devScratch, { recursive: true, force: true });
} else if (script) {
  for (const line of fs.readFileSync(script, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length > 0 && !trimmed.startsWith("#")) {
      const control = JSON.parse(trimmed) as Record<string, unknown>;
      if (control.settle === true) {
        await waitForServicesIdle();
        continue;
      }
      if (control.waitForServiceChunk === true) {
        await waitForServiceChunk();
        continue;
      }
    }
    handleLine(line);
  }
  await waitForServicesIdle();
  journalWriter?.finish();
  if (serviceWorker) await serviceWorker.terminate();
  fs.rmSync(devScratch, { recursive: true, force: true });
} else {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", handleLine);
  rl.on("close", async () => {
    await waitForServicesIdle();
    journalWriter?.finish();
    if (serviceWorker) await serviceWorker.terminate();
    fs.rmSync(devScratch, { recursive: true, force: true });
  });
}

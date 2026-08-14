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
// Cmd.persist snapshots the committed model in virtual-host memory, and
// capability-enabled Cmd.store performs against a process-local byte map;
// Cmd.db uses a real process-local SQLite database, and typed app services
// execute directly through their generated contract.
// Every other effect (files, buffered/streaming fetch, clipboard,
// notifications, spawn, audio, raw host commands)
// is printed as `cmd ...` and NOT performed — feed its result back yourself
// as an ordinary Msg line. That is the point: results are plain messages,
// and the loop stays deterministic.

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { register } from "node:module";
import { constants as sqliteConstants, DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import os from "node:os";
import crypto from "node:crypto";
import { Worker } from "node:worker_threads";
import { installTextMethods } from "./text_polyfill.ts";
import { checkFile, formatDiagnostic } from "./frontend.ts";
import { DevhostJournalWriter, readDevhostJournal, requestKeyBase } from "./devhost_journal.mjs";
import { inspectRelationalSql, relationalRuntimePolicy, setRelationalAuthorizer } from "./sqlite_runtime_policy.ts";

interface Cmdish {
  readonly op: string;
  readonly [field: string]: unknown;
}

function usage(): never {
  console.error("usage: devhost.ts <core.ts> [--script <msgs.ndjson>] [--service-cwd <app-data-dir>] [--app-id <id>] [--capability <name>]... [--permission <name>]... [--sdk-core <generated-core.ts>] [--sqlite-src <src>]");
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
let sdkCore: string | null = null;
let sqliteSrc: string | null = null;
let journalRecordArg: string | null = null;
let journalReplayArg: string | null = null;
let serviceCwd: string | null = null;
let canvasLabel = "canvas";
let windowWidth = 800;
let windowHeight = 600;
let appName: string | null = null;
let appId = "app";
const servicePackages: { name: string; version: string; content_hash: string }[] = [];
const capabilities = new Set<string>();
const permissions = new Set<string>();
let windowViewsEnabled = false;
const windowViews: string[] = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--script") script = args[++i] ?? null;
  else if (args[i] === "--capability") {
    const capability = args[++i] ?? null;
    if (capability === null) usage();
    capabilities.add(capability);
  }
  else if (args[i] === "--permission") {
    const permission = args[++i] ?? null;
    if (permission === null) usage();
    permissions.add(permission);
  }
  else if (args[i] === "--window-views") windowViewsEnabled = true;
  else if (args[i] === "--window-view") {
    windowViewsEnabled = true;
    const label = args[++i] ?? null;
    if (label === null || label.length === 0) usage();
    windowViews.push(label);
  }
  else if (args[i] === "--persist-ok") persistOk = args[++i] ?? null;
  else if (args[i] === "--persist-none") persistNone = args[++i] ?? null;
  else if (args[i] === "--persist-err") persistErr = args[++i] ?? null;
  else if (args[i] === "--sdk-core") sdkCore = args[++i] ?? null;
  else if (args[i] === "--sqlite-src") sqliteSrc = args[++i] ?? null;
  else if (args[i] === "--record-journal") journalRecordArg = args[++i] ?? null;
  else if (args[i] === "--replay-journal") journalReplayArg = args[++i] ?? null;
  else if (args[i] === "--service-cwd") serviceCwd = args[++i] ?? null;
  else if (args[i] === "--canvas-label") canvasLabel = args[++i] ?? canvasLabel;
  else if (args[i] === "--window-width") windowWidth = Number(args[++i]);
  else if (args[i] === "--window-height") windowHeight = Number(args[++i]);
  else if (args[i] === "--app-name") appName = args[++i] ?? null;
  else if (args[i] === "--app-id") appId = args[++i] ?? appId;
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
const launchCwd = process.cwd();
entry = path.resolve(launchCwd, entry);
if (script !== null) script = path.resolve(launchCwd, script);
if (serviceCwd !== null) serviceCwd = path.resolve(launchCwd, serviceCwd);
const journalRecordValue = process.env.NATIVE_SDK_SESSION_RECORD ?? journalRecordArg;
const journalReplayValue = process.env.NATIVE_SDK_SESSION_REPLAY ?? journalReplayArg;
const journalRecordPath = journalRecordValue ? path.resolve(launchCwd, journalRecordValue) : null;
const journalReplayPath = journalReplayValue ? path.resolve(launchCwd, journalReplayValue) : null;
if (journalRecordPath && journalReplayPath) throw new Error("record and replay cannot be armed together");
if (serviceCwd !== null) {
  fs.mkdirSync(serviceCwd, { recursive: true });
  process.chdir(serviceCwd);
}
const persistRouteCount = [persistOk, persistNone, persistErr].filter((route) => route !== null).length;
if (persistRouteCount !== 0 && persistRouteCount !== 3) usage();
let checked: ReturnType<typeof checkFile> | null = null;
if (capabilities.size > 0 || permissions.size > 0 || windowViewsEnabled || (persistOk !== null && persistNone !== null && persistErr !== null) || fs.existsSync(path.join(path.dirname(path.resolve(entry)), "services"))) {
  // Type information is erased by the time this module imports the app core.
  // Run the frontend inside the watched process so every node --watch restart
  // revalidates manifest-owned routes against the newly edited Msg union.
  checked = checkFile(entry, {
    capabilities: [...new Set([...capabilities, ...(persistOk === null ? [] : ["persist"])])],
    permissions: [...permissions],
    persistRoutes: persistOk !== null && persistNone !== null && persistErr !== null ? { ok: persistOk, none: persistNone, err: persistErr } : undefined,
    servicesContract: true,
    servicePackages,
    sdkCorePath: sdkCore ?? undefined,
    windowViews: windowViewsEnabled ? windowViews : undefined,
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
  generatedCoreUrl: sdkCore === null ? null : pathToFileURL(path.resolve(sdkCore)).href,
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
const strictDecoder = new TextDecoder("utf-8", { fatal: true });
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
interface VirtualStoreRecord {
  readonly key: Uint8Array;
  readonly value: Uint8Array;
}

/// Process-local Tier-2 store. Like SQLite, record identity is the encoded
/// UTF-8 key rather than the source JavaScript string. That distinction is
/// observable for ill-formed UTF-16: TextEncoder canonicalizes every lone
/// surrogate to U+FFFD, so strings with the same encoded bytes must address
/// one record here just as they do in the native host.
const recordStore = new Map<string, VirtualStoreRecord>();
/// Process-local Tier-4 backing. The namespace includes the manifest app id,
/// matching the native keychain service/account split. Transcript output
/// never includes the stored bytes.
const credentialStore = new Map<string, Uint8Array>();
const maxCredentialSecretBytes = 5 * 512;

interface PendingStoreResult {
  readonly seq: number;
  readonly routeKey: string;
  readonly okKind: string;
  readonly errKind: string;
  readonly ok: boolean;
  readonly okVoid: boolean;
  readonly bytes: Uint8Array;
  active: boolean;
}

/// Store operations are performed in command-stream order, but their routed
/// results wait until the dispatch's complete command walk has returned. This
/// is the native effect boundary: a later command in one Cmd.batch can replace
/// or cancel an earlier result before either arm runs.
const pendingStoreResults: PendingStoreResult[] = [];
const pendingStoreByKey = new Map<string, PendingStoreResult>();
let dispatchDepth = 0;
let nextEffectResultSeq = 1;
let drainingEffectResults = false;

type DbOutcome = "constraint" | "busy" | "io_failed" | "corrupt" | "misuse" | "rejected" | "cancelled";
type DbResultKind = "page" | "done" | "exec";

interface PendingDbOperation {
  readonly routeKey: string;
  readonly query: boolean;
  readonly live: boolean;
  readonly pageKind: string;
  readonly doneKind: string;
  readonly errKind: string;
  active: boolean;
}

interface PendingDbResult {
  readonly seq: number;
  readonly operation: PendingDbOperation;
  readonly kind: DbResultKind;
  readonly outcome: "ok" | DbOutcome;
  readonly bytes: Uint8Array;
}

const relationalDb = new DatabaseSync(":memory:");
relationalDb.exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=250;");
let relationalTrackWrites = false;
let relationalAllowTransaction = false;
const relationalChangedTables = new Set<string>();
let relationalChangedAllTables = false;
const relationalSchemaActions = new Set([
  sqliteConstants.SQLITE_CREATE_INDEX, sqliteConstants.SQLITE_CREATE_TABLE,
  sqliteConstants.SQLITE_CREATE_TEMP_INDEX, sqliteConstants.SQLITE_CREATE_TEMP_TABLE,
  sqliteConstants.SQLITE_CREATE_TEMP_TRIGGER, sqliteConstants.SQLITE_CREATE_TEMP_VIEW,
  sqliteConstants.SQLITE_CREATE_TRIGGER, sqliteConstants.SQLITE_CREATE_VIEW,
  sqliteConstants.SQLITE_DROP_INDEX, sqliteConstants.SQLITE_DROP_TABLE,
  sqliteConstants.SQLITE_DROP_TEMP_INDEX, sqliteConstants.SQLITE_DROP_TEMP_TABLE,
  sqliteConstants.SQLITE_DROP_TEMP_TRIGGER, sqliteConstants.SQLITE_DROP_TEMP_VIEW,
  sqliteConstants.SQLITE_DROP_TRIGGER, sqliteConstants.SQLITE_DROP_VIEW,
  sqliteConstants.SQLITE_ALTER_TABLE, sqliteConstants.SQLITE_CREATE_VTABLE,
  sqliteConstants.SQLITE_DROP_VTABLE,
]);
const relationalAuthorizer = (action: number, first: string | null, second: string | null): number => {
  if (relationalTrackWrites && relationalSchemaActions.has(action)) relationalChangedAllTables = true;
  if (relationalTrackWrites && first !== null &&
      (action === sqliteConstants.SQLITE_INSERT || action === sqliteConstants.SQLITE_UPDATE || action === sqliteConstants.SQLITE_DELETE)) {
    relationalChangedTables.add(first);
  }
  if (!relationalAllowTransaction &&
      (action === sqliteConstants.SQLITE_TRANSACTION || action === sqliteConstants.SQLITE_SAVEPOINT)) {
    return sqliteConstants.SQLITE_DENY;
  }
  return relationalRuntimePolicy(action, first, second);
};
const relationalAuthorizerAvailable = setRelationalAuthorizer(relationalDb, relationalAuthorizer);

function applyDevMigrations(src: string): void {
  const schemaDir = path.join(src, "schema");
  if (!fs.existsSync(schemaDir)) return;
  const names = fs.readdirSync(schemaDir)
    .filter((name) => /^\d{4}_[a-z0-9][a-z0-9_-]*\.sql$/.test(name))
    .sort();
  for (let i = 0; i < names.length; i++) {
    const expected = String(i + 1).padStart(4, "0") + "_";
    if (!names[i]!.startsWith(expected)) throw new Error(`SQLite migration chain must be contiguous at ${expected}*.sql`);
  }
  if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, null);
  try {
    relationalDb.exec("BEGIN IMMEDIATE;");
    if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, relationalAuthorizer);
    for (let i = 0; i < names.length; i++) {
      let tail = fs.readFileSync(path.join(schemaDir, names[i]!), "utf8");
      while (dbTailHasStatement(tail, "")) {
        const statement = relationalDb.prepare(tail);
        const inspection = inspectRelationalSql(statement.sourceSQL, true);
        if (inspection.error !== null) throw new Error(inspection.error);
        statement.run();
        tail = tail.slice(statement.sourceSQL.length);
      }
    }
    if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, null);
    relationalDb.exec(`PRAGMA user_version=${names.length};`);
    relationalDb.exec("COMMIT;");
  } catch (reason) {
    if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, null);
    try { relationalDb.exec("ROLLBACK;"); } catch {}
    throw reason;
  } finally {
    if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, relationalAuthorizer);
  }
}

if (sqliteSrc !== null) applyDevMigrations(sqliteSrc);

function setRelationalQueryOnly(enabled: boolean): void {
  if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, null);
  try {
    relationalDb.exec(`PRAGMA query_only=${enabled ? "ON" : "OFF"};`);
  } finally {
    if (relationalAuthorizerAvailable) setRelationalAuthorizer(relationalDb, relationalAuthorizer);
  }
}

function relationalTransaction(sql: "BEGIN IMMEDIATE;" | "COMMIT;" | "ROLLBACK;"): void {
  relationalAllowTransaction = true;
  try {
    relationalDb.exec(sql);
  } finally {
    relationalAllowTransaction = false;
  }
}
const pendingDbResults: PendingDbResult[] = [];
const pendingDbByKey = new Map<string, PendingDbOperation>();
/// The packaged TS bridge and Zig Effects host share one fixed relational
/// slot family. Track every devhost operation explicitly too: keyed,
/// unkeyed, one-shot, and live subscriptions all consume the same capacity.
const activeDbOperations = new Set<PendingDbOperation>();

interface LiveDbSubscription {
  readonly operation: PendingDbOperation;
  readonly signature: string;
  readonly sql: string;
  readonly params: readonly unknown[];
  readonly tables: readonly string[];
}

const liveDbByKey = new Map<string, LiveDbSubscription>();
const dirtyLiveDbKeys = new Set<string>();

const maxStoreKeyBytes = 512;
const maxStoreValueBytes = 1024 * 1024;
const maxStoreBatchEntries = 64;
const maxStoreBatchBytes = 8 * 1024 * 1024;
const maxStoreScanLimit = 256;
const maxStoreResultBytes = maxStoreValueBytes + (2 * maxStoreKeyBytes) + 32;
const maxDbEffects = 16;
const maxDbSqlBytes = 64 * 1024;
const maxDbParameters = 64;
const maxDbExecStatements = 64;
const maxDbParameterBytes = 1024 * 1024;
const maxDbExecParameterBytes = 8 * 1024 * 1024;
const maxDbPageRows = 256;
const maxDbPageBytes = 256 * 1024;
const maxDbResultRows = 8 * 1024;
const maxDbResultBytes = 8 * 1024 * 1024;

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

function channelMsg(
  kind: string,
  key: number,
  state: "data" | "closed" | "rejected",
  bytes = new Uint8Array(0),
  droppedPending = 0,
  droppedTotal = 0,
): unknown {
  return { kind, key, state, bytes, droppedPending, droppedTotal };
}

interface ServiceTask {
  readonly id: number;
  readonly cmd: Cmdish;
  readonly operation: ServiceOperationRuntime;
  readonly request: unknown;
  readonly channelKey: number | null;
  readonly channelEvent: string | null;
  readonly cancelFlag: Int32Array;
  readonly streamStateBuffer: SharedArrayBuffer;
  readonly streamInFlight: Int32Array;
  readonly streamDrops: BigUint64Array;
  readonly engineIndex: number;
  readonly deadlineAt: number | null;
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

function takeServiceStreamDrops(task: ServiceTask): { pending: number; total: number } {
  const mask = 0xffffffffn;
  for (;;) {
    const current = Atomics.load(task.streamDrops, 0);
    const total = current >> 32n;
    if (Atomics.compareExchange(task.streamDrops, 0, current, total << 32n) === current) {
      return { pending: Number(current & mask), total: Number(total) };
    }
  }
}

function closeServiceChannel(task: ServiceTask): void {
  if (task.channelKey === null || task.channelEvent === null) return;
  if (serviceChannels.has(task.channelKey)) {
    const dropped = takeServiceStreamDrops(task);
    if (journalWriter) { journalWriter.channel(task.channelKey, "closed", new Uint8Array(0), dropped.pending, dropped.total); journalWriter.wake(); }
    dispatch(channelMsg(task.channelEvent, task.channelKey, "closed", new Uint8Array(0), dropped.pending, dropped.total));
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
  removeServiceKey(task);
  dispatch(bytesMsg(task.cmd.errKind as string, bytes));
}

function serviceSuccess(task: ServiceTask, result: unknown): void {
  if (task.responseDelivered) return;
  task.responseDelivered = true;
  const wireResult = task.operation.result.kind === "bytes" ? result as Uint8Array : encodeServiceValue(task.operation.result, result);
  if (journalWriter) { journalWriter.host(task.engineIndex, true, wireResult); journalWriter.wake(); }
  releaseServiceSlot(task);
  removeServiceKey(task);
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
    removeServiceKey(task);
  }
  Atomics.store(task.cancelFlag, 0, 1);
  if (!timeout && task.operation.stream !== null && !task.responseDelivered) {
    serviceFailure(task, encoder.encode("cancelled"));
    closeServiceChannel(task);
  }
  if (!task.hardTimer) task.hardTimer = setTimeout(() => stopWorkerFor(task), cooperativeCancelGraceMs);
}

const portableServiceEnvironment = new Set([
  "PATH", "HOME", "USER", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
  "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
]);
const windowsServiceEnvironment = new Set(["USERPROFILE", "USERNAME", "SYSTEMROOT", "COMSPEC", "PATHEXT"]);

function serviceWorkerEnvironment(): Record<string, string> {
  const environment: Record<string, string> = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    const comparison = process.platform === "win32" ? name.toUpperCase() : name;
    if (portableServiceEnvironment.has(comparison) || (process.platform === "win32" && windowsServiceEnvironment.has(comparison))) {
      environment[name] = value;
    }
  }
  return environment;
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
    env: serviceWorkerEnvironment(),
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
      const dropped = takeServiceStreamDrops(task);
      Atomics.sub(task.streamInFlight, 0, 1);
      if (!task.cancelled && !task.timedOut && task.channelKey !== null && task.channelEvent !== null && serviceChannels.has(task.channelKey)) {
        task.chunks += 1;
        const bytes = encodeServiceValue(task.operation.stream!.chunk, message.chunk);
        if (journalWriter) { journalWriter.channel(task.channelKey, "data", bytes, dropped.pending, dropped.total); journalWriter.wake(); }
        dispatch(channelMsg(task.channelEvent, task.channelKey, "data", bytes, dropped.pending, dropped.total));
      }
      return;
    }
    if (message.type === "result" || message.type === "error") {
      finishService(task, { type: message.type, result: message.result, error: message.error, elapsed: message.elapsed ?? 0 });
    }
  });
  const failed = (): void => {
    const task = activeService ?? serviceQueue.shift() ?? null;
    if (task !== null && activeService === null) activeService = task;
    serviceWorker = null;
    serviceWorkerReady = false;
    if (!task) {
      settleServiceWaiters();
      return;
    }
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
  if (task.deadlineAt !== null) {
    const remaining = task.deadlineAt - performance.now();
    if (remaining <= 0) {
      task.timedOut = true;
      serviceFailure(task, encoder.encode(JSON.stringify({ kind: "timeout", message: "service request timed out" })));
      closeServiceChannel(task);
      activeService = null;
      startNextService();
      return;
    }
    task.deadlineTimer = setTimeout(() => requestServiceStop(task, true), remaining);
  }
  serviceWorker.postMessage({
    id: task.id,
    name: task.operation.name,
    request: task.request,
    cancelBuffer: task.cancelFlag.buffer,
    streamStateBuffer: task.streamStateBuffer,
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
  const streamStateBuffer = new SharedArrayBuffer(16);
  const task: ServiceTask = {
    id: nextServiceId++, cmd, operation, request, channelKey, channelEvent,
    cancelFlag: new Int32Array(new SharedArrayBuffer(4)),
    streamStateBuffer,
    streamInFlight: new Int32Array(streamStateBuffer, 0, 1),
    streamDrops: new BigUint64Array(streamStateBuffer, 8, 1),
    engineIndex,
    deadlineAt: operation.deadline_ms === null ? null : performance.now() + operation.deadline_ms,
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

function emptyMsg(kind: string): unknown {
  return { kind };
}

function storeKeyBytes(key: string, allowEmpty = false): Uint8Array | null {
  const bytes = encoder.encode(key);
  if ((!allowEmpty && bytes.length === 0) || bytes.length > maxStoreKeyBytes) return null;
  return bytes;
}

function storeKeyIdentity(bytes: Uint8Array): string {
  let identity = "";
  for (const byte of bytes) identity += String.fromCharCode(byte);
  return identity;
}

function validStoreKeyBytes(bytes: Uint8Array, allowEmpty = false): Uint8Array | null {
  if ((!allowEmpty && bytes.length === 0) || bytes.length > maxStoreKeyBytes) return null;
  try {
    strictDecoder.decode(bytes);
  } catch {
    return null;
  }
  return bytes;
}

function compareBytes(left: Uint8Array, right: Uint8Array): number {
  const count = Math.min(left.length, right.length);
  for (let i = 0; i < count; i++) {
    if (left[i]! !== right[i]!) return left[i]! - right[i]!;
  }
  return left.length - right.length;
}

function startsWithBytes(value: Uint8Array, prefix: Uint8Array): boolean {
  if (prefix.length > value.length) return false;
  for (let i = 0; i < prefix.length; i++) if (value[i] !== prefix[i]) return false;
  return true;
}

function frameStoreScan(entries: ReadonlyArray<readonly [Uint8Array, Uint8Array]>, next: Uint8Array): Uint8Array {
  let length = 8 + next.length;
  for (const [key, value] of entries) length += 8 + key.length + value.length;
  const output = new Uint8Array(length);
  const view = new DataView(output.buffer);
  let at = 0;
  const writeU32 = (value: number): void => {
    view.setUint32(at, value, true);
    at += 4;
  };
  const writeBytes = (bytes: Uint8Array): void => {
    writeU32(bytes.length);
    output.set(bytes, at);
    at += bytes.length;
  };
  writeU32(entries.length);
  for (const [key, value] of entries) {
    writeBytes(key);
    writeBytes(value);
  }
  writeBytes(next);
  return output;
}

function queueStoreResult(cmd: Cmdish, ok: boolean, bytes: Uint8Array, okVoid: boolean): void {
  const routeKey = cmd.key as string;
  if (routeKey.length > 0) {
    const replaced = pendingStoreByKey.get(routeKey);
    if (replaced) replaced.active = false;
  }
  const result: PendingStoreResult = {
    seq: nextEffectResultSeq++,
    routeKey,
    okKind: cmd.okKind as string,
    errKind: cmd.errKind as string,
    ok,
    okVoid,
    bytes,
    active: true,
  };
  pendingStoreResults.push(result);
  if (routeKey.length > 0) pendingStoreByKey.set(routeKey, result);
}

function cancelPendingStore(routeKey: string): boolean {
  const pending = pendingStoreByKey.get(routeKey);
  if (!pending) return false;
  pending.active = false;
  pendingStoreByKey.delete(routeKey);
  return true;
}

function rejectStore(cmd: Cmdish, reason: string): void {
  say(`cmd ${cmd.op} rejected ${reason}`);
  queueStoreResult(cmd, false, encoder.encode(reason), false);
}

function performStoreCmd(cmd: Cmdish): void {
  const routeKey = cmd.key as string;
  if (!capabilities.has("store")) return rejectStore(cmd, "rejected");
  switch (cmd.op) {
    case "store_set": {
      const key = cmd.storeKey as string;
      const keyBytes = storeKeyBytes(key);
      const bytes = cmd.bytes;
      if (!keyBytes) return rejectStore(cmd, "bad_key");
      if (!(bytes instanceof Uint8Array) || bytes.length > maxStoreValueBytes) return rejectStore(cmd, "over_bound");
      recordStore.set(storeKeyIdentity(keyBytes), { key: keyBytes.slice(), value: bytes.slice() });
      say(`cmd store_set ${routeKey} ${key} (stored in virtual host memory)`);
      queueStoreResult(cmd, true, new Uint8Array(0), true);
      return;
    }
    case "store_get": {
      const key = cmd.storeKey as string;
      const keyBytes = storeKeyBytes(key);
      if (!keyBytes) return rejectStore(cmd, "bad_key");
      const value = recordStore.get(storeKeyIdentity(keyBytes))?.value;
      const result = new Uint8Array(value === undefined ? 1 : value.length + 1);
      if (value !== undefined) {
        result[0] = 1;
        result.set(value, 1);
      }
      say(`cmd store_get ${routeKey} ${key} (${value === undefined ? "miss" : "hit"})`);
      queueStoreResult(cmd, true, result, false);
      return;
    }
    case "store_delete": {
      const key = cmd.storeKey as string;
      const keyBytes = storeKeyBytes(key);
      if (!keyBytes) return rejectStore(cmd, "bad_key");
      recordStore.delete(storeKeyIdentity(keyBytes));
      say(`cmd store_delete ${routeKey} ${key} (deleted from virtual host memory)`);
      queueStoreResult(cmd, true, new Uint8Array(0), true);
      return;
    }
    case "store_scan": {
      const prefix = cmd.prefix as string;
      const after = cmd.after as string | Uint8Array;
      const prefixBytes = storeKeyBytes(prefix, true);
      const afterBytes = typeof after === "string"
        ? (after === "" ? new Uint8Array(0) : storeKeyBytes(after))
        : validStoreKeyBytes(after, true);
      const requested = cmd.limit as number;
      const limit = requested === 0 ? 100 : requested;
      if (!prefixBytes || !afterBytes) return rejectStore(cmd, "bad_key");
      if (!Number.isInteger(limit) || limit < 1 || limit > maxStoreScanLimit) return rejectStore(cmd, "over_bound");
      const matches = [...recordStore.values()]
        .map(({ key, value }) => [key, value] as const)
        .filter(([key]) => startsWithBytes(key, prefixBytes) && (afterBytes.length === 0 || compareBytes(key, afterBytes) > 0))
        .sort(([left], [right]) => compareBytes(left, right));
      const page: Array<readonly [Uint8Array, Uint8Array]> = [];
      let framedLength = 8;
      for (const entry of matches) {
        if (page.length >= limit) break;
        const rowLength = 8 + entry[0].length + entry[1].length;
        if (framedLength + rowLength + entry[0].length > maxStoreResultBytes && page.length > 0) break;
        page.push(entry);
        framedLength += rowLength;
      }
      const hasMore = page.length < matches.length;
      const next = hasMore ? page.at(-1)![0] : new Uint8Array(0);
      say(`cmd store_scan ${routeKey} ${prefix} (${page.length} records${hasMore ? ", more" : ""})`);
      queueStoreResult(cmd, true, frameStoreScan(page, next), false);
      return;
    }
    case "store_set_many": {
      const entries = cmd.entries as ReadonlyArray<readonly [string, Uint8Array]>;
      if (!Array.isArray(entries) || entries.length === 0 || entries.length > maxStoreBatchEntries) return rejectStore(cmd, "over_bound");
      let encodedLength = 8;
      for (const [key, value] of entries) {
        const keyBytes = storeKeyBytes(key);
        if (!keyBytes) return rejectStore(cmd, "bad_key");
        if (!(value instanceof Uint8Array) || value.length > maxStoreValueBytes) return rejectStore(cmd, "over_bound");
        encodedLength += 8 + keyBytes.length + value.length;
        if (encodedLength > maxStoreBatchBytes) return rejectStore(cmd, "over_bound");
      }
      for (const [key, value] of entries) {
        const keyBytes = storeKeyBytes(key)!;
        recordStore.set(storeKeyIdentity(keyBytes), { key: keyBytes.slice(), value: value.slice() });
      }
      say(`cmd store_set_many ${routeKey} (${entries.length} records stored atomically)`);
      queueStoreResult(cmd, true, new Uint8Array(0), true);
      return;
    }
  }
}

function credentialFields(payload: unknown): Uint8Array[] | null {
  if (!(payload instanceof Uint8Array)) return null;
  const fields: Uint8Array[] = [];
  let at = 0;
  while (at < payload.length) {
    if (payload.length - at < 4) return null;
    const length = new DataView(payload.buffer, payload.byteOffset + at, 4).getUint32(0, true);
    at += 4;
    if (length > payload.length - at) return null;
    fields.push(payload.slice(at, at + length));
    at += length;
  }
  return fields;
}

function rejectCredentials(cmd: Cmdish, outcome: string): void {
  say(`cmd ${cmd.name} rejected ${outcome}`);
  queueStoreResult(cmd, false, encoder.encode(outcome), false);
}

function performCredentialsCmd(cmd: Cmdish): void {
  const name = cmd.name as string;
  if (!capabilities.has("credentials") || !permissions.has("credentials")) {
    rejectCredentials(cmd, "denied");
    return;
  }
  const fields = credentialFields(cmd.payload);
  const expected = name === "core.credentials.set" ? 2 : 1;
  if (!fields || fields.length !== expected) return rejectCredentials(cmd, "rejected");
  const keyBytes = fields[0]!;
  let key: string;
  try {
    key = strictDecoder.decode(keyBytes);
  } catch {
    return rejectCredentials(cmd, "over_bound");
  }
  if (keyBytes.length === 0 || keyBytes.length > 256 || key.includes("\0")) return rejectCredentials(cmd, "over_bound");
  const identity = `${appId}\0${key}`;
  if (name === "core.credentials.set") {
    const secret = fields[1]!;
    if (secret.length > maxCredentialSecretBytes) return rejectCredentials(cmd, "over_bound");
    credentialStore.set(identity, secret.slice());
    say(`cmd ${name} ${cmd.key as string} ${key} (<redacted, ${secret.length} bytes> stored in virtual host memory)`);
    queueStoreResult(cmd, true, new Uint8Array(0), true);
    return;
  }
  if (name === "core.credentials.get") {
    const secret = credentialStore.get(identity);
    say(`cmd ${name} ${cmd.key as string} ${key} (${secret ? `<redacted, ${secret.length} bytes>` : "miss"})`);
    if (!secret) queueStoreResult(cmd, false, encoder.encode("miss"), false);
    else queueStoreResult(cmd, true, secret.slice(), false);
    return;
  }
  if (name === "core.credentials.delete") {
    credentialStore.delete(identity);
    say(`cmd ${name} ${cmd.key as string} ${key} (deleted from virtual host memory)`);
    queueStoreResult(cmd, true, new Uint8Array(0), true);
    return;
  }
  rejectCredentials(cmd, "rejected");
}

type DbBindValue = null | bigint | number | string | Uint8Array;

function validDbSql(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && !value.includes("\0") && encoder.encode(value).length <= maxDbSqlBytes;
}

/// Node's SQLite wrapper prepares only the first statement and does not expose
/// sqlite3's tail pointer directly. `sourceSQL` is that exact first slice, so
/// inspect only its tail for another token. Trigger-body semicolons remain in
/// sourceSQL and trailing comments/empty semicolons stay legal.
function dbTailHasStatement(sql: string, sourceSQL: string): boolean {
  const tail = sql.slice(sourceSQL.length);
  let at = 0;
  while (at < tail.length) {
    const char = tail[at]!;
    if (/\s/.test(char) || char === ";") {
      at += 1;
      continue;
    }
    if (char === "-" && tail[at + 1] === "-") {
      const newline = tail.indexOf("\n", at + 2);
      if (newline < 0) return false;
      at = newline + 1;
      continue;
    }
    if (char === "/" && tail[at + 1] === "*") {
      const end = tail.indexOf("*/", at + 2);
      if (end < 0) return false;
      at = end + 2;
      continue;
    }
    return true;
  }
  return false;
}

function dbParams(value: unknown, byteLimit: number): ReadonlyArray<DbBindValue> | null {
  if (!Array.isArray(value) || value.length > maxDbParameters) return null;
  const params: DbBindValue[] = [];
  let bytes = 0;
  for (const item of value) {
    if (item === null) params.push(null);
    else if (typeof item === "boolean") params.push(item ? 1n : 0n);
    else if (typeof item === "number" && Number.isFinite(item)) params.push(Number.isSafeInteger(item) ? BigInt(item) : item);
    else if (typeof item === "object" && item !== null && (item as { __dbText?: unknown }).__dbText === true && Array.isArray((item as { bytes?: unknown }).bytes)) {
      const rawBytes = (item as { bytes: unknown[] }).bytes;
      if (!rawBytes.every((byte) => typeof byte === "number" && Number.isInteger(byte) && byte >= 0 && byte <= 255)) return null;
      const textBytes = Uint8Array.from(rawBytes as number[]);
      let text: string;
      try { text = strictDecoder.decode(textBytes); } catch { return null; }
      bytes += textBytes.length;
      params.push(text);
    } else if (typeof item === "string") {
      bytes += encoder.encode(item).length;
      params.push(item);
    } else if (item instanceof Uint8Array) {
      bytes += item.length;
      params.push(item);
    } else return null;
    if (bytes > byteLimit) return null;
  }
  return params;
}

function dbErrorOutcome(reason: unknown): DbOutcome {
  if (reason !== null && typeof reason === "object") {
    const error = reason as { readonly errcode?: number; readonly errstr?: string; readonly message?: string };
    const primary = (error.errcode ?? 0) & 0xff;
    if (primary === 19 || error.errstr === "constraint failed") return "constraint";
    if (primary === 5 || primary === 6) return "busy";
    if (primary === 10) return "io_failed";
    if (primary === 11 || primary === 26) return "corrupt";
    if (primary === 23) return "misuse";
    if ((error.message ?? "").includes("query_only")) return "misuse";
  }
  return "misuse";
}

function dbU32(value: number): Uint8Array {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value, true);
  return bytes;
}

function dbValue(value: unknown): Uint8Array | null {
  if (value === null) return new Uint8Array([0]);
  if (typeof value === "bigint") {
    const bytes = new Uint8Array(9);
    bytes[0] = 1;
    new DataView(bytes.buffer).setBigInt64(1, value, true);
    return bytes;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    const bytes = new Uint8Array(9);
    bytes[0] = 2;
    new DataView(bytes.buffer).setFloat64(1, value, true);
    return bytes;
  }
  if (typeof value === "string" || value instanceof Uint8Array) {
    const body = typeof value === "string" ? encoder.encode(value) : value;
    const bytes = new Uint8Array(5 + body.length);
    bytes[0] = typeof value === "string" ? 3 : 4;
    new DataView(bytes.buffer).setUint32(1, body.length, true);
    bytes.set(body, 5);
    return bytes;
  }
  return null;
}

function concatDbParts(parts: ReadonlyArray<Uint8Array>, length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let at = 0;
  for (const part of parts) {
    bytes.set(part, at);
    at += part.length;
  }
  return bytes;
}

function dbHeader(columnNames: ReadonlyArray<string>, rowCount: number): Uint8Array | null {
  const parts: Uint8Array[] = [dbU32(columnNames.length), dbU32(rowCount)];
  let length = 8;
  for (const name of columnNames) {
    const body = encoder.encode(name);
    length += 4 + body.length;
    if (length > maxDbPageBytes) return null;
    parts.push(dbU32(body.length), body);
  }
  return concatDbParts(parts, length);
}

type EncodedDbPages =
  | { readonly outcome: "ok"; readonly pages: ReadonlyArray<Uint8Array>; readonly rowCount: number }
  | { readonly outcome: "misuse" | "rejected" };

function encodeDbPages(columnNames: ReadonlyArray<string>, rows: Iterable<ReadonlyArray<unknown>>): EncodedDbPages {
  const emptyHeader = dbHeader(columnNames, 0);
  if (!emptyHeader) return { outcome: "misuse" };
  const pages: Uint8Array[] = [];
  let members: Uint8Array[] = [];
  let pageLength = emptyHeader.length;
  let resultBytes = 0;
  let rowCount = 0;

  const flush = (): boolean => {
    const header = dbHeader(columnNames, members.length);
    if (!header || resultBytes + pageLength > maxDbResultBytes) return false;
    pages.push(concatDbParts([header, ...members], pageLength));
    resultBytes += pageLength;
    members = [];
    pageLength = emptyHeader.length;
    return true;
  };

  for (const row of rows) {
    if (rowCount === maxDbResultRows) return { outcome: "rejected" };
    const values: Uint8Array[] = [];
    let length = 0;
    for (const value of row) {
      const bytes = dbValue(value);
      if (!bytes) return { outcome: "misuse" };
      length += bytes.length;
      if (length + emptyHeader.length > maxDbPageBytes) return { outcome: "misuse" };
      values.push(bytes);
    }
    const encoded = concatDbParts(values, length);
    if (members.length > 0 && (members.length === maxDbPageRows || pageLength + encoded.length > maxDbPageBytes)) {
      if (!flush()) return { outcome: "rejected" };
    }
    members.push(encoded);
    pageLength += encoded.length;
    rowCount += 1;
  }
  if (members.length > 0 || pages.length === 0) {
    if (!flush()) return { outcome: "rejected" };
  }
  return { outcome: "ok", pages, rowCount };
}

function dbBindArgs(sql: string, params: ReadonlyArray<DbBindValue>): ReadonlyArray<unknown> {
  const namedIndexes = new Map<string, number>();
  const positionalIndexes = new Set<number>();
  let maxIndex = 0;
  let at = 0;
  while (at < sql.length) {
    const char = sql[at]!;
    if (char === "'" || char === '"' || char === "`") {
      const quote = char;
      at += 1;
      while (at < sql.length) {
        if (sql[at] !== quote) { at += 1; continue; }
        if (sql[at + 1] === quote) { at += 2; continue; }
        at += 1;
        break;
      }
      continue;
    }
    if (char === "[") {
      const end = sql.indexOf("]", at + 1);
      at = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (char === "-" && sql[at + 1] === "-") {
      const end = sql.indexOf("\n", at + 2);
      at = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (char === "/" && sql[at + 1] === "*") {
      const end = sql.indexOf("*/", at + 2);
      at = end < 0 ? sql.length : end + 2;
      continue;
    }
    if (char === "?") {
      let end = at + 1;
      while (/[0-9]/.test(sql[end] ?? "")) end += 1;
      const explicit = end > at + 1 ? Number(sql.slice(at + 1, end)) : null;
      const index = explicit ?? maxIndex + 1;
      if (!Number.isSafeInteger(index) || index <= 0) throw new Error("SQLite positional parameter index is invalid");
      maxIndex = Math.max(maxIndex, index);
      positionalIndexes.add(index);
      at = end;
      continue;
    }
    if ((char === ":" || char === "@" || char === "$") && /[A-Za-z_]/.test(sql[at + 1] ?? "")) {
      let end = at + 2;
      while (/[A-Za-z0-9_]/.test(sql[end] ?? "")) end += 1;
      const name = sql.slice(at, end);
      if (!namedIndexes.has(name)) namedIndexes.set(name, ++maxIndex);
      at = end;
      continue;
    }
    at += 1;
  }
  if (maxIndex !== params.length) throw new Error("SQLite parameter count does not match its value array");
  if (namedIndexes.size === 0) return params;
  const named: Record<string, DbBindValue> = {};
  const indexesClaimedByName = new Set<number>();
  for (const [name, index] of namedIndexes) {
    named[name] = params[index - 1]!;
    indexesClaimedByName.add(index);
  }
  const positional: DbBindValue[] = [];
  const lastPositionalIndex = positionalIndexes.size === 0 ? 0 : Math.max(...positionalIndexes);
  for (let index = 1; index <= maxIndex; index++) {
    if (indexesClaimedByName.has(index)) continue;
    // Numbered placeholders can leave holes. Node's SQLite binding API
    // counts those holes among its anonymous arguments, exactly as the C
    // API's 1..parameter_count index walk does.
    if (index <= lastPositionalIndex) positional.push(params[index - 1]!);
  }
  return [named, ...positional];
}

function beginDbOperation(cmd: Cmdish, query: boolean): PendingDbOperation | null {
  const routeKey = cmd.key as string;
  if (routeKey.length > 0 && liveDbByKey.has(routeKey)) return null;
  const active = routeKey.length === 0 ? undefined : pendingDbByKey.get(routeKey);
  if (active) {
    if (!query) return null;
    releaseDbOperation(active, true);
  }
  const operation: PendingDbOperation = {
    routeKey,
    query,
    live: false,
    pageKind: query ? cmd.pageKind as string : "",
    doneKind: query ? cmd.doneKind as string : cmd.okKind as string,
    errKind: cmd.errKind as string,
    active: true,
  };
  if (activeDbOperations.size === maxDbEffects) return null;
  activeDbOperations.add(operation);
  if (routeKey.length > 0) pendingDbByKey.set(routeKey, operation);
  return operation;
}

function queueDbResult(operation: PendingDbOperation, kind: DbResultKind, outcome: "ok" | DbOutcome, bytes = new Uint8Array(0)): void {
  pendingDbResults.push({ seq: nextEffectResultSeq++, operation, kind, outcome, bytes });
}

function discardDbResults(operation: PendingDbOperation): void {
  for (let index = pendingDbResults.length - 1; index >= 0; index--) {
    if (pendingDbResults[index]!.operation === operation) pendingDbResults.splice(index, 1);
  }
}

function releaseDbOperation(operation: PendingDbOperation, discardResults: boolean): void {
  operation.active = false;
  activeDbOperations.delete(operation);
  if (discardResults) discardDbResults(operation);
}

function rejectDbOperation(cmd: Cmdish, query: boolean, outcome: DbOutcome, operation?: PendingDbOperation): void {
  const pending = operation ?? {
    routeKey: "",
    query,
    live: false,
    pageKind: query ? cmd.pageKind as string : "",
    doneKind: query ? cmd.doneKind as string : cmd.okKind as string,
    errKind: cmd.errKind as string,
    active: true,
  };
  say(`cmd ${cmd.op} rejected ${outcome}`);
  queueDbResult(pending, query ? "done" : "exec", outcome);
}

function runDbQuery(sql: unknown, rawParams: unknown, operation: PendingDbOperation): void {
  const params = dbParams(rawParams, maxDbParameterBytes);
  if (!validDbSql(sql) || !params) {
    rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, "rejected", operation);
    return;
  }
  try {
    const inspection = inspectRelationalSql(sql, true);
    if (inspection.error !== null) throw new Error(inspection.error);
    setRelationalQueryOnly(true);
    const statement = relationalDb.prepare(sql);
    if (dbTailHasStatement(sql, statement.sourceSQL)) {
      rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, "misuse", operation);
      return;
    }
    statement.setReturnArrays(true);
    statement.setReadBigInts(true);
    const columns = statement.columns().map((column) => column.name);
    if (columns.length === 0) {
      rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, "misuse", operation);
      return;
    }
    const rows = statement.iterate(...dbBindArgs(sql, params)) as Iterable<ReadonlyArray<unknown>>;
    const encoded = encodeDbPages(columns, rows);
    if (encoded.outcome !== "ok") {
      rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, encoded.outcome, operation);
      return;
    }
    say(`${operation.live ? "sub db_live" : "cmd db_query"} ${operation.routeKey} (${encoded.rowCount} rows in ${encoded.pages.length} page${encoded.pages.length === 1 ? "" : "s"})`);
    for (const page of encoded.pages) queueDbResult(operation, "page", "ok", page);
    queueDbResult(operation, "done", "ok");
  } catch (reason) {
    rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, dbErrorOutcome(reason), operation);
  } finally {
    setRelationalQueryOnly(false);
  }
}

function performDbCmd(cmd: Cmdish): void {
  const query = cmd.op === "db_query";
  const operation = beginDbOperation(cmd, query);
  if (!operation) return rejectDbOperation(cmd, query, "rejected");
  if (!capabilities.has("sqlite")) return rejectDbOperation(cmd, query, "rejected", operation);

  if (query) {
    runDbQuery(cmd.sql, cmd.params, operation);
    return;
  }

  const statements = cmd.statements;
  if (!Array.isArray(statements) || statements.length === 0 || statements.length > maxDbExecStatements) {
    return rejectDbOperation(cmd, false, "rejected", operation);
  }
  const validated: Array<readonly [string, ReadonlyArray<DbBindValue>]> = [];
  let parameterBytes = 0;
  for (const item of statements) {
    if (!Array.isArray(item) || item.length !== 2 || !validDbSql(item[0])) return rejectDbOperation(cmd, false, "rejected", operation);
    const params = dbParams(item[1], maxDbExecParameterBytes - parameterBytes);
    if (!params) return rejectDbOperation(cmd, false, "rejected", operation);
    for (const value of params) {
      if (typeof value === "string") parameterBytes += encoder.encode(value).length;
      else if (value instanceof Uint8Array) parameterBytes += value.length;
    }
    validated.push([item[0], params]);
  }

  let began = false;
  try {
    relationalChangedTables.clear();
    relationalChangedAllTables = false;
    relationalTrackWrites = true;
    relationalTransaction("BEGIN IMMEDIATE;");
    began = true;
    for (const [sql, params] of validated) {
      const inspection = inspectRelationalSql(sql, true);
      if (inspection.error !== null) throw new Error(inspection.error);
      const statement = relationalDb.prepare(sql);
      if (dbTailHasStatement(sql, statement.sourceSQL)) throw new Error("relational exec statement contains stacked SQL");
      if (statement.columns().length !== 0) throw new Error("relational exec statement yields rows");
      statement.run(...dbBindArgs(sql, params));
      if (!relationalAuthorizerAvailable) relationalChangedAllTables = true;
    }
    relationalTransaction("COMMIT;");
    began = false;
    for (const [key, live] of liveDbByKey) {
      if (relationalChangedAllTables || live.tables.some((table) => relationalChangedTables.has(table))) dirtyLiveDbKeys.add(key);
    }
    say(`cmd db_exec ${operation.routeKey} (${validated.length} statements committed atomically)`);
    queueDbResult(operation, "exec", "ok");
  } catch (reason) {
    if (began) {
      try { relationalTransaction("ROLLBACK;"); } catch {}
    }
    rejectDbOperation(cmd, false, dbErrorOutcome(reason), operation);
  } finally {
    relationalTrackWrites = false;
  }
}

function cancelPendingDb(routeKey: string): boolean {
  const operation = pendingDbByKey.get(routeKey);
  if (!operation || !operation.query) return false;
  releaseDbOperation(operation, true);
  pendingDbByKey.delete(routeKey);
  return true;
}

function nextPendingStoreResult(): PendingStoreResult | undefined {
  while (pendingStoreResults.length > 0) {
    const result = pendingStoreResults[0];
    if (result.active && (result.routeKey.length === 0 || pendingStoreByKey.get(result.routeKey) === result)) return result;
    pendingStoreResults.shift();
  }
  return undefined;
}

function nextPendingDbResult(): PendingDbResult | undefined {
  while (pendingDbResults.length > 0) {
    const result = pendingDbResults[0];
    if (result.operation.active) return result;
    pendingDbResults.shift();
  }
  return undefined;
}

function drainEffectResults(): void {
  if (dispatchDepth !== 0 || drainingEffectResults) return;
  drainingEffectResults = true;
  try {
    while (true) {
      const storeResult = nextPendingStoreResult();
      const dbResult = nextPendingDbResult();
      if (!storeResult && !dbResult) break;

      if (storeResult && (!dbResult || storeResult.seq < dbResult.seq)) {
        pendingStoreResults.shift();
        if (storeResult.routeKey.length > 0) pendingStoreByKey.delete(storeResult.routeKey);
        storeResult.active = false;
        if (!storeResult.ok) dispatch(bytesMsg(storeResult.errKind, storeResult.bytes));
        else if (storeResult.okVoid) dispatch(emptyMsg(storeResult.okKind));
        else dispatch(bytesMsg(storeResult.okKind, storeResult.bytes));
        continue;
      }

      const result = pendingDbResults.shift()!;
      const operation = result.operation;
      const terminal = result.outcome !== "ok" || result.kind !== "page";
      if (terminal && !operation.live) {
        releaseDbOperation(operation, false);
        if (operation.routeKey.length > 0 && pendingDbByKey.get(operation.routeKey) === operation) {
          pendingDbByKey.delete(operation.routeKey);
        }
      }
      if (result.outcome !== "ok") dispatch(bytesMsg(operation.errKind, encoder.encode(result.outcome)));
      else if (result.kind === "page") dispatch(bytesMsg(operation.pageKind, result.bytes));
      else dispatch(emptyMsg(operation.doneKind));
    }
  } finally {
    drainingEffectResults = false;
  }
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
      if (cancelPendingStore(key)) {
        say(`cmd cancel ${key} (store result dropped)`);
      } else if (cancelPendingDb(key)) {
        say(`cmd cancel ${key} (database query result dropped)`);
      } else if (delays.delete(key)) {
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
      if (typeof cmd.name === "string" && cmd.name.startsWith("core.credentials.")) {
        performCredentialsCmd(cmd);
        return;
      }
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
    case "store_set":
    case "store_get":
    case "store_delete":
    case "store_scan":
    case "store_set_many":
      performStoreCmd(cmd);
      return;
    case "db_query":
    case "db_exec":
      performDbCmd(cmd);
      return;
    case "read_file":
    case "write_file":
    case "append_file":
    case "stat_file":
    case "delete_file":
    case "read_file_stream":
    case "write_file_stream":
    case "write_file_chunk":
    case "write_file_close": {
      // The logic-only host deliberately performs no ambient filesystem IO;
      // it still names the runtime policy so dev transcripts cannot imply
      // these commands bypass the manifest gate.
      const details = Object.entries(cmd)
        .filter(([k]) => k !== "op")
        .map(([k, v]) => `${k}=${JSON.stringify(jsonable(v))}`)
        .join(" ");
      say(`cmd ${cmd.op} ${details}`.trimEnd() + " (not performed by the virtual host; runtime requires filesystem permission outside app dirs)");
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
  const declaredLive = new Map<string, Cmdish>();
  const collect = (sub: Cmdish): void => {
    if (sub.op === "timer") {
      declared.set(sub.key as string, { everyMs: sub.everyMs as number, msgKind: sub.msgKind as string });
    } else if (sub.op === "db_live") {
      const key = sub.key as string;
      if (key.length === 0 || declaredLive.has(key)) throw new Error("a live query requires one unique, non-empty subscription key");
      declaredLive.set(key, sub);
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

  // Retire absent live queries before allocating their replacements. Both
  // sets may fit the shared database family independently even when their
  // transient union does not (for example, sixteen old keys replaced by one
  // new key).
  for (const [key, active] of [...liveDbByKey]) {
    if (!declaredLive.has(key)) {
      releaseDbOperation(active.operation, true);
      liveDbByKey.delete(key);
      dirtyLiveDbKeys.delete(key);
      say(`sub cancel db_live ${key}`);
    }
  }

  for (const [key, sub] of declaredLive) {
    const tables = sub.tables;
    const params = sub.params;
    if (!Array.isArray(tables) || tables.length === 0 || !tables.every((table) => typeof table === "string" && table.length > 0) || !Array.isArray(params)) {
      throw new Error(`live query ${key} carries an invalid generated dependency or parameter set`);
    }
    if (pendingDbByKey.has(key)) throw new Error(`live-query key ${key} collides with an in-flight database command`);
    const signature = JSON.stringify([
      sub.pageKind, sub.doneKind, sub.errKind, sub.sql,
      jsonable(params), tables,
    ]);
    const active = liveDbByKey.get(key);
    if (active?.signature === signature) continue;
    if (active) {
      releaseDbOperation(active.operation, true);
    }
    const operation: PendingDbOperation = {
      routeKey: key,
      query: true,
      live: true,
      pageKind: sub.pageKind as string,
      doneKind: sub.doneKind as string,
      errKind: sub.errKind as string,
      active: true,
    };
    if (activeDbOperations.size === maxDbEffects) {
      throw new Error("more relational commands and live queries are active than the database slot family can hold");
    }
    activeDbOperations.add(operation);
    const live: LiveDbSubscription = {
      operation,
      signature,
      sql: sub.sql as string,
      params,
      tables: tables as string[],
    };
    liveDbByKey.set(key, live);
    dirtyLiveDbKeys.delete(key);
    say(`sub ${active ? "re-arm" : "arm"} db_live ${key}`);
    if (!capabilities.has("sqlite")) rejectDbOperation(sub, true, "rejected", operation);
    else runDbQuery(live.sql, live.params, operation);
  }
}

function flushLiveDbSubscriptions(): void {
  for (const key of [...dirtyLiveDbKeys]) {
    dirtyLiveDbKeys.delete(key);
    const live = liveDbByKey.get(key);
    if (live?.operation.active) runDbQuery(live.sql, live.params, live.operation);
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
  dispatchDepth += 1;
  try {
    if (cmd) performCmd(cmd as Cmdish);
    reconcileSubs();
    flushLiveDbSubscriptions();
  } finally {
    dispatchDepth -= 1;
  }
  drainEffectResults();
  const route = restored ? persistOk : persistNone;
  if (route) dispatch({ kind: route });
}

function dispatch(msg: unknown): void {
  dispatchDepth += 1;
  try {
    const result = mod.update(model, msg);
    const [next, cmd] = Array.isArray(result) ? result : [result, null];
    model = next;
    say(`model ${JSON.stringify(jsonable(model))}`);
    if (cmd) performCmd(cmd as Cmdish);
    reconcileSubs();
    flushLiveDbSubscriptions();
  } finally {
    dispatchDepth -= 1;
  }
  drainEffectResults();
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
    for (const live of liveDbByKey.values()) releaseDbOperation(live.operation, true);
    liveDbByKey.clear();
    dirtyLiveDbKeys.clear();
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

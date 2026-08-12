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
// Cmd.persist snapshots the committed model in virtual-host memory;
// capability-enabled Cmd.store performs against a process-local byte map,
// and Cmd.db uses a real process-local SQLite database.
// Every other effect
// (files, buffered/streaming fetch, clipboard,
// notifications, spawn, audio, host commands)
// is printed as `cmd ...` and NOT performed — feed its result back yourself
// as an ordinary Msg line. That is the point: results are plain messages,
// and the loop stays deterministic.

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { register } from "node:module";
import { constants as sqliteConstants, DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { installTextMethods } from "./text_polyfill.ts";
import { checkFile, formatDiagnostic } from "./frontend.ts";

interface Cmdish {
  readonly op: string;
  readonly [field: string]: unknown;
}

function usage(): never {
  console.error("usage: devhost.ts <core.ts> [--script <msgs.ndjson>] [--capability <name>]... [--sdk-core <generated-core.ts>] [--sqlite-src <src>]");
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
const capabilities = new Set<string>();
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--script") script = args[++i] ?? null;
  else if (args[i] === "--capability") {
    const capability = args[++i] ?? null;
    if (capability === null) usage();
    capabilities.add(capability);
  }
  else if (args[i] === "--persist-ok") persistOk = args[++i] ?? null;
  else if (args[i] === "--persist-none") persistNone = args[++i] ?? null;
  else if (args[i] === "--persist-err") persistErr = args[++i] ?? null;
  else if (args[i] === "--sdk-core") sdkCore = args[++i] ?? null;
  else if (args[i] === "--sqlite-src") sqliteSrc = args[++i] ?? null;
  else if (args[i] === "--help" || args[i] === "-h") usage();
  else if (!args[i].startsWith("-")) entry = args[i];
  else usage();
}
if (!entry) usage();
const persistRouteCount = [persistOk, persistNone, persistErr].filter((route) => route !== null).length;
if (persistRouteCount !== 0 && persistRouteCount !== 3) usage();
if (persistOk !== null && persistNone !== null && persistErr !== null) {
  // Type information is erased by the time this module imports the app core.
  // Run the frontend inside the watched process so every node --watch restart
  // revalidates manifest-owned routes against the newly edited Msg union.
  const checked = checkFile(entry, {
    capabilities: [...new Set([...capabilities, "persist"])],
    persistRoutes: { ok: persistOk, none: persistNone, err: persistErr },
    sdkCorePath: sdkCore ?? undefined,
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
register(new URL("./devhost_resolver.mjs", import.meta.url), import.meta.url, {
  data: { generatedCoreUrl: sdkCore === null ? null : pathToFileURL(path.resolve(sdkCore)).href },
});

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
const relationalOwnedPragmas = new Set([
  "user_version", "schema_version", "writable_schema", "query_only",
  "journal_mode", "synchronous", "locking_mode", "foreign_keys",
  "defer_foreign_keys", "busy_timeout", "wal_autocheckpoint", "temp_store",
  "temp_store_directory", "data_store_directory",
]);
let relationalTrackWrites = false;
const relationalChangedTables = new Set<string>();
const relationalAuthorizer = (action: number, first: string | null, second: string | null): number => {
  if (relationalTrackWrites && first !== null &&
      (action === sqliteConstants.SQLITE_INSERT || action === sqliteConstants.SQLITE_UPDATE || action === sqliteConstants.SQLITE_DELETE)) {
    relationalChangedTables.add(first);
  }
  if (action === sqliteConstants.SQLITE_ATTACH || action === sqliteConstants.SQLITE_DETACH) return sqliteConstants.SQLITE_DENY;
  if (action === sqliteConstants.SQLITE_PRAGMA && second !== null && relationalOwnedPragmas.has((first ?? "").toLowerCase())) {
    return sqliteConstants.SQLITE_DENY;
  }
  return sqliteConstants.SQLITE_OK;
};
relationalDb.setAuthorizer(relationalAuthorizer);

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
  relationalDb.setAuthorizer(null);
  try {
    relationalDb.exec("BEGIN IMMEDIATE;");
    for (let i = 0; i < names.length; i++) {
      relationalDb.exec(fs.readFileSync(path.join(schemaDir, names[i]!), "utf8"));
      relationalDb.exec(`PRAGMA user_version=${i + 1};`);
    }
    relationalDb.exec("COMMIT;");
  } catch (reason) {
    try { relationalDb.exec("ROLLBACK;"); } catch {}
    throw reason;
  } finally {
    relationalDb.setAuthorizer(relationalAuthorizer);
  }
}

if (sqliteSrc !== null) applyDevMigrations(sqliteSrc);

function setRelationalQueryOnly(enabled: boolean): void {
  relationalDb.setAuthorizer(null);
  try {
    relationalDb.exec(`PRAGMA query_only=${enabled ? "ON" : "OFF"};`);
  } finally {
    relationalDb.setAuthorizer(relationalAuthorizer);
  }
}
const pendingDbResults: PendingDbResult[] = [];
const pendingDbByKey = new Map<string, PendingDbOperation>();

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
const maxDbSqlBytes = 64 * 1024;
const maxDbParameters = 64;
const maxDbExecStatements = 64;
const maxDbParameterBytes = 1024 * 1024;
const maxDbExecParameterBytes = 8 * 1024 * 1024;
const maxDbPageRows = 256;
const maxDbPageBytes = 256 * 1024;

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

function encodeDbPages(columnNames: ReadonlyArray<string>, rows: ReadonlyArray<ReadonlyArray<unknown>>): ReadonlyArray<Uint8Array> | null {
  const emptyHeader = dbHeader(columnNames, 0);
  if (!emptyHeader) return null;
  const encodedRows: Uint8Array[] = [];
  for (const row of rows) {
    const values: Uint8Array[] = [];
    let length = 0;
    for (const value of row) {
      const bytes = dbValue(value);
      if (!bytes) return null;
      length += bytes.length;
      if (length + emptyHeader.length > maxDbPageBytes) return null;
      values.push(bytes);
    }
    encodedRows.push(concatDbParts(values, length));
  }

  const pages: Uint8Array[] = [];
  let at = 0;
  do {
    const members: Uint8Array[] = [];
    let pageLength = emptyHeader.length;
    while (at < encodedRows.length && members.length < maxDbPageRows) {
      const row = encodedRows[at]!;
      if (members.length > 0 && pageLength + row.length > maxDbPageBytes) break;
      if (pageLength + row.length > maxDbPageBytes) return null;
      members.push(row);
      pageLength += row.length;
      at += 1;
    }
    const header = dbHeader(columnNames, members.length)!;
    pages.push(concatDbParts([header, ...members], pageLength));
  } while (at < encodedRows.length);
  return pages;
}

function dbBindArgs(sql: string, params: ReadonlyArray<DbBindValue>): ReadonlyArray<unknown> {
  const names: string[] = [];
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
    if (char === ":" && /[A-Za-z_]/.test(sql[at + 1] ?? "")) {
      let end = at + 2;
      while (/[A-Za-z0-9_]/.test(sql[end] ?? "")) end += 1;
      const name = sql.slice(at + 1, end);
      if (!names.includes(name)) names.push(name);
      at = end;
      continue;
    }
    at += 1;
  }
  if (names.length === 0) return params;
  if (names.length !== params.length) throw new Error("SQLite named parameter count does not match its value array");
  const named: Record<string, DbBindValue> = {};
  for (let i = 0; i < names.length; i++) named[names[i]!] = params[i]!;
  return [named];
}

function beginDbOperation(cmd: Cmdish, query: boolean): PendingDbOperation | null {
  const routeKey = cmd.key as string;
  const active = routeKey.length === 0 ? undefined : pendingDbByKey.get(routeKey);
  if (active) {
    if (!query) return null;
    active.active = false;
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
  if (routeKey.length > 0) pendingDbByKey.set(routeKey, operation);
  return operation;
}

function queueDbResult(operation: PendingDbOperation, kind: DbResultKind, outcome: "ok" | DbOutcome, bytes = new Uint8Array(0)): void {
  pendingDbResults.push({ seq: nextEffectResultSeq++, operation, kind, outcome, bytes });
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
    const rows = statement.all(...dbBindArgs(sql, params)) as ReadonlyArray<ReadonlyArray<unknown>>;
    const pages = encodeDbPages(columns, rows);
    if (!pages) {
      rejectDbOperation({ op: operation.live ? "db_live" : "db_query" }, true, "misuse", operation);
      return;
    }
    say(`${operation.live ? "sub db_live" : "cmd db_query"} ${operation.routeKey} (${rows.length} rows in ${pages.length} page${pages.length === 1 ? "" : "s"})`);
    for (const page of pages) queueDbResult(operation, "page", "ok", page);
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
  if (!operation) return rejectDbOperation(cmd, false, "rejected");
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
    relationalTrackWrites = true;
    relationalDb.exec("BEGIN IMMEDIATE;");
    began = true;
    for (const [sql, params] of validated) {
      const statement = relationalDb.prepare(sql);
      if (dbTailHasStatement(sql, statement.sourceSQL)) throw new Error("relational exec statement contains stacked SQL");
      if (statement.columns().length !== 0) throw new Error("relational exec statement yields rows");
      statement.run(...dbBindArgs(sql, params));
    }
    relationalDb.exec("COMMIT;");
    began = false;
    for (const [key, live] of liveDbByKey) {
      if (live.tables.some((table) => relationalChangedTables.has(table))) dirtyLiveDbKeys.add(key);
    }
    say(`cmd db_exec ${operation.routeKey} (${validated.length} statements committed atomically)`);
    queueDbResult(operation, "exec", "ok");
  } catch (reason) {
    if (began) {
      try { relationalDb.exec("ROLLBACK;"); } catch {}
    }
    rejectDbOperation(cmd, false, dbErrorOutcome(reason), operation);
  } finally {
    relationalTrackWrites = false;
  }
}

function cancelPendingDb(routeKey: string): boolean {
  const operation = pendingDbByKey.get(routeKey);
  if (!operation || !operation.query) return false;
  operation.active = false;
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
        operation.active = false;
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

  for (const [key, sub] of declaredLive) {
    const tables = sub.tables;
    const params = sub.params;
    if (!Array.isArray(tables) || tables.length === 0 || !tables.every((table) => typeof table === "string" && table.length > 0) || !Array.isArray(params)) {
      throw new Error(`live query ${key} carries an invalid generated dependency or parameter set`);
    }
    const signature = JSON.stringify([
      sub.pageKind, sub.doneKind, sub.errKind, sub.sql,
      jsonable(params), tables,
    ]);
    const active = liveDbByKey.get(key);
    if (active?.signature === signature) continue;
    if (active) active.operation.active = false;
    const operation: PendingDbOperation = {
      routeKey: key,
      query: true,
      live: true,
      pageKind: sub.pageKind as string,
      doneKind: sub.doneKind as string,
      errKind: sub.errKind as string,
      active: true,
    };
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
  for (const [key, active] of [...liveDbByKey]) {
    if (!declaredLive.has(key)) {
      active.operation.active = false;
      liveDbByKey.delete(key);
      dirtyLiveDbKeys.delete(key);
      say(`sub cancel db_live ${key}`);
    }
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
  if (typeof record.advance === "number") {
    advance(record.advance);
    return;
  }
  if (record.restart === true) {
    timers.clear();
    delays.clear();
    for (const live of liveDbByKey.values()) live.operation.active = false;
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
  dispatch(revive(parsed));
}

if (script) {
  for (const line of fs.readFileSync(script, "utf8").split("\n")) handleLine(line);
} else {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", handleLine);
}

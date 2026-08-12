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
// capability-enabled Cmd.store performs against a process-local byte map.
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
import { pathToFileURL } from "node:url";
import { installTextMethods } from "./text_polyfill.ts";
import { checkFile, formatDiagnostic } from "./frontend.ts";

interface Cmdish {
  readonly op: string;
  readonly [field: string]: unknown;
}

function usage(): never {
  console.error("usage: devhost.ts <core.ts> [--script <msgs.ndjson>] [--capability <name>]...");
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
register(new URL("./devhost_resolver.mjs", import.meta.url));

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
let drainingStoreResults = false;

const maxStoreKeyBytes = 512;
const maxStoreValueBytes = 1024 * 1024;
const maxStoreBatchEntries = 64;
const maxStoreBatchBytes = 8 * 1024 * 1024;
const maxStoreScanLimit = 256;
const maxStoreResultBytes = maxStoreValueBytes + (2 * maxStoreKeyBytes) + 32;

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

function drainStoreResults(): void {
  if (dispatchDepth !== 0 || drainingStoreResults) return;
  drainingStoreResults = true;
  try {
    while (pendingStoreResults.length > 0) {
      const result = pendingStoreResults.shift()!;
      if (!result.active) continue;
      if (result.routeKey.length > 0) {
        if (pendingStoreByKey.get(result.routeKey) !== result) continue;
        pendingStoreByKey.delete(result.routeKey);
      }
      result.active = false;
      if (!result.ok) dispatch(bytesMsg(result.errKind, result.bytes));
      else if (result.okVoid) dispatch(emptyMsg(result.okKind));
      else dispatch(bytesMsg(result.okKind, result.bytes));
    }
  } finally {
    drainingStoreResults = false;
  }
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
  } finally {
    dispatchDepth -= 1;
  }
  drainStoreResults();
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
  } finally {
    dispatchDepth -= 1;
  }
  drainStoreResults();
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

// IndexedDB, stored in SQLite: the factory, databases, version changes, transactions and object
// stores, with the records kept in a SQLite file per database in the app's data directory. The
// store keeps a version and the object stores in tables of its own, and each record as a key and
// a structured-cloned value, so a database survives the app and is shared by its windows.
//
// The requests of a transaction run in the order they were made, on the microtask queue, against
// one SQLite transaction: a readwrite transaction commits when its queue drains, and an error a
// handler didn't prevent aborts it. Object stores support inline and out-of-line keys, key
// generators, add/put/get/getKey/getAll/getAllKeys/count/delete/clear and IDBKeyRange. Object
// stores can carry indexes, which read their records in index-key order, and a cursor over a
// store or an index walks those records one at a time in the direction asked for.

import { existsSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { Blob, Event } from "./dom.ts";
import { plainBytes } from "./bytes.ts";
import { SqliteDb, SqliteStmt, SQLITE_CONSTRAINT, SQLITE_DONE, SQLITE_OK, SQLITE_ROW, storeDirectory } from "./sqlite.ts";

// ---------------------------------------------------------------------------
// Errors and events

/** The failures IndexedDB reports: a DOMException by name, with its message. It is a value of its
 *  own rather than an Error subclass, which the compiler doesn't lower as a base class. */
export class IDBException {
  get [Symbol.toStringTag](): string { return "IDBException"; }
  readonly name: string;
  readonly message: string;
  constructor(name: string, message: string) {
    this.name = name;
    this.message = message;
  }
}

/** Whether a value is a Date, without matching it against the built-in class. */
function isDate(v: any): boolean {
  return v !== null && typeof v === "object" && typeof (v as any).getTime === "function"
    && typeof (v as any).getFullYear === "function";
}

const HEX = "0123456789abcdef";

/** The event a version change dispatches. It is a value of its own rather than a subclass of the
 *  DOM's Event: an IndexedDB module that extends dom.ts's class is a cycle the compiler refuses. */
export class IDBVersionChangeEvent {
  get [Symbol.toStringTag](): string { return "IDBVersionChangeEvent"; }
  readonly type: string;
  readonly oldVersion: number;
  readonly newVersion: number;
  readonly bubbles: boolean = false;
  readonly cancelable: boolean = false;
  defaultPrevented: boolean = false;
  readonly target: any = null;
  constructor(type: string, init?: { oldVersion?: number; newVersion?: number }) {
    this.type = type;
    this.oldVersion = init === undefined || init.oldVersion === undefined ? 0 : init.oldVersion;
    this.newVersion = init === undefined || init.newVersion === undefined ? 0 : init.newVersion;
  }
  preventDefault(): void {
    this.defaultPrevented = true;
  }
}

/** The event listener shape a request and a transaction share. */
type Listener = { type: string; fn: (event: any) => void };

/** A target a request, a database or a transaction dispatches to: handlers and listeners. */
class Target {
  protected listeners: Listener[] = [];

  addEventListener(type: string, listener: any): void {
    if (listener === null || listener === undefined) return;
    if (typeof listener === "function") this.listeners.push({ type, fn: listener });
    else if (typeof listener.handleEvent === "function") this.listeners.push({ type, fn: (e: any) => listener.handleEvent(e) });
  }

  removeEventListener(type: string, listener: any): void {
    for (let i = this.listeners.length - 1; i >= 0; i--) {
      if (this.listeners[i].type === type && this.listeners[i].fn === listener) this.listeners.splice(i, 1);
    }
  }

  /** Runs the listeners for an event's type, after the class's own handler has run. */
  protected emitListeners(event: any): void {
    for (const l of this.listeners.slice()) {
      if (l.type !== event.type) continue;
      try { l.fn.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
  }

  dispatchEvent(event: any): boolean {
    const handler = (this as any)["on" + event.type];
    if (typeof handler === "function") {
      try { handler.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    for (const l of this.listeners.slice()) {
      if (l.type !== event.type) continue;
      try { l.fn.call(this, event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// Keys

/** A value usable as a key, encoded so equality and ordering both have an answer. */
interface Key {
  /** 0 number, 1 date, 2 string, 3 binary, 4 array. */
  type: number;
  number: number;
  text: string;
  bytes: Uint8Array;
  array: Key[];
}

const NO_BYTES = new Uint8Array(0);

function isBinary(v: any): boolean {
  return v instanceof ArrayBuffer
    || (v !== null && typeof v === "object" && typeof v.byteLength === "number" && typeof v.buffer === "object");
}

/** The bytes of an ArrayBuffer or a typed array. */
function bytesOf(v: any): Uint8Array {
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  const view = v as ArrayBufferView;
  const bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
  const copy = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) copy[i] = bytes[i];
  return copy;
}

/** Reads `v` as a key, throwing DataError when it isn't one. `depth` stops a cyclic array. */
function keyOf(v: any, depth: number = 0): Key {
  if (typeof v === "number") {
    if (isNaN(v) || !isFinite(v)) throw new IDBException("DataError", "The key is not a valid number.");
    return { type: 0, number: v === 0 ? 0 : v, text: "", bytes: NO_BYTES, array: [] };
  }
  if (isDate(v)) {
    const time = v.getTime();
    if (isNaN(time) || !isFinite(time)) throw new IDBException("DataError", "The key is not a valid date.");
    return { type: 1, number: time, text: "", bytes: NO_BYTES, array: [] };
  }
  if (typeof v === "string") return { type: 2, number: 0, text: v, bytes: NO_BYTES, array: [] };
  if (isBinary(v)) return { type: 3, number: 0, text: "", bytes: bytesOf(v), array: [] };
  if (Array.isArray(v)) {
    if (depth > 32) throw new IDBException("DataError", "The key array is nested too deeply.");
    const items: Key[] = [];
    for (const item of v) items.push(keyOf(item, depth + 1));
    return { type: 4, number: 0, text: "", bytes: NO_BYTES, array: items };
  }
  throw new IDBException("DataError", "The key is not a number, a date, a string, a buffer or an array of those.");
}

/** A key as one string, for equality: the record's primary key in SQLite. */
function keyText(key: Key): string {
  if (key.type === 4) return JSON.stringify(keyTree(key));
  if (key.type === 0 || key.type === 1) return key.type + "|" + String(key.number);
  if (key.type === 2) return "2|" + key.text;
  let hex = "";
  for (let i = 0; i < key.bytes.length; i++) {
    const b = key.bytes[i];
    hex += HEX[(b >> 4) & 15] + HEX[b & 15];
  }
  return "3|" + hex;
}

function compareKeys(a: Key, b: Key): number {
  if (a.type !== b.type) return a.type - b.type;
  if (a.type === 0 || a.type === 1) return a.number < b.number ? -1 : a.number > b.number ? 1 : 0;
  if (a.type === 2) return a.text < b.text ? -1 : a.text > b.text ? 1 : 0;
  if (a.type === 3) {
    const n = Math.min(a.bytes.length, b.bytes.length);
    for (let i = 0; i < n; i++) if (a.bytes[i] !== b.bytes[i]) return a.bytes[i] - b.bytes[i];
    return a.bytes.length - b.bytes.length;
  }
  const n = Math.min(a.array.length, b.array.length);
  for (let i = 0; i < n; i++) {
    const c = compareKeys(a.array[i], b.array[i]);
    if (c !== 0) return c;
  }
  return a.array.length - b.array.length;
}

/** A key range: the standard's IDBKeyRange, with its bounds and open flags. */
export class IDBKeyRange {
  get [Symbol.toStringTag](): string { return "IDBKeyRange"; }
  readonly lower: any;
  readonly upper: any;
  readonly lowerOpen: boolean;
  readonly upperOpen: boolean;

  constructor(lower: any, upper: any, lowerOpen: boolean, upperOpen: boolean) {
    this.lower = lower;
    this.upper = upper;
    this.lowerOpen = lowerOpen;
    this.upperOpen = upperOpen;
  }

  static only(value: any): IDBKeyRange {
    const key = keyOf(value);
    return new IDBKeyRange(encodeKeyForScript(key), encodeKeyForScript(key), false, false);
  }

  static lowerBound(...args: any[]): IDBKeyRange {
    const key = keyOf(args[0]);
    return new IDBKeyRange(encodeKeyForScript(key), undefined, args[1] === true, true);
  }

  static upperBound(...args: any[]): IDBKeyRange {
    const key = keyOf(args[0]);
    return new IDBKeyRange(undefined, encodeKeyForScript(key), true, args[1] === true);
  }

  static bound(...args: any[]): IDBKeyRange {
    const a = keyOf(args[0]);
    const b = keyOf(args[1]);
    if (compareKeys(a, b) > 0) throw new IDBException("DataError", "The lower bound is greater than the upper bound.");
    return new IDBKeyRange(encodeKeyForScript(a), encodeKeyForScript(b), args[2] === true, args[3] === true);
  }

  includes(key: any): boolean {
    const k = keyOf(key);
    if (this.lower !== undefined) {
      const c = compareKeys(k, keyOf(this.lower));
      if (c < 0 || (c === 0 && this.lowerOpen)) return false;
    }
    if (this.upper !== undefined) {
      const c = compareKeys(k, keyOf(this.upper));
      if (c > 0 || (c === 0 && this.upperOpen)) return false;
    }
    return true;
  }
}

/** A key handed back to the page: numbers, dates, strings, buffers and arrays as they were. */
function encodeKeyForScript(key: Key): any {
  if (key.type === 0) return key.number;
  if (key.type === 1) return new Date(key.number);
  if (key.type === 2) return key.text;
  if (key.type === 3) {
    const copy = new ArrayBuffer(key.bytes.length);
    const out = new Uint8Array(copy);
    for (let i = 0; i < key.bytes.length; i++) out[i] = key.bytes[i];
    return copy;
  }
  const items: any[] = [];
  for (const item of key.array) items.push(encodeKeyForScript(item));
  return items;
}

/** A decoded key from a record row. */
function decodeKeyRow(t: number, n: number, s: string, b: Uint8Array): Key {
  if (t === 4) {
    const items: Key[] = [];
    const text = s;
    // Array keys are stored as their canonical text; parse it back.
    return parseArrayKey(text);
  }
  return { type: t, number: n, text: s, bytes: b, array: [] };
}

/** A key as JSON the record can keep, arrays and buffers included. */
function keyTree(key: Key): any {
  if (key.type === 4) {
    const items: any[] = [];
    for (const item of key.array) items.push(keyTree(item));
    return { t: 4, a: items };
  }
  if (key.type === 3) {
    let hex = "";
    for (let i = 0; i < key.bytes.length; i++) hex += HEX[(key.bytes[i] >> 4) & 15] + HEX[key.bytes[i] & 15];
    return { t: 3, b: hex };
  }
  return key.type === 2 ? { t: 2, s: key.text } : { t: key.type, n: key.number };
}

/** Parses the JSON of an array key. */
function parseArrayKey(text: string): Key {
  return keyFromTree(JSON.parse(text));
}

function keyFromTree(tree: any): Key {
  if (tree.t === 4) {
    const items: Key[] = [];
    for (const item of tree.a) items.push(keyFromTree(item));
    return { type: 4, number: 0, text: "", bytes: NO_BYTES, array: items };
  }
  if (tree.t === 3) {
    const hex = String(tree.b);
    const bytes = new Uint8Array(Math.floor(hex.length / 2));
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return { type: 3, number: 0, text: "", bytes, array: [] };
  }
  if (tree.t === 2) return { type: 2, number: 0, text: String(tree.s), bytes: NO_BYTES, array: [] };
  return { type: Number(tree.t), number: Number(tree.n), text: "", bytes: NO_BYTES, array: [] };
}

// ---------------------------------------------------------------------------
// Values

/** Marks a structured-clone value JSON can't carry on its own. */
interface Tagged { $t: string; $v: any }

/** Whether a value is a plain object (or null). */
/** Whether a value is a Blob (or a File, which is one with a name). */
function isBlobLike(v: any): boolean {
  return v !== null && typeof v === "object" && typeof v.arrayBuffer === "function"
    && typeof v.size === "number" && typeof v.type === "string";
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function base64ToBytes(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i) & 0xff;
  return bytes;
}

function isPlainObject(v: any): boolean {
  // The compiler can't lower Object.getPrototypeOf, and the objects that reach here are already
  // known not to be dates, buffers or arrays: what is left is a page object, unless it is a
  // Blob, whose bytes only a stream can read.
  if (v === null || typeof v !== "object") return false;
  if (typeof (v as any).arrayBuffer === "function") return false;
  return typeof (v as any).nodeType !== "number";
}

/** Structured-clones a value into JSON the store keeps: dates, buffers and arrays kept as tags. */
async function cloneValue(v: any, depth: number = 0, seen: any[] = []): Promise<any> {
  if (depth > 64) throw new IDBException("DataCloneError", "The value is nested too deeply.");
  if (v === null || v === undefined) return null;
  if (typeof v === "string" || typeof v === "boolean") return v;
  if (typeof v === "number") {
    if (isNaN(v)) return { $t: "nan", $v: 0 } as Tagged;
    if (!isFinite(v)) return { $t: v > 0 ? "inf" : "-inf", $v: 0 } as Tagged;
    return v;
  }
  if (typeof v === "function" || typeof v === "symbol" || typeof v === "bigint") {
    throw new IDBException("DataCloneError", "The value can't be cloned.");
  }
  for (const s of seen) if (s === v) throw new IDBException("DataCloneError", "The value contains a cycle.");
  seen.push(v);
  let out: any;
  if (isDate(v)) out = { $t: "date", $v: v.getTime() } as Tagged;
  else if (isBlobLike(v)) {
    // A Blob's bytes are read asynchronously, which is why a write may take a turn to finish.
    const bytes = new Uint8Array(await v.arrayBuffer());
    const data = bytesToBase64(bytes);
    out = { $t: "blob", type: v.type === undefined ? "" : v.type, data } as any;
  } else if (isBinary(v)) {
    out = { $t: "bin", $v: bytesToBase64(bytesOf(v)) } as Tagged;
  } else if (Array.isArray(v)) {
    const items: any[] = [];
    for (const item of v) items.push(await cloneValue(item, depth + 1, seen));
    out = items;
  } else if (isPlainObject(v)) {
    const record: { [key: string]: any } = {};
    for (const key of Object.keys(v)) {
      if (typeof (v as any)[key] === "function" || typeof (v as any)[key] === "symbol") continue;
      record[key] = await cloneValue((v as any)[key], depth + 1, seen);
    }
    out = record;
  } else {
    throw new IDBException("DataCloneError", "The value can't be cloned.");
  }
  seen.pop();
  return out;
}

/** The value a record's JSON names, with its tags restored. */
function restoreValue(v: any): any {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) {
    const items: any[] = [];
    for (const item of v) items.push(restoreValue(item));
    return items;
  }
  if (typeof v.$t === "string") {
    if (v.$t === "date") return new Date(v.$v);
    if (v.$t === "nan") return NaN;
    if (v.$t === "inf") return Infinity;
    if (v.$t === "-inf") return -Infinity;
    if (v.$t === "bin") {
      return base64ToBytes(v.$v).buffer;
    }
    if (v.$t === "blob") {
      return new Blob([plainBytes(base64ToBytes(String(v.data)))], { type: String(v.type) });
    }

  }
  const out: { [key: string]: any } = {};
  for (const key of Object.keys(v)) out[key] = restoreValue(v[key]);
  return out;
}

// ---------------------------------------------------------------------------
// Requests

/** What a request read: its result, or the error it failed with. */
export class IDBRequest extends Target {
  get [Symbol.toStringTag](): string { return "IDBRequest"; }
  readonly source: any;
  transaction: any;
  readyState: string = "pending";
  result: any = undefined;
  error: any = undefined;
  onsuccess: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;

  constructor(source: any, transaction: any) {
    super();
    this.source = source;
    this.transaction = transaction;
  }

  /** Reports the value the request read. */
  succeed(result: any): void {
    this.result = result;
    this.readyState = "done";
    this.dispatchEvent(new Event("success"));
  }

  /** Reports the failure, which the transaction aborts unless a handler prevents it. */
  fail(error: any): void {
    this.error = error;
    this.readyState = "done";
    const event = new Event("error", { cancelable: true });
    this.dispatchEvent(event);
    if (this.transaction !== null && !event.defaultPrevented) this.transaction.abortWith(error);
  }
}

/** The request open() hands back; its success is a connection. */
export class IDBOpenDBRequest extends IDBRequest {
  get [Symbol.toStringTag](): string { return "IDBOpenDBRequest"; }
  onblocked: ((event: any) => void) | null = null;
  onupgradeneeded: ((event: any) => void) | null = null;

  constructor() {
    super(null, null);
  }
}

// ---------------------------------------------------------------------------
// Transactions

/** One operation a transaction runs, and the request it reports to. */
interface Operation {
  run: () => any;
  request: IDBRequest;
}

export class IDBTransaction extends Target {
  get [Symbol.toStringTag](): string { return "IDBTransaction"; }
  readonly db: IDBDatabase;
  readonly mode: string;
  readonly objectStoreNames: string[];
  readonly durability: string = "default";
  error: any = null;
  oncomplete: ((event: any) => void) | null = null;
  onabort: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;

  private queue: Operation[] = [];
  private running: boolean = false;
  private finished: boolean = false;
  /** Whether this transaction's BEGIN has run; a waiting transaction hasn't started yet. */
  private began: boolean = false;
  /** A versionchange transaction is the one an upgrade runs in. */
  readonly versionChange: boolean;

  constructor(db: IDBDatabase, names: string[], mode: string, versionChange: boolean = false) {
    super();
    this.db = db;
    this.objectStoreNames = names;
    this.mode = mode;
    this.versionChange = versionChange;
    db._register(this);
    db._enqueue(this);
  }

  /** Runs the transaction now that no other one is open on the connection. */
  _start(): void {
    const rc = this.db._db.exec(this.mode === "readwrite" || this.versionChange ? "BEGIN IMMEDIATE" : "BEGIN");
    if (rc !== SQLITE_OK) {
      this.finished = true;
      this.db._unregister(this);
      this.db._transactionDone(this);
      const ev = new Event("error");
      if (typeof this.onerror === "function") {
        try { this.onerror(ev); } catch (e) { console.error("Uncaught " + String(e)); }
      }
      this.emitListeners(ev);
      return;
    }
    this.began = true;
    // A transaction that never gets a request still completes, at the end of the current turn.
    Promise.resolve().then(() => this._drain());
  }

  /** Queues a store operation; the request reports it when the queue reaches it. */
  _queue(run: () => any, request: IDBRequest): void {
    if (this.finished) throw new IDBException("TransactionInactiveError", "The transaction has finished.");
    this.queue.push({ run, request });
  }

  objectStore(name: string): IDBObjectStore {
    if (this.finished) throw new IDBException("TransactionInactiveError", "The transaction has finished.");
    if (this.objectStoreNames.indexOf(name) < 0) {
      throw new IDBException("NotFoundError", "The transaction doesn't include '" + name + "'.");
    }
    return new IDBObjectStore(this, name);
  }

  /** Abandons the transaction: its queued requests fail and its writes roll back. */
  abort(): void {
    this.abortWith(new IDBException("AbortError", "The transaction was aborted."));
  }

  /** Rolls back and reports abort, once. */
  abortWith(error: any): void {
    if (this.finished) return;
    this.finished = true;
    if (this.began) this.db._db.exec("ROLLBACK");
    this.error = error;
    this.db._unregister(this);
    const event = new Event("abort");
    if (typeof this.onabort === "function") {
      try { this.onabort(event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    this.emitListeners(event);
    this.db._transactionDone(this);
  }

  commit(): void {
    // IndexedDB's commit() is an optimization; the transaction already commits when it drains.
  }

  async _drain(): Promise<void> {
    while (!this.finished && this.queue.length > 0) {
      const op = this.queue.shift()!;
      let result: any;
      let failure: any = null;
      try {
        result = await op.run();
      } catch (e) {
        failure = e instanceof IDBException ? e : new IDBException("UnknownError", String(e));
      }
      if (this.finished) return;
      if (failure !== null) {
        op.request.fail(failure);
        if (this.finished) return;
      } else {
        op.request.succeed(result);
        if (this.finished) return;
      }
    }
    if (this.finished) return;
    this._finish();
  }

  _finish(): void {
    if (this.finished) return;
    if (this.queue.length > 0) {
      void this._drain();
      return;
    }
    this.finished = true;
    const rc = this.began ? this.db._db.exec("COMMIT") : SQLITE_OK;
    this.began = false;
    this.db._unregister(this);
    if (rc !== SQLITE_OK) {
      this.error = new IDBException("UnknownError", this.db._db.error());
      this.aborted();
      return;
    }
    this.completed();
    this.db._transactionDone(this);
  }

  /** Reports complete to the transaction's handler and its listeners. */
  private completed(): void {
    const event = new Event("complete");
    if (typeof this.oncomplete === "function") {
      try { this.oncomplete(event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    this.emitListeners(event);
  }

  /** Reports abort to the handler and listeners, after a commit that failed. */
  private aborted(): void {
    const event = new Event("abort");
    if (typeof this.onabort === "function") {
      try { this.onabort(event); } catch (e) { console.error("Uncaught " + String(e)); }
    }
    this.emitListeners(event);
  }
}

// ---------------------------------------------------------------------------
// Object stores

/** The key an object's key path names, or undefined when it has none. */
export function keyFromKeyPath(value: any, keyPath: string): any {
  if (keyPath === "") return undefined;
  const parts = keyPath.split(".");
  let at: any = value;
  for (const part of parts) {
    if (at === null || at === undefined || typeof at !== "object") return undefined;
    if (!(part in at)) return undefined;
    at = at[part];
  }
  return at;
}

/** The keys a value has in an index: one, or one per element of a multiEntry array. */
function indexKeysOf(value: any, keyPath: string, multiEntry: boolean): Key[] {
  const raw = keyFromKeyPath(value, keyPath);
  if (raw === undefined) return [];
  const out: Key[] = [];
  if (multiEntry && Array.isArray(raw)) {
    for (const item of raw) {
      try {
        out.push(keyOf(item));
      } catch (e) {
        // An element that isn't a key indexes nothing, as the standard has it.
      }
    }
  } else {
    try {
      out.push(keyOf(raw));
    } catch (e) {
      // A value that isn't a key indexes nothing.
    }
  }
  return out;
}

/** One row a cursor walks: its index or primary key, its primary key, and the record. */
interface CursorEntry {
  key: Key;
  primary: Key;
  json: string | null;
}

/** A cursor over a store or an index. The same request reports each step: continue() or
 *  advance() queues the next one on the transaction, and a success whose result is null is the
 *  end of the range. */
export class IDBCursor {
  get [Symbol.toStringTag](): string { return "IDBCursor"; }
  readonly source: any;
  readonly direction: string;
  readonly request: IDBRequest;
  key: any = undefined;
  primaryKey: any = undefined;
  value: any = undefined;

  private entries: CursorEntry[];
  private at: number = -1;
  private keysOnly: boolean;
  private done: boolean = false;
  /** Whether a step is queued and its success hasn't run: the cursor moves once a turn at most. */
  private stepping: boolean = false;

  constructor(source: any, request: IDBRequest, entries: CursorEntry[], direction: string, keysOnly: boolean) {
    this.source = source;
    this.request = request;
    this.entries = entries;
    this.direction = direction;
    this.keysOnly = keysOnly;
  }

  /** Moves the cursor and hands it back, or null at the end of the range. */
  _step(count: number, target: Key | null): any {
    this.stepping = false;
    if (this.done) return null;
    const forward = this.direction !== "prev" && this.direction !== "prevunique";
    let at = this.at;
    if (target !== null) {
      // The entries are already in the cursor's direction, so the search runs forward through
      // them; only the comparison with the target follows the direction.
      at++;
      while (at >= 0 && at < this.entries.length) {
        const c = compareKeys(this.entries[at].key, target);
        if (forward ? c >= 0 : c <= 0) break;
        at++;
      }
    } else {
      at = this.at + count;
    }
    if (at < 0 || at >= this.entries.length) {
      this.done = true;
      return null;
    }
    this.at = at;
    const entry = this.entries[at];
    this.key = encodeKeyForScript(entry.key);
    this.primaryKey = encodeKeyForScript(entry.primary);
    this.value = this.keysOnly || entry.json === null ? undefined : restoreValue(JSON.parse(entry.json));
    return this;
  }

  /** The store this cursor's records live in, whether it walks the store or one of its indexes. */
  _store(): IDBObjectStore {
    return this.source instanceof IDBIndex ? this.source.objectStore : this.source;
  }

  /** A cursor that hasn't reached a record yet, or has moved past the end, has none to act on. */
  private requireRecord(): void {
    if (this.at < 0 || this.done) {
      throw new IDBException("InvalidStateError", "The cursor isn't on a record.");
    }
  }

  /** The next step starts only once the last one's success has run. */
  private beginStep(): void {
    this.requireRecord();
    if (this.stepping) throw new IDBException("InvalidStateError", "The cursor is already moving.");
    this.stepping = true;
    this.request.readyState = "pending";
  }

  continue(...args: any[]): void {
    this.requireRecord();
    let target: Key | null = null;
    if (args.length > 0 && args[0] !== undefined) {
      target = keyOf(args[0]);
      // The key must lie ahead of the cursor: after it going forward, before it going back.
      const forward = this.direction === "next" || this.direction === "nextunique";
      const c = compareKeys(target, this.entries[this.at].key);
      if (forward ? c <= 0 : c >= 0) {
        throw new IDBException("DataError", "The key doesn't lie ahead of the cursor.");
      }
    }
    this.beginStep();
    const self = this;
    this._store().transaction._queue(() => self._step(1, target), this.request);
  }

  advance(count: number): void {
    this.requireRecord();
    // A count below one has nowhere to move to; the standard makes that a TypeError.
    const n = Math.trunc(Number(count));
    if (!(n >= 1)) throw new IDBException("TypeError", "The count must be at least 1.");
    this.beginStep();
    const self = this;
    this._store().transaction._queue(() => self._step(n, null), this.request);
  }

  update(value: any): IDBRequest {
    this.requireRecord();
    if (this.keysOnly) throw new IDBException("InvalidStateError", "A key cursor has no value to update.");
    return this._store()._replaceAt(value, this.primaryKey);
  }

  delete(): IDBRequest {
    this.requireRecord();
    return this._store().delete(this.primaryKey);
  }
}

/** One index of a store: a second key every record takes from its value, which is queried in
 *  the primary key's order. Its records are read from the store's own rows, so a write costs the
 *  same whether the store has indexes or not; uniqueness is checked against the other rows. */
/** The range a cursor query names, or null for all records. */
function cursorRange(query: any): IDBKeyRange | null {
  if (query === undefined || query === null) return null;
  return query instanceof IDBKeyRange ? query : IDBKeyRange.only(query);
}

const CURSOR_DIRECTIONS = ["next", "nextunique", "prev", "prevunique"];

/** The entries a store cursor walks, in its direction's order. */
function storeCursorEntries(store: IDBObjectStore, range: IDBKeyRange | null, direction: string): CursorEntry[] {
  const rows = store.db._records(store.name);
  rows.sort((a, b) => compareKeys(a.key, b.key));
  if (direction === "prev" || direction === "prevunique") rows.reverse();
  const out: CursorEntry[] = [];
  for (const row of rows) {
    if (range !== null && !range.includes(encodeKeyForScript(row.key))) continue;
    out.push({ key: row.key, primary: row.key, json: row.json });
  }
  return out;
}

/** The entries an index cursor walks, in its direction's order, unique keys dropped when asked. */
function indexCursorEntries(index: IDBIndex, range: IDBKeyRange | null, direction: string): CursorEntry[] {
  const entries: CursorEntry[] = [];
  for (const entry of index._entries()) {
    if (range !== null && !range.includes(encodeKeyForScript(entry.indexKey))) continue;
    entries.push({ key: entry.indexKey, primary: entry.primary, json: entry.json });
  }
  if (direction === "prev" || direction === "prevunique") entries.reverse();
  if (direction === "nextunique" || direction === "prevunique") {
    const unique: CursorEntry[] = [];
    for (const entry of entries) {
      if (unique.length === 0 || compareKeys(unique[unique.length - 1].key, entry.key) !== 0) unique.push(entry);
    }
    return unique;
  }
  return entries;
}

export class IDBIndex {
  get [Symbol.toStringTag](): string { return "IDBIndex"; }
  readonly name: string;
  readonly keyPath: string;
  readonly unique: boolean;
  readonly multiEntry: boolean;
  readonly objectStore: IDBObjectStore;

  constructor(store: IDBObjectStore, name: string, keyPath: string, unique: boolean, multiEntry: boolean) {
    this.objectStore = store;
    this.name = name;
    this.keyPath = keyPath;
    this.unique = unique;
    this.multiEntry = multiEntry;
  }

  /** The keys this record has in the index: one, or one per element of a multiEntry array. */
  _keysOf(value: any): Key[] {
    return indexKeysOf(value, this.keyPath, this.multiEntry);
  }

  /** Every record with its index key, which is what a query walks. */
  _entries(): { indexKey: Key; primary: Key; json: string }[] {
    const out: { indexKey: Key; primary: Key; json: string }[] = [];
    const rows = this.objectStore.db._records(this.objectStore.name);
    for (const row of rows) {
      const keys = this._keysOf(restoreValue(JSON.parse(row.json)));
      for (const key of keys) out.push({ indexKey: key, primary: row.key, json: row.json });
    }
    out.sort((a, b) => {
      const c = compareKeys(a.indexKey, b.indexKey);
      return c !== 0 ? c : compareKeys(a.primary, b.primary);
    });
    return out;
  }

  _matching(query: any, count: number | undefined): { indexKey: Key; primary: Key; json: string }[] {
    const range = query === undefined ? null : query instanceof IDBKeyRange ? query : IDBKeyRange.only(query);
    const entries = this._entries();
    const out: { indexKey: Key; primary: Key; json: string }[] = [];
    const limit = count === undefined ? entries.length : Math.max(0, count);
    for (const entry of entries) {
      if (range !== null && !range.includes(encodeKeyForScript(entry.indexKey))) continue;
      if (out.length >= limit) break;
      out.push(entry);
    }
    return out;
  }

  get(key: any): IDBRequest {
    return this.objectStore._readIndex(this, key, false, true);
  }

  getKey(key: any): IDBRequest {
    return this.objectStore._readIndex(this, key, true, true);
  }

  getAll(query?: any, count?: number): IDBRequest {
    return this.objectStore._readIndex(this, query, false, false, count);
  }

  getAllKeys(query?: any, count?: number): IDBRequest {
    return this.objectStore._readIndex(this, query, true, false, count);
  }

  count(query?: any): IDBRequest {
    return this.objectStore._readIndex(this, query, false, false, undefined, true);
  }

  /** A cursor over the records this index holds, in index-key order. */
  openCursor(query?: any, direction: string = "next"): IDBRequest {
    return this._openCursor(query, direction, false);
  }

  /** A cursor over the index's primary keys alone. */
  openKeyCursor(query?: any, direction: string = "next"): IDBRequest {
    return this._openCursor(query, direction, true);
  }

  private _openCursor(query: any, direction: string, keysOnly: boolean): IDBRequest {
    if (CURSOR_DIRECTIONS.indexOf(direction) < 0) {
      throw new IDBException("TypeError", "The cursor direction '" + direction + "' isn't one of next, nextunique, prev or prevunique.");
    }
    // A query that isn't a key is refused here, as a browser refuses it, not when the request runs.
    const range = cursorRange(query);
    const request = new IDBRequest(this, this.objectStore.transaction);
    const self = this;
    this.objectStore.transaction._queue(() => {
      const cursor = new IDBCursor(self, request, indexCursorEntries(self, range, direction), direction, keysOnly);
      return cursor._step(1, null);
    }, request);
    return request;
  }
}

export class IDBObjectStore {
  get [Symbol.toStringTag](): string { return "IDBObjectStore"; }
  readonly transaction: IDBTransaction;
  readonly name: string;
  readonly keyPath: string;
  readonly autoIncrement: boolean;
  readonly db: IDBDatabase;

  constructor(transaction: IDBTransaction, name: string) {
    this.transaction = transaction;
    this.name = name;
    this.db = transaction.db;
    const row = this.db._storeRow(name);
    if (row === null) throw new IDBException("NotFoundError", "No object store named '" + name + "'.");
    this.keyPath = row.keyPath;
    this.autoIncrement = row.autoIncrement;
  }

  /** The key a value carries at the store's key path, or undefined for an out-of-line store. */
  _keyOfValue(value: any): any {
    if (this.keyPath === "") return undefined;
    const key = keyFromKeyPath(value, this.keyPath);
    if (key === undefined) throw new IDBException("DataError", "The value has no key at '" + this.keyPath + "'.");
    return key;
  }

  /** The indexes the store's schema has now. */
  get indexNames(): string[] {
    const names: string[] = [];
    for (const row of this.db._indexes(this.name)) names.push(row.name);
    return names;
  }

  /** Adds an index to the store; only a version change may. */
  createIndex(name: string, keyPath: any, options?: any): IDBIndex {
    if (this.transaction.mode !== "versionchange") {
      throw new IDBException("InvalidStateError", "Indexes can only be made during a version change.");
    }
    if (typeof keyPath !== "string" || keyPath === "") {
      throw new IDBException("SyntaxError", "An index needs a key path.");
    }
    if (this.indexNames.indexOf(name) >= 0) {
      throw new IDBException("ConstraintError", "An index named '" + name + "' already exists.");
    }
    const unique = options !== undefined && options.unique === true;
    const multiEntry = options !== undefined && options.multiEntry === true;
    this.db._createIndex(this.name, name, keyPath, unique, multiEntry);
    return new IDBIndex(this, name, keyPath, unique, multiEntry);
  }

  deleteIndex(name: string): void {
    if (this.transaction.mode !== "versionchange") {
      throw new IDBException("InvalidStateError", "Indexes can only be removed during a version change.");
    }
    if (this.db._indexRow(this.name, name) === null) {
      throw new IDBException("NotFoundError", "No index named '" + name + "'.");
    }
    this.db._deleteIndex(this.name, name);
  }

  index(name: string): IDBIndex {
    const row = this.db._indexRow(this.name, name);
    if (row === null) throw new IDBException("NotFoundError", "No index named '" + name + "'.");
    return new IDBIndex(this, row.name, row.keyPath, row.unique, row.multiEntry);
  }

  /** Runs an index read in the store's transaction. */
  _readIndex(source: IDBIndex, query: any, keys: boolean, single: boolean, count?: number, counting?: boolean): IDBRequest {
    const request = new IDBRequest(source, this.transaction);
    this.transaction._queue(() => {
      const entries = single
        ? (() => {
          const wanted = keyOf(query);
          const out: { indexKey: Key; primary: Key; json: string }[] = [];
          for (const entry of source._entries()) {
            if (compareKeys(entry.indexKey, wanted) === 0) { out.push(entry); break; }
          }
          return out;
        })()
        : source._matching(query, count);
      if (counting === true) return entries.length;
      if (single === true && keys === true) return entries.length === 0 ? undefined : encodeKeyForScript(entries[0].primary);
      if (single === true) return entries.length === 0 ? undefined : restoreValue(JSON.parse(entries[0].json));
      const out: any[] = [];
      for (const entry of entries) out.push(keys ? encodeKeyForScript(entry.primary) : restoreValue(JSON.parse(entry.json)));
      return out;
    }, request);
    return request;
  }

  /** Adds a record, failing when its key is taken. */
  add(value: any, key?: any): IDBRequest {
    return this._write(value, key, true);
  }

  /** Adds or replaces a record. */
  put(value: any, key?: any): IDBRequest {
    return this._write(value, key, false);
  }

  private _write(value: any, key: any, add: boolean): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(async () => {
      if (self.transaction.mode === "readonly") {
        throw new IDBException("ReadOnlyError", "The transaction is readonly.");
      }
      let useKey = self.keyPath === "" ? key : keyFromKeyPath(value, self.keyPath);
      let generated = false;
      if (useKey === undefined) {
        if (!self.autoIncrement) throw new IDBException("DataError", "The store needs a key.");
        useKey = self.db._nextId(self.name);
        generated = true;
      }
      // The stored value is a clone, and a generated key goes into the clone, never the caller's
      // object.
      const clone = await cloneValue(value);
      if (generated && self.keyPath !== "") {
        if (clone === null || typeof clone !== "object" || Array.isArray(clone)) {
          throw new IDBException("DataError", "The value can't carry a key at '" + self.keyPath + "'.");
        }
        const parts = self.keyPath.split(".");
        let at: any = clone;
        for (let i = 0; i < parts.length - 1; i++) at = at[parts[i]];
        at[parts[parts.length - 1]] = useKey;
      }
      const encoded = keyOf(useKey);
      const text = keyText(encoded);
      const asValue = restoreValue(JSON.parse(JSON.stringify(clone)));
      for (const row of self.db._indexes(self.name)) {
        if (!row.unique) continue;
        const probe = new IDBIndex(self, row.name, row.keyPath, true, row.multiEntry);
        for (const key of probe._keysOf(asValue)) {
          if (self.db._indexKeyTaken(self.name, row, key, text)) {
            throw new IDBException("ConstraintError", "The index '" + row.name + "' already has that key.");
          }
        }
      }
      const existing = self.db._recordText(self.name, text);
      if (existing !== null && add) throw new IDBException("ConstraintError", "The key already exists in the store.");
      const json = JSON.stringify(clone);
      self.db._writeRecord(self.name, text, encoded, json);
      return encodeKeyForScript(encoded);
    }, request);
    return request;
  }

  get(key: any): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      const encoded = keyOf(key);
      return self.db._readRecord(self.name, keyText(encoded));
    }, request);
    return request;
  }

  getKey(key: any): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      const encoded = keyOf(key);
      const json = self.db._readRecord(self.name, keyText(encoded));
      return json === undefined ? undefined : encodeKeyForScript(encoded);
    }, request);
    return request;
  }

  getAll(query?: any, count?: number): IDBRequest {
    return this._readAll(query, count, false);
  }

  getAllKeys(query?: any, count?: number): IDBRequest {
    return this._readAll(query, count, true);
  }

  private _readAll(query: any, count: number | undefined, keys: boolean): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      const range = query === undefined ? null : query instanceof IDBKeyRange ? query : IDBKeyRange.only(query);
      const rows = self.db._records(self.name);
      const hits: { key: Key; json: string }[] = [];
      for (const row of rows) if (range === null || range.includes(encodeKeyForScript(row.key))) hits.push(row);
      hits.sort((a, b) => compareKeys(a.key, b.key));
      const limit = count === undefined ? hits.length : Math.max(0, count);
      const out: any[] = [];
      for (let i = 0; i < hits.length && out.length < limit; i++) {
        out.push(keys ? encodeKeyForScript(hits[i].key) : restoreValue(JSON.parse(hits[i].json)));
      }
      return out;
    }, request);
    return request;
  }

  count(query?: any): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      const range = query === undefined ? null : query instanceof IDBKeyRange ? query : IDBKeyRange.only(query);
      const rows = self.db._records(self.name);
      let n = 0;
      for (const row of rows) if (range === null || range.includes(encodeKeyForScript(row.key))) n++;
      return n;
    }, request);
    return request;
  }

  delete(key: any): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      if (self.transaction.mode === "readonly") throw new IDBException("ReadOnlyError", "The transaction is readonly.");
      const encoded = keyOf(key);
      self.db._deleteRecord(self.name, keyText(encoded));
      return undefined;
    }, request);
    return request;
  }

  clear(): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      if (self.transaction.mode === "readonly") throw new IDBException("ReadOnlyError", "The transaction is readonly.");
      self.db._clearRecords(self.name);
      return undefined;
    }, request);
    return request;
  }

  /** A cursor over the store's records, walking them in the direction asked for. */
  openCursor(query?: any, direction: string = "next"): IDBRequest {
    return this._openCursor(query, direction, false);
  }

  /** A cursor over the store's primary keys alone. */
  openKeyCursor(query?: any, direction: string = "next"): IDBRequest {
    return this._openCursor(query, direction, true);
  }

  private _openCursor(query: any, direction: string, keysOnly: boolean): IDBRequest {
    if (CURSOR_DIRECTIONS.indexOf(direction) < 0) {
      throw new IDBException("TypeError", "The cursor direction '" + direction + "' isn't one of next, nextunique, prev or prevunique.");
    }
    // A query that isn't a key is refused here, as a browser refuses it, not when the request runs.
    const range = cursorRange(query);
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(() => {
      const cursor = new IDBCursor(self, request, storeCursorEntries(self, range, direction), direction, keysOnly);
      return cursor._step(1, null);
    }, request);
    return request;
  }

  /** Writes a value over the record a cursor is on, which keeps the primary key. */
  _replaceAt(value: any, primary: any): IDBRequest {
    const request = new IDBRequest(this, this.transaction);
    const self = this;
    this.transaction._queue(async () => {
      if (self.transaction.mode === "readonly") throw new IDBException("ReadOnlyError", "The transaction is readonly.");
      const primaryKey = keyOf(primary);
      let useKey = primary;
      if (self.keyPath !== "") {
        const named = keyFromKeyPath(value, self.keyPath);
        if (named === undefined) throw new IDBException("DataError", "The value has no key at '" + self.keyPath + "'.");
        if (compareKeys(keyOf(named), primaryKey) !== 0) {
          throw new IDBException("DataError", "The value's key isn't the cursor's primary key.");
        }
        useKey = named;
      }
      const encoded = keyOf(useKey);
      const clone = await cloneValue(value);
      const text = keyText(encoded);
      // A rewritten record has to pass the same unique indexes a put does, itself excepted.
      const asValue = restoreValue(JSON.parse(JSON.stringify(clone)));
      for (const row of self.db._indexes(self.name)) {
        if (!row.unique) continue;
        const probe = new IDBIndex(self, row.name, row.keyPath, true, row.multiEntry);
        for (const key of probe._keysOf(asValue)) {
          if (self.db._indexKeyTaken(self.name, row, key, text)) {
            throw new IDBException("ConstraintError", "The index '" + row.name + "' already has that key.");
          }
        }
      }
      self.db._writeRecord(self.name, text, encoded, JSON.stringify(clone));
      return encodeKeyForScript(encoded);
    }, request);
    return request;
  }
}

// ---------------------------------------------------------------------------
// Databases

/** One open connection to a database. */
export class IDBDatabase extends Target {
  get [Symbol.toStringTag](): string { return "IDBDatabase"; }
  readonly name: string;
  readonly _db: SqliteDb;
  version: number;
  onabort: ((event: any) => void) | null = null;
  onclose: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onversionchange: ((event: any) => void) | null = null;

  private transactions: IDBTransaction[] = [];
  private closed: boolean = false;
  /** The transaction SQLite has open, and the ones waiting for it to finish. */
  private activeTx: IDBTransaction | null = null;
  private waitingTx: IDBTransaction[] = [];
  /** The object store rows, name, key path and generator, read once. */
  private stores: { name: string; keyPath: string; autoIncrement: boolean; nextId: number }[] = [];

  constructor(name: string, db: SqliteDb, version: number) {
    super();
    this.name = name;
    this._db = db;
    this.version = version;
    this._loadStores();
  }

  /** The stores a version's schema holds, as the tables have them now. */
  get objectStoreNames(): string[] {
    const names: string[] = [];
    for (const store of this.stores) names.push(store.name);
    return names;
  }

  _loadStores(): void {
    this.stores = [];
    const stmt = new SqliteStmt(this._db.prepare("SELECT name, key_path, auto_increment, next_id FROM stores ORDER BY id"));
    while (stmt.step() === SQLITE_ROW) {
      this.stores.push({
        name: stmt.columnText(0), keyPath: stmt.columnText(1),
        autoIncrement: stmt.columnDouble(2) !== 0, nextId: stmt.columnDouble(3),
      });
    }
    stmt.finalize();
  }

  _storeRow(name: string): { keyPath: string; autoIncrement: boolean } | null {
    for (const store of this.stores) {
      if (store.name === name) return { keyPath: store.keyPath, autoIncrement: store.autoIncrement };
    }
    return null;
  }

  /** The key the store's generator hands out next, advanced now. */
  _nextId(name: string): number {
    for (const store of this.stores) {
      if (store.name !== name) continue;
      const id = store.nextId;
      store.nextId = id + 1;
      const stmt = new SqliteStmt(this._db.prepare("UPDATE stores SET next_id = ? WHERE name = ?"));
      stmt.bindDouble(1, store.nextId);
      stmt.bindText(2, name);
      stmt.step();
      stmt.finalize();
      return id;
    }
    throw new IDBException("NotFoundError", "No object store named '" + name + "'.");
  }

  /** The records of a store, with their keys. */
  _records(name: string): { key: Key; json: string }[] {
    const out: { key: Key; json: string }[] = [];
    const stmt = new SqliteStmt(this._db.prepare(
      "SELECT kt, kn, ks, kb, key, value FROM records WHERE store = ?"));
    stmt.bindText(1, name);
    while (stmt.step() === SQLITE_ROW) {
      out.push({
        key: decodeKeyRow(stmt.columnDouble(0), stmt.columnDouble(1), stmt.columnText(2), stmt.columnBlob(3)),
        json: stmt.columnText(5),
      });
    }
    stmt.finalize();
    return out;
  }

  _recordText(name: string, text: string): string | null {
    const stmt = new SqliteStmt(this._db.prepare("SELECT value FROM records WHERE store = ? AND key = ?"));
    stmt.bindText(1, name);
    stmt.bindText(2, text);
    const hit = stmt.step() === SQLITE_ROW ? stmt.columnText(0) : null;
    stmt.finalize();
    return hit;
  }

  _readRecord(name: string, text: string): any {
    const json = this._recordText(name, text);
    return json === null ? undefined : restoreValue(JSON.parse(json));
  }

  _writeRecord(name: string, text: string, key: Key, json: string): void {
    const stmt = new SqliteStmt(this._db.prepare(
      "INSERT INTO records (store, kt, kn, ks, kb, key, value) VALUES (?, ?, ?, ?, ?, ?, ?) " +
      "ON CONFLICT(store, key) DO UPDATE SET kt = excluded.kt, kn = excluded.kn, ks = excluded.ks, " +
      "kb = excluded.kb, value = excluded.value"));
    stmt.bindText(1, name);
    stmt.bindDouble(2, key.type);
    stmt.bindDouble(3, key.number);
    stmt.bindText(4, key.type === 4 ? keyText(key) : key.text);
    stmt.bindBlob(5, key.bytes);
    stmt.bindText(6, text);
    stmt.bindText(7, json);
    stmt.step();
    stmt.finalize();
  }

  _deleteRecord(name: string, text: string): void {
    const stmt = new SqliteStmt(this._db.prepare("DELETE FROM records WHERE store = ? AND key = ?"));
    stmt.bindText(1, name);
    stmt.bindText(2, text);
    stmt.step();
    stmt.finalize();
  }

  _clearRecords(name: string): void {
    const stmt = new SqliteStmt(this._db.prepare("DELETE FROM records WHERE store = ?"));
    stmt.bindText(1, name);
    stmt.step();
    stmt.finalize();
  }

  /** The index rows of a store, as the tables have them now. */
  _indexes(store: string): { name: string; keyPath: string; unique: boolean; multiEntry: boolean }[] {
    const out: { name: string; keyPath: string; unique: boolean; multiEntry: boolean }[] = [];
    const stmt = new SqliteStmt(this._db.prepare(
      "SELECT name, key_path, unique_flag, multi_entry FROM indexes WHERE store = ? ORDER BY id"));
    stmt.bindText(1, store);
    while (stmt.step() === SQLITE_ROW) {
      out.push({ name: stmt.columnText(0), keyPath: stmt.columnText(1), unique: stmt.columnDouble(2) !== 0, multiEntry: stmt.columnDouble(3) !== 0 });
    }
    stmt.finalize();
    return out;
  }

  _indexRow(store: string, name: string): { name: string; keyPath: string; unique: boolean; multiEntry: boolean } | null {
    for (const row of this._indexes(store)) if (row.name === name) return row;
    return null;
  }

  _createIndex(store: string, name: string, keyPath: string, unique: boolean, multiEntry: boolean): void {
    const stmt = new SqliteStmt(this._db.prepare(
      "INSERT INTO indexes (store, name, key_path, unique_flag, multi_entry) VALUES (?, ?, ?, ?, ?)"));
    stmt.bindText(1, store);
    stmt.bindText(2, name);
    stmt.bindText(3, keyPath);
    stmt.bindInt(4, unique ? 1 : 0);
    stmt.bindInt(5, multiEntry ? 1 : 0);
    stmt.step();
    stmt.finalize();
  }

  _deleteIndex(store: string, name: string): void {
    const stmt = new SqliteStmt(this._db.prepare("DELETE FROM indexes WHERE store = ? AND name = ?"));
    stmt.bindText(1, store);
    stmt.bindText(2, name);
    stmt.step();
    stmt.finalize();
  }

  /** Whether another record already has this key in the index. */
  _indexKeyTaken(store: string, row: { name: string; keyPath: string; multiEntry: boolean }, key: Key, exceptText: string): boolean {
    for (const record of this._records(store)) {
      if (keyText(record.key) === exceptText) continue;
      const keys = indexKeysOf(restoreValue(JSON.parse(record.json)), row.keyPath, row.multiEntry);
      for (const other of keys) if (compareKeys(other, key) === 0) return true;
    }
    return false;
  }

  /** Starts a transaction over the named stores (or all of them for a version change). */
  transaction(stores: string | string[], mode: string = "readonly", options?: any): IDBTransaction {
    void options;
    if (this.closed) throw new IDBException("InvalidStateError", "The connection is closed.");
    const names: string[] = typeof stores === "string" ? [stores] : stores.slice();
    if (names.length === 0) throw new IDBException("InvalidAccessError", "A transaction needs a store.");
    for (const name of names) {
      if (this.objectStoreNames.indexOf(name) < 0) {
        throw new IDBException("NotFoundError", "No object store named '" + name + "'.");
      }
    }
    if (mode !== "readonly" && mode !== "readwrite") {
      throw new IDBException("TypeError", "The transaction mode isn't readonly or readwrite.");
    }
    return new IDBTransaction(this, names, mode);
  }

  /** Runs the upgrade's versionchange transaction, which may add and remove stores. */
  _versionTransaction(oldVersion: number, newVersion: number): IDBTransaction {
    this.version = newVersion;
    return new IDBTransaction(this, this.objectStoreNames.slice(), "versionchange", true);
  }

  createObjectStore(name: string, options?: any): IDBObjectStore {
    if (this.closed) throw new IDBException("InvalidStateError", "The connection is closed.");
    if (this._activeTransaction === null) {
      throw new IDBException("InvalidStateError", "Object stores can only be made during a version change.");
    }
    if (this.objectStoreNames.indexOf(name) >= 0) {
      throw new IDBException("ConstraintError", "An object store named '" + name + "' already exists.");
    }
    const keyPath = options !== undefined && typeof options.keyPath === "string" ? options.keyPath : "";
    const autoIncrement = options !== undefined && options.autoIncrement === true;
    if (autoIncrement && keyPath !== "" && !/^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$/.test(keyPath)) {
      throw new IDBException("SyntaxError", "The key path isn't an identifier.");
    }
    const stmt = new SqliteStmt(this._db.prepare(
      "INSERT INTO stores (name, key_path, auto_increment, next_id) VALUES (?, ?, ?, 1)"));
    stmt.bindText(1, name);
    stmt.bindText(2, keyPath);
    stmt.bindInt(3, autoIncrement ? 1 : 0);
    stmt.step();
    stmt.finalize();
    this._loadStores();
    return new IDBObjectStore(this._activeTransaction!, name);
  }

  /** The transaction a versionchange handler is running in. */
  _activeTransaction: IDBTransaction | null = null;

  deleteObjectStore(name: string): void {
    if (this.closed) throw new IDBException("InvalidStateError", "The connection is closed.");
    if (this._activeTransaction === null) {
      throw new IDBException("InvalidStateError", "Object stores can only be removed during a version change.");
    }
    if (this.objectStoreNames.indexOf(name) < 0) {
      throw new IDBException("NotFoundError", "No object store named '" + name + "'.");
    }
    for (const sql of ["DELETE FROM records WHERE store = ?", "DELETE FROM indexes WHERE store = ?", "DELETE FROM stores WHERE name = ?"]) {
      const stmt = new SqliteStmt(this._db.prepare(sql));
      stmt.bindText(1, name);
      stmt.step();
      stmt.finalize();
    }
    this._loadStores();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const transaction of this.transactions.slice()) transaction.abort();
    const at = openDatabases.indexOf(this);
    if (at >= 0) openDatabases.splice(at, 1);
    this._db.close();
    resumedOpen();
  }

  /** Starts a transaction, or waits until the one SQLite has open finishes. */
  _enqueue(transaction: IDBTransaction): void {
    if (this.activeTx === null) {
      this.activeTx = transaction;
      transaction._start();
    } else {
      this.waitingTx.push(transaction);
    }
  }

  /** A transaction has finished; the next one waiting may start. */
  _transactionDone(transaction: IDBTransaction): void {
    if (this.activeTx === transaction) this.activeTx = null;
    if (this.waitingTx.length > 0 && this.activeTx === null && !this.closed) {
      const next = this.waitingTx.shift()!;
      this.activeTx = next;
      next._start();
    }
  }

  _register(transaction: IDBTransaction): void {
    if (this.transactions.indexOf(transaction) < 0) this.transactions.push(transaction);
  }

  _unregister(transaction: IDBTransaction): void {
    const at = this.transactions.indexOf(transaction);
    if (at >= 0) this.transactions.splice(at, 1);
  }
}

// ---------------------------------------------------------------------------
// Opening

const openDatabases: IDBDatabase[] = [];

/** A pending open or delete waiting for another connection to close. */
let pendingOpen: (() => void) | null = null;

/** Tries the waiting open again after a connection closed. */
function resumedOpen(): void {
  if (pendingOpen !== null) {
    const retry = pendingOpen;
    pendingOpen = null;
    retry();
  }
}

function safeName(name: string): string {
  let out = "";
  for (let i = 0; i < name.length && out.length < 64; i++) {
    const ch = name[i];
    out += /[A-Za-z0-9_-]/.test(ch) ? ch : "-";
  }
  return out === "" ? "db" : out;
}

function dbPath(name: string): string {
  return join(storeDirectory(), safeName(name) + ".sqlite");
}

/** Creates the store's tables in a new database. */
function initSchema(db: SqliteDb): void {
  db.exec(
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
    "CREATE TABLE IF NOT EXISTS stores (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, " +
    "key_path TEXT NOT NULL DEFAULT '', auto_increment INTEGER NOT NULL DEFAULT 0, next_id INTEGER NOT NULL DEFAULT 1);" +
    "CREATE TABLE IF NOT EXISTS records (store TEXT NOT NULL, kt INTEGER NOT NULL, kn REAL NOT NULL DEFAULT 0, " +
    "ks TEXT NOT NULL DEFAULT '', kb BLOB NOT NULL DEFAULT x'', key TEXT NOT NULL, value TEXT NOT NULL, " +
    "PRIMARY KEY (store, key));" +
    "CREATE TABLE IF NOT EXISTS indexes (id INTEGER PRIMARY KEY AUTOINCREMENT, store TEXT NOT NULL, " +
    "name TEXT NOT NULL, key_path TEXT NOT NULL, unique_flag INTEGER NOT NULL DEFAULT 0, " +
    "multi_entry INTEGER NOT NULL DEFAULT 0, UNIQUE (store, name));");
}

function readVersion(db: SqliteDb): number {
  const stmt = new SqliteStmt(db.prepare("SELECT value FROM meta WHERE key = 'version'"));
  const version = stmt.step() === SQLITE_ROW ? Number(stmt.columnText(0)) : 0;
  stmt.finalize();
  return isNaN(version) ? 0 : version;
}

function writeVersion(db: SqliteDb, version: number): void {
  const stmt = new SqliteStmt(db.prepare(
    "INSERT INTO meta (key, value) VALUES ('version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"));
  stmt.bindText(1, String(version));
  stmt.step();
  stmt.finalize();
}

/** The factory the page calls indexedDB. */
export class IDBFactory {
  get [Symbol.toStringTag](): string { return "IDBFactory"; }
  open(name: string, version?: number): IDBOpenDBRequest {
    const request = new IDBOpenDBRequest();
    const dbName = String(name);
    const wanted = version === undefined ? undefined : Number(version);
    const run = (): void => {
      if (wanted !== undefined && (!isFinite(wanted) || wanted <= 0 || Math.floor(wanted) !== wanted)) {
        request.fail(new IDBException("TypeError", "The version must be a positive integer."));
        return;
      }
      const path = dbPath(dbName);
      const sql = SqliteDb.open(path);
      if (sql === null) {
        request.fail(new IDBException("UnknownError", "The database couldn't be opened."));
        return;
      }
      try {
        initSchema(sql);
      } catch (e) {
        sql.close();
        request.fail(new IDBException("UnknownError", String(e)));
        return;
      }
      const current = readVersion(sql);
      const next = wanted === undefined ? (current === 0 ? 1 : current) : wanted;
      if (next < current) {
        sql.close();
        request.fail(new IDBException("VersionError", "The requested version is lower than the current version."));
        return;
      }
      if (next === current && current > 0) {
        const db = new IDBDatabase(dbName, sql, current);
        openDatabases.push(db);
        request.succeed(db);
        return;
      }
      // A version change needs the other connections closed; ask them and continue when they are.
      const others = openDatabases.filter((db) => db.name === dbName);
      for (const other of others) {
        other.dispatchEvent(new IDBVersionChangeEvent("versionchange", { oldVersion: current, newVersion: next }));
      }
      if (others.length > 0) {
        request.dispatchEvent(new Event("blocked"));
        sql.close();
        pendingOpen = run;
        return;
      }
      sql.close();
      upgrade(dbName, path, current, next, request);
    };
    Promise.resolve().then(run);
    return request;
  }

  deleteDatabase(name: string): IDBOpenDBRequest {
    const request = new IDBOpenDBRequest();
    const dbName = String(name);
    const run = (): void => {
      const others = openDatabases.filter((db) => db.name === dbName);
      for (const other of others) {
        other.dispatchEvent(new IDBVersionChangeEvent("versionchange", { oldVersion: other.version, newVersion: 0 }));
      }
      if (others.length > 0) {
        request.dispatchEvent(new Event("blocked"));
        pendingOpen = run;
        return;
      }
      const path = dbPath(dbName);
      if (existsSync(path)) {
        try {
          unlinkSync(path);
        } catch (e) {
          request.fail(new IDBException("UnknownError", String(e)));
          return;
        }
      }
      request.succeed(undefined);
    };
    Promise.resolve().then(run);
    return request;
  }

  databases(): Promise<{ name: string; version: number }[]> {
    return Promise.resolve().then(() => {
      const dir = storeDirectory();
      const out: { name: string; version: number }[] = [];
      for (const file of readdirSync(dir)) {
        if (!file.endsWith(".sqlite")) continue;
        const sql = SqliteDb.open(join(dir, file));
        if (sql === null) continue;
        initSchema(sql);
        const version = readVersion(sql);
        sql.close();
        out.push({ name: file.slice(0, file.length - 7), version });
      }
      return out;
    });
  }
}

/** Opens the store and runs the upgrade in a versionchange transaction, then reports success. */
function upgrade(name: string, path: string, oldVersion: number, newVersion: number, request: IDBOpenDBRequest): void {
  const sql = SqliteDb.open(path);
  if (sql === null) {
    request.fail(new IDBException("UnknownError", "The database couldn't be opened."));
    return;
  }
  initSchema(sql);
  const db = new IDBDatabase(name, sql, oldVersion);
  // During the upgrade the request's result is the database being upgraded, as in a browser.
  request.result = db;
  openDatabases.push(db);
  const transaction = db._versionTransaction(oldVersion, newVersion);
  db._activeTransaction = transaction;
  request.transaction = transaction;
  let failed: any = null;
  transaction.addEventListener("abort", () => {
    failed = transaction.error === null ? new IDBException("AbortError", "The upgrade was aborted.") : transaction.error;
  });
  request.dispatchEvent(new IDBVersionChangeEvent("upgradeneeded", { oldVersion, newVersion }));
  db._activeTransaction = null;
  // The upgrade's own requests run through the transaction; when it completes, so does the open.
  transaction.addEventListener("complete", () => finishOpen(db, transaction, request, newVersion, null));
}

function finishOpen(db: IDBDatabase, transaction: IDBTransaction, request: IDBOpenDBRequest, version: number, failed: any): void {
  if (failed !== null) {
    db.close();
    request.fail(failed instanceof Error ? failed : new IDBException("AbortError", "The upgrade was aborted."));
    return;
  }
  request.transaction = null;
  try {
    writeVersion(db._db, version);
  } catch (e) {
    db.close();
    request.fail(new IDBException("UnknownError", String(e)));
    return;
  }
  request.succeed(db);
}

/** The page's one factory, made on first use so loading the module has no side effects. */
let factoryInstance: IDBFactory | null = null;

function factory(): IDBFactory {
  if (factoryInstance === null) factoryInstance = new IDBFactory();
  return factoryInstance;
}

/** The page's indexedDB global. */
export const indexedDB = {
  open(name: string, version?: number): IDBOpenDBRequest { return factory().open(name, version); },
  deleteDatabase(name: string): IDBOpenDBRequest { return factory().deleteDatabase(name); },
  databases(): Promise<{ name: string; version: number }[]> { return factory().databases(); },
};

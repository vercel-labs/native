// A small binding over the host's SQLite: the store IndexedDB keeps its records in. A database is
// a file in the app's own data directory; statements are prepared once and stepped row by row, all
// synchronously, which is what lets IndexedDB requests run in the order their transaction queued.

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import {
  hostSqliteBindBlob, hostSqliteBindDouble, hostSqliteBindInt, hostSqliteBindNull, hostSqliteBindText,
  hostSqliteChanges, hostSqliteClearBindings, hostSqliteClose, hostSqliteColumnBlob,
  hostSqliteColumnDouble, hostSqliteColumnText, hostSqliteColumnType, hostSqliteErrmsg,
  hostSqliteExec, hostSqliteFinalize, hostSqliteLastId, hostSqliteOpen, hostSqlitePrepare,
  hostSqliteReset, hostSqliteStep, hostStorageDir, hostStorageOpen,
} from "./host.ts";

export const SQLITE_OK = 0;
export const SQLITE_ROW = 100;
export const SQLITE_DONE = 101;
export const SQLITE_CONSTRAINT = 19;

/** The app's name, which picks its data directory; mount sets it from the page's title. */
let appName = "app";

export function setStoreAppName(name: string): void {
  if (name !== "") appName = name;
}

/** The app's data directory, with the indexeddb folder made inside it. */
export function storeDirectory(): string {
  let dir = "";
  hostStorageDir((value) => {
    dir = value;
  });
  if (dir === "") {
    // No localStorage has been opened yet: its name finds the same directory.
    hostStorageOpen(appName);
    hostStorageDir((value) => {
      dir = value;
    });
  }
  const indexed = join(dir, "indexeddb");
  mkdirSync(indexed, { recursive: true });
  return indexed;
}

/** One open database. Statements prepared against it are finalized with it. */
export class SqliteDb {
  readonly id: number;

  constructor(id: number) {
    this.id = id;
  }

  /** Opens a database file; null when SQLite can't open it. */
  static open(path: string): SqliteDb | null {
    const id = hostSqliteOpen(path);
    return id === 0 ? null : new SqliteDb(id);
  }

  exec(sql: string): number {
    return hostSqliteExec(this.id, sql);
  }

  /** Prepares one statement, or returns 0 when it doesn't parse. */
  prepare(sql: string): number {
    return hostSqlitePrepare(this.id, sql);
  }

  /** The rows the last statement changed, and the rowid it inserted. */
  changes(): number {
    return hostSqliteChanges(this.id);
  }

  lastId(): number {
    return hostSqliteLastId(this.id);
  }

  error(): string {
    let message = "";
    hostSqliteErrmsg(this.id, (value) => {
      message = value;
    });
    return message === "" ? "SQLite error" : message;
  }

  close(): void {
    hostSqliteClose(this.id);
  }
}

/** One prepared statement. */
export class SqliteStmt {
  readonly id: number;

  constructor(id: number) {
    this.id = id;
  }

  bindText(index: number, value: string): void {
    hostSqliteBindText(this.id, index, value);
  }

  bindDouble(index: number, value: number): void {
    hostSqliteBindDouble(this.id, index, value);
  }

  bindInt(index: number, value: number): void {
    hostSqliteBindInt(this.id, index, value);
  }

  bindNull(index: number): void {
    hostSqliteBindNull(this.id, index);
  }

  bindBlob(index: number, value: Uint8Array): void {
    hostSqliteBindBlob(this.id, index, value);
  }

  /** SQLITE_ROW (100), SQLITE_DONE (101) or an error code. */
  step(): number {
    return hostSqliteStep(this.id);
  }

  reset(): void {
    hostSqliteReset(this.id);
    hostSqliteClearBindings(this.id);
  }

  finalize(): void {
    hostSqliteFinalize(this.id);
  }

  /** The SQLite type of a column: 1 integer, 2 float, 3 text, 4 blob, 5 null. */
  columnType(col: number): number {
    return hostSqliteColumnType(this.id, col);
  }

  columnText(col: number): string {
    let value = "";
    hostSqliteColumnText(this.id, col, (text) => {
      value = text;
    });
    return value;
  }

  columnBlob(col: number): Uint8Array {
    let bytes = new Uint8Array(0);
    hostSqliteColumnBlob(this.id, col, (blob) => {
      const copy = new Uint8Array(blob.length);
      for (let i = 0; i < blob.length; i++) copy[i] = blob[i];
      bytes = copy;
    });
    return bytes;
  }

  columnDouble(col: number): number {
    return hostSqliteColumnDouble(this.id, col);
  }
}

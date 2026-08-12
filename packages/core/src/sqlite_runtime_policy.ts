// Runtime-owned SQLite policy shared by schema/query analysis and the
// node devhost. Node's SQLite is intentionally only the parser/executor for
// those tools: its build enables optional modules and functions that the
// vendored app engine does not ship, so this gate narrows it to the runtime's
// documented FTS5 + JSON surface.

import { constants as sqliteConstants } from "node:sqlite";

const relationalOwnedPragmas = new Set([
  "user_version", "schema_version", "writable_schema", "query_only",
  "journal_mode", "synchronous", "locking_mode", "foreign_keys",
  "defer_foreign_keys", "busy_timeout", "wal_autocheckpoint", "temp_store",
  "temp_store_directory", "data_store_directory",
]);

const relationalVirtualTableModules = new Set(["fts5", "fts5vocab"]);
const relationalUnavailableReadTables = new Set(["dbstat", "fts3tokenize"]);

// SQLITE_ENABLE_MATH_FUNCTIONS is enabled in Node's SQLite but not in the
// app engine. These names are otherwise absent from the vendored build (the
// core `round` function is deliberately not part of this list).
const relationalOptionalFunctions = new Set([
  "acos", "acosh", "asin", "asinh", "atan", "atan2", "atanh",
  "ceil", "ceiling", "cos", "cosh", "degrees", "exp", "floor", "ln",
  "log", "log10", "log2", "mod", "pi", "pow", "power", "radians",
  "sin", "sinh", "sqrt", "tan", "tanh", "trunc",
  // Node also enables RTREE/GEOPOLY. CREATE VIRTUAL TABLE is gated below;
  // reject their scalar inspection helpers as well.
  "rtreecheck", "rtreedepth", "rtreenode",
]);

export function relationalRuntimePolicy(
  action: number,
  first: string | null,
  second: string | null,
): number {
  if (action === sqliteConstants.SQLITE_ATTACH || action === sqliteConstants.SQLITE_DETACH) {
    return sqliteConstants.SQLITE_DENY;
  }
  if (action === sqliteConstants.SQLITE_PRAGMA && second !== null && relationalOwnedPragmas.has((first ?? "").toLowerCase())) {
    return sqliteConstants.SQLITE_DENY;
  }
  if (action === sqliteConstants.SQLITE_CREATE_VTABLE && !relationalVirtualTableModules.has((second ?? "").toLowerCase())) {
    return sqliteConstants.SQLITE_DENY;
  }
  if (action === sqliteConstants.SQLITE_READ && relationalUnavailableReadTables.has((first ?? "").toLowerCase())) {
    return sqliteConstants.SQLITE_DENY;
  }
  if (action === sqliteConstants.SQLITE_FUNCTION) {
    const name = (second ?? first ?? "").toLowerCase();
    if (relationalOptionalFunctions.has(name) || name.startsWith("geopoly_")) {
      return sqliteConstants.SQLITE_DENY;
    }
  }
  return sqliteConstants.SQLITE_OK;
}

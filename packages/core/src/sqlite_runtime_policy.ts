// Runtime-owned SQLite policy shared by schema/query analysis and the
// node devhost. Node's SQLite is intentionally only the parser/executor for
// those tools: its build enables optional modules and functions that the
// vendored app engine does not ship, so this gate narrows it to the runtime's
// documented FTS5 + JSON surface.

import { constants as sqliteConstants, type DatabaseSync } from "node:sqlite";

type SqliteAuthorizer = (
  action: number,
  first: string | null,
  second: string | null,
  databaseName?: string | null,
  triggerOrView?: string | null,
) => number;
type AuthorizerDatabase = DatabaseSync & {
  setAuthorizer?: (callback: SqliteAuthorizer | null) => void;
};

interface SqlToken {
  readonly text: string;
  readonly kind: "word" | "identifier" | "literal" | "symbol";
}

export interface RelationalTableReference {
  readonly schema: string | null;
  readonly table: string;
}

const relationalOwnedPragmas = new Set([
  "user_version", "schema_version", "writable_schema", "query_only",
  "journal_mode", "synchronous", "locking_mode", "foreign_keys",
  "defer_foreign_keys", "busy_timeout", "wal_autocheckpoint", "temp_store",
  "temp_store_directory", "data_store_directory",
]);

const relationalVirtualTableModules = new Set(["fts5", "fts5vocab"]);
const relationalUnavailableReadTables = new Set(["dbstat", "fts3tokenize"]);
const relationalTempSchemaActions = new Set([
  sqliteConstants.SQLITE_CREATE_TEMP_INDEX, sqliteConstants.SQLITE_CREATE_TEMP_TABLE,
  sqliteConstants.SQLITE_CREATE_TEMP_TRIGGER, sqliteConstants.SQLITE_CREATE_TEMP_VIEW,
  sqliteConstants.SQLITE_DROP_TEMP_INDEX, sqliteConstants.SQLITE_DROP_TEMP_TABLE,
  sqliteConstants.SQLITE_DROP_TEMP_TRIGGER, sqliteConstants.SQLITE_DROP_TEMP_VIEW,
]);

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
  // The app engine is compiled with SQLITE_OMIT_LOAD_EXTENSION. Node keeps
  // the function in its parser surface even though execution is unauthorized.
  "load_extension",
]);

function sqlTokens(sql: string): SqlToken[] {
  const tokens: SqlToken[] = [];
  let at = 0;
  while (at < sql.length) {
    const char = sql[at]!;
    if (/\s/.test(char)) { at += 1; continue; }
    if (char === ";") { at += 1; continue; }
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
    if (char === "'") {
      let text = "";
      at += 1;
      while (at < sql.length) {
        if (sql[at] !== "'") { text += sql[at]!; at += 1; continue; }
        if (sql[at + 1] === "'") { text += "'"; at += 2; continue; }
        at += 1;
        break;
      }
      tokens.push({ text: text.toLowerCase(), kind: "literal" });
      continue;
    }
    if (char === "\"" || char === "`" || char === "[") {
      const close = char === "[" ? "]" : char;
      let text = "";
      at += 1;
      while (at < sql.length) {
        if (sql[at] !== close) { text += sql[at]!; at += 1; continue; }
        if (sql[at + 1] === close) { text += close; at += 2; continue; }
        at += 1;
        break;
      }
      tokens.push({ text: text.toLowerCase(), kind: "identifier" });
      continue;
    }
    if (/[A-Za-z_]/.test(char)) {
      let end = at + 1;
      while (/[A-Za-z0-9_$]/.test(sql[end] ?? "")) end += 1;
      tokens.push({ text: sql.slice(at, end).toLowerCase(), kind: "word" });
      at = end;
      continue;
    }
    tokens.push({ text: char, kind: "symbol" });
    at += 1;
  }
  return tokens;
}

function tokenName(token: SqlToken | undefined): string | null {
  return token?.kind === "word" || token?.kind === "identifier" ? token.text : null;
}

function sqliteName(token: SqlToken | undefined): string | null {
  return token?.kind === "literal" ? token.text : tokenName(token);
}

const relationalFromTerminators = new Set([
  "where", "group", "having", "window", "order", "limit", "returning",
  "union", "intersect", "except",
]);

function tableReferenceAt(tokens: readonly SqlToken[], start: number): RelationalTableReference | null {
  const first = sqliteName(tokens[start]);
  if (first === null) return null;
  if (tokens[start + 1]?.text !== ".") return { schema: null, table: first };
  const table = sqliteName(tokens[start + 2]);
  return table === null ? null : { schema: first, table };
}

/// Table factors named by one SQLite statement. The scanner follows FROM
/// lists at each parenthesis depth, including comma joins, and preserves
/// quoted identifiers as one token. SQLite remains the grammar authority;
/// this is the shared compatibility/dependency view used where Node 22 has no
/// authorizer callback and where EXPLAIN text loses identifier boundaries.
export function relationalTableReferences(sql: string): readonly RelationalTableReference[] {
  const tokens = sqlTokens(sql);
  const references: RelationalTableReference[] = [];
  const fromDepths = new Set<number>();
  const expectingAtDepth = new Set<number>();
  let depth = 0;

  for (let at = 0; at < tokens.length; at++) {
    const token = tokens[at]!;
    if (token.text === "(") {
      expectingAtDepth.delete(depth);
      depth += 1;
      continue;
    }
    if (token.text === ")") {
      fromDepths.delete(depth);
      expectingAtDepth.delete(depth);
      depth = Math.max(0, depth - 1);
      continue;
    }

    if (expectingAtDepth.has(depth)) {
      const reference = tableReferenceAt(tokens, at);
      expectingAtDepth.delete(depth);
      if (reference !== null) references.push(reference);
    }

    if (token.kind === "word" && token.text === "from") {
      fromDepths.add(depth);
      expectingAtDepth.add(depth);
      continue;
    }
    if (token.kind === "word" && token.text === "join") {
      fromDepths.add(depth);
      expectingAtDepth.add(depth);
      continue;
    }
    if (fromDepths.has(depth) && token.text === ",") {
      expectingAtDepth.add(depth);
      continue;
    }
    if (fromDepths.has(depth) && token.kind === "word" && relationalFromTerminators.has(token.text)) {
      fromDepths.delete(depth);
      expectingAtDepth.delete(depth);
      continue;
    }
    if (token.kind === "word" && (token.text === "update" || token.text === "into")) {
      let tableAt = at + 1;
      if (token.text === "update" && tokens[tableAt]?.kind === "word" && tokens[tableAt]?.text === "or") tableAt += 2;
      const reference = tableReferenceAt(tokens, tableAt);
      if (reference !== null) references.push(reference);
    }
  }
  return references;
}

function cteNamesAndMainToken(tokens: readonly SqlToken[], start: number): { ctes: Set<string>; declarations: Set<number>; main: number } {
  const ctes = new Set<string>();
  const declarations = new Set<number>();
  if (tokens[start]?.kind !== "word" || tokens[start]?.text !== "with") return { ctes, declarations, main: start };
  let at = tokens[start + 1]?.kind === "word" && tokens[start + 1]?.text === "recursive" ? start + 2 : start + 1;
  while (at < tokens.length) {
    const name = sqliteName(tokens[at]);
    if (name === null) break;
    ctes.add(name);
    declarations.add(at);
    at += 1;
    if (tokens[at]?.text === "(") {
      let depth = 1;
      while (++at < tokens.length && depth > 0) {
        if (tokens[at]?.text === "(") depth += 1;
        else if (tokens[at]?.text === ")") depth -= 1;
      }
    }
    if (tokens[at]?.kind !== "word" || tokens[at]?.text !== "as") break;
    at += 1;
    if (tokens[at]?.kind === "word" && tokens[at]?.text === "not") at += 1;
    if (tokens[at]?.kind === "word" && tokens[at]?.text === "materialized") at += 1;
    if (tokens[at]?.text !== "(") break;
    let depth = 1;
    while (++at < tokens.length && depth > 0) {
      if (tokens[at]?.text === "(") depth += 1;
      else if (tokens[at]?.text === ")") depth -= 1;
    }
    if (tokens[at]?.text !== ",") break;
    at += 1;
  }
  return { ctes, declarations, main: at };
}

/// Node 22 ships `node:sqlite` without DatabaseSync.setAuthorizer. Keep the
/// native authorizer when the host provides it, and let callers pair this with
/// `inspectRelationalSql` on older supported Node releases.
export function setRelationalAuthorizer(
  db: DatabaseSync,
  callback: SqliteAuthorizer | null,
): boolean {
  const setAuthorizer = (db as AuthorizerDatabase).setAuthorizer;
  if (typeof setAuthorizer !== "function") return false;
  setAuthorizer.call(db, callback);
  return true;
}

export interface RelationalSqlInspection {
  readonly error: string | null;
  readonly writes: boolean;
}

/// Preflight one SQLite statement without executing it. SQLite remains the
/// grammar authority; this compatibility inspection covers the policy events
/// that Node 22 cannot expose through an authorizer callback.
export function inspectRelationalSql(sql: string, denyTransactions: boolean): RelationalSqlInspection {
  const tokens = sqlTokens(sql);
  let start = 0;
  if (tokens[start]?.kind === "word" && tokens[start]?.text === "explain") {
    start += 1;
    if (tokens[start]?.kind === "word" && tokens[start]?.text === "query" && tokens[start + 1]?.kind === "word" && tokens[start + 1]?.text === "plan") start += 2;
  }
  const { ctes, declarations, main } = cteNamesAndMainToken(tokens, start);
  const keyword = tokens[main]?.kind === "word" ? tokens[main]?.text ?? "" : "";
  const writes = keyword === "insert" || keyword === "update" || keyword === "delete" || keyword === "replace" ||
    keyword === "create" || keyword === "drop" || keyword === "alter";

  if (keyword === "attach" || keyword === "detach" || keyword === "vacuum") {
    return { error: "not authorized to access databases outside the relational store", writes };
  }
  if (ddlTargetsTempSchema(tokens, main, keyword)) {
    return { error: "TEMP schema objects are not authorized because native reads use a separate connection", writes };
  }
  if (denyTransactions && (keyword === "begin" || keyword === "commit" || keyword === "end" || keyword === "rollback" || keyword === "savepoint" || keyword === "release")) {
    return { error: "transaction control is not authorized", writes };
  }
  if (keyword === "pragma") {
    let nameAt = main + 1;
    if (tokens[nameAt + 1]?.text === ".") nameAt += 2;
    const name = sqliteName(tokens[nameAt]);
    const value = tokens[nameAt + 1];
    if (name !== null && relationalOwnedPragmas.has(name) && value !== undefined) {
      return { error: `PRAGMA ${name} is not authorized`, writes };
    }
  }

  if (keyword === "create") {
    const virtualAt = tokens.findIndex((token, index) => index > main && token.kind === "word" && token.text === "virtual");
    const usingAt = tokens.findIndex((token, index) => index > virtualAt && token.kind === "word" && token.text === "using");
    if (virtualAt >= 0 && usingAt >= 0) {
      const module = sqliteName(tokens[usingAt + 1]) ?? "";
      if (!relationalVirtualTableModules.has(module)) {
        return { error: `virtual table module ${module || "<unknown>"} is not authorized`, writes };
      }
    }
  }

  let declaredTableAt = -1;
  if (keyword === "create") {
    const tableAt = tokens.findIndex((token, index) => index > main && token.kind === "word" && token.text === "table");
    if (tableAt >= 0) {
      declaredTableAt = tableAt + 1;
      if (tokens[declaredTableAt]?.kind === "word" && tokens[declaredTableAt]?.text === "if") declaredTableAt += 3;
      if (tokens[declaredTableAt + 1]?.text === ".") declaredTableAt += 2;
    }
  }

  for (let at = 0; at + 1 < tokens.length; at++) {
    const name = tokenName(tokens[at]);
    if (name === null || tokens[at + 1]?.text !== "(") continue;
    if (at !== declaredTableAt && !declarations.has(at) && (relationalOptionalFunctions.has(name) || name.startsWith("geopoly_"))) {
      return { error: `SQLite function ${name} is not authorized because it is unavailable in the packaged runtime`, writes };
    }
  }

  for (const reference of relationalTableReferences(sql)) {
    if (reference.schema === "temp") {
      return { error: "TEMP schema objects are not authorized because native reads use a separate connection", writes };
    }
    if (relationalUnavailableReadTables.has(reference.table) && (reference.schema !== null || !ctes.has(reference.table))) {
      return { error: `SQLite table ${reference.table} is not authorized because it is unavailable in the packaged runtime`, writes };
    }
  }
  return { error: null, writes };
}

function ddlTargetsTempSchema(tokens: readonly SqlToken[], main: number, keyword: string): boolean {
  if (keyword !== "create" && keyword !== "drop" && keyword !== "alter") return false;
  let at = main + 1;
  if (keyword === "create" && (sqliteName(tokens[at]) === "temp" || sqliteName(tokens[at]) === "temporary")) return true;
  if (keyword === "create" && sqliteName(tokens[at]) === "unique") at += 1;
  if (keyword === "create" && sqliteName(tokens[at]) === "virtual") at += 1;
  if (!["table", "index", "trigger", "view"].includes(sqliteName(tokens[at]) ?? "")) return false;
  at += 1;
  if (sqliteName(tokens[at]) === "if") at += keyword === "create" ? 3 : 2;
  return sqliteName(tokens[at]) === "temp" && tokens[at + 1]?.text === ".";
}

export function relationalRuntimePolicy(
  action: number,
  first: string | null,
  second: string | null,
): number {
  if (action === sqliteConstants.SQLITE_ATTACH || action === sqliteConstants.SQLITE_DETACH) {
    return sqliteConstants.SQLITE_DENY;
  }
  if (relationalTempSchemaActions.has(action)) {
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

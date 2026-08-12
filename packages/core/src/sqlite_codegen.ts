// SQLite schema/query analysis and deterministic generated surfaces.
// The real SQLite parser is the authority: migrations run against an
// in-memory DatabaseSync and every declared statement is prepared there.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { constants as sqliteConstants, DatabaseSync, type StatementSync } from "node:sqlite";
import { inspectRelationalSql, relationalRuntimePolicy, relationalTableReferences, setRelationalAuthorizer } from "./sqlite_runtime_policy.ts";

export interface SqliteDiagnostic {
  readonly rule: `NS14${number}`;
  readonly message: string;
  readonly file: string;
  readonly line: number;
  readonly column: number;
  readonly fix?: string;
  readonly why?: string;
  readonly warning?: boolean;
}

export interface MigrationSource {
  readonly version: number;
  readonly name: string;
  readonly file: string;
  readonly sql: string;
  readonly hash: string;
}

export type SqlType = "INTEGER" | "REAL" | "TEXT" | "BLOB" | "ANY";

export interface QueryField {
  readonly name: string;
  readonly sqlType: SqlType;
  readonly nullable: boolean;
}

export interface DeclaredQuery {
  readonly name: string;
  readonly kind: "query" | "exec";
  readonly live: boolean;
  readonly file: string;
  readonly line: number;
  readonly sql: string;
  readonly params: readonly QueryField[];
  readonly columns: readonly QueryField[];
  readonly tables: readonly string[];
}

export interface SqliteAnalysis {
  readonly migrations: readonly MigrationSource[];
  readonly queries: readonly DeclaredQuery[];
  readonly diagnostics: readonly SqliteDiagnostic[];
  readonly warnings: readonly SqliteDiagnostic[];
  readonly schemaHash: string;
}

const migrationPattern = /^(\d{4})_([a-z0-9][a-z0-9_-]*)\.sql$/;
const queryHeader = /^\s*--\s*name:\s*([A-Za-z][A-Za-z0-9]*)(?:\s+(:exec))?(?:\s+(:live))?\s*$/;
const ident = /^[A-Za-z_][A-Za-z0-9_]*$/;

function diag(rule: `NS14${number}`, file: string, line: number, message: string, fix?: string, why?: string, warning = false): SqliteDiagnostic {
  return { rule, file, line, column: 1, message, ...(fix ? { fix } : {}), ...(why ? { why } : {}), ...(warning ? { warning: true } : {}) };
}

function sqliteMessage(error: unknown): string {
  return error instanceof Error ? error.message.replace(/^SQLITE_ERROR:\s*/, "") : String(error);
}

function scanParameters(sql: string): { names: string[]; unsupported: boolean } {
  const names: string[] = [];
  let unsupported = false;
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
    if (char === "?" || ((char === "$" || char === "@") && /[A-Za-z_]/.test(sql[at + 1] ?? ""))) {
      unsupported = true;
    }
    at += 1;
  }
  return { names, unsupported };
}

function tailHasStatement(sql: string, sourceSQL: string): boolean {
  const tail = sql.slice(sourceSQL.length);
  let at = 0;
  while (at < tail.length) {
    const char = tail[at]!;
    if (/\s/.test(char) || char === ";") { at += 1; continue; }
    if (char === "-" && tail[at + 1] === "-") {
      const end = tail.indexOf("\n", at + 2);
      if (end < 0) return false;
      at = end + 1;
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

function execMigrationSql(db: DatabaseSync, sql: string): void {
  let tail = sql;
  while (tailHasStatement(tail, "")) {
    const statement = db.prepare(tail);
    const inspection = inspectRelationalSql(statement.sourceSQL, true);
    if (inspection.error !== null) throw new Error(inspection.error);
    statement.run();
    tail = tail.slice(statement.sourceSQL.length);
  }
}

function sha256(parts: readonly string[]): string {
  const hash = crypto.createHash("sha256");
  for (const part of parts) hash.update(part).update("\0");
  return hash.digest("hex");
}

export function analyzeSqlite(srcDir: string): SqliteAnalysis {
  const diagnostics: SqliteDiagnostic[] = [];
  const warnings: SqliteDiagnostic[] = [];
  const schemaDir = path.join(srcDir, "schema");
  const migrations: MigrationSource[] = [];
  if (fs.existsSync(schemaDir)) {
    for (const name of fs.readdirSync(schemaDir).sort()) {
      const file = path.join(schemaDir, name);
      if (!fs.statSync(file).isFile()) continue;
      const match = migrationPattern.exec(name);
      if (!match) {
        if (name.endsWith(".sql")) diagnostics.push(diag("NS1401", file, 1, `Migration \`${name}\` is not named NNNN_description.sql.`, "Rename it to a four-digit, monotonically numbered migration such as 0001_init.sql.", "Migration filenames are the durable schema version; their order must be unambiguous."));
        continue;
      }
      const version = Number(match[1]);
      const sql = fs.readFileSync(file, "utf8").replaceAll("\r\n", "\n");
      migrations.push({ version, name: match[2], file, sql, hash: sha256([sql]) });
    }
  }
  migrations.sort((a, b) => a.version - b.version);
  for (let i = 0; i < migrations.length; i++) {
    const expected = i + 1;
    if (migrations[i]!.version !== expected) diagnostics.push(diag("NS1402", migrations[i]!.file, 1, `Migration version ${migrations[i]!.version} appears where ${expected} is required.`, `Number migrations contiguously; the next filename is ${String(expected).padStart(4, "0")}_name.sql.`, "The runtime advances PRAGMA user_version one append-only step at a time and never guesses across gaps."));
    if (!tailHasStatement(migrations[i]!.sql, "")) diagnostics.push(diag("NS1403", migrations[i]!.file, 1, "A migration is empty.", "Add the schema change, or remove the unshipped migration and create it again.", "Every published version is monotonic and may never be reused."));
    if (migrations[i]!.sql.includes("\0")) diagnostics.push(diag("NS1403", migrations[i]!.file, 1, "A migration contains a NUL byte.", "Remove the NUL byte and keep the migration as ordinary UTF-8 SQL.", "Both SQLite's C API and the generated runtime module require an unambiguous SQL boundary."));
    if (Buffer.byteLength(migrations[i]!.sql) > 1024 * 1024) diagnostics.push(diag("NS1403", migrations[i]!.file, 1, "A migration exceeds the 1 MiB runtime bound.", "Split the schema change across consecutive migrations.", "Migration input has its own explicit bound so startup memory is predictable."));
  }

  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys=ON;");
  if (diagnostics.length === 0) {
    db.exec("BEGIN IMMEDIATE;");
    let migrationAuthorizerInstalled = false;
    let activeMigration: MigrationSource | undefined;
    try {
      migrationAuthorizerInstalled = setRelationalAuthorizer(db, (action, first, second) => {
        if (action === sqliteConstants.SQLITE_TRANSACTION || action === sqliteConstants.SQLITE_SAVEPOINT) {
          return sqliteConstants.SQLITE_DENY;
        }
        return relationalRuntimePolicy(action, first, second);
      });
      for (const migration of migrations) {
        activeMigration = migration;
        try {
          execMigrationSql(db, migration.sql);
        } catch (error) {
          diagnostics.push(diag("NS1404", migration.file, 1, `SQLite rejected migration ${String(migration.version).padStart(4, "0")}: ${sqliteMessage(error)}.`, "Fix the SQL at this migration; native check applies the real SQLite dialect in memory.", "Shipping a migration that fails would prevent the app database from opening."));
          break;
        }
      }
      if (migrationAuthorizerInstalled) setRelationalAuthorizer(db, null);
      migrationAuthorizerInstalled = false;
      if (diagnostics.length === 0) {
        db.exec(`PRAGMA user_version=${migrations.at(-1)?.version ?? 0};`);
        db.exec("COMMIT;");
      }
      else db.exec("ROLLBACK;");
    } catch (error) {
      if (migrationAuthorizerInstalled) {
        try { setRelationalAuthorizer(db, null); } catch {}
      }
      try { db.exec("ROLLBACK;"); } catch {}
      if (diagnostics.length === 0) {
        const migration = activeMigration ?? migrations.at(-1);
        diagnostics.push(diag(
          "NS1404",
          migration?.file ?? schemaDir,
          1,
          `SQLite could not commit the migration chain: ${sqliteMessage(error)}.`,
          "Remove transaction-control SQL from migrations and fix the reported SQLite error.",
          "The runtime owns the one transaction that applies the complete pending migration chain.",
        ));
      }
    }
  }

  if (diagnostics.length === 0) {
    const tableRows = db.prepare("PRAGMA table_list;").all() as Array<Record<string, unknown>>;
    for (const row of tableRows) {
      const name = String(row.name ?? "");
      const schema = String(row.schema ?? "");
      const kind = String(row.type ?? "");
      if (schema !== "main" || name.startsWith("sqlite_") || kind !== "table") continue;
      if (Number(row.strict ?? 0) !== 1) diagnostics.push(diag("NS1405", migrations.at(-1)?.file ?? schemaDir, 1, `Table \`${name}\` is not STRICT.`, `Declare it with \`CREATE TABLE ${name}(...) STRICT\` in its introducing migration.`, "Generated parameter and result types are honest only when SQLite enforces the declared storage classes."));
    }
  }

  const queriesFile = path.join(srcDir, "queries.sql");
  const queries: DeclaredQuery[] = [];
  if (fs.existsSync(queriesFile) && diagnostics.length === 0) {
    let statementWrites = false;
    let statementControlsTransaction = false;
    const queryAuthorizerInstalled = setRelationalAuthorizer(db, (action, first, second) => {
      if (action === sqliteConstants.SQLITE_INSERT || action === sqliteConstants.SQLITE_UPDATE || action === sqliteConstants.SQLITE_DELETE) statementWrites = true;
      if (action === sqliteConstants.SQLITE_TRANSACTION || action === sqliteConstants.SQLITE_SAVEPOINT) statementControlsTransaction = true;
      return relationalRuntimePolicy(action, first, second);
    });
    const source = fs.readFileSync(queriesFile, "utf8").replaceAll("\r\n", "\n");
    const lines = source.split("\n");
    const headers: Array<{ name: string; exec: boolean; live: boolean; line: number; headerStart: number; start: number }> = [];
    let offset = 0;
    for (let i = 0; i < lines.length; i++) {
      const match = queryHeader.exec(lines[i]!);
      if (match) headers.push({ name: match[1]!, exec: match[2] === ":exec", live: match[3] === ":live", line: i + 1, headerStart: offset, start: offset + lines[i]!.length + 1 });
      offset += lines[i]!.length + 1;
    }
    if (source.trim().length > 0 && headers.length === 0) diagnostics.push(diag("NS1410", queriesFile, 1, "queries.sql contains no named query blocks.", "Start each statement with `-- name: queryName`, optionally followed by `:exec` or `:live`.", "Stable names are the generated API and the live-query replay identity."));
    if (headers.length > 0 && tailHasStatement(source.slice(0, headers[0]!.headerStart), "")) diagnostics.push(diag("NS1410", queriesFile, 1, "queries.sql contains SQL before its first named query block.", "Put a `-- name: queryName` header immediately before every statement.", "Unnamed SQL has no generated constructor and would otherwise escape build-time validation."));
    const names = new Set<string>();
    const generatedNames = new Map<string, string>();
    const reservesTransactionBuilder = headers.some((header) => header.exec);
    for (let i = 0; i < headers.length; i++) {
      const header = headers[i]!;
      const end = i + 1 < headers.length ? headers[i + 1]!.headerStart : source.length;
      const sql = source.slice(header.start, end).trim();
      if (names.has(header.name)) {
        diagnostics.push(diag("NS1411", queriesFile, header.line, `Declared query name \`${header.name}\` is duplicated.`, "Give every block a unique camelCase name.", "Generated members and journal identities must be one-to-one."));
        continue;
      }
      names.add(header.name);
      const generatedName = `q${pascal(header.name)}`;
      const priorName = generatedNames.get(generatedName);
      if (priorName !== undefined || (reservesTransactionBuilder && generatedName === "qTx")) {
        const conflict = priorName === undefined ? "the generated transaction builder" : `declared query \`${priorName}\``;
        diagnostics.push(diag("NS1411", queriesFile, header.line, `Declared query \`${header.name}\` generates \`${generatedName}\`, which collides with ${conflict}.`, "Rename the query so its generated q<Name> member is unique after the first letter is capitalized.", "Generated constructors, row types, decoders, and replay identities must stay one-to-one."));
        continue;
      }
      generatedNames.set(generatedName, header.name);
      if (sql.length === 0) {
        diagnostics.push(diag("NS1412", queriesFile, header.line, `Declared query \`${header.name}\` has no SQL.`, "Put exactly one SQLite statement below its name header."));
        continue;
      }
      if (header.live && header.exec) {
        diagnostics.push(diag("NS1413", queriesFile, header.line, `Declared query \`${header.name}\` cannot be both :exec and :live.`, "Remove :live; subscriptions are read queries."));
        continue;
      }
      try {
        statementWrites = false;
        statementControlsTransaction = false;
        const inspection = inspectRelationalSql(sql, true);
        if (inspection.error !== null) throw new Error(inspection.error);
        const statement = db.prepare(sql);
        const writes = queryAuthorizerInstalled ? statementWrites : inspection.writes;
        const controlsTransaction = statementControlsTransaction;
        if (tailHasStatement(sql, statement.sourceSQL)) throw new Error("declared query contains more than one statement");
        const columns = statement.columns();
        if (controlsTransaction) throw new Error("transaction control is engine-owned and cannot be declared");
        if (header.exec && !writes) throw new Error(":exec statement is read-only");
        if (!header.exec && writes) throw new Error("writable statement must be declared with :exec and cannot return rows");
        if (header.exec && columns.length > 0) throw new Error(":exec statement returns rows");
        if (!header.exec && columns.length === 0) throw new Error("query returns no columns; declare writes with :exec");
        const columnNames = new Set<string>();
        for (const column of columns) {
          if (columnNames.has(column.name)) throw new Error(`result column \`${column.name}\` is duplicated; give every selected column a unique AS alias`);
          columnNames.add(column.name);
        }
        const parameterScan = scanParameters(sql);
        if (parameterScan.unsupported) throw new Error("declared queries use :named parameters, not positional, $named, or @named placeholders");
        const params = inferParams(db, sql, parameterScan.names);
        const explain = db.prepare(`EXPLAIN ${sql}`);
        if (params.length === 0) explain.all();
        else explain.all(dummyBindings(params.map((param) => param.name)));
        const result = columns.map((column, index) => inferColumn(db, column, sql, index, columns.length));
        const tables = dependencyTables(db, sql, params.map((p) => p.name));
        if (header.live && tables.length === 0) diagnostics.push(diag("NS1421", queriesFile, header.line, `Live query \`${header.name}\` has no table dependency and cannot refresh.`, "Remove :live for a one-shot query, or select from a schema table.", "A live subscription must have at least one generated table dependency so committed writes can invalidate it."));
        for (const field of [...params, ...result]) {
          if (field.sqlType === "INTEGER" && /(^id$|_id$|Id$)/.test(field.name)) {
            warnings.push(diag("NS1422", queriesFile, header.line, `INTEGER identifier \`${field.name}\` in \`${header.name}\` maps to an exact TypeScript number.`, "Keep identifier values within -(2^53-1)..(2^53-1); generated page decoders reject wider i64 values instead of rounding them.", "Choosing number keeps the app-core API uniform; an explicit bigint tier can be added later without silently changing existing generated contracts.", true));
          }
        }
        queries.push({ name: header.name, kind: header.exec ? "exec" : "query", live: header.live, file: queriesFile, line: header.line, sql, params, columns: result, tables });
      } catch (error) {
        diagnostics.push(diag("NS1414", queriesFile, header.line + 1, `SQLite rejected declared query \`${header.name}\`: ${sqliteMessage(error)}.`, "Fix the table, column, parameter, or statement shape named by SQLite.", "Declared queries are prepared against the schema produced by the complete migration chain."));
      }
    }
  }
  db.close();
  return { migrations, queries, diagnostics, warnings, schemaHash: sha256(migrations.flatMap((m) => [String(m.version), m.name, m.hash])) };
}

function normalizeType(type: string | null): SqlType {
  const upper = (type ?? "").toUpperCase();
  if (upper.includes("INT")) return "INTEGER";
  if (upper.includes("REAL") || upper.includes("FLOA") || upper.includes("DOUB")) return "REAL";
  if (upper.includes("TEXT") || upper.includes("CHAR") || upper.includes("CLOB")) return "TEXT";
  if (upper.includes("BLOB")) return "BLOB";
  return "ANY";
}

function tableInfo(db: DatabaseSync, table: string): Array<Record<string, unknown>> {
  const quoted = table.replaceAll("'", "''");
  return db.prepare(`PRAGMA table_xinfo('${quoted}');`).all() as Array<Record<string, unknown>>;
}

function inferColumn(db: DatabaseSync, column: ReturnType<StatementSync["columns"]>[number], sql: string, index: number, columnCount: number): QueryField {
  let sqlType = normalizeType(column.type);
  let nullable = true;
  if (column.table && column.column) {
    const row = tableInfo(db, column.table).find((entry) => String(entry.name) === column.column);
    if (row) nullable = Number(row.notnull ?? 0) !== 1 && Number(row.pk ?? 0) === 0;
  }
  if (isDirectCountColumn(sql, index, columnCount)) {
    nullable = false;
    sqlType = "INTEGER";
  }
  // Statement.columns() reports the origin and declared type of the first
  // SELECT arm only. Later compound arms may legally contribute NULL or any
  // other SQLite storage class, so that metadata cannot narrow the row wire.
  if (hasTopLevelCompoundSelect(sql)) {
    nullable = true;
    sqlType = "ANY";
  }
  // SQLite's column-origin metadata names the underlying NOT NULL column,
  // but an outer join may synthesize NULL for it. Conservatively widen all
  // result columns in an outer-join statement; generated decoding must never
  // reject a legal row merely to claim a narrower type.
  if (/\b(?:left|right|full)(?:\s+outer)?\s+join\b/i.test(sql)) nullable = true;
  // SQLite retains the origin metadata of a NOT NULL table column through a
  // scalar subquery, but an empty scalar subquery produces NULL. The origin
  // still determines the storage class; only its nullability must widen.
  const expressions = topLevelSelectExpressions(sql);
  if (expressions.length === columnCount && containsSubquery(expressions[index] ?? "")) nullable = true;
  return { name: column.name, sqlType, nullable };
}

function containsSubquery(expression: string): boolean {
  let quote = "";
  for (let at = 0; at < expression.length; at++) {
    const char = expression[at]!;
    if (quote) {
      if (char === quote && expression[at + 1] === quote) { at += 1; continue; }
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === "\"" || char === "`") { quote = char; continue; }
    if (char === "[") {
      const end = expression.indexOf("]", at + 1);
      at = end < 0 ? expression.length : end;
      continue;
    }
    if (char !== "(") continue;
    let next = at + 1;
    while (next < expression.length) {
      if (/\s/.test(expression[next]!)) { next += 1; continue; }
      if (expression[next] === "-" && expression[next + 1] === "-") {
        const end = expression.indexOf("\n", next + 2);
        next = end < 0 ? expression.length : end + 1;
        continue;
      }
      if (expression[next] === "/" && expression[next + 1] === "*") {
        const end = expression.indexOf("*/", next + 2);
        next = end < 0 ? expression.length : end + 2;
        continue;
      }
      break;
    }
    if (/^(?:select|with)\b/i.test(expression.slice(next))) return true;
  }
  return false;
}

function hasTopLevelCompoundSelect(sql: string): boolean {
  let depth = 0;
  let quote = "";
  for (let at = 0; at < sql.length; at++) {
    const char = sql[at]!;
    if (quote) {
      if (char === quote && sql[at + 1] === quote) { at += 1; continue; }
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === '"' || char === "`") { quote = char; continue; }
    if (char === "[") {
      const end = sql.indexOf("]", at + 1);
      at = end < 0 ? sql.length : end;
      continue;
    }
    if (char === "-" && sql[at + 1] === "-") {
      const end = sql.indexOf("\n", at + 2);
      at = end < 0 ? sql.length : end;
      continue;
    }
    if (char === "/" && sql[at + 1] === "*") {
      const end = sql.indexOf("*/", at + 2);
      at = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (char === "(") { depth += 1; continue; }
    if (char === ")") { depth -= 1; continue; }
    if (depth !== 0 || /[A-Za-z0-9_]/.test(sql[at - 1] ?? "")) continue;
    if (/^(?:union|intersect|except)\b/i.test(sql.slice(at))) return true;
  }
  return false;
}

function isDirectCountColumn(sql: string, index: number, columnCount: number): boolean {
  const expressions = topLevelSelectExpressions(sql);
  if (expressions.length !== columnCount) return false;
  const expression = expressions[index]?.trim().replace(/^distinct\s+/i, "") ?? "";
  const count = /^count\s*\(/i.exec(expression);
  if (!count) return false;
  let depth = 0;
  let quote = "";
  for (let at = expression.indexOf("(", count.index); at < expression.length; at++) {
    const char = expression[at]!;
    if (quote) {
      if (char === quote && expression[at + 1] === quote) { at += 1; continue; }
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === '"' || char === "`") { quote = char; continue; }
    if (char === "(") depth += 1;
    else if (char === ")" && --depth === 0) {
      const suffix = expression.slice(at + 1).trim();
      return suffix.length === 0 || /^(?:as\s+)?(?:[A-Za-z_][A-Za-z0-9_]*|"(?:[^"]|"")+"|`(?:[^`]|``)+`|\[(?:[^\]]|\]\])+\])$/i.test(suffix);
    }
  }
  return false;
}

function topLevelSelectExpressions(sql: string): string[] {
  let depth = 0;
  let quote = "";
  let selectEnd = -1;
  let expressionStart = -1;
  const expressions: string[] = [];
  for (let at = 0; at < sql.length; at++) {
    const char = sql[at]!;
    if (quote) {
      if (char === quote && sql[at + 1] === quote) { at += 1; continue; }
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === '"' || char === "`") { quote = char; continue; }
    if (char === "[") {
      const end = sql.indexOf("]", at + 1);
      at = end < 0 ? sql.length : end;
      continue;
    }
    if (char === "-" && sql[at + 1] === "-") {
      const end = sql.indexOf("\n", at + 2);
      at = end < 0 ? sql.length : end;
      continue;
    }
    if (char === "/" && sql[at + 1] === "*") {
      const end = sql.indexOf("*/", at + 2);
      at = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (char === "(") { depth += 1; continue; }
    if (char === ")") { depth -= 1; continue; }
    if (depth !== 0) continue;
    const wordBoundary = !/[A-Za-z0-9_]/.test(sql[at - 1] ?? "");
    if (selectEnd < 0 && wordBoundary && /^select\b/i.test(sql.slice(at))) {
      selectEnd = at + 6;
      expressionStart = selectEnd;
      at += 5;
      continue;
    }
    if (selectEnd < 0) continue;
    if (char === ",") {
      expressions.push(sql.slice(expressionStart, at));
      expressionStart = at + 1;
      continue;
    }
    if (wordBoundary && /^(?:from|union|intersect|except)\b/i.test(sql.slice(at))) {
      expressions.push(sql.slice(expressionStart, at));
      return expressions;
    }
  }
  if (expressionStart >= 0) expressions.push(sql.slice(expressionStart));
  return expressions;
}

function inferParams(db: DatabaseSync, sql: string, names: readonly string[]): QueryField[] {
  const tables = new Map<string, Array<Record<string, unknown>>>();
  const mainTables = canonicalMainTables(db);
  for (const reference of relationalTableReferences(sql)) {
    if (reference.schema !== null && reference.schema !== "main") continue;
    const table = mainTables.get(reference.table);
    if (table !== undefined) tables.set(table, tableInfo(db, table));
  }
  const allColumns = [...tables.values()].flat();
  return names.map((name) => {
    let type: SqlType = "ANY";
    let nullable = true;
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const around = new RegExp(`(?:(?:[A-Za-z_][A-Za-z0-9_]*\\.)?([A-Za-z_][A-Za-z0-9_]*)\\s*(?:=|<>|!=|<=|>=|<|>|MATCH|LIKE|GLOB|IS)\\s*:${escaped}|:${escaped}\\s*(?:=|<>|!=|<=|>=|<|>|MATCH|LIKE|GLOB|IS)\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\.)?([A-Za-z_][A-Za-z0-9_]*))`, "i").exec(sql);
    let columnName = around?.[1] ?? around?.[2];
    if (!columnName) {
      const insert = /\binsert\s+into\s+(?:main\.)?["`\[]?([A-Za-z_][A-Za-z0-9_]*)[^\(]*\(([^)]*)\)\s*values\s*\(([^)]*)\)/i.exec(sql);
      if (insert) {
        const columns = insert[2]!.split(",").map((value) => value.trim().replace(/^["`\[]|["`\]]$/g, ""));
        const values = insert[3]!.split(",").map((value) => value.trim());
        const valueIndex = values.findIndex((value) => value === `:${name}`);
        if (valueIndex >= 0) columnName = columns[valueIndex];
      }
    }
    if (columnName) {
      const matches = allColumns.filter((entry) => String(entry.name) === columnName);
      const inferredTypes = new Set(matches.map((entry) => normalizeType(String(entry.type ?? ""))));
      if (matches.length > 0 && inferredTypes.size === 1) {
        type = inferredTypes.values().next().value ?? "ANY";
        nullable = matches.some((row) => Number(row.notnull ?? 0) !== 1 && Number(row.pk ?? 0) === 0);
      }
    }
    return { name, sqlType: type, nullable };
  });
}

function dummyBindings(names: readonly string[]): Record<string, null> {
  return Object.fromEntries(names.map((name) => [name, null]));
}

function dependencyTables(db: DatabaseSync, sql: string, params: readonly string[]): string[] {
  const found = new Set<string>();
  for (const reference of relationalTableReferences(sql)) {
    if (reference.schema === null || reference.schema === "main") found.add(reference.table);
  }
  try {
    const rows = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(dummyBindings(params)) as Array<Record<string, unknown>>;
    for (const row of rows) {
      const detail = String(row.detail ?? "");
      for (const match of detail.matchAll(/\b(?:SCAN|SEARCH)\s+(?:TABLE\s+)?([A-Za-z_][A-Za-z0-9_]*)/gi)) found.add(match[1]!);
    }
  } catch {}
  const tableRows = (db.prepare("PRAGMA table_list;").all() as Array<Record<string, unknown>>)
    .filter((row) => String(row.schema) === "main");
  const realTables = new Map(tableRows.map((row) => [String(row.name).toLowerCase(), String(row.name)]));
  const dependencies = new Set(
    [...found]
      .map((name) => realTables.get(name.toLowerCase()))
      .filter((name): name is string => name !== undefined && !name.toLowerCase().startsWith("sqlite_")),
  );
  // sqlite3_update_hook names FTS shadow tables, not the virtual table the
  // SELECT spells. Carry those generated dependencies too so FTS live
  // queries invalidate on every committed index mutation.
  for (const name of [...dependencies]) {
    const virtual = tableRows.find((row) => String(row.name) === name && String(row.type) === "virtual");
    if (!virtual) continue;
    for (const row of tableRows) {
      const shadow = String(row.name);
      if (String(row.type) === "shadow" && shadow.startsWith(`${name}_`)) dependencies.add(shadow);
    }
  }
  return [...dependencies].sort();
}

function canonicalMainTables(db: DatabaseSync): Map<string, string> {
  const rows = db.prepare("PRAGMA table_list;").all() as Array<Record<string, unknown>>;
  return new Map(
    rows
      .filter((row) => String(row.schema) === "main")
      .map((row) => [String(row.name).toLowerCase(), String(row.name)]),
  );
}

function tsType(field: QueryField, parameter = false): string {
  // Dynamic core text is UTF-8 bytes. Generated TEXT parameters wrap those
  // bytes with dbText() at the wire edge; decoded TEXT rows stay bytes so a
  // subscribed row can live honestly in Model.
  const base = field.sqlType === "INTEGER" || field.sqlType === "REAL" ? "number" : field.sqlType === "TEXT" || field.sqlType === "BLOB" ? "Uint8Array" : parameter ? "DbValue" : "DbDecodedValue";
  return field.nullable ? `${base} | null` : base;
}

function paramExpr(field: QueryField): string {
  const access = `params.${field.name}`;
  if (field.sqlType !== "TEXT") return access;
  return field.nullable ? `${access} === null ? null : dbText(${access})` : `dbText(${access})`;
}

function pascal(name: string): string {
  return name[0]!.toUpperCase() + name.slice(1);
}

function js(value: string): string {
  return JSON.stringify(value);
}

export function generatedFragments(analysis: SqliteAnalysis): { types: string; cmds: string; subs: string } {
  const typeLines: string[] = [];
  const cmdLines: string[] = [];
  const subLines: string[] = [];
  const rowQueries = analysis.queries.filter((query) => query.kind === "query");
  if (rowQueries.length > 0) {
    typeLines.push(`export type DbDecodedValue = null | number | Uint8Array;`);
    typeLines.push(`function nsgDbPageNeed(bytes: Uint8Array, at: number, count: number): void { if (at < 0 || count < 0 || at + count > bytes.length) throw new Error("a relational page ended mid-value"); }`);
    typeLines.push(`function nsgDbPageU32(bytes: Uint8Array, at: number): number { nsgDbPageNeed(bytes, at, 4); return bytes[at]! + bytes[at + 1]! * 256 + bytes[at + 2]! * 65536 + bytes[at + 3]! * 16777216; }`);
    typeLines.push(`function nsgDbPageI64(bytes: Uint8Array, at: number): number { nsgDbPageNeed(bytes, at, 8); const lo = nsgDbPageU32(bytes, at); const hiUnsigned = nsgDbPageU32(bytes, at + 4); const hi = hiUnsigned >= 2147483648 ? hiUnsigned - 4294967296 : hiUnsigned; const value = hi * 4294967296 + lo; if (!Number.isSafeInteger(value)) throw new Error("a SQLite INTEGER exceeds TypeScript's exact number range"); return Math.trunc(value); }`);
    typeLines.push(`function nsgDbPageF64(bytes: Uint8Array, at: number): number { nsgDbPageNeed(bytes, at, 8); const value = new DataView(bytes.buffer, bytes.byteOffset + at, 8).getFloat64(0, true); if (!Number.isFinite(value)) throw new Error("a relational page carries a non-finite REAL"); return value; }`);
  }
  for (const query of analysis.queries) {
    const stem = pascal(query.name);
    typeLines.push(`export interface ${stem}Params {`);
    for (const param of query.params) typeLines.push(`  readonly ${param.name}: ${tsType(param, true)};`);
    typeLines.push("}");
    if (query.kind === "query") {
      typeLines.push(`export interface ${stem}Row {`);
      for (const column of query.columns) typeLines.push(`  readonly ${ident.test(column.name) ? column.name : js(column.name)}: ${tsType(column)};`);
      typeLines.push("}");
      typeLines.push(generatePageDecoder(query, stem));
    }
  }
  const execNames = analysis.queries.filter((q) => q.kind === "exec");
  for (const query of analysis.queries) {
    const stem = pascal(query.name);
    const values = query.params.map(paramExpr).join(", ");
    if (query.kind === "query") {
      cmdLines.push(`q${stem}<M extends Msgish>(params: ${stem}Params, route: TypedRowsRoute<${stem}Row, M>): Cmd<M> { return Cmd.db.query(${js(query.sql)}, [${values}], route); },`);
    } else {
      cmdLines.push(`q${stem}(params: ${stem}Params): TypedDbStatement { return { sql: ${js(query.sql)}, params: [${values}], __typedDbStatement: true }; },`);
    }
  }
  if (execNames.length > 0) cmdLines.push("qTx<M extends Msgish>(statements: ReadonlyArray<TypedDbStatement>, route: WriteRoute<M>): Cmd<M> { const raw: DbStatement[] = []; for (const statement of statements) raw.push([statement.sql, statement.params]); return Cmd.db.exec(raw, route); },");
  const live = analysis.queries.filter((q) => q.live);
  for (const query of live) {
    const stem = pascal(query.name);
    const values = query.params.map(paramExpr).join(", ");
    subLines.push(`q${stem}<M extends Msgish>(key: string, params: ${stem}Params, route: TypedRowsRoute<${stem}Row, M>): Sub<M> { return { op: "db_live", key, pageKind: route.page, doneKind: route.done, errKind: route.err, sql: ${js(query.sql)}, params: [${values}], tables: [${query.tables.map(js).join(", ")}] }; },`);
  }
  return { types: typeLines.join("\n"), cmds: cmdLines.join("\n"), subs: subLines.join("\n") };
}

function generatePageDecoder(query: DeclaredQuery, stem: string): string {
  const out: string[] = [`export function decode${stem}Page(bytes: Uint8Array): ReadonlyArray<${stem}Row> {`, "  let at = 0;", "  const columnCount = nsgDbPageU32(bytes, at); at += 4;", "  const rowCount = nsgDbPageU32(bytes, at); at += 4;", `  if (columnCount !== ${query.columns.length} || rowCount > 256) throw new Error("a relational page does not match declared query ${query.name}");`];
  for (const column of query.columns) {
    const nameBytes = [...Buffer.from(column.name, "utf8")];
    out.push(`  { const length = nsgDbPageU32(bytes, at); at += 4; if (length !== ${nameBytes.length}) throw new Error("a relational page column does not match declared query ${query.name}"); nsgDbPageNeed(bytes, at, length);`);
    nameBytes.forEach((byte, index) => out.push(`    if (bytes[at + ${index}] !== ${byte}) throw new Error("a relational page column does not match declared query ${query.name}");`));
    out.push("    at += length; }");
  }
  out.push(`  const rows: ${stem}Row[] = [];`, "  for (let rowIndex = 0; rowIndex < rowCount; rowIndex++) {");
  query.columns.forEach((column, index) => {
    const local = `field${index}`;
    const tag = `tag${index}`;
    out.push(`    let ${local}: ${tsType(column)};`, "    nsgDbPageNeed(bytes, at, 1);", `    const ${tag} = bytes[at]!; at += 1;`);
    const nullArm = column.nullable ? `${local} = null;` : `throw new Error("a non-null declared column arrived as NULL");`;
    const numberArms = column.sqlType === "REAL"
      ? `else if (tag === 1) { ${local} = nsgDbPageI64(bytes, at); at += 8; } else if (tag === 2) { ${local} = nsgDbPageF64(bytes, at); at += 8; }`
      : `else if (tag === 1) { const integer = nsgDbPageI64(bytes, at); if (!(integer >= -9007199254740991 && integer <= 9007199254740991)) throw new Error("a SQLite INTEGER exceeds TypeScript's exact number range"); ${local} = Math.trunc(integer); at += 8; }`;
    if (column.sqlType === "INTEGER" || column.sqlType === "REAL") {
      out.push(`    if (${tag} === 0) { ${nullArm} } ${numberArms.replaceAll("tag", tag)} else throw new Error("a relational value does not match its declared numeric type");`);
    } else if (column.sqlType === "TEXT" || column.sqlType === "BLOB") {
      const expected = column.sqlType === "TEXT" ? 3 : 4;
      out.push(`    if (${tag} === 0) { ${nullArm} } else if (${tag} === ${expected}) { const length = nsgDbPageU32(bytes, at); at += 4; nsgDbPageNeed(bytes, at, length); ${local} = bytes.slice(at, at + length); at += length; } else throw new Error("a relational value does not match its declared byte type");`);
    } else {
      out.push(`    if (${tag} === 0) { ${local} = null; } else if (${tag} === 1) { ${local} = nsgDbPageI64(bytes, at); at += 8; } else if (${tag} === 2) { ${local} = nsgDbPageF64(bytes, at); at += 8; } else if (${tag} === 3 || ${tag} === 4) { const length = nsgDbPageU32(bytes, at); at += 4; nsgDbPageNeed(bytes, at, length); ${local} = bytes.slice(at, at + length); at += length; } else throw new Error("a relational value carries an unknown tag");`);
    }
  });
  out.push(`    rows.push({ ${query.columns.map((column, index) => `${ident.test(column.name) ? column.name : js(column.name)}: field${index}`).join(", ")} });`, "  }", "  if (at !== bytes.length) throw new Error(\"a relational page carries trailing bytes\");", "  return rows;", "}");
  return out.join("\n");
}

export function generateCoreSurface(base: string, analysis: SqliteAnalysis): string {
  const fragments = generatedFragments(analysis);
  return base
    .replace("// @native-sqlite-generated-types", fragments.types)
    .replace("// @native-sqlite-generated-cmds", fragments.cmds)
    .replace("// @native-sqlite-generated-subs", fragments.subs);
}

function zigMultiline(sql: string): string {
  return sql.split("\n").map((line) => `        \\\\${line}`).join("\n");
}

export function generateMigrationsZig(analysis: SqliteAnalysis): string {
  const out = ["// Generated by native SQLite schema analysis; do not edit.", "const relational = @import(\"native_sdk\").relational_store;", ""];
  for (const migration of analysis.migrations) {
    out.push(`const migration_${migration.version}: []const u8 =`, zigMultiline(migration.sql), ";", "");
  }
  out.push("pub const migrations = [_]relational.Migration{");
  for (const migration of analysis.migrations) out.push(`    .{ .version = ${migration.version}, .name = ${js(migration.name)}, .sql = migration_${migration.version} },`);
  out.push("};", "");
  return out.join("\n");
}

export function formatSqliteDiagnostic(d: SqliteDiagnostic): string {
  let out = `${d.file}:${d.line}:${d.column} ${d.warning ? "warning[" : ""}${d.rule}${d.warning ? "]" : ""} ${d.message}`;
  if (d.fix) out += `\n  fix: ${d.fix}`;
  if (d.why) out += `\n  why: ${d.why}`;
  return out;
}

export interface MigrationState { readonly version: number; readonly hashes: readonly string[]; readonly schema_hash: string }

function validMigrationState(value: unknown): value is MigrationState {
  if (value === null || typeof value !== "object") return false;
  const state = value as Partial<MigrationState>;
  return Number.isSafeInteger(state.version)
    && (state.version ?? -1) >= 0
    && Array.isArray(state.hashes)
    && state.hashes.length === state.version
    && state.hashes.every((hash) => typeof hash === "string" && hash.length > 0)
    && typeof state.schema_hash === "string"
    && state.schema_hash.length > 0;
}

function damagedMigrationState(stateFile: string): SqliteDiagnostic {
  return diag(
    "NS1408",
    stateFile,
    1,
    "The migration lock is unreadable or malformed.",
    "Restore src/schema/migrations.lock.json from version control; do not regenerate it over an unknown history.",
    "The lock is the append-only authority for migrations already applied to installed databases, so damaged state must never be silently re-baselined.",
  );
}

export function checkMigrationState(analysis: SqliteAnalysis, stateFile: string): SqliteDiagnostic[] {
  // Never bless a chain that the real-SQLite/schema pass rejected. The CLI
  // still prints those primary diagnostics; the append-only lock remains at
  // the last valid chain so fixing the SQL cannot accidentally establish a
  // broken history as the new baseline.
  if (analysis.diagnostics.length > 0) return [];
  let prior: MigrationState | null = null;
  let stateSource: string | null = null;
  try {
    stateSource = fs.readFileSync(stateFile, "utf8");
  } catch (error) {
    if (!(error !== null && typeof error === "object" && "code" in error && error.code === "ENOENT")) {
      return [damagedMigrationState(stateFile)];
    }
  }
  if (stateSource !== null) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(stateSource);
    } catch {
      return [damagedMigrationState(stateFile)];
    }
    if (!validMigrationState(parsed)) return [damagedMigrationState(stateFile)];
    prior = parsed;
  }
  const errors: SqliteDiagnostic[] = [];
  if (prior) {
    for (let i = 0; i < prior.hashes.length; i++) {
      if (analysis.migrations[i]?.hash !== prior.hashes[i]) errors.push(diag("NS1406", analysis.migrations[i]?.file ?? path.join(path.dirname(stateFile), "schema"), 1, `Published migration ${String(i + 1).padStart(4, "0")} changed after it was accepted.`, "Restore the migration and add a new numbered migration for the change.", "Installed databases may already have applied every prior version; migration history is append-only."));
    }
    if (analysis.migrations.length < prior.version) errors.push(diag("NS1407", path.dirname(stateFile), 1, `The migration chain moved backward from ${prior.version} to ${analysis.migrations.length}.`, "Restore the removed migrations; version numbers are never reused."));
  }
  if (errors.length === 0) {
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    const next: MigrationState = { version: analysis.migrations.length, hashes: analysis.migrations.map((m) => m.hash), schema_hash: analysis.schemaHash };
    const temp = `${stateFile}.${process.pid}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify(next, null, 2)}\n`);
    fs.renameSync(temp, stateFile);
  }
  return errors;
}

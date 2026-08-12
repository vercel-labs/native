import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { analyzeSqlite, checkMigrationState, generateCoreSurface, generateMigrationsZig } from "../src/sqlite_codegen.ts";
import { inspectRelationalSql } from "../src/sqlite_runtime_policy.ts";

function fixture(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  fs.mkdirSync(path.join(root, "schema"));
  fs.writeFileSync(path.join(root, "schema", "0001_init.sql"), `
CREATE TABLE folder(id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
CREATE TABLE note(id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL REFERENCES folder(id), title TEXT NOT NULL) STRICT;
`);
  fs.writeFileSync(path.join(root, "queries.sql"), `-- name: notesInFolder :live
SELECT n.id, n.title FROM note n WHERE n.folder_id = :folder ORDER BY n.id;

-- name: moveNote :exec
UPDATE note SET folder_id = :to WHERE id = :id;
`);
  return root;
}

test("real SQLite validates migrations and emits typed query/live constructors", () => {
  const root = fixture();
  try {
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.queries.length, 2);
    assert.deepEqual(result.queries[0]!.tables, ["note"]);
    assert.equal(result.queries[0]!.columns[0]!.sqlType, "INTEGER");
    const source = generateCoreSurface("// @native-sqlite-generated-types\nconst Cmd = {\n// @native-sqlite-generated-cmds\n};\nconst Sub = {\n// @native-sqlite-generated-subs\n};", result);
    assert.match(source, /interface NotesInFolderRow/);
    assert.match(source, /qNotesInFolder<M extends Msgish>/);
    assert.match(source, /op: "db_live"/);
    assert.match(source, /qMoveNote\(params: MoveNoteParams\): TypedDbStatement/);
    assert.match(source, /qTx<M extends Msgish>/);
    assert.match(generateMigrationsZig(result), /version = 1/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("migration history is append-only and SQL errors point into authored files", () => {
  const root = fixture();
  try {
    const first = analyzeSqlite(root);
    const state = path.join(root, "schema", "migrations.lock.json");
    assert.deepEqual(checkMigrationState(first, state), []);
    fs.appendFileSync(path.join(root, "schema", "0001_init.sql"), "\n-- edited\n");
    const changed = analyzeSqlite(root);
    assert.equal(checkMigrationState(changed, state)[0]?.rule, "NS1406");
    fs.writeFileSync(path.join(root, "queries.sql"), "-- name: broken\nSELECT missing FROM note;\n");
    const broken = analyzeSqlite(root);
    assert.equal(broken.diagnostics[0]?.rule, "NS1414");
    assert.match(broken.diagnostics[0]?.file ?? "", /queries\.sql$/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a damaged migration lock is rejected without replacing its history", () => {
  const root = fixture();
  try {
    const result = analyzeSqlite(root);
    const state = path.join(root, "schema", "migrations.lock.json");
    fs.writeFileSync(state, "{ definitely not json\n");
    assert.equal(checkMigrationState(result, state)[0]?.rule, "NS1408");
    assert.equal(fs.readFileSync(state, "utf8"), "{ definitely not json\n");

    fs.writeFileSync(state, JSON.stringify({ version: 1, hashes: [], schema_hash: "hash" }));
    assert.equal(checkMigrationState(result, state)[0]?.rule, "NS1408");
    assert.deepEqual(JSON.parse(fs.readFileSync(state, "utf8")), { version: 1, hashes: [], schema_hash: "hash" });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("STRICT tables and contiguous migration versions are hard gates", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(path.join(root, "schema", "0002_gap.sql"), "CREATE TABLE loose(id INTEGER);\n");
    const gap = analyzeSqlite(root);
    assert.equal(gap.diagnostics[0]?.rule, "NS1402");
    fs.renameSync(path.join(root, "schema", "0002_gap.sql"), path.join(root, "schema", "0001_init.sql"));
    const loose = analyzeSqlite(root);
    assert.equal(loose.diagnostics[0]?.rule, "NS1405");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("declared queries are one statement with fully named parameters", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: positional\nSELECT title FROM note WHERE id = ?;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1414");

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: stacked\nSELECT title FROM note; SELECT name FROM folder;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1414");

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: colonLiteral\nSELECT ':not_a_parameter' AS literal FROM note WHERE id = :id /* :also_ignored */;\n",
    );
    const valid = analyzeSqlite(root);
    assert.deepEqual(valid.diagnostics, []);
    assert.deepEqual(valid.queries[0]?.params.map((param) => param.name), ["id"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("outer joins widen generated result nullability", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: foldersWithNotes\nSELECT n.title FROM folder AS f LEFT JOIN note AS n ON n.folder_id = f.id;\n",
    );
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.queries[0]?.columns[0]?.nullable, true);
    assert.match(generateCoreSurface("// @native-sqlite-generated-types\n// @native-sqlite-generated-cmds\n// @native-sqlite-generated-subs", result), /readonly title: Uint8Array \| null/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("scalar subqueries widen generated result nullability", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: maybeNote\nSELECT (SELECT id FROM note WHERE id = -1) AS id;\n",
    );
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.queries[0]?.columns, [
      { name: "id", sqlType: "INTEGER", nullable: true },
    ]);
    assert.match(generateCoreSurface("// @native-sqlite-generated-types\n// @native-sqlite-generated-cmds\n// @native-sqlite-generated-subs", result), /readonly id: number \| null/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("compound selects widen every result across all arms", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      `-- name: mixedId
SELECT id FROM note UNION ALL SELECT NULL;

-- name: mixedCount
SELECT count(*) AS value FROM note UNION ALL SELECT title FROM note;
`,
    );
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.queries.map((query) => query.columns), [
      [{ name: "id", sqlType: "ANY", nullable: true }],
      [{ name: "value", sqlType: "ANY", nullable: true }],
    ]);
    const source = generateCoreSurface("// @native-sqlite-generated-types\n// @native-sqlite-generated-cmds\n// @native-sqlite-generated-subs", result);
    assert.match(source, /readonly id: DbDecodedValue/);
    assert.match(source, /readonly value: DbDecodedValue/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("comment-only migration drafts stay invalid and unlocked", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(path.join(root, "schema", "0001_draft.sql"), `-- Append-only SQLite migration.
-- Add the schema change before accepting this version.
`);
    const result = analyzeSqlite(root);
    assert.equal(result.diagnostics[0]?.rule, "NS1403");
    const state = path.join(root, "schema", "migrations.lock.json");
    assert.deepEqual(checkMigrationState(result, state), []);
    assert.equal(fs.existsSync(state), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("generated members and result fields cannot collide", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: notes\nSELECT id FROM note;\n-- name: Notes\nSELECT title FROM note;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1411");

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: duplicateColumns\nSELECT folder.id, note.id FROM folder JOIN note ON note.folder_id = folder.id;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1414");

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: tx :exec\nUPDATE note SET title = title;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1411");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("unnamed SQL is rejected while views resolve to underlying live dependencies", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "SELECT id FROM note;\n-- name: named\nSELECT id FROM note;\n",
    );
    assert.equal(analyzeSqlite(root).diagnostics[0]?.rule, "NS1410");

    fs.appendFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "\nCREATE VIEW note_titles AS SELECT id, title FROM note;\n",
    );
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: titles :live\nSELECT id, title FROM note_titles;\n",
    );
    const view = analyzeSqlite(root);
    assert.deepEqual(view.diagnostics, []);
    assert.ok(view.queries[0]?.tables.includes("note"));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("SQLite authorizer events enforce declared query and exec shapes", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: writableQuery\nINSERT INTO note(id,folder_id,title) VALUES(1,1,'x') RETURNING id;\n",
    );
    const writable = analyzeSqlite(root);
    assert.equal(writable.diagnostics[0]?.rule, "NS1414");
    assert.match(writable.diagnostics[0]?.message ?? "", /writable statement must be declared with :exec/);

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: readOnlyExec :exec\nSELECT id FROM note;\n",
    );
    const readOnly = analyzeSqlite(root);
    assert.equal(readOnly.diagnostics[0]?.rule, "NS1414");
    assert.match(readOnly.diagnostics[0]?.message ?? "", /:exec statement is read-only/);

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: insertFromCte :exec\nWITH input(id, folder_id, title) AS (VALUES(1, 1, 'x')) INSERT INTO note SELECT * FROM input;\n",
    );
    assert.deepEqual(analyzeSqlite(root).diagnostics, []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("live queries require an invalidation dependency", () => {
  const root = fixture();
  try {
    fs.writeFileSync(path.join(root, "queries.sql"), "-- name: staticValue :live\nSELECT 1 AS value;\n");
    const result = analyzeSqlite(root);
    assert.equal(result.diagnostics[0]?.rule, "NS1421");
    assert.equal(result.warnings.some((warning) => warning.rule === "NS1421"), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("quoted table names remain typed live-query dependencies", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      'CREATE TABLE "user notes"(id INTEGER PRIMARY KEY, title TEXT NOT NULL) STRICT;\n',
    );
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      '-- name: matchingNotes :live\nSELECT id, title FROM "user notes" WHERE title = :title;\n',
    );
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.queries[0]?.tables, ["user notes"]);
    assert.deepEqual(result.queries[0]?.params, [{ name: "title", sqlType: "TEXT", nullable: false }]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("COUNT inference follows the selected aggregate rather than its alias", () => {
  const root = fixture();
  try {
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: totals\nSELECT count(*) AS count, NULL AS count_hint FROM note;\n",
    );
    const result = analyzeSqlite(root);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.queries[0]?.columns, [
      { name: "count", sqlType: "INTEGER", nullable: false },
      { name: "count_hint", sqlType: "ANY", nullable: true },
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("migrations cannot terminate the analyzer-owned transaction", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "CREATE TABLE note(id INTEGER PRIMARY KEY) STRICT;\nCOMMIT;\n",
    );
    const result = analyzeSqlite(root);
    assert.equal(result.diagnostics[0]?.rule, "NS1404");
    assert.match(result.diagnostics[0]?.message ?? "", /not authorized|transaction/i);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("migration analysis applies the packaged runtime SQLite sandbox", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "PRAGMA 'user_version'=99;\nCREATE TABLE note(id INTEGER PRIMARY KEY) STRICT;\n",
    );
    const pragma = analyzeSqlite(root);
    assert.equal(pragma.diagnostics[0]?.rule, "NS1404");
    assert.match(pragma.diagnostics[0]?.message ?? "", /not authorized/i);

    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "ATTACH DATABASE ':memory:' AS escaped;\nCREATE TABLE note(id INTEGER PRIMARY KEY) STRICT;\n",
    );
    const attach = analyzeSqlite(root);
    assert.equal(attach.diagnostics[0]?.rule, "NS1404");
    assert.match(attach.diagnostics[0]?.message ?? "", /not authorized/i);

    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "CREATE TEMP TABLE session_note(id INTEGER PRIMARY KEY) STRICT;\n",
    );
    const temporary = analyzeSqlite(root);
    assert.equal(temporary.diagnostics[0]?.rule, "NS1404");
    assert.match(temporary.diagnostics[0]?.message ?? "", /not authorized/i);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the Node 22 policy fallback rejects TEMP access and load_extension", () => {
  for (const sql of [
    "CREATE TEMP TABLE session_note(id INTEGER);",
    "CREATE TABLE temp.session_note(id INTEGER);",
    "SELECT * FROM temp.session_note;",
    "SELECT load_extension(:path);",
  ]) {
    assert.match(inspectRelationalSql(sql, true).error ?? "", /not authorized|unavailable/i);
  }
  assert.match(
    inspectRelationalSql("SELECT d.name FROM sqlite_schema AS s, dbstat AS d;", true).error ?? "",
    /unavailable/i,
  );
  assert.equal(inspectRelationalSql("SELECT main.note.id FROM main.note;", true).error, null);
});

test("analysis rejects Node-only SQLite modules and functions", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-sqlite-check-"));
  try {
    fs.mkdirSync(path.join(root, "schema"));
    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "CREATE VIRTUAL TABLE box USING rtree(id, min_x, max_x);\n",
    );
    const module = analyzeSqlite(root);
    assert.equal(module.diagnostics[0]?.rule, "NS1404");
    assert.match(module.diagnostics[0]?.message ?? "", /not authorized/i);

    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "CREATE TABLE item(id INTEGER PRIMARY KEY) STRICT;\n",
    );
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: distance\nSELECT sqrt(:value) AS distance;\n",
    );
    const scalar = analyzeSqlite(root);
    assert.equal(scalar.diagnostics[0]?.rule, "NS1414");
    assert.match(scalar.diagnostics[0]?.message ?? "", /not authorized/i);

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: extension\nSELECT load_extension(:path) AS loaded;\n",
    );
    const extension = analyzeSqlite(root);
    assert.equal(extension.diagnostics[0]?.rule, "NS1414");
    assert.match(extension.diagnostics[0]?.message ?? "", /load_extension.*not authorized/i);

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: pages\nSELECT name FROM dbstat;\n",
    );
    const table = analyzeSqlite(root);
    assert.equal(table.diagnostics[0]?.rule, "NS1414");
    assert.match(table.diagnostics[0]?.message ?? "", /not authorized|prohibited/i);

    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: localPages\nWITH dbstat(name) AS (VALUES('local')), sqrt(value) AS (VALUES(4)) SELECT name FROM dbstat CROSS JOIN sqrt;\n",
    );
    assert.deepEqual(analyzeSqlite(root).diagnostics, []);

    fs.writeFileSync(
      path.join(root, "schema", "0001_init.sql"),
      "CREATE VIRTUAL TABLE search_index USING fts5(body);\n",
    );
    fs.writeFileSync(
      path.join(root, "queries.sql"),
      "-- name: matches\nSELECT body FROM search_index WHERE search_index MATCH :term;\n",
    );
    assert.deepEqual(analyzeSqlite(root).diagnostics, []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

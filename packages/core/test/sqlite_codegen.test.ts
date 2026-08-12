import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { analyzeSqlite, checkMigrationState, generateCoreSurface, generateMigrationsZig } from "../src/sqlite_codegen.ts";

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
    const state = path.join(root, ".native", "sqlite-schema.json");
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

// The editor declaration files are generated directly from the same models
// that generate their sources. These tests hold each generated declaration
// byte-identical to what declaration emit produces for the generated source,
// across the shapes the generators can produce.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import ts from "@typescript/old";
import { analyzeSqlite, generateCoreDeclarations, generateCoreSurface } from "../src/sqlite_codegen.ts";
import { checkFiles } from "./helpers.ts";

const sdkDir = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), "sdk");
const sdkCore = fs.readFileSync(path.join(sdkDir, "core.ts"), "utf8");
const sdkCoreDeclarations = fs.readFileSync(path.join(sdkDir, "core.d.ts"), "utf8");

/// Declaration emit for a generated SDK core module, compiled in place of
/// sdk/core.ts so its relative SDK imports resolve.
function emittedCoreDeclarations(source: string): string {
  const compilerOptions: ts.CompilerOptions = {
    strict: true,
    exactOptionalPropertyTypes: true,
    target: ts.ScriptTarget.ESNext,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    lib: ["lib.esnext.d.ts"],
    types: [],
    allowImportingTsExtensions: true,
    rewriteRelativeImportExtensions: true,
    declaration: true,
    emitDeclarationOnly: true,
    skipLibCheck: false,
  };
  const input = path.join(sdkDir, "core.ts");
  const host = ts.createCompilerHost(compilerOptions);
  const getSourceFile = host.getSourceFile.bind(host);
  host.getSourceFile = (fileName, languageVersion, onError, shouldCreateNewSourceFile) =>
    path.resolve(fileName) === input
      ? ts.createSourceFile(fileName, source, languageVersion, true)
      : getSourceFile(fileName, languageVersion, onError, shouldCreateNewSourceFile);
  let output = "";
  host.writeFile = (fileName, text) => {
    if (fileName.endsWith("core.d.ts")) output = text;
  };
  const program = ts.createProgram([input], compilerOptions, host);
  const errors = ts.getPreEmitDiagnostics(program).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n")), []);
  program.emit();
  return output.replace(/(from\s+")(\.\.?\/[^"]+)\.ts(")/g, "$1$2.js$3");
}

function sqliteApp(schema: string, queries: string): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-editor-dts-"));
  fs.mkdirSync(path.join(root, "schema"));
  fs.writeFileSync(path.join(root, "schema", "0001_init.sql"), schema);
  if (queries !== "") fs.writeFileSync(path.join(root, "queries.sql"), queries);
  return root;
}

const schema = `
CREATE TABLE folder(id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
CREATE TABLE note(
  id INTEGER PRIMARY KEY,
  folder_id INTEGER NOT NULL REFERENCES folder(id),
  title TEXT NOT NULL,
  body TEXT,
  score REAL,
  weight REAL NOT NULL,
  thumb BLOB,
  data BLOB NOT NULL,
  extra ANY
) STRICT;
`;

const sqliteCases: Record<string, string> = {
  "live and exec queries": `-- name: notesInFolder :live
SELECT n.id, n.title FROM note n WHERE n.folder_id = :folder ORDER BY n.id;

-- name: moveNote :exec
UPDATE note SET folder_id = :to WHERE id = :id;
`,
  "every column class, nullable and not": `-- name: everything 
SELECT id, title, body, score, weight, thumb, data, extra, id + 1 AS "next id", title || '!' AS loud FROM note WHERE id = :id;
`,
  "nullable and text parameters": `-- name: search 
SELECT id FROM note WHERE body = :body AND title = :title AND score > :score;

-- name: insertNote :exec
INSERT INTO note(id, folder_id, title, body, score, weight, thumb, data, extra) VALUES (:id, :folder, :title, :body, :score, :weight, :thumb, :data, :extra);
`,
  "exec only": `-- name: renameFolder :exec
UPDATE folder SET name = :name WHERE id = :id;

-- name: dropFolder :exec
DELETE FROM folder WHERE id = :id;
`,
  "rows only, none live": `-- name: folders 
SELECT id, name FROM folder ORDER BY id;
`,
  "no queries file": ``,
};

for (const [name, queries] of Object.entries(sqliteCases)) {
  test(`generated SQLite declarations match declaration emit: ${name}`, () => {
    const app = sqliteApp(schema, queries);
    try {
      const analysis = analyzeSqlite(app);
      assert.deepEqual(analysis.diagnostics, []);
      assert.equal(analysis.queries.length > 0, queries !== "");
      assert.equal(
        generateCoreDeclarations(sdkCore, sdkCoreDeclarations, analysis),
        emittedCoreDeclarations(generateCoreSurface(sdkCore, analysis)),
      );
    } finally {
      fs.rmSync(app, { recursive: true, force: true });
    }
  });
}

test("a missing SQLite declaration anchor fails instead of dropping generated declarations", () => {
  const app = sqliteApp(schema, sqliteCases["live and exec queries"]!);
  try {
    const analysis = analyzeSqlite(app);
    const withoutCmd = sdkCoreDeclarations.replace("export declare const Cmd: {", "export declare const Commands: {");
    assert.throws(() => generateCoreDeclarations(sdkCore, withoutCmd, analysis), /no anchor for \/\/ @native-sqlite-generated-cmds/);
  } finally {
    fs.rmSync(app, { recursive: true, force: true });
  }
});

const serviceModel = `export interface Model { readonly n: number; }
export type Msg = { readonly kind: "tick" };
export function update(model: Model): Model { return model; }`;

const serviceCases: Record<string, Record<string, string>> = {
  "bytes request and result": {
    "services/feeds.ts": "export function parse(bytes: Uint8Array): Uint8Array { return bytes; }",
  },
  "records, enums and unions from two modules, nested types only in codecs": {
    "shared.ts": `
export type Flavor = "plain" | "rich";
export type Inner = { readonly bytes: Uint8Array };
export type Choice =
  | { readonly kind: "kept"; readonly inner: Inner }
  | { readonly kind: "skipped"; readonly count: number };
export type Request = { readonly flavor: Flavor; readonly choice: Choice; readonly maybe: Uint8Array | null };
export type Result = { readonly inner: Inner; readonly parts: readonly Uint8Array[] };`,
    "services/shapes.ts": `
import type { Choice, Flavor, Request, Result } from "../shared.ts";
export function convert(request: Request): Result { return { inner: { bytes: request.maybe ?? new Uint8Array(0) }, parts: [] }; }
export function flavor(choice: Choice): Flavor { return choice.kind === "kept" ? "rich" : "plain"; }`,
  },
  "no request, optional and composite slice results, several modules": {
    "services/clock.ts": "export function now(): number { return 0; }",
    "services/lists.ts": `
export function maybe(bytes: Uint8Array): Uint8Array | null { return bytes.length ? bytes : null; }
export function groups(values: readonly (Uint8Array | null)[]): readonly (readonly Uint8Array[])[] { return [values.filter((v): v is Uint8Array => v !== null)]; }
export function flags(on: boolean): readonly boolean[] { return [on]; }`,
  },
  "streaming and request/response operations together": {
    "shared.ts": "export type Chunk = { readonly bytes: Uint8Array; readonly index: number; };",
    "services/feeds.ts": `
import type { Chunk } from "../shared.ts";
/**
 * @streamBuffer 4
 */
export function stream(bytes: Uint8Array, emit: (chunk: Chunk) => void): Uint8Array { emit({ bytes, index: 0 }); return bytes; }
export function once(bytes: Uint8Array): Uint8Array { return bytes; }`,
  },
  "a stream-only service": {
    "services/feeds.ts": `
/**
 * @streamBuffer 2
 */
export function stream(bytes: Uint8Array, emit: (chunk: Uint8Array) => void): Uint8Array { emit(bytes); return bytes; }`,
  },
};

for (const [name, files] of Object.entries(serviceCases)) {
  test(`generated service client declarations match declaration emit: ${name}`, () => {
    const result = checkFiles({ "core.ts": serviceModel, ...files });
    assert.equal(result.ok, true, JSON.stringify([...result.diagnostics, ...result.typeErrors]));
    const emitted = ts.transpileDeclaration(result.servicesClient!, {
      fileName: "index.ts",
      compilerOptions: { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext },
      reportDiagnostics: true,
    });
    assert.deepEqual(emitted.diagnostics?.filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error) ?? [], []);
    assert.equal(result.servicesClientDeclarations, emitted.outputText);
  });
}

// services.contract.json — the only fact channel for the phase-1 service
// seam. It is emitted from the same parsed program as the core contract; all
// downstream dispatch/host generation consumes this document rather than
// re-reading author source for declarations.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ts, hasExportModifier, lineColumn, type TypedAst } from "./typed_ast.ts";
import { makeDiagnostic, type SubsetDiagnostic } from "./diagnostics.ts";

export const serviceContractFormat = 1;
export const serviceProtocolVersion = 1;

export interface ServiceOperation {
  readonly name: string;
  readonly module: string;
  readonly export: string;
  readonly payload: "none" | "bytes";
  readonly result: "bytes";
  readonly source_hash: string;
}

export interface ServiceSurfaceResult {
  readonly operations: readonly ServiceOperation[];
  readonly diagnostics: readonly SubsetDiagnostic[];
  readonly contract: string | null;
}

function report(site: string, node: ts.Node): SubsetDiagnostic {
  const file = node.getSourceFile();
  const where = lineColumn(file, node.getStart(file));
  return makeDiagnostic("NS1067", site, file.fileName, where.line, where.column);
}

function aliasesIn(files: readonly ts.SourceFile[]): ReadonlySet<string> {
  const aliases = new Set<string>(["Uint8Array"]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const file of files) {
      for (const stmt of file.statements) {
        if (!ts.isTypeAliasDeclaration(stmt) || !ts.isTypeReferenceNode(stmt.type) || !ts.isIdentifier(stmt.type.typeName)) continue;
        if (!aliases.has(stmt.type.typeName.text) || aliases.has(stmt.name.text)) continue;
        aliases.add(stmt.name.text);
        changed = true;
      }
    }
  }
  return aliases;
}

function isBytesType(node: ts.TypeNode | undefined, aliases: ReadonlySet<string>): boolean {
  return !!node && ts.isTypeReferenceNode(node) && ts.isIdentifier(node.typeName) && aliases.has(node.typeName.text);
}

function unwrapExpression(expr: ts.Expression): ts.Expression {
  while (ts.isAsExpression(expr) || ts.isTypeAssertionExpression(expr) || ts.isParenthesizedExpression(expr)) expr = expr.expression;
  return expr;
}

function explicitThrowIsKindTagged(tast: TypedAst, expr: ts.Expression): boolean {
  const value = unwrapExpression(expr);
  if (!ts.isObjectLiteralExpression(value) || value.properties.length !== 2) return false;
  const [kind, message] = value.properties;
  const messageType = ts.isPropertyAssignment(message) ? tast.typeOf(message.initializer) : null;
  const messageIsString = messageType !== null && (
    (messageType.flags & (ts.TypeFlags.String | ts.TypeFlags.StringLiteral)) !== 0 ||
    (messageType.isUnion() && messageType.types.every((member) => member.isStringLiteral())) ||
    // The in-process checker deliberately has no Node declaration universe;
    // defer an unresolved ambient expression to scriptc and stringify it in
    // the scratch adapter rather than false-rejecting a real string result.
    (messageType.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) !== 0
  );
  return ts.isPropertyAssignment(kind) && ts.isIdentifier(kind.name) && kind.name.text === "kind" &&
    ts.isStringLiteral(kind.initializer) && kind.initializer.text.length > 0 &&
    ts.isPropertyAssignment(message) && ts.isIdentifier(message.name) && message.name.text === "message" &&
    messageIsString;
}

function throwIsLexicallyCaught(node: ts.ThrowStatement): boolean {
  let child: ts.Node = node;
  for (let parent = node.parent; parent; child = parent, parent = parent.parent) {
    if (ts.isFunctionLike(parent)) return false;
    if (ts.isTryStatement(parent) && parent.tryBlock === child && parent.catchClause) return true;
  }
  return false;
}

function pinnedScriptcVersion(): string {
  const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8")) as {
    dependencies?: { scriptc?: unknown };
  };
  const pin = manifest.dependencies?.scriptc;
  if (typeof pin !== "string" || !/^\d+\.\d+\.\d+$/.test(pin)) {
    throw new Error("packages/core/package.json carries no exact scriptc pin");
  }
  return pin;
}

export function emitServiceContract(
  tast: TypedAst,
  files: readonly ts.SourceFile[],
  srcRoot: string,
): ServiceSurfaceResult {
  if (files.length === 0) return { operations: [], diagnostics: [], contract: null };

  const diagnostics: SubsetDiagnostic[] = [];
  const operations: ServiceOperation[] = [];
  const names = new Set<string>();
  const namespaceClaims = new Map<string, ts.Node>();
  const aliases = aliasesIn(files);

  for (const file of files) {
    const relative = path.relative(srcRoot, file.fileName).split(path.sep).join("/");
    const module = relative.replace(/^services\//, "").replace(/\.ts$/, "");
    const moduleName = path.posix.basename(module);
    const sourceHash = crypto.createHash("sha256").update(fs.readFileSync(file.fileName)).digest("hex");
    for (const stmt of file.statements) {
      const claim = (name: ts.Identifier): void => {
        if (name.text.startsWith("__nativeSdk")) {
          diagnostics.push(report("A service declaration uses the reserved `__nativeSdk` transport-adapter prefix.", name));
          return;
        }
        const prior = namespaceClaims.get(name.text);
        if (prior && prior !== stmt) {
          diagnostics.push(makeDiagnostic(
            "NS1038",
            `\`${name.text}\` is also declared in the service class; module-scope type and exported value names must be unique within a compiler class.`,
            file.fileName,
            lineColumn(file, name.getStart(file)).line,
            lineColumn(file, name.getStart(file)).column,
          ));
        } else namespaceClaims.set(name.text, stmt);
      };
      const declaredName = (ts.isFunctionDeclaration(stmt) || ts.isClassDeclaration(stmt)) ? stmt.name : undefined;
      if (declaredName && !hasExportModifier(stmt) && declaredName.text.startsWith("__nativeSdk")) {
        diagnostics.push(report("A service declaration uses the reserved `__nativeSdk` transport-adapter prefix.", declaredName));
      }
      if (ts.isInterfaceDeclaration(stmt) || ts.isTypeAliasDeclaration(stmt)) claim(stmt.name);
      else if ((ts.isFunctionDeclaration(stmt) || ts.isClassDeclaration(stmt)) && stmt.name && hasExportModifier(stmt)) claim(stmt.name);
      else if (ts.isVariableStatement(stmt)) {
        for (const decl of stmt.declarationList.declarations) {
          if (!ts.isIdentifier(decl.name)) continue;
          if (hasExportModifier(stmt)) claim(decl.name);
          else if (decl.name.text.startsWith("__nativeSdk")) {
            diagnostics.push(report("A service declaration uses the reserved `__nativeSdk` transport-lowering prefix.", decl.name));
          }
        }
      }

      if (ts.isExportDeclaration(stmt) && !stmt.isTypeOnly) {
        diagnostics.push(report("A service value is exported through an export list or re-export, which has no direct operation declaration.", stmt));
        continue;
      }
      if (!ts.isFunctionDeclaration(stmt) || !hasExportModifier(stmt)) continue;
      if (stmt.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword)) {
        diagnostics.push(report("A service operation is default-exported, but generated dispatch imports operations by their named exports.", stmt));
        continue;
      }
      if (!stmt.name) {
        diagnostics.push(report("A service exports an unnamed function.", stmt));
        continue;
      }
      const opName = `${moduleName}.${stmt.name.text}`;
      if (names.has(opName)) {
        diagnostics.push(report(`The operation name \`${opName}\` is declared more than once (module basenames form the public prefix).`, stmt.name));
        continue;
      }
      names.add(opName);

      const asyncModifier = stmt.modifiers?.some((m) => m.kind === ts.SyntaxKind.AsyncKeyword) ?? false;
      if (asyncModifier || stmt.asteriskToken || !stmt.body) {
        diagnostics.push(report(`\`${opName}\` is not a synchronous function with a body.`, stmt.name));
        continue;
      }
      if (stmt.parameters.length > 1 || (stmt.parameters.length === 1 && !isBytesType(stmt.parameters[0].type, aliases))) {
        diagnostics.push(report(`\`${opName}\` does not take zero arguments or one Uint8Array payload.`, stmt.name));
        continue;
      }
      if (!isBytesType(stmt.type, aliases)) {
        diagnostics.push(report(`\`${opName}\` does not declare a Uint8Array return type.`, stmt.name));
        continue;
      }
      operations.push({
        name: opName,
        module: `src/${relative}`,
        export: stmt.name.text,
        payload: stmt.parameters.length === 0 ? "none" : "bytes",
        result: "bytes",
        source_hash: sourceHash,
      });
    }

    const visitThrows = (node: ts.Node): void => {
      if (ts.isThrowStatement(node) && node.expression) {
        if (!explicitThrowIsKindTagged(tast, node.expression)) {
          diagnostics.push(report("An explicit service throw is not an inline `{ kind, message: string }` shape.", node));
        } else if (throwIsLexicallyCaught(node)) {
          diagnostics.push(report("A tagged service throw is caught inside the service instead of escaping through the operation boundary.", node));
        }
      }
      ts.forEachChild(node, visitThrows);
    };
    visitThrows(file);
  }

  if (diagnostics.length > 0) return { operations, diagnostics, contract: null };
  const document = {
    format: serviceContractFormat,
    protocol_version: serviceProtocolVersion,
    compiler_version: pinnedScriptcVersion(),
    deterministic: false,
    operations,
  };
  return { operations, diagnostics, contract: `${JSON.stringify(document, null, 2)}\n` };
}

// services.contract.json — the only fact channel for the typed service
// seam. It is emitted from the same parsed program as the core contract; all
// downstream dispatch/host generation consumes this document rather than
// re-reading author source for declarations.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ts, hasExportModifier, exportListBindings, lineColumn, type TypedAst } from "./typed_ast.ts";
import { makeDiagnostic, type SubsetDiagnostic } from "./diagnostics.ts";
import { TypeTable, type ZType } from "./types.ts";
import type { IntInference } from "./infer.ts";

export const serviceContractFormat = 3;
export const serviceProtocolVersion = 3;

export type ServiceTypeRef =
  | { readonly kind: "bool" | "f64" | "i64" | "bytes" }
  | { readonly kind: "optional"; readonly inner: ServiceTypeRef }
  | { readonly kind: "slice"; readonly elem: ServiceTypeRef }
  | { readonly kind: "record" | "enum" | "union"; readonly name: string };

export interface ServiceRecordType {
  readonly name: string;
  readonly origin: string;
  readonly fields: readonly { readonly name: string; readonly type: ServiceTypeRef }[];
}

export interface ServiceEnumType {
  readonly name: string;
  readonly origin: string;
  readonly members: readonly string[];
}

export interface ServiceUnionType {
  readonly name: string;
  readonly origin: string;
  readonly arms: readonly {
    readonly name: string;
    readonly fields: readonly { readonly name: string; readonly type: ServiceTypeRef }[];
  }[];
}

export interface ServiceTypes {
  readonly records: readonly ServiceRecordType[];
  readonly enums: readonly ServiceEnumType[];
  readonly unions: readonly ServiceUnionType[];
}

export interface ServicePackage {
  readonly name: string;
  readonly version: string;
  readonly content_hash: string;
}

export interface ServiceOperation {
  readonly name: string;
  readonly client: string;
  readonly module: string;
  readonly export: string;
  readonly request: { readonly kind: "none" } | ServiceTypeRef;
  readonly result: ServiceTypeRef;
  readonly deadline_ms: number | null;
  readonly cancellable: boolean;
  readonly stream: { readonly chunk: ServiceTypeRef; readonly in_flight: number } | null;
  readonly source_hash: string;
}

export interface ServiceSurfaceResult {
  readonly operations: readonly ServiceOperation[];
  readonly types: ServiceTypes;
  readonly diagnostics: readonly SubsetDiagnostic[];
  readonly contract: string | null;
  readonly client: string | null;
}

function report(site: string, node: ts.Node): SubsetDiagnostic {
  const file = node.getSourceFile();
  const where = lineColumn(file, node.getStart(file));
  return makeDiagnostic("NS1067", site, file.fileName, where.line, where.column);
}

function isBytesType(tast: TypedAst, node: ts.TypeNode | undefined, seen = new Set<ts.Node>()): boolean {
  if (!node || !ts.isTypeReferenceNode(node)) return false;
  const name = ts.isIdentifier(node.typeName) ? node.typeName : node.typeName.right;
  const declaration = tast.declarationOf(name);
  if (name.text === "Uint8Array") {
    // Preserve the direct global spelling while still respecting a local
    // type alias that shadows it.
    if (!declaration || !ts.isTypeAliasDeclaration(declaration)) return true;
  }
  if (!declaration || !ts.isTypeAliasDeclaration(declaration) || seen.has(declaration)) return false;
  seen.add(declaration);
  return isBytesType(tast, declaration.type, seen);
}

function isServiceCancellationType(tast: TypedAst, node: ts.TypeNode | undefined): boolean {
  if (!node || !ts.isTypeReferenceNode(node) || node.typeArguments?.length) return false;
  const name = ts.isIdentifier(node.typeName) ? node.typeName : node.typeName.right;
  if (name.text !== "ServiceCancellation") return false;
  const declaration = tast.declarationOf(name);
  if (!declaration) return false;
  const source = declaration.getSourceFile().fileName.split(path.sep).join("/");
  return source.endsWith("/sdk/core.ts") || source.endsWith("/sdk/core.d.ts") || source.endsWith("/compile-surface/core.ts");
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

function sourceGraphHash(files: readonly ts.SourceFile[], srcRoot: string): string {
  const facts = files.map((file) => ({
    module: path.relative(srcRoot, file.fileName).split(path.sep).join("/"),
    hash: crypto.createHash("sha256").update(fs.readFileSync(file.fileName)).digest("hex"),
  })).sort((a, b) => a.module < b.module ? -1 : a.module > b.module ? 1 : 0);
  const graph = crypto.createHash("sha256");
  graph.update("native-sdk.services.sources.v1\0");
  for (const fact of facts) {
    graph.update(fact.module);
    graph.update("\0");
    graph.update(fact.hash);
    graph.update("\0");
  }
  return graph.digest("hex");
}

function supportedOperationIdentifier(name: string): boolean {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name);
}

class ServiceShapeError extends Error {
  readonly node: ts.Node;
  constructor(message: string, node: ts.Node) {
    super(message);
    this.node = node;
  }
}

class ServiceShapeTable {
  readonly records: ServiceRecordType[] = [];
  readonly enums: ServiceEnumType[] = [];
  readonly unions: ServiceUnionType[] = [];
  private readonly listed = new Set<string>();
  private readonly tast: TypedAst;
  private readonly table: TypeTable;
  private readonly infer: IntInference;
  private readonly srcRoot: string;
  private readonly fallbackSite: ts.Node;

  constructor(
    tast: TypedAst,
    table: TypeTable,
    infer: IntInference,
    srcRoot: string,
    fallbackSite: ts.Node,
  ) {
    this.tast = tast;
    this.table = table;
    this.infer = infer;
    this.srcRoot = srcRoot;
    this.fallbackSite = fallbackSite;
  }

  ref(node: ts.TypeNode, site: ts.Node): ServiceTypeRef {
    return this.reflect(this.table.resolveTypeNode(node), site);
  }

  private origin(decl: ts.Declaration, name: string): string {
    const file = decl.getSourceFile();
    const relative = path.relative(this.srcRoot, file.fileName).split(path.sep).join("/");
    if (relative.startsWith("services/")) {
      throw new ServiceShapeError(
        `Service boundary type \`${name}\` is declared under src/services; declare and export the shared data shape from a core-class module so both sides read one authority`,
        decl,
      );
    }
    const directlyExported = hasExportModifier(decl);
    const listExported = exportListBindings(this.tast, file)
      .some((binding) => binding.target === decl && !binding.renamed);
    if (!directlyExported && !listExported) {
      throw new ServiceShapeError(
        `Service boundary type \`${name}\` is not exported from ${relative}; export the shared declaration so the generated client can import the same shape`,
        decl,
      );
    }
    return relative;
  }

  private reflect(type: ZType, decl: ts.Node): ServiceTypeRef {
    switch (type.k) {
      case "bool": return { kind: "bool" };
      case "f64": return { kind: "f64" };
      case "i64": return { kind: "i64" };
      case "number": return { kind: this.infer.classOfDecl(decl) === "i64" ? "i64" : "f64" };
      case "bytes": return { kind: "bytes" };
      case "numAlias": return { kind: "i64" };
      case "optional": return { kind: "optional", inner: this.reflect(type.inner, decl) };
      case "slice": return { kind: "slice", elem: this.reflect(type.elem, decl) };
      case "struct":
        this.collectRecord(type.name);
        return { kind: "record", name: type.name };
      case "enum":
        this.collectEnum(type.name);
        return { kind: "enum", name: type.name };
      case "union":
        this.collectUnion(type.name);
        return { kind: "union", name: type.name };
      case "string":
        throw new ServiceShapeError("Dynamic string data has no core boundary representation; use Uint8Array byte text or a string-literal union", decl);
      case "void":
        throw new ServiceShapeError("A service boundary slot resolves to void", decl);
    }
  }

  private collectRecord(name: string): void {
    if (this.listed.has(name)) return;
    const info = this.table.structs.get(name);
    if (!info) throw new ServiceShapeError(`The shared type table has no record named \`${name}\``, this.fallbackSite);
    this.listed.add(name);
    const record: ServiceRecordType = {
      name,
      origin: this.origin(info.decl, name),
      fields: info.fields.map((field) => ({ name: field.tsName, type: this.reflect(field.type, field.decl) })),
    };
    this.records.push(record);
  }

  private collectEnum(name: string): void {
    if (this.listed.has(name)) return;
    const info = this.table.enums.get(name);
    if (!info) throw new ServiceShapeError(`The shared type table has no enum named \`${name}\``, this.fallbackSite);
    this.listed.add(name);
    this.enums.push({ name, origin: this.origin(info.decl, name), members: info.members });
  }

  private collectUnion(name: string): void {
    if (this.listed.has(name)) return;
    const info = this.table.unions.get(name);
    if (!info) throw new ServiceShapeError(`The shared type table has no union named \`${name}\``, this.fallbackSite);
    this.listed.add(name);
    const union: ServiceUnionType = {
      name,
      origin: this.origin(info.decl, name),
      arms: info.arms.map((arm) => ({
        name: arm.tag,
        fields: arm.fields.map((field) => ({ name: field.tsName, type: this.reflect(field.type, field.decl) })),
      })),
    };
    this.unions.push(union);
  }

  document(): ServiceTypes {
    return { records: this.records, enums: this.enums, unions: this.unions };
  }
}

function clientIdentifier(operation: Pick<ServiceOperation, "name" | "export">): string {
  const stem = `${operation.name.slice(0, operation.name.lastIndexOf("."))}_${operation.export}`;
  const words = stem.split(/[^A-Za-z0-9_$]+|_+/).filter(Boolean);
  const joined = words.map((word, index) => index === 0 ? word : word[0].toUpperCase() + word.slice(1)).join("");
  return supportedOperationIdentifier(joined) ? joined : `service_${operation.export}`;
}

function typeSpelling(ref: ServiceTypeRef): string {
  switch (ref.kind) {
    case "bool": return "boolean";
    case "f64":
    case "i64": return "number";
    case "bytes": return "Uint8Array";
    case "optional": return `${typeSpelling(ref.inner)} | null`;
    case "slice": {
      const elem = typeSpelling(ref.elem);
      return `readonly ${ref.elem.kind === "optional" || ref.elem.kind === "slice" ? `(${elem})` : elem}[]`;
    }
    case "record":
    case "enum":
    case "union": return ref.name;
  }
}

function emitServiceClientDocument(document: {
  readonly operations: readonly ServiceOperation[];
  readonly types: ServiceTypes;
}): string {
  const imports = new Map<string, Set<string>>();
  const addImport = (origin: string, name: string): void => {
    const names = imports.get(origin) ?? new Set<string>();
    names.add(name);
    imports.set(origin, names);
  };
  addImport("core.ts", "Msg");
  for (const type of [...document.types.records, ...document.types.enums, ...document.types.unions]) addImport(type.origin, type.name);

  let out = "// Generated from services.contract.json. Do not edit.\n";
  out += "import { Cmd, serviceBoolBytes, serviceBytes, serviceConcat, serviceEnumBytes, serviceF64Bytes, serviceI64Bytes, serviceOptionalBytes, serviceSliceBytes, serviceUnionBytes, type ServiceRoute, type ServiceStreamRoute } from \"@native-sdk/core\";\n";
  for (const [origin, names] of [...imports].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
    out += `import type { ${[...names].sort().join(", ")} } from \"./${origin}\";\n`;
  }

  const records = new Map(document.types.records.map((type) => [type.name, type]));
  const enums = new Map(document.types.enums.map((type) => [type.name, type]));
  const unions = new Map(document.types.unions.map((type) => [type.name, type]));
  const encode = (ref: ServiceTypeRef, value: string): string => {
    switch (ref.kind) {
      case "bool": return `serviceBoolBytes(${value})`;
      case "f64": return `serviceF64Bytes(${value})`;
      case "i64": return `serviceI64Bytes(${value})`;
      case "bytes": return `serviceBytes(${value})`;
      case "optional": return `${value} === null ? serviceOptionalBytes(null) : serviceOptionalBytes(${encode(ref.inner, value)})`;
      case "slice": return `serviceSliceBytes(${value}.map((item) => ${encode(ref.elem, "item")}))`;
      case "record": return `__nativeSdkEncode${ref.name}(${value})`;
      case "enum": {
        const members = enums.get(ref.name)?.members ?? [];
        const index = members.reduceRight((tail, member, i) => `${value} === ${JSON.stringify(member)} ? ${i} : (${tail})`, "0");
        return `serviceEnumBytes(${index})`;
      }
      case "union": return `__nativeSdkEncode${ref.name}(${value})`;
    }
  };

  for (const record of records.values()) {
    out += `\nfunction __nativeSdkEncode${record.name}(value: ${record.name}): Uint8Array {\n`;
    out += `  return serviceConcat([${record.fields.map((field) => encode(field.type, `value.${field.name}`)).join(", ")}]);\n}\n`;
  }
  for (const union of unions.values()) {
    out += `\nfunction __nativeSdkEncode${union.name}(value: ${union.name}): Uint8Array {\n  switch (value.kind) {\n`;
    union.arms.forEach((arm, index) => {
      const fields = arm.fields.map((field) => encode(field.type, `value.${field.name}`));
      out += `    case ${JSON.stringify(arm.name)}: return serviceConcat([serviceUnionBytes(${index})${fields.length ? `, ${fields.join(", ")}` : ""}]);\n`;
    });
    out += "  }\n}\n";
  }
  for (const operation of document.operations) {
    const fn = operation.client;
    const request = operation.request.kind === "none" ? null : operation.request;
    const requestParam = request ? `request: ${typeSpelling(request)}, ` : "";
    const payload = request ? (request.kind === "bytes" ? "request" : encode(request, "request")) : "new Uint8Array(0)";
    const routeType = operation.stream === null ? "ServiceRoute" : "ServiceStreamRoute";
    out += `\nexport function ${fn}(${requestParam}route: ${routeType}<Msg, ${typeSpelling(operation.result)}>): Cmd<Msg> {\n`;
    out += operation.stream === null
      ? `  return Cmd.serviceRequest(${JSON.stringify(operation.name)}, ${payload}, route);\n}\n`
      : `  return Cmd.serviceStreamRequest(${JSON.stringify(operation.name)}, route.channelKey, ${payload}, route, ${operation.stream.in_flight});\n}\n`;
  }
  return out;
}

export function emitServiceContract(
  tast: TypedAst,
  table: TypeTable,
  infer: IntInference,
  files: readonly ts.SourceFile[],
  hostFiles: readonly ts.SourceFile[],
  srcRoot: string,
  packages: readonly ServicePackage[] = [],
): ServiceSurfaceResult {
  const emptyTypes: ServiceTypes = { records: [], enums: [], unions: [] };
  if (files.length === 0) return { operations: [], types: emptyTypes, diagnostics: [], contract: null, client: null };

  const diagnostics: SubsetDiagnostic[] = [];
  const operations: ServiceOperation[] = [];
  const shapes = new ServiceShapeTable(tast, table, infer, srcRoot, files[0]);
  const names = new Set<string>();
  const namespaceClaims = new Map<string, ts.Node>();
  const sourceHash = sourceGraphHash(hostFiles, srcRoot);
  for (const file of files) {
    const relative = path.relative(srcRoot, file.fileName).split(path.sep).join("/");
    const module = relative.replace(/^services\//, "").replace(/\.ts$/, "");
    const moduleName = path.posix.basename(module);
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
      if (!supportedOperationIdentifier(stmt.name.text)) {
        diagnostics.push(report(
          `\`${stmt.name.text}\` is outside the service contract's portable identifier set (ASCII letters, digits, \`_\`, and \`$\`).`,
          stmt.name,
        ));
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
      if (stmt.parameters.length > 3 || stmt.parameters.some((parameter) => !parameter.type)) {
        diagnostics.push(report(`\`${opName}\` does not take an explicitly annotated request, optional generated emit capability, and optional ServiceCancellation capability.`, stmt.name));
        continue;
      }
      if (!stmt.type) {
        diagnostics.push(report(`\`${opName}\` does not declare an explicit contract-encodable return type.`, stmt.name));
        continue;
      }
      try {
        let requestParameter: ts.ParameterDeclaration | null = null;
        let streamChunk: ServiceTypeRef | null = null;
        let cancellable = false;
        let boundaryParameters = [...stmt.parameters];
        const cancellationParameter = boundaryParameters[boundaryParameters.length - 1];
        if (cancellationParameter && isServiceCancellationType(tast, cancellationParameter.type)) {
          cancellable = true;
          boundaryParameters = boundaryParameters.slice(0, -1);
        }
        if (boundaryParameters.some((parameter) => isServiceCancellationType(tast, parameter.type))) {
          diagnostics.push(report(`\`${opName}\` places ServiceCancellation before another parameter; the generated cancellation capability must be last.`, stmt.name));
          continue;
        }
        if (boundaryParameters.length > 2) {
          diagnostics.push(report(`\`${opName}\` has more than one data parameter; service operations take at most one request followed by the generated emit capability.`, stmt.name));
          continue;
        }
        if (boundaryParameters.length > 0) {
          const last = boundaryParameters[boundaryParameters.length - 1];
          if (last.type && ts.isFunctionTypeNode(last.type)) {
            const emitType = last.type;
            if (emitType.parameters.length !== 1 || !emitType.parameters[0].type || emitType.type.kind !== ts.SyntaxKind.VoidKeyword) {
              diagnostics.push(report(`\`${opName}\` has an invalid emit capability; spell the last parameter as \`emit: (chunk: SharedChunk) => void\`.`, last));
              continue;
            }
            streamChunk = shapes.ref(emitType.parameters[0].type, emitType.parameters[0]);
            requestParameter = boundaryParameters.length === 2 ? boundaryParameters[0] : null;
          } else {
            if (boundaryParameters.length > 1) {
              diagnostics.push(report(`\`${opName}\` has two data parameters; the second parameter is reserved for \`emit: (chunk: SharedChunk) => void\`.`, last));
              continue;
            }
            requestParameter = boundaryParameters[0];
          }
        }
        const deadlineTag = ts.getJSDocTags(stmt).find((tag) => tag.tagName.text === "deadlineMs");
        const deadlineText = typeof deadlineTag?.comment === "string" ? deadlineTag.comment.trim() : "";
        const deadline = deadlineText === "" ? null : Number(deadlineText);
        if (deadline !== null && (!Number.isSafeInteger(deadline) || deadline < 1 || deadline > 86_400_000)) {
          diagnostics.push(report(`\`${opName}\` has an invalid @deadlineMs value; use a whole 1..86400000 millisecond deadline.`, deadlineTag ?? stmt.name));
          continue;
        }
        const streamTag = ts.getJSDocTags(stmt).find((tag) => tag.tagName.text === "streamBuffer");
        const streamText = typeof streamTag?.comment === "string" ? streamTag.comment.trim() : "";
        const streamBuffer = streamText === "" ? 8 : Number(streamText);
        if (streamChunk !== null && (!Number.isSafeInteger(streamBuffer) || streamBuffer < 1 || streamBuffer > 64)) {
          diagnostics.push(report(`\`${opName}\` has an invalid @streamBuffer value; use a whole 1..64 in-flight chunk cap.`, streamTag ?? stmt.name));
          continue;
        }
        const client = clientIdentifier({ name: opName, export: stmt.name.text });
        const priorClient = operations.find((operation) => operation.client === client);
        if (priorClient) {
          diagnostics.push(report(`\`${opName}\` and \`${priorClient.name}\` both generate the client name \`${client}\`; rename one service module or export.`, stmt.name));
          continue;
        }
        operations.push({
          name: opName,
          client,
          module: `src/${relative}`,
          export: stmt.name.text,
          request: requestParameter === null
            ? { kind: "none" }
            : shapes.ref(requestParameter.type!, requestParameter),
          result: shapes.ref(stmt.type, stmt),
          deadline_ms: deadline,
          cancellable,
          stream: streamChunk === null ? null : { chunk: streamChunk, in_flight: streamBuffer },
          source_hash: sourceHash,
        });
      } catch (error) {
        if (error instanceof ServiceShapeError) {
          diagnostics.push(report(`${error.message}.`, error.node));
          continue;
        }
        throw error;
      }
    }
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
  for (const file of hostFiles) visitThrows(file);

  if (operations.length === 0 && diagnostics.length === 0) {
    diagnostics.push(report("The service tree exports no callable operations.", files[0]));
  }
  const types = shapes.document();
  if (diagnostics.length > 0) return { operations, types, diagnostics, contract: null, client: null };
  const document = {
    format: serviceContractFormat,
    protocol_version: serviceProtocolVersion,
    compiler_version: pinnedScriptcVersion(),
    deterministic: false,
    packages,
    types,
    operations,
  };
  return {
    operations,
    types,
    diagnostics,
    contract: `${JSON.stringify(document, null, 2)}\n`,
    client: emitServiceClientDocument(document),
  };
}

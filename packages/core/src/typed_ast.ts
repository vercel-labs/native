// The TypedAst seam — the ONLY file that imports the type-checker provider.
//
// The transpiler needs resolved types (union discrimination, literal types,
// readonly-ness, symbol resolution, contextual types) but must not couple to
// a particular checker API: today the provider is the `@typescript/typescript6`
// compat package (same checker semantics as the author-facing TS7 tsc by
// upstream design); when the stable Go-native programmatic API ships, only
// this adapter changes.
//
// Surface discipline:
//   - Syntax (node kinds, tree walking) passes through as `ts` — syntax trees
//     are structurally identical across the two providers by design.
//   - Every TYPE question goes through the named queries on `TypedAst` below.
//     Checker/emitter code never touches `program.getTypeChecker()` directly.

import tsImpl from "@typescript/typescript6";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ts = tsImpl;

/// Absolute path of the SDK directory this package ships (sdk/core.ts and
/// the transpiled library modules beside it).
export const sdkModuleDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "sdk");

/// Absolute path of the SDK module the subset program maps the
/// "@native-sdk/core" specifier onto (the `Cmd` surface authors import).
/// This module is INTRINSIC: the transpiler lowers references to it onto
/// the rt kernel and never emits its code.
export const sdkCoreModulePath = path.join(sdkModuleDir, "core.ts");

/// The SDK LIBRARY modules an app core may import by published name. Unlike
/// sdk/core.ts these are ordinary subset TypeScript, transpiled into the
/// emitted core when (and only when) imported — the module-granular
/// tree-shake. Validated once in this package's CI and re-checked at app
/// build time (the re-check is cheap: tsc already parses the file for the
/// program, and a diagnostic pointing into the SDK is an SDK bug by
/// definition).
export const sdkLibraryModules: ReadonlyMap<string, string> = new Map([
  ["@native-sdk/core/text", path.join(sdkModuleDir, "text.ts")],
  ["@native-sdk/core/events", path.join(sdkModuleDir, "events.ts")],
]);

/// The ambient byte-text method surface (declaration merging into
/// lib.esnext's Uint8Array): part of every core's PROGRAM (an extra root
/// file, never an importable module), so `draft.toUpperCase()` typechecks
/// in core compilation exactly as the emitted rt helpers and the devhost
/// polyfill run it. Outside a core program the methods do not exist —
/// the surface is core-only by construction.
export const bytesTextMethodsDts = path.join(sdkModuleDir, "bytes_text_methods.d.ts");
export type Node = tsImpl.Node;
export type SourceFile = tsImpl.SourceFile;
export type Symbol = tsImpl.Symbol;
export type Type = tsImpl.Type;
export type Declaration = tsImpl.Declaration;

/// The compiler options every app core is checked with (the shipped tsconfig,
/// spec section 6). Stricter than or equal to TS7's hardened defaults —
/// except `useUnknownInCatchVariables` (see below), where the subset checker
/// itself is the stricter authority — so the 6-to-7 provider swap changes no
/// acceptance decision.
export function subsetCompilerOptions(): tsImpl.CompilerOptions {
  return {
    strict: true,
    // The one strict-family knob turned OFF: the subset's own checker types
    // a `catch (e)` binding as the core's thrown union (collected from the
    // actual `throw` sites) and validates every use against it, so kind
    // tests narrow with no `as` ceremony — `unknown` would demand the
    // ceremony back while teaching nothing the thrown-shape rules don't.
    useUnknownInCatchVariables: false,
    target: tsImpl.ScriptTarget.ESNext,
    module: tsImpl.ModuleKind.ESNext,
    moduleResolution: tsImpl.ModuleResolutionKind.Bundler,
    lib: ["lib.esnext.d.ts"],
    types: [],
    // The SDK modules ship inside this package; app cores import them by
    // their published names. Absolute mappings so entry files anywhere
    // (tmp dirs, workspaces) resolve the same modules.
    paths: {
      "@native-sdk/core": [sdkCoreModulePath.replace(/\.ts$/, "")],
      ...Object.fromEntries(
        [...sdkLibraryModules].map(([name, p]) => [name, [p.replace(/\.ts$/, "")]]),
      ),
    },
    // Relative imports inside src/ are spelled with their real filename
    // ("./parsers.ts") because the same core runs unmodified under node,
    // whose loader resolves real files, never bare stems.
    allowImportingTsExtensions: true,
    verbatimModuleSyntax: true,
    exactOptionalPropertyTypes: true,
    noFallthroughCasesInSwitch: true,
    isolatedModules: true,
    noEmit: true,
    skipLibCheck: true,
  };
}

export interface UnionMemberInfo {
  /// Discriminant literal of this member for the given tag property, e.g.
  /// "insert_text" for { kind: "insert_text", ... }.
  readonly tag: string;
  /// Non-tag properties, in declaration order.
  readonly fields: readonly PropInfo[];
  readonly declaration: tsImpl.TypeNode;
}

export interface PropInfo {
  readonly name: string;
  readonly optional: boolean;
  readonly readonly: boolean;
  readonly typeNode: tsImpl.TypeNode | undefined;
  readonly declaration: tsImpl.Declaration;
}

export class TypedAst {
  readonly program: tsImpl.Program;
  private readonly checker: tsImpl.TypeChecker;

  constructor(program: tsImpl.Program) {
    this.program = program;
    this.checker = program.getTypeChecker();
  }

  /// Author-facing acceptance: the provider's full diagnostics for a file.
  fileDiagnostics(file: SourceFile): readonly tsImpl.Diagnostic[] {
    return tsImpl.getPreEmitDiagnostics(this.program, file);
  }

  /// Symbol resolution: which declaration an identifier means.
  symbolOf(node: Node): Symbol | undefined {
    return this.checker.getSymbolAtLocation(node);
  }

  /// The canonical declaration of an identifier/expression's symbol, with
  /// alias (import) indirection resolved.
  declarationOf(node: Node): Declaration | undefined {
    let sym = this.checker.getSymbolAtLocation(node);
    if (!sym) return undefined;
    if (sym.flags & tsImpl.SymbolFlags.Alias) sym = this.checker.getAliasedSymbol(sym);
    return sym.declarations?.[0];
  }

  /// The underlying declaration an export specifier binds (`export { a }`,
  /// `export { a as b }`, `export { x } from "./m.ts"` alike), with alias
  /// indirection resolved to the real declaration — the flat-namespace
  /// target the exported name binds over.
  exportSpecifierTarget(spec: tsImpl.ExportSpecifier): Declaration | undefined {
    let sym = this.checker.getSymbolAtLocation(spec.propertyName ?? spec.name);
    if (!sym) return undefined;
    if (sym.flags & tsImpl.SymbolFlags.Alias) sym = this.checker.getAliasedSymbol(sym);
    return (sym.valueDeclaration as Declaration | undefined) ?? sym.declarations?.[0];
  }

  /// Resolved type of an expression position.
  typeOf(node: Node): Type {
    return this.checker.getTypeAtLocation(node);
  }

  /// The VALUE side of a shorthand property (`{ x }` reads the local/param
  /// `x`): getSymbolAtLocation on the name yields the property symbol, so
  /// the value symbol needs its own query.
  shorthandValueDeclaration(node: tsImpl.ShorthandPropertyAssignment): Declaration | undefined {
    const sym = this.checker.getShorthandAssignmentValueSymbol(node);
    return sym?.declarations?.[0];
  }

  /// Resolved (contextual) type of an expression — the type the surrounding
  /// position expects, e.g. the annotated interface for an object literal.
  contextualTypeOf(expr: tsImpl.Expression): Type | undefined {
    return this.checker.getContextualType(expr);
  }

  typeToString(type: Type): string {
    return this.checker.typeToString(type);
  }

  /// True when the type contains `null` or `undefined` as a union member.
  isNullable(type: Type): boolean {
    if (!type.isUnion()) return (type.flags & (tsImpl.TypeFlags.Null | tsImpl.TypeFlags.Undefined)) !== 0;
    return type.types.some((t) => (t.flags & (tsImpl.TypeFlags.Null | tsImpl.TypeFlags.Undefined)) !== 0);
  }

  /// Which JS empties (null / undefined) the expression's resolved type
  /// carries. The native optional folds both into one empty, so an empty
  /// TEST (`=== null`, `=== undefined`) is only emittable when the value
  /// carries exactly the tested empty — the emitter's R7c check.
  emptiesOf(node: Node): { null: boolean; undefined: boolean } {
    const t = this.checker.getTypeAtLocation(node);
    const members = t.isUnion() ? t.types : [t];
    return {
      null: members.some((m) => (m.flags & tsImpl.TypeFlags.Null) !== 0),
      undefined: members.some((m) => (m.flags & tsImpl.TypeFlags.Undefined) !== 0),
    };
  }

  /// True when a callback's resolved return type is boolean-only (every
  /// union member boolean-like). The NS1023 comparator check: a boolean
  /// where JS expects a sign is wrong under node too, so it is taught.
  arrowReturnsBoolean(fn: tsImpl.ArrowFunction | tsImpl.FunctionExpression | tsImpl.FunctionDeclaration): boolean {
    const t = this.checker.getTypeAtLocation(fn);
    const sigs = t.getCallSignatures();
    if (sigs.length === 0) return false;
    const booleanLike = tsImpl.TypeFlags.Boolean | tsImpl.TypeFlags.BooleanLiteral;
    return sigs.every((s) => {
      const ret = s.getReturnType();
      const members = ret.isUnion() ? ret.types : [ret];
      return members.every((m) => (m.flags & booleanLike) !== 0);
    });
  }

  /// True when the expression's resolved type is Uint8Array (through
  /// aliases like `type Bytes = Uint8Array`).
  isBytesTyped(expr: tsImpl.Expression): boolean {
    const t = this.checker.getTypeAtLocation(expr);
    return t.symbol?.name === "Uint8Array";
  }

  /// Literal value at a type position (string/number literal types), else null.
  literalValue(type: Type): string | number | null {
    if (type.isStringLiteral()) return type.value;
    if (type.isNumberLiteral()) return type.value;
    return null;
  }

  /// Union members of a discriminated union type node, with the discriminant
  /// literal of each member for the given tag property. Returns null when the
  /// node is not a union of object types each carrying a literal tag.
  discriminatedUnionMembers(node: tsImpl.TypeNode, tagName: string): UnionMemberInfo[] | null {
    if (!tsImpl.isUnionTypeNode(node)) return null;
    const members: UnionMemberInfo[] = [];
    for (const member of node.types) {
      if (!tsImpl.isTypeLiteralNode(member)) return null;
      let tag: string | null = null;
      const fields: PropInfo[] = [];
      for (const prop of member.members) {
        if (!tsImpl.isPropertySignature(prop) || !prop.name || !tsImpl.isIdentifier(prop.name)) return null;
        const name = prop.name.text;
        if (name === tagName) {
          if (!prop.type) return null;
          const t = this.checker.getTypeFromTypeNode(prop.type);
          const value = this.literalValue(t);
          if (typeof value !== "string") return null;
          tag = value;
          continue;
        }
        fields.push({
          name,
          optional: prop.questionToken !== undefined,
          readonly: hasReadonlyModifier(prop),
          typeNode: prop.type,
          declaration: prop,
        });
      }
      if (tag === null) return null;
      members.push({ tag, fields, declaration: member });
    }
    return members;
  }

  /// String-literal union members of a type alias node (e.g. Filter), in
  /// declaration order; null when the node is not a pure string-literal union.
  stringLiteralUnionMembers(node: tsImpl.TypeNode): string[] | null {
    if (!tsImpl.isUnionTypeNode(node)) return null;
    const out: string[] = [];
    for (const member of node.types) {
      if (!tsImpl.isLiteralTypeNode(member) || !tsImpl.isStringLiteral(member.literal)) return null;
      out.push(member.literal.text);
    }
    return out;
  }

  /// Number-literal union members (e.g. 0 | 1 | 2), else null.
  numberLiteralUnionMembers(node: tsImpl.TypeNode): number[] | null {
    if (!tsImpl.isUnionTypeNode(node)) return null;
    const out: number[] = [];
    for (const member of node.types) {
      if (!tsImpl.isLiteralTypeNode(member) || !tsImpl.isNumericLiteral(member.literal)) return null;
      out.push(Number(member.literal.text));
    }
    return out;
  }

  /// Properties of an interface declaration, in declaration order.
  propsOfInterface(decl: tsImpl.InterfaceDeclaration): PropInfo[] {
    const out: PropInfo[] = [];
    for (const member of decl.members) {
      if (!tsImpl.isPropertySignature(member) || !member.name || !tsImpl.isIdentifier(member.name)) continue;
      out.push({
        name: member.name.text,
        optional: member.questionToken !== undefined,
        readonly: hasReadonlyModifier(member),
        typeNode: member.type,
        declaration: member,
      });
    }
    return out;
  }

  /// tsc's own assignability relation — thrown values checked against the
  /// core's declared error shape (the catch assertion's type node).
  isAssignableToNode(expr: tsImpl.Expression, typeNode: tsImpl.TypeNode): boolean {
    const src = this.checker.getTypeAtLocation(expr);
    const dst = this.checker.getTypeFromTypeNode(typeNode);
    return this.checker.isTypeAssignableTo(src, dst);
  }

  /// Fields of a data-class declaration (annotated property declarations),
  /// in declaration order — the struct layout `new` constructs.
  propsOfClass(decl: tsImpl.ClassDeclaration): PropInfo[] {
    const out: PropInfo[] = [];
    for (const member of decl.members) {
      if (!tsImpl.isPropertyDeclaration(member) || !member.name || !tsImpl.isIdentifier(member.name)) continue;
      // `static` fields are per-class module consts, never instance layout.
      if ((tsImpl.getModifiers(member) ?? []).some((m) => m.kind === tsImpl.SyntaxKind.StaticKeyword)) continue;
      out.push({
        name: member.name.text,
        optional: member.questionToken !== undefined,
        readonly: hasReadonlyModifier(member),
        typeNode: member.type,
        declaration: member,
      });
    }
    return out;
  }

  /// Const-evaluability: fold an expression of literals and module constants
  /// to a number, else null. This is the transpiler's comptime surface for
  /// numeric module constants.
  constEvalNumber(expr: tsImpl.Expression): number | null {
    if (tsImpl.isNumericLiteral(expr)) return Number(expr.text);
    if (tsImpl.isParenthesizedExpression(expr)) return this.constEvalNumber(expr.expression);
    if (tsImpl.isPrefixUnaryExpression(expr) && expr.operator === tsImpl.SyntaxKind.MinusToken) {
      const inner = this.constEvalNumber(expr.operand);
      return inner === null ? null : -inner;
    }
    if (tsImpl.isBinaryExpression(expr)) {
      const l = this.constEvalNumber(expr.left);
      const r = this.constEvalNumber(expr.right);
      if (l === null || r === null) return null;
      switch (expr.operatorToken.kind) {
        case tsImpl.SyntaxKind.PlusToken: return l + r;
        case tsImpl.SyntaxKind.MinusToken: return l - r;
        case tsImpl.SyntaxKind.AsteriskToken: return l * r;
        case tsImpl.SyntaxKind.SlashToken: return l / r;
        case tsImpl.SyntaxKind.PercentToken: return l % r;
        // The host IS a JS engine, so these fold to their exact JS values
        // (`**` right-associates with the JS pow corners; shifts apply
        // ToInt32/ToUint32 with the count masked & 31).
        case tsImpl.SyntaxKind.AsteriskAsteriskToken: return l ** r;
        case tsImpl.SyntaxKind.LessThanLessThanToken: return l << r;
        case tsImpl.SyntaxKind.GreaterThanGreaterThanToken: return l >> r;
        case tsImpl.SyntaxKind.GreaterThanGreaterThanGreaterThanToken: return l >>> r;
        default: return null;
      }
    }
    // Math.<fn>(consts) folds through the host JS Math — by definition the
    // JS value, NaN/Infinity/-0 corners included.
    if (
      tsImpl.isCallExpression(expr) &&
      tsImpl.isPropertyAccessExpression(expr.expression) &&
      tsImpl.isIdentifier(expr.expression.expression) &&
      expr.expression.expression.text === "Math"
    ) {
      const fn = comptimeMathFns.get(expr.expression.name.text);
      if (!fn) return null;
      const args: number[] = [];
      for (const a of expr.arguments) {
        const v = this.constEvalNumber(a);
        if (v === null) return null;
        args.push(v);
      }
      return fn(...args);
    }
    if (tsImpl.isIdentifier(expr)) {
      // The NaN/Infinity globals (a shadowing declaration in the module
      // itself does not count — same rule as the emitter's `undefined`).
      if (expr.text === "NaN" || expr.text === "Infinity") {
        const decl = this.declarationOf(expr);
        if (!decl || decl.getSourceFile() !== expr.getSourceFile()) {
          return expr.text === "NaN" ? NaN : Infinity;
        }
      }
      const decl = this.declarationOf(expr);
      if (decl && tsImpl.isVariableDeclaration(decl) && decl.initializer &&
          (tsImpl.getCombinedNodeFlags(decl) & tsImpl.NodeFlags.Const) !== 0) {
        return this.constEvalNumber(decl.initializer);
      }
    }
    return null;
  }

  /// Declaration of the property a literal's member assigns to, resolved via
  /// the contextual (expected) type of the enclosing object literal.
  contextualPropDecl(prop: tsImpl.PropertyAssignment): Declaration | undefined {
    const objLit = prop.parent;
    if (!tsImpl.isObjectLiteralExpression(objLit)) return undefined;
    let contextual = this.checker.getContextualType(objLit);
    if (!contextual || !prop.name || !tsImpl.isIdentifier(prop.name)) return undefined;
    // `T | null` contexts: the property lives on the non-null constituent.
    contextual = this.checker.getNonNullableType(contextual);
    // Union contexts (e.g. `Model | [Model, Cmd<Msg>]` return positions):
    // the property lives on whichever constituent carries it.
    if (contextual.isUnion()) {
      for (const member of contextual.types) {
        const sym = member.getProperty(prop.name.text);
        if (sym?.declarations?.[0]) return sym.declarations[0];
      }
      return undefined;
    }
    const sym = contextual.getProperty(prop.name.text);
    return sym?.declarations?.[0];
  }

  /// Generic instantiation sites for a declaration — the monomorphization
  /// worklist. v1 supports non-generic app cores; the query exists so the
  /// seam is complete, and returns the empty list until generics land.
  genericInstantiations(_decl: Declaration): readonly Type[] {
    return [];
  }

  /// The resolved type of a TYPE NODE position (`typeof CONST` queries and
  /// generic-argument type nodes resolve through the checker, never by
  /// re-implementing its inference).
  typeFromTypeNode(node: tsImpl.TypeNode): Type {
    return this.checker.getTypeFromTypeNode(node);
  }

  /// The RESOLVED type arguments of a call to a generic function — tsc's
  /// own signature resolution (explicit arguments and inferred ones alike),
  /// aligned with the callee's type-parameter list. Undefined when the call
  /// does not resolve or resolves without instantiation.
  resolvedCallTypeArguments(call: tsImpl.CallExpression): readonly Type[] | undefined {
    const sig = this.checker.getResolvedSignature(call);
    if (!sig) return undefined;
    return this.checker.getTypeArgumentsForResolvedSignature(sig);
  }

  /// Type arguments of a resolved reference type (e.g. `readonly T[]`'s
  /// element, a generic interface instantiation's arguments).
  typeArgumentsOf(type: Type): readonly Type[] {
    if ((type.flags & tsImpl.TypeFlags.Object) === 0) return [];
    if (((type as tsImpl.ObjectType).objectFlags & tsImpl.ObjectFlags.Reference) === 0) return [];
    return this.checker.getTypeArguments(type as tsImpl.TypeReference);
  }

  isArrayLikeType(type: Type): boolean {
    return this.checker.isArrayType(type);
  }
}

/// The Math functions the transpiler folds at compile time (the emitter's
/// v1 Math surface; Math.random is banned by NS1005 and never reaches here).
const comptimeMathFns = new Map<string, (...args: number[]) => number>([
  ["floor", Math.floor],
  ["ceil", Math.ceil],
  ["trunc", Math.trunc],
  ["abs", Math.abs],
  ["sign", Math.sign],
  ["sqrt", Math.sqrt],
  ["round", Math.round],
  ["min", Math.min],
  ["max", Math.max],
]);

export function hasReadonlyModifier(node: tsImpl.PropertySignature | tsImpl.PropertyDeclaration): boolean {
  return node.modifiers?.some((m) => m.kind === tsImpl.SyntaxKind.ReadonlyKeyword) ?? false;
}

export function hasExportModifier(node: tsImpl.Node): boolean {
  const mods = (node as { modifiers?: readonly tsImpl.ModifierLike[] }).modifiers;
  return mods?.some((m) => m.kind === tsImpl.SyntaxKind.ExportKeyword) ?? false;
}

/// One VALUE binding an export list creates: `export { a }` binds `a`,
/// `export { a as b }` binds `b`, and `export { x } from "./m.ts"` binds `x`
/// over another module's declaration. Type-only statements and specifiers
/// (`export type { T }`, `export { type T }`) never appear here — they erase.
export interface ExportListBinding {
  /// The name the binding is exported under (`b` in `export { a as b }`).
  readonly exportedName: string;
  /// The exported-name node, for diagnostics.
  readonly nameNode: tsImpl.ModuleExportName;
  readonly spec: tsImpl.ExportSpecifier;
  /// Whether the exported name differs from the target declaration's own
  /// name (a renamed export binds a NEW name over the declaration).
  readonly renamed: boolean;
  /// Whether the list re-exports from another module (`export ... from`).
  readonly reExport: boolean;
  /// The resolved underlying declaration, alias indirection included; the
  /// checker teaches when this is missing or outside the core's modules.
  readonly target: Declaration | undefined;
}

/// The value bindings of every export list in a file, in source order.
export function exportListBindings(tast: TypedAst, file: SourceFile): ExportListBinding[] {
  const out: ExportListBinding[] = [];
  for (const stmt of file.statements) {
    if (!tsImpl.isExportDeclaration(stmt) || stmt.isTypeOnly) continue;
    if (!stmt.exportClause || !tsImpl.isNamedExports(stmt.exportClause)) continue;
    for (const spec of stmt.exportClause.elements) {
      if (spec.isTypeOnly) continue;
      const target = tast.exportSpecifierTarget(spec);
      const targetName =
        target && tsImpl.isFunctionDeclaration(target)
          ? target.name?.text
          : target && (tsImpl.isVariableDeclaration(target) || tsImpl.isClassDeclaration(target)) && target.name && tsImpl.isIdentifier(target.name)
            ? target.name.text
            : target && (tsImpl.isInterfaceDeclaration(target) || tsImpl.isTypeAliasDeclaration(target))
              ? target.name.text
              : undefined;
      const exportedName = spec.name.text;
      out.push({
        exportedName,
        nameNode: spec.name,
        spec,
        renamed: targetName !== undefined && targetName !== exportedName,
        reExport: stmt.moduleSpecifier !== undefined,
        target,
      });
    }
  }
  return out;
}

export function lineColumn(file: SourceFile, pos: number): { line: number; column: number } {
  const lc = file.getLineAndCharacterOfPosition(pos);
  return { line: lc.line + 1, column: lc.character + 1 };
}

/// Build a checked program rooted at the app-core entry file. tsc resolves
/// the whole import graph from it (relative modules under src/, the SDK
/// modules by their published names), so a multi-file core needs no extra
/// root names; modules.ts validates the graph's boundaries first.
export function createSubsetProgram(entry: string): tsImpl.Program {
  return tsImpl.createProgram([entry, bytesTextMethodsDts], subsetCompilerOptions());
}

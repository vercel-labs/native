// The subset checker: everything tsc cannot enforce, with teaching errors.
//
// Layering (spec section 5): tsc's own readonly/type errors fire first; this
// checker adds the subset rules on the typed AST; the emitter re-derives every
// rule during emission and turns any gap into a loud internal error.

import { ts, TypedAst, lineColumn, hasExportModifier, exportListBindings, type ExportListBinding } from "./typed_ast.ts";
import { makeDiagnostic, type SubsetDiagnostic, type RuleId } from "./diagnostics.ts";
import type { TypeTable } from "./types.ts";
import {
  arrayOwnership,
  constFunctionValue,
  functionValueLegality,
  instanceOwnership,
  mutatingArrayMethods,
  ownedMutatingMethods,
  valuePositionStep,
} from "./ownership.ts";

/// The VariableDeclaration a function value is const-bound to (through
/// paren/as wrappers), else null.
function owningConstDecl(fn: ts.Node): ts.VariableDeclaration | null {
  let cur: ts.Node = fn;
  while (ts.isParenthesizedExpression(cur.parent) || ts.isAsExpression(cur.parent) || ts.isSatisfiesExpression(cur.parent)) {
    cur = cur.parent;
  }
  return ts.isVariableDeclaration(cur.parent) && cur.parent.initializer !== undefined ? cur.parent : null;
}

const stringObservers = new Set(["charCodeAt", "codePointAt", "charAt", "at"]);

/// The STAYS-OUT tail of the byte-text method surface (declared ambient on
/// Uint8Array only so these spellings reach a teaching here instead of a
/// bare tsc "property does not exist"). Each entry names its rule and why:
/// UTF-16 code units and normalization (NS1060), ambient locale state
/// (NS1005), regex engines (NS1040).
const bytesTextStaysOut = new Map<string, { readonly id: RuleId; readonly site: string }>([
  ["charCodeAt", { id: "NS1060", site: "`.charCodeAt` reads UTF-16 code units, which byte text does not have — read the byte (`b[i]`, `.at(i)`)." }],
  ["charAt", { id: "NS1060", site: "`.charAt` reads UTF-16 code units, which byte text does not have — slice the byte range (`.subarray(i, j)`)." }],
  ["codePointAt", { id: "NS1060", site: "`.codePointAt` walks UTF-16 code-unit indices, which byte text does not have — read bytes, or decode where the host renders." }],
  ["normalize", { id: "NS1060", site: "`.normalize` applies Unicode normalization forms, a table set with no place in the byte model — compare exact bytes, or normalize at the host edge." }],
  ["replace", { id: "NS1060", site: "`.replace` is not in v1 — rebuild the text with `.split(sep)`, slices, and a push-builder of parts." }],
  ["replaceAll", { id: "NS1060", site: "`.replaceAll` is not in v1 — rebuild the text with `.split(sep)`, slices, and a push-builder of parts." }],
  ["localeCompare", { id: "NS1005", site: "`.localeCompare` orders by the ambient locale (use `orderIgnoreCase` from \"@native-sdk/core/text\", or compare bytes)." }],
  ["toLocaleUpperCase", { id: "NS1005", site: "`.toLocaleUpperCase` cases by the ambient locale (`.toUpperCase()` is the locale-free simple mapping)." }],
  ["toLocaleLowerCase", { id: "NS1005", site: "`.toLocaleLowerCase` cases by the ambient locale (`.toLowerCase()` is the locale-free simple mapping)." }],
  ["match", { id: "NS1040", site: "`.match` takes a regular expression." }],
  ["matchAll", { id: "NS1040", site: "`.matchAll` takes a regular expression." }],
  ["search", { id: "NS1040", site: "`.search` takes a regular expression." }],
]);

const ambientGlobals = new Set(["Date", "console", "fetch", "setTimeout", "setInterval", "performance", "process", "globalThis"]);

/// Every assignment operator, `=` and the compound family alike — for the
/// NS1043 statement-position rule (the emitter maps them as statements).
const compoundAndPlainAssignmentOps = new Set<ts.SyntaxKind>([
  ts.SyntaxKind.EqualsToken,
  ts.SyntaxKind.PlusEqualsToken,
  ts.SyntaxKind.MinusEqualsToken,
  ts.SyntaxKind.AsteriskEqualsToken,
  ts.SyntaxKind.SlashEqualsToken,
  ts.SyntaxKind.PercentEqualsToken,
  ts.SyntaxKind.AsteriskAsteriskEqualsToken,
  ts.SyntaxKind.AmpersandEqualsToken,
  ts.SyntaxKind.BarEqualsToken,
  ts.SyntaxKind.CaretEqualsToken,
  ts.SyntaxKind.LessThanLessThanEqualsToken,
  ts.SyntaxKind.GreaterThanGreaterThanEqualsToken,
  ts.SyntaxKind.GreaterThanGreaterThanGreaterThanEqualsToken,
  ts.SyntaxKind.AmpersandAmpersandEqualsToken,
  ts.SyntaxKind.BarBarEqualsToken,
  ts.SyntaxKind.QuestionQuestionEqualsToken,
]);

/// An arrow inside a call's argument expression — the inline-callback
/// position (array methods), reached through literal wrappers so more
/// specific teachings (e.g. NS1027 on routing objects) stay in charge.
/// Everything else is a STORED function value (NS1046).
function isCallArgument(fn: ts.ArrowFunction): boolean {
  let cur: ts.Node = fn;
  for (;;) {
    const p: ts.Node = cur.parent;
    if (ts.isCallExpression(p) && (p.arguments as readonly ts.Node[]).includes(cur)) return true;
    if (
      ts.isParenthesizedExpression(p) ||
      ts.isPropertyAssignment(p) ||
      ts.isObjectLiteralExpression(p) ||
      ts.isArrayLiteralExpression(p) ||
      ts.isAsExpression(p) ||
      ts.isSatisfiesExpression(p)
    ) {
      cur = p;
      continue;
    }
    return false;
  }
}

/// Whether an expression sits inside a classic for-loop's incrementor slot
/// (walking up through comma chains and parens) — the one home for comma
/// sequences and statement-position assignment forms in expression syntax.
function inForIncrementor(node: ts.Expression): boolean {
  let cur: ts.Node = node;
  for (;;) {
    const p: ts.Node = cur.parent;
    if (ts.isForStatement(p) && p.incrementor === cur) return true;
    const chains =
      ts.isParenthesizedExpression(p) ||
      (ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.CommaToken);
    if (!chains) return false;
    cur = p;
  }
}

/// `xs.push(...)` / `xs.unshift(...)` / `xs.splice(...)` — spread arguments
/// there keep the emitter's tailored teaching (one element per iteration)
/// instead of the arity rule.
function isMutatingAppendCall(call: ts.CallExpression): boolean {
  return (
    ts.isPropertyAccessExpression(call.expression) &&
    ["push", "unshift", "splice"].includes(call.expression.name.text)
  );
}

/// `for (const [i, x] of xs.entries())` — the entries() teach (use the
/// classic loop) is more useful than the destructuring rule for this shape.
function isEntriesLoopBinding(pattern: ts.ArrayBindingPattern): boolean {
  const decl = pattern.parent;
  if (!ts.isVariableDeclaration(decl) || !ts.isVariableDeclarationList(decl.parent)) return false;
  const loop = decl.parent.parent;
  if (!ts.isForOfStatement(loop)) return false;
  let iter = loop.expression;
  while (ts.isParenthesizedExpression(iter)) iter = iter.expression;
  return (
    ts.isCallExpression(iter) &&
    ts.isPropertyAccessExpression(iter.expression) &&
    iter.expression.name.text === "entries"
  );
}

/// The core's single thrown shape (NS1057): every `throw` carries a value
/// of one type, because the value unwinds through one native payload slot.
/// The shape comes from catch assertions (`const err = e as ParseError;`)
/// when any exist — all must agree — else structurally from the throw
/// expressions themselves (each must resolve to the same named table type,
/// number, boolean, or bytes). Shared by the checker (teaching) and the
/// emitter (layer-3 re-derivation + the slot's emitted type).
export interface ThrownShapeResult {
  readonly shape: import("./types.ts").ZType | null;
  /// The declared type node the shape came from (a catch assertion), used
  /// for tsc-assignability checks on every throw; null when structural.
  readonly shapeNode: ts.TypeNode | null;
  /// True when `shape` is the checker-SYNTHESIZED union of several distinct
  /// thrown shapes (registered in the table under THROWN_UNION_NAME so the
  /// whole narrowing pipeline sees an ordinary union); false when one shape
  /// — or a DECLARED union whose arms equal the thrown set — carries it.
  readonly synthesized: boolean;
  readonly problems: readonly { readonly node: ts.Node; readonly msg: string }[];
}

/// The emitted name of the synthesized thrown union (heterogeneous throws
/// with no declared union matching the thrown set). Reserved alongside the
/// `Thrown` error set and the `thrown_payload` slot.
export const THROWN_UNION_NAME = "ThrownPayload";

/// The kind-tagged arm(s) a thrown shape contributes to the core's thrown
/// union: a registered union contributes its arms; an interface with a
/// string-literal `kind` field contributes one arm (its other fields as the
/// payload). Anything else cannot join a heterogeneous thrown set.
export function thrownArmsOfShape(
  ty: import("./types.ts").ZType,
  table: TypeTable,
): readonly { readonly tag: string; readonly fields: readonly import("./types.ts").ZField[] }[] | null {
  if (ty.k === "union") return table.unions.get(ty.name)?.arms ?? null;
  if (ty.k !== "struct") return null;
  const info = table.structs.get(ty.name);
  if (!info) return null;
  const kindField = info.fields.find((f) => f.tsName === "kind");
  if (!kindField) return null;
  const decl = kindField.decl;
  if (!ts.isPropertySignature(decl) || !decl.type) return null;
  if (!ts.isLiteralTypeNode(decl.type) || !ts.isStringLiteral(decl.type.literal)) return null;
  return [{ tag: decl.type.literal.text, fields: info.fields.filter((f) => f.tsName !== "kind") }];
}

export function thrownShapeOf(
  tast: TypedAst,
  table: TypeTable,
  files: readonly ts.SourceFile[],
): ThrownShapeResult {
  const throws: ts.ThrowStatement[] = [];
  const catchVars = new Set<ts.Node>();
  const assertions: ts.AsExpression[] = [];
  const collect = (n: ts.Node): void => {
    if (ts.isThrowStatement(n)) throws.push(n);
    if (ts.isCatchClause(n) && n.variableDeclaration && ts.isIdentifier(n.variableDeclaration.name)) {
      catchVars.add(n.variableDeclaration);
    }
    ts.forEachChild(n, collect);
  };
  for (const f of files) collect(f);
  if (throws.length === 0 && catchVars.size === 0) return { shape: null, shapeNode: null, synthesized: false, problems: [] };
  const findAssertions = (n: ts.Node): void => {
    if (ts.isAsExpression(n) && ts.isIdentifier(n.expression)) {
      const d = tast.declarationOf(n.expression);
      if (d && catchVars.has(d)) assertions.push(n);
    }
    ts.forEachChild(n, findAssertions);
  };
  for (const f of files) findAssertions(f);

  const canonRef = (t: import("./types.ts").ZType): string =>
    table.zigTypeRef(t.k === "number" ? { k: "f64" } : t);
  const problems: { node: ts.Node; msg: string }[] = [];

  /// A throw expression's shape: an assertion resolves its named type; an
  /// identifier resolves its declared/inferred named type; numbers and
  /// booleans and bytes resolve directly. A rethrow of the catch binding
  /// is shape-neutral (it IS the slot).
  const typeOfThrow = (e: ts.Expression): import("./types.ts").ZType | "rethrow" | null => {
    let cur = e;
    while (ts.isParenthesizedExpression(cur)) cur = cur.expression;
    if (ts.isIdentifier(cur)) {
      const d = tast.declarationOf(cur);
      if (d && catchVars.has(d)) return "rethrow";
    }
    if (ts.isAsExpression(cur) || ts.isSatisfiesExpression(cur)) {
      const t = table.resolveTypeNode(cur.type);
      return t.k === "void" ? null : t;
    }
    const flags = tast.typeOf(cur).flags;
    if ((flags & (ts.TypeFlags.Number | ts.TypeFlags.NumberLiteral)) !== 0) return { k: "f64" };
    if ((flags & (ts.TypeFlags.Boolean | ts.TypeFlags.BooleanLiteral)) !== 0) return { k: "bool" };
    const str = tast.typeToString(tast.typeOf(cur));
    if (str === "Uint8Array" || str.startsWith("Uint8Array<")) return { k: "bytes" };
    return table.resolveName(str);
  };

  // Structural pre-pass: the DISTINCT shapes the core actually throws.
  // Two or more distinct shapes take the heterogeneous path — the thrown
  // union — and the single-shape path below stays byte-for-byte what it
  // always was.
  const distinct = new Map<string, { readonly ty: import("./types.ts").ZType; readonly node: ts.Node }>();
  for (const t of throws) {
    const ty = typeOfThrow(t.expression);
    if (ty === "rethrow" || ty === null) continue;
    const key = canonRef(ty);
    if (!distinct.has(key)) distinct.set(key, { ty, node: t });
  }
  if (distinct.size >= 2) {
    return thrownUnionOf(table, distinct, throws, assertions, typeOfThrow, canonRef, problems);
  }

  let shape: import("./types.ts").ZType | null = null;
  let shapeNode: ts.TypeNode | null = null;
  for (const a of assertions) {
    const t = table.resolveTypeNode(a.type);
    if (t.k === "void") {
      problems.push({ node: a, msg: `the catch assertion's type does not resolve to a subset shape.` });
      continue;
    }
    if (shape === null) {
      shape = t;
      shapeNode = a.type;
    } else if (canonRef(shape) !== canonRef(t)) {
      problems.push({
        node: a,
        msg: `this catch narrows to \`${a.type.getText()}\`, but the core's error shape is already \`${shapeNode?.getText() ?? canonRef(shape)}\`.`,
      });
    }
  }

  for (const t of throws) {
    const e = t.expression;
    if (shapeNode !== null) {
      let cur = e;
      while (ts.isParenthesizedExpression(cur)) cur = cur.expression;
      if (ts.isIdentifier(cur)) {
        const d = tast.declarationOf(cur);
        if (d && catchVars.has(d)) continue; // rethrow
      }
      if (!tast.isAssignableToNode(e, shapeNode)) {
        problems.push({
          node: t,
          msg: `this \`throw\` does not carry the core's error shape \`${shapeNode.getText()}\` (tsc says the value is not assignable to it).`,
        });
      }
      continue;
    }
    const ty = typeOfThrow(e);
    if (ty === "rethrow") continue;
    if (ty === null) {
      problems.push({
        node: t,
        msg: `the thrown value's shape does not resolve — throw a named value (\`const err: ParseError = {...}; throw err;\` or \`throw {...} as ParseError\`).`,
      });
      continue;
    }
    if (shape === null) shape = ty;
    else if (canonRef(shape) !== canonRef(ty)) {
      problems.push({
        node: t,
        msg: `this \`throw\` carries \`${canonRef(ty)}\`, but the core already throws \`${canonRef(shape)}\`.`,
      });
    }
  }
  if (shape !== null && shape.k === "number") shape = { k: "f64" };
  return { shape, shapeNode, synthesized: false, problems };
}

/// The heterogeneous path: merge every distinct thrown shape's kind-tagged
/// arms into ONE union — a declared union whose arms equal the merged set
/// when one exists, else a synthesized union registered in the table under
/// THROWN_UNION_NAME. Catch assertions must name that union (arm shapes
/// narrow with kind tests, not `as`).
function thrownUnionOf(
  table: TypeTable,
  distinct: ReadonlyMap<string, { readonly ty: import("./types.ts").ZType; readonly node: ts.Node }>,
  throws: readonly ts.ThrowStatement[],
  assertions: readonly ts.AsExpression[],
  typeOfThrow: (e: ts.Expression) => import("./types.ts").ZType | "rethrow" | null,
  canonRef: (t: import("./types.ts").ZType) => string,
  problems: { node: ts.Node; msg: string }[],
): ThrownShapeResult {
  type Arm = { readonly tag: string; readonly fields: readonly import("./types.ts").ZField[] };
  const arms: Arm[] = [];
  const tagOwner = new Map<string, string>();
  for (const [key, { ty, node }] of distinct) {
    const memberArms = thrownArmsOfShape(ty, table);
    if (memberArms === null) {
      problems.push({
        node,
        msg: `this \`throw\` carries \`${key}\`, which cannot join the core's thrown union — heterogeneous throws narrow by \`kind\`, so give each thrown value a kind-discriminated record shape (an interface with a string-literal \`kind\` field, or a \`kind\`-discriminated union).`,
      });
      continue;
    }
    for (const arm of memberArms) {
      const owner = tagOwner.get(arm.tag);
      if (owner !== undefined) {
        // The same tag from two member shapes is ONE arm when the payloads
        // agree (a shape overlapping a declared union's arm); different
        // payloads under one tag could never be told apart in a catch.
        const prior = arms.find((a) => a.tag === arm.tag);
        const samePayload =
          prior !== undefined &&
          prior.fields.length === arm.fields.length &&
          prior.fields.every((f, i) => arm.fields[i].tsName === f.tsName && canonRef(arm.fields[i].type) === canonRef(f.type));
        if (owner !== key && !samePayload) {
          problems.push({
            node,
            msg: `thrown shapes \`${owner}\` and \`${key}\` both carry kind "${arm.tag}" with different payloads — a catch could not tell them apart; give each shape its own tag.`,
          });
        }
        continue;
      }
      tagOwner.set(arm.tag, key);
      arms.push(arm);
    }
  }
  // Unresolvable throws still teach the naming fix.
  for (const t of throws) {
    if (typeOfThrow(t.expression) === null) {
      problems.push({
        node: t,
        msg: `the thrown value's shape does not resolve — throw a named value (\`const err: ParseError = {...}; throw err;\` or \`throw {...} as ParseError\`).`,
      });
    }
  }

  // A declared union whose arm set equals the merged set IS the thrown
  // union (assertions may name it; nothing synthesizes).
  const armsEqual = (a: readonly Arm[], b: readonly Arm[]): boolean => {
    if (a.length !== b.length) return false;
    return a.every((arm) => {
      const other = b.find((x) => x.tag === arm.tag);
      if (!other || other.fields.length !== arm.fields.length) return false;
      return arm.fields.every(
        (f, i) => other.fields[i].tsName === f.tsName && canonRef(other.fields[i].type) === canonRef(f.type),
      );
    });
  };
  let name: string | null = null;
  let synthesized = false;
  for (const info of table.unions.values()) {
    if (info.name === THROWN_UNION_NAME) continue;
    if (armsEqual(info.arms, arms)) {
      name = info.name;
      break;
    }
  }
  if (name === null) {
    name = THROWN_UNION_NAME;
    synthesized = true;
    if (!table.unions.has(THROWN_UNION_NAME)) {
      // The registered entry is what lets zigTypeRef, kind narrowing, and
      // the switch lowering treat the thrown union as an ordinary union;
      // `decl` is never consulted for it (no source statement matches).
      const anyUnion = [...distinct.values()].find((d) => d.ty.k === "union");
      const decl = (anyUnion ? table.unions.get((anyUnion.ty as { name: string }).name)?.decl : undefined) as ts.TypeAliasDeclaration;
      table.unions.set(THROWN_UNION_NAME, { name: THROWN_UNION_NAME, decl, arms, exported: false });
    }
  }

  for (const a of assertions) {
    const t = table.resolveTypeNode(a.type);
    if (!(t.k === "union" && t.name === name)) {
      problems.push({
        node: a,
        msg: `this catch narrows to \`${a.type.getText()}\`, but the core throws several shapes — test \`kind\` in the catch (\`if (e.kind === ...)\`) instead of asserting one of them.`,
      });
    }
  }

  return { shape: { k: "union", name }, shapeNode: null, synthesized, problems };
}

export interface CheckResult {
  readonly diagnostics: SubsetDiagnostic[];
  /// Teaching notices that do NOT stop the build (today: NS1028, the
  /// not-yet-host-backed persist op). Same shape as diagnostics, surfaced
  /// as warnings by the CLI.
  readonly warnings: SubsetDiagnostic[];
  /// Local names bound to the SDK `Cmd` surface (import from
  /// "@native-sdk/core"). The emitter lowers references through these names
  /// onto the rt command builders.
  readonly cmdNames: Set<string>;
  /// Local names bound to the SDK `Sub` surface, lowered onto the rt
  /// subscription builders the same way.
  readonly subNames: Set<string>;
}

export class SubsetChecker {
  private readonly diagnostics: SubsetDiagnostic[] = [];
  private readonly warnings: SubsetDiagnostic[] = [];
  readonly cmdNames = new Set<string>();
  readonly subNames = new Set<string>();
  /// Local names bound by `import * as ns` over in-graph modules — a fast
  /// pre-filter for the NS1039 bare-alias check (confirmed by symbol).
  private readonly nsAliasNames = new Set<string>();

  private readonly tast: TypedAst;
  private readonly table: TypeTable;
  /// The core's modules in canonical order; files[0] is the entry
  /// (src/core.ts), the one module the entry-point exports may live in.
  private readonly files: readonly ts.SourceFile[];
  private readonly entry: ts.SourceFile;
  private readonly fileSet: Set<ts.SourceFile>;

  constructor(tast: TypedAst, table: TypeTable, files: readonly ts.SourceFile[] | ts.SourceFile) {
    this.tast = tast;
    this.table = table;
    this.files = Array.isArray(files) ? files : [files as ts.SourceFile];
    this.entry = this.files[0];
    this.fileSet = new Set(this.files);
  }

  check(): CheckResult {
    for (const file of this.files) this.findCmdNames(file);
    for (const file of this.files) this.checkModuleShape(file);
    this.checkEntryContract();
    this.checkNameCollisions();
    this.checkModelHoldsData();
    this.checkModelTextIsBytes();
    this.checkCmdPurity();
    this.checkSubPurity();
    this.checkModelBindingSurface();
    this.checkViewUnbound();
    for (const file of this.files) this.walk(file);
    this.checkExceptions();
    return {
      diagnostics: this.diagnostics,
      warnings: this.warnings,
      cmdNames: this.cmdNames,
      subNames: this.subNames,
    };
  }

  private report(id: RuleId, site: string, node: ts.Node): void {
    const file = node.getSourceFile();
    const { line, column } = lineColumn(file, node.getStart());
    this.diagnostics.push(makeDiagnostic(id, site, file.fileName, line, column));
  }

  private warn(id: RuleId, site: string, node: ts.Node): void {
    const file = node.getSourceFile();
    const { line, column } = lineColumn(file, node.getStart());
    this.warnings.push(makeDiagnostic(id, site, file.fileName, line, column));
  }

  // ---------------------------------------------------------- cmd namespace

  /// Local names bound to the SDK `Cmd`/`Sub` exports by an import from
  /// "@native-sdk/core" (usually just `Cmd`/`Sub`; renames are honored).
  private findCmdNames(file: ts.SourceFile): void {
    for (const stmt of file.statements) {
      if (!ts.isImportDeclaration(stmt)) continue;
      const spec = stmt.moduleSpecifier;
      if (!ts.isStringLiteral(spec)) continue;
      if (stmt.importClause?.isTypeOnly) continue;
      const bindings = stmt.importClause?.namedBindings;
      if (spec.text !== "@native-sdk/core") {
        // NS1039 (half 1): `import * as ns` over an in-graph module is the
        // supported dot-syntax alias; record the local name for the
        // bare-value check in walk().
        if (bindings && ts.isNamespaceImport(bindings)) this.nsAliasNames.add(bindings.name.text);
        continue;
      }
      if (bindings && ts.isNamespaceImport(bindings)) {
        // NS1039 (half 2): the intrinsic SDK surface is imported by name —
        // the purity rules (NS1017/NS1025) and the asciiBytes fold recognize
        // the factories by their imported names.
        this.report("NS1039", `\`import * as ${bindings.name.text}\` aliases the intrinsic SDK module.`, bindings);
        continue;
      }
      if (bindings && ts.isNamedImports(bindings)) {
        for (const el of bindings.elements) {
          if ((el.propertyName ?? el.name).text === "Cmd") this.cmdNames.add(el.name.text);
          if ((el.propertyName ?? el.name).text === "Sub") this.subNames.add(el.name.text);
        }
      }
    }
  }

  /// NS1017 — the purity rule: `Cmd` appears in exactly two places. As a
  /// type, in `update`'s or `initialModel`'s return annotation; as a value,
  /// in factory calls inside the command slot of that function's returned
  /// `[model, cmd]` tuple. Anywhere else a command could escape the
  /// dispatch cycle.
  private checkCmdPurity(): void {
    if (this.cmdNames.size === 0) return;
    const visit = (node: ts.Node): void => {
      if (ts.isImportDeclaration(node)) return;
      if (ts.isIdentifier(node) && this.cmdNames.has(node.text) && this.isSdkReference(node)) {
        if (!this.cmdUseIsLegal(node)) {
          this.report("NS1017", `\`${node.getText()}\` puts a Cmd outside update's return path.`, node);
        }
      }
      ts.forEachChild(node, visit);
    };
    for (const file of this.files) visit(file);
  }

  /// NS1025 — the same purity rule for subscriptions: `Sub` appears as a
  /// type in `subscriptions`' return annotation and as factory calls in its
  /// return path, nowhere else.
  private checkSubPurity(): void {
    if (this.subNames.size === 0) return;
    const visit = (node: ts.Node): void => {
      if (ts.isImportDeclaration(node)) return;
      if (ts.isIdentifier(node) && this.subNames.has(node.text) && this.isSdkReference(node)) {
        if (!this.subUseIsLegal(node)) {
          this.report(
            "NS1025",
            `\`${node.getText()}\` puts a Sub outside subscriptions' return path.`,
            node,
          );
        }
      }
      ts.forEachChild(node, visit);
    };
    for (const file of this.files) visit(file);
  }

  /// Whether an identifier refers to an ambient global — i.e. is NOT
  /// shadowed by a declaration in one of the core's own modules (lib.d.ts
  /// declarations do not count as shadowing).
  private isAmbientRef(node: ts.Identifier): boolean {
    const decl = this.tast.declarationOf(node);
    return decl === undefined || !this.fileSet.has(decl.getSourceFile());
  }

  /// A use of the imported name, not e.g. a property called `Cmd` or a
  /// shadowing local (a declaration in any of the core's own modules).
  private isSdkReference(node: ts.Identifier): boolean {
    const parent = node.parent;
    if (ts.isPropertyAccessExpression(parent) && parent.name === node) return false;
    if (ts.isPropertySignature(parent) || ts.isPropertyAssignment(parent)) {
      if (parent.name === node) return false;
    }
    const decl = this.tast.declarationOf(node);
    return decl === undefined || !this.fileSet.has(decl.getSourceFile());
  }

  private cmdUseIsLegal(node: ts.Identifier): boolean {
    // Cmd may ride update's dispatch returns and initialModel's boot pair.
    return this.effectUseIsLegal(node, new Set(["update", "initialModel"]), true);
  }

  private subUseIsLegal(node: ts.Identifier): boolean {
    // Sub values are the whole return value of subscriptions, no tuple.
    return this.effectUseIsLegal(node, new Set(["subscriptions"]), false);
  }

  /// Shared purity shape for the inert-effect surfaces. Type position: the
  /// name inside the return type annotation of one of `fnNames`. Value
  /// position: `X.<factory>` reached from the effect slot of a `return`
  /// directly inside one of `fnNames` (not inside a callback) — the cmd
  /// slot of a returned `[model, cmd]` tuple when `tupleSlot`, else the
  /// whole return expression.
  private effectUseIsLegal(node: ts.Identifier, fnNames: Set<string>, tupleSlot: boolean): boolean {
    // The effect surfaces belong to the ENTRY module's entry points: a
    // dispatch function in an imported file is not the app's (NS1014
    // teaches the export; this keeps a private homonym from smuggling one).
    if (node.getSourceFile() !== this.entry) return false;
    if (ts.isTypeReferenceNode(node.parent) && node.parent.typeName === node) {
      let fn: ts.Node | undefined = node.parent;
      while (fn && !ts.isFunctionDeclaration(fn)) fn = fn.parent;
      if (!fn || !ts.isFunctionDeclaration(fn) || !fnNames.has(fn.name?.text ?? "") || !fn.type) return false;
      return node.getStart() >= fn.type.getStart() && node.getEnd() <= fn.type.getEnd();
    }
    if (!ts.isPropertyAccessExpression(node.parent) || node.parent.expression !== node) return false;
    let cur: ts.Node = node;
    while (cur.parent && !ts.isReturnStatement(cur.parent)) {
      if (
        ts.isFunctionDeclaration(cur.parent) ||
        ts.isArrowFunction(cur.parent) ||
        ts.isFunctionExpression(cur.parent)
      ) {
        return false;
      }
      cur = cur.parent;
    }
    const ret = cur.parent;
    if (!ret || !ts.isReturnStatement(ret)) return false;
    let fn: ts.Node | undefined = ret;
    while (fn && !ts.isFunctionDeclaration(fn) && !ts.isArrowFunction(fn) && !ts.isFunctionExpression(fn)) {
      fn = fn.parent;
    }
    if (!fn || !ts.isFunctionDeclaration(fn) || !fnNames.has(fn.name?.text ?? "")) return false;
    if (!tupleSlot) return true;
    let retExpr = ret.expression;
    while (retExpr && ts.isParenthesizedExpression(retExpr)) retExpr = retExpr.expression;
    if (!retExpr || !ts.isArrayLiteralExpression(retExpr) || retExpr.elements.length !== 2) return false;
    const slot = retExpr.elements[1];
    return node.getStart() >= slot.getStart() && node.getEnd() <= slot.getEnd();
  }

  /// NS1031 — exported single-Model-parameter helpers also emit as Model
  /// declarations markup binds by their own names (`doneCount` →
  /// `{doneCount}`), so each emitted name must be unique across the Model's
  /// fields, the helpers, and the `view_unbound` opt-out declaration.
  private checkModelBindingSurface(): void {
    const model = this.table.structs.get("Model");
    if (!model) return;
    const taken = new Map<string, string>();
    for (const f of model.fields) taken.set(f.zigName, `Model field \`${f.tsName}\``);
    taken.set("view_unbound", "the `view_unbound` opt-out declaration");
    for (const h of this.table.modelHelperDecls()) {
      const holder = taken.get(h.zigName);
      if (holder !== undefined) {
        this.report(
          "NS1031",
          `Exported helper \`${h.name}\` emits the Model declaration \`${h.zigName}\`, which collides with ${holder}.`,
          h.decl.name ?? h.decl,
        );
      }
      taken.set(h.zigName, `exported helper \`${h.name}\``);
    }
  }

  /// NS1032 — `export const viewUnbound = [...] as const`: the dead-state
  /// lint opt-out. Every entry must be a string literal naming a Model
  /// field, an exported model helper, or a Msg kind; the emitter routes the
  /// list into the Model/Msg `view_unbound` declarations `native check`
  /// reads.
  private checkViewUnbound(): void {
    for (const stmt of this.entry.statements) {
      if (!ts.isVariableStatement(stmt)) continue;
      for (const decl of stmt.declarationList.declarations) {
        if (!ts.isIdentifier(decl.name) || decl.name.text !== "viewUnbound") continue;
        if (!decl.initializer) {
          this.report("NS1032", "`viewUnbound` has no initializer.", decl);
          continue;
        }
        let init = decl.initializer;
        while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init)) init = init.expression;
        if (!ts.isArrayLiteralExpression(init)) {
          this.report("NS1032", "`viewUnbound` is not an array literal.", decl);
          continue;
        }
        const fields = new Set((this.table.structs.get("Model")?.fields ?? []).map((f) => f.tsName));
        const helpers = new Set(this.table.modelHelperDecls().map((h) => h.name));
        const kinds = new Set((this.table.unions.get("Msg")?.arms ?? []).map((a) => a.tag));
        for (const el of init.elements) {
          if (!ts.isStringLiteral(el)) {
            this.report("NS1032", "`viewUnbound` holds a non-literal entry.", el);
            continue;
          }
          if (!fields.has(el.text) && !helpers.has(el.text) && !kinds.has(el.text)) {
            this.report("NS1032", `\`"${el.text}"\` names no Model field, exported model helper, or Msg kind.`, el);
          }
        }
      }
    }
  }

  // --------------------------------------------------------- module surface

  private checkModuleShape(file: ts.SourceFile): void {
    for (const stmt of file.statements) {
      if (ts.isClassDeclaration(stmt)) {
        this.checkClassDeclaration(stmt);
      } else if (ts.isEnumDeclaration(stmt)) {
        this.report("NS1008", `\`enum ${stmt.name.text}\` is non-erasable syntax.`, stmt);
      } else if (ts.isModuleDeclaration(stmt)) {
        this.report("NS1008", `\`namespace ${stmt.name.getText()}\` is non-erasable syntax.`, stmt);
      } else if (ts.isVariableStatement(stmt)) {
        const isConst = (stmt.declarationList.flags & ts.NodeFlags.Const) !== 0;
        if (!isConst) {
          this.report("NS1010", `Module-level \`let\` makes mutable global state.`, stmt);
        }
      } else if (ts.isExportAssignment(stmt)) {
        this.report(
          "NS1047",
          stmt.isExportEquals ? "`export =` exports an anonymous value." : "`export default` exports an anonymous value.",
          stmt,
        );
      } else if (ts.isExportDeclaration(stmt) && !stmt.isTypeOnly) {
        if (!stmt.exportClause || !ts.isNamedExports(stmt.exportClause)) {
          this.report("NS1047", "`export * from` re-exports a whole module surface without naming anything.", stmt);
        } else {
          this.checkExportList(stmt, file);
        }
      } else if (
        ts.isFunctionDeclaration(stmt) &&
        stmt.modifiers?.some((m) => m.kind === ts.SyntaxKind.DefaultKeyword)
      ) {
        this.report("NS1047", "`export default` exports the function anonymously.", stmt);
      }
      // Import-boundary rules (relative imports inside src/, npm specifiers,
      // cycles, missing files) live in the module-graph resolver
      // (modules.ts, NS1034-NS1037), which runs before the program is built.
    }
  }

  /// Export lists and value re-exports (`export { a, b as c }`,
  /// `export { x } from "./m.ts"`) bind names over EXISTING declarations in
  /// the flat emitted namespace — real, because every consumer resolves by
  /// name and NS1038 keeps exported names unique. What teaches here is the
  /// genuinely unsound tail: names from outside the core's modules, renamed
  /// bindings over things that have no single emitted value (generic
  /// templates, classes, wiring config), and non-identifier export names.
  private checkExportList(stmt: ts.ExportDeclaration, file: ts.SourceFile): void {
    const bindings = exportListBindings(this.tast, file).filter((b) => b.spec.parent.parent === stmt);
    for (const b of bindings) {
      if (!ts.isIdentifier(b.nameNode)) {
        this.report("NS1047", `\`export { ... as "${b.exportedName}" }\` exports a name no identifier can bind.`, b.spec);
        continue;
      }
      const target = b.target;
      if (!target) {
        this.report("NS1047", `\`${b.exportedName}\` resolves to no declaration the emitted module can bind.`, b.spec);
        continue;
      }
      if (ts.isInterfaceDeclaration(target) || ts.isTypeAliasDeclaration(target)) {
        continue; // type re-exported without `type` — tsc's isolatedModules error teaches
      }
      if (!this.fileSet.has(target.getSourceFile())) {
        this.report(
          "NS1047",
          `\`${b.exportedName}\` re-exports a declaration from outside the core's modules (the SDK surface and ambient names are not the core's to re-export).`,
          b.spec,
        );
        continue;
      }
      if (b.renamed && ts.isClassDeclaration(target)) {
        this.report(
          "NS1047",
          `\`${b.exportedName}\` renames class \`${target.name?.text}\` — a class exports under its declared name (\`new\` sites and the emitted struct resolve by it).`,
          b.spec,
        );
        continue;
      }
      if (b.renamed && ts.isFunctionDeclaration(target) && target.typeParameters && target.typeParameters.length > 0) {
        this.report(
          "NS1047",
          `\`${b.exportedName}\` renames generic \`${target.name?.text}\` — a generic template emits one function per instantiation, so there is no single value to bind a new name over.`,
          b.spec,
        );
        continue;
      }
      const targetName = ts.isFunctionDeclaration(target) || ts.isVariableDeclaration(target) ? target.name?.getText() : undefined;
      if (b.renamed && (targetName === "viewUnbound" || targetName === "envMsgs")) {
        this.report(
          "NS1047",
          `\`${b.exportedName}\` renames \`${targetName}\`, which is wiring config the build reads by its own name, not an emitted value.`,
          b.spec,
        );
      }
    }
  }

  /// NS1014 — the entry contract: the build wires the dispatch surface and
  /// the host-event channels from src/core.ts only. Imports may FEED those
  /// entry points, but the exports themselves live in the entry module.
  private static readonly entryOnlyExports = new Set([
    "update", "initialModel", "subscriptions",
    "commandMsg", "keyMsg", "frameMsg", "pinchMsg", "appearanceMsg", "chromeMsg", "envMsgs",
    "viewUnbound",
  ]);

  private checkEntryContract(): void {
    // Export lists claim entry-surface names too: an imported module
    // list-exporting `update` is as silently inert as declaring it there,
    // and the entry re-exporting (or rename-binding) an entry point leaves
    // the wiring nothing to wire — the dispatch machinery keys on the
    // DECLARATION (its name, its return shape), so the entry point must be
    // declared in core.ts and exported under its own name.
    for (const file of this.files) {
      for (const b of exportListBindings(this.tast, file)) {
        if (!SubsetChecker.entryOnlyExports.has(b.exportedName)) continue;
        if (file !== this.entry) {
          this.report("NS1014", `\`${b.exportedName}\` is exported from an imported module.`, b.spec);
        } else if (b.target && b.target.getSourceFile() !== this.entry) {
          this.report("NS1014", `\`${b.exportedName}\` is re-exported from an imported module — declare it in core.ts.`, b.spec);
        } else if (b.renamed) {
          this.report(
            "NS1014",
            `\`${b.exportedName}\` is bound by a renamed export — the build wires the declaration itself, so declare \`${b.exportedName}\` and export it under its own name.`,
            b.spec,
          );
        }
      }
    }
    for (const file of this.files) {
      if (file === this.entry) continue;
      for (const stmt of file.statements) {
        if (ts.isFunctionDeclaration(stmt) && stmt.name && hasExportModifier(stmt)) {
          if (SubsetChecker.entryOnlyExports.has(stmt.name.text)) {
            this.report("NS1014", `\`${stmt.name.text}\` is exported from an imported module.`, stmt.name);
          }
        } else if (ts.isVariableStatement(stmt)) {
          for (const decl of stmt.declarationList.declarations) {
            if (!ts.isIdentifier(decl.name)) continue;
            const name = decl.name.text;
            // envMsgs/viewUnbound are wiring CONFIG the emitter reads by
            // name from the entry module; even unexported copies elsewhere
            // would be silently inert (or worse, silently wired).
            if (name === "envMsgs" || name === "viewUnbound" || (hasExportModifier(stmt) && SubsetChecker.entryOnlyExports.has(name))) {
              this.report("NS1014", `\`${name}\` is declared in an imported module.`, decl.name);
            }
          }
        }
      }
    }
  }

  /// NS1038 — one flat emitted namespace: type names (which the whole
  /// pipeline resolves by name) and EXPORTED value names must be unique
  /// across the core's modules. Private value collisions are fine — the
  /// emitter uniques those with a per-module prefix.
  private checkNameCollisions(): void {
    interface Claim {
      readonly file: ts.SourceFile;
      /// The underlying declaration, so a name exported twice OVER THE SAME
      /// declaration (`export function f` re-exported down a chain) never
      /// reads as a collision — one declaration is one emitted name.
      readonly decl: ts.Node;
    }
    const types = new Map<string, Claim>();
    const exportedValues = new Map<string, Claim>();
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (ts.isInterfaceDeclaration(stmt) || ts.isTypeAliasDeclaration(stmt)) {
          const name = stmt.name.text;
          const prior = types.get(name) ?? exportedValues.get(name);
          if (prior) {
            // Same-file collisions count too: a type and an exported value
            // (or two interface declarations — TS merges them, the emitted
            // module cannot) would emit one Zig name twice.
            const where = prior.file === file ? "in this module" : `in ${prior.file.fileName}`;
            this.report("NS1038", `Type \`${name}\` is also declared ${where}.`, stmt.name);
          } else {
            types.set(name, { file, decl: stmt });
          }
        } else if (ts.isFunctionDeclaration(stmt) && stmt.name && hasExportModifier(stmt)) {
          this.recordExportedValue(stmt.name.text, stmt.name, stmt, types, exportedValues, file);
        } else if (ts.isVariableStatement(stmt) && hasExportModifier(stmt)) {
          for (const decl of stmt.declarationList.declarations) {
            if (ts.isIdentifier(decl.name)) this.recordExportedValue(decl.name.text, decl.name, decl, types, exportedValues, file);
          }
        }
      }
      // Export lists bind names into the same exported-value namespace: a
      // renamed export claims its NEW name; an un-renamed one claims the
      // declaration's own name (deduped by declaration identity above).
      for (const b of exportListBindings(this.tast, file)) {
        const t = b.target;
        if (!t || !this.fileSet.has(t.getSourceFile())) continue;
        if (!ts.isFunctionDeclaration(t) && !ts.isVariableDeclaration(t) && !ts.isClassDeclaration(t)) continue;
        this.recordExportedValue(b.exportedName, b.spec.name, t, types, exportedValues, file);
      }
    }
  }

  private recordExportedValue(
    name: string,
    site: ts.Node,
    decl: ts.Node,
    types: Map<string, { readonly file: ts.SourceFile; readonly decl: ts.Node }>,
    exportedValues: Map<string, { readonly file: ts.SourceFile; readonly decl: ts.Node }>,
    file: ts.SourceFile,
  ): void {
    const prior = exportedValues.get(name) ?? types.get(name);
    if (prior) {
      if (prior.decl === decl) return; // the same declaration under the same name — one emitted binding
      const where = prior.file === file ? "in this module" : `in ${prior.file.fileName}`;
      this.report("NS1038", `Exported \`${name}\` is also declared ${where}.`, site);
    } else {
      exportedValues.set(name, { file, decl });
    }
  }

  /// NS1003: no function-typed fields anywhere in the model/message tree.
  private checkModelHoldsData(): void {
    const scanFields = (typeName: string, seen: Set<string>): void => {
      if (seen.has(typeName)) return;
      seen.add(typeName);
      const struct = this.table.structs.get(typeName);
      const fields = struct
        ? struct.fields
        : this.table.unions.get(typeName)?.arms.flatMap((a) => [...a.fields]) ?? [];
      for (const f of fields) {
        const decl = f.decl;
        if (ts.isPropertySignature(decl) && decl.type && ts.isFunctionTypeNode(decl.type)) {
          this.report("NS1003", `\`${f.tsName}\` stores a function in the ${typeName} tree.`, decl);
        }
        const t = f.type;
        const nested = t.k === "slice" ? t.elem : t.k === "optional" ? t.inner : t;
        if (nested.k === "struct" || nested.k === "union") scanFields(nested.name, seen);
      }
    };
    const seen = new Set<string>();
    scanFields("Model", seen);
    scanFields("Msg", seen);
  }

  /// NS1024: a `string`-typed field anywhere in the MODEL tree (a
  /// literal-union tag is not a string — it compiles to an enum). Reported
  /// at the field's declaration, before any use, so the fix lands where the
  /// edit goes: retype as `Uint8Array` (+ `asciiBytes` for literals) or a
  /// string-literal union for closed sets.
  private checkModelTextIsBytes(): void {
    const seen = new Set<string>();
    const scanType = (typeName: string): void => {
      if (seen.has(typeName)) return;
      seen.add(typeName);
      const struct = this.table.structs.get(typeName);
      const fields = struct
        ? struct.fields.map((f) => ({ f, owner: typeName }))
        : (this.table.unions.get(typeName)?.arms.flatMap((a) =>
            a.fields.map((f) => ({ f, owner: `${typeName}.${a.tag}` })),
          ) ?? []);
      for (const { f, owner } of fields) {
        const t = f.type.k === "optional" ? f.type.inner : f.type;
        const nested = t.k === "slice" ? (t.elem.k === "optional" ? t.elem.inner : t.elem) : t;
        if (t.k === "string" || (t.k === "slice" && nested.k === "string")) {
          this.report(
            "NS1024",
            `Model field \`${f.tsName}\` on \`${owner}\` is typed \`string\`${t.k === "slice" ? " elements" : ""}.`,
            f.decl,
          );
        }
        if (nested.k === "struct" || nested.k === "union") scanType(nested.name);
      }
    };
    scanType("Model");
  }

  // ---------------------------------------------------------- data classes

  /// A data class: annotated fields, at most one constructor, plain methods.
  /// The banned tail teaches — inheritance (NS1055), accessors/statics/
  /// privacy/auto-accessors (NS1056), generics (NS1053), parameter
  /// properties (NS1008, non-erasable) — each named at its construct.
  private checkClassDeclaration(stmt: ts.ClassDeclaration): void {
    const name = stmt.name?.text;
    if (!name) {
      this.report("NS1006", "An anonymous class has no name to construct with `new`.", stmt);
      return;
    }
    if (stmt.modifiers?.some((m) => m.kind === ts.SyntaxKind.AbstractKeyword)) {
      this.report("NS1055", `\`abstract class ${name}\` exists to be subclassed.`, stmt);
    }
    if (stmt.typeParameters && stmt.typeParameters.length > 0) {
      this.report(
        "NS1053",
        `generic \`class ${name}<...>\`: a class emits as one concrete struct — make the varying piece a generic function or a generic record type.`,
        stmt,
      );
    }
    for (const h of stmt.heritageClauses ?? []) {
      // `implements` is an erasable type-level promise and stays legal.
      if (h.token === ts.SyntaxKind.ExtendsKeyword) {
        this.report("NS1055", `\`class ${name} extends ...\` declares inheritance.`, h);
      }
    }
    if (this.table.classes.has(name) && this.table.isPointerStruct(name)) {
      // FLAGGED follow-up: heap-node class instances (Model storage) need
      // the pointer-repr construction path; v1 keeps instances local values.
      this.report(
        "NS1056",
        `class \`${name}\` is stored in the Model tree — class instances stay local values in v1; store a record (interface) in the Model and construct the class from it where behavior is needed.`,
        stmt,
      );
    }
    let sawCtor = false;
    for (const m of stmt.members) {
      const memberName = m.name?.getText() ?? "<member>";
      if (ts.isGetAccessorDeclaration(m) || ts.isSetAccessorDeclaration(m)) {
        this.report("NS1056", `\`${ts.isGetAccessorDeclaration(m) ? "get" : "set"} ${memberName}\` declares an accessor.`, m);
        continue;
      }
      if (ts.isClassStaticBlockDeclaration(m)) {
        this.report("NS1056", "`static { }` runs code at module load.", m);
        continue;
      }
      if (ts.isIndexSignatureDeclaration(m)) {
        this.report("NS1041", "An index signature makes the instance shape dynamic.", m);
        continue;
      }
      if (ts.isSemicolonClassElement(m)) continue;
      const mods = ts.canHaveModifiers(m) ? (ts.getModifiers(m) ?? []) : [];
      const flag = (kind: ts.SyntaxKind): boolean => mods.some((x) => x.kind === kind);
      // `private`/`protected` keywords are ERASED: tsc enforces them at the
      // type level, which is their whole meaning (runtime #-privacy below
      // stays taught).
      if (flag(ts.SyntaxKind.StaticKeyword) && ts.isPropertyDeclaration(m)) {
        // `static readonly` fields with initializers are module consts;
        // a MUTABLE static is module state, and an uninitialized one has
        // no value to emit.
        if (!flag(ts.SyntaxKind.ReadonlyKeyword)) {
          this.report("NS1010", `\`static ${memberName}\` is mutable per-class state — module state by another spelling.`, m);
        } else if (!m.initializer) {
          this.report("NS1056", `\`static readonly ${memberName}\` has no initializer (a static const IS its value).`, m);
        }
      }
      if (flag(ts.SyntaxKind.AccessorKeyword)) {
        this.report("NS1056", `\`accessor ${memberName}\` declares an auto-accessor pair.`, m);
      }
      if (flag(ts.SyntaxKind.AbstractKeyword)) {
        this.report("NS1055", `\`abstract ${memberName}\` exists for subclasses to fill in.`, m);
      }
      if (m.name && ts.isPrivateIdentifier(m.name)) {
        this.report("NS1056", `\`${m.name.text}\` declares a #-private member (a runtime privacy brand).`, m);
        continue;
      }
      if (ts.isPropertyDeclaration(m)) {
        if (!m.name || !ts.isIdentifier(m.name)) {
          this.report("NS1056", "A computed field name makes the shape dynamic.", m);
          continue;
        }
        // Static consts follow the module-const rules (annotation optional
        // for foldable numbers/strings); the checks below are instance-layout
        // rules.
        if (flag(ts.SyntaxKind.StaticKeyword)) continue;
        if (!m.type) {
          this.report("NS1056", `field \`${m.name.text}\` has no type annotation (spell it: \`${m.name.text}: number = ...\`).`, m);
        }
        if (m.questionToken) {
          this.report("NS1056", `optional field \`${m.name.text}?\` — spell the empty explicitly (\`${m.name.text}: T | null\`).`, m);
        }
        continue;
      }
      if (ts.isConstructorDeclaration(m)) {
        if (!m.body) {
          this.report("NS1056", "A constructor overload signature declares no body.", m);
          continue;
        }
        if (sawCtor) this.report("NS1056", "A class has one constructor.", m);
        sawCtor = true;
        for (const pm of m.parameters) {
          if (ts.canHaveModifiers(pm) && (ts.getModifiers(pm)?.length ?? 0) > 0) {
            this.report("NS1008", `constructor parameter property \`${pm.name.getText()}\` is non-erasable syntax.`, pm);
          }
        }
        continue;
      }
      if (ts.isMethodDeclaration(m)) {
        if (!ts.isIdentifier(m.name)) {
          this.report("NS1056", "A computed method name makes dispatch dynamic.", m);
        }
        continue;
      }
    }
  }

  /// The class member (method or constructor body of a table-registered
  /// data class) a node sits in, looking through arrows (which inherit
  /// `this`) and stopping at any function that re-binds it.
  private enclosingClassMember(node: ts.Node): ts.MethodDeclaration | ts.ConstructorDeclaration | null {
    let cur: ts.Node | undefined = node.parent;
    while (cur && !ts.isSourceFile(cur)) {
      if (ts.isFunctionDeclaration(cur) || ts.isFunctionExpression(cur)) return null;
      if (ts.isPropertyDeclaration(cur)) return null; // field initializers stay taught
      if (ts.isMethodDeclaration(cur) || ts.isConstructorDeclaration(cur)) {
        const cls = cur.parent;
        if (ts.isClassDeclaration(cls) && cls.name && this.table.classes.get(cls.name.text)?.decl === cls) {
          return cur;
        }
        return null;
      }
      cur = cur.parent;
    }
    return null;
  }

  // ------------------------------------------------------------- exceptions

  /// NS1058: `finally` runs on every exit path via a scoped defer, which
  /// cannot carry control flow — so returns, throws, and breaks/continues
  /// that leave the finally block teach.
  private checkFinallyBlock(fin: ts.Block): void {
    const visit = (n: ts.Node, loopDepth: number, switchDepth: number, labels: Set<string>): void => {
      if (ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n)) return;
      if (ts.isReturnStatement(n)) {
        this.report("NS1058", "`return` inside `finally` overrides the pending return or exception.", n);
      } else if (ts.isThrowStatement(n)) {
        this.report("NS1058", "`throw` inside `finally` replaces the pending return or exception.", n);
      } else if (ts.isBreakStatement(n) || ts.isContinueStatement(n)) {
        const kw = ts.isBreakStatement(n) ? "break" : "continue";
        const local = n.label
          ? labels.has(n.label.text)
          : ts.isBreakStatement(n)
            ? loopDepth > 0 || switchDepth > 0
            : loopDepth > 0;
        if (!local) {
          this.report("NS1058", `\`${kw}\` inside \`finally\` jumps out of it, overriding the pending exit.`, n);
        }
      }
      const isLoop =
        ts.isForStatement(n) || ts.isForOfStatement(n) || ts.isForInStatement(n) || ts.isWhileStatement(n) || ts.isDoStatement(n);
      const nextLabels = ts.isLabeledStatement(n) ? new Set([...labels, n.label.text]) : labels;
      ts.forEachChild(n, (c) =>
        visit(c, loopDepth + (isLoop ? 1 : 0), switchDepth + (ts.isSwitchStatement(n) ? 1 : 0), nextLabels),
      );
    };
    for (const stmt of fin.statements) visit(stmt, 0, 0, new Set());
  }

  /// NS1057: the checker types a catch binding as the core's thrown shape
  /// (the thrown union when shapes differ), so it is read IN PLACE — kind
  /// tests (`if (e.kind === "parse")`), field reads off the narrowed arm,
  /// bare rethrow, or a single `as` narrowing. What teaches is the binding
  /// ESCAPING untyped: tsc types it `any` here (the subset checker is the
  /// authority), so a bare `e` handed to a call, stored, or returned would
  /// leave the type system silently.
  private checkCatchClause(cc: ts.CatchClause): void {
    const v = cc.variableDeclaration;
    if (!v) return;
    if (!ts.isIdentifier(v.name)) {
      this.report("NS1057", "a destructured catch binding — bind a name and narrow it once.", v);
      return;
    }
    const name = v.name.text;
    const visit = (n: ts.Node): void => {
      if (ts.isIdentifier(n) && n !== v.name && this.tast.declarationOf(n) === v) {
        let cur: ts.Node = n;
        let p: ts.Node = cur.parent;
        while (ts.isParenthesizedExpression(p)) {
          cur = p;
          p = p.parent;
        }
        const asserted = ts.isAsExpression(p) && p.expression === cur;
        const rethrown = ts.isThrowStatement(p) && p.expression === cur;
        const readInPlace = ts.isPropertyAccessExpression(p) && p.expression === cur;
        if (!asserted && !rethrown && !readInPlace) {
          this.report(
            "NS1057",
            `catch binding \`${name}\` escapes as an untyped value — read it in place (\`${name}.kind\` tests, the narrowed arm's fields), rethrow it (\`throw ${name};\`), or narrow it once (\`const err = ${name} as YourError;\`) and hand the narrowed value on.`,
            n,
          );
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(cc.block);
  }

  /// NS1057, module-wide: every throw carries the core's one error shape.
  private checkExceptions(): void {
    const res = thrownShapeOf(this.tast, this.table, this.files);
    for (const pr of res.problems) this.report("NS1057", pr.msg, pr.node);
  }

  // ------------------------------------------------------------------ walk

  /// Whether the tsc type string names a mutable-or-readonly ARRAY. A bare
  /// `Uint8Array` is bytes (its own writable-until-escape discipline), but an
  /// array OF byte buffers (`Uint8Array[]`, `Array<Uint8Array>`) is an array
  /// like any other and follows array ownership.
  private isArrayTypeString(t: string): boolean {
    // tsc may print bytes with its buffer parameter (`Uint8Array<ArrayBuffer>`).
    const withoutBytes = t.replace(/Uint8Array(<[^<>]*>)?/g, "");
    return withoutBytes.includes("[]") || t.startsWith("readonly") || withoutBytes.includes("Array");
  }

  /// The ownership teaching for one mutation site (a mutating method call or
  /// an indexed write). Legal on locally-owned arrays; NS1051 after an
  /// escape; NS1022 for in-place sort on shared data; NS1001 otherwise.
  private checkArrayMutation(base: ts.Expression, site: ts.Node, what: string, method: string | null): void {
    const verdict = arrayOwnership(this.tast, base, site);
    if (verdict.owned) {
      // The emitter enforces the exact lowering shapes (value-position
      // rules, spread arguments, iteration interleaving).
      return;
    }
    if (verdict.why === "escaped") {
      this.report("NS1051", `${what} mutates after the array escaped: ${verdict.detail}.`, site);
    } else if (method === "sort") {
      this.report("NS1022", `\`.sort()\` sorts, in place, an array this function does not own: ${verdict.detail}.`, site);
    } else {
      this.report("NS1001", `${what} mutates an array this function does not own: ${verdict.detail}.`, site);
    }
  }

  /// The ownership teaching for one class-instance mutation site (a field
  /// write or a mutating-method call). Legal on locally-owned instances;
  /// NS1051 after an escape; NS1001 on shared data.
  private checkInstanceMutation(base: ts.Expression, site: ts.Node, what: string): void {
    const verdict = instanceOwnership(this.tast, base, site);
    if (verdict.owned) return;
    if (verdict.why === "escaped") {
      this.report("NS1051", `${what} mutates after the instance escaped: ${verdict.detail}.`, site);
    } else {
      this.report("NS1001", `${what} mutates an instance this function does not own: ${verdict.detail}.`, site);
    }
  }

  /// Whether a resolved type mentions a type parameter anywhere (such an
  /// argument resolves when the ENCLOSING generic instantiates).
  private containsTypeParameter(t: import("./typed_ast.ts").Type): boolean {
    if ((t.flags & ts.TypeFlags.TypeParameter) !== 0) return true;
    if (t.isUnion()) return t.types.some((m) => this.containsTypeParameter(m));
    return this.tast.typeArgumentsOf(t).some((a) => this.containsTypeParameter(a));
  }

  private isStringTyped(expr: ts.Expression): boolean {
    const t = this.tast.typeOf(expr);
    return (t.flags & (ts.TypeFlags.String | ts.TypeFlags.StringLiteral)) !== 0;
  }

  /// String-typed, or a string-literal union value (emitted as an enum,
  /// where relational order would be declaration order, not code units).
  private isStringValued(expr: ts.Expression): boolean {
    if (this.isStringTyped(expr)) return true;
    const t = this.tast.typeOf(expr);
    return t.isUnion() && t.types.every((m) => m.isStringLiteral());
  }

  private walk(root: ts.Node): void {
    const visit = (node: ts.Node): void => {
      // NS1002 — synchronous updates.
      if (ts.isAwaitExpression(node)) {
        this.report("NS1002", "`await` cannot appear inside an app core.", node);
      } else if (
        (ts.isFunctionDeclaration(node) || ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isMethodDeclaration(node)) &&
        node.modifiers?.some((m) => m.kind === ts.SyntaxKind.AsyncKeyword)
      ) {
        this.report("NS1002", "`async` functions cannot appear inside an app core.", node);
      }

      // NS1006 — classes are module-level declarations (expressions stay
      // taught); `this` is the receiver inside a data-class member and
      // reaches only fields and methods (`this.count`, `this.step()`).
      if (ts.isClassExpression(node)) {
        this.report("NS1006", "A class expression declares a class.", node);
      }
      if (node.kind === ts.SyntaxKind.ThisKeyword) {
        const member = this.enclosingClassMember(node);
        if (member === null) {
          this.report("NS1006", "`this` outside a class member body refers to no instance.", node);
        } else if (
          ts.canHaveModifiers(member) &&
          (ts.getModifiers(member) ?? []).some((x) => x.kind === ts.SyntaxKind.StaticKeyword)
        ) {
          this.report(
            "NS1056",
            "`this` inside a static member is the class object, which is not a value — reach statics by the class name (`Task.LIMIT`, `Task.fromRow(...)`).",
            node,
          );
        } else if (!(ts.isPropertyAccessExpression(node.parent) && node.parent.expression === node)) {
          this.report(
            "NS1056",
            "`this` is used as a value (returned, stored, or passed) — only `this.field` and `this.method()` reach the receiver.",
            node,
          );
        }
      }

      // NS1042 — generators (a resumable frame is hidden state).
      if (
        (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isMethodDeclaration(node)) &&
        node.asteriskToken
      ) {
        this.report("NS1042", "`function*` declares a generator.", node);
      } else if (ts.isYieldExpression(node)) {
        this.report("NS1042", "`yield` suspends a generator frame.", node);
      }

      // NS1046 — functions are module-level declarations (or const-bound
      // local helpers, which hoist); everything else that treats a function
      // as a runtime value stays taught.
      if (ts.isFunctionDeclaration(node) && !ts.isSourceFile(node.parent) && !node.asteriskToken) {
        this.report("NS1046", `\`function ${node.name?.text ?? "<anonymous>"}\` declares a nested function.`, node);
      } else if (
        (ts.isFunctionExpression(node) && !node.asteriskToken) ||
        (ts.isArrowFunction(node) && !isCallArgument(node))
      ) {
        // NS1054 — the const-bound local-helper shape hoists to a module-
        // level declaration when it is capture-free, fully annotated, and
        // only called or passed as an array-method callback.
        const owner = owningConstDecl(node);
        const hoisted = owner ? constFunctionValue(owner) : null;
        if (owner && hoisted === node) {
          const verdict = functionValueLegality(owner, hoisted, this.tast);
          if (!verdict.ok) {
            this.report("NS1054", `This local function value cannot hoist: ${verdict.why}.`, node);
          }
        } else if (ts.isFunctionExpression(node)) {
          this.report("NS1046", "A `function` expression outside a `const` binding makes a function value.", node);
        } else {
          this.report("NS1046", "An arrow function outside a call-argument position or a `const` binding makes a stored function value.", node);
        }
      }
      if (ts.isCallExpression(node) && node.questionDotToken) {
        this.report("NS1046", "`?.()` calls a possibly-absent function value.", node);
      }
      // NS1054 — a call through a record FIELD reads a stored function.
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        !node.questionDotToken
      ) {
        const d = this.tast.declarationOf(node.expression.name);
        if (
          d &&
          ts.isPropertySignature(d) &&
          d.type &&
          ts.isFunctionTypeNode(d.type) &&
          this.fileSet.has(d.getSourceFile())
        ) {
          this.report("NS1054", `\`.${node.expression.name.text}()\` calls a function stored in a record field.`, node);
        }
      }

      // NS1040 — regular expressions.
      if (node.kind === ts.SyntaxKind.RegularExpressionLiteral) {
        this.report("NS1040", "A regex literal builds a RegExp value.", node);
      }

      // NS1041 — no runtime type or shape tests.
      if (ts.isTypeOfExpression(node)) {
        this.report("NS1041", "`typeof` reads a runtime type tag.", node);
      }

      // NS1044 — BigInt/Symbol value kinds.
      if (node.kind === ts.SyntaxKind.BigIntLiteral) {
        this.report("NS1044", "A BigInt literal makes an arbitrary-precision integer.", node);
      }

      // NS1043 — comma and void squeeze statements into expression position;
      // an assignment's value is read after the statement. The classic
      // for-loop's incrementor is the sanctioned home for both.
      if (ts.isVoidExpression(node)) {
        this.report("NS1043", "`void` manufactures a JS undefined.", node);
      }
      // `++`/`--` in value position: legal when the split statement is
      // provably order-exact (`arr[i++]`, `const n = ++count`); the
      // remainder teaches instead of stopping at the emitter.
      if (
        (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) &&
        (node.operator === ts.SyntaxKind.PlusPlusToken || node.operator === ts.SyntaxKind.MinusMinusToken) &&
        !ts.isExpressionStatement(node.parent) &&
        !inForIncrementor(node) &&
        ts.isIdentifier(node.operand)
      ) {
        const verdict = valuePositionStep(node, node.operand, this.tast);
        if (!verdict.ok) {
          this.report("NS1043", `\`++\`/\`--\` used as a value hides a statement (${verdict.why}).`, node);
        }
      }
      if (ts.isBinaryExpression(node)) {
        const op = node.operatorToken.kind;
        if (op === ts.SyntaxKind.CommaToken && !inForIncrementor(node)) {
          this.report("NS1043", "A comma expression sequences statements in expression position.", node);
        }
        if (
          compoundAndPlainAssignmentOps.has(op) &&
          !ts.isExpressionStatement(node.parent) &&
          !inForIncrementor(node)
        ) {
          // A number assignment may ride a value position when the split
          // statement is provably order-exact (sole mention, unskippable).
          const verdict = valuePositionStep(node, node.left, this.tast);
          if (!verdict.ok) {
            this.report("NS1043", `An assignment used as a value hides a statement (${verdict.why}).`, node);
          }
        }
        // NS1048 — loose equality coerces.
        if (op === ts.SyntaxKind.EqualsEqualsToken) {
          this.report("NS1048", "`==` compares with coercion.", node);
        } else if (op === ts.SyntaxKind.ExclamationEqualsToken) {
          this.report("NS1048", "`!=` compares with coercion.", node);
        }
        // NS1041 — `in` / `instanceof` runtime tests.
        if (op === ts.SyntaxKind.InKeyword) {
          this.report("NS1041", "`in` queries an object's shape at runtime.", node);
        } else if (op === ts.SyntaxKind.InstanceOfKeyword) {
          this.report("NS1041", "`instanceof` tests a class identity at runtime.", node);
        }
      }

      // NS1018 — a tagged template runs a function over strings at runtime.
      if (ts.isTaggedTemplateExpression(node)) {
        this.report("NS1018", "A tagged template runs a function over its strings at runtime.", node);
      }

      // NS1045 — destructuring: record fields into const locals only.
      if (ts.isArrayBindingPattern(node)) {
        // `for (const [i, x] of xs.entries())` keeps its own tailored
        // teaching (the emitter names the classic-loop rewrite).
        if (!isEntriesLoopBinding(node)) {
          this.report("NS1045", "Array destructuring binds element positions.", node);
        }
      } else if (ts.isObjectBindingPattern(node)) {
        if (ts.isParameter(node.parent)) {
          this.report("NS1045", "A parameter destructures in the signature.", node);
        } else if (ts.isVariableDeclaration(node.parent) && ts.isVariableDeclarationList(node.parent.parent)) {
          const list = node.parent.parent;
          if (ts.isForOfStatement(list.parent) || ts.isForInStatement(list.parent)) {
            this.report("NS1045", "A loop binding destructures its element.", node);
          } else if ((list.flags & ts.NodeFlags.Const) === 0) {
            this.report("NS1045", "`let` destructuring makes reassignable aliases.", node);
          }
        }
        for (const el of node.elements) {
          if (el.dotDotDotToken) {
            this.report("NS1045", "`...rest` collects the remaining fields into a new object.", el);
          } else if (el.initializer) {
            this.report("NS1045", "A destructuring default expects an absent field.", el);
          } else if (!ts.isIdentifier(el.name)) {
            this.report("NS1045", "A nested destructuring pattern hides its reads.", el);
          } else if (el.propertyName && !ts.isIdentifier(el.propertyName)) {
            this.report("NS1045", "A computed destructuring key resolves at runtime.", el);
          }
        }
      }

      // NS1019 — dynamic argument lists (defaults are checked below).
      if (ts.isParameter(node) && node.dotDotDotToken) {
        this.report("NS1019", `\`...${node.name.getText()}\` collects a dynamic argument list.`, node);
      }
      if (ts.isSpreadElement(node) && ts.isCallExpression(node.parent) && !isMutatingAppendCall(node.parent)) {
        this.report("NS1019", "`...` spreads a dynamic argument list into a call.", node);
      }
      if (
        ts.isIdentifier(node) &&
        node.text === "arguments" &&
        !(ts.isPropertyAccessExpression(node.parent) && node.parent.name === node) &&
        !(ts.isPropertySignature(node.parent) || ts.isPropertyAssignment(node.parent)) &&
        this.isAmbientRef(node)
      ) {
        this.report("NS1019", "`arguments` reads the dynamic argument list.", node);
      }

      // NS1039 — a namespace alias is dot-syntax, not a value.
      if (ts.isIdentifier(node) && this.nsAliasNames.has(node.text)) {
        const sym = this.tast.symbolOf(node);
        const d = sym?.declarations?.[0];
        if (d && ts.isNamespaceImport(d) && d.name !== node) {
          const p = node.parent;
          const legal =
            (ts.isPropertyAccessExpression(p) && p.expression === node) ||
            (ts.isQualifiedName(p) && p.left === node);
          if (!legal) {
            this.report("NS1039", `\`${node.text}\` uses a namespace alias as a value.`, node);
          }
        }
      }

      // R20 — exceptions are deterministic control flow: `throw` unwinds
      // to the nearest catch inside the core (an uncaught throw is a
      // defined panic at the boundary — node crashes there too). The
      // discipline rules teach: one error shape per core (NS1057) and no
      // control flow out of `finally` (NS1058).
      if (ts.isTryStatement(node)) {
        if (node.finallyBlock) this.checkFinallyBlock(node.finallyBlock);
        if (node.catchClause) this.checkCatchClause(node.catchClause);
      }

      // NS1008 — decorators.
      if (ts.isDecorator(node)) {
        this.report("NS1008", "Decorators are non-erasable syntax.", node);
      }

      // NS1009 — for/in.
      if (ts.isForInStatement(node)) {
        this.report("NS1009", "`for`/`in` walks prototype chains.", node);
      }

      // NS1013 — `debugger` pauses a JS engine the binary does not carry.
      if (node.kind === ts.SyntaxKind.DebuggerStatement) {
        this.report("NS1013", "`debugger` pauses a JS engine.", node);
      }

      // NS1049 — `var` hoists; const/let map exactly. (Module-level `var`
      // additionally teaches NS1010, the module-state rule.)
      if (
        ts.isVariableDeclarationList(node) &&
        (node.flags & (ts.NodeFlags.Let | ts.NodeFlags.Const)) === 0
      ) {
        this.report("NS1049", "`var` declares a hoisted, function-scoped local.", node);
      }

      // NS1052 — an un-annotated local initialized from a spread array
      // literal has no slice target for the emitter to lower against
      // (the generic emit-time stop taught nothing; this names the fix).
      if (
        ts.isVariableDeclaration(node) &&
        !node.type &&
        node.initializer !== undefined
      ) {
        let init: ts.Expression = node.initializer;
        while (ts.isParenthesizedExpression(init)) init = init.expression;
        if (ts.isArrayLiteralExpression(init) && init.elements.some((el) => ts.isSpreadElement(el))) {
          this.report(
            "NS1052",
            `\`${node.name.getText()}\` spreads into an array literal without declaring its array type.`,
            node,
          );
        }
      }

      // NS1050 — generics live on module-level declarations (functions,
      // interfaces, type aliases — monomorphized per call site). Function
      // VALUES and the entry points stay concrete.
      if (
        (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) &&
        node.typeParameters &&
        node.typeParameters.length > 0
      ) {
        this.report("NS1050", "A generic function value declares a type parameter.", node);
      } else if (
        ts.isFunctionDeclaration(node) &&
        node.typeParameters &&
        node.typeParameters.length > 0 &&
        node.name &&
        SubsetChecker.entryOnlyExports.has(node.name.text)
      ) {
        this.report("NS1050", `Entry point \`${node.name.text}\` declares a type parameter.`, node);
      }

      // NS1053 — a generic call must resolve to concrete emitted types
      // (tsc's own signature resolution; type parameters of an enclosing
      // generic resolve at that generic's instantiation).
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)) {
        const gdecl = this.tast.declarationOf(node.expression);
        if (
          gdecl &&
          ts.isFunctionDeclaration(gdecl) &&
          gdecl.typeParameters &&
          gdecl.typeParameters.length > 0 &&
          this.fileSet.has(gdecl.getSourceFile())
        ) {
          const targs = this.tast.resolvedCallTypeArguments(node);
          if (!targs || targs.length < gdecl.typeParameters.length) {
            this.report("NS1053", `\`${gdecl.name?.text}\` is called without resolvable type arguments.`, node);
          } else {
            targs.forEach((a, idx) => {
              if (this.containsTypeParameter(a)) return; // resolves at the enclosing instantiation
              const z = this.table.zTypeOfTsType(a);
              if (!z || z.k === "void") {
                this.report(
                  "NS1053",
                  `\`${gdecl.name?.text}\`'s type argument \`${gdecl.typeParameters![idx]?.name.text ?? idx + 1}\` resolves to \`${this.tast.typeToString(a)}\`, which has no concrete emitted type.`,
                  node,
                );
              }
            });
          }
        }
      }

      // NS1012 — a computed property name builds a shape at runtime.
      if (ts.isComputedPropertyName(node)) {
        this.report("NS1012", "A computed property name builds a shape at runtime.", node);
      }

      // NS1012 — shape stability.
      if (ts.isDeleteExpression(node)) {
        this.report("NS1012", "`delete` removes a field from a fixed shape.", node);
      } else if (ts.isGetAccessor(node) || ts.isSetAccessor(node)) {
        this.report("NS1012", "Getters/setters make field reads run code.", node);
      }

      // NS1013 — closed world.
      if (ts.isCallExpression(node)) {
        if (ts.isIdentifier(node.expression)) {
          const callName = node.expression.text;
          if (callName === "eval") {
            this.report("NS1013", "`eval` executes dynamic code.", node);
          } else if (callName === "RegExp" && this.isAmbientRef(node.expression)) {
            this.report("NS1040", "`RegExp(...)` builds a RegExp value.", node);
          } else if ((callName === "Symbol" || callName === "BigInt") && this.isAmbientRef(node.expression)) {
            this.report("NS1044", `\`${callName}(...)\` makes a ${callName} value.`, node);
          }
        }
        if (node.expression.kind === ts.SyntaxKind.ImportKeyword) {
          this.report("NS1013", "Dynamic `import()` loads code at runtime.", node);
        }
      }
      if (ts.isNewExpression(node)) {
        if (ts.isIdentifier(node.expression)) {
          const name = node.expression.text;
          if (name === "Error" && this.isAmbientRef(node.expression)) {
            this.report(
              "NS1057",
              "`new Error(...)` builds an engine error object (message string, stack trace) with no native shape.",
              node,
            );
          } else if (name === "Function") {
            this.report("NS1013", "`new Function` compiles source at runtime.", node);
          } else if (name === "Map" || name === "Set") {
            // NS1011 — no Map/Set in v1, with or without type arguments.
            this.report("NS1011", `\`new ${name}\` constructs a hashed container.`, node);
          } else if (name === "RegExp") {
            this.report("NS1040", "`new RegExp` builds a RegExp value.", node);
          } else if (name === "Promise") {
            this.report("NS1002", "`new Promise` starts asynchronous work.", node);
          } else if (name === "Date") {
            this.report("NS1005", "`new Date` reads ambient wall-clock state.", node);
          } else if (name !== "Uint8Array") {
            const decl = this.tast.declarationOf(node.expression);
            const cls = this.table.classes.get(name);
            const supported = decl !== null && ts.isClassDeclaration(decl) && cls !== undefined && cls.decl === decl;
            // `new` of a registered data class constructs a record-shaped
            // value; ill-shaped local classes teach at their declaration,
            // and everything ambient lands here.
            if (!supported && this.isAmbientRef(node.expression)) {
              this.report("NS1006", `\`new ${name}\` constructs a class instance.`, node);
            }
          }
        } else {
          this.report("NS1006", "`new` constructs a class instance.", node);
        }
      }

      // NS1005 — determinism (and the runtime-surface globals near it).
      if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression)) {
        const base = node.expression.text;
        const member = node.name.text;
        if (base === "Math" && member === "random") {
          this.report("NS1005", "`Math.random()` draws ambient randomness.", node);
        } else if (ambientGlobals.has(base)) {
          this.report("NS1005", `\`${base}.${member}\` reaches ambient platform state.`, node);
        } else if (base === "Array" && (member === "from" || member === "of" || member === "fromAsync") && this.isAmbientRef(node.expression)) {
          // NS1059 — the Array constructors get their own accurate teaching
          // (they BUILD arrays; only `Array.isArray` tests a runtime shape).
          this.report("NS1059", `\`Array.${member}\` constructs an array through a runtime protocol.`, node);
        } else if ((base === "Object" || base === "Reflect" || base === "JSON" || base === "Array") && this.isAmbientRef(node.expression)) {
          this.report("NS1041", `\`${base}.${member}\` works on runtime shapes.`, node);
        } else if (base === "Symbol" && this.isAmbientRef(node.expression)) {
          this.report("NS1044", `\`Symbol.${member}\` names an engine symbol.`, node);
        } else if (base === "Promise" && this.isAmbientRef(node.expression)) {
          this.report("NS1002", `\`Promise.${member}\` starts asynchronous work.`, node);
        }
      }

      // NS1060/NS1005/NS1040 — the byte-text stays-out tail: spellings the
      // ambient surface declares only so each one can teach its reason
      // (UTF-16, locale, regex) and the byte-honest alternative here.
      if (
        ts.isPropertyAccessExpression(node) &&
        bytesTextStaysOut.has(node.name.text) &&
        this.tast.isBytesTyped(node.expression)
      ) {
        const teach = bytesTextStaysOut.get(node.name.text)!;
        this.report(teach.id, teach.site, node);
      }

      // NS1004 — string code-unit observation (UTF-16/UTF-8 seam).
      if (ts.isPropertyAccessExpression(node) && node.name.text === "length" && this.isStringTyped(node.expression)) {
        this.report("NS1004", "`.length` on a string counts code units.", node);
      } else if (
        ts.isPropertyAccessExpression(node) &&
        stringObservers.has(node.name.text) &&
        this.isStringTyped(node.expression)
      ) {
        this.report("NS1004", `\`.${node.name.text}\` on a string reads code units.`, node);
      } else if (ts.isElementAccessExpression(node) && this.isStringTyped(node.expression)) {
        this.report("NS1004", "Indexing a string reads a code unit.", node);
      } else if (ts.isBinaryExpression(node)) {
        const op = node.operatorToken.kind;
        const relational =
          op === ts.SyntaxKind.LessThanToken ||
          op === ts.SyntaxKind.LessThanEqualsToken ||
          op === ts.SyntaxKind.GreaterThanToken ||
          op === ts.SyntaxKind.GreaterThanEqualsToken;
        if (relational && this.isStringValued(node.left) && this.isStringValued(node.right)) {
          this.report("NS1004", "Relational comparison on strings orders code units.", node);
        }
        // NS1018 — string concatenation (either operand string-valued makes
        // JS `+` concatenate; `+=` is the same operation through assignment).
        const concatOp = op === ts.SyntaxKind.PlusToken || op === ts.SyntaxKind.PlusEqualsToken;
        if (concatOp && (this.isStringValued(node.left) || this.isStringValued(node.right))) {
          this.report("NS1018", "`+` on a string concatenates at runtime.", node);
        }
      }

      // NS1019 — parameter defaults are silently arity-changing; ban them.
      if (ts.isParameter(node) && node.initializer) {
        this.report("NS1019", `Parameter \`${node.name.getText()}\` declares a default value.`, node);
      }

      // NS1021 — a null/undefined test on an optional chain distinguishes JS
      // undefined (the chain short-circuited) from null (the field's value);
      // the native optional cannot.
      if (ts.isBinaryExpression(node)) {
        const op = node.operatorToken.kind;
        const equality =
          op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.ExclamationEqualsEqualsToken;
        if (equality) {
          const pairs: Array<[ts.Expression, ts.Expression]> = [
            [node.left, node.right],
            [node.right, node.left],
          ];
          for (const [chainSide, nullSide] of pairs) {
            const isNullish =
              nullSide.kind === ts.SyntaxKind.NullKeyword ||
              (ts.isIdentifier(nullSide) && nullSide.text === "undefined");
            let unwrapped = chainSide;
            while (ts.isParenthesizedExpression(unwrapped)) unwrapped = unwrapped.expression;
            if (isNullish && ts.isOptionalChain(unwrapped)) {
              this.report("NS1021", "A `?.` chain flows into a null test.", node);
              break;
            }
          }
        }
      }

      // NS1028 — persist compiles and stays on the wire, but no shipping
      // host performs it yet; teach the writeFile path without stopping
      // the build.
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        node.expression.name.text === "persist" &&
        ts.isIdentifier(node.expression.expression) &&
        this.cmdNames.has(node.expression.expression.text) &&
        this.isSdkReference(node.expression.expression)
      ) {
        this.warn("NS1028", "`Cmd.persist()` asks for a host service no shipping host provides yet.", node);
      }

      // NS1001/NS1022/NS1051 — mutation stays inside local ownership:
      // mutating array methods are legal on arrays this function created and
      // still owns; shared data (parameters, model/msg trees, module tables)
      // and escaped locals keep the teaching rules. Bytes keep their legacy
      // treatment (a Uint8Array writes through `.set`/indexed stores).
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
        const method = node.expression.name.text;
        if (mutatingArrayMethods.has(method)) {
          const t = this.tast.typeToString(this.tast.typeOf(node.expression.expression));
          if (this.isArrayTypeString(t)) {
            if (!ownedMutatingMethods.has(method)) {
              // `copyWithin` stays out of v1 even on owned arrays.
              this.report("NS1001", `\`.${method}()\` is not part of v1 (splice/fill cover its uses).`, node);
            } else {
              this.checkArrayMutation(node.expression.expression, node, `\`.${method}()\``, method);
            }
          } else if (t.includes("Uint8Array")) {
            // Legacy bytes treatment: whole-buffer mutators stay taught
            // (bytes write through `.set` and indexed stores instead).
            if (method === "sort") {
              this.report("NS1022", `\`.sort()\` sorts the array in place.`, node);
            } else {
              this.report("NS1001", `\`.${method}()\` mutates an existing array.`, node);
            }
          }
        }
        // NS1023 — a boolean comparator is a JS bug the types can catch
        // (in-place `.sort` keeps exactly the `.toSorted` comparator rules).
        if (method === "toSorted" || method === "sort") {
          const cmp = node.arguments[0];
          if (cmp && ts.isArrowFunction(cmp) && this.tast.arrowReturnsBoolean(cmp)) {
            this.report("NS1023", `This \`.${method}\` comparator returns a boolean.`, cmp);
          }
        }
      }

      // The same ownership rule for indexed writes: `xs[i] = v`, the
      // compound forms, and `xs[i]++` mutate the array exactly like the
      // methods do (bytes stay on their own writable-until-escape rule).
      {
        let writeTarget: ts.Expression | null = null;
        let what = "";
        if (
          ts.isBinaryExpression(node) &&
          compoundAndPlainAssignmentOps.has(node.operatorToken.kind) &&
          ts.isElementAccessExpression(node.left)
        ) {
          writeTarget = node.left.expression;
          what = "An indexed write";
        } else if (
          (ts.isPostfixUnaryExpression(node) || ts.isPrefixUnaryExpression(node)) &&
          (node.operator === ts.SyntaxKind.PlusPlusToken || node.operator === ts.SyntaxKind.MinusMinusToken) &&
          ts.isElementAccessExpression(node.operand)
        ) {
          writeTarget = node.operand.expression;
          what = "`++`/`--` on an element";
        }
        if (writeTarget !== null) {
          const t = this.tast.typeToString(this.tast.typeOf(writeTarget));
          if (this.isArrayTypeString(t)) {
            this.checkArrayMutation(writeTarget, node, what, null);
          }
        }
      }

      // Class-instance mutation follows the same local-ownership rule as
      // arrays: your own `new` instance mutates freely until it escapes;
      // `this` writes inside members are the class's own business (the
      // CALL of a mutating method is where ownership gates).
      {
        let fieldWrite: ts.PropertyAccessExpression | null = null;
        let what = "";
        if (
          ts.isBinaryExpression(node) &&
          compoundAndPlainAssignmentOps.has(node.operatorToken.kind) &&
          ts.isPropertyAccessExpression(node.left)
        ) {
          fieldWrite = node.left;
          what = `A write to field \`.${node.left.name.text}\``;
        } else if (
          (ts.isPostfixUnaryExpression(node) || ts.isPrefixUnaryExpression(node)) &&
          (node.operator === ts.SyntaxKind.PlusPlusToken || node.operator === ts.SyntaxKind.MinusMinusToken) &&
          ts.isPropertyAccessExpression(node.operand)
        ) {
          fieldWrite = node.operand;
          what = `\`++\`/\`--\` on field \`.${node.operand.name.text}\``;
        }
        if (fieldWrite !== null && fieldWrite.expression.kind !== ts.SyntaxKind.ThisKeyword) {
          const propDecl = this.tast.declarationOf(fieldWrite.name);
          if (propDecl && ts.isPropertyDeclaration(propDecl)) {
            this.checkInstanceMutation(fieldWrite.expression, node, what);
          }
        }
        if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
          const recv = node.expression.expression;
          const methodDecl = this.tast.declarationOf(node.expression.name);
          if (
            recv.kind !== ts.SyntaxKind.ThisKeyword &&
            methodDecl &&
            ts.isMethodDeclaration(methodDecl) &&
            ts.isClassDeclaration(methodDecl.parent) &&
            methodDecl.parent.name &&
            this.table.classes.get(methodDecl.parent.name.text)?.mutating.has(node.expression.name.text)
          ) {
            this.checkInstanceMutation(recv, node, `\`.${node.expression.name.text}()\` (a method that writes \`this\`)`);
          }
        }
      }

      ts.forEachChild(node, visit);
    };
    visit(root);
  }
}

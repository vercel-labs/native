// R2 integer inference: JS semantics are f64 everywhere, but the emitter may
// use i64 wherever that is unobservable. A `number` slot (const, local, param,
// field, return) is emitted as i64 when:
//
//   - it is PROVEN integer: every value flowing in is integer-valued
//     (integer literals, lengths, byte reads, integer arithmetic), and the
//     slot is not externally constructible; or
//   - it is DEMANDED integer: some use requires an integer (memory index,
//     bitwise op, equality with a proven-integer value), which is sound
//     because f64 holds every integer the demand sites can produce exactly.
//
// Everything else stays f64, matching JS bit-for-bit. External slots are the
// app boundary: fields reachable from `Msg` and parameters of exported
// functions — the host may pass any f64 there, so proof never starts from
// them, only demand can claim them.
//
// A final demotion pass resolves mixed sites (e.g. `Math.max(K, x)` with x
// f64) by pushing undemanded integer slots to f64 so emitted arithmetic
// type-checks without casts. The same pass keeps every assignment edge
// same-typed by construction: a float-tainted slot demotes the undecided
// slots that flow into it, and a slot fed by a resolved-integer slot is
// demanded to match. When neither side can move — a fractional value flows
// into a slot some use forces to be an integer — that is a conflict reported
// as a teaching error (NS1016), never a downstream Zig type error.

import { ts, TypedAst, exportListBindings } from "./typed_ast.ts";
import { constFunctionValue } from "./ownership.ts";
import { thrownShapeOf } from "./checker.ts";
import type { TypeTable } from "./types.ts";

/// The `return` expressions of a callback body, nested functions excluded —
/// the values a block-body callback can produce.
export function returnExpressionsOf(body: ts.Node): ts.Expression[] {
  const out: ts.Expression[] = [];
  const visit = (n: ts.Node): void => {
    if (ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n)) return;
    if (ts.isReturnStatement(n) && n.expression) out.push(n.expression);
    ts.forEachChild(n, visit);
  };
  visit(body);
  return out;
}

/// Array methods whose callback carries the element index as its second
/// parameter in v1 (reduce's index is its third and stays unmapped).
export const indexCarryingMethods = new Set(["map", "filter", "find", "findIndex", "some", "every"]);

/// Array methods that accept a function-valued callback argument at all —
/// the positions where a bare reference to a module-level function inlines
/// like an arrow (`xs.map(encodeTurn)`).
export const callbackTakingMethods = new Set([
  ...indexCarryingMethods,
  "reduce",
  "sort",
  "toSorted",
  "forEach",
  "flatMap",
]);

/// The receiver of `for (const [i, x] of xs.entries())` when the binding
/// element belongs to that loop form, else null.
function entriesLoopReceiver(el: ts.BindingElement): ts.Expression | null {
  const pattern = el.parent;
  if (!ts.isArrayBindingPattern(pattern)) return null;
  const decl = pattern.parent;
  if (!ts.isVariableDeclaration(decl) || !ts.isVariableDeclarationList(decl.parent)) return null;
  const loop = decl.parent.parent;
  if (!ts.isForOfStatement(loop)) return null;
  let iter = loop.expression;
  while (ts.isParenthesizedExpression(iter)) iter = iter.expression;
  if (
    !ts.isCallExpression(iter) ||
    !ts.isPropertyAccessExpression(iter.expression) ||
    iter.expression.name.text !== "entries"
  ) {
    return null;
  }
  return iter.expression.expression;
}

export interface Slot {
  readonly decl: ts.Node;
  readonly label: string;
  external: boolean;
  /// A number parameter of an exported function — the ABI boundary the host
  /// calls across. Genuine integer demand (index/bitwise chains) may still
  /// claim it to i64 (the emitted signature IS the contract type), but a
  /// mere comparison must not: the host may pass any f64, and an i64-claimed
  /// signature would truncate what node would compare exactly.
  hostBoundary: boolean;
  float: boolean;
  proven: boolean;
  demanded: boolean;
  /// The demand is TENTATIVE — claimed only so a comparison's two sides
  /// land same-typed, never by a genuine integer requirement (index,
  /// bitwise, size). A tentative claim yields when float later reaches the
  /// slot: it demotes to f64 and the comparison widens, instead of
  /// reporting a manufactured NS1016 conflict. Hard demand (`demandSlot`
  /// with viaComparison=false) upgrades and clears this.
  comparisonDemanded: boolean;
  readonly inflows: Contribution[];
}

export interface Contribution {
  readonly slots: Slot[];
  /// A fractional literal, division, or other definitely-float source.
  float: boolean;
  /// A source the analysis cannot classify (kills proof, not demand).
  unknown: boolean;
  /// At least one definitely-integer source (literal, length, byte read).
  intSource: boolean;
  /// The expression the contribution was read from (conflict reporting).
  readonly site: ts.Expression;
}

interface CompareSite {
  readonly left: Contribution;
  readonly right: Contribution;
}

/// An assignment or mix the fixed point could not make same-typed: a
/// fractional value meets a slot that some use forces to stay an integer.
export interface IntFloatConflict {
  readonly node: ts.Node;
  /// The integer-forced slot's source name, for the teaching message.
  readonly slotLabel: string;
}

export class IntInference {
  private readonly slots = new Map<ts.Node, Slot>();
  private readonly compareSites: CompareSite[] = [];
  private readonly mixSites: CompareSite[] = [];
  private readonly demandSeeds: Contribution[] = [];
  readonly conflicts: IntFloatConflict[] = [];

  private readonly tast: TypedAst;
  private readonly table: TypeTable;
  /// The core's modules in canonical order; files[0] is the entry. Slots
  /// and flows span all of them — declarationOf resolves across files, so
  /// a call from core.ts into parsers.ts wires argument flows into the
  /// callee's parameter slots exactly like a same-file call.
  private readonly files: readonly ts.SourceFile[];
  private readonly fileSet: Set<ts.SourceFile>;

  constructor(tast: TypedAst, table: TypeTable, files: readonly ts.SourceFile[] | ts.SourceFile) {
    this.tast = tast;
    this.table = table;
    this.files = Array.isArray(files) ? files : [files as ts.SourceFile];
    this.fileSet = new Set(this.files);
    this.collectCallbackReferencedFns();
    this.collectSlots();
    this.markExternal();
    this.collectFlows();
    this.resolve();
  }

  // ------------------------------------------------------------- slot setup

  /// Module-level function declarations referenced BARE as an array-method
  /// callback (`xs.map(encodeTurn)`). Their bodies inline at the use site
  /// like arrows, so their number parameters read number-array elements —
  /// always f64 (R2 covers slots, not elements) — and must classify like
  /// arrow captures, not like ordinary called parameters.
  private readonly callbackReferencedFns = new Set<ts.FunctionDeclaration>();

  private collectCallbackReferencedFns(): void {
    const visit = (node: ts.Node): void => {
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        callbackTakingMethods.has(node.expression.name.text)
      ) {
        for (const arg of node.arguments) {
          if (!ts.isIdentifier(arg)) continue;
          const decl = this.tast.declarationOf(arg);
          if (decl && ts.isFunctionDeclaration(decl)) this.callbackReferencedFns.add(decl);
        }
      }
      ts.forEachChild(node, visit);
    };
    for (const f of this.files) visit(f);
  }

  private numberish(node: ts.TypeNode | undefined): boolean {
    if (!node) return false;
    const t = this.table.resolveTypeNode(node);
    return t.k === "number" || (t.k === "optional" && t.inner.k === "number");
  }

  private addSlot(decl: ts.Node, label: string): void {
    if (!this.slots.has(decl)) {
      this.slots.set(decl, {
        decl,
        label,
        external: false,
        hostBoundary: false,
        float: false,
        proven: true,
        demanded: false,
        comparisonDemanded: false,
        inflows: [],
      });
    }
  }

  /// A slot that starts float: array-callback captures read number-array
  /// elements, which are always emitted f64 (R2 covers slots, not elements).
  /// A body that demands an integer from one is an NS1016 conflict.
  private addFloatSlot(decl: ts.Node, label: string): void {
    if (!this.slots.has(decl)) {
      this.slots.set(decl, {
        decl,
        label,
        external: false,
        hostBoundary: false,
        float: true,
        proven: false,
        demanded: false,
        comparisonDemanded: false,
        inflows: [],
      });
    }
  }

  private collectSlots(): void {
    // Untyped `const x = <numeric expr>` locals detect numeric-ness by
    // READING other slots (numericInit), so they resolve on a second,
    // fixpoint pass: with multiple files a referenced field or function
    // slot may be declared in a file visited later.
    const untypedLocals: ts.VariableDeclaration[] = [];
    const visit = (node: ts.Node): void => {
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name)) {
        const list = node.parent;
        if (ts.isVariableDeclarationList(list) && ts.isForOfStatement(list.parent)) {
          // for...of bindings: byte elements are integer reads, number-array
          // elements are f64 (R2 covers slots, not elements) — the same split
          // as array-callback captures below.
          const numberTyped = (this.tast.typeOf(node.name).flags & ts.TypeFlags.Number) !== 0;
          if (numberTyped) {
            if (this.tast.isBytesTyped(list.parent.expression)) this.addSlot(node, node.name.text);
            else this.addFloatSlot(node, node.name.text);
          }
        } else if (this.numberish(node.type)) {
          this.addSlot(node, node.name.text);
        } else if (!node.type && node.initializer) {
          untypedLocals.push(node);
        }
      } else if (ts.isParameter(node) && ts.isIdentifier(node.name)) {
        if (ts.isArrowFunction(node.parent)) {
          const numberTyped = node.type
            ? this.numberish(node.type)
            : (this.tast.typeOf(node.name).flags & ts.TypeFlags.Number) !== 0;
          if (numberTyped) {
            // A reduce accumulator is a real slot — it receives the initial
            // value and the body result (flows wired in collectFlows), so R2
            // resolves its class like any local. An array-callback index
            // parameter is the loop index, a proven integer. Element
            // captures stay f64.
            if (this.isReduceAccumulator(node.parent, node) || this.isCallbackIndexParam(node.parent, node)) {
              this.addSlot(node, node.name.text);
            } else {
              this.addFloatSlot(node, node.name.text);
            }
          }
        } else if (ts.isFunctionExpression(node.parent)) {
          // A hoisted function-expression helper's number params are
          // f64 like arrow captures — call flows are not wired, so the
          // conservative JS-faithful class is the sound one.
          if (this.numberish(node.type)) this.addFloatSlot(node, node.name.text);
        } else if (ts.isFunctionDeclaration(node.parent) && this.callbackReferencedFns.has(node.parent)) {
          // A module fn referenced bare as a callback inlines at that use
          // site: its number params read array elements, which are f64.
          if (this.numberish(node.type)) this.addFloatSlot(node, node.name.text);
        } else if (this.numberish(node.type)) {
          this.addSlot(node, node.name.text);
        }
      } else if (ts.isPropertySignature(node) && node.name && ts.isIdentifier(node.name)) {
        if (this.numberish(node.type)) this.addSlot(node, node.name.text);
      } else if (ts.isPropertyDeclaration(node) && node.name && ts.isIdentifier(node.name)) {
        // R19: a class field is a slot like a record field, fed by its
        // initializer and by `this.x = ...` writes (wired in collectFlows).
        // An UNTYPED `static readonly K = 9` is a module const in class
        // clothing: numeric-ness comes from its foldable initializer, like
        // untyped module-const locals.
        if (this.numberish(node.type)) this.addSlot(node, node.name.text);
        else if (!node.type && node.initializer && this.tast.constEvalNumber(node.initializer) !== null) {
          this.addSlot(node, node.name.text);
        }
      } else if (ts.isMethodDeclaration(node) && node.name && ts.isIdentifier(node.name)) {
        if (this.numberish(node.type)) this.addSlot(node, `${node.name.text}()`);
      } else if (ts.isFunctionDeclaration(node) && node.name) {
        if (this.numberish(node.type)) this.addSlot(node, `${node.name.text}()`);
      } else if (ts.isBindingElement(node) && ts.isIdentifier(node.name)) {
        // `for (const [i, x] of xs.entries())`: the index is a proven
        // integer (the loop index); the element splits like the plain
        // for...of — byte reads are integers, number-array elements stay
        // f64 (R2 covers slots, not elements).
        const entriesRecv = entriesLoopReceiver(node);
        if (entriesRecv !== null) {
          const pattern = node.parent as ts.ArrayBindingPattern;
          if (pattern.elements[0] === node) {
            this.addSlot(node, node.name.text);
          } else if ((this.tast.typeOf(node.name).flags & ts.TypeFlags.Number) !== 0) {
            if (this.tast.isBytesTyped(entriesRecv)) this.addSlot(node, node.name.text);
            else this.addFloatSlot(node, node.name.text);
          }
          ts.forEachChild(node, visit);
          return;
        }
        // `const { total } = stats;` — a number-fielded binding is a real
        // slot, classed by the field that feeds it (wired in collectFlows).
        const f = this.destructuredField(node);
        const ft = f?.type;
        if (ft && (ft.k === "number" || (ft.k === "optional" && ft.inner.k === "number"))) {
          this.addSlot(node, node.name.text);
        }
      }
      ts.forEachChild(node, visit);
    };
    for (const file of this.files) visit(file);
    // Fixpoint over the untyped locals: `const a = LIMIT` may reference a
    // slot another untyped local (or a later file) introduces.
    let added = true;
    while (added) {
      added = false;
      for (const node of untypedLocals) {
        if (this.slots.has(node)) continue;
        if (this.numericInit(node.initializer!)) {
          this.addSlot(node, (node.name as ts.Identifier).text);
          added = true;
        }
      }
    }
  }

  /// Untyped `const x = <numeric expr>` locals also get slots.
  private numericInit(expr: ts.Expression): boolean {
    if (ts.isParenthesizedExpression(expr)) return this.numericInit(expr.expression);
    if (ts.isNumericLiteral(expr)) return true;
    // `const z = (y = 5)`: the assignment's value is the number target's.
    if (
      ts.isBinaryExpression(expr) &&
      ts.isIdentifier(expr.left) &&
      (expr.operatorToken.kind === ts.SyntaxKind.EqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.PlusEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.MinusEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.AsteriskEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.SlashEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.PercentEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.AsteriskAsteriskEqualsToken)
    ) {
      const decl = this.tast.declarationOf(expr.left);
      return decl !== undefined && this.slots.has(decl);
    }
    // `const n = ++count` / `count++` value positions read a number slot.
    if (
      ts.isPostfixUnaryExpression(expr) ||
      (ts.isPrefixUnaryExpression(expr) &&
        (expr.operator === ts.SyntaxKind.PlusPlusToken || expr.operator === ts.SyntaxKind.MinusMinusToken))
    ) {
      return true;
    }
    if (
      ts.isPrefixUnaryExpression(expr) &&
      (expr.operator === ts.SyntaxKind.MinusToken ||
        expr.operator === ts.SyntaxKind.PlusToken ||
        expr.operator === ts.SyntaxKind.TildeToken)
    ) {
      return expr.operator === ts.SyntaxKind.TildeToken || this.numericInit(expr.operand);
    }
    if (ts.isBinaryExpression(expr)) {
      switch (expr.operatorToken.kind) {
        case ts.SyntaxKind.PlusToken:
        case ts.SyntaxKind.MinusToken:
        case ts.SyntaxKind.AsteriskToken:
        case ts.SyntaxKind.SlashToken:
        case ts.SyntaxKind.PercentToken:
        case ts.SyntaxKind.AsteriskAsteriskToken:
        case ts.SyntaxKind.AmpersandToken:
        case ts.SyntaxKind.BarToken:
        case ts.SyntaxKind.CaretToken:
        case ts.SyntaxKind.LessThanLessThanToken:
        case ts.SyntaxKind.GreaterThanGreaterThanToken:
        case ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken:
          return true;
        case ts.SyntaxKind.QuestionQuestionToken:
          // `model.cursor ?? 0` is a number when a branch is numeric.
          return this.numericInit(expr.left) || this.numericInit(expr.right);
        default:
          return false;
      }
    }
    if (ts.isCallExpression(expr)) {
      // A reduce value is numeric when its initial value is (slot collection
      // has not reached the accumulator parameter yet at this point).
      if (
        ts.isPropertyAccessExpression(expr.expression) &&
        expr.expression.name.text === "reduce" &&
        expr.arguments[1]
      ) {
        return this.numericInit(expr.arguments[1]);
      }
      const c = this.contribution(expr);
      return c.slots.length > 0 || c.intSource || c.float;
    }
    if (ts.isPropertyAccessExpression(expr)) {
      if (expr.name.text === "length") return true;
      return this.slotOfName(expr.name) !== undefined;
    }
    if (ts.isIdentifier(expr)) {
      const decl = this.tast.declarationOf(expr);
      return decl !== undefined && this.slots.has(decl);
    }
    if (ts.isElementAccessExpression(expr)) return true;
    if (ts.isConditionalExpression(expr)) {
      return this.numericInit(expr.whenTrue) || this.numericInit(expr.whenFalse);
    }
    return false;
  }

  /// The record field a `const { a } = expr;` binding element reads,
  /// resolved through the initializer's declared type — the table is keyed
  /// by name, and NS1038 keeps type names unique across the core's files.
  private destructuredField(el: ts.BindingElement): import("./types.ts").ZField | null {
    const pattern = el.parent;
    if (!ts.isObjectBindingPattern(pattern)) return null;
    const varDecl = pattern.parent;
    if (!ts.isVariableDeclaration(varDecl) || !varDecl.initializer) return null;
    const t = this.tast.typeOf(varDecl.initializer);
    const typeName = t.aliasSymbol?.name ?? t.symbol?.name;
    const struct = typeName ? this.table.structs.get(typeName) : undefined;
    const prop =
      el.propertyName && ts.isIdentifier(el.propertyName)
        ? el.propertyName.text
        : ts.isIdentifier(el.name)
          ? el.name.text
          : null;
    return struct?.fields.find((x) => x.tsName === prop) ?? null;
  }

  /// The second parameter of an arrow handed to an index-carrying array
  /// method — the JS element index, a proven integer (the emitted loop
  /// index widened to i64).
  private isCallbackIndexParam(arrow: ts.ArrowFunction, param: ts.ParameterDeclaration): boolean {
    if (arrow.parameters.length < 2 || arrow.parameters[1] !== param) return false;
    const call = arrow.parent;
    return (
      ts.isCallExpression(call) &&
      call.arguments[0] === arrow &&
      ts.isPropertyAccessExpression(call.expression) &&
      indexCarryingMethods.has(call.expression.name.text)
    );
  }

  /// The first parameter of a two-parameter arrow handed to `.reduce`.
  private isReduceAccumulator(arrow: ts.ArrowFunction, param: ts.ParameterDeclaration): boolean {
    if (arrow.parameters.length !== 2 || arrow.parameters[0] !== param) return false;
    const call = arrow.parent;
    return (
      ts.isCallExpression(call) &&
      call.arguments[0] === arrow &&
      ts.isPropertyAccessExpression(call.expression) &&
      call.expression.name.text === "reduce"
    );
  }

  /// External slots: the host constructs these — Msg-reachable number fields
  /// and number parameters of exported functions.
  private markExternal(): void {
    const seen = new Set<string>();
    const markType = (name: string): void => {
      if (seen.has(name)) return;
      seen.add(name);
      const union = this.table.unions.get(name);
      if (union) {
        for (const arm of union.arms) {
          for (const f of arm.fields) {
            this.markField(f.decl, f.type.k);
            this.markNested(f.type, markType);
          }
        }
      }
      const struct = this.table.structs.get(name);
      if (struct) {
        for (const f of struct.fields) {
          this.markField(f.decl, f.type.k);
          this.markNested(f.type, markType);
        }
      }
    };
    markType("Msg");
    // Only the ENTRY module's exports face the host ABI (the wiring and
    // markup bind through the entry). An exported function in an imported
    // module is an ordinary cross-module call, so proof still applies —
    // unless the entry's export list re-exports it, which puts it on the
    // entry surface like any other export.
    //
    // Both export spellings mark: the inline modifier and an un-renamed
    // export list entry (`export { pinchMsg }`) export the DECLARATION
    // itself (the emitter's isExportedDecl seam emits them identically),
    // so boundary classing must see them identically too. Renamed entries
    // stay out on purpose: renamed wiring names never reach inference
    // (the checker fences them, NS1014/NS1047), and a renamed ordinary
    // function keeps its historical classing.
    const entryExportedFns = new Set<ts.FunctionDeclaration>();
    for (const stmt of this.files[0].statements) {
      if (ts.isFunctionDeclaration(stmt) && stmt.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword)) {
        entryExportedFns.add(stmt);
      }
    }
    for (const b of exportListBindings(this.tast, this.files[0])) {
      if (!b.renamed && b.target && ts.isFunctionDeclaration(b.target)) entryExportedFns.add(b.target);
    }
    for (const stmt of entryExportedFns) {
      for (const p of stmt.parameters) {
        const slot = this.slots.get(p);
        if (slot) {
          slot.external = true;
          slot.hostBoundary = true;
          slot.proven = false;
        }
      }
      // The pinch channel's parameter record is intrinsically
      // fractional: magnification deltas are ~0.01..0.3 per event and
      // the pointer anchor is sub-point, so its number fields are HOST
      // values, never provable integers. Marking them boundary-fed
      // keeps a core's `pinch.scale === 0` comparison from
      // int-claiming the slot (which would round every zoom product
      // to whole numbers); the integer side of such a comparison
      // widens to f64 instead. The loop marks EVERY field of the
      // record, so any field the channel grows (windowId, the source
      // identity, included) is boundary-classed without a new rule.
      // frameMsg/keyMsg records keep their historical by-usage
      // classing.
      if (stmt.name?.text === "pinchMsg") {
        for (const p of stmt.parameters) {
          if (!p.type) continue;
          const t = this.table.resolveTypeNode(p.type);
          if (t.k !== "struct") continue;
          const struct = this.table.structs.get(t.name);
          if (!struct) continue;
          for (const f of struct.fields) {
            const slot = this.slots.get(f.decl);
            if (slot) {
              slot.external = true;
              slot.hostBoundary = true;
              slot.proven = false;
            }
          }
        }
      }
    }
  }

  private markField(decl: ts.Node, _kind: string): void {
    const slot = this.slots.get(decl);
    if (slot) {
      slot.external = true;
      slot.proven = false;
    }
  }

  private markNested(t: import("./types.ts").ZType, markType: (n: string) => void): void {
    switch (t.k) {
      case "struct":
      case "union":
        markType(t.name);
        break;
      case "slice":
        this.markNested(t.elem, markType);
        break;
      case "optional":
        this.markNested(t.inner, markType);
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------- flow analysis

  private slotOfNode(node: ts.Node): Slot | undefined {
    return this.slots.get(node);
  }

  /// Whether an expression is an `import * as ns` alias (by its own symbol,
  /// so shadowing locals do not count).
  private isNamespaceAliasBase(e: ts.Expression): boolean {
    if (!ts.isIdentifier(e)) return false;
    const sym = this.tast.symbolOf(e);
    const d = sym?.declarations?.[0];
    return d !== undefined && ts.isNamespaceImport(d);
  }

  /// The class MethodDeclaration a property-access callee resolves to,
  /// else null (R19 dispatch, shared by flows and contributions).
  private methodDeclOf(callee: ts.PropertyAccessExpression): ts.MethodDeclaration | null {
    const decl = this.tast.declarationOf(callee.name);
    return decl && ts.isMethodDeclaration(decl) && ts.isClassDeclaration(decl.parent) ? decl : null;
  }

  private slotOfName(name: ts.Node): Slot | undefined {
    const decl = this.tast.declarationOf(name);
    if (decl) return this.slots.get(decl);
    // A catch binding's field read (`e.at`): tsc types the binding as `any`
    // here (no symbol resolves), but the subset types it as the core's
    // thrown shape — resolve the field's declaration through it so payload
    // reads share the field's own slot.
    const p = name.parent;
    if (
      ts.isPropertyAccessExpression(p) &&
      p.name === name &&
      ts.isIdentifier(name) &&
      this.isCatchBinding(p.expression)
    ) {
      const fieldDecl = this.thrownFieldDecl(name.text);
      if (fieldDecl) return this.slots.get(fieldDecl);
    }
    return undefined;
  }

  /// Whether an expression is a `catch (e)` binding (by declaration).
  private isCatchBinding(e: ts.Expression): boolean {
    let cur = e;
    while (ts.isParenthesizedExpression(cur)) cur = cur.expression;
    if (!ts.isIdentifier(cur)) return false;
    const d = this.tast.declarationOf(cur);
    return d !== undefined && ts.isVariableDeclaration(d) && ts.isCatchClause(d.parent);
  }

  /// The declaration of the thrown shape's field with this name (first
  /// match across the thrown union's arms), memoized per inference run.
  private thrownShapeMemo: import("./types.ts").ZType | null | undefined;
  private thrownFieldDecl(name: string): ts.Declaration | null {
    if (this.thrownShapeMemo === undefined) {
      this.thrownShapeMemo = thrownShapeOf(this.tast, this.table, this.files).shape;
    }
    const shape = this.thrownShapeMemo;
    if (!shape) return null;
    if (shape.k === "union") {
      for (const arm of this.table.unions.get(shape.name)?.arms ?? []) {
        const f = arm.fields.find((x) => x.tsName === name);
        if (f) return f.decl;
      }
      return null;
    }
    if (shape.k === "struct") {
      return this.table.structs.get(shape.name)?.fields.find((x) => x.tsName === name)?.decl ?? null;
    }
    return null;
  }

  /// The number slots and source classes contributing to an expression.
  contribution(expr: ts.Expression): Contribution {
    const c: Contribution = { slots: [], float: false, unknown: false, intSource: false, site: expr };
    this.contribute(expr, c);
    return c;
  }

  private contribute(expr: ts.Expression, c: Contribution): void {
    if (
      ts.isParenthesizedExpression(expr) ||
      ts.isAsExpression(expr) ||
      ts.isNonNullExpression(expr) ||
      ts.isSatisfiesExpression(expr)
    ) {
      return this.contribute(expr.expression, c);
    }
    if (ts.isNumericLiteral(expr)) {
      if (Number.isInteger(Number(expr.text)) && !expr.text.includes(".") && !/[eE]/.test(expr.text)) {
        c.intSource = true;
      } else {
        c.float = true;
      }
      return;
    }
    if (ts.isPostfixUnaryExpression(expr)) {
      // `i++` in value position: the value is the slot's own (pre-step).
      return this.contribute(expr.operand, c);
    }
    if (ts.isPrefixUnaryExpression(expr)) {
      if (expr.operator === ts.SyntaxKind.PlusPlusToken || expr.operator === ts.SyntaxKind.MinusMinusToken) {
        return this.contribute(expr.operand, c);
      }
      if (expr.operator === ts.SyntaxKind.MinusToken || expr.operator === ts.SyntaxKind.PlusToken) {
        // `-0` (and any negation folding to -0) is a float source: i64 has no
        // signed zero, so an int-claimed slot would return +0 where node
        // keeps -0 — the same family as the % fold rule below.
        const folded = this.tast.constEvalNumber(expr);
        if (folded !== null && Object.is(folded, -0)) {
          c.float = true;
          return;
        }
        return this.contribute(expr.operand, c);
      }
      if (expr.operator === ts.SyntaxKind.TildeToken) {
        // `~x` is ToInt32 then bitwise-not: always a signed 32-bit integer.
        c.intSource = true;
        return;
      }
      return;
    }
    if (ts.isIdentifier(expr)) {
      const slot = this.slotOfName(expr);
      if (slot) {
        c.slots.push(slot);
        return;
      }
      // The NaN/Infinity globals are definitely-float values (a shadowing
      // declaration in this module does not count).
      if (expr.text === "NaN" || expr.text === "Infinity") {
        const decl = this.tast.declarationOf(expr);
        if (!decl || !this.fileSet.has(decl.getSourceFile())) c.float = true;
        return;
      }
      // R15e: a slot typed by a TYPE PARAMETER has no inference slot; under
      // an active instantiation scope it resolves — `T = number` slots are
      // f64 (the JS-exact class), so they read as definitely-float here.
      {
        const decl = this.tast.declarationOf(expr);
        const typeNode =
          decl && (ts.isParameter(decl) || ts.isVariableDeclaration(decl)) ? decl.type : undefined;
        if (typeNode) {
          const t = this.table.resolveTypeNode(typeNode);
          if (t.k === "f64" || (t.k === "optional" && t.inner.k === "f64")) c.float = true;
        }
      }
      return;
    }
    if (ts.isPropertyAccessExpression(expr)) {
      if (expr.name.text === "length") {
        c.intSource = true;
        return;
      }
      const slot = this.slotOfName(expr.name);
      if (slot) c.slots.push(slot);
      return;
    }
    if (ts.isElementAccessExpression(expr)) {
      // Byte reads are integer-valued, and numeric-literal-union elements
      // (e.g. RunClass arrays) carry integer members. A plain number-ARRAY
      // element is f64 — R2 covers slots, not elements — so it reads as a
      // definitely-float source, the same rule as callback captures.
      if (this.tast.isBytesTyped(expr.expression)) {
        c.intSource = true;
        return;
      }
      const t = this.tast.typeOf(expr);
      const members = t.isUnion() ? t.types : [t];
      if (members.every((m) => m.isNumberLiteral())) {
        c.intSource = true;
        return;
      }
      c.float = true;
      return;
    }
    if (ts.isBinaryExpression(expr)) {
      switch (expr.operatorToken.kind) {
        case ts.SyntaxKind.SlashToken:
        case ts.SyntaxKind.AsteriskAsteriskToken:
          // Division is float always; `**` follows it (2 ** -2 is 0.25, and
          // the NaN/Infinity corners are float-only values).
          c.float = true;
          this.contribute(expr.left, c);
          this.contribute(expr.right, c);
          return;
        case ts.SyntaxKind.PercentToken: {
          // A remainder that folds to a non-integer is a float source even
          // over integer operands: a zero (or -0) divisor makes NaN, and a
          // negative dividend can make -0 (both spelled f64Literal at emit).
          const folded = this.tast.constEvalNumber(expr);
          if (folded !== null && (!Number.isInteger(folded) || Object.is(folded, -0))) {
            c.float = true;
            return;
          }
          this.contribute(expr.left, c);
          this.contribute(expr.right, c);
          return;
        }
        case ts.SyntaxKind.PlusToken:
        case ts.SyntaxKind.MinusToken:
        case ts.SyntaxKind.AsteriskToken: {
          // Constant arithmetic that folds to -0 (`0 * -1`) is a float
          // source even over integer operands, same as the % rule below.
          const folded = this.tast.constEvalNumber(expr);
          if (folded !== null && Object.is(folded, -0)) {
            c.float = true;
            return;
          }
          this.contribute(expr.left, c);
          this.contribute(expr.right, c);
          return;
        }
        case ts.SyntaxKind.AmpersandToken:
        case ts.SyntaxKind.BarToken:
        case ts.SyntaxKind.CaretToken:
        case ts.SyntaxKind.LessThanLessThanToken:
        case ts.SyntaxKind.GreaterThanGreaterThanToken:
        case ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken:
        case ts.SyntaxKind.QuestionQuestionToken:
          this.contribute(expr.left, c);
          this.contribute(expr.right, c);
          return;
        case ts.SyntaxKind.EqualsToken:
        case ts.SyntaxKind.PlusEqualsToken:
        case ts.SyntaxKind.MinusEqualsToken:
        case ts.SyntaxKind.AsteriskEqualsToken:
        case ts.SyntaxKind.SlashEqualsToken:
        case ts.SyntaxKind.PercentEqualsToken:
        case ts.SyntaxKind.AsteriskAsteriskEqualsToken:
          // An assignment in value position reads the target after the
          // statement — the target slot's own value.
          this.contribute(expr.left, c);
          return;
        default:
          return; // comparisons/logic produce booleans
      }
    }
    if (ts.isConditionalExpression(expr)) {
      this.contribute(expr.whenTrue, c);
      this.contribute(expr.whenFalse, c);
      return;
    }
    if (ts.isCallExpression(expr)) {
      const callee = expr.expression;
      if (ts.isPropertyAccessExpression(callee) && this.isNamespaceAliasBase(callee.expression)) {
        // `ns.helper()` contributes the target function's return slot.
        const decl = this.tast.declarationOf(callee.name);
        const ret = decl && ts.isFunctionDeclaration(decl) ? this.slots.get(decl) : undefined;
        if (ret) c.slots.push(ret);
        else c.unknown = true;
        return;
      }
      if (ts.isPropertyAccessExpression(callee) && this.methodDeclOf(callee) !== null) {
        // R19: a data-class method call contributes its return slot.
        const ret = this.slots.get(this.methodDeclOf(callee)!);
        if (ret) c.slots.push(ret);
        else c.unknown = true;
        return;
      }
      if (ts.isPropertyAccessExpression(callee)) {
        const method = callee.name.text;
        if (ts.isIdentifier(callee.expression) && callee.expression.text === "Math") {
          // A Math call that folds at compile time contributes its folded JS
          // value's own class — `Math.floor(5 / 2)` is the integer 2 even
          // though the division inside is a float source.
          const folded = this.tast.constEvalNumber(expr);
          if (folded !== null) {
            if (Number.isInteger(folded) && !Object.is(folded, -0)) c.intSource = true;
            else c.float = true;
            return;
          }
          if (method === "min" || method === "max") {
            if (expr.arguments.length === 0) {
              // Math.min() is Infinity, Math.max() is -Infinity.
              c.float = true;
              return;
            }
            for (const arg of expr.arguments) this.contribute(arg, c);
            return;
          }
          if (method === "floor" || method === "ceil" || method === "trunc" || method === "abs" || method === "sign") {
            // Integer-classed argument in, integer-classed value out (the
            // identity/abs/sign of an integer). A float argument keeps the
            // result float: floor(NaN) is NaN, floor(Infinity) is Infinity,
            // so no integer type can hold the result soundly.
            for (const arg of expr.arguments) this.contribute(arg, c);
            return;
          }
          if (method === "round" || method === "sqrt") {
            // Definitely-float sources: round/sqrt of NaN/Infinity is not an
            // integer (and sqrt is irrational off perfect squares), so these
            // live in f64 slots and an index use is a taught conflict. The
            // argument stays unconstrained — an integer-classed read widens
            // at the site.
            c.float = true;
            return;
          }
          c.unknown = true;
          return;
        }
        if (method === "charCodeAt" || method === "indexOf" || method === "lastIndexOf" || method === "findIndex" || method === "length") {
          c.intSource = true;
          return;
        }
        if (method === "at") {
          // Bytes `.at(i)` — byte values are integers (the same rule as a
          // bytes element read; strings have no `.at` past the checker).
          c.intSource = true;
          return;
        }
        if (method === "reduce") {
          // The value of a reduce IS its accumulator slot (fed by the initial
          // value and the body result; flows wired in collectFlows).
          const arrow = expr.arguments[0];
          const accP = arrow !== undefined && ts.isArrowFunction(arrow) ? arrow.parameters[0] : undefined;
          const slot = accP ? this.slots.get(accP) : undefined;
          if (slot) {
            c.slots.push(slot);
          } else {
            c.unknown = true;
          }
          return;
        }
        if (method === "find" || method === "pop" || method === "shift") {
          // Array elements are f64-classed (R2 covers slots, not elements),
          // so a find/pop/shift value reads as a definitely-float source in
          // numeric positions — an index use downstream is a taught NS1016.
          c.float = true;
          return;
        }
        c.unknown = true;
        return;
      }
      if (ts.isIdentifier(callee)) {
        const decl = this.tast.declarationOf(callee);
        if (decl && ts.isFunctionDeclaration(decl)) {
          const ret = this.slots.get(decl);
          if (ret) {
            c.slots.push(ret);
            return;
          }
        }
        // A hoisted local helper's numbers emit f64 (its parameter slots
        // are element-style float slots), so its call value reads float.
        if (decl && ts.isVariableDeclaration(decl)) {
          const fn = constFunctionValue(decl);
          if (fn?.type && this.numberish(fn.type)) {
            c.float = true;
            return;
          }
        }
      }
      c.unknown = true;
      return;
    }
    // Anything else (object/array literals, template strings) contributes no
    // number value in a numeric position; mark unknown to stay conservative.
    if (
      ts.isObjectLiteralExpression(expr) ||
      ts.isArrayLiteralExpression(expr) ||
      ts.isTemplateExpression(expr) ||
      ts.isStringLiteral(expr) ||
      expr.kind === ts.SyntaxKind.NullKeyword ||
      expr.kind === ts.SyntaxKind.TrueKeyword ||
      expr.kind === ts.SyntaxKind.FalseKeyword ||
      ts.isNewExpression(expr) ||
      ts.isArrowFunction(expr)
    ) {
      return;
    }
    c.unknown = true;
  }

  private flowInto(target: ts.Node | undefined, expr: ts.Expression): void {
    if (!target) return;
    const slot = this.slots.get(target);
    if (!slot) return;
    slot.inflows.push(this.contribution(expr));
  }

  private demand(expr: ts.Expression): void {
    this.demandSeeds.push(this.contribution(expr));
  }

  private collectFlows(): void {
    const enclosingFunction = (node: ts.Node): ts.Node | undefined => {
      let cur: ts.Node | undefined = node.parent;
      while (cur) {
        if (
          ts.isFunctionDeclaration(cur) ||
          ts.isArrowFunction(cur) ||
          ts.isFunctionExpression(cur) ||
          ts.isMethodDeclaration(cur) ||
          ts.isConstructorDeclaration(cur)
        ) {
          return cur;
        }
        cur = cur.parent;
      }
      return undefined;
    };

    /// A class-field slot written through a property access (`this.x = e`,
    /// `t.x = e`), else undefined — assignment flows wire into it exactly
    /// like a local's.
    const fieldAssignTarget = (left: ts.Expression): ts.Node | undefined => {
      if (!ts.isPropertyAccessExpression(left)) return undefined;
      const decl = this.tast.declarationOf(left.name);
      return decl && ts.isPropertyDeclaration(decl) ? decl : undefined;
    };

    const visit = (node: ts.Node): void => {
      if (ts.isVariableDeclaration(node) && node.initializer && ts.isIdentifier(node.name)) {
        this.flowInto(node, node.initializer);
      } else if (ts.isPropertyDeclaration(node) && node.initializer && ts.isIdentifier(node.name)) {
        // R19: `count: number = 0` feeds the field slot like a local's init.
        this.flowInto(node, node.initializer);
      } else if (ts.isBindingElement(node) && ts.isIdentifier(node.name)) {
        // `const { total } = stats;` — the local is fed by the record field's
        // own slot, so its machine class follows the field's. An
        // unresolvable base stays a conservative unknown (kills proof).
        const slot = this.slots.get(node);
        if (slot) {
          const f = this.destructuredField(node);
          const fieldSlot = f ? this.slots.get(f.decl) : undefined;
          slot.inflows.push({
            slots: fieldSlot ? [fieldSlot] : [],
            float: false,
            unknown: fieldSlot === undefined,
            intSource: false,
            site: node.name,
          });
        }
      } else if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.TildeToken) {
        // `~x` applies ToInt32: the operand is an integer-required position.
        this.demand(node.operand);
      } else if (ts.isBinaryExpression(node)) {
        const op = node.operatorToken.kind;
        if (op === ts.SyntaxKind.EqualsToken && ts.isIdentifier(node.left)) {
          const decl = this.tast.declarationOf(node.left);
          this.flowInto(decl, node.right);
        } else if (op === ts.SyntaxKind.EqualsToken && fieldAssignTarget(node.left) !== undefined) {
          this.flowInto(fieldAssignTarget(node.left), node.right);
        } else if (
          op === ts.SyntaxKind.PlusEqualsToken ||
          op === ts.SyntaxKind.MinusEqualsToken ||
          op === ts.SyntaxKind.AsteriskEqualsToken ||
          op === ts.SyntaxKind.PercentEqualsToken ||
          op === ts.SyntaxKind.QuestionQuestionEqualsToken
        ) {
          if (ts.isIdentifier(node.left)) this.flowInto(this.tast.declarationOf(node.left), node.right);
          else if (fieldAssignTarget(node.left) !== undefined) this.flowInto(fieldAssignTarget(node.left), node.right);
        } else if (
          op === ts.SyntaxKind.SlashEqualsToken ||
          op === ts.SyntaxKind.AsteriskAsteriskEqualsToken
        ) {
          // `x /= y` and `x **= y` assign a float-always result into x.
          if (ts.isIdentifier(node.left)) {
            const decl = this.tast.declarationOf(node.left);
            const slot = decl ? this.slots.get(decl) : undefined;
            if (slot) {
              const c = this.contribution(node.right);
              c.float = true;
              slot.inflows.push(c);
            }
          }
        } else if (
          op === ts.SyntaxKind.AmpersandEqualsToken ||
          op === ts.SyntaxKind.BarEqualsToken ||
          op === ts.SyntaxKind.CaretEqualsToken ||
          op === ts.SyntaxKind.LessThanLessThanEqualsToken ||
          op === ts.SyntaxKind.GreaterThanGreaterThanEqualsToken ||
          op === ts.SyntaxKind.GreaterThanGreaterThanGreaterThanEqualsToken
        ) {
          // Bitwise/shift compounds: both sides are integer-required, and
          // the assigned result is a definite ToInt32/ToUint32 integer.
          this.demand(node.left);
          this.demand(node.right);
          if (ts.isIdentifier(node.left)) {
            const decl = this.tast.declarationOf(node.left);
            const slot = decl ? this.slots.get(decl) : undefined;
            if (slot) {
              slot.inflows.push({ slots: [], float: false, unknown: false, intSource: true, site: node.right });
            }
          }
        } else if (
          op === ts.SyntaxKind.AmpersandToken ||
          op === ts.SyntaxKind.BarToken ||
          op === ts.SyntaxKind.CaretToken ||
          op === ts.SyntaxKind.LessThanLessThanToken ||
          op === ts.SyntaxKind.GreaterThanGreaterThanToken ||
          op === ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken
        ) {
          this.demand(node.left);
          this.demand(node.right);
        } else if (
          op === ts.SyntaxKind.EqualsEqualsEqualsToken ||
          op === ts.SyntaxKind.ExclamationEqualsEqualsToken ||
          op === ts.SyntaxKind.LessThanToken ||
          op === ts.SyntaxKind.LessThanEqualsToken ||
          op === ts.SyntaxKind.GreaterThanToken ||
          op === ts.SyntaxKind.GreaterThanEqualsToken
        ) {
          this.compareSites.push({ left: this.contribution(node.left), right: this.contribution(node.right) });
        } else if (
          op === ts.SyntaxKind.PlusToken ||
          op === ts.SyntaxKind.MinusToken ||
          op === ts.SyntaxKind.AsteriskToken ||
          op === ts.SyntaxKind.PercentToken
        ) {
          this.mixSites.push({ left: this.contribution(node.left), right: this.contribution(node.right) });
        }
      } else if (ts.isElementAccessExpression(node)) {
        this.demand(node.argumentExpression);
      } else if (ts.isAsExpression(node) && ts.isObjectLiteralExpression(node.expression)) {
        // `{ kind: "outer", n: err.n } as Fail` (throw payloads, mostly):
        // the assertion IS the contextual type — wire each member into the
        // asserted shape's field slot, arm-matched by the kind tag.
        const t = this.table.resolveTypeNode(node.type);
        let fields: readonly { tsName: string; decl: ts.Declaration }[] | null = null;
        if (t.k === "struct") {
          fields = this.table.structs.get(t.name)?.fields ?? null;
        } else if (t.k === "union") {
          const kindProp = node.expression.properties.find(
            (pp): pp is ts.PropertyAssignment =>
              ts.isPropertyAssignment(pp) && ts.isIdentifier(pp.name) && pp.name.text === "kind",
          );
          const tag = kindProp && ts.isStringLiteral(kindProp.initializer) ? kindProp.initializer.text : null;
          fields = tag !== null ? (this.table.unions.get(t.name)?.arms.find((a) => a.tag === tag)?.fields ?? null) : null;
        }
        if (fields !== null) {
          for (const pp of node.expression.properties) {
            if (ts.isPropertyAssignment(pp) && ts.isIdentifier(pp.name)) {
              const fld = fields.find((x) => x.tsName === (pp.name as ts.Identifier).text);
              if (fld) this.flowInto(fld.decl, pp.initializer);
            } else if (ts.isShorthandPropertyAssignment(pp)) {
              const fld = fields.find((x) => x.tsName === pp.name.text);
              const slot = fld ? this.slots.get(fld.decl) : undefined;
              if (slot) {
                const valueDecl = this.tast.shorthandValueDeclaration(pp);
                const valueSlot = valueDecl ? this.slots.get(valueDecl) : undefined;
                slot.inflows.push({
                  slots: valueSlot ? [valueSlot] : [],
                  float: false,
                  unknown: valueSlot === undefined,
                  intSource: false,
                  site: pp.name,
                });
              }
            }
          }
        }
      } else if (ts.isPropertyAssignment(node)) {
        const target = this.tast.contextualPropDecl(node);
        this.flowInto(target, node.initializer);
      } else if (ts.isShorthandPropertyAssignment(node)) {
        const target = this.tast.contextualPropDecl(node as unknown as ts.PropertyAssignment);
        if (target) {
          const slot = this.slots.get(target);
          if (slot) {
            // The shorthand's name resolves to the PROPERTY symbol; the
            // value flowing in is the local/param it reads, which needs its
            // own symbol query. Unresolvable stays a conservative unknown
            // (kills proof), never a phantom integer proof.
            const valueDecl = this.tast.shorthandValueDeclaration(node);
            const valueSlot = valueDecl ? this.slots.get(valueDecl) : undefined;
            slot.inflows.push({
              slots: valueSlot ? [valueSlot] : [],
              float: false,
              unknown: valueSlot === undefined,
              intSource: false,
              site: node.name,
            });
          }
        }
      } else if (ts.isReturnStatement(node) && node.expression) {
        const fn = enclosingFunction(node);
        if (fn) this.flowInto(fn, node.expression);
      } else if (ts.isCallExpression(node)) {
        const callee = node.expression;
        if (ts.isIdentifier(callee)) {
          const decl = this.tast.declarationOf(callee);
          if (decl && ts.isFunctionDeclaration(decl)) {
            decl.parameters.forEach((p, i) => {
              const arg = node.arguments[i];
              if (arg) this.flowInto(p, arg);
            });
          }
        } else if (ts.isPropertyAccessExpression(callee) && this.isNamespaceAliasBase(callee.expression)) {
          // `ns.helper(x)` — the namespace alias erases, so arguments flow
          // into the target function's parameter slots exactly like a
          // direct call.
          const decl = this.tast.declarationOf(callee.name);
          if (decl && ts.isFunctionDeclaration(decl)) {
            decl.parameters.forEach((p, i) => {
              const arg = node.arguments[i];
              if (arg) this.flowInto(p, arg);
            });
          }
        } else if (ts.isPropertyAccessExpression(callee) && this.methodDeclOf(callee) !== null) {
          // R19: `t.method(x)` flows arguments into the method's parameter
          // slots, exactly like a direct call.
          this.methodDeclOf(callee)!.parameters.forEach((mp, i) => {
            const arg = node.arguments[i];
            if (arg) this.flowInto(mp, arg);
          });
        } else if (ts.isPropertyAccessExpression(callee)) {
          const method = callee.name.text;
          if (ts.isIdentifier(callee.expression) && callee.expression.text === "Math") {
            if ((method === "min" || method === "max") && node.arguments.length >= 2) {
              // Pairwise over consecutive arguments: demotion chains through,
              // so one float argument floats the whole site.
              for (let i = 0; i + 1 < node.arguments.length; i++) {
                this.mixSites.push({
                  left: this.contribution(node.arguments[i]),
                  right: this.contribution(node.arguments[i + 1]),
                });
              }
            }
          } else if (method === "subarray" || method === "slice" || method === "set" || method === "charCodeAt" || method === "repeat" || method === "at") {
            // repeat's count and at's index are integer positions, like
            // every index (a fractional flow is a taught NS1016).
            const start = method === "set" ? 1 : 0;
            for (let i = start; i < node.arguments.length; i++) this.demand(node.arguments[i]);
          } else if (method === "padStart" || method === "padEnd") {
            // The target BYTE length indexes memory; the fill is bytes.
            if (node.arguments[0]) this.demand(node.arguments[0]);
          } else if (method === "splice") {
            // start and deleteCount index memory (rt.sliceIndex); inserted
            // items are elements and stay unconstrained (f64 like all array
            // elements).
            for (let i = 0; i < Math.min(node.arguments.length, 2); i++) this.demand(node.arguments[i]);
          } else if (method === "fill") {
            // start/end index memory; the fill VALUE (argument 0) is an
            // element and stays unconstrained.
            for (let i = 1; i < node.arguments.length; i++) this.demand(node.arguments[i]);
          } else if (method === "reduce") {
            // The accumulator slot is fed by the initial value and by the
            // callback body's result (each iteration assigns it back) — for
            // a block body, by every `return` expression.
            const arrow = node.arguments[0];
            if (arrow && ts.isArrowFunction(arrow) && arrow.parameters.length === 2) {
              const accP = arrow.parameters[0];
              if (node.arguments[1]) this.flowInto(accP, node.arguments[1]);
              if (!ts.isBlock(arrow.body)) this.flowInto(accP, arrow.body);
              else for (const r of returnExpressionsOf(arrow.body)) this.flowInto(accP, r);
            }
          }
        }
      } else if (ts.isNewExpression(node)) {
        if (ts.isIdentifier(node.expression) && node.expression.text === "Uint8Array") {
          for (const arg of node.arguments ?? []) this.demand(arg);
        } else if (ts.isIdentifier(node.expression)) {
          // R19: `new C(x)` flows arguments into the constructor's
          // parameter slots, exactly like a direct call.
          const decl = this.tast.declarationOf(node.expression);
          if (decl && ts.isClassDeclaration(decl)) {
            const ctor = decl.members.find(
              (m): m is ts.ConstructorDeclaration => ts.isConstructorDeclaration(m) && m.body !== undefined,
            );
            ctor?.parameters.forEach((cp, i) => {
              const arg = node.arguments?.[i];
              if (arg) this.flowInto(cp, arg);
            });
          }
        }
      } else if (ts.isArrowFunction(node) && !ts.isBlock(node.body)) {
        this.flowInto(node, node.body);
      }
      ts.forEachChild(node, visit);
    };
    for (const file of this.files) visit(file);
  }

  // ------------------------------------------------------------- resolution

  private sideIsInt(c: Contribution): boolean {
    if (c.float || c.unknown) return false;
    if (c.slots.length === 0) return c.intSource;
    return c.slots.every((s) => !s.float && (s.proven || s.demanded));
  }

  /// Taint-only float check (demand phase): undecided slots are not float yet.
  private sideFloatTaint(c: Contribution): boolean {
    if (c.float) return true;
    return c.slots.some((s) => s.float);
  }

  /// Final float check (demotion phase): undecided slots resolve to f64.
  private sideIsFloat(c: Contribution): boolean {
    if (c.float) return true;
    return c.slots.some((s) => s.float) || (c.slots.length > 0 && c.slots.every((s) => this.finalClassOf(s) === "f64"));
  }

  private finalClassOf(s: Slot): "i64" | "f64" {
    if (s.float) return "f64";
    return s.proven || s.demanded ? "i64" : "f64";
  }

  private resolve(): void {
    const all = [...this.slots.values()];

    // Forward float taint from literal/div sources. The fixpoint flag is
    // LOCAL: this also runs inside the demotion loop below, and clobbering
    // that loop's `changed` would end its fixpoint one pass early (a
    // two-hop demotion chain — field -> destructured alias -> local —
    // would strand the far end as a phantom NS1016 conflict).
    let changed = true;
    const propagateFloat = () => {
      let moved = true;
      while (moved) {
        moved = false;
        for (const s of all) {
          if (s.float) continue;
          if (s.inflows.some((c) => c.float || c.slots.some((x) => x.float))) {
            s.float = true;
            moved = true;
          }
        }
      }
    };
    propagateFloat();

    // Greatest-fixpoint integer proof: demote until stable.
    changed = true;
    while (changed) {
      changed = false;
      for (const s of all) {
        if (!s.proven) continue;
        const bad =
          s.float ||
          s.external ||
          s.inflows.some((c) => c.float || c.unknown || c.slots.some((x) => !x.proven || x.float));
        if (bad) {
          s.proven = false;
          changed = true;
        }
      }
    }

    // Least-fixpoint demand: seeds, backward through inflows, plus
    // comparisons against proven/demanded integer sides. Comparison-origin
    // demand never claims a host-boundary slot, nor any slot a host-boundary
    // slot feeds: the comparison itself does not require an integer (the
    // emitter widens the integer side into f64 instead), and an i64-claimed
    // exported signature would truncate host f64 values that node compares
    // exactly — claiming only part of such a chain would manufacture an
    // NS1016 conflict out of thin air. Genuine demand chains (index,
    // bitwise, size positions) still claim host params — there the emitted
    // i64 signature is the contract type the wiring builds against.
    const boundaryFed = new Map<Slot, boolean>();
    const touchesBoundary = (s: Slot): boolean => {
      const memo = boundaryFed.get(s);
      if (memo !== undefined) return memo;
      boundaryFed.set(s, false); // cycle guard: a cycle adds no boundary
      const touched =
        s.hostBoundary || s.inflows.some((c) => !c.float && c.slots.some((x) => touchesBoundary(x)));
      boundaryFed.set(s, touched);
      return touched;
    };
    const demandSlot = (s: Slot, viaComparison: boolean): void => {
      if (s.float) return;
      if (s.demanded) {
        // A hard requirement reaching a tentatively-claimed slot upgrades
        // it (and its backward chain): the claim stops being yieldable.
        if (!viaComparison && s.comparisonDemanded) {
          s.comparisonDemanded = false;
          for (const c of s.inflows) {
            if (c.float) continue;
            for (const x of c.slots) demandSlot(x, false);
          }
        }
        return;
      }
      if (viaComparison && touchesBoundary(s)) return;
      s.demanded = true;
      s.comparisonDemanded = viaComparison;
      for (const c of s.inflows) {
        if (c.float) continue;
        for (const x of c.slots) demandSlot(x, viaComparison);
      }
    };
    for (const c of this.demandSeeds) {
      if (c.float) continue;
      for (const s of c.slots) demandSlot(s, false);
    }
    changed = true;
    while (changed) {
      changed = false;
      for (const site of this.compareSites) {
        const pairs: Array<[Contribution, Contribution]> = [
          [site.left, site.right],
          [site.right, site.left],
        ];
        for (const [a, b] of pairs) {
          if (this.sideIsInt(a) && !this.sideFloatTaint(b)) {
            // A side partly fed by the host boundary resolves f64 as a
            // whole; claiming its other slots would only split the side.
            if (b.slots.some((s) => touchesBoundary(s))) continue;
            for (const s of b.slots) {
              if (!s.demanded && !s.float) {
                demandSlot(s, true);
                changed = true;
              }
            }
          }
        }
      }
    }

    // Forward demand across assignment edges: a demanded source is i64, so
    // the slot it is assigned into must match (and its other sources follow
    // through demandSlot's backward recursion). Tentativeness rides along:
    // a slot fed only by comparison-claimed sources is itself yieldable,
    // while a hard-demanded source hardens what it feeds.
    changed = true;
    while (changed) {
      changed = false;
      for (const s of all) {
        if (s.float) continue;
        const hardFed = s.inflows.some(
          (c) => !c.float && c.slots.some((x) => !x.float && x.demanded && !x.comparisonDemanded),
        );
        if (!s.demanded) {
          const tentativeFed = s.inflows.some(
            (c) => !c.float && c.slots.some((x) => !x.float && x.demanded && x.comparisonDemanded),
          );
          if (hardFed || tentativeFed) {
            demandSlot(s, !hardFed);
            changed = true;
          }
        } else if (s.comparisonDemanded && hardFed) {
          demandSlot(s, false);
          changed = true;
        }
      }
    }

    // Mixed-site and assignment-edge demotion: an unclaimed integer slot
    // meeting a float side becomes f64, and an f64-resolving slot demotes
    // the proven-but-undemanded slots assigned into it — every edge lands
    // same-typed unless a HARD-demanded slot meets float (a reported
    // conflict). Comparison-claimed slots yield here: the tentative claim
    // existed only to keep the comparison same-typed, so float reaching it
    // demotes the slot and the comparison widens instead of manufacturing
    // an NS1016 conflict.
    const demote = (s: Slot): boolean => {
      if (s.float) return false;
      if (s.demanded && !s.comparisonDemanded) return false;
      s.demanded = false;
      s.comparisonDemanded = false;
      s.float = true;
      s.proven = false;
      return true;
    };
    changed = true;
    while (changed) {
      changed = false;
      const sites = [...this.mixSites, ...this.compareSites];
      for (const site of sites) {
        const pairs: Array<[Contribution, Contribution]> = [
          [site.left, site.right],
          [site.right, site.left],
        ];
        for (const [a, b] of pairs) {
          if (!this.sideIsFloat(a)) continue;
          for (const s of b.slots) {
            // Claimed slots (tentative included) hold their class here:
            // the emitter widens the integer side of a mixed comparison
            // exactly, so a compare site never needs to demote a claim.
            if (!s.float && !s.demanded && this.finalClassOf(s) === "i64") {
              s.float = true;
              s.proven = false;
              changed = true;
            }
          }
        }
      }
      for (const s of all) {
        if (this.finalClassOf(s) !== "f64") continue;
        for (const c of s.inflows) {
          for (const x of c.slots) {
            if (demote(x)) changed = true;
          }
        }
      }
      // A tentative claim with float flowing straight into the slot yields
      // too — the same rule, seen from the inflow side.
      for (const s of all) {
        if (!s.demanded || !s.comparisonDemanded) continue;
        const floatIn = s.inflows.some((c) => c.float || c.slots.some((x) => x.float));
        if (floatIn && demote(s)) changed = true;
      }
      if (changed) propagateFloat();
    }

    this.collectConflicts();
  }

  /// Every edge the fixed point above could not make same-typed is a real
  /// int/float conflict; report it instead of emitting mismatched Zig.
  private collectConflicts(): void {
    const seen = new Set<ts.Node>();
    const report = (node: ts.Node, slotLabel: string): void => {
      if (seen.has(node)) return;
      seen.add(node);
      this.conflicts.push({ node, slotLabel });
    };
    for (const s of this.slots.values()) {
      if (s.demanded) {
        // An integer-required slot with float reaching it, directly or
        // through taint, cannot be emitted as either machine type.
        const src = s.inflows.find((c) => c.float || c.slots.some((x) => x.float));
        if (s.float || src) report(src?.site ?? s.decl, s.label);
      } else if (this.finalClassOf(s) === "f64") {
        for (const c of s.inflows) {
          const hard = c.slots.find((x) => this.finalClassOf(x) === "i64");
          if (hard) report(c.site, hard.label);
        }
      }
    }
    // Index/bitwise positions themselves: a float-valued expression can
    // never become the usize the memory site needs.
    for (const c of this.demandSeeds) {
      if (c.float || c.slots.some((x) => this.finalClassOf(x) === "f64")) {
        report(c.site, c.site.getText().replace(/\s+/g, " "));
      }
    }
    for (const site of this.mixSites) {
      const pairs: Array<[Contribution, Contribution]> = [
        [site.left, site.right],
        [site.right, site.left],
      ];
      for (const [a, b] of pairs) {
        if (!this.sideIsFloat(a)) continue;
        const hard = b.slots.find((x) => this.finalClassOf(x) === "i64");
        if (hard) report(b.site, hard.label);
      }
    }
    // Comparisons are looser than mixes: an INTERNAL i64 slot holds only
    // integer values by proof, so the emitter widens its read exactly and
    // the comparison agrees with node bit for bit — no conflict. An
    // EXTERNAL i64-claimed slot is different: node can receive a fraction
    // there that the emitted i64 boundary cannot represent, so a float
    // comparison against it is a real divergence to teach.
    for (const site of this.compareSites) {
      const pairs: Array<[Contribution, Contribution]> = [
        [site.left, site.right],
        [site.right, site.left],
      ];
      for (const [a, b] of pairs) {
        if (!this.sideIsFloat(a)) continue;
        const hard = b.slots.find((x) => this.finalClassOf(x) === "i64" && x.external);
        if (hard) report(b.site, hard.label);
      }
    }
  }

  // ------------------------------------------------------------------ query

  /// Final emission class of a number slot's declaration.
  classOfDecl(decl: ts.Node): "i64" | "f64" | null {
    const s = this.slots.get(decl);
    return s ? this.finalClassOf(s) : null;
  }

  /// Final emission class of a numeric expression.
  classOfExpr(expr: ts.Expression): "i64" | "f64" {
    const c = this.contribution(expr);
    if (c.float) return "f64";
    if (c.slots.length === 0) return "i64";
    return c.slots.every((s) => this.finalClassOf(s) === "i64") ? "i64" : "f64";
  }

  debugDump(): string {
    return [...this.slots.values()]
      .map((s) => `${s.label}: ${this.finalClassOf(s)}${s.external ? " (ext)" : ""}${s.demanded ? " (dem)" : ""}${s.proven ? " (prov)" : ""}`)
      .join("\n");
  }
}

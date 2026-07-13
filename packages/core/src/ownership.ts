// Array ownership: the local-mutation rule, shared by the checker (the
// teaching layer) and the emitter (the layer-3 re-derivation).
//
// An array is LOCALLY OWNED at a mutation site iff it is a function-local
// binding created by the function's own array construction (an array
// literal, or a fresh copy from `.slice()`/`.map()`/`.filter()`/`.concat()`/
// `.toSorted()`) and the binding has not ESCAPED before the mutation: not
// returned, not passed to another function (the deliberate v1 conservatism —
// a callee could alias it), not stored into a structure, not aliased by a
// second binding. Reads never end ownership: method calls, element and
// `.length` access, `for...of` iteration, and spreads into fresh literals
// (which copy) all leave the array yours. Parameters, model/msg data, and
// module-level consts are never locally owned.
//
// Escapes gate by POSITION: a mutation is legal only when no escape sits
// before it. An escape inside a loop gates the whole loop body (the loop's
// second iteration would mutate after the first iteration's escape), so an
// escape's effective position is the start of its outermost enclosing loop.

import { ts, TypedAst, lineColumn } from "./typed_ast.ts";

/// Every JS array method that mutates its receiver (the checker's gate set).
export const mutatingArrayMethods = new Set([
  "push", "pop", "shift", "unshift", "splice", "sort", "reverse", "fill", "copyWithin",
]);

/// The mutating methods v1 supports on locally-owned arrays (`copyWithin`
/// stays out everywhere — splice/fill cover its uses).
export const ownedMutatingMethods = new Set([
  "push", "pop", "shift", "unshift", "splice", "sort", "reverse", "fill",
]);

/// Methods that change the array's LENGTH. These force the builder lowering
/// (a growable slice plus a live fill count) and may not run against the
/// array a loop is iterating — JS walks the live array there.
export const lengthChangingMethods = new Set(["push", "pop", "shift", "unshift", "splice"]);

/// Methods that can GROW the array (the emitted slice variable is reassigned
/// by rt.frameGrow, so its binding must be `var`).
export const growingMethods = new Set(["push", "unshift", "splice"]);

export type OwnershipVerdict =
  | { readonly owned: true; readonly decl: ts.VariableDeclaration }
  | { readonly owned: false; readonly why: "not-local"; readonly detail: string }
  | { readonly owned: false; readonly why: "escaped"; readonly detail: string };

export function unwrapExpr(e: ts.Expression): ts.Expression {
  while (
    ts.isParenthesizedExpression(e) ||
    ts.isAsExpression(e) ||
    ts.isSatisfiesExpression(e) ||
    ts.isNonNullExpression(e)
  ) {
    e = e.expression;
  }
  return e;
}

/// The owning constructors: expressions that create a FRESH array this
/// function is the only holder of.
export function isOwningInitializer(init: ts.Expression): boolean {
  const e = unwrapExpr(init);
  if (ts.isArrayLiteralExpression(e)) return true;
  return (
    ts.isCallExpression(e) &&
    ts.isPropertyAccessExpression(e.expression) &&
    // `.split` is the bytes method: a fresh array of views, the caller's own.
    ["slice", "map", "filter", "concat", "toSorted", "split"].includes(e.expression.name.text)
  );
}

export function enclosingFunctionOf(node: ts.Node): ts.Node | null {
  let cur: ts.Node | undefined = node.parent;
  while (cur && !ts.isSourceFile(cur)) {
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
  return null;
}

/// A `readonly T[]` parameter type (the borrow shape): the type operator
/// spelling or a ReadonlyArray reference. Bytes keep their own discipline.
function isReadonlySliceType(node: ts.TypeNode): boolean {
  if (ts.isTypeOperatorNode(node) && node.operator === ts.SyntaxKind.ReadonlyKeyword && ts.isArrayTypeNode(node.type)) {
    return true;
  }
  return ts.isTypeReferenceNode(node) && ts.isIdentifier(node.typeName) && node.typeName.text === "ReadonlyArray";
}

/// Whether passing `arg` into `call` BORROWS instead of escaping: the
/// resolved callee's parameter is declared `readonly T[]`, and the callee
/// provably cannot mutate or alias the value out — every use of the
/// parameter in its body is a read, or another borrowing pass (checked
/// coinductively, so mutual/self recursion over borrowed slices stays
/// legal: an in-progress parameter is assumed safe until a real escape
/// disproves it).
function borrowedByCall(
  tast: TypedAst,
  call: ts.CallExpression,
  arg: ts.Node,
  inProgress: Set<ts.ParameterDeclaration>,
): boolean {
  const idx = (call.arguments as readonly ts.Node[]).indexOf(arg);
  if (idx < 0) return false;
  if (call.arguments.slice(0, idx + 1).some((a) => ts.isSpreadElement(a))) return false;
  const callee = unwrapExpr(call.expression);
  if (!ts.isIdentifier(callee)) return false;
  const d = tast.declarationOf(callee);
  let params: readonly ts.ParameterDeclaration[] | null = null;
  let body: ts.Node | null = null;
  if (d && ts.isFunctionDeclaration(d) && d.body) {
    params = d.parameters;
    body = d.body;
  } else if (d && ts.isVariableDeclaration(d)) {
    const fnValue = constFunctionValue(d);
    if (fnValue) {
      params = fnValue.parameters;
      body = fnValue.body;
    }
  }
  if (!params || !body) return false;
  const p = params[idx];
  if (!p || p.dotDotDotToken || !p.type || !isReadonlySliceType(p.type)) return false;
  if (inProgress.has(p)) return true; // coinductive: recursion over a borrow stays a borrow
  inProgress.add(p);
  try {
    return paramStaysBorrowed(tast, p, body, inProgress);
  } finally {
    inProgress.delete(p);
  }
}

/// Every use of a readonly-slice parameter inside the callee body must keep
/// the borrow: reads (member/element access, iteration, spreads into fresh
/// literals) and further borrowing passes. A return, a store, an alias, or
/// a pass into a non-borrowing position aliases the caller's array out.
function paramStaysBorrowed(
  tast: TypedAst,
  param: ts.ParameterDeclaration,
  body: ts.Node,
  inProgress: Set<ts.ParameterDeclaration>,
): boolean {
  let safe = true;
  const visit = (n: ts.Node): void => {
    if (!safe) return;
    if (ts.isIdentifier(n) && n !== param.name && tast.declarationOf(n) === param) {
      let cur: ts.Node = n;
      let p: ts.Node = cur.parent;
      while (
        ts.isParenthesizedExpression(p) ||
        ts.isAsExpression(p) ||
        ts.isSatisfiesExpression(p) ||
        ts.isNonNullExpression(p)
      ) {
        cur = p;
        p = p.parent;
      }
      const read =
        (ts.isPropertyAccessExpression(p) && p.expression === cur) ||
        (ts.isElementAccessExpression(p) && p.expression === cur) ||
        (ts.isForOfStatement(p) && p.expression === cur) ||
        (ts.isSpreadElement(p) && ts.isArrayLiteralExpression(p.parent));
      if (read) return;
      if (ts.isCallExpression(p) && (p.arguments as readonly ts.Node[]).includes(cur)) {
        if (!borrowedByCall(tast, p, cur, inProgress)) safe = false;
        return;
      }
      safe = false;
    }
    ts.forEachChild(n, visit);
  };
  visit(body);
  return safe;
}

/// Classify one identifier occurrence: null when the use is a read that
/// keeps ownership, else a short past-tense description of the escape.
/// `fn` is the owning function: a `return` there is TERMINAL — execution
/// ends, so it can never precede a later mutation dynamically (the
/// early-exit `if (...) return out;` shape stays legal) — while a `return`
/// inside a nested callback stores the value into the produced array and is
/// a real escape.
function escapeKindOf(n: ts.Identifier, fn: ts.Node, tast: TypedAst): string | null {
  // A reference inside a STORED function value (a const-bound helper, not
  // an inline call-argument callback) escapes at the capture: the closure
  // retains the reference past this statement, so JS would show it every
  // later mutation while the hoisted native helper cannot.
  {
    let walk: ts.Node = n;
    while (walk !== fn && walk.parent) {
      const up: ts.Node = walk.parent;
      if ((ts.isArrowFunction(up) || ts.isFunctionExpression(up)) && up !== fn && !inCallArgumentPosition(up)) {
        return "was captured by a stored function value";
      }
      if (up === fn) break;
      walk = up;
    }
  }
  let cur: ts.Node = n;
  let p: ts.Node = cur.parent;
  while (
    ts.isParenthesizedExpression(p) ||
    ts.isAsExpression(p) ||
    ts.isSatisfiesExpression(p) ||
    ts.isNonNullExpression(p)
  ) {
    cur = p;
    p = p.parent;
  }
  // Reads: method calls / .length (property access), element reads and
  // writes, iteration, and spreads into fresh array literals (a copy).
  if (ts.isPropertyAccessExpression(p) && p.expression === cur) return null;
  if (ts.isElementAccessExpression(p) && p.expression === cur) return null;
  if (ts.isForOfStatement(p) && p.expression === cur) return null;
  if (ts.isSpreadElement(p) && ts.isArrayLiteralExpression(p.parent)) return null;
  if (ts.isReturnStatement(p)) {
    return enclosingFunctionOf(p) === fn ? null : "was returned from a callback";
  }
  if (ts.isCallExpression(p) && (p.arguments as readonly ts.Node[]).includes(cur)) {
    // Passing into a `readonly T[]` parameter BORROWS: the callee provably
    // cannot mutate or alias the array out, so ownership survives the call.
    if (borrowedByCall(tast, p, cur, new Set())) return null;
    return "was passed to a call";
  }
  if (ts.isVariableDeclaration(p) && p.initializer === cur) return "was aliased by another binding";
  if (ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
    // The RHS stores the reference; the LHS is a rebinding, reported as the
    // reassignment verdict by arrayOwnership (never owned) instead.
    return p.right === cur ? "was stored through an assignment" : null;
  }
  if (ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p)) return "was stored in an object";
  if (ts.isSpreadAssignment(p)) return "was spread into an object";
  if (ts.isArrayLiteralExpression(p)) return "was stored in an array";
  return "escaped as a value";
}

/// An escape inside a loop gates the whole loop: its effective position is
/// the start of its outermost enclosing loop (bounded by the function).
function effectivePos(n: ts.Node, fn: ts.Node): number {
  let pos = n.getStart();
  let cur: ts.Node | undefined = n.parent;
  while (cur && cur !== fn) {
    if (
      ts.isForStatement(cur) ||
      ts.isForOfStatement(cur) ||
      ts.isForInStatement(cur) ||
      ts.isWhileStatement(cur) ||
      ts.isDoStatement(cur)
    ) {
      pos = Math.min(pos, cur.getStart());
    }
    cur = cur.parent;
  }
  return pos;
}

/// Whether the binding is ever ASSIGNED after its declaration.
function isReassignedBinding(tast: TypedAst, decl: ts.VariableDeclaration, fn: ts.Node): boolean {
  let found = false;
  const visit = (n: ts.Node): void => {
    if (found) return;
    if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const target = unwrapExpr(n.left);
      if (ts.isIdentifier(target) && tast.declarationOf(target) === decl) {
        found = true;
        return;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(fn);
  return found;
}

/// Flow-sensitive ownership for a reassigned `let`: the binding stays owned
/// when EVERY assignment installs a fresh owning constructor — the binding
/// can then never hold a shared array, whatever the control flow. One mixed
/// assignment (an alias, a helper result) and the binding never owns.
export function everyAssignmentOwning(
  tast: TypedAst,
  decl: ts.VariableDeclaration,
  fn: ts.Node,
  owningInit: (init: ts.Expression) => boolean = isOwningInitializer,
): boolean {
  let allOwning = true;
  const visit = (n: ts.Node): void => {
    if (!allOwning) return;
    if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const target = unwrapExpr(n.left);
      if (ts.isIdentifier(target) && tast.declarationOf(target) === decl && !owningInit(n.right)) {
        allOwning = false;
        return;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(fn);
  return allOwning;
}

/// The first escape of `decl` whose effective position precedes `sitePos`,
/// described for the teaching diagnostic — or null when the binding is still
/// owned at the site.
function escapeBefore(
  tast: TypedAst,
  decl: ts.VariableDeclaration,
  fn: ts.Node,
  sitePos: number,
): string | null {
  let found: string | null = null;
  let foundPos = Infinity;
  const visit = (n: ts.Node): void => {
    if (ts.isIdentifier(n) && n !== decl.name && tast.declarationOf(n) === decl) {
      const kind = escapeKindOf(n, fn, tast);
      if (kind !== null) {
        const pos = effectivePos(n, fn);
        if (pos < sitePos && pos < foundPos) {
          const file = n.getSourceFile();
          const { line } = lineColumn(file, n.getStart());
          foundPos = pos;
          found = `${kind} (line ${line})`;
        }
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(fn);
  return found;
}

export type ValueStepVerdict = { readonly ok: true } | { readonly ok: false; readonly why: string };

/// A const-bound function VALUE (`const helper = (x) => ...` /
/// `const helper = function (x) {...}`) declared inside a function — the
/// shape that hoists to a module-level declaration. Named function
/// expressions and non-const bindings stay taught.
export function constFunctionValue(decl: ts.VariableDeclaration): ts.ArrowFunction | ts.FunctionExpression | null {
  if (!ts.isIdentifier(decl.name) || !decl.initializer) return null;
  if (!ts.isVariableDeclarationList(decl.parent) || (decl.parent.flags & ts.NodeFlags.Const) === 0) return null;
  if (!enclosingFunctionOf(decl)) return null; // module-level function values stay taught
  const init = unwrapExpr(decl.initializer);
  if (ts.isArrowFunction(init) && !init.asteriskToken) return init;
  if (ts.isFunctionExpression(init) && !init.name && !init.asteriskToken) return init;
  return null;
}

/// Whether a function value sits in a call's ARGUMENT position (the inline
/// callback home), reached through literal wrappers.
export function inCallArgumentPosition(fn: ts.Node): boolean {
  let cur: ts.Node = fn;
  for (;;) {
    const p: ts.Node = cur.parent;
    if (!p) return false;
    if (ts.isCallExpression(p) && (p.arguments as readonly ts.Node[]).includes(cur as ts.Expression)) return true;
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

/// Legality of hoisting a const-bound function value to module level.
/// Everything the hoisted declaration cannot represent teaches: captures of
/// enclosing locals (module consts and other hoistable helpers are fine),
/// missing signature annotations, and uses beyond a direct call or an
/// array-method callback argument.
export function functionValueLegality(
  decl: ts.VariableDeclaration,
  fn: ts.ArrowFunction | ts.FunctionExpression,
  tast: TypedAst,
): ValueStepVerdict {
  const name = (decl.name as ts.Identifier).text;
  if (fn.typeParameters && fn.typeParameters.length > 0) {
    return { ok: false, why: `\`${name}\` declares a type parameter (generic helpers are module-level function declarations)` };
  }
  if (!fn.type) {
    return { ok: false, why: `\`${name}\` has no return type annotation (a hoisted helper spells its full signature)` };
  }
  for (const p of fn.parameters) {
    if (!ts.isIdentifier(p.name) || !p.type) {
      return { ok: false, why: `\`${name}\` has a parameter without a name and type annotation` };
    }
  }
  // A helper inside a GENERIC function must not mention its type
  // parameters: the hoisted declaration is one concrete fn, while the
  // enclosing generic instantiates per call site.
  for (const typeNode of [fn.type, ...fn.parameters.map((p) => p.type)]) {
    if (!typeNode) continue;
    let mentioned: string | null = null;
    const scan = (tn: ts.Node): void => {
      if (mentioned) return;
      if (ts.isTypeReferenceNode(tn) && ts.isIdentifier(tn.typeName)) {
        const d = tast.declarationOf(tn.typeName);
        if (d && ts.isTypeParameterDeclaration(d)) mentioned = tn.typeName.text;
      }
      ts.forEachChild(tn, scan);
    };
    scan(typeNode);
    if (mentioned) {
      return { ok: false, why: `\`${name}\`'s signature references type parameter \`${mentioned}\` (hoisted helpers are concrete — make it a module-level generic function)` };
    }
  }
  const captured = capturedOuterLocal(fn, tast);
  if (captured !== null) {
    return { ok: false, why: `\`${name}\` captures \`${captured}\` from the enclosing function (pass it as a parameter)` };
  }
  const badUse = illegalFunctionValueUse(decl, tast);
  if (badUse !== null) return { ok: false, why: badUse };
  return { ok: true };
}

/// The first identifier the function value CLOSES OVER: declared in an
/// enclosing function (not module scope, not the value's own scope). Other
/// hoistable helpers are exempt — they become module-level names too.
function capturedOuterLocal(fn: ts.ArrowFunction | ts.FunctionExpression, tast: TypedAst): string | null {
  let found: string | null = null;
  const file = fn.getSourceFile();
  const visit = (n: ts.Node): void => {
    if (found !== null) return;
    if (ts.isIdentifier(n)) {
      const d = tast.declarationOf(n);
      if (
        d &&
        (ts.isVariableDeclaration(d) || ts.isParameter(d) || ts.isBindingElement(d)) &&
        enclosingFunctionOf(d) !== null &&
        !(d.getSourceFile() === file && d.pos >= fn.pos && d.end <= fn.end)
      ) {
        if (ts.isVariableDeclaration(d) && constFunctionValue(d) !== null) return; // hoists too (self-recursion included)
        found = n.text;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(fn.body);
  return found;
}

/// The first USE of the binding beyond a direct call (`helper(x)`) or an
/// array-method callback argument (`xs.map(helper)`), described for the
/// teaching diagnostic; null when every use is legal.
function illegalFunctionValueUse(decl: ts.VariableDeclaration, tast: TypedAst): string | null {
  const fn = enclosingFunctionOf(decl);
  if (!fn) return "the binding is not function-local";
  const name = (decl.name as ts.Identifier).text;
  let found: string | null = null;
  const visit = (n: ts.Node): void => {
    if (found !== null) return;
    if (ts.isIdentifier(n) && n !== decl.name && tast.declarationOf(n) === decl) {
      let cur: ts.Node = n;
      let p: ts.Node = cur.parent;
      while (ts.isParenthesizedExpression(p)) {
        cur = p;
        p = p.parent;
      }
      const directCall = ts.isCallExpression(p) && p.expression === cur && !p.questionDotToken;
      const callbackArg =
        ts.isCallExpression(p) &&
        (p.arguments as readonly ts.Node[]).includes(cur) &&
        ts.isPropertyAccessExpression(p.expression);
      if (!directCall && !callbackArg) {
        found = `\`${name}\` is used as a value beyond a direct call or an array-method callback (call it, or inline the logic)`;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(fn);
  return found;
}

/// Legality of a `++`/`--` or assignment used AS A VALUE (`arr[i++]`,
/// `const n = ++count`, `const z = (y = 5)`). The lowering splits the step
/// into its own statement and reads the variable, which is JS-order-exact
/// only when BOTH hold:
///
///   - the step cannot be skipped or repeated: it does not sit in a
///     short-circuit right operand, a ternary branch, a loop condition or
///     incrementor slot, or a case label (all positions JS may not reach);
///   - the stepped variable's ONLY mention in the evaluation unit (the
///     enclosing statement's expression, or the callback body) is the step
///     itself — another read would observe the mid-expression order the
///     split statement cannot reproduce.
///
/// Number-typed identifier locals only: the value read back after the
/// statement equals the expression's JS value for every operator form.
export function valuePositionStep(expr: ts.Expression, target: ts.Expression, tast: TypedAst): ValueStepVerdict {
  const t = unwrapExpr(target);
  if (!ts.isIdentifier(t)) {
    return { ok: false, why: "the stepped target is not a plain local variable" };
  }
  const decl = tast.declarationOf(t);
  if (!decl || !ts.isVariableDeclaration(decl)) {
    return { ok: false, why: `\`${t.text}\` is not a local variable` };
  }
  const flags = tast.typeOf(t).flags;
  if ((flags & (ts.TypeFlags.Number | ts.TypeFlags.NumberLiteral)) === 0) {
    return { ok: false, why: `\`${t.text}\` is not number-typed (the split-statement value is pinned for numbers only)` };
  }
  let cur: ts.Node = expr;
  let scope: ts.Node | null = null;
  for (;;) {
    const p: ts.Node = cur.parent;
    if (!p || ts.isSourceFile(p)) {
      return { ok: false, why: "the step sits at module level" };
    }
    if (ts.isConditionalExpression(p) && (p.whenTrue === cur || p.whenFalse === cur)) {
      return { ok: false, why: "the step sits in a ternary branch JS may skip" };
    }
    if (ts.isBinaryExpression(p) && p.right === cur) {
      const op = p.operatorToken.kind;
      if (
        op === ts.SyntaxKind.AmpersandAmpersandToken ||
        op === ts.SyntaxKind.BarBarToken ||
        op === ts.SyntaxKind.QuestionQuestionToken ||
        op === ts.SyntaxKind.AmpersandAmpersandEqualsToken ||
        op === ts.SyntaxKind.BarBarEqualsToken ||
        op === ts.SyntaxKind.QuestionQuestionEqualsToken
      ) {
        return { ok: false, why: "the step sits in a short-circuit right operand JS may skip" };
      }
    }
    if ((ts.isWhileStatement(p) || ts.isDoStatement(p)) && p.expression === cur) {
      return { ok: false, why: "the step sits in a loop condition JS re-evaluates per iteration" };
    }
    if (ts.isForStatement(p) && (p.condition === cur || p.incrementor === cur)) {
      return { ok: false, why: "the step sits in a for-loop head slot (the incrementor takes plain steps; the condition re-evaluates)" };
    }
    if (ts.isCaseClause(p) && p.expression === cur) {
      return { ok: false, why: "the step sits in a case label JS evaluates only when earlier cases miss" };
    }
    if (
      (ts.isPropertyAccessExpression(p) || ts.isElementAccessExpression(p) || ts.isCallExpression(p)) &&
      ts.isOptionalChain(p)
    ) {
      // Conservative: a chain hop may short-circuit past the step.
      return { ok: false, why: "the step rides an optional chain JS may short-circuit" };
    }
    if ((ts.isArrowFunction(p) || ts.isFunctionExpression(p)) && (p as ts.ArrowFunction).body === cur) {
      scope = cur;
      break;
    }
    if (isStatementBoundary(p)) {
      scope = cur;
      break;
    }
    cur = p;
  }
  let count = 0;
  const visit = (n: ts.Node): void => {
    if (ts.isIdentifier(n) && n !== decl.name && tast.declarationOf(n) === decl) count += 1;
    ts.forEachChild(n, visit);
  };
  visit(scope);
  if (count !== 1) {
    return {
      ok: false,
      why: `\`${t.text}\` is mentioned ${count} times in the same evaluation unit (the split statement would lose JS's mid-expression order)`,
    };
  }
  return { ok: true };
}

function isStatementBoundary(p: ts.Node): boolean {
  return (
    ts.isExpressionStatement(p) ||
    ts.isReturnStatement(p) ||
    ts.isIfStatement(p) ||
    ts.isSwitchStatement(p) ||
    ts.isVariableStatement(p) ||
    ts.isForOfStatement(p) ||
    ts.isForStatement(p) ||
    ts.isBlock(p) ||
    ts.isSourceFile(p)
  );
}

/// Method names of a data class whose bodies write the receiver: an
/// assignment/compound/step into `this.field`, or a call of another
/// mutating method on `this` (computed to a fixpoint). These emit with a
/// pointer receiver, and their call sites require a locally-owned instance.
export function mutatingMethodNames(decl: ts.ClassDeclaration): Set<string> {
  const bodies = new Map<string, ts.Node>();
  for (const m of decl.members) {
    if (ts.isMethodDeclaration(m) && m.name && ts.isIdentifier(m.name) && m.body) {
      bodies.set(m.name.text, m.body);
    }
  }
  const isThisField = (e: ts.Expression): boolean => {
    const u = unwrapExpr(e);
    return ts.isPropertyAccessExpression(u) && u.expression.kind === ts.SyntaxKind.ThisKeyword;
  };
  const mutating = new Set<string>();
  const writesThis = (body: ts.Node): boolean => {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (
        ts.isBinaryExpression(n) &&
        compoundAndPlainAssignmentOps.has(n.operatorToken.kind) &&
        isThisField(n.left)
      ) {
        found = true;
      } else if (
        (ts.isPrefixUnaryExpression(n) || ts.isPostfixUnaryExpression(n)) &&
        (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken) &&
        isThisField(n.operand)
      ) {
        found = true;
      } else if (
        ts.isCallExpression(n) &&
        ts.isPropertyAccessExpression(n.expression) &&
        n.expression.expression.kind === ts.SyntaxKind.ThisKeyword &&
        mutating.has(n.expression.name.text)
      ) {
        found = true;
      }
      ts.forEachChild(n, visit);
    };
    visit(body);
    return found;
  };
  for (;;) {
    let grew = false;
    for (const [name, body] of bodies) {
      if (!mutating.has(name) && writesThis(body)) {
        mutating.add(name);
        grew = true;
      }
    }
    if (!grew) break;
  }
  return mutating;
}

/// Assignment operators that WRITE their target (plain and compound forms).
export const compoundAndPlainAssignmentOps = new Set<ts.SyntaxKind>([
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
  ts.SyntaxKind.QuestionQuestionEqualsToken,
  ts.SyntaxKind.AmpersandAmpersandEqualsToken,
  ts.SyntaxKind.BarBarEqualsToken,
]);

/// The ownership verdict for mutating a CLASS INSTANCE at `site` (a field
/// write or a mutating-method call through `base`). Exactly the array rule
/// with `new ClassName(...)` as the owning constructor: your own fresh
/// instance is yours to mutate until it escapes; parameters, model data,
/// and aliased bindings teach.
export function instanceOwnership(tast: TypedAst, base: ts.Expression, site: ts.Node): OwnershipVerdict {
  return ownershipOf(tast, base, site, (init) => {
    const e = unwrapExpr(init);
    return ts.isNewExpression(e) && ts.isIdentifier(e.expression) && e.expression.text !== "Uint8Array";
  }, "instance");
}

/// The ownership verdict for mutating `base` at `site`. `base` is the
/// receiver expression of a mutating method call or an indexed write.
export function arrayOwnership(tast: TypedAst, base: ts.Expression, site: ts.Node): OwnershipVerdict {
  return ownershipOf(tast, base, site, isOwningInitializer, "array");
}

function ownershipOf(
  tast: TypedAst,
  base: ts.Expression,
  site: ts.Node,
  owningInit: (init: ts.Expression) => boolean,
  what: "array" | "instance",
): OwnershipVerdict {
  const b = unwrapExpr(base);
  if (!ts.isIdentifier(b)) {
    return {
      owned: false,
      why: "not-local",
      detail: `the ${what} is reached through a structure, not a local binding this function created`,
    };
  }
  const decl = tast.declarationOf(b);
  if (decl && ts.isParameter(decl)) {
    return { owned: false, why: "not-local", detail: `\`${b.text}\` is a parameter — the caller's ${what}` };
  }
  if (!decl || !ts.isVariableDeclaration(decl)) {
    return { owned: false, why: "not-local", detail: `\`${b.text}\` is not a local binding` };
  }
  const fn = enclosingFunctionOf(decl);
  if (!fn) {
    return {
      owned: false,
      why: "not-local",
      detail: `\`${b.text}\` is module-level data, shared by every dispatch`,
    };
  }
  if (!decl.initializer) {
    return { owned: false, why: "not-local", detail: `\`${b.text}\` was declared without a creating initializer` };
  }
  if (!owningInit(decl.initializer)) {
    const e = unwrapExpr(decl.initializer);
    const detail = ts.isIdentifier(e)
      ? `\`${b.text}\` aliases \`${e.text}\` instead of owning fresh storage${what === "array" ? " — copy with `.slice()` to own it" : ""}`
      : `\`${b.text}\` was not created by this function's own ${what === "array" ? "array construction — copy with `.slice()` to own it" : "`new` expression"}`;
    return { owned: false, why: "not-local", detail };
  }
  if (isReassignedBinding(tast, decl, fn) && !everyAssignmentOwning(tast, decl, fn, owningInit)) {
    return {
      owned: false,
      why: "not-local",
      detail: `\`${b.text}\` is reassigned from a value this function does not own — a binding stays yours only while every assignment installs a fresh ${what === "array" ? "array construction (a literal or a copy)" : "\`new\` expression"}`,
    };
  }
  const escape = escapeBefore(tast, decl, fn, site.getStart());
  if (escape !== null) {
    return { owned: false, why: "escaped", detail: `\`${b.text}\` ${escape}` };
  }
  return { owned: true, decl };
}

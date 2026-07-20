// The Zig emitter: mapping rules R1-R18 from the subset spec, applied
// mechanically to the checked, integer-inferred module.
//
// Output contract: HUMAN-READABLE Zig — your names are your names. Fields,
// declarations, and variables all keep their TS spellings (markup binds the
// model's field names exactly as written), source comments ride along, and
// every construct maps by rule, never by per-site judgment. The eject story
// depends on a person being able to adopt this file and on the markup still
// binding the same names afterwards.
//
// Anything outside the implemented mapping stops the build with NS9001 — the
// emitter re-derives the subset rules and refuses to guess (spec section 5,
// enforcement layer 3).

import path from "node:path";
import { ts, TypedAst, hasExportModifier, exportListBindings, sdkCoreModulePath } from "./typed_ast.ts";
import { TypeTable, snakeCase, zigDeclName, zigLocalName, isZigPrimitiveName, isStaticMember, mangleZType, type ZType, type ZField, type UnionInfo, type StructInfo, type ClassInfo } from "./types.ts";
import { IntInference, returnExpressionsOf } from "./infer.ts";
import { thrownShapeOf, thrownArmsOfShape, THROWN_UNION_NAME, type CheckResult } from "./checker.ts";
import type { RuleId } from "./diagnostics.ts";
import {
  everyAssignmentOwning,
  arrayOwnership,
  enclosingFunctionOf,
  growingMethods,
  isOwningInitializer,
  lengthChangingMethods,
  ownedMutatingMethods,
  unwrapExpr,
  valuePositionStep,
  constFunctionValue,
  functionValueLegality,
} from "./ownership.ts";

/// The function forms an array-method callback position accepts: the inline
/// arrow, and what a bare reference resolves to (a hoisted local helper —
/// arrow or function expression — or a module-level function declaration).
/// One lowering serves all of them: the parameters are real bound AST nodes
/// that claim the loop captures, and the body inlines at the use site.
type CallbackFn = ts.ArrowFunction | ts.FunctionExpression | ts.FunctionDeclaration;

function isCallbackFn(node: ts.Node): node is CallbackFn {
  return ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isFunctionDeclaration(node);
}

class EmitError extends Error {
  readonly node: ts.Node;
  /// Layer-3 re-derivations of taught rules carry the rule's own ID; every
  /// other stop is the internal NS9001.
  readonly ruleId: RuleId;
  constructor(message: string, node: ts.Node, ruleId: RuleId = "NS9001") {
    super(message);
    this.node = node;
    this.ruleId = ruleId;
  }
}

/// One enclosing edge-target construct (see Ctx.edgeKills). `label` is the
/// SOURCE label naming the construct (loopLabel mangling happens at
/// emission), null for unlabeled ones. An unlabeled `break` binds the
/// innermost loop-or-switch stage, an unlabeled `continue` the innermost
/// loop, labeled exits the innermost stage carrying their label, and a
/// lifted callback's lowered `return` the innermost callback stage.
interface EdgeKillStage {
  readonly kind: "loop" | "switch" | "block" | "callback";
  readonly label: string | null;
  readonly kills: Set<string>;
}

/// Where a closing scope's recorded kills go — kills travel the same edges
/// control does. `merge` applies them to the surviving fall-through flow;
/// `drop` discards them (every route leaves the emitted function); an array
/// of destination sets carries them along the scope's non-local edges (the
/// enclosing try's pending catch set, break/continue target stages, the
/// lifted callback's stage), each applied where its edge lands.
type KillRouting = "merge" | "drop" | readonly Set<string>[];

interface Ctx {
  readonly lines: string[];
  indent: number;
  /// Inside a data-class member body: the receiver's emitted name (`self`),
  /// its struct type, whether it is a pointer (`self: *T` in mutating
  /// methods), and — inside a constructor — the local being built (a plain
  /// `return;` there returns it).
  thisName?: string | null;
  thisType?: ZType | null;
  thisSelfPtr?: boolean;
  ctorSelf?: string | null;
  /// R20: the label of the ENCLOSING try body (same emitted function) — a
  /// `throw` (or a throwing call) breaks to it; null means the throw
  /// propagates (`return error.Thrown`) to the caller.
  tryLabel?: string | null;
  /// R20: true while emitting inside a try body whose local catch has some
  /// route back into the function. There ANY statement containing a
  /// throwing call is a resuming route — it lands in the catch, and the
  /// catch's fall-back carries the region's narrowing kills to a merge
  /// point — so kill dropping (allRoutesLeaveFunction) treats each one as
  /// a route that does not leave. A catch whose every route leaves the
  /// function (including its own throws, judged against ITS enclosing
  /// handler) closes that path, and the flag stays off for its body.
  catchResumes?: boolean;
  /// R20: the ENCLOSING try's pending exception kills — kills travel the
  /// same edges control does (allRoutesLeaveFunction's route destinations).
  /// A scope whose only in-function routes are throws caught by that try's
  /// catch never falls through into the try body's remaining statements,
  /// so its kills must not merge into intra-try flow; they wait here and
  /// emitTryCore hands them to the catch as its ENTRY state (the catch
  /// body's reads see them), where they ride the catch's own kill-frame
  /// routing out — post-try on fall-through, the edge stage on a
  /// break/continue, dropped when every catch route leaves the function
  /// (see popNarrowKillFrame's route form). The throw edge is one instance
  /// of the general rule; break/continue/lowered-return edges stage the
  /// same way on edgeKills below.
  pendingCatchKills?: Set<string> | null;
  /// The enclosing edge-target constructs of the emitted function,
  /// innermost last: loops, switches, labeled blocks, and lifted-callback
  /// value blocks. A scope that exits ONLY along break/continue/lowered-
  /// return edges stages its kills on the target construct's set
  /// (popNarrowKillFrame's route form, the sibling of pendingCatchKills),
  /// and the construct's emitter applies them where those edges land — the
  /// post-construct state for breaks and callback returns, and for
  /// continue edges the back-edge join, which the emitter also realizes as
  /// the post-loop state: the loop-entry model delegates in-body
  /// next-iteration reads to tsc (the checker rejects a read relying on a
  /// narrow the back edge kills), so the only emission the kill must still
  /// reach is the normal-completion exit. Applying a stage records into
  /// the then-innermost kill frame, so staged kills keep propagating
  /// outward exactly like merge-class kills.
  readonly edgeKills: EdgeKillStage[];
  /// decl node -> zig identifier
  readonly names: Map<ts.Node, string>;
  readonly used: Set<string>;
  /// normalized source text of an expression -> replacement zig expr
  /// (optional-narrowing captures, union payload captures)
  readonly memberSubst: Map<string, string>;
  /// The subset of memberSubst entries that RENAME without narrowing: a
  /// union payload capture of an optional-typed field holds the payload
  /// as-is (`.got => |parsed|` with `got: ?f64` binds `parsed: ?f64`), so
  /// type queries must keep the optional. Maps key -> that replacement;
  /// zTypeOfExpr only unwraps when the ACTIVE replacement differs (a
  /// null-guard capture overwriting the key installs a fresh name, so the
  /// identity check stays correct through save/restore cycles).
  readonly stillOptionalSubst: Map<string, string>;
  /// source text of a union-typed expr -> active arm tag (kind guards)
  readonly narrowedUnion: Map<string, string>;
  /// Invalidation frames, innermost last: every scope that snapshots and
  /// restores the narrowing maps pushes a Set here, and the assignment path
  /// records into the innermost frame each memberSubst key whose narrowing
  /// it permanently deleted (the assigned value may be null again). The
  /// snapshot restore at scope exit gives CONTAINMENT — narrowings added
  /// inside the scope die there — but restoring alone would also resurrect
  /// narrowings an assignment inside the scope killed; re-applying the
  /// frame's deletions after the restore keeps those dead. Frames merge
  /// outward on pop so an inner branch's kill reaches every enclosing exit
  /// it can fall through to; a scope that always leaves the function drops
  /// its kills instead (see popNarrowKillFrame).
  readonly narrowKilled: Set<string>[];
  /// declared/inferred types of locals
  readonly localTypes: Map<ts.Node, ZType>;
  /// Locally-owned arrays with length-changing mutations (the push-builder
  /// generalized): the mutable slice and fill-count names the lowerings
  /// operate through. `growable` marks slices a push/unshift/splice may
  /// rt.frameGrow (their binding is `var`; fixed-capacity ones are `const`).
  readonly builders: Map<ts.Node, { slice: string; len: string; elemRef: string; elem: ZType; growable: boolean }>;
  /// Inside a lifted block-body callback: `return v` lowers to
  /// `break :<label> v` out of the labeled value block.
  retLabel: string | null;
  returnType: ZType;
  /// Set for `update(model, msg): Model | [Model, Cmd<Msg>]` (and the same
  /// pair shape on `initialModel`): every return lowers to the pair-result
  /// struct, and the cmd slot lowers onto rt's command builders (the
  /// versioned effect-bytes channel).
  cmdReturn: { readonly msgUnion: string } | null;
  /// Set for `subscriptions(model): Sub<Msg>`: every return lowers onto
  /// rt's subscription builders (the same versioned bytes channel).
  subReturn: { readonly msgUnion: string } | null;
}

interface Emitted {
  code: string;
  /// For `.filter(...)` results: the kept-count variable, so `.length`
  /// reads the count instead of re-slicing.
  filterLen?: string;
}

/// An exported single-Model-parameter helper that also forwards as a Model
/// declaration (the markup fn-backed-scalar shape). `zigName` is the emitted
/// declaration name (the TS name, @"..."-quoted only when it collides with a
/// Zig keyword); `ret` the emitted return type reference.
interface ModelHelper {
  readonly name: string;
  readonly zigName: string;
  /// The emitted module-level fn the forwarder calls — the declaration's
  /// claimed name (a renamed export's target may be private and prefixed).
  readonly fnName: string;
  readonly decl: ts.FunctionDeclaration;
  readonly ret: string;
}

/// App-level kernel capacities (bytes), forwarded into the emitted core's
/// rt instantiation. Absent fields keep the rt defaults.
export interface KernelCapacities {
  readonly frameCap?: number;
  readonly heapCap?: number;
}

// The host effect engine's fixed capacities, mirrored so compile-time-known
// arguments that would be rejected at runtime stop the build instead
// (NS1030). Dynamic values stay the engine's to validate through err arms.
const MAX_FILE_PATH_BYTES = 1024;
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_URL_BYTES = 2048;
const MAX_FETCH_HEADERS = 8;
const MAX_FETCH_HEADER_BYTES = 1024;
const MAX_FETCH_PAYLOAD_BYTES = 64 * 1024;
const MAX_SPAWN_ARGV = 16;
const MAX_SPAWN_ARGV_BYTES = 2048;
const MAX_SPAWN_STDIN_BYTES = 4096;
const MAX_AUDIO_PATH_BYTES = 1024;

/// The closed `Cmd.fetch` verb set, wire value = position.
const FETCH_METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"];

/// The audio event states an event arm's `state` union must carry — the
/// engine's event vocabulary, matched by member NAME (declaration order is
/// the app's own).
const AUDIO_STATES = ["loaded", "position", "completed", "failed", "rejected", "spectrum"];

/// Names the emitted module's own fixtures occupy (header helpers + commit
/// machinery): module-level claims and function locals unique around them.
const emittedFixtureNames = [
  "std", "rt", "jlen", "uz", "jsAnd", "jsOr", "jsXor", "jsShl", "jsShr", "jsUshr", "jsBitNot",
  "jsPow", "tagEq", "tagIsNull",
  "tagCast", "strEq", "strIsNull", "numEq", "numIsNull", "empty_bytes", "UpdateResult", "InitResult",
  "CommitMode", "commitBytes", "commitScalars", "commitModelRoot",
  "shouldCopy", "inOldHeap", "old_heap_base", "old_heap_len", "core_root",
] as const;

/// The `Cmd.audio*` control verbs and their zig enum literals (`resume` is a
/// Zig keyword, so its literal is quoted).
const AUDIO_VERBS: Record<string, string> = {
  audioPause: ".pause",
  audioResume: '.@"resume"',
  audioStop: ".stop",
  audioSeek: ".seek",
  audioSetVolume: ".volume",
};

export class Emitter {
  private readonly out: string[] = [];

  private readonly tast: TypedAst;
  private readonly table: TypeTable;
  private readonly infer: IntInference;
  private readonly checkResult: CheckResult;
  /// The core's modules in canonical order; files[0] is the ENTRY (the one
  /// module the wiring channels and viewUnbound are read from). All emit
  /// into ONE core.zig: the core instantiates one rt kernel, and Zig's
  /// order-free module scope means cross-file references need no
  /// declaration ordering.
  private readonly files: readonly ts.SourceFile[];
  private readonly file: ts.SourceFile;
  private readonly fileSet: Set<ts.SourceFile>;
  /// Module-level decl -> emitted name. Names keep their source spelling;
  /// only a PRIVATE value decl colliding with an earlier claim takes a
  /// per-module prefix (`<file>_<name>`) — the round-3 hygiene pass lifted
  /// to module scope. Exported values and all type names never rename
  /// (they are the binding/import surface; collisions are checker NS1038).
  private readonly moduleNames = new Map<ts.Node, string>();
  /// Emitted names of data-class functions, keyed `ClassName#member`
  /// (`Task#new`, `Task#rename`).
  private readonly classFnNames = new Map<string, string>();
  /// Declarations exported by an UN-renamed export list entry (`export
  /// { f }`, `export { f } from "./m.ts"`): exported exactly like the
  /// modifier — `pub`, name never renamed.
  private readonly listExportedDecls = new Set<ts.Node>();
  /// Names bound by RENAMED export list entries (`export { f as g }` binds
  /// `g`): claimed up front (exported names never rename), emitted as
  /// `pub const g = f;` aliases at the list's site.
  private readonly exportAliasNames = new Set<string>();
  /// R20: the core's single thrown shape (null when nothing throws), and
  /// the functions a throw can PROPAGATE out of (they return `Thrown!T`).
  private thrownShape: ZType | null = null;
  /// True when the thrown shape is the checker-synthesized union of several
  /// distinct thrown shapes — its declaration emits in the R20 header.
  private thrownSynthesized = false;
  private readonly leakingFns = new Set<ts.Node>();
  /// Const-bound local function VALUES (R15d): decl -> the arrow/function
  /// expression that hoists to a module-level declaration. Names live in
  /// moduleNames (claimed up front, so no body local can shadow one).
  private readonly hoistedFns = new Map<ts.VariableDeclaration, ts.ArrowFunction | ts.FunctionExpression>();
  private readonly hoistQueue: ts.VariableDeclaration[] = [];
  private readonly hoistQueued = new Set<ts.VariableDeclaration>();
  /// R15e monomorphization: one emitted fn per (generic decl, resolved
  /// argument list), deduped by mangled name; the queue drains after the
  /// module walk (an instantiation body may enqueue more).
  private readonly genericInsts = new Map<
    string,
    { decl: ts.FunctionDeclaration; scope: Map<ts.Declaration, ZType>; name: string; args: ZType[] }
  >();
  private readonly genericQueue: string[] = [];
  private readonly genericNames = new Set<string>();
  private readonly sourceName: string;
  private readonly capacities: KernelCapacities;
  /// Per-switch memo for the defaultless value-switch exhaustiveness
  /// consult (alwaysExits re-asks along every kill-routing scan).
  private switchCoversTypeMemo = new WeakMap<ts.SwitchStatement, boolean>();

  /// Computed once at the top of emitModule (before any type emission).
  private helpers: ModelHelper[] = [];
  private unbound: { model: string[]; msg: string[] } = { model: [], msg: [] };

  constructor(
    tast: TypedAst,
    table: TypeTable,
    infer: IntInference,
    checkResult: CheckResult,
    files: readonly ts.SourceFile[] | ts.SourceFile,
    sourceName: string,
    capacities: KernelCapacities = {},
  ) {
    this.tast = tast;
    this.table = table;
    this.infer = infer;
    this.checkResult = checkResult;
    this.files = Array.isArray(files) ? files : [files as ts.SourceFile];
    this.file = this.files[0];
    this.fileSet = new Set(this.files);
    this.sourceName = sourceName;
    this.capacities = capacities;
    this.claimModuleNames();
    this.computeExceptions();
  }

  // ------------------------------------------------------------ exceptions

  /// R20 pre-pass: resolve the thrown shape (layer-3 re-derivation of
  /// NS1057) and compute the leak fixpoint — a function leaks when a throw
  /// (or a call of a leaking function) is not contained by a try/catch in
  /// the same emitted function. Leaking functions return `Thrown!T`.
  private computeExceptions(): void {
    const res = thrownShapeOf(this.tast, this.table, this.files);
    if (res.problems.length > 0) {
      this.fail(res.problems[0].node, res.problems[0].msg, "NS1057");
    }
    this.thrownShape = res.shape;
    this.thrownSynthesized = res.synthesized;
    if (this.thrownShape === null) return;

    /// The emitted function a node belongs to: module fns, class members,
    /// and hoisted helpers are boundaries; inline callbacks are not (their
    /// bodies inline into the caller).
    const ownerOf = (node: ts.Node): ts.Node | null => {
      let cur: ts.Node | undefined = node.parent;
      while (cur && !ts.isSourceFile(cur)) {
        if (ts.isFunctionDeclaration(cur) || ts.isMethodDeclaration(cur) || ts.isConstructorDeclaration(cur)) return cur;
        if (ts.isArrowFunction(cur) || ts.isFunctionExpression(cur)) {
          for (const [decl, fn] of this.hoistedFns) {
            if (fn === cur) return decl;
          }
          // Inline callback: inlines into the enclosing function.
        }
        cur = cur.parent;
      }
      return null;
    };
    const contained = (node: ts.Node): boolean => {
      let cur: ts.Node | undefined = node;
      let prev: ts.Node | undefined;
      while (cur && !ts.isSourceFile(cur)) {
        if (ts.isFunctionDeclaration(cur) || ts.isMethodDeclaration(cur) || ts.isConstructorDeclaration(cur)) return false;
        if ((ts.isArrowFunction(cur) || ts.isFunctionExpression(cur)) && [...this.hoistedFns.values()].includes(cur)) {
          return false;
        }
        if (ts.isTryStatement(cur) && cur.catchClause && prev === cur.tryBlock) return true;
        prev = cur;
        cur = cur.parent;
      }
      return false;
    };
    const calleeOwner = (n: ts.CallExpression | ts.NewExpression): ts.Node | null => this.calleeOwnerOf(n);
    for (;;) {
      let grew = false;
      const visit = (n: ts.Node): void => {
        if (ts.isThrowStatement(n) && !contained(n)) {
          const o = ownerOf(n);
          if (o && !this.leakingFns.has(o)) {
            this.leakingFns.add(o);
            grew = true;
          }
        }
        if ((ts.isCallExpression(n) || ts.isNewExpression(n)) && !contained(n)) {
          const target = calleeOwner(n);
          if (target && this.leakingFns.has(target)) {
            const o = ownerOf(n);
            if (o && !this.leakingFns.has(o)) {
              this.leakingFns.add(o);
              grew = true;
            }
          }
        }
        ts.forEachChild(n, visit);
      };
      for (const f of this.files) visit(f);
      if (!grew) break;
    }
  }

  /// The leak-analysis owner a call or `new` dispatches to (module fn,
  /// hoisted helper's declaration, class method, or constructor), else null.
  private calleeOwnerOf(n: ts.CallExpression | ts.NewExpression): ts.Node | null {
    if (ts.isNewExpression(n)) {
      if (!ts.isIdentifier(n.expression)) return null;
      const cls = this.table.classes.get(n.expression.text);
      return cls?.ctor ?? null;
    }
    const callee = n.expression;
    if (ts.isIdentifier(callee)) {
      const decl = this.tast.declarationOf(callee);
      if (decl && ts.isFunctionDeclaration(decl)) return decl;
      if (decl && ts.isVariableDeclaration(decl) && this.hoistedFns.has(decl)) return decl;
      return null;
    }
    if (ts.isPropertyAccessExpression(callee)) {
      const decl = this.tast.declarationOf(callee.name);
      if (decl && ts.isMethodDeclaration(decl) && ts.isClassDeclaration(decl.parent)) return decl;
      if (this.isNamespaceAliasBase(callee.expression) && decl && ts.isFunctionDeclaration(decl)) return decl;
      return null;
    }
    return null;
  }

  /// Wrap an emitted call of a LEAKING function for this site: inside a
  /// try body the error breaks to its catch; elsewhere it propagates (the
  /// enclosing function leaks too, by the fixpoint).
  private wrapThrowingCall(code: string, ctx: Ctx): string {
    return ctx.tryLabel ? `(${code} catch break :${ctx.tryLabel})` : `(try ${code})`;
  }

  /// Whether anything inside `root` can REACH the enclosing catch: a throw
  /// or a leaking call not contained by a nested try/catch within root.
  private throwsWithin(root: ts.Node): boolean {
    if (this.thrownShape === null) return false;
    let found = false;
    const containedBelow = (n: ts.Node): boolean => {
      let cur: ts.Node | undefined = n;
      let prev: ts.Node | undefined;
      while (cur && cur !== root) {
        if (ts.isTryStatement(cur) && cur.catchClause && prev === cur.tryBlock) return true;
        prev = cur;
        cur = cur.parent;
      }
      return false;
    };
    const visit = (n: ts.Node): void => {
      if (found) return;
      if ((ts.isArrowFunction(n) || ts.isFunctionExpression(n)) && [...this.hoistedFns.values()].includes(n)) return;
      if (ts.isFunctionDeclaration(n)) return;
      if (ts.isThrowStatement(n) && !containedBelow(n)) {
        found = true;
        return;
      }
      if ((ts.isCallExpression(n) || ts.isNewExpression(n)) && !containedBelow(n)) {
        const target = this.calleeOwnerOf(n);
        if (target && this.leakingFns.has(target)) {
          found = true;
          return;
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(root);
    return found;
  }

  /// Claim every module-level name up front, across all files: fixture
  /// names first, then types (never renamed), then exported values (never
  /// renamed), then private values entry-first — a private collision takes
  /// `<module>_<name>` (then `_2`, `_3`, ... if still taken).
  private claimModuleNames(): void {
    const taken = new Set<string>(emittedFixtureNames);
    // R20 fixture names (emitted only when something throws, reserved always).
    taken.add("Thrown");
    taken.add("thrown_payload");
    taken.add(THROWN_UNION_NAME);
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (ts.isInterfaceDeclaration(stmt) || ts.isTypeAliasDeclaration(stmt)) {
          taken.add(stmt.name.text);
          taken.add(`commit${stmt.name.text}`);
          taken.add(`commit${stmt.name.text}s`);
        } else if (ts.isClassDeclaration(stmt) && stmt.name) {
          taken.add(stmt.name.text);
          taken.add(`commit${stmt.name.text}`);
          taken.add(`commit${stmt.name.text}s`);
        }
      }
    }
    // Data-class functions: the constructor (`Task__new`) and one module
    // fn per method (`Task__rename`), claimed like every module name.
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (!ts.isClassDeclaration(stmt) || !stmt.name) continue;
        const cls = this.table.classes.get(stmt.name.text);
        if (!cls || cls.decl !== stmt) continue;
        const claimClassFn = (member: string): void => {
          let candidate = `${stmt.name!.text}__${member}`;
          let n = 2;
          while (taken.has(candidate)) candidate = `${stmt.name!.text}__${member}_${n++}`;
          taken.add(candidate);
          this.classFnNames.set(`${stmt.name!.text}#${member}`, candidate);
        };
        claimClassFn("new");
        for (const m of cls.methods) {
          if (ts.isIdentifier(m.name)) claimClassFn(m.name.text);
        }
        // Statics: module-level functions and consts under the class's
        // mangled names (`Task__fromRow`, `Task__LIMIT`).
        for (const m of cls.staticMethods) {
          if (ts.isIdentifier(m.name)) claimClassFn(m.name.text);
        }
        for (const m of cls.staticConsts) {
          if (ts.isIdentifier(m.name)) claimClassFn(m.name.text);
        }
      }
    }
    // Export lists first: an un-renamed entry exports its declaration (the
    // decl claims its own name below, as exported); a renamed entry claims
    // the NEW name here so no private value steals it.
    for (const file of this.files) {
      for (const b of exportListBindings(this.tast, file)) {
        const t = b.target;
        if (!t || !this.fileSet.has(t.getSourceFile())) continue;
        if (!ts.isFunctionDeclaration(t) && !ts.isVariableDeclaration(t)) continue;
        if (b.renamed) {
          taken.add(b.exportedName);
          this.exportAliasNames.add(b.exportedName);
        } else {
          this.listExportedDecls.add(t);
        }
      }
    }
    const claimValue = (decl: ts.Node, name: ts.Identifier, exported: boolean, file: ts.SourceFile): void => {
      if (exported || !taken.has(name.text)) {
        taken.add(name.text);
        this.moduleNames.set(decl, name.text);
        return;
      }
      const stem = snakeCase(path.basename(file.fileName).replace(/\.ts$/, "")).replace(/[^A-Za-z0-9_]/g, "_");
      let candidate = `${stem}_${name.text}`;
      let n = 2;
      while (taken.has(candidate)) candidate = `${stem}_${name.text}_${n++}`;
      taken.add(candidate);
      this.moduleNames.set(decl, candidate);
    };
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (ts.isFunctionDeclaration(stmt) && stmt.name) {
          claimValue(stmt, stmt.name, this.isExportedDecl(stmt), file);
        } else if (ts.isVariableStatement(stmt)) {
          for (const d of stmt.declarationList.declarations) {
            if (ts.isIdentifier(d.name)) claimValue(d, d.name, hasExportModifier(stmt) || this.listExportedDecls.has(d), file);
          }
        }
      }
    }
    // R15d: const-bound local function values hoist to module scope. Claim
    // their emitted names up front (source name when free, else qualified
    // by the enclosing function) so no body local shadows one — Zig
    // rejects all shadowing.
    for (const file of this.files) {
      const visit = (node: ts.Node): void => {
        if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name)) {
          const fn = constFunctionValue(node);
          if (fn) {
            this.hoistedFns.set(node, fn);
            let cur: ts.Node | undefined = node.parent;
            while (cur && !ts.isFunctionDeclaration(cur)) cur = ts.isSourceFile(cur) ? undefined : cur.parent;
            const owner = cur && ts.isFunctionDeclaration(cur) ? cur.name?.text : undefined;
            let candidate = node.name.text;
            if (taken.has(candidate) && owner) candidate = `${owner}_${node.name.text}`;
            let n = 2;
            while (taken.has(candidate)) candidate = `${node.name.text}_${n++}`;
            taken.add(candidate);
            this.moduleNames.set(node, candidate);
          }
        }
        ts.forEachChild(node, visit);
      };
      visit(file);
    }
  }

  /// The emitted name of a module-level value declaration (identity), or
  /// null when the declaration is not module-level.
  private moduleNameOf(decl: ts.Node | undefined): string | null {
    if (!decl) return null;
    return this.moduleNames.get(decl) ?? null;
  }

  /// Exported by the modifier OR an un-renamed export list entry — the two
  /// spellings bind the same flat-namespace name and emit `pub` alike.
  private isExportedDecl(decl: ts.Node): boolean {
    return hasExportModifier(decl) || this.listExportedDecls.has(decl);
  }

  fail(node: ts.Node, what: string, ruleId: RuleId = "NS9001"): never {
    throw new EmitError(what, node, ruleId);
  }

  /// Whether an expression is an `import * as ns` alias, by its own symbol
  /// (shadowing locals do not count). The alias is pure dot-syntax: member
  /// references resolve to the target module's declarations and emit their
  /// flat module-scope names.
  private isNamespaceAliasBase(e: ts.Expression): boolean {
    if (!ts.isIdentifier(e)) return false;
    const sym = this.tast.symbolOf(e);
    const d = sym?.declarations?.[0];
    return d !== undefined && ts.isNamespaceImport(d);
  }

  /// An SDK function imported from "@native-sdk/core", recognized by
  /// identity: the resolved declaration lives in the SDK module itself, so
  /// renames are honored and shadowing locals are not.
  private isSdkIntrinsic(decl: ts.Declaration, name: string): decl is ts.FunctionDeclaration {
    return (
      ts.isFunctionDeclaration(decl) &&
      decl.name?.text === name &&
      path.resolve(decl.getSourceFile().fileName) === path.resolve(sdkCoreModulePath)
    );
  }

  // ================================================================= module

  /// Exported single-Model-parameter helpers: `export function doneCount(
  /// model: Model): number`. Each also emits as a forwarding declaration ON
  /// the Model struct (`fn (self: *const Model) V`, under the TS name) so
  /// markup views bind the derived value by the name you wrote
  /// (`{doneCount}`) — the same fn-backed-scalar shape Zig app models
  /// expose. The reserved
  /// core entry points never forward (update/initialModel/subscriptions are
  /// the dispatch surface, not derived values).
  private modelHelpers(): ModelHelper[] {
    const out: ModelHelper[] = [];
    if (!this.table.structs.has("Model")) return out;
    for (const h of this.table.modelHelperDecls()) {
      const rt = this.table.resolveTypeNode(h.decl.type!);
      const ret = this.returnTypeRef(this.resolveNumberClass(rt, h.decl), h.decl);
      out.push({ name: h.name, zigName: h.zigName, fnName: this.moduleNameOf(h.decl) ?? h.name, decl: h.decl, ret });
    }
    // NS1031 re-derivation: one emitted name per Model member. A forwarder
    // colliding with a field (or another forwarder) would be ambiguous to
    // every binding engine, and Zig rejects the declaration outright.
    const model = this.table.structs.get("Model")!;
    const taken = new Map<string, string>();
    for (const f of model.fields) taken.set(f.zigName, `Model field \`${f.tsName}\``);
    taken.set("view_unbound", "the `view_unbound` opt-out declaration");
    for (const h of out) {
      const holder = taken.get(h.zigName);
      if (holder !== undefined) {
        this.fail(
          h.decl,
          `Exported helper \`${h.name}\` emits the Model declaration \`${h.zigName}\`, which collides with ${holder}.`,
          "NS1031",
        );
      }
      taken.set(h.zigName, `exported helper \`${h.name}\``);
    }
    return out;
  }

  /// The `export const viewUnbound = [...] as const` opt-out list, split by
  /// where each name lands: Model members (fields and exported helpers, by
  /// their TS names — the names markup binds) and Msg kinds (raw tags). Emitted as
  /// `pub const view_unbound` on Model/Msg — the dead-state lint opt-out
  /// `native check` reads. NS1032 re-derivation: the checker validates the
  /// same shape with the teaching copy.
  private viewUnboundNames(helpers: readonly ModelHelper[]): { model: string[]; msg: string[] } {
    const model: string[] = [];
    const msg: string[] = [];
    for (const stmt of this.file.statements) {
      if (!ts.isVariableStatement(stmt)) continue;
      for (const decl of stmt.declarationList.declarations) {
        if (!ts.isIdentifier(decl.name) || decl.name.text !== "viewUnbound" || !decl.initializer) continue;
        let init = decl.initializer;
        while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init)) init = init.expression;
        if (!ts.isArrayLiteralExpression(init)) {
          this.fail(decl, "`viewUnbound` must be a const array of string literals.", "NS1032");
        }
        const modelFields = this.table.structs.get("Model")?.fields ?? [];
        const msgArms = this.table.unions.get("Msg")?.arms ?? [];
        for (const el of init.elements) {
          if (!ts.isStringLiteral(el)) {
            this.fail(el, "`viewUnbound` entries must be string literals.", "NS1032");
          }
          const entry = el.text;
          const field = modelFields.find((f) => f.tsName === entry);
          const helper = helpers.find((h) => h.name === entry);
          const arm = msgArms.find((a) => a.tag === entry);
          if (field) model.push(field.tsName);
          else if (helper) model.push(helper.name);
          else if (arm) msg.push(arm.tag);
          else this.fail(el, `\`${entry}\` names no Model field, exported model helper, or Msg kind.`, "NS1032");
        }
      }
    }
    return { model, msg };
  }

  emitModule(): string {
    if (this.files.length > 1) {
      const names = this.files.map((f) => path.basename(f.fileName)).join(", ");
      this.out.push(`//! Emitted from ${this.sourceName} and its imports (${names}; one`);
      this.out.push(`//! section per source module) by @native-sdk/core, the app-core subset`);
    } else {
      this.out.push(`//! Emitted from ${this.sourceName} by @native-sdk/core, the app-core subset`);
    }
    this.out.push(`//! transpiler. Mapping rules R1-R18 are the subset spec's; the rt kernel`);
    this.out.push(`//! provides the frame arena and the two-space committed-model heap.`);
    this.out.push(``);
    this.out.push(`const std = @import("std");`);
    const caps: string[] = [];
    if (this.capacities.frameCap !== undefined) caps.push(`.frame_cap = ${this.capacities.frameCap}`);
    if (this.capacities.heapCap !== undefined) caps.push(`.heap_cap = ${this.capacities.heapCap}`);
    if (caps.length > 0) {
      // App-configured kernel capacities (the transpiler's --frame-cap /
      // --heap-cap options): comptime parameters of the rt instantiation.
      this.out.push(`pub const rt = @import("rt.zig").Kernel(.{ ${caps.join(", ")} });`);
    } else {
      this.out.push(`pub const rt = @import("rt.zig").default;`);
    }
    this.out.push(``);
    this.out.push(`// R2: integer-inferred \`number\` -> i64; \`.length\` reads widen to i64.`);
    this.out.push(`inline fn jlen(bytes: []const u8) i64 {`);
    this.out.push(`    return @intCast(bytes.len);`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R2: i64 -> usize at every memory-index site (checked in safe builds).`);
    this.out.push(`inline fn uz(v: i64) usize {`);
    this.out.push(`    return @intCast(v);`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R9: JS bitwise applies ToInt32 to each operand and yields that signed`);
    this.out.push(`// 32-bit result. Sites whose operands are provably in range emit the plain`);
    this.out.push(`// i64 operators instead (identical result, no wrap).`);
    this.out.push(`inline fn jsAnd(a: i64, b: i64) i64 {`);
    this.out.push(`    return @as(i32, @truncate(a)) & @as(i32, @truncate(b));`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn jsOr(a: i64, b: i64) i64 {`);
    this.out.push(`    return @as(i32, @truncate(a)) | @as(i32, @truncate(b));`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn jsXor(a: i64, b: i64) i64 {`);
    this.out.push(`    return @as(i32, @truncate(a)) ^ @as(i32, @truncate(b));`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R9: JS shifts wrap the value to 32 bits and mask the count & 31; \`<<\``);
    this.out.push(`// and \`>>\` yield the signed 32-bit result, \`>>>\` the unsigned one.`);
    this.out.push(`inline fn jsShl(a: i64, b: i64) i64 {`);
    this.out.push(`    const n: u5 = @intCast(@as(u32, @bitCast(@as(i32, @truncate(b)))) & 31);`);
    this.out.push(`    return @as(i32, @bitCast(@as(u32, @bitCast(@as(i32, @truncate(a)))) << n));`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn jsShr(a: i64, b: i64) i64 {`);
    this.out.push(`    const n: u5 = @intCast(@as(u32, @bitCast(@as(i32, @truncate(b)))) & 31);`);
    this.out.push(`    return @as(i32, @truncate(a)) >> n;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn jsUshr(a: i64, b: i64) i64 {`);
    this.out.push(`    const n: u5 = @intCast(@as(u32, @bitCast(@as(i32, @truncate(b)))) & 31);`);
    this.out.push(`    return @as(u32, @bitCast(@as(i32, @truncate(a)))) >> n;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn jsBitNot(a: i64) i64 {`);
    this.out.push(`    return ~@as(i32, @truncate(a));`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R8: JS \`**\` differs from libm pow on two corners it defines itself:`);
    this.out.push(`// a NaN exponent is NaN even for base 1, and (+-1) ** (+-Infinity) is NaN.`);
    this.out.push(`fn jsPow(a: f64, b: f64) f64 {`);
    this.out.push(`    if (std.math.isNan(b)) return std.math.nan(f64);`);
    this.out.push(`    if ((a == 1 or a == -1) and std.math.isInf(b)) return std.math.nan(f64);`);
    this.out.push(`    return std.math.pow(f64, a, b);`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R5b: two string-literal unions overlap as string sets, so equality across`);
    this.out.push(`// them compares the underlying literal names — resolved per member at compile`);
    this.out.push(`// time (no runtime string work). null on an optional side equals only null.`);
    this.out.push(`fn tagEq(a: anytype, b: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(b)) == .optional) return if (b) |v| tagEq(a, v) else tagIsNull(a);`);
    this.out.push(`    if (@typeInfo(@TypeOf(a)) == .optional) return if (a) |v| tagEq(v, b) else false;`);
    this.out.push(`    switch (a) {`);
    this.out.push(`        inline else => |v| {`);
    this.out.push(`            if (!@hasField(@TypeOf(b), @tagName(v))) return false;`);
    this.out.push(`            return b == @field(@TypeOf(b), @tagName(v));`);
    this.out.push(`        },`);
    this.out.push(`    }`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`fn tagIsNull(a: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(a)) == .optional) return a == null;`);
    this.out.push(`    return false;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// R5b: assigning across literal unions re-tags the value by literal name`);
    this.out.push(`// (the TypeScript checker has already proven the member exists there).`);
    this.out.push(`fn tagCast(comptime T: type, v: anytype) if (@typeInfo(@TypeOf(v)) == .optional) ?T else T {`);
    this.out.push(`    if (@typeInfo(@TypeOf(v)) == .optional) return if (v) |x| tagCast(T, x) else null;`);
    this.out.push(`    switch (v) {`);
    this.out.push(`        inline else => |tag| return @field(T, @tagName(tag)),`);
    this.out.push(`    }`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// JS \`===\` on strings compares contents, and null equals only null. The`);
    this.out.push(`// emitter routes string-typed (never bytes-typed) equality through here.`);
    this.out.push(`fn strEq(a: anytype, b: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(a)) == .optional) return if (a) |v| strEq(v, b) else strIsNull(b);`);
    this.out.push(`    if (@typeInfo(@TypeOf(b)) == .optional) return if (b) |v| strEq(a, v) else false;`);
    this.out.push(`    return std.mem.eql(u8, a, b);`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`fn strIsNull(b: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(b)) == .optional) return b == null;`);
    this.out.push(`    return false;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`// JS \`===\` on numbers whose machine classes diverge (an optional i64`);
    this.out.push(`// slot against an f64 value): unwrap optionals with the JS truth table`);
    this.out.push(`// (null equals only null, never a number) and widen the integer side`);
    this.out.push(`// exactly, so the comparison is IEEE f64 equality — node's semantics.`);
    this.out.push(`fn numEq(a: anytype, b: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(a)) == .optional) return if (a) |v| numEq(v, b) else numIsNull(b);`);
    this.out.push(`    if (@typeInfo(@TypeOf(b)) == .optional) return if (b) |v| numEq(a, v) else false;`);
    this.out.push(`    const av: f64 = if (@TypeOf(a) == i64) @floatFromInt(a) else a;`);
    this.out.push(`    const bv: f64 = if (@TypeOf(b) == i64) @floatFromInt(b) else b;`);
    this.out.push(`    return av == bv;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`fn numIsNull(b: anytype) bool {`);
    this.out.push(`    if (@typeInfo(@TypeOf(b)) == .optional) return b == null;`);
    this.out.push(`    return false;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`const empty_bytes: []const u8 = &.{};`);
    if (this.thrownShape !== null) {
      this.out.push(``);
      this.out.push(`// R20: \`throw\` unwinds as error.Thrown to the nearest catch; the thrown`);
      this.out.push(`// value (the core's thrown shape, NS1057) crosses in this slot. An`);
      this.out.push(`// uncaught throw panics at the exported boundary — node crashes there too.`);
      this.out.push(`const Thrown = error{Thrown};`);
      if (this.thrownSynthesized && this.thrownShape.k === "union") {
        // Heterogeneous throws: the slot is the union of the core's thrown
        // shapes, tagged by their \`kind\` fields — a catch narrows it with
        // ordinary kind tests.
        const info = this.table.unions.get(this.thrownShape.name)!;
        this.out.push(`const ${info.name} = union(enum) {`);
        for (const arm of info.arms) {
          if (arm.fields.length === 0) {
            this.out.push(`    ${zigId(arm.tag)},`);
          } else if (arm.fields.length === 1) {
            this.out.push(`    ${zigId(arm.tag)}: ${this.fieldTypeRef(arm.fields[0])},`);
          } else {
            const fields = arm.fields.map((f) => `${fieldName(f)}: ${this.fieldTypeRef(f)}`);
            this.out.push(`    ${zigId(arm.tag)}: struct { ${fields.join(", ")} },`);
          }
        }
        this.out.push(`};`);
      }
      this.out.push(`var thrown_payload: ${this.table.zigTypeRef(this.thrownShape)} = undefined;`);
    }

    this.helpers = this.modelHelpers();
    this.unbound = this.viewUnboundNames(this.helpers);
    this.validateHostChannels();
    if (this.helpers.length > 0) {
      this.out.push(``);
      this.out.push(`// Model forwarders call the module-level helpers through this alias:`);
      this.out.push(`// inside the Model struct an unqualified helper name would resolve to`);
      this.out.push(`// the forwarder itself.`);
      this.out.push(`const core_root = @This();`);
    }

    for (const file of this.files) {
      if (this.files.length > 1) {
        // One emitted module per core (one rt kernel instance, order-free
        // Zig scope); each source module keeps its identity as a section.
        this.out.push(``);
        this.out.push(`// ${"=".repeat(74)}`);
        this.out.push(`// module: ${path.basename(file.fileName)}${file === this.file ? " (entry)" : ""}`);
        this.out.push(`// ${"=".repeat(74)}`);
      }
      for (const stmt of file.statements) {
        const comments = this.leadingComments(stmt);
        if (
          ts.isVariableStatement(stmt) ||
          ts.isInterfaceDeclaration(stmt) ||
          ts.isTypeAliasDeclaration(stmt) ||
          ts.isFunctionDeclaration(stmt) ||
          ts.isClassDeclaration(stmt)
        ) {
          if (comments.length > 0) {
            this.out.push(``);
            this.out.push(...comments);
          } else {
            this.out.push(``);
          }
        }
        if (ts.isVariableStatement(stmt)) {
          this.emitModuleConst(stmt);
        } else if (ts.isInterfaceDeclaration(stmt)) {
          if (this.table.genericStructTemplates.has(stmt.name.text)) {
            // R15e: a generic interface is a template; instantiations emit
            // in the generated-instantiations section per concrete use.
            this.out.push(`// interface ${stmt.name.text}<...>: generic template (instantiations emit per use)`);
          } else {
            this.emitStruct(stmt);
          }
        } else if (ts.isTypeAliasDeclaration(stmt)) {
          this.emitTypeAlias(stmt);
        } else if (ts.isClassDeclaration(stmt)) {
          this.emitClass(stmt);
        } else if (ts.isFunctionDeclaration(stmt)) {
          if (stmt.typeParameters && stmt.typeParameters.length > 0) {
            // R15e: a generic function emits one monomorphic fn per
            // resolved call site (`pick__Task`), in the instantiations
            // section — nothing at the template's own site.
            this.out.push(`// fn ${stmt.name?.text}<...>: generic template (instantiations emit per call site)`);
          } else {
            this.emitFunction(stmt);
          }
        } else if (ts.isExportDeclaration(stmt)) {
          // Export lists: an un-renamed entry made its declaration `pub`
          // (nothing to emit here); a RENAMED entry binds a new exported
          // name over the declaration — a Zig alias in the flat namespace.
          const aliases: string[] = [];
          for (const b of exportListBindings(this.tast, file)) {
            if (b.spec.parent.parent !== stmt || !b.renamed) continue;
            const t = b.target;
            if (!t || !this.fileSet.has(t.getSourceFile())) continue;
            if (!ts.isFunctionDeclaration(t) && !ts.isVariableDeclaration(t)) continue;
            const targetName = this.moduleNameOf(t);
            if (targetName === null) continue; // generic templates and config are checker-taught
            aliases.push(`pub const ${b.exportedName} = ${targetName};`);
          }
          if (aliases.length > 0) {
            this.out.push(``);
            this.out.push(`// export { ... as ... }: renamed bindings over the flat namespace`);
            this.out.push(...aliases);
          }
          continue;
        } else if (ts.isImportDeclaration(stmt)) {
          // Imports carry no runtime code of their own: SDK/type-only
          // imports erase, and in-graph modules emit once in their own
          // section.
          continue;
        }
      }
    }

    // Generic instantiations and hoisted helpers may discover each other
    // (a helper calling a generic, a generic body declaring a helper), so
    // both queues drain to a joint fixed point; instantiated TYPES emit
    // last (Zig module scope is order-free).
    while (this.genericQueue.length > 0 || this.hoistQueue.length > 0) {
      this.emitGenericInstantiations();
      this.emitHoistedFunctions();
    }
    this.emitInstantiatedTypes();
    this.emitCommitWalkers();
    return this.out.join("\n") + "\n";
  }

  /// R15e: emit every queued generic instantiation under its resolved
  /// type-parameter scope.
  private emitGenericInstantiations(): void {
    while (this.genericQueue.length > 0) {
      const key = this.genericQueue.shift()!;
      const inst = this.genericInsts.get(key)!;
      this.out.push(``);
      this.out.push(
        `// ${inst.decl.name?.text}<${inst.args.map((a) => this.table.zigTypeRef(a)).join(", ")}> (R15e monomorphization)`,
      );
      this.table.withTypeParams(inst.scope, () => this.emitFunction(inst.decl, inst.name));
    }
  }

  /// Instantiated generic TYPES (`Box<Task>` -> `Box__Task`), in creation
  /// order; emission may not create new ones (fields resolved at
  /// instantiation), so a single drain suffices.
  private emitInstantiatedTypes(): void {
    for (const name of this.table.instantiationOrder) {
      const st = this.table.structs.get(name);
      if (st) {
        this.out.push(``);
        this.out.push(`// ${name}: generic instantiation (R15e)`);
        const fields = st.fields.map((f) => `${fieldName(f)}: ${this.fieldTypeRef(f)}`);
        if (fields.join(", ").length <= 70 && st.fields.length <= 2) {
          this.out.push(`${st.exported ? "pub " : ""}const ${name} = struct { ${fields.join(", ")} };`);
        } else {
          this.out.push(`${st.exported ? "pub " : ""}const ${name} = struct {`);
          for (const f of fields) this.out.push(`    ${f},`);
          this.out.push(`};`);
        }
        continue;
      }
      const un = this.table.unions.get(name);
      if (un) {
        this.out.push(``);
        this.out.push(`// ${name}: generic instantiation (R15e)`);
        this.out.push(`${un.exported ? "pub " : ""}const ${name} = union(enum) {`);
        for (const arm of un.arms) {
          if (arm.fields.length === 0) {
            this.out.push(`    ${zigId(arm.tag)},`);
          } else if (arm.fields.length === 1) {
            this.out.push(`    ${zigId(arm.tag)}: ${this.fieldTypeRef(arm.fields[0])},`);
          } else {
            const fields = arm.fields.map((f) => `${fieldName(f)}: ${this.fieldTypeRef(f)}`);
            this.out.push(`    ${zigId(arm.tag)}: struct { ${fields.join(", ")} },`);
          }
        }
        this.out.push(`};`);
      }
    }
  }

  /// R15d: emit every hoisted local helper (const-bound function values).
  /// Emission may discover more (a helper declaring its own helper), so the
  /// queue drains to a fixed point.
  private emitHoistedFunctions(): void {
    let first = true;
    while (this.hoistQueue.length > 0) {
      const decl = this.hoistQueue.shift()!;
      if (first) {
        this.out.push(``);
        this.out.push(`// ------------------------------------------- hoisted local helpers (R15d)`);
        first = false;
      }
      this.emitHoistedFunction(decl, this.hoistedFns.get(decl)!, this.moduleNames.get(decl)!);
    }
  }

  private emitHoistedFunction(
    decl: ts.VariableDeclaration,
    fn: ts.ArrowFunction | ts.FunctionExpression,
    name: string,
  ): void {
    if (!fn.type) this.fail(decl, "a hoisted helper without a return type annotation", "NS1054");
    const retT = this.resolveNumberClass(this.table.resolveTypeNode(fn.type), fn);
    const ctx: Ctx = {
      lines: [],
      indent: 1,
      names: new Map(),
      used: this.moduleScopeNames(),
      memberSubst: new Map(),
      stillOptionalSubst: new Map(),
      narrowedUnion: new Map(),
      narrowKilled: [],
      edgeKills: [],
      localTypes: new Map(),
      builders: new Map(),
      retLabel: null,
      returnType: retT,
      cmdReturn: null,
      subReturn: null,
    };
    const params: string[] = [];
    for (const p of fn.parameters) {
      if (!ts.isIdentifier(p.name) || !p.type) this.fail(p, "a hoisted helper parameter without a type annotation", "NS1054");
      if (p.initializer) this.fail(p, `parameter \`${p.name.text}\` declares a default value`, "NS1019");
      const zname = this.claim(ctx, p, zigLocalName(p.name.text));
      const t = this.table.resolveTypeNode(p.type);
      ctx.localTypes.set(p, t);
      params.push(`${zname}: ${this.typeRefWithNumbers(t, p)}`);
    }
    const ret = `${this.leakingFns.has(decl) ? "Thrown!" : ""}${this.returnTypeRef(retT, fn)}`;
    this.out.push(``);
    this.out.push(`// hoisted from \`const ${decl.name.getText()}\` in ${enclosingFunctionName(decl) ?? "a function body"}`);
    const sig = `fn ${name}(${params.join(", ")}) ${ret} {`;
    if (sig.length <= 100) {
      this.out.push(sig);
    } else {
      this.out.push(`fn ${name}(`);
      for (const p of params) this.out.push(`    ${p},`);
      this.out.push(`) ${ret} {`);
    }
    if (ts.isBlock(fn.body)) {
      this.emitBlockStatements(fn.body.statements, ctx);
    } else {
      const v = this.emitExpr(fn.body, ctx, retT).code;
      this.push(ctx, `return ${v};`);
    }
    const discards: string[] = [];
    for (const p of fn.parameters) {
      const zname = ctx.names.get(p)!;
      const used = new RegExp(`\\b${zname}\\b`);
      if (!ctx.lines.some((l) => used.test(l))) discards.push(`    _ = ${zname};`);
    }
    this.out.push(...discards, ...ctx.lines);
    this.out.push(`}`);
  }

  private leadingComments(stmt: ts.Node): string[] {
    const text = stmt.getSourceFile().getFullText();
    const ranges = ts.getLeadingCommentRanges(text, stmt.getFullStart()) ?? [];
    const lines: string[] = [];
    for (const r of ranges) {
      const raw = text.slice(r.pos, r.end);
      if (r.kind === ts.SyntaxKind.SingleLineCommentTrivia) {
        lines.push(raw.trimEnd());
      } else {
        for (const l of raw.split("\n")) {
          const stripped = l.replace(/^\s*\/?\*+\/?\s?/, "");
          if (stripped.trim().length > 0) lines.push(`// ${stripped.trimEnd()}`);
        }
      }
    }
    return lines;
  }

  // ---------------------------------------------------------- module consts

  private emitModuleConst(stmt: ts.VariableStatement): void {
    for (const decl of stmt.declarationList.declarations) {
      const pub = hasExportModifier(stmt) || this.listExportedDecls.has(decl) ? "pub " : "";
      if (!ts.isIdentifier(decl.name) || !decl.initializer) this.fail(stmt, "module const shape");
      const name = this.moduleNameOf(decl) ?? decl.name.text;
      // The dead-state opt-out list is transpiler config, not module data:
      // already validated and routed into the Model/Msg `view_unbound`
      // declarations (viewUnboundNames), nothing to emit here.
      if (name === "viewUnbound") continue;
      // The env override channel: a declarative table the generated wiring
      // walks at comptime (read the named variables once at launch,
      // dispatch each present value through its bytes arm).
      if (name === "envMsgs") {
        this.emitEnvMsgs(decl, pub);
        continue;
      }
      let init = decl.initializer;
      while (ts.isParenthesizedExpression(init) || ts.isSatisfiesExpression(init)) init = init.expression;
      const cls = this.infer.classOfDecl(decl);
      if (cls) {
        const value = this.tast.constEvalNumber(init);
        if (value === null) this.fail(decl, "module const must fold to a number (R1)");
        // R1: exported const number -> pub const i64/f64, comptime-foldable.
        this.out.push(`${pub}const ${name}: ${cls} = ${formatNumber(value, cls)};`);
        continue;
      }
      const declared = decl.type ? this.table.resolveTypeNode(decl.type) : null;
      if (ts.isStringLiteral(init)) {
        // R5: an enum-annotated literal is the member, not runtime text.
        if (declared?.k === "enum") {
          this.out.push(`${pub}const ${name}: ${declared.name} = .${zigId(init.text)};`);
        } else {
          this.out.push(`${pub}const ${name} = "${escapeZigString(init.text)}";`);
        }
        continue;
      }
      // R1b: module const tables — rodata, no arena involvement. asciiBytes
      // literals fold like everywhere else; arrays and interface-annotated
      // records recurse through emitComptimeValue.
      if (ts.isCallExpression(init) && ts.isIdentifier(init.expression)) {
        const fnDecl = this.tast.declarationOf(init.expression);
        if (fnDecl && this.isSdkIntrinsic(fnDecl, "asciiBytes") && ts.isStringLiteral(init.arguments[0])) {
          const bytesRef = this.table.zigTypeRef({ k: "bytes" });
          this.out.push(
            `${pub}const ${name}: ${bytesRef} = "${escapeZigString((init.arguments[0] as ts.StringLiteral).text)}";`,
          );
          continue;
        }
      }
      if (ts.isArrayLiteralExpression(init)) {
        const t = declared ?? this.zTypeOfExpr(init, this.moduleCtx());
        if (t.k !== "slice" || t.elem.k === "void") {
          this.fail(
            decl,
            `a module const table whose element type cannot be resolved (annotate the const: \`const ${name}: readonly T[] = [...]\`)`,
          );
        }
        this.out.push(`${pub}const ${name}: ${this.table.zigTypeRef(t)} = ${this.emitComptimeValue(init, t)};`);
        continue;
      }
      if (ts.isObjectLiteralExpression(init)) {
        if (!declared || declared.k !== "struct") {
          this.fail(
            decl,
            `a module const record without an interface annotation (declare the shape as an interface and annotate: \`const ${name}: Limits = { ... }\`)`,
          );
        }
        this.out.push(
          `${pub}const ${name}: ${this.table.zigTypeRef(declared)} = ${this.emitComptimeValue(init, declared)};`,
        );
        continue;
      }
      this.fail(
        decl,
        "module-level const of this initializer kind (v1 folds numbers, strings, asciiBytes literals, array tables, and interface-annotated record tables)",
      );
    }
  }

  /// `export const envMsgs = [{ env: "NAME", msg: "<arm>" }] as const` —
  /// the launch-time environment override channel: the generated wiring
  /// reads each named variable once at boot and dispatches every present
  /// value through its one-bytes-field arm (ordinary journaled Msgs, so
  /// replay carries the recorded values). Emitted as a comptime tuple the
  /// wiring walks with `inline for`.
  private emitEnvMsgs(decl: ts.VariableDeclaration, pub: string): void {
    let init = decl.initializer!;
    while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init)) init = init.expression;
    if (!ts.isArrayLiteralExpression(init)) {
      this.fail(decl, "`envMsgs` must be a const array of inline `{ env, msg }` records", "NS1033");
    }
    const entries: Array<{ env: string; msg: string }> = [];
    for (const el of init.elements) {
      let e: ts.Expression = el;
      while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
      if (!ts.isObjectLiteralExpression(e)) {
        this.fail(el, "`envMsgs` entries are inline `{ env, msg }` records", "NS1033");
      }
      let env: string | null = null;
      let msg: string | null = null;
      for (const p of e.properties) {
        if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name) || !ts.isStringLiteral(p.initializer)) {
          this.fail(p, "`envMsgs` fields are string literals", "NS1033");
        }
        if (p.name.text === "env") env = p.initializer.text;
        else if (p.name.text === "msg") msg = p.initializer.text;
        else this.fail(p, `\`envMsgs\` field \`${p.name.text}\` (entries carry exactly \`env\` and \`msg\`)`, "NS1033");
      }
      if (env === null || msg === null || env.length === 0) {
        this.fail(e, "`envMsgs` entries carry a non-empty `env` name and a `msg` arm", "NS1033");
      }
      const arm = this.hostChannelArm(el, msg, "envMsgs");
      if (!(arm.fields.length === 1 && arm.fields[0].type.k === "bytes")) {
        this.fail(el, `\`envMsgs\` target \`${msg}\` does not carry exactly one \`Uint8Array\` payload field`, "NS1033");
      }
      entries.push({ env, msg });
    }
    this.out.push(`${pub}const envMsgs = .{`);
    for (const entry of entries) {
      this.out.push(`    .{ .env = "${escapeZigString(entry.env)}", .msg = "${escapeZigString(entry.msg)}" },`);
    }
    this.out.push(`};`);
  }

  /// A Msg arm a wiring-channel export names, or a taught NS1033.
  private hostChannelArm(site: ts.Node, tag: string, channel: string): UnionInfo["arms"][number] {
    const info = this.table.unions.get("Msg");
    const arm = info?.arms.find((a) => a.tag === tag);
    if (!arm) {
      this.fail(site, `\`${channel}\` names \`${tag}\`, which is not an arm of the Msg union`, "NS1033");
    }
    return arm;
  }

  /// Validate the generated-wiring channel exports (`appearanceMsg`,
  /// `chromeMsg`, `frameMsg`, `keyMsg`, `pinchMsg`; `envMsgs` validates during its own
  /// emission and `commandMsg` needs only its fn form): the wiring builds
  /// these host events structurally from the declarations, so a wrong
  /// shape must be a teaching NS1033 at check time — transpile-clean
  /// implies zig-clean, generated wiring included.
  private validateHostChannels(): void {
    const isNum = (k: string): boolean => k === "number" || k === "i64" || k === "f64";
    const recordFields = (t: ZType): readonly ZField[] | null => {
      if (t.k !== "struct") return null;
      return this.table.structs.get(t.name)?.fields ?? null;
    };
    const fieldNamed = (fields: readonly ZField[], name: string): ZField | undefined =>
      fields.find((f) => f.tsName === name);
    const numericRecord = (t: ZType, names: readonly string[]): boolean => {
      const fields = recordFields(t);
      if (!fields || fields.length !== names.length) return false;
      return names.every((n) => {
        const f = fieldNamed(fields, n);
        return f !== undefined && isNum(f.type.k);
      });
    };
    for (const stmt of this.file.statements) {
      if (ts.isVariableStatement(stmt)) {
        for (const decl of stmt.declarationList.declarations) {
          if (!ts.isIdentifier(decl.name)) continue;
          if (!hasExportModifier(stmt) && !this.listExportedDecls.has(decl)) continue;
          const name = decl.name.text;
          if (name !== "appearanceMsg" && name !== "chromeMsg") continue;
          let init = decl.initializer;
          while (init && (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init))) init = init.expression;
          if (!init || !ts.isStringLiteral(init)) {
            this.fail(decl, `\`${name}\` must be a string literal naming a Msg arm`, "NS1033");
          }
          const arm = this.hostChannelArm(decl, init.text, name);
          if (name === "appearanceMsg") {
            // { colorScheme: <named "light"|"dark" alias>, reduceMotion:
            //   boolean, highContrast: boolean } — matched by NAME.
            const scheme = fieldNamed(arm.fields, "colorScheme");
            const schemeEnum = scheme && scheme.type.k === "enum" ? this.table.enums.get(scheme.type.name) : null;
            const schemeOk =
              schemeEnum !== null &&
              schemeEnum !== undefined &&
              schemeEnum.members.length === 2 &&
              schemeEnum.members.includes("light") &&
              schemeEnum.members.includes("dark");
            const ok =
              arm.fields.length === 3 &&
              schemeOk &&
              fieldNamed(arm.fields, "reduceMotion")?.type.k === "bool" &&
              fieldNamed(arm.fields, "highContrast")?.type.k === "bool";
            if (!ok) {
              this.fail(
                decl,
                `\`appearanceMsg\` target \`${init.text}\` is not the appearance record (exactly \`colorScheme\` — a named "light" | "dark" alias — plus \`reduceMotion\` and \`highContrast\` booleans)`,
                "NS1033",
              );
            }
          } else {
            // { insets: {top,right,bottom,left}, buttons: {x,y,width,height},
            //   tabsProjected: boolean } — matched by NAME.
            const insets = fieldNamed(arm.fields, "insets");
            const buttons = fieldNamed(arm.fields, "buttons");
            const ok =
              arm.fields.length === 3 &&
              insets !== undefined &&
              numericRecord(insets.type, ["top", "right", "bottom", "left"]) &&
              buttons !== undefined &&
              numericRecord(buttons.type, ["x", "y", "width", "height"]) &&
              fieldNamed(arm.fields, "tabsProjected")?.type.k === "bool";
            if (!ok) {
              this.fail(
                decl,
                `\`chromeMsg\` target \`${init.text}\` is not the chrome record (exactly \`insets\` — a top/right/bottom/left number record — plus \`buttons\` — an x/y/width/height number record — and a \`tabsProjected\` boolean)`,
                "NS1033",
              );
            }
          }
        }
      }
      if (ts.isFunctionDeclaration(stmt) && stmt.name && this.isExportedDecl(stmt)) {
        const name = stmt.name.text;
        if (name !== "frameMsg" && name !== "keyMsg" && name !== "pinchMsg") continue;
        const returnsMsgOrNull = ((): boolean => {
          if (!stmt.type) return false;
          const t = this.table.resolveTypeNode(stmt.type);
          return t.k === "optional" && t.inner.k === "union" && t.inner.name === "Msg";
        })();
        if (!returnsMsgOrNull) {
          this.fail(stmt, `\`${name}\` must return \`Msg | null\``, "NS1033");
        }
        if (name === "frameMsg") {
          const paramT = stmt.parameters.length === 2 && stmt.parameters[1].type
            ? this.table.resolveTypeNode(stmt.parameters[1].type!)
            : null;
          const modelT = stmt.parameters.length === 2 && stmt.parameters[0].type
            ? this.table.resolveTypeNode(stmt.parameters[0].type!)
            : null;
          const ok =
            modelT !== null &&
            modelT.k === "struct" &&
            modelT.name === "Model" &&
            paramT !== null &&
            numericRecord(paramT, ["width", "height", "timestampMs", "intervalMs"]);
          if (!ok) {
            this.fail(
              stmt,
              "`frameMsg` takes `(model: Model, frame: FrameEvent)` where FrameEvent is exactly `{ width, height, timestampMs, intervalMs }` numbers",
              "NS1033",
            );
          }
        } else if (name === "keyMsg") {
          const paramT = stmt.parameters.length === 1 && stmt.parameters[0].type
            ? this.table.resolveTypeNode(stmt.parameters[0].type!)
            : null;
          const fields = paramT ? recordFields(paramT) : null;
          const ok =
            fields !== null &&
            fields.length === 5 &&
            fieldNamed(fields, "key")?.type.k === "string" &&
            (["shift", "control", "alt", "super"] as const).every(
              (n) => fieldNamed(fields, n)?.type.k === "bool",
            );
          if (!ok) {
            this.fail(
              stmt,
              "`keyMsg` takes one `KeyEvent` parameter, exactly `{ key: string; shift: boolean; control: boolean; alt: boolean; super: boolean }`",
              "NS1033",
            );
          }
        } else {
          // pinchMsg: { windowId, label: string,
          //   phase: <named "begin"|"change"|"end" alias>, scale, x, y }
          //   — matched by NAME (the wiring maps the phase enum by
          //   member name and widens the numbers; windowId/label are the
          //   source identity — x/y are view-local, so a coordinate
          //   without its view is not a position).
          const paramT = stmt.parameters.length === 1 && stmt.parameters[0].type
            ? this.table.resolveTypeNode(stmt.parameters[0].type!)
            : null;
          const fields = paramT ? recordFields(paramT) : null;
          const phase = fields ? fieldNamed(fields, "phase") : undefined;
          const phaseEnum = phase && phase.type.k === "enum" ? this.table.enums.get(phase.type.name) : null;
          const phaseOk =
            phaseEnum !== null &&
            phaseEnum !== undefined &&
            phaseEnum.members.length === 3 &&
            phaseEnum.members.includes("begin") &&
            phaseEnum.members.includes("change") &&
            phaseEnum.members.includes("end");
          const ok =
            fields !== null &&
            fields.length === 6 &&
            phaseOk &&
            fieldNamed(fields, "label")?.type.k === "string" &&
            (["windowId", "scale", "x", "y"] as const).every((n) => {
              const f = fieldNamed(fields, n);
              return f !== undefined && isNum(f.type.k);
            });
          if (!ok) {
            this.fail(
              stmt,
              '`pinchMsg` takes one `PinchEvent` parameter, exactly `{ windowId: number; label: string; phase: PinchPhase; scale: number; x: number; y: number }` where PinchPhase is a named "begin" | "change" | "end" alias',
              "NS1033",
            );
          }
        }
      }
    }
  }

  /// A bare Ctx for module-scope type probes (no function state).
  private moduleCtx(): Ctx {
    return {
      lines: [],
      indent: 0,
      names: new Map(),
      used: new Set(),
      memberSubst: new Map(),
      stillOptionalSubst: new Map(),
      narrowedUnion: new Map(),
      narrowKilled: [],
      edgeKills: [],
      localTypes: new Map(),
      builders: new Map(),
      retLabel: null,
      returnType: { k: "void" },
      cmdReturn: null,
      subReturn: null,
    };
  }

  /// R1b: one value of a module const table — comptime data only, emitted as
  /// rodata (numbers fold, records become struct literals behind `&` when
  /// the type is a pointer struct, arrays become `&.{ ... }` slices).
  /// Number positions resolve through the same slot/element classes as
  /// runtime emission, so reads see identical types either way.
  private emitComptimeValue(expr: ts.Expression, expected: ZType): string {
    let e = expr;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (expected.k === "optional") {
      if (e.kind === ts.SyntaxKind.NullKeyword) return "null";
      return this.emitComptimeValue(e, expected.inner);
    }
    // A reference to another module const is already rodata: emit its name.
    if (ts.isIdentifier(e) && expected.k !== "number" && expected.k !== "i64" && expected.k !== "f64") {
      const decl = this.tast.declarationOf(e);
      if (decl && ts.isVariableDeclaration(decl) && decl.parent.parent && ts.isVariableStatement(decl.parent.parent)) {
        return this.moduleNameOf(decl) ?? e.text;
      }
    }
    switch (expected.k) {
      case "number":
        // Element positions the slot inference does not cover are f64 (R2).
        return this.comptimeNumber(e, "f64");
      case "f64":
        return this.comptimeNumber(e, "f64");
      case "i64":
        return this.comptimeNumber(e, "i64");
      case "numAlias":
        return this.comptimeNumber(e, "i64");
      case "bool":
        if (e.kind === ts.SyntaxKind.TrueKeyword) return "true";
        if (e.kind === ts.SyntaxKind.FalseKeyword) return "false";
        this.fail(e, "a table boolean that is not a literal");
        break;
      case "enum":
        if (ts.isStringLiteral(e)) return `.${zigId(e.text)}`;
        this.fail(e, "a table literal-union value that is not a string literal");
        break;
      case "string":
        if (ts.isStringLiteral(e)) return `"${escapeZigString(e.text)}"`;
        this.fail(e, "a table string that is not a literal");
        break;
      case "bytes": {
        if (ts.isCallExpression(e) && ts.isIdentifier(e.expression)) {
          const decl = this.tast.declarationOf(e.expression);
          if (decl && this.isSdkIntrinsic(decl, "asciiBytes") && ts.isStringLiteral(e.arguments[0])) {
            return `"${escapeZigString((e.arguments[0] as ts.StringLiteral).text)}"`;
          }
        }
        if (ts.isNewExpression(e) && ts.isIdentifier(e.expression) && e.expression.text === "Uint8Array") {
          const arg = e.arguments?.[0];
          if (!arg || (ts.isNumericLiteral(arg) && arg.text === "0")) return "empty_bytes";
        }
        this.fail(e, "table bytes that are not an asciiBytes literal (dynamic bytes cannot live in rodata)");
        break;
      }
      case "struct": {
        if (!ts.isObjectLiteralExpression(e)) this.fail(e, "a table record that is not an object literal");
        const info = this.table.structs.get(expected.name);
        if (!info) this.fail(e, `unknown struct ${expected.name}`);
        const values = new Map<string, ts.Expression>();
        for (const p of e.properties) {
          if (ts.isSpreadAssignment(p)) {
            this.fail(p, "a spread in a module const table (write the fields out — tables are comptime data)");
          }
          if (ts.isPropertyAssignment(p) && ts.isIdentifier(p.name)) values.set(p.name.text, p.initializer);
          else if (ts.isShorthandPropertyAssignment(p)) values.set(p.name.text, p.name);
          else this.fail(p, "table record member kind");
        }
        const parts: string[] = [];
        for (const f of info.fields) {
          const v = values.get(f.tsName);
          if (!v) this.fail(e, `table record missing field ${f.tsName}`);
          parts.push(`.${fieldName(f)} = ${this.emitComptimeValue(v, this.fieldZType(f))}`);
        }
        const literal = `.{ ${parts.join(", ")} }`;
        return info.promoted ? literal : `&${literal}`;
      }
      case "slice": {
        if (!ts.isArrayLiteralExpression(e)) this.fail(e, "a table array that is not an array literal");
        if (e.elements.some((el) => ts.isSpreadElement(el))) {
          this.fail(e, "a spread in a module const table (write the elements out — tables are comptime data)");
        }
        if (e.elements.length === 0) return "&.{}";
        const parts = e.elements.map((el) => this.emitComptimeValue(el as ts.Expression, expected.elem));
        return `&.{ ${parts.join(", ")} }`;
      }
      default:
        this.fail(e, `a module const table value of type ${expected.k} (v1)`);
    }
  }

  /// A comptime-folded number in a table slot of the given class.
  private comptimeNumber(e: ts.Expression, cls: "i64" | "f64"): string {
    const v = this.tast.constEvalNumber(e);
    if (v === null) this.fail(e, "a table number that does not fold at compile time (tables are comptime data)");
    return formatNumber(v, cls);
  }

  // ------------------------------------------------------------------ types

  private emitStruct(decl: ts.InterfaceDeclaration | ts.ClassDeclaration): void {
    if (!decl.name) return;
    const info = this.table.structs.get(decl.name.text);
    if (!info) return;
    const pub = info.exported ? "pub " : "";
    const note = info.promoted
      ? "" // R4 record promotion: by-value struct
      : "";
    const fields = info.fields.map((f) => `${fieldName(f)}: ${this.fieldTypeRef(f)}`);
    const isModel = info.name === "Model";
    const decls: string[] = [];
    if (isModel) {
      for (const h of this.helpers) {
        // The markup fn-backed-scalar shape (`fn (self: *const Model) V`),
        // forwarding to the emitted module-level helper.
        decls.push(`    pub fn ${h.zigName}(self: *const Model) ${h.ret} {`);
        decls.push(`        return core_root.${h.fnName}(self);`);
        decls.push(`    }`);
      }
      if (this.unbound.model.length > 0) {
        // The dead-state lint opt-out `native check` reads (viewUnbound).
        decls.push(`    pub const view_unbound = .{ ${this.unbound.model.map((n) => `"${n}"`).join(", ")} };`);
      }
    }
    if (decls.length === 0 && fields.join(", ").length <= 70 && info.fields.length <= 2) {
      this.out.push(`${pub}const ${info.name} = struct { ${fields.join(", ")} };${note}`);
    } else {
      this.out.push(`${pub}const ${info.name} = struct {`);
      for (const f of fields) this.out.push(`    ${f},`);
      if (decls.length > 0) this.out.push(``);
      this.out.push(...decls);
      this.out.push(`};`);
    }
  }

  /// R19: a data class emits as its struct (the same layout an interface
  /// takes) plus module-level functions: `Task__new` for the constructor
  /// (field initializers in declaration order, then the body) and one fn
  /// per method — mutating methods (any that write `this`, transitively)
  /// take `self: *Task`, the rest take the receiver by value.
  private emitClass(stmt: ts.ClassDeclaration): void {
    const name = stmt.name?.text;
    const cls = name !== undefined ? this.table.classes.get(name) : undefined;
    const st = name !== undefined ? this.table.structs.get(name) : undefined;
    if (!name || !cls || !st || st.decl !== stmt) {
      this.fail(stmt, "class declaration shape (NS1006/NS1055 territory)", "NS1006");
    }
    if (this.table.isPointerStruct(name)) {
      this.fail(
        stmt,
        `class \`${name}\` is stored in the Model tree — class instances stay local values in v1; store a record (interface) in the Model and construct the class from it where behavior is needed`,
        "NS1056",
      );
    }
    this.emitStruct(stmt);
    this.emitCtor(name, cls);
    for (const m of cls.methods) {
      this.out.push(``);
      this.emitMethod(name, cls, m);
    }
    // R19b: statics are per-class module declarations — `static readonly`
    // fields as consts, `static` methods as receiver-less functions, both
    // under the class's mangled names (`Task.LIMIT` -> `Task__LIMIT`).
    for (const m of cls.staticConsts) {
      this.emitStaticConst(name, m);
    }
    for (const m of cls.staticMethods) {
      this.out.push(``);
      this.emitStaticMethod(name, m);
    }
  }

  /// A `static readonly` field with an initializer: a module const under the
  /// class's mangled name, following the module-const value rules.
  private emitStaticConst(className: string, m: ts.PropertyDeclaration): void {
    const constName = this.classFnNames.get(`${className}#${(m.name as ts.Identifier).text}`)!;
    let init = m.initializer!;
    while (ts.isParenthesizedExpression(init) || ts.isSatisfiesExpression(init) || ts.isAsExpression(init)) init = init.expression;
    const cls = this.infer.classOfDecl(m);
    if (cls) {
      const value = this.tast.constEvalNumber(init);
      if (value === null) this.fail(m, `static const \`${(m.name as ts.Identifier).text}\` must fold to a number (R1)`);
      this.out.push(`const ${constName}: ${cls} = ${formatNumber(value, cls)};`);
      return;
    }
    const declared = m.type ? this.table.resolveTypeNode(m.type) : null;
    if (ts.isStringLiteral(init)) {
      if (declared?.k === "enum") {
        this.out.push(`const ${constName}: ${declared.name} = .${zigId(init.text)};`);
      } else {
        this.out.push(`const ${constName} = "${escapeZigString(init.text)}";`);
      }
      return;
    }
    if (ts.isCallExpression(init) && ts.isIdentifier(init.expression)) {
      const fnDecl = this.tast.declarationOf(init.expression);
      if (fnDecl && this.isSdkIntrinsic(fnDecl, "asciiBytes") && ts.isStringLiteral(init.arguments[0])) {
        const bytesRef = this.table.zigTypeRef({ k: "bytes" });
        this.out.push(`const ${constName}: ${bytesRef} = "${escapeZigString((init.arguments[0] as ts.StringLiteral).text)}";`);
        return;
      }
    }
    if (ts.isArrayLiteralExpression(init) && declared?.k === "slice" && declared.elem.k !== "void") {
      this.out.push(`const ${constName}: ${this.table.zigTypeRef(declared)} = ${this.emitComptimeValue(init, declared)};`);
      return;
    }
    if (ts.isObjectLiteralExpression(init) && declared?.k === "struct") {
      this.out.push(`const ${constName}: ${this.table.zigTypeRef(declared)} = ${this.emitComptimeValue(init, declared)};`);
      return;
    }
    this.fail(
      m,
      `static const of this initializer kind (statics fold numbers, strings, asciiBytes literals, and annotated array/record tables — like module consts)`,
    );
  }

  /// A `static` method: a module-level function with no receiver, under the
  /// class's mangled name (`Task.fromRow(...)` -> `Task__fromRow(...)`).
  private emitStaticMethod(className: string, m: ts.MethodDeclaration): void {
    if (!m.body || !ts.isIdentifier(m.name)) this.fail(m, "static method declaration shape");
    const fnName = this.classFnNames.get(`${className}#${m.name.text}`)!;
    const ctx = this.classBodyCtx(m.type ? this.resolveNumberClass(this.table.resolveTypeNode(m.type), m) : { k: "void" });
    const params: string[] = [];
    for (const p of m.parameters) {
      if (!ts.isIdentifier(p.name) || !p.type) this.fail(p, "static method parameter without a type annotation");
      if (p.initializer) this.fail(p, `parameter \`${p.name.text}\` declares a default value`, "NS1019");
      const zname = this.claim(ctx, p, zigLocalName(p.name.text));
      const t = this.table.resolveTypeNode(p.type);
      ctx.localTypes.set(p, t);
      params.push(`${zname}: ${this.paramTypeRef(p, t, m.body)}`);
    }
    const ret = `${this.leakingFns.has(m) ? "Thrown!" : ""}${m.type ? this.returnTypeRef(ctx.returnType, m) : "void"}`;
    this.out.push(`fn ${fnName}(${params.join(", ")}) ${ret} {`);
    this.emitBlockStatements(m.body.statements, ctx);
    this.out.push(...this.paramDiscards(ctx, [...m.parameters]), ...ctx.lines);
    this.out.push(`}`);
  }

  private classBodyCtx(returnType: ZType): Ctx {
    return {
      lines: [],
      indent: 1,
      names: new Map(),
      used: this.moduleScopeNames(),
      memberSubst: new Map(),
      stillOptionalSubst: new Map(),
      narrowedUnion: new Map(),
      narrowKilled: [],
      edgeKills: [],
      localTypes: new Map(),
      builders: new Map(),
      retLabel: null,
      returnType,
      cmdReturn: null,
      subReturn: null,
    };
  }

  /// Zig rejects unused parameters; discard the ones the emitted body never
  /// reads (shared by functions, constructors, and methods).
  private paramDiscards(ctx: Ctx, decls: readonly ts.Node[]): string[] {
    const discards: string[] = [];
    for (const p of decls) {
      const zname = ctx.names.get(p);
      if (!zname) continue;
      const used = new RegExp(`\\b${zname}\\b`);
      if (!ctx.lines.some((l) => used.test(l))) discards.push(`    _ = ${zname};`);
    }
    return discards;
  }

  private emitCtor(name: string, cls: ClassInfo): void {
    const fnName = this.classFnNames.get(`${name}#new`)!;
    const ctx = this.classBodyCtx({ k: "struct", name });
    const params: string[] = [];
    for (const p of cls.ctor?.parameters ?? []) {
      if (!ts.isIdentifier(p.name) || !p.type) this.fail(p, "constructor parameter without a type annotation");
      if (p.initializer) this.fail(p, `parameter \`${p.name.text}\` declares a default value`, "NS1019");
      const zname = this.claim(ctx, p, zigLocalName(p.name.text));
      const t = this.table.resolveTypeNode(p.type);
      ctx.localTypes.set(p, t);
      params.push(`${zname}: ${this.paramTypeRef(p, t, cls.ctor?.body)}`);
    }
    const self = this.claim(ctx, cls.decl, "self");
    ctx.thisName = self;
    ctx.thisType = { k: "struct", name };
    ctx.thisSelfPtr = false;
    ctx.ctorSelf = self;
    this.out.push(``);
    this.out.push(`// \`new ${name}(...)\`: field initializers in declaration order, then the constructor body.`);
    this.out.push(`fn ${fnName}(${params.join(", ")}) ${cls.ctor && this.leakingFns.has(cls.ctor) ? `Thrown!${name}` : name} {`);
    this.push(ctx, `var ${self}: ${name} = undefined;`);
    const st = this.table.structs.get(name)!;
    for (const member of cls.decl.members) {
      if (!ts.isPropertyDeclaration(member) || !ts.isIdentifier(member.name) || !member.initializer) continue;
      const f = st.fields.find((x) => x.tsName === (member.name as ts.Identifier).text);
      if (!f) continue;
      const v = this.emitExpr(member.initializer, ctx, this.resolveNumberClass(f.type, f.decl));
      this.push(ctx, `${self}.${f.zigName} = ${v.code};`);
    }
    if (cls.ctor?.body) this.emitBlockStatements(cls.ctor.body.statements, ctx);
    this.push(ctx, `return ${self};`);
    this.out.push(...this.paramDiscards(ctx, cls.ctor?.parameters ?? []), ...ctx.lines);
    this.out.push(`}`);
  }

  private emitMethod(name: string, cls: ClassInfo, m: ts.MethodDeclaration): void {
    if (!m.body || !ts.isIdentifier(m.name)) this.fail(m, "method declaration shape");
    const mName = m.name.text;
    const fnName = this.classFnNames.get(`${name}#${mName}`)!;
    const mutates = cls.mutating.has(mName);
    const ctx = this.classBodyCtx(m.type ? this.resolveNumberClass(this.table.resolveTypeNode(m.type), m) : { k: "void" });
    const self = this.claim(ctx, m, "self");
    ctx.thisName = self;
    ctx.thisType = { k: "struct", name };
    ctx.thisSelfPtr = mutates;
    const params: string[] = [`${self}: ${mutates ? `*${name}` : name}`];
    for (const p of m.parameters) {
      if (!ts.isIdentifier(p.name) || !p.type) this.fail(p, "method parameter without a type annotation");
      if (p.initializer) this.fail(p, `parameter \`${p.name.text}\` declares a default value`, "NS1019");
      const zname = this.claim(ctx, p, zigLocalName(p.name.text));
      const t = this.table.resolveTypeNode(p.type);
      ctx.localTypes.set(p, t);
      params.push(`${zname}: ${this.paramTypeRef(p, t, m.body)}`);
    }
    const ret = `${this.leakingFns.has(m) ? "Thrown!" : ""}${m.type ? this.returnTypeRef(ctx.returnType, m) : "void"}`;
    this.out.push(`fn ${fnName}(${params.join(", ")}) ${ret} {`);
    this.emitBlockStatements(m.body.statements, ctx);
    this.out.push(...this.paramDiscards(ctx, [m, ...m.parameters]), ...ctx.lines);
    this.out.push(`}`);
  }

  private fieldTypeRef(f: ZField): string {
    // An unresolvable field type (`void` marks it) must never emit: a void
    // field would silently drop the payload and its reads would not
    // compile. The one common way here is an INLINE literal union — name it.
    if (f.type.k === "void" || (f.type.k === "optional" && f.type.inner.k === "void")) {
      this.fail(
        f.decl,
        `field \`${f.tsName}\` has a type outside the subset forms (an inline string-literal union must be a NAMED alias: \`export type Scheme = "light" | "dark"\`)`,
      );
    }
    return this.typeRefWithNumbers(f.type, f.decl);
  }

  /// zigTypeRef with `number` resolved through the inference result for the
  /// given declaration slot.
  private typeRefWithNumbers(t: ZType, decl: ts.Node): string {
    if (t.k === "number") return this.infer.classOfDecl(decl) ?? "f64";
    if (t.k === "optional" && t.inner.k === "number") {
      return `?${this.infer.classOfDecl(decl) ?? "f64"}`;
    }
    return this.table.zigTypeRef(t);
  }

  /// The type as an EXPECTED type for value emission: `number` resolved to
  /// the declaration slot's inferred class so float positions are visible.
  private resolveNumberClass(t: ZType, decl: ts.Node): ZType {
    if (t.k === "number") return { k: this.infer.classOfDecl(decl) ?? "f64" };
    if (t.k === "optional" && t.inner.k === "number") {
      return { k: "optional", inner: { k: this.infer.classOfDecl(decl) ?? "f64" } };
    }
    return t;
  }

  private emitTypeAlias(decl: ts.TypeAliasDeclaration): void {
    const name = decl.name.text;
    const pub = hasExportModifier(decl) ? "pub " : "";
    if (this.table.genericAliasTemplates.has(name)) {
      // A generic alias is a template: instantiations emit on demand in the
      // generated-instantiations section; the template itself erases.
      this.out.push(`// type ${name}<...>: generic template (instantiations emit per use)`);
      return;
    }
    if (this.table.structuralAliases.has(name)) {
      // `type Limit = typeof LIMIT` — type-level only; every slot typed by
      // it already carries the widened value type, so nothing emits here.
      this.out.push(`// type ${name} = ${decl.type.getText()} (type query; erases)`);
      return;
    }
    if (this.table.bytesAliases.has(name)) {
      // R3: Uint8Array -> []const u8 (immutable view once escaped).
      this.out.push(`${pub}const ${name} = []const u8;`);
      return;
    }
    const en = this.table.enums.get(name);
    if (en) {
      // R5: string-literal union -> enum(u8), declaration order (wire-stable).
      const members = en.members.map((m, i) => `${zigId(m)} = ${i}`).join(", ");
      const oneLine = `${pub}const ${name} = enum(u8) { ${members} };`;
      if (oneLine.length <= 100) this.out.push(oneLine);
      else {
        this.out.push(`${pub}const ${name} = enum(u8) {`);
        en.members.forEach((m, i) => this.out.push(`    ${zigId(m)} = ${i},`));
        this.out.push(`};`);
      }
      return;
    }
    const na = this.table.numAliases.get(name);
    if (na) {
      // R5: number-literal union -> its integer repr (see report: names for a
      // synthesized enum cannot be derived mechanically, so v1 keeps the ints).
      this.out.push(`${pub}const ${name} = ${na.repr}; // values: ${na.values.join(", ")}`);
      return;
    }
    const un = this.table.unions.get(name);
    if (un) {
      // R6: discriminated union (`kind` tag) -> union(enum), payloads inline.
      this.out.push(`${pub}const ${name} = union(enum) {`);
      for (const arm of un.arms) {
        if (arm.fields.length === 0) {
          this.out.push(`    ${zigId(arm.tag)},`);
        } else if (arm.fields.length === 1) {
          const f = arm.fields[0];
          this.out.push(`    ${zigId(arm.tag)}: ${this.fieldTypeRef(f)},`);
        } else {
          const fields = arm.fields.map((f) => `${fieldName(f)}: ${this.fieldTypeRef(f)}`);
          this.out.push(`    ${zigId(arm.tag)}: struct { ${fields.join(", ")} },`);
        }
      }
      if (name === "Msg" && this.unbound.msg.length > 0) {
        // The dead-state lint opt-out `native check` reads (viewUnbound).
        this.out.push(``);
        this.out.push(`    pub const view_unbound = .{ ${this.unbound.msg.map((n) => `"${n}"`).join(", ")} };`);
      }
      this.out.push(`};`);
      return;
    }
    const target = this.table.plainAliases.get(name);
    if (target) {
      this.out.push(`${pub}const ${name} = ${target};`);
      return;
    }
    this.fail(decl, `type alias \`${name}\` outside the subset type forms`);
  }

  // -------------------------------------------------------------- functions

  /// Module-scope names every function body must not shadow: Zig rejects
  /// ALL shadowing, so locals and generated temps claim around these. With
  /// a multi-file core this is every file's EMITTED module-level name.
  private moduleScopeNames(): Set<string> {
    const names = new Set<string>(emittedFixtureNames);
    names.add("Thrown");
    names.add("thrown_payload");
    names.add(THROWN_UNION_NAME);
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (ts.isInterfaceDeclaration(stmt) || ts.isTypeAliasDeclaration(stmt)) {
          names.add(stmt.name.text);
          names.add(`commit${stmt.name.text}`);
          names.add(`commit${stmt.name.text}s`);
        }
      }
    }
    for (const name of this.moduleNames.values()) names.add(name);
    for (const name of this.exportAliasNames) names.add(name);
    return names;
  }

  private emitFunction(decl: ts.FunctionDeclaration, nameOverride?: string): void {
    if (!decl.name || !decl.body) this.fail(decl, "function declaration shape");
    const name = nameOverride ?? this.moduleNameOf(decl) ?? decl.name.text;
    const pub = this.isExportedDecl(decl) ? "pub " : "";
    const cmdShape = this.cmdReturnShape(decl);
    const subShape = this.subReturnShape(decl);
    const ctx: Ctx = {
      lines: [],
      indent: 1,
      names: new Map(),
      used: this.moduleScopeNames(),
      memberSubst: new Map(),
      stillOptionalSubst: new Map(),
      narrowedUnion: new Map(),
      narrowKilled: [],
      edgeKills: [],
      localTypes: new Map(),
      builders: new Map(),
      retLabel: null,
      returnType: cmdShape
        ? this.table.resolveTypeNode(cmdShape.modelNode)
        : subShape || !decl.type
          ? { k: "void" }
          : this.resolveNumberClass(this.table.resolveTypeNode(decl.type), decl),
      cmdReturn: cmdShape ? { msgUnion: cmdShape.msgUnion } : null,
      subReturn: subShape ? { msgUnion: subShape.msgUnion } : null,
    };
    if (cmdShape) {
      // The pair-return contract: the committed-model root plus the encoded
      // command bytes (rt's Cmd wire format; consume before frameReset).
      // update's pair is UpdateResult; initialModel's boot pair (the init
      // command, run once at install) is InitResult.
      const modelRef = this.table.zigTypeRef(ctx.returnType);
      this.out.push(`pub const ${cmdShape.resultName} = struct { model: ${modelRef}, cmd: rt.Cmd };`);
      this.out.push(``);
    }
    const params: string[] = [];
    for (const p of decl.parameters) {
      if (!ts.isIdentifier(p.name) || !p.type) this.fail(p, "parameter without a type annotation");
      // Layer-3 re-derivation of NS1019: a default would be dropped from the
      // fixed-arity Zig signature and calls omitting the argument would break.
      if (p.initializer) this.fail(p, `parameter \`${p.name.text}\` declares a default value`, "NS1019");
      const zname = this.claim(ctx, p, zigLocalName(p.name.text));
      const t = this.table.resolveTypeNode(p.type);
      ctx.localTypes.set(p, t);
      params.push(`${zname}: ${this.paramTypeRef(p, t, decl.body)}`);
    }
    const retDecl: ts.Node = decl;
    const plainRet = cmdShape
      ? cmdShape.resultName
      : subShape
        ? "rt.Sub"
        : decl.type
          ? this.returnTypeRef(ctx.returnType, retDecl)
          : "void";
    // R20: a function a throw can propagate out of returns `Thrown!T`;
    // when it is EXPORTED, the plain-ABI wrapper below catches an uncaught
    // throw as a deterministic panic (node crashes at the same point).
    const leaks = this.leakingFns.has(decl) && !nameOverride;
    const wrapped = leaks && this.isExportedDecl(decl);
    const fnName = wrapped ? `${name}__throws` : name;
    const fnPub = wrapped ? "" : pub;
    const ret = this.leakingFns.has(decl) ? `Thrown!${plainRet}` : plainRet;
    const sig = `${fnPub}fn ${fnName}(${params.join(", ")}) ${ret} {`;
    if (sig.length <= 100) {
      this.out.push(sig);
    } else {
      this.out.push(`${fnPub}fn ${fnName}(`);
      for (const p of params) this.out.push(`    ${p},`);
      this.out.push(`) ${ret} {`);
    }
    this.emitBlockStatements(decl.body.statements, ctx);
    // Zig rejects unused parameters; discard the ones the EMITTED body never
    // reads (a source read may fold away entirely — Number.isInteger of an
    // integer-classed argument emits a constant).
    const discards: string[] = [];
    for (const p of decl.parameters) {
      const zname = ctx.names.get(p)!;
      const used = new RegExp(`\\b${zname}\\b`);
      if (!ctx.lines.some((l) => used.test(l))) discards.push(`    _ = ${zname};`);
    }
    this.out.push(...discards, ...ctx.lines);
    this.out.push(`}`);
    if (wrapped) {
      const argNames = decl.parameters.map((p) => ctx.names.get(p)!);
      this.out.push(``);
      this.out.push(`// The exported ABI stays plain: an uncaught throw is a defined panic here,`);
      this.out.push(`// exactly where node's process would crash.`);
      this.out.push(`${pub}fn ${name}(${params.join(", ")}) ${plainRet} {`);
      this.out.push(
        `    return ${fnName}(${argNames.join(", ")}) catch @panic("uncaught throw reached the core boundary (node crashes here too) — catch it inside the core");`,
      );
      this.out.push(`}`);
    }
  }

  /// The spec's effectful pair shape — `Model | [Model, Cmd<Msg>]` (or the
  /// bare tuple) on `update`, and the same boot pair on `initialModel` (the
  /// init command, performed once at install before the first view build).
  /// Returns the tuple's model type node, the Msg union the Cmd is
  /// parameterized over, and the emitted result-struct name; null for every
  /// plain return type.
  private cmdReturnShape(
    decl: ts.FunctionDeclaration,
  ): { modelNode: ts.TypeNode; msgUnion: string; resultName: string } | null {
    const t = decl.type;
    if (!t) return null;
    const members = ts.isUnionTypeNode(t) ? t.types : [t];
    const tuples = members.filter((m) => ts.isTupleTypeNode(m));
    if (tuples.length !== 1) return null;
    const tuple = tuples[0] as ts.TupleTypeNode;
    if (tuple.elements.length !== 2) return null;
    const cmdRef = tuple.elements[1];
    if (
      !ts.isTypeReferenceNode(cmdRef) ||
      !ts.isIdentifier(cmdRef.typeName) ||
      !this.checkResult.cmdNames.has(cmdRef.typeName.text)
    ) {
      return null;
    }
    // Re-derivation of NS1017: the checker only lets update and initialModel
    // carry this type.
    const fnName = decl.name?.text;
    if (fnName !== "update" && fnName !== "initialModel") {
      this.fail(t, "Cmd-bearing return type outside update/initialModel (NS1017)");
    }
    const arg = cmdRef.typeArguments?.[0];
    if (!arg || !ts.isTypeReferenceNode(arg) || !ts.isIdentifier(arg.typeName)) {
      this.fail(cmdRef, "Cmd type argument (the app's Msg union)");
    }
    const resolved = this.table.resolveName(arg.typeName.text);
    if (!resolved || resolved.k !== "union") this.fail(arg, "Cmd's Msg type argument (a discriminated union)");
    return {
      modelNode: tuple.elements[0],
      msgUnion: resolved.name,
      resultName: fnName === "update" ? "UpdateResult" : "InitResult",
    };
  }

  /// The declarative-subscriptions shape — `subscriptions(model): Sub<Msg>`.
  /// Returns the Msg union the Sub is parameterized over; null for every
  /// other return type.
  private subReturnShape(decl: ts.FunctionDeclaration): { msgUnion: string } | null {
    const t = decl.type;
    if (
      !t ||
      !ts.isTypeReferenceNode(t) ||
      !ts.isIdentifier(t.typeName) ||
      !this.checkResult.subNames.has(t.typeName.text)
    ) {
      return null;
    }
    // Re-derivation of NS1025: the checker only lets `subscriptions` carry
    // this type.
    if (decl.name?.text !== "subscriptions") {
      this.fail(t, "Sub-bearing return type outside subscriptions (NS1025)", "NS1025");
    }
    const arg = t.typeArguments?.[0];
    if (!arg || !ts.isTypeReferenceNode(arg) || !ts.isIdentifier(arg.typeName)) {
      this.fail(t, "Sub type argument (the app's Msg union)");
    }
    const resolved = this.table.resolveName(arg.typeName.text);
    if (!resolved || resolved.k !== "union") this.fail(arg, "Sub's Msg type argument (a discriminated union)");
    return { msgUnion: resolved.name };
  }

  /// The value of a `return` statement. Under the pair-return contract every
  /// return normalizes to the pair-result struct: `return model` is sugar for
  /// `[model, Cmd.none]` (spec section 2), and the cmd slot lowers through
  /// emitCmdExpr onto rt's command builders. Under the subscriptions
  /// contract the whole value lowers through emitSubExpr.
  private emitReturn(expr: ts.Expression, ctx: Ctx): string {
    if (ctx.subReturn) return this.emitSubExpr(expr, ctx);
    if (!ctx.cmdReturn) return this.emitExpr(expr, ctx, ctx.returnType).code;
    let e = expr;
    while (ts.isParenthesizedExpression(e)) e = e.expression;
    if (ts.isArrayLiteralExpression(e)) {
      if (e.elements.length !== 2 || e.elements.some((el) => ts.isSpreadElement(el))) {
        this.fail(e, "pair-return tuple shape ([model, cmd])");
      }
      const model = this.emitExpr(e.elements[0], ctx, ctx.returnType).code;
      const cmd = this.emitCmdExpr(e.elements[1], ctx);
      return `.{ .model = ${model}, .cmd = ${cmd} }`;
    }
    const model = this.emitExpr(expr, ctx, ctx.returnType).code;
    return `.{ .model = ${model}, .cmd = rt.cmd_none }`;
  }

  /// True when the expression is the imported SDK `Cmd` namespace.
  private isCmdNamespace(expr: ts.Expression): boolean {
    return ts.isIdentifier(expr) && this.checkResult.cmdNames.has(expr.text);
  }

  /// True when the expression is the imported SDK `Sub` namespace.
  private isSubNamespace(expr: ts.Expression): boolean {
    return ts.isIdentifier(expr) && this.checkResult.subNames.has(expr.text);
  }

  /// The cmd slot of a returned `[model, cmd]` tuple: inert factory data
  /// lowered directly onto the rt command builders, which encode the
  /// versioned Cmd wire format into the frame arena (rt.cmd_format_version).
  private emitCmdExpr(expr: ts.Expression, ctx: Ctx): string {
    let e = expr;
    while (ts.isParenthesizedExpression(e)) e = e.expression;
    if (ts.isConditionalExpression(e)) {
      const cond = this.emitCondition(e.condition, ctx);
      return `if (${cond}) ${this.emitCmdExpr(e.whenTrue, ctx)} else ${this.emitCmdExpr(e.whenFalse, ctx)}`;
    }
    if (ts.isPropertyAccessExpression(e) && this.isCmdNamespace(e.expression)) {
      if (e.name.text === "none") return "rt.cmd_none";
      this.fail(e, `Cmd.${e.name.text} in value position`);
    }
    if (
      ts.isCallExpression(e) &&
      ts.isPropertyAccessExpression(e.expression) &&
      this.isCmdNamespace(e.expression.expression)
    ) {
      const method = e.expression.name.text;
      if (method === "persist") return "rt.cmdPersist()";
      if (method === "now") {
        const arg = e.arguments[0];
        if (!arg || !ts.isStringLiteral(arg)) this.fail(e, "Cmd.now target (a string-literal Msg kind)");
        const unionName = ctx.cmdReturn!.msgUnion;
        const info = this.table.unions.get(unionName);
        if (!info) this.fail(e, `unknown union ${unionName}`);
        const arm = info.arms.find((a) => a.tag === arg.text);
        if (!arm) this.fail(arg, `Cmd.now target "${arg.text}" is not an arm of ${unionName}`);
        const numberPayload =
          arm.fields.length === 1 &&
          (arm.fields[0].type.k === "number" ||
            arm.fields[0].type.k === "i64" ||
            arm.fields[0].type.k === "f64");
        if (!numberPayload) {
          this.fail(arg, `Cmd.now target "${arg.text}" (needs exactly one number payload field)`);
        }
        return `rt.cmdNow(@intFromEnum(std.meta.Tag(${unionName}).${zigId(arg.text)}))`;
      }
      if (method === "host") {
        const nameArg = e.arguments[0];
        if (!nameArg || !ts.isStringLiteral(nameArg)) this.fail(e, "Cmd.host name (a string literal)");
        if (nameArg.text.length > 255) this.fail(nameArg, "Cmd.host name over 255 bytes");
        const rest = e.arguments.slice(1);
        // One bytes/record argument is the v2 payload form (host_bytes on
        // the wire); a payload with anything alongside it has no encoding.
        if (rest.some((a) => this.isHostPayloadArg(a, ctx))) {
          if (rest.length !== 1) {
            this.fail(e, `\`Cmd.host\` mixes a payload with other arguments`, "NS1026");
          }
          const payload = this.emitHostPayload(rest[0], ctx);
          return `rt.cmdHostBytes("${escapeZigString(nameArg.text)}", ${payload})`;
        }
        if (rest.length > 255) this.fail(e, "Cmd.host with over 255 args");
        const args = rest.map((a) => {
          // NS1020: the scalar form holds f64 scalars only. The check looks
          // through `as` casts, so a smuggled string value stops here
          // instead of corrupting the encoded arg list.
          const t = this.zTypeOfExpr(a, ctx);
          const numeric = t.k === "number" || t.k === "i64" || t.k === "f64" || t.k === "numAlias";
          if (!numeric) {
            this.fail(a, `\`Cmd.host\` argument \`${a.getText()}\` is not a number`, "NS1020");
          }
          return this.emitExpr(a, ctx, { k: "f64" }).code;
        });
        const list = args.length > 0 ? `&.{ ${args.join(", ")} }` : "&.{}";
        return `rt.cmdHost("${escapeZigString(nameArg.text)}", ${list})`;
      }
      if (method === "request") {
        const nameArg = e.arguments[0];
        if (!nameArg || !ts.isStringLiteral(nameArg)) this.fail(e, "Cmd.request name (a string literal)");
        if (nameArg.text.length > 255) this.fail(nameArg, "Cmd.request name over 255 bytes");
        const payloadArg = e.arguments[1];
        if (!payloadArg) this.fail(e, "Cmd.request payload (bytes or a flat record)");
        if (!this.isHostPayloadArg(payloadArg, ctx)) {
          this.fail(
            payloadArg,
            `\`Cmd.request\` payload \`${payloadArg.getText()}\` is not bytes or a flat record`,
            "NS1026",
          );
        }
        const route = this.requestRoute(e, e.arguments[2], ctx);
        const payload = this.emitHostPayload(payloadArg, ctx);
        return `rt.cmdRequest("${escapeZigString(nameArg.text)}", "${escapeZigString(route.key)}", ${route.okTag}, ${route.errTag}, ${payload})`;
      }
      if (method === "cancel") {
        const keyArg = e.arguments[0];
        if (!keyArg || !ts.isStringLiteral(keyArg)) {
          this.fail(e, `\`Cmd.cancel\` takes the effect key as a string literal`, "NS1027");
        }
        if (keyArg.text.length > 255) this.fail(keyArg, "Cmd.cancel key over 255 bytes");
        return `rt.cmdCancel("${escapeZigString(keyArg.text)}")`;
      }
      if (method === "readFile") {
        const path = this.effectBytesArg(e, e.arguments[0], "Cmd.readFile path", MAX_FILE_PATH_BYTES, ctx);
        const route = this.requestRoute(e, e.arguments[1], ctx, "bytes");
        return `rt.cmdReadFile("${escapeZigString(route.key)}", ${route.okTag}, ${route.errTag}, ${path})`;
      }
      if (method === "writeFile") {
        const path = this.effectBytesArg(e, e.arguments[0], "Cmd.writeFile path", MAX_FILE_PATH_BYTES, ctx);
        const bytes = this.effectBytesArg(e, e.arguments[1], "Cmd.writeFile bytes", MAX_FILE_BYTES, ctx);
        const route = this.requestRoute(e, e.arguments[2], ctx, "void");
        return `rt.cmdWriteFile("${escapeZigString(route.key)}", ${route.okTag}, ${route.errTag}, ${path}, ${bytes})`;
      }
      if (method === "fetch") {
        const spec = this.fetchSpec(e, e.arguments[0], ctx);
        const route = this.requestRoute(e, e.arguments[1], ctx, "fetched");
        return (
          `rt.cmdFetch("${escapeZigString(route.key)}", ${route.okTag}, ${route.errTag}, ` +
          `.${spec.method}, ${spec.timeoutMs}, ${spec.url}, ${spec.headers}, ${spec.body})`
        );
      }
      if (method === "clipboardWrite") {
        const bytes = this.effectBytesArg(e, e.arguments[0], "Cmd.clipboardWrite bytes", null, ctx);
        return `rt.cmdClipWrite(${bytes})`;
      }
      if (method === "clipboardRead") {
        const route = this.requestRoute(e, e.arguments[0], ctx, "bytes");
        return `rt.cmdClipRead("${escapeZigString(route.key)}", ${route.okTag}, ${route.errTag})`;
      }
      if (method === "delay") {
        const keyArg = e.arguments[0];
        if (!keyArg || !ts.isStringLiteral(keyArg)) {
          this.fail(e, `\`Cmd.delay\` takes its key as a string literal`, "NS1027");
        }
        if (keyArg.text.length > 255) this.fail(keyArg, "Cmd.delay key over 255 bytes");
        const msArg = e.arguments[1];
        if (!msArg) this.fail(e, "Cmd.delay interval (milliseconds)");
        // The engine bound is 1ms..one year; a compile-time-known interval
        // outside it should stop the build instead of shipping a certain
        // runtime rejection (dynamic intervals are validated by the host).
        const literalMs = this.numberLiteralValue(msArg);
        if (literalMs !== null && !(literalMs >= 1 && literalMs <= 31_536_000_000)) {
          this.fail(msArg, `\`Cmd.delay\` interval ${literalMs} is outside the engine's 1ms..one-year bound`, "NS1030");
        }
        const ms = this.emitExpr(msArg, ctx, { k: "f64" }).code;
        const kindArg = e.arguments[2];
        if (!kindArg || !ts.isStringLiteral(kindArg)) {
          this.fail(e, `\`Cmd.delay\` takes its target Msg kind as a string literal`, "NS1027");
        }
        const tag = this.numberArmTag(kindArg, ctx.cmdReturn!.msgUnion, "Cmd.delay");
        return `rt.cmdDelay("${escapeZigString(keyArg.text)}", ${ms}, ${tag})`;
      }
      if (method === "spawn") {
        return this.emitSpawnCmd(e, ctx);
      }
      if (method === "audioPlay") {
        return this.emitAudioPlayCmd(e, ctx);
      }
      if (method in AUDIO_VERBS) {
        return this.emitAudioCtlCmd(e, method, ctx);
      }
      if (method === "batch") {
        const arr = e.arguments[0];
        if (!arr || !ts.isArrayLiteralExpression(arr)) this.fail(e, "Cmd.batch argument (an array literal in v1)");
        const parts = arr.elements.map((el) => this.emitCmdExpr(el, ctx));
        if (parts.length === 0) return "rt.cmd_none";
        return `rt.cmdBatch(&.{ ${parts.join(", ")} })`;
      }
      this.fail(
        e,
        `Cmd.${method} (the v2 command set is none, persist, now, host, request, cancel, readFile, writeFile, fetch, clipboardWrite, clipboardRead, delay, spawn, audioPlay, audioPause, audioResume, audioStop, audioSeek, audioSetVolume, batch)`,
      );
    }
    this.fail(expr, "command expression (Cmd values are built inline from the Cmd.* factories)");
  }

  /// The routing spec of a routed effect op: an inline `{ key?, ok, err }`
  /// object with string-literal values. `err` must name a Msg arm whose
  /// payload is exactly one bytes field; the ok arm's required shape is the
  /// op's result shape — one bytes field ("bytes": request/readFile/
  /// clipboardRead), no fields ("void": writeFile), or one number field plus
  /// one bytes field ("fetched": fetch's status/body record). The host
  /// builds the result Msg from that declared shape (NS1027 teaches every
  /// other spelling, callbacks included).
  private requestRoute(
    call: ts.CallExpression,
    arg: ts.Expression | undefined,
    ctx: Ctx,
    okShape: "bytes" | "void" | "fetched" = "bytes",
  ): { key: string; okTag: string; errTag: string } {
    let e = arg;
    while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e))) e = e.expression;
    if (!e || !ts.isObjectLiteralExpression(e)) {
      this.fail(arg ?? call, `\`Cmd.request\` routing is an inline \`{ key?, ok, err }\` object`, "NS1027");
    }
    let key = "";
    let ok: ts.StringLiteral | null = null;
    let err: ts.StringLiteral | null = null;
    for (const p of e.properties) {
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) {
        this.fail(p, `\`Cmd.request\` routing member \`${p.getText()}\` is not a plain property`, "NS1027");
      }
      let v: ts.Expression = p.initializer;
      while (ts.isParenthesizedExpression(v) || ts.isAsExpression(v) || ts.isSatisfiesExpression(v)) v = v.expression;
      if (!ts.isStringLiteral(v)) {
        this.fail(
          p.initializer,
          `\`Cmd.request\` routing value \`${p.initializer.getText()}\` is not a string literal`,
          "NS1027",
        );
      }
      if (p.name.text === "key") {
        if (v.text.length > 255) this.fail(v, "Cmd.request key over 255 bytes");
        key = v.text;
      } else if (p.name.text === "ok") ok = v;
      else if (p.name.text === "err") err = v;
      else this.fail(p, `\`Cmd.request\` routing member \`${p.name.text}\``, "NS1027");
    }
    if (!ok || !err) this.fail(e, `\`Cmd.request\` routing without both \`ok\` and \`err\` arms`, "NS1027");
    return {
      key,
      okTag: this.routedArmTag(ok, ctx, okShape),
      errTag: this.routedArmTag(err, ctx, "bytes"),
    };
  }

  /// Resolve a routing arm name to its Msg tag value, requiring the arm to
  /// carry exactly the payload shape the effect produces: one bytes field
  /// ("bytes"), no fields ("void"), or one number field plus one bytes field
  /// ("fetched" — fetch's status/body — and "collected" — a collect spawn's
  /// code/output — both matched by type, names are the author's).
  private routedArmTag(arg: ts.StringLiteral, ctx: Ctx, shape: "bytes" | "void" | "fetched" | "collected"): string {
    const unionName = ctx.cmdReturn!.msgUnion;
    const info = this.table.unions.get(unionName);
    if (!info) this.fail(arg, `unknown union ${unionName}`);
    const arm = info.arms.find((a) => a.tag === arg.text);
    if (!arm) {
      this.fail(arg, `routing target \`${arg.text}\` is not an arm of ${unionName}`, "NS1027");
    }
    const isNumber = (k: string): boolean => k === "number" || k === "i64" || k === "f64";
    const matches =
      shape === "bytes"
        ? arm.fields.length === 1 && arm.fields[0].type.k === "bytes"
        : shape === "void"
          ? arm.fields.length === 0
          : arm.fields.length === 2 &&
            arm.fields.some((f) => f.type.k === "bytes") &&
            arm.fields.some((f) => isNumber(f.type.k));
    if (!matches) {
      const wanted =
        shape === "bytes"
          ? "exactly one `Uint8Array` payload field"
          : shape === "void"
            ? "no payload fields (a successful write has nothing to report)"
            : shape === "fetched"
              ? "exactly two payload fields — one number (the HTTP status) and one `Uint8Array` (the body)"
              : "exactly two payload fields — one number (the exit code) and one `Uint8Array` (the collected stdout)";
      this.fail(arg, `routing target \`${arg.text}\` does not carry ${wanted}`, "NS1027");
    }
    return `@intFromEnum(std.meta.Tag(${unionName}).${zigId(arg.text)})`;
  }

  /// `Cmd.spawn(argv, route)`: an inline argv array of bytes elements and a
  /// `{ key?, stdin?, collect?, line?, exit, err }` routing object. Line mode
  /// routes each stdout line to the optional bytes `line` arm and the exit
  /// code to a single-number `exit` arm; `collect: true` buffers stdout and
  /// routes the exit as a code/output record instead (no line arm).
  private emitSpawnCmd(e: ts.CallExpression, ctx: Ctx): string {
    let argvArg = e.arguments[0];
    while (argvArg && (ts.isParenthesizedExpression(argvArg) || ts.isAsExpression(argvArg) || ts.isSatisfiesExpression(argvArg))) {
      argvArg = argvArg.expression;
    }
    if (!argvArg || !ts.isArrayLiteralExpression(argvArg) || argvArg.elements.some((el) => ts.isSpreadElement(el))) {
      this.fail(
        e.arguments[0] ?? e,
        `\`Cmd.spawn\` argv is an inline array literal of bytes elements ([asciiBytes("/bin/ps"), ...])`,
        "NS1029",
      );
    }
    if (argvArg.elements.length === 0) {
      this.fail(argvArg, `\`Cmd.spawn\` argv is empty; the engine needs at least the program name`, "NS1030");
    }
    if (argvArg.elements.length > MAX_SPAWN_ARGV) {
      this.fail(
        argvArg,
        `\`Cmd.spawn\` argv carries ${argvArg.elements.length} elements; the engine bound is ${MAX_SPAWN_ARGV}`,
        "NS1030",
      );
    }
    const args = argvArg.elements.map((el) => this.effectBytesArg(e, el, "Cmd.spawn argv element", null, ctx));
    // The 2 KiB bound is on the WHOLE argv block; stop the build only when
    // every element's byte length is knowable (dynamic elements stay the
    // engine's to validate through the err arm).
    const literalLens = argvArg.elements.map((el) => this.literalBytesLength(el));
    if (literalLens.every((len) => len !== null)) {
      const total = literalLens.reduce((n: number, len) => n + (len ?? 0), 0);
      if (total > MAX_SPAWN_ARGV_BYTES) {
        this.fail(argvArg, `\`Cmd.spawn\` argv is ${total} bytes; the engine bound is ${MAX_SPAWN_ARGV_BYTES}`, "NS1030");
      }
    }

    let route = e.arguments[1];
    while (route && (ts.isParenthesizedExpression(route) || ts.isAsExpression(route) || ts.isSatisfiesExpression(route))) route = route.expression;
    if (!route || !ts.isObjectLiteralExpression(route)) {
      this.fail(
        e.arguments[1] ?? e,
        `\`Cmd.spawn\` routing is an inline \`{ key?, stdin?, collect?, line?, exit, err }\` object`,
        "NS1027",
      );
    }
    let key = "";
    let stdin = '""';
    let collect = false;
    let line: ts.StringLiteral | null = null;
    let exit: ts.StringLiteral | null = null;
    let err: ts.StringLiteral | null = null;
    for (const p of route.properties) {
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) {
        this.fail(p, `\`Cmd.spawn\` routing member \`${p.getText()}\` is not a plain property`, "NS1027");
      }
      const name = p.name.text;
      let v: ts.Expression = p.initializer;
      while (ts.isParenthesizedExpression(v) || ts.isAsExpression(v) || ts.isSatisfiesExpression(v)) v = v.expression;
      if (name === "stdin") {
        stdin = this.effectBytesArg(e, p.initializer, "Cmd.spawn stdin", MAX_SPAWN_STDIN_BYTES, ctx);
        continue;
      }
      if (name === "collect") {
        // The output mode encodes into the wire record at build time, so it
        // is the literal `true` (a lines spawn simply omits it).
        if (v.kind !== ts.SyntaxKind.TrueKeyword) {
          this.fail(p.initializer, `\`Cmd.spawn\` collect must be the literal \`true\``, "NS1029");
        }
        collect = true;
        continue;
      }
      if (!ts.isStringLiteral(v)) {
        this.fail(
          p.initializer,
          `\`Cmd.spawn\` routing value \`${p.initializer.getText()}\` is not a string literal`,
          "NS1027",
        );
      }
      if (name === "key") {
        if (v.text.length > 255) this.fail(v, "Cmd.spawn key over 255 bytes");
        key = v.text;
      } else if (name === "line") line = v;
      else if (name === "exit") exit = v;
      else if (name === "err") err = v;
      else this.fail(p, `\`Cmd.spawn\` routing member \`${name}\``, "NS1027");
    }
    if (!exit || !err) this.fail(route, `\`Cmd.spawn\` routing without both \`exit\` and \`err\` arms`, "NS1027");
    if (collect && line !== null) {
      this.fail(
        line,
        `\`Cmd.spawn\` collect mode has no line framing (whole stdout arrives on the exit arm) — drop the \`line\` arm or drop \`collect\``,
        "NS1027",
      );
    }
    const lineTag = line !== null ? this.routedArmTag(line, ctx, "bytes") : "rt.spawn_no_line_tag";
    const exitTag = collect
      ? this.routedArmTag(exit, ctx, "collected")
      : this.numberArmTag(exit, ctx.cmdReturn!.msgUnion, "Cmd.spawn exit");
    const errTag = this.routedArmTag(err, ctx, "bytes");
    const mode = collect ? ".collect" : ".lines";
    return (
      `rt.cmdSpawn("${escapeZigString(key)}", ${lineTag}, ${exitTag}, ${errTag}, ` +
      `${mode}, &.{ ${args.join(", ")} }, ${stdin})`
    );
  }

  /// `Cmd.audioPlay(key, source, route)`: a string-literal key, an inline
  /// `{ path?, url?, cachePath?, expectedBytes? }` source (at least one of
  /// path/url), and `{ event }` routing onto the six-field audio event arm.
  private emitAudioPlayCmd(e: ts.CallExpression, ctx: Ctx): string {
    const keyArg = e.arguments[0];
    if (!keyArg || !ts.isStringLiteral(keyArg)) {
      this.fail(e, `\`Cmd.audioPlay\` takes its key as a string literal`, "NS1027");
    }
    if (keyArg.text.length > 255) this.fail(keyArg, "Cmd.audioPlay key over 255 bytes");

    let source = e.arguments[1];
    while (source && (ts.isParenthesizedExpression(source) || ts.isAsExpression(source) || ts.isSatisfiesExpression(source))) source = source.expression;
    if (!source || !ts.isObjectLiteralExpression(source)) {
      this.fail(
        e.arguments[1] ?? e,
        `\`Cmd.audioPlay\` takes an inline \`{ path?, url?, cachePath?, expectedBytes? }\` source object`,
        "NS1029",
      );
    }
    let audio_path = '""';
    let url = '""';
    let cache_path = '""';
    let expected = "0";
    let has_source = false;
    for (const p of source.properties) {
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) {
        this.fail(p, `\`Cmd.audioPlay\` source member \`${p.getText()}\` is not a plain property`, "NS1029");
      }
      const name = p.name.text;
      if (name === "path") {
        audio_path = this.effectBytesArg(e, p.initializer, "Cmd.audioPlay path", MAX_AUDIO_PATH_BYTES, ctx);
        has_source = true;
      } else if (name === "url") {
        url = this.effectBytesArg(e, p.initializer, "Cmd.audioPlay url", MAX_AUDIO_PATH_BYTES, ctx);
        has_source = true;
      } else if (name === "cachePath") {
        cache_path = this.effectBytesArg(e, p.initializer, "Cmd.audioPlay cachePath", MAX_AUDIO_PATH_BYTES, ctx);
      } else if (name === "expectedBytes") {
        const literal = this.numberLiteralValue(p.initializer);
        if (literal !== null && !(literal >= 0 && Number.isFinite(literal))) {
          this.fail(p.initializer, `\`Cmd.audioPlay\` expectedBytes ${literal} is not a byte count`, "NS1030");
        }
        expected = this.emitExpr(p.initializer, ctx, { k: "f64" }).code;
      } else {
        this.fail(p, `\`Cmd.audioPlay\` source member \`${name}\``, "NS1029");
      }
    }
    if (!has_source) {
      this.fail(source, `\`Cmd.audioPlay\` source without a \`path\` or a \`url\` — nothing could play`, "NS1029");
    }

    let route = e.arguments[2];
    while (route && (ts.isParenthesizedExpression(route) || ts.isAsExpression(route) || ts.isSatisfiesExpression(route))) route = route.expression;
    if (!route || !ts.isObjectLiteralExpression(route)) {
      this.fail(e.arguments[2] ?? e, `\`Cmd.audioPlay\` routing is an inline \`{ event }\` object`, "NS1027");
    }
    let event: ts.StringLiteral | null = null;
    for (const p of route.properties) {
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) {
        this.fail(p, `\`Cmd.audioPlay\` routing member \`${p.getText()}\` is not a plain property`, "NS1027");
      }
      let v: ts.Expression = p.initializer;
      while (ts.isParenthesizedExpression(v) || ts.isAsExpression(v) || ts.isSatisfiesExpression(v)) v = v.expression;
      if (p.name.text !== "event") {
        this.fail(p, `\`Cmd.audioPlay\` routing member \`${p.name.text}\``, "NS1027");
      }
      if (!ts.isStringLiteral(v)) {
        this.fail(p.initializer, `\`Cmd.audioPlay\` event arm is not a string literal`, "NS1027");
      }
      event = v;
    }
    if (!event) this.fail(route, `\`Cmd.audioPlay\` routing without an \`event\` arm`, "NS1027");
    const tag = this.audioEventArmTag(event, ctx);
    return `rt.cmdAudioPlay("${escapeZigString(keyArg.text)}", ${tag}, ${audio_path}, ${url}, ${cache_path}, ${expected})`;
  }

  /// Resolve the audio event arm: exactly the six SDK-fixed fields, matched
  /// by NAME — state (a named literal-union alias carrying exactly the six
  /// audio states, any order), positionMs/durationMs (numbers), playing/
  /// buffering (booleans), bands (bytes).
  private audioEventArmTag(arg: ts.StringLiteral, ctx: Ctx): string {
    const unionName = ctx.cmdReturn!.msgUnion;
    const info = this.table.unions.get(unionName);
    if (!info) this.fail(arg, `unknown union ${unionName}`);
    const arm = info.arms.find((a) => a.tag === arg.text);
    if (!arm) {
      this.fail(arg, `routing target \`${arg.text}\` is not an arm of ${unionName}`, "NS1027");
    }
    const shape =
      "the six audio event fields — state (a named alias of exactly " +
      AUDIO_STATES.map((s) => `"${s}"`).join(" | ") +
      "), positionMs: number, durationMs: number, playing: boolean, buffering: boolean, bands: Uint8Array";
    const fieldsByName = new Map(arm.fields.map((f) => [f.tsName, f]));
    const isNumber = (k: string): boolean => k === "number" || k === "i64" || k === "f64";
    const state = fieldsByName.get("state");
    const position = fieldsByName.get("positionMs");
    const duration = fieldsByName.get("durationMs");
    const playing = fieldsByName.get("playing");
    const buffering = fieldsByName.get("buffering");
    const bands = fieldsByName.get("bands");
    const stateOk =
      state !== undefined &&
      state.type.k === "enum" &&
      state.type.members.length === AUDIO_STATES.length &&
      AUDIO_STATES.every((s) => state.type.k === "enum" && state.type.members.includes(s));
    const matches =
      arm.fields.length === 6 &&
      stateOk &&
      position !== undefined &&
      isNumber(position.type.k) &&
      duration !== undefined &&
      isNumber(duration.type.k) &&
      playing !== undefined &&
      playing.type.k === "bool" &&
      buffering !== undefined &&
      buffering.type.k === "bool" &&
      bands !== undefined &&
      bands.type.k === "bytes";
    if (!matches) {
      this.fail(arg, `routing target \`${arg.text}\` does not carry ${shape}`, "NS1027");
    }
    return `@intFromEnum(std.meta.Tag(${unionName}).${zigId(arg.text)})`;
  }

  /// The `Cmd.audioPause/Resume/Stop/Seek/SetVolume` control verbs: a
  /// string-literal key plus the seek position / volume value where the verb
  /// takes one.
  private emitAudioCtlCmd(e: ts.CallExpression, method: string, ctx: Ctx): string {
    const keyArg = e.arguments[0];
    if (!keyArg || !ts.isStringLiteral(keyArg)) {
      this.fail(e, `\`Cmd.${method}\` takes its key as a string literal`, "NS1027");
    }
    if (keyArg.text.length > 255) this.fail(keyArg, `Cmd.${method} key over 255 bytes`);
    let value = "0";
    if (method === "audioSeek") {
      const msArg = e.arguments[1];
      if (!msArg) this.fail(e, "Cmd.audioSeek position (milliseconds)");
      const literal = this.numberLiteralValue(msArg);
      if (literal !== null && !(literal >= 0 && Number.isFinite(literal))) {
        this.fail(msArg, `\`Cmd.audioSeek\` position ${literal} is not a millisecond offset`, "NS1030");
      }
      value = this.emitExpr(msArg, ctx, { k: "f64" }).code;
    } else if (method === "audioSetVolume") {
      const volArg = e.arguments[1];
      if (!volArg) this.fail(e, "Cmd.audioSetVolume volume (0..1)");
      const literal = this.numberLiteralValue(volArg);
      if (literal !== null && !(literal >= 0 && literal <= 1)) {
        this.fail(volArg, `\`Cmd.audioSetVolume\` volume ${literal} is outside 0..1`, "NS1030");
      }
      value = this.emitExpr(volArg, ctx, { k: "f64" }).code;
    }
    return `rt.cmdAudioCtl("${escapeZigString(keyArg.text)}", ${AUDIO_VERBS[method]}, ${value})`;
  }

  /// Resolve a `Cmd.now`/`Cmd.delay`/`Sub.timer` target arm to its tag,
  /// requiring exactly one number payload field.
  private numberArmTag(arg: ts.StringLiteral, unionName: string, factory: string): string {
    const info = this.table.unions.get(unionName);
    if (!info) this.fail(arg, `unknown union ${unionName}`);
    const arm = info.arms.find((a) => a.tag === arg.text);
    if (!arm) {
      this.fail(arg, `${factory} target \`${arg.text}\` is not an arm of ${unionName}`, "NS1027");
    }
    const numberPayload =
      arm.fields.length === 1 &&
      (arm.fields[0].type.k === "number" || arm.fields[0].type.k === "i64" || arm.fields[0].type.k === "f64");
    if (!numberPayload) {
      this.fail(
        arg,
        `${factory} target \`${arg.text}\` does not carry exactly one number payload field`,
        "NS1027",
      );
    }
    return `@intFromEnum(std.meta.Tag(${unionName}).${zigId(arg.text)})`;
  }

  /// A bytes-typed effect argument (paths, URLs, bodies, clipboard text).
  /// When the value is a compile-time `asciiBytes` literal and the engine
  /// bound is knowable, an over-bound literal stops the build (NS1030);
  /// dynamic bytes are the host's to validate through the err arm.
  private effectBytesArg(
    call: ts.CallExpression,
    arg: ts.Expression | undefined,
    what: string,
    maxBytes: number | null,
    ctx: Ctx,
  ): string {
    if (!arg) this.fail(call, `${what} (bytes — asciiBytes for literals)`, "NS1029");
    if (this.zTypeOfExpr(arg, ctx).k !== "bytes") {
      this.fail(arg, `${what} \`${arg.getText()}\` is not bytes`, "NS1029");
    }
    if (maxBytes !== null) {
      const literalLen = this.literalBytesLength(arg);
      if (literalLen !== null && literalLen > maxBytes) {
        this.fail(arg, `${what} is ${literalLen} bytes; the engine bound is ${maxBytes}`, "NS1030");
      }
    }
    return this.emitExpr(arg, ctx, { k: "bytes" }).code;
  }

  /// The byte length of a compile-time `asciiBytes("...")` literal; null
  /// for everything dynamic.
  private literalBytesLength(arg: ts.Expression): number | null {
    let e = arg;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (!ts.isCallExpression(e) || !ts.isIdentifier(e.expression)) return null;
    const decl = this.tast.declarationOf(e.expression);
    if (!decl || !this.isSdkIntrinsic(decl, "asciiBytes")) return null;
    const inner = e.arguments[0];
    return inner && ts.isStringLiteral(inner) ? inner.text.length : null;
  }

  /// The numeric value of a compile-time number literal (unary minus
  /// included); null for everything dynamic.
  private numberLiteralValue(arg: ts.Expression): number | null {
    let e = arg;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (ts.isNumericLiteral(e)) return Number(e.text);
    if (
      ts.isPrefixUnaryExpression(e) &&
      e.operator === ts.SyntaxKind.MinusToken &&
      ts.isNumericLiteral(e.operand)
    ) {
      return -Number(e.operand.text);
    }
    return null;
  }

  /// The `Cmd.fetch` spec: an inline `{ url, method?, headers?, body?,
  /// timeoutMs? }` object literal. `method`/`timeoutMs`/header NAMES must
  /// be compile-time literals (they encode into the wire record's fixed
  /// fields); `url`/`body`/header VALUES are bytes expressions (values may
  /// also be string literals). Comptime-knowable engine bounds stop the
  /// build (NS1030); the rest surfaces at runtime through the err arm.
  private fetchSpec(
    call: ts.CallExpression,
    arg: ts.Expression | undefined,
    ctx: Ctx,
  ): { url: string; method: string; timeoutMs: string; headers: string; body: string } {
    let e = arg;
    while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e))) e = e.expression;
    if (!e || !ts.isObjectLiteralExpression(e)) {
      this.fail(arg ?? call, `\`Cmd.fetch\` takes an inline \`{ url, method?, headers?, body?, timeoutMs? }\` object`, "NS1029");
    }
    let url: string | null = null;
    let method = "GET";
    let timeoutMs = "0";
    let headers = "&.{}";
    let body = '""';
    for (const p of e.properties) {
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) {
        this.fail(p, `\`Cmd.fetch\` spec member \`${p.getText()}\` is not a plain property`, "NS1029");
      }
      const name = p.name.text;
      const value = p.initializer;
      if (name === "url") {
        url = this.effectBytesArg(call, value, "Cmd.fetch url", MAX_URL_BYTES, ctx);
      } else if (name === "body") {
        body = this.effectBytesArg(call, value, "Cmd.fetch body", MAX_FETCH_PAYLOAD_BYTES, ctx);
      } else if (name === "method") {
        let v: ts.Expression = value;
        while (ts.isParenthesizedExpression(v) || ts.isAsExpression(v) || ts.isSatisfiesExpression(v)) v = v.expression;
        if (!ts.isStringLiteral(v) || !FETCH_METHODS.includes(v.text)) {
          this.fail(value, `\`Cmd.fetch\` method (one of ${FETCH_METHODS.map((m) => `"${m}"`).join(", ")})`, "NS1029");
        }
        method = v.text;
      } else if (name === "timeoutMs") {
        const literal = this.numberLiteralValue(value);
        if (literal === null || !Number.isInteger(literal) || literal < 1 || literal > 0xffff_ffff) {
          this.fail(value, `\`Cmd.fetch\` timeoutMs (a positive integer literal of milliseconds)`, "NS1029");
        }
        timeoutMs = String(literal);
      } else if (name === "headers") {
        headers = this.fetchHeaders(value, ctx);
      } else {
        this.fail(p, `\`Cmd.fetch\` spec member \`${name}\``, "NS1029");
      }
    }
    if (url === null) this.fail(e, `\`Cmd.fetch\` spec without a \`url\``, "NS1029");
    return { url, method, timeoutMs, headers, body };
  }

  /// Fetch headers: an inline flat record. Header NAMES are compile-time
  /// field names, ASCII and bounded (they gate NS1030's block math and the
  /// request-line checks at build time). Header VALUES are compile-time
  /// string literals (ASCII — the one text whose byte length equals its
  /// literal length on both runtimes) OR runtime bytes expressions
  /// (`Uint8Array`; asciiBytes for literals) — a runtime value rides the
  /// record's length-prefixed value field at dispatch time exactly like
  /// `url`/`body` bytes do (the wire layout is identical either way; the
  /// engine validates runtime values through the err arm). Encoded in
  /// TS-field-name (code-unit) sort order — the same order the SDK factory
  /// produces under node.
  private fetchHeaders(arg: ts.Expression, ctx: Ctx): string {
    let e = arg;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (!ts.isObjectLiteralExpression(e)) {
      this.fail(arg, `\`Cmd.fetch\` headers (an inline flat record of string-literal or bytes values)`, "NS1029");
    }
    const isAscii = (s: string): boolean => [...s].every((c) => c.charCodeAt(0) <= 0x7f);
    const pairs: Array<{ name: string; value: string; valueLen: number | null }> = [];
    for (const p of e.properties) {
      if (!ts.isPropertyAssignment(p) || (!ts.isIdentifier(p.name) && !ts.isStringLiteral(p.name))) {
        this.fail(p, `\`Cmd.fetch\` header \`${p.getText()}\` is not a plain field`, "NS1029");
      }
      const name = p.name.text;
      if (!isAscii(name)) {
        this.fail(p, `\`Cmd.fetch\` header \`${name}\` carries a non-ASCII name`, "NS1029");
      }
      if (name.length === 0 || name.includes(":") || /[\r\n]/.test(name)) {
        this.fail(p, `\`Cmd.fetch\` header name \`${name}\` would corrupt the request line`, "NS1029");
      }
      if (name.length > 255) this.fail(p, `\`Cmd.fetch\` header name over 255 bytes`, "NS1030");
      let v: ts.Expression = p.initializer;
      while (ts.isParenthesizedExpression(v) || ts.isAsExpression(v) || ts.isSatisfiesExpression(v)) v = v.expression;
      if (ts.isStringLiteral(v)) {
        if (!isAscii(v.text)) {
          this.fail(p, `\`Cmd.fetch\` header \`${name}\` carries non-ASCII text`, "NS1029");
        }
        if (/[\r\n]/.test(v.text)) {
          this.fail(p, `\`Cmd.fetch\` header \`${name}\` value would corrupt the request line`, "NS1029");
        }
        pairs.push({ name, value: `"${escapeZigString(v.text)}"`, valueLen: v.text.length });
      } else if (this.zTypeOfExpr(v, ctx).k === "bytes") {
        // A runtime value: the builder length-prefixes it into the record
        // at dispatch time; the engine rejects an over-bound block or a
        // CR/LF-carrying value through the err arm.
        pairs.push({ name, value: this.emitExpr(v, ctx, { k: "bytes" }).code, valueLen: this.literalBytesLength(v) });
      } else {
        this.fail(
          p.initializer,
          `\`Cmd.fetch\` header \`${name}\` value is not a string literal or bytes`,
          "NS1029",
        );
      }
    }
    if (pairs.length > MAX_FETCH_HEADERS) {
      this.fail(e, `\`Cmd.fetch\` carries ${pairs.length} headers; the engine bound is ${MAX_FETCH_HEADERS}`, "NS1030");
    }
    // The 1 KiB bound is on the WHOLE header block; runtime values
    // contribute an unknowable length, so the comptime stop fires only
    // when the KNOWN bytes alone already exceed it (a guaranteed runtime
    // rejection) — dynamic remainders stay the engine's to validate.
    const knownBytes = pairs.reduce((n, h) => n + h.name.length + (h.valueLen ?? 0), 0);
    if (knownBytes > MAX_FETCH_HEADER_BYTES) {
      this.fail(e, `\`Cmd.fetch\` header block is ${knownBytes} bytes; the engine bound is ${MAX_FETCH_HEADER_BYTES}`, "NS1030");
    }
    if (pairs.length === 0) return "&.{}";
    pairs.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    const items = pairs.map((h) => `.{ .name = "${escapeZigString(h.name)}", .value = ${h.value} }`);
    return `&.{ ${items.join(", ")} }`;
  }

  /// True when a `Cmd.host`/`Cmd.request` argument is a v2 payload: a
  /// bytes-typed value or an inline record literal.
  private isHostPayloadArg(arg: ts.Expression, ctx: Ctx): boolean {
    let e = arg;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (ts.isObjectLiteralExpression(e)) return true;
    return this.zTypeOfExpr(e, ctx).k === "bytes";
  }

  /// A host payload lowered to its wire bytes. Raw bytes pass through; an
  /// inline record lowers through the derived encoder: fields sorted by
  /// name, number -> f64 LE, boolean -> one 0/1 byte, bytes -> u32 LE
  /// length + bytes (the same encoding sdk hostRecordBytes produces under
  /// node, so the wire is byte-identical).
  private emitHostPayload(arg: ts.Expression, ctx: Ctx): string {
    let e = arg;
    while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
    if (!ts.isObjectLiteralExpression(e)) {
      return this.emitExpr(e, ctx, { k: "bytes" }).code;
    }
    interface Field {
      readonly name: string;
      readonly kind: "number" | "bool" | "bytes";
      readonly value: ts.Expression;
    }
    const fields: Field[] = [];
    for (const p of e.properties) {
      let name: string;
      let value: ts.Expression;
      if (ts.isPropertyAssignment(p) && ts.isIdentifier(p.name)) {
        name = p.name.text;
        value = p.initializer;
      } else if (ts.isShorthandPropertyAssignment(p)) {
        name = p.name.text;
        value = p.name;
      } else {
        this.fail(p, `host record member \`${p.getText()}\` is not a plain field`, "NS1026");
      }
      const t = this.zTypeOfExpr(value, ctx);
      const kind =
        t.k === "number" || t.k === "i64" || t.k === "f64" || t.k === "numAlias"
          ? "number"
          : t.k === "bool"
            ? "bool"
            : t.k === "bytes"
              ? "bytes"
              : null;
      if (kind === null) {
        this.fail(value, `host record field \`${name}\` of type ${t.k} has no wire encoding`, "NS1026");
      }
      fields.push({ name, kind, value });
    }
    // Field order is sorted by TS name (code-unit order) — the exact order
    // sdk hostRecordBytes uses under node.
    fields.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    const payload = this.freshName(ctx, "payload");
    const temps: string[] = [];
    const lenParts: string[] = [];
    let fixed = 0;
    const values = fields.map((f) => {
      if (f.kind === "number") {
        fixed += 8;
        const code = this.emitExpr(f.value, ctx, { k: "f64" }).code;
        // @bitCast below needs a typed f64 operand; integer reads already
        // widened through @as(f64, ...), everything else takes the coercion
        // here (a no-op on runtime f64 values, the typer on literals).
        return code.startsWith("@as(f64,") ? code : `@as(f64, ${code})`;
      }
      if (f.kind === "bool") {
        fixed += 1;
        return this.emitExpr(f.value, ctx, { k: "bool" }).code;
      }
      fixed += 4;
      const temp = this.freshName(ctx, `p_${zigLocalName(f.name)}`);
      temps.push(temp);
      this.push(ctx, `const ${temp}: []const u8 = ${this.emitExpr(f.value, ctx, { k: "bytes" }).code};`);
      lenParts.push(`${temp}.len`);
      return temp;
    });
    this.push(ctx, `const ${payload} = rt.frameAlloc(u8, ${[String(fixed), ...lenParts].join(" + ")});`);
    let off = "0";
    const bump = (n: string): void => {
      off = off === "0" ? n : `${off} + ${n}`;
    };
    fields.forEach((f, i) => {
      const v = values[i];
      if (f.kind === "number") {
        this.push(ctx, `std.mem.writeInt(u64, ${payload}[${off}..][0..8], @bitCast(${v}), .little);`);
        bump("8");
      } else if (f.kind === "bool") {
        this.push(ctx, `${payload}[${off}] = @intFromBool(${v});`);
        bump("1");
      } else {
        this.push(ctx, `std.mem.writeInt(u32, ${payload}[${off}..][0..4], @intCast(${v}.len), .little);`);
        bump("4");
        this.push(ctx, `@memcpy(${payload}[${off}..][0..${v}.len], ${v});`);
        bump(`${v}.len`);
      }
    });
    return payload;
  }

  /// The return value of `subscriptions(model)`: inert descriptor data
  /// lowered onto the rt subscription builders, the same way emitCmdExpr
  /// lowers commands.
  private emitSubExpr(expr: ts.Expression, ctx: Ctx): string {
    let e = expr;
    while (ts.isParenthesizedExpression(e)) e = e.expression;
    if (ts.isConditionalExpression(e)) {
      const cond = this.emitCondition(e.condition, ctx);
      return `if (${cond}) ${this.emitSubExpr(e.whenTrue, ctx)} else ${this.emitSubExpr(e.whenFalse, ctx)}`;
    }
    if (ts.isPropertyAccessExpression(e) && this.isSubNamespace(e.expression)) {
      if (e.name.text === "none") return "rt.sub_none";
      this.fail(e, `Sub.${e.name.text} in value position`);
    }
    if (
      ts.isCallExpression(e) &&
      ts.isPropertyAccessExpression(e.expression) &&
      this.isSubNamespace(e.expression.expression)
    ) {
      const method = e.expression.name.text;
      if (method === "timer") {
        const keyArg = e.arguments[0];
        if (!keyArg || !ts.isStringLiteral(keyArg)) {
          this.fail(e, `\`Sub.timer\` takes its key as a string literal`, "NS1027");
        }
        if (keyArg.text.length > 255) this.fail(keyArg, "Sub.timer key over 255 bytes");
        const everyArg = e.arguments[1];
        if (!everyArg) this.fail(e, "Sub.timer interval (milliseconds)");
        const every = this.emitExpr(everyArg, ctx, { k: "f64" }).code;
        const kindArg = e.arguments[2];
        if (!kindArg || !ts.isStringLiteral(kindArg)) {
          this.fail(e, `\`Sub.timer\` takes its target Msg kind as a string literal`, "NS1027");
        }
        const unionName = ctx.subReturn!.msgUnion;
        const info = this.table.unions.get(unionName);
        if (!info) this.fail(e, `unknown union ${unionName}`);
        const arm = info.arms.find((a) => a.tag === kindArg.text);
        if (!arm) {
          this.fail(kindArg, `timer target \`${kindArg.text}\` is not an arm of ${unionName}`, "NS1027");
        }
        const numberPayload =
          arm.fields.length === 1 &&
          (arm.fields[0].type.k === "number" ||
            arm.fields[0].type.k === "i64" ||
            arm.fields[0].type.k === "f64");
        if (!numberPayload) {
          this.fail(
            kindArg,
            `timer target \`${kindArg.text}\` does not carry exactly one number payload field`,
            "NS1027",
          );
        }
        return `rt.subTimer("${escapeZigString(keyArg.text)}", ${every}, @intFromEnum(std.meta.Tag(${unionName}).${zigId(kindArg.text)}))`;
      }
      if (method === "batch") {
        const arr = e.arguments[0];
        if (!arr || !ts.isArrayLiteralExpression(arr)) this.fail(e, "Sub.batch argument (an array literal)");
        const parts = arr.elements.map((el) => this.emitSubExpr(el, ctx));
        if (parts.length === 0) return "rt.sub_none";
        return `rt.subBatch(&.{ ${parts.join(", ")} })`;
      }
      this.fail(e, `Sub.${method} (the subscription set is none, timer, batch)`);
    }
    this.fail(expr, "subscription expression (Sub values are built inline from the Sub.* factories)");
  }

  private returnTypeRef(t: ZType, decl: ts.Node): string {
    if (t.k === "number" || (t.k === "optional" && t.inner.k === "number")) {
      const cls = this.infer.classOfDecl(decl) ?? "f64";
      return t.k === "optional" ? `?${cls}` : cls;
    }
    return this.table.zigTypeRef(t);
  }

  /// Per-declaration ids for narrowing keys (see narrowKey). A WeakMap
  /// identity id rather than the declaration's source position: positions
  /// can collide across files, and imported consts narrow too.
  private readonly narrowKeyIds = new WeakMap<ts.Declaration, number>();
  private narrowKeyNextId = 1;

  /// Explicit node-scoped keys: a lowering that re-emits one specific
  /// expression NODE under a capture (the optional-call receiver) can
  /// register a key for it even when the expression has no canonical
  /// narrowing key. The key is unique to the node, so it can never match
  /// a different occurrence — it carries a single node's rewrite, not a
  /// narrowing fact.
  private readonly nodeNarrowKeys = new WeakMap<ts.Node, string>();

  /// The key an expression narrows/substitutes under: normalized source
  /// text with the base identifier DECLARATION-qualified (`q#3`, member
  /// chains `q#3.v`). Emission FLATTENS plain lexical blocks and callback
  /// bodies share the enclosing maps, so raw text would let two
  /// same-named declarations collide — a block-local `const q` shadow
  /// leaves its entries live for the OUTER q after the block, and an
  /// outer capture rewrites a callback parameter's reads. Symbol identity
  /// makes the collision impossible; the maps' values and mechanics are
  /// unchanged. Wrapper spellings collide by design: parentheses,
  /// non-null assertions, `as`, and `satisfies` all erase at emission
  /// (`(q)`, `q!`, and `q as Quote` are the tested `q`), so every
  /// consumer comparing or looking up keys sees through them — an arm
  /// spelled `q!` matches its guard's `q`, and a narrow installed for `q`
  /// rewrites the `q!` read. A base the checker cannot resolve keys by
  /// plain text — same behavior as before, and such bases are never
  /// locals.
  ///
  /// Element accesses qualify recursively, like property chains — the
  /// grammar is `base[index]` where the base is this same key and the
  /// index is a canonical argument form: a literal index canonicalizes by
  /// VALUE (`xs#3[0]`, so `xs[0]`, `xs[0x0]`, and `xs["0"]` are one key,
  /// exactly the one element JS reads), and an identifier index qualifies
  /// by the index's own declaration (`xs#3[i#7]` — a shadowed `i` is a
  /// different element). Anything non-canonical — a computed index, a
  /// call — has NO narrowing key: two spellings of `xs[f()]` need not
  /// read the same element, so nothing may narrow, substitute, or match
  /// through one. Returning null here is the decline answer every
  /// consumer honors: no substitution installs, capture gates see no
  /// read, and the expression's reads stay live optionals. Raw source
  /// text is never a key — emission flattens lexical blocks, so text
  /// would let a shadowed declaration's narrow leak onto the outer name.
  private narrowKey(expr: ts.Node): string | null {
    const override = this.nodeNarrowKeys.get(expr);
    if (override !== undefined) return override;
    let e: ts.Node = expr;
    while (
      ts.isParenthesizedExpression(e) ||
      ts.isNonNullExpression(e) ||
      ts.isAsExpression(e) ||
      ts.isSatisfiesExpression(e)
    ) {
      e = e.expression;
    }
    if (ts.isPropertyAccessExpression(e)) {
      const base = this.narrowKey(e.expression);
      return base === null ? null : `${base}${e.questionDotToken ? "?." : "."}${e.name.text}`;
    }
    if (ts.isElementAccessExpression(e)) {
      const base = this.narrowKey(e.expression);
      if (base === null) return null;
      const index = this.canonicalIndexKey(e.argumentExpression);
      if (index === null) return null;
      return `${base}${e.questionDotToken ? "?." : ""}[${index}]`;
    }
    if (ts.isIdentifier(e)) {
      const decl = this.tast.declarationOf(e);
      if (decl) {
        let id = this.narrowKeyIds.get(decl);
        if (id === undefined) {
          id = this.narrowKeyNextId++;
          this.narrowKeyIds.set(decl, id);
        }
        return `${e.text}#${id}`;
      }
      return e.text;
    }
    // `this` is one object per member body (arrows keep it), never
    // shadowable — the keyword is its own key.
    if (e.kind === ts.SyntaxKind.ThisKeyword) return "this";
    return null;
  }

  /// The canonical form of an element-access index, or null when the
  /// index is not a stable reference to one element (see narrowKey).
  /// Literals canonicalize by the VALUE JS coerces to a property key —
  /// a numeric string index is the numeric index (`xs["0"]` is `xs[0]`).
  private canonicalIndexKey(arg: ts.Expression): string | null {
    let a: ts.Expression = arg;
    while (
      ts.isParenthesizedExpression(a) ||
      ts.isNonNullExpression(a) ||
      ts.isAsExpression(a) ||
      ts.isSatisfiesExpression(a)
    ) {
      a = a.expression;
    }
    if (ts.isNumericLiteral(a)) return String(Number(a.text));
    if (ts.isStringLiteral(a) || ts.isNoSubstitutionTemplateLiteral(a)) {
      const n = Number(a.text);
      return String(n) === a.text ? String(n) : JSON.stringify(a.text);
    }
    if (ts.isIdentifier(a)) return this.narrowKey(a);
    return null;
  }

  private identifierUsed(body: ts.Node, decl: ts.Node): boolean {
    let used = false;
    const visit = (n: ts.Node): void => {
      if (used) return;
      if (ts.isIdentifier(n) && this.tast.declarationOf(n) === decl && n.parent !== decl) used = true;
      ts.forEachChild(n, visit);
    };
    visit(body);
    return used;
  }

  // ------------------------------------------------------------- statements

  private push(ctx: Ctx, line: string): void {
    ctx.lines.push(line.length ? "    ".repeat(ctx.indent) + line : "");
  }

  /// The one exit statement spelling: a function-level `return v;`, or —
  /// inside a lifted block-body callback — the labeled `break` that yields
  /// the callback's value out of its value block.
  private returnText(ctx: Ctx, v: string | null, node: ts.Node): string {
    if (ctx.retLabel) {
      if (v === null) {
        this.fail(
          node,
          "a callback `return` without a value (JS would produce `undefined` there; return an explicit value)",
        );
      }
      return `break :${ctx.retLabel} ${v};`;
    }
    if (v === null && ctx.ctorSelf) {
      // JS constructors return the instance on every path.
      return `return ${ctx.ctorSelf};`;
    }
    return v === null ? `return;` : `return ${v};`;
  }

  /// Name uniquing: a colliding name takes an `_N` suffix (`i` -> `i_2`),
  /// never a bare digit — `i2`/`u8` would land in Zig's primitive-type
  /// namespace and need the reserved-word underscore, which made nested
  /// callback captures unreadable (`i2_`, `i22_`). Source names keep their
  /// spelling whenever free; generated names yield (callback parameters are
  /// claimed before their loop captures are drawn).
  private uniqueName(ctx: Ctx, preferred: string): string {
    let name = zigSafeName(preferred);
    let i = 2;
    while (ctx.used.has(name)) name = zigSafeName(`${preferred}_${i++}`);
    ctx.used.add(name);
    return name;
  }

  private claim(ctx: Ctx, decl: ts.Node, preferred: string): string {
    const name = this.uniqueName(ctx, preferred);
    ctx.names.set(decl, name);
    return name;
  }

  private freshName(ctx: Ctx, hint: string): string {
    return this.uniqueName(ctx, hint);
  }

  /// Open an invalidation frame: every scope that snapshots/restores the
  /// narrowing maps brackets its emission with this pair, so assignment
  /// kills recorded during the scope survive the restore (see Ctx.narrowKilled).
  private pushNarrowKillFrame(ctx: Ctx): void {
    ctx.narrowKilled.push(new Set());
  }

  /// Close the innermost invalidation frame: re-apply its recorded kills to
  /// the just-restored narrowing maps and merge them one frame outward (an
  /// inner branch's kill must reach every enclosing exit it can fall
  /// through to). A kill on ANY fall-through path inside the scope deletes
  /// the narrow at the merge point, so a path that kept the value non-null
  /// pays a re-check — never wrong code. Only memberSubst is touched,
  /// mirroring the assignment-invalidation path (a stillOptionalSubst entry
  /// is inert once its memberSubst entry is gone, and narrowedUnion is not
  /// what `.?` substitutions live in).
  ///
  /// `drop` discards the frame's kills instead: the caller has proven the
  /// scope always leaves the emitted function, so no path carrying those
  /// kills reaches the merge point — merging them would delete narrowings
  /// tsc keeps on the surviving flow, and a read there relies on the
  /// substitution's unwrap spelling (losing it emits a field access on an
  /// optional, not a re-check).
  ///
  /// A destination array routes the kills along the scope's non-local
  /// edges instead: the scope's only in-function routes are caught throws
  /// and/or escaping break/continue/lowered-return edges, so no path
  /// carrying the kills reaches THIS merge point either — but each edge
  /// resumes somewhere in the function, and the kills must be live there.
  /// Kills travel the same edges control does: they wait in the
  /// destination sets (the enclosing try's pendingCatchKills, the target
  /// constructs' edgeKills stages) and the owning emitters apply them
  /// where the edges land — never mid-flight, where tsc keeps the
  /// surviving paths' narrows.
  private popNarrowKillFrame(ctx: Ctx, routing: KillRouting = "merge"): Set<string> {
    const killed = ctx.narrowKilled.pop() ?? new Set<string>();
    if (routing === "drop") return killed;
    if (routing !== "merge") {
      for (const dest of routing) for (const key of killed) dest.add(key);
      return killed;
    }
    for (const key of killed) ctx.memberSubst.delete(key);
    const parent = ctx.narrowKilled[ctx.narrowKilled.length - 1];
    if (parent) for (const key of killed) parent.add(key);
    return killed;
  }

  /// Bracket `emit` in one narrowing flow scope: on exit, restore the three
  /// narrowing maps to their entry snapshot (containment), then re-apply and
  /// merge — or drop, or route to the enclosing try's pending set — the
  /// kills recorded inside (see popNarrowKillFrame).
  ///
  /// `joinInto` defers merge-class kills for a JOIN instead of applying
  /// them here: a multi-alternative construct (if/else arms, an else-if
  /// chain, switch clauses) must emit every alternative from the shared
  /// ENTRY state — tsc types the arms as alternatives, not a sequence, so
  /// one arm's kill applied mid-construct would strip a sibling of a
  /// narrowing tsc keeps there. The caller collects each arm's kills and
  /// applies the union once via applyJoinedNarrowKills, after the last
  /// alternative. Only merge-class kills defer: an always-leaving arm
  /// still drops its kills, and an arm whose only in-function routes are
  /// non-local edges still routes them to those edges' destination sets —
  /// those edges never reach a sibling.
  private withNarrowScope<T>(
    ctx: Ctx,
    mode: KillRouting,
    emit: () => T,
    joinInto?: Set<string>,
  ): T {
    const savedSubst = new Map(ctx.memberSubst);
    const savedStillOptional = new Map(ctx.stillOptionalSubst);
    const savedNarrowed = new Map(ctx.narrowedUnion);
    this.pushNarrowKillFrame(ctx);
    try {
      return emit();
    } finally {
      ctx.memberSubst.clear();
      for (const [k, v] of savedSubst) ctx.memberSubst.set(k, v);
      ctx.stillOptionalSubst.clear();
      for (const [k, v] of savedStillOptional) ctx.stillOptionalSubst.set(k, v);
      ctx.narrowedUnion.clear();
      for (const [k, v] of savedNarrowed) ctx.narrowedUnion.set(k, v);
      if (mode === "merge" && joinInto) {
        for (const key of this.popNarrowKillFrame(ctx, "drop")) joinInto.add(key);
      } else {
        this.popNarrowKillFrame(ctx, mode);
      }
    }
  }

  /// The JOIN of a multi-alternative construct: apply the union of the
  /// alternatives' merge-class kills to the surviving flow, once, after
  /// every alternative has emitted from the shared entry state (see
  /// withNarrowScope's `joinInto`). Same application as a plain merge —
  /// delete the narrow, propagate the kill one frame outward so enclosing
  /// exits keep it dead past their restores.
  private applyJoinedNarrowKills(ctx: Ctx, join: ReadonlySet<string>): void {
    for (const key of join) {
      ctx.memberSubst.delete(key);
      ctx.narrowKilled[ctx.narrowKilled.length - 1]?.add(key);
    }
  }

  /// Bracket a construct's emission with an edge-kill stage (Ctx.edgeKills):
  /// scopes inside that exit only along edges bound to this construct stage
  /// their kills here, and the returned set is what the caller applies at
  /// the point those edges land — applyJoinedNarrowKills after the closing
  /// brace for loops, labeled blocks, and callback value blocks; folded
  /// through the clause join for switches (the two mechanisms share one
  /// application point, so a kill is neither applied twice mid-construct
  /// nor dropped between them). The application records into the
  /// then-innermost kill frame, so a staged kill keeps propagating outward
  /// — through enclosing joins and post-narrow subtractions — exactly like
  /// a merge-class kill applied at the same spot.
  private stagedEdgeKills(
    ctx: Ctx,
    kind: EdgeKillStage["kind"],
    label: string | null,
    emit: () => void,
  ): Set<string> {
    const stage: EdgeKillStage = { kind, label, kills: new Set() };
    ctx.edgeKills.push(stage);
    try {
      emit();
    } finally {
      ctx.edgeKills.pop();
    }
    return stage.kills;
  }

  private emitBlockStatements(
    stmts: readonly ts.Statement[],
    ctx: Ctx,
    joinInto?: Set<string>,
    entryKills?: ReadonlySet<string>,
    trailing?: () => void,
  ): void {
    // Narrowing is flow-scoped the way tsc scopes it: an early-exit guard
    // narrows the statements after it in ITS list, and whatever those
    // statements nest — never code beyond the list. The narrowing maps ride
    // the shared ctx, so the scope's entry/exit snapshot is what bounds
    // them: a `break`/`continue`/`return` guard inside a loop body or a
    // branch cannot leak its captures into code after the construct (where
    // the capture is out of scope in Zig and the narrowing wrong in TS).
    //
    // Invalidation survives the restore — an assignment inside the block
    // that killed a narrowing (assigned a possibly-null value) must stay
    // dead past the merge — UNLESS every route out of the list leaves the
    // emitted function (allRoutesLeaveFunction): then no path carrying the
    // kills reaches the merge, tsc keeps the narrow on the surviving flow,
    // and reads there depend on it.
    const env = {
      returnLeaves: ctx.retLabel === null,
      throwResumes: ctx.catchResumes === true,
    };
    const leavesFn = this.allRoutesLeaveFunction(stmts, env);
    // Edge-kills channel: when the list's only in-function routes are
    // non-local edges — throws the enclosing catch hands back, escaping
    // break/continue edges, lowered callback returns — no path carrying
    // the kills falls through into the statements after this list, so
    // merging them here would poison flow tsc keeps narrowed (the killing
    // paths cannot reach it). Kills travel the same edges control does:
    // each class stages at its destination — the try's pending set for
    // caught throws, the target construct's stage for break/continue, the
    // callback stage for lowered returns — and the owning emitter applies
    // it where the edge lands. Re-asking the route question with every
    // edge class treated as leaving isolates exactly this case: any true
    // fall-through still forces the plain merge (which is a conservative
    // superset — its kills persist into all downstream states, the edge
    // destinations included).
    // `entryKills` are kills that arrived WITH control (a catch entered on
    // throw edges that carried them): they widen the list's entry state —
    // its reads see them — and then ride this frame's routing out, exactly
    // like a kill the first statement made. Routing is what makes them
    // land where flow says: a fall-through carries them to the code after
    // the construct, an escaping break/continue stages them at that edge's
    // destination, and a list whose every route leaves the function drops
    // them (no surviving path carries them anywhere).
    // `trailing` is emission that tsc types under the list's END state — a
    // do-while's trailing exit test evaluates after the body, so a terminal
    // guard in the body narrows it. It runs inside this same scope: a scope
    // closed between the list and the test would restore the maps before
    // the read they guard (the callback trailing-return fix, applied to the
    // loop lowering).
    this.withNarrowScope(
      ctx,
      leavesFn ? "drop" : this.edgeKillRouting(stmts, env, ctx),
      () => {
        if (entryKills) {
          for (const key of entryKills) {
            ctx.memberSubst.delete(key);
            ctx.narrowKilled[ctx.narrowKilled.length - 1]?.add(key);
          }
        }
        this.emitStatementList(stmts, ctx);
        trailing?.();
      },
      joinInto,
    );
  }

  /// The routing for a list that does NOT always leave the function: the
  /// non-local-edges-only route form when it applies, else "merge". A
  /// destination that fails to resolve (a caught throw without a pending
  /// set, an edge whose target construct has no stage) falls back to the
  /// plain merge — over-merging costs a re-check, never wrong code.
  private edgeKillRouting(
    stmts: readonly ts.Statement[],
    env: { returnLeaves: boolean; throwResumes: boolean },
    ctx: Ctx,
  ): KillRouting {
    if (!this.allRoutesLeaveFunction(stmts, { ...env, edgesLeave: true, throwResumes: false })) {
      return "merge";
    }
    const targets: Set<string>[] = [];
    if (env.throwResumes && !this.allRoutesLeaveFunction(stmts, { ...env, edgesLeave: true })) {
      // With edges leaving but caught throws resuming, any remaining
      // resuming route is a caught throw: this list exits along the
      // throw edge into the enclosing catch.
      if (ctx.pendingCatchKills == null) return "merge";
      targets.push(ctx.pendingCatchKills);
    }
    const edges = this.escapingEdgesOf(stmts, env.returnLeaves);
    const innermost = (pred: (s: EdgeKillStage) => boolean): EdgeKillStage | null => {
      for (let i = ctx.edgeKills.length - 1; i >= 0; i--) {
        if (pred(ctx.edgeKills[i])) return ctx.edgeKills[i];
      }
      return null;
    };
    for (const label of edges.breaks) {
      const stage = innermost((s) =>
        label === null ? s.kind === "loop" || s.kind === "switch" : s.label === label,
      );
      if (stage === null) return "merge";
      targets.push(stage.kills);
    }
    for (const label of edges.continues) {
      const stage = innermost((s) => s.kind === "loop" && (label === null || s.label === label));
      if (stage === null) return "merge";
      targets.push(stage.kills);
    }
    if (edges.callbackReturn) {
      const stage = innermost((s) => s.kind === "callback");
      if (stage === null) return "merge";
      targets.push(stage.kills);
    }
    // No resolvable destination at all would leave resuming routes with
    // nowhere to carry the kills — that only happens when the two route
    // analyses disagree, so keep the conservative merge.
    return targets.length > 0 ? targets : "merge";
  }

  /// The escaping non-local edges out of a statement list: the labels (null
  /// = unlabeled) of break/continue statements whose target sits at or
  /// outside the list, and whether any lowered `return` exits it (lifted
  /// callbacks: returnLeaves is false). Binding mirrors
  /// allRoutesLeaveFunction's target tracking — a loop binds unlabeled
  /// break and continue for its subtree, a switch binds unlabeled break, a
  /// labeled statement binds its label — and callback bodies are theirs
  /// alone (tsc rejects a break/continue crossing a function boundary;
  /// their returns are analyzed at their own emission).
  private escapingEdgesOf(
    stmts: readonly ts.Statement[],
    returnLeaves: boolean,
  ): { breaks: Set<string | null>; continues: Set<string | null>; callbackReturn: boolean } {
    const breaks = new Set<string | null>();
    const continues = new Set<string | null>();
    let callbackReturn = false;
    interface Bound {
      readonly labels: ReadonlySet<string>;
      readonly breakBound: boolean;
      readonly continueBound: boolean;
    }
    const visit = (n: ts.Node, st: Bound): void => {
      if (ts.isBreakStatement(n)) {
        if (n.label ? !st.labels.has(n.label.text) : !st.breakBound) breaks.add(n.label?.text ?? null);
        return;
      }
      if (ts.isContinueStatement(n)) {
        if (n.label ? !st.labels.has(n.label.text) : !st.continueBound) continues.add(n.label?.text ?? null);
        return;
      }
      if (ts.isReturnStatement(n)) {
        if (!returnLeaves) callbackReturn = true;
        return;
      }
      if (ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n)) return;
      if (ts.isLabeledStatement(n)) {
        visit(n.statement, { ...st, labels: new Set(st.labels).add(n.label.text) });
        return;
      }
      if (
        ts.isWhileStatement(n) ||
        ts.isDoStatement(n) ||
        ts.isForStatement(n) ||
        ts.isForOfStatement(n) ||
        ts.isForInStatement(n)
      ) {
        ts.forEachChild(n, (c) => visit(c, { ...st, breakBound: true, continueBound: true }));
        return;
      }
      if (ts.isSwitchStatement(n)) {
        ts.forEachChild(n, (c) => visit(c, { ...st, breakBound: true }));
        return;
      }
      ts.forEachChild(n, (c) => visit(c, st));
    };
    const start: Bound = { labels: new Set(), breakBound: false, continueBound: false };
    for (const s of stmts) visit(s, start);
    return { breaks, continues, callbackReturn };
  }

  private emitStatementList(stmts: readonly ts.Statement[], ctx: Ctx): void {
    for (let i = 0; i < stmts.length; i++) {
      const stmt = stmts[i];
      for (const c of this.leadingComments(stmt)) this.push(ctx, c);
      // R7 fusion: `const x = f(); if (x === null) <exit>` -> orelse (and the
      // `=== undefined` spelling a `.find` miss takes, per R7c).
      if (ts.isVariableStatement(stmt) && i + 1 < stmts.length) {
        const decl = stmt.declarationList.declarations[0];
        const next = stmts[i + 1];
        const test = ts.isIfStatement(next) ? this.emptyTestOf(next.expression) : null;
        if (
          stmt.declarationList.declarations.length === 1 &&
          decl.initializer &&
          ts.isIdentifier(decl.name) &&
          ts.isIfStatement(next) &&
          !next.elseStatement &&
          test !== null &&
          ts.isIdentifier(test.target) &&
          // Declaration identity, not name text: the guard must test THIS
          // declaration for the fusion's const to stand in for it (a
          // same-named outer local tested here narrows the wrong slot).
          this.tast.declarationOf(test.target) === decl &&
          this.alwaysExits(next.thenStatement) &&
          // A reassigned `let` cannot fuse: the fusion emits `const` typed by
          // the non-optional payload, so a later `p = ...` (or a legal
          // `p = null`) has no binding to land in. The plain path already
          // types it `var p: ?T` and guards with a real `if`.
          !this.isReassigned(decl, ctx)
        ) {
          const initType = this.zTypeOfExpr(decl.initializer, ctx);
          if (initType.k === "optional") {
            this.requireFaithfulEmptyTest(test.target, test.flavor, next.expression);
            this.emitOrelseFusion(decl, next.thenStatement, initType.inner, ctx);
            i += 1;
            continue;
          }
        }
      }
      this.emitStatement(stmt, ctx);
    }
  }

  /// `x === null` / `x === undefined` (the empty on either side, either
  /// order): the tested target and which JS empty the test names, or null
  /// for every other condition.
  private emptyTestOf(
    cond: ts.Expression,
    op: ts.SyntaxKind = ts.SyntaxKind.EqualsEqualsEqualsToken,
  ): { target: ts.Expression; flavor: "null" | "undefined" } | null {
    // Wrapper spellings must not change what the test matches: the
    // condition, either operand, and the returned target all strip
    // parentheses, non-null assertions, `as`, and `satisfies` — emission
    // erases every one of them, and tsc's own narrowing sees through them
    // too (`(q) === null` and `q! !== null` both test `q`), so downstream
    // shape checks and key derivations see the identifier itself.
    const c = unwrapExpr(cond);
    if (!ts.isBinaryExpression(c) || c.operatorToken.kind !== op) return null;
    const left = unwrapExpr(c.left);
    const right = unwrapExpr(c.right);
    const sides: Array<[ts.Expression, ts.Expression]> = [
      [left, right],
      [right, left],
    ];
    for (const [target, emptySide] of sides) {
      const flavor = this.emptyFlavorOf(emptySide);
      if (flavor && !this.emptyFlavorOf(target)) return { target, flavor };
    }
    return null;
  }

  /// The literal empty an expression spells: `null`, or the global
  /// `undefined` (a shadowing local declared in one of the core's own
  /// modules does not count).
  private emptyFlavorOf(e: ts.Expression): "null" | "undefined" | null {
    if (e.kind === ts.SyntaxKind.NullKeyword) return "null";
    if (ts.isIdentifier(e) && e.text === "undefined") {
      const decl = this.tast.declarationOf(e);
      if (!decl || !this.fileSet.has(decl.getSourceFile())) return "undefined";
    }
    return null;
  }

  /// A literal JS empty in VALUE position, through the value-preserving
  /// wrappers emission erases (parens, `as`, `satisfies`, non-null
  /// assertions): the `null` keyword or the global `undefined` identifier.
  /// Every ternary-arm and nullish EMPTINESS decision must use this, never
  /// a ZType check — `undefined`'s internal type is void, so a type check
  /// reads an `undefined` arm as a non-empty value and drops the
  /// optionality it carries, skipping the later guard's unwrap.
  private isEmptyLiteral(e: ts.Expression): boolean {
    return this.emptyFlavorOf(unwrapExpr(e)) !== null;
  }

  /// R7c: JS keeps null and undefined distinct; the native optional folds
  /// both into one empty. An empty test therefore only maps when the
  /// target's own type carries exactly the tested empty — testing the wrong
  /// one is constant-false under node but a real hit natively, so it stops
  /// here instead of diverging.
  private requireFaithfulEmptyTest(
    target: ts.Expression,
    flavor: "null" | "undefined",
    site: ts.Node,
  ): void {
    const empties = this.tast.emptiesOf(target);
    if (flavor === "null" && empties.undefined) {
      this.fail(
        site,
        "`=== null` on a value whose empty is JS `undefined` (a `.find` miss); test `=== undefined` or normalize with `??`",
      );
    }
    if (flavor === "undefined" && empties.null) {
      this.fail(site, "`=== undefined` on a value whose empty is `null`; test `=== null`");
    }
  }

  /// Whether a statement NEVER falls through to the statement after it.
  /// tsc's control-flow analysis narrows after any such statement — return,
  /// throw, break, and continue all qualify (a break/continue jumps to an
  /// enclosing construct's boundary, never to the next statement in
  /// sequence), so an early-exit guard narrows the remainder of its block
  /// no matter which exit the guard takes. A constant-true loop that no
  /// break binds qualifies too: it never completes normally, so tsc treats
  /// the statement after it as unreachable (and Zig types such a loop
  /// noreturn — the two terminality judgments must stay aligned).
  /// Kill-frame drops need the stronger whole-function question; that is
  /// allRoutesLeaveFunction.
  private alwaysExits(stmt: ts.Statement): boolean {
    if (ts.isReturnStatement(stmt)) return true;
    if (ts.isBreakStatement(stmt) || ts.isContinueStatement(stmt)) return true;
    // R20: a throw never falls through (it unwinds to a catch or out of
    // the function), and a try/catch exits when both arms do — any throw
    // mid-try lands in the catch, which exits. NS1058 keeps `finally`
    // from redirecting control flow, so it cannot un-exit either arm.
    if (ts.isThrowStatement(stmt)) return true;
    if (ts.isTryStatement(stmt)) {
      const tryExits = this.alwaysExits(stmt.tryBlock);
      const catchExits =
        stmt.catchClause === undefined || this.alwaysExits(stmt.catchClause.block);
      return tryExits && catchExits;
    }
    if (ts.isBlock(stmt)) {
      const last = stmt.statements[stmt.statements.length - 1];
      return last !== undefined && this.alwaysExits(last);
    }
    if (ts.isIfStatement(stmt)) {
      return (
        stmt.elseStatement !== undefined &&
        this.alwaysExits(stmt.thenStatement) &&
        this.alwaysExits(stmt.elseStatement)
      );
    }
    // A constant-true loop with no break bound to it never completes
    // normally, so the statement after it is unreachable — tsc's CFA types
    // post-loop code off the paths that never get there. The recognition
    // mirrors tsc's scope for our subset: the literal `true` keyword (and
    // the omitted / literal-true `for` condition) only, never arbitrary
    // constant-foldable expressions. Returns and throws inside the loop
    // leave the function without completing the loop, so they don't make
    // its end reachable (allRoutesLeaveFunction classifies them as routes
    // of their own); `continue` stays inside. Only a break bound to the
    // loop resumes right after it.
    if (ts.isWhileStatement(stmt) || ts.isDoStatement(stmt)) {
      return stmt.expression.kind === ts.SyntaxKind.TrueKeyword && !this.bindsBreak(stmt);
    }
    if (ts.isForStatement(stmt)) {
      return (
        (stmt.condition === undefined || stmt.condition.kind === ts.SyntaxKind.TrueKeyword) &&
        !this.bindsBreak(stmt)
      );
    }
    if (ts.isSwitchStatement(stmt)) {
      // A break bound to THIS switch resumes right after it, so the switch
      // completes normally even when every clause body ends in an exit
      // statement (the ubiquitous clause-terminating `break;` is exactly
      // such a break).
      if (this.bindsBreak(stmt)) return false;
      // A value switch (R13d) without a default may skip every clause —
      // unless its case labels cover the scrutinee's literal-union type,
      // in which case tsc's CFA (which is what this predicate mirrors)
      // treats the switch as always entering a clause. Kind switches are
      // exhaustive by NS1015; defaulted switches always enter a clause;
      // everything else consults the type (conservative false when the
      // scrutinee is not an enumerable literal union).
      const kindSwitch =
        ts.isPropertyAccessExpression(stmt.expression) && stmt.expression.name.text === "kind";
      const hasDefault = stmt.caseBlock.clauses.some((c) => ts.isDefaultClause(c));
      if (!kindSwitch && !hasDefault && !this.valueSwitchCoversScrutineeType(stmt)) return false;
      // Stacked case labels (`case "a": case "b": body`) share one body:
      // JS falls through an empty clause onto the next clause's statements
      // (the switch emitters coalesce the labels into one arm the same
      // way), so an empty clause's terminality is its group's tail's — the
      // next statement-bearing clause at or after it. A trailing run of
      // empty clauses has no body at all: control falls out of the switch,
      // so the switch completes normally.
      const clauses = stmt.caseBlock.clauses;
      return clauses.every((c, i) => {
        let stmts: readonly ts.Statement[] = c.statements;
        for (let j = i + 1; stmts.length === 0 && j < clauses.length; j++) {
          stmts = clauses[j].statements;
        }
        if (stmts.length === 1 && ts.isBlock(stmts[0])) stmts = (stmts[0] as ts.Block).statements;
        const last = stmts[stmts.length - 1];
        return last !== undefined && this.alwaysExits(last);
      });
    }
    if (ts.isLabeledStatement(stmt)) {
      // A label adds exactly one edge: `break label` resumes right AFTER
      // the labeled statement, making its end reachable. So the statement
      // is terminal iff the wrapped statement is terminal AND nothing
      // inside breaks to the label. The check is additive: a wrapped
      // loop's unlabeled breaks are already the loop's own concern
      // (bindsBreak, which also sees wrapping labels), and a labeled
      // BLOCK's inner terminality comes from the block rule above.
      return (
        this.alwaysExits(stmt.statement) &&
        !this.breaksToLabel(stmt.statement, stmt.label.text)
      );
    }
    return false;
  }

  /// Whether a defaultless VALUE switch's case labels cover every member of
  /// the scrutinee's literal-union type. Enumerable scrutinees are
  /// string/number/boolean literal unions ONLY: any wider type, any
  /// non-literal member, or any case label that is not a literal after
  /// wrapper-stripping answers false — the conservative side (a false merely
  /// merges a kill tsc kept and completes the lowered fallthrough; a wrong
  /// true emits an `else => unreachable` real execution can REACH). The type
  /// consulted is scrutineeCoverageType's SOUND type, never the checker's
  /// raw flow type: tsc keeps a local's narrowing across callback bodies
  /// that assign it, so its flow-exhaustiveness can be false at runtime.
  /// alwaysExits stays syntax-only on every other construct, and every
  /// caller is an emission path where `this.tast` is live, so the capability
  /// is unconditional. The lowering side of the same claim lives in
  /// emitValueSwitch: a covered-by-type defaultless switch whose arms all
  /// exit closes its never-reached fallthrough with `else => unreachable`
  /// (numeric) or emits no else at all (string enums, already
  /// Zig-exhaustive), so the terminality claim and the emitted shape agree —
  /// both consumers read this one memoized judgment and demote together.
  private valueSwitchCoversScrutineeType(stmt: ts.SwitchStatement): boolean {
    const memo = this.switchCoversTypeMemo.get(stmt);
    if (memo !== undefined) return memo;
    const answer = this.computeValueSwitchCoversScrutineeType(stmt);
    this.switchCoversTypeMemo.set(stmt, answer);
    return answer;
  }

  /// The type a defaultless switch's exhaustiveness may be judged against —
  /// null when no sound basis exists (the caller then answers false). tsc's
  /// flow type at the scrutinee is NOT such a basis on its own: tsc never
  /// widens a local's narrowing for assignments inside callbacks (it types
  /// `let k: "a" | "b" = "a"; xs.map(() => { k = "b"; }); switch (k)` with
  /// k still "a"), so a flow-exhaustive switch can be skipped by real
  /// execution. Sound bases, in order:
  ///   - an identifier local/param never assigned inside any nested
  ///     function of the switch's own enclosing function keeps the flow
  ///     type: locals cannot alias, so a scan over nested-function scopes
  ///     for assignments is exact, and without a capture-site assignment
  ///     the straight-line CFA is;
  ///   - any other narrowable reference (identifier, property read) is
  ///     judged by its DECLARED type — a symbol can hold any member of its
  ///     declared union at runtime whatever the flow claims;
  ///   - a non-reference scrutinee (call result, arithmetic, literal) has
  ///     no flow claims to distrust: its own resolved type stands.
  private scrutineeCoverageType(expr: ts.Expression): ts.Type | null {
    const e = unwrapExpr(expr);
    if (ts.isIdentifier(e)) {
      if (this.scrutineeFlowTrustable(e)) return this.tast.typeOf(e);
      return this.declaredTypeOfReference(e);
    }
    if (ts.isPropertyAccessExpression(e)) return this.declaredTypeOfReference(e.name);
    if (ts.isElementAccessExpression(e)) return null;
    return this.tast.typeOf(e);
  }

  /// The declared (declaration-site) type of a reference: the annotation
  /// when the declaration carries one, else the checker's type AT the
  /// declaration name — the symbol's initial type, which no flow narrowing
  /// has touched. Null when the declaration shape is not one whose declared
  /// type is recoverable; callers treat null as "cannot judge".
  private declaredTypeOfReference(name: ts.Node): ts.Type | null {
    const decl = this.tast.declarationOf(name);
    if (!decl) return null;
    if (
      (ts.isVariableDeclaration(decl) ||
        ts.isParameter(decl) ||
        ts.isPropertySignature(decl) ||
        ts.isPropertyDeclaration(decl)) &&
      decl.type
    ) {
      return this.tast.typeFromTypeNode(decl.type);
    }
    if (ts.isVariableDeclaration(decl) && ts.isIdentifier(decl.name)) {
      return this.tast.typeOf(decl.name);
    }
    return null;
  }

  /// Whether the flow type of this identifier may be trusted for an
  /// exhaustiveness claim: it names a local/param declared in the SAME
  /// enclosing function, and no nested function/callback in that function's
  /// body assigns it BEFORE the read can execute. Locals cannot alias in
  /// TypeScript, so the only escape hatch from the straight-line CFA is a
  /// capture-site assignment — the exact hole tsc's optimistic callback
  /// model leaves open. Declines when the declaration lives in an outer
  /// scope (the local IS a capture there) or when any nested function that
  /// can have RUN before the read (nestedFnRunsBeforeUse: position for
  /// arrows/function expressions, always for hoisted declarations and
  /// class members, back edges for shared loops) assigns or ++/--s it.
  private scrutineeFlowTrustable(id: ts.Identifier): boolean {
    const decl = this.tast.declarationOf(id);
    if (!decl || (!ts.isVariableDeclaration(decl) && !ts.isParameter(decl))) return false;
    const isFnScope = (n: ts.Node): boolean =>
      ts.isArrowFunction(n) ||
      ts.isFunctionExpression(n) ||
      ts.isFunctionDeclaration(n) ||
      ts.isMethodDeclaration(n) ||
      ts.isConstructorDeclaration(n) ||
      ts.isGetAccessorDeclaration(n) ||
      ts.isSetAccessorDeclaration(n);
    const enclosing = (n: ts.Node): ts.Node => {
      let cur: ts.Node | undefined = n.parent;
      while (cur && !isFnScope(cur)) cur = cur.parent;
      return cur ?? n.getSourceFile();
    };
    const scope = enclosing(id);
    if (scope !== enclosing(decl)) return false;
    let assignedInNested = false;
    // `root` is the OUTERMOST nested function of the current subtree: the
    // reach-before-use judgment belongs to it (an arrow inside a hoisted
    // declaration runs whenever the declaration does, so the inner arrow's
    // own position proves nothing).
    const visit = (n: ts.Node, root: ts.Node | null): void => {
      if (assignedInNested) return;
      const enter = root ?? (n !== scope && isFnScope(n) ? n : null);
      if (enter) {
        if (
          ts.isBinaryExpression(n) &&
          n.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
          n.operatorToken.kind <= ts.SyntaxKind.LastAssignment
        ) {
          const target = unwrapExpr(n.left);
          if (
            ts.isIdentifier(target) &&
            this.tast.declarationOf(target) === decl &&
            this.nestedFnRunsBeforeUse(enter, id)
          ) {
            assignedInNested = true;
            return;
          }
        }
        if (
          (ts.isPrefixUnaryExpression(n) || ts.isPostfixUnaryExpression(n)) &&
          (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken)
        ) {
          const target = unwrapExpr(n.operand as ts.Expression);
          if (
            ts.isIdentifier(target) &&
            this.tast.declarationOf(target) === decl &&
            this.nestedFnRunsBeforeUse(enter, id)
          ) {
            assignedInNested = true;
            return;
          }
        }
      }
      ts.forEachChild(n, (c) => visit(c, enter));
    };
    visit(scope, null);
    return !assignedInNested;
  }

  /// Whether an assignment inside nested function `fn` can have EXECUTED
  /// before the flow-trusted read at `use`. Labels the position rule with
  /// JS evaluation semantics:
  ///   - function DECLARATIONS hoist — they exist from scope start, so an
  ///     earlier call can run them wherever they sit — and class-member
  ///     bodies (methods, accessors, constructors) exist from their
  ///     container's creation: all count regardless of position;
  ///   - arrow functions and function EXPRESSIONS do not exist as values
  ///     before their definition evaluates, so one whose definition sits
  ///     textually after the read cannot have run before it — UNLESS a
  ///     loop encloses both, whose back edge re-enters the read after the
  ///     definition evaluated on an earlier iteration. An arrow defined
  ///     before the read counts even when only a variable holds it
  ///     (conservative-correct: whether anything calls it is not asked).
  private nestedFnRunsBeforeUse(fn: ts.Node, use: ts.Identifier): boolean {
    if (!ts.isArrowFunction(fn) && !ts.isFunctionExpression(fn)) return true;
    if (fn.getStart() < use.getStart()) return true;
    for (let cur: ts.Node | undefined = fn.parent; cur && !ts.isSourceFile(cur); cur = cur.parent) {
      if (ts.isFunctionLike(cur)) break;
      if (
        ts.isIterationStatement(cur, false) &&
        cur.getStart() <= use.getStart() &&
        use.getEnd() <= cur.getEnd()
      ) {
        return true;
      }
    }
    return false;
  }

  private computeValueSwitchCoversScrutineeType(stmt: ts.SwitchStatement): boolean {
    const type = this.scrutineeCoverageType(stmt.expression);
    if (type === null) return false;
    const members = type.isUnion() ? type.types : [type];
    const wanted = new Set<string>();
    for (const member of members) {
      if (member.isStringLiteral()) wanted.add(`s:${member.value}`);
      else if (member.isNumberLiteral()) wanted.add(`n:${member.value}`);
      else if (member.flags & ts.TypeFlags.BooleanLiteral) {
        wanted.add(`b:${this.tast.typeToString(member)}`);
      } else return false;
    }
    for (const clause of stmt.caseBlock.clauses) {
      if (ts.isDefaultClause(clause)) continue;
      const label = unwrapExpr(clause.expression);
      if (ts.isStringLiteral(label)) wanted.delete(`s:${label.text}`);
      else if (label.kind === ts.SyntaxKind.TrueKeyword) wanted.delete("b:true");
      else if (label.kind === ts.SyntaxKind.FalseKeyword) wanted.delete("b:false");
      else {
        const v = this.tast.constEvalNumber(label);
        if (v === null) return false;
        wanted.delete(`n:${v}`);
      }
    }
    return wanted.size === 0;
  }

  /// Kill-frame drop eligibility: whether EVERY route out of this statement
  /// list leaves the emitted function. Only then may the list's narrowing
  /// kills drop (emitBlockStatements) or a catch arm close the exception
  /// paths over its try body (emitTryCore) — the final statement alone
  /// cannot answer this, because earlier statements open routes of their
  /// own. The routes, and when each one resumes in-function instead of
  /// leaving:
  ///   - fallthrough off the end of the list — always resumes;
  ///   - `return` — resumes where returns lower to labeled breaks (lifted
  ///     callbacks: env.returnLeaves is false);
  ///   - `break`/`continue` at any nesting depth whose target sits at or
  ///     outside the list — always resumes (after the target construct,
  ///     inside the function). One bound to a loop/switch/label WHOLLY
  ///     inside the list stays inside it and is not a route out, so the
  ///     walk tracks locally-bound targets, never spellings;
  ///   - `throw`, or any statement containing a throwing call, whose
  ///     handler can fall back into the function — the handler is the
  ///     nearest catch inside the list, and the route's destination is
  ///     that catch PLUS its continuation: a catch that falls through
  ///     resumes at the statements following its try (transitively out
  ///     through enclosing blocks), so the route leaves iff every route
  ///     out of the catch leaves AND that continuation leaves. Outside
  ///     any local try, whatever env.throwResumes says about the
  ///     surroundings.
  /// When a route resists classification the answer is false (merge): an
  /// over-merge costs a narrow tsc would have kept, an under-merge
  /// resurrects a dead one and emits an unwrap Zig rejects. The
  /// continuation after a try is known positionally inside statement
  /// lists (the top list and nested blocks); inside loop bodies, switch
  /// clauses, and inline callbacks a catch's fallthrough re-enters the
  /// construct, so the continuation is treated as resuming there.
  /// `env.edgesLeave` re-asks the question with escaping break/continue
  /// edges and lowered returns treated as LEAVING: emitBlockStatements uses
  /// the difference to isolate lists whose only in-function routes are
  /// non-local edges (their kills stage at the edges' destinations rather
  /// than merging — see edgeKillRouting). A leaving return's expression
  /// still walks: throwing calls inside it ride the throw edges, not the
  /// return edge.
  private allRoutesLeaveFunction(
    stmts: readonly ts.Statement[],
    env: { returnLeaves: boolean; throwResumes: boolean; edgesLeave?: boolean },
  ): boolean {
    // `labels` / `breaks` / `continues` carry the targets bound inside the
    // list so far on this path; `throwResumes` is the handler visibility at
    // this point (re-derived at every try/catch met on the way down);
    // `inCallback` marks inline (unlifted) callback bodies, whose returns
    // are their own but whose throwing calls act at this site.
    interface State {
      readonly labels: ReadonlySet<string>;
      readonly breaks: number;
      readonly continues: number;
      readonly throwResumes: boolean;
      readonly inCallback: boolean;
    }
    // `tailLeaves`: whether control falling through past the node (to the
    // rest of its enclosing list, transitively outward) leaves the
    // function on every route — the positional continuation a
    // fallthrough catch hands a caught throw.
    const resumes = (n: ts.Node, st: State, tailLeaves: boolean): boolean => {
      const walk = (c: ts.Node): boolean => resumes(c, st, tailLeaves);
      if (ts.isBreakStatement(n)) {
        if (env.edgesLeave) return false;
        return !st.inCallback && (n.label ? !st.labels.has(n.label.text) : st.breaks === 0);
      }
      if (ts.isContinueStatement(n)) {
        if (env.edgesLeave) return false;
        return !st.inCallback && (n.label ? !st.labels.has(n.label.text) : st.continues === 0);
      }
      if (ts.isReturnStatement(n)) {
        if (!st.inCallback && !env.returnLeaves && !env.edgesLeave) return true;
        return n.expression !== undefined && walk(n.expression);
      }
      if (ts.isThrowStatement(n)) {
        return st.throwResumes || walk(n.expression);
      }
      if ((ts.isCallExpression(n) || ts.isNewExpression(n)) && st.throwResumes) {
        const target = this.calleeOwnerOf(n);
        if (target && this.leakingFns.has(target)) return true;
      }
      if (ts.isBlock(n)) {
        // A block's own fallthrough continues wherever the block's does,
        // so its statements scan positionally against the same tail.
        return scanList(n.statements, st, tailLeaves).resumes;
      }
      if (ts.isTryStatement(n) && n.catchClause !== undefined) {
        // Throws in the body land in this catch, whose destination is the
        // catch block plus its continuation: a fallthrough catch resumes
        // at the statements after this try, so the caught throw leaves
        // iff the catch-then-rest continuation leaves. The catch itself
        // runs against the handler visible OUTSIDE this try (its own
        // throws escape to enclosing handlers, never back into it).
        const catchScan = scanList(n.catchClause.block.statements, st, tailLeaves);
        const bodyThrowResumes = !catchScan.leaves;
        return (
          resumes(n.tryBlock, { ...st, throwResumes: bodyThrowResumes }, tailLeaves) ||
          catchScan.resumes ||
          (n.finallyBlock !== undefined && walk(n.finallyBlock))
        );
      }
      if (ts.isLabeledStatement(n)) {
        const bound = new Set(st.labels);
        bound.add(n.label.text);
        return resumes(n.statement, { ...st, labels: bound }, tailLeaves);
      }
      if (
        ts.isWhileStatement(n) ||
        ts.isDoStatement(n) ||
        ts.isForStatement(n) ||
        ts.isForOfStatement(n) ||
        ts.isForInStatement(n)
      ) {
        // The loop binds unlabeled break/continue for its whole subtree
        // (heads hold no break/continue — tsc rejects them there). A
        // fallthrough inside the body resumes at the back edge, in the
        // function, so the body scans against a resuming tail.
        return (
          ts.forEachChild(n, (c) =>
            resumes(c, { ...st, breaks: st.breaks + 1, continues: st.continues + 1 }, false) ||
            undefined,
          ) === true
        );
      }
      if (ts.isSwitchStatement(n)) {
        // Clause fallthrough resumes at the next clause / after the
        // switch — in the function — so clauses scan against a resuming
        // tail too.
        return (
          walk(n.expression) ||
          resumes(n.caseBlock, { ...st, breaks: st.breaks + 1 }, false)
        );
      }
      // Declarations don't run here; lifted callbacks are analyzed at
      // their own emission (their bodies get a retLabel of their own).
      if (ts.isFunctionDeclaration(n)) return false;
      if (ts.isArrowFunction(n) || ts.isFunctionExpression(n)) {
        if ([...this.hoistedFns.values()].includes(n)) return false;
        return resumes(n.body, { ...st, inCallback: true }, false);
      }
      return ts.forEachChild(n, (c) => walk(c) || undefined) === true;
    };
    // One right-to-left pass over a statement list: `resumes` is whether
    // any route out of any statement resumes in-function (each statement
    // classified against the continuation after ITS position); `leaves`
    // is whether control entering the list leaves the function on every
    // route — no route resumes, and fallthrough (which stops at the first
    // always-exiting statement) bottoms out in an exit or a leaving tail.
    // The fallthrough chain deliberately ignores in-list resuming routes:
    // any such route already forces `resumes`, and every consumer of
    // `leaves` (the verdict below, a caught throw's continuation) sits
    // under a scan whose `resumes` it feeds.
    const scanList = (
      list: readonly ts.Statement[],
      st: State,
      tailLeaves: boolean,
    ): { leaves: boolean; resumes: boolean } => {
      let cont = tailLeaves;
      let any = false;
      for (let i = list.length - 1; i >= 0; i--) {
        if (resumes(list[i], st, cont)) any = true;
        cont = this.alwaysExits(list[i]) || cont;
      }
      return { leaves: !any && cont, resumes: any };
    };
    const start: State = {
      labels: new Set(),
      breaks: 0,
      continues: 0,
      throwResumes: env.throwResumes,
      inCallback: false,
    };
    // Fallthrough off the end of the whole list always resumes.
    return scanList(stmts, start, false).leaves;
  }

  private emitOrelseFusion(decl: ts.VariableDeclaration, exit: ts.Statement, inner: ZType, ctx: Ctx): void {
    const name = this.claim(ctx, decl, zigLocalName((decl.name as ts.Identifier).text));
    ctx.localTypes.set(decl, inner);
    const init = orelseOperand(this.emitExpr(decl.initializer!, ctx).code);
    const exitStmts = ts.isBlock(exit) ? exit.statements : [exit];
    // A one-statement exit inlines (`orelse return v` / `orelse break` /
    // `orelse continue`); anything needing statements takes the block form
    // below — the block never falls through, so Zig types it noreturn.
    const inline = this.singleExitText(exit, ctx);
    if (inline !== null) {
      this.push(ctx, `const ${name} = ${init} orelse ${inline}`);
      return;
    }
    this.push(ctx, `const ${name} = ${init} orelse {`);
    const sub = this.nestedCtx(ctx);
    this.emitBlockStatements(exitStmts, sub);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `};`);
  }

  /// Clone a ctx for a probe or a same-indent sub-emission. ISOLATION LAW:
  /// the clone shares every mutable flow structure with its parent BY
  /// REFERENCE — memberSubst, stillOptionalSubst, narrowedUnion, the
  /// narrowKilled frame stack, the edgeKills stages, and pendingCatchKills
  /// — it isolates only the output lines. A PROBE (an emission whose lines
  /// may be discarded to pick a lowering shape) must therefore bracket
  /// itself with withNarrowScope: a probe that processes an assignment to
  /// an outer narrowed local (an inline map callback inside a ternary arm)
  /// would otherwise delete the narrowing for everything emitted after it
  /// — the SIBLING arm then reads the optional raw, invalid Zig. Sibling
  /// arms of one expression construct follow the statement-level law: each
  /// arm probes AND emits from the construct's entry state, and the arms'
  /// real kills join once after the last arm (applyJoinedNarrowKills).
  /// Kills a discarded probe stages on the shared edge sets (edgeKills,
  /// pendingCatchKills) are re-staged identically when the arm re-emits,
  /// so the sharing stays observationally clean — the narrowing maps and
  /// kill frames are the state a probe MUST NOT touch.
  private childCtx(ctx: Ctx): Ctx {
    return { ...ctx, lines: [], indent: ctx.indent };
  }

  private nestedCtx(ctx: Ctx): Ctx {
    return { ...ctx, lines: [], indent: ctx.indent + 1 };
  }

  private emitStatement(stmt: ts.Statement, ctx: Ctx): void {
    if (ts.isVariableStatement(stmt)) {
      for (const decl of stmt.declarationList.declarations) this.emitVarDecl(decl, stmt, ctx);
      return;
    }
    if (ts.isReturnStatement(stmt)) {
      if (!stmt.expression) {
        this.push(ctx, this.returnText(ctx, null, stmt));
        return;
      }
      const v = this.emitReturn(stmt.expression, ctx);
      this.push(ctx, this.returnText(ctx, v, stmt));
      return;
    }
    if (ts.isIfStatement(stmt)) {
      this.emitIf(stmt, ctx);
      return;
    }
    // Loops (and below, labeled statements and switches) bracket their
    // emission with an edge-kill stage: kills that ride a break edge bound
    // here apply to the POST-construct state — the destination the break
    // resumes at — and kills on a continue edge ride the back edge into
    // the loop-entry join. The emitter realizes both as the post-loop
    // application below: the loop-entry model delegates in-body
    // next-iteration reads to tsc (a read relying on a narrow the back
    // edge kills is a tsc error the checker already rejected), so the
    // only remaining state a back-edge kill must reach is the loop's
    // normal-completion exit — the same post-loop point.
    if (ts.isWhileStatement(stmt)) {
      const staged = this.stagedEdgeKills(ctx, "loop", null, () => this.emitWhile(stmt, ctx, null));
      // A `while (false)` body is tsc-unreachable (tscExcludedArm): kills
      // its break edges staged here never execute, so they don't apply.
      this.applyJoinedNarrowKills(ctx, this.tscExcludedArm(stmt, stmt.statement) ? new Set() : staged);
      return;
    }
    if (ts.isDoStatement(stmt)) {
      this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", null, () => this.emitDoWhile(stmt, ctx, null)));
      return;
    }
    if (ts.isForStatement(stmt)) {
      this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", null, () => this.emitClassicFor(stmt, ctx, null)));
      return;
    }
    if (ts.isForOfStatement(stmt)) {
      this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", null, () => this.emitForOf(stmt, ctx, null)));
      return;
    }
    if (ts.isLabeledStatement(stmt)) {
      // R12c: labels map onto Zig's labeled loops and blocks — `break
      // :label` / `continue :label` are the native spellings of the JS
      // labeled exits. A label on a non-loop statement wraps it in a
      // labeled block (JS break-to-label semantics; continue onto a
      // non-loop label is a tsc error). JS allows a label nothing jumps
      // to; Zig rejects an unused one, so those drop the label entirely.
      const label = this.labelReferenced(stmt.statement, stmt.label.text)
        ? loopLabel(stmt.label.text)
        : null;
      // The stage binds by the SOURCE label: a labeled break/continue's
      // kills must land at this construct's post-state even from deep
      // inside nested loops (edgeKillRouting resolves labels innermost-
      // out, so an inner-targeted unlabeled break never binds here).
      const jsLabel = stmt.label.text;
      const inner = stmt.statement;
      if (ts.isWhileStatement(inner)) {
        const staged = this.stagedEdgeKills(ctx, "loop", jsLabel, () => this.emitWhile(inner, ctx, label));
        // Same tsc-unreachable exclusion as the unlabeled while dispatch.
        this.applyJoinedNarrowKills(ctx, this.tscExcludedArm(inner, inner.statement) ? new Set() : staged);
      } else if (ts.isDoStatement(inner)) {
        this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", jsLabel, () => this.emitDoWhile(inner, ctx, label)));
      } else if (ts.isForStatement(inner)) {
        this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", jsLabel, () => this.emitClassicFor(inner, ctx, label)));
      } else if (ts.isForOfStatement(inner)) {
        this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "loop", jsLabel, () => this.emitForOf(inner, ctx, label)));
      } else if (label === null) {
        this.emitStatement(inner, ctx);
      } else {
        const kills = this.stagedEdgeKills(ctx, "block", jsLabel, () => {
          this.push(ctx, `${label}: {`);
          const sub = this.nestedCtx(ctx);
          this.emitBlockStatements(ts.isBlock(inner) ? inner.statements : [inner], sub);
          ctx.lines.push(...sub.lines);
          this.push(ctx, `}`);
        });
        this.applyJoinedNarrowKills(ctx, kills);
      }
      return;
    }
    if (ts.isSwitchStatement(stmt)) {
      // Clause-terminating breaks are stripped before their clause's route
      // analysis, so their kills ride the sibling JOIN (the switch
      // emitters' joinInto) to the same post-switch point this stage
      // applies at — one application, nothing dropped between the two
      // mechanisms. The stage itself keeps unlabeled-break RESOLUTION
      // faithful (a break under a switch binds the switch, never a loop
      // outside it; the mid-clause spellings that would stage here stop
      // the build at their own emission). Labeled exits out of a labeled
      // switch bind the wrapping labeled BLOCK's stage instead.
      this.applyJoinedNarrowKills(ctx, this.stagedEdgeKills(ctx, "switch", null, () => this.emitSwitch(stmt, ctx)));
      return;
    }
    if (ts.isExpressionStatement(stmt)) {
      this.emitExpressionStatement(stmt.expression, ctx);
      return;
    }
    if (ts.isBlock(stmt)) {
      // A plain lexical block is NOT a merge boundary: tsc's narrowing is
      // flow-based, so a narrow (or kill) established inside a fall-through
      // block survives into the statements after it. Emission FLATTENS the
      // block's statements into the enclosing list instead of bracketing
      // them (no withNarrowScope, no Zig braces): name uniquing is already
      // function-wide (ctx.used and the decl-keyed ctx.names ride every
      // nested ctx by reference), so Zig block scope is never load-bearing
      // for shadowing — and flattening is what keeps a narrowing capture
      // lowered inside the block (an orelse fusion's const, a `.?` subst's
      // target) in the same Zig scope as the post-block reads that rely on
      // it. Merge contexts (if/else arms, loop bodies, switch clauses,
      // callback and try/catch bodies, labeled blocks) never reach this
      // case — their emitters unwrap the block and bracket its statement
      // LIST — so control only ever falls straight through here. Nested
      // plain blocks flatten recursively.
      this.emitStatementList(stmt.statements, ctx);
      return;
    }
    if (ts.isBreakStatement(stmt)) {
      // An unlabeled JS break binds the nearest loop OR switch; Zig's
      // `break` binds loops only. A break that reaches statement emission
      // bound to a switch (the clause-terminating `break;` never gets
      // here — the switch emitters strip it) would jump past the wrong
      // construct, so it stops the build instead of miscompiling.
      if (!stmt.label && this.breakBindsEnclosingSwitch(stmt)) {
        this.fail(
          stmt,
          "a `break` that exits a `switch` from inside a clause body (only a clause-ending `break` has a mapping; restructure with an early `return`, or label the switch and `break <label>`)",
        );
      }
      this.push(ctx, stmt.label ? `break :${loopLabel(stmt.label.text)};` : `break;`);
      return;
    }
    if (ts.isContinueStatement(stmt)) {
      this.push(ctx, stmt.label ? `continue :${loopLabel(stmt.label.text)};` : `continue;`);
      return;
    }
    if (ts.isEmptyStatement(stmt)) {
      return; // `;` — a JS no-op maps to nothing.
    }
    if (ts.isThrowStatement(stmt)) {
      // R20: store the payload, then unwind — a labeled break to the
      // enclosing try body, or error.Thrown out of the function (the leak
      // fixpoint has given it a `Thrown!T` signature).
      if (this.thrownShape === null) this.fail(stmt, "`throw` without a resolved thrown shape", "NS1057");
      this.push(ctx, `thrown_payload = ${this.emitThrownValue(stmt.expression, ctx)};`);
      this.push(ctx, ctx.tryLabel ? `break :${ctx.tryLabel};` : `return error.Thrown;`);
      return;
    }
    if (ts.isTryStatement(stmt)) {
      this.emitTry(stmt, ctx);
      return;
    }
    this.fail(stmt, `statement kind ${ts.SyntaxKind[stmt.kind]}`);
  }

  /// The thrown value, coerced into the payload slot's type. Single-shape
  /// cores pass straight through (the expected-type machinery constructs
  /// literals in place). Under the thrown UNION, a value of one MEMBER
  /// shape re-tags: a member union's value through an arm-by-arm switch, a
  /// kind-tagged record through its arm constructor — both drop the `kind`
  /// field the tag now carries.
  private emitThrownValue(expr: ts.Expression, ctx: Ctx): string {
    const target = this.thrownShape!;
    if (target.k === "union") {
      const src = this.zTypeOfExpr(expr, ctx);
      if (src.k === "union" && src.name !== target.name) {
        const srcInfo = this.table.unions.get(src.name);
        if (srcInfo) {
          const v = this.emitExpr(expr, ctx).code;
          const arms = srcInfo.arms.map((arm) => {
            const t = zigId(arm.tag);
            if (arm.fields.length === 0) return `.${t} => .${t}`;
            if (arm.fields.length === 1) return `.${t} => |p| .{ .${t} = p }`;
            return `.${t} => |p| .{ .${t} = .{ ${arm.fields.map((f) => `.${fieldName(f)} = p.${fieldName(f)}`).join(", ")} } }`;
          });
          return `switch (${v}) { ${arms.join(", ")} }`;
        }
      }
      if (src.k === "struct" && src.name !== target.name) {
        const memberArms = thrownArmsOfShape(src, this.table);
        if (memberArms && memberArms.length === 1) {
          const arm = memberArms[0];
          const t = zigId(arm.tag);
          if (arm.fields.length === 0) return `.${t}`;
          const v = this.emitExpr(expr, ctx).code;
          if (arm.fields.length === 1) return `.{ .${t} = ${maybeParen(v)}.${fieldName(arm.fields[0])} }`;
          const tmp = this.freshName(ctx, "thrown_src");
          this.push(ctx, `const ${tmp} = ${v};`);
          return `.{ .${t} = .{ ${arm.fields.map((f) => `.${fieldName(f)} = ${tmp}.${fieldName(f)}`).join(", ")} } }`;
        }
      }
    }
    return this.emitExpr(expr, ctx, this.thrownShape ?? undefined).code;
  }

  /// R20: try/catch/finally. `finally` becomes a scoped defer (it runs on
  /// fall-through, return, break, and throw alike — the checker's NS1058
  /// keeps control flow out of it). The try body gets a label a throw
  /// breaks to; normal completion skips the catch arm with an outer label:
  ///
  ///     try_done: {
  ///         try_body: {
  ///             ...          // throw -> thrown_payload = v; break :try_body;
  ///             break :try_done;
  ///         }
  ///         ...catch arm (reads thrown_payload)...
  ///     }
  private emitTry(stmt: ts.TryStatement, ctx: Ctx): void {
    const fin = stmt.finallyBlock && stmt.finallyBlock.statements.length > 0 ? stmt.finallyBlock : undefined;
    if (fin) {
      // The defer's TEXT precedes the try body's, but its FLOW follows it:
      // the finally runs at the construct's exits, after the body and catch.
      // So the finally emits in a bracketed scope — its entry state is the
      // pre-try narrows minus the keys tsc widens for a finally (see
      // finallyEntryKills: any possibly-null assignment in the try or catch
      // kills, path-insensitively), and its own kills stage in `finStage`
      // rather than merging, so the body emitted after this text still
      // holds every narrow tsc keeps at its program points (the finally
      // has not run there). The staged kills apply once at the construct's
      // exit below — the state every fall-through continuation resumes
      // from — and propagate outward through the enclosing frames exactly
      // like a merge-class kill applied at that spot.
      this.push(ctx, `{`);
      const wrap = this.nestedCtx(ctx);
      this.push(wrap, `// finally: a scoped defer runs it on every exit of this block.`);
      this.push(wrap, `defer {`);
      const finCtx = this.nestedCtx(wrap);
      const finStage = new Set<string>();
      this.withNarrowScope(
        finCtx,
        "merge",
        () => {
          for (const key of this.finallyEntryKills(stmt, finCtx)) finCtx.memberSubst.delete(key);
          this.emitBlockStatements(fin.statements, finCtx);
        },
        finStage,
      );
      wrap.lines.push(...finCtx.lines);
      this.push(wrap, `}`);
      this.emitTryCore(stmt, wrap);
      ctx.lines.push(...wrap.lines);
      this.push(ctx, `}`);
      this.applyJoinedNarrowKills(ctx, finStage);
      return;
    }
    this.emitTryCore(stmt, ctx);
  }

  /// Whether tsc's CFA treats `arm` as statically unreachable inside
  /// `construct` — the then-arm of `if (false)`, the else-arm of
  /// `if (true)`, a `while (false)` body. Such an arm contributes NOTHING
  /// to the flow bookkeeping: no kills at the branch join, no widening of
  /// a finally's entry narrows (both consumers share this one judgment).
  /// The arm still EMITS — Zig compiles `if (false)` fine — only the flow
  /// accounting skips it.
  ///
  /// Only the bare `true`/`false` keywords qualify, pinned against the
  /// checker provider: a `const NEVER = false` alias condition WIDENS
  /// under tsc, so a reference never excludes. A do-while(false) body is
  /// never excluded either — the test runs AFTER the body, so the body
  /// executes once and tsc counts its assignments.
  private tscExcludedArm(construct: ts.Node, arm: ts.Node | undefined): boolean {
    if (arm === undefined) return false;
    if (ts.isIfStatement(construct)) {
      if (construct.expression.kind === ts.SyntaxKind.FalseKeyword) return arm === construct.thenStatement;
      if (construct.expression.kind === ts.SyntaxKind.TrueKeyword) return arm === construct.elseStatement;
      return false;
    }
    return (
      ts.isWhileStatement(construct) &&
      construct.expression.kind === ts.SyntaxKind.FalseKeyword &&
      arm === construct.statement
    );
  }

  /// The narrows dead at a finally block's entry: tsc types a finally from
  /// the pre-try state minus every key the try or catch body may assign
  /// null/undefined to — path-insensitively, because an exception can hand
  /// control to the finally from between any two statements, so a later
  /// non-null re-assignment does not revive the narrow there. A provably
  /// non-null assignment keeps a live-slot `.?` spelling (it reads the
  /// variable, never a stale value; valid at every interruption point,
  /// since the slot holds the guarded value before the write and the
  /// non-null replacement after it). A capture spelling still drops —
  /// defensively: every capture-binding construct declines the capture
  /// form when its scope assigns the target (captureServesBranch and the
  /// exit-guard's assignsTarget check), so a capture live here never has
  /// an assignment to survive.
  ///
  /// The scan counts exactly the assignments tsc's CFA counts — killing a
  /// key tsc keeps strips a substitution the finally's reads were typed
  /// against and emits member access on a raw optional, invalid Zig. Two
  /// exclusions, both pinned against the checker provider:
  ///   - code under a KEYWORD-LITERAL constant condition tsc treats as
  ///     unreachable never counts (tscExcludedArm — the same judgment the
  ///     branch-join layer applies): `if (false) ...`, the else of
  ///     `if (true) ...`, a `while (false)` body, and the right side of
  ///     `false && ...` / `true || ...` all keep the finally narrowed
  ///     (probed). Only the bare keywords qualify — a `const NEVER = false`
  ///     alias condition WIDENS under tsc (probed), and it still walks here;
  ///     the same keyword-only judgment alwaysExits applies to constant-true
  ///     loops. Anything else (do-while, non-literal conditions) stays on
  ///     the conservative path-insensitive walk.
  ///   - nested function/callback bodies never count (the throwsWithin skip
  ///     idiom): tsc keeps the finally narrowed even when a callback DEFINED
  ///     in the try assigns the target — called there or not (probed) — so
  ///     counting those assignments would kill a narrow tsc typed the
  ///     finally's reads with.
  /// Real conditional assignments (`if (flag) p = null`) still count: tsc
  /// widens for any reachable may-assign, whatever the path condition.
  private finallyEntryKills(stmt: ts.TryStatement, ctx: Ctx): Set<string> {
    const kills = new Set<string>();
    const visit = (n: ts.Node): void => {
      if (ts.isArrowFunction(n) || ts.isFunctionExpression(n) || ts.isFunctionDeclaration(n)) return;
      if (ts.isIfStatement(n)) {
        if (this.tscExcludedArm(n, n.thenStatement)) {
          if (n.elseStatement) visit(n.elseStatement);
          return;
        }
        if (n.elseStatement && this.tscExcludedArm(n, n.elseStatement)) {
          visit(n.thenStatement);
          return;
        }
      }
      if (ts.isWhileStatement(n) && this.tscExcludedArm(n, n.statement)) return;
      if (ts.isBinaryExpression(n)) {
        const op = n.operatorToken.kind;
        if (op === ts.SyntaxKind.AmpersandAmpersandToken && n.left.kind === ts.SyntaxKind.FalseKeyword) return;
        if (op === ts.SyntaxKind.BarBarToken && n.left.kind === ts.SyntaxKind.TrueKeyword) return;
      }
      if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
        const key = this.narrowKey(n.left);
        if (key !== null) {
          const subst = ctx.memberSubst.get(key);
          const empties = this.tast.emptiesOf(n.right);
          const mayBeEmpty = empties.null || empties.undefined;
          const survives = subst !== undefined && subst.endsWith(".?") && !mayBeEmpty;
          if (!survives && (subst !== undefined || mayBeEmpty)) kills.add(key);
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(stmt.tryBlock);
    if (stmt.catchClause) visit(stmt.catchClause.block);
    return kills;
  }

  private emitTryCore(stmt: ts.TryStatement, ctx: Ctx): void {
    const cc = stmt.catchClause;
    if (!cc) {
      // try/finally: throws propagate past this construct (the defer runs
      // first) to ctx's handler — the caller when ctx.tryLabel is null, an
      // enclosing catch otherwise. No catch fallthrough is added HERE, so
      // kill dropping inherits ctx.tryLabel/ctx.catchResumes unchanged:
      // the inherited flags already answer for whichever handler a throw
      // reaches, and a body ending in `return` may still drop its kills
      // when nothing up the chain can resume past a merge.
      this.push(ctx, `{`);
      const sub = this.nestedCtx(ctx);
      this.emitBlockStatements(stmt.tryBlock.statements, sub);
      ctx.lines.push(...sub.lines);
      this.push(ctx, `}`);
      return;
    }
    if (!this.throwsWithin(stmt.tryBlock)) {
      this.push(ctx, `// try: nothing inside can throw — the catch arm is unreachable and elided.`);
      this.push(ctx, `{`);
      const sub = this.nestedCtx(ctx);
      this.emitBlockStatements(stmt.tryBlock.statements, sub);
      ctx.lines.push(...sub.lines);
      this.push(ctx, `}`);
      return;
    }
    // A try body whose every path exits needs no skip label — a path
    // either leaves the function or breaks (a throw) into the catch arm.
    const bodyExits = this.alwaysExits(stmt.tryBlock);
    const done = bodyExits ? null : this.freshName(ctx, "try_done");
    const body = this.freshName(ctx, "try_body");
    this.push(ctx, done === null ? `{` : `${done}: {`);
    const outer = this.nestedCtx(ctx);
    this.push(outer, `${body}: {`);
    const inner = this.nestedCtx(outer);
    inner.tryLabel = body;
    // The body's kills may only drop when no exception path can resume
    // past this try: a catch that falls through re-enters the merge
    // carrying whatever a mid-body throw killed. A catch closes every such
    // path only when EVERY route out of it leaves the function — asked
    // against ctx, not the body label, because the catch's own throws
    // break to ctx's enclosing handler — and then it also closes paths
    // from any try nested in this body, so the flag is overwritten rather
    // than or-ed with the inherited value.
    inner.catchResumes = !this.allRoutesLeaveFunction(cc.block.statements, {
      returnLeaves: ctx.retLabel === null,
      throwResumes: ctx.catchResumes === true,
    });
    // Fresh pending set for THIS try: kills routed here rode throw edges
    // into this catch (popNarrowKillFrame's route form) and apply at
    // the post-try merge below. A nested try's body re-derives its own set,
    // so kills always land at the same destination the throw route resolves
    // to; the catch block itself inherits the ENCLOSING set through ctx
    // (its throws escape outward, never back into this try).
    const pendingKills = new Set<string>();
    inner.pendingCatchKills = pendingKills;
    this.emitBlockStatements(stmt.tryBlock.statements, inner);
    if (done !== null) this.push(inner, `break :${done};`);
    outer.lines.push(...inner.lines);
    this.push(outer, `}`);
    // Exception-kills handoff: kills travel the same edges control does,
    // and the routes that fed this set are throws that land in THIS catch
    // — so they enter as the catch's INPUT state (tsc types the catch from
    // the state at the throw points: a narrowing an always-throwing arm
    // killed before throwing is dead inside the catch) and then follow the
    // catch's own routes out, via the catch list's kill-frame routing. A
    // catch that falls through carries them to the post-try continuation;
    // a catch that breaks/continues stages them at that edge's landing
    // point; a catch whose every route leaves the function drops them —
    // the post-try continuation is then reached only by clean paths, where
    // tsc keeps the narrow, so applying them there unconditionally would
    // poison the normal fallthrough. The body's normal-exit kills already
    // applied at the body's own merge just above, so the catch also sees
    // those (tsc-correct too: a mid-body throw can follow any fall-through
    // assignment). They never touch the intra-try flow already emitted
    // above.
    const catchCtx: Ctx = { ...outer, lines: [] };
    if (cc.variableDeclaration && ts.isIdentifier(cc.variableDeclaration.name)) {
      if (this.identifierUsed(cc.block, cc.variableDeclaration)) {
        const ename = this.claim(catchCtx, cc.variableDeclaration, zigLocalName(cc.variableDeclaration.name.text));
        catchCtx.localTypes.set(cc.variableDeclaration, this.thrownShape!);
        this.push(catchCtx, `const ${ename} = thrown_payload;`);
      }
    }
    this.emitBlockStatements(cc.block.statements, catchCtx, undefined, pendingKills);
    outer.lines.push(...catchCtx.lines);
    ctx.lines.push(...outer.lines);
    this.push(ctx, `}`);
  }

  private emitWhile(stmt: ts.WhileStatement, ctx: Ctx, label: string | null): void {
    const head = label === null ? "while" : `${label}: while`;
    // R7d: `while (x !== null && <rest>)` — unwrap spelling, re-tested per
    // iteration, with the substitutions active over the body (an
    // assignment to the guarded local drops them for what follows, exactly
    // like TS narrowing).
    if (ts.isBinaryExpression(stmt.expression) &&
        stmt.expression.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
      const wop = stmt.expression.operatorToken.kind;
      const conjuncts = this.flattenLogical(stmt.expression, wop);
      const wBody = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
      const applies =
        conjuncts.length > 1 &&
        conjuncts.some((c, i) => {
          const g = this.nullGuardOf(c, wop, ctx);
          return (
            g !== null &&
            this.anyReadsTarget([...conjuncts.slice(i + 1), stmt.statement], g.target)
          );
        });
      if (applies) {
        const guards = new Map<string, string>();
        const before = ctx.lines.length;
        const condText = this.emitNullGuardChainUnwrap(conjuncts, wop, ctx, guards);
        if (ctx.lines.length !== before) this.fail(stmt, "while-condition requiring lowered statements");
        this.push(ctx, `${head} (${condText}) {`);
        const sub = this.nestedCtx(ctx);
        this.withSubsts(guards, ctx, () =>
          this.withKindNarrows(this.chainKindGuards(conjuncts, wop), ctx, () =>
            this.emitBlockStatements(wBody, sub),
          ),
        );
        ctx.lines.push(...sub.lines);
        this.push(ctx, `}`);
        return;
      }
    }
    const before = ctx.lines.length;
    const cond = this.emitExpr(stmt.expression, ctx, { k: "bool" }).code;
    if (ctx.lines.length !== before) this.fail(stmt, "while-condition requiring lowered statements");
    const body = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
    // A `while (false)` body is statically unreachable to tsc's CFA
    // (tscExcludedArm), so its kills never reach the post-loop state —
    // merging them would strip a narrow tsc typed the fall-through reads
    // with. The body still emits; only the flow bookkeeping skips.
    const deadBody = this.tscExcludedArm(stmt, stmt.statement);
    if (label === null && body.length === 1 && this.isSimpleAssignment(body[0])) {
      // Probe in a flow scope (see childCtx): taken, the assignment's
      // kills apply below exactly as a merge would; discarded, the full
      // body re-emission repeats them.
      const bodyJoin = new Set<string>();
      const sub = this.childCtx(ctx);
      sub.indent = 0;
      this.withNarrowScope(ctx, "merge", () => this.emitStatement(body[0], sub), bodyJoin);
      if (sub.lines.length === 1) {
        this.push(ctx, `while (${cond}) ${sub.lines[0].trim()}`);
        this.applyJoinedNarrowKills(ctx, deadBody ? new Set() : bodyJoin);
        return;
      }
    }
    this.push(ctx, `${head} (${cond}) {`);
    const sub = this.nestedCtx(ctx);
    if (deadBody) {
      this.withNarrowScope(ctx, "drop", () => this.emitBlockStatements(body, sub));
    } else {
      this.emitBlockStatements(body, sub);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
  }

  /// R12d: `do { body } while (cond)` — the body runs before the first
  /// test. Without a loop-bound `continue` the mapping is the plain
  /// `while (true)` + trailing exit test. A `continue` in JS jumps TO the
  /// test, so that body takes the first-pass flag form instead: the flag
  /// short-circuits the condition on the first entry and every later
  /// entry (continue included) evaluates it — exactly node's order.
  private emitDoWhile(stmt: ts.DoStatement, ctx: Ctx, label: string | null): void {
    const body = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
    const head = label === null ? "while" : `${label}: while`;
    if (!this.bindsContinue(stmt.statement, label)) {
      this.push(ctx, `${head} (true) {`);
      const sub = this.nestedCtx(ctx);
      // tsc evaluates the do-while condition AFTER the body and carries the
      // body's flow state into it — a terminal guard in the body narrows
      // the trailing test. The body and the lowered `if (!(cond)) break;`
      // therefore emit inside ONE narrowing scope (the `trailing` hook),
      // restored only at the loop boundary: a restore between them would
      // strip the narrow before the read it covers. Iteration-entry state
      // is not at risk — the test is the last text in the loop body, so
      // nothing emits under its narrows past the back edge, and the
      // restore still runs before the post-loop continuation.
      // A body that always exits never reaches the test in JS either; the
      // emitted trailing test would be Zig unreachable-code.
      const trailing = this.alwaysExits(stmt.statement)
        ? undefined
        : (): void => {
            const before = sub.lines.length;
            const cond = this.emitExpr(stmt.expression, sub, { k: "bool" }).code;
            if (sub.lines.length !== before) this.fail(stmt, "do-while condition requiring lowered statements");
            this.push(sub, `if (!(${cond})) break;`);
          };
      this.emitBlockStatements(body, sub, undefined, undefined, trailing);
      ctx.lines.push(...sub.lines);
      this.push(ctx, `}`);
      return;
    }
    const first = this.freshName(ctx, "first_pass");
    const before = ctx.lines.length;
    const cond = this.emitExpr(stmt.expression, ctx, { k: "bool" }).code;
    if (ctx.lines.length !== before) this.fail(stmt, "do-while condition requiring lowered statements");
    this.push(ctx, `var ${first} = true;`);
    this.push(ctx, `${head} (${first} or (${cond})) {`);
    const sub = this.nestedCtx(ctx);
    this.push(sub, `${first} = false;`);
    this.emitBlockStatements(body, sub);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
  }

  /// Whether any `break`/`continue` under `body` names this label (JS
  /// allows an unreferenced label; Zig rejects one, so it must drop).
  /// Duplicate nested labels cannot shadow — tsc rejects them.
  private labelReferenced(body: ts.Node, name: string): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if ((ts.isBreakStatement(n) || ts.isContinueStatement(n)) && n.label?.text === name) {
        found = true;
        return;
      }
      ts.forEachChild(n, visit);
    };
    visit(body);
    return found;
  }

  /// Whether a loop body contains a `continue` that binds to THIS loop: an
  /// unlabeled one outside any nested loop, or a labeled one naming this
  /// loop's label.
  private bindsContinue(body: ts.Node, label: string | null): boolean {
    let found = false;
    const visit = (n: ts.Node, insideNested: boolean): void => {
      if (found) return;
      if (ts.isContinueStatement(n)) {
        if (n.label) {
          if (label !== null && loopLabel(n.label.text) === label) found = true;
        } else if (!insideNested) {
          found = true;
        }
        return;
      }
      const nested =
        insideNested ||
        ts.isWhileStatement(n) ||
        ts.isDoStatement(n) ||
        ts.isForStatement(n) ||
        ts.isForOfStatement(n) ||
        ts.isForInStatement(n);
      // Callbacks cannot `continue` an outer loop (tsc rejects it), so
      // function boundaries need no special casing here.
      ts.forEachChild(n, (c) => visit(c, nested));
    };
    visit(body, false);
    return found;
  }

  /// Whether an unlabeled `break` statement binds a `switch` rather than a
  /// loop: the nearest enclosing loop-or-switch, walking out of the break,
  /// is a switch. (tsc already rejects a break with neither.)
  private breakBindsEnclosingSwitch(stmt: ts.BreakStatement): boolean {
    let cur: ts.Node | undefined = stmt.parent;
    while (cur) {
      if (
        ts.isWhileStatement(cur) ||
        ts.isDoStatement(cur) ||
        ts.isForStatement(cur) ||
        ts.isForOfStatement(cur) ||
        ts.isForInStatement(cur) ||
        ts.isFunctionLike(cur)
      ) {
        return false;
      }
      if (ts.isSwitchStatement(cur)) return true;
      cur = cur.parent;
    }
    return false;
  }

  /// Whether a `break` inside this switch's clauses (or this loop's body)
  /// binds the switch/loop itself: an unlabeled one outside any nested
  /// loop or switch, or a labeled one naming a label wrapped directly
  /// around this statement. Such a break resumes right AFTER the
  /// statement — the switch/loop falls through.
  /// (A break inside a callback cannot reach out — tsc rejects it — so
  /// function boundaries need no special casing, same as bindsContinue.)
  private bindsBreak(
    stmt: ts.SwitchStatement | ts.WhileStatement | ts.DoStatement | ts.ForStatement,
  ): boolean {
    const wrappingLabels = new Set<string>();
    let p: ts.Node | undefined = stmt.parent;
    while (p && ts.isLabeledStatement(p)) {
      wrappingLabels.add(p.label.text);
      p = p.parent;
    }
    let found = false;
    const visit = (n: ts.Node, insideNested: boolean): void => {
      if (found) return;
      if (ts.isBreakStatement(n)) {
        if (n.label) {
          if (wrappingLabels.has(n.label.text)) found = true;
        } else if (!insideNested) {
          found = true;
        }
        return;
      }
      const nested =
        insideNested ||
        ts.isWhileStatement(n) ||
        ts.isDoStatement(n) ||
        ts.isForStatement(n) ||
        ts.isForOfStatement(n) ||
        ts.isForInStatement(n) ||
        ts.isSwitchStatement(n);
      ts.forEachChild(n, (c) => visit(c, nested));
    };
    if (ts.isSwitchStatement(stmt)) {
      ts.forEachChild(stmt.caseBlock, (c) => visit(c, false));
    } else {
      // Loop heads hold no break (tsc rejects one there); only the body
      // can bind this loop.
      visit(stmt.statement, false);
    }
    return found;
  }

  /// Whether any `break` naming `label` sits inside `node`. Function
  /// boundaries stop the walk: a labeled break cannot cross one (tsc
  /// rejects it), and a nested function may legally reuse the label name
  /// for a labeled statement of its own. tsc rejects duplicate labels on
  /// the same nesting path, so no inner rebinding can shadow `label`.
  private breaksToLabel(node: ts.Node, label: string): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (ts.isBreakStatement(n)) {
        if (n.label !== undefined && n.label.text === label) found = true;
        return;
      }
      if (ts.isFunctionLike(n)) return;
      ts.forEachChild(n, visit);
    };
    visit(node);
    return found;
  }

  private isSimpleAssignment(stmt: ts.Statement): boolean {
    if (!ts.isExpressionStatement(stmt)) return false;
    const e = stmt.expression;
    if (ts.isBinaryExpression(e)) {
      const k = e.operatorToken.kind;
      return (
        k === ts.SyntaxKind.PlusEqualsToken ||
        k === ts.SyntaxKind.MinusEqualsToken ||
        k === ts.SyntaxKind.EqualsToken
      );
    }
    return ts.isPostfixUnaryExpression(e) || ts.isPrefixUnaryExpression(e);
  }

  private emitVarDecl(decl: ts.VariableDeclaration, stmt: ts.VariableStatement, ctx: Ctx): void {
    if (ts.isObjectBindingPattern(decl.name)) {
      this.emitObjectDestructure(decl, decl.name, stmt, ctx);
      return;
    }
    if (!ts.isIdentifier(decl.name)) {
      // Layer-3 re-derivation of NS1045 (array patterns and the rest).
      this.fail(decl, "a destructuring pattern beyond const record fields", "NS1045");
    }
    // Layer-3 re-derivation of NS1049: `var` hoists; only const/let map.
    if ((stmt.declarationList.flags & (ts.NodeFlags.Let | ts.NodeFlags.Const)) === 0) {
      this.fail(decl, "`var` declares a hoisted, function-scoped local", "NS1049");
    }
    // R15d: a const-bound function value hoists to a module-level fn; the
    // local binding erases (references emit the hoisted name).
    const hoistFn = this.hoistedFns.get(decl);
    if (hoistFn) {
      const verdict = functionValueLegality(decl, hoistFn, this.tast);
      if (!verdict.ok) {
        this.fail(decl, `a local function value that cannot hoist — ${verdict.why}`, "NS1054");
      }
      if (!this.hoistQueued.has(decl)) {
        this.hoistQueued.add(decl);
        this.hoistQueue.push(decl);
      }
      this.push(ctx, `// const ${decl.name.text}: hoisted to fn ${this.moduleNames.get(decl)!} (module scope)`);
      return;
    }
    {
      const init = decl.initializer ? unwrapExpr(decl.initializer) : null;
      if (init && (ts.isArrowFunction(init) || ts.isFunctionExpression(init))) {
        // Layer-3 re-derivation of NS1046/NS1054 (non-const or named shapes).
        this.fail(decl, "a function value outside the const-bound local-helper shape", "NS1046");
      }
    }
    const isLet = (stmt.declarationList.flags & ts.NodeFlags.Let) !== 0;
    const reassigned = isLet && this.isReassigned(decl, ctx);
    // R17m: a reassigned binding whose EVERY assignment installs a fresh
    // owning construction stays owned (flow-sensitive) — it may mutate, and
    // length-changing mutations still lower through the builder (each
    // assignment resets the slice and fill count).
    const fnScope = enclosingFunctionOf(decl);
    const reassignedOwning =
      reassigned &&
      decl.initializer !== undefined &&
      isOwningInitializer(decl.initializer) &&
      fnScope !== null &&
      everyAssignmentOwning(this.tast, decl, fnScope);
    // R19: a locally-owned class instance the function mutates (field
    // writes or mutating-method calls) binds `var` — the mutations write
    // through `&name`.
    const instanceMutated =
      !reassigned &&
      decl.initializer !== undefined &&
      ts.isNewExpression(unwrapExpr(decl.initializer)) &&
      this.instanceMutationsExist(decl);
    const kw = reassigned || instanceMutated ? "var" : "const";
    const name = this.claim(ctx, decl, zigLocalName(decl.name.text));
    const declared = decl.type ? this.table.resolveTypeNode(decl.type) : null;

    // R17k (generalized): a locally-owned array with length-changing
    // mutations (push/pop/shift/unshift/splice) lowers to a frame builder —
    // a mutable slice plus a live fill count. Reads of the name see the
    // filled prefix, `.length` the count; the mutations themselves lower in
    // tryEmitPushCall / tryEmitMutatingCall. Fixed-length mutations
    // (sort/reverse/fill, indexed writes) need no builder: every owning
    // constructor already emits a mutable arena copy they write through.
    const mutations = (!reassigned || reassignedOwning) && decl.initializer ? this.mutationsOf(decl) : new Set<string>();
    if (mutations.size > 0 && decl.initializer && isOwningInitializer(decl.initializer)) {
      const sliceT = declared ?? this.zTypeOfExpr(decl.initializer, ctx);
      const needsLen = [...mutations].some((m) => lengthChangingMethods.has(m));
      const growable = [...mutations].some((m) => growingMethods.has(m));
      const init = unwrapExpr(decl.initializer);
      if (sliceT.k === "slice" && needsLen) {
        const lenVar = this.freshName(ctx, `${name}_len`);
        const elemRef = this.table.zigTypeRef(sliceT.elem);
        ctx.localTypes.set(decl, sliceT);
        ctx.builders.set(decl, { slice: name, len: lenVar, elemRef, elem: sliceT.elem, growable });
        const varKw = growable || reassignedOwning ? "var" : "const";
        if (ts.isArrayLiteralExpression(init) && init.elements.length === 0) {
          this.push(ctx, `${varKw} ${name} = rt.frameAlloc(${elemRef}, 0);`);
          this.push(ctx, `var ${lenVar}: usize = 0;`);
        } else {
          const seed = this.emitExpr(decl.initializer, ctx, sliceT, `${name}_seed`);
          this.push(ctx, `${varKw} ${name} = ${seed.code};`);
          this.push(ctx, `var ${lenVar}: usize = ${name}.len;`);
        }
        const declKey = this.narrowKey(decl.name);
        if (declKey !== null) {
          ctx.memberSubst.set(declKey, `${name}[0..${lenVar}]`);
          ctx.memberSubst.set(`${declKey}.length`, `@as(i64, @intCast(${lenVar}))`);
        }
        return;
      }
      if (sliceT.k === "slice" && ts.isArrayLiteralExpression(init) && init.elements.length === 0) {
        // sort/reverse/fill on an always-empty literal: nothing grows it,
        // so the mutation is dead — and the emitted `&.{}` has no mutable
        // storage behind it.
        this.fail(decl, "mutating an always-empty array literal (nothing grows it; seed it with elements, or build it with push first)");
      }
      // Fixed-length mutations fall through to the normal emission: the
      // owning constructor's arena copy is element-mutable as it stands.
    }

    if (!decl.initializer) {
      // `let target: number;` -> `var target: i64 = undefined;`
      const t = declared ? this.typeRefWithNumbers(declared, decl) : this.fail(decl, "untyped uninitialized local");
      ctx.localTypes.set(decl, declared!);
      this.push(ctx, `var ${name}: ${t} = undefined;`);
      return;
    }

    const expected = declared ?? undefined;
    const t = expected ?? this.zTypeOfExpr(decl.initializer, ctx);
    ctx.localTypes.set(decl, t);
    const v = this.emitExpr(decl.initializer, ctx, this.resolveNumberClass(expected ?? t, decl), name);
    if (v.code === name) return; // lowered directly into a named temp
    const annotation = this.varAnnotation(decl, t, reassigned, ctx);
    this.push(ctx, `${kw} ${name}${annotation} = ${v.code};`);
    if (v.filterLen) {
      const declKey = this.narrowKey(decl.name);
      if (declKey !== null) ctx.memberSubst.set(`${declKey}.length`, `@as(i64, @intCast(${v.filterLen}))`);
    }
  }

  /// R6b: `const { total, done: doneCount } = stats;` — record-field
  /// destructuring is a compile-time alias per field, so it lowers to plain
  /// field reads. The checker (NS1045) has already restricted the shape to
  /// const + identifier bindings over a struct-typed value.
  private emitObjectDestructure(
    decl: ts.VariableDeclaration,
    pattern: ts.ObjectBindingPattern,
    stmt: ts.VariableStatement,
    ctx: Ctx,
  ): void {
    if ((stmt.declarationList.flags & ts.NodeFlags.Const) === 0) {
      this.fail(decl, "`let` destructuring (bind with `const`; reassign a plain `let` local)", "NS1045");
    }
    if (!decl.initializer) this.fail(decl, "destructuring without an initializer");
    const rawT = this.zTypeOfExpr(decl.initializer, ctx);
    if (rawT.k !== "struct") {
      this.fail(
        decl,
        `destructuring a ${rawT.k === "optional" ? "possibly-null value (guard it with !== null first)" : rawT.k} (v1 destructures record fields)`,
      );
    }
    const info = this.table.structs.get(rawT.name);
    if (!info) this.fail(decl, `unknown record type ${rawT.name}`);
    // A non-identifier base materializes once, matching JS's single
    // evaluation of the right-hand side.
    let base = this.emitExpr(decl.initializer, ctx).code;
    if (!ts.isIdentifier(decl.initializer)) {
      // Type-derived temp (`TaskList` -> `task_list`): a synthetic name, so
      // the snake form both reads as a value and never shadows the type.
      const tmp = this.freshName(ctx, snakeCase(rawT.name));
      this.push(ctx, `const ${tmp} = ${base};`);
      base = tmp;
    }
    for (const el of pattern.elements) {
      if (el.dotDotDotToken || el.initializer || !ts.isIdentifier(el.name)) {
        this.fail(el, "a destructuring pattern beyond const record fields", "NS1045");
      }
      const propName =
        el.propertyName && ts.isIdentifier(el.propertyName) ? el.propertyName.text : el.name.text;
      const field = info.fields.find((f) => f.tsName === propName);
      if (!field) this.fail(el, `\`${propName}\` names no field of ${rawT.name}`);
      const name = this.claim(ctx, el, zigLocalName(el.name.text));
      ctx.localTypes.set(el, field.type);
      this.push(ctx, `const ${name} = ${base}.${fieldName(field)};`);
    }
  }

  /// Number locals: `var` always needs a type; `const` needs one when the
  /// initializer's natural Zig type differs (byte reads are u8, we hold i64).
  private varAnnotation(decl: ts.VariableDeclaration, t: ZType, reassigned: boolean, ctx: Ctx): string {
    if (t.k === "number") {
      const cls = this.infer.classOfDecl(decl) ?? "f64";
      const init = decl.initializer!;
      if (reassigned) return `: ${cls}`;
      if (ts.isElementAccessExpression(init) || ts.isNumericLiteral(init)) return `: ${cls}`;
      // A ternary of literal branches would peer-resolve to comptime_int,
      // which cannot depend on the runtime condition; the annotation anchors
      // the runtime type.
      if (ts.isConditionalExpression(init)) return `: ${cls}`;
      return "";
    }
    if (!decl.type && t.k === "optional" && t.inner.k === "number") {
      // Unannotated optional-number locals from null-branched ternaries
      // (and any reassigned form): anchor `?i64`/`?f64` so a `null` arm
      // cannot leave the peer type comptime-only.
      const cls = this.infer.classOfDecl(decl) ?? "f64";
      if (reassigned || ts.isConditionalExpression(decl.initializer!)) return `: ?${cls}`;
      return "";
    }
    if (t.k === "enum") {
      // String-enum locals emit bare enum literals (`.rest`), whose type
      // is comptime-only. A runtime-conditional initializer or a
      // reassigned `var` would make the comptime-only type depend on
      // runtime control flow — the annotation anchors the real enum type
      // (`const next_phase: Phase = if (...) .rest else .focus;`).
      if (reassigned || ts.isConditionalExpression(unwrapExpr(decl.initializer!))) return `: ${this.table.zigTypeRef(t)}`;
      return "";
    }
    if (decl.type && (t.k === "struct" || t.k === "slice" || t.k === "optional" || t.k === "union")) {
      // Keep author-written annotations that carry pointer-ness, give
      // conditional initializers a result type (anonymous struct/union
      // literals in the branches cannot peer-resolve without one), and keep
      // optionals optional — `let x: T | null = {...}` must hold ?T so later
      // null assignments and tests stay well-typed.
      if (t.k === "struct" && this.table.isPointerStruct(t.name)) return `: ${this.table.zigTypeRef(t)}`;
      // An annotated BY-VALUE record local initialized from a literal
      // anchors its declared type too: the emitted `.{ ... }` would
      // otherwise be its own anonymous struct type, which cannot coerce
      // when the local is later passed to a typed parameter.
      if ((t.k === "struct" || t.k === "union") && ts.isObjectLiteralExpression(decl.initializer!)) return `: ${this.table.zigTypeRef(t)}`;
      if (t.k === "optional") return `: ${this.typeRefWithNumbers(t, decl)}`;
      if (ts.isConditionalExpression(decl.initializer!)) return `: ${this.table.zigTypeRef(t)}`;
    }
    return "";
  }

  private isReassigned(decl: ts.VariableDeclaration, _ctx: Ctx): boolean {
    let fn: ts.Node | undefined = decl;
    while (fn && !ts.isFunctionDeclaration(fn) && !ts.isArrowFunction(fn) && !ts.isSourceFile(fn)) fn = fn.parent;
    if (!fn) return false;
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (ts.isBinaryExpression(n) && assignmentOps.has(n.operatorToken.kind) && ts.isIdentifier(n.left)) {
        if (this.tast.declarationOf(n.left) === decl) found = true;
      } else if (
        (ts.isPostfixUnaryExpression(n) || ts.isPrefixUnaryExpression(n)) &&
        (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken) &&
        ts.isIdentifier(n.operand) &&
        this.tast.declarationOf(n.operand) === decl
      ) {
        found = true;
      }
      ts.forEachChild(n, visit);
    };
    visit(fn);
    return found;
  }

  private emitIf(stmt: ts.IfStatement, ctx: Ctx): void {
    const cond = stmt.expression;

    // R13b: `if (e.kind !== "tag") <exit>` -> `if (e != .tag) <exit>` + narrow.
    if (
      ts.isBinaryExpression(cond) &&
      cond.operatorToken.kind === ts.SyntaxKind.ExclamationEqualsEqualsToken &&
      ts.isPropertyAccessExpression(cond.left) &&
      cond.left.name.text === "kind" &&
      ts.isStringLiteral(cond.right) &&
      !stmt.elseStatement &&
      this.alwaysExits(stmt.thenStatement)
    ) {
      const base = this.emitExpr(cond.left.expression, ctx).code;
      const tag = cond.right.text;
      const exit = this.singleExitText(stmt.thenStatement, ctx);
      if (exit !== null) {
        this.push(ctx, `if (${base} != .${zigId(tag)}) ${exit}`);
      } else {
        // Multi-statement exits (a throw is always two emitted statements)
        // keep the guard's narrowing through the block form.
        this.push(ctx, `if (${base} != .${zigId(tag)}) {`);
        const sub = this.nestedCtx(ctx);
        const exitStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
        this.emitBlockStatements(exitStmts, sub);
        ctx.lines.push(...sub.lines);
        this.push(ctx, `}`);
      }
      const t = this.zTypeOfExpr(cond.left.expression, ctx);
      if (t.k === "union") this.narrowUnion(cond.left.expression, t.name, tag, ctx);
      return;
    }

    // R7: `if (x === null) <exit>` -> `const v = x orelse <exit>;` for
    // property-access and local/param targets alike (`=== undefined` is the
    // same test on undefined-flavored values, per R7c).
    const exitTest = this.emptyTestOf(cond);
    if (
      exitTest &&
      (ts.isPropertyAccessExpression(exitTest.target) || ts.isIdentifier(exitTest.target)) &&
      !stmt.elseStatement &&
      this.alwaysExits(stmt.thenStatement)
    ) {
      const t = this.zTypeOfExpr(exitTest.target, ctx);
      if (t.k === "optional") {
        const exit = this.singleExitText(stmt.thenStatement, ctx);
        // A guard whose narrowed value the rest of the scope never reads
        // must not bind a capture — an unused Zig const is a compile
        // error — so it stays a plain null test (one-statement exits
        // here; multi-statement unread exits ride the generic arm below).
        if (!this.followingReadsTarget(stmt, exitTest.target)) {
          if (exit !== null) {
            this.requireFaithfulEmptyTest(exitTest.target, exitTest.flavor, cond);
            const prop = this.emitExpr(exitTest.target, ctx).code;
            this.push(ctx, `if (${prop} == null) ${exit}`);
            return;
          }
        } else {
          this.requireFaithfulEmptyTest(exitTest.target, exitTest.flavor, cond);
          const prop = this.emitExpr(exitTest.target, ctx).code;
          // A reassigned target cannot narrow through a capture (the capture
          // goes stale at the assignment): keep the plain null test and
          // install the `.?` spelling, whose reads see the live variable and
          // which the assignment path keeps alive across provably non-null
          // writes.
          if (this.assignsTarget([...this.followingStatementsOf(stmt)], exitTest.target)) {
            if (exit !== null) {
              this.push(ctx, `if (${prop} == null) ${exit}`);
            } else {
              this.push(ctx, `if (${prop} == null) {`);
              const sub = this.nestedCtx(ctx);
              const exitStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
              this.emitBlockStatements(exitStmts, sub);
              ctx.lines.push(...sub.lines);
              this.push(ctx, `}`);
            }
            const exitKey = this.narrowKey(exitTest.target);
            if (exitKey !== null) ctx.memberSubst.set(exitKey, `${prop}.?`);
            return;
          }
          const name = this.freshName(ctx, this.narrowHint(exitTest.target));
          if (exit !== null) {
            this.push(ctx, `const ${name} = ${prop} orelse ${exit}`);
          } else {
            // Multi-statement exits (a throw is always two emitted
            // statements) take the block form; the block never falls
            // through, so Zig types it noreturn and the unwrap holds.
            this.push(ctx, `const ${name} = ${prop} orelse {`);
            const sub = this.nestedCtx(ctx);
            const exitStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
            this.emitBlockStatements(exitStmts, sub);
            ctx.lines.push(...sub.lines);
            this.push(ctx, `};`);
          }
          const exitKey = this.narrowKey(exitTest.target);
          if (exitKey !== null) ctx.memberSubst.set(exitKey, name);
          return;
        }
      }
    }

    // R7 dual: `if (x === null) { A } else { <uses x> }` — TS narrows the
    // ELSE branch, so the capture unwraps there and the miss body rides the
    // else arm: `if (x) |v| { <else> } else { <then> }`. Without this the
    // else branch would read fields through the optional — invalid Zig.
    if (
      exitTest &&
      stmt.elseStatement &&
      (ts.isPropertyAccessExpression(exitTest.target) || ts.isIdentifier(exitTest.target)) &&
      this.branchReadsTarget(stmt.elseStatement, exitTest.target)
    ) {
      const t = this.zTypeOfExpr(exitTest.target, ctx);
      const key = this.narrowKey(exitTest.target);
      if (t.k === "optional" && key !== null) {
        this.requireFaithfulEmptyTest(exitTest.target, exitTest.flavor, cond);
        const prop = this.emitExpr(exitTest.target, ctx).code;
        const join = new Set<string>();
        const hitBody = ts.isBlock(stmt.elseStatement) ? stmt.elseStatement.statements : [stmt.elseStatement];
        const missBody = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
        // A branch that reassigns the target before any read could
        // consume a capture takes the plain-test `.?` spelling instead
        // (see captureServesBranch) — a capture would bind unused or go
        // stale behind a join.
        if (this.captureServesBranch(stmt.elseStatement, exitTest.target)) {
          const name = this.freshName(ctx, this.narrowHint(exitTest.target));
          this.push(ctx, `if (${prop}) |${name}| {`);
          const saved = ctx.memberSubst.get(key);
          ctx.memberSubst.set(key, name);
          const sub = this.nestedCtx(ctx);
          this.emitBlockStatements(hitBody, sub, join);
          ctx.lines.push(...sub.lines);
          ctx.memberSubst.delete(key);
          if (saved !== undefined) ctx.memberSubst.set(key, saved);
          this.push(ctx, `} else {`);
          const esub = this.nestedCtx(ctx);
          this.emitBlockStatements(missBody, esub, join);
          ctx.lines.push(...esub.lines);
          this.push(ctx, `}`);
        } else {
          this.push(ctx, `if (${prop} == null) {`);
          const esub = this.nestedCtx(ctx);
          this.emitBlockStatements(missBody, esub, join);
          ctx.lines.push(...esub.lines);
          this.push(ctx, `} else {`);
          const saved = ctx.memberSubst.get(key);
          ctx.memberSubst.set(key, `${prop}.?`);
          const sub = this.nestedCtx(ctx);
          this.emitBlockStatements(hitBody, sub, join);
          ctx.lines.push(...sub.lines);
          ctx.memberSubst.delete(key);
          if (saved !== undefined) ctx.memberSubst.set(key, saved);
          this.push(ctx, `}`);
        }
        this.applyJoinedNarrowKills(ctx, join);
        // A miss branch that always exits narrows everything AFTER the if
        // too (TS's control-flow narrowing): reads there unwrap through the
        // safety-checked `.?` — provably non-null, the miss path returned.
        // UNLESS the surviving arm killed the target: tsc's post-if state
        // is the guard-implied narrow MINUS the joined kills, so a killed
        // key stays dead and the code after re-checks instead.
        if (
          !join.has(key) &&
          this.alwaysExits(stmt.thenStatement) &&
          this.followingReadsTarget(stmt, exitTest.target)
        ) {
          ctx.memberSubst.set(key, `${prop}.?`);
        }
        return;
      }
    }

    // R7: `if (x !== null) <uses x>` -> the payload-capturing `if (x) |v|`,
    // as a one-line return when the branch is a single return, else as the
    // full capture block (the else branch, if any, stays unnarrowed).
    const presentTest = this.emptyTestOf(cond, ts.SyntaxKind.ExclamationEqualsEqualsToken);
    if (
      presentTest &&
      (ts.isPropertyAccessExpression(presentTest.target) || ts.isIdentifier(presentTest.target)) &&
      this.branchReadsTarget(stmt.thenStatement, presentTest.target)
    ) {
      const t = this.zTypeOfExpr(presentTest.target, ctx);
      const key = this.narrowKey(presentTest.target);
      if (t.k === "optional" && key !== null) {
        this.requireFaithfulEmptyTest(presentTest.target, presentTest.flavor, cond);
        const prop = this.emitExpr(presentTest.target, ctx).code;
        // A branch that reassigns the target before any read could
        // consume a capture takes the plain-test `.?` spelling instead
        // (see captureServesBranch) — a capture would bind unused or go
        // stale behind a join; `.?` reads always see the live slot.
        const liveCapture = this.captureServesBranch(stmt.thenStatement, presentTest.target);
        const name = liveCapture ? this.freshName(ctx, this.narrowHint(presentTest.target)) : `${prop}.?`;
        const single = unwrapSingle(stmt.thenStatement);
        if (liveCapture && !stmt.elseStatement && single && ts.isReturnStatement(single)) {
          const saved = ctx.memberSubst.get(key);
          ctx.memberSubst.set(key, name);
          // Probe in a flow scope (see childCtx). Its kills discard both
          // ways: a lines-free probe processed no statements (nothing can
          // kill without lowering lines), and the discarded case re-emits
          // the branch below under the block path's own scope.
          const sub = this.childCtx(ctx);
          const v = this.withNarrowScope(ctx, "merge", () =>
            single.expression ? this.emitReturn(single.expression, sub) : null, new Set());
          ctx.memberSubst.delete(key);
          if (saved !== undefined) ctx.memberSubst.set(key, saved);
          if (sub.lines.length === 0 && v) {
            this.push(ctx, `if (${prop}) |${name}| ${this.returnText(ctx, v, single)}`);
            return;
          }
        }
        const join = new Set<string>();
        this.push(ctx, liveCapture ? `if (${prop}) |${name}| {` : `if (${prop} != null) {`);
        const saved = ctx.memberSubst.get(key);
        ctx.memberSubst.set(key, name);
        const sub = this.nestedCtx(ctx);
        const thenBody = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
        this.emitBlockStatements(thenBody, sub, join);
        ctx.lines.push(...sub.lines);
        ctx.memberSubst.delete(key);
        if (saved !== undefined) ctx.memberSubst.set(key, saved);
        if (stmt.elseStatement) {
          this.push(ctx, `} else {`);
          const esub = this.nestedCtx(ctx);
          const elseBody = ts.isBlock(stmt.elseStatement) ? stmt.elseStatement.statements : [stmt.elseStatement];
          this.emitBlockStatements(elseBody, esub, join);
          ctx.lines.push(...esub.lines);
        }
        this.push(ctx, `}`);
        this.applyJoinedNarrowKills(ctx, join);
        // An else branch that always exits narrows everything AFTER the if
        // too (the mirror of the R7-dual rule above): only the hit path
        // falls through, so reads there unwrap via the safety-checked `.?`
        // — unless that hit path killed the target (post-if state is the
        // narrow minus the joined kills; a killed key re-checks instead).
        if (
          !join.has(key) &&
          stmt.elseStatement &&
          this.alwaysExits(stmt.elseStatement) &&
          this.followingReadsTarget(stmt, presentTest.target)
        ) {
          ctx.memberSubst.set(key, `${prop}.?`);
        }
        return;
      }
    }

    // R7d: null-guarded logical chains (`if (x !== null && x.items.length >
    // 0)`) — capture blocks / `.?` unwraps per position; see the R7d block.
    if (this.tryEmitNullGuardIf(stmt, ctx)) return;

    // An if-statement condition may lower statements (array-method scans
    // like `if (xs.some(...))` bind their loop right before the `if`); the
    // condition is evaluated exactly once, so hoisting preserves semantics.
    // (while/ternary conditions stay statement-free: re-evaluation there
    // could not be hoisted.)
    const condText = this.emitExpr(cond, ctx, { k: "bool" }).code;
    // R13c: a kind guard narrows the branch TS narrows — payload reads map
    // to Zig's safety-checked payload accessors under the matching guard.
    const posGuard = this.kindGuardOf(cond);
    const negGuard = this.kindGuardOf(cond, ts.SyntaxKind.ExclamationEqualsEqualsToken);
    const thenStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
    // Single-return then-branch without else stays on one line when short.
    if (!stmt.elseStatement && thenStmts.length === 1 && ts.isReturnStatement(thenStmts[0])) {
      // Probe in a flow scope (see childCtx). Its kills discard both ways:
      // a lines-free probe processed no statements, and the discarded case
      // re-emits the branch below under the block path's own scope.
      const sub = this.childCtx(ctx);
      const r = thenStmts[0];
      const v = this.withNarrowScope(ctx, "merge", () => this.withKindNarrow(posGuard, ctx, () =>
        r.expression ? this.emitReturn(r.expression, sub) : null,
      ), new Set());
      const text = this.returnText(ctx, v, r);
      if (sub.lines.length === 0 && condText.length + text.length <= 80) {
        this.push(ctx, `if (${condText}) ${text}`);
        return;
      }
    }
    const join = new Set<string>();
    // A tsc-unreachable arm (bare keyword-literal condition — see
    // tscExcludedArm) still emits, but contributes no kills to the join:
    // tsc's CFA excludes the arm, so a kill from it would strip a narrow
    // tsc typed the fall-through reads with (a raw optional read, invalid
    // Zig). Its kills feed a discarded set instead of the join.
    const discard = new Set<string>();
    this.push(ctx, `if (${condText}) {`);
    const sub = this.nestedCtx(ctx);
    const thenJoin = this.tscExcludedArm(stmt, stmt.thenStatement) ? discard : join;
    this.withKindNarrow(posGuard, ctx, () => this.emitBlockStatements(thenStmts, sub, thenJoin));
    ctx.lines.push(...sub.lines);
    if (stmt.elseStatement) {
      if (ts.isIfStatement(stmt.elseStatement)) {
        // else-if chain
        this.push(ctx, `} else ${""}`.trimEnd());
        // Rewrite: emit as `} else if (...) {` by recursing with a marker.
        ctx.lines.pop();
        this.emitElseIf(stmt.elseStatement, ctx, join);
        this.applyJoinedNarrowKills(ctx, join);
        // This exit path narrows like the common tail below: an exiting
        // empty-test arm at the HEAD of a chain still narrows everything
        // after the whole statement (the else-if arms ride the non-empty
        // path), and skipping it here left fall-through reads optional.
        this.applyPostIfNarrow(stmt, exitTest, presentTest, ctx, join);
        return;
      }
      this.push(ctx, `} else {`);
      const esub = this.nestedCtx(ctx);
      const elseStmts = ts.isBlock(stmt.elseStatement) ? stmt.elseStatement.statements : [stmt.elseStatement];
      const elseJoin = this.tscExcludedArm(stmt, stmt.elseStatement) ? discard : join;
      this.withKindNarrow(negGuard, ctx, () => this.emitBlockStatements(elseStmts, esub, elseJoin));
      ctx.lines.push(...esub.lines);
    }
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
    this.applyPostIfNarrow(stmt, exitTest, presentTest, ctx, join);
  }

  /// tsc narrows AFTER an if whose empty-testing arm always exits — only
  /// the non-empty path falls through. The tailored R7 paths in emitIf
  /// return for the shapes where an arm READS the target; these are the
  /// generic leftovers (the miss arm has an else — possibly a whole
  /// else-if chain — or no arm reads the target), so fall-through reads
  /// unwrap via the safety-checked `.?`. Every exit path from emitIf that
  /// finished emitting the statement must apply this — with the
  /// statement's just-joined kill set: tsc's post-if state is the
  /// guard-implied narrow MINUS the arms' kills, so a target a surviving
  /// arm killed stays dead (installing it anyway would resurrect the
  /// narrow the join buried, emitting a `.?` read or test against a slot
  /// that can be null again).
  private applyPostIfNarrow(
    stmt: ts.IfStatement,
    exitTest: { target: ts.Expression; flavor: "null" | "undefined" } | null,
    presentTest: { target: ts.Expression; flavor: "null" | "undefined" } | null,
    ctx: Ctx,
    join: ReadonlySet<string>,
  ): void {
    const postNarrow =
      (exitTest && this.alwaysExits(stmt.thenStatement) ? exitTest : null) ??
      (presentTest && stmt.elseStatement && this.alwaysExits(stmt.elseStatement) ? presentTest : null);
    if (
      postNarrow &&
      (ts.isPropertyAccessExpression(postNarrow.target) || ts.isIdentifier(postNarrow.target)) &&
      this.followingReadsTarget(stmt, postNarrow.target)
    ) {
      const key = this.narrowKey(postNarrow.target);
      if (key === null || join.has(key)) return;
      const t = this.zTypeOfExpr(postNarrow.target, ctx);
      const empties = this.tast.emptiesOf(postNarrow.target);
      // The unfaithful-empty spellings keep their R7c teaching on the
      // paths that emit tests; here the narrow just quietly declines.
      const faithful = postNarrow.flavor === "null" ? !empties.undefined : !empties.null;
      if (t.k === "optional" && faithful) {
        const code = this.emitExpr(postNarrow.target, ctx).code;
        ctx.memberSubst.set(key, `${code}.?`);
      }
    }
  }

  /// Capture-name hint for a narrowed optional target.
  private narrowHint(target: ts.Expression): string {
    if (ts.isPropertyAccessExpression(target)) return zigLocalName(target.name.text);
    if (ts.isIdentifier(target)) return zigLocalName(target.text);
    return "opt";
  }

  /// Whether a guarded branch READS its narrowed target — a Zig capture the
  /// branch never uses would be an unused-capture error, so unread guards
  /// keep the plain `!= null` comparison instead. A plain assignment's
  /// TARGET is not a read: the write goes to the raw slot, never the
  /// capture, so a write-only arm (a pure kill) must decline the capture
  /// form or the capture binds unused.
  private branchReadsTarget(branch: ts.Statement, target: ts.Expression): boolean {
    if (ts.isIdentifier(target)) {
      const decl = this.tast.declarationOf(target);
      if (decl) return this.identifierRead(branch, decl);
    }
    // Property chains compare by declaration-qualified key, never text —
    // a shadowed spelling in a nested callback is not a read (anyReadsKey).
    return this.anyReadsKey([branch], this.narrowKey(target));
  }

  /// identifierUsed, minus references that are the bare TARGET of a plain
  /// `=` assignment (compound assignments and `++`/`--` read the slot and
  /// still count).
  private identifierRead(body: ts.Node, decl: ts.Node): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (
        ts.isIdentifier(n) &&
        this.tast.declarationOf(n) === decl &&
        n.parent !== decl &&
        !(
          ts.isBinaryExpression(n.parent) &&
          n.parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
          n.parent.left === n
        )
      ) {
        found = true;
        return;
      }
      ts.forEachChild(n, visit);
    };
    visit(body);
    return found;
  }

  /// Whether any statement AFTER an early-exit guard reads the guarded
  /// target — the scope a `const v = x orelse <exit>;` capture serves. An
  /// unread capture would be an unused Zig const, a compile error.
  /// Property chains compare by declaration-qualified key (anyReadsKey),
  /// which is inherently boundary-aware — `model.now` is a different key
  /// from `model.nowDurationMs`, and a shadowed spelling in a nested
  /// callback is a different declaration.
  private followingReadsTarget(stmt: ts.IfStatement, target: ts.Expression): boolean {
    const following: ts.Node[] = [...this.followingStatementsOf(stmt)];
    // Flow off the end of a do-while body continues INTO the trailing
    // test (tsc evaluates the condition after the body), and the lowered
    // `if (!(cond)) break;` emits inside the body's narrowing scope — a
    // condition read is a read the guard's capture serves.
    const trailingTest = this.trailingDoWhileTestOf(stmt);
    if (trailingTest !== null) following.push(trailingTest);
    if (following.length === 0) return false;
    if (ts.isIdentifier(target)) {
      const decl = this.tast.declarationOf(target);
      if (decl) return following.some((s) => this.identifierUsed(s, decl));
    }
    return this.anyReadsKey(following, this.narrowKey(target));
  }

  /// The statements after `stmt` in its own list — the scope an early-exit
  /// guard's narrowing serves. A plain lexical block is no flow boundary
  /// (emitStatement flattens it), so the walk continues past it: a guard at
  /// the end of such a block narrows the statements after the BLOCK,
  /// transitively out through enclosing plain blocks.
  private followingStatementsOf(stmt: ts.Statement): readonly ts.Statement[] {
    const parent = stmt.parent;
    if (ts.isBlock(parent) || ts.isSourceFile(parent) || ts.isCaseClause(parent) || ts.isDefaultClause(parent)) {
      const statements = parent.statements;
      const at = statements.indexOf(stmt);
      if (at >= 0) {
        const rest = statements.slice(at + 1);
        if (ts.isBlock(parent) && isPlainLexicalBlock(parent)) {
          return [...rest, ...this.followingStatementsOf(parent)];
        }
        return rest;
      }
    }
    return [];
  }

  /// The do-while trailing test the flow after `stmt` runs into, when that
  /// test actually emits inside the body's narrowing scope — i.e. `stmt`
  /// sits in the body list (transitively through plain lexical blocks) of
  /// a do-while lowered to the `while (true)` + trailing-exit-test form.
  /// The first-pass-flag form (a body binding `continue`) hoists the test
  /// ahead of the body, where a body narrow's capture is out of scope, and
  /// an always-exiting body emits no test at all — both return null, so a
  /// guard read only by the condition binds no capture there (an unused
  /// Zig const is a compile error).
  private trailingDoWhileTestOf(stmt: ts.Statement): ts.Expression | null {
    let cur: ts.Statement = stmt;
    for (;;) {
      const parent: ts.Node = cur.parent;
      if (ts.isBlock(parent) && isPlainLexicalBlock(parent)) {
        cur = parent;
        continue;
      }
      const holder = ts.isBlock(parent) ? parent.parent : parent;
      if (!ts.isDoStatement(holder)) return null;
      // Mirror emitStatement's label derivation: the loop's Zig label
      // exists only when a labeled break/continue references it.
      const label =
        ts.isLabeledStatement(holder.parent) && this.labelReferenced(holder, holder.parent.label.text)
          ? loopLabel(holder.parent.label.text)
          : null;
      if (this.bindsContinue(holder.statement, label)) return null;
      if (this.alwaysExits(holder.statement)) return null;
      return holder.expression;
    }
  }

  /// Every arm of the chain — each else-if body and the final else — is a
  /// SIBLING of the head if's then arm: its merge-class kills collect into
  /// the chain-wide `join` the head applies after the whole statement, so
  /// no arm emits against a preceding arm's kills (they are alternatives,
  /// not a sequence).
  private emitElseIf(stmt: ts.IfStatement, ctx: Ctx, join: Set<string>): void {
    // A chained condition that needs lowered statements cannot sit between
    // `}` and `else if`; open a plain else block and start a fresh if inside.
    // The probe works on a copied name set so it burns no real names, and
    // brackets in a flow scope (see childCtx) — both routes below re-emit
    // the condition for real.
    const probe: Ctx = { ...ctx, lines: [], used: new Set(ctx.used) };
    this.withNarrowScope(ctx, "merge", () => this.emitExpr(stmt.expression, probe, { k: "bool" }), new Set());
    if (probe.lines.length > 0) {
      this.push(ctx, `} else {`);
      const inner = this.nestedCtx(ctx);
      // The nested if is one arm of the enclosing chain: bracket it in a
      // flow scope so its narrows stay contained and its kills join with
      // its siblings' instead of applying mid-chain.
      this.withNarrowScope(ctx, "merge", () => this.emitIf(stmt, inner), join);
      ctx.lines.push(...inner.lines);
      this.push(ctx, `}`);
      return;
    }
    const condText = this.emitCondition(stmt.expression, ctx);
    this.push(ctx, `} else if (${condText}) {`);
    const sub = this.nestedCtx(ctx);
    const thenStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
    // tsc-unreachable arms contribute no kills to the chain's join (see
    // emitIf's discard note; tscExcludedArm).
    this.emitBlockStatements(thenStmts, sub, this.tscExcludedArm(stmt, stmt.thenStatement) ? new Set() : join);
    ctx.lines.push(...sub.lines);
    if (stmt.elseStatement) {
      if (ts.isIfStatement(stmt.elseStatement)) {
        this.emitElseIf(stmt.elseStatement, ctx, join);
        return;
      }
      this.push(ctx, `} else {`);
      const esub = this.nestedCtx(ctx);
      const elseStmts = ts.isBlock(stmt.elseStatement) ? stmt.elseStatement.statements : [stmt.elseStatement];
      this.emitBlockStatements(elseStmts, esub, this.tscExcludedArm(stmt, stmt.elseStatement) ? new Set() : join);
      ctx.lines.push(...esub.lines);
    }
    this.push(ctx, `}`);
  }

  private emitCondition(cond: ts.Expression, ctx: Ctx): string {
    const before = ctx.lines.length;
    const text = this.emitExpr(cond, ctx, { k: "bool" }).code;
    if (ctx.lines.length !== before) this.fail(cond, "condition requiring lowered statements");
    return text;
  }

  /// A guard's exit branch as ONE Zig statement (`return v;`, `break;`,
  /// `continue;`, labeled forms included), or null when it needs a block
  /// (multi-statement bodies; a throw always emits two statements).
  private singleExitText(stmt: ts.Statement, ctx: Ctx): string | null {
    const single = unwrapSingle(stmt);
    if (single && ts.isReturnStatement(single)) {
      if (!single.expression) return this.returnText(ctx, null, single);
      // Probe in a flow scope (see childCtx): a lines-free probe processed
      // no statements, so the discarded kill set is empty; a lines-bearing
      // probe is declined and the caller re-emits under its own scope.
      const sub = this.childCtx(ctx);
      const v = this.withNarrowScope(ctx, "merge", () => this.emitReturn(single.expression!, sub), new Set());
      if (sub.lines.length === 0) return this.returnText(ctx, v, single);
      return null;
    }
    if (single && (ts.isBreakStatement(single) || ts.isContinueStatement(single))) {
      // A break bound to a switch has no one-statement Zig spelling (Zig
      // `break` binds loops); declining here routes it through statement
      // emission, where it stops the build with its teaching.
      if (ts.isBreakStatement(single) && !single.label && this.breakBindsEnclosingSwitch(single)) {
        return null;
      }
      const kw = ts.isBreakStatement(single) ? "break" : "continue";
      return single.label ? `${kw} :${loopLabel(single.label.text)};` : `${kw};`;
    }
    return null;
  }

  /// `x.kind === "tag"` (either operand order) -> the guarded base and tag.
  private kindGuardOf(
    cond: ts.Expression,
    op: ts.SyntaxKind = ts.SyntaxKind.EqualsEqualsEqualsToken,
  ): { base: ts.Expression; tag: string } | null {
    // Wrappers strip exactly as in emptyTestOf: a parenthesized, asserted,
    // or `as`/`satisfies`-cast guard or operand must narrow the same arm
    // the bare spelling does (emission erases every one of them).
    const c = unwrapExpr(cond);
    if (!ts.isBinaryExpression(c) || c.operatorToken.kind !== op) return null;
    const sides: Array<[ts.Expression, ts.Expression]> = [
      [unwrapExpr(c.left), unwrapExpr(c.right)],
      [unwrapExpr(c.right), unwrapExpr(c.left)],
    ];
    for (const [kindSide, litSide] of sides) {
      if (
        ts.isPropertyAccessExpression(kindSide) &&
        kindSide.name.text === "kind" &&
        ts.isStringLiteral(litSide)
      ) {
        return { base: kindSide.expression, tag: litSide.text };
      }
    }
    return null;
  }

  /// R13c: run `emitBranch` with the union narrowed to the guard's arm —
  /// payload reads inside map to Zig's safety-checked payload accessors —
  /// then restore the outer narrowing state.
  private withKindNarrow<T>(
    guard: { base: ts.Expression; tag: string } | null,
    ctx: Ctx,
    emitBranch: () => T,
  ): T {
    if (!guard) return emitBranch();
    // An optional union only reaches a kind guard through a null guard TS
    // accepted, so the narrowed base is the inner union.
    const t = unwrapOptional(this.zTypeOfExpr(guard.base, ctx));
    if (t.k !== "union") return emitBranch();
    const savedSubst = new Map(ctx.memberSubst);
    // stillOptionalSubst rides along: narrowUnion overwrites an optional
    // payload's marker with ITS access spelling, and a marker left out of
    // sync with the restored memberSubst breaks the identity check
    // zTypeOfExpr keys on — a redundant kind guard inside a payload
    // capture would leave the capture looking non-null for the rest of
    // the arm, routing reads around the null-narrowing lowerings.
    const savedStillOptional = new Map(ctx.stillOptionalSubst);
    const savedNarrow = new Map(ctx.narrowedUnion);
    this.pushNarrowKillFrame(ctx);
    this.narrowUnion(guard.base, t.name, guard.tag, ctx);
    try {
      return emitBranch();
    } finally {
      ctx.memberSubst.clear();
      for (const [k, v] of savedSubst) ctx.memberSubst.set(k, v);
      ctx.stillOptionalSubst.clear();
      for (const [k, v] of savedStillOptional) ctx.stillOptionalSubst.set(k, v);
      ctx.narrowedUnion.clear();
      for (const [k, v] of savedNarrow) ctx.narrowedUnion.set(k, v);
      // Assignment kills inside the branch stay dead past this restore
      // (the snapshot would resurrect them; see popNarrowKillFrame).
      this.popNarrowKillFrame(ctx);
    }
  }

  private narrowUnion(expr: ts.Expression, unionName: string, tag: string, ctx: Ctx): void {
    const info = this.table.unions.get(unionName);
    if (!info) return;
    const arm = info.arms.find((a) => a.tag === tag);
    if (!arm) return;
    const baseText = this.emitExpr(expr, ctx).code;
    const key = this.narrowKey(expr);
    if (key === null) return;
    ctx.narrowedUnion.set(key, tag);
    for (const f of arm.fields) {
      const access =
        arm.fields.length === 1 ? `${baseText}.${zigId(tag)}` : `${baseText}.${zigId(tag)}.${fieldName(f)}`;
      ctx.memberSubst.set(`${key}.${f.tsName}`, access);
      // Kind-narrowing selects the arm; it proves nothing about a field
      // that is itself optional — the payload access keeps the optional.
      if (this.fieldZType(f).k === "optional") ctx.stillOptionalSubst.set(`${key}.${f.tsName}`, access);
    }
  }

  // --------------------------------------------------- null-guarded chains
  //
  // R7d: `x !== null && <uses x>` (and the `x === null || <uses x>` dual)
  // narrows exactly like the standalone R7 guards. Three spellings, chosen
  // by position: a boolean VALUE takes the capturing if-expression
  // `(if (x) |v| <rest> else false)`; an if-STATEMENT without an else nests
  // the R7 capture blocks; a branch-bearing if or a ternary keeps the guard
  // as a plain `!= null` comparison and unwraps later reads with `.?` (the
  // short-circuit guards it), because a Zig capture's scope could never
  // reach the branch TS narrows by the same condition.

  /// The conjuncts of a same-operator logical chain, parens unwrapped.
  private flattenLogical(expr: ts.Expression, op: ts.SyntaxKind): ts.Expression[] {
    let e = expr;
    while (ts.isParenthesizedExpression(e)) e = e.expression;
    if (ts.isBinaryExpression(e) && e.operatorToken.kind === op) {
      return [...this.flattenLogical(e.left, op), ...this.flattenLogical(e.right, op)];
    }
    return [e];
  }

  /// A conjunct that null-guards an optional for the rest of the chain:
  /// `x !== null` under `&&`, `x === null` under `||` (either operand order,
  /// and the `undefined` spelling on undefined-flavored values per R7c).
  private nullGuardOf(
    conj: ts.Expression,
    op: ts.SyntaxKind,
    ctx: Ctx,
  ): { target: ts.Expression; flavor: "null" | "undefined" } | null {
    const polarity =
      op === ts.SyntaxKind.AmpersandAmpersandToken
        ? ts.SyntaxKind.ExclamationEqualsEqualsToken
        : ts.SyntaxKind.EqualsEqualsEqualsToken;
    const test = this.emptyTestOf(conj, polarity);
    if (!test) return null;
    if (!ts.isPropertyAccessExpression(test.target) && !ts.isIdentifier(test.target)) return null;
    if (this.zTypeOfExpr(test.target, ctx).k !== "optional") return null;
    return test;
  }

  /// Whether any of the nodes READS the guarded target — declaration
  /// identity for identifiers, declaration-QUALIFIED narrowKeys for
  /// property chains (anyReadsKey). Never source text: a shadowed spelling
  /// inside a nested callback (`xs.map((box) => box.q)`) is not a read of
  /// the outer `box.q`, and matching it by text binds a capture the
  /// declaration-keyed substitution (correctly) never rewrites — a Zig
  /// unused-capture error.
  ///
  /// Reads, not uses (identifierRead, the same judgment branchReadsTarget
  /// and captureServesBranch apply): the bare TARGET of a plain `=`
  /// assignment writes the raw slot, never the capture, so a write-only
  /// occurrence cannot consume a binding — gating a capture on it binds
  /// the capture unused, a Zig error. Compound assignments and `++`/`--`
  /// read the slot and still count. Property-chain targets are immutable
  /// model data, so their key walk needs no write exclusion.
  private anyReadsTarget(nodes: readonly ts.Node[], target: ts.Expression): boolean {
    if (ts.isIdentifier(target)) {
      const decl = this.tast.declarationOf(target);
      if (decl) return nodes.some((n) => this.identifierRead(n, decl));
    }
    return this.anyReadsKey(nodes, this.narrowKey(target));
  }

  /// The property-chain read walk every capture/substitution GATE in the
  /// narrowing machinery uses: visit the nodes' property accesses (and
  /// identifiers, for the no-declaration corner), canonicalize each
  /// through narrowKey, and compare against the target's key — the same
  /// identity the installed substitutions are looked up by, so a gate that
  /// fires here is a gate whose capture WILL be consumed. Wrapper
  /// spellings (`(box.q)`, `box.q!`) match through the key's own
  /// canonicalization; a longer chain (`box.q.name`) matches via its
  /// inner access on the recursive walk.
  private anyReadsKey(nodes: readonly ts.Node[], key: string | null): boolean {
    // A keyless target (see narrowKey) has no reads to serve: nothing can
    // be substituted for it, so every gate over it declines.
    if (key === null) return false;
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if ((ts.isPropertyAccessExpression(n) || ts.isIdentifier(n)) && this.narrowKey(n) === key) {
        found = true;
        return;
      }
      ts.forEachChild(n, visit);
    };
    for (const n of nodes) visit(n);
    return found;
  }

  /// Whether the nodes ASSIGN the guarded local (only identifiers are
  /// assignable — property targets are immutable model data). A capture
  /// would go stale across the assignment, so such guards take the `.?`
  /// unwrap spelling, whose reads always see the live variable.
  private assignsTarget(nodes: readonly ts.Node[], target: ts.Expression): boolean {
    if (!ts.isIdentifier(target)) return false;
    const decl = this.tast.declarationOf(target);
    if (!decl) return false;
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (
        ts.isBinaryExpression(n) &&
        assignmentOps.has(n.operatorToken.kind) &&
        ts.isIdentifier(n.left) &&
        this.tast.declarationOf(n.left) === decl
      ) {
        found = true;
        return;
      }
      if (
        (ts.isPostfixUnaryExpression(n) || ts.isPrefixUnaryExpression(n)) &&
        (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken) &&
        ts.isIdentifier(n.operand) &&
        this.tast.declarationOf(n.operand) === decl
      ) {
        found = true;
        return;
      }
      ts.forEachChild(n, visit);
    };
    for (const n of nodes) visit(n);
    return found;
  }

  /// Whether a guarded branch can bind a Zig CAPTURE for its narrowed
  /// target. tsc keeps the narrow through a provably non-null
  /// reassignment, but a capture goes stale there — the assignment
  /// emitter transitions the substitution to the live-slot `.?` spelling
  /// — so the capture form only holds when every plain `=` assignment to
  /// the target sits at the branch's top statement level (straight-line
  /// flow the transition covers) AND some read precedes the first
  /// assignment to consume the binding. An assignment inside a nested
  /// construct (an if arm, a loop body — whose back edge reaches even
  /// the reads spelled above it) hands the branch to the `.?` spelling
  /// up front, which is valid for every read the guard dominates. A
  /// branch that never assigns the target keeps the capture; property
  /// targets are never assignable.
  private captureServesBranch(branch: ts.Statement, target: ts.Expression): boolean {
    if (!ts.isIdentifier(target)) return true;
    const decl = this.tast.declarationOf(target);
    if (!decl) return true;
    const stmts = ts.isBlock(branch) ? branch.statements : [branch];
    const plainAssignOf = (s: ts.Statement): ts.BinaryExpression | null =>
      ts.isExpressionStatement(s) &&
      ts.isBinaryExpression(s.expression) &&
      s.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isIdentifier(s.expression.left) &&
      this.tast.declarationOf(s.expression.left) === decl
        ? s.expression
        : null;
    let anyAssign = false;
    let readBeforeAssign = false;
    for (const s of stmts) {
      const assign = plainAssignOf(s);
      if (assign) {
        // The RHS evaluates before the write, so its reads still consume
        // the capture.
        if (!anyAssign && this.identifierRead(assign.right, decl)) readBeforeAssign = true;
        anyAssign = true;
        continue;
      }
      if (this.assignsTarget([s], target)) return false;
      if (!anyAssign && this.identifierRead(s, decl)) readBeforeAssign = true;
    }
    return anyAssign ? readBeforeAssign : true;
  }

  /// True when some conjunct null-guards a target a LATER conjunct reads —
  /// the chain needs one of the R7d lowerings to stay valid Zig.
  private chainHasNullGuard(conjuncts: readonly ts.Expression[], op: ts.SyntaxKind, ctx: Ctx): boolean {
    return conjuncts.some((c, i) => {
      const g = this.nullGuardOf(c, op, ctx);
      return g !== null && this.anyReadsTarget(conjuncts.slice(i + 1), g.target);
    });
  }

  /// The VALUE spelling: guards capture through Zig's if-expression, so the
  /// whole chain stays a plain boolean expression (returns, while
  /// conditions, operands).
  private emitNullGuardChainValue(
    conjuncts: readonly ts.Expression[],
    op: ts.SyntaxKind,
    ctx: Ctx,
  ): string {
    const isAnd = op === ts.SyntaxKind.AmpersandAmpersandToken;
    const zop = isAnd ? "and" : "or";
    const emitOne = (n: ts.Expression): string =>
      precedenceParen(n, zop, this.emitExpr(n, ctx, { k: "bool" }).code);
    const c0 = conjuncts[0];
    const rest = conjuncts.slice(1);
    if (rest.length === 0) return emitOne(c0);
    const guard = this.nullGuardOf(c0, op, ctx);
    const guardKey = guard === null ? null : this.narrowKey(guard.target);
    if (guard && guardKey !== null && this.anyReadsTarget(rest, guard.target)) {
      this.requireFaithfulEmptyTest(guard.target, guard.flavor, c0);
      const key = guardKey;
      const prop = this.emitExpr(guard.target, ctx).code;
      const cap = this.freshName(ctx, this.narrowHint(guard.target));
      const saved = ctx.memberSubst.get(key);
      ctx.memberSubst.set(key, cap);
      const inner = this.emitNullGuardChainValue(rest, op, ctx);
      ctx.memberSubst.delete(key);
      if (saved !== undefined) ctx.memberSubst.set(key, saved);
      return `(if (${prop}) |${cap}| ${inner} else ${isAnd ? "false" : "true"})`;
    }
    // A kind guard narrows the rest of the chain, exactly like the pairwise
    // R13c logic the plain path applies.
    const kindGuard = isAnd
      ? this.kindGuardOf(c0)
      : this.kindGuardOf(c0, ts.SyntaxKind.ExclamationEqualsEqualsToken);
    const head = emitOne(c0);
    const tail = this.withKindNarrow(kindGuard, ctx, () => this.emitNullGuardChainValue(rest, op, ctx));
    return `${head} ${zop} ${tail}`;
  }

  /// The BRANCH spelling: the guard stays `!= null` and later reads unwrap
  /// with `.?` (safe under the short-circuit). Substitutions this emits are
  /// recorded in `guards` and left INACTIVE on return — the caller activates
  /// them over the branch TS narrows by the same condition.
  private emitNullGuardChainUnwrap(
    conjuncts: readonly ts.Expression[],
    op: ts.SyntaxKind,
    ctx: Ctx,
    guards: Map<string, string>,
  ): string {
    const isAnd = op === ts.SyntaxKind.AmpersandAmpersandToken;
    const zop = isAnd ? "and" : "or";
    const saved = new Map(ctx.memberSubst);
    this.pushNarrowKillFrame(ctx);
    const emitChain = (conjs: readonly ts.Expression[]): string => {
      const c0 = conjs[0];
      const rest = conjs.slice(1);
      const guard = this.nullGuardOf(c0, op, ctx);
      if (guard) {
        this.requireFaithfulEmptyTest(guard.target, guard.flavor, c0);
        const key = this.narrowKey(guard.target);
        const prop = this.emitExpr(guard.target, ctx).code;
        const head = `${prop} ${isAnd ? "!=" : "=="} null`;
        if (rest.length === 0) return head;
        if (key !== null) {
          ctx.memberSubst.set(key, `${prop}.?`);
          guards.set(key, `${prop}.?`);
        }
        return `${head} ${zop} ${emitChain(rest)}`;
      }
      const head = precedenceParen(c0, zop, this.emitExpr(c0, ctx, { k: "bool" }).code);
      if (rest.length === 0) return head;
      const kindGuard = isAnd
        ? this.kindGuardOf(c0)
        : this.kindGuardOf(c0, ts.SyntaxKind.ExclamationEqualsEqualsToken);
      const tail = this.withKindNarrow(kindGuard, ctx, () => emitChain(rest));
      return `${head} ${zop} ${tail}`;
    };
    const code = emitChain(conjuncts);
    ctx.memberSubst.clear();
    for (const [k, v] of saved) ctx.memberSubst.set(k, v);
    // A conjunct can smuggle statements in (a block-bodied callback, an
    // R10b value-position step); an assignment kill made there must stay
    // dead past this restore (see popNarrowKillFrame).
    this.popNarrowKillFrame(ctx);
    return code;
  }

  /// Run `emit` with the given member substitutions active, then restore.
  private withSubsts<T>(guards: ReadonlyMap<string, string>, ctx: Ctx, emit: () => T): T {
    const saved = new Map(ctx.memberSubst);
    for (const [k, v] of guards) ctx.memberSubst.set(k, v);
    this.pushNarrowKillFrame(ctx);
    try {
      return emit();
    } finally {
      ctx.memberSubst.clear();
      for (const [k, v] of saved) ctx.memberSubst.set(k, v);
      // Assignment kills inside the scope stay dead past this restore
      // (the snapshot would resurrect them; see popNarrowKillFrame).
      this.popNarrowKillFrame(ctx);
    }
  }

  /// Every kind guard among the conjuncts (positive under `&&`, negated
  /// under `||`), for narrowing the branch the whole condition proves.
  private chainKindGuards(
    conjuncts: readonly ts.Expression[],
    op: ts.SyntaxKind,
  ): Array<{ base: ts.Expression; tag: string }> {
    const polarity =
      op === ts.SyntaxKind.AmpersandAmpersandToken
        ? ts.SyntaxKind.EqualsEqualsEqualsToken
        : ts.SyntaxKind.ExclamationEqualsEqualsToken;
    const out: Array<{ base: ts.Expression; tag: string }> = [];
    for (const c of conjuncts) {
      const g = this.kindGuardOf(c, polarity);
      if (g) out.push(g);
    }
    return out;
  }

  /// withKindNarrow over a list of guards.
  private withKindNarrows<T>(
    guards: ReadonlyArray<{ base: ts.Expression; tag: string }>,
    ctx: Ctx,
    emit: () => T,
  ): T {
    if (guards.length === 0) return emit();
    return this.withKindNarrow(guards[0], ctx, () => this.withKindNarrows(guards.slice(1), ctx, emit));
  }

  /// R7d in statement position — see emitIf. Returns true when it handled
  /// the statement.
  private tryEmitNullGuardIf(stmt: ts.IfStatement, ctx: Ctx): boolean {
    const cond = stmt.expression;
    if (!ts.isBinaryExpression(cond)) return false;
    const op = cond.operatorToken.kind;
    if (op !== ts.SyntaxKind.AmpersandAmpersandToken && op !== ts.SyntaxKind.BarBarToken) return false;
    const isAnd = op === ts.SyntaxKind.AmpersandAmpersandToken;
    const conjuncts = this.flattenLogical(cond, op);
    if (conjuncts.length < 2) return false;
    const exitDual = !isAnd && !stmt.elseStatement && this.alwaysExits(stmt.thenStatement);
    const applies = conjuncts.some((c, i) => {
      const g = this.nullGuardOf(c, op, ctx);
      if (!g) return false;
      if (exitDual) return true; // the statements after the exit are narrowed
      const later: ts.Node[] = [...conjuncts.slice(i + 1)];
      const branch = isAnd ? stmt.thenStatement : stmt.elseStatement;
      if (branch) later.push(branch);
      return this.anyReadsTarget(later, g.target);
    });
    if (!applies) return false;

    // Shape A: `if (x !== null && <rest>) <then>` with no else — the R7
    // capture blocks nest around an inner condition.
    if (isAnd && !stmt.elseStatement) {
      const thenBody = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
      const caps: Array<{ key: string; saved: string | undefined }> = [];
      const capLines: Array<{ prop: string; cap: string }> = [];
      let gi = 0;
      while (gi < conjuncts.length) {
        const g = this.nullGuardOf(conjuncts[gi], op, ctx);
        if (!g) break;
        const readers: ts.Node[] = [...conjuncts.slice(gi + 1), stmt.thenStatement];
        if (!this.anyReadsTarget(readers, g.target)) break;
        // A reassigned local cannot narrow through a capture (the capture
        // goes stale); the unwrap spelling below reads the live variable.
        if (this.assignsTarget(readers, g.target)) break;
        const key = this.narrowKey(g.target);
        if (key === null) break;
        this.requireFaithfulEmptyTest(g.target, g.flavor, conjuncts[gi]);
        const prop = this.emitExpr(g.target, ctx).code;
        const cap = this.freshName(ctx, this.narrowHint(g.target));
        caps.push({ key, saved: ctx.memberSubst.get(key) });
        capLines.push({ prop, cap });
        ctx.memberSubst.set(key, cap);
        gi++;
      }
      if (gi > 0) {
        const rest = conjuncts.slice(gi);
        const emitInner = (level: number, cur: Ctx): void => {
          if (level < capLines.length) {
            this.push(cur, `if (${capLines[level].prop}) |${capLines[level].cap}| {`);
            const sub = this.nestedCtx(cur);
            emitInner(level + 1, sub);
            cur.lines.push(...sub.lines);
            this.push(cur, `}`);
            return;
          }
          if (rest.length === 0) {
            this.emitBlockStatements(thenBody, cur);
            return;
          }
          // The remaining conjuncts are one boolean condition (guards inside
          // them compose in value form); their kind guards narrow the body.
          const condText = this.emitNullGuardChainValue(rest, op, cur);
          this.push(cur, `if (${condText}) {`);
          const sub = this.nestedCtx(cur);
          this.withKindNarrows(this.chainKindGuards(rest, op), cur, () =>
            this.emitBlockStatements(thenBody, sub),
          );
          cur.lines.push(...sub.lines);
          this.push(cur, `}`);
        };
        emitInner(0, ctx);
        for (const c of caps) {
          ctx.memberSubst.delete(c.key);
          if (c.saved !== undefined) ctx.memberSubst.set(c.key, c.saved);
        }
        return true;
      }
      // No leading guard to capture (the guard sits mid-chain): fall through
      // to the unwrap spelling below.
    }

    // Shape B: the unwrap spelling — `x != null and <rest with x.?>`, with
    // the same substitutions active over the branch TS narrows (`&&` narrows
    // then; `||` narrows else, and after an exiting then, everything below).
    const guards = new Map<string, string>();
    const condText = this.emitNullGuardChainUnwrap(conjuncts, op, ctx, guards);
    const kindGuards = this.chainKindGuards(conjuncts, op);
    const thenStmts = ts.isBlock(stmt.thenStatement) ? stmt.thenStatement.statements : [stmt.thenStatement];
    const join = new Set<string>();
    this.push(ctx, `if (${condText}) {`);
    const tSub = this.nestedCtx(ctx);
    if (isAnd) {
      this.withSubsts(guards, ctx, () =>
        this.withKindNarrows(kindGuards, ctx, () => this.emitBlockStatements(thenStmts, tSub, join)),
      );
    } else {
      this.emitBlockStatements(thenStmts, tSub, join);
    }
    ctx.lines.push(...tSub.lines);
    if (stmt.elseStatement) {
      this.push(ctx, `} else {`);
      const eSub = this.nestedCtx(ctx);
      const elseStmts = ts.isBlock(stmt.elseStatement) ? stmt.elseStatement.statements : [stmt.elseStatement];
      if (!isAnd) {
        this.withSubsts(guards, ctx, () =>
          this.withKindNarrows(kindGuards, ctx, () => this.emitBlockStatements(elseStmts, eSub, join)),
        );
      } else {
        this.emitBlockStatements(elseStmts, eSub, join);
      }
      ctx.lines.push(...eSub.lines);
    }
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
    if (exitDual) {
      // `if (x === null || <bad>) return ...;` — the code below runs only
      // with x present, so the unwrap substitutions stay active — minus
      // any target the arm killed on a non-leaving exit (a break/continue
      // route merges its kills; the post-statement state subtracts them).
      for (const [k, v] of guards) {
        if (!join.has(k)) ctx.memberSubst.set(k, v);
      }
    }
    return true;
  }

  private emitClassicFor(stmt: ts.ForStatement, ctx: Ctx, label: string | null): void {
    if (
      !stmt.initializer ||
      !ts.isVariableDeclarationList(stmt.initializer) ||
      stmt.initializer.declarations.length === 0 ||
      !stmt.condition ||
      !stmt.incrementor
    ) {
      this.fail(stmt, "classic for loop shape (v1 needs init/cond/increment)");
    }
    // One induction variable is the common shape; `let i = 0, j = n` walks
    // from both ends. Zig scopes the vars to the enclosing block (names are
    // uniqued), which is unobservable — the subset has no closures.
    for (const decl of stmt.initializer.declarations) {
      if (!ts.isIdentifier(decl.name) || !decl.initializer) this.fail(stmt, "for-loop induction variable");
      const name = this.claim(ctx, decl, zigLocalName(decl.name.text));
      ctx.localTypes.set(decl, { k: "number" });
      const cls = this.infer.classOfDecl(decl) ?? "i64";
      const init = this.emitExpr(decl.initializer, ctx).code;
      this.push(ctx, `var ${name}: ${cls} = ${init};`);
    }
    const cond = this.emitCondition(stmt.condition, ctx);
    const inc = this.incrementText(stmt.incrementor, ctx);
    const head = label === null ? "while" : `${label}: while`;
    this.push(ctx, `${head} (${cond}) : (${inc}) {`);
    const sub = this.nestedCtx(ctx);
    const body = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
    this.emitBlockStatements(body, sub);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
  }

  /// R12b: `for (const x of xs)` -> Zig's for-capture loop, `break`/
  /// `continue` included. Array elements capture directly; bytes capture the
  /// u8 and widen into the variable's inferred number class (byte reads are
  /// u8, number slots hold i64/f64 — the same rule as R2 element reads).
  /// `.entries()` has no mapping: the classic loop carries the index.
  private emitForOf(stmt: ts.ForOfStatement, ctx: Ctx, label: string | null): void {
    let iter = stmt.expression;
    while (ts.isParenthesizedExpression(iter)) iter = iter.expression;
    if (
      ts.isCallExpression(iter) &&
      ts.isPropertyAccessExpression(iter.expression) &&
      iter.expression.name.text === "entries"
    ) {
      this.emitForOfEntries(stmt, iter, ctx, label);
      return;
    }
    if (!ts.isVariableDeclarationList(stmt.initializer) || stmt.initializer.declarations.length !== 1) {
      this.fail(stmt, "for...of binding shape (v1 binds one `const` name)");
    }
    if ((stmt.initializer.flags & ts.NodeFlags.Const) === 0) {
      this.fail(stmt.initializer, "for...of with a `let` binding (the element is a per-iteration constant; bind with `const`)");
    }
    const decl = stmt.initializer.declarations[0];
    if (!ts.isIdentifier(decl.name)) this.fail(decl, "destructuring in a for...of binding (v1)");
    const baseT = this.zTypeOfExpr(iter, ctx);
    if (baseT.k !== "slice" && baseT.k !== "bytes") {
      this.fail(stmt, `for...of over ${baseT.k} (v1 iterates arrays and bytes)`);
    }
    // A loop may not change the LENGTH of the array it iterates (push, pop,
    // shift, unshift, splice): the emitted loop walks a snapshot of the
    // filled prefix, while JS checks the live length every step. Fixed-
    // length mutations (indexed writes, fill/reverse/sort) read and write
    // the same live memory in both worlds and stay legal.
    if (ts.isIdentifier(iter)) {
      const iterDecl = this.tast.declarationOf(iter);
      if (iterDecl && ctx.builders.has(iterDecl) && this.mutatesLengthOf(stmt.statement, iterDecl)) {
        this.fail(
          stmt,
          "changing the length of the array this loop iterates (JS would walk the live array; collect into a second builder instead)",
        );
      }
    }
    const base = this.emitExpr(iter, ctx).code;
    const body = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
    const used = this.identifierUsed(stmt.statement, decl);
    const sub = this.nestedCtx(ctx);
    const head = label === null ? "for" : `${label}: for`;
    if (baseT.k === "bytes" && used) {
      // The capture is a u8 byte read; the loop variable is a number slot.
      const cap = this.freshName(sub, `${zigLocalName(decl.name.text)}_byte`);
      this.push(ctx, `${head} (${base}) |${cap}| {`);
      const name = this.claim(sub, decl, zigLocalName(decl.name.text));
      sub.localTypes.set(decl, { k: "number" });
      const cls = this.infer.classOfDecl(decl) ?? "i64";
      const widened = cls === "f64" ? `@as(f64, @floatFromInt(${cap}))` : cap;
      this.push(sub, `const ${name}: ${cls} = ${widened};`);
    } else if (baseT.k === "slice" && used) {
      const cap = this.claim(sub, decl, zigLocalName(decl.name.text));
      sub.localTypes.set(decl, baseT.elem);
      this.push(ctx, `${head} (${base}) |${cap}| {`);
    } else {
      this.push(ctx, `${head} (${base}) |_| {`);
    }
    this.emitBlockStatements(body, sub);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
  }

  /// R12d: `for (const [i, x] of xs.entries())` — the destructured-tuple
  /// loop form ONLY (exactly two identifier bindings, no defaults/rest)
  /// lowers onto Zig's indexed for-capture; the index is the loop index,
  /// integer-classed, and the receiver is evaluated once (JS evaluates the
  /// iterable expression once too). Every other tuple/iterator shape keeps
  /// its tailored teaching.
  private emitForOfEntries(
    stmt: ts.ForOfStatement,
    iter: ts.CallExpression,
    ctx: Ctx,
    label: string | null,
  ): void {
    const teach =
      "`.entries()` in a for...of beyond `for (const [i, x] of xs.entries())` (bind exactly the [index, element] pair, or use a classic `for (let i = 0; ...)` loop)";
    if (iter.arguments.length !== 0) this.fail(iter, teach);
    if (
      !ts.isVariableDeclarationList(stmt.initializer) ||
      stmt.initializer.declarations.length !== 1 ||
      (stmt.initializer.flags & ts.NodeFlags.Const) === 0
    ) {
      this.fail(stmt, teach);
    }
    const decl = stmt.initializer.declarations[0];
    const pattern = decl.name;
    if (
      !ts.isArrayBindingPattern(pattern) ||
      pattern.elements.length !== 2 ||
      !pattern.elements.every(
        (el) =>
          ts.isBindingElement(el) && !el.dotDotDotToken && !el.initializer && ts.isIdentifier(el.name) && !el.propertyName,
      )
    ) {
      this.fail(stmt, teach);
    }
    const arrExpr = (iter.expression as ts.PropertyAccessExpression).expression;
    const baseT = this.zTypeOfExpr(arrExpr, ctx);
    if (baseT.k !== "slice" && baseT.k !== "bytes") {
      this.fail(stmt, `for...of over \`.entries()\` of ${baseT.k} (v1 iterates arrays and bytes)`);
    }
    // Same live-length conservatism as the plain for...of: the emitted loop
    // walks a snapshot of the filled prefix.
    const arrId = unwrapExpr(arrExpr);
    if (ts.isIdentifier(arrId)) {
      const iterDecl = this.tast.declarationOf(arrId);
      if (iterDecl && ctx.builders.has(iterDecl) && this.mutatesLengthOf(stmt.statement, iterDecl)) {
        this.fail(
          stmt,
          "changing the length of the array this loop iterates (JS would walk the live array; collect into a second builder instead)",
        );
      }
    }
    const iEl = pattern.elements[0] as ts.BindingElement;
    const xEl = pattern.elements[1] as ts.BindingElement;
    const base = this.emitExpr(arrExpr, ctx).code;
    const body = ts.isBlock(stmt.statement) ? stmt.statement.statements : [stmt.statement];
    const iUsed = this.identifierUsed(stmt.statement, iEl);
    const xUsed = this.identifierUsed(stmt.statement, xEl);
    const sub = this.nestedCtx(ctx);
    const head = label === null ? "for" : `${label}: for`;
    // Element capture first (Zig binds captures in operand order), then the
    // usize loop index widened into the i64 the subset's numbers live in.
    let xCap = "_";
    if (xUsed && baseT.k === "slice") {
      xCap = this.claim(sub, xEl, zigLocalName((xEl.name as ts.Identifier).text));
      sub.localTypes.set(xEl, baseT.elem);
    } else if (xUsed) {
      xCap = this.freshName(sub, `${zigLocalName((xEl.name as ts.Identifier).text)}_byte`);
    }
    const idxCap = iUsed ? this.freshName(sub, `${zigLocalName((iEl.name as ts.Identifier).text)}_idx`) : "_";
    this.push(ctx, `${head} (${base}, 0..) |${xCap}, ${idxCap}| {`);
    if (iUsed) {
      const iName = this.claim(sub, iEl, zigLocalName((iEl.name as ts.Identifier).text));
      sub.localTypes.set(iEl, { k: "number" });
      const cls = this.infer.classOfDecl(iEl) ?? "i64";
      const widened = cls === "f64" ? `@as(f64, @floatFromInt(${idxCap}))` : `@intCast(${idxCap})`;
      this.push(sub, `const ${iName}: ${cls} = ${widened};`);
    }
    if (xUsed && baseT.k === "bytes") {
      // The capture is a u8 byte read; the loop variable is a number slot.
      const name = this.claim(sub, xEl, zigLocalName((xEl.name as ts.Identifier).text));
      sub.localTypes.set(xEl, { k: "number" });
      const cls = this.infer.classOfDecl(xEl) ?? "i64";
      const widened = cls === "f64" ? `@as(f64, @floatFromInt(${xCap}))` : xCap;
      this.push(sub, `const ${name}: ${cls} = ${widened};`);
    }
    this.emitBlockStatements(body, sub);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
  }

  private incrementText(expr: ts.Expression, ctx: Ctx): string {
    // A comma sequence steps several counters per iteration (`i++, j--`);
    // Zig's continue expression takes the statement block form.
    if (ts.isBinaryExpression(expr) && expr.operatorToken.kind === ts.SyntaxKind.CommaToken) {
      const steps = this.flattenCommas(expr).map((e) => this.incrementText(e, ctx));
      return `{ ${steps.join("; ")}; }`;
    }
    if (
      (ts.isPostfixUnaryExpression(expr) || ts.isPrefixUnaryExpression(expr)) &&
      (expr.operator === ts.SyntaxKind.PlusPlusToken || expr.operator === ts.SyntaxKind.MinusMinusToken) &&
      ts.isIdentifier(expr.operand)
    ) {
      const op = expr.operator === ts.SyntaxKind.PlusPlusToken ? "+=" : "-=";
      return `${this.emitExpr(expr.operand, ctx).code} ${op} 1`;
    }
    if (
      ts.isBinaryExpression(expr) &&
      (expr.operatorToken.kind === ts.SyntaxKind.PlusEqualsToken ||
        expr.operatorToken.kind === ts.SyntaxKind.MinusEqualsToken)
    ) {
      const op = expr.operatorToken.kind === ts.SyntaxKind.PlusEqualsToken ? "+=" : "-=";
      return `${this.emitExpr(expr.left, ctx).code} ${op} ${this.emitExpr(expr.right, ctx).code}`;
    }
    this.fail(expr, "for-loop incrementor shape");
  }

  /// Left-deep comma chains (`a, b, c`) in source order.
  private flattenCommas(expr: ts.Expression): ts.Expression[] {
    if (ts.isBinaryExpression(expr) && expr.operatorToken.kind === ts.SyntaxKind.CommaToken) {
      return [...this.flattenCommas(expr.left), expr.right];
    }
    return [expr];
  }

  // R13: switch on the `kind` discriminant -> switch on the tagged union.
  // R13d: switch on a literal-union VALUE (enum / numeric alias) -> a plain
  // Zig switch over the members.
  private emitSwitch(stmt: ts.SwitchStatement, ctx: Ctx): void {
    const scrutinee = stmt.expression;
    if (!ts.isPropertyAccessExpression(scrutinee) || scrutinee.name.text !== "kind") {
      const t = this.zTypeOfExpr(scrutinee, ctx);
      if (t.k === "enum" || t.k === "numAlias") {
        this.emitValueSwitch(stmt, t, ctx);
        return;
      }
      if (t.k === "number" || t.k === "i64" || t.k === "f64" || t.k === "string") {
        this.emitPlainSwitch(stmt, t, ctx);
        return;
      }
      this.fail(stmt, "switch scrutinee (v1 switches on a union `kind` tag, a literal-union value, or a plain number/string)");
    }
    const baseType = this.zTypeOfExpr(scrutinee.expression, ctx);
    if (baseType.k !== "union") this.fail(stmt, "switch on a non-union tag");
    const info = this.table.unions.get(baseType.name);
    if (!info) this.fail(stmt, `unknown union ${baseType.name}`);
    const base = this.emitExpr(scrutinee.expression, ctx).code;
    const baseKey = this.narrowKey(scrutinee.expression);
    this.push(ctx, `switch (${base}) {`);
    const armCtx = { ...ctx, indent: ctx.indent + 1 };
    const covered = new Set<string>();
    // Clauses are pure siblings — alternatives from the switch's entry
    // state, never a sequence: tsc's noFallthroughCasesInSwitch (on in the
    // subset's program options) rejects a non-empty clause that falls into
    // the next, and label stacking shares ONE body. So each clause's
    // merge-class kills join here and apply only after every clause has
    // emitted (see applyJoinedNarrowKills) — applying them per clause
    // would strip a later clause of a narrowing tsc keeps there.
    const join = new Set<string>();
    let sawDefault = false;
    // Label stacking (`case "a": case "b": body`): JS runs the next body
    // for every stacked label, so the labels coalesce into one Zig arm.
    let pending: string[] = [];
    const clauses = stmt.caseBlock.clauses;
    for (let ci = 0; ci < clauses.length; ci++) {
      const clause = clauses[ci];
      if (ts.isDefaultClause(clause)) {
        // R13e: `default` on a union-kind switch covers the arms no case
        // names — the Zig `else` prong. JS matches it only after every
        // case misses, wherever it sits, so it must be last here (the
        // fallthrough-into-default shape has no clean arm mapping).
        if (ci !== clauses.length - 1) {
          this.fail(clause, "a `default` clause that is not the last clause of a union switch (move it to the end)");
        }
        if (pending.length > 0) {
          this.fail(clause, "case labels falling through into `default` (give them their own body)");
        }
        sawDefault = true;
        const uncoveredArms = info.arms.filter((a) => !covered.has(a.tag));
        let stmts: readonly ts.Statement[] = clause.statements;
        if (stmts.length === 1 && ts.isBlock(stmts[0])) stmts = (stmts[0] as ts.Block).statements;
        const last = stmts[stmts.length - 1];
        if (last && ts.isBreakStatement(last) && !last.label) stmts = stmts.slice(0, -1);
        if (uncoveredArms.length === 0) {
          // Every arm has its own case, so JS can never reach the default —
          // an else prong here would be a Zig "unreachable else" error.
          this.push(armCtx, `// default arm: unreachable (every kind has a case)`);
          continue;
        }
        const sub = this.nestedCtx(armCtx);
        this.emitBlockStatements(stmts, sub, join);
        const single = sub.lines.length === 1 ? sub.lines[0].trim() : null;
        if (single && (single.startsWith("return ") || single.startsWith("break :")) && single.endsWith(";")) {
          const armText = `else => ${single.slice(0, -1)},`;
          if (armText.length + 4 * armCtx.indent <= 100) {
            this.push(armCtx, armText);
            continue;
          }
        }
        this.push(armCtx, `else => {`);
        ctx.lines.push(...sub.lines);
        this.push(armCtx, `},`);
        continue;
      }
      if (!ts.isStringLiteral(clause.expression)) this.fail(clause, "non-literal case label");
      const tag = clause.expression.text;
      covered.add(tag);
      const arm = info.arms.find((a) => a.tag === tag);
      if (!arm) this.fail(clause, `case "${tag}" is not an arm of ${baseType.name}`);
      if (clause.statements.length === 0) {
        pending.push(tag);
        continue;
      }
      let stmts: readonly ts.Statement[] = clause.statements;
      if (stmts.length === 1 && ts.isBlock(stmts[0])) stmts = (stmts[0] as ts.Block).statements;
      // A case-ending `break` closes the TS clause; the Zig arm ends itself.
      const last = stmts[stmts.length - 1];
      if (last && ts.isBreakStatement(last) && !last.label) stmts = stmts.slice(0, -1);

      const sub = this.nestedCtx(armCtx);
      // Payload capture + member substitution for this arm's fields. Field
      // use is judged by the declaration-qualified key the substitutions
      // are installed under — a same-named field of some OTHER value in
      // the body (`box.v` beside payload field `v`) is not a payload read,
      // and binding the capture for it would leave it unused.
      const savedSubst = new Map(ctx.memberSubst);
      const savedStillOptional = new Map(ctx.stillOptionalSubst);
      let capture = "";
      const payloadUsed = baseKey !== null && arm.fields.some((f) =>
        this.anyReadsKey(stmts, `${baseKey}.${f.tsName}`),
      );
      if (pending.length > 0 && payloadUsed) {
        // The shared body would need one capture per differently-shaped
        // payload; give the payload-reading arm its own body instead.
        this.fail(clause, "stacked case labels sharing a body that reads a payload (give the payload arm its own body)");
      }
      if (arm.fields.length === 1 && payloadUsed) {
        const cap = this.freshName(sub, zigLocalName(arm.fields[0].tsName));
        capture = `|${cap}| `;
        sub.memberSubst.set(`${baseKey}.${arm.fields[0].tsName}`, cap);
        // The capture holds the payload AS-IS: an optional field stays
        // optional through it (this is a rename, not a null-narrowing).
        if (this.fieldZType(arm.fields[0]).k === "optional") {
          sub.stillOptionalSubst.set(`${baseKey}.${arm.fields[0].tsName}`, cap);
        }
      } else if (arm.fields.length > 1 && payloadUsed) {
        const cap = this.freshName(sub, zigId(arm.tag));
        capture = `|${cap}| `;
        for (const f of arm.fields) {
          sub.memberSubst.set(`${baseKey}.${f.tsName}`, `${cap}.${fieldName(f)}`);
          if (this.fieldZType(f).k === "optional") {
            sub.stillOptionalSubst.set(`${baseKey}.${f.tsName}`, `${cap}.${fieldName(f)}`);
          }
        }
      }
      this.pushNarrowKillFrame(ctx);
      this.emitBlockStatements(stmts, sub);
      // Restore: captures are arm-scoped, and the still-optional markers
      // stay paired with the substitutions they annotate. Repopulate from
      // the snapshot rather than deleting the arm's additions — a nested
      // switch on the same subject OVERWRITES entries the snapshot already
      // held (its capture shadows the outer one), and a delete-only sweep
      // would leave the inner capture name active after its block closed.
      ctx.memberSubst.clear();
      for (const [k, v] of savedSubst) ctx.memberSubst.set(k, v);
      ctx.stillOptionalSubst.clear();
      for (const [k, v] of savedStillOptional) ctx.stillOptionalSubst.set(k, v);
      // Assignment kills inside the arm join with the sibling clauses'
      // and apply after the last clause (the snapshot above must not
      // resurrect them; see applyJoinedNarrowKills).
      for (const key of this.popNarrowKillFrame(ctx, "drop")) join.add(key);

      const labels = [...pending, tag].map((t) => `.${zigId(t)}`).join(", ");
      pending = [];
      const single = sub.lines.length === 1 ? sub.lines[0].trim() : null;
      if (single && (single.startsWith("return ") || single.startsWith("break :")) && single.endsWith(";")) {
        const armText = `${labels} => ${capture}${single.slice(0, -1)},`;
        if (armText.length + 4 * armCtx.indent <= 100) {
          this.push(armCtx, armText);
          continue;
        }
      }
      this.push(armCtx, `${labels} => ${capture}{`);
      ctx.lines.push(...sub.lines);
      this.push(armCtx, `},`);
    }
    if (pending.length > 0) {
      // Trailing label-only clauses: matching them does nothing in JS.
      this.push(armCtx, `${pending.map((t) => `.${zigId(t)}`).join(", ")} => {},`);
    }
    if (!sawDefault) {
      for (const arm of info.arms) {
        if (!covered.has(arm.tag)) this.fail(stmt, `switch does not cover arm "${arm.tag}" (NS1015)`);
      }
    }
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
  }

  /// R13d: a switch over a literal-union VALUE. Member labels become enum or
  /// integer arms; label-only clauses stack onto the next body (`case "a":
  /// case "b": return x`); a trailing `default` becomes `else`. JS semantics
  /// hold: an uncovered value skips the switch (a partial switch gains an
  /// empty `else` arm), and fallthrough out of a non-empty clause is already
  /// rejected by tsc (noFallthroughCasesInSwitch).
  private emitValueSwitch(
    stmt: ts.SwitchStatement,
    t: (ZType & { k: "enum" }) | (ZType & { k: "numAlias" }),
    ctx: Ctx,
  ): void {
    const base = this.emitExpr(stmt.expression, ctx).code;
    this.push(ctx, `switch (${base}) {`);
    const armCtx = { ...ctx, indent: ctx.indent + 1 };
    const covered = new Set<string>();
    // Clauses are siblings (noFallthroughCasesInSwitch; stacked labels
    // share one body): kills join and apply after the last clause.
    const join = new Set<string>();
    let pending: string[] = [];
    let sawDefault = false;
    let allExit = true;
    const clauses = stmt.caseBlock.clauses;
    clauses.forEach((clause, ci) => {
      let label: string | null = null;
      if (ts.isDefaultClause(clause)) {
        // JS matches `default` only after every case misses, wherever it
        // sits; a non-final default with fallthrough has no clean mapping.
        if (ci !== clauses.length - 1) {
          this.fail(clause, "a `default` clause that is not the last clause of a value switch (move it to the end)");
        }
        if (pending.length > 0) {
          this.fail(clause, "case labels falling through into `default` (give them their own body)");
        }
        sawDefault = true;
      } else if (t.k === "enum") {
        if (!ts.isStringLiteral(clause.expression)) this.fail(clause, "non-literal case label");
        const tag = clause.expression.text;
        if (!t.members.includes(tag)) this.fail(clause, `case "${tag}" is not a member of ${t.name}`);
        if (covered.has(tag)) this.fail(clause, `duplicate case "${tag}" (JS treats it as dead code)`);
        covered.add(tag);
        label = `.${zigId(tag)}`;
      } else {
        const v = this.tast.constEvalNumber(clause.expression);
        if (v === null || !Number.isInteger(v) || Object.is(v, -0)) {
          this.fail(clause, "non-integer case label on a numeric-union switch");
        }
        if (!t.values.includes(v)) this.fail(clause, `case ${v} is not a member of ${t.name}`);
        if (covered.has(String(v))) this.fail(clause, `duplicate case ${v} (JS treats it as dead code)`);
        covered.add(String(v));
        label = String(v);
      }
      let stmts: readonly ts.Statement[] = clause.statements;
      if (stmts.length === 1 && ts.isBlock(stmts[0])) stmts = (stmts[0] as ts.Block).statements;
      if (stmts.length === 0) {
        // A label-only clause falls through onto the next body (empty
        // trailing labels — and an empty default — are JS no-ops).
        if (label) pending.push(label);
        return;
      }
      const exits = this.alwaysExits(stmts[stmts.length - 1]);
      const last = stmts[stmts.length - 1];
      if (last && ts.isBreakStatement(last) && !last.label) stmts = stmts.slice(0, -1);
      if (!exits || (last && ts.isBreakStatement(last))) allExit = false;
      const armLabel = label ? [...pending, label].join(", ") : "else";
      pending = [];
      const sub = this.nestedCtx(armCtx);
      this.emitBlockStatements(stmts, sub, join);
      const single = sub.lines.length === 1 ? sub.lines[0].trim() : null;
      if (single && (single.startsWith("return ") || single.startsWith("break :")) && single.endsWith(";")) {
        const armText = `${armLabel} => ${single.slice(0, -1)},`;
        if (armText.length + 4 * armCtx.indent <= 100) {
          this.push(armCtx, armText);
          return;
        }
      }
      this.push(armCtx, `${armLabel} => {`);
      ctx.lines.push(...sub.lines);
      this.push(armCtx, `},`);
    });
    if (pending.length > 0) this.push(armCtx, `${pending.join(", ")} => {},`);
    if (!sawDefault) {
      const total = t.k === "enum" ? t.members.length : t.values.length;
      // Coverage of the declared members, or of the scrutinee's sound
      // coverage type (valueSwitchCoversScrutineeType — declared-type based,
      // never the raw flow type): either proves the fallthrough arm never
      // runs, and alwaysExits claims terminality off the second, so the
      // emitted shape must close exactly the path the claim closed. When
      // the judgment declines, the else completes (`else => {}`) and the
      // terminality claim declines with it — a reached `unreachable` is
      // never acceptable.
      const coveredByType = covered.size === total || this.valueSwitchCoversScrutineeType(stmt);
      if (t.k === "numAlias") {
        // The Zig scrutinee is an integer type, so an else arm is always
        // required. With every member covered by an exiting arm the else is
        // unreachable by the TypeScript types.
        this.push(armCtx, coveredByType && allExit ? `else => unreachable,` : `else => {},`);
      } else if (covered.size < total) {
        // JS: an uncovered member skips the switch; one the TypeScript
        // types rule out never reaches it.
        this.push(armCtx, coveredByType && allExit ? `else => unreachable,` : `else => {},`);
      }
    }
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
  }

  /// R13f: a switch over a PLAIN number/string value lowers to an if/else
  /// chain with JS strict-equality semantics — NaN matches no case, -0
  /// matches 0, string cases compare contents — and JS case-order
  /// semantics: cases test in source order, `default` matches only after
  /// every case misses wherever it sits, and an EMPTY default stacks onto
  /// the next body (fallthrough out of a non-empty body is already tsc's
  /// noFallthroughCasesInSwitch error).
  private emitPlainSwitch(
    stmt: ts.SwitchStatement,
    t: ZType,
    ctx: Ctx,
  ): void {
    const isString = t.k === "string";
    // The scrutinee evaluates once, like JS's switch expression.
    let sw = this.emitExpr(stmt.expression, ctx).code;
    if (!ts.isIdentifier(unwrapExpr(stmt.expression))) {
      const tmp = this.freshName(ctx, "sw");
      this.push(ctx, `const ${tmp} = ${sw};`);
      sw = tmp;
    }
    const swClass = isString ? null : this.infer.classOfExpr(stmt.expression);
    const caseCond = (caseExpr: ts.Expression): string => {
      const code = this.emitExpr(caseExpr, ctx).code;
      if (isString) {
        if (!this.isStringCase(caseExpr)) {
          this.fail(caseExpr, "a non-string case label on a string switch (JS `===` across types never matches; drop the case)");
        }
        return `strEq(${sw}, ${code})`;
      }
      const folded = this.tast.constEvalNumber(caseExpr);
      if (folded !== null && swClass === "i64" && Number.isInteger(folded) && !Object.is(folded, -0)) {
        return `${sw} == ${code}`;
      }
      if (swClass === "i64" && this.infer.classOfExpr(caseExpr) === "i64" && folded === null) {
        return `${sw} == ${code}`;
      }
      // Mixed or float classes: IEEE f64 equality with exact widening —
      // node's `===` (NaN never matches, -0 == 0).
      return `numEq(${sw}, ${code})`;
    };
    interface PlainArm {
      readonly conds: string[];
      readonly stmts: readonly ts.Statement[];
      alsoDefault: boolean;
    }
    const arms: PlainArm[] = [];
    let pending: string[] = [];
    let pendingDefault = false;
    let sawDefault = false;
    const clauses = stmt.caseBlock.clauses;
    for (const clause of clauses) {
      if (ts.isDefaultClause(clause)) {
        sawDefault = true;
        if (clause.statements.length === 0) {
          // An empty default stacks onto the next body (JS fallthrough).
          pendingDefault = true;
          continue;
        }
      } else if (clause.statements.length === 0) {
        pending.push(caseCond(clause.expression));
        continue;
      }
      let stmts: readonly ts.Statement[] = clause.statements;
      if (stmts.length === 1 && ts.isBlock(stmts[0])) stmts = (stmts[0] as ts.Block).statements;
      const last = stmts[stmts.length - 1];
      if (last && ts.isBreakStatement(last) && !last.label) stmts = stmts.slice(0, -1);
      this.forbidEarlyBreak(stmts);
      const conds = ts.isDefaultClause(clause) ? pending : [...pending, caseCond(clause.expression)];
      pending = [];
      const arm: PlainArm = { conds, stmts, alsoDefault: pendingDefault || ts.isDefaultClause(clause) };
      pendingDefault = false;
      arms.push(arm);
    }
    // Trailing label-only clauses (and a trailing empty default): JS no-ops.
    const defaultArm = arms.find((a) => a.alsoDefault) ?? null;
    // The lowered if/else chain's arms are the switch's clauses — siblings
    // (noFallthroughCasesInSwitch): kills join and apply after the chain.
    const join = new Set<string>();
    let opened = false;
    for (const arm of arms) {
      if (arm.conds.length === 0) continue; // a pure default arm emits as the else below
      const cond = arm.conds.join(" or ");
      this.push(ctx, `${opened ? "} else " : ""}if (${cond}) {`);
      const sub = this.nestedCtx(ctx);
      this.emitBlockStatements(arm.stmts, sub, join);
      ctx.lines.push(...sub.lines);
      opened = true;
    }
    if (defaultArm && opened) {
      this.push(ctx, `} else {`);
      const sub = this.nestedCtx(ctx);
      this.emitBlockStatements(defaultArm.stmts, sub, join);
      ctx.lines.push(...sub.lines);
    } else if (defaultArm) {
      // Every case label was empty-trailing (or none existed): the default
      // body runs unconditionally — straight-line flow, so its kills merge
      // as usual rather than joining with the (nonexistent) other arms.
      const sub = this.childCtx(ctx);
      this.emitBlockStatements(defaultArm.stmts, sub);
      ctx.lines.push(...sub.lines);
      this.applyJoinedNarrowKills(ctx, join);
      return;
    }
    if (opened) this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
    if (sawDefault && !defaultArm && clauses.length > 0) {
      // A trailing empty default is a JS no-op; nothing to emit.
    }
  }

  /// String-valued case label check for the plain string switch — the only
  /// case values whose `===` can match a string scrutinee.
  private isStringCase(e: ts.Expression): boolean {
    const u = unwrapExpr(e);
    if (ts.isStringLiteral(u) || ts.isNoSubstitutionTemplateLiteral(u)) return true;
    return (this.tast.typeOf(u).flags & (ts.TypeFlags.String | ts.TypeFlags.StringLiteral)) !== 0;
  }

  /// Plain-value switch clauses map to exclusive if/else arms, so only a
  /// TRAILING `break` (already stripped) has a mapping; an early break
  /// inside the clause body would need a jump the chain does not have.
  private forbidEarlyBreak(stmts: readonly ts.Statement[]): void {
    const visit = (n: ts.Node): void => {
      if (
        ts.isForStatement(n) ||
        ts.isForOfStatement(n) ||
        ts.isWhileStatement(n) ||
        ts.isDoStatement(n) ||
        ts.isSwitchStatement(n)
      ) {
        return; // breaks inside these target them, not the switch
      }
      if (ts.isBreakStatement(n) && !n.label) {
        this.fail(n, "an early `break` inside a plain-value switch clause (end the clause with a single trailing `break` or a `return`)");
      }
      ts.forEachChild(n, visit);
    };
    for (const s of stmts) visit(s);
  }

  /// Layer-3 ownership for indexed writes: `xs[i] = v` (and the compound
  /// and `++`/`--` forms) mutates the array like the methods do, so the base
  /// must be a still-owned local. The append idiom (`xs[xs.length] = v`,
  /// which grows in JS) teaches push; other out-of-bounds writes make a JS
  /// sparse array (NS1012 territory) and trap on the emitted bounds check.
  private guardElementWrite(target: ts.ElementAccessExpression, site: ts.Node, ctx: Ctx): void {
    const baseT = this.zTypeOfExpr(target.expression, ctx);
    if (baseT.k !== "slice") return;
    const baseId = unwrapExpr(target.expression);
    const verdict = arrayOwnership(this.tast, target.expression, site);
    if (!verdict.owned) {
      this.fail(
        site,
        `an indexed write to an array this function does not own — ${verdict.detail} (copy with \`.slice()\` first, or build the next value immutably)`,
        verdict.why === "escaped" ? "NS1051" : "NS1001",
      );
    }
    if (this.appendWriteBase(target) !== null) {
      // Only the plain `=` growth shape lowers as a push (handled before
      // this guard); compound forms read the out-of-bounds slot first.
      this.fail(site, "an appending write outside the plain `=` form (`xs[xs.length] = v` appends; a compound form reads the missing slot first — JS undefined)");
    }
    const decl = ts.isIdentifier(baseId) ? this.tast.declarationOf(baseId) : undefined;
    if (decl && ts.isVariableDeclaration(decl) && this.isReassigned(decl, ctx) && !this.isReassignedOwning(decl)) {
      this.fail(site, "an indexed write through a reassigned binding whose assignments are not all fresh constructions (keep the owned array in one binding, or assign only literals/copies)");
    }
  }

  /// R17m: every assignment to the binding installs a fresh owning
  /// construction — the flow-sensitive ownership rule's emitter mirror.
  private isReassignedOwning(decl: ts.VariableDeclaration): boolean {
    const fn = enclosingFunctionOf(decl);
    return (
      fn !== null &&
      decl.initializer !== undefined &&
      isOwningInitializer(decl.initializer) &&
      everyAssignmentOwning(this.tast, decl, fn)
    );
  }

  private emitExpressionStatement(expr: ts.Expression, ctx: Ctx): void {
    // R17m: `xs[xs.length] = v` on an owned array IS a push — the one
    // growth shape (compound forms read the out-of-bounds slot first and
    // keep the teach below).
    if (
      ts.isBinaryExpression(expr) &&
      expr.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isElementAccessExpression(expr.left) &&
      this.appendWriteBase(expr.left) !== null &&
      this.zTypeOfExpr(expr.left.expression, ctx).k === "slice"
    ) {
      const baseId = this.appendWriteBase(expr.left)!;
      const decl = this.tast.declarationOf(baseId);
      const builder = decl ? ctx.builders.get(decl) : undefined;
      if (builder) {
        const verdict = arrayOwnership(this.tast, expr.left.expression, expr);
        if (!verdict.owned) {
          this.fail(
            expr,
            `an appending write to an array this function does not own — ${verdict.detail}`,
            verdict.why === "escaped" ? "NS1051" : "NS1001",
          );
        }
        const v = this.emitExpr(expr.right, ctx, this.elemZType(builder.elem)).code;
        this.push(
          ctx,
          `if (${builder.len} == ${builder.slice}.len) ${builder.slice} = rt.frameGrow(${builder.elemRef}, ${builder.slice});`,
        );
        this.push(ctx, `${builder.slice}[${builder.len}] = ${v};`);
        this.push(ctx, `${builder.len} += 1;`);
        return;
      }
    }
    if (
      ts.isBinaryExpression(expr) &&
      ts.isElementAccessExpression(expr.left) &&
      expr.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      expr.operatorToken.kind <= ts.SyntaxKind.LastAssignment
    ) {
      this.guardElementWrite(expr.left, expr, ctx);
    }
    // R17m: a reassignment of a builder-backed owning binding resets the
    // slice and the fill count (every assignment is a fresh owning
    // construction, so the binding stays owned).
    if (
      ts.isBinaryExpression(expr) &&
      expr.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isIdentifier(expr.left)
    ) {
      const decl = this.tast.declarationOf(expr.left);
      const builder = decl && ts.isVariableDeclaration(decl) ? ctx.builders.get(decl) : undefined;
      if (builder) {
        let rhs = unwrapExpr(expr.right);
        if (ts.isArrayLiteralExpression(rhs) && rhs.elements.length === 0) {
          this.push(ctx, `${builder.slice} = rt.frameAlloc(${builder.elemRef}, 0);`);
          this.push(ctx, `${builder.len} = 0;`);
          return;
        }
        const t = ctx.localTypes.get(decl!) ?? this.zTypeOfExpr(expr.right, ctx);
        const v = this.emitExpr(expr.right, ctx, t).code;
        this.push(ctx, `${builder.slice} = ${v};`);
        this.push(ctx, `${builder.len} = ${builder.slice}.len;`);
        return;
      }
    }
    if (
      (ts.isPostfixUnaryExpression(expr) || ts.isPrefixUnaryExpression(expr)) &&
      ts.isElementAccessExpression(expr.operand)
    ) {
      this.guardElementWrite(expr.operand, expr, ctx);
    }
    if (ts.isBinaryExpression(expr)) {
      const op = expr.operatorToken.kind;
      if (op === ts.SyntaxKind.EqualsToken) {
        // The RHS still sees the pre-assignment narrowing; the TARGET is the
        // raw slot (never a `.?`/capture substitution — the write goes to
        // the variable itself). When the assigned value can be null, the
        // narrowing dies with the assignment, exactly like TS.
        const t = this.zTypeOfExprClassed(expr.left, ctx);
        const v = this.emitExpr(expr.right, ctx, t, undefined);
        const key = this.narrowKey(expr.left);
        const hadSubst = key === null ? undefined : ctx.memberSubst.get(key);
        if (key !== null && hadSubst !== undefined) ctx.memberSubst.delete(key);
        const target = this.emitExpr(expr.left, ctx).code;
        const empties = this.tast.emptiesOf(expr.right);
        const mayBeEmpty = empties.null || empties.undefined;
        if (key !== null && hadSubst !== undefined && hadSubst.endsWith(".?") && !mayBeEmpty) {
          // `.?` substitutions read the live variable, so they survive an
          // assignment of a provably non-null value.
          ctx.memberSubst.set(key, hadSubst);
        } else if (
          key !== null &&
          hadSubst !== undefined &&
          !mayBeEmpty &&
          hadSubst !== ctx.stillOptionalSubst.get(key) &&
          this.zTypeOfExpr(expr.left, ctx).k === "optional"
        ) {
          // A capture substitution would read the stale capture, but tsc
          // keeps the target narrowed through a provably non-null
          // assignment — so the substitution TRANSITIONS to the live-slot
          // `.?` spelling from this point onward: still narrowed, reads go
          // through the reassigned slot. (The still-optional renames are
          // payload aliases, not null-narrows; they have no `.?` form.)
          ctx.memberSubst.set(key, `${target}.?`);
        }
        if (key !== null && !ctx.memberSubst.has(key) && (hadSubst !== undefined || mayBeEmpty)) {
          // The narrowing died with this assignment (the value may be null
          // again, or the substitution has no live-slot form to transition
          // to). Record the kill so scope
          // exits, whose snapshot restores give containment, do not
          // resurrect it past the merge — and record it even when NO
          // substitution was live: a construct's post-exit narrow
          // (applyPostIfNarrow and kin) subtracts the joined kills, and
          // tsc buries the guard-implied narrow for every possibly-null
          // assignment an arm makes, active substitution or not.
          ctx.narrowKilled[ctx.narrowKilled.length - 1]?.add(key);
        }
        this.push(ctx, `${target} = ${this.byteStoreNarrowed(expr, v.code, ctx)};`);
        return;
      }
      if (op === ts.SyntaxKind.PlusEqualsToken || op === ts.SyntaxKind.MinusEqualsToken) {
        const target = this.emitExpr(expr.left, ctx).code;
        const v = this.emitExpr(expr.right, ctx).code;
        this.push(ctx, `${target} ${op === ts.SyntaxKind.PlusEqualsToken ? "+=" : "-="} ${v};`);
        return;
      }
      // R16b: the remaining compound assignments, each `x op= v` exactly
      // `x = x op v` (JS evaluates the target reference once; the subset's
      // targets are plain locals/fields, so re-spelling it is the same).
      if (op === ts.SyntaxKind.AsteriskEqualsToken || op === ts.SyntaxKind.SlashEqualsToken) {
        const target = this.emitExpr(expr.left, ctx).code;
        let v = this.emitExpr(expr.right, ctx).code;
        // `/=` is float always (like `/`); `*=` widens only into a float slot.
        if (op === ts.SyntaxKind.SlashEqualsToken || this.infer.classOfExpr(expr.left) === "f64") {
          v = this.widenToF64(expr.right, v, ctx);
        }
        this.push(ctx, `${target} ${op === ts.SyntaxKind.AsteriskEqualsToken ? "*=" : "/="} ${v};`);
        return;
      }
      if (op === ts.SyntaxKind.PercentEqualsToken) {
        // JS %= is the truncated remainder — @rem, same policy as binary %.
        const target = this.emitExpr(expr.left, ctx).code;
        let v = this.emitExpr(expr.right, ctx).code;
        let t = target;
        if (this.infer.classOfExpr(expr.left) === "f64" || this.infer.classOfExpr(expr.right) === "f64") {
          v = this.widenToF64(expr.right, v, ctx);
          t = this.widenToF64(expr.left, t, ctx);
        }
        this.push(ctx, `${target} = @rem(${t}, ${v});`);
        return;
      }
      if (op === ts.SyntaxKind.AsteriskAsteriskEqualsToken) {
        const target = this.emitExpr(expr.left, ctx).code;
        const t = this.widenToF64(expr.left, target, ctx);
        const v = this.widenToF64(expr.right, this.emitExpr(expr.right, ctx).code, ctx);
        this.push(ctx, `${target} = jsPow(${t}, ${v});`);
        return;
      }
      const bitCompound: Partial<Record<ts.SyntaxKind, string>> = {
        [ts.SyntaxKind.AmpersandEqualsToken]: "jsAnd",
        [ts.SyntaxKind.BarEqualsToken]: "jsOr",
        [ts.SyntaxKind.CaretEqualsToken]: "jsXor",
        [ts.SyntaxKind.LessThanLessThanEqualsToken]: "jsShl",
        [ts.SyntaxKind.GreaterThanGreaterThanEqualsToken]: "jsShr",
        [ts.SyntaxKind.GreaterThanGreaterThanGreaterThanEqualsToken]: "jsUshr",
      };
      const bitHelper = bitCompound[op];
      if (bitHelper) {
        const target = this.emitExpr(expr.left, ctx).code;
        const v = this.emitExpr(expr.right, ctx).code;
        this.push(ctx, `${target} = ${bitHelper}(${target}, ${v});`);
        return;
      }
      if (op === ts.SyntaxKind.AmpersandAmpersandEqualsToken || op === ts.SyntaxKind.BarBarEqualsToken) {
        // `x &&= v` assigns only when x is true (and `||=` only when false),
        // evaluating v only then — exactly the guarded assignment.
        const t = this.zTypeOfExpr(expr.left, ctx);
        if (t.k !== "bool") {
          this.fail(expr, `\`${op === ts.SyntaxKind.AmpersandAmpersandEqualsToken ? "&&=" : "||="}\` on a non-boolean (v1 guards booleans; spell other flows with if)`);
        }
        const target = this.emitExpr(expr.left, ctx).code;
        const v = this.emitExpr(expr.right, ctx, { k: "bool" }).code;
        const guard = op === ts.SyntaxKind.AmpersandAmpersandEqualsToken ? target : `!${maybeParen(target)}`;
        this.push(ctx, `if (${guard}) ${target} = ${v};`);
        return;
      }
      if (op === ts.SyntaxKind.QuestionQuestionEqualsToken) {
        // `x ??= v` assigns only when x is empty — the optional's null.
        const t = this.zTypeOfExprClassed(expr.left, ctx);
        if (t.k !== "optional") {
          this.fail(expr, "`??=` on a value that can never be null (assign directly, or type the slot `T | null`)");
        }
        const target = this.emitExpr(expr.left, ctx).code;
        const v = this.emitExpr(expr.right, ctx, t).code;
        this.push(ctx, `if (${target} == null) ${target} = ${v};`);
        return;
      }
    }
    if (
      (ts.isPostfixUnaryExpression(expr) || ts.isPrefixUnaryExpression(expr)) &&
      (expr.operator === ts.SyntaxKind.PlusPlusToken || expr.operator === ts.SyntaxKind.MinusMinusToken)
    ) {
      const target = this.emitExpr(expr.operand as ts.Expression, ctx).code;
      this.push(ctx, `${target} ${expr.operator === ts.SyntaxKind.PlusPlusToken ? "+=" : "-="} 1;`);
      return;
    }
    if (ts.isCallExpression(expr)) {
      if (this.tryEmitPushCall(expr, ctx)) return;
      if (this.tryEmitMutatingCall(expr, ctx)) return;
      const lowered = this.tryEmitSetCall(expr, ctx);
      if (lowered) return;
      const v = this.emitExpr(expr, ctx);
      this.push(ctx, `_ = ${v.code};`);
      return;
    }
    this.fail(expr, `expression statement kind ${ts.SyntaxKind[expr.kind]}`);
  }

  /// A store into a `Uint8Array` element (`buf[i] = v`) narrows i64 to the
  /// u8 slot with JS's exact ToUint8 semantics — modulo 256, negatives
  /// wrapping (`buf[i] = -1` stores 255 under node) — via a two's-complement
  /// truncate. Comptime-known in-range values coerce on their own and stay
  /// untouched, so existing emissions are byte-identical.
  private byteStoreNarrowed(expr: ts.BinaryExpression, code: string, ctx: Ctx): string {
    if (!ts.isElementAccessExpression(expr.left)) return code;
    if (this.zTypeOfExpr(expr.left.expression, ctx).k !== "bytes") return code;
    const folded = this.tast.constEvalNumber(expr.right);
    if (folded !== null && Number.isInteger(folded) && folded >= 0 && folded <= 255) return code;
    return `@as(u8, @truncate(@as(u64, @bitCast(${code}))))`;
  }

  /// Whether the enclosing function ever mutates the class instance bound
  /// to `decl` — a field write through the binding, a `++`/`--` on a field,
  /// or a call of a mutating method (R19's `var` trigger).
  private instanceMutationsExist(decl: ts.VariableDeclaration): boolean {
    const fn = enclosingFunctionOf(decl);
    if (!fn) return false;
    const isTarget = (e: ts.Expression): boolean => {
      const u = unwrapExpr(e);
      return ts.isIdentifier(u) && this.tast.declarationOf(u) === decl;
    };
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (
        ts.isBinaryExpression(n) &&
        n.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
        n.operatorToken.kind <= ts.SyntaxKind.LastAssignment &&
        ts.isPropertyAccessExpression(n.left) &&
        isTarget(n.left.expression)
      ) {
        found = true;
      } else if (
        (ts.isPostfixUnaryExpression(n) || ts.isPrefixUnaryExpression(n)) &&
        (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken) &&
        ts.isPropertyAccessExpression(n.operand) &&
        isTarget(n.operand.expression)
      ) {
        found = true;
      } else if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && isTarget(n.expression.expression)) {
        const mDecl = this.tast.declarationOf(n.expression.name);
        if (mDecl && ts.isMethodDeclaration(mDecl) && ts.isClassDeclaration(mDecl.parent) && mDecl.parent.name) {
          const cls = this.table.classes.get(mDecl.parent.name.text);
          if (cls && cls.mutating.has(n.expression.name.text)) found = true;
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(fn);
    return found;
  }

  /// Every owned-mutating method invoked on a local anywhere in its
  /// enclosing function — the trigger for the builder lowering (R17k).
  /// Whether the function body writes THROUGH a bytes parameter —
  /// `out.set(...)`/`fill`/`copyWithin`/`sort`/`reverse`, or an indexed
  /// store `out[i] = ...`. Such a parameter must emit as `[]u8`: the
  /// writes lower to `@memcpy`/element stores, and a `[]const u8` target
  /// is "cannot copy to constant pointer" at compile time (release-mode
  /// app builds were the first to analyze the path in the wave-2 trials).
  private paramBytesWritten(root: ts.Node, p: ts.ParameterDeclaration): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
        const base = unwrapExpr(n.expression.expression);
        if (
          bytesWritingMethods.has(n.expression.name.text) &&
          ts.isIdentifier(base) &&
          this.tast.declarationOf(base) === p
        ) {
          found = true;
          return;
        }
      }
      const target =
        ts.isBinaryExpression(n) && assignmentOps.has(n.operatorToken.kind)
          ? n.left
          : (ts.isPostfixUnaryExpression(n) || ts.isPrefixUnaryExpression(n)) &&
              (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken)
            ? n.operand
            : null;
      if (target && ts.isElementAccessExpression(target)) {
        const base = unwrapExpr(target.expression);
        if (ts.isIdentifier(base) && this.tast.declarationOf(base) === p) {
          found = true;
          return;
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(root);
    return found;
  }

  /// The parameter's emitted Zig type: `typeRefWithNumbers`, except a
  /// bytes parameter the body writes through drops const-ness.
  private paramTypeRef(p: ts.ParameterDeclaration, t: ZType, body: ts.Node | undefined): string {
    if (t.k === "bytes" && body && this.paramBytesWritten(body, p)) return "[]u8";
    return this.typeRefWithNumbers(t, p);
  }

  private mutationsOf(decl: ts.VariableDeclaration): Set<string> {
    const out = new Set<string>();
    const fn = enclosingFunctionOf(decl);
    if (!fn) return out;
    const visit = (n: ts.Node): void => {
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
        const method = n.expression.name.text;
        const base = unwrapExpr(n.expression.expression);
        if (ownedMutatingMethods.has(method) && ts.isIdentifier(base) && this.tast.declarationOf(base) === decl) {
          out.add(method);
        }
      }
      // `xs[xs.length] = v` IS a push (the one growth shape) — it forces
      // the builder lowering exactly like the method spelling.
      if (
        ts.isBinaryExpression(n) &&
        n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isElementAccessExpression(n.left) &&
        this.appendWriteBase(n.left) !== null
      ) {
        const base = unwrapExpr(n.left.expression);
        if (ts.isIdentifier(base) && this.tast.declarationOf(base) === decl) out.add("push");
      }
      ts.forEachChild(n, visit);
    };
    visit(fn);
    return out;
  }

  /// `xs[xs.length]` — the JS growth shape: the indexed base when the index
  /// is exactly the same identifier's `.length`, else null.
  private appendWriteBase(target: ts.ElementAccessExpression): ts.Identifier | null {
    const idx = unwrapExpr(target.argumentExpression);
    const baseId = unwrapExpr(target.expression);
    if (
      ts.isPropertyAccessExpression(idx) &&
      idx.name.text === "length" &&
      ts.isIdentifier(baseId) &&
      ts.isIdentifier(unwrapExpr(idx.expression)) &&
      this.tast.declarationOf(unwrapExpr(idx.expression) as ts.Identifier) === this.tast.declarationOf(baseId)
    ) {
      return baseId;
    }
    return null;
  }

  /// Whether any length-changing mutation of `decl` occurs under `root` —
  /// the guard for loops and callbacks iterating the array (the emitted loop
  /// walks a snapshot of the filled prefix; JS walks the live array).
  private mutatesLengthOf(root: ts.Node, decl: ts.Node): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
        const base = unwrapExpr(n.expression.expression);
        if (
          lengthChangingMethods.has(n.expression.name.text) &&
          ts.isIdentifier(base) &&
          this.tast.declarationOf(base) === decl
        ) {
          found = true;
          return;
        }
      }
      ts.forEachChild(n, visit);
    };
    visit(root);
    return found;
  }

  /// Whether any identifier under `root` references `decl`.
  private referencesDecl(root: ts.Node, decl: ts.Node): boolean {
    let found = false;
    const visit = (n: ts.Node): void => {
      if (found) return;
      if (ts.isIdentifier(n) && this.tast.declarationOf(n) === decl) {
        found = true;
        return;
      }
      ts.forEachChild(n, visit);
    };
    visit(root);
    return found;
  }

  /// The mutation target of a mutating method call: the builder entry for
  /// length-changing lowerings, or the plain arena slice for fixed-length
  /// mutations on owned locals. Everything else is a taught stop — the
  /// layer-3 re-derivation of the ownership rule (NS1001/NS1022/NS1051).
  private mutationTarget(
    expr: ts.CallExpression,
    baseExpr: ts.Expression,
    method: string,
    ctx: Ctx,
  ): {
    readonly builder: { slice: string; len: string; elemRef: string; elem: ZType; growable: boolean } | null;
    readonly raw: string;
    readonly len: string;
    readonly elemRef: string;
    readonly elemT: ZType;
  } {
    const base = unwrapExpr(baseExpr);
    const decl = ts.isIdentifier(base) ? this.tast.declarationOf(base) : undefined;
    const builder = decl ? ctx.builders.get(decl) : undefined;
    if (builder) {
      return {
        builder,
        raw: builder.slice,
        len: builder.len,
        elemRef: builder.elemRef,
        elemT: this.elemZType(builder.elem),
      };
    }
    // No builder: re-derive the ownership verdict so the stop teaches the
    // boundary (never a generic internal error).
    const verdict = arrayOwnership(this.tast, baseExpr, expr);
    if (!verdict.owned) {
      this.fail(
        expr,
        `\`.${method}\` on an array this function does not own — ${verdict.detail} (create the array here: \`const out: T[] = []\`, or copy with \`.slice()\`, and finish mutating before it escapes; shared arrays update immutably: spread \`[...xs, x]\`, sort with \`.toSorted\`)`,
        verdict.why === "escaped" ? "NS1051" : method === "sort" ? "NS1022" : "NS1001",
      );
    }
    if (decl && ts.isVariableDeclaration(decl) && this.isReassigned(decl, ctx) && !this.isReassignedOwning(decl)) {
      this.fail(
        expr,
        `\`.${method}\` on a reassigned binding whose assignments are not all fresh constructions (keep the owned array in one binding: \`const out: T[] = []\` — or assign only literals/copies, which keeps the binding owned)`,
      );
    }
    if (lengthChangingMethods.has(method)) {
      // Owned, but the decl lowering did not produce a builder (an
      // annotation-less empty literal, a non-slice type) — the shape stop.
      this.fail(
        expr,
        `\`.${method}\` outside the builder shape (declare \`const out: T[] = [];\` in this function, mutate it, and use \`out\` afterwards; existing arrays grow immutably with a spread: \`[...xs, x]\`)`,
      );
    }
    // Fixed-length mutation on an owned local: the arena slice itself.
    const baseT = this.zTypeOfExpr(baseExpr, ctx);
    if (baseT.k !== "slice") this.fail(expr, `.${method} on ${baseT.k}`);
    const raw = this.emitExpr(baseExpr, ctx).code;
    return {
      builder: null,
      raw,
      len: `${raw}.len`,
      elemRef: this.table.zigTypeRef(baseT.elem),
      elemT: this.elemZType(baseT.elem),
    };
  }

  /// R17k: `out.push(x)` on a recognized builder -> grow-if-full + append.
  /// Push on anything else is a taught stop naming the ownership boundary.
  private tryEmitPushCall(expr: ts.CallExpression, ctx: Ctx): boolean {
    if (!ts.isPropertyAccessExpression(expr.expression) || expr.expression.name.text !== "push") return false;
    const baseExpr = expr.expression.expression;
    const baseT = this.zTypeOfExpr(baseExpr, ctx);
    if (baseT.k !== "slice") return false;
    const target = this.mutationTarget(expr, baseExpr, "push", ctx);
    const builder = target.builder!;
    if (expr.arguments.some((a) => ts.isSpreadElement(a))) {
      this.fail(expr, "`.push(...xs)` with a spread (push one element per iteration: `for (const x of xs) out.push(x);`)");
    }
    // JS evaluates every argument BEFORE the first append; when a later
    // argument reads the array (or its length), materialize the values
    // first so they see the pre-push state.
    const base = unwrapExpr(baseExpr);
    const decl = ts.isIdentifier(base) ? this.tast.declarationOf(base) : undefined;
    const hoist =
      expr.arguments.length > 1 &&
      decl !== undefined &&
      expr.arguments.slice(1).some((a) => this.referencesDecl(a, decl));
    const values: string[] = [];
    for (const arg of expr.arguments) {
      let v = this.emitExpr(arg, ctx, target.elemT).code;
      if (hoist && !ts.isNumericLiteral(arg)) {
        const tmp = this.freshName(ctx, "pushed");
        this.push(ctx, `const ${tmp} = ${v};`);
        v = tmp;
      }
      values.push(v);
    }
    for (const v of values) {
      this.push(
        ctx,
        `if (${builder.len} == ${builder.slice}.len) ${builder.slice} = rt.frameGrow(${builder.elemRef}, ${builder.slice});`,
      );
      this.push(ctx, `${builder.slice}[${builder.len}] = ${v};`);
      this.push(ctx, `${builder.len} += 1;`);
    }
    return true;
  }

  /// The statement-position mutating methods on owned arrays: pop/shift
  /// (dropping the removed value), unshift, splice (dropping the removed
  /// array), reverse, fill, and in-place sort. Value-position pop/shift/
  /// splice lower in emitCall; push has its own lowering above.
  private tryEmitMutatingCall(expr: ts.CallExpression, ctx: Ctx): boolean {
    if (!ts.isPropertyAccessExpression(expr.expression)) return false;
    const method = expr.expression.name.text;
    if (!ownedMutatingMethods.has(method) || method === "push") return false;
    const baseExpr = expr.expression.expression;
    const baseT = this.zTypeOfExpr(baseExpr, ctx);
    if (baseT.k !== "slice") return false;
    switch (method) {
      case "pop":
      case "shift":
        this.emitPopShift(expr, baseExpr, method, ctx, { statement: true });
        return true;
      case "unshift":
        this.emitUnshift(expr, baseExpr, ctx);
        return true;
      case "splice":
        this.emitSplice(expr, baseExpr, baseT as ZType & { k: "slice" }, ctx, { statement: true });
        return true;
      case "reverse": {
        if (expr.arguments.length !== 0) this.fail(expr, "reverse arity");
        const target = this.mutationTarget(expr, baseExpr, "reverse", ctx);
        const view = target.builder ? `${target.raw}[0..${target.len}]` : target.raw;
        this.push(ctx, `std.mem.reverse(${target.elemRef}, ${view});`);
        return true;
      }
      case "fill":
        this.emitFill(expr, baseExpr, ctx);
        return true;
      case "sort":
        this.emitInPlaceSort(expr, baseExpr, baseT as ZType & { k: "slice" }, ctx);
        return true;
      default:
        return false;
    }
  }

  /// `xs.pop()` / `xs.shift()` — remove from the tail/head. The value is the
  /// tier's one empty on an empty array (?E — JS spells it undefined), the
  /// same optional the `.find` miss produces.
  private emitPopShift(
    expr: ts.CallExpression,
    baseExpr: ts.Expression,
    method: "pop" | "shift",
    ctx: Ctx,
    opts: { statement: boolean; nameHint?: string },
  ): Emitted {
    if (expr.arguments.length !== 0) this.fail(expr, `${method} arity`);
    const target = this.mutationTarget(expr, baseExpr, method, ctx);
    const builder = target.builder;
    if (!builder) {
      // Fixed-length lowerings never include pop/shift; mutationTarget only
      // returns without a builder for sort/reverse/fill shapes.
      this.fail(expr, `\`.${method}\` outside the builder shape (declare \`const out: T[] = [];\` in this function and mutate that)`);
    }
    const raw = builder.slice;
    const len = builder.len;
    if (opts.statement) {
      if (method === "pop") {
        this.push(ctx, `if (${len} > 0) ${len} -= 1;`);
      } else {
        this.push(ctx, `if (${len} > 0) {`);
        const sub = this.nestedCtx(ctx);
        this.push(sub, `${len} -= 1;`);
        this.push(sub, `std.mem.copyForwards(${builder.elemRef}, ${raw}[0..${len}], ${raw}[1..${len} + 1]);`);
        ctx.lines.push(...sub.lines);
        this.push(ctx, `}`);
      }
      return { code: "" };
    }
    const out = this.freshName(ctx, opts.nameHint ?? (method === "pop" ? "popped" : "shifted"));
    const elemRef = this.table.zigTypeRef(builder.elem);
    this.push(ctx, `var ${out}: ?${elemRef} = null;`);
    this.push(ctx, `if (${len} > 0) {`);
    const sub = this.nestedCtx(ctx);
    if (method === "pop") {
      this.push(sub, `${len} -= 1;`);
      this.push(sub, `${out} = ${raw}[${len}];`);
    } else {
      this.push(sub, `${out} = ${raw}[0];`);
      this.push(sub, `${len} -= 1;`);
      this.push(sub, `std.mem.copyForwards(${builder.elemRef}, ${raw}[0..${len}], ${raw}[1..${len} + 1]);`);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: out };
  }

  /// `xs.unshift(...items)` — grow if needed, shift the prefix right, set
  /// the items. The JS value (the new length) is not mapped; read `.length`.
  private emitUnshift(expr: ts.CallExpression, baseExpr: ts.Expression, ctx: Ctx): void {
    if (expr.arguments.some((a) => ts.isSpreadElement(a))) {
      this.fail(expr, "`.unshift(...xs)` with a spread (unshift one element per call, or build a fresh array with a spread literal: `[...xs, ...ys]`)");
    }
    if (expr.arguments.length === 0) return; // JS: a no-op beyond returning the length.
    const target = this.mutationTarget(expr, baseExpr, "unshift", ctx);
    const builder = target.builder!;
    const raw = builder.slice;
    const len = builder.len;
    const k = expr.arguments.length;
    const base = unwrapExpr(baseExpr);
    const decl = ts.isIdentifier(base) ? this.tast.declarationOf(base) : undefined;
    // JS evaluates the items before the shift; hoist any that read the array.
    const values = expr.arguments.map((arg) => {
      let v = this.emitExpr(arg, ctx, target.elemT).code;
      if (decl && this.referencesDecl(arg, decl) && !ts.isNumericLiteral(arg)) {
        const tmp = this.freshName(ctx, "fronted");
        this.push(ctx, `const ${tmp} = ${v};`);
        v = tmp;
      }
      return v;
    });
    this.push(ctx, `while (${len} + ${k} > ${raw}.len) ${raw} = rt.frameGrow(${builder.elemRef}, ${raw});`);
    this.push(ctx, `std.mem.copyBackwards(${builder.elemRef}, ${raw}[${k}..${len} + ${k}], ${raw}[0..${len}]);`);
    values.forEach((v, i) => this.push(ctx, `${raw}[${i}] = ${v};`));
    this.push(ctx, `${len} += ${k};`);
  }

  /// `xs.splice(start, deleteCount?, ...items)` with JS index resolution:
  /// a negative start counts from the end and clamps (rt.sliceIndex), the
  /// delete count clamps into [0, len - start] (omitted deletes the rest).
  /// The value is the removed elements, a fresh arena array — skipped when
  /// the call is a statement.
  private emitSplice(
    expr: ts.CallExpression,
    baseExpr: ts.Expression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    opts: { statement: boolean; nameHint?: string },
  ): Emitted {
    if (expr.arguments.some((a) => ts.isSpreadElement(a))) {
      this.fail(expr, "`.splice(...)` with a spread argument (insert one element per splice, or rebuild with a spread literal: `[...xs.slice(0, i), ...ys, ...xs.slice(i)]`)");
    }
    const target = this.mutationTarget(expr, baseExpr, "splice", ctx);
    const builder = target.builder!;
    const raw = builder.slice;
    const len = builder.len;
    const elemRef = builder.elemRef;
    if (expr.arguments.length === 0) {
      // JS: splice() removes nothing; the value is a fresh empty array.
      if (opts.statement) return { code: "" };
      const out = this.freshName(ctx, opts.nameHint ?? "removed");
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, 0);`);
      return { code: out };
    }
    const at = this.freshName(ctx, `${raw}_at`);
    const startCode = this.emitExpr(expr.arguments[0], ctx).code;
    this.push(ctx, `const ${at} = rt.sliceIndex(${len}, ${startCode});`);
    const cut = this.freshName(ctx, `${raw}_cut`);
    if (expr.arguments.length >= 2) {
      const dcArg = expr.arguments[1];
      const dcCode = this.emitExpr(dcArg, ctx).code;
      const folded = this.tast.constEvalNumber(dcArg);
      const nonNegative = folded !== null && Number.isInteger(folded) && folded >= 0;
      const dc = nonNegative ? `${folded}` : `uz(@max(${dcCode}, 0))`;
      this.push(ctx, `const ${cut} = @min(${len} - ${at}, ${dc});`);
    } else {
      this.push(ctx, `const ${cut} = ${len} - ${at};`);
    }
    let out = "";
    if (!opts.statement) {
      out = this.freshName(ctx, opts.nameHint ?? "removed");
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${cut});`);
      this.push(ctx, `@memcpy(${out}, ${raw}[${at}..${at} + ${cut}]);`);
    }
    const items = expr.arguments.slice(2);
    const k = items.length;
    const base = unwrapExpr(baseExpr);
    const decl = ts.isIdentifier(base) ? this.tast.declarationOf(base) : undefined;
    const values = items.map((arg) => {
      let v = this.emitExpr(arg, ctx, target.elemT).code;
      if (decl && this.referencesDecl(arg, decl) && !ts.isNumericLiteral(arg)) {
        const tmp = this.freshName(ctx, "spliced_in");
        this.push(ctx, `const ${tmp} = ${v};`);
        v = tmp;
      }
      return v;
    });
    if (k > 0) {
      this.push(ctx, `while (${len} - ${cut} + ${k} > ${raw}.len) ${raw} = rt.frameGrow(${elemRef}, ${raw});`);
      this.push(ctx, `if (${k} > ${cut}) {`);
      const grow = this.nestedCtx(ctx);
      this.push(grow, `std.mem.copyBackwards(${elemRef}, ${raw}[${at} + ${k}..${len} - ${cut} + ${k}], ${raw}[${at} + ${cut}..${len}]);`);
      ctx.lines.push(...grow.lines);
      this.push(ctx, `} else {`);
      const shrink = this.nestedCtx(ctx);
      this.push(shrink, `std.mem.copyForwards(${elemRef}, ${raw}[${at} + ${k}..${len} - ${cut} + ${k}], ${raw}[${at} + ${cut}..${len}]);`);
      ctx.lines.push(...shrink.lines);
      this.push(ctx, `}`);
      values.forEach((v, i) => this.push(ctx, `${raw}[${at}${i > 0 ? ` + ${i}` : ""}] = ${v};`));
      this.push(ctx, `${len} = ${len} - ${cut} + ${k};`);
    } else {
      this.push(ctx, `std.mem.copyForwards(${elemRef}, ${raw}[${at}..${len} - ${cut}], ${raw}[${at} + ${cut}..${len}]);`);
      this.push(ctx, `${len} -= ${cut};`);
    }
    return { code: out };
  }

  /// `xs.fill(v, start?, end?)` with the JS/slice bound resolution:
  /// negatives count from the end, everything clamps, a crossed range fills
  /// nothing. The JS value (the same array) is not mapped in value position.
  private emitFill(expr: ts.CallExpression, baseExpr: ts.Expression, ctx: Ctx): void {
    if (expr.arguments.length === 0 || expr.arguments.length > 3) this.fail(expr, "fill arity");
    const target = this.mutationTarget(expr, baseExpr, "fill", ctx);
    const v = this.emitExpr(expr.arguments[0], ctx, target.elemT).code;
    const view = target.builder ? `${target.raw}[0..${target.len}]` : target.raw;
    if (expr.arguments.length === 1) {
      this.push(ctx, `@memset(${view}, ${v});`);
      return;
    }
    const lo = this.freshName(ctx, `${target.raw}_from`);
    const a = this.emitExpr(expr.arguments[1], ctx).code;
    this.push(ctx, `const ${lo} = rt.sliceIndex(${target.len}, ${a});`);
    let hi = `${target.len}`;
    if (expr.arguments[2]) {
      hi = this.freshName(ctx, `${target.raw}_to`);
      const b = this.emitExpr(expr.arguments[2], ctx).code;
      this.push(ctx, `const ${hi} = @max(${lo}, rt.sliceIndex(${target.len}, ${b}));`);
    }
    this.push(ctx, `@memset(${target.raw}[${lo}..${hi}], ${v});`);
  }

  /// R17j applied in place: `xs.sort(cmp)` on an owned array runs the same
  /// stable insertion sort `.toSorted` uses, without the copy. Comparator
  /// rules are unchanged (sign-returning, NS1023; the comparator-less arity
  /// is JS ToString ordering — a taught stop).
  private emitInPlaceSort(
    expr: ts.CallExpression,
    baseExpr: ts.Expression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
  ): void {
    const cb = this.callbackArg(expr, 0);
    if (!cb) {
      this.fail(
        expr,
        "`.sort()` without a comparator (JS sorts by string ToString order there, so [10, 9] stays [10, 9]; pass `(a, b) => a - b` for ascending numbers)",
      );
    }
    if (!isCallbackFn(cb) || cb.parameters.length !== 2) {
      this.fail(expr, "sort comparator shape ((a, b) => sign)");
    }
    // Layer-3 re-derivation of NS1023: a boolean comparator never sorts.
    if (this.tast.arrowReturnsBoolean(cb)) {
      this.fail(cb, "this `.sort` comparator returns a boolean", "NS1023");
    }
    const target = this.mutationTarget(expr, baseExpr, "sort", ctx);
    let view = target.raw;
    if (target.builder) {
      view = this.freshName(ctx, `${target.raw}_live`);
      this.push(ctx, `const ${view} = ${target.raw}[0..${target.len}];`);
    }
    this.push(ctx, `// JS sort: stable insertion sort; the comparator's sign orders each pair.`);
    this.emitInsertionSort(view, cb, baseT, ctx);
  }

  /// R11: `.set(src, off)` on a fresh buffer -> @memcpy.
  private tryEmitSetCall(expr: ts.CallExpression, ctx: Ctx): boolean {
    if (!ts.isPropertyAccessExpression(expr.expression) || expr.expression.name.text !== "set") return false;
    const baseT = this.zTypeOfExpr(expr.expression.expression, ctx);
    if (baseT.k !== "bytes") return false;
    const dst = this.emitExpr(expr.expression.expression, ctx).code;
    const srcExpr = expr.arguments[0];
    let src = this.emitExpr(srcExpr, ctx).code;
    if (!ts.isIdentifier(srcExpr)) {
      const name = this.freshName(ctx, "segment");
      this.push(ctx, `const ${name} = ${src};`);
      src = name;
    }
    const off = expr.arguments[1] ? this.emitIndex(expr.arguments[1], ctx) : "0";
    const dstRange = off === "0" ? `${dst}[0..${src}.len]` : `${dst}[${off}..][0..${src}.len]`;
    this.push(ctx, `@memcpy(${dstRange}, ${src});`);
    return true;
  }

  // ------------------------------------------------------------ expressions

  private emitIndex(expr: ts.Expression, ctx: Ctx): string {
    if (ts.isNumericLiteral(expr)) return expr.text;
    const v = this.emitExpr(expr, ctx).code;
    return `uz(${v})`;
  }

  /// Whether an equality with an optional numeric operand needs the
  /// null-safe widening helper: the two sides' machine classes diverge and
  /// neither side is a comptime-known value Zig coerces into the other's
  /// class on its own (an integer-valued literal coerces anywhere; a
  /// fractional literal coerces into f64 but can never coerce into an
  /// i64-classed optional — that is exactly the numEq case).
  private optionalEqNeedsWiden(expr: ts.BinaryExpression): boolean {
    const lFold = this.tast.constEvalNumber(expr.left);
    const rFold = this.tast.constEvalNumber(expr.right);
    if (lFold !== null && rFold !== null) return false;
    const lCls = this.infer.classOfExpr(expr.left);
    const rCls = this.infer.classOfExpr(expr.right);
    if (lFold !== null) return !(rCls === "f64" || Number.isInteger(lFold));
    if (rFold !== null) return !(lCls === "f64" || Number.isInteger(rFold));
    return lCls !== rCls;
  }

  /// R2: an integer-classed number value landing in an f64 position widens
  /// exactly (lengths, byte loads, and integer-valued expressions are all
  /// f64-representable). Slot-to-slot disagreements never reach this point —
  /// the inference fixed point resolved them or reported NS1016 — so what
  /// remains is a well-defined value conversion, not a papered-over mismatch.
  private widenToF64(expr: ts.Expression, code: string, ctx: Ctx): string {
    if (this.zTypeOfExpr(expr, ctx).k !== "number") return code;
    if (this.tast.constEvalNumber(expr) !== null) return code; // comptime-known: coerces
    if (this.infer.classOfExpr(expr) !== "i64") return code;
    return `@as(f64, @floatFromInt(${code}))`;
  }

  /// A compile-time-known non-negative integer below 2^31: `x & mask` with
  /// such a mask reads only low bits the ToInt32 wrap preserves and lands
  /// non-negative in range, so the plain i64 `&` matches JS exactly.
  private i31Mask(expr: ts.Expression): boolean {
    const v = this.tast.constEvalNumber(expr);
    return v !== null && Number.isInteger(v) && v >= 0 && v < 2 ** 31;
  }

  /// Provably within the signed 32-bit range, so the ToInt32 wrap is the
  /// identity: folded constants in range and `&` results already proven by
  /// i31Mask/this predicate. Everything else takes the wrap helpers.
  private provablyI32(expr: ts.Expression): boolean {
    if (ts.isParenthesizedExpression(expr)) return this.provablyI32(expr.expression);
    const v = this.tast.constEvalNumber(expr);
    if (v !== null) return Number.isInteger(v) && v >= -(2 ** 31) && v < 2 ** 31;
    if (ts.isBinaryExpression(expr) && expr.operatorToken.kind === ts.SyntaxKind.AmpersandToken) {
      return (
        this.i31Mask(expr.left) ||
        this.i31Mask(expr.right) ||
        (this.provablyI32(expr.left) && this.provablyI32(expr.right))
      );
    }
    return false;
  }

  /// emitExprValue plus the cross-type coercions the expected type forces:
  /// values of an overlapping literal union re-tag into the expected enum
  /// (R5b), and proven-integer reads widen exactly into f64 positions (R2).
  private emitExpr(expr: ts.Expression, ctx: Ctx, expected?: ZType, nameHint?: string): Emitted {
    const v = this.emitExprValue(expr, ctx, expected, nameHint);
    if (!expected) return v;
    // Wrapper nodes hand `expected` to the inner expression; conditionals
    // hand it to each branch — the coercion has already been applied there.
    if (
      ts.isParenthesizedExpression(expr) ||
      ts.isAsExpression(expr) ||
      ts.isSatisfiesExpression(expr) ||
      ts.isNonNullExpression(expr) ||
      ts.isConditionalExpression(expr)
    ) {
      return v;
    }
    const want = unwrapOptional(expected);
    if (want.k === "enum") {
      const have = unwrapOptional(this.zTypeOfExpr(expr, ctx));
      if (have.k === "enum" && have.name !== want.name) {
        return { ...v, code: `tagCast(${want.name}, ${v.code})` };
      }
    }
    if (want.k === "f64") {
      return { ...v, code: this.widenToF64(expr, v.code, ctx) };
    }
    if (want.k === "bool" && expected.k === "bool") {
      // A boolean `?.` chain in a condition: JS treats the short-circuit
      // undefined as falsy, exactly `orelse false`.
      const have = this.zTypeOfExpr(expr, ctx);
      if (have.k === "optional" && have.inner.k === "bool" && ts.isOptionalChain(expr)) {
        return { ...v, code: `(${v.code} orelse false)` };
      }
    }
    return v;
  }

  private emitExprValue(expr: ts.Expression, ctx: Ctx, expected?: ZType, nameHint?: string): Emitted {
    const substKey = this.narrowKey(expr);
    const subst = substKey === null ? undefined : ctx.memberSubst.get(substKey);
    if (subst !== undefined) return { code: subst };

    if (ts.isParenthesizedExpression(expr)) {
      const inner = this.emitExpr(expr.expression, ctx, expected, nameHint);
      return { ...inner, code: needsParens(expr.expression) ? `(${inner.code})` : inner.code };
    }
    if (ts.isNumericLiteral(expr)) return { code: expr.text };
    if (expr.kind === ts.SyntaxKind.TrueKeyword) return { code: "true" };
    if (expr.kind === ts.SyntaxKind.FalseKeyword) return { code: "false" };
    if (expr.kind === ts.SyntaxKind.NullKeyword) return { code: "null" };
    // The global `undefined` VALUE (a `.find`-miss return, an optional
    // reset) is the optional empty, exactly like `null` — Zig's
    // `undefined` keyword is uninitialized memory and must never appear
    // for it.
    if (ts.isIdentifier(expr) && expr.text === "undefined" && this.emptyFlavorOf(expr) === "undefined") {
      return { code: "null" };
    }
    if (ts.isStringLiteral(expr) || ts.isNoSubstitutionTemplateLiteral(expr)) {
      // A hole-free template literal IS a string literal in JS.
      if (expected?.k === "enum") return { code: `.${zigId(expr.text)}` };
      return { code: `"${escapeZigString(expr.text)}"` };
    }
    if (ts.isIdentifier(expr)) {
      const decl = this.tast.declarationOf(expr);
      if (decl && ctx.names.has(decl)) return { code: ctx.names.get(decl)! };
      // A module-level value resolves by declaration identity — this is
      // what makes cross-file references, import renames, and the
      // collision-prefixed private names all land on the emitted name.
      const moduleName = this.moduleNameOf(decl);
      if (moduleName !== null) return { code: moduleName };
      // The NaN/Infinity globals are f64 literals (a shadowing declaration
      // in one of the core's modules does not count).
      if ((expr.text === "NaN" || expr.text === "Infinity") && (!decl || !this.fileSet.has(decl.getSourceFile()))) {
        return { code: expr.text === "NaN" ? "std.math.nan(f64)" : "std.math.inf(f64)" };
      }
      return { code: expr.text };
    }
    if (ts.isPrefixUnaryExpression(expr)) {
      if (expr.operator === ts.SyntaxKind.ExclamationToken) {
        const v = this.emitExpr(expr.operand, ctx, { k: "bool" }).code;
        return { code: `!${maybeParen(v)}` };
      }
      if (expr.operator === ts.SyntaxKind.MinusToken) {
        // A negation folding to -0 must spell the f64 literal: Zig's `-0` is
        // the comptime integer zero, which coerces to +0.0 (the slot is
        // float-classed by inference — i64 cannot hold a signed zero).
        const folded = this.tast.constEvalNumber(expr);
        if (folded !== null && Object.is(folded, -0)) return { code: f64Literal(-0) };
        return { code: `-${this.emitExpr(expr.operand, ctx).code}` };
      }
      if (expr.operator === ts.SyntaxKind.PlusToken) {
        // Unary plus is ToNumber — the identity on the subset's numbers
        // (NaN and -0 included). Non-number operands would be a coercion.
        const t = unwrapOptional(this.zTypeOfExpr(expr.operand, ctx));
        if (t.k !== "number" && t.k !== "i64" && t.k !== "f64") {
          this.fail(expr, "unary `+` on a non-number (it would coerce; numbers are already numbers)");
        }
        return this.emitExpr(expr.operand, ctx, expected);
      }
      if (expr.operator === ts.SyntaxKind.TildeToken) {
        // R9: `~x` is ToInt32 bitwise-not; the operand is integer-required.
        return { code: `jsBitNot(${this.emitExpr(expr.operand, ctx).code})` };
      }
      if (expr.operator === ts.SyntaxKind.PlusPlusToken || expr.operator === ts.SyntaxKind.MinusMinusToken) {
        // R10b: pre-step value position (`const n = ++count`) — the step
        // lowers to its own statement, then the variable reads back (its
        // post-step value IS the JS value of the expression).
        return this.emitValueStep(expr, expr.operand, ctx, { preStep: true });
      }
      this.fail(expr, "unary operator");
    }
    if (ts.isPostfixUnaryExpression(expr)) {
      // R10b: post-step value position (`arr[i++]`) — the pre-step value
      // snapshots first, then the step runs as its own statement.
      return this.emitValueStep(expr, expr.operand, ctx, { preStep: false });
    }
    if (ts.isPropertyAccessExpression(expr)) return this.emitPropertyAccess(expr, ctx);
    if (ts.isElementAccessExpression(expr)) {
      // R7b (element hop): `a?.b[i]` / `xs?.[i]` over a nullable base lowers
      // to the same null-propagating if-capture as property hops; the value
      // is optional (`??` or an equality consumes it). A chain marker over a
      // base that can never be null emits as a plain access.
      const baseT = this.zTypeOfExpr(expr.expression, ctx);
      if (ts.isOptionalChain(expr) && baseT.k === "optional") {
        const inner = baseT.inner;
        if (inner.k !== "slice" && inner.k !== "bytes") {
          this.fail(expr, `indexing ${inner.k} through an optional chain`);
        }
        const baseCode = this.emitExpr(expr.expression, ctx).code;
        const cap = this.freshName(ctx, nameHint ?? "elems");
        // Probe in a flow scope (see childCtx): a lines-free index probe
        // processed no statements, and a lines-bearing one stops the build.
        const idxCtx = this.childCtx(ctx);
        const idx = this.withNarrowScope(ctx, "merge", () => this.emitIndex(expr.argumentExpression, idxCtx), new Set());
        if (idxCtx.lines.length > 0) {
          // JS only evaluates the index when the base is non-null; an index
          // needing its own statements cannot ride the inline capture.
          this.fail(expr, "an index expression with side effects on an optional chain (hoist the index to its own const first)");
        }
        return { code: `(if (${baseCode}) |${cap}| ${cap}[${idx}] else null)` };
      }
      const base = this.emitExpr(expr.expression, ctx).code;
      return { code: `${base}[${this.emitIndex(expr.argumentExpression, ctx)}]` };
    }
    if (ts.isBinaryExpression(expr) && assignmentOps.has(expr.operatorToken.kind)) {
      // R10b: an assignment consumed as a value (`const z = (y = 5)`) —
      // the statement runs first, then the variable reads back (its
      // post-assignment value IS the JS value for every operator form).
      return this.emitValueStep(expr, expr.left, ctx, { preStep: true });
    }
    if (ts.isBinaryExpression(expr)) return this.emitBinary(expr, ctx, expected);
    if (ts.isConditionalExpression(expr)) return this.emitConditional(expr, ctx, expected, nameHint);
    if (ts.isCallExpression(expr)) return this.emitCall(expr, ctx, expected, nameHint);
    if (ts.isNewExpression(expr)) return this.emitNew(expr, ctx);
    if (expr.kind === ts.SyntaxKind.ThisKeyword) {
      // R19: `this` is the emitted receiver parameter (`self`); Zig
      // auto-derefs pointer receivers on field access.
      if (!ctx.thisName) this.fail(expr, "`this` outside a class member body", "NS1006");
      return { code: ctx.thisName };
    }
    if (ts.isObjectLiteralExpression(expr)) return this.emitObjectLiteral(expr, ctx, expected, nameHint);
    if (ts.isArrayLiteralExpression(expr)) return this.emitArrayLiteral(expr, ctx, expected, nameHint);
    if (ts.isTemplateExpression(expr)) return this.emitTemplate(expr, ctx);
    if (ts.isNonNullExpression(expr) || ts.isAsExpression(expr) || ts.isSatisfiesExpression(expr)) {
      return this.emitExpr(expr.expression, ctx, expected, nameHint);
    }
    this.fail(expr, `expression kind ${ts.SyntaxKind[expr.kind]}`);
  }

  private emitPropertyAccess(expr: ts.PropertyAccessExpression, ctx: Ctx): Emitted {
    const key = this.narrowKey(expr);
    const subst = key === null ? undefined : ctx.memberSubst.get(key);
    if (subst !== undefined) return { code: subst };
    // Layer-3 re-derivation of NS1017 (`Cmd.none` outside the return slot)
    // and NS1025 (its Sub mirror).
    if (this.isCmdNamespace(expr.expression)) {
      this.fail(expr, `Cmd.${expr.name.text} outside update's return path (NS1017)`);
    }
    if (this.isSubNamespace(expr.expression)) {
      this.fail(expr, `Sub.${expr.name.text} outside subscriptions' return path (NS1025)`, "NS1025");
    }
    // R15c: `ns.member` through an `import * as ns` — the alias erases and
    // the member emits its flat module-scope name.
    if (this.isNamespaceAliasBase(expr.expression)) {
      const decl = this.tast.declarationOf(expr.name);
      const name = this.moduleNameOf(decl);
      if (name !== null) return { code: name };
      this.fail(expr, `namespace member \`${expr.getText()}\` (no emitted value by that name)`);
    }
    // R19b: `Task.LIMIT` — a static const reads its module-level emitted
    // name (the class name is dot-syntax here, never a value).
    {
      const decl = this.tast.declarationOf(expr.name);
      if (
        decl &&
        ts.isPropertyDeclaration(decl) &&
        isStaticMember(decl) &&
        ts.isClassDeclaration(decl.parent) &&
        decl.parent.name &&
        this.table.classes.get(decl.parent.name.text)?.decl === decl.parent &&
        ts.isIdentifier(decl.name)
      ) {
        const constName = this.classFnNames.get(`${decl.parent.name.text}#${decl.name.text}`);
        if (constName) return { code: constName };
        this.fail(expr, `static \`${expr.getText()}\` has no emitted const (mutable statics are module state)`, "NS1010");
      }
    }
    // R7b: optional chains lower to null-propagating if-captures.
    if (ts.isOptionalChain(expr)) return this.emitOptionalChain(expr, ctx);
    const prop = expr.name.text;
    if (prop === "length") {
      const baseLenKey = this.narrowKey(expr.expression);
      const lenSubst = baseLenKey === null ? undefined : ctx.memberSubst.get(`${baseLenKey}.length`);
      if (lenSubst !== undefined) return { code: lenSubst };
      const baseT = this.zTypeOfExpr(expr.expression, ctx);
      const base = this.emitExpr(expr.expression, ctx);
      if (baseT.k === "bytes" || baseT.k === "string") return { code: `jlen(${base.code})` };
      if (baseT.k === "slice") {
        if (base.filterLen) return { code: `@as(i64, @intCast(${base.filterLen}))` };
        return { code: `@as(i64, @intCast(${base.code}.len))` };
      }
      this.fail(expr, `.length on ${baseT.k}`);
    }
    // Union payload fields are only reachable through a narrowing construct
    // (switch, kind guard); anything else must stop here, not in Zig.
    const baseT = this.zTypeOfExpr(expr.expression, ctx);
    if (baseT.k === "union") {
      this.fail(expr, `union field access outside a \`kind\` guard or switch`);
    }
    const base = this.emitExpr(expr.expression, ctx).code;
    return { code: `${base}.${zigDeclName(prop)}` };
  }

  /// R7b: `base?.prop` (and every later hop of the same chain) lowers to a
  /// null-propagating if-capture, `(if (base) |v| v.prop else null)`. The
  /// value is optional; `??` or an equality against a value consumes it —
  /// a null test on it is NS1021 (JS undefined vs null would disagree).
  /// Hops whose base can never be null emit as plain accesses.
  private emitOptionalChain(expr: ts.PropertyAccessExpression, ctx: Ctx): Emitted {
    const base = expr.expression;
    const baseT = this.zTypeOfExpr(base, ctx);
    const baseCode = this.emitExpr(base, ctx).code;
    if (baseT.k !== "optional") {
      return { code: this.chainHop(baseCode, baseT, expr, ctx) };
    }
    const hint = ts.isPropertyAccessExpression(base)
      ? zigLocalName(base.name.text)
      : ts.isIdentifier(base)
        ? zigLocalName(base.text)
        : "opt";
    const cap = this.freshName(ctx, hint);
    const inner = this.chainHop(cap, baseT.inner, expr, ctx);
    return { code: `(if (${baseCode}) |${cap}| ${inner} else null)` };
  }

  /// One property hop of an optional chain, on a base proven non-null.
  private chainHop(baseCode: string, baseT: ZType, expr: ts.PropertyAccessExpression, ctx: Ctx): string {
    const prop = expr.name.text;
    if (prop === "length") {
      if (baseT.k === "bytes" || baseT.k === "string") return `jlen(${baseCode})`;
      if (baseT.k === "slice") return `@as(i64, @intCast(${baseCode}.len))`;
      this.fail(expr, `.length on ${baseT.k}`);
    }
    if (baseT.k === "union") {
      this.fail(expr, "union field access outside a `kind` guard or switch");
    }
    return `${baseCode}.${zigDeclName(prop)}`;
  }

  private emitBinary(expr: ts.BinaryExpression, ctx: Ctx, expected?: ZType): Emitted {
    const op = expr.operatorToken.kind;
    // `x === null` / `x !== null` on optionals — and the `=== undefined`
    // spelling, which is the same one native empty when the target's type
    // carries undefined (a `.find` miss) and a taught stop otherwise (R7c).
    const emptyTest =
      op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.ExclamationEqualsEqualsToken
        ? this.emptyTestOf(expr, op)
        : null;
    if (emptyTest) {
      const target = emptyTest.target;
      // Layer-3 re-derivation of NS1021: the native optional cannot tell a
      // short-circuited chain (JS undefined) from a null field value.
      let chainProbe: ts.Expression = target;
      while (ts.isParenthesizedExpression(chainProbe)) chainProbe = chainProbe.expression;
      if (ts.isOptionalChain(chainProbe)) {
        this.fail(expr, "a `?.` chain flows into a null test", "NS1021");
      }
      this.requireFaithfulEmptyTest(target, emptyTest.flavor, expr);
      const v = this.emitExpr(target, ctx).code;
      return { code: `${v} ${op === ts.SyntaxKind.EqualsEqualsEqualsToken ? "==" : "!="} null` };
    }
    const isEquality =
      op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.ExclamationEqualsEqualsToken;
    // `e.kind === "tag"` -> `e == .tag` (the literal on either side).
    if (isEquality) {
      const sides: Array<[ts.Expression, ts.Expression]> = [
        [expr.left, expr.right],
        [expr.right, expr.left],
      ];
      for (const [kindSide, litSide] of sides) {
        if (
          ts.isPropertyAccessExpression(kindSide) &&
          kindSide.name.text === "kind" &&
          ts.isStringLiteral(litSide)
        ) {
          const base = this.emitExpr(kindSide.expression, ctx).code;
          const zop = op === ts.SyntaxKind.EqualsEqualsEqualsToken ? "==" : "!=";
          return { code: `${base} ${zop} .${zigId(litSide.text)}` };
        }
      }
      // Enum comparisons against string literals (the literal on either side).
      for (const [valueSide, litSide] of sides) {
        if (!ts.isStringLiteral(litSide)) continue;
        const t = unwrapOptional(this.zTypeOfExpr(valueSide, ctx));
        if (t.k === "enum") {
          const base = this.emitExpr(valueSide, ctx).code;
          const zop = op === ts.SyntaxKind.EqualsEqualsEqualsToken ? "==" : "!=";
          return { code: `${base} ${zop} .${zigId(litSide.text)}` };
        }
      }
      // R5b: equality across two distinct literal unions compares literal
      // names — the overlap of the two string sets, resolved at compile time.
      const lt = unwrapOptional(this.zTypeOfExpr(expr.left, ctx));
      const rt = unwrapOptional(this.zTypeOfExpr(expr.right, ctx));
      if (lt.k === "enum" && rt.k === "enum" && lt.name !== rt.name) {
        const l = this.emitExpr(expr.left, ctx).code;
        const r = this.emitExpr(expr.right, ctx).code;
        const call = `tagEq(${l}, ${r})`;
        return { code: op === ts.SyntaxKind.EqualsEqualsEqualsToken ? call : `!${call}` };
      }
      // R5c: `===` on string-typed operands is content equality in JS, so it
      // lowers to strEq (std.mem.eql with tagEq's null table). Bytes never
      // take this path: `===` on Uint8Array is JS reference identity, which
      // slice-content comparison would silently change.
      if (lt.k === "string" && rt.k === "string") {
        const l = this.emitExpr(expr.left, ctx).code;
        const r = this.emitExpr(expr.right, ctx).code;
        const call = `strEq(${l}, ${r})`;
        return { code: op === ts.SyntaxKind.EqualsEqualsEqualsToken ? call : `!${call}` };
      }
      // R5c: a literal-union value against a plain string compares the tag
      // name's bytes (at runtime the JS value IS that string).
      if ((lt.k === "enum" && rt.k === "string") || (lt.k === "string" && rt.k === "enum")) {
        const enumSide = lt.k === "enum" ? expr.left : expr.right;
        const strSide = lt.k === "enum" ? expr.right : expr.left;
        if (this.zTypeOfExpr(enumSide, ctx).k === "optional") {
          this.fail(expr, "equality between an optional literal-union value and a plain string (v1)");
        }
        const e = this.emitExpr(enumSide, ctx).code;
        const s = this.emitExpr(strSide, ctx).code;
        const call = `strEq(@tagName(${e}), ${s})`;
        return { code: op === ts.SyntaxKind.EqualsEqualsEqualsToken ? call : `!${call}` };
      }
      if (lt.k === "bytes" || rt.k === "bytes") {
        this.fail(
          expr,
          "`===` on bytes (JS compares Uint8Array references, not contents; compare an id, or the contents with a loop)",
        );
      }
      // Optional numeric equality across DIVERGING machine classes (an
      // optional i64 slot against an f64 value, either order): Zig's plain
      // operators cannot compare `?i64` with `f64`, so the comparison
      // routes through the null-safe widening helper — null equals only
      // null, the integer side widens exactly, node's truth table holds.
      if (lt.k === "number" && rt.k === "number") {
        const rawL = this.zTypeOfExpr(expr.left, ctx);
        const rawR = this.zTypeOfExpr(expr.right, ctx);
        const anyOptional = rawL.k === "optional" || rawR.k === "optional";
        if (anyOptional && this.optionalEqNeedsWiden(expr)) {
          const l = this.emitExpr(expr.left, ctx).code;
          const r = this.emitExpr(expr.right, ctx).code;
          const call = `numEq(${l}, ${r})`;
          return { code: op === ts.SyntaxKind.EqualsEqualsEqualsToken ? call : `!${call}` };
        }
      }
      // Same-class optional numeric equality (`cls === 0` with cls:
      // number | null, either order, either operand optional) falls
      // through to the plain operators: Zig's optional equality is already
      // null-safe with the JS truth table — null equals only null, and
      // never a number — so no unwrap is emitted and a null operand can
      // never trap.
    }
    if (op === ts.SyntaxKind.QuestionQuestionToken) {
      // `x ?? null` folds JS undefined and null into one empty value — which
      // is exactly what the native optional already is, so the left side IS
      // the result (this is also how a `?.` chain value normalizes). The
      // wrapped spellings (`x ?? (null)`) and the `x ?? undefined` flavor
      // fold identically.
      if (this.isEmptyLiteral(expr.right)) {
        return this.emitExpr(expr.left, ctx, expected);
      }
      // Both sides see the expected type: either may need an enum re-tag.
      // A bool expectation stops here — the orelse below already consumes
      // the optional, so the left side must stay optional (no chain fold).
      const inherited = expected?.k === "bool" ? undefined : expected;
      const l = orelseOperand(this.emitExpr(expr.left, ctx, inherited).code);
      const r = this.emitExpr(expr.right, ctx, inherited ? unwrapOptional(inherited) : undefined).code;
      return { code: `${l} orelse ${r}` };
    }
    // R8: `**` is JS float pow (2 ** -2 is 0.25); both operands widen and
    // the jsPow helper pins the two corners JS defines away from libm (a
    // NaN exponent, and +-1 ** +-Infinity). Right-associativity is the
    // parser's — the AST already nests `2 ** 3 ** 2` rightward. A constant
    // site folds to its exact JS value like `/`.
    if (op === ts.SyntaxKind.AsteriskAsteriskToken) {
      const folded = this.tast.constEvalNumber(expr);
      if (folded !== null) return { code: f64Literal(folded) };
      const l = this.widenToF64(expr.left, this.emitExpr(expr.left, ctx).code, ctx);
      const r = this.widenToF64(expr.right, this.emitExpr(expr.right, ctx).code, ctx);
      return { code: `jsPow(${l}, ${r})` };
    }
    // R9: shifts wrap to 32 bits with the count masked & 31 (`<<`/`>>`
    // signed, `>>>` unsigned) — always through the helpers; the operands
    // are integer-required positions (a float operand is a taught NS1016).
    if (
      op === ts.SyntaxKind.LessThanLessThanToken ||
      op === ts.SyntaxKind.GreaterThanGreaterThanToken ||
      op === ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken
    ) {
      const folded = this.tast.constEvalNumber(expr);
      if (folded !== null) return { code: String(folded) };
      const helper =
        op === ts.SyntaxKind.LessThanLessThanToken
          ? "jsShl"
          : op === ts.SyntaxKind.GreaterThanGreaterThanToken
            ? "jsShr"
            : "jsUshr";
      const l = this.emitExpr(expr.left, ctx).code;
      const r = this.emitExpr(expr.right, ctx).code;
      return { code: `${helper}(${l}, ${r})` };
    }
    const table: Partial<Record<ts.SyntaxKind, string>> = {
      [ts.SyntaxKind.EqualsEqualsEqualsToken]: "==",
      [ts.SyntaxKind.ExclamationEqualsEqualsToken]: "!=",
      [ts.SyntaxKind.LessThanToken]: "<",
      [ts.SyntaxKind.LessThanEqualsToken]: "<=",
      [ts.SyntaxKind.GreaterThanToken]: ">",
      [ts.SyntaxKind.GreaterThanEqualsToken]: ">=",
      [ts.SyntaxKind.PlusToken]: "+",
      [ts.SyntaxKind.MinusToken]: "-",
      [ts.SyntaxKind.AsteriskToken]: "*",
      [ts.SyntaxKind.SlashToken]: "/",
      [ts.SyntaxKind.PercentToken]: "%",
      [ts.SyntaxKind.AmpersandAmpersandToken]: "and",
      [ts.SyntaxKind.BarBarToken]: "or",
      [ts.SyntaxKind.AmpersandToken]: "&",
      [ts.SyntaxKind.BarToken]: "|",
      [ts.SyntaxKind.CaretToken]: "^",
    };
    const zop = table[op];
    if (!zop) this.fail(expr, `binary operator ${ts.SyntaxKind[op]}`);
    // Layer-3 re-derivation of NS1018: `+` with a string/bytes operand is JS
    // concatenation, which has no native mapping.
    if (op === ts.SyntaxKind.PlusToken) {
      const lc0 = unwrapOptional(this.zTypeOfExpr(expr.left, ctx));
      const rc0 = unwrapOptional(this.zTypeOfExpr(expr.right, ctx));
      const texty = (t: ZType) => t.k === "string" || t.k === "bytes" || t.k === "enum";
      if (texty(lc0) || texty(rc0)) {
        this.fail(expr, "`+` on a string concatenates at runtime", "NS1018");
      }
    }
    // JS division is float always, so a division that folds at compile time
    // is emitted as its JS f64 value: Zig's comptime `/` truncates
    // comptime_ints (5 / 2 would silently emit 2 where JS says 2.5) and
    // rejects a zero divisor outright (0 / 0 is a compile error, JS says NaN).
    if (op === ts.SyntaxKind.SlashToken) {
      const folded = this.tast.constEvalNumber(expr);
      if (folded !== null) return { code: f64Literal(folded) };
    }
    // Constant +,-,* folding to -0 (`0 * -1`) spells the f64 literal: the
    // emitted Zig integer arithmetic would produce +0 where node keeps -0
    // (the slot is float-classed by inference, same family as % below).
    if (
      op === ts.SyntaxKind.PlusToken ||
      op === ts.SyntaxKind.MinusToken ||
      op === ts.SyntaxKind.AsteriskToken
    ) {
      const folded = this.tast.constEvalNumber(expr);
      if (folded !== null && Object.is(folded, -0)) return { code: f64Literal(-0) };
    }
    // JS % folds the same way: `5 % 0` is NaN (Zig's comptime @rem rejects a
    // zero divisor outright) and `-5 % 5` is -0. Integer-classed folds keep
    // the plain integer literal so index positions stay comptime-usable.
    if (op === ts.SyntaxKind.PercentToken) {
      const folded = this.tast.constEvalNumber(expr);
      if (folded !== null) {
        const intish =
          Number.isInteger(folded) && !Object.is(folded, -0) && this.infer.classOfExpr(expr) === "i64";
        return { code: intish ? String(folded) : f64Literal(folded) };
      }
    }
    // R7d: `x !== null && <uses x>` (and the `||` dual) in value position —
    // the capturing if-expression spelling; see the R7d block above.
    if (op === ts.SyntaxKind.AmpersandAmpersandToken || op === ts.SyntaxKind.BarBarToken) {
      const conjuncts = this.flattenLogical(expr, op);
      if (conjuncts.length > 1 && this.chainHasNullGuard(conjuncts, op, ctx)) {
        return { code: this.emitNullGuardChainValue(conjuncts, op, ctx) };
      }
    }

    // R13c: `x.kind === "t" && <uses payload>` narrows its right side (and
    // the `!==`/`||` dual) — short-circuiting guards the payload accessor.
    const chainGuard =
      op === ts.SyntaxKind.AmpersandAmpersandToken
        ? this.kindGuardOf(expr.left)
        : op === ts.SyntaxKind.BarBarToken
          ? this.kindGuardOf(expr.left, ts.SyntaxKind.ExclamationEqualsEqualsToken)
          : null;
    // Operands do not inherit the site's expected type: coercions into the
    // expected type apply to the whole result (below and in emitExpr). The
    // exception is `&&`/`||`, whose operands are themselves boolean sites
    // (a boolean `?.` chain there needs its `orelse false`).
    const logical = op === ts.SyntaxKind.AmpersandAmpersandToken || op === ts.SyntaxKind.BarBarToken;
    const operandExpected: ZType | undefined = logical ? { k: "bool" } : undefined;
    const l = this.emitExpr(expr.left, ctx, operandExpected);
    const r = this.withKindNarrow(chainGuard, ctx, () => this.emitExpr(expr.right, ctx, operandExpected));
    let lc = l.code;
    let rc = r.code;
    // R2: inside an f64-classed comparison or arithmetic site, integer READS
    // widen exactly so both Zig operands are float (slots never take casts —
    // the inference fixed point already made them agree or reported NS1016).
    const numericSite =
      op === ts.SyntaxKind.PlusToken ||
      op === ts.SyntaxKind.MinusToken ||
      op === ts.SyntaxKind.AsteriskToken ||
      op === ts.SyntaxKind.PercentToken ||
      isEquality ||
      op === ts.SyntaxKind.LessThanToken ||
      op === ts.SyntaxKind.LessThanEqualsToken ||
      op === ts.SyntaxKind.GreaterThanToken ||
      op === ts.SyntaxKind.GreaterThanEqualsToken;
    if (op === ts.SyntaxKind.SlashToken) {
      // JS division is float always (5 / 2 is 2.5); both operands widen so the
      // site is IEEE f64 division — by-zero yields the JS infinities/NaN, never
      // a truncating integer divide or a divide trap.
      lc = this.widenToF64(expr.left, lc, ctx);
      rc = this.widenToF64(expr.right, rc, ctx);
    } else if (numericSite) {
      const floatSide =
        this.infer.classOfExpr(expr.left) === "f64" || this.infer.classOfExpr(expr.right) === "f64";
      if (floatSide) {
        lc = this.widenToF64(expr.left, lc, ctx);
        rc = this.widenToF64(expr.right, rc, ctx);
      }
    }
    if (op === ts.SyntaxKind.PercentToken) {
      // JS % is the truncated remainder on both ints and floats, which is
      // exactly @rem. Float sites keep full IEEE corners (x % 0 is NaN,
      // finite % Infinity is x); an integer site's zero divisor traps loudly
      // in native builds, the same policy as out-of-bounds indexing.
      return { code: `@rem(${lc}, ${rc})` };
    }
    if (
      op === ts.SyntaxKind.AmpersandToken ||
      op === ts.SyntaxKind.BarToken ||
      op === ts.SyntaxKind.CaretToken
    ) {
      // R9: JS bitwise wraps each operand to a signed 32-bit value first. The
      // plain i64 operator is identical when that wrap cannot change anything:
      // `&` against a non-negative sub-2^31 mask depends only on low bits the
      // wrap preserves, and any op over operands already proven inside the
      // 32-bit range. Everything else goes through the wrap helpers.
      const plain =
        op === ts.SyntaxKind.AmpersandToken
          ? this.i31Mask(expr.left) ||
            this.i31Mask(expr.right) ||
            (this.provablyI32(expr.left) && this.provablyI32(expr.right))
          : this.provablyI32(expr.left) && this.provablyI32(expr.right);
      if (!plain) {
        const helper =
          op === ts.SyntaxKind.AmpersandToken ? "jsAnd" : op === ts.SyntaxKind.BarToken ? "jsOr" : "jsXor";
        return { code: `${helper}(${lc}, ${rc})` };
      }
    }
    const lp = precedenceParen(expr.left, zop, lc);
    const rp = precedenceParen(expr.right, zop, rc);
    return { code: `${lp} ${zop} ${rp}` };
  }

  private emitted(e: Emitted): string {
    return e.code;
  }

  private emitConditional(
    expr: ts.ConditionalExpression,
    ctx: Ctx,
    expected?: ZType,
    nameHint?: string,
  ): Emitted {
    const cond = expr.condition;
    // `x === null ? A : x` -> `x orelse A` (the `=== undefined` spelling on
    // undefined-flavored values maps the same way, per R7c).
    const missTest = this.emptyTestOf(cond);
    const missArmKey = this.narrowKey(expr.whenFalse);
    if (missTest && missArmKey !== null && missArmKey === this.narrowKey(missTest.target)) {
      this.requireFaithfulEmptyTest(missTest.target, missTest.flavor, cond);
      // Probe both sides in throwaway child ctxs: the fusion only holds
      // when the miss arm is statement-free. An arm that lowers statements
      // (a spread literal builds its copy line by line) must not ride the
      // orelse — those lines would land ABOVE it and run even on the
      // non-empty path — so it falls through to the narrowed-ternary
      // lowering below, which scopes them to the branch that runs.
      const tT = this.zTypeOfExpr(missTest.target, ctx);
      const armWant =
        expected ? unwrapOptional(expected) : tT.k === "optional" ? tT.inner : undefined;
      // Both probes bracket in a flow scope (see childCtx): discarded, they
      // must leave no trace; taken, the miss arm's real kills join onto the
      // post-expression state below.
      const fuseJoin = new Set<string>();
      const targetSub = this.childCtx(ctx);
      const target = this.withNarrowScope(ctx, "merge", () => this.emitExpr(missTest.target, targetSub).code, fuseJoin);
      const altSub = this.childCtx(ctx);
      const alt = this.withNarrowScope(ctx, "merge", () => this.emitExpr(expr.whenTrue, altSub, armWant).code, fuseJoin);
      if (altSub.lines.length === 0) {
        // The target is evaluated exactly once; its lowered lines (if any)
        // ride ahead of the orelse like any condition's.
        ctx.lines.push(...targetSub.lines);
        this.applyJoinedNarrowKills(ctx, fuseJoin);
        return { code: `${target} orelse ${alt}` };
      }
    }
    // `x === null ? A : <uses x>` (and the `=== undefined` find-miss
    // spelling) — the narrowing dual of the `!==` case below: TS narrows
    // the ELSE branch, so the capture unwraps there and the miss branch
    // rides the else arm. Without this the else branch would read fields
    // through the optional — invalid Zig.
    if (
      missTest &&
      (ts.isPropertyAccessExpression(missTest.target) || ts.isIdentifier(missTest.target)) &&
      // An unread capture would be a Zig unused-capture error; unread
      // guards keep the plain comparison. Declaration identity for
      // identifier targets: a wrapped read (`q!`) is still a read of q.
      this.anyReadsTarget([expr.whenFalse], missTest.target)
    ) {
      const t = this.zTypeOfExpr(missTest.target, ctx);
      if (t.k === "optional") {
        this.requireFaithfulEmptyTest(missTest.target, missTest.flavor, cond);
        return this.emitNarrowedTernary(expr, missTest.target, expr.whenFalse, expr.whenTrue, ctx, expected, nameHint);
      }
    }
    // `x !== null ? <uses x> : B` -> `if (x) |v| ... else B`.
    const hitTest = this.emptyTestOf(cond, ts.SyntaxKind.ExclamationEqualsEqualsToken);
    if (
      hitTest &&
      (ts.isPropertyAccessExpression(hitTest.target) || ts.isIdentifier(hitTest.target)) &&
      // An unread capture would be a Zig unused-capture error; unread guards
      // keep the plain comparison. Declaration identity for identifier
      // targets: a wrapped read (`q!`) is still a read of q.
      this.anyReadsTarget([expr.whenTrue], hitTest.target)
    ) {
      const t = this.zTypeOfExpr(hitTest.target, ctx);
      if (t.k === "optional") {
        this.requireFaithfulEmptyTest(hitTest.target, hitTest.flavor, cond);
        return this.emitNarrowedTernary(expr, hitTest.target, expr.whenTrue, expr.whenFalse, ctx, expected, nameHint);
      }
    }
    // R7d: a null-guarded chain condition — `x !== null && x.a > 0 ? x.a :
    // -1` — takes the unwrap spelling, with the substitutions active over
    // the branch TS narrows by the condition (`&&` -> whenTrue, `||` dual ->
    // whenFalse; the condition being false proves every disjunct false).
    if (ts.isBinaryExpression(cond)) {
      const cop = cond.operatorToken.kind;
      if (cop === ts.SyntaxKind.AmpersandAmpersandToken || cop === ts.SyntaxKind.BarBarToken) {
        const isAnd = cop === ts.SyntaxKind.AmpersandAmpersandToken;
        const conjuncts = this.flattenLogical(cond, cop);
        const narrowedBranch = isAnd ? expr.whenTrue : expr.whenFalse;
        const applies =
          conjuncts.length > 1 &&
          conjuncts.some((c, i) => {
            const g = this.nullGuardOf(c, cop, ctx);
            return (
              g !== null && this.anyReadsTarget([...conjuncts.slice(i + 1), narrowedBranch], g.target)
            );
          });
        if (applies) {
          const guards = new Map<string, string>();
          const condText = this.emitNullGuardChainUnwrap(conjuncts, cop, ctx, guards);
          const kindGuards = this.chainKindGuards(conjuncts, cop);
          const narrowedExpected = isAnd && expected ? unwrapOptional(expected) : expected;
          const emitNarrowed = (sub: Ctx, e: ts.Expression, want?: ZType): string =>
            this.withSubsts(guards, ctx, () =>
              this.withKindNarrows(kindGuards, ctx, () => this.emitExpr(e, sub, want).code),
            );
          // Each arm probes and emits from the ENTRY state, kills joining
          // after the last arm (see childCtx's isolation law).
          const probeJoin = new Set<string>();
          const thenSub2 = this.childCtx(ctx);
          const thenCode = this.withNarrowScope(ctx, "merge", () => isAnd
            ? emitNarrowed(thenSub2, expr.whenTrue, narrowedExpected)
            : this.emitExpr(expr.whenTrue, thenSub2, expected ? unwrapOptional(expected) : expected).code, probeJoin);
          const elseSub2 = this.childCtx(ctx);
          const elseCode = this.withNarrowScope(ctx, "merge", () => isAnd
            ? this.emitExpr(expr.whenFalse, elseSub2, expected).code
            : emitNarrowed(elseSub2, expr.whenFalse, expected), probeJoin);
          if (thenSub2.lines.length === 0 && elseSub2.lines.length === 0) {
            // The probes ARE the emission here: their kills are the join.
            this.applyJoinedNarrowKills(ctx, probeJoin);
            return { code: `if (${condText}) ${thenCode} else ${elseCode}` };
          }
          // A branch needing lowered statements: re-emit each into a nested
          // block assigning a named temp (the R17b lowering the plain
          // conditional path uses). probeJoin is discarded with the probe
          // lines — the re-emissions below record the real kills.
          const chainJoin = new Set<string>();
          const t2 = expected ?? this.zTypeOfExpr(expr, ctx);
          const name = this.freshName(ctx, nameHint ?? "value");
          this.push(ctx, `var ${name}: ${this.table.zigTypeRef(t2)} = undefined;`);
          this.push(ctx, `if (${condText}) {`);
          const nt = this.nestedCtx(ctx);
          const ntCode = this.withNarrowScope(ctx, "merge", () => isAnd
            ? emitNarrowed(nt, expr.whenTrue, narrowedExpected)
            : this.emitExpr(expr.whenTrue, nt, expected ? unwrapOptional(expected) : expected).code, chainJoin);
          nt.lines.push("    ".repeat(nt.indent) + `${name} = ${ntCode};`);
          ctx.lines.push(...nt.lines);
          this.push(ctx, `} else {`);
          const ne = this.nestedCtx(ctx);
          const neCode = this.withNarrowScope(ctx, "merge", () => isAnd
            ? this.emitExpr(expr.whenFalse, ne, expected).code
            : emitNarrowed(ne, expr.whenFalse, expected), chainJoin);
          ne.lines.push("    ".repeat(ne.indent) + `${name} = ${neCode};`);
          ctx.lines.push(...ne.lines);
          this.push(ctx, `}`);
          this.applyJoinedNarrowKills(ctx, chainJoin);
          return { code: name };
        }
      }
    }

    // R13c: kind guards narrow the branch TS narrows, in ternaries too.
    const posGuard = this.kindGuardOf(cond);
    const negGuard = this.kindGuardOf(cond, ts.SyntaxKind.ExclamationEqualsEqualsToken);
    // Branches that need lowered statements (spreads): lower via a named
    // temp. Each arm probes and emits from the ENTRY state, kills joining
    // after the last arm (see childCtx's isolation law).
    const probeJoin = new Set<string>();
    const thenSub = this.childCtx(ctx);
    const thenV = this.withNarrowScope(ctx, "merge", () => this.withKindNarrow(posGuard, ctx, () =>
      this.emitExpr(expr.whenTrue, thenSub, expected ? unwrapOptional(expected) : expected),
    ), probeJoin);
    const elseSub = this.childCtx(ctx);
    const elseV = this.withNarrowScope(ctx, "merge", () =>
      this.withKindNarrow(negGuard, ctx, () => this.emitExpr(expr.whenFalse, elseSub, expected)), probeJoin);
    // The condition is evaluated exactly once, so it may lower statements
    // (array-method scans) into the surrounding ctx ahead of the branch.
    const condText = this.emitExpr(cond, ctx, { k: "bool" }).code;
    if (thenSub.lines.length === 0 && elseSub.lines.length === 0) {
      // The probes ARE the emission here: their kills are the join.
      this.applyJoinedNarrowKills(ctx, probeJoin);
      return { code: `if (${condText}) ${thenV.code} else ${elseV.code}` };
    }
    // R17b-style lowering into an assignment target. probeJoin is discarded
    // with the probe lines — the re-emissions record the real kills.
    const join = new Set<string>();
    const t = expected ?? this.zTypeOfExpr(expr, ctx);
    const name = this.freshName(ctx, nameHint ?? "value");
    this.push(ctx, `var ${name}: ${this.table.zigTypeRef(t)} = undefined;`);
    this.push(ctx, `if (${condText}) {`);
    const ts1 = this.nestedCtx(ctx);
    const v1 = this.withNarrowScope(ctx, "merge", () => this.withKindNarrow(posGuard, ctx, () =>
      this.emitExpr(expr.whenTrue, ts1, expected ? unwrapOptional(expected) : expected),
    ), join);
    ts1.lines.push("    ".repeat(ts1.indent) + `${name} = ${v1.code};`);
    ctx.lines.push(...ts1.lines);
    this.push(ctx, `} else {`);
    const ts2 = this.nestedCtx(ctx);
    const v2 = this.withNarrowScope(ctx, "merge", () =>
      this.withKindNarrow(negGuard, ctx, () => this.emitExpr(expr.whenFalse, ts2, expected)), join);
    ts2.lines.push("    ".repeat(ts2.indent) + `${name} = ${v2.code};`);
    ctx.lines.push(...ts2.lines);
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
    return { code: name };
  }

  /// R7-narrowed ternary: `if (target) |cap| <narrowed> else <other>`, with
  /// the capture substitution active over the arm TS narrows. Arms whose
  /// emission lowers statements (a spread literal builds its arena copy
  /// line by line; a nested lowered ternary needs its temp) cannot ride an
  /// if-EXPRESSION arm — the pushed lines would land above the conditional,
  /// running BOTH arms unconditionally and reading the capture before it
  /// binds. Those take the R17b statement lowering instead: a typed temp
  /// assigned under a statement if/else, so exactly the taken arm's
  /// statements run, once.
  private emitNarrowedTernary(
    expr: ts.ConditionalExpression,
    targetExpr: ts.Expression,
    narrowedArm: ts.Expression,
    otherArm: ts.Expression,
    ctx: Ctx,
    expected: ZType | undefined,
    nameHint: string | undefined,
  ): Emitted {
    // The callers gate on a read of the target (anyReadsTarget), which a
    // keyless target can never satisfy — the key is present here.
    const key = this.narrowKey(targetExpr)!;
    const target = this.emitExpr(targetExpr, ctx).code;
    const cap = this.freshName(ctx, this.narrowHint(targetExpr));
    const emitNarrowedArm = (sub: Ctx): string => {
      const saved = ctx.memberSubst.get(key);
      ctx.memberSubst.set(key, cap);
      const code = this.emitExpr(narrowedArm, sub, expected ? unwrapOptional(expected) : undefined).code;
      ctx.memberSubst.delete(key);
      if (saved !== undefined) ctx.memberSubst.set(key, saved);
      return code;
    };
    // Probe both arms in throwaway child ctxs: statement-free arms keep
    // the tight expression form (the common case — numbers, tags, field
    // reads — stays exactly as before). Each arm probes and emits from the
    // ENTRY state, kills joining after the last arm (see childCtx's
    // isolation law).
    const probeJoin = new Set<string>();
    const narrowedSub = this.childCtx(ctx);
    const narrowedV = this.withNarrowScope(ctx, "merge", () => emitNarrowedArm(narrowedSub), probeJoin);
    const otherSub = this.childCtx(ctx);
    const otherV = this.withNarrowScope(ctx, "merge", () => this.emitExpr(otherArm, otherSub, expected).code, probeJoin);
    if (narrowedSub.lines.length === 0 && otherSub.lines.length === 0) {
      // The probes ARE the emission here: their kills are the join.
      this.applyJoinedNarrowKills(ctx, probeJoin);
      return { code: `if (${target}) |${cap}| ${narrowedV} else ${otherV}` };
    }
    // R17b-style lowering: re-emit each arm into its own scoped block
    // feeding the temp (the probe lines are discarded — they were never
    // pushed to ctx, and probeJoin drops with them; the re-emissions
    // record the real kills).
    const join = new Set<string>();
    const t = expected ?? this.zTypeOfExpr(expr, ctx);
    const name = this.freshName(ctx, nameHint ?? "value");
    this.push(ctx, `var ${name}: ${this.table.zigTypeRef(t)} = undefined;`);
    this.push(ctx, `if (${target}) |${cap}| {`);
    const ts1 = this.nestedCtx(ctx);
    const v1 = this.withNarrowScope(ctx, "merge", () => emitNarrowedArm(ts1), join);
    ts1.lines.push("    ".repeat(ts1.indent) + `${name} = ${v1};`);
    ctx.lines.push(...ts1.lines);
    this.push(ctx, `} else {`);
    const ts2 = this.nestedCtx(ctx);
    const v2 = this.withNarrowScope(ctx, "merge", () => this.emitExpr(otherArm, ts2, expected).code, join);
    ts2.lines.push("    ".repeat(ts2.indent) + `${name} = ${v2};`);
    ctx.lines.push(...ts2.lines);
    this.push(ctx, `}`);
    this.applyJoinedNarrowKills(ctx, join);
    return { code: name };
  }

  /// R19: one data-class method call. Mutating methods take the receiver's
  /// address (the checker has proven local ownership); the layer-3
  /// re-derivation stops any receiver the address rule cannot spell.
  private emitMethodCall(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    cls: ClassInfo,
    mDecl: ts.MethodDeclaration,
    ctx: Ctx,
  ): Emitted {
    const mName = (mDecl.name as ts.Identifier).text;
    const fnName = this.classFnNames.get(`${cls.name}#${mName}`)!;
    const mutates = cls.mutating.has(mName);
    const args = expr.arguments.map((a, i) => {
      const p = mDecl.parameters[i];
      const pt = p?.type ? this.resolveNumberClass(this.table.resolveTypeNode(p.type), p) : undefined;
      return this.emitExpr(a, ctx, pt).code;
    });
    let recv: string;
    const base = unwrapExpr(callee.expression);
    if (base.kind === ts.SyntaxKind.ThisKeyword) {
      if (!ctx.thisName) this.fail(expr, "`this` outside a class member body", "NS1006");
      if (mutates) {
        // The mutating-methods fixpoint marks every caller of a mutating
        // method mutating too, so `this` here is `*T` (or the ctor's local).
        recv = ctx.ctorSelf ? `&${ctx.thisName}` : ctx.thisName;
      } else {
        recv = ctx.thisSelfPtr ? `${ctx.thisName}.*` : ctx.thisName!;
      }
    } else if (mutates) {
      if (!ts.isIdentifier(base)) {
        this.fail(expr, `\`.${mName}()\` writes \`this\` on a receiver that is not a locally-owned binding (NS1001/NS1051)`, "NS1001");
      }
      recv = `&${this.emitExpr(callee.expression, ctx).code}`;
    } else {
      recv = this.emitExpr(callee.expression, ctx).code;
    }
    const code = `${fnName}(${[recv, ...args].join(", ")})`;
    return { code: this.leakingFns.has(mDecl) ? this.wrapThrowingCall(code, ctx) : code };
  }

  private emitNew(expr: ts.NewExpression, ctx: Ctx): Emitted {
    if (ts.isIdentifier(expr.expression) && expr.expression.text === "Uint8Array") {
      const arg = expr.arguments?.[0];
      if (!arg || (ts.isNumericLiteral(arg) && arg.text === "0")) {
        return { code: `empty_bytes` };
      }
      // R11: `new Uint8Array(n)` -> frame-arena alloc (fresh, writable).
      return { code: `rt.frameAlloc(u8, ${this.emitIndex(arg, ctx)})` };
    }
    // R19: `new Task(...)` calls the class's emitted constructor fn.
    if (ts.isIdentifier(expr.expression)) {
      const cls = this.table.classes.get(expr.expression.text);
      const decl = this.tast.declarationOf(expr.expression);
      if (cls && decl === cls.decl) {
        const fnName = this.classFnNames.get(`${cls.name}#new`)!;
        const ctorParams = cls.ctor?.parameters ?? [];
        const args = (expr.arguments ?? []).map((a, i) => {
          const cp = ctorParams[i];
          const pt = cp?.type ? this.resolveNumberClass(this.table.resolveTypeNode(cp.type), cp) : undefined;
          return this.emitExpr(a, ctx, pt).code;
        });
        const code = `${fnName}(${args.join(", ")})`;
        return { code: cls.ctor !== null && this.leakingFns.has(cls.ctor) ? this.wrapThrowingCall(code, ctx) : code };
      }
    }
    this.fail(expr, "`new` outside Uint8Array and this core's data classes");
  }

  private emitTemplate(expr: ts.TemplateExpression, ctx: Ctx): Emitted {
    // R18: template literal -> std.fmt.bufPrint into a comptime-max buffer.
    let fmt = escapeZigString(expr.head.text);
    let width = expr.head.text.length;
    const args: string[] = [];
    for (const span of expr.templateSpans) {
      const cls = this.infer.classOfExpr(span.expression);
      if (cls !== "i64") {
        this.fail(span.expression, "non-integer template hole (JS float ToString fidelity is an rt v2 surface)");
      }
      fmt += "{d}";
      width += 20; // i64 digits + sign
      args.push(this.emitExpr(span.expression, ctx).code);
      fmt += escapeZigString(span.literal.text);
      width += span.literal.text.length;
    }
    const buf = this.freshName(ctx, "buf");
    const text = this.freshName(ctx, "text");
    this.push(ctx, `const ${buf} = rt.frameAlloc(u8, ${width});`);
    this.push(ctx, `const ${text} = std.fmt.bufPrint(${buf}, "${fmt}", .{ ${args.join(", ")} }) catch unreachable;`);
    return { code: text };
  }

  // ------------------------------------------------------------------ calls

  private emitCall(expr: ts.CallExpression, ctx: Ctx, expected?: ZType, nameHint?: string): Emitted {
    const callee = expr.expression;
    // `g?.()` calls a possibly-absent FUNCTION VALUE — that stays taught
    // (NS1046/NS1054 territory), unlike a `?.method()` over a nullable
    // RECEIVER, which null-propagates like every other chain hop.
    if (expr.questionDotToken) {
      this.fail(expr, "optional call `?.()` (guard the function value first)");
    }
    if (ts.isPropertyAccessExpression(callee) && ts.isOptionalChain(callee)) {
      const recvT = this.zTypeOfExpr(callee.expression, ctx);
      if (recvT.k === "optional") {
        return this.emitOptionalReceiverCall(expr, callee, ctx, nameHint);
      }
      // A chain marker over a base that can never be null: JS proceeds
      // unconditionally, so the call emits plain.
    }

    if (ts.isPropertyAccessExpression(callee)) {
      const method = callee.name.text;
      // Layer-3 re-derivation of NS1017: Cmd factories are only reachable
      // through the pair-return lowering (emitReturn -> emitCmdExpr); the
      // Sub factories mirror it through NS1025.
      if (this.isCmdNamespace(callee.expression)) {
        this.fail(expr, `Cmd.${method} outside update's return path (NS1017)`);
      }
      if (this.isSubNamespace(callee.expression)) {
        this.fail(expr, `Sub.${method} outside subscriptions' return path (NS1025)`, "NS1025");
      }
      // R15c: `ns.helper(x)` through an `import * as ns` — a direct call of
      // the target module's function under its flat emitted name.
      if (this.isNamespaceAliasBase(callee.expression)) {
        const decl = this.tast.declarationOf(callee.name);
        if (decl && ts.isFunctionDeclaration(decl)) {
          if (this.isSdkIntrinsic(decl, "asciiBytes")) {
            this.fail(expr, "asciiBytes through a namespace alias (import it by name)");
          }
          const args: string[] = [];
          expr.arguments.forEach((a, i) => {
            const p = decl.parameters[i];
            const pt = p?.type ? this.resolveNumberClass(this.table.resolveTypeNode(p.type), p) : undefined;
            args.push(this.emitExpr(a, ctx, pt).code);
          });
          let name = this.moduleNameOf(decl) ?? this.fail(expr, `namespace call \`${expr.getText()}\``);
          const throwsOut = this.leakingFns.has(decl);
          if (throwsOut && this.isExportedDecl(decl)) name = `${name}__throws`;
          const code = `${name}(${args.join(", ")})`;
          return { code: throwsOut ? this.wrapThrowingCall(code, ctx) : code };
        }
        this.fail(expr, `namespace call \`${callee.getText()}\` (no emitted function by that name)`);
      }
      // R8: Math.min/max -> @min/@max on integer sites. Float sites take the
      // rt helpers instead: JS propagates NaN and orders -0 below +0, while
      // the builtins resolve NaN to the other operand and pick either zero.
      if (ts.isIdentifier(callee.expression) && callee.expression.text === "Math") {
        // R8: a Math call over comptime-evaluable arguments folds to its JS
        // value (the same fold module consts take) — integer-classed folds
        // stay integer literals, everything else spells the exact f64.
        const folded = this.tast.constEvalNumber(expr);
        if (folded !== null) {
          const intish =
            Number.isInteger(folded) && !Object.is(folded, -0) && this.infer.classOfExpr(expr) === "i64";
          return { code: intish ? String(folded) : f64Literal(folded) };
        }
        if (method === "min" || method === "max") {
          // JS Math.min() is Infinity and Math.max() is -Infinity (folded
          // above via constEvalNumber); one argument is the identity.
          if (expr.arguments.length === 0) {
            return { code: f64Literal(method === "min" ? Infinity : -Infinity) };
          }
          if (expr.arguments.length === 1) return this.emitExpr(expr.arguments[0], ctx);
          // R8 + R2: one float argument makes the site float — integer reads
          // among the arguments widen exactly so the operands peer-resolve.
          // Float sites take the rt helpers: JS propagates NaN and orders -0
          // below +0, while Zig's builtins do neither.
          const anyFloat = expr.arguments.some((a) => this.infer.classOfExpr(a) === "f64");
          const args = expr.arguments.map((a) => {
            const code = this.emitExpr(a, ctx).code;
            return anyFloat ? this.widenToF64(a, code, ctx) : code;
          });
          if (anyFloat) {
            const helper = method === "min" ? "rt.jsMin" : "rt.jsMax";
            return { code: args.reduce((acc, a) => (acc === "" ? a : `${helper}(${acc}, ${a})`), "") };
          }
          return { code: `@${method}(${args.join(", ")})` };
        }
        if (method === "floor" || method === "ceil" || method === "trunc" || method === "abs" || method === "sign") {
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, `Math.${method} arity`);
          const code = this.emitExpr(arg, ctx).code;
          if (this.infer.classOfExpr(arg) === "i64") {
            // An integer is its own floor/ceil/trunc; abs and sign stay
            // integer-valued (JS integers fit i64, so -x cannot overflow).
            if (method === "abs") return { code: `@as(i64, @intCast(@abs(${code})))` };
            if (method === "sign") return { code: `std.math.sign(${code})` };
            return { code };
          }
          // Float sites: @floor/@ceil/@trunc/@abs are the IEEE operations JS
          // specifies (NaN/Infinity propagate; -0 corners: floor/ceil/trunc
          // keep the zero sign, abs clears it). Math.sign needs rt.jsSign —
          // it must return NaN for NaN and the signed zero itself.
          const widened = this.widenToF64(arg, code, ctx);
          if (method === "sign") return { code: `rt.jsSign(${widened})` };
          return { code: `@${method}(${widened})` };
        }
        if (method === "sqrt") {
          // Always float-valued (irrational off perfect squares); @sqrt is
          // IEEE: sqrt(-0) is -0, sqrt of a negative is NaN.
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, "Math.sqrt arity");
          const code = this.widenToF64(arg, this.emitExpr(arg, ctx).code, ctx);
          return { code: `@sqrt(${code})` };
        }
        if (method === "round") {
          // JS rounds half toward positive infinity with exact .5 handling
          // and signed-zero preservation; rt.jsRound carries those semantics.
          // The result is always float-classed (round of NaN/Infinity is not
          // an integer), so index positions stay a taught NS1016.
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, "Math.round arity");
          const code = this.widenToF64(arg, this.emitExpr(arg, ctx).code, ctx);
          return { code: `rt.jsRound(${code})` };
        }
        this.fail(expr, `Math.${method} (v1 maps floor/ceil/trunc/abs/sign/sqrt/round/min/max)`);
      }
      // Number.isInteger / isFinite / isNaN: on an integer-classed argument
      // the answer is a constant; float arguments take the IEEE classifiers.
      if (ts.isIdentifier(callee.expression) && callee.expression.text === "Number") {
        if (method === "isInteger" || method === "isFinite" || method === "isNaN") {
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, `Number.${method} arity`);
          const code = this.emitExpr(arg, ctx).code;
          if (this.infer.classOfExpr(arg) === "i64") {
            return { code: method === "isNaN" ? "false" : "true" };
          }
          const widened = this.widenToF64(arg, code, ctx);
          if (method === "isInteger") return { code: `rt.jsIsInteger(${widened})` };
          if (method === "isFinite") return { code: `std.math.isFinite(${widened})` };
          return { code: `std.math.isNan(${widened})` };
        }
        this.fail(expr, `Number.${method} (v1 maps isInteger/isFinite/isNaN)`);
      }
      // R19: a data-class method call dispatches to its module fn —
      // `t.rename(x)` -> `Task__rename(&t, x)` (pointer receiver when the
      // method writes `this`, by-value receiver otherwise). A STATIC method
      // call (`Task.fromRow(...)`) dispatches receiver-less.
      {
        const mDecl = this.tast.declarationOf(callee.name);
        if (mDecl && ts.isMethodDeclaration(mDecl) && ts.isClassDeclaration(mDecl.parent) && mDecl.parent.name) {
          const cls = this.table.classes.get(mDecl.parent.name.text);
          if (cls && cls.decl === mDecl.parent) {
            if (isStaticMember(mDecl)) {
              const fnName = this.classFnNames.get(`${cls.name}#${(mDecl.name as ts.Identifier).text}`)!;
              const args = expr.arguments.map((a, i) => {
                const p = mDecl.parameters[i];
                const pt = p?.type ? this.resolveNumberClass(this.table.resolveTypeNode(p.type), p) : undefined;
                return this.emitExpr(a, ctx, pt).code;
              });
              const code = `${fnName}(${args.join(", ")})`;
              return { code: this.leakingFns.has(mDecl) ? this.wrapThrowingCall(code, ctx) : code };
            }
            return this.emitMethodCall(expr, callee, cls, mDecl, ctx);
          }
        }
      }
      const baseT = this.zTypeOfExpr(callee.expression, ctx);
      if (baseT.k === "bytes") {
        if (method === "subarray") {
          // R11: `.subarray(a, b)` -> slice (view, no copy), with JS bound
          // resolution: negatives count from the end and both bounds clamp
          // into [0, len] (rt.subarray) — out-of-range bounds view less,
          // never trap, exactly like `.slice`.
          if (expr.arguments.length > 2) this.fail(expr, "subarray arity");
          const base = this.emitExpr(callee.expression, ctx).code;
          if (expr.arguments.length === 0) return { code: base };
          const a = this.emitExpr(expr.arguments[0], ctx).code;
          const b = expr.arguments[1] ? this.emitExpr(expr.arguments[1], ctx).code : "null";
          return { code: `rt.subarray(${base}, ${a}, ${b})` };
        }
        if (method === "slice") {
          // R11: `.slice(a, b)` -> arena alloc + copy (slice() always
          // copies), with JS index resolution: negatives count from the end
          // and both bounds clamp into [0, len] (rt.sliceIndex), the same
          // rule as array .slice — out-of-range bounds copy less, never trap.
          if (expr.arguments.length > 2) this.fail(expr, "slice arity");
          const base = this.emitExpr(callee.expression, ctx).code;
          const copy = this.freshName(ctx, nameHint ?? "copy");
          if (expr.arguments.length === 0) {
            this.push(ctx, `const ${copy} = rt.frameAlloc(u8, ${base}.len);`);
            this.push(ctx, `@memcpy(${copy}, ${base});`);
            return { code: copy };
          }
          const lo = this.freshName(ctx, `${copy}_from`);
          const a = this.emitExpr(expr.arguments[0], ctx).code;
          this.push(ctx, `const ${lo} = rt.sliceIndex(${base}.len, ${a});`);
          let hi = `${base}.len`;
          if (expr.arguments[1]) {
            hi = this.freshName(ctx, `${copy}_to`);
            const b = this.emitExpr(expr.arguments[1], ctx).code;
            this.push(ctx, `const ${hi} = @max(${lo}, rt.sliceIndex(${base}.len, ${b}));`);
          }
          this.push(ctx, `const ${copy} = rt.frameAlloc(u8, ${hi} - ${lo});`);
          this.push(ctx, `@memcpy(${copy}, ${base}[${lo}..${hi}]);`);
          return { code: copy };
        }
        if (method === "join") return this.emitBytesJoin(expr, callee, ctx, nameHint);
        // R11t: the everyday string-method surface on bytes — byte-honest
        // semantics (byte lengths/offsets, byte-wise search, simple case
        // mapping), each lowered onto its rt text helper. The node devhost
        // polyfills the same methods from the same generated tables.
        if (method === "toUpperCase" || method === "toLowerCase") {
          if (expr.arguments.length !== 0) this.fail(expr, `${method} arity (no arguments — locale forms stay out)`);
          const base = this.emitExpr(callee.expression, ctx).code;
          return { code: `rt.${method === "toUpperCase" ? "textUpper" : "textLower"}(${base})` };
        }
        if (method === "repeat") {
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, "repeat arity (the count)");
          const folded = this.tast.constEvalNumber(arg);
          if (folded !== null && (folded < 0 || !Number.isInteger(folded))) {
            this.fail(arg, `repeat count ${folded} (JS throws RangeError below 0 and truncates fractions; pass a non-negative integer)`);
          }
          const base = this.emitExpr(callee.expression, ctx).code;
          return { code: `rt.textRepeat(${base}, ${this.emitExpr(arg, ctx).code})` };
        }
        if (method === "startsWith" || method === "endsWith" || method === "includes" || method === "indexOf" || method === "lastIndexOf") {
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) {
            this.fail(expr, `${method} arity (v1 takes the needle only — no position/fromIndex)`);
          }
          const base = this.emitExpr(callee.expression, ctx).code;
          const argT = this.zTypeOfExpr(arg, ctx);
          if (argT.k === "bytes") {
            const needle = this.emitExpr(arg, ctx, { k: "bytes" }).code;
            const helper = { startsWith: "textStartsWith", endsWith: "textEndsWith", includes: "textIncludes", indexOf: "textIndexOf", lastIndexOf: "textLastIndexOf" }[method];
            return { code: `rt.${helper}(${base}, ${needle})` };
          }
          if (method === "startsWith" || method === "endsWith") {
            this.fail(arg, `${method} needle \`${arg.getText()}\` (bytes — asciiBytes for literals)`);
          }
          // The number form keeps JS TypedArray element search (one byte
          // value, SameValueZero) — the dispatch-by-argument-type rule.
          const needle = this.widenToF64(arg, this.emitExpr(arg, ctx).code, ctx);
          const helper = { includes: "textIncludesByte", indexOf: "textIndexOfByte", lastIndexOf: "textLastIndexOfByte" }[method];
          return { code: `rt.${helper}(${base}, ${needle})` };
        }
        if (method === "padStart" || method === "padEnd") {
          const nArg = expr.arguments[0];
          if (!nArg || expr.arguments.length > 2) this.fail(expr, `${method} arity (target byte length, optional fill bytes)`);
          const fillArg = expr.arguments[1];
          if (fillArg && this.zTypeOfExpr(fillArg, ctx).k !== "bytes") {
            this.fail(fillArg, `${method} fill \`${fillArg.getText()}\` (bytes — asciiBytes for literals)`);
          }
          const base = this.emitExpr(callee.expression, ctx).code;
          const n = this.emitExpr(nArg, ctx).code;
          const fill = fillArg ? this.emitExpr(fillArg, ctx, { k: "bytes" }).code : `" "`;
          return { code: `rt.${method === "padStart" ? "textPadStart" : "textPadEnd"}(${base}, ${n}, ${fill})` };
        }
        if (method === "trim" || method === "trimStart" || method === "trimEnd") {
          if (expr.arguments.length !== 0) this.fail(expr, `${method} arity`);
          const base = this.emitExpr(callee.expression, ctx).code;
          const helper = { trim: "textTrim", trimStart: "textTrimStart", trimEnd: "textTrimEnd" }[method];
          return { code: `rt.${helper}(${base})` };
        }
        if (method === "split") {
          const sep = expr.arguments[0];
          if (!sep || expr.arguments.length !== 1) {
            this.fail(expr, "split arity (one bytes separator; the limit argument is not in v1)");
          }
          if (this.zTypeOfExpr(sep, ctx).k !== "bytes") {
            this.fail(sep, `split separator \`${sep.getText()}\` (bytes — asciiBytes for literals)`);
          }
          if (this.literalBytesLength(sep) === 0) {
            this.fail(sep, "split with an empty separator (JS splits per UTF-16 code unit there, which would expose the encoding seam; slice byte ranges instead)");
          }
          const base = this.emitExpr(callee.expression, ctx).code;
          return { code: `rt.textSplit(${base}, ${this.emitExpr(sep, ctx, { k: "bytes" }).code})` };
        }
        if (method === "at") {
          const arg = expr.arguments[0];
          if (!arg || expr.arguments.length !== 1) this.fail(expr, "at arity (one byte index)");
          const base = this.emitExpr(callee.expression, ctx).code;
          return { code: `rt.textAt(${base}, ${this.emitExpr(arg, ctx).code})` };
        }
        this.fail(expr, `Bytes method .${method} in value position`);
      }
      if (baseT.k === "slice") {
        // A callback may not change the LENGTH of the array its own method
        // iterates: the emitted loop is bounded by the snapshot length,
        // while JS bounds each visit by the live array.
        {
          const iterBase = unwrapExpr(callee.expression);
          const iterDecl = ts.isIdentifier(iterBase) ? this.tast.declarationOf(iterBase) : undefined;
          if (iterDecl && ctx.builders.has(iterDecl)) {
            for (const arg of expr.arguments) {
              if (ts.isArrowFunction(arg) && this.mutatesLengthOf(arg, iterDecl)) {
                this.fail(
                  expr,
                  `changing the length of the array .${method} iterates from inside its callback (JS bounds the walk by the live array; collect into a second builder instead)`,
                );
              }
            }
          }
        }
        if (method === "pop" || method === "shift") {
          return this.emitPopShift(expr, callee.expression, method, ctx, { statement: false, nameHint });
        }
        if (method === "splice") {
          return this.emitSplice(expr, callee.expression, baseT, ctx, { statement: false, nameHint });
        }
        if (method === "sort" || method === "reverse" || method === "fill") {
          this.fail(
            expr,
            `\`.${method}\` in value position (the JS value is the same array; mutate as its own statement, then use the array by name)`,
          );
        }
        if (method === "unshift") {
          this.fail(
            expr,
            "`.unshift` in value position (the JS value is the new length; unshift as a statement and read `out.length` after it)",
          );
        }
        if (method === "map") return this.emitMap(expr, callee, baseT, ctx, expected, nameHint);
        if (method === "filter") return this.emitFilter(expr, callee, baseT, ctx, nameHint);
        if (method === "find" || method === "findIndex" || method === "some" || method === "every") {
          return this.emitPredicateScan(expr, callee, baseT, method, ctx, nameHint);
        }
        if (method === "reduce") return this.emitReduce(expr, callee, baseT, ctx);
        if (method === "slice") return this.emitArraySlice(expr, callee, baseT, ctx, nameHint);
        if (method === "concat") return this.emitConcat(expr, callee, baseT, ctx, nameHint);
        if (method === "toSorted") return this.emitToSorted(expr, callee, baseT, ctx, nameHint);
        if (method === "indexOf" || method === "includes") {
          return this.emitEqualityScan(expr, callee, baseT, method, ctx, nameHint);
        }
        if (method === "join") {
          // The elementwise template-hole rule: number-array elements are
          // f64-classed, and float ToString fidelity is an rt v2 surface.
          this.fail(expr, "`.join` on a number array (elements are float-valued; join byte values instead)");
        }
        if (method === "push") {
          // Statement-position pushes lowered in tryEmitPushCall land here
          // only when the JS return value (the new length) is consumed.
          this.fail(
            expr,
            "`.push` in value position (the JS value is the new length; push as a statement and read `out.length` after it)",
          );
        }
        this.fail(
          expr,
          `array method .${method} (v1 maps map/filter/find/findIndex/some/every/reduce/slice/concat/toSorted/indexOf/includes/spread, plus push/pop/shift/unshift/splice/reverse/fill/sort on locally-owned arrays)`,
        );
      }
      this.fail(expr, `method call .${method}`);
    }

    if (ts.isIdentifier(callee)) {
      const decl = this.tast.declarationOf(callee);
      // R3b: the SDK `asciiBytes` intrinsic folds at compile time — a literal
      // argument becomes rodata, a template becomes frame-arena bytes.
      if (decl && this.isSdkIntrinsic(decl, "asciiBytes")) {
        const arg = expr.arguments[0];
        if (ts.isStringLiteral(arg)) return { code: `"${escapeZigString(arg.text)}"` };
        if (ts.isTemplateExpression(arg)) return this.emitTemplate(arg, ctx);
        this.fail(arg, "asciiBytes argument (a string literal or template only)");
      }
      // R15e: a call of a user-declared generic instantiates it from tsc's
      // RESOLVED type arguments — one monomorphic fn per distinct list.
      if (decl && ts.isFunctionDeclaration(decl) && decl.typeParameters && decl.typeParameters.length > 0) {
        return this.emitGenericCall(expr, decl, ctx);
      }
      const args: string[] = [];
      // R15d: a direct call of a hoisted local helper types its arguments
      // by the helper's own annotated parameters, like any declaration.
      const hoisted = decl && ts.isVariableDeclaration(decl) ? this.hoistedFns.get(decl) : undefined;
      const params = decl && ts.isFunctionDeclaration(decl) ? decl.parameters : hoisted?.parameters;
      expr.arguments.forEach((a, i) => {
        const p = params?.[i];
        const pt = p?.type ? this.resolveNumberClass(this.table.resolveTypeNode(p.type), p) : undefined;
        args.push(this.emitExpr(a, ctx, pt).code);
      });
      let name = this.emitExpr(callee, ctx).code;
      // R20: calls of leaking functions route the error — to the enclosing
      // catch, or onward to this function's own caller.
      const leakKey = decl && (ts.isFunctionDeclaration(decl) || (ts.isVariableDeclaration(decl) && this.hoistedFns.has(decl))) ? decl : null;
      const throwsOut = leakKey !== null && this.leakingFns.has(leakKey);
      if (throwsOut && decl && ts.isFunctionDeclaration(decl) && this.isExportedDecl(decl)) name = `${name}__throws`;
      const code = `${name}(${args.join(", ")})`;
      return { code: throwsOut ? this.wrapThrowingCall(code, ctx) : code };
    }
    this.fail(expr, "call shape");
  }

  /// R15e: lower a call of a user-declared generic function. tsc's own
  /// signature resolution supplies the type arguments (explicit and
  /// inferred alike); each maps to a concrete ZType (a bare `number`
  /// instantiates f64, the JS-exact class), the instantiation dedupes by
  /// its readable mangled name (`pick__Task`, `pick__f64`), and the call
  /// emits against the instantiated signature. Inside a template body a
  /// type argument may still BE a type parameter — the active scope
  /// resolves it (generics calling generics).
  private emitGenericCall(expr: ts.CallExpression, decl: ts.FunctionDeclaration, ctx: Ctx): Emitted {
    const fnName = decl.name?.text ?? "<anonymous>";
    const tps = decl.typeParameters!;
    const resolved = this.resolvedGenericArgs(expr, decl);
    if (resolved === null) {
      this.fail(expr, `generic \`${fnName}\` called without resolvable type arguments`, "NS1053");
    }
    for (let i = 0; i < tps.length; i++) {
      if (resolved[i].k === "void") {
        this.fail(
          expr,
          `generic \`${fnName}\`: type argument \`${tps[i].name.text}\` does not resolve to a concrete emitted type`,
          "NS1053",
        );
      }
    }
    const base = this.moduleNameOf(decl) ?? fnName;
    const mangle = `${base}__${resolved.map(mangleZType).join("__")}`;
    let inst = this.genericInsts.get(mangle);
    if (!inst) {
      let name = mangle;
      let n = 2;
      while (this.genericNames.has(name) || this.moduleScopeNames().has(name)) name = `${mangle}_${n++}`;
      this.genericNames.add(name);
      const scope = new Map<ts.Declaration, ZType>();
      tps.forEach((tp, i) => scope.set(tp, resolved[i]));
      inst = { decl, scope, name, args: resolved };
      this.genericInsts.set(mangle, inst);
      this.genericQueue.push(mangle);
    }
    // Parameter expected types resolve under the CALLEE's scope; argument
    // emission runs under the caller's (still-active) scope.
    const pts = this.table.withTypeParams(
      inst.scope,
      () =>
        decl.parameters.map((p) =>
          p.type ? this.resolveNumberClass(this.table.resolveTypeNode(p.type), p) : undefined,
        ),
    );
    const args: string[] = [];
    expr.arguments.forEach((a, i) => {
      args.push(this.emitExpr(a, ctx, pts[i]).code);
    });
    const code = `${inst.name}(${args.join(", ")})`;
    return { code: this.leakingFns.has(decl) ? this.wrapThrowingCall(code, ctx) : code };
  }

  /// The resolved-and-mapped type arguments of a generic call (a bare
  /// `number` maps to f64 — the class every JS value fits exactly; integer
  /// proof never crosses a type parameter). A slot that cannot map at all
  /// is `void` in the list; null when tsc resolves no arguments.
  private resolvedGenericArgs(expr: ts.CallExpression, decl: ts.FunctionDeclaration): ZType[] | null {
    const tps = decl.typeParameters!;
    const targs = this.tast.resolvedCallTypeArguments(expr);
    if (!targs || targs.length < tps.length) return null;
    return tps.map((_, i) => {
      const z = this.table.zTypeOfTsType(targs[i]);
      if (!z || z.k === "void") return { k: "void" } as ZType;
      return z.k === "number" ? ({ k: "f64" } as ZType) : z;
    });
  }

  /// The instantiation scope a generic CALL resolves under, or null.
  private genericScopeOfCall(
    expr: ts.CallExpression,
    decl: ts.FunctionDeclaration,
  ): Map<ts.Declaration, ZType> | null {
    const resolved = this.resolvedGenericArgs(expr, decl);
    if (resolved === null) return null;
    const scope = new Map<ts.Declaration, ZType>();
    decl.typeParameters!.forEach((tp, i) => scope.set(tp, resolved[i]));
    return scope;
  }

  /// The callback argument of an array-method call, with a bare function
  /// reference resolved to its declaration: a const-bound local helper
  /// (arrow or function expression) resolves to its function node, and a
  /// module-level `function` declaration resolves to itself. Every resolved
  /// form is capture-free with real bound parameters, so inlining the body
  /// at the use site is exact — `xs.map(encodeTurn)` is `xs.map((t) =>
  /// <encodeTurn's body>)`. Generic declarations stay unresolved (their
  /// bodies need instantiation; wrap the call in an arrow).
  private callbackArg(expr: ts.CallExpression, i: number): ts.Expression | ts.FunctionDeclaration | undefined {
    const arg = expr.arguments[i];
    if (arg && ts.isIdentifier(arg)) {
      const decl = this.tast.declarationOf(arg);
      if (decl && ts.isVariableDeclaration(decl)) {
        const fn = this.hoistedFns.get(decl);
        if (fn) return fn;
      }
      if (decl && ts.isFunctionDeclaration(decl) && decl.body && !(decl.typeParameters && decl.typeParameters.length > 0)) {
        return decl;
      }
    }
    return arg;
  }

  /// R10b: a `++`/`--`/assignment consumed as a value. The lowering runs
  /// the step as its own statement and reads the variable back (JS's value
  /// for every operator form once valuePositionStep proves the split is
  /// order-exact); the postfix forms snapshot the pre-step value first.
  private emitValueStep(
    expr: ts.Expression,
    target: ts.Expression,
    ctx: Ctx,
    opts: { preStep: boolean },
  ): Emitted {
    const verdict = valuePositionStep(expr, target, this.tast);
    if (!verdict.ok) {
      this.fail(
        expr,
        `a \`++\`/\`--\`/assignment in a value position the split statement cannot pin — ${verdict.why} (step as its own statement, then read the variable)`,
        "NS1043",
      );
    }
    const name = this.emitExpr(unwrapExpr(target), ctx).code;
    if (opts.preStep) {
      this.emitExpressionStatement(expr, ctx);
      return { code: name };
    }
    const snap = this.freshName(ctx, `${name}_was`);
    this.push(ctx, `const ${snap} = ${name};`);
    this.emitExpressionStatement(expr, ctx);
    return { code: snap };
  }

  /// R7b (method hop): `xs?.slice()` — a mapped method call over a nullable
  /// receiver lowers to a captured if-statement: the receiver evaluates
  /// once, the method lowering (loops and copies included) runs inside the
  /// non-null arm, and the value is the optional the chain short-circuit
  /// makes (JS undefined folds into the one native empty, like every hop).
  private emitOptionalReceiverCall(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    const recv = callee.expression;
    const recvCode = this.emitExpr(recv, ctx).code;
    const hint = ts.isPropertyAccessExpression(recv)
      ? zigLocalName(recv.name.text)
      : ts.isIdentifier(recv)
        ? zigLocalName(recv.text)
        : "recv";
    const cap = this.freshName(ctx, hint);
    const sub = this.nestedCtx(ctx);
    sub.memberSubst = new Map(ctx.memberSubst);
    // The rewrite targets exactly this receiver NODE (emitCall re-emits
    // it under the capture). A receiver without a canonical narrowing key
    // still needs the rewrite, so it gets a node-scoped key — unique to
    // the node, never a narrowing fact another occurrence could match.
    let recvKey = this.narrowKey(recv);
    if (recvKey === null) {
      recvKey = `@recv#${this.narrowKeyNextId++}`;
      this.nodeNarrowKeys.set(recv, recvKey);
    }
    sub.memberSubst.set(recvKey, cap);
    const inner = this.emitCall(expr, sub, undefined, nameHint);
    const resT = this.zTypeOfExprClassed(expr, sub);
    if (resT.k === "void") this.fail(expr, `optional-chain call .${callee.name.text} without a mapped value type`);
    const optT: ZType = resT.k === "optional" ? resT : { k: "optional", inner: resT };
    const rname = this.freshName(ctx, nameHint ?? `${hint}_${zigLocalName(callee.name.text)}`);
    this.push(ctx, `var ${rname}: ${this.table.zigTypeRef(optT)} = null;`);
    this.push(ctx, `if (${recvCode}) |${cap}| {`);
    ctx.lines.push(...sub.lines);
    const armCtx = { ...ctx, indent: ctx.indent + 1 };
    this.push(armCtx, `${rname} = ${inner.code};`);
    this.push(ctx, `}`);
    return { code: rname };
  }

  /// R17i: lift a callback body to a value inside the emitted loop body. An
  /// expression body inlines directly. A block body whose only `return` is
  /// the trailing statement lifts as straight-line statements plus that
  /// value; a body with early returns wraps in a labeled value block where
  /// every `return v` lowers to `break :label v` (returnText). Fresh labels
  /// per callback make one level of nesting fall out naturally.
  private emitCallbackValue(cb: CallbackFn, sub: Ctx, expected: ZType, hint: string): string {
    if (!ts.isBlock(cb.body)) {
      return this.emitExpr(cb.body, sub, expected).code;
    }
    if (!this.alwaysExits(cb.body)) {
      this.fail(
        cb,
        "a callback code path that falls off the end (JS would produce `undefined` there; end every path with an explicit `return`)",
      );
    }
    const body = cb.body.statements;
    // Every exit is terminal (a constant-true loop, or throws) with no
    // `return v` anywhere: tsc types the body `never`, but the labeled
    // value block below would carry a label no `break` uses — a Zig
    // compile error — and a callback that can never produce its value has
    // no useful emission anyway.
    if (!body.some((s) => containsReturn(s))) {
      this.fail(cb, "a callback none of whose paths returns a value (every path loops forever or throws)");
    }
    const last = body[body.length - 1];
    const earlyReturns = body.slice(0, -1).some((s) => containsReturn(s));
    if (last && ts.isReturnStatement(last) && last.expression && !earlyReturns) {
      // The prefix's guards narrow the trailing return's expression, so both
      // emit inside ONE flow scope — a scope around the prefix alone would
      // restore the maps before the expression they guard. The restore still
      // runs before the caller continues, so the callback's narrowing never
      // reaches its siblings in the emitted loop body.
      const trailing = last.expression;
      return this.withNarrowScope(sub, "merge", () => {
        this.emitStatementList(body.slice(0, -1), sub);
        return this.emitExpr(trailing, sub, expected).code;
      });
    }
    const label = this.freshName(sub, "cb");
    const name = this.freshName(sub, hint);
    this.push(sub, `const ${name}: ${this.table.zigTypeRef(expected)} = ${label}: {`);
    const inner = this.nestedCtx(sub);
    inner.retLabel = label;
    inner.cmdReturn = null;
    inner.subReturn = null;
    inner.returnType = expected;
    // The callback edge-kill stage: an arm that kills a narrow and then
    // `return`s exits along the lowered `break :label` edge, whose
    // destination is the continuation AFTER this value block — so its
    // kills apply here, once the block closes, and the arm's siblings and
    // the trailing in-callback flow keep the narrows tsc keeps there.
    const kills = this.stagedEdgeKills(sub, "callback", null, () => this.emitBlockStatements(body, inner));
    sub.lines.push(...inner.lines);
    this.push(sub, `};`);
    this.applyJoinedNarrowKills(sub, kills);
    return name;
  }

  /// R17m: bind a callback's index parameter (JS hands the element index as
  /// the second parameter) to the emitted loop index, widened into the
  /// parameter's inferred number class. Callbacks never take a third
  /// parameter (the JS array argument) — reference the array by name.
  private checkCallbackArity(expr: ts.CallExpression, cb: CallbackFn, method: string): void {
    if (cb.parameters.length > 2) {
      this.fail(
        expr,
        `a ${method} callback with more than (element, index) parameters (the third JS parameter is the array itself; reference the array by its own name instead)`,
      );
    }
  }

  /// Claim and bind an index parameter inside the loop body ctx. Returns the
  /// usize loop-capture name the emitted `for (..., 0..)` must bind, or null
  /// when the callback declares no (used) index. The source parameter claims
  /// its own name FIRST; the generated capture yields (`i` -> `i_2`), so the
  /// author's name survives into the emitted body.
  private bindIndexParam(cb: CallbackFn, sub: Ctx, existingCap?: string): string | null {
    const param = cb.parameters[1];
    if (!param || !this.identifierUsed(cb.body, param)) return null;
    const name = this.claim(sub, param, zigLocalName((param.name as ts.Identifier).text));
    const cap = existingCap ?? this.freshName(sub, "i");
    sub.localTypes.set(param, { k: "number" });
    const cls = this.infer.classOfDecl(param) ?? "i64";
    const value = cls === "f64" ? `@floatFromInt(${cap})` : `@intCast(${cap})`;
    this.push(sub, `const ${name}: ${cls} = ${value};`);
    return cap;
  }

  /// R17b: `.map(f)` -> exact-size alloc + inlined-callback loop. The output
  /// element type is the CALLBACK's result type — a type-changing map
  /// (`tasks.map(t => t.id)`) allocates what it produces, never the source
  /// element type.
  private emitMap(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    expected?: ZType,
    nameHint?: string,
  ): Emitted {
    const cb = this.callbackArg(expr, 0);
    if (!cb || !isCallbackFn(cb) || cb.parameters.length < 1) this.fail(expr, "map callback shape");
    this.checkCallbackArity(expr, cb, "map");
    const want = expected ? unwrapOptional(expected) : undefined;
    const resultElem =
      this.mapResultElem(expr, baseT, ctx) ?? (want?.k === "slice" ? want.elem : baseT.elem);
    const elemT = this.elemZType(resultElem);
    const base = this.emitExpr(callee.expression, ctx).code;
    const elemRef = this.table.zigTypeRef(elemT);
    const out = this.freshName(ctx, nameHint ?? "mapped");
    const param = cb.parameters[0];
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${base}.len);`);
    const sub = this.nestedCtx(ctx);
    // An element parameter the callback never reads captures as `_` (a named
    // unused capture is a Zig error).
    let elemName = "_";
    if (this.identifierUsed(cb.body, param)) {
      elemName = this.claim(sub, param, zigLocalName((param.name as ts.Identifier).text));
      sub.localTypes.set(param, baseT.elem);
    }
    const idx = this.bindIndexParam(cb, sub) ?? this.freshName(sub, "i");
    this.push(ctx, `for (${base}, 0..) |${elemName}, ${idx}| {`);
    if (ts.isBlock(cb.body)) {
      const v = this.emitCallbackValue(cb, sub, elemT, "elem");
      this.push(sub, `${out}[${idx}] = ${v};`);
    } else {
      this.emitAssignInto(`${out}[${idx}]`, cb.body, sub, elemT);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: out };
  }

  /// The element type a `.map` callback produces, typed from its returned
  /// expressions with the parameters bound. The value optionalizes when any
  /// return can be a JS empty (`x > 0 ? x : null`). Null when the returns
  /// carry no resolvable type (object literals type from the expected slot;
  /// the caller falls back to the contextual or source element type).
  private mapResultElem(
    expr: ts.CallExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
  ): ZType | null {
    const cb = this.callbackArg(expr, 0);
    if (!cb || !isCallbackFn(cb) || cb.parameters.length < 1) return null;
    const probe: Ctx = { ...ctx, localTypes: new Map(ctx.localTypes) };
    probe.localTypes.set(cb.parameters[0], baseT.elem);
    if (cb.parameters[1]) probe.localTypes.set(cb.parameters[1], { k: "number" });
    const rets = ts.isBlock(cb.body) ? returnExpressionsOf(cb.body) : [cb.body];
    let elem: ZType | null = null;
    let empty = false;
    for (const r of rets) {
      let e: ts.Expression = r;
      while (ts.isParenthesizedExpression(e)) e = e.expression;
      const empties = this.tast.emptiesOf(e);
      if (empties.null || empties.undefined) empty = true;
      if (e.kind === ts.SyntaxKind.NullKeyword) continue;
      if (elem === null) {
        const t = this.zTypeOfExpr(e, probe);
        if (t.k !== "void") elem = t;
      }
    }
    if (elem === null) return null;
    if (empty && elem.k !== "optional") return { k: "optional", inner: elem };
    return elem;
  }

  /// R17c: `.filter(f)` -> source-length alloc, fill, slice to count.
  private emitFilter(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    const cb = this.callbackArg(expr, 0);
    if (!cb || !isCallbackFn(cb) || cb.parameters.length < 1) this.fail(expr, "filter callback shape");
    this.checkCallbackArity(expr, cb, "filter");
    const base = this.emitExpr(callee.expression, ctx).code;
    const elemRef = this.table.zigTypeRef(baseT.elem);
    const out = this.freshName(ctx, nameHint ?? "kept");
    const lenVar = this.freshName(ctx, `${out}_len`);
    const param = cb.parameters[0];
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${base}.len);`);
    this.push(ctx, `var ${lenVar}: usize = 0;`);
    const sub = this.nestedCtx(ctx);
    const elemName = this.claim(sub, param, zigLocalName((param.name as ts.Identifier).text));
    sub.localTypes.set(param, baseT.elem);
    const idxCap = this.bindIndexParam(cb, sub);
    this.push(ctx, idxCap ? `for (${base}, 0..) |${elemName}, ${idxCap}| {` : `for (${base}) |${elemName}| {`);
    const cond = ts.isBlock(cb.body)
      ? this.emitCallbackValue(cb, sub, { k: "bool" }, "keep")
      : // Expression bodies may lower statements (a nested scan) into the
        // loop body — evaluated per iteration, exactly like JS.
        this.emitExpr(cb.body, sub, { k: "bool" }).code;
    sub.lines.push("    ".repeat(sub.indent) + `if (${cond}) {`);
    sub.lines.push("    ".repeat(sub.indent + 1) + `${out}[${lenVar}] = ${elemName};`);
    sub.lines.push("    ".repeat(sub.indent + 1) + `${lenVar} += 1;`);
    sub.lines.push("    ".repeat(sub.indent) + `}`);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: `${out}[0..${lenVar}]`, filterLen: lenVar };
  }

  /// The inlined predicate of a scan callback: an (element[, index])
  /// parameter list, an expression body or a lifted block body
  /// (emitCallbackValue). `idxCap` is the usize loop capture the emitted
  /// `for (..., 0..)` must bind when the callback uses its index.
  private scanPredicate(
    expr: ts.CallExpression,
    method: string,
    baseT: ZType & { k: "slice" },
    sub: Ctx,
  ): { elemName: string; cond: string; idxCap: string | null } {
    const cb = this.callbackArg(expr, 0);
    if (!cb || !isCallbackFn(cb) || cb.parameters.length < 1) {
      this.fail(expr, `${method} callback shape`);
    }
    this.checkCallbackArity(expr, cb, method);
    const param = cb.parameters[0];
    // `.find` copies the element out, so its capture is always read; the
    // other scans capture `_` when the predicate ignores the element.
    let elemName = "_";
    if (method === "find" || this.identifierUsed(cb.body, param)) {
      elemName = this.claim(sub, param, zigLocalName((param.name as ts.Identifier).text));
      sub.localTypes.set(param, baseT.elem);
    }
    const idxCap = this.bindIndexParam(cb, sub);
    const cond = ts.isBlock(cb.body)
      ? this.emitCallbackValue(cb, sub, { k: "bool" }, "matches")
      : // Expression bodies may lower statements (a nested scan) into the
        // loop body — evaluated per iteration, exactly like JS.
        this.emitExpr(cb.body, sub, { k: "bool" }).code;
    return { elemName, cond, idxCap };
  }

  /// R17d: predicate scans lower to an early-exit loop. `.find` yields the
  /// tier's one empty on a miss (?E — JS spells it undefined, tested with
  /// `=== undefined` or folded with `??`), `.findIndex` -1, and
  /// `.some`/`.every` their JS vacuous defaults (false / true).
  private emitPredicateScan(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    method: "find" | "findIndex" | "some" | "every",
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    const base = this.emitExpr(callee.expression, ctx).code;
    const hint = { find: "found", findIndex: "found_at", some: "any_match", every: "all_match" }[method];
    const out = this.freshName(ctx, nameHint ?? hint);
    const sub = this.nestedCtx(ctx);
    const inner = (line: string) => sub.lines.push("    ".repeat(sub.indent) + line);
    const innerDeep = (line: string) => sub.lines.push("    ".repeat(sub.indent + 1) + line);
    const forLine = (elemName: string, idxCap: string | null): string =>
      idxCap ? `for (${base}, 0..) |${elemName}, ${idxCap}| {` : `for (${base}) |${elemName}| {`;
    if (method === "find") {
      this.push(ctx, `var ${out}: ?${this.table.zigTypeRef(baseT.elem)} = null;`);
      const { elemName, cond, idxCap } = this.scanPredicate(expr, method, baseT, sub);
      this.push(ctx, forLine(elemName, idxCap));
      inner(`if (${cond}) {`);
      innerDeep(`${out} = ${elemName};`);
      innerDeep(`break;`);
      inner(`}`);
    } else if (method === "findIndex") {
      this.push(ctx, `var ${out}: i64 = -1;`);
      const { elemName, cond, idxCap } = this.scanPredicate(expr, method, baseT, sub);
      const idx = idxCap ?? this.freshName(sub, "i");
      this.push(ctx, `for (${base}, 0..) |${elemName}, ${idx}| {`);
      inner(`if (${cond}) {`);
      innerDeep(`${out} = @intCast(${idx});`);
      innerDeep(`break;`);
      inner(`}`);
    } else {
      this.push(ctx, `var ${out} = ${method === "some" ? "false" : "true"};`);
      const { elemName, cond, idxCap } = this.scanPredicate(expr, method, baseT, sub);
      this.push(ctx, forLine(elemName, idxCap));
      inner(`if (${method === "some" ? cond : `!${maybeParen(cond)}`}) {`);
      innerDeep(`${out} = ${method === "some" ? "true" : "false"};`);
      innerDeep(`break;`);
      inner(`}`);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: out };
  }

  /// R17e: `.reduce(f, init)` -> accumulator loop; the accumulator keeps the
  /// callback's own name. The no-initial arity is a taught stop: JS throws
  /// on an empty array there, and throw has no mapping (NS1007).
  private emitReduce(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
  ): Emitted {
    if (expr.arguments.length < 2) {
      this.fail(
        expr,
        "`.reduce` with no initial value throws on an empty array; pass the starting accumulator as the second argument",
        "NS1007",
      );
    }
    const cb = this.callbackArg(expr, 0);
    if (!cb || !isCallbackFn(cb) || cb.parameters.length !== 2) {
      this.fail(
        expr,
        "reduce callback shape ((acc, x) => next; the index parameter is not in v1 — use a classic loop when the fold needs it)",
      );
    }
    const accParam = cb.parameters[0];
    const elemParam = cb.parameters[1];
    const init = expr.arguments[1];
    // Number accumulators take the slot's inferred class (array-callback
    // captures are f64 by R2); everything else keeps its own type.
    const accT0 = this.zTypeOfExpr(init, ctx);
    const accT: ZType =
      accT0.k === "number" ? { k: this.infer.classOfDecl(accParam) ?? "f64" } : accT0;
    const accRef = this.table.zigTypeRef(accT);
    if (accRef === "void") this.fail(init, "reduce initial value of this expression kind");
    const base = this.emitExpr(callee.expression, ctx).code;
    const acc = this.claim(ctx, accParam, zigLocalName((accParam.name as ts.Identifier).text));
    ctx.localTypes.set(accParam, accT);
    const v = this.emitExpr(init, ctx, accT).code;
    this.push(ctx, `var ${acc}: ${accRef} = ${v};`);
    const sub = this.nestedCtx(ctx);
    const elemUsed = this.identifierUsed(cb.body, elemParam);
    let elemName = "_";
    if (elemUsed) {
      elemName = this.claim(sub, elemParam, zigLocalName((elemParam.name as ts.Identifier).text));
      sub.localTypes.set(elemParam, baseT.elem);
    }
    this.push(ctx, `for (${base}) |${elemName}| {`);
    if (ts.isBlock(cb.body)) {
      const v = this.emitCallbackValue(cb, sub, accT, "next");
      this.push(sub, `${acc} = ${v};`);
    } else {
      this.emitAssignInto(acc, cb.body, sub, accT);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: acc };
  }

  /// R17f: array `.slice(a, b)` -> exact-size arena copy with JS index
  /// resolution — negatives count from the end, everything clamps into
  /// [0, len], and a start past the end is the empty copy (rt.sliceIndex).
  private emitArraySlice(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    if (expr.arguments.length > 2) this.fail(expr, "slice arity");
    const base = this.emitExpr(callee.expression, ctx).code;
    const elemRef = this.table.zigTypeRef(baseT.elem);
    const out = this.freshName(ctx, nameHint ?? "copied");
    if (expr.arguments.length === 0) {
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${base}.len);`);
      this.push(ctx, `@memcpy(${out}, ${base});`);
      return { code: out };
    }
    const lo = this.freshName(ctx, `${out}_from`);
    const a = this.emitExpr(expr.arguments[0], ctx).code;
    this.push(ctx, `const ${lo} = rt.sliceIndex(${base}.len, ${a});`);
    let hi = `${base}.len`;
    if (expr.arguments[1]) {
      hi = this.freshName(ctx, `${out}_to`);
      const b = this.emitExpr(expr.arguments[1], ctx).code;
      this.push(ctx, `const ${hi} = @max(${lo}, rt.sliceIndex(${base}.len, ${b}));`);
    }
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${hi} - ${lo});`);
    this.push(ctx, `@memcpy(${out}, ${base}[${lo}..${hi}]);`);
    return { code: out };
  }

  /// R17g: `.concat(ys, ...)` -> one exact-size alloc, memcpy per part.
  private emitConcat(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    const parts = [this.emitExpr(callee.expression, ctx).code];
    for (const arg of expr.arguments) {
      const argT = this.zTypeOfExpr(arg, ctx);
      if (argT.k !== "slice" && !ts.isArrayLiteralExpression(unwrapExpr(arg))) {
        this.fail(arg, "concat argument that is not an array (append single items with a spread: `[...xs, x]`)");
      }
      // Literal arguments type from the receiver (`xs.concat([1, 2])`).
      parts.push(this.emitExpr(arg, ctx, baseT).code);
    }
    const elemRef = this.table.zigTypeRef(baseT.elem);
    const out = this.freshName(ctx, nameHint ?? "combined");
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${parts.map((p) => `${p}.len`).join(" + ")});`);
    if (parts.length === 1) {
      this.push(ctx, `@memcpy(${out}, ${parts[0]});`);
    } else if (parts.length === 2) {
      this.push(ctx, `@memcpy(${out}[0..${parts[0]}.len], ${parts[0]});`);
      this.push(ctx, `@memcpy(${out}[${parts[0]}.len..], ${parts[1]});`);
    } else {
      const at = this.freshName(ctx, `${out}_at`);
      this.push(ctx, `var ${at}: usize = 0;`);
      for (const p of parts) {
        this.push(ctx, `@memcpy(${out}[${at}..][0..${p}.len], ${p});`);
        this.push(ctx, `${at} += ${p}.len;`);
      }
    }
    return { code: out };
  }

  /// R17h: `.indexOf` / `.includes` -> an equality scan over scalar
  /// elements. indexOf is JS strict equality — NaN never matches, which the
  /// plain float compare already gives; includes is SameValueZero, so float
  /// scans carry the extra NaN arm. Record/bytes elements stop loudly: JS
  /// compares references there, which has no mapping (match a field with
  /// `.findIndex` instead).
  private emitEqualityScan(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    method: "indexOf" | "includes",
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    if (expr.arguments.length !== 1) this.fail(expr, `${method} arity (v1 takes the needle only)`);
    const elemT = this.elemZType(baseT.elem);
    const scalar =
      elemT.k === "f64" || elemT.k === "i64" || elemT.k === "bool" || elemT.k === "enum" || elemT.k === "numAlias";
    if (!scalar) {
      this.fail(expr, `.${method} on an array of ${baseT.elem.k} elements (JS compares references there; match a field with .find/.findIndex)`);
    }
    const base = this.emitExpr(callee.expression, ctx).code;
    const arg = expr.arguments[0];
    let needle = this.emitExpr(arg, ctx, elemT).code;
    const inline =
      ts.isIdentifier(arg) || ts.isNumericLiteral(arg) || ts.isStringLiteral(arg) || ts.isPrefixUnaryExpression(arg);
    if (!inline) {
      const named = this.freshName(ctx, "needle");
      this.push(ctx, `const ${named} = ${needle};`);
      needle = named;
    }
    const out = this.freshName(ctx, nameHint ?? (method === "indexOf" ? "found_at" : "contains"));
    this.push(ctx, method === "indexOf" ? `var ${out}: i64 = -1;` : `var ${out} = false;`);
    const sub = this.nestedCtx(ctx);
    const elemName = this.freshName(sub, "x");
    const inner = (line: string) => sub.lines.push("    ".repeat(sub.indent) + line);
    const innerDeep = (line: string) => sub.lines.push("    ".repeat(sub.indent + 1) + line);
    const nanArm =
      method === "includes" && elemT.k === "f64"
        ? ` or (std.math.isNan(${elemName}) and std.math.isNan(${needle}))`
        : "";
    if (method === "indexOf") {
      const idx = this.freshName(sub, "i");
      this.push(ctx, `for (${base}, 0..) |${elemName}, ${idx}| {`);
      inner(`if (${elemName} == ${needle}) {`);
      innerDeep(`${out} = @intCast(${idx});`);
      innerDeep(`break;`);
      inner(`}`);
    } else {
      this.push(ctx, `for (${base}) |${elemName}| {`);
      inner(`if (${elemName} == ${needle}${nanArm}) {`);
      innerDeep(`${out} = true;`);
      innerDeep(`break;`);
      inner(`}`);
    }
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: out };
  }

  /// R17j: `.toSorted(cmp)` -> arena copy + stable insertion sort ordered
  /// by the comparator's sign: negative puts `a` before `b`; zero and NaN
  /// keep the original order, which is exactly what makes the JS sort
  /// stable. Byte-identical to node for every consistent comparator; an
  /// inconsistent one (`a - b` over NaN elements) is implementation-defined
  /// in JS itself. The comparator-less arity and boolean comparators are
  /// taught stops (ToString ordering / NS1023).
  private emitToSorted(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    const cb = this.callbackArg(expr, 0);
    if (!cb) {
      this.fail(
        expr,
        "`.toSorted()` without a comparator (JS sorts by string ToString order there, so [10, 9] stays [10, 9]; pass `(a, b) => a - b` for ascending numbers)",
      );
    }
    if (!isCallbackFn(cb) || cb.parameters.length !== 2) {
      this.fail(expr, "toSorted comparator shape ((a, b) => sign)");
    }
    // Layer-3 re-derivation of NS1023: a boolean comparator never sorts.
    if (this.tast.arrowReturnsBoolean(cb)) {
      this.fail(cb, "this `.toSorted` comparator returns a boolean", "NS1023");
    }
    const base = this.emitExpr(callee.expression, ctx).code;
    const elemRef = this.table.zigTypeRef(baseT.elem);
    const out = this.freshName(ctx, nameHint ?? "sorted");
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${base}.len);`);
    this.push(ctx, `@memcpy(${out}, ${base});`);
    this.push(ctx, `// JS toSorted: stable insertion sort; the comparator's sign orders each pair.`);
    this.emitInsertionSort(out, cb, baseT, ctx);
    return { code: out };
  }

  /// The shared stable insertion sort over `target` (a mutable slice):
  /// `.toSorted` runs it over a fresh copy, in-place `.sort` over the owned
  /// array's live prefix. Negative comparator values order `a` before `b`;
  /// zero and NaN keep the original order — exactly JS's stability.
  private emitInsertionSort(
    target: string,
    cb: ts.ArrowFunction,
    baseT: ZType & { k: "slice" },
    ctx: Ctx,
  ): void {
    const i = this.freshName(ctx, "i");
    this.push(ctx, `var ${i}: usize = 1;`);
    this.push(ctx, `while (${i} < ${target}.len) : (${i} += 1) {`);
    const outerSub = this.nestedCtx(ctx);
    const aParam = cb.parameters[0];
    const bParam = cb.parameters[1];
    const aName = this.claim(outerSub, aParam, zigLocalName((aParam.name as ts.Identifier).text));
    outerSub.localTypes.set(aParam, baseT.elem);
    const j = this.freshName(outerSub, "j");
    this.push(outerSub, `const ${aName} = ${target}[${i}];`);
    this.push(outerSub, `var ${j}: usize = ${i};`);
    this.push(outerSub, `while (${j} > 0) : (${j} -= 1) {`);
    const innerSub = this.nestedCtx(outerSub);
    const bName = this.claim(innerSub, bParam, zigLocalName((bParam.name as ts.Identifier).text));
    innerSub.localTypes.set(bParam, baseT.elem);
    this.push(innerSub, `const ${bName} = ${target}[${j} - 1];`);
    const cmpClass: ZType = { k: this.comparatorClass(cb) };
    const cmp = this.emitCallbackValue(cb, innerSub, cmpClass, "order");
    this.push(innerSub, `if (!(${cmp} < 0)) break;`);
    this.push(innerSub, `${target}[${j}] = ${bName};`);
    outerSub.lines.push(...innerSub.lines);
    this.push(outerSub, `}`);
    this.push(outerSub, `${target}[${j}] = ${aName};`);
    ctx.lines.push(...outerSub.lines);
    this.push(ctx, `}`);
  }

  /// The emission class of a comparator's returned number: f64 as soon as
  /// any returned value is float-classed, else i64 (`< 0` works for both;
  /// the class only anchors the lifted value block's annotation).
  private comparatorClass(cb: ts.ArrowFunction): "i64" | "f64" {
    const exprs = ts.isBlock(cb.body) ? returnExpressionsOf(cb.body) : [cb.body];
    return exprs.some((e) => this.infer.classOfExpr(e) === "f64") ? "f64" : "i64";
  }

  /// R18b: `.join(sep)` on bytes -> per-element {d} prints into one
  /// exact-bound arena buffer, the separator folded at compile time like
  /// asciiBytes. Byte elements are always integers, so this is the template-
  /// hole rule applied elementwise; number arrays stay a taught stop.
  private emitBytesJoin(
    expr: ts.CallExpression,
    callee: ts.PropertyAccessExpression,
    ctx: Ctx,
    nameHint?: string,
  ): Emitted {
    if (expr.arguments.length > 1) this.fail(expr, "join arity");
    let sep = ",";
    const sepArg = expr.arguments[0];
    if (sepArg) {
      if (!ts.isStringLiteral(sepArg)) this.fail(sepArg, "join separator (a string literal, folded like asciiBytes)");
      sep = sepArg.text;
    }
    // The emitted @memcpy length counts bytes; keep the fold exact.
    if (!/^[\x00-\x7F]*$/.test(sep)) this.fail(sepArg ?? expr, "non-ASCII join separator");
    const base = this.emitExpr(callee.expression, ctx).code;
    const out = this.freshName(ctx, nameHint ?? "joined");
    const len = this.freshName(ctx, `${out}_len`);
    // Exact upper bound: three digits per byte plus the separators.
    const bound =
      sep.length > 0
        ? `if (${base}.len == 0) 0 else ${base}.len * 3 + (${base}.len - 1) * ${sep.length}`
        : `${base}.len * 3`;
    this.push(ctx, `const ${out} = rt.frameAlloc(u8, ${bound});`);
    this.push(ctx, `var ${len}: usize = 0;`);
    const sub = this.nestedCtx(ctx);
    const b = this.freshName(sub, "b");
    const chunk = this.freshName(sub, "chunk");
    const inner = (line: string) => sub.lines.push("    ".repeat(sub.indent) + line);
    const innerDeep = (line: string) => sub.lines.push("    ".repeat(sub.indent + 1) + line);
    if (sep.length > 0) {
      const idx = this.freshName(sub, "i");
      this.push(ctx, `for (${base}, 0..) |${b}, ${idx}| {`);
      inner(`if (${idx} > 0) {`);
      innerDeep(`@memcpy(${out}[${len}..][0..${sep.length}], "${escapeZigString(sep)}");`);
      innerDeep(`${len} += ${sep.length};`);
      inner(`}`);
    } else {
      this.push(ctx, `for (${base}) |${b}| {`);
    }
    inner(`const ${chunk} = std.fmt.bufPrint(${out}[${len}..], "{d}", .{${b}}) catch unreachable;`);
    inner(`${len} += ${chunk}.len;`);
    ctx.lines.push(...sub.lines);
    this.push(ctx, `}`);
    return { code: `${out}[0..${len}]` };
  }

  /// Lower `target = <expr>` where the expression may need statements
  /// (ternaries and spreads inside map callbacks).
  private emitAssignInto(target: string, expr: ts.Expression, ctx: Ctx, expected: ZType): void {
    if (ts.isParenthesizedExpression(expr)) return this.emitAssignInto(target, expr.expression, ctx, expected);
    if (ts.isConditionalExpression(expr)) {
      const cond = this.emitCondition(expr.condition, ctx);
      this.push(ctx, `if (${cond}) {`);
      const t = this.nestedCtx(ctx);
      this.emitAssignInto(target, expr.whenTrue, t, expected);
      ctx.lines.push(...t.lines);
      this.push(ctx, `} else {`);
      const e = this.nestedCtx(ctx);
      this.emitAssignInto(target, expr.whenFalse, e, expected);
      ctx.lines.push(...e.lines);
      this.push(ctx, `}`);
      return;
    }
    const v = this.emitExpr(expr, ctx, expected);
    this.push(ctx, `${target} = ${v.code};`);
  }

  // --------------------------------------------------------------- literals

  private emitObjectLiteral(
    expr: ts.ObjectLiteralExpression,
    ctx: Ctx,
    expected?: ZType,
    nameHint?: string,
  ): Emitted {
    let t = expected;
    if (t?.k === "optional") t = t.inner;
    if (t?.k === "union") return this.emitUnionLiteral(expr, t.name, ctx);
    if (!t || t.k !== "struct") this.fail(expr, "object literal without a known struct target");
    const info = this.table.structs.get(t.name);
    if (!info) this.fail(expr, `unknown struct ${t.name}`);

    const spread = expr.properties.find((p) => ts.isSpreadAssignment(p)) as ts.SpreadAssignment | undefined;
    if (spread) {
      // R15: `{ ...x, f: v }` -> copy node, overwrite listed fields.
      const src = this.emitExpr(spread.expression, ctx).code;
      const out = this.freshName(ctx, nameHint ?? "out");
      if (info.promoted) {
        this.push(ctx, `var ${out} = ${src};`);
      } else {
        this.push(ctx, `const ${out} = rt.frameCreate(${info.name}, ${src}.*);`);
      }
      for (const p of expr.properties) {
        if (ts.isSpreadAssignment(p)) continue;
        if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) this.fail(p, "object literal member");
        const field = info.fields.find((f) => f.tsName === (p.name as ts.Identifier).text);
        if (!field) this.fail(p, `field ${p.name.getText()} on ${info.name}`);
        const ft = this.fieldZType(field);
        const v = this.emitExpr(p.initializer, ctx, ft, field.zigName);
        this.push(ctx, `${out}.${fieldName(field)} = ${v.code};`);
      }
      return { code: out };
    }

    const parts: string[] = [];
    for (const p of expr.properties) {
      let name: string;
      let value: string;
      if (ts.isPropertyAssignment(p) && ts.isIdentifier(p.name)) {
        const field = info.fields.find((f) => f.tsName === (p.name as ts.Identifier).text);
        if (!field) this.fail(p, `field ${p.name.text} on ${info.name}`);
        name = fieldName(field);
        value = this.emitExpr(p.initializer, ctx, this.fieldZType(field), field.zigName).code;
      } else if (ts.isShorthandPropertyAssignment(p)) {
        const field = info.fields.find((f) => f.tsName === p.name.text);
        if (!field) this.fail(p, `field ${p.name.text} on ${info.name}`);
        name = fieldName(field);
        value = this.emitExpr(p.name, ctx, this.fieldZType(field)).code;
      } else {
        this.fail(p, "object literal member kind");
      }
      parts.push(`.${name} = ${value}`);
    }
    const inner = parts.join(", ");
    const literal = inner.length + 8 <= 92 ? `.{ ${inner} }` : `.{\n${parts.map((p) => "    ".repeat(ctx.indent + 1) + p + ",").join("\n")}\n${"    ".repeat(ctx.indent)}}`;
    if (info.promoted) return { code: literal };
    // R14: model-stored/aliased records live behind *const T in the arena.
    return { code: `rt.frameCreate(${info.name}, ${literal})` };
  }

  /// R6: `{ kind: "tag", ...payload }` -> union init.
  private emitUnionLiteral(expr: ts.ObjectLiteralExpression, unionName: string, ctx: Ctx): Emitted {
    const info = this.table.unions.get(unionName);
    if (!info) this.fail(expr, `unknown union ${unionName}`);
    let tag: string | null = null;
    const values = new Map<string, ts.Expression>();
    for (const p of expr.properties) {
      if (ts.isShorthandPropertyAssignment(p)) {
        // `{ kind: "range", v }` — the shorthand reads the local by name.
        values.set(p.name.text, p.name);
        continue;
      }
      if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name)) this.fail(p, "union literal member");
      if (p.name.text === "kind") {
        if (!ts.isStringLiteral(p.initializer)) this.fail(p, "non-literal union tag");
        tag = p.initializer.text;
      } else {
        values.set(p.name.text, p.initializer);
      }
    }
    if (tag === null) this.fail(expr, "union literal without a kind tag");
    const arm = info.arms.find((a) => a.tag === tag);
    if (!arm) this.fail(expr, `tag "${tag}" is not an arm of ${unionName}`);
    if (arm.fields.length === 0) return { code: `.${zigId(tag)}` };
    if (arm.fields.length === 1) {
      const f = arm.fields[0];
      const init = values.get(f.tsName);
      if (!init) this.fail(expr, `union arm "${tag}" missing field ${f.tsName}`);
      const v = this.emitExpr(init, ctx, this.fieldZType(f), f.zigName).code;
      return { code: `.{ .${zigId(tag)} = ${v} }` };
    }
    const parts: string[] = [];
    for (const f of arm.fields) {
      const init = values.get(f.tsName);
      if (!init) this.fail(expr, `union arm "${tag}" missing field ${f.tsName}`);
      const v = this.emitExpr(init, ctx, this.fieldZType(f), f.zigName).code;
      parts.push(`.${fieldName(f)} = ${v}`);
    }
    return { code: `.{ .${zigId(tag)} = .{ ${parts.join(", ")} } }` };
  }

  private fieldZType(f: ZField): ZType {
    if (f.type.k === "number") {
      return { k: this.infer.classOfDecl(f.decl) === "f64" ? "f64" : "i64" };
    }
    if (f.type.k === "optional" && f.type.inner.k === "number") {
      return { k: "optional", inner: { k: this.infer.classOfDecl(f.decl) === "f64" ? "f64" : "i64" } };
    }
    return f.type;
  }

  /// Expected type of one element of a slice: number elements are always
  /// f64 (the R2 inference covers slots, not array elements).
  private elemZType(elem: ZType): ZType {
    return elem.k === "number" ? { k: "f64" } : elem;
  }

  private emitArrayLiteral(
    expr: ts.ArrayLiteralExpression,
    ctx: Ctx,
    expected?: ZType,
    nameHint?: string,
  ): Emitted {
    if (!expected || expected.k !== "slice") this.fail(expr, "array literal without a slice target");
    if (expr.elements.length === 0) return { code: `&.{}` };
    const spreads = expr.elements.filter((e): e is ts.SpreadElement => ts.isSpreadElement(e));
    for (const s of spreads) {
      const t = this.zTypeOfExpr(s.expression, ctx);
      if (t.k !== "slice") this.fail(s, `array spread over ${t.k} (v1 spreads arrays into array literals)`);
    }
    if (spreads.length === 1 && expr.elements[0] === spreads[0]) {
      // R17: `[...xs, a, b]` -> alloc len+n, memcpy, append.
      const rest = expr.elements.slice(1);
      const src = this.emitExpr(spreads[0].expression, ctx).code;
      const out = this.freshName(ctx, nameHint ?? "appended");
      const elemRef = this.table.zigTypeRef(expected.elem);
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${src}.len + ${rest.length});`);
      this.push(ctx, `@memcpy(${out}[0..${src}.len], ${src});`);
      rest.forEach((e, i) => {
        const v = this.emitExpr(e as ts.Expression, ctx, this.elemZType(expected.elem)).code;
        this.push(ctx, `${out}[${src}.len${i > 0 ? ` + ${i}` : ""}] = ${v};`);
      });
      return { code: out };
    }
    if (spreads.length === 1 && expr.elements[expr.elements.length - 1] === spreads[0]) {
      // R17l prepend: `[a, b, ...xs]` -> alloc n+len, set, memcpy the tail.
      const lead = expr.elements.slice(0, -1);
      const src = this.emitExpr(spreads[0].expression, ctx).code;
      const out = this.freshName(ctx, nameHint ?? "prepended");
      const elemRef = this.table.zigTypeRef(expected.elem);
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${src}.len + ${lead.length});`);
      lead.forEach((e, i) => {
        const v = this.emitExpr(e as ts.Expression, ctx, this.elemZType(expected.elem)).code;
        this.push(ctx, `${out}[${i}] = ${v};`);
      });
      this.push(ctx, `@memcpy(${out}[${lead.length}..], ${src});`);
      return { code: out };
    }
    if (spreads.length > 0) {
      // R17l multi-spread: `[...a, x, ...b]` -> one exact-size alloc, then
      // segment copies through a cursor (the concat form generalized).
      const srcs = new Map<ts.SpreadElement, string>();
      for (const s of spreads) srcs.set(s, this.emitExpr(s.expression, ctx).code);
      const scalarCount = expr.elements.length - spreads.length;
      const sizeParts = spreads.map((s) => `${srcs.get(s)}.len`);
      if (scalarCount > 0) sizeParts.push(String(scalarCount));
      const out = this.freshName(ctx, nameHint ?? "combined");
      const elemRef = this.table.zigTypeRef(expected.elem);
      const at = this.freshName(ctx, `${out}_at`);
      this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${sizeParts.join(" + ")});`);
      this.push(ctx, `var ${at}: usize = 0;`);
      for (const e of expr.elements) {
        if (ts.isSpreadElement(e)) {
          const src = srcs.get(e)!;
          this.push(ctx, `@memcpy(${out}[${at}..][0..${src}.len], ${src});`);
          this.push(ctx, `${at} += ${src}.len;`);
        } else {
          const v = this.emitExpr(e as ts.Expression, ctx, this.elemZType(expected.elem)).code;
          this.push(ctx, `${out}[${at}] = ${v};`);
          this.push(ctx, `${at} += 1;`);
        }
      }
      return { code: out };
    }
    const parts = expr.elements.map((e) => this.emitExpr(e as ts.Expression, ctx, this.elemZType(expected.elem)).code);
    const out = this.freshName(ctx, nameHint ?? "items");
    const elemRef = this.table.zigTypeRef(expected.elem);
    this.push(ctx, `const ${out} = rt.frameAlloc(${elemRef}, ${parts.length});`);
    parts.forEach((p, i) => this.push(ctx, `${out}[${i}] = ${p};`));
    return { code: out };
  }

  // ---------------------------------------------------------- type of expr

  /// zTypeOfExpr with `number` resolved to the expression's inferred class:
  /// the expected type for values assigned into the expression's slot.
  private zTypeOfExprClassed(expr: ts.Expression, ctx: Ctx): ZType {
    const t = this.zTypeOfExpr(expr, ctx);
    if (t.k === "number") return { k: this.infer.classOfExpr(expr) };
    if (t.k === "optional" && t.inner.k === "number") {
      return { k: "optional", inner: { k: this.infer.classOfExpr(expr) } };
    }
    return t;
  }

  private zTypeOfExpr(expr: ts.Expression, ctx: Ctx): ZType {
    const t = this.zTypeOfExprRaw(expr, ctx);
    // A narrowing substitution (null-guard capture or `.?` unwrap) proves
    // the value non-null for every use it rewrites, so the expression's
    // effective type is the inner one. A RENAMING substitution — a union
    // payload capture whose field is itself optional — holds the payload
    // as-is and must keep the optional (stillOptionalSubst records those
    // by their exact replacement).
    if (t.k === "optional") {
      const key = this.narrowKey(expr);
      const rep = key === null ? undefined : ctx.memberSubst.get(key);
      if (key !== null && rep !== undefined && rep !== ctx.stillOptionalSubst.get(key)) return t.inner;
    }
    return t;
  }

  private zTypeOfExprRaw(expr: ts.Expression, ctx: Ctx): ZType {
    if (
      ts.isParenthesizedExpression(expr) ||
      ts.isNonNullExpression(expr) ||
      ts.isAsExpression(expr) ||
      ts.isSatisfiesExpression(expr)
    ) {
      return this.zTypeOfExpr(expr.expression, ctx);
    }
    if (ts.isNumericLiteral(expr)) return { k: "number" };
    if (
      ts.isPrefixUnaryExpression(expr) &&
      (expr.operator === ts.SyntaxKind.MinusToken ||
        expr.operator === ts.SyntaxKind.PlusToken ||
        expr.operator === ts.SyntaxKind.PlusPlusToken ||
        expr.operator === ts.SyntaxKind.MinusMinusToken)
    ) {
      return this.zTypeOfExpr(expr.operand, ctx);
    }
    if (ts.isPostfixUnaryExpression(expr)) {
      return this.zTypeOfExpr(expr.operand, ctx);
    }
    if (ts.isPrefixUnaryExpression(expr) && expr.operator === ts.SyntaxKind.TildeToken) {
      return { k: "number" };
    }
    if (ts.isStringLiteral(expr) || ts.isNoSubstitutionTemplateLiteral(expr) || ts.isTemplateExpression(expr)) {
      return { k: "string" };
    }
    if (expr.kind === ts.SyntaxKind.TrueKeyword || expr.kind === ts.SyntaxKind.FalseKeyword) return { k: "bool" };
    if (ts.isIdentifier(expr)) {
      const decl = this.tast.declarationOf(expr);
      if (decl && ctx.localTypes.has(decl)) return ctx.localTypes.get(decl)!;
      if (decl && ts.isVariableDeclaration(decl)) {
        if (decl.type) return this.table.resolveTypeNode(decl.type);
        if (decl.initializer) return this.zTypeOfExpr(decl.initializer, ctx);
      }
      if (decl && ts.isParameter(decl) && decl.type) return this.table.resolveTypeNode(decl.type);
      return { k: "void" };
    }
    if (ts.isPropertyAccessExpression(expr)) {
      // `Task.LIMIT` — a static const carries its declared/inferred type.
      {
        const decl = this.tast.declarationOf(expr.name);
        if (decl && ts.isPropertyDeclaration(decl) && isStaticMember(decl)) {
          if (decl.type) return this.table.resolveTypeNode(decl.type);
          if (decl.initializer) return this.zTypeOfExpr(decl.initializer, ctx);
          return { k: "void" };
        }
      }
      // `ns.member` — the member's own declared type, exactly like a named
      // import of it.
      if (this.isNamespaceAliasBase(expr.expression)) {
        const decl = this.tast.declarationOf(expr.name);
        if (decl && ts.isVariableDeclaration(decl)) {
          if (decl.type) return this.table.resolveTypeNode(decl.type);
          if (decl.initializer) return this.zTypeOfExpr(decl.initializer, ctx);
        }
        return { k: "void" };
      }
      const baseT = this.zTypeOfExpr(expr.expression, ctx);
      // A `?.` hop over a nullable base makes the whole chain value optional
      // (the R7b if-capture's `else null` arm).
      const chainOptional = ts.isOptionalChain(expr) && baseT.k === "optional";
      const optionalize = (t: ZType): ZType =>
        chainOptional && t.k !== "optional" ? { k: "optional", inner: t } : t;
      if (expr.name.text === "length") return optionalize({ k: "number" });
      const base = baseT.k === "optional" ? baseT.inner : baseT;
      if (base.k === "struct") {
        const info = this.table.structs.get(base.name);
        const f = info?.fields.find((x) => x.tsName === expr.name.text);
        if (f) return optionalize(f.type);
      }
      if (base.k === "union") {
        // Narrowed access: the payload field's type.
        const info = this.table.unions.get(base.name);
        for (const arm of info?.arms ?? []) {
          const f = arm.fields.find((x) => x.tsName === expr.name.text);
          if (f) return optionalize(f.type);
        }
      }
      return { k: "void" };
    }
    if (ts.isElementAccessExpression(expr)) {
      const rawBaseT = this.zTypeOfExpr(expr.expression, ctx);
      // A `?.` hop over a nullable base makes the chain value optional.
      const chainOptional = ts.isOptionalChain(expr) && rawBaseT.k === "optional";
      const baseT = chainOptional ? (rawBaseT as ZType & { k: "optional" }).inner : rawBaseT;
      const optionalize = (t: ZType): ZType =>
        chainOptional && t.k !== "optional" ? { k: "optional", inner: t } : t;
      if (baseT.k === "bytes") return optionalize({ k: "number" });
      if (baseT.k === "slice") return optionalize(baseT.elem);
      return { k: "void" };
    }
    if (ts.isCallExpression(expr)) {
      const callee = expr.expression;
      if (ts.isPropertyAccessExpression(callee) && this.isNamespaceAliasBase(callee.expression)) {
        const decl = this.tast.declarationOf(callee.name);
        if (decl && ts.isFunctionDeclaration(decl) && decl.type) return this.table.resolveTypeNode(decl.type);
        return { k: "void" };
      }
      if (ts.isPropertyAccessExpression(callee)) {
        const method = callee.name.text;
        if (ts.isIdentifier(callee.expression) && callee.expression.text === "Math") return { k: "number" };
        if (ts.isIdentifier(callee.expression) && callee.expression.text === "Number") return { k: "bool" };
        {
          // R19: a data-class method call's value is its annotated return.
          const mDecl = this.tast.declarationOf(callee.name);
          if (mDecl && ts.isMethodDeclaration(mDecl) && ts.isClassDeclaration(mDecl.parent) && mDecl.parent.name && this.table.classes.get(mDecl.parent.name.text)?.decl === mDecl.parent) {
            return mDecl.type ? this.table.resolveTypeNode(mDecl.type) : { k: "void" };
          }
        }
        const rawBaseT = this.zTypeOfExpr(callee.expression, ctx);
        // `xs?.slice()` — a method call over a nullable receiver makes the
        // call value optional (the R7b short-circuit).
        const chainOptional = ts.isOptionalChain(callee) && rawBaseT.k === "optional";
        if (chainOptional) {
          const inner = this.zTypeOfMethodResult(
            expr,
            method,
            (rawBaseT as ZType & { k: "optional" }).inner,
            ctx,
          );
          if (inner.k === "void") return inner;
          return inner.k === "optional" ? inner : { k: "optional", inner };
        }
        return this.zTypeOfMethodResult(expr, method, rawBaseT, ctx);
      }
      if (ts.isIdentifier(callee)) {
        const decl = this.tast.declarationOf(callee);
        if (decl && ts.isFunctionDeclaration(decl)) {
          if (this.isSdkIntrinsic(decl, "asciiBytes")) return { k: "bytes" };
          // R15e: a generic call's value is its return type under the
          // call's own resolved instantiation scope.
          if (decl.typeParameters && decl.typeParameters.length > 0) {
            if (!decl.type) return { k: "void" };
            const scope = this.genericScopeOfCall(expr, decl);
            if (!scope) return { k: "void" };
            return this.table.withTypeParams(scope, () => this.table.resolveTypeNode(decl.type!));
          }
          if (decl.type) return this.table.resolveTypeNode(decl.type);
        }
        // R15d: a hoisted local helper's call value is its annotated return.
        if (decl && ts.isVariableDeclaration(decl)) {
          const fn = this.hoistedFns.get(decl);
          if (fn?.type) return this.table.resolveTypeNode(fn.type);
        }
      }
      return { k: "void" };
    }
    if (ts.isNewExpression(expr) && ts.isIdentifier(expr.expression) && expr.expression.text === "Uint8Array") {
      return { k: "bytes" };
    }
    if (ts.isNewExpression(expr) && ts.isIdentifier(expr.expression) && this.table.classes.has(expr.expression.text)) {
      return { k: "struct", name: expr.expression.text };
    }
    if (expr.kind === ts.SyntaxKind.ThisKeyword) {
      return ctx.thisType ?? { k: "void" };
    }
    if (ts.isConditionalExpression(expr)) {
      // An empty branch — `null` or the global `undefined` — makes the
      // ternary's VALUE optional (`hit === undefined ? null : hit.at` is
      // `?i64`, not `i64`; `q === null ? undefined : q` stays `?P`) —
      // dropping it here would type locals non-optional and break every
      // later null test on them.
      const trueEmpty = this.isEmptyLiteral(expr.whenTrue);
      const falseEmpty = this.isEmptyLiteral(expr.whenFalse);
      if (trueEmpty && falseEmpty) return { k: "void" };
      if (trueEmpty || falseEmpty) {
        const t = this.zTypeOfExpr(trueEmpty ? expr.whenFalse : expr.whenTrue, ctx);
        return t.k === "optional" || t.k === "void" ? t : { k: "optional", inner: t };
      }
      // The condition's own null test narrows the arm that reuses the
      // tested value, exactly as tsc types it: `q === null ? {...f} : q`
      // and `q !== null ? q : {...f}` both VALUE as the non-optional Quote,
      // never `?Quote` — keeping the raw optional here types an inferred
      // local `?Quote` and its first non-optional use fails to compile.
      // The unwrap only holds when the OTHER arm cannot contribute null:
      // a known-optional other arm keeps the optional (its null flows
      // through), and the empty-literal arms (`null`/`undefined`, wrapped
      // or bare, in either position) were handled above.
      const missTest = this.emptyTestOf(expr.condition);
      const hitTest = this.emptyTestOf(expr.condition, ts.SyntaxKind.ExclamationEqualsEqualsToken);
      const narrowedByCond = (arm: ts.Expression, t: ZType, other: ts.Expression): ZType => {
        const test = arm === expr.whenFalse ? missTest : hitTest;
        if (test === null || t.k !== "optional") return t;
        const armKey = this.narrowKey(arm);
        if (armKey === null || armKey !== this.narrowKey(test.target)) return t;
        const otherT = this.zTypeOfExpr(other, ctx);
        return otherT.k === "optional" ? t : t.inner;
      };
      const t = this.zTypeOfExpr(expr.whenTrue, ctx);
      if (t.k !== "void") return narrowedByCond(expr.whenTrue, t, expr.whenFalse);
      const f = this.zTypeOfExpr(expr.whenFalse, ctx);
      return narrowedByCond(expr.whenFalse, f, expr.whenTrue);
    }
    if (ts.isBinaryExpression(expr)) {
      const op = expr.operatorToken.kind;
      if (op === ts.SyntaxKind.QuestionQuestionToken) {
        const t = this.zTypeOfExpr(expr.left, ctx);
        return t.k === "optional" ? t.inner : t;
      }
      if (assignmentOps.has(op)) {
        // R10b: the value of an assignment is the assigned value — the
        // target's own type once the statement has run.
        return this.zTypeOfExpr(expr.left, ctx);
      }
      if (
        op === ts.SyntaxKind.PlusToken ||
        op === ts.SyntaxKind.MinusToken ||
        op === ts.SyntaxKind.AsteriskToken ||
        op === ts.SyntaxKind.SlashToken ||
        op === ts.SyntaxKind.PercentToken ||
        op === ts.SyntaxKind.AsteriskAsteriskToken ||
        op === ts.SyntaxKind.AmpersandToken ||
        op === ts.SyntaxKind.BarToken ||
        op === ts.SyntaxKind.CaretToken ||
        op === ts.SyntaxKind.LessThanLessThanToken ||
        op === ts.SyntaxKind.GreaterThanGreaterThanToken ||
        op === ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken
      ) {
        return { k: "number" };
      }
      return { k: "bool" };
    }
    if (ts.isArrayLiteralExpression(expr)) {
      // Element type from the first typed element (spreads and nulls skip);
      // the literal's own type when no annotation carries one.
      for (const el of expr.elements) {
        if (ts.isSpreadElement(el)) continue;
        if (el.kind === ts.SyntaxKind.NullKeyword) continue;
        const t = this.zTypeOfExpr(el as ts.Expression, ctx);
        if (t.k !== "void") return { k: "slice", elem: t };
      }
      return { k: "void" };
    }
    if (ts.isObjectLiteralExpression(expr)) return { k: "void" };
    return { k: "void" };
  }

  /// The value type of a mapped array/bytes method call, given the
  /// receiver's (non-optional) type.
  private zTypeOfMethodResult(expr: ts.CallExpression, method: string, baseT: ZType, ctx: Ctx): ZType {
    if (baseT.k === "bytes" && (method === "subarray" || method === "slice")) return { k: "bytes" };
    if (baseT.k === "bytes" && method === "join") return { k: "bytes" };
    if (baseT.k === "bytes") {
      // R11t: the byte-text method surface.
      switch (method) {
        case "toUpperCase":
        case "toLowerCase":
        case "repeat":
        case "padStart":
        case "padEnd":
        case "trim":
        case "trimStart":
        case "trimEnd":
          return { k: "bytes" };
        case "startsWith":
        case "endsWith":
        case "includes":
          return { k: "bool" };
        case "indexOf":
        case "lastIndexOf":
          return { k: "i64" };
        case "split":
          return { k: "slice", elem: { k: "bytes" } };
        case "at":
          return { k: "optional", inner: { k: "i64" } };
      }
    }
    if (baseT.k === "slice" && method === "filter") return baseT;
    if (baseT.k === "slice" && method === "map") {
      // The output element type is the callback's result type (the
      // type-changing map); unresolvable callbacks (object literals
      // typed from the slot) keep the source element type.
      const elem = this.mapResultElem(expr, baseT, ctx);
      return elem ? { k: "slice", elem } : baseT;
    }
    if (baseT.k === "slice") {
      if (method === "slice" || method === "concat" || method === "toSorted" || method === "splice") return baseT;
      if (method === "find" || method === "pop" || method === "shift") {
        return { k: "optional", inner: baseT.elem };
      }
      if (method === "findIndex" || method === "indexOf") return { k: "number" };
      if (method === "some" || method === "every" || method === "includes") return { k: "bool" };
      if (method === "reduce") {
        const init = expr.arguments[1];
        if (!init) return { k: "number" };
        const t = this.zTypeOfExpr(init, ctx);
        if (t.k !== "number" && t.k !== "i64" && t.k !== "f64") return t;
        // The accumulator slot's class IS the result class (emitReduce
        // types the loop variable the same way).
        const cb = this.callbackArg(expr, 0);
        const accParam = cb && isCallbackFn(cb) ? cb.parameters[0] : undefined;
        const cls = accParam ? this.infer.classOfDecl(accParam) : null;
        return cls ? { k: cls } : t;
      }
    }
    return { k: "void" };
  }

  // -------------------------------------------------------- commit walkers

  /// Whether a model value of this type holds anything the commit boundary
  /// must copy (bytes, heap nodes, slices) — types that are pure scalars
  /// commit as themselves and need no walker.
  private typeNeedsCommit(t: ZType, visiting: Set<string> = new Set()): boolean {
    switch (t.k) {
      case "bytes":
      case "slice":
        return true;
      case "struct":
        return this.table.isPointerStruct(t.name);
      case "union": {
        if (visiting.has(t.name)) return false;
        visiting.add(t.name);
        const info = this.table.unions.get(t.name);
        if (!info) return false;
        return info.arms.some((a) => a.fields.some((f) => this.typeNeedsCommit(this.fieldZType(f), visiting)));
      }
      case "optional":
        return this.typeNeedsCommit(t.inner, visiting);
      default:
        return false;
    }
  }

  /// Emitted per model type from its shape: the commit boundary of spec 4.2.
  private emitCommitWalkers(): void {
    const model = this.table.structs.get("Model");
    if (!model || model.promoted) return;

    // Reachable node types, post-order so leaves emit first.
    const structs: StructInfo[] = [];
    const unions: UnionInfo[] = [];
    const seen = new Set<string>();
    const seenUnions = new Set<string>();
    const sliceElems = new Set<string>();
    let bytesUsed = false;
    let scalarSlices = false;
    const visitType = (t: ZType): void => {
      switch (t.k) {
        case "bytes":
          bytesUsed = true;
          return;
        case "struct": {
          if (seen.has(t.name)) return;
          seen.add(t.name);
          const info = this.table.structs.get(t.name);
          if (!info) return;
          for (const f of info.fields) visitType(this.fieldZType(f));
          structs.push(info);
          return;
        }
        case "union": {
          // R6b: a model-stored tagged union stays by value; the walker
          // copies through the ACTIVE arm's payload only (the other arms'
          // old payloads die with the frame/old space).
          if (seenUnions.has(t.name)) return;
          seenUnions.add(t.name);
          const info = this.table.unions.get(t.name);
          if (!info) return;
          for (const arm of info.arms) for (const f of arm.fields) visitType(this.fieldZType(f));
          if (info.arms.some((a) => a.fields.some((f) => this.typeNeedsCommit(this.fieldZType(f))))) {
            unions.push(info);
          }
          return;
        }
        case "slice":
          if (t.elem.k === "struct") sliceElems.add(t.elem.name);
          else if (isScalarElem(this.elemZType(t.elem))) scalarSlices = true;
          visitType(t.elem);
          return;
        case "optional":
          visitType(t.inner);
          return;
        default:
          return;
      }
    };
    visitType({ k: "struct", name: "Model" });

    this.out.push(``);
    this.out.push(`// ------------------------------------------------------------------ commit`);
    this.out.push(`// Emitted from the Model's type shape: the commit walkers copy frame-arena`);
    this.out.push(`// nodes into the model heap and share everything already persistent.`);
    this.out.push(`//`);
    this.out.push(`// incremental: copy frame-resident nodes only — O(new nodes).`);
    this.out.push(`// full:        after a two-space flip, copy everything live — O(live model).`);
    this.out.push(``);
    this.out.push(`const CommitMode = enum { incremental, full };`);
    this.out.push(``);
    this.out.push(`// During a full (compacting) commit the flipped-away space must also be`);
    this.out.push(`// copied out of. Rodata/static pointers are in neither region: shared as-is.`);
    this.out.push(`var old_heap_base: usize = 0;`);
    this.out.push(`var old_heap_len: usize = 0;`);
    this.out.push(``);
    this.out.push(`fn inOldHeap(addr: usize) bool {`);
    this.out.push(`    return addr >= old_heap_base and addr < old_heap_base + old_heap_len;`);
    this.out.push(`}`);
    this.out.push(``);
    this.out.push(`inline fn shouldCopy(mode: CommitMode, ptr: anytype) bool {`);
    this.out.push(`    const addr = @intFromPtr(ptr);`);
    this.out.push(`    return switch (mode) {`);
    this.out.push(`        .incremental => rt.inFrame(addr),`);
    this.out.push(`        .full => rt.inFrame(addr) or inOldHeap(addr),`);
    this.out.push(`    };`);
    this.out.push(`}`);

    if (bytesUsed) {
      this.out.push(``);
      this.out.push(`fn commitBytes(bytes: []const u8, mode: CommitMode) []const u8 {`);
      this.out.push(`    if (bytes.len == 0) return empty_bytes;`);
      this.out.push(`    if (!shouldCopy(mode, bytes.ptr)) return bytes;`);
      this.out.push(`    const out = rt.heapAlloc(u8, bytes.len);`);
      this.out.push(`    @memcpy(out, bytes);`);
      this.out.push(`    return out;`);
      this.out.push(`}`);
    }

    if (scalarSlices) {
      this.out.push(``);
      this.out.push(`// Primitive arrays (numbers, booleans, tags) copy in one exact-size block;`);
      this.out.push(`// an unchanged array shares by pointer, exactly like record arrays.`);
      this.out.push(`fn commitScalars(comptime T: type, values: []const T, mode: CommitMode) []const T {`);
      this.out.push(`    if (values.len == 0) return &.{};`);
      this.out.push(`    if (!shouldCopy(mode, values.ptr)) return values;`);
      this.out.push(`    const out = rt.heapAlloc(T, values.len);`);
      this.out.push(`    @memcpy(out, values);`);
      this.out.push(`    return out;`);
      this.out.push(`}`);
    }

    for (const info of structs) {
      this.out.push(``);
      this.out.push(`fn commit${info.name}(value: *const ${info.name}, mode: CommitMode) *const ${info.name} {`);
      this.out.push(`    if (!shouldCopy(mode, value)) return value;`);
      this.out.push(`    return rt.heapCreate(${info.name}, .{`);
      for (const f of info.fields) {
        this.out.push(`        .${fieldName(f)} = ${this.commitFieldExpr(f)},`);
      }
      this.out.push(`    });`);
      this.out.push(`}`);
      if (sliceElems.has(info.name)) {
        this.out.push(``);
        this.out.push(
          `fn commit${info.name}s(values: []const *const ${info.name}, mode: CommitMode) []const *const ${info.name} {`,
        );
        this.out.push(`    if (values.len == 0) return &.{};`);
        this.out.push(`    if (!shouldCopy(mode, values.ptr)) return values;`);
        this.out.push(`    const out = rt.heapAlloc(*const ${info.name}, values.len);`);
        this.out.push(`    for (values, 0..) |v, i| out[i] = commit${info.name}(v, mode);`);
        this.out.push(`    return out;`);
        this.out.push(`}`);
      }
    }

    for (const info of unions) {
      // R6b: the union value lives inline in its holder — the walker
      // rewrites the active arm's heap references and passes every other
      // arm through unchanged. Compaction never chases a dead arm's payload.
      this.out.push(``);
      this.out.push(`fn commit${info.name}(value: ${info.name}, mode: CommitMode) ${info.name} {`);
      this.out.push(`    return switch (value) {`);
      for (const arm of info.arms) {
        const armNeedsCommit = arm.fields.some((f) => this.typeNeedsCommit(this.fieldZType(f)));
        if (!armNeedsCommit) {
          this.out.push(`        .${zigId(arm.tag)} => value,`);
          continue;
        }
        if (arm.fields.length === 1) {
          const inner = this.commitValueExpr(this.fieldZType(arm.fields[0]), "v", arm.fields[0].decl);
          this.out.push(`        .${zigId(arm.tag)} => |v| .{ .${zigId(arm.tag)} = ${inner} },`);
        } else {
          const parts = arm.fields.map(
            (f) => `.${fieldName(f)} = ${this.commitValueExpr(this.fieldZType(f), `v.${fieldName(f)}`, f.decl)}`,
          );
          this.out.push(`        .${zigId(arm.tag)} => |v| .{ .${zigId(arm.tag)} = .{ ${parts.join(", ")} } },`);
        }
      }
      this.out.push(`    };`);
      this.out.push(`}`);
    }

    this.out.push(``);
    this.out.push(`/// Frame-end commit: returns the persistent model root; flips into a full`);
    this.out.push(`/// compacting copy when the heap passes its watermark.`);
    this.out.push(`pub fn commitModelRoot(next: *const Model) *const Model {`);
    this.out.push(`    const before = rt.heapUsed();`);
    this.out.push(`    if (before > rt.heap_watermark) {`);
    this.out.push(`        old_heap_base = rt.currentHeapBase();`);
    this.out.push(`        old_heap_len = rt.heap_cap;`);
    this.out.push(`        rt.heapFlip();`);
    this.out.push(`        rt.stat_compactions += 1;`);
    this.out.push(`        const committed = commitModel(next, .full);`);
    this.out.push(`        rt.stat_commit_last = rt.heapUsed();`);
    this.out.push(`        return committed;`);
    this.out.push(`    }`);
    this.out.push(`    const committed = commitModel(next, .incremental);`);
    this.out.push(`    rt.stat_commit_last = rt.heapUsed() - before;`);
    this.out.push(`    return committed;`);
    this.out.push(`}`);
  }

  private commitFieldExpr(f: ZField): string {
    return this.commitValueExpr(this.fieldZType(f), `value.${fieldName(f)}`, f.decl);
  }

  /// The commit expression for one model value (a struct field or a union
  /// arm payload): scalars pass through, everything heap-shaped routes to
  /// its walker.
  private commitValueExpr(t: ZType, access: string, decl: ts.Node): string {
    switch (t.k) {
      case "i64":
      case "f64":
      case "bool":
      case "enum":
      case "numAlias":
        return access;
      case "bytes":
        return `commitBytes(${access}, mode)`;
      case "struct":
        if (this.table.isPointerStruct(t.name)) return `commit${t.name}(${access}, mode)`;
        return this.assertShallow(t, access);
      case "union":
        return this.typeNeedsCommit(t) ? `commit${t.name}(${access}, mode)` : access;
      case "slice": {
        if (t.elem.k === "struct" && this.table.isPointerStruct(t.elem.name)) {
          return `commit${t.elem.name}s(${access}, mode)`;
        }
        const elem = this.elemZType(t.elem);
        if (isScalarElem(elem)) {
          return `commitScalars(${this.table.zigTypeRef(elem)}, ${access}, mode)`;
        }
        this.fail(
          decl,
          `commit walker for slice of ${t.elem.k} in the model (v1 stores arrays of records, numbers, booleans, and literal-union tags)`,
        );
        break;
      }
      case "optional": {
        const inner = t.inner;
        if (!this.typeNeedsCommit(inner)) return access;
        // `opt` never collides: the only surrounding captures are a union
        // arm's `v` and the walker's `value` parameter.
        return `if (${access}) |opt| ${this.commitValueExpr(inner, "opt", decl)} else null`;
      }
      default:
        this.fail(decl, `commit walker for field type ${t.k}`);
    }
  }

  private assertShallow(t: ZType & { k: "struct" }, access: string): string {
    const info = this.table.structs.get(t.name);
    const deep = info?.fields.some((f) => {
      const ft = this.fieldZType(f);
      return ft.k === "bytes" || ft.k === "struct" || ft.k === "slice" || ft.k === "optional";
    });
    if (deep) {
      throw new EmitError(`promoted struct ${t.name} holding heap references inside the model (v1)`, info!.decl);
    }
    return access;
  }
}

// ---------------------------------------------------------------- helpers

/// The named function declaration a node sits in (for emitted comments).
function enclosingFunctionName(node: ts.Node): string | null {
  let cur: ts.Node | undefined = node.parent;
  while (cur && !ts.isSourceFile(cur)) {
    if (ts.isFunctionDeclaration(cur) && cur.name) return `\`${cur.name.text}\``;
    cur = cur.parent;
  }
  return null;
}

/// Uint8Array methods that WRITE through the receiver. The emitter lowers
/// them to `@memcpy`/element stores, so a parameter they run against must
/// emit as `[]u8` — never `[]const u8`.
const bytesWritingMethods = new Set(["set", "fill", "copyWithin", "sort", "reverse"]);

const assignmentOps = new Set([
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

function fieldName(f: ZField): string {
  return f.zigName;
}

/// Slice elements the generic scalar walker can @memcpy: fixed-size values
/// with no heap references.
function isScalarElem(t: ZType): boolean {
  return t.k === "i64" || t.k === "f64" || t.k === "bool" || t.k === "enum" || t.k === "numAlias";
}

function zigId(name: string): string {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : `@"${name}"`;
}

/// Zig keywords that are legal JS label identifiers — a TS label with one of
/// these names takes a suffix so the emitted `label: while` stays parseable.
const zigOnlyKeywords = new Set([
  "test", "pub", "fn", "defer", "error", "comptime", "inline", "align", "and", "or",
  "orelse", "union", "struct", "opaque", "resume", "suspend", "async", "unreachable",
  "usingnamespace", "noalias", "callconv", "anytype", "anyframe", "volatile",
  "allowzero", "addrspace", "linksection", "threadlocal", "errdefer", "nosuspend",
  "undefined", "asm",
]);

/// The emitted Zig label for a TS statement label (R12c).
function loopLabel(name: string): string {
  return zigOnlyKeywords.has(name) ? `${name}_label` : name;
}

/// Variable names that would shadow a Zig primitive type (i2, u8, f64, ...)
/// take the reserved-word convention: a trailing underscore. Collision
/// suffixing produces these routinely (a second loop index becomes `i2`).
function zigSafeName(name: string): string {
  return isZigPrimitiveName(name) ? `${name}_` : name;
}

function formatNumber(v: number, cls: "i64" | "f64"): string {
  if (Number.isInteger(v) && !Object.is(v, -0)) return String(v);
  if (cls === "i64") throw new Error(`non-integer constant emitted as i64: ${v}`);
  return f64Literal(v);
}

/// A JS number as Zig f64 source text, non-finite values and the signed
/// zero included (String(NaN/Infinity/-0) would be invalid or wrong Zig).
function f64Literal(v: number): string {
  if (Number.isNaN(v)) return "std.math.nan(f64)";
  if (v === Infinity) return "std.math.inf(f64)";
  if (v === -Infinity) return "-std.math.inf(f64)";
  if (Object.is(v, -0)) return "-0.0";
  const s = String(v);
  return /[.eE]/.test(s) ? s : `${s}.0`;
}

function escapeZigString(s: string): string {
  let out = "";
  for (const ch of s) {
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\r") out += "\\r";
    else out += ch;
  }
  return out;
}

/// A block statement sitting directly in a statement list — a plain lexical
/// block, where control always falls straight through. Everything else a
/// Block can be (an if/else arm, a loop or callback body, a try/catch
/// block, a labeled statement's body) is a merge context: control JOINS at
/// its exit, so narrowing must bracket it there.
function isPlainLexicalBlock(b: ts.Block): boolean {
  return (
    ts.isBlock(b.parent) ||
    ts.isSourceFile(b.parent) ||
    ts.isCaseClause(b.parent) ||
    ts.isDefaultClause(b.parent)
  );
}

function unwrapOptional(t: ZType): ZType {
  return t.k === "optional" ? t.inner : t;
}

/// Parenthesize an emitted expression that must stand as the LEFT operand
/// of `orelse`. A TS ternary lowers to a Zig `if (c) A else B` EXPRESSION;
/// bare, `if (c) A else B orelse X` binds the orelse to the ELSE arm only
/// (a type error at best, the wrong value at worst), so the whole
/// conditional gets wrapped.
function orelseOperand(code: string): string {
  return code.startsWith("if ") ? `(${code})` : code;
}

/// Whether a statement contains a `return` of its own function level
/// (nested functions excluded) — the early-exit test for callback lifting.
function containsReturn(node: ts.Node): boolean {
  let found = false;
  const visit = (n: ts.Node): void => {
    if (found) return;
    if (ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n)) return;
    if (ts.isReturnStatement(n)) {
      found = true;
      return;
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return found;
}

function unwrapSingle(stmt: ts.Statement): ts.Statement | null {
  if (ts.isBlock(stmt)) return stmt.statements.length === 1 ? stmt.statements[0] : null;
  return stmt;
}

function needsParens(expr: ts.Expression): boolean {
  return ts.isBinaryExpression(expr) || ts.isConditionalExpression(expr);
}

function maybeParen(code: string): string {
  return /^[A-Za-z0-9_.@()\[\]?*"]+$/.test(code) || /^\w+\(.*\)$/.test(code) ? code : `(${code})`;
}

/// Zig has no operator precedence between `and`/`or` and comparisons beyond
/// the C-like table; parenthesize nested binary operands conservatively.
function precedenceParen(orig: ts.Expression, parentOp: string, code: string): string {
  if (!ts.isBinaryExpression(orig) && !ts.isConditionalExpression(orig)) return code;
  if (code.startsWith("(") && code.endsWith(")")) return code;
  if (ts.isConditionalExpression(orig)) return `(${code})`;
  const childOp = orig.operatorToken.kind;
  const cmp = new Set([
    ts.SyntaxKind.EqualsEqualsEqualsToken,
    ts.SyntaxKind.ExclamationEqualsEqualsToken,
    ts.SyntaxKind.LessThanToken,
    ts.SyntaxKind.LessThanEqualsToken,
    ts.SyntaxKind.GreaterThanToken,
    ts.SyntaxKind.GreaterThanEqualsToken,
  ]);
  const arith = new Set([
    ts.SyntaxKind.PlusToken,
    ts.SyntaxKind.MinusToken,
    ts.SyntaxKind.AsteriskToken,
  ]);
  if (parentOp === "and" || parentOp === "or") {
    // comparisons bind tighter than and/or; mixed and/or requires parens.
    if (cmp.has(childOp) || arith.has(childOp)) return code;
    return `(${code})`;
  }
  if (["==", "!=", "<", "<=", ">", ">="].includes(parentOp)) {
    if (arith.has(childOp)) return code;
    return `(${code})`;
  }
  if (["+", "-"].includes(parentOp)) {
    if (arith.has(childOp)) return code;
    return `(${code})`;
  }
  if (["&", "|", "^"].includes(parentOp)) return `(${code})`;
  if (["*"].includes(parentOp)) {
    if (childOp === ts.SyntaxKind.AsteriskToken) return code;
    return `(${code})`;
  }
  return `(${code})`;
}

export { EmitError };

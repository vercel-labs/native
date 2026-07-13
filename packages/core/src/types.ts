// The module type table: every named type in an app core, classified into
// the Zig type model the mapping rules emit against.
//
//   string-literal union  -> enum(u8), declaration order (R5)
//   number-literal union  -> integer alias (R5; see report: v1 emits the
//                            integer repr instead of a synthesized enum —
//                            member names cannot be derived mechanically)
//   discriminated union   -> union(enum), payloads inlined per arm (R6)
//   interface             -> struct; by-value when promoted (R4), else a
//                            frame/heap node behind *const T (R14)
//   readonly T[]          -> []const E; []const *const T for node types (R16)
//   T | null/undefined    -> ?T (R7)
//   Uint8Array            -> []const u8 (R3)

import { ts, TypedAst, hasExportModifier, exportListBindings, type PropInfo } from "./typed_ast.ts";
import { mutatingMethodNames } from "./ownership.ts";

export type ZType =
  | { readonly k: "number" } // resolved to i64/f64 per slot by integer inference (R2)
  | { readonly k: "i64" }
  | { readonly k: "f64" }
  | { readonly k: "bool" }
  | { readonly k: "void" }
  | { readonly k: "bytes" }
  | { readonly k: "string" } // rodata literals only; storage is []const u8
  | { readonly k: "numAlias"; readonly name: string; readonly repr: "u8" | "i64"; readonly values: readonly number[] }
  | { readonly k: "enum"; readonly name: string; readonly members: readonly string[] }
  | { readonly k: "struct"; readonly name: string }
  | { readonly k: "union"; readonly name: string }
  | { readonly k: "slice"; readonly elem: ZType }
  | { readonly k: "optional"; readonly inner: ZType };

export interface ZField {
  readonly tsName: string;
  readonly zigName: string;
  readonly type: ZType;
  readonly decl: ts.Declaration;
}

export interface StructInfo {
  readonly name: string;
  readonly decl: ts.InterfaceDeclaration | ts.ClassDeclaration;
  /// Filled in the second collection pass (field types may reference types
  /// declared in any of the core's files, in any order).
  fields: readonly ZField[];
  /// Mutable: an un-renamed export list (`export { Task }`) exports a class
  /// declared without the modifier.
  exported: boolean;
  promoted: boolean;
}

export interface UnionArm {
  readonly tag: string;
  /// Empty -> void arm; one field -> bare payload; several -> anonymous struct.
  readonly fields: readonly ZField[];
}

export interface UnionInfo {
  readonly name: string;
  readonly decl: ts.TypeAliasDeclaration;
  /// Filled in the second collection pass, like StructInfo.fields.
  arms: readonly UnionArm[];
  readonly exported: boolean;
}

export interface EnumInfo {
  readonly name: string;
  readonly decl: ts.TypeAliasDeclaration;
  readonly members: readonly string[];
  readonly exported: boolean;
}

export interface NumAliasInfo {
  readonly name: string;
  readonly decl: ts.TypeAliasDeclaration;
  readonly repr: "u8" | "i64";
  readonly values: readonly number[];
  readonly exported: boolean;
}

/// A data class: the struct (registered in `structs` under the same name)
/// plus its behavior surface — the constructor `new` calls and the methods
/// that emit as module-level functions.
export interface ClassInfo {
  readonly name: string;
  readonly decl: ts.ClassDeclaration;
  readonly ctor: ts.ConstructorDeclaration | null;
  /// Instance methods (static methods are module-level functions, below).
  readonly methods: readonly ts.MethodDeclaration[];
  /// `static` methods: module-level functions under the class's mangled
  /// names (`Task__fromRow`), no receiver.
  readonly staticMethods: readonly ts.MethodDeclaration[];
  /// `static readonly` fields with initializers: module consts under the
  /// class's mangled names (`Task__LIMIT`). Mutable statics are taught
  /// (module state, NS1010).
  readonly staticConsts: readonly ts.PropertyDeclaration[];
  /// Methods whose bodies (transitively) write `this` — pointer receivers;
  /// call sites require a locally-owned instance.
  readonly mutating: ReadonlySet<string>;
}

/// Whether a class member carries the `static` modifier.
export function isStaticMember(m: ts.ClassElement): boolean {
  return ts.canHaveModifiers(m) && (ts.getModifiers(m) ?? []).some((x) => x.kind === ts.SyntaxKind.StaticKeyword);
}

export class TypeTable {
  readonly structs = new Map<string, StructInfo>();
  readonly classes = new Map<string, ClassInfo>();
  readonly unions = new Map<string, UnionInfo>();
  readonly enums = new Map<string, EnumInfo>();
  readonly numAliases = new Map<string, NumAliasInfo>();
  /// Aliases that resolve to bytes (e.g. `type Bytes = Uint8Array`).
  readonly bytesAliases = new Set<string>();
  /// Alias name -> aliased named type (plain `type A = B`).
  readonly plainAliases = new Map<string, string>();
  /// Aliases that resolve STRUCTURALLY through their type node under the
  /// active type-parameter scope (`type Limit = typeof LIMIT` today).
  readonly structuralAliases = new Map<string, ts.TypeNode>();
  /// Generic templates: declared once, instantiated per concrete argument
  /// list (`Box<Task>` -> the emitted struct `Box__Task`).
  readonly genericStructTemplates = new Map<string, ts.InterfaceDeclaration>();
  readonly genericAliasTemplates = new Map<string, ts.TypeAliasDeclaration>();
  /// Instantiations created on demand, in creation order — the emitter
  /// appends these as a generated-types section (Zig scope is order-free).
  readonly instantiationOrder: string[] = [];
  readonly declOrder: string[] = [];

  /// The active type-parameter substitution (monomorphization): resolved
  /// concrete type per TypeParameterDeclaration, keyed by declaration
  /// identity. One scope at a time — instantiations emit serially.
  private typeParamScope: ReadonlyMap<ts.Declaration, ZType> | null = null;

  withTypeParams<T>(scope: ReadonlyMap<ts.Declaration, ZType> | null, run: () => T): T {
    const prev = this.typeParamScope;
    this.typeParamScope = scope;
    try {
      return run();
    } finally {
      this.typeParamScope = prev;
    }
  }

  activeTypeParams(): ReadonlyMap<ts.Declaration, ZType> | null {
    return this.typeParamScope;
  }

  private readonly tast: TypedAst;
  /// The core's modules in canonical order (entry first) — one flat type
  /// namespace across all of them (cross-file name collisions are the
  /// checker's NS1038).
  private readonly files: readonly ts.SourceFile[];

  constructor(tast: TypedAst, files: readonly ts.SourceFile[] | ts.SourceFile) {
    this.tast = tast;
    this.files = Array.isArray(files) ? files : [files as ts.SourceFile];
    // Two passes: names classify first (across every file), fields resolve
    // second — a field's type may reference a type declared in a LATER
    // file (`core.ts` holding a `readonly Item[]` of `tables.ts`'s Item),
    // so resolution must see the whole namespace.
    for (const file of this.files) this.classify(file);
    for (const file of this.files) this.fill(file);
    // An un-renamed export list over a class exports it exactly like the
    // modifier would (renamed class exports are checker-taught NS1047).
    for (const file of this.files) {
      for (const b of exportListBindings(this.tast, file)) {
        if (b.target && ts.isClassDeclaration(b.target) && !b.renamed && b.target.name) {
          const info = this.structs.get(b.target.name.text);
          if (info && info.decl === b.target) info.exported = true;
        }
      }
    }
    this.markPromotions();
  }

  private classify(file: ts.SourceFile): void {
    for (const stmt of file.statements) {
      if (ts.isClassDeclaration(stmt) && stmt.name) {
        // A data class is a struct (its fields) plus module-level functions
        // (constructor and methods). Ill-shaped classes (heritage, generics)
        // are checker-taught; they stay out of the table so nothing emits
        // against a shape the mapping does not carry.
        if ((stmt.typeParameters && stmt.typeParameters.length > 0) || (stmt.heritageClauses && stmt.heritageClauses.length > 0)) {
          continue;
        }
        const name = stmt.name.text;
        this.structs.set(name, {
          name,
          decl: stmt,
          fields: [],
          exported: hasExportModifier(stmt),
          promoted: true, // refined by markPromotions
        });
        const methods = stmt.members.filter(
          (m): m is ts.MethodDeclaration => ts.isMethodDeclaration(m) && ts.isIdentifier(m.name) && !isStaticMember(m),
        );
        const staticMethods = stmt.members.filter(
          (m): m is ts.MethodDeclaration => ts.isMethodDeclaration(m) && ts.isIdentifier(m.name) && isStaticMember(m),
        );
        const staticConsts = stmt.members.filter(
          (m): m is ts.PropertyDeclaration =>
            ts.isPropertyDeclaration(m) &&
            ts.isIdentifier(m.name) &&
            isStaticMember(m) &&
            m.initializer !== undefined &&
            (ts.getModifiers(m) ?? []).some((x) => x.kind === ts.SyntaxKind.ReadonlyKeyword),
        );
        const ctor =
          stmt.members.find((m): m is ts.ConstructorDeclaration => ts.isConstructorDeclaration(m) && m.body !== undefined) ??
          null;
        this.classes.set(name, { name, decl: stmt, ctor, methods, staticMethods, staticConsts, mutating: mutatingMethodNames(stmt) });
        this.declOrder.push(name);
        continue;
      }
      if (ts.isInterfaceDeclaration(stmt)) {
        const name = stmt.name.text;
        if (stmt.typeParameters && stmt.typeParameters.length > 0) {
          // A generic interface is a TEMPLATE: it emits nothing itself and
          // instantiates per concrete argument list (`Box<Task>`).
          this.genericStructTemplates.set(name, stmt);
          continue;
        }
        this.structs.set(name, {
          name,
          decl: stmt,
          fields: [],
          exported: hasExportModifier(stmt),
          promoted: true, // refined by markPromotions
        });
        this.declOrder.push(name);
      } else if (ts.isTypeAliasDeclaration(stmt)) {
        const name = stmt.name.text;
        const exported = hasExportModifier(stmt);
        if (stmt.typeParameters && stmt.typeParameters.length > 0) {
          // A generic alias resolves structurally per instantiation:
          // discriminated-union bodies become named instantiations, other
          // bodies resolve straight through under the argument scope.
          this.genericAliasTemplates.set(name, stmt);
          continue;
        }
        if (ts.isTypeQueryNode(stmt.type)) {
          // `type Limit = typeof LIMIT` — the alias resolves structurally
          // through the checker's own type query (type-level only; the
          // emitted slots carry the widened value type).
          this.structuralAliases.set(name, stmt.type);
          this.declOrder.push(name);
          continue;
        }
        const strings = this.tast.stringLiteralUnionMembers(stmt.type);
        if (strings) {
          this.enums.set(name, { name, decl: stmt, members: strings, exported });
          this.declOrder.push(name);
          continue;
        }
        const numbers = this.tast.numberLiteralUnionMembers(stmt.type);
        if (numbers) {
          const repr = numbers.every((v) => Number.isInteger(v) && v >= 0 && v <= 255) ? "u8" : "i64";
          this.numAliases.set(name, { name, decl: stmt, repr, values: numbers, exported });
          this.declOrder.push(name);
          continue;
        }
        const disc = this.tast.discriminatedUnionMembers(stmt.type, "kind");
        if (disc) {
          this.unions.set(name, { name, decl: stmt, arms: [], exported });
          this.declOrder.push(name);
          continue;
        }
        if (ts.isTypeReferenceNode(stmt.type) && ts.isIdentifier(stmt.type.typeName)) {
          const target = stmt.type.typeName.text;
          if (target === "Uint8Array") {
            this.bytesAliases.add(name);
            this.declOrder.push(name);
            continue;
          }
          this.plainAliases.set(name, target);
          this.declOrder.push(name);
        }
      }
    }
  }

  private fill(file: ts.SourceFile): void {
    for (const stmt of file.statements) {
      if (ts.isClassDeclaration(stmt) && stmt.name) {
        const info = this.structs.get(stmt.name.text);
        if (info && info.decl === stmt) {
          info.fields = this.tast.propsOfClass(stmt).map((p) => this.fieldOf(p));
        }
      } else if (ts.isInterfaceDeclaration(stmt)) {
        const info = this.structs.get(stmt.name.text);
        if (info && info.decl === stmt) {
          info.fields = this.tast.propsOfInterface(stmt).map((p) => this.fieldOf(p));
        }
      } else if (ts.isTypeAliasDeclaration(stmt)) {
        const info = this.unions.get(stmt.name.text);
        if (info && info.decl === stmt) {
          const disc = this.tast.discriminatedUnionMembers(stmt.type, "kind");
          if (disc) {
            info.arms = disc.map((m) => ({ tag: m.tag, fields: m.fields.map((p) => this.fieldOf(p)) }));
          }
        }
      }
    }
  }

  private fieldOf(p: PropInfo): ZField {
    return {
      tsName: p.name,
      zigName: zigDeclName(p.name),
      type: p.typeNode ? this.resolveTypeNode(p.typeNode) : { k: "void" },
      decl: p.declaration,
    };
  }

  /// R4: an interface is a by-value struct unless it is stored in the model
  /// tree (Model and everything reachable from its fields), or is identity-
  /// compared. When in doubt, stay a pointer.
  private markPromotions(): void {
    const pointerKind = new Set<string>();
    const seenUnions = new Set<string>();
    const visit = (t: ZType): void => {
      switch (t.k) {
        case "struct": {
          if (pointerKind.has(t.name)) return;
          pointerKind.add(t.name);
          const info = this.structs.get(t.name);
          if (info) for (const f of info.fields) visit(f.type);
          return;
        }
        case "union": {
          // A tagged union stored in the model tree keeps its by-value
          // layout (the active arm lives inline), but every record its arms
          // reference is model data and must be a heap node.
          if (seenUnions.has(t.name)) return;
          seenUnions.add(t.name);
          const info = this.unions.get(t.name);
          if (info) for (const arm of info.arms) for (const f of arm.fields) visit(f.type);
          return;
        }
        case "slice":
          return visit(t.elem);
        case "optional":
          return visit(t.inner);
        default:
          return;
      }
    };
    const model = this.structs.get("Model");
    if (model) visit({ k: "struct", name: "Model" });
    // The text-input mirror contract is structural on the ZIG side too: the
    // engines recognize a declared event union by its exact payload shapes
    // (by-value selection/caret-move records) and TRANSLATE runtime events
    // into it by constructing those records. A core that also stores the
    // editor state in its Model (a perfectly idiomatic choice) would drag
    // those records into pointer-kind here and silently break the mirror —
    // so records referenced from a text-input-shaped union always stay
    // by value (they are two-scalar records; by-value model storage is the
    // promoted default everywhere else already).
    for (const info of this.unions.values()) {
      if (!isTextInputMirror(info)) continue;
      for (const arm of info.arms) {
        for (const f of arm.fields) {
          if (f.type.k === "struct") pointerKind.delete(f.type.name);
        }
      }
    }
    for (const name of pointerKind) {
      const info = this.structs.get(name);
      if (info) info.promoted = false;
    }
  }

  isPointerStruct(name: string): boolean {
    const info = this.structs.get(name);
    return info !== undefined && !info.promoted;
  }

  /// Exported single-Model-parameter helpers with a mapped return type:
  /// each also emits as a forwarding declaration on the Model struct (the
  /// markup fn-backed-scalar shape), under its own TS name — markup binds
  /// `doneCount` as `{doneCount}`. The reserved entry points
  /// (update/initialModel/subscriptions) never forward. Shared by the
  /// checker (NS1031/NS1032) and the emitter.
  ///
  /// ENTRY-ONLY on purpose: under node the app's module object is the
  /// entry's exports, so a helper exported from an imported module would
  /// bind natively but not exist under node. An imported module's export
  /// is cross-module API (`nextTrackId` for update to call), never a
  /// markup binding — put binding helpers in core.ts.
  modelHelperDecls(): { name: string; zigName: string; decl: ts.FunctionDeclaration }[] {
    const out: { name: string; zigName: string; decl: ts.FunctionDeclaration }[] = [];
    if (!this.structs.has("Model")) return out;
    for (const stmt of this.files[0].statements) {
      if (!ts.isFunctionDeclaration(stmt) || !stmt.name || !hasExportModifier(stmt)) continue;
      if (!this.isModelHelperShape(stmt, stmt.name.text)) continue;
      out.push({ name: stmt.name.text, zigName: zigDeclName(stmt.name.text), decl: stmt });
    }
    // Export-list bindings join the surface under their EXPORTED names —
    // only where the declaration itself is entry-module (the entry-only
    // rule above holds: a re-exported imported helper would bind natively
    // but not exist on node's entry module object).
    for (const b of exportListBindings(this.tast, this.files[0])) {
      const t = b.target;
      if (!t || !ts.isFunctionDeclaration(t) || t.getSourceFile() !== this.files[0]) continue;
      if (!this.isModelHelperShape(t, b.exportedName)) continue;
      if (out.some((h) => h.name === b.exportedName && h.decl === t)) continue;
      out.push({ name: b.exportedName, zigName: zigDeclName(b.exportedName), decl: t });
    }
    return out;
  }

  /// The single-Model-parameter derived-value shape, under the name the
  /// helper is exported as (the reserved entry points never forward).
  private isModelHelperShape(stmt: ts.FunctionDeclaration, exportedName: string): boolean {
    if (exportedName === "update" || exportedName === "initialModel" || exportedName === "subscriptions") return false;
    if (stmt.parameters.length !== 1) return false;
    const p = stmt.parameters[0];
    if (!p.type || !stmt.type) return false;
    const pt = this.resolveTypeNode(p.type);
    if (pt.k !== "struct" || pt.name !== "Model") return false;
    return this.resolveTypeNode(stmt.type).k !== "void";
  }

  resolveName(name: string): ZType | null {
    const seen = new Set<string>();
    let cur = name;
    while (this.plainAliases.has(cur) && !seen.has(cur)) {
      seen.add(cur);
      cur = this.plainAliases.get(cur)!;
    }
    const structural = this.structuralAliases.get(cur);
    if (structural) return this.resolveTypeNode(structural);
    if (this.bytesAliases.has(cur)) return { k: "bytes" };
    if (this.structs.has(cur)) return { k: "struct", name: cur };
    if (this.unions.has(cur)) return { k: "union", name: cur };
    if (this.enums.has(cur)) return { k: "enum", name: cur, members: this.enums.get(cur)!.members };
    if (this.numAliases.has(cur)) {
      const a = this.numAliases.get(cur)!;
      return { k: "numAlias", name: cur, repr: a.repr, values: a.values };
    }
    if (cur === "Uint8Array") return { k: "bytes" };
    return null;
  }

  resolveTypeNode(node: ts.TypeNode): ZType {
    switch (node.kind) {
      case ts.SyntaxKind.NumberKeyword:
        return { k: "number" };
      case ts.SyntaxKind.BooleanKeyword:
        return { k: "bool" };
      case ts.SyntaxKind.StringKeyword:
        return { k: "string" };
      case ts.SyntaxKind.VoidKeyword:
        return { k: "void" };
      default:
        break;
    }
    if (ts.isParenthesizedTypeNode(node)) return this.resolveTypeNode(node.type);
    if (ts.isLiteralTypeNode(node) && ts.isStringLiteral(node.literal)) {
      // A single string-literal type (`kind: "parse"` on an error record):
      // the field holds exactly that literal, stored as rodata text — what
      // lets an interface with a literal `kind` field exist as a struct and
      // contribute its arm to the thrown union.
      return { k: "string" };
    }
    if (ts.isTypeQueryNode(node)) {
      // `typeof CONST` — the checker's own type query, widened to the
      // value's slot type (type-level only; erases under node identically).
      return this.zTypeOfTsType(this.tast.typeFromTypeNode(node)) ?? { k: "void" };
    }
    if (ts.isUnionTypeNode(node)) {
      const nonNull = node.types.filter(
        (t) =>
          !(ts.isLiteralTypeNode(t) && t.literal.kind === ts.SyntaxKind.NullKeyword) &&
          t.kind !== ts.SyntaxKind.UndefinedKeyword,
      );
      if (nonNull.length === 1 && nonNull.length !== node.types.length) {
        return { k: "optional", inner: this.resolveTypeNode(nonNull[0]) };
      }
      // Non-null inline unions must be named aliases (enum/tagged union).
      return { k: "void" };
    }
    if (ts.isArrayTypeNode(node)) {
      return { k: "slice", elem: this.resolveTypeNode(node.elementType) };
    }
    if (ts.isTypeOperatorNode(node) && node.operator === ts.SyntaxKind.ReadonlyKeyword) {
      return this.resolveTypeNode(node.type);
    }
    if (ts.isTypeReferenceNode(node) && ts.isQualifiedName(node.typeName)) {
      // `ns.Config` through a namespace import: the alias erases and type
      // names are unique across the core's files (NS1038), so the right
      // side resolves directly against the table (declaration identity
      // covers a re-aliased name).
      const named = this.resolveName(node.typeName.right.text);
      if (named) return named;
      const decl = this.tast.declarationOf(node.typeName.right);
      if (decl && (ts.isInterfaceDeclaration(decl) || ts.isTypeAliasDeclaration(decl))) {
        const byDecl = this.resolveName(decl.name.text);
        if (byDecl) return byDecl;
      }
      return { k: "void" };
    }
    if (ts.isTypeReferenceNode(node) && ts.isIdentifier(node.typeName)) {
      const name = node.typeName.text;
      if (name === "ReadonlyArray" || name === "Array") {
        const arg = node.typeArguments?.[0];
        return { k: "slice", elem: arg ? this.resolveTypeNode(arg) : { k: "void" } };
      }
      const decl = this.tast.declarationOf(node.typeName);
      // A type-parameter reference resolves through the active
      // monomorphization scope (`T` -> the instantiation's concrete type).
      if (decl && ts.isTypeParameterDeclaration(decl)) {
        return this.typeParamScope?.get(decl) ?? { k: "void" };
      }
      // A generic template instantiates per concrete argument list.
      const templateName = decl && (ts.isInterfaceDeclaration(decl) || ts.isTypeAliasDeclaration(decl)) ? decl.name.text : name;
      const structTemplate = this.genericStructTemplates.get(templateName);
      if (structTemplate) {
        return this.instantiateStruct(structTemplate, (node.typeArguments ?? []).map((a) => this.resolveTypeNode(a)));
      }
      const aliasTemplate = this.genericAliasTemplates.get(templateName);
      if (aliasTemplate) {
        return this.instantiateAlias(aliasTemplate, (node.typeArguments ?? []).map((a) => this.resolveTypeNode(a)));
      }
      const named = this.resolveName(name);
      if (named) return named;
      // A renamed import (`import { Row as R }`): resolve through the
      // symbol to the declared name — the table is keyed by declarations.
      if (decl && (ts.isInterfaceDeclaration(decl) || ts.isTypeAliasDeclaration(decl)) && decl.name.text !== name) {
        const byDecl = this.resolveName(decl.name.text);
        if (byDecl) return byDecl;
      }
    }
    return { k: "void" };
  }

  /// One concrete instantiation of a generic interface: a named struct per
  /// distinct argument list (`Box<Task>` -> `Box__Task`), deduped by name.
  /// Fields resolve under the template's parameter scope; a recursive
  /// reference lands on the already-registered name.
  instantiateStruct(template: ts.InterfaceDeclaration, args: readonly ZType[]): ZType {
    if (args.length === 0 || args.some((a) => a.k === "void")) return { k: "void" };
    const name = `${template.name.text}__${args.map(mangleZType).join("__")}`;
    if (!this.structs.has(name)) {
      const scope = new Map<ts.Declaration, ZType>();
      template.typeParameters!.forEach((tp, i) => scope.set(tp, args[i] ?? { k: "void" }));
      const info: StructInfo = {
        name,
        decl: template,
        fields: [],
        exported: hasExportModifier(template),
        promoted: true, // instantiations follow the same promotion pass when model-reachable
      };
      this.structs.set(name, info);
      this.instantiationOrder.push(name);
      info.fields = this.withTypeParams(scope, () => this.tast.propsOfInterface(template).map((p) => this.fieldOf(p)));
    }
    return { k: "struct", name };
  }

  /// One concrete instantiation of a generic type alias. A discriminated
  /// union body becomes a named union instantiation; every other body
  /// (optionals, arrays, plain compositions) resolves structurally under
  /// the argument scope.
  instantiateAlias(template: ts.TypeAliasDeclaration, args: readonly ZType[]): ZType {
    if (args.length === 0 || args.some((a) => a.k === "void")) return { k: "void" };
    const scope = new Map<ts.Declaration, ZType>();
    template.typeParameters!.forEach((tp, i) => scope.set(tp, args[i] ?? { k: "void" }));
    const disc = this.tast.discriminatedUnionMembers(template.type, "kind");
    if (!disc) {
      return this.withTypeParams(scope, () => this.resolveTypeNode(template.type));
    }
    const name = `${template.name.text}__${args.map(mangleZType).join("__")}`;
    if (!this.unions.has(name)) {
      const info: UnionInfo = { name, decl: template, arms: [], exported: hasExportModifier(template) };
      this.unions.set(name, info);
      this.instantiationOrder.push(name);
      info.arms = this.withTypeParams(scope, () =>
        disc.map((m) => ({ tag: m.tag, fields: m.fields.map((p) => this.fieldOf(p)) })),
      );
    }
    return { k: "union", name };
  }

  /// ts.Type -> ZType: the resolved-type side of the mapping, used where a
  /// type arrives from the checker instead of a syntax node (type queries,
  /// resolved generic arguments). Returns null for types with no mapping.
  zTypeOfTsType(t: import("./typed_ast.ts").Type): ZType | null {
    // A still-generic type parameter resolves through the active scope
    // (generics calling generics inside a template body).
    if ((t.flags & ts.TypeFlags.TypeParameter) !== 0) {
      const decl = t.symbol?.declarations?.[0];
      const mapped = decl ? this.typeParamScope?.get(decl) : undefined;
      return mapped ?? null;
    }
    // A named generic-alias instantiation (`Opt<Task>`) resolves through
    // its template under the resolved-argument scope.
    if (t.aliasSymbol) {
      const aliasName = t.aliasSymbol.name;
      const aliasTemplate = this.genericAliasTemplates.get(aliasName);
      if (aliasTemplate) {
        const args: ZType[] = [];
        for (const a of t.aliasTypeArguments ?? []) {
          const z = this.zTypeOfTsType(a);
          if (!z) return null;
          args.push(z);
        }
        return this.instantiateAlias(aliasTemplate, args);
      }
      const named = this.resolveName(aliasName);
      if (named) return named;
    }
    if ((t.flags & (ts.TypeFlags.Number | ts.TypeFlags.NumberLiteral)) !== 0) return { k: "number" };
    if ((t.flags & (ts.TypeFlags.Boolean | ts.TypeFlags.BooleanLiteral)) !== 0) return { k: "bool" };
    if ((t.flags & (ts.TypeFlags.String | ts.TypeFlags.StringLiteral)) !== 0) return { k: "string" };
    if (t.isUnion()) {
      const members = t.types;
      if (members.every((m) => (m.flags & (ts.TypeFlags.BooleanLiteral | ts.TypeFlags.Boolean)) !== 0)) {
        return { k: "bool" };
      }
      const nonNull = members.filter((m) => (m.flags & (ts.TypeFlags.Null | ts.TypeFlags.Undefined)) === 0);
      if (nonNull.length < members.length && nonNull.length >= 1) {
        const inner = this.zTypeOfNonNullMembers(nonNull);
        if (!inner) return null;
        return inner.k === "optional" ? inner : { k: "optional", inner };
      }
      return this.zTypeOfNonNullMembers(nonNull);
    }
    return this.zTypeOfObjectType(t);
  }

  /// The non-null members of a resolved union, mapped as one type. A
  /// single member maps directly; several string literals recover their
  /// declared enum by exact member set (tsc flattens `Filter | null`, so
  /// the alias name is gone by here); several number literals widen to the
  /// number slot type; anything else has no single mapping.
  private zTypeOfNonNullMembers(members: readonly import("./typed_ast.ts").Type[]): ZType | null {
    if (members.length === 0) return null;
    if (members.length === 1) return this.zTypeOfTsType(members[0]);
    if (members.every((m) => m.isStringLiteral())) {
      const set = new Set(members.map((m) => (m as { value: string }).value));
      for (const en of this.enums.values()) {
        if (en.members.length === set.size && en.members.every((x) => set.has(x))) {
          return { k: "enum", name: en.name, members: en.members };
        }
      }
      return null;
    }
    if (members.every((m) => (m.flags & (ts.TypeFlags.NumberLiteral | ts.TypeFlags.Number)) !== 0)) {
      // An unnamed number-literal union widens to its slot type; named
      // aliases resolve through resolveName before this point.
      return { k: "number" };
    }
    return null;
  }

  private zTypeOfObjectType(t: import("./typed_ast.ts").Type): ZType | null {
    const symName = t.symbol?.name;
    if (symName === "Uint8Array") return { k: "bytes" };
    if (this.tast.isArrayLikeType(t)) {
      const elem = this.tast.typeArgumentsOf(t)[0];
      const inner = elem ? this.zTypeOfTsType(elem) : null;
      return inner ? { k: "slice", elem: inner } : null;
    }
    if (symName) {
      const structTemplate = this.genericStructTemplates.get(symName);
      if (structTemplate) {
        const args: ZType[] = [];
        for (const a of this.tast.typeArgumentsOf(t)) {
          const z = this.zTypeOfTsType(a);
          if (!z) return null;
          args.push(z);
        }
        const inst = this.instantiateStruct(structTemplate, args);
        return inst.k === "void" ? null : inst;
      }
      const named = this.resolveName(symName);
      if (named) return named;
    }
    return null;
  }

  /// The Zig type reference for a resolved type, in field/param position.
  zigTypeRef(t: ZType): string {
    switch (t.k) {
      case "number":
        // Positions the slot inference does not cover (e.g. number-array
        // elements) stay f64 — the JS-faithful conservative default (R2).
        return "f64";
      case "i64":
        return "i64";
      case "f64":
        return "f64";
      case "bool":
        return "bool";
      case "void":
        return "void";
      case "bytes":
      case "string":
        return this.bytesAliases.has("Bytes") ? "Bytes" : "[]const u8";
      case "numAlias":
        return t.name;
      case "enum":
        return t.name;
      case "union":
        return t.name;
      case "struct":
        return this.isPointerStruct(t.name) ? `*const ${t.name}` : t.name;
      case "slice":
        return `[]const ${this.zigTypeRef(t.elem)}`;
      case "optional":
        return `?${this.zigTypeRef(t.inner)}`;
    }
  }
}

/// The canvas text-input event vocabulary — a union carrying exactly these
/// eleven tags is the declared mirror the markup engines resolve `on-input`
/// through (matched structurally on the Zig side; see
/// ui_markup_reflect.declaredTextInputUnion).
const textInputMirrorTags = [
  "insert_text",
  "delete_backward",
  "delete_forward",
  "delete_word_backward",
  "delete_word_forward",
  "clear",
  "move_caret",
  "set_selection",
  "set_composition",
  "commit_composition",
  "cancel_composition",
];

function isTextInputMirror(info: { arms: readonly UnionArm[] }): boolean {
  if (info.arms.length !== textInputMirrorTags.length) return false;
  const tags = new Set(info.arms.map((a) => a.tag));
  return textInputMirrorTags.every((tag) => tags.has(tag));
}

const zigReserved = new Set([
  "error", "var", "const", "fn", "type", "test", "struct", "union", "enum", "opaque",
  "align", "and", "or", "orelse", "return", "break", "continue", "defer", "errdefer",
  "if", "else", "switch", "while", "for", "try", "catch", "pub", "export", "extern",
  "inline", "noalias", "comptime", "unreachable", "undefined", "null", "true", "false",
  "anytype", "async", "await", "resume", "suspend", "nosuspend", "threadlocal", "volatile",
  "packed", "linksection", "callconv", "usingnamespace", "asm",
]);

/// Readable monomorphization mangle: one emitted name component per
/// resolved type argument (`pick__Task`, `pick__f64`, `Box__Task`).
export function mangleZType(t: ZType): string {
  switch (t.k) {
    case "number":
    case "f64":
      return "f64";
    case "i64":
      return "i64";
    case "bool":
      return "bool";
    case "bytes":
      return "bytes";
    case "string":
      return "str";
    case "void":
      return "void";
    case "numAlias":
    case "enum":
    case "struct":
    case "union":
      return t.name;
    case "slice":
      return `arr_${mangleZType(t.elem)}`;
    case "optional":
      return `opt_${mangleZType(t.inner)}`;
  }
}

/// Emitted-name policy: your names are your names. A TS identifier passes
/// through verbatim, so the emitted Zig mirrors the source and markup binds
/// the model's field names exactly as written (`{nextId}`, `{doneCount}`).
///
/// `zigDeclName` covers the binding surface (struct/union fields and Model
/// forwarding decls): a name that collides with a Zig keyword or primitive
/// type is @"..."-quoted, which keeps the reflected name — and therefore the
/// markup binding — byte-for-byte the TS name.
export function zigDeclName(name: string): string {
  if (zigReserved.has(name) || isZigPrimitiveName(name) || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    return `@"${name}"`;
  }
  return name;
}

/// `zigLocalName` covers locals and parameters (never a binding surface):
/// verbatim, with the trailing-underscore convention for Zig keywords —
/// locals go through the uniqueness suffixer, which cannot suffix a
/// @"..."-quoted name.
export function zigLocalName(name: string): string {
  return zigReserved.has(name) ? `${name}_` : name;
}

/// Variable names that would shadow a Zig primitive type (i2, u8, f64, ...).
export function isZigPrimitiveName(name: string): boolean {
  return /^([iu]\d+|f(16|32|64|80|128)|c_\w+|isize|usize|bool|void|comptime_(int|float)|any(opaque|error|frame|type)|noreturn)$/.test(
    name,
  );
}

/// Generated-file stems only (module-prefix disambiguation): camelCase ->
/// snake_case. User identifiers never pass through here.
export function snakeCase(name: string): string {
  if (name.toUpperCase() === name) return name; // SCREAMING_CASE constants pass through
  const out = name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
  return zigReserved.has(out) ? `${out}_` : out;
}

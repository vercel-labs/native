// The contract sidecar (core.contract.json, schema format 1), emitted
// DIRECTLY from frontend analysis: the type table, integer inference,
// and the entry module's channel exports carry every fact the document
// states, so no Zig emission sits in the loop.
//
// This is the same document tools/corewire/extract.zig reflects out of
// a transpiler-emitted core module, byte for byte: section layout,
// naming (synthesized `<Container>_<member>` records included), slot
// paths, origin facts, and the synthesized Wyhash identities all follow
// the extractor's construction, and the build pins the equivalence per
// fixture (test-contract-equivalence) for as long as both producers
// exist. Keeping the two in lockstep is deliberate: corewire's facade,
// profile, and mirror projections consume this document, and the
// external-compile lane must see exactly the contract the transpiler
// lane attests.
//
// Identity fields are synthesized deterministically (a frontend sidecar
// attests no real compile): hashes derive from the entry path and the
// emitted surface, so re-runs are byte-identical and a core edit moves
// them.

import { ts, hasExportModifier, exportListBindings, sdkCoreModulePath, type TypedAst } from "./typed_ast.ts";
import { TypeTable, type ZType, type ZField, type UnionArm } from "./types.ts";
import type { IntInference } from "./infer.ts";
import type { CheckResult } from "./checker.ts";
import { wyhashHex } from "./wyhash.ts";
import path from "node:path";

/// A contract fact the schema cannot carry (the extractor's
/// @compileError twin): thrown with the offending node for a teaching
/// diagnostic at the caller.
export class ContractError extends Error {
  readonly node: ts.Node;
  constructor(message: string, node: ts.Node) {
    super(message);
    this.node = node;
  }
}

/// The reflected-type view: what the emitted Zig type WOULD reflect as
/// (aliases erased, numbers classed per slot, storage kind resolved) —
/// the vocabulary the sidecar's TypeRef family spells.
type RType =
  | { readonly k: "bool" | "f64" | "i64" | "bytes" }
  | { readonly k: "optional"; readonly inner: RType }
  | { readonly k: "slice"; readonly elem: RType }
  | { readonly k: "value" | "node" | "enum" | "union"; readonly name: string };

interface TableField {
  readonly name: string;
  readonly rt: RType;
}

interface TableArm {
  readonly tag: string;
  /// The authored member name of a single-payload arm; null otherwise.
  readonly member: string | null;
  /// Null payload = void arm.
  readonly payload: RType | null;
}

type TableEntry =
  | { readonly kind: "struct"; readonly name: string; readonly fields: readonly TableField[] }
  | { readonly kind: "enum"; readonly name: string; readonly members: readonly string[] }
  | { readonly kind: "union"; readonly name: string; readonly arms: readonly TableArm[] };

export interface ContractInput {
  readonly tast: TypedAst;
  readonly table: TypeTable;
  readonly infer: IntInference;
  readonly checkResult: CheckResult;
  readonly files: readonly ts.SourceFile[];
  /// The entry spelling the document states (the extractor takes the
  /// build-root-relative fixture path; app builds state the app-relative
  /// core path). Never a filesystem-absolute leak.
  readonly entry: string;
}

/// A JSON string literal: quoted and escaped exactly as the extractor's
/// `js` helper spells it (JSON.stringify would spell control characters
/// differently — \b instead of ).
function js(text: string): string {
  let out = '"';
  for (const ch of text) {
    const code = ch.codePointAt(0)!;
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else out += ch;
  }
  return out + '"';
}

function boolJson(value: boolean): string {
  return value ? "true" : "false";
}

export function emitContractSidecar(input: ContractInput): string {
  return new ContractEmitter(input).emit();
}

class ContractEmitter {
  private readonly tast: TypedAst;
  private readonly table: TypeTable;
  private readonly infer: IntInference;
  private readonly checkResult: CheckResult;
  private readonly files: readonly ts.SourceFile[];
  private readonly entryFile: ts.SourceFile;
  private readonly entry: string;

  private readonly entries: TableEntry[] = [];
  private readonly listed = new Set<string>();
  private readonly slots: string[] = [];
  /// Origin fragment per table name (`, "origin": ...` [+ privacy]).
  private readonly origins = new Map<string, string>();

  constructor(input: ContractInput) {
    this.tast = input.tast;
    this.table = input.table;
    this.infer = input.infer;
    this.checkResult = input.checkResult;
    this.files = input.files;
    this.entryFile = input.files[0];
    this.entry = input.entry;
    this.collectOrigins();
  }

  // ------------------------------------------------------------ reflection

  /// The reflected type of a slot: numbers class through the inference
  /// result at the slot's own declaration (top level and through one
  /// optional wrapper, exactly the emitter's typeRefWithNumbers rule —
  /// deeper positions stay f64), aliases erase, storage kind resolves.
  private reflect(t: ZType, decl: ts.Node | null, top: boolean): RType {
    switch (t.k) {
      case "number": {
        const cls = top && decl ? (this.infer.classOfDecl(decl) ?? "f64") : "f64";
        return { k: cls };
      }
      case "i64":
        return { k: "i64" };
      case "f64":
        return { k: "f64" };
      case "bool":
        return { k: "bool" };
      case "bytes":
      case "string":
        return { k: "bytes" };
      case "numAlias": {
        if (t.repr === "i64") return { k: "i64" };
        throw new ContractError(
          `the contract schema has no TypeRef form for the u8-repr number alias \`${t.name}\` — use a string-literal union (an enum) or widen the values past 255 so the alias spells i64`,
          this.declOfTableName(t.name) ?? this.entryFile,
        );
      }
      case "enum":
        return { k: "enum", name: t.name };
      case "union":
        return { k: "union", name: t.name };
      case "struct":
        return { k: this.table.isPointerStruct(t.name) ? "node" : "value", name: t.name };
      case "slice":
        return { k: "slice", elem: this.reflect(t.elem, decl, false) };
      case "optional":
        return { k: "optional", inner: this.reflect(t.inner, decl, top) };
      case "void":
        throw new ContractError("a contract slot resolved to no subset type (internal)", this.entryFile);
    }
  }

  private declOfTableName(name: string): ts.Node | null {
    return (
      this.table.structs.get(name)?.decl ??
      this.table.unions.get(name)?.decl ??
      this.table.enums.get(name)?.decl ??
      this.table.numAliases.get(name)?.decl ??
      null
    );
  }

  /// Whether a reflected type spells i64 at its own slot (through
  /// optionals) — the extractor's `spellsI64`.
  private spellsI64(rt: RType): boolean {
    if (rt.k === "i64") return true;
    if (rt.k === "optional") return this.spellsI64(rt.inner);
    return false;
  }

  private typeRefJson(rt: RType): string {
    switch (rt.k) {
      case "bool":
        return '{"kind": "bool"}';
      case "f64":
        return '{"kind": "f64"}';
      case "i64":
        return '{"kind": "i64"}';
      case "bytes":
        return '{"kind": "bytes"}';
      case "optional":
        return `{"kind": "optional", "inner": ${this.typeRefJson(rt.inner)}}`;
      case "slice":
        return `{"kind": "slice", "elem": ${this.typeRefJson(rt.elem)}}`;
      case "node":
        return `{"kind": "node", "name": ${js(rt.name)}}`;
      case "value":
        return `{"kind": "value", "name": ${js(rt.name)}}`;
      case "enum":
        return `{"kind": "enum", "name": ${js(rt.name)}}`;
      case "union":
        return `{"kind": "union", "name": ${js(rt.name)}}`;
    }
  }

  private appendSlot(pathSpelling: string): void {
    this.slots.push(`{"slot": ${js(pathSpelling)}, "class": "i64"}`);
  }

  // --------------------------------------------------------------- origins

  /// The declaring module of every named table type: SDK modules spell
  /// their shipped staging path, core modules their
  /// entry-relative POSIX path; a private declaration carries the
  /// additive `"exported": false` marker; synthesized names stay out.
  private collectOrigins(): void {
    const sdkDir = path.resolve(path.dirname(sdkCoreModulePath));
    const entryDir = path.dirname(path.resolve(this.entryFile.fileName));
    for (const file of this.files) {
      for (const stmt of file.statements) {
        if (!ts.isInterfaceDeclaration(stmt) && !ts.isTypeAliasDeclaration(stmt) && !ts.isClassDeclaration(stmt)) continue;
        if (!stmt.name) continue;
        const name = stmt.name.text;
        if (this.origins.has(name)) continue;
        if (!this.table.structs.has(name) && !this.table.enums.has(name) && !this.table.unions.has(name)) continue;
        if (this.table.genericStructTemplates.has(name) || this.table.genericAliasTemplates.has(name)) continue;
        const fileName = path.resolve(file.fileName);
        const origin =
          path.dirname(fileName) === sdkDir
            ? `sdk/${path.basename(fileName)}`
            : path.relative(entryDir, fileName).split(path.sep).join("/");
        const exported =
          hasExportModifier(stmt) ||
          file.statements.some(
            (candidate) =>
              ts.isExportDeclaration(candidate) &&
              candidate.moduleSpecifier === undefined &&
              candidate.exportClause !== undefined &&
              ts.isNamedExports(candidate.exportClause) &&
              candidate.exportClause.elements.some(
                (spec) => spec.name.text === name && this.tast.exportSpecifierTarget(spec) === stmt,
              ),
          );
        this.origins.set(name, `, "origin": ${js(origin)}${exported ? "" : ', "exported": false'}`);
      }
    }
  }

  private originFragment(name: string): string {
    return this.origins.get(name) ?? "";
  }

  // ------------------------------------------------------------- reach set

  /// Add every table-worthy type reachable from `t`, in first-visit
  /// order (the extractor's ReachSet.collect). `container`/`member`
  /// name synthesized records at their reference site.
  private collect(t: ZType, decl: ts.Node | null, container: string, member: string): void {
    switch (t.k) {
      case "number":
      case "i64":
      case "f64":
      case "bool":
      case "bytes":
      case "string":
      case "numAlias":
      case "void":
        return;
      case "optional":
        return this.collect(t.inner, decl, container, member);
      case "slice":
        return this.collect(t.elem, decl, container, member);
      case "enum": {
        if (this.listed.has(t.name)) return;
        this.listed.add(t.name);
        const info = this.table.enums.get(t.name);
        this.entries.push({ kind: "enum", name: t.name, members: info?.members ?? t.members });
        return;
      }
      case "struct": {
        if (this.listed.has(t.name)) return;
        this.listed.add(t.name);
        const info = this.table.structs.get(t.name);
        if (!info) throw new ContractError(`the type table carries no record named \`${t.name}\` (internal)`, this.entryFile);
        this.entries.push({
          kind: "struct",
          name: t.name,
          fields: info.fields.map((f) => ({ name: f.tsName, rt: this.reflect(f.type, f.decl, true) })),
        });
        for (const f of info.fields) this.collect(f.type, f.decl, t.name, f.tsName);
        return;
      }
      case "union": {
        if (this.listed.has(t.name)) return;
        this.listed.add(t.name);
        const info = this.table.unions.get(t.name);
        if (!info) throw new ContractError(`the type table carries no union named \`${t.name}\` (internal)`, this.entryFile);
        this.entries.push({
          kind: "union",
          name: t.name,
          arms: info.arms.map((arm) => this.tableArm(t.name, arm)),
        });
        for (const arm of info.arms) this.collectArmPayload(t.name, arm);
        return;
      }
    }
  }

  /// One tabled union arm: bare payloads keep their reflected type, a
  /// multi-field payload references its synthesized record.
  private tableArm(unionName: string, arm: UnionArm): TableArm {
    if (arm.fields.length === 0) return { tag: arm.tag, member: null, payload: null };
    if (arm.fields.length === 1) {
      const f = arm.fields[0];
      return { tag: arm.tag, member: f.tsName, payload: this.reflect(f.type, f.decl, true) };
    }
    return { tag: arm.tag, member: null, payload: { k: "value", name: `${unionName}_${arm.tag}` } };
  }

  /// The reach walk through one tabled arm's payload — a synthesized
  /// record entry lands at its first-reference position, exactly where
  /// the extractor's DFS places it.
  private collectArmPayload(unionName: string, arm: UnionArm): void {
    if (arm.fields.length === 0) return;
    if (arm.fields.length === 1) {
      const f = arm.fields[0];
      this.collect(f.type, f.decl, unionName, arm.tag);
      return;
    }
    this.collectSynthesized(`${unionName}_${arm.tag}`, arm.fields);
  }

  /// Table a synthesized (anonymous in the emitted Zig) record under its
  /// deterministic `<Container>_<member>` name, then walk its fields.
  private collectSynthesized(name: string, fields: readonly ZField[]): void {
    if (this.listed.has(name)) return;
    this.listed.add(name);
    this.entries.push({
      kind: "struct",
      name,
      fields: fields.map((f) => ({ name: f.tsName, rt: this.reflect(f.type, f.decl, true) })),
    });
    for (const f of fields) this.collect(f.type, f.decl, name, f.tsName);
  }

  // ------------------------------------------------------- entry-module facts

  /// Whether a declaration is exported by the modifier or an un-renamed
  /// export list entry (the emitter's isExportedDecl twin).
  private isListExported(decl: ts.Node, file: ts.SourceFile): boolean {
    return exportListBindings(this.tast, file).some((b) => !b.renamed && b.target === decl);
  }

  /// The entry module's exported function under `name` — a function
  /// declaration exported directly, or an export-list binding (renamed
  /// included: the emitted alias binds the exported name).
  private entryExportedFunction(name: string): ts.FunctionDeclaration | null {
    for (const stmt of this.entryFile.statements) {
      if (ts.isFunctionDeclaration(stmt) && stmt.name?.text === name && hasExportModifier(stmt)) return stmt;
    }
    for (const b of exportListBindings(this.tast, this.entryFile)) {
      if (b.exportedName === name && b.target && ts.isFunctionDeclaration(b.target)) return b.target;
    }
    for (const stmt of this.entryFile.statements) {
      if (ts.isFunctionDeclaration(stmt) && stmt.name?.text === name && this.isListExported(stmt, this.entryFile)) return stmt;
    }
    return null;
  }

  /// The entry module's exported const under `name` (modifier or export
  /// list), unwrapped past as/satisfies/parens.
  private entryExportedConst(name: string): ts.Expression | null {
    for (const stmt of this.entryFile.statements) {
      if (!ts.isVariableStatement(stmt)) continue;
      for (const decl of stmt.declarationList.declarations) {
        if (!ts.isIdentifier(decl.name) || decl.name.text !== name || !decl.initializer) continue;
        if (!hasExportModifier(stmt) && !this.isListExported(decl, this.entryFile)) continue;
        let init = decl.initializer;
        while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init)) {
          init = init.expression;
        }
        return init;
      }
    }
    for (const b of exportListBindings(this.tast, this.entryFile)) {
      if (b.exportedName !== name || !b.target || !ts.isVariableDeclaration(b.target)) continue;
      if (!b.target.initializer) continue;
      let init = b.target.initializer;
      while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init)) {
        init = init.expression;
      }
      return init;
    }
    return null;
  }

  /// The spec's effectful pair shape on update/initialModel — the
  /// presence fact the sidecar restates as *_returns_cmd.
  private returnsCmdPair(decl: ts.FunctionDeclaration | null): boolean {
    const t = decl?.type;
    if (!t) return false;
    const members = ts.isUnionTypeNode(t) ? t.types : [t];
    const tuples = members.filter((m) => ts.isTupleTypeNode(m));
    if (tuples.length !== 1) return false;
    const tuple = tuples[0] as ts.TupleTypeNode;
    if (tuple.elements.length !== 2) return false;
    const cmdRef = tuple.elements[1];
    return (
      ts.isTypeReferenceNode(cmdRef) &&
      ts.isIdentifier(cmdRef.typeName) &&
      this.checkResult.cmdNames.has(cmdRef.typeName.text)
    );
  }

  /// Whether the declared return ALSO admits the bare model (the mixed
  /// idiom, `Model | [Model, Cmd<Msg>]`) — the additive fact the facade
  /// emitter keys its narrowing wrapper on (*_returns_bare).
  private returnsBareModel(decl: ts.FunctionDeclaration | null): boolean {
    const t = decl?.type;
    if (!t || !ts.isUnionTypeNode(t)) return false;
    return t.types.some((m) => !ts.isTupleTypeNode(m));
  }

  /// The `export const viewUnbound = [...]` opt-out list, split by side
  /// (the emitter's viewUnboundNames twin; shapes are checker-taught, so
  /// unresolvable spellings simply stay off both lists here).
  private viewUnbound(helperNames: readonly string[]): { model: string[]; msg: string[] } {
    const model: string[] = [];
    const msg: string[] = [];
    for (const stmt of this.entryFile.statements) {
      if (!ts.isVariableStatement(stmt)) continue;
      for (const decl of stmt.declarationList.declarations) {
        if (!ts.isIdentifier(decl.name) || decl.name.text !== "viewUnbound" || !decl.initializer) continue;
        let init = decl.initializer;
        while (ts.isParenthesizedExpression(init) || ts.isAsExpression(init) || ts.isSatisfiesExpression(init)) {
          init = init.expression;
        }
        if (!ts.isArrayLiteralExpression(init)) continue;
        const modelFields = this.table.structs.get("Model")?.fields ?? [];
        const msgArms = this.table.unions.get("Msg")?.arms ?? [];
        for (const el of init.elements) {
          if (!ts.isStringLiteral(el)) continue;
          const entry = el.text;
          if (modelFields.some((f) => f.tsName === entry) || helperNames.includes(entry)) model.push(entry);
          else if (msgArms.some((a) => a.tag === entry)) msg.push(entry);
        }
      }
    }
    // `statusItem` is consumed by the generated launcher, not markup. It
    // is still an ordinary Model helper in the core ABI, so teach native
    // check that this one helper is intentionally shell-bound without
    // making every app repeat it in `viewUnbound`.
    if (helperNames.includes("statusItem") && !model.includes("statusItem")) model.push("statusItem");
    if (helperNames.includes("statusItems") && !model.includes("statusItems")) model.push("statusItems");
    return { model, msg };
  }

  /// `export const envMsgs = [{ env, msg }] as const` — the entries, in
  /// declaration order (shape teaching is the checker/emitter's NS1033).
  private envMsgEntries(): { env: string; msg: string }[] {
    const init = this.entryExportedConst("envMsgs");
    if (!init || !ts.isArrayLiteralExpression(init)) return [];
    const entries: { env: string; msg: string }[] = [];
    for (const el of init.elements) {
      let e: ts.Expression = el;
      while (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isSatisfiesExpression(e)) e = e.expression;
      if (!ts.isObjectLiteralExpression(e)) continue;
      let env: string | null = null;
      let msg: string | null = null;
      for (const p of e.properties) {
        if (!ts.isPropertyAssignment(p) || !ts.isIdentifier(p.name) || !ts.isStringLiteral(p.initializer)) continue;
        if (p.name.text === "env") env = p.initializer.text;
        else if (p.name.text === "msg") msg = p.initializer.text;
      }
      if (env !== null && msg !== null) entries.push({ env, msg });
    }
    return entries;
  }

  /// An exported string-literal channel const (`appearanceMsg`,
  /// `chromeMsg`), as its JSON value fragment; "null" when absent.
  private channelConstJson(name: string): string {
    const init = this.entryExportedConst(name);
    if (init && ts.isStringLiteral(init)) return js(init.text);
    return "null";
  }

  // ---------------------------------------------------------------- emission

  emit(): string {
    const modelName = "Model";
    const msgName = "Msg";
    const model = this.table.structs.get(modelName);
    const msg = this.table.unions.get(msgName);
    if (!model || !msg) {
      throw new ContractError("a core exports `Model` (a record) and `Msg` (a discriminated union)", this.entryFile);
    }

    const helperDecls = this.table.modelHelperDecls();

    // Phase 1: the reach set — Model, then every non-void Msg arm
    // payload the number_bytes family does not absorb, then helper
    // returns (first-visit order; the extractor's root order).
    this.collect({ k: "struct", name: modelName }, null, "", "");
    // collect(Model) recursively closes over every type reachable from the
    // model. Remember that prefix before Msg/helper-only types join the table;
    // persistence fingerprints exactly this prefix, so a Msg-only edit does
    // not spuriously require a snapshot schema bump.
    const modelEntryCount = this.entries.length;
    for (const arm of msg.arms) {
      if (arm.fields.length === 0) continue;
      if (this.isNumberBytesShape(arm)) continue;
      this.collectArmPayloadForMsg(msgName, arm);
    }
    const helperReturns = helperDecls.map((h) => {
      const ret = this.table.resolveTypeNode(h.decl.type!);
      this.collect(ret, h.decl, "helpers", h.name);
      return { name: h.name, decl: h.decl, ret };
    });

    // Phase 2: sections.
    let structs = "";
    let enums = "";
    let unions = "";
    let structCount = 0;
    let enumCount = 0;
    let unionCount = 0;
    const modelShapeParts: string[] = [];
    for (const [entryIndex, entry] of this.entries.entries()) {
      if (entry.kind === "struct") {
        let fields = "";
        entry.fields.forEach((f, index) => {
          if (index > 0) fields += ", ";
          fields += `{"name": ${js(f.name)}, "type": ${this.typeRefJson(f.rt)}}`;
          if (this.spellsI64(f.rt)) this.appendSlot(`${entry.name}.${f.name}`);
        });
        if (structCount > 0) structs += ",\n      ";
        structs += `{"name": ${js(entry.name)}${this.originFragment(entry.name)}, "fields": [${fields}]}`;
        if (entryIndex < modelEntryCount) modelShapeParts.push(`struct:${entry.name}:${fields}`);
        structCount += 1;
      } else if (entry.kind === "enum") {
        const members = entry.members.map((m) => js(m)).join(", ");
        if (enumCount > 0) enums += ",\n      ";
        enums += `{"name": ${js(entry.name)}${this.originFragment(entry.name)}, "members": [${members}]}`;
        if (entryIndex < modelEntryCount) modelShapeParts.push(`enum:${entry.name}:${members}`);
        enumCount += 1;
      } else {
        let arms = "";
        entry.arms.forEach((arm, index) => {
          if (index > 0) arms += ", ";
          const memberFragment = arm.member !== null ? `, "member": ${js(arm.member)}` : "";
          const payload = arm.payload === null ? '{"kind": "void"}' : this.typeRefJson(arm.payload);
          arms += `{"name": ${js(arm.tag)}${memberFragment}, "payload": ${payload}}`;
          if (arm.payload !== null && this.spellsI64(arm.payload)) this.appendSlot(`${entry.name}.${arm.tag}`);
        });
        if (unionCount > 0) unions += ",\n      ";
        unions += `{"name": ${js(entry.name)}${this.originFragment(entry.name)}, "arms": [${arms}]}`;
        if (entryIndex < modelEntryCount) modelShapeParts.push(`union:${entry.name}:${arms}`);
        unionCount += 1;
      }
    }

    // Message arms with payload descriptors.
    let msgArms = "";
    msg.arms.forEach((arm, index) => {
      if (index > 0) msgArms += ",\n      ";
      const memberFragment = arm.fields.length === 1 ? `, "member": ${js(arm.fields[0].tsName)}` : "";
      msgArms += `{"name": ${js(arm.tag)}${memberFragment}, "payload": ${this.payloadDescriptor(msgName, arm)}}`;
    });

    // Helpers, in export (= Model forwarding declaration) order.
    let helpers = "";
    let helperCount = 0;
    for (const h of helperReturns) {
      if (helperCount > 0) helpers += ",\n    ";
      const reflected = this.reflect(h.ret, h.decl, true);
      if (this.spellsI64(reflected)) this.appendSlot(`helpers.${h.name}.return`);
      helpers += `{"name": ${js(h.name)}, "params": [], "returns": ${this.typeRefJson(reflected)}, "arena": false}`;
      helperCount += 1;
    }

    const unbound = this.viewUnbound(helperDecls.map((h) => h.name));
    const modelUnbound = unbound.model.map((n) => js(n)).join(", ");
    const msgUnbound = unbound.msg.map((n) => js(n)).join(", ");

    // Channels: export presence IS the wiring decision.
    const hasCommand = this.entryExportedFunction("commandMsg") !== null;
    const hasFrame = this.entryExportedFunction("frameMsg") !== null;
    const hasKey = this.entryExportedFunction("keyMsg") !== null;
    const hasPinch = this.entryExportedFunction("pinchMsg") !== null;
    const hasDrop = this.entryExportedFunction("dropMsg") !== null;
    const envMsgs = this.envMsgEntries()
      .map((e) => `{"env": ${js(e.env)}, "msg": ${js(e.msg)}}`)
      .join(", ");
    const appearance = this.channelConstJson("appearanceMsg");
    const chrome = this.channelConstJson("chromeMsg");

    // Entry-shape flags, from the declared return annotations — the
    // same pair-shape discrimination the emitter applies.
    const initReturnsCmd = this.returnsCmdPair(this.entryExportedFunction("initialModel"));
    const updateReturnsCmd = this.returnsCmdPair(this.entryExportedFunction("update"));
    // The mixed-idiom facts ride only when true (additive fields; a
    // compiler's co-emitted sidecar never carries them).
    const initReturnsBare = initReturnsCmd && this.returnsBareModel(this.entryExportedFunction("initialModel"));
    const updateReturnsBare = updateReturnsCmd && this.returnsBareModel(this.entryExportedFunction("update"));
    const hasSubscriptions = this.entryExportedFunction("subscriptions") !== null;
    const hasMigrate = this.entryExportedFunction("migrate") !== null;

    let abiExports =
      '"abi_version", "build_id", "set_panic_sink", "init", "collect", ' +
      '"frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", ' +
      '"dispatch_number", "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", ' +
      '"dispatch_record", "dispatch_text_input", "dispatch_scroll_state", ' +
      '"subscriptions", "model_snapshot", "persist_snapshot", "restore_model", "migrate_model", "helper_call"';
    if (hasCommand) abiExports += ', "command_msg"';
    if (hasFrame) abiExports += ', "frame_msg"';
    if (hasKey) abiExports += ', "key_msg"';
    if (hasPinch) abiExports += ', "pinch_msg"';
    if (hasDrop) abiExports += ', "drop_msg"';

    const typesJson =
      `{\n    "structs": [\n      ${structs}\n    ],\n` +
      `    "enums": [\n      ${enums}\n    ],\n` +
      `    "unions": [\n      ${unions}\n    ]\n  }`;

    const slots = this.slots.join(",\n    ");
    const slotCount = this.slots.length;

    // Deterministic synthesized identity, the extractor's construction
    // verbatim: every section behind a label and a NUL separator, so
    // the serialization is injective and re-runs reproduce it exactly.
    const surface =
      `entry=${this.entry}` +
      `\x00model=${modelName}` +
      `\x00msg=${msgName}` +
      `\x00types=${typesJson}` +
      `\x00arms=${msgArms}` +
      `\x00helpers=${helpers}` +
      `\x00model_unbound=${modelUnbound}` +
      `\x00msg_unbound=${msgUnbound}` +
      `\x00env=${envMsgs}` +
      `\x00appearance=${appearance}` +
      `\x00chrome=${chrome}` +
      `\x00exports=${abiExports}` +
      `\x00flags=${boolJson(initReturnsCmd)}${boolJson(updateReturnsCmd)}` +
      `${boolJson(hasSubscriptions)}${boolJson(hasCommand)}${boolJson(hasFrame)}` +
      `${boolJson(hasKey)}${boolJson(hasPinch)}${boolJson(hasDrop)}${boolJson(hasMigrate)}`;
    const surfaceBytes = new TextEncoder().encode(surface);
    const sourceHash = wyhashHex(0x5eedc0den, surfaceBytes);
    const buildId = wyhashHex(0xb11d1d00n, surfaceBytes);
    const modelFingerprint = wyhashHex(
      0x5a9e5eedn,
      new TextEncoder().encode(`model=${modelName}\x00${modelShapeParts.join("\x00")}`),
    );

    return (
      "{\n" +
      '  "format": 1,\n' +
      '  "wire_version": 6,\n' +
      '  "abi_version": 2,\n' +
      '  "compiler_version": "0.0.1",\n' +
      `  "entry": ${js(this.entry)},\n` +
      `  "source_hash": "${sourceHash}",\n` +
      `  "build_id": "${buildId}",\n` +
      `  "model_fingerprint": "${modelFingerprint}",\n` +
      `  "types": ${typesJson},\n` +
      `  "model": ${js(modelName)},\n` +
      `  "model_helpers": [${helperCount > 0 ? `\n    ${helpers}\n  ` : ""}],\n` +
      `  "model_unbound": [${modelUnbound}],\n` +
      `  "msg": {\n    "name": ${js(msgName)},\n    "arms": [\n      ${msgArms}\n    ],\n    "unbound": [${msgUnbound}]\n  },\n` +
      `  "init_returns_cmd": ${boolJson(initReturnsCmd)},\n` +
      `  "update_returns_cmd": ${boolJson(updateReturnsCmd)},\n` +
      (initReturnsBare ? '  "init_returns_bare": true,\n' : "") +
      (updateReturnsBare ? '  "update_returns_bare": true,\n' : "") +
      `  "has_subscriptions": ${boolJson(hasSubscriptions)},\n` +
      `  "has_migrate": ${boolJson(hasMigrate)},\n` +
      '  "channels": {\n' +
      `    "command_msg": ${boolJson(hasCommand)},\n` +
      `    "frame_msg": ${boolJson(hasFrame)},\n` +
      `    "key_msg": ${boolJson(hasKey)},\n` +
      `    "pinch_msg": ${boolJson(hasPinch)},\n` +
      `    "drop_msg": ${boolJson(hasDrop)},\n` +
      `    "appearance_msg": ${appearance},\n` +
      `    "chrome_msg": ${chrome},\n` +
      `    "env_msgs": [${envMsgs}]\n` +
      "  },\n" +
      `  "abi": {\n    "prefix": "nsc_core_",\n    "exports": [${abiExports}],\n    "snapshot_format": 1\n  },\n` +
      `  "integer_slots": [${slotCount > 0 ? `\n    ${slots}\n  ` : ""}],\n` +
      '  "deterministic": true,\n' +
      '  "async_free": true\n' +
      "}\n"
    );
  }

  /// The anonymous two-field number-plus-bytes shape, in declaration
  /// order (number first) — the family that never needs a table entry.
  private isNumberBytesShape(arm: UnionArm): boolean {
    if (arm.fields.length !== 2) return false;
    const first = this.reflect(arm.fields[0].type, arm.fields[0].decl, true);
    const second = this.reflect(arm.fields[1].type, arm.fields[1].decl, true);
    return (first.k === "f64" || first.k === "i64") && second.k === "bytes";
  }

  /// The reach walk through one MESSAGE arm's payload (the tabled-union
  /// twin, with the Msg-specific number_bytes exemption already applied
  /// by the caller).
  private collectArmPayloadForMsg(msgName: string, arm: UnionArm): void {
    if (arm.fields.length === 1) {
      const f = arm.fields[0];
      this.collect(f.type, f.decl, msgName, arm.tag);
      return;
    }
    this.collectSynthesized(`${msgName}_${arm.tag}`, arm.fields);
  }

  /// The payload descriptor of one Msg arm, collecting integer slots
  /// for the number-carrying families (the extractor's construction).
  private payloadDescriptor(msgName: string, arm: UnionArm): string {
    if (arm.fields.length === 0) return '{"kind": "void"}';
    if (arm.fields.length === 1) {
      const f = arm.fields[0];
      const rt = this.reflect(f.type, f.decl, true);
      switch (rt.k) {
        case "bytes":
          return '{"kind": "bytes"}';
        case "f64":
          return '{"kind": "number", "class": "f64"}';
        case "i64":
          this.appendSlot(`${msgName}.${arm.tag}`);
          return '{"kind": "number", "class": "i64"}';
        case "bool":
          return '{"kind": "scalar", "type": {"kind": "bool"}}';
        case "enum":
          return `{"kind": "enum", "name": ${js(rt.name)}}`;
        case "union":
          return `{"kind": "union", "name": ${js(rt.name)}}`;
        case "value":
          return `{"kind": "record", "name": ${js(rt.name)}}`;
        case "node":
          throw new ContractError(
            `Msg arm \`${arm.tag}\` carries the by-reference record \`${rt.name}\`, which has no schema form in sidecar format 1 — store the record by value (declare it as an object-literal type alias) or carry its fields inline`,
            f.decl,
          );
        case "optional":
        case "slice":
          throw new ContractError(
            `Msg arm \`${arm.tag}\` carries a payload with no sidecar descriptor form (optional and array payloads have none in format 1) — wrap the payload in a named record`,
            f.decl,
          );
      }
    }
    if (this.isNumberBytesShape(arm)) {
      const numberField = arm.fields[0];
      const cls = this.reflect(numberField.type, numberField.decl, true).k === "i64" ? "i64" : "f64";
      if (cls === "i64") this.appendSlot(`${msgName}.${arm.tag}.${numberField.tsName}`);
      return (
        `{"kind": "number_bytes", "number_field": ${js(numberField.tsName)}` +
        `, "number_class": "${cls}", "bytes_field": ${js(arm.fields[1].tsName)}}`
      );
    }
    return `{"kind": "record", "name": ${js(`${msgName}_${arm.tag}`)}}`;
  }
}

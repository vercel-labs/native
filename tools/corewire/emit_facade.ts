// The TypeScript entry projection of the compiled core's complete contract.
import type { TypeRef, Payload, RecordType, MsgArm } from "./core_contract.ts";
import { findRecord, findEnum, findUnion } from "./core_contract.ts";
import { projectionPlan, validateFacade } from "./core_projection.ts";
import type { ProjectionPlan } from "./core_projection.ts";
import { CodeWriter, commentText, tsString, tsProp, tsAccess, synthesized, scrollIndexes, scrollFields, isTextInputUnion } from "./core_emission.ts";
import type { EmissionInput, EmissionContract, EmissionResult } from "./core_emission.ts";
import * as text from "./facade_templates.ts";

const maxSafe = "9007199254740991";
function lowerBound(className: string | null): string { return className === "u64" ? "0" : "-9007199254740991"; }
function payloadNumberClass(p: Payload): string | null {
  if (p.kind === "number") return p.class!;
  if (p.kind === "scalar" && (p.type!.kind === "f64" || p.type!.kind === "i64")) return p.type!.kind;
  return null;
}
export function emitFacade(input: EmissionInput): EmissionResult {
  const plan = projectionPlan(input.sidecar), diagnostics = validateFacade(input.sidecar, plan);
  if (diagnostics.length > 0) return { output: "", diagnostics };
  const model = findRecord(input.sidecar, input.sidecar.model)!;
  for (const name of input.sidecar.msg.unbound) {
    if (model.fields.some(field => field.name === name) || input.sidecar.model_helpers.some(helper => helper.name === name)) {
      diagnostics.push({ path: "msg.unbound", message: `"${name}" is an unbound message arm shadowed by a homonymous Model field or exported helper — the compiler resolves Model fields and helpers before message arms, so the projection's single unbound list cannot mark this arm; rename one side in the core source` });
    }
  }
  if (diagnostics.length > 0) return { output: "", diagnostics };
  const emitter = new FacadeEmitter(input, plan); emitter.run();
  return { output: emitter.out, diagnostics };
}
class FacadeEmitter extends CodeWriter {
  input: EmissionInput; s: EmissionContract; plan: ProjectionPlan;
  usedCodec: string[] = []; referenced: string[] = [];
  needsPinchPhase: boolean = false; needsMemberTrap: boolean = false; tempCounter: number = 0;
  neededEnumTables: string[] = []; neededEnumIndexes: string[] = [];
  neededRecordWriters: string[] = []; neededUnionWriters: string[] = []; neededUnionDecoders: string[] = [];
  constructor(input: EmissionInput, plan: ProjectionPlan) { super(); this.input = input; this.s = input.sidecar; this.plan = plan; }
  use(id: string): void {
    if (this.usedCodec.includes(id)) return;
    this.usedCodec.push(id);
    let deps: string[] = [];
    if (["read_i64", "read_i64_saturating", "read_u64_saturating"].includes(id)) deps = ["read_u32"];
    else if (["read_u8", "read_u32", "read_f64", "read_bool", "read_bytes_body", "assert_consumed"].includes(id)) deps = ["trap"];
    else if (["w_u32", "w_u8", "w_f64", "w_bool"].includes(id)) deps = ["sink"];
    else if (["w_i64", "w_u64"].includes(id)) deps = ["w_u32", "trunc_toward_zero", "trap"];
    else if (id === "w_bytes") deps = ["w_u32"];
    else if (id === "short_text") deps = ["sink", "trap"];
    else if (id === "enum_index") deps = ["trap"];
    else if (id === "cmd_encoder") deps = ["w_u8", "w_f64", "w_bytes", "short_text", "utf8_text", "enum_index", "trap"];
    else if (id === "sub_encoder") deps = ["w_u8", "w_u32", "w_f64", "w_bytes", "short_text", "utf8_text", "trap"];
    for (const dep of deps) this.use(dep);
  }
  reference(name: string): void {
    if (!this.isGeneratedOnlyType(name) && this.isExportedType(name) && !this.referenced.includes(name)) this.referenced.push(name);
  }
  memberOf(member: string | null): string { return member ?? "value"; }
  originOf(name: string): string {
    for (const r of this.s.types.structs) if (r.name === name) return r.origin ?? this.entryBasename();
    for (const e of this.s.types.enums) if (e.name === name) return e.origin ?? this.entryBasename();
    for (const u of this.s.types.unions) if (u.name === name) return u.origin ?? this.entryBasename();
    return this.entryBasename();
  }
  entryBasename(): string {
    const entry = this.s.entry.replace(/\/+$/, "");
    return entry.slice(entry.lastIndexOf("/") + 1);
  }
  isGeneratedOnlyType(name: string): boolean {
    if (name === this.s.model || name === this.s.msg.name) return false;
    for (const r of this.s.types.structs) if (r.name === name) return r.origin === null;
    for (const e of this.s.types.enums) if (e.name === name) return e.origin === null;
    for (const u of this.s.types.unions) if (u.name === name) return u.origin === null;
    return false;
  }
  isExportedType(name: string): boolean {
    if (name === this.s.model || name === this.s.msg.name) return true;
    for (const r of this.s.types.structs) if (r.name === name) return r.exported;
    for (const e of this.s.types.enums) if (e.name === name) return e.exported;
    for (const u of this.s.types.unions) if (u.name === name) return u.exported;
    return true;
  }
  slotClassAt(path: string): string | null {
    for (const entry of this.s.integer_slots) if (entry.slot === path) return entry.class;
    return null;
  }
  slotClass(container: string, member: string): string | null { return this.slotClassAt(container + "." + member); }
  nestedSlotClass(container: string, member: string, field: string): string | null { return this.slotClassAt(container + "." + member + "." + field); }
  intWriter(container: string, member: string): string {
    if (this.slotClass(container, member) === "u64") { this.use("w_u64"); return "nscfWU64"; }
    this.use("w_i64"); return "nscfWI64";
  }
  run(): void {
    const body = new FacadeEmitter(this.input, this.plan);
    body.privateTypeDeclarations(); body.channelConsts(); body.unboundDecl(); body.helperWrappers(); body.entryPoints();
    body.tagTable(); body.dispatchSurface(); body.channelEntries(); body.postCycle(); body.helperCall();
    body.generatedTables(); body.codecSection(); body.bootState();
    this.header(); this.imports(body); this.reexports(); this.raw(body.out);
  }
  header(): void { this.print(text.header, [commentText(this.s.entry), commentText(this.s.compiler_version), this.input.build_id_hex]); }
  importPath(origin: string): string { return '"./' + tsString(origin) + '"'; }
  groups(names: string[]): { origin: string; names: string[] }[] {
    const groups: { origin: string; names: string[] }[] = [];
    for (const name of names) {
      const origin = this.originOf(name);
      let group = groups.find(g => g.origin === origin);
      if (group === undefined) { group = { origin, names: [] }; groups.push(group); }
      group.names.push(name);
    }
    return groups;
  }
  imports(body: FacadeEmitter): void {
    const values = ["initialModel as nscfInitialModel", "update as nscfUpdate"];
    if (this.s.has_migrate) values.push("migrate as nscfMigrate");
    if (this.s.has_subscriptions) values.push("subscriptions as nscfSubscriptions");
    const c = this.s.channels;
    if (c.command_msg) values.push("commandMsg as nscfChanCommandMsg");
    if (c.frame_msg) values.push("frameMsg as nscfChanFrameMsg");
    if (c.key_msg) values.push("keyMsg as nscfChanKeyMsg");
    if (c.pinch_msg) values.push("pinchMsg as nscfChanPinchMsg");
    if (c.drop_msg) values.push("dropMsg as nscfChanDropMsg");
    for (const h of this.s.model_helpers) values.push(h.name + " as nscfH_" + h.name);
    this.raw("\nimport {\n"); for (const value of values) this.print("  {s},\n", [value]);
    this.print("}} from {s};\n", [this.importPath(this.entryBasename())]);
    const ordered = [this.s.model, this.s.msg.name];
    for (const name of body.referenced) if (!ordered.includes(name)) ordered.push(name);
    for (const group of this.groups(ordered)) this.print("import type {{ {s} }} from {s};\n", [group.names.join(", "), this.importPath(group.origin)]);
    const cmd = body.usedCodec.includes("cmd_encoder"), sub = body.usedCodec.includes("sub_encoder");
    if (cmd && sub) this.raw('import type { Cmd as nscfCmd, Sub as nscfSub, DbText as nscfDbText } from "./sdk/core.ts";\n');
    else if (cmd) this.raw('import type { Cmd as nscfCmd, DbText as nscfDbText } from "./sdk/core.ts";\n');
    else if (sub) this.raw('import type { Sub as nscfSub, DbText as nscfDbText } from "./sdk/core.ts";\n');
    if (body.needsPinchPhase) this.raw('import type { PinchPhase } from "./sdk/events.ts";\n');
    if (c.drop_msg) this.raw('import type { FileDropPoint } from "./sdk/events.ts";\n');
    this.needsPinchPhase = body.needsPinchPhase;
  }
  reexports(): void {
    const ordered = [this.s.model, this.s.msg.name];
    for (const r of this.s.types.structs) if (!this.plan.inlined.includes(r.name) && !this.isGeneratedOnlyType(r.name) && r.exported && !ordered.includes(r.name)) ordered.push(r.name);
    for (const e of this.s.types.enums) if (!this.isGeneratedOnlyType(e.name) && e.exported && !ordered.includes(e.name)) ordered.push(e.name);
    for (const u of this.s.types.unions) if (!this.isGeneratedOnlyType(u.name) && u.exported && !ordered.includes(u.name)) ordered.push(u.name);
    this.raw(text.reexportPrelude);
    for (const g of this.groups(ordered)) this.print("export type {{ {s} }} from {s};\n", [g.names.join(", "), this.importPath(g.origin)]);
  }
  privateTypeDeclarations(): void {
    if (![...this.s.types.structs, ...this.s.types.enums, ...this.s.types.unions].some(e => !e.exported)) return;
    this.raw(text.privateTypes);
    for (const r of this.s.types.structs) {
      if (r.exported) continue; this.print("type {s} = {{\n", [r.name]);
      for (const f of r.fields) this.print("  readonly {s}: {s};\n", [tsProp(f.name), this.spellRef(f.type)]);
      this.raw("};\n\n");
    }
    for (const e of this.s.types.enums) {
      if (e.exported) continue; this.print("type {s} = ", [e.name]);
      for (let i = 0; i < e.members.length; i++) this.print('{s}"{s}"', [i === 0 ? "" : " | ", tsString(e.members[i])]);
      this.raw(";\n\n");
    }
    for (const u of this.s.types.unions) {
      if (u.exported) continue; this.print("type {s} =\n", [u.name]);
      for (const a of u.arms) {
        this.print('  | {{ readonly kind: "{s}"', [tsString(a.name)]);
        if (a.payload.kind !== "void") {
          const r = this.synthesizedRecordOf(a.payload, u.name, a.name);
          if (r !== null) for (const f of r.fields) this.print("; readonly {s}: {s}", [tsProp(f.name), this.spellRef(f.type)]);
          else this.print("; readonly {s}: {s}", [tsProp(this.memberOf(a.member)), this.spellRef(a.payload)]);
        }
        this.raw(" }\n");
      }
      this.raw(";\n\n");
    }
  }
  channelConsts(): void {
    const c = this.s.channels;
    if (c.appearance_msg === null && c.chrome_msg === null && c.env_msgs.length === 0) return;
    this.raw(text.channels);
    if (c.appearance_msg !== null) this.print('\nexport const appearanceMsg = "{s}";\n', [tsString(c.appearance_msg)]);
    if (c.chrome_msg !== null) this.print('\nexport const chromeMsg = "{s}";\n', [tsString(c.chrome_msg)]);
    if (c.env_msgs.length > 0) {
      this.raw("\nexport const envMsgs = [\n");
      for (const e of c.env_msgs) this.print('  {{ env: "{s}", msg: "{s}" }},\n', [tsString(e.env), tsString(e.msg)]);
      this.raw("];\n");
    }
  }
  unboundDecl(): void {
    const model = findRecord(this.s, this.s.model)!;
    const fields = this.s.model_unbound.filter(n => model.fields.some(f => f.name === n));
    const helpers = this.s.model_unbound.filter(n => this.s.model_helpers.some(h => h.name === n));
    if (fields.length === 0 && helpers.length === 0 && this.s.msg.unbound.length === 0) return;
    this.raw(text.unbound);
    for (const n of [...this.s.msg.unbound, ...fields, ...helpers]) this.print('  "{s}",\n', [tsString(n)]);
    this.raw("];\n");
  }
  helperWrappers(): void {
    if (this.s.model_helpers.length === 0) return;
    this.raw(text.helperPrelude);
    for (const h of this.s.model_helpers) {
      const returns = this.spellRef(h.returns), optionalInt = h.returns.kind === "optional" && h.returns.inner!.kind === "i64";
      if (h.params.length > 0) {
        const params = h.params.map((p, index) => `p${index}: ${this.spellRef(p)}`);
        const args = h.params.map((_p, index) => `p${index}`);
        this.print("\nexport function {s}(model: {s}, {s}): {s} {{\n", [h.name, this.s.model, params.join(", "), returns]);
        this.print("  const nscfValue = nscfH_{s}(model, {s});\n", [h.name, args.join(", ")]);
        if (h.returns.kind === "i64" || optionalInt) {
          if (optionalInt) this.raw("  if (nscfValue === null) return null;\n");
          this.print("  if (nscfValue >= {s} && nscfValue <= {s}) return Math.trunc(nscfValue);\n", [lowerBound(this.nestedSlotClass("helpers", h.name, "return")), maxSafe]);
          this.raw('  nscfTrap("a helper return is outside its attested integer range");\n');
          this.use("trap");
        } else this.print("  return nscfValue as {s};\n", [returns]);
        this.raw("}\n");
      } else if (h.returns.kind === "i64" || optionalInt) {
        const lower = lowerBound(this.nestedSlotClass("helpers", h.name, "return"));
        this.print(optionalInt ? text.helperOptionalInteger : text.helperInteger, optionalInt
          ? [h.name, this.s.model, returns, h.name, lower, maxSafe] : [h.name, this.s.model, h.name, lower, maxSafe]);
        this.use("trap");
      } else if (h.returns.kind === "slice") this.print(text.helperSequence, [h.name, this.s.model, returns, h.name, returns]);
      else this.print(text.helperValue, [h.name, this.s.model, returns, h.name]);
    }
  }
  entryPoints(): void {
    this.raw(text.entries);
    if (this.s.init_returns_cmd) this.use("cmd_encoder");
    this.print(this.s.init_returns_cmd ? (this.s.init_returns_bare ? text.initMixed : text.initCommand) : text.initModel, [this.s.model]);
  }
  tagTable(): void {
    this.raw(text.messageTags); for (const a of this.s.msg.arms) this.print('  "{s}",\n', [tsString(a.name)]); this.raw("];\n\n");
    for (let i = 0; i < this.s.msg.arms.length; i++) this.print("const nscfTag_{s} = {d};\n", [this.s.msg.arms[i].name, String(i)]);
    this.use("trap"); this.raw(text.unknownTag);
    if (this.s.update_returns_cmd) this.use("cmd_encoder");
    this.print(this.s.update_returns_cmd ? (this.s.update_returns_bare ? text.updateMixed : text.updateCommand) : text.updateModel, [this.s.model, this.s.msg.name, this.s.model]);
    if (this.s.has_subscriptions) { this.use("sub_encoder"); this.print(text.subscriptions, [this.s.model]); }
  }
  dispatchSurface(): void {
    this.use("trap"); this.raw(text.dispatchPrelude);
    this.print(this.s.update_returns_cmd ? text.commitCommand : text.commitModel, [this.s.model]);
    this.raw(text.bootstrap); this.raw(this.s.init_returns_cmd ? text.bootCommand : text.bootEmpty);
    this.dispatchVoid(); this.dispatchBytes(); this.dispatchNumber(); this.dispatchNumberBytes(); this.dispatchBool();
    this.dispatchEnum(); this.dispatchRecord(); this.dispatchTextInput(); this.dispatchScrollState();
  }
  bootState(): void {
    this.raw("\n// Boot after the command encoder's lookup tables are initialized.\n");
    if (this.s.init_returns_cmd) this.print("const nscfBootPair = init();\nlet nscfCommitted: {s} = nscfBootPair[0];\n", [this.s.model]);
    else this.print("let nscfCommitted: {s} = nscfInitialModel();\n", [this.s.model]);
  }
  commitLine(object: string): string { return "return nscfCommit(coreUpdate(nscfCommitted, " + object + "));"; }
  armObject(arm: MsgArm, value: string): string {
    return '{ kind: "' + tsString(arm.name) + '", ' + tsProp(this.memberOf(arm.member)) + ": " + value + " }";
  }
  dispatchVoid(): void {
    this.raw("\nexport function dispatch_void(tag: number): Uint8Array {\n");
    for (const a of this.s.msg.arms) if (a.payload.kind === "void")
      this.print("  if (tag === nscfTag_{s}) {s}\n", [a.name, this.commitLine('{ kind: "' + tsString(a.name) + '" }')]);
    this.raw('  nscfUnknownTag("bare", tag);\n}\n');
  }
  dispatchBytes(): void {
    this.raw("\nexport function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {\n");
    for (const a of this.s.msg.arms) if (a.payload.kind === "bytes" || (a.payload.kind === "scalar" && a.payload.type!.kind === "bytes"))
      this.print("  if (tag === nscfTag_{s}) {s}\n", [a.name, this.commitLine(this.armObject(a, "payload"))]);
    this.raw('  nscfUnknownTag("bytes", tag);\n}\n');
  }
  dispatchNumber(): void {
    this.raw("\nexport function dispatch_number(tag: number, value: number): Uint8Array {\n");
    if (this.s.msg.arms.some(a => payloadNumberClass(a.payload) === "f64")) {
      this.raw("  // These arms remain f64-classed in the contract: preserve the value\n  // exactly instead of routing it through the integer proof below.\n");
      for (const a of this.s.msg.arms) if (payloadNumberClass(a.payload) === "f64")
        this.print("  if (tag === nscfTag_{s}) {s}\n", [a.name, this.commitLine(this.armObject(a, "value"))]);
    }
    for (const a of this.s.msg.arms) if (payloadNumberClass(a.payload) === "i64")
      this.print(text.dispatchInteger, [a.name, lowerBound(this.slotClass(this.s.msg.name, a.name)), maxSafe, this.armObject(a, "whole")]);
    this.raw('  nscfUnknownTag("number", tag);\n}\n');
  }
  dispatchNumberBytes(): void {
    this.raw("\nexport function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {\n");
    for (const a of this.s.msg.arms) {
      const p = a.payload; if (p.kind !== "number_bytes") continue;
      const kind = tsString(a.name), number = tsProp(p.number_field!), bytes = tsProp(p.bytes_field!);
      if (p.number_class === "i64") this.print(text.dispatchNumberBytesInteger, [a.name, lowerBound(this.nestedSlotClass(this.s.msg.name, a.name, p.number_field!)), maxSafe, kind, number, bytes]);
      else this.print('  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: "{s}", {s}: value, {s}: payload }}));\n', [a.name, kind, number, bytes]);
    }
    this.raw('  nscfUnknownTag("number-with-bytes", tag);\n}\n');
  }
  dispatchBool(): void {
    this.raw("\nexport function dispatch_bool(tag: number, value: number): Uint8Array {\n");
    for (const a of this.s.msg.arms) if (a.payload.kind === "scalar" && a.payload.type!.kind === "bool")
      this.print("  if (tag === nscfTag_{s}) {s}\n", [a.name, this.commitLine(this.armObject(a, "value !== 0"))]);
    this.raw('  nscfUnknownTag("boolean", tag);\n}\n');
  }
  dispatchEnum(): void {
    this.raw("\nexport function dispatch_enum(tag: number, member: number): Uint8Array {\n");
    for (const a of this.s.msg.arms) if (a.payload.kind === "enum_ref") {
      const name = a.payload.name!; this.needEnumTable(name);
      this.print(text.dispatchEnumGuard, [a.name, name, tsString(name), this.commitLine(this.armObject(a, "nscfMembers" + name + "[member]!"))]);
      this.needsMemberTrap = true;
    }
    this.raw('  nscfUnknownTag("enum", tag);\n}\n');
  }
  dispatchRecord(): void {
    this.raw("\nexport function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {\n");
    for (const a of this.s.msg.arms) {
      const p = a.payload;
      if (p.kind === "record") {
        const r = findRecord(this.s, p.name!); if (r === null) continue;
        this.print("  if (tag === nscfTag_{s}) {{\n", [a.name]);
        this.recordDecodeCommit(r, a.name, this.synthesizedRecordOf({ kind: "value", name: p.name! }, this.s.msg.name, a.name) !== null ? null : this.memberOf(a.member));
        this.raw("  }\n");
      } else if (p.kind === "union_ref") {
        this.needUnionDecoder(p.name!);
        this.print('  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: "{s}", {s}: nscfDecode{s}(fields) }}));\n', [a.name, tsString(a.name), tsProp(this.memberOf(a.member)), p.name!]);
      }
    }
    this.raw('  nscfUnknownTag("record", tag);\n}\n');
  }
  dispatchTextInput(): void {
    this.raw("\nexport function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {\n");
    for (const a of this.s.msg.arms) if (a.payload.kind === "union_ref") {
      this.needUnionDecoder(a.payload.name!);
      this.print('  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: "{s}", {s}: nscfDecode{s}(event) }}));\n', [a.name, tsString(a.name), tsProp(this.memberOf(a.member)), a.payload.name!]);
    }
    this.raw('  nscfUnknownTag("text-input", tag);\n}\n');
  }
  dispatchScrollState(): void {
    this.raw(text.scrollDispatch);
    for (const a of this.s.msg.arms) {
      const p = a.payload; if (p.kind !== "record" || scrollIndexes(this.s, p.name!) === null) continue;
      const r = findRecord(this.s, p.name!)!, fields: string[] = [], guards: string[] = [];
      for (const f of r.fields) {
        const index = scrollFields[0].indexOf(f.name), snake = scrollFields[1].indexOf(f.name);
        const param = index >= 0 ? scrollFields[0][index] : snake >= 0 ? scrollFields[0][snake] : f.name;
        let value = param;
        if (f.type.kind === "i64") {
          guards.push(param + " >= " + lowerBound(this.slotClass(r.name, f.name)) + " && " + param + " <= " + maxSafe);
          value = "Math.trunc(" + param + ")";
        }
        fields.push(tsProp(f.name) + ": " + value);
      }
      const flat = this.synthesizedRecordOf({ kind: "value", name: p.name! }, this.s.msg.name, a.name) !== null;
      const object = '{ kind: "' + tsString(a.name) + '", ' + (flat ? fields.join(", ") : tsProp(this.memberOf(a.member)) + ": { " + fields.join(", ") + " }") + " }";
      if (guards.length === 0) this.print("  if (tag === nscfTag_{s}) {s}\n", [a.name, this.commitLine(object)]);
      else { this.print(text.scrollDispatchGuard, [a.name, guards.join(" && "), object]); this.use("trap"); }
    }
    this.raw('  nscfUnknownTag("scroll-state", tag);\n}\n');
  }
  channelEntries(): void {
    const c = this.s.channels; this.use("sink"); this.use("trap");
    this.print(text.messageEnvelope, [this.s.msg.name]); this.msgPayloadWriter();
    if (c.key_msg || c.command_msg && !c.command_bytes) this.use("ascii_string");
    if (c.command_msg) this.raw(c.command_bytes ? text.commandBytesEntry : text.commandEntry);
    if (c.frame_msg) this.raw(this.s.abi.exports.includes("frame_msg_ns") ? text.frameEntryNs : text.frameEntry);
    if (c.key_msg) this.raw(text.keyEntry);
    if (c.pinch_msg) { this.needsPinchPhase = true; this.use("ascii_string"); this.raw(text.pinchEntry); this.needsMemberTrap = true; }
    if (c.drop_msg) {
      for (const id of ["read_f64", "read_u32", "read_bool", "read_bytes_body", "assert_consumed", "ascii_string"]) this.use(id);
      this.raw(text.dropEntry);
    }
  }
  msgPayloadWriter(): void {
    this.print("\nfunction nscfMsgPayload(sink: nscfSink, value: {s}): void {{\n", [this.s.msg.name]);
    for (const a of this.s.msg.arms) {
      this.print('  if (value.kind === "{s}") {{\n', [tsString(a.name)]);
      const p = a.payload, member = this.memberOf(a.member), access = tsAccess("value", member);
      switch (p.kind) {
        case "void": break;
        case "bytes": this.use("w_bytes"); this.print("    nscfWBytes(sink, {s});\n", [access]); break;
        case "number":
          if (p.class === "i64") this.print("    {s}(sink, {s});\n", [this.intWriter(this.s.msg.name, a.name), access]);
          else { this.use("w_f64"); this.print("    nscfWF64(sink, {s});\n", [access]); }
          break;
        case "number_bytes":
          if (p.number_class === "i64") this.print("    {s}(sink, {s});\n", [this.intWriter(this.s.msg.name, a.name + "." + p.number_field!), tsAccess("value", p.number_field!)]);
          else { this.use("w_f64"); this.print("    nscfWF64(sink, {s});\n", [tsAccess("value", p.number_field!)]); }
          this.use("w_bytes"); this.print("    nscfWBytes(sink, {s});\n", [tsAccess("value", p.bytes_field!)]); break;
        case "record": {
          const r = findRecord(this.s, p.name!)!;
          if (this.synthesizedRecordOf({ kind: "value", name: p.name! }, this.s.msg.name, a.name) !== null) {
            for (const f of r.fields) this.fieldWriteStatements(f.type, tsAccess("value", f.name), r.name, f.name, 2);
          } else { this.needRecordWriter(p.name!); this.print("    nscfWrite{s}(sink, {s});\n", [p.name!, access]); }
          break;
        }
        case "union_ref": this.needUnionWriter(p.name!); this.print("    nscfWrite{s}(sink, {s});\n", [p.name!, access]); break;
        case "enum_ref": this.needEnumIndex(p.name!); this.use("w_u32"); this.print("    nscfWU32(sink, nscfIndex{s}({s}));\n", [p.name!, access]); break;
        case "scalar":
          if (p.type!.kind === "i64") this.print("    {s}(sink, {s});\n", [this.intWriter(this.s.msg.name, a.name), access]);
          else if (p.type!.kind === "bool") { this.use("w_bool"); this.print("    nscfWBool(sink, {s});\n", [access]); }
          else if (p.type!.kind === "f64") { this.use("w_f64"); this.print("    nscfWF64(sink, {s});\n", [access]); }
          else if (p.type!.kind === "bytes") { this.use("w_bytes"); this.print("    nscfWBytes(sink, {s});\n", [access]); }
          else throw new Error("unsupported validated channel scalar");
          break;
        default: throw new Error("unknown channel payload");
      }
      this.raw("    return;\n  }\n");
    }
    this.raw('  nscfTrap("a channel produced a message outside the declared union — the value and the contract disagree");\n}\n');
  }
  postCycle(): void {
    this.raw("\n// --------------------------------------------------------- post-cycle\n");
    this.raw(this.s.has_subscriptions ? text.subscriptionsAfterCycle : text.emptySubscriptions);
    const model = findRecord(this.s, this.s.model)!;
    this.use("sink"); this.use("w_u32"); this.use("w_bytes"); this.needRecordWriter(this.s.model);
    this.print(text.snapshot, [this.s.model]);
    this.print(text.persistPrelude, [this.input.snapshot_text, this.s.model, this.s.model, String(model.fields.length)]);
    this.tempCounter = 0;
    for (let i = 0; i < model.fields.length; i++) {
      const f = model.fields[i], index = String(i);
      this.print("  {{\n    const nscfFieldSink{d} = nscfNewSink();\n    {{\n      const sink = nscfFieldSink{d};\n", [index, index]);
      this.fieldWriteStatements(f.type, tsAccess("value", f.name), model.name, f.name, 3);
      this.print("    }}\n    nscfWU32(sink, {d});\n    nscfWBytes(sink, nscfFinish(nscfFieldSink{d}));\n  }}\n", [index, index]);
    }
    this.print(text.persistEnd, [this.s.model]);
    this.print("\nfunction nscfDecodeSnapshot{s}(bytes: Uint8Array): {s} {{\n", [this.s.model, this.s.model]);
    const decode = new RecordDecode(this, "bytes", 1, "0", false); decode.run(model);
    this.use("assert_consumed"); this.print("  nscfAssertConsumed(bytes, {s});\n", [decode.offsetText()]);
    const construction = decode.constructionText();
    if (decode.guards.length > 0) {
      this.print('  if ({s}) return {s};\n  nscfTrap("a restored integer value is NaN or outside its attested exact-integer range — the snapshot cannot represent this Model");\n', [decode.guards.join(" && "), construction]);
      this.use("trap");
    } else this.print("  return {s};\n", [construction]);
    this.raw("}\n"); this.raw(text.restorePrelude);
    this.use("read_u32"); this.use("read_bytes_body"); this.use("trap");
    this.print('  const nscfFieldCount = nscfReadU32(snapshot, nscfAt);\n  nscfAt += 4;\n  if (nscfFieldCount !== {d}) nscfTrap("a model snapshot carries the wrong field count for this Model");\n', [String(model.fields.length)]);
    for (let i = 0; i < model.fields.length; i++) {
      const index = String(i);
      this.print('  const nscfFieldTag{d} = nscfReadU32(snapshot, nscfAt);\n  nscfAt += 4;\n  if (nscfFieldTag{d} !== {d}) nscfTrap("a model snapshot field tag does not match this Model");\n  const nscfFieldLen{d} = nscfReadU32(snapshot, nscfAt);\n  nscfAt += 4;\n  const nscfFieldBytes{d} = nscfReadBytesBody(snapshot, nscfAt, nscfFieldLen{d});\n  nscfAt += nscfFieldLen{d};\n  for (let nscfFieldAt{d} = 0; nscfFieldAt{d} < nscfFieldBytes{d}.length; nscfFieldAt{d}++) sink.push(nscfFieldBytes{d}[nscfFieldAt{d}]!);\n',
        [index, index, index, index, index, index, index, index, index, index, index, index, index]);
    }
    this.raw(text.restoreFieldsEnd); this.print(text.restoreFinish, [this.s.model]);
    if (this.s.has_migrate) this.print(text.migration, [this.s.model]);
    else this.raw(text.noMigration);
  }
  helperCall(): void {
    this.use("trap"); this.use("assert_consumed");
    if (this.s.model_helpers.length === 0) { this.raw(text.helperEmpty); return; }
    const parameterized = this.s.model_helpers.some(h => h.params.length > 0);
    this.use("sink"); this.raw(parameterized ? text.helperCallPrelude.replace("  nscfAssertConsumed(args, 0);\n", "") : text.helperCallPrelude);
    for (let i = 0; i < this.s.model_helpers.length; i++) {
      const h = this.s.model_helpers[i];
      this.print("  if (helper === {d}) {{\n", [String(i)]);
      let argumentsText = "";
      let guards: string[] = [];
      if (h.params.length > 0) {
        const decode = new RecordDecode(this, "args", 2, "0", false);
        for (let index = 0; index < h.params.length; index++) decode.fieldLocal(`p${index}`, h.params[index], "helpers", `${h.name}.params[${index}]`);
        this.print("    nscfAssertConsumed(args, {s});\n", [decode.offsetText()]);
        argumentsText = ", " + decode.exprs.map(p => p.text).join(", ");
        guards = decode.guards;
      } else if (parameterized) this.raw("    nscfAssertConsumed(args, 0);\n");
      if (guards.length) this.print("    if ({s}) {{\n", [guards.join(" && ")]);
      this.print("    const sink = nscfNewSink();\n    const nscfValue = {s}(nscfCommitted{s});\n", [h.name, argumentsText]);
      this.fieldWriteStatements(h.returns, "nscfValue", "helpers", h.name + ".return", 2);
      this.raw("    return nscfFinish(sink);\n");
      if (guards.length) this.raw('    }\n    nscfTrap("a helper argument is outside its attested integer range");\n');
      this.raw("  }\n");
    }
    this.raw('  nscfTrap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");\n}\n');
  }
  needEnumTable(name: string): void { if (!this.neededEnumTables.includes(name)) { this.neededEnumTables.push(name); this.reference(name); } }
  needEnumIndex(name: string): void { this.needEnumTable(name); if (!this.neededEnumIndexes.includes(name)) this.neededEnumIndexes.push(name); }
  needRecordWriter(name: string): void { if (!this.neededRecordWriters.includes(name)) { this.neededRecordWriters.push(name); this.reference(name); } }
  needUnionWriter(name: string): void { if (!this.neededUnionWriters.includes(name)) { this.neededUnionWriters.push(name); this.reference(name); } }
  needUnionDecoder(name: string): void { if (!this.neededUnionDecoders.includes(name)) { this.neededUnionDecoders.push(name); this.reference(name); } }
  generatedTables(): void {
    let header = false, enumAt = 0, enumIndexAt = 0, recordAt = 0, unionWriteAt = 0, unionDecodeAt = 0;
    while (enumAt < this.neededEnumTables.length || enumIndexAt < this.neededEnumIndexes.length || recordAt < this.neededRecordWriters.length
      || unionWriteAt < this.neededUnionWriters.length || unionDecodeAt < this.neededUnionDecoders.length) {
      if (!header) { header = true; this.raw(text.generatedTablesPrelude); }
      while (enumAt < this.neededEnumTables.length) this.enumTable(this.neededEnumTables[enumAt++]);
      while (enumIndexAt < this.neededEnumIndexes.length) this.enumIndexFn(this.neededEnumIndexes[enumIndexAt++]);
      while (recordAt < this.neededRecordWriters.length) this.recordWriter(this.neededRecordWriters[recordAt++]);
      while (unionWriteAt < this.neededUnionWriters.length) this.unionWriter(this.neededUnionWriters[unionWriteAt++]);
      while (unionDecodeAt < this.neededUnionDecoders.length) this.unionDecoder(this.neededUnionDecoders[unionDecodeAt++]);
    }
    if (this.needsMemberTrap) { this.use("trap"); this.raw(text.memberTrap); }
  }
  enumTable(name: string): void {
    const entry = findEnum(this.s, name)!;
    this.print("\nconst nscfMembers{s}: {s}[] = [", [name, name]);
    for (let i = 0; i < entry.members.length; i++) this.print('{s}"{s}"', [i === 0 ? "" : ", ", tsString(entry.members[i])]);
    this.raw("];\n");
  }
  enumIndexFn(name: string): void { this.use("trap"); this.print(text.enumIndex, [name, name, name, name]); }
  fieldWriteStatements(ref: TypeRef, expr: string, container: string, member: string, depth: number): void {
    const pad = this.indentText(depth);
    switch (ref.kind) {
      case "bool": this.use("w_bool"); this.print("{s}nscfWBool(sink, {s});\n", [pad, expr]); break;
      case "i64": this.print("{s}{s}(sink, {s});\n", [pad, this.intWriter(container, member), expr]); break;
      case "f64": this.use("w_f64"); this.print("{s}nscfWF64(sink, {s});\n", [pad, expr]); break;
      case "bytes":
        this.use("w_bytes");
        if (this.isThemeStateAccent(container, member)) { this.use("utf8_text"); this.print("{s}nscfWBytes(sink, nscfUtf8TextBytes({s}));\n", [pad, expr]); }
        else this.print("{s}nscfWBytes(sink, {s});\n", [pad, expr]);
        break;
      case "void": break;
      case "optional": {
        this.use("w_bool"); const temp = "nscfOpt" + this.tempCounter++;
        this.print("{s}const {s} = {s};\n{s}if ({s} === null || {s} === undefined) {{\n{s}  nscfWBool(sink, false);\n{s}}} else {{\n{s}  nscfWBool(sink, true);\n", [pad, temp, expr, pad, temp, temp, pad, pad, pad]);
        this.fieldWriteStatements(ref.inner!, temp, container, member, depth + 1); this.print("{s}}}\n", [pad]); break;
      }
      case "slice": {
        this.use("w_u32"); const index = "nscfIdx" + this.tempCounter++;
        this.print("{s}nscfWU32(sink, {s}.length);\n{s}for (let {s} = 0; {s} < {s}.length; {s}++) {{\n", [pad, expr, pad, index, index, expr, index]);
        this.fieldWriteStatements(ref.elem!, expr + "[" + index + "]!", container, member, depth + 1); this.print("{s}}}\n", [pad]); break;
      }
      case "node": case "value": {
        const name = ref.name!;
        if (this.plan.flattened.includes(name)) {
          const r = findRecord(this.s, name)!;
          for (const f of r.fields) this.fieldWriteStatements(f.type, expr + "." + f.name, name, f.name, depth);
        } else { this.needRecordWriter(name); this.print("{s}nscfWrite{s}(sink, {s});\n", [pad, name, expr]); }
        break;
      }
      case "enum": this.needEnumIndex(ref.name!); this.use("w_u32"); this.print("{s}nscfWU32(sink, nscfIndex{s}({s}));\n", [pad, ref.name!, expr]); break;
      case "union": this.needUnionWriter(ref.name!); this.print("{s}nscfWrite{s}(sink, {s});\n", [pad, ref.name!, expr]); break;
      default: throw new Error("unknown writer type");
    }
  }
  isThemeStateAccent(container: string, member: string): boolean {
    if (member !== "accent") return false;
    for (const h of this.s.model_helpers) if (h.name === "themeState")
      return (h.returns.kind === "node" || h.returns.kind === "value") && h.returns.name === container;
    return false;
  }
  recordWriter(name: string): void {
    const r = findRecord(this.s, name)!; this.use("sink"); this.tempCounter = 0;
    this.print("\nfunction nscfWrite{s}(sink: nscfSink, value: {s}): void {{\n", [name, name]);
    for (const f of r.fields) this.fieldWriteStatements(f.type, tsAccess("value", f.name), name, f.name, 1);
    this.raw("}\n");
  }
  unionWriter(name: string): void {
    const u = findUnion(this.s, name)!; this.use("sink"); this.use("w_u8"); this.use("trap"); this.tempCounter = 0;
    this.print("\nfunction nscfWrite{s}(sink: nscfSink, value: {s}): void {{\n", [name, name]);
    for (let i = 0; i < u.arms.length; i++) {
      const a = u.arms[i]; this.print('  if (value.kind === "{s}") {{\n    nscfWU8(sink, {d});\n', [tsString(a.name), String(i)]);
      if (a.payload.kind !== "void") {
        const r = this.synthesizedRecordOf(a.payload, u.name, a.name);
        if (r !== null) for (const f of r.fields) this.fieldWriteStatements(f.type, tsAccess("value", f.name), r.name, f.name, 2);
        else this.fieldWriteStatements(a.payload, tsAccess("value", this.memberOf(a.member)), u.name, a.name, 2);
      }
      this.raw("    return;\n  }\n");
    }
    this.print('  nscfTrap("{s} carries an arm outside its declared union — the value and the contract disagree");\n}}\n', [tsString(name)]);
  }
  recordDecodeCommit(r: RecordType, arm: string, member: string | null): void {
    const decode = new RecordDecode(this, "fields", 2, "0", false); decode.run(r);
    this.use("assert_consumed"); this.print("    nscfAssertConsumed(fields, {s});\n", [decode.offsetText()]);
    const construction = decode.constructionText();
    const object = member !== null ? '{ kind: "' + tsString(arm) + '", ' + tsProp(member) + ": " + construction + " }"
      : '{ kind: "' + tsString(arm) + '",' + construction.slice(1, -1) + "}";
    if (decode.guards.length > 0) {
      this.print('    if ({s}) {{\n      return nscfCommit(coreUpdate(nscfCommitted, {s}));\n    }}\n    nscfTrap("a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");\n', [decode.guards.join(" && "), object]);
      this.use("trap");
    } else this.print("    return nscfCommit(coreUpdate(nscfCommitted, {s}));\n", [object]);
  }
  unionDecoder(name: string): void {
    const u = findUnion(this.s, name)!; this.use("trap"); this.use("assert_consumed");
    this.print(text.unionDecoderPrelude, [name, name]);
    for (let i = 0; i < u.arms.length; i++) {
      const a = u.arms[i], kind = tsString(a.name); this.print("  if (arm === {d}) {{\n", [String(i)]);
      if (a.payload.kind === "void") this.print('    nscfAssertConsumed(bytes, 1);\n    return {{ kind: "{s}" }};\n', [kind]);
      else {
        const decode = new RecordDecode(this, "bytes", 2, "1", isTextInputUnion(this.s, name) && a.name === "set_selection");
        const r = this.synthesizedRecordOf(a.payload, u.name, a.name); let construction = "";
        if (r !== null) {
          decode.run(r); const inner = decode.constructionText();
          construction = '{ kind: "' + kind + '",' + inner.slice(1, -1) + "}";
        } else {
          decode.fieldLocal(this.memberOf(a.member), a.payload, u.name, a.name);
          construction = '{ kind: "' + kind + '", ' + tsProp(this.memberOf(a.member)) + ": " + decode.exprs[0].text + " }";
        }
        this.print("    nscfAssertConsumed(bytes, {s});\n", [decode.offsetText()]);
        if (decode.guards.length > 0) this.print('    if ({s}) {{\n      return {s};\n    }}\n    nscfTrap("a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");\n', [decode.guards.join(" && "), construction]);
        else this.print("    return {s};\n", [construction]);
      }
      this.raw("  }\n");
    }
    this.raw('  nscfTrap("a dispatched union payload carries a union arm index past the declared arms — the host and this core disagree about the contract");\n}\n');
  }
  codecSection(): void {
    if (this.usedCodec.length === 0) return; this.raw(text.codecPrelude);
    const snippets = [
      { id: "trap", code: text.trap }, { id: "read_u8", code: text.readU8 }, { id: "read_u32", code: text.readU32 },
      { id: "read_f64", code: text.readF64 }, { id: "read_i64", code: text.readI64 }, { id: "read_i64_saturating", code: text.readI64Saturating },
      { id: "read_u64_saturating", code: text.readU64Saturating }, { id: "read_bool", code: text.readBool }, { id: "read_bytes_body", code: text.readBytesBody },
      { id: "assert_consumed", code: text.assertConsumed }, { id: "trunc_toward_zero", code: text.truncTowardZero }, { id: "sink", code: text.sink },
      { id: "w_u8", code: text.writeU8 }, { id: "w_u32", code: text.writeU32 }, { id: "w_f64", code: text.writeF64 },
      { id: "w_i64", code: text.writeI64 }, { id: "w_u64", code: text.writeU64 }, { id: "w_bool", code: text.writeBool },
      { id: "w_bytes", code: text.writeBytes }, { id: "short_text", code: text.shortText }, { id: "utf8_text", code: text.utf8Text },
      { id: "ascii_string", code: text.asciiString }, { id: "enum_index", code: text.enumIndexCodec },
    ];
    for (const snippet of snippets) if (this.usedCodec.includes(snippet.id)) this.raw(snippet.code);
    if (this.usedCodec.includes("cmd_encoder")) this.cmdEncoder();
    if (this.usedCodec.includes("sub_encoder")) this.subEncoder();
  }
  cmdEncoder(): void { this.print(text.commandEncoderPrefix, [this.s.msg.name]); this.raw(text.commandEncoderBody); this.print(text.commandEncoderSuffix, [this.s.msg.name]); }
  subEncoder(): void { this.print(text.subscriptionEncoder, [this.s.msg.name, this.s.msg.name]); }
  spellRef(ref: TypeRef): string {
    switch (ref.kind) {
      case "bool": return "boolean";
      case "f64": case "i64": return "number";
      case "bytes": return "Uint8Array";
      case "void": return "void";
      case "optional": return this.spellRef(ref.inner!) + " | null";
      case "slice": {
        const elem = this.spellRef(ref.elem!);
        return (elem.includes(" ") || elem.includes("|") ? "(" + elem + ")" : elem) + "[]";
      }
      case "node": case "value": case "enum": case "union": this.reference(ref.name!); return ref.name!;
      default: throw new Error("unknown facade type");
    }
  }
  indentText(depth: number): string { return " ".repeat(depth * 2); }
  synthesizedRecordOf(ref: TypeRef, container: string, member: string): RecordType | null {
    if (ref.kind !== "value" || !synthesized(container, member, ref.name!) || !this.plan.inlined.includes(ref.name!)) return null;
    const r = findRecord(this.s, ref.name!); return r !== null && r.origin === null ? r : null;
  }
}

class RecordDecode {
  em: FacadeEmitter; buf: string; indent: number; start: string; saturatingSelection: boolean;
  localCount: number = 0; cursorStarted: boolean = false;
  guards: string[] = []; exprs: { name: string; text: string }[] = [];
  constructor(em: FacadeEmitter, buf: string, indent: number, start: string, saturatingSelection: boolean) {
    this.em = em; this.buf = buf; this.indent = indent; this.start = start; this.saturatingSelection = saturatingSelection;
  }
  offsetText(): string { return "nscfAt"; }
  nextLocal(): string { return "nscfV" + this.localCount++; }
  line(code: string, args: string[]): void { this.em.raw(this.em.indentText(this.indent)); this.em.print(code, args); }
  ensureCursor(): void { if (!this.cursorStarted) { this.cursorStarted = true; this.line("let nscfAt = {s};\n", [this.start]); } }
  advance(amount: string): void { this.line("nscfAt += {s};\n", [amount]); }
  addGuard(guards: string[], local: string, className: string | null): void {
    guards.push(local + " >= " + lowerBound(className) + " && " + local + " <= " + maxSafe);
  }
  guardedStatement(guards: string[], statement: string): void {
    if (guards.length === 0) { this.line("{s}\n", [statement]); return; }
    this.line("if ({s}) {{\n", [guards.join(" && ")]); this.indent++; this.line("{s}\n", [statement]); this.indent--;
    this.line("}} else {{\n", []); this.indent++;
    this.line('nscfTrap("a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");\n', []);
    this.indent--; this.line("}}\n", []); this.em.use("trap");
  }
  run(r: RecordType): void { this.ensureCursor(); for (const f of r.fields) this.fieldLocal(f.name, f.type, r.name, f.name); }
  fieldLocal(name: string, ref: TypeRef, container: string, member: string): void {
    this.ensureCursor(); this.exprs.push({ name, text: this.decodeRef(ref, name, container, member, this.guards) });
  }
  decodeRecord(r: RecordType, guards: string[]): string {
    const parts: string[] = [];
    for (const f of r.fields) parts.push(tsProp(f.name) + ": " + this.decodeRef(f.type, f.name, r.name, f.name, guards));
    return "{ " + parts.join(", ") + " }";
  }
  decodeUnion(name: string): string {
    const u = findUnion(this.em.s, name)!; this.em.use("read_u8");
    const tag = this.nextLocal(); this.line("const {s} = nscfReadU8({s}, nscfAt);\n", [tag, this.buf]); this.advance("1");
    const local = this.nextLocal(); this.line("let {s}: {s};\n", [local, name]);
    for (let i = 0; i < u.arms.length; i++) {
      const a = u.arms[i]; this.line("{s}if ({s} === {d}) {{\n", [i === 0 ? "" : "else ", tag, String(i)]); this.indent++;
      const guards: string[] = []; let object = "";
      if (a.payload.kind === "void") object = '{ kind: "' + tsString(a.name) + '" }';
      else {
        const r = this.em.synthesizedRecordOf(a.payload, u.name, a.name);
        if (r !== null) { const inner = this.decodeRecord(r, guards); object = '{ kind: "' + tsString(a.name) + '",' + inner.slice(1, -1) + "}"; }
        else {
          const value = this.decodeRef(a.payload, this.em.memberOf(a.member), u.name, a.name, guards);
          object = '{ kind: "' + tsString(a.name) + '", ' + tsProp(this.em.memberOf(a.member)) + ": " + value + " }";
        }
      }
      this.guardedStatement(guards, local + " = " + object + ";"); this.indent--; this.line("}}\n", []);
    }
    this.line("else {{\n", []); this.indent++;
    this.line('nscfTrap("a dispatched union payload carries a union arm index past the declared arms — the host and this core disagree about the contract");\n', []);
    this.indent--; this.line("}}\n", []); this.em.use("trap"); return local;
  }
  decodeRef(ref: TypeRef, fieldName: string, container: string, member: string, guards: string[]): string {
    const em = this.em;
    switch (ref.kind) {
      case "f64": {
        em.use("read_f64"); const local = this.nextLocal();
        this.line("const {s} = nscfReadF64({s}, nscfAt);\n", [local, this.buf]); this.advance("8"); return local;
      }
      case "i64": {
        const className = em.slotClass(container, member), selection = fieldName === "anchor" || fieldName === "focus";
        const reader = this.saturatingSelection && selection ? (className === "u64" ? "read_u64_saturating" : "read_i64_saturating") : "read_i64";
        const readerName = reader === "read_u64_saturating" ? "nscfReadU64Saturating" : reader === "read_i64_saturating" ? "nscfReadI64Saturating" : "nscfReadI64";
        em.use(reader); const local = this.nextLocal();
        this.line("const {s} = {s}({s}, nscfAt);\n", [local, readerName, this.buf]); this.advance("8");
        this.addGuard(guards, local, className); return "Math.trunc(" + local + ")";
      }
      case "bool": {
        em.use("read_bool"); const local = this.nextLocal();
        this.line("const {s} = nscfReadBool({s}, nscfAt);\n", [local, this.buf]); this.advance("1"); return local;
      }
      case "bytes": {
        em.use("read_u32"); em.use("read_bytes_body"); const len = this.nextLocal();
        this.line("const {s} = nscfReadU32({s}, nscfAt);\n", [len, this.buf]); this.advance("4"); const local = this.nextLocal();
        this.line("const {s} = nscfReadBytesBody({s}, nscfAt, {s});\n", [local, this.buf, len]); this.advance(len); return local;
      }
      case "enum": {
        const name = ref.name!; em.use("read_u32"); em.needEnumTable(name); em.needsMemberTrap = true; const local = this.nextLocal();
        this.line("const {s} = nscfReadU32({s}, nscfAt);\n", [local, this.buf]);
        this.line('if ({s} >= nscfMembers{s}.length) nscfMember("{s}", {s});\n', [local, name, tsString(name), local]); this.advance("4");
        return "nscfMembers" + name + "[" + local + "]!";
      }
      case "node": case "value": return this.decodeRecord(findRecord(em.s, ref.name!)!, guards);
      case "optional": {
        em.use("read_bool"); const present = this.nextLocal();
        this.line("const {s} = nscfReadBool({s}, nscfAt);\n", [present, this.buf]); this.advance("1"); const local = this.nextLocal();
        this.line("let {s}: {s} | null = null;\n", [local, em.spellRef(ref.inner!)]); this.line("if ({s}) {{\n", [present]); this.indent++;
        const innerGuards: string[] = [], value = this.decodeRef(ref.inner!, fieldName, container, member, innerGuards);
        this.guardedStatement(innerGuards, local + " = " + value + ";"); this.indent--; this.line("}}\n", []); return local;
      }
      case "slice": {
        em.use("read_u32"); const len = this.nextLocal(); this.line("const {s} = nscfReadU32({s}, nscfAt);\n", [len, this.buf]); this.advance("4");
        const local = this.nextLocal(); this.line("const {s}: {s} = [];\n", [local, em.spellRef(ref)]); const index = this.nextLocal();
        this.line("for (let {s} = 0; {s} < {s}; {s}++) {{\n", [index, index, len, index]); this.indent++;
        const elemGuards: string[] = [], value = this.decodeRef(ref.elem!, fieldName, container, member, elemGuards);
        this.guardedStatement(elemGuards, local + ".push(" + value + ");"); this.indent--; this.line("}}\n", []); return local;
      }
      case "union": return this.decodeUnion(ref.name!);
      default: throw new Error("unknown decoded type");
    }
  }
  constructionText(): string { return "{ " + this.exprs.map(e => tsProp(e.name) + ": " + e.text).join(", ") + " }"; }
}

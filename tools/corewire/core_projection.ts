// Shared layout planning and admission rules for the two core projections.
import { findRecord, findEnum, findUnion, findArm, flag, walkRefs, usesVirtualExtentHelpers } from "./core_contract.ts";
import type { CoreContract, TypeRef, Payload, RecordType, Diagnostic } from "./core_contract.ts";
import { tsReservedWords, fixedExports, ambientValues, zigKeywords, zigPrimitives } from "./core_vocabulary.ts";

export interface ProjectionPlan { inlined: string[]; flattened: string[]; node_stored: string[] }
function innermost(ref: TypeRef): TypeRef {
  while (ref.kind === "optional" || ref.kind === "slice") ref = ref.kind === "optional" ? ref.inner! : ref.elem!;
  return ref;
}
function synthesized(container: string, member: string, name: string): boolean { return name === container + "_" + member; }
function note(names: string[], name: string): void { if (!names.includes(name)) names.push(name); }
function refCount(ref: TypeRef, name: string): number {
  const r = innermost(ref);
  return ["node", "value", "enum", "union"].includes(r.kind) && r.name === name ? 1 : 0;
}
function referenceCount(s: CoreContract, name: string): number {
  let count = s.model === name ? 1 : 0;
  walkRefs(s, (ref) => { count += refCount(ref, name); });
  for (const a of s.msg.arms) if (["record", "union_ref", "enum_ref"].includes(a.payload.kind) && a.payload.name === name) count++;
  return count;
}
function candidate(candidates: string[], container: string, member: string, ref: TypeRef): void {
  const r = innermost(ref);
  if (r.kind === "value" && synthesized(container, member, r.name!)) candidates.push(r.name!);
}
function flattenedRecord(s: CoreContract, plan: ProjectionPlan, ref: TypeRef, container: string, member: string): RecordType | null {
  if (ref.kind !== "value" || !synthesized(container, member, ref.name!) || !plan.inlined.includes(ref.name!)) return null;
  const record = findRecord(s, ref.name!);
  return record !== null && record.origin === null ? record : null;
}
function payloadRef(p: Payload): TypeRef { return { kind: "value", name: p.name! }; }
function storedNodes(s: CoreContract, scalarMessages: boolean): string[] {
  const names: string[] = [s.model];
  walkRefs(s, (ref, at) => {
    if (!scalarMessages && at.startsWith("msg.arms[")) return;
    const r = innermost(ref);
    if (r.kind === "node") note(names, r.name!);
  });
  return names;
}
export function projectionPlan(s: CoreContract): ProjectionPlan {
  const plan: ProjectionPlan = { inlined: [], flattened: [], node_stored: storedNodes(s, true) };
  const candidates: string[] = [];
  for (const r of s.types.structs) for (const f of r.fields) candidate(candidates, r.name, f.name, f.type);
  for (const u of s.types.unions) for (const a of u.arms) candidate(candidates, u.name, a.name, a.payload);
  for (const a of s.msg.arms) if (a.payload.kind === "record" && synthesized(s.msg.name, a.name, a.payload.name!)) candidates.push(a.payload.name!);
  for (const name of candidates) {
    const r = findRecord(s, name);
    if (referenceCount(s, name) === 1 && r !== null && r.origin === null && r.fields.length >= 2) plan.inlined.push(name);
  }
  for (const a of s.msg.arms) if (a.payload.kind === "record") {
    const r = flattenedRecord(s, plan, payloadRef(a.payload), s.msg.name, a.name);
    if (r !== null) plan.flattened.push(r.name);
  }
  for (const u of s.types.unions) for (const a of u.arms) {
    const r = flattenedRecord(s, plan, a.payload, u.name, a.name);
    if (r !== null) plan.flattened.push(r.name);
  }
  return plan;
}
function tableNames(s: CoreContract): string[] {
  const out: string[] = [];
  for (const r of s.types.structs) out.push(r.name);
  for (const e of s.types.enums) out.push(e.name);
  for (const u of s.types.unions) out.push(u.name);
  return out;
}
function numeric(ref: TypeRef): boolean { return ref.kind === "f64" || ref.kind === "i64"; }
function valueRecord(s: CoreContract, ref: TypeRef): RecordType | null { return ref.kind === "value" ? findRecord(s, ref.name!) : null; }
function numericRecord(s: CoreContract, ref: TypeRef, names: string[]): boolean {
  const r = valueRecord(s, ref);
  if (r === null || r.fields.length !== names.length) return false;
  for (const name of names) if (!r.fields.some(f => f.name === name && numeric(f.type))) return false;
  return true;
}
function channelRecord(s: CoreContract, name: string): RecordType | null {
  const a = findArm(s, name);
  return a !== null && a.payload.kind === "record" ? findRecord(s, a.payload.name!) : null;
}
function appearanceRecord(s: CoreContract, r: RecordType): boolean {
  if (r.fields.length !== 3) return false;
  let scheme = false, reduce = false, contrast = false;
  for (const f of r.fields) {
    if (f.name === "colorScheme") {
      const e = f.type.kind === "enum" ? findEnum(s, f.type.name!) : null;
      if (e === null || e.members.length !== 2) return false;
      scheme = e.members.includes("light") && e.members.includes("dark");
    } else if (f.name === "reduceMotion") reduce = f.type.kind === "bool";
    else if (f.name === "highContrast") contrast = f.type.kind === "bool";
  }
  return scheme && reduce && contrast;
}
function chromeRecord(s: CoreContract, r: RecordType): boolean {
  if (r.fields.length !== 3) return false;
  let insets = false, buttons = false, tabs = false;
  for (const f of r.fields) {
    if (f.name === "insets") insets = numericRecord(s, f.type, ["top", "right", "bottom", "left"]);
    else if (f.name === "buttons") buttons = numericRecord(s, f.type, ["x", "y", "width", "height"]);
    else if (f.name === "tabsProjected") tabs = f.type.kind === "bool";
  }
  return insets && buttons && tabs;
}
function mirrorNames(s: CoreContract, out: Diagnostic[]): void {
  const reserved = ["std", "shim_rt", "core_abi", "abi", "rt", "msg_tags", "boot", "initialModel", "update", "commitModelRoot", "sidecar_build_id", "sidecar_model_fingerprint", "sidecar_abi_version", "sidecar_snapshot_format", "deterministic", "async_free", "snapshotModel", "modelSnapshot", "persistenceSnapshot", "restoreModel", "referenceAttestedExports", "T", "n", "model", "msg", "payload", "encoded", "cmd_ptr", "cmd_len", "subs_ptr", "subs_len", "snap_ptr", "snap_len", "out", "out_ptr", "out_len", "tag", "tag_name", "name", "frame", "key", "pinch", "value", "self", "index", "args", "args_tuple", "allocator", "fields", "field", "next", "helper_args", "view_unbound"];
  for (const h of s.model_helpers) for (let i = 0; i < h.params.length; i++) reserved.push(`p${i}`);
  reserved.push("subscriptions", "commandMsg", "frameMsg", "keyMsg", "pinchMsg", "dropMsg", "appearanceMsg", "chromeMsg", "envMsgs");
  if (s.model !== "Model") reserved.push("Model");
  if (s.msg.name !== "Msg") reserved.push("Msg");
  if (s.abi.exports.includes("native_view")) reserved.push("nativeView", "nativeViewEvent", "ptr", "len", "arena");
  if (s.abi.exports.includes("native_virtual_requests")) reserved.push("nativeVirtualRequests", "nativeVirtualView");
  if (usesVirtualExtentHelpers(s)) reserved.push("virtualExtentHelper", "virtualExtentEstimate");
  if (s.abi.exports.includes("native_media_view")) reserved.push("nativeMediaView");
  if (s.abi.exports.includes("native_media_window_view")) reserved.push("nativeMediaWindowView");
  if (s.abi.exports.includes("native_window_view")) reserved.push("nativeWindowView", "label", "ptr", "len", "arena");
  const policies = ["radio", "tabs", "tree", "list", "menu", "toggle", "accordion", "slider", "split", "scroll", "resizable", "text", "timer", "db", "effect", "stream", "window", "theme", "status"];
  const methods = ["nativeRadioPolicy", "nativeTabsPolicy", "nativeTreePolicy", "nativeListPolicy", "nativeMenuPolicy", "nativeTogglePolicy", "nativeAccordionPolicy", "nativeSliderPolicy", "nativeSplitPolicy", "nativeScrollPolicy", "nativeResizablePolicy", "nativeTextPolicy", "nativeTimerPolicy", "nativeDbPolicy", "nativeEffectPolicy", "nativeStreamPolicy", "nativeWindowPolicy", "nativeThemePolicy", "nativeStatusPolicy"];
  for (let i = 0; i < policies.length; i++) if (s.abi.exports.includes("native_" + policies[i] + "_policy")) {
    reserved.push(methods[i]);
    if (policies[i] === "text") reserved.push("nativePressHoldPolicy", "nativeTabFocusPolicy", "nativeSurfaceScopePolicy", "nativeFocusReturnPolicy", "nativeTooltipPolicy");
    reserved.push("request", "output", "ptr", "len");
  }
  if (s.model_helpers.length > 0) reserved.push("callHelper");
  const c = s.channels;
  if (c.command_msg || c.frame_msg || c.key_msg || c.pinch_msg || c.drop_msg || s.abi.exports.includes("native_view")) reserved.push("msgFromEnvelope", "decodeMsgEnvelope", "envelope", "header", "arena");
  if (s.init_returns_cmd) reserved.push("InitResult");
  if (s.update_returns_cmd) reserved.push("UpdateResult");
  if (c.frame_msg) reserved.push("FrameEvent");
  if (c.key_msg) reserved.push("KeyEvent");
  if (c.pinch_msg) reserved.push("PinchEvent", "PinchPhase");
  if (c.drop_msg) reserved.push("FileDropEvent", "FileDropPoint");
  const tables = tableNames(s);
  for (const name of tables) if (reserved.includes(name)) flag(out, "types", `type name "${name}" collides with a declaration the generated shim itself must make; rename the type in the core source`);
  if (reserved.includes(s.msg.name) || tables.includes(s.msg.name)) flag(out, "msg.name", `message union name "${s.msg.name}" collides with another declaration of the generated shim; rename the union in the core source`);
  for (const h of s.model_helpers) {
    if (reserved.includes(h.name)) flag(out, "model_helpers", `helper "${h.name}" collides with a declaration the generated shim itself must make (methods shadow file-scope names inside the model struct); rename the helper in the core source`);
    if (tables.includes(h.name) || s.msg.name === h.name) flag(out, "model_helpers", `helper "${h.name}" shadows the type of the same name inside the model struct, where field types resolve; rename one in the core source`);
  }
  const model = findRecord(s, s.model);
  if (model !== null) {
    if (usesVirtualExtentHelpers(s)) for (const f of model.fields) {
      if (f.name === "virtualExtentHelper" || f.name === "virtualExtentEstimate") flag(out, "types", `model field "${f.name}" collides with a declaration the generated shim itself must make; rename the field in the core source`);
    }
    for (const h of s.model_helpers) {
      if (h.name === "view_unbound") flag(out, "model_helpers", 'helper "view_unbound" takes the unbound-list declaration\'s spelling — the contract reflection reads that name as the opt-out tuple; rename the helper in the core source');
      for (const f of model.fields) if (f.name === h.name) flag(out, "model_helpers", `helper "${h.name}" collides with the model field of the same name — the mirror declares helpers as model methods, one member namespace; rename one in the core source`);
    }
    if (s.model_unbound.length > 0) for (const f of model.fields) if (f.name === "view_unbound") flag(out, "model_unbound", 'the model field "view_unbound" collides with the unbound-list declaration the mirror must make; rename the field in the core source');
  }
  if (s.msg.unbound.length > 0) for (const a of s.msg.arms) if (a.name === "view_unbound") flag(out, "msg.unbound", 'the message arm "view_unbound" collides with the unbound-list declaration the mirror must make; rename the arm in the core source');
}
function mirrorChannelShapes(s: CoreContract, out: Diagnostic[]): void {
  if (s.channels.appearance_msg !== null) {
    const r = channelRecord(s, s.channels.appearance_msg);
    const teaching = "the appearance arm must carry exactly { colorScheme: a light/dark enum, reduceMotion: bool, highContrast: bool } — the host builds this record by field name";
    if (r === null) { flag(out, "channels.appearance_msg", teaching); return; }
    if (!appearanceRecord(s, r)) flag(out, "channels.appearance_msg", teaching);
  }
  if (s.channels.chrome_msg !== null) {
    const r = channelRecord(s, s.channels.chrome_msg);
    const teaching = "the chrome arm must carry exactly { insets: top/right/bottom/left numbers, buttons: x/y/width/height numbers, tabsProjected: bool } — the host builds this record by field name";
    if (r === null) { flag(out, "channels.chrome_msg", teaching); return; }
    if (!chromeRecord(s, r)) flag(out, "channels.chrome_msg", teaching);
  }
}
function unsigned(s: CoreContract, slot: string): boolean { return s.integer_slots.some(p => p.slot === slot && p.class === "u64"); }
function scrollRecord(r: RecordType): boolean {
  const spellings = [
    ["offsetX", "offsetY", "velocityX", "velocityY", "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY"],
    ["offset_x", "offset_y", "velocity_x", "velocity_y", "viewport_extent_x", "viewport_extent_y", "content_extent_x", "content_extent_y"],
  ];
  return r.fields.length === 8 && spellings.some(fields => fields.every(name => r.fields.some(f => f.name === name && numeric(f.type))));
}
function mirrorIntegers(s: CoreContract, out: Diagnostic[]): void {
  for (const a of s.msg.arms) {
    if (a.payload.kind !== "record") continue;
    const r = findRecord(s, a.payload.name!);
    if (r === null || !scrollRecord(r)) continue;
    for (const f of r.fields) if (f.type.kind === "i64" && ["offsetX", "offsetY", "velocityX", "velocityY", "offset_x", "offset_y", "velocity_x", "velocity_y"].includes(f.name) && unsigned(s, r.name + "." + f.name))
      flag(out, "integer_slots", `"${r.name}.${f.name}" is a signed scroll-state axis (offsets and velocities go negative during rubber-banding and upward flicks) — the u64 class cannot carry those values; keep offset and velocity fields i64 or f64`);
  }
  if (s.channels.chrome_msg !== null) {
    const r = channelRecord(s, s.channels.chrome_msg);
    if (r !== null) for (const f of r.fields) if (f.name === "buttons") {
      const nested = valueRecord(s, f.type);
      if (nested !== null) for (const g of nested.fields) if (g.type.kind === "i64" && (g.name === "x" || g.name === "y") && unsigned(s, nested.name + "." + g.name))
        flag(out, "integer_slots", `"${nested.name}.${g.name}" is the window-control cluster's position, reported in signed content coordinates — the u64 class cannot carry it; keep buttons x and y i64 or f64`);
    }
  }
}
export function validateMirror(s: CoreContract): Diagnostic[] {
  const out: Diagnostic[] = [];
  mirrorNames(s, out); mirrorChannelShapes(s, out);
  const nodes = storedNodes(s, false);
  for (const a of s.msg.arms) if (a.payload.kind === "record" && nodes.includes(a.payload.name!)) flag(out, "msg.arms", `arm "${a.name}": record "${a.payload.name}" is stored by reference in the model graph, and the compiled core keeps that storage when the record doubles as an arm payload — a fact the record payload family cannot carry; keep the arm's payload a value-stored record`);
  mirrorIntegers(s, out);
  return out;
}

function identifier(name: string, dollar: boolean): boolean {
  if (name.length === 0 || (name.charCodeAt(0) >= 48 && name.charCodeAt(0) <= 57)) return false;
  for (let i = 0; i < name.length; i++) {
    const c = name.charCodeAt(i);
    if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 95 || (dollar && c === 36))) return false;
  }
  return true;
}
function primitive(name: string): boolean {
  if (zigPrimitives.includes(name)) return true;
  if (name.length < 2 || (name[0] !== "i" && name[0] !== "u")) return false;
  for (let i = 1; i < name.length; i++) if (name.charCodeAt(i) < 48 || name.charCodeAt(i) > 57) return false;
  return true;
}
function identifierIssue(name: string, declaration: boolean): string | null {
  if (name.length === 0) return "is empty";
  if (name === "_") return "is the discard spelling in the compiled module";
  if (name.charCodeAt(0) >= 48 && name.charCodeAt(0) <= 57) return "starts with a digit";
  if (!identifier(name, false)) return "uses characters outside the compiled module's identifier set (letters, digits, underscore)";
  if (zigKeywords.includes(name)) return "is a keyword in the compiled module";
  if (primitive(name)) return "is a primitive type name in the compiled module";
  if (declaration && tsReservedWords.includes(name)) return "is a reserved word in TypeScript";
  return null;
}
function generatedType(s: CoreContract, name: string): boolean {
  if (name === s.model || name === s.msg.name) return false;
  const r = findRecord(s, name), e = findEnum(s, name), u = findUnion(s, name);
  return r !== null ? r.origin === null : e !== null ? e.origin === null : u !== null ? u.origin === null : false;
}
function reservedNamespace(name: string): boolean { return name.startsWith("nsc_core_") || name.startsWith("nscf"); }
function facadeFacts(s: CoreContract, plan: ProjectionPlan, out: Diagnostic[]): void {
  const model = findRecord(s, s.model);
  if (model === null || model.origin === null) flag(out, "types", "the model declaration carries no authored type-origin fact — this sidecar predates facade metadata; regenerate it with the current compiler before requesting --facade, --profile, or --check");
  for (const a of s.msg.arms) {
    const p = a.payload;
    const needs = p.kind !== "void" && p.kind !== "number_bytes" && (p.kind !== "record" || flattenedRecord(s, plan, payloadRef(p), s.msg.name, a.name) === null);
    if (needs && a.member === null) flag(out, "msg.arms", `arm "${a.name}" carries one payload but no authored member-name fact — this sidecar predates facade metadata; regenerate it with the current compiler`);
  }
  for (const u of s.types.unions) for (const a of u.arms) {
    if (a.payload.kind === "void" || flattenedRecord(s, plan, a.payload, u.name, a.name) !== null) continue;
    if (a.member === null) flag(out, "types.unions", `arm "${a.name}" of "${u.name}" carries one payload but no authored member-name fact — this sidecar predates facade metadata; regenerate it with the current compiler`);
  }
}
function modelValueRecords(s: CoreContract, out: Diagnostic[]): void {
  const model = findRecord(s, s.model), visited: string[] = [];
  if (model === null) return;
  function visit(ref: TypeRef): void {
    if (ref.kind === "value" || ref.kind === "node" || ref.kind === "union") {
      const name = ref.name!;
      if (visited.includes(name)) return;
      visited.push(name);
      if (ref.kind === "union") {
        const u = findUnion(s, name);
        if (u !== null) for (const a of u.arms) visit(a.payload);
        return;
      }
      const r = findRecord(s, name);
      if (r === null) return;
      for (const f of r.fields) {
        if (ref.kind === "node") visit(f.type);
        else if (!["f64", "i64", "bool", "enum"].includes(f.type.kind)) {
          flag(out, "types", `"${name}" is a value-stored record the model keeps, but field "${f.name}" is not a scalar — the compiled projection commits value records shallowly, so heap-backed fields would dangle across frames; store "${name}" by reference in the core source`);
          break;
        }
      }
    } else if (ref.kind === "slice") {
      const elem = ref.elem!.kind === "optional" ? ref.elem!.inner! : ref.elem!;
      if (elem.kind === "value") flag(out, "types", `a model sequence holds "${elem.name}" by value — sequences the model keeps carry reference-stored records (the compiled projection has no by-value sequence commit); store "${elem.name}" by reference in the core source`);
      visit(ref.elem!);
    } else if (ref.kind === "optional") visit(ref.inner!);
  }
  for (const f of model.fields) visit(f.type);
}
function facadeNames(s: CoreContract, plan: ProjectionPlan, out: Diagnostic[]): void {
  const names = tableNames(s); names.push(s.msg.name, s.model);
  for (const name of names) {
    const issue = identifierIssue(name, true);
    if (issue !== null) flag(out, "types", `type name "${name}" ${issue} — the facade must stay declarable end to end (TypeScript source, then the compiled module, which takes identifiers verbatim); rename it in the core source`);
    if (name === "Uint8Array") flag(out, "types", '"Uint8Array" shadows the ambient byte type every encoder in the generated facade uses; rename the type in the core source');
    if (name === "Buffer") flag(out, "types", '"Buffer" shadows the ambient buffer type the generated f64 codec uses; rename the type in the core source');
    if (s.channels.pinch_msg && name === "PinchPhase") flag(out, "types", '"PinchPhase" collides with the SDK vocabulary the wired pinch channel imports; rename the type in the core source');
    if (s.channels.drop_msg && name === "FileDropPoint") flag(out, "types", '"FileDropPoint" collides with the SDK vocabulary the wired file-drop channel imports; rename the type in the core source');
  }
  for (const a of s.msg.arms) {
    const issue = identifierIssue(a.name, false);
    if (issue !== null) flag(out, "msg.arms", `arm "${a.name}" ${issue} — the facade must stay declarable end to end; rename it in the core source`);
    if (a.member === "kind") flag(out, "msg.arms", `arm "${a.name}" names its payload member "kind", the discriminator's own spelling — the constructed arm object would declare it twice; rename the member in the core source`);
  }
  for (const u of s.types.unions) for (const a of u.arms) {
    const issue = identifierIssue(a.name, false);
    if (issue !== null) flag(out, "types.unions", `arm "${a.name}" of "${u.name}" ${issue} — the facade must stay declarable end to end; rename it in the core source`);
    if (a.member === "kind") flag(out, "types.unions", `arm "${a.name}" of "${u.name}" names its payload member "kind", the discriminator's own spelling; rename the member in the core source`);
  }
  for (const e of s.types.enums) {
    for (const name of e.members) {
      const issue = identifierIssue(name, false);
      if (issue !== null) flag(out, "types.enums", `member "${name}" of "${e.name}" ${issue} — the facade must stay declarable end to end; rename it in the core source`);
    }
    if (e.members.length < 2) flag(out, "types", `enum "${e.name}" has one member — a single string literal is not a union in the projected subset, so no source can author it; give the state a second member or fold it away in the core source`);
  }
  for (const r of s.types.structs) for (const f of r.fields) {
    const issue = identifierIssue(f.name, false);
    if (issue !== null) flag(out, "types", `field "${f.name}" ${issue} — the facade must stay declarable end to end; rename it in the core source`);
    if (reservedNamespace(f.name)) flag(out, "types", `field "${f.name}" takes the facade's reserved nsc name space; rename it in the core source`);
  }
  for (const a of s.msg.arms) {
    const p = a.payload;
    if (p.kind === "number_bytes") for (const name of [p.number_field!, p.bytes_field!]) {
      const issue = identifierIssue(name, false);
      if (issue !== null) flag(out, "msg.arms", `field "${name}" ${issue} — the facade must stay declarable end to end; rename it in the core source`);
      if (name === "kind") flag(out, "msg.arms", `arm "${a.name}" flattens a field spelled "kind" beside the message discriminator of the same name; rename the field in the core source`);
      if (reservedNamespace(name)) flag(out, "msg.arms", `field "${name}" takes the facade's reserved nsc name space; rename it in the core source`);
    }
    else if (p.kind === "record") {
      const r = flattenedRecord(s, plan, payloadRef(p), s.msg.name, a.name);
      if (r !== null) for (const f of r.fields) if (f.name === "kind") flag(out, "msg.arms", `arm "${a.name}" flattens a field spelled "kind" beside the message discriminator of the same name; rename the field in the core source`);
    }
  }
  for (const u of s.types.unions) for (const a of u.arms) {
    const r = flattenedRecord(s, plan, a.payload, u.name, a.name);
    if (r !== null) for (const f of r.fields) if (f.name === "kind") flag(out, "types.unions", `arm "${a.name}" of "${u.name}" flattens a field spelled "kind" beside the arm discriminator of the same name; rename the field in the core source`);
  }
  for (const h of s.model_helpers) {
    if (!identifier(h.name, true) || tsReservedWords.includes(h.name) || identifierIssue(h.name, true) !== null) { flag(out, "model_helpers", `helper "${h.name}" is not declarable as an exported function in both pipeline languages; rename it in the core source`); continue; }
    if (reservedNamespace(h.name)) flag(out, "model_helpers", `helper "${h.name}" takes the facade's reserved nsc name space; rename it in the core source`);
    for (const name of fixedExports) if (h.name === name) flag(out, "model_helpers", `helper "${h.name}" collides with a declaration the generated facade itself must export; rename it in the core source`);
    for (const name of ambientValues) if (h.name === name) flag(out, "model_helpers", `helper "${h.name}" shadows an ambient value the generated facade calls; rename it in the core source`);
  }
  const declarations = tableNames(s); declarations.push(s.msg.name);
  for (const name of declarations) {
    if (name.length === 0) continue;
    if (reservedNamespace(name)) { flag(out, "types", `"${name}" collides with the facade's reserved nsc name space; rename it in the core source`); continue; }
    for (const fixed of fixedExports) if (name === fixed) flag(out, "types", `"${name}" collides with a declaration the generated facade itself must make; rename it in the core source`);
  }
  for (const r of s.types.structs) if (generatedType(s, r.name) && !plan.flattened.includes(r.name)) flag(out, "types", `compiler-generated table type "${r.name}" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete record`);
  for (const e of s.types.enums) if (generatedType(s, e.name)) flag(out, "types", `compiler-generated table type "${e.name}" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete type`);
  for (const u of s.types.unions) if (generatedType(s, u.name)) flag(out, "types", `compiler-generated table type "${u.name}" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete union`);
  const values: string[] = [];
  walkRefs(s, (ref) => { const r = innermost(ref); if (r.kind === "value") note(values, r.name!); });
  for (const name of values) if (plan.node_stored.includes(name)) flag(out, "types", `"${name}" is stored by reference at one site and by value at another — the projection states storage once per declaration, so one record cannot say both; split the type in the core source`);
  modelValueRecords(s, out);
  for (const channel of [{ name: "appearance_msg", arm: s.channels.appearance_msg }, { name: "chrome_msg", arm: s.channels.chrome_msg }]) {
    const name = channel.arm;
    if (name === null) continue;
    const a = findArm(s, name);
    if (a !== null && a.payload.kind === "record" && !plan.flattened.includes(a.payload.name!)) flag(out, `channels.${channel.name}`, `arm "${name}" carries the named record "${a.payload.name}", which the projection cannot flatten into the arm (the host fills the event's fields directly on the arm) — declare the event's fields inline on the arm in the core source`);
  }
}
function nestedOptional(ref: TypeRef, inside: boolean, at: string, out: Diagnostic[]): void {
  if (ref.kind === "optional") {
    if (inside) { flag(out, at, "a nested optional has no TypeScript projection — one null carries one absence level, and the source language cannot author a second; flatten the state in the core source"); return; }
    nestedOptional(ref.inner!, true, at, out);
  } else if (ref.kind === "slice") nestedOptional(ref.elem!, false, at, out);
}
export function validateFacade(s: CoreContract, plan: ProjectionPlan): Diagnostic[] {
  const out: Diagnostic[] = [];
  facadeFacts(s, plan, out); facadeNames(s, plan, out);
  walkRefs(s, (ref, at) => nestedOptional(ref, false, at, out));
  return out;
}

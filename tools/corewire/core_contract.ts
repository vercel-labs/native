// Portable semantic rules over the native decoder's complete core contract.
// The decoder owns syntax, structural defaults, and exact version spellings.
export interface TypeRef {
  kind: string;
  inner?: TypeRef;
  elem?: TypeRef;
  name?: string;
}
export interface Field { name: string; type: TypeRef }
export interface RecordType { name: string; origin: string | null; exported: boolean; fields: Field[] }
export interface EnumType { name: string; origin: string | null; exported: boolean; members: string[] }
export interface UnionType { name: string; origin: string | null; exported: boolean; arms: { name: string; member: string | null; payload: TypeRef }[] }
export interface Payload {
  kind: string; name?: string; class?: string; type?: TypeRef;
  number_field?: string; number_class?: string; bytes_field?: string;
}
export interface MsgArm { name: string; member: string | null; payload: Payload }
export interface Helper { name: string; params: TypeRef[]; returns: TypeRef; arena: boolean }
export interface CoreContract {
  wire_version: number; abi_version: number;
  types: { structs: RecordType[]; enums: EnumType[]; unions: UnionType[] };
  model: string; msg: { name: string; arms: MsgArm[]; unbound: string[] };
  model_helpers: Helper[]; model_unbound: string[];
  init_returns_cmd: boolean; update_returns_cmd: boolean;
  channels: { command_msg: boolean; frame_msg: boolean; key_msg: boolean; pinch_msg: boolean; drop_msg: boolean;
    appearance_msg: string | null; chrome_msg: string | null; env_msgs: { env: string; msg: string }[] };
  abi: { exports: string[]; snapshot_format: number };
  integer_slots: { slot: string; class: string }[];
}
export interface Diagnostic { path: string; message: string }
export interface CoreInput { sidecar: CoreContract; wire_text: string; abi_text: string; snapshot_text: string }
export function flag(out: Diagnostic[], path: string, message: string): void { out.push({ path, message }); }
export function findRecord(s: CoreContract, name: string): RecordType | null {
  for (const r of s.types.structs) if (r.name === name) return r;
  return null;
}
export function findEnum(s: CoreContract, name: string): EnumType | null {
  for (const r of s.types.enums) if (r.name === name) return r;
  return null;
}
export function findUnion(s: CoreContract, name: string): UnionType | null {
  for (const r of s.types.unions) if (r.name === name) return r;
  return null;
}
export function findArm(s: CoreContract, name: string): MsgArm | null {
  for (const r of s.msg.arms) if (r.name === name) return r;
  return null;
}
function tableKind(s: CoreContract, name: string): string {
  if (findRecord(s, name) !== null) return "struct";
  if (findEnum(s, name) !== null) return "enum";
  if (findUnion(s, name) !== null) return "union";
  return "";
}
function article(kind: string): string { return kind === "enum" ? "an" : "a"; }
function noteName(out: Diagnostic[], names: string[], name: string, at: string, what: string): void {
  if (names.includes(name)) flag(out, at, `duplicate ${what} "${name}" — V3 requires unique names here`);
  else names.push(name);
}
function names(s: CoreContract, out: Diagnostic[]): void {
  const tables: string[] = [];
  for (let i = 0; i < s.types.structs.length; i++) {
    const r = s.types.structs[i];
    noteName(out, tables, r.name, `types.structs[${i}].name`, "type-table name");
    const fields: string[] = [];
    for (let j = 0; j < r.fields.length; j++) noteName(out, fields, r.fields[j].name, `types.structs[${i}].fields[${j}].name`, "field name");
  }
  for (let i = 0; i < s.types.enums.length; i++) {
    const r = s.types.enums[i];
    noteName(out, tables, r.name, `types.enums[${i}].name`, "type-table name");
    const members: string[] = [];
    for (let j = 0; j < r.members.length; j++) noteName(out, members, r.members[j], `types.enums[${i}].members[${j}]`, "enum member");
  }
  for (let i = 0; i < s.types.unions.length; i++) {
    const r = s.types.unions[i];
    noteName(out, tables, r.name, `types.unions[${i}].name`, "type-table name");
    const arms: string[] = [];
    for (let j = 0; j < r.arms.length; j++) noteName(out, arms, r.arms[j].name, `types.unions[${i}].arms[${j}].name`, "union arm");
  }
  const arms: string[] = [], helpers: string[] = [], env: string[] = [];
  for (let i = 0; i < s.msg.arms.length; i++) noteName(out, arms, s.msg.arms[i].name, `msg.arms[${i}].name`, "message arm");
  for (let i = 0; i < s.model_helpers.length; i++) noteName(out, helpers, s.model_helpers[i].name, `model_helpers[${i}].name`, "helper name");
  for (let i = 0; i < s.channels.env_msgs.length; i++) noteName(out, env, s.channels.env_msgs[i].env, `channels.env_msgs[${i}].env`, "environment variable name");
}

class Reach {
  s: CoreContract; out: Diagnostic[]; seen: string[] = []; pending: string[] | null = null;
  constructor(s: CoreContract, out: Diagnostic[]) { this.s = s; this.out = out; }
  wrong(name: string, wanted: string, at: string): void {
    const found = tableKind(this.s, name);
    flag(this.out, at, found !== ""
      ? `"${name}" names ${article(found)} ${found} in the type table, but this reference requires ${article(wanted)} ${wanted} — V4`
      : `"${name}" names no entry in the type table (no struct, enum, or union declares it) — V4`);
  }
  check(ref: TypeRef, at: string): void {
    if (ref.kind === "optional") { this.check(ref.inner!, at); return; }
    if (ref.kind === "slice") { this.check(ref.elem!, at); return; }
    let wanted = "";
    if (ref.kind === "node" || ref.kind === "value") wanted = "struct";
    else if (ref.kind === "enum") wanted = "enum";
    else if (ref.kind === "union") wanted = "union";
    if (wanted === "") return;
    const name = ref.name!;
    if (tableKind(this.s, name) !== wanted) { this.wrong(name, wanted, at); return; }
    if (this.pending !== null) this.pending.push(name);
    else this.visit(name);
  }
  visit(root: string): void {
    const work: string[] = [root];
    while (work.length > 0) {
      const name = work.pop()!;
      if (this.seen.includes(name)) continue;
      this.seen.push(name);
      this.pending = work;
      const r = findRecord(this.s, name);
      if (r !== null) {
        for (let i = 0; i < r.fields.length; i++) this.check(r.fields[i].type, `types.structs.${name}.fields[${i}].type`);
      } else {
        const u = findUnion(this.s, name);
        if (u !== null) for (let i = 0; i < u.arms.length; i++) this.check(u.arms[i].payload, `types.unions.${name}.arms[${i}].payload`);
      }
      this.pending = null;
    }
  }
}
function references(s: CoreContract, out: Diagnostic[]): void {
  const reach = new Reach(s, out);
  if (findRecord(s, s.model) === null) {
    const found = tableKind(s, s.model);
    flag(out, "model", found !== ""
      ? `"${s.model}" names ${article(found)} ${found} in the type table, but the model root must be a struct — V4`
      : `"${s.model}" names no struct in the type table — V4`);
  } else reach.visit(s.model);
  for (let i = 0; i < s.msg.arms.length; i++) {
    const p = s.msg.arms[i].payload;
    const wanted = p.kind === "record" ? "struct" : p.kind === "union_ref" ? "union" : p.kind === "enum_ref" ? "enum" : "";
    if (wanted !== "") {
      if (tableKind(s, p.name!) !== wanted) reach.wrong(p.name!, wanted, `msg.arms[${i}].payload.name`);
      else reach.visit(p.name!);
    } else if (p.kind === "scalar") reach.check(p.type!, `msg.arms[${i}].payload.type`);
  }
  for (let i = 0; i < s.model_helpers.length; i++) {
    const h = s.model_helpers[i];
    reach.check(h.returns, `model_helpers[${i}].returns`);
    for (let j = 0; j < h.params.length; j++) reach.check(h.params[j], `model_helpers[${i}].params[${j}]`);
  }
  for (let i = 0; i < s.types.structs.length; i++) if (!reach.seen.includes(s.types.structs[i].name)) unreachable(out, "structs", i, s.types.structs[i].name);
  for (let i = 0; i < s.types.enums.length; i++) if (!reach.seen.includes(s.types.enums[i].name)) unreachable(out, "enums", i, s.types.enums[i].name);
  for (let i = 0; i < s.types.unions.length; i++) if (!reach.seen.includes(s.types.unions[i].name)) unreachable(out, "unions", i, s.types.unions[i].name);
}
function unreachable(out: Diagnostic[], table: string, i: number, name: string): void {
  flag(out, `types.${table}[${i}]`, `"${name}" is unreachable from model, msg, model_helpers, and channels — the type table lists exactly the reachable types, nothing else (V4)`);
}
interface Edge { name: string; wrap: number }
interface Shape { edges: Edge[]; leaf: number }
function measure(shape: Shape, ref: TypeRef, wrap: number): void {
  if (ref.kind === "optional") measure(shape, ref.inner!, wrap + 1);
  else if (ref.kind === "slice") measure(shape, ref.elem!, wrap + 1);
  else if (ref.kind === "node" || ref.kind === "value" || ref.kind === "union") shape.edges.push({ name: ref.name!, wrap });
  else shape.leaf = Math.max(shape.leaf, wrap + 1);
}
function shapeOf(s: CoreContract, name: string): Shape {
  const shape: Shape = { edges: [], leaf: 0 };
  const r = findRecord(s, name), u = findUnion(s, name);
  if (r !== null) for (const f of r.fields) measure(shape, f.type, 0);
  else if (u !== null) for (const a of u.arms) measure(shape, a.payload, 0);
  return shape;
}
function acyclic(s: CoreContract, out: Diagnostic[]): void {
  const states = new Map<string, number>(), depths = new Map<string, number>();
  const roots: string[] = [];
  for (const r of s.types.structs) roots.push(r.name);
  for (const u of s.types.unions) roots.push(u.name);
  let depthRefused = false;
  for (const root of roots) {
    if ((states.get(root) ?? 0) !== 0) continue;
    const stack: { name: string; shape: Shape; next: number }[] = [{ name: root, shape: shapeOf(s, root), next: 0 }];
    states.set(root, 1);
    while (stack.length > 0) {
      const top = stack[stack.length - 1];
      if (top.next < top.shape.edges.length) {
        const child = top.shape.edges[top.next].name;
        top.next++;
        const state = states.get(child) ?? 0;
        if (state === 1) {
          let cycle = "", started = false;
          for (const frame of stack) {
            if (!started && frame.name !== child) continue;
            started = true; cycle += frame.name + " -> ";
          }
          flag(out, "types", `the type reference graph has a cycle (${cycle}${child}) — recursive state types are refused at compile time and can never be encoded (V5)`);
          return;
        }
        if (state === 0) { states.set(child, 1); stack.push({ name: child, shape: shapeOf(s, child), next: 0 }); }
        continue;
      }
      let deepest = top.shape.leaf;
      for (const edge of top.shape.edges) deepest = Math.max(deepest, edge.wrap + (depths.get(edge.name) ?? 0));
      const depth = deepest + 1;
      depths.set(top.name, depth); states.set(top.name, 2);
      if (depth > 256 && !depthRefused) {
        depthRefused = true;
        flag(out, "types", `the value tree under "${top.name}" expands deeper than 256 levels (record chains and optional/slice wrapping both count) — no real contract nests state this deep, and every consumer bounds its walks; flatten the state in the core source`);
      }
      stack.pop();
    }
  }
}
function messages(s: CoreContract, out: Diagnostic[]): void {
  if (s.msg.arms.length === 0) flag(out, "msg.arms", "the message union declares no arms — a core with no messages cannot dispatch; declare at least one arm");
  if (s.msg.arms.length > 256) flag(out, "msg.arms", `${s.msg.arms.length} arms exceed the 256-arm bound (wire tags ride a u8) — V6`);
  for (let i = 0; i < s.types.unions.length; i++) {
    const u = s.types.unions[i];
    if (u.arms.length === 0) flag(out, `types.unions[${i}]`, `union "${u.name}" declares no arms — a valueless union has no mirror form; declare at least one arm`);
    if (u.arms.length > 256) flag(out, `types.unions[${i}]`, `union "${u.name}" has ${u.arms.length} arms; encoded union values carry a one-byte declaration-order arm index (256 arms at most)`);
  }
  for (let i = 0; i < s.types.enums.length; i++) {
    const e = s.types.enums[i];
    if (e.members.length === 0) flag(out, `types.enums[${i}]`, `enum "${e.name}" declares no members — a valueless enum has no mirror form; declare at least one member`);
    if (e.members.length > 256) flag(out, `types.enums[${i}]`, `enum "${e.name}" has ${e.members.length} members; the mirror's enums ride a u8 tag with member index = wire value (256 members at most)`);
  }
  for (let i = 0; i < s.msg.arms.length; i++) {
    const p = s.msg.arms[i].payload;
    if (p.kind === "number_bytes" && p.number_field === p.bytes_field)
      flag(out, `msg.arms[${i}].payload`, `number_field and bytes_field are both "${p.number_field}" — the two field names must be distinct (V7)`);
    if (p.kind === "scalar" && p.type!.kind === "void") flag(out, `msg.arms[${i}].payload.type`, "a scalar descriptor cannot carry void — bare arms use the void descriptor kind (V7)");
    if (p.kind === "scalar" && (p.type!.kind === "node" || p.type!.kind === "value")) flag(out, `msg.arms[${i}].payload.type`, "a scalar descriptor cannot carry a record — record payloads use the record descriptor kind (V7)");
  }
}
function flagVoid(ref: TypeRef, at: string, out: Diagnostic[]): void {
  if (ref.kind === "void") flag(out, at, "the void TypeRef carries no value and is legal only as a bare union arm payload — this slot needs a value type");
  else if (ref.kind === "optional") flagVoid(ref.inner!, at, out);
  else if (ref.kind === "slice") flagVoid(ref.elem!, at, out);
}
export function walkRefs(s: CoreContract, visit: (ref: TypeRef, at: string) => void): void {
  for (let i = 0; i < s.types.structs.length; i++) for (let j = 0; j < s.types.structs[i].fields.length; j++) visit(s.types.structs[i].fields[j].type, `types.structs[${i}].fields[${j}].type`);
  for (let i = 0; i < s.types.unions.length; i++) for (let j = 0; j < s.types.unions[i].arms.length; j++) visit(s.types.unions[i].arms[j].payload, `types.unions[${i}].arms[${j}].payload`);
  for (let i = 0; i < s.model_helpers.length; i++) {
    visit(s.model_helpers[i].returns, `model_helpers[${i}].returns`);
    for (let j = 0; j < s.model_helpers[i].params.length; j++) visit(s.model_helpers[i].params[j], `model_helpers[${i}].params[${j}]`);
  }
  for (let i = 0; i < s.msg.arms.length; i++) if (s.msg.arms[i].payload.kind === "scalar") visit(s.msg.arms[i].payload.type!, `msg.arms[${i}].payload.type`);
}
function voidPositions(s: CoreContract, out: Diagnostic[]): void {
  walkRefs(s, (ref, at) => { if (ref.kind !== "void" || !at.startsWith("types.unions[")) flagVoid(ref, at, out); });
}
function unbound(s: CoreContract, out: Diagnostic[]): void {
  const model = findRecord(s, s.model);
  if (model === null) return;
  for (let i = 0; i < s.model_unbound.length; i++) {
    const name = s.model_unbound[i];
    if (!model.fields.some(f => f.name === name) && !s.model_helpers.some(h => h.name === name)) flag(out, `model_unbound[${i}]`, `"${name}" is neither a field of the model struct "${s.model}" nor an exported helper (V8)`);
  }
  for (let i = 0; i < s.msg.unbound.length; i++) if (findArm(s, s.msg.unbound[i]) === null) flag(out, `msg.unbound[${i}]`, `"${s.msg.unbound[i]}" is not an arm of the message union (V8)`);
}
function channels(s: CoreContract, out: Diagnostic[]): void {
  for (const channel of [{ name: "appearance_msg", arm: s.channels.appearance_msg }, { name: "chrome_msg", arm: s.channels.chrome_msg }]) {
    const name = channel.arm;
    if (name === null) continue;
    const arm = findArm(s, name);
    if (arm === null) flag(out, `channels.${channel.name}`, `"${name}" names no arm of the message union (V9)`);
    else if (!["record", "union_ref", "enum_ref", "scalar"].includes(arm.payload.kind)) flag(out, `channels.${channel.name}`, `arm "${name}" has a ${arm.payload.kind} payload descriptor, but this channel requires the named-type family (record/union/enum/scalar) — the host constructs the arm's payload itself, so it must learn the shape from the type table (V9)`);
  }
  for (let i = 0; i < s.channels.env_msgs.length; i++) {
    const name = s.channels.env_msgs[i].msg, arm = findArm(s, name);
    if (arm === null) flag(out, `channels.env_msgs[${i}].msg`, `"${name}" names no arm of the message union (V9)`);
    else if (arm.payload.kind !== "bytes") flag(out, `channels.env_msgs[${i}].msg`, `arm "${name}" has a ${arm.payload.kind} payload descriptor, but environment channels deliver the variable's value as bytes, so the target arm's descriptor must be bytes (V9)`);
  }
  for (const channel of [{ name: "command_msg", wired: s.channels.command_msg }, { name: "frame_msg", wired: s.channels.frame_msg }, { name: "key_msg", wired: s.channels.key_msg }, { name: "pinch_msg", wired: s.channels.pinch_msg }, { name: "drop_msg", wired: s.channels.drop_msg }]) {
    const listed = s.abi.exports.includes(channel.name);
    if (channel.wired && !listed) flag(out, `channels.${channel.name}`, `the channel is declared wired but "${channel.name}" is missing from abi.exports — presence is biconditional (V9)`);
    if (!channel.wired && listed) flag(out, "abi.exports", `"${channel.name}" is listed but channels.${channel.name} is false — presence is biconditional (V9)`);
  }
}
export const unconditionalExports = ["abi_version", "build_id", "set_panic_sink", "init", "collect", "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number", "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record", "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot", "persist_snapshot", "restore_model", "migrate_model", "helper_call"];
export const conditionalExports = ["command_msg", "frame_msg", "key_msg", "pinch_msg", "drop_msg", "native_view", "native_window_view", "native_media_view", "native_media_window_view", "native_radio_policy", "native_tabs_policy", "native_tree_policy", "native_list_policy", "native_menu_policy", "native_toggle_policy", "native_accordion_policy", "native_slider_policy", "native_split_policy", "native_scroll_policy", "native_resizable_policy", "native_text_policy", "native_timer_policy", "native_db_policy", "native_effect_policy", "native_stream_policy", "native_window_policy", "native_theme_policy", "native_status_policy"];
function abi(s: CoreContract, out: Diagnostic[]): void {
  let cursor = 0;
  for (const name of unconditionalExports) {
    if (s.abi.exports[cursor] === name) cursor++;
    else { flag(out, `abi.exports[${cursor}]`, `expected the unconditional export "${name}" here — abi.exports lists every unconditional suffix, then the wired channel entries, in the canonical order: identity getters (abi_version, build_id), the mode-provided entries (set_panic_sink, init, collect, frame_reset), then the entry-point map (V11)`); return; }
  }
  for (const name of conditionalExports) if (s.abi.exports[cursor] === name) cursor++;
  if (cursor < s.abi.exports.length) flag(out, `abi.exports[${cursor}]`, `"${s.abi.exports[cursor]}" is not an export suffix of ABI version 2 (or is out of canonical order) — V11`);
}
function spellsInteger(ref: TypeRef): boolean { return ref.kind === "i64" || (ref.kind === "optional" && spellsInteger(ref.inner!)); }
function wrapsInteger(ref: TypeRef): boolean { return ref.kind === "i64" || (ref.kind === "optional" && wrapsInteger(ref.inner!)) || (ref.kind === "slice" && wrapsInteger(ref.elem!)); }
interface SlotPath { path: string; dotted: boolean }
function integerPaths(s: CoreContract): SlotPath[] {
  const paths: SlotPath[] = [];
  function add(parts: string[]): void { paths.push({ path: parts.join("."), dotted: parts.some(p => p.includes(".")) }); }
  for (const r of s.types.structs) for (const f of r.fields) if (spellsInteger(f.type)) add([r.name, f.name]);
  for (const u of s.types.unions) for (const a of u.arms) if (spellsInteger(a.payload)) add([u.name, a.name]);
  for (const a of s.msg.arms) {
    const p = a.payload;
    if (p.kind === "number" && p.class === "i64") add([s.msg.name, a.name]);
    else if (p.kind === "number_bytes" && p.number_class === "i64") add([s.msg.name, a.name, p.number_field!]);
    else if (p.kind === "scalar" && spellsInteger(p.type!)) add([s.msg.name, a.name]);
  }
  for (const h of s.model_helpers) {
    if (spellsInteger(h.returns)) paths.push({ path: `helpers.${h.name}.return`, dotted: h.name.includes(".") });
    for (let i = 0; i < h.params.length; i++) if (spellsInteger(h.params[i])) paths.push({ path: `helpers.${h.name}.params[${i}]`, dotted: h.name.includes(".") });
  }
  return paths;
}
interface SlotTarget { kind: string; spelling: string }
function target(kind: string, spelling = ""): SlotTarget { return { kind, spelling }; }
function classify(ref: TypeRef): SlotTarget {
  if (ref.kind === "i64") return target("integer");
  if (ref.kind === "optional") return classify(ref.inner!);
  if (ref.kind === "slice") return wrapsInteger(ref.elem!) ? target("slice_element") : target("not_integer", "a slice");
  const spelling = ref.kind === "node" || ref.kind === "value" ? "a record" : ref.kind === "enum" ? "an enum" : ref.kind === "union" ? "a union" : ref.kind;
  return target("not_integer", spelling);
}
function numberTarget(kind: string): SlotTarget { return kind === "i64" ? target("integer") : target("not_integer", "f64"); }
function parameterIndex(digits: string, bound: number): number {
  // Match the native unsigned decimal parser, including its optional plus
  // and separators. Values at/above the actual array bound cannot resolve.
  const negative = digits.startsWith("-");
  let i = digits.startsWith("+") || negative ? 1 : 0, value = 0, saw = false;
  if (i === digits.length || digits.endsWith("_")) return -1;
  for (; i < digits.length; i++) {
    const c = digits.charCodeAt(i);
    if (c === 95 && saw) continue;
    if (c < 48 || c > 57) return -1;
    saw = true; value = value * 10 + c - 48;
    if (value >= bound) return -1;
  }
  return saw && (!negative || value === 0) ? value : -1;
}
export function resolveSlot(s: CoreContract, path: string): SlotTarget {
  const parts = path.split(".");
  if (parts.length > 4 || parts.some(p => p.length === 0)) return target("unresolved");
  if (parts.length === 3 && parts[0] === "helpers") {
    for (const h of s.model_helpers) if (h.name === parts[1]) {
      if (parts[2] === "return") return classify(h.returns);
      if (parts[2].startsWith("params[") && parts[2].endsWith("]")) {
        const index = parameterIndex(parts[2].slice(7, -1), h.params.length);
        if (index >= 0) return classify(h.params[index]);
      }
      return target("unresolved");
    }
    return target("unresolved");
  }
  if (parts[0] === s.msg.name) {
    const a = findArm(s, parts[1]);
    if (parts.length === 2 && a !== null) {
      const p = a.payload;
      if (p.kind === "number") return numberTarget(p.class!);
      if (p.kind === "scalar") return classify(p.type!);
      return target("not_integer", p.kind === "record" ? "a record" : p.kind === "union_ref" ? "a union" : p.kind === "enum_ref" ? "an enum" : p.kind === "number_bytes" ? "a number_bytes record (its number field is the slot)" : p.kind);
    }
    if (parts.length === 3) {
      if (a !== null && a.payload.kind === "number_bytes") {
        if (parts[2] === a.payload.number_field) return numberTarget(a.payload.number_class!);
        if (parts[2] === a.payload.bytes_field) return target("not_integer", "bytes");
      }
      return target("unresolved");
    }
  }
  if (parts.length === 2) {
    const r = findRecord(s, parts[0]);
    if (r !== null) { for (const f of r.fields) if (f.name === parts[1]) return classify(f.type); return target("unresolved"); }
    const u = findUnion(s, parts[0]);
    if (u !== null) for (const a of u.arms) if (a.name === parts[1]) return classify(a.payload);
  }
  return target("unresolved");
}
function integerSlots(s: CoreContract, out: Diagnostic[]): void {
  const expected = integerPaths(s);
  for (const p of expected) if (p.dotted) flag(out, "integer_slots", `the i64 slot at "${p.path}" involves a name containing '.', which the slot path grammar cannot address unambiguously — rename it in the core source (V10)`);
  for (let i = 0; i < expected.length; i++) for (let j = 0; j < i; j++) if (expected[i].path === expected[j].path) flag(out, "integer_slots", `two distinct i64 slots spell the one path "${expected[i].path}" — the slot-path grammar cannot address them separately, so their attestations cannot be told apart; rename one of the colliding surfaces in the core source (V10)`);
  if (out.length > 0) return;
  const consumed = s.integer_slots.map(() => false);
  for (const p of expected) {
    let found = false;
    for (let i = 0; i < s.integer_slots.length; i++) if (!consumed[i] && s.integer_slots[i].slot === p.path) { consumed[i] = true; found = true; break; }
    if (!found) flag(out, "integer_slots", `the sidecar spells "${p.path}" i64 but attests no integer_slots entry for it — every i64 spelling has exactly one entry (V10)`);
  }
  for (let i = 0; i < s.integer_slots.length; i++) {
    if (consumed[i]) continue;
    const name = s.integer_slots[i].slot, at = `integer_slots[${i}].slot`;
    if (s.integer_slots.slice(0, i).some(p => p.slot === name)) { flag(out, at, `duplicate entry for "${name}" — every i64 slot has exactly one entry (V10)`); continue; }
    const t = resolveSlot(s, name);
    if (t.kind === "integer") flag(out, at, `"${name}" resolves to no slot the sidecar spells i64 — every entry must name a real i64 slot (V10)`);
    else if (t.kind === "not_integer") flag(out, at, `"${name}" resolves to a slot the sidecar spells ${t.spelling}, not i64 — an attested integer class must sit on an i64 spelling (V10)`);
    else if (t.kind === "slice_element") flag(out, at, `"${name}" addresses a sequence — the format-1 slot-path grammar has no slice-element form, so slice elements are never integer-attested; the emitter spells them f64 and readers exempt them from the bijection (V10)`);
    else flag(out, at, `"${name}" resolves against none of the sidecar's own tables — slot paths name a record field or union arm (<Type>.<name>), a message payload ("${s.msg.name}.<arm>" or "${s.msg.name}.<arm>.<numberField>"), or a helper signature slot (helpers.<name>.return, helpers.<name>.params[<index>]) (V10)`);
  }
}
export function validateCore(input: CoreInput): Diagnostic[] {
  const s = input.sidecar, out: Diagnostic[] = [];
  if (s.wire_version !== 8) flag(out, "wire_version", `this SDK's command-wire vocabulary is generation 8, the sidecar declares ${input.wire_text} — the compiled core's effect builders speak a different wire; upgrade the SDK or pin the compiler release that matches it`);
  if (s.abi_version !== 2) flag(out, "abi_version", `this generator binds core ABI version 2, the sidecar declares ${input.abi_text} — upgrade the SDK or pin the compiler release that matches it`);
  if (s.abi.snapshot_format !== 1) flag(out, "abi.snapshot_format", `this generator decodes snapshot format 1, the sidecar declares ${input.snapshot_text} — upgrade the SDK or pin the compiler release that matches it`);
  names(s, out);
  if (out.length > 0) return out;
  references(s, out);
  if (out.length > 0) return out;
  acyclic(s, out); messages(s, out); voidPositions(s, out); unbound(s, out); channels(s, out); abi(s, out); integerSlots(s, out);
  return out;
}

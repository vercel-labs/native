// Portable code emission consumes complete facts from the structural reader.
import type { CoreContract, CoreInput, Diagnostic, TypeRef, RecordType } from "./core_contract.ts";
import { findRecord, findEnum, findUnion } from "./core_contract.ts";
import { zigKeywords, zigPrimitives } from "./core_vocabulary.ts";

export interface EmissionContract extends CoreContract {
  format: number; compiler_version: string; entry: string;
  deterministic: boolean; async_free: boolean;
  has_subscriptions: boolean; has_migrate: boolean;
  init_returns_bare: boolean; update_returns_bare: boolean;
  abi: CoreContract["abi"] & { prefix: string };
}
export interface EmissionInput extends CoreInput {
  sidecar: EmissionContract;
  build_id_hex: string;
  model_fingerprint_hex: string;
}
export interface EmissionResult { output: string; diagnostics: Diagnostic[] }

// Formatting arguments are already exact strings. In particular, u64
// identities never cross a JavaScript-number conversion.
export function formatCode(text: string, args: string[]): string {
  let out = "", argument = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charAt(i);
    if (c === "{" && text.charAt(i + 1) === "{") { out += "{"; i++; }
    else if (c === "}" && text.charAt(i + 1) === "}") { out += "}"; i++; }
    else if (c === "{") {
      const end = text.indexOf("}", i + 1);
      if (end < 0 || argument >= args.length) throw new Error("invalid code template");
      out += args[argument++]; i = end;
    } else out += c;
  }
  if (argument !== args.length) throw new Error("unused code template argument");
  return out;
}
export class CodeWriter {
  out: string = "";
  raw(text: string): void { this.out += text; }
  print(text: string, args: string[]): void { this.out += formatCode(text, args); }
}
export function commentText(text: string): string {
  return text.replace(/[\x00-\x1f\x7f]/g, " ").replace(/[\u2028\u2029]/g, "   ");
}
export function zigString(text: string): string {
  let out = "";
  const hex = "0123456789abcdef";
  const bytes = new TextEncoder().encode(text);
  for (const b of bytes) {
    if (b === 10) out += "\\n";
    else if (b === 13) out += "\\r";
    else if (b === 9) out += "\\t";
    else if (b === 92) out += "\\\\";
    else if (b === 34) out += '\\"';
    else if (b >= 32 && b <= 126) out += String.fromCharCode(b);
    else out += "\\x" + hex.charAt(b >> 4) + hex.charAt(b & 15);
  }
  return out;
}
export function zigIdent(name: string): string {
  const plain = /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && name !== "_"
    && !zigKeywords.includes(name) && !zigPrimitives.includes(name)
    && !/^[iu][0-9]+$/.test(name);
  return plain ? name : '@"' + zigString(name) + '"';
}
export function synthesized(container: string, member: string, name: string): boolean {
  return name === container + "_" + member;
}
export const scrollFields = [
  ["offsetX", "offsetY", "velocityX", "velocityY", "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY"],
  ["offset_x", "offset_y", "velocity_x", "velocity_y", "viewport_extent_x", "viewport_extent_y", "content_extent_x", "content_extent_y"],
];
export function scrollIndexes(s: CoreContract, name: string): number[] | null {
  const r = findRecord(s, name);
  if (r === null || r.fields.length !== 8) return null;
  for (const names of scrollFields) {
    const indexes: number[] = [];
    for (const name of names) {
      const index = r.fields.findIndex(f => f.name === name && (f.type.kind === "f64" || f.type.kind === "i64"));
      if (index < 0) break;
      indexes.push(index);
    }
    if (indexes.length === 8) return indexes;
  }
  return null;
}
function valueRecord(s: CoreContract, ref: TypeRef): RecordType | null {
  return ref.kind === "value" ? findRecord(s, ref.name!) : null;
}
function numeric(ref: TypeRef): boolean { return ref.kind === "f64" || ref.kind === "i64"; }
export function isTextInputUnion(s: CoreContract, name: string): boolean {
  const entry = findUnion(s, name);
  const tags = ["insert_text", "delete_backward", "delete_forward", "delete_word_backward", "delete_word_forward",
    "delete_to_start", "delete_to_line_start", "clear", "move_caret", "set_selection", "set_composition",
    "commit_composition", "cancel_composition"];
  if (entry === null || entry.arms.length !== tags.length || !tags.every(t => entry.arms.some(a => a.name === t))) return false;
  for (const arm of entry.arms) {
    if (arm.name === "insert_text") { if (arm.payload.kind !== "bytes") return false; }
    else if (arm.name === "move_caret") {
      const r = valueRecord(s, arm.payload); if (r === null || r.fields.length !== 2) return false;
      let direction = false, extend = false;
      for (const f of r.fields) {
        if (f.name === "extend") extend = f.type.kind === "bool";
        else if (f.name === "direction") {
          const e = f.type.kind === "enum" ? findEnum(s, f.type.name!) : null;
          const members = ["previous", "next", "previous_word", "next_word", "start", "end"];
          direction = e !== null && e.members.length === members.length && members.every(m => e.members.includes(m));
        }
      }
      if (!direction || !extend) return false;
    } else if (arm.name === "set_selection") {
      const r = valueRecord(s, arm.payload);
      if (r === null || r.fields.length !== 2
        || !["anchor", "focus"].every(n => r.fields.some(f => f.name === n && numeric(f.type)))) return false;
    } else if (arm.name === "set_composition") {
      const r = valueRecord(s, arm.payload); if (r === null || r.fields.length !== 2) return false;
      let text = false, cursor = false;
      for (const f of r.fields) {
        if (f.name === "text") text = f.type.kind === "bytes";
        else if (f.name === "cursor") cursor = f.type.kind === "optional" && numeric(f.type.inner!);
      }
      if (!text || !cursor) return false;
    } else if (arm.payload.kind !== "void") return false;
  }
  return true;
}
export function tsString(text: string): string {
  return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}
export function tsProp(name: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) ? name : '"' + tsString(name) + '"';
}
export function tsAccess(base: string, name: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) ? base + "." + name : base + '["' + tsString(name) + '"]';
}

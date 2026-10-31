// A lossless tree over canonical JSON from the structural decoder. Scalar
// lexemes retain exact native numeric spellings and complete additive fields.
export interface Member { key: string; name: string; value: JsonNode }
export interface JsonNode { kind: string; literal: string; members: Member[]; items: JsonNode[] }
export class Parser {
  source: string; at = 0;
  constructor(source: string) { this.source = source; }
  space(): void { while (/\s/.test(this.source.charAt(this.at)) && this.at < this.source.length) this.at++; }
  quoted(): string {
    const start = this.at++;
    while (this.at < this.source.length) {
      const ch = this.source.charAt(this.at++);
      if (ch === '"') return this.source.slice(start, this.at);
      if (ch === "\\") this.at++;
    }
    throw new Error("unterminated canonical JSON string");
  }
  node(): JsonNode {
    this.space(); const ch = this.source.charAt(this.at);
    const result: JsonNode = { kind: "scalar", literal: "", members: [], items: [] };
    if (ch === '"') { result.literal = this.quoted(); return result; }
    if (ch === "{" || ch === "[") {
      this.at++; result.kind = ch === "{" ? "object" : "array";
      this.space(); const close = ch === "{" ? "}" : "]";
      if (this.source.charAt(this.at) === close) { this.at++; return result; }
      while (this.at < this.source.length) {
        this.space();
        if (ch === "{") {
          const key = this.quoted(); this.space();
          if (this.source.charAt(this.at++) !== ":") throw new Error("invalid canonical JSON member");
          const name = JSON.parse(key) as string;
          result.members.push({ key, name, value: this.node() });
        } else result.items.push(this.node());
        this.space(); const next = this.source.charAt(this.at++);
        if (next === close) return result;
        if (next !== ",") throw new Error("invalid canonical JSON container");
      }
      throw new Error("unterminated canonical JSON container");
    }
    const start = this.at;
    while (this.at < this.source.length && !/[\s,}\]]/.test(this.source.charAt(this.at))) this.at++;
    if (start === this.at) throw new Error("invalid canonical JSON scalar");
    result.literal = this.source.slice(start, this.at); return result;
  }
}
function member(node: JsonNode, name: string): JsonNode {
  for (const entry of node.members) if (entry.name === name) return entry.value;
  throw new Error("effective-sidecar structural drift");
}
function string(node: JsonNode): string { return JSON.parse(node.literal) as string; }
function bytesEqual(text: string, raw: number[]): boolean {
  const encoded = new TextEncoder().encode(text);
  if (encoded.length !== raw.length) return false;
  for (let i = 0; i < raw.length; i++) if (encoded[i] !== raw[i]) return false;
  return true;
}
export function render(node: JsonNode, depth: number): string {
  if (node.kind === "scalar") return node.literal;
  const object = node.kind === "object", length = object ? node.members.length : node.items.length;
  const open = object ? "{" : "[", close = object ? "}" : "]";
  if (length === 0) return open + close;
  let out = open + "\n";
  for (let i = 0; i < length; i++) {
    out += "  ".repeat(depth + 1);
    if (object) out += node.members[i].key + ": " + render(node.members[i].value, depth + 1);
    else out += render(node.items[i], depth + 1);
    out += (i + 1 === length ? "" : ",") + "\n";
  }
  return out + "  ".repeat(depth) + close;
}
export function rewriteEffective(source: string, slots: number[][]): string {
  const parser = new Parser(source), root = parser.node();
  parser.space(); if (parser.at !== source.length) throw new Error("trailing canonical JSON input");
  const records = member(member(root, "types"), "structs").items;
  for (const slot of slots) {
    let changed = false;
    for (const record of records) {
      const container = string(member(record, "name"));
      for (const field of member(record, "fields").items) {
        if (!bytesEqual(container + "." + string(member(field, "name")), slot)) continue;
        const type = member(field, "type"), kind = member(type, "kind");
        const target = string(kind) === "optional" ? member(member(type, "inner"), "kind") : kind;
        target.literal = '"f64"'; changed = true; break;
      }
      if (changed) break;
    }
    if (!changed) throw new Error("effective-sidecar projection drift");
  }
  const attestations = member(root, "integer_slots");
  attestations.items = attestations.items.filter(entry => !slots.some(slot => bytesEqual(string(member(entry, "slot")), slot)));
  return render(root, 0) + "\n";
}
export function projectEffective(input: string): string {
  const facts = JSON.parse(input) as { canonical_source: string; slots: number[][] };
  return rewriteEffective(facts.canonical_source, facts.slots);
}

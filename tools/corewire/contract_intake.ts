// Schema intake over lossless JSON facts. Native supplies syntax and exact
// number lexemes; TypeScript owns field admission, defaults and diagnostics.
import { Parser, render } from "./lossless_projection.ts";
import type { JsonNode } from "./lossless_projection.ts";

export interface IntakeDiagnostic { path: string; message: string; severity: string }
export interface IntakeResult { normalized: string; diagnostics: IntakeDiagnostic[] }
class Refusal extends Error {}
function scalar(literal: string): JsonNode { return { kind: "scalar", literal, members: [], items: [] }; }
function object(fields: { name: string; value: JsonNode }[]): JsonNode {
  return { kind: "object", literal: "", items: [], members: fields.map(f => ({ name: f.name, key: JSON.stringify(f.name), value: f.value })) };
}
function array(items: JsonNode[]): JsonNode { return { kind: "array", literal: "", members: [], items }; }
class CoreMapper {
  diagnostics: IntakeDiagnostic[] = [];
  fail(path: string, message: string): never { this.diagnostics.push({ path, message, severity: "error" }); throw new Refusal(); }
  kind(v: JsonNode): string {
    if (v.kind === "object") return "an object";
    if (v.kind === "array") return "an array";
    if (v.literal === "null") return "null";
    if (v.literal === "true" || v.literal === "false") return "a boolean";
    return v.literal.startsWith('"') ? "a string" : "a number";
  }
  members(v: JsonNode, at: string, known: string[]): JsonNode {
    if (v.kind !== "object") this.fail(at, `expected an object, found ${this.kind(v)}`);
    for (const f of v.members) if (!known.includes(f.name)) this.diagnostics.push({ path: this.path(at, f.name), message: "unknown field ignored (an emitter newer than this reader may emit additive facts)", severity: "warning" });
    return v;
  }
  path(at: string, name: string): string { return at === "" ? name : at + "." + name; }
  maybe(v: JsonNode, name: string): JsonNode | null { for (const f of v.members) if (f.name === name) return f.value; return null; }
  get(v: JsonNode, name: string, at: string): JsonNode { const f = this.maybe(v, name); if (f === null) this.fail(this.path(at, name), "required field missing"); return f; }
  text(v: JsonNode, at: string, nonempty = true): string {
    if (!v.literal.startsWith('"')) this.fail(at, `expected a string, found ${this.kind(v)}`);
    const text = JSON.parse(v.literal) as string;
    if (nonempty && text.length === 0) this.fail(at, "expected a non-empty string");
    return text;
  }
  bool(v: JsonNode, at: string): JsonNode {
    if (v.literal !== "true" && v.literal !== "false") this.fail(at, `expected true or false, found ${this.kind(v)}`);
    return v;
  }
  integer(v: JsonNode, at: string): JsonNode {
    const negative = v.literal.startsWith("-"), digits = negative ? v.literal.slice(1) : v.literal;
    const bound = negative ? "9223372036854775808" : "9223372036854775807";
    if (v.literal === "-0" || !/^-?[0-9]+$/.test(v.literal) || digits.length > 19 || (digits.length === 19 && digits > bound)) this.fail(at, `expected an integer, found ${this.kind(v)}`);
    return v;
  }
  list(v: JsonNode, at: string): JsonNode[] { if (v.kind !== "array") this.fail(at, `expected an array, found ${this.kind(v)}`); return v.items; }
  strings(v: JsonNode, at: string): JsonNode { return array(this.list(v, at).map((f, i) => { this.text(f, `${at}[${i}]`); return f; })); }
  optional(v: JsonNode, name: string, at: string, boolean: boolean): JsonNode {
    const f = this.maybe(v, name); if (f === null) return scalar(boolean ? "true" : "null");
    if (boolean) return this.bool(f, this.path(at, name));
    this.text(f, this.path(at, name)); return f;
  }
  type(v: JsonNode, at: string, depth = 0): JsonNode {
    if (depth > 256) this.fail(at, "TypeRef nesting exceeds 256 levels — no real contract wraps a slot this deep; flatten the state in the core source");
    if (v.kind !== "object") this.fail(at, `expected an object, found ${this.kind(v)}`);
    const k = this.maybe(v, "kind");
    if (k === null) this.fail(at + ".kind", "required field missing (every TypeRef carries a kind discriminator)");
    const kind = this.text(k, at + ".kind", false);
    if (["bool", "f64", "i64", "bytes", "void"].includes(kind)) { this.members(v, at, ["kind"]); return object([{ name: kind, value: object([]) }]); }
    if (kind === "optional" || kind === "slice") {
      const field = kind === "optional" ? "inner" : "elem";
      this.members(v, at, ["kind", field]);
      return object([{ name: kind, value: this.type(this.get(v, field, at), at + "." + field, depth + 1) }]);
    }
    if (["node", "value", "enum", "union"].includes(kind)) {
      this.members(v, at, ["kind", "name"]); const name = this.get(v, "name", at); this.text(name, at + ".name");
      return object([{ name: kind === "enum" || kind === "union" ? kind + "_ref" : kind, value: name }]);
    }
    this.fail(at + ".kind", `unknown TypeRef kind "${kind}" — this reader is too old for this sidecar; upgrade the SDK tooling or pin the compiler release it was built for`);
  }
  numberClass(v: JsonNode, at: string, integer: boolean): JsonNode {
    const text = this.text(v, at, false);
    if (text === "i64" || text === (integer ? "u64" : "f64")) return v;
    if (integer && text === "f64") this.fail(at, 'integer_slots records the compiler\'s integer-class verdicts; class "f64" has no place here (f64 is the default class and is never attested)');
    this.fail(at, integer ? `unknown integer class "${text}" — the format-1 classes are "i64" and "u64"; this reader is too old for anything else` : `unknown number class "${text}" — the v1 classes are "f64" and "i64"; this reader is too old for anything else`);
  }
  payload(v: JsonNode, at: string): JsonNode {
    if (v.kind !== "object") this.fail(at, `expected an object, found ${this.kind(v)}`);
    const k = this.maybe(v, "kind"); if (k === null) this.fail(at + ".kind", "required field missing (every payload descriptor carries a kind discriminator)");
    const kind = this.text(k, at + ".kind", false);
    if (kind === "void" || kind === "bytes") { this.members(v, at, ["kind"]); return object([{ name: kind, value: object([]) }]); }
    if (kind === "number") { this.members(v, at, ["kind", "class"]); return object([{ name: kind, value: this.numberClass(this.get(v, "class", at), at + ".class", false) }]); }
    if (kind === "number_bytes") {
      this.members(v, at, ["kind", "number_field", "number_class", "bytes_field"]);
      const fields = ["number_field", "number_class", "bytes_field"].map(name => { const value = this.get(v, name, at); if (name === "number_class") this.numberClass(value, at + "." + name, false); else this.text(value, at + "." + name); return { name, value }; });
      return object([{ name: kind, value: object(fields) }]);
    }
    if (["record", "union", "enum"].includes(kind)) { this.members(v, at, ["kind", "name"]); const name = this.get(v, "name", at); this.text(name, at + ".name"); return object([{ name: kind === "record" ? kind : kind + "_ref", value: name }]); }
    if (kind === "scalar") { this.members(v, at, ["kind", "type"]); return object([{ name: kind, value: this.type(this.get(v, "type", at), at + ".type") }]); }
    this.fail(at + ".kind", `unknown payload descriptor kind "${kind}" — this reader is too old for this sidecar; upgrade the SDK tooling or pin the compiler release it was built for (half-understanding a message arm is how wrong dispatch ships)`);
  }
  fields(v: JsonNode, at: string): JsonNode {
    return array(this.list(v, at).map((f, i) => {
      const p = `${at}[${i}]`; this.members(f, p, ["name", "type"]);
      const name = this.get(f, "name", p); this.text(name, p + ".name");
      return object([{ name: "name", value: name }, { name: "type", value: this.type(this.get(f, "type", p), p + ".type") }]);
    }));
  }
  types(v: JsonNode): JsonNode {
    this.members(v, "types", ["structs", "enums", "unions"]);
    return object(["structs", "enums", "unions"].map(table => {
      const at = "types." + table;
      return { name: table, value: array(this.list(this.get(v, table, "types"), at).map((item, i) => {
        const p = `${at}[${i}]`, tail = table === "structs" ? "fields" : table === "enums" ? "members" : "arms";
        this.members(item, p, ["name", "origin", "exported", ...(table === "structs" ? ["synthesized"] : []), tail]);
        // The native record reader admits fields before the record's name.
        let content: JsonNode;
        if (table === "structs") content = this.fields(this.get(item, tail, p), p + "." + tail);
        else if (table === "unions") content = array(this.list(this.get(item, tail, p), p + "." + tail).map((arm, j) => {
          const q = `${p}.arms[${j}]`; this.members(arm, q, ["name", "member", "payload"]);
          const name = this.get(arm, "name", q); this.text(name, q + ".name");
          const member = this.optional(arm, "member", q, false);
          return object([{ name: "name", value: name }, { name: "member", value: member }, { name: "payload", value: this.type(this.get(arm, "payload", q), q + ".payload") }]);
        }));
        else content = scalar("null");
        const name = this.get(item, "name", p); this.text(name, p + ".name");
        const origin = this.optional(item, "origin", p, false), exported = this.optional(item, "exported", p, true);
        if (table === "enums") content = this.strings(this.get(item, tail, p), p + "." + tail);
        return object([{ name: "name", value: name }, { name: "origin", value: origin }, { name: "exported", value: exported }, { name: tail, value: content }]);
      })) };
    }));
  }
  helpers(v: JsonNode): JsonNode {
    return array(this.list(v, "model_helpers").map((item, i) => {
      const p = `model_helpers[${i}]`; this.members(item, p, ["name", "params", "returns", "arena"]);
      const params = array(this.list(this.get(item, "params", p), p + ".params").map((r, j) => this.type(r, `${p}.params[${j}]`)));
      const name = this.get(item, "name", p); this.text(name, p + ".name");
      return object([{ name: "name", value: name }, { name: "params", value: params }, { name: "returns", value: this.type(this.get(item, "returns", p), p + ".returns") }, { name: "arena", value: this.bool(this.get(item, "arena", p), p + ".arena") }]);
    }));
  }
  msg(v: JsonNode): JsonNode {
    this.members(v, "msg", ["name", "arms", "unbound"]);
    const arms = array(this.list(this.get(v, "arms", "msg"), "msg.arms").map((arm, i) => {
      const p = `msg.arms[${i}]`; this.members(arm, p, ["name", "member", "payload"]);
      const name = this.get(arm, "name", p); this.text(name, p + ".name");
      const member = this.optional(arm, "member", p, false);
      return object([{ name: "name", value: name }, { name: "member", value: member }, { name: "payload", value: this.payload(this.get(arm, "payload", p), p + ".payload") }]);
    }));
    const name = this.get(v, "name", "msg"); this.text(name, "msg.name");
    return object([{ name: "name", value: name }, { name: "arms", value: arms }, { name: "unbound", value: this.strings(this.get(v, "unbound", "msg"), "msg.unbound") }]);
  }
  abi(v: JsonNode): JsonNode {
    this.members(v, "abi", ["prefix", "exports", "snapshot_format"]);
    const prefix = this.get(v, "prefix", "abi"), text = this.text(prefix, "abi.prefix"), bytes = new TextEncoder().encode(text);
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      if (b !== 95 && !(b >= 65 && b <= 90) && !(b >= 97 && b <= 122) && !(i > 0 && b >= 48 && b <= 57))
        this.fail("abi.prefix", `byte 0x${b.toString(16).padStart(2, "0")} at offset ${i} cannot appear in a linker symbol name — the prefix is spelled verbatim into every exported symbol; use ASCII letters, digits, and underscores, not starting with a digit`);
    }
    return object([{ name: "prefix", value: prefix }, { name: "exports", value: this.strings(this.get(v, "exports", "abi"), "abi.exports") }, { name: "snapshot_format", value: this.integer(this.get(v, "snapshot_format", "abi"), "abi.snapshot_format") }]);
  }
  channels(v: JsonNode, abi: JsonNode): JsonNode {
    this.members(v, "channels", ["command_msg", "command_bytes", "frame_msg", "key_msg", "pinch_msg", "drop_msg", "appearance_msg", "chrome_msg", "env_msgs"]);
    const env = array(this.list(this.get(v, "env_msgs", "channels"), "channels.env_msgs").map((item, i) => {
      const p = `channels.env_msgs[${i}]`; this.members(item, p, ["env", "msg"]);
      return object(["env", "msg"].map(name => { const value = this.get(item, name, p); this.text(value, p + "." + name); return { name, value }; }));
    }));
    const fields = ["command_msg", "command_bytes", "frame_msg", "key_msg", "pinch_msg", "drop_msg"].map(name => {
      let value = this.maybe(v, name);
      if ((name === "command_bytes" || name === "drop_msg") && value === null) value = scalar(name === "drop_msg" && this.get(abi, "exports", "abi").items.some(f => this.text(f, "abi.exports") === "drop_msg") ? "true" : "false");
      else value = this.bool(this.get(v, name, "channels"), "channels." + name);
      return { name, value };
    });
    for (const name of ["appearance_msg", "chrome_msg"]) {
      const value = this.get(v, name, "channels");
      if (value.literal !== "null") {
        if (value.literal.startsWith('"')) this.text(value, "channels." + name);
        else this.fail("channels." + name, `expected null or a message arm name string, found ${this.kind(value)}`);
      }
      fields.push({ name, value });
    }
    fields.push({ name: "env_msgs", value: env }); return object(fields);
  }
  hash(v: JsonNode, at: string): JsonNode {
    if (this.kind(v) === "a number") this.fail(at, "64-bit hashes are encoded as strings of exactly 16 lowercase hex digits, never JSON numbers (JSON cannot carry a u64 exactly)");
    if (!v.literal.startsWith('"')) this.fail(at, `expected a 16-lowercase-hex-digit string, found ${this.kind(v)}`);
    const text = this.text(v, at, false), bytes = new TextEncoder().encode(text);
    if (bytes.length !== 16) this.fail(at, `expected exactly 16 lowercase hex digits, found ${bytes.length} characters ("${text}")`);
    for (const b of bytes) if (!(b >= 48 && b <= 57) && !(b >= 97 && b <= 102)) this.fail(at, `expected lowercase hex digits only, found '${String.fromCharCode(b)}' in "${text}"`);
    return v;
  }
  root(v: JsonNode): JsonNode {
    const known = ["format", "wire_version", "abi_version", "compiler_version", "entry", "source_hash", "build_id", "model_fingerprint", "types", "model", "model_helpers", "model_unbound", "msg", "init_returns_cmd", "update_returns_cmd", "init_returns_bare", "update_returns_bare", "has_subscriptions", "has_migrate", "channels", "abi", "integer_slots", "deterministic", "async_free"];
    this.members(v, "", known);
    const format = this.integer(this.get(v, "format", ""), "format");
    if (format.literal !== "1") this.fail("format", `this reader implements sidecar format 1, found ${format.literal} — upgrade the SDK tooling or pin the compiler release that matches it`);
    const abi = this.abi(this.get(v, "abi", "")), channels = this.channels(this.get(v, "channels", ""), abi);
    const fields = known.map(name => {
      if (name === "abi") return { name, value: abi };
      if (name === "channels") return { name, value: channels };
      const value = this.maybe(v, name);
      if (name === "init_returns_bare" || name === "update_returns_bare") return { name, value: value === null ? scalar("false") : this.bool(value, name) };
      const required = this.get(v, name, "");
      if (["format", "wire_version", "abi_version"].includes(name)) return { name, value: this.integer(required, name) };
      if (["compiler_version", "entry", "model"].includes(name)) { this.text(required, name); return { name, value: required }; }
      if (["source_hash", "build_id", "model_fingerprint"].includes(name)) return { name, value: this.hash(required, name) };
      if (name === "types") return { name, value: this.types(required) };
      if (name === "model_helpers") return { name, value: this.helpers(required) };
      if (name === "model_unbound") return { name, value: this.strings(required, name) };
      if (name === "msg") return { name, value: this.msg(required) };
      if (name === "integer_slots") return { name, value: array(this.list(required, name).map((item, i) => {
        const p = `integer_slots[${i}]`; this.members(item, p, ["slot", "class"]);
        const slot = this.get(item, "slot", p); this.text(slot, p + ".slot");
        return object([{ name: "slot", value: slot }, { name: "class", value: this.numberClass(this.get(item, "class", p), p + ".class", true) }]);
      })) };
      return { name, value: this.bool(required, name) };
    });
    return object(fields);
  }
}

export function coreIntake(source: string): IntakeResult {
  const mapper = new CoreMapper();
  try { const parser = new Parser(source); return { normalized: render(mapper.root(parser.node()), 0), diagnostics: mapper.diagnostics }; }
  catch (error) { if (!(error instanceof Refusal)) throw error; return { normalized: "", diagnostics: mapper.diagnostics }; }
}

// The service schema is strict; only TypeRef's three optional carrier members
// have defaults. Integer conversion facts come from the native exact decoder.
interface IntegerFact { literal: string; value: string; error: string }
interface ServiceInput { canonical: string; integers: IntegerFact[] }
interface SchemaField { name: string; schema: string; defaultLiteral: string }
interface ServiceResult { normalized: string; error: string }
function field(name: string, schema: string, defaultLiteral = ""): SchemaField { return { name, schema, defaultLiteral }; }
function schemaFields(schema: string): SchemaField[] {
  if (schema === "Contract") return [field("format", "integer"), field("protocol_version", "integer"), field("compiler_version", "string"), field("deterministic", "boolean"), field("packages", "[]Package"), field("types", "Types"), field("operations", "[]Operation")];
  if (schema === "Package") return [field("name", "string"), field("version", "string"), field("content_hash", "string")];
  if (schema === "Types") return [field("records", "[]Record"), field("enums", "[]Enum"), field("unions", "[]Union")];
  if (schema === "Record") return [field("name", "string"), field("origin", "string"), field("fields", "[]Field")];
  if (schema === "Enum") return [field("name", "string"), field("origin", "string"), field("members", "[]string")];
  if (schema === "Union") return [field("name", "string"), field("origin", "string"), field("arms", "[]Arm")];
  if (schema === "Arm") return [field("name", "string"), field("fields", "[]Field")];
  if (schema === "Field") return [field("name", "string"), field("type", "TypeRef")];
  if (schema === "TypeRef") return [field("kind", "TypeKind"), field("inner", "?TypeRef", "null"), field("elem", "?TypeRef", "null"), field("name", "?string", "null")];
  if (schema === "Operation") return [field("name", "string"), field("client", "string"), field("module", "string"), field("export", "string"), field("request", "TypeRef"), field("result", "TypeRef"), field("deadline_ms", "?integer"), field("cancellable", "boolean"), field("stream", "?Stream"), field("source_hash", "string")];
  if (schema === "Stream") return [field("chunk", "TypeRef"), field("in_flight", "integer")];
  throw new Error("unknown service schema");
}
class ServiceMapper {
  integers: IntegerFact[]; error = "";
  constructor(integers: IntegerFact[]) { this.integers = integers; }
  fail(error: string): never { this.error = error; throw new Refusal(); }
  integer(v: JsonNode): JsonNode {
    const literal = v.literal.startsWith('"') ? JSON.stringify(JSON.parse(v.literal)) : v.literal;
    for (const fact of this.integers) if (fact.literal === literal) {
      if (fact.error !== "") this.fail(fact.error);
      return scalar(fact.value);
    }
    this.fail("UnexpectedToken");
  }
  decode(v: JsonNode, schema: string): JsonNode {
    if (schema.startsWith("?")) return v.literal === "null" ? v : this.decode(v, schema.slice(1));
    if (schema.startsWith("[]")) {
      if (v.kind !== "array") this.fail("UnexpectedToken");
      return array(v.items.map(item => this.decode(item, schema.slice(2))));
    }
    if (schema === "string") {
      if (v.kind === "array") {
        const bytes: JsonNode[] = [];
        for (const item of v.items) {
          const exact = this.integer(item), value = Number(exact.literal);
          if (value < 0 || value > 255) this.fail("Overflow");
          bytes.push(exact);
        }
        return array(bytes);
      }
      if (!v.literal.startsWith('"')) this.fail("UnexpectedToken"); return v;
    }
    if (schema === "boolean") { if (v.literal !== "true" && v.literal !== "false") this.fail("UnexpectedToken"); return v; }
    if (schema === "integer") return this.integer(v);
    if (schema === "TypeKind") {
      const kinds = ["none", "bool", "f64", "i64", "bytes", "optional", "slice", "record", "enum", "union"];
      let text = v.literal;
      if (text.startsWith('"')) text = JSON.parse(text) as string;
      else if (v.kind !== "scalar" || text === "null" || text === "true" || text === "false") this.fail("UnexpectedToken");
      if (kinds.includes(text)) return scalar(JSON.stringify(text));
      if (/^[0-9]+$/.test(text)) {
        const index = Number(text); if (index >= 0 && index < kinds.length) return scalar(JSON.stringify(kinds[index]));
      }
      this.fail("InvalidEnumTag");
    }
    if (v.kind !== "object") this.fail("UnexpectedToken");
    const fields = schemaFields(schema), decoded: { name: string; value: JsonNode }[] = [];
    for (const member of v.members) {
      const f = fields.find(f => f.name === member.name);
      if (f === undefined) this.fail("UnknownField");
      if (decoded.some(d => d.name === f.name)) this.fail("DuplicateField");
      decoded.push({ name: f.name, value: this.decode(member.value, f.schema) });
    }
    for (const f of fields) if (!decoded.some(d => d.name === f.name)) {
      if (f.defaultLiteral === "") this.fail("MissingField");
      decoded.push({ name: f.name, value: scalar(f.defaultLiteral) });
    }
    return object(decoded);
  }
}
export function serviceIntake(input: string): ServiceResult {
  const facts = JSON.parse(input) as ServiceInput, mapper = new ServiceMapper(facts.integers);
  try { const parser = new Parser(facts.canonical); return { normalized: render(mapper.decode(parser.node(), "Contract"), 0), error: "" }; }
  catch (error) { if (!(error instanceof Refusal)) throw error; return { normalized: "", error: mapper.error }; }
}

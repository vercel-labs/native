// The service projections of corewire's structurally decoded contract.
// Compiled by scriptc's static tier into the host tool; no JavaScript runtime ships.
import { createHash } from "node:crypto";
import * as fragments from "./service_templates.ts";

export interface TypeRef {
  kind: "none" | "bool" | "f64" | "i64" | "bytes" | "optional" | "slice" | "record" | "enum" | "union";
  inner: TypeRef | null;
  elem: TypeRef | null;
  name: string | null;
}
interface Field { name: string; type: TypeRef }
export interface Operation {
  name: string; client: string; module: string; export: string;
  request: TypeRef; result: TypeRef; deadline_ms: number | null; cancellable: boolean;
  stream: { chunk: TypeRef; in_flight: number } | null; source_hash: string;
}
export interface ServiceContract {
  format: number; protocol_version: number; compiler_version: string; deterministic: boolean;
  packages: { name: string; version: string; content_hash: string }[];
  types: {
    records: { name: string; origin: string; fields: Field[] }[];
    enums: { name: string; origin: string; members: string[] }[];
    unions: { name: string; origin: string; arms: { name: string; fields: Field[] }[] }[];
  };
  operations: Operation[];
}
export const inprocSymbolPrefix = "nsc_svc_";

function ascii(value: string, mode: string): boolean {
  if (value.length === 0) return false;
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    const digit = c >= 48 && c <= 57;
    const letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    if (mode === "digits") { if (!digit) return false; }
    else if (mode === "hex") { if (!(digit || (c >= 97 && c <= 102))) return false; }
    else if (mode === "identifier") { if (!(letter || c === 95 || c === 36 || (i > 0 && digit))) return false; }
    else if (!(letter || digit || c === 46 || c === 95 || c === 45)) return false;
  }
  return true;
}
function identifier(value: string): boolean { return ascii(value, "identifier"); }
function exactVersion(value: string): boolean {
  const parts = value.split(".");
  return parts.length === 3 && ascii(parts[0], "digits") && ascii(parts[1], "digits") && ascii(parts[2], "digits");
}
function packageName(value: string): boolean {
  if (!value.startsWith("@")) return ascii(value, "package");
  const parts = value.slice(1).split("/");
  return parts.length === 2 && ascii(parts[0], "package") && ascii(parts[1], "package");
}
function digest(value: string): boolean { return value.length === 64 && ascii(value, "hex"); }

function validType(ref: TypeRef): boolean {
  switch (ref.kind) {
    case "none": case "bool": case "f64": case "i64": case "bytes":
      return ref.inner === null && ref.elem === null && ref.name === null;
    case "optional": return ref.inner !== null && ref.elem === null && ref.name === null && validType(ref.inner);
    case "slice": return ref.elem !== null && ref.inner === null && ref.name === null && validType(ref.elem);
    default: return ref.name !== null && ref.name.length > 0 && ref.inner === null && ref.elem === null;
  }
}

// Structural JSON errors remain at the native decoder, with its exact field
// types/defaults and refusals. Every portable semantic rule is applied here,
// in the reference's diagnostic order, before any projection is written.
export function validateContract(contract: ServiceContract, basenames: readonly string[], formatText: string, protocolText: string): string {
  let out = "";
  if (contract.format !== 3) out += `corewire: services contract format is ${formatText}, expected 3\n`;
  if (contract.protocol_version !== 3) out += `corewire: service protocol is ${protocolText}, expected 3\n`;
  if (contract.deterministic) out += "corewire: a service contract may not attest deterministic=true — ambient authority is the service class's visible distinction\n";
  if (!exactVersion(contract.compiler_version)) out += `corewire: services contract compiler_version "${contract.compiler_version}" is not an exact X.Y.Z pin\n`;
  if (contract.operations.length === 0) out += "corewire: services contract contains no operations\n";
  for (let index = 0; index < contract.operations.length; index++) {
    const op = contract.operations[index];
    const dot = op.name.lastIndexOf(".");
    if (dot < 1 || !identifier(op.name.slice(dot + 1))) out += `corewire: operations[${index}].name "${op.name}" is not <module>.<export>\n`;
    if (!identifier(op.client)) out += `corewire: operations[${index}].client "${op.client}" is not a TypeScript identifier\n`;
    if (!op.module.startsWith("src/services/") || !op.module.endsWith(".ts") || op.module.includes("..")) out += `corewire: operations[${index}].module "${op.module}" is not a safe src/services/*.ts path\n`;
    if (!identifier(op.export)) out += `corewire: operations[${index}].export "${op.export}" is not a TypeScript identifier\n`;
    // Zig's basename follows the host's separator rules. The adapter supplies
    // that one explicit path fact; projection does not normalize the module.
    const basename = basenames[index];
    if (!basename.endsWith(".ts") || op.name !== basename.slice(0, -3) + "." + op.export) out += `corewire: operations[${index}].name "${op.name}" does not match module basename "${basename}" and export "${op.export}"\n`;
    if (!digest(op.source_hash)) out += `corewire: operations[${index}].source_hash is not a lowercase SHA-256 hex digest\n`;
    if (op.result.kind === "none") out += `corewire: operations[${index}].result may not be void\n`;
    if (!validType(op.request) || !validType(op.result)) out += `corewire: operations[${index}] carries an invalid type reference\n`;
    if (op.deadline_ms !== null && (op.deadline_ms < 1 || op.deadline_ms > 86400000)) out += `corewire: operations[${index}].deadline_ms is outside 1..86400000\n`;
    if (op.stream !== null && (!validType(op.stream.chunk) || op.stream.chunk.kind === "none" || op.stream.in_flight < 1 || op.stream.in_flight > 64)) out += `corewire: operations[${index}].stream must carry an encodable chunk and a 1..64 in_flight cap\n`;
    for (let earlier = 0; earlier < index; earlier++) if (contract.operations[earlier].name === op.name) out += `corewire: duplicate service operation name "${op.name}"\n`;
  }
  for (let index = 0; index < contract.packages.length; index++) {
    const item = contract.packages[index];
    if (!packageName(item.name) || !exactVersion(item.version) || !digest(item.content_hash)) out += `corewire: packages[${index}] must carry name, exact version, and a lowercase SHA-256 content_hash\n`;
    for (let earlier = 0; earlier < index; earlier++) if (contract.packages[earlier].name === item.name) out += `corewire: duplicate service package "${item.name}"\n`;
  }
  return out;
}

function quote(text: string): string {
  let out = '"';
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    let escaped = "";
    if (code === 34) escaped = '\\"';
    else if (code === 92) escaped = "\\\\";
    else if (code === 10) escaped = "\\n";
    else if (code === 13) escaped = "\\r";
    else if (code === 9) escaped = "\\t";
    else if (code < 32) escaped = "\\u00" + "0123456789abcdef".charAt(code >> 4) + "0123456789abcdef".charAt(code & 15);
    else continue;
    // Copy whole Unicode spans, never isolated UTF-16 surrogate halves.
    out += text.slice(start, i) + escaped;
    start = i + 1;
  }
  return out + text.slice(start) + '"';
}

function integerBytes(value: number): Uint8Array {
  const bytes = new Uint8Array(8);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, value >>> 0, true);
  view.setInt32(4, Math.floor(value / 4294967296), true);
  return bytes;
}
export function contractFingerprint(contract: ServiceContract): Uint8Array {
  const hash = createHash("sha256");
  hash.update("native-sdk.services.abi.v3\u0000");
  const field = (value: string): void => {
    const bytes = new TextEncoder().encode(value);
    hash.update(integerBytes(bytes.length)); hash.update(bytes);
  };
  const type = (ref: TypeRef): void => {
    const kinds = ["none", "bool", "f64", "i64", "bytes", "optional", "slice", "record", "enum", "union"];
    hash.update(new Uint8Array([kinds.indexOf(ref.kind)]));
    if (ref.inner !== null) type(ref.inner);
    if (ref.elem !== null) type(ref.elem);
    if (ref.name !== null) field(ref.name);
  };
  hash.update(integerBytes(contract.format)); hash.update(integerBytes(contract.protocol_version));
  for (const record of contract.types.records) { field(record.name); for (const f of record.fields) { field(f.name); type(f.type); } }
  for (const enumeration of contract.types.enums) { field(enumeration.name); for (const member of enumeration.members) field(member); }
  for (const union of contract.types.unions) { field(union.name); for (const arm of union.arms) { field(arm.name); for (const f of arm.fields) { field(f.name); type(f.type); } } }
  hash.update(integerBytes(contract.operations.length));
  for (const op of contract.operations) {
    field(op.name); type(op.request); type(op.result); hash.update(integerBytes(op.deadline_ms ?? 0));
    hash.update(new Uint8Array([op.cancellable ? 1 : 0]));
    hash.update(new Uint8Array([op.stream !== null ? 1 : 0]));
    if (op.stream !== null) { type(op.stream.chunk); hash.update(integerBytes(op.stream.in_flight)); }
  }
  return new Uint8Array(hash.digest());
}

function decode(ref: TypeRef, reader: string): string {
  switch (ref.kind) {
    case "none": return "undefined";
    case "bool": case "f64": case "i64": return reader + "." + ref.kind + "()";
    case "bytes": return reader + ".bytesValue()";
    case "optional": return `readOptional(${reader}, (nested) => ${decode(ref.inner!, "nested")})`;
    case "slice": return `readSlice(${reader}, (nested) => ${decode(ref.elem!, "nested")})`;
    default: return `__nativeSdkDecode${ref.name}(${reader})`;
  }
}
function encode(ref: TypeRef, value: string): string {
  switch (ref.kind) {
    case "none": return "new Uint8Array(0)";
    case "bool": return `writeBool(${value})`;
    case "f64": return `writeF64(${value})`;
    case "i64": return `writeI64(${value})`;
    case "bytes": return `writeBytes(${value})`;
    case "optional": return `${value} === null ? writeOptional(null) : writeOptional(${encode(ref.inner!, value)})`;
    case "slice": return `writeSlice(${value}.map((item) => ${encode(ref.elem!, "item")}))`;
    default: return `__nativeSdkEncode${ref.name}(${value})`;
  }
}
function tsType(ref: TypeRef): string {
  switch (ref.kind) {
    case "none": return "void";
    case "bool": return "boolean";
    case "f64": case "i64": return "number";
    case "bytes": return "Uint8Array";
    case "optional": return tsType(ref.inner!) + " | null";
    case "slice": {
      const elem = ref.elem!;
      const parens = elem.kind === "optional" || elem.kind === "slice";
      return "readonly " + (parens ? "(" : "") + tsType(elem) + (parens ? ")" : "") + "[]";
    }
    default: return ref.name!;
  }
}
function typeImports(contract: ServiceContract): string {
  let out = "";
  for (const record of contract.types.records) out += `import type { ${record.name} } from "./${record.origin}";\n`;
  for (const enumeration of contract.types.enums) out += `import type { ${enumeration.name} } from "./${enumeration.origin}";\n`;
  for (const union of contract.types.unions) out += `import type { ${union.name} } from "./${union.origin}";\n`;
  return out;
}
function encoders(contract: ServiceContract, host: boolean): string {
  let out = "";
  for (const record of contract.types.records) {
    out += `${host ? "" : "\n"}function __nativeSdkEncode${record.name}(value: ${record.name}): Uint8Array { return concat([`;
    out += record.fields.map(f => encode(f.type, "value." + f.name)).join(", ") + "]); }\n";
  }
  for (const enumeration of contract.types.enums) {
    out += `${host ? "" : "\n"}function __nativeSdkEncode${enumeration.name}(value: ${enumeration.name}): Uint8Array { return ${host ? "writeU32" : "writeEnum"}(`;
    for (let i = 0; i < enumeration.members.length; i++) out += "value === " + quote(enumeration.members[i]) + " ? " + i + " : (";
    out += "0" + ")".repeat(enumeration.members.length) + "); }\n";
  }
  for (const union of contract.types.unions) {
    out += `${host ? "" : "\n"}function __nativeSdkEncode${union.name}(value: ${union.name}): Uint8Array { switch (value.kind) {\n`;
    for (let i = 0; i < union.arms.length; i++) {
      const arm = union.arms[i];
      out += "  case " + quote(arm.name) + ": return concat([" + (host ? "new Uint8Array([" + i + "])" : "writeUnion(" + i + ")");
      for (const f of arm.fields) out += ", " + encode(f.type, "value." + f.name);
      out += "]);\n";
    }
    out += "} }\n";
  }
  return out;
}
function hostCodecs(contract: ServiceContract): string {
  // Reference order interleaves each decoder with its corresponding encoder.
  let out = fragments.codecs;
  for (const record of contract.types.records) {
    out += `function __nativeSdkDecode${record.name}(reader: __NativeSdkReader): ${record.name} { return { `;
    out += record.fields.map(f => f.name + ": " + decode(f.type, "reader")).join(", ") + " }; }\n";
    out += encoders({ ...contract, types: { records: [record], enums: [], unions: [] } }, true);
  }
  for (const enumeration of contract.types.enums) {
    out += `function __nativeSdkDecode${enumeration.name}(reader: __NativeSdkReader): ${enumeration.name} { switch (reader.u32()) {\n`;
    for (let i = 0; i < enumeration.members.length; i++) out += "  case " + i + ": return " + quote(enumeration.members[i]) + ";\n";
    out += '  default: throw new Error("invalid service enum");\n} }\n';
    out += encoders({ ...contract, types: { records: [], enums: [enumeration], unions: [] } }, true);
  }
  for (const union of contract.types.unions) {
    out += `function __nativeSdkDecode${union.name}(reader: __NativeSdkReader): ${union.name} { switch (reader.u8()) {\n`;
    for (let i = 0; i < union.arms.length; i++) {
      const arm = union.arms[i]; out += "  case " + i + ": return { kind: " + quote(arm.name);
      for (const f of arm.fields) out += ", " + f.name + ": " + decode(f.type, "reader");
      out += " };\n";
    }
    out += '  default: throw new Error("invalid service union");\n} }\n';
    out += encoders({ ...contract, types: { records: [], enums: [], unions: [union] } }, true);
  }
  return out;
}
function dispatchCases(contract: ServiceContract, child: boolean): string {
  let out = "";
  for (let i = 0; i < contract.operations.length; i++) {
    const op = contract.operations[i]; out += "    case " + i + ": {\n";
    const args: string[] = [];
    if (op.request.kind === "none") out += '      if (payload.length !== 0) throw new Error("unexpected service request payload");\n';
    else {
      args.push("request");
      if (op.request.kind === "bytes") out += "      const request = payload;\n";
      else out += "      const reader = new __NativeSdkReader(payload);\n      const request = " + decode(op.request, "reader") + ";\n      reader.finish();\n";
    }
    if (op.stream !== null) args.push("(chunk) => __nativeSdkEmit" + i + (child ? "(requestId, chunk)" : "(chunk)"));
    if (op.cancellable) args.push("cancellation(cancelPath)");
    const call = "serviceOp" + i + "(" + args.join(", ") + ")";
    out += "      return " + (op.result.kind === "bytes" ? call : encode(op.result, call)) + ";\n    }\n";
  }
  return out;
}
export function emitHost(contract: ServiceContract, child: boolean): string {
  let out = fragments.hostImports;
  for (let i = 0; i < contract.operations.length; i++) {
    const op = contract.operations[i]; out += `import { ${op.export} as serviceOp${i} } from "./${op.module.slice(4)}";\n`;
  }
  out += typeImports(contract) + "\n";
  if (child) out += "const PROTOCOL_VERSION = " + contract.protocol_version + ";\n";
  out += "const CONTRACT_FINGERPRINT = new Uint8Array([" + Array.from(contractFingerprint(contract)).join(", ") + "]);\n";
  out += (child ? fragments.hostTransport : fragments.inprocTransport) + hostCodecs(contract);
  for (let i = 0; i < contract.operations.length; i++) {
    const stream = contract.operations[i].stream;
    if (stream !== null) {
      out += "\nfunction __nativeSdkEmit" + i + "(" + (child ? "requestId: number, " : "") + "chunk: " + tsType(stream.chunk) + "): void { " + (child ? "writeResult(requestId, 2, " : "__nativeSdkEmitFrame(");
      out += (stream.chunk.kind === "bytes" ? "chunk" : encode(stream.chunk, "chunk")) + "); }\n";
    }
  }
  out += (child ? fragments.hostSwitch : fragments.inprocSwitch) + dispatchCases(contract, child) + (child ? fragments.hostLoop : fragments.inprocDispatch);
  return out;
}
export function emitRegistry(contract: ServiceContract): string {
  let out = "//! Generated by corewire from services.contract.json. Do not edit.\npub const enabled = true;\npub const protocol_version: u8 = " + contract.protocol_version + ';\npub const compiler_version = "' + contract.compiler_version + '";\npub const inproc_symbol_prefix = "' + inprocSymbolPrefix + '";\n';
  out += "pub const contract_fingerprint = [_]u8{" + Array.from(contractFingerprint(contract)).join(", ") + fragments.registryOperationHeader;
  for (let i = 0; i < contract.operations.length; i++) {
    const op = contract.operations[i];
    out += `    .{ .name = "${op.name}", .index = ${i}, .deadline_ms = ${op.deadline_ms === null ? "null" : String(op.deadline_ms)}, .cancellable = ${op.cancellable}, .streaming = ${op.stream !== null}, .in_flight = ${op.stream === null ? 0 : op.stream.in_flight} },\n`;
  }
  out += fragments.registryLookup + "pub fn resultIsBytes(index: u16) bool {\n    return switch (index) {\n";
  for (let i = 0; i < contract.operations.length; i++) if (contract.operations[i].result.kind === "bytes") out += "        " + i + " => true,\n";
  return out + "        else => false,\n    };\n}\n" + fragments.registryDecoder;
}
export function emitClient(contract: ServiceContract): string {
  let out = fragments.clientImports + typeImports(contract) + encoders(contract, false);
  for (const op of contract.operations) {
    out += "\nexport function " + op.client + "(";
    if (op.request.kind !== "none") out += "request: " + tsType(op.request) + ", ";
    out += (op.stream === null ? "route: ServiceRoute<Msg, " : "route: ServiceStreamRoute<Msg, ") + tsType(op.result) + ">): Cmd<Msg> {\n  return Cmd.";
    out += (op.stream === null ? "serviceRequest(" : "serviceStreamRequest(") + quote(op.name);
    if (op.stream !== null) out += ", route.channelKey";
    out += ", " + (op.request.kind === "none" ? "new Uint8Array(0)" : op.request.kind === "bytes" ? "request" : encode(op.request, "request")) + ", route";
    if (op.stream !== null) out += ", " + op.stream.in_flight;
    out += ");\n}\n";
  }
  return out;
}
export function emitInprocProfile(optimization: string): string {
  let out = fragments.profileHeader;
  if (optimization !== "") out += '  "optimization": "' + optimization + '",\n';
  const prefix = inprocSymbolPrefix;
  return out + '  "abi": {\n    "prefix": "' + prefix + '",\n    "init_symbol": "' + prefix + 'init",\n    "sink_register_symbol": "' + prefix + 'set_panic_sink",\n    "collect_symbol": "' + prefix + 'collect",\n    "result_reset_symbol": null,\n    "localize_runtime": true,\n    "instance_per_thread": true\n  },\n  "exports": [\n    { "export": "dispatch", "symbol": "' + prefix + 'dispatch", "params": ["u32", "bytes", "bytes", "bytes"], "returns": "bytes" },\n    { "export": "contractFingerprint", "symbol": "' + prefix + 'contract_fingerprint", "params": [], "returns": "bytes" }\n  ]\n}\n';
}
export function validateServices(input: string): string {
  const facts = JSON.parse(input) as { contract: ServiceContract; basenames: string[]; format_text: string; protocol_text: string };
  return validateContract(facts.contract, facts.basenames, facts.format_text, facts.protocol_text);
}
export function generateServices(input: string, projection: string, optimization: string): string {
  if (projection === "profile") return emitInprocProfile(optimization);
  const contract = JSON.parse(input) as ServiceContract;
  switch (projection) {
    case "host": return emitHost(contract, true);
    case "inproc": return emitHost(contract, false);
    case "registry": return emitRegistry(contract);
    case "client": return emitClient(contract);
    default: throw new Error("unknown service projection");
  }
}

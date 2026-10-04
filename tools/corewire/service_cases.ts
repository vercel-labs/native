// Shared conformance corpus: every wire type, transport shape and refusal.
import type { ServiceContract, TypeRef } from "./emit_service.ts";
const ref = (kind: TypeRef["kind"], inner: TypeRef | null = null, elem: TypeRef | null = null, name: string | null = null): TypeRef => ({ kind, inner, elem, name });
export function baseContract(): ServiceContract {
  return {
    format: 3, protocol_version: 3, compiler_version: "0.2.2", deterministic: false, packages: [],
    types: {
      records: [{ name: "Envelope", origin: "shared.ts", fields: [{ name: "enabled", type: ref("bool") }, { name: "whole", type: ref("i64") }, { name: "value", type: ref("f64") }, { name: "bytes", type: ref("bytes") }, { name: "choice", type: ref("enum", null, null, "Choice") }, { name: "event", type: ref("union", null, null, "Event") }] }],
      enums: [{ name: "Choice", origin: "shared.ts", members: ["plain", 'café 🧪 " \\b\n\t\b\f\u0000'] }],
      unions: [{ name: "Event", origin: "shared.ts", arms: [{ name: "none", fields: [] }, { name: "data", fields: [{ name: "items", type: ref("slice", null, ref("optional", ref("bytes"))) }] }] }],
    },
    operations: [{ name: "feeds.parse", client: "feedsParse", module: "src/services/feeds.ts", export: "parse", request: ref("bytes"), result: ref("bytes"), deadline_ms: null, cancellable: false, stream: null, source_hash: "a".repeat(64) }],
  };
}
export interface ServiceCase { name: string; input: string; optimization: string }
export function serviceCases(): ServiceCase[] {
  const cases: ServiceCase[] = [];
  const add = (name: string, mutate: (c: ServiceContract) => void, optimization = "") => {
    const c = baseContract(); mutate(c); cases.push({ name, input: JSON.stringify(c), optimization });
  };
  for (const optimization of ["", "dev", "release"]) add("optimization-" + (optimization || "default"), () => {}, optimization);
  const types: TypeRef[] = [ref("none"), ref("bool"), ref("f64"), ref("i64"), ref("bytes"), ref("record", null, null, "Envelope"), ref("enum", null, null, "Choice"), ref("union", null, null, "Event"), ref("optional", ref("bytes")), ref("slice", null, ref("optional", ref("slice", null, ref("bytes"))))];
  for (let t = 0; t < types.length; t++) for (const cancellable of [false, true]) for (const streaming of [false, true]) add(`shape-${t}-${cancellable}-${streaming}`, c => {
    c.operations[0].request = types[t]; c.operations[0].result = types[t].kind === "none" ? ref("bool") : types[t];
    c.operations[0].cancellable = cancellable; c.operations[0].deadline_ms = streaming ? 86400000 : 1;
    c.operations[0].stream = streaming ? { chunk: types[t].kind === "none" ? ref("bytes") : types[t], in_flight: cancellable ? 64 : 1 } : null;
  });
  add("multiple-operations", c => { c.operations.push({ ...c.operations[0], name: "feeds.$refresh", client: "feeds$refresh", export: "$refresh", request: ref("none"), cancellable: true }); });
  add("empty-types", c => { c.types = { records: [], enums: [], unions: [] }; });
  add("empty-members", c => { c.types.enums[0].members = []; c.types.unions[0].arms = []; c.types.records[0].fields = []; });
  add("unicode-module", c => { c.operations[0].module = "src/services/café🧪.ts"; c.operations[0].name = "café🧪.parse"; });
  add("host-basename", c => { c.operations[0].module = "src/services/sub\\feeds.ts"; c.operations[0].name = "sub\\feeds.parse"; });
  add("exact-packages", c => { c.packages = [{ name: "@scope/pkg", version: "01.002.3", content_hash: "b".repeat(64) }, { name: "simple._-", version: "1.0.0", content_hash: "c".repeat(64) }]; });
  for (const field of ["format", "protocol_version"] as const) for (const value of [-1, 0, 4, 9007199254740991]) add(`${field}-${value}`, c => { c[field] = value; });
  add("authority", c => { c.deterministic = true; });
  for (const value of ["", "0.2", "0.2.2-beta", "1.2.3\n", "١.2.3"]) add("version-" + JSON.stringify(value), c => { c.compiler_version = value; });
  add("no-operations", c => { c.operations = []; });
  for (const value of ["", ".parse", "feeds.", "feeds.2parse", "feeds.parse\n"]) add("name-" + JSON.stringify(value), c => { c.operations[0].name = value; });
  for (const field of ["client", "export"] as const) for (const value of ["", "2bad", "has-dash", "parse\n", "café"]) add(field + "-" + JSON.stringify(value), c => { c.operations[0][field] = value; });
  for (const value of ["feeds.ts", "src/services/x..ts", "src/services/feeds.js", "src/services/feeds.ts\n", "src/services/different.ts"]) add("module-" + JSON.stringify(value), c => { c.operations[0].module = value; });
  for (const value of ["", "a".repeat(63), "A".repeat(64), "g".repeat(64), "a".repeat(63) + "\n"]) add("hash-" + JSON.stringify(value), c => { c.operations[0].source_hash = value; });
  add("void-result", c => { c.operations[0].result = ref("none"); });
  add("scalar-inner", c => { c.operations[0].request.inner = ref("bool"); });
  add("missing-inner", c => { c.operations[0].request = ref("optional"); });
  add("missing-elem", c => { c.operations[0].request = ref("slice"); });
  add("empty-name", c => { c.operations[0].request = ref("record", null, null, ""); });
  for (const deadline of [-1, 0, 86400001, 9007199254740991]) add("deadline-" + deadline, c => { c.operations[0].deadline_ms = deadline; });
  for (const limit of [-1, 0, 65]) add("stream-cap-" + limit, c => { c.operations[0].stream = { chunk: ref("bytes"), in_flight: limit }; });
  add("void-chunk", c => { c.operations[0].stream = { chunk: ref("none"), in_flight: 8 }; });
  add("invalid-chunk", c => { c.operations[0].stream = { chunk: ref("optional"), in_flight: 8 }; });
  add("duplicates", c => { c.operations.push(c.operations[0], c.operations[0]); });
  for (const name of ["", "@scope", "@/pkg", "@scope/", "@scope/pkg/extra", "pkg\n", "é"]) add("package-" + JSON.stringify(name), c => { c.packages = [{ name, version: "1.2.3", content_hash: "a".repeat(64) }]; });
  add("bad-package-facts", c => { c.packages = [{ name: "pkg", version: "1.2", content_hash: "A".repeat(64) }]; });
  add("duplicate-packages", c => { c.packages = [0, 1, 2].map(() => ({ name: "pkg", version: "1.2.3", content_hash: "a".repeat(64) })); });
  add("ordered-errors", c => { c.format = 1; c.protocol_version = 1; c.deterministic = true; c.compiler_version = "bad"; c.operations[0].name = "bad"; c.operations[0].client = "bad-name"; c.operations[0].result = ref("none"); c.operations[0].deadline_ms = 0; });
  for (const field of ["format", "protocol_version"] as const) for (const value of ["9223372036854775807", "-9223372036854775808"]) {
    const c = baseContract(); c[field] = 9007199254740991;
    cases.push({ name: `${field}-${value}`, input: JSON.stringify(c).replace(`${field}\":9007199254740991`, `${field}\":${value}`), optimization: "" });
  }
  return cases;
}

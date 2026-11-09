// Structural conformance cases captured before replacing the native reader.
import { baseContract as core } from "./core_cases.ts";
import { baseContract as service } from "./service_cases.ts";
export interface IntakeCase { name: string; mode: string; input: string }
export function intakeCases(): IntakeCase[] {
  const out: IntakeCase[] = [];
  const encode = (v: unknown): string => JSON.stringify(v, (k, v) => (k === "origin" || k === "member") && v === null ? undefined : v);
  const c = JSON.parse(encode(core()));
  const s = service();
  function add(mode: string, name: string, value: unknown): void { out.push({ name: mode + "-" + name, mode, input: mode === "core" ? encode(value) : JSON.stringify(value) }); }
  function visit(mode: string, source: unknown, path: (string | number)[], depth: number): void {
    let current: any = source; for (const key of path) current = current[key];
    const at = path.join(".") || "root";
    for (const value of [null, true, false, 0, 1.5, "", "invalid", [], {}]) {
      const copy = structuredClone(source); let parent: any = copy;
      for (const key of path.slice(0, -1)) parent = parent[key];
      if (path.length === 0) add(mode, at + "-" + JSON.stringify(value), value);
      else { parent[path[path.length - 1]] = value; add(mode, at + "-" + JSON.stringify(value), copy); }
    }
    if (current !== null && typeof current === "object" && !Array.isArray(current)) {
      const unknown = structuredClone(source); let node: any = unknown; for (const key of path) node = node[key];
      node.additive = { exact: 17 }; add(mode, at + "-unknown", unknown);
      for (const key of Object.keys(current)) {
        const missing = structuredClone(source); let node: any = missing; for (const p of path) node = node[p];
        delete node[key]; add(mode, at + "-missing-" + key, missing);
        if (depth < 8) visit(mode, source, [...path, key], depth + 1);
      }
    } else if (Array.isArray(current) && current.length > 0 && depth < 8) visit(mode, source, [...path, 0], depth + 1);
  }
  visit("core", c, [], 0); visit("service", s, [], 0);
  for (const mode of ["core", "service"]) {
    const input = mode === "core" ? encode(c) : JSON.stringify(s);
    for (const number of ["-0", "1.0", "1e0", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "-9223372036854775809", '"3"', '"3.0"'])
      out.push({ name: mode + "-format-lexeme-" + number, mode, input: input.replace(/"format":\d+/, '"format":' + number) });
    out.push({ name: mode + "-duplicate-format", mode, input: input.replace('"format":', '"format":0,"format":') });
  }
  for (const hashes of ["0000000000000000", "ffffffffffffffff", "8000000000000000", "0000000000000001"]) {
    const changed = structuredClone(c); for (const key of ["source_hash", "build_id", "model_fingerprint"]) changed[key] = hashes;
    add("core", "hash-" + hashes, changed);
  }
  for (const kind of ["bool", "f64", "i64", "bytes", "void", "optional", "slice", "node", "value", "enum", "union", "unknown", ""]) {
    const changed = structuredClone(c); changed.types.structs[0].fields[0].type = { kind, inner: { kind: "bool" }, elem: { kind: "bool" }, name: "Model", extra: true };
    add("core", "typeref-" + kind, changed);
  }
  const source = JSON.stringify(s);
  for (const value of ['"3"', '"3.0"', '"3e0"', '"\\u0033"', '1.5', '"9223372036854775807"', '"-9223372036854775808"'])
    out.push({ name: "service-deadline-lexeme-" + value, mode: "service", input: source.replace('"deadline_ms":null', '"deadline_ms":' + value) });
  for (const value of ['"1"', '"-1"', '1.0', '1.5', '255', '256', '"bool"'])
    out.push({ name: "service-enum-lexeme-" + value, mode: "service", input: source.replace('"kind":"bool"', '"kind":' + value) });
  for (const value of ["[]", "[65,66,67]", "[256]", "[-1]", "[1.5]", '["65"]'])
    out.push({ name: "service-byte-string-" + value, mode: "service", input: source.replace('"compiler_version":"0.2.2"', '"compiler_version":' + value) });
  out.push({ name: "service-unknown-before-duplicate", mode: "service", input: source.replace('"format":3', '"unknown":1,"format":3,"format":3') });
  out.push({ name: "service-duplicate-before-unknown", mode: "service", input: source.replace('"format":3', '"format":3,"format":3,"unknown":1') });
  return out;
}

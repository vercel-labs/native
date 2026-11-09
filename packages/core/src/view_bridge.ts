/** The per-app half of the development view evaluator: typed reads of this
 * contract's model, its helpers, and its message constructors. Generated
 * from the contract alone, never from author source.
 */
import { createHash } from "node:crypto";
import type { ViewContract } from "./view_frontend.ts";

interface Ref { kind: string; name?: string; elem?: Ref; inner?: Ref; class?: string; type?: Ref }

/** Changes whenever a program compiled against one build could misread another. */
export function viewBridgeIdentity(contract: ViewContract, evaluatorSource: string): string {
  const relevant = { model: contract.model, types: contract.types, helpers: contract.model_helpers, msg: contract.msg };
  return createHash("sha256").update("native view program 1\0").update(JSON.stringify(relevant)).update("\0").update(evaluatorSource).digest("hex");
}

type Record = ViewContract["types"]["structs"][number] & { origin?: string | null };
type Enum = { name: string; members: string[]; origin?: string | null };

export function viewBridgeSource(contract: ViewContract, identity: string): string {
  const allStructs = contract.types.structs as Record[], enums = (contract.types.enums ?? []) as Enum[];
  // Only records a view can reach: the model, helper results and helper
  // parameters, through record, list and optional fields.
  const reachable = new Set<string>();
  const visit = (ref: Ref | undefined): void => {
    if (!ref) return;
    if ((ref.kind === "value" || ref.kind === "node") && ref.name && !reachable.has(ref.name)) {
      reachable.add(ref.name);
      for (const field of allStructs.find(item => item.name === ref.name)?.fields ?? []) visit(field.type);
    }
    visit(ref.inner); visit(ref.elem);
  };
  visit({ kind: "value", name: contract.model });
  for (const helper of contract.model_helpers) { visit(helper.returns); helper.params.forEach(visit); }
  // Declared records keep their names; anonymous ones are spelled out, as
  // the generated entry module spells them.
  const spellings = new Map<string, string | null>();
  const spell = (ref: Ref): string | null => {
    switch (ref.kind) {
      case "bool": return "boolean";
      case "i64": case "f64": return "number";
      case "bytes": return "Uint8Array";
      case "optional": { const inner = spell(ref.inner!); return inner === null ? null : `${inner} | null`; }
      case "slice": { const elem = spell(ref.elem!); return elem === null ? null : `readonly (${elem})[]`; }
      case "enum": {
        const item = enums.find(entry => entry.name === ref.name);
        if (!item) return null;
        return item.origin === null ? item.members.map(member => JSON.stringify(member)).join(" | ") : item.name;
      }
      case "value": case "node": return spellRecord(ref.name!);
    }
    return null;
  };
  const spellRecord = (name: string): string | null => {
    if (spellings.has(name)) return spellings.get(name)!;
    const record = allStructs.find(item => item.name === name);
    if (!record) return null;
    if (record.origin !== null && record.origin !== undefined) { spellings.set(name, name); return name; }
    spellings.set(name, null);
    const fields: string[] = [];
    for (const field of record.fields) { const type = spell(field.type); if (type === null) return null; fields.push(`readonly ${JSON.stringify(field.name)}: ${type}`); }
    const spelled = `{ ${fields.join("; ")} }`;
    spellings.set(name, spelled);
    return spelled;
  };
  const structs = allStructs.filter(item => reachable.has(item.name) && spellRecord(item.name) !== null);
  const typeOf = (record: Record): string => spellRecord(record.name)!;
  const structIndex = (name: string): number => structs.findIndex(item => item.name === name);
  const enumIndex = (name: string): number => enums.findIndex(item => item.name === name);
  const wrap = (ref: Ref, e: string): string => {
    switch (ref.kind) {
      case "bool": return `nscvdBoolean(${e})`;
      case "i64": case "f64": return `nscvdNum(${e})`;
      case "bytes": return `nscvdBytesValue(${e})`;
      case "enum": return `nscvdStr(${e})`;
      case "optional": return `(${e} === null ? nscvdNull() : ${wrap(ref.inner!, e + "!")})`;
      case "value": case "node": return structIndex(ref.name!) < 0 ? `nscvdUnsupported(${JSON.stringify(ref.name)})` : `nscvdWrapS${structIndex(ref.name!)}(${e})`;
      case "slice": {
        const elem = ref.elem!;
        if (elem.kind === "bool") return `nscvdBoolsValue(nscvdCopyBooleans(${e}))`;
        if (elem.kind === "i64" || elem.kind === "f64") return `nscvdNumsValue(nscvdCopyNumbers(${e}))`;
        if (elem.kind === "bytes") return `nscvdByteListValue(nscvdCopyBytes(${e}))`;
        if (elem.kind === "enum") return `nscvdStrListValue(nscvdCopyStrings(${e}))`;
        if (elem.kind === "value" || elem.kind === "node") return structIndex(elem.name!) < 0 ? `nscvdUnsupported(${JSON.stringify(elem.name)})` : `nscvdWrapL${structIndex(elem.name!)}(${e})`;
        return `nscvdUnsupported("a nested list")`;
      }
    }
    return `nscvdUnsupported(${JSON.stringify(ref.kind)})`;
  };
  // Integer slots are proven at the literal: a checked local, then the
  // bounded conversion the compiler recognizes as whole.
  let integers: string[] = [];
  const scalar = (ref: Ref, e: string): string => {
    switch (ref.kind) {
      case "bool": return `nscvdBool(${e})`;
      case "f64": return `nscvdNumber(${e})`;
      case "i64": { const local = `nscvdI${integers.length}`; integers.push(`const ${local} = nscvdI64(nscvdNumber(${e}));`); return `${local} >= -9007199254740991 && ${local} <= 9007199254740991 ? Math.trunc(${local}) : 0`; }
      case "bytes": return `nscvdBytes(${e})`;
      case "enum": return `nscvdEnum${enumIndex(ref.name!)}(nscvdString(${e}))`;
    }
    throw new Error(`development view bridge: unsupported message field ${ref.kind}`);
  };
  const out: string[] = [];
  out.push("// Generated development view bridge for this app's contract.", `const nscvdBridgeIdentity = ${JSON.stringify(identity)};`);
  out.push("class NscvdContract {");
  structs.forEach((item, i) => out.push(`  r${i}: (${typeOf(item)}) | null = null;`, `  l${i}: readonly (${typeOf(item)})[] = [];`));
  out.push("}");
  out.push("function nscvdContractValue(type: number, list: boolean): NscvdValue { const value = nscvdTagged(NSCVD_CONTRACT); value.ct = type; value.cl = list; value.c = new NscvdContract(); return value; }");
  structs.forEach((item, i) => out.push(
    `function nscvdWrapS${i}(record: ${typeOf(item)}): NscvdValue { const value = nscvdContractValue(${i}, false); value.c!.r${i} = record; return value; }`,
    `function nscvdWrapL${i}(list: readonly (${typeOf(item)})[]): NscvdValue { const value = nscvdContractValue(${i}, true); value.c!.l${i} = list; return value; }`));
  enums.forEach((item, i) => out.push(`function nscvdEnum${i}(value: string): ${spell({ kind: "enum", name: item.name })} {`, ...item.members.map(member => `  if (value === ${JSON.stringify(member)}) return ${JSON.stringify(member)};`), `  throw new Error("invalid ${item.name} value " + value);`, "}"));
  out.push(`function nscvdModel(): NscvdValue { return nscvdWrapS${structIndex(contract.model)}(nscfCommitted); }`);
  out.push("function nscvdContractField(value: NscvdValue, name: string): NscvdValue {", "  if (value.cl) throw new Error(\"development view list has no field \" + name);", "  switch (value.ct) {");
  structs.forEach((item, i) => {
    out.push(`    case ${i}: {`, `      const record = value.c!.r${i}!;`, "      switch (name) {");
    for (const field of item.fields) out.push(`        case ${JSON.stringify(field.name)}: return ${wrap(field.type, `record[${JSON.stringify(field.name)}]`)};`);
    out.push("      }", "      break;", "    }");
  });
  out.push("  }", "  throw new Error(\"unknown development view model field \" + name);", "}");
  out.push("function nscvdContractItems(value: NscvdValue): NscvdValue[] {", "  if (!value.cl) throw new Error(\"development view record is not iterable\");", "  const out: NscvdValue[] = [];", "  switch (value.ct) {");
  structs.forEach((_item, i) => out.push(`    case ${i}: for (const item of value.c!.l${i}) out.push(nscvdWrapS${i}(item)); return out;`));
  out.push("  }", "  throw new Error(\"unknown development view list\");", "}");
  out.push("function nscvdContractLength(value: NscvdValue): number {", "  if (!value.cl) throw new Error(\"development view record has no length\");", "  switch (value.ct) {");
  structs.forEach((_item, i) => out.push(`    case ${i}: return value.c!.l${i}.length;`));
  out.push("  }", "  throw new Error(\"unknown development view list\");", "}");
  out.push("function nscvdHelper(name: string, args: NscvdValue[]): NscvdValue {", "  switch (name) {");
  for (const helper of contract.model_helpers) {
    if (helper.params.length > 1) continue;
    const range = helper.params.length === 1 ? "nscvdRange(args[1]!)" : null;
    if (helper.params.length === 1 && !["value", "node"].includes(helper.params[0]!.kind)) continue;
    out.push(`    case ${JSON.stringify(helper.name)}: return ${wrap(helper.returns, `${helper.name}(nscfCommitted${range ? ", " + range : ""})`)};`);
  }
  out.push("  }", "  throw new Error(\"unknown development view helper \" + name);", "}");
  out.push("function nscvdPackMsg(arm: string, keys: string[], values: NscvdValue[]): number[] {",
    "  const field = (key: string): NscvdValue => { for (let i = 0; i < keys.length; i++) if (keys[i] === key) return values[i]!; throw new Error(\"missing development view message field \" + key); };",
    "  switch (arm) {");
  for (const arm of contract.msg.arms) {
    const p = arm.payload as Ref, fields: string[] = [`kind: ${JSON.stringify(arm.name)}`];
    integers = [];
    if (p.kind === "void") { /* kind only */ }
    else if (arm.member && ["number", "bytes", "bool", "enum", "scalar"].includes(p.kind)) {
      const type: Ref = p.kind === "number" ? { kind: p.class ?? "f64" } : p.kind === "scalar" ? p.type! : p;
      if (!["bool", "f64", "i64", "bytes", "enum"].includes(type.kind)) continue;
      fields.push(`${JSON.stringify(arm.member)}: ${scalar(type, `field(${JSON.stringify(arm.member)})`)}`);
    } else if (p.kind === "record" && !arm.member) {
      const record = allStructs.find(item => item.name === p.name);
      if (!record || !record.fields.every(f => ["bool", "f64", "i64", "bytes", "enum"].includes(f.type.kind))) continue;
      for (const f of record.fields) fields.push(`${JSON.stringify(f.name)}: ${scalar(f.type, `field(${JSON.stringify(f.name)})`)}`);
    } else continue;
    out.push(`    case ${JSON.stringify(arm.name)}: { ${integers.join(" ")} return Array.from(nscfPackMsg({ ${fields.join(", ")} })); }`);
  }
  out.push("  }", "  throw new Error(\"unknown development view message \" + arm);", "}");
  const imageRecords = structs.map((item, i) => ({ item, i })).filter(({ item }) => item.fields.length === 4 && ["source", "image", "width", "height"].every(name => item.fields.some(f => f.name === name)));
  out.push("function nscvdMarkdownImages(value: NscvdValue): { source: Uint8Array; image: number; width: number; height: number }[] {", "  const out: { source: Uint8Array; image: number; width: number; height: number }[] = [];", "  if (value.t === NSCVD_LIST && value.list.length === 0) return out;", "  if (!value.cl) throw new Error(\"development view expected markdown images\");", "  switch (value.ct) {");
  for (const { item, i } of imageRecords) if (["i64", "f64"].includes(item.fields.find(f => f.name === "image")!.type.kind)) out.push(`    case ${i}: for (const x of value.c!.l${i}) out.push({ source: x.source, image: x.image, width: x.width, height: x.height }); return out;`);
  out.push("  }", "  throw new Error(\"development view expected markdown images\");", "}");
  out.push("function nscvdMarkdownImageWords(value: NscvdValue): { source: Uint8Array; image: { imageLower: number; imageUpper: number }; width: number; height: number }[] {", "  const out: { source: Uint8Array; image: { imageLower: number; imageUpper: number }; width: number; height: number }[] = [];", "  if (value.t === NSCVD_LIST && value.list.length === 0) return out;", "  if (!value.cl) throw new Error(\"development view expected markdown images\");", "  switch (value.ct) {");
  for (const { item, i } of imageRecords) if (["value", "node"].includes(item.fields.find(f => f.name === "image")!.type.kind)) out.push(`    case ${i}: for (const x of value.c!.l${i}) out.push({ source: x.source, image: { imageLower: x.image.imageLower, imageUpper: x.image.imageUpper }, width: x.width, height: x.height }); return out;`);
  out.push("  }", "  throw new Error(\"development view expected markdown images\");", "}");
  return out.join("\n") + "\n";
}

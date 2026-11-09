/** The view program: the typed statements a compiled view executes. The view
 * compiler builds this tree once; `printStatements` writes the TypeScript the
 * release core compiles, and `encodeViewProgram` writes the same program for
 * the development evaluator. Both outputs come from one tree, so they cannot
 * disagree about what a view does.
 */

/** Record types an object or array literal constructs. */
export type ViewRecordType =
  | "node" | "span" | "context_item" | "chart_series" | "component_text" | "timeline_item"
  | "virtual_request" | "msg" | "image_identity";

export type ViewExpr =
  | { readonly k: "num"; readonly text: string }
  | { readonly k: "str"; readonly value: string }
  | { readonly k: "bool"; readonly value: boolean }
  | { readonly k: "undefined" }
  | { readonly k: "null" }
  | { readonly k: "id"; readonly name: string }
  | { readonly k: "field"; readonly target: ViewExpr; readonly name: string; readonly bracket: boolean }
  | { readonly k: "index"; readonly target: ViewExpr; readonly index: ViewExpr }
  | { readonly k: "nonnull"; readonly target: ViewExpr }
  | { readonly k: "group"; readonly inner: ViewExpr }
  | { readonly k: "length"; readonly target: ViewExpr }
  | { readonly k: "call"; readonly fn: string; readonly args: readonly ViewExpr[] }
  | { readonly k: "binary"; readonly op: string; readonly left: ViewExpr; readonly right: ViewExpr; readonly paren: boolean }
  | { readonly k: "unary"; readonly op: "!" | "-"; readonly operand: ViewExpr; readonly paren: boolean }
  | { readonly k: "cond"; readonly test: ViewExpr; readonly then: ViewExpr; readonly otherwise: ViewExpr }
  | { readonly k: "nullish"; readonly left: ViewExpr; readonly right: ViewExpr }
  | { readonly k: "object"; readonly type: ViewRecordType; readonly name?: string; readonly props: readonly ViewProp[] }
  | { readonly k: "array"; readonly items: readonly ViewExpr[] }
  | { readonly k: "encode"; readonly value: ViewExpr }
  | { readonly k: "decode"; readonly value: ViewExpr }
  | { readonly k: "string"; readonly value: ViewExpr }
  | { readonly k: "from"; readonly value: ViewExpr }
  | { readonly k: "pack"; readonly msg: ViewExpr }
  | { readonly k: "label_bytes"; readonly list: ViewExpr; readonly bytes: boolean }
  | { readonly k: "float32"; readonly bytes: ViewExpr; readonly offset: number }
  | { readonly k: "empty_bytes" };

/** An object literal property; `quoted` keys print as JSON strings. */
export type ViewProp = { readonly key: string; readonly value: ViewExpr; readonly quoted?: boolean };

export type ViewStmt =
  | { readonly k: "const"; readonly name: string; readonly type?: string; readonly init: ViewExpr }
  | { readonly k: "expr"; readonly expr: ViewExpr }
  | { readonly k: "assign"; readonly target: ViewExpr; readonly value: ViewExpr }
  | { readonly k: "push"; readonly target: ViewExpr; readonly value: ViewExpr }
  | { readonly k: "if"; readonly test: ViewExpr; readonly then: readonly ViewStmt[]; readonly otherwise?: readonly ViewStmt[] }
  | { readonly k: "for"; readonly name: string; readonly items: ViewExpr; readonly body: readonly ViewStmt[] }
  | { readonly k: "throw_if"; readonly test: ViewExpr; readonly message: string };

// ------------------------------------------------------------ construction

export const v = {
  num: (text: string): ViewExpr => ({ k: "num", text }),
  str: (value: string): ViewExpr => ({ k: "str", value }),
  bool: (value: boolean): ViewExpr => ({ k: "bool", value }),
  undef: (): ViewExpr => ({ k: "undefined" }),
  nul: (): ViewExpr => ({ k: "null" }),
  id: (name: string): ViewExpr => ({ k: "id", name }),
  field: (target: ViewExpr, name: string, bracket = false): ViewExpr => ({ k: "field", target, name, bracket }),
  index: (target: ViewExpr, index: ViewExpr): ViewExpr => ({ k: "index", target, index }),
  nonnull: (target: ViewExpr): ViewExpr => ({ k: "nonnull", target }),
  /** Explicit parentheses: grouping only, no change in meaning. */
  group: (inner: ViewExpr): ViewExpr => ({ k: "group", inner }),
  length: (target: ViewExpr): ViewExpr => ({ k: "length", target }),
  call: (fn: string, ...args: ViewExpr[]): ViewExpr => ({ k: "call", fn, args }),
  binary: (op: string, left: ViewExpr, right: ViewExpr, paren = true): ViewExpr => ({ k: "binary", op, left, right, paren }),
  unary: (op: "!" | "-", operand: ViewExpr, paren = true): ViewExpr => ({ k: "unary", op, operand, paren }),
  cond: (test: ViewExpr, then: ViewExpr, otherwise: ViewExpr): ViewExpr => ({ k: "cond", test, then, otherwise }),
  nullish: (left: ViewExpr, right: ViewExpr): ViewExpr => ({ k: "nullish", left, right }),
  object: (type: ViewRecordType, props: readonly ViewProp[], name?: string): ViewExpr => ({ k: "object", type, props, name }),
  array: (items: readonly ViewExpr[]): ViewExpr => ({ k: "array", items }),
  encode: (value: ViewExpr): ViewExpr => ({ k: "encode", value }),
  decode: (value: ViewExpr): ViewExpr => ({ k: "decode", value }),
  string: (value: ViewExpr): ViewExpr => ({ k: "string", value }),
  from: (value: ViewExpr): ViewExpr => ({ k: "from", value }),
  pack: (msg: ViewExpr): ViewExpr => ({ k: "pack", msg }),
  labelBytes: (list: ViewExpr, bytes: boolean): ViewExpr => ({ k: "label_bytes", list, bytes }),
  float32: (bytes: ViewExpr, offset: number): ViewExpr => ({ k: "float32", bytes, offset }),
  emptyBytes: (): ViewExpr => ({ k: "empty_bytes" }),
  prop: (key: string, value: ViewExpr, quoted = false): ViewProp => ({ key, value, quoted }),
};

export const s = {
  const: (name: string, init: ViewExpr, type?: string): ViewStmt => ({ k: "const", name, type, init }),
  expr: (expr: ViewExpr): ViewStmt => ({ k: "expr", expr }),
  assign: (target: ViewExpr, value: ViewExpr): ViewStmt => ({ k: "assign", target, value }),
  push: (target: ViewExpr, value: ViewExpr): ViewStmt => ({ k: "push", target, value }),
  if: (test: ViewExpr, then: readonly ViewStmt[], otherwise?: readonly ViewStmt[]): ViewStmt => ({ k: "if", test, then, otherwise }),
  for: (name: string, items: ViewExpr, body: readonly ViewStmt[]): ViewStmt => ({ k: "for", name, items, body }),
  throwIf: (test: ViewExpr, message: string): ViewStmt => ({ k: "throw_if", test, message }),
};

// ------------------------------------------------------------ printing

export function printExpr(e: ViewExpr): string {
  switch (e.k) {
    case "num": return e.text;
    case "str": return JSON.stringify(e.value);
    case "bool": return e.value ? "true" : "false";
    case "undefined": return "undefined";
    case "null": return "null";
    case "id": return e.name;
    case "field": return e.bracket ? `${printExpr(e.target)}[${JSON.stringify(e.name)}]` : `${printExpr(e.target)}.${e.name}`;
    case "index": return `${printExpr(e.target)}[${printExpr(e.index)}]`;
    case "nonnull": return `${printExpr(e.target)}!`;
    case "group": return `(${printExpr(e.inner)})`;
    case "length": return `${printExpr(e.target)}.length`;
    case "call": return `${e.fn}(${e.args.map(printExpr).join(", ")})`;
    case "binary": {
      const text = `${printExpr(e.left)} ${e.op} ${printExpr(e.right)}`;
      return e.paren ? `(${text})` : text;
    }
    case "unary": return e.paren ? `(${e.op}${printExpr(e.operand)})` : `${e.op}${printExpr(e.operand)}`;
    case "cond": return `(${printExpr(e.test)}) ? ${printExpr(e.then)} : ${printExpr(e.otherwise)}`;
    case "nullish": return `${printExpr(e.left)} ?? ${printExpr(e.right)}`;
    case "object": return `{ ${e.props.map(p => `${p.quoted ? JSON.stringify(p.key) : p.key}: ${printExpr(p.value)}`).join(", ")} }`;
    case "array": return `[${e.items.map(printExpr).join(", ")}]`;
    case "encode": return `new TextEncoder().encode(${printExpr(e.value)})`;
    case "decode": return `new TextDecoder().decode(${printExpr(e.value)})`;
    case "string": return `String(${printExpr(e.value)})`;
    case "from": return `Array.from(${printExpr(e.value)})`;
    case "pack": return `Array.from(nscfPackMsg(${printExpr(e.msg)}))`;
    case "label_bytes": return `${printExpr(e.list)}.map(value => nscvTextBytes([${e.bytes ? "value" : "new TextEncoder().encode(value)"}]))`;
    case "float32": return `new DataView(${printExpr(e.bytes)}.buffer).getFloat32(${e.offset}, true)`;
    case "empty_bytes": return "new Uint8Array(0)";
  }
}

/** One line per simple statement; blocks open and close on their own lines. */
export function printStatements(statements: readonly ViewStmt[], out: string[] = []): string[] {
  for (const st of statements) {
    switch (st.k) {
      case "const": out.push(`const ${st.name}${st.type ? ": " + st.type : ""} = ${printExpr(st.init)};`); break;
      case "expr": out.push(`${printExpr(st.expr)};`); break;
      case "assign": out.push(`${printExpr(st.target)} = ${printExpr(st.value)};`); break;
      case "push": out.push(`${printExpr(st.target)}.push(${printExpr(st.value)});`); break;
      case "if":
        out.push(`if (${printExpr(st.test)}) {`); printStatements(st.then, out); out.push("}");
        if (st.otherwise) { out.push("else {"); printStatements(st.otherwise, out); out.push("}"); }
        break;
      case "for": out.push(`for (const ${st.name} of ${printExpr(st.items)}) {`); printStatements(st.body, out); out.push("}"); break;
      case "throw_if": out.push(`if (${printExpr(st.test)}) throw new Error(${JSON.stringify(st.message)});`); break;
    }
  }
  return out;
}

// ------------------------------------------------------------ encoding

/** One compiled view per root: the main view and each declared window. */
export interface ViewProgram {
  readonly main: readonly ViewStmt[];
  readonly windows: readonly { readonly label: string; readonly body: readonly ViewStmt[]; readonly attribution?: string }[];
  /** Where each view's nodes were authored, as a JSON fragment of the
   * development records (development compiles only; empty otherwise). */
  readonly mainAttribution?: string;
}

const exprKinds = ["num", "str", "bool", "undefined", "null", "id", "field", "index", "nonnull", "group", "length", "call", "binary", "unary", "cond", "nullish", "object", "array", "encode", "decode", "string", "from", "pack", "label_bytes", "float32", "empty_bytes"] as const;
const stmtKinds = ["const", "expr", "assign", "push", "if", "for", "throw_if"] as const;

/** The binary program the development evaluator reads (view_evaluator.ts).
 * `identity` names the app build the program was compiled against.
 */
export function encodeViewProgram(program: ViewProgram, identity: string): Uint8Array {
  const bytes: number[] = [];
  const u8 = (value: number) => bytes.push(value & 255);
  const u32 = (value: number) => { for (let i = 0; i < 4; i++) bytes.push((value >>> (8 * i)) & 255); };
  const str = (value: string) => { const encoded = new TextEncoder().encode(value); u32(encoded.length); for (const byte of encoded) bytes.push(byte); };
  const f64 = (value: number) => { const view = new DataView(new ArrayBuffer(8)); view.setFloat64(0, value, true); for (let i = 0; i < 8; i++) bytes.push(view.getUint8(i)); };
  const expr = (e: ViewExpr): void => {
    u8(exprKinds.indexOf(e.k));
    switch (e.k) {
      case "num": {
        const value = Number(e.text);
        if (!Number.isFinite(value)) throw new Error("view program number is not finite");
        f64(value); break;
      }
      case "str": str(e.value); break;
      case "bool": u8(e.value ? 1 : 0); break;
      case "undefined": case "null": case "empty_bytes": break;
      case "id": str(e.name); break;
      case "field": expr(e.target); str(e.name); break;
      case "index": expr(e.target); expr(e.index); break;
      case "nonnull": case "length": expr(e.target); break;
      case "group": expr(e.inner); break;
      case "call": str(e.fn); u32(e.args.length); e.args.forEach(expr); break;
      case "binary": str(e.op); expr(e.left); expr(e.right); break;
      case "unary": u8(e.op === "!" ? 0 : 1); expr(e.operand); break;
      case "cond": expr(e.test); expr(e.then); expr(e.otherwise); break;
      case "nullish": expr(e.left); expr(e.right); break;
      case "object": str(e.type); str(e.name ?? ""); u32(e.props.length); for (const prop of e.props) { str(prop.key); expr(prop.value); } break;
      case "array": u32(e.items.length); e.items.forEach(expr); break;
      case "encode": case "decode": case "string": case "from": expr(e.value); break;
      case "pack": expr(e.msg); break;
      case "label_bytes": expr(e.list); u8(e.bytes ? 1 : 0); break;
      case "float32": expr(e.bytes); u32(e.offset); break;
    }
  };
  const block = (statements: readonly ViewStmt[]): void => { u32(statements.length); statements.forEach(stmt); };
  const stmt = (st: ViewStmt): void => {
    u8(stmtKinds.indexOf(st.k));
    switch (st.k) {
      case "const": str(st.name); expr(st.init); break;
      case "expr": expr(st.expr); break;
      case "assign": case "push": expr(st.target); expr(st.value); break;
      case "if": expr(st.test); block(st.then); if (st.otherwise) { u8(1); block(st.otherwise); } else u8(0); break;
      case "for": str(st.name); expr(st.items); block(st.body); break;
      case "throw_if": expr(st.test); str(st.message); break;
    }
  };
  for (const byte of [78, 83, 86, 80]) u8(byte);
  u32(1); str(identity);
  u32(1 + program.windows.length);
  str(""); block(program.main); str(program.mainAttribution ?? "");
  for (const window of program.windows) { str(window.label); block(window.body); str(window.attribution ?? ""); }
  return Uint8Array.from(bytes);
}

/** First compiled-view surface: scalar bindings, void events and counter widgets.
 * This frontend emits typed code beside the committed core, shared by every
 * build mode. Unsupported markup is a build error, never an interpreter fallback.
 */
type Scalar = "number" | "boolean";
interface Ref { kind: string }
export interface ViewContract {
  model: string;
  types: { structs: { name: string; fields: { name: string; type: Ref }[] }[] };
  model_helpers: { name: string; params: Ref[]; returns: Ref }[];
  msg: { arms: { name: string; payload: Ref }[] };
}
interface Element { name: string; attrs: Map<string, string>; children: Element[]; text: string; at: number }
interface Expr { code: string; type: Scalar }

export function compileView(source: string, contract: ViewContract): string {
  const fail: (at: number, message: string) => never = (at, message) => {
    const before = source.slice(0, at).split("\n");
    throw new Error(`app.native:${before.length}:${before.at(-1)!.length + 1}: compiled TypeScript view: ${message}`);
  };
  if (new TextEncoder().encode(source).length > 64 * 1024) fail(0, "source exceeds 64 KiB");
  if (contract.types.structs.some(item => item.name === "NscViewNode") || contract.model_helpers.some(item => ["NscViewNode", "native_view", "JSON", "TextEncoder"].includes(item.name))) {
    fail(0, "core name collides with compiled view wiring (NscViewNode, native_view, JSON or TextEncoder)");
  }
  let pos = 0;
  let count = 0;
  const decode = (raw: string, at: number): string => raw.replace(/&([^;\s]*);|&/g, (_all, entity: string | undefined) => {
    const known: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
    if (entity && Object.hasOwn(known, entity)) return known[entity]!;
    return fail(at, `unsupported entity &${entity ?? ""};`);
  });
  const skip = () => {
    for (;;) {
      while (/\s/.test(source[pos] ?? "") && pos < source.length) pos++;
      if (!source.startsWith("<!--", pos)) return;
      const end = source.indexOf("-->", pos + 4);
      if (end < 0) fail(pos, "unterminated comment");
      pos = end + 3;
    }
  };
  const element = (depth: number): Element => {
    skip();
    const at = pos;
    if (depth > 64 || ++count > 1024) fail(at, "view exceeds 64 levels or 1024 elements");
    const start = /^<([a-z][a-z0-9-]*)\b/.exec(source.slice(pos));
    if (!start) fail(pos, "expected an element");
    pos += start[0].length;
    const node: Element = { name: start[1]!, attrs: new Map(), children: [], text: "", at };
    for (;;) {
      while (/\s/.test(source[pos] ?? "") && pos < source.length) pos++;
      if (source.startsWith("/>", pos)) { pos += 2; return node; }
      if (source[pos] === ">") { pos++; break; }
      const attr = /^([a-z][a-z0-9-]*)\s*=\s*"([^"]*)"/.exec(source.slice(pos));
      if (!attr) fail(pos, "expected a quoted attribute or >");
      if (node.attrs.has(attr[1]!)) fail(pos, `duplicate attribute ${attr[1]}`);
      node.attrs.set(attr[1]!, decode(attr[2]!, pos));
      pos += attr[0].length;
    }
    for (;;) {
      if (pos >= source.length) fail(at, `unclosed <${node.name}>`);
      if (source.startsWith("<!--", pos)) {
        const end = source.indexOf("-->", pos + 4);
        if (end < 0) fail(pos, "unterminated comment");
        pos = end + 3; continue;
      }
      if (source.startsWith("</", pos)) {
        const close = /^<\/([a-z][a-z0-9-]*)\s*>/.exec(source.slice(pos));
        if (!close || close[1] !== node.name) fail(pos, `expected </${node.name}>`);
        pos += close[0].length;
        return node;
      }
      if (source[pos] === "<") node.children.push(element(depth + 1));
      else {
        const end = source.indexOf("<", pos);
        const stop = end < 0 ? source.length : end;
        node.text += decode(source.slice(pos, stop), pos);
        pos = stop;
      }
    }
  };
  const root = element(0);
  skip();
  if (pos !== source.length) fail(pos, "expected exactly one root element");
  const scalar = (ref: Ref): Scalar | null => ref.kind === "bool" ? "boolean" : ["i64", "f64"].includes(ref.kind) ? "number" : null;
  const fields = contract.types.structs.find(item => item.name === contract.model)?.fields;
  if (!fields) fail(0, "contract has no model fields");
  const expression = (raw: string, at: number): Expr => {
    const tokens: string[] = [];
    let offset = 0;
    while (offset < raw.length) {
      const token = /^\s*(\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|===|!==|<=|>=|&&|\|\||[()!+*\/<>=-])/.exec(raw.slice(offset));
      if (!token) {
        if (raw.slice(offset).trim() === "") break;
        fail(at, `unsupported expression ${raw}`);
      }
      tokens.push(token[1]!); offset += token[0].length;
      if (tokens.length > 128) fail(at, "expression exceeds 128 tokens");
    }
    let cursor = 0;
    const precedences: Record<string, number> = { "||": 1, "&&": 2, "===": 3, "!==": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6 };
    const parse = (min: number): Expr => {
      const token = tokens[cursor++];
      let left: Expr;
      if (token === "(") {
        left = parse(0);
        if (tokens[cursor++] !== ")") fail(at, "expected )");
      } else if (token === "!" || token === "-") {
        const inner = parse(7);
        const expected = token === "!" ? "boolean" : "number";
        if (inner.type !== expected) fail(at, `${token} requires ${expected}`);
        left = { code: `(${token}${inner.code})`, type: expected };
      } else if (token === "true" || token === "false") left = { code: token, type: "boolean" };
      else if (token && /^\d/.test(token)) {
        if (!Number.isFinite(Number(token))) fail(at, "non-finite literal");
        left = { code: token, type: "number" };
      } else {
        const field = fields!.find(item => item.name === token);
        const helper = contract.model_helpers.find(item => item.name === token && item.params.length === 0);
        const type = field ? scalar(field.type) : helper ? scalar(helper.returns) : null;
        if (!type) fail(at, `unknown or unsupported scalar binding ${token ?? "(empty)"}`);
        left = { code: field ? `nscfCommitted[${JSON.stringify(token)}]` : `${token}(nscfCommitted)`, type };
      }
      for (;;) {
        const op = tokens[cursor];
        const precedence = op && Object.hasOwn(precedences, op) ? precedences[op] : undefined;
        if (precedence === undefined || precedence < min) break;
        cursor++;
        const right = parse(precedence + 1);
        const logical = op === "&&" || op === "||";
        const equality = op === "===" || op === "!==";
        const comparison = ["<", "<=", ">", ">="].includes(op!);
        if (left.type !== right.type || (logical ? left.type !== "boolean" : !equality && left.type !== "number")) fail(at, `invalid operands for ${op}`);
        left = { code: `(${left.code} ${op} ${right.code})`, type: logical || equality || comparison ? "boolean" : "number" };
      }
      return left;
    };
    const result = parse(0);
    if (cursor !== tokens.length) fail(at, `unsupported expression ${raw}`);
    return result;
  };
  const bound = (raw: string, type: Scalar, at: number): string => {
    const inner = /^\{([^{}]*)\}$/.exec(raw);
    const expr = expression(inner ? inner[1]! : raw, at);
    if (expr.type !== type) fail(at, `expected ${type} binding`);
    return expr.code;
  };
  const text = (raw: string, at: number): string => {
    const parts: string[] = [];
    let last = 0;
    for (const match of raw.matchAll(/\{([^{}]*)\}/g)) {
      parts.push(JSON.stringify(raw.slice(last, match.index)), `String(${expression(match[1]!, at).code})`);
      last = match.index + match[0].length;
    }
    const tail = raw.slice(last);
    parts.push(JSON.stringify(tail));
    if (raw.replace(/\{[^{}]*\}/g, "").match(/[{}]/)) fail(at, "unbalanced text binding");
    return parts.join(" + ");
  };
  const output: string[] = [];
  let next = 0;
  const emitChildren = (nodes: Element[]) => {
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i]!;
      if (node.name === "else") fail(node.at, "else must immediately follow if");
      if (node.name !== "if") { emit(node); continue; }
      if (node.attrs.size !== 1 || !node.attrs.has("test") || node.text.trim()) fail(node.at, "if requires only test and child elements");
      output.push(`if (${bound(node.attrs.get("test")!, "boolean", node.at)}) {`);
      emitChildren(node.children); output.push("}");
      const alternate = nodes[i + 1];
      if (alternate?.name === "else") {
        if (alternate.attrs.size || alternate.text.trim()) fail(alternate.at, "else accepts only child elements");
        output.push("else {"); emitChildren(alternate.children); output.push("}"); i++;
      }
    }
  };
  const emit = (node: Element) => {
    const kinds: Record<string, string> = { column: "column", row: "row", text: "text", button: "button", switch: "switch_control", "status-bar": "status_bar" };
    if (!Object.hasOwn(kinds, node.name)) fail(node.at, `unsupported element <${node.name}>`);
    const kind = kinds[node.name];
    if (!kind) fail(node.at, `unsupported element <${node.name}>`);
    const container = node.name === "column" || node.name === "row";
    if (container ? node.text.trim() !== "" : node.children.length !== 0) fail(node.at, "mixed content is unsupported");
    const props: string[] = [`kind: ${JSON.stringify(kind)}`, `text: ${text(node.text.trim(), node.at)}`];
    for (const [name, value] of node.attrs) {
      if (["gap", "padding", "grow"].includes(name)) props.push(`${name}: ${bound(value, "number", node.at)}`);
      else if (name === "checked" || name === "disabled") {
        if (name === "checked" && node.name !== "switch") fail(node.at, "checked requires switch");
        props.push(`${name}: ${bound(value, "boolean", node.at)}`);
      } else if (name === "key") {
        if (/[{}]/.test(value) || /^(?:[-+]?\d|[.][-+]?\d|true$|false$)/.test(value)) fail(node.at, "keys must be literal strings starting with a nonnumeric character");
        props.push(`key: ${JSON.stringify(value)}`);
      } else if (["main", "cross", "size", "variant"].includes(name)) {
        const vocab: Record<string, string[]> = { main: ["start", "center", "end", "space_between"], cross: ["start", "center", "end", "stretch"], size: ["default", "sm", "lg"], variant: ["default", "primary", "secondary", "ghost", "destructive"] };
        if (!vocab[name]!.includes(value)) fail(node.at, `unsupported ${name}=${value}`);
        props.push(`${name}: ${JSON.stringify(value)}`);
      } else if (name === "on-press" || name === "on-toggle") {
        if (name === "on-press" ? node.name !== "button" : node.name !== "switch") fail(node.at, `${name} is unsupported on ${node.name}`);
        const tag = contract.msg.arms.findIndex(arm => arm.name === value && arm.payload.kind === "void");
        if (tag < 0 || tag > 255) fail(node.at, `event ${value} must name a void Msg arm`);
        props.push(`${name === "on-press" ? "press" : "toggle"}: ${tag}`);
      } else fail(node.at, `unsupported attribute ${name}`);
    }
    const id = next++;
    output.push(`const nscvNode${id}: NscViewNode = { end: 0, ${props.join(", ")} };`, `nscvNodes.push(nscvNode${id});`);
    emitChildren(node.children);
    output.push(`nscvNode${id}.end = nscvNodes.length;`);
  };
  emit(root);
  return `\n// Generated Native markup; reads the actual committed TypeScript model.\n` +
    `type NscViewNode = { end: number; kind: string; text: string; key?: string; gap?: number; padding?: number; grow?: number; main?: string; cross?: string; size?: string; variant?: string; checked?: boolean; disabled?: boolean; press?: number; toggle?: number };\n` +
    `export function native_view(): Uint8Array {\nconst nscvNodes: NscViewNode[] = [];\n${output.join("\n")}\nreturn new TextEncoder().encode(JSON.stringify({ format: 1, nodes: nscvNodes }));\n}\n`;
}

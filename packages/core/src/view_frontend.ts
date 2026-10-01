/** Native markup compiled beside the committed TypeScript core. Unsupported
 * constructs fail at build time; no bindings are evaluated by the native host.
 */
interface Ref { kind: string; name?: string; elem?: Ref; inner?: Ref; class?: string; type?: Ref }
interface Arm { name: string; member?: string; payload: Ref }
export interface ViewContract {
  model: string;
  types: { structs: { name: string; fields: { name: string; type: Ref }[] }[]; enums?: { name: string; members: string[] }[]; unions?: { name: string; arms?: Arm[] }[] };
  model_helpers: { name: string; params: Ref[]; returns: Ref }[];
  msg: { name?: string; arms: Arm[] };
}
interface Element { name: string; attrs: Map<string, string>; children: Element[]; text: string; at: number; file: string }
interface Expr { code: string; type: Ref }
type Scope = ReadonlyMap<string, Expr>;
interface Slot { children: Element[]; scope: Scope; slot?: Slot }
export interface ViewSources { entry?: string; sources?: ReadonlyMap<string, string> }

export function compileView(source: string, contract: ViewContract, options: ViewSources = {}): string {
  const entry = options.entry ?? "app.native";
  const sources = new Map(options.sources); sources.set(entry, source);
  const fail: (node: Pick<Element, "file" | "at">, message: string) => never = (node, message) => {
    const before = sources.get(node.file)!.slice(0, node.at).split("\n");
    throw new Error(`${node.file}:${before.length}:${before.at(-1)!.length + 1}: compiled TypeScript view: ${message}`);
  };
  const origin = { file: entry, at: 0 };
  const reserved = ["NscViewNode", "native_view", "JSON", "TextEncoder", "TextDecoder", "String", "Number", "Array"];
  const names = [...contract.types.structs, ...contract.types.enums ?? [], ...contract.types.unions ?? [], ...contract.model_helpers];
  if (names.some(item => reserved.includes(item.name) || item.name.startsWith("nscv")) || reserved.includes(contract.msg.name ?? "")) {
    fail(origin, "core name collides with compiled view wiring");
  }
  let count = 0, sourceBytes = 0;
  const parse = (file: string): Element[] => {
    const src = sources.get(file)!;
    sourceBytes += new TextEncoder().encode(src).length;
    if (sourceBytes > 64 * 1024) fail({ file, at: 0 }, "source closure exceeds 64 KiB");
    let pos = 0;
    const error: (message: string) => never = message => fail({ file, at: pos }, message);
    const decode = (raw: string): string => raw.replace(/&([^;\s]*);|&/g, (_all, entity: string | undefined) => {
      const known: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
      if (entity && Object.hasOwn(known, entity)) return known[entity]!;
      return error(`unsupported entity &${entity ?? ""};`);
    });
    const skip = () => {
      for (;;) {
        while (/\s/.test(src[pos] ?? "") && pos < src.length) pos++;
        if (!src.startsWith("<!--", pos)) return;
        const end = src.indexOf("-->", pos + 4);
        if (end < 0) error("unterminated comment");
        pos = end + 3;
      }
    };
    const element = (depth: number): Element => {
      skip();
      const at = pos;
      if (depth > 64 || ++count > 1024) error("view exceeds 64 levels or 1024 elements");
      const start = /^<([a-z][a-z0-9-]*)\b/.exec(src.slice(pos));
      if (!start) error("expected an element");
      pos += start[0].length;
      const node: Element = { name: start[1]!, attrs: new Map(), children: [], text: "", at, file };
      for (;;) {
        while (/\s/.test(src[pos] ?? "") && pos < src.length) pos++;
        if (src.startsWith("/>", pos)) { pos += 2; return node; }
        if (src[pos] === ">") { pos++; break; }
        const attr = /^([a-z][a-z0-9-]*)\s*=\s*"([^"]*)"/.exec(src.slice(pos));
        if (!attr) error("expected a quoted attribute or >");
        if (node.attrs.has(attr[1]!)) error(`duplicate attribute ${attr[1]}`);
        node.attrs.set(attr[1]!, decode(attr[2]!)); pos += attr[0].length;
      }
      for (;;) {
        if (pos >= src.length) fail(node, `unclosed <${node.name}>`);
        if (src.startsWith("<!--", pos)) {
          const end = src.indexOf("-->", pos + 4);
          if (end < 0) error("unterminated comment");
          pos = end + 3; continue;
        }
        if (src.startsWith("</", pos)) {
          const close = /^<\/([a-z][a-z0-9-]*)\s*>/.exec(src.slice(pos));
          if (!close || close[1] !== node.name) error(`expected </${node.name}>`);
          pos += close[0].length; return node;
        }
        if (src[pos] === "<") node.children.push(element(depth + 1));
        else {
          const end = src.indexOf("<", pos), stop = end < 0 ? src.length : end;
          node.text += decode(src.slice(pos, stop)); pos = stop;
        }
      }
    };
    const nodes: Element[] = []; skip();
    while (pos < src.length) { nodes.push(element(0)); skip(); }
    return nodes;
  };
  const templates = new Map<string, Element>(), loaded = new Set<string>();
  const load = (file: string, stack: string[]): Element[] => {
    if (stack.includes(file)) fail({ file, at: 0 }, "cyclic markup import");
    if (loaded.has(file)) return [];
    loaded.add(file);
    const roots: Element[] = [];
    for (const node of parse(file)) {
      if (node.name === "import") {
        if (node.attrs.size !== 1 || !node.attrs.has("src") || node.children.length || node.text.trim()) fail(node, "import requires only src");
        const raw = node.attrs.get("src")!;
        if (!raw || raw.startsWith("/") || /[\\:\0]/.test(raw)) fail(node, "import must be a relative markup path");
        const parts = file.split("/").slice(0, -1);
        for (const part of raw.split("/")) {
          if (part === "..") { if (!parts.length) fail(node, "import escapes the source directory"); parts.pop(); }
          else if (part && part !== ".") parts.push(part);
        }
        const target = parts.join("/");
        if (!sources.has(target)) fail(node, `missing imported source ${target}`);
        if (load(target, [...stack, file]).length) fail(node, "imported files may contain only imports and templates");
      } else if (node.name === "template") {
        const name = node.attrs.get("name");
        if (!name || !/^[a-z][a-z0-9-]*$/.test(name) || templates.has(name)) fail(node, "invalid or duplicate template name");
        if ([...node.attrs.keys()].some(key => key !== "name" && key !== "args") || node.text.trim()) fail(node, "template accepts only name, args and child elements");
        templates.set(name, node);
      } else roots.push(node);
    }
    return roots;
  };
  const roots = load(entry, []);
  if (roots.length !== 1) fail(origin, "expected exactly one root element");
  const fields = contract.types.structs.find(item => item.name === contract.model)?.fields;
  if (!fields) fail(origin, "contract has no model fields");
  const category = (ref: Ref): string => ["i64", "f64"].includes(ref.kind) ? "number" : ref.kind === "bool" ? "boolean" : ref.kind;
  const path = (raw: string, node: Element, scope: Scope): Expr => {
    if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(raw)) fail(node, `unsupported binding path ${raw}`);
    const [name, ...members] = raw.split(".");
    const field = fields!.find(item => item.name === name);
    const helper = contract.model_helpers.find(item => item.name === name && item.params.length === 0);
    let value = scope.get(name!) ?? (field ? { code: `nscfCommitted[${JSON.stringify(name)}]`, type: field.type } : helper ? { code: `${name}(nscfCommitted)`, type: helper.returns } : null);
    if (!value) fail(node, `unknown binding ${name}`);
    for (const member of members) {
      const record: ViewContract["types"]["structs"][number] | undefined = ["node", "value"].includes(value.type.kind) ? contract.types.structs.find(item => item.name === value!.type.name) : undefined;
      const next: { name: string; type: Ref } | undefined = record?.fields.find(item => item.name === member);
      if (!next) fail(node, `unsupported field ${member} on ${raw}`);
      value = { code: `${value.code}[${JSON.stringify(member)}]`, type: next.type };
    }
    return value;
  };
  const expression = (raw: string, node: Element, scope: Scope): Expr => {
    const tokens: string[] = []; let offset = 0;
    while (offset < raw.length) {
      const token = /^\s*('[^'\\]*'|\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|===|!==|==|!=|<=|>=|&&|\|\||[()!+*\/<>=-])/.exec(raw.slice(offset));
      if (!token) { if (!raw.slice(offset).trim()) break; fail(node, `unsupported expression ${raw}`); }
      tokens.push(token[1]!); offset += token[0].length;
      if (tokens.length > 128) fail(node, "expression exceeds 128 tokens");
    }
    let cursor = 0;
    const precedences: Record<string, number> = { "||": 1, "&&": 2, "===": 3, "!==": 3, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6 };
    const parseExpr = (min: number): Expr => {
      const token = tokens[cursor++]; let left: Expr;
      if (token === "(") { left = parseExpr(0); if (tokens[cursor++] !== ")") fail(node, "expected )"); }
      else if (token === "!" || token === "-") {
        const inner = parseExpr(7), expected = token === "!" ? "boolean" : "number";
        if (category(inner.type) !== expected) fail(node, `${token} requires ${expected}`);
        left = { code: `(${token}${inner.code})`, type: { kind: token === "!" ? "bool" : "f64" } };
      } else if (token === "true" || token === "false") left = { code: token, type: { kind: "bool" } };
      else if (token?.startsWith("'")) left = { code: JSON.stringify(token.slice(1, -1)), type: { kind: "string", name: token.slice(1, -1) } };
      else if (token && /^\d/.test(token)) {
        if (!Number.isFinite(Number(token))) fail(node, "non-finite literal");
        left = { code: token, type: { kind: token.includes(".") ? "f64" : "i64" } };
      } else left = path(token ?? "", node, scope);
      for (;;) {
        const op = tokens[cursor], precedence = op && Object.hasOwn(precedences, op) ? precedences[op] : undefined;
        if (precedence === undefined || precedence < min) break;
        cursor++; const right = parseExpr(precedence + 1);
        const logical = op === "&&" || op === "||", equality = ["==", "!=", "===", "!=="].includes(op!);
        const comparison = ["<", "<=", ">", ">="].includes(op!);
        let valid = category(left.type) === category(right.type) && (logical ? category(left.type) === "boolean" : category(left.type) === "number" || equality && category(left.type) === "boolean");
        if (equality && [left.type.kind, right.type.kind].includes("enum")) {
          const enumRef = left.type.kind === "enum" ? left : right, literal = left.type.kind === "string" ? left : right;
          valid = literal.type.kind === "string" && !!contract.types.enums?.find(item => item.name === enumRef.type.name)?.members.includes(literal.type.name!);
        }
        if (!valid) fail(node, `invalid operands for ${op}`);
        left = { code: `(${left.code} ${op === "==" ? "===" : op === "!=" ? "!==" : op} ${right.code})`, type: { kind: logical || equality || comparison ? "bool" : "f64" } };
      }
      return left;
    };
    const result = parseExpr(0);
    if (cursor !== tokens.length) fail(node, `unsupported expression ${raw}`);
    return result;
  };
  const binding = (raw: string, node: Element, scope: Scope): Expr => expression(/^\{([^{}]*)\}$/.exec(raw)?.[1] ?? raw, node, scope);
  const bound = (raw: string, type: string, node: Element, scope: Scope): string => {
    const expr = binding(raw, node, scope);
    if (category(expr.type) !== type) fail(node, `expected ${type} binding`);
    return expr.code;
  };
  const textValue = (expr: Expr, node: Element): string => {
    if (expr.type.kind === "bytes") return `new TextDecoder().decode(${expr.code})`;
    if (["number", "boolean", "enum", "string"].includes(category(expr.type))) return `String(${expr.code})`;
    return fail(node, "text requires bytes, an enum or a scalar binding");
  };
  const text = (raw: string, node: Element, scope: Scope): string => {
    const parts: string[] = []; let last = 0;
    for (const match of raw.matchAll(/\{([^{}]*)\}/g)) {
      parts.push(JSON.stringify(raw.slice(last, match.index)), textValue(expression(match[1]!, node, scope), node)); last = match.index + match[0].length;
    }
    parts.push(JSON.stringify(raw.slice(last)));
    if (raw.replace(/\{[^{}]*\}/g, "").match(/[{}]/)) fail(node, "unbalanced text binding");
    return parts.join(" + ");
  };
  const key = (raw: string, node: Element, scope: Scope): Expr => {
    if (/^-?\d+$/.test(raw)) {
      if (!Number.isSafeInteger(Number(raw))) fail(node, "key is not an exact integer");
      return { code: `nscvInteger(${raw})`, type: { kind: "i64" } };
    }
    if (!raw.startsWith("{")) {
      if (/^(?:[-+]?\d|[.]\d|true$|false$)/.test(raw)) fail(node, "keys must be integers or strings");
      return { code: JSON.stringify(raw), type: { kind: "string" } };
    }
    const expr = binding(raw, node, scope);
    if (expr.type.kind !== "i64" && expr.type.kind !== "bytes" && expr.type.kind !== "string") fail(node, "keys must be integers or strings");
    return expr.type.kind === "i64" ? { code: `nscvInteger(${expr.code})`, type: expr.type } : { code: textValue(expr, node), type: { kind: "string" } };
  };
  const output: string[] = []; let next = 0;
  const textInputUnion = (ref: Ref): boolean => {
    const arms = ref.kind === "union" ? contract.types.unions?.find(item => item.name === ref.name)?.arms : undefined;
    const verbs = ["delete_backward", "delete_forward", "delete_word_backward", "delete_word_forward", "delete_to_start", "delete_to_line_start", "clear", "commit_composition", "cancel_composition"];
    if (!arms || arms.length !== 13 || !verbs.every(name => arms.some(arm => arm.name === name && arm.payload.kind === "void"))) return false;
    const payload = (name: string) => arms.find(arm => arm.name === name)?.payload;
    const record = (name: string) => {
      const type = payload(name);
      return type && ["value", "record"].includes(type.kind) ? contract.types.structs.find(item => item.name === type.name)?.fields : undefined;
    };
    const move = record("move_caret"), selection = record("set_selection"), composition = record("set_composition");
    const direction = move?.find(field => field.name === "direction")?.type;
    const members = direction?.kind === "enum" ? contract.types.enums?.find(item => item.name === direction.name)?.members : undefined;
    const directions = ["previous", "next", "previous_word", "next_word", "start", "end"];
    const cursor = composition?.find(field => field.name === "cursor")?.type;
    return payload("insert_text")?.kind === "bytes" && move?.length === 2 &&
      !!members && members.length === 6 && directions.every(name => members.includes(name)) &&
      move.some(field => field.name === "extend" && field.type.kind === "bool") &&
      selection?.length === 2 && ["anchor", "focus"].every(name => selection.some(field => field.name === name && category(field.type) === "number")) &&
      composition?.length === 2 && composition.some(field => field.name === "text" && field.type.kind === "bytes") &&
      cursor?.kind === "optional" && !!cursor.inner && category(cursor.inner) === "number";
  };
  const emitChildren = (nodes: Element[], scope: Scope, slot: Slot | undefined, stack: string[], depth: number) => {
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i]!;
      if (node.name === "else") fail(node, "else must immediately follow if");
      if (node.name !== "if") { emit(node, scope, slot, stack, depth); continue; }
      if (node.attrs.size !== 1 || !node.attrs.has("test") || node.text.trim()) fail(node, "if requires only test and child elements");
      output.push(`if (${bound(node.attrs.get("test")!, "boolean", node, scope)}) {`);
      emitChildren(node.children, scope, slot, stack, depth + 1); output.push("}");
      const alternate = nodes[i + 1];
      if (alternate?.name === "else") {
        if (alternate.attrs.size || alternate.text.trim()) fail(alternate, "else accepts only child elements");
        output.push("else {"); emitChildren(alternate.children, scope, slot, stack, depth + 1); output.push("}"); i++;
      }
    }
  };
  const event = (raw: string, channel: string, node: Element, scope: Scope): string => {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)(?::\{([^{}]+)\})?$/.exec(raw);
    const arm = contract.msg.arms.find(item => item.name === match?.[1]);
    if (!arm || !match) fail(node, `unknown or unsupported event ${raw}`);
    const payload = match[2] ? path(match[2], node, scope) : null;
    if (channel === "input") {
      if (payload || !textInputUnion(arm.payload)) fail(node, "on-input requires a bare TextInputEvent Msg arm");
      return String(contract.msg.arms.indexOf(arm));
    }
    if (channel === "scroll") {
      const record = arm.payload.kind === "record" ? contract.types.structs.find(item => item.name === arm.payload.name) : null;
      const names = ["offsetX", "offsetY", "velocityX", "velocityY", "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY"];
      if (payload || !record || record.fields.length !== 8 || !names.every(name => record.fields.some(field => field.name === name && category(field.type) === "number"))) fail(node, "on-scroll requires a bare ScrollState Msg arm");
      return String(contract.msg.arms.indexOf(arm));
    }
    let props = `kind: ${JSON.stringify(arm.name)}`;
    if (channel === "drag") {
      const record = arm.payload.kind === "record" ? contract.types.structs.find(item => item.name === arm.payload.name) : null;
      const names = ["sourceId", "phase", "x", "y", "viewWidth", "viewHeight"];
      if (!payload || category(payload.type) !== "number" || !record || record.fields.length !== 6 || !names.every(name => record.fields.some(field => field.name === name && (["x", "y", "viewWidth", "viewHeight"].includes(name) ? field.type.kind === "f64" : category(field.type) === "number")))) fail(node, "on-drag requires a sourceId binding and the six-field drag Msg record");
      props += `, sourceId: ${payload.code}, phase: 0, x: 0, y: 0, viewWidth: 0, viewHeight: 0`;
    } else if (arm.payload.kind === "void") { if (payload) fail(node, "void Msg arm cannot take a payload"); }
    else {
      const type = arm.payload.kind === "number" ? { kind: arm.payload.class ?? "f64" } : arm.payload.kind === "scalar" ? arm.payload.type! : arm.payload;
      if (!payload || !arm.member || category(type) !== category(payload.type) || !["number", "boolean", "bytes"].includes(category(type))) fail(node, "event requires a matching scalar Msg payload binding");
      props += `, ${JSON.stringify(arm.member)}: ${payload.code}`;
    }
    return `Array.from(nscfPackMsg({ ${props} }))`;
  };
  const emit = (node: Element, scope: Scope, slot: Slot | undefined, stack: string[], depth: number): void => {
    if (depth > 64 || next > 4096) fail(node, "expanded view exceeds 64 levels or 4096 elements");
    if (node.name === "use") {
      const name = node.attrs.get("template"), template = name ? templates.get(name) : null;
      if (!template) fail(node, `unknown template ${name}`);
      if (stack.includes(name!)) fail(node, "recursive template use");
      if (node.text.trim()) fail(node, "use accepts only child elements");
      const args = (template.attrs.get("args") ?? "").split(/[\s,]+/).filter(Boolean), inner = new Map<string, Expr>();
      for (const arg of args) {
        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(arg) || inner.has(arg)) fail(template, "invalid or duplicate template argument");
        const raw = node.attrs.get(arg);
        if (raw === undefined) fail(node, `missing template argument ${arg}`);
        const value = raw.startsWith("{") ? binding(raw, node, scope) : { code: JSON.stringify(raw), type: { kind: "string" } };
        const variable = `nscvArg${next++}`; output.push(`const ${variable} = ${value.code};`); inner.set(arg, { ...value, code: variable });
      }
      if ([...node.attrs.keys()].some(arg => arg !== "template" && !args.includes(arg))) fail(node, "unknown template argument");
      emitChildren(template.children, inner, { children: node.children, scope, slot }, [...stack, name!], depth + 1); return;
    }
    if (node.name === "slot") {
      if (!slot || node.attrs.size || node.children.length || node.text.trim()) fail(node, "slot requires a template use and no attributes or children");
      emitChildren(slot.children, slot.scope, slot.slot, stack, depth + 1); return;
    }
    if (node.name === "for") {
      const each = node.attrs.get("each"), as = node.attrs.get("as"), field = node.attrs.get("key");
      if (!each || !as || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(as) || !field || node.attrs.size !== 3 || node.text.trim()) fail(node, "for requires each, as, key and child elements");
      const items = path(each, node, scope);
      if (items.type.kind !== "slice" || !items.type.elem) fail(node, "each requires a list binding");
      const id = next++, variable = `nscvItem${id}`, inner = new Map(scope); inner.set(as, { code: variable, type: items.type.elem });
      const base = key(`{${as}.${field}}`, node, inner);
      output.push(`for (const ${variable} of ${items.code}) {`, `const nscvFirst${id} = nscvNodes.length;`);
      emitChildren(node.children, inner, slot, stack, depth + 1);
      output.push(`nscvLoopKeys(nscvNodes, nscvFirst${id}, ${base.code});`, "}"); return;
    }
    const kinds: Record<string, string> = { column: "column", row: "row", panel: "panel", badge: "badge", input: "input", "search-field": "search_field", text: "text", button: "button", switch: "switch_control", "status-bar": "status_bar", spacer: "spacer", scroll: "scroll", avatar: "avatar" };
    if (!Object.hasOwn(kinds, node.name)) fail(node, `unsupported element <${node.name}>`);
    const container = ["column", "row", "scroll", "panel"].includes(node.name);
    if (container ? node.text.trim() !== "" : node.children.length !== 0) fail(node, "mixed content is unsupported");
    const props: string[] = [`kind: ${JSON.stringify(kinds[node.name])}`, `text: ${text(node.text.trim(), node, scope)}`];
    for (const [name, value] of node.attrs) {
      if (["gap", "padding", "grow", "width", "height", "value", "image"].includes(name)) props.push(`${name}: ${bound(value, "number", node, scope)}`);
      else if (["checked", "disabled", "window-drag", "wrap"].includes(name)) {
        if (name === "checked" && node.name !== "switch") fail(node, "checked requires switch");
        if (name === "wrap" && node.name !== "text") fail(node, "wrap requires text");
        props.push(`${name === "window-drag" ? "windowDrag" : name}: ${bound(value, "boolean", node, scope)}`);
      } else if (name === "key" || name === "global-key") {
        const expr = key(value, node, scope), prop = name === "key" ? "key" : "globalKey";
        props.push(`${prop}${expr.type.kind === "i64" ? "Int" : ""}: ${expr.code}`);
      } else if (["label", "text", "placeholder"].includes(name)) {
        if (name !== "label" && !["input", "search-field"].includes(node.name)) fail(node, `${name} requires a text-entry widget`);
        if (name === "text" && node.text.trim()) fail(node, "text attribute cannot be combined with element text");
        const expr = value.startsWith("{") ? binding(value, node, scope) : { code: JSON.stringify(value), type: { kind: "string" } };
        if (!["bytes", "string", "enum"].includes(expr.type.kind)) fail(node, `${name} requires text`);
        if (name === "text") props[1] = `text: ${textValue(expr, node)}`;
        else props.push(`${name}: ${textValue(expr, node)}`);
      }
      else if (name === "icon") { if (/[{}]/.test(value)) fail(node, "icon requires a literal name"); props.push(`icon: ${JSON.stringify(value)}`); }
      else if (["main", "cross", "size", "variant", "role", "background", "foreground", "radius"].includes(name)) {
        const vocab: Record<string, string[]> = { main: ["start", "center", "end", "space_between"], cross: ["start", "center", "end", "stretch"], size: ["default", "sm", "lg", "icon", "heading"], variant: ["default", "primary", "secondary", "ghost", "destructive", "outline"], role: ["listitem"], background: ["background", "surface"], foreground: ["text", "text_muted", "destructive"], radius: ["sm", "md", "lg"] };
        if (!vocab[name]!.includes(value)) fail(node, `unsupported ${name}=${value}`);
        if (name === "size" && value === "heading" && node.name !== "text") fail(node, "heading size requires text");
        props.push(`${name}: ${JSON.stringify(value)}`);
      } else if (["on-press", "on-toggle", "on-drag", "on-scroll", "on-input", "on-submit"].includes(name)) {
        const channel = name.slice(3);
        if (channel === "press" && node.name !== "button" || channel === "toggle" && node.name !== "switch" || channel === "scroll" && node.name !== "scroll") fail(node, `${name} is unsupported on ${node.name}`);
        if (["input", "submit"].includes(channel) && !["input", "search-field"].includes(node.name)) fail(node, `${name} is unsupported on ${node.name}`);
        props.push(`${channel}: ${event(value, channel, node, scope)}`);
      } else fail(node, `unsupported attribute ${name}`);
    }
    const id = next++;
    output.push(`const nscvNode${id}: NscViewNode = { end: 0, ${props.join(", ")} };`, `nscvNodes.push(nscvNode${id});`, 'if (nscvNodes.length > 1024) throw new Error("compiled view exceeds 1024 nodes");');
    emitChildren(node.children, scope, slot, stack, depth + 1); output.push(`nscvNode${id}.end = nscvNodes.length;`);
  };
  emit(roots[0]!, new Map(), undefined, [], 0);
  return `\n// Generated Native markup; reads the actual committed TypeScript model.\n` +
    `type NscViewNode = { end: number; kind: string; text: string; placeholder?: string; wrap?: boolean; key?: string; keyInt?: number; keySlot?: number; globalKey?: string; globalKeyInt?: number; gap?: number; padding?: number; grow?: number; width?: number; height?: number; value?: number; image?: number; icon?: string; label?: string; role?: string; background?: string; foreground?: string; radius?: string; windowDrag?: boolean; main?: string; cross?: string; size?: string; variant?: string; checked?: boolean; disabled?: boolean; press?: number[]; toggle?: number[]; drag?: number[]; scroll?: number; input?: number; submit?: number[] };\n` +
    `function nscvInteger(value: number): number { if (!Number.isSafeInteger(value)) throw new Error("compiled view key is not an exact integer"); return value; }\n` +
    `function nscvLoopKeys(nodes: NscViewNode[], first: number, base: string | number): void { let slot = 0; for (let i = first; i < nodes.length; i = nodes[i]!.end) { const node = nodes[i]!; if (node.key === undefined && node.keyInt === undefined && node.globalKey === undefined && node.globalKeyInt === undefined) { if (typeof base === "number") node.keyInt = base; else node.key = base; node.keySlot = slot; } slot++; } }\n` +
    `export function native_view(): Uint8Array {\nconst nscvNodes: NscViewNode[] = [];\n${output.join("\n")}\nif (nscvNodes.length === 0 || nscvNodes[0]!.end !== nscvNodes.length) throw new Error("compiled view requires one rendered root");\nreturn new TextEncoder().encode(JSON.stringify({ format: 2, nodes: nscvNodes }));\n}\n`;
}

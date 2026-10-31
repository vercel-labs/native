/** Native markup compiled beside the committed TypeScript core. Unsupported
 * constructs fail at build time; no bindings are evaluated by the native host.
 */
import { portableSourceText } from "./portable_sources.ts";
import { wyhash } from "./wyhash.ts";
import { printStatements, s, v, type ViewExpr, type ViewProgram, type ViewProp, type ViewStmt } from "./view_program.ts";
export type { ViewProgram } from "./view_program.ts";

interface Ref { kind: string; name?: string; elem?: Ref; inner?: Ref; class?: string; type?: Ref }
interface Arm { name: string; member?: string; payload: Ref }
export interface ViewContract {
  model: string;
  types: { structs: { name: string; fields: { name: string; type: Ref }[] }[]; enums?: { name: string; members: string[] }[]; unions?: { name: string; arms?: Arm[] }[] };
  model_helpers: { name: string; params: Ref[]; returns: Ref }[];
  msg: { name?: string; arms: Arm[] };
}
interface Element { name: string; attrs: Map<string, string>; children: Element[]; content: (Element | { text: string; at: number; end: number })[]; text: string; at: number; end: number; file: string }
interface Expr { code: ViewExpr; type: Ref; virtualIndex?: string }
type Scope = ReadonlyMap<string, Expr>;
interface Slot { children: Element[]; scope: Scope; slot?: Slot; chain: readonly ViewSourceSite[] }
export interface ViewSources { entry?: string; sources?: ReadonlyMap<string, string> }

export interface WindowViewSource extends ViewSources { label: string; source: string }

/** Where a view node was authored: a markup file (relative to the app's
 * `src/`, empty for the root view file), the element's UTF-8 byte span,
 * and its 1-based line and byte column.
 */
export interface ViewSourceSite { readonly file: string; readonly start: number; readonly end: number; readonly line: number; readonly column: number }
/** A node's definition site and the `<use>` sites that placed it, outermost first. */
export interface ViewSource extends ViewSourceSite { readonly chain: readonly ViewSourceSite[] }

/** The model names and Msg kinds the compiled views read or dispatch,
 * collected while compiling so `native check` can report model state and
 * messages no view uses.
 */
export interface ViewUsage { readonly model: Set<string>; readonly msg: Set<string> }

const colorTokenNames = ["background", "surface", "surface_subtle", "surface_pressed", "text", "text_muted", "syntax_plain", "syntax_comment", "syntax_keyword", "syntax_literal", "syntax_function", "syntax_property", "syntax_constant", "border", "accent", "accent_text", "destructive", "destructive_text", "success", "success_text", "warning", "warning_text", "info", "info_text", "focus_ring", "shadow", "scrim", "disabled"];

const nonHitTargetNames = ["row", "column", "stack", "list", "grid", "split", "tree", "breadcrumb", "button-group", "pagination", "radio-group", "tabs", "toggle-group", "badge", "avatar", "tooltip", "separator", "spacer", "table", "data-grid", "table-row", "skeleton", "spinner", "icon"];

export function compileView(source: string, contract: ViewContract, options: ViewSources = {}): string {
  return compileViewBundle(source, contract, options, []);
}

/** One shared prelude, primary view, and a closed label-addressed window set.
 * Window source paths are relative to src/windows, preserving its import boundary.
 */
export function compileViewBundle(source: string, contract: ViewContract, options: ViewSources,
  windows: readonly WindowViewSource[], usage?: ViewUsage): string {
  return compileViewProgram(source, contract, options, windows, usage).text;
}

/** The release TypeScript and the program it prints, from one compilation.
 * With `development`, every view export serves the development evaluator's
 * active program when one is prepared (view_evaluator.ts must be staged
 * beside the result); release builds never pass it.
 */
export function compileViewProgram(source: string, contract: ViewContract, options: ViewSources,
  windows: readonly WindowViewSource[], usage?: ViewUsage, development = false): { text: string; program: ViewProgram; virtual: boolean } {
  // Source paths are stamped relative to the app's src/; the root view file
  // is stamped empty, as the native markup engine stamps it.
  const entry = options.entry ?? "app.native";
  const main = compileViewFunction(source, contract, options, "nscvMainView", false, usage, development ? file => file === entry ? "" : file : undefined);
  const program: ViewProgram & { windows: ViewProgram["windows"][number][] } = { main: main.body, mainAttribution: main.attribution, windows: [] };
  // `compiled` reads its video state from `nscvVideo` and is the export's
  // whole result when no development program is active.
  const exported = (signature: string, label: string, video: string, virtual: string, compiled: string): string => development
    ? `export function ${signature}: Uint8Array { const nscvVideo = ${video}; if (nscvdActive()) return nscvdView(${label}, nscvVideo, ${virtual}); return ${compiled}; }\n`
    : `export function ${signature}: Uint8Array { return ${compiled.replace("nscvVideo", video)}; }\n`;
  let generated = viewPrelude + main.text +
    exported("native_view()", "new Uint8Array(0)", "nscvEmptyVideo()", "undefined", "nscvMainView(nscvVideo)") +
    exported("native_media_view(request: Uint8Array)", "new Uint8Array(0)", "nscvVideoState(request)", "undefined", "nscvMainView(nscvVideo)");
  const labels = new Set<string>();
  const branches: string[] = [];
  for (const [index, window] of windows.entries()) {
    if (!window.label || new TextEncoder().encode(window.label).length > 64 ||
      /[\\/\0]/.test(window.label) || [".", ".."].includes(window.label) || labels.has(window.label)) {
      throw new Error("compiled TypeScript view: invalid or duplicate window label");
    }
    labels.add(window.label);
    const compiled = compileViewFunction(window.source, contract, window, `nscvWindow${index}`, false, usage, development ? file => `windows/${file}` : undefined);
    generated += compiled.text; program.windows.push({ label: window.label, body: compiled.body, attribution: compiled.attribution });
    branches.push(`if (nscvWindowLabel(label, ${JSON.stringify(window.label)})) return nscvWindow${index}(nscvVideo);`);
  }
  const virtual = [source, ...options.sources?.values() ?? [], ...windows.flatMap(window => [window.source, ...window.sources?.values() ?? []])].some(value => /<virtual-window\b/.test(value));
  if (windows.length === 0 && !virtual) return { text: generated, program, virtual };
  generated += `function nscvWindowLabel(label: Uint8Array, expected: string): boolean { const bytes = new TextEncoder().encode(expected); if (label.length !== bytes.length) return false; for (let i = 0; i < bytes.length; i++) if (label[i] !== bytes[i]) return false; return true; }\n`;
  if (windows.length) generated +=
    `function nscvWindowView(label: Uint8Array, nscvVideo: NscVideoPlaybackState): Uint8Array {\n${branches.join("\n")}\nthrow new Error("unknown compiled window view label");\n}\n` +
    exported("native_window_view(label: Uint8Array)", "label", "nscvEmptyVideo()", "undefined", "nscvWindowView(label, nscvVideo)") +
    exported("native_media_window_view(label: Uint8Array, request: Uint8Array)", "label", "nscvVideoState(request)", "undefined", "nscvWindowView(label, nscvVideo)");
  if (virtual) generated += `function nscvVirtualView(label: Uint8Array, nscvVideo: NscVideoPlaybackState, nscvVirtual: NscVirtualBuild): Uint8Array {\nif (label.length === 0) return nscvMainView(nscvVideo, nscvVirtual);\n${windows.map((window, index) => `if (nscvWindowLabel(label, ${JSON.stringify(window.label)})) return nscvWindow${index}(nscvVideo, nscvVirtual);`).join("\n")}\nthrow new Error("unknown compiled virtual window label");\n}\n` +
    (development
      ? `export function native_virtual_requests(label: Uint8Array, video: Uint8Array): Uint8Array { const nscvVideo = nscvVideoState(video); const nscvVirtual: NscVirtualBuild = { requestsOnly: true, requests: [], ranges: [], consumed: [] }; if (nscvdActive()) return nscvdView(label, nscvVideo, nscvVirtual); return nscvVirtualView(label, nscvVideo, nscvVirtual); }\n` +
        `export function native_virtual_view(label: Uint8Array, context: Uint8Array, video: Uint8Array): Uint8Array { const nscvVideo = nscvVideoState(video); const nscvVirtual = nscvVirtualContext(context); if (nscvdActive()) return nscvdView(label, nscvVideo, nscvVirtual); return nscvVirtualView(label, nscvVideo, nscvVirtual); }\n`
      : `export function native_virtual_requests(label: Uint8Array, video: Uint8Array): Uint8Array { return nscvVirtualView(label, nscvVideoState(video), { requestsOnly: true, requests: [], ranges: [], consumed: [] }); }\n` +
        `export function native_virtual_view(label: Uint8Array, context: Uint8Array, video: Uint8Array): Uint8Array { return nscvVirtualView(label, nscvVideoState(video), nscvVirtualContext(context)); }\n`);
  return { text: generated, program, virtual };
}

/** The static half of a development view's records, as one JSON fragment:
 * the source table and every markup file it names, root view file first,
 * with the Wyhash (seed 0, hex) of the bytes the view was compiled from.
 */
function sourceAttribution(table: readonly ViewSource[], sources: ReadonlyMap<string, string>, entry: string, stamp: (file: string) => string): string {
  const files = [entry];
  const byStamp = new Map([...sources.keys()].map(file => [stamp(file), file]));
  for (const source of table) for (const site of [source, ...source.chain]) {
    const file = byStamp.get(site.file)!;
    if (!files.includes(file)) files.push(file);
  }
  const listed = files.map(file => ({ path: stamp(file), hash: wyhash(0n, new TextEncoder().encode(sources.get(file)!)).toString(16).padStart(16, "0") }));
  return `"sourceTable":${JSON.stringify(table)},"sourceFiles":${JSON.stringify(listed)}`;
}

function compileViewFunction(source: string, contract: ViewContract, options: ViewSources, functionName: string, exported: boolean, usage?: ViewUsage,
  stamp?: (file: string) => string): { text: string; body: readonly ViewStmt[]; attribution: string } {
  const entry = options.entry ?? "app.native";
  const sources = new Map(options.sources); sources.set(entry, source);
  const fail: (node: Pick<Element, "file" | "at">, message: string) => never = (node, message) => {
    const before = sources.get(node.file)!.slice(0, node.at).split("\n");
    throw new Error(`${node.file}:${before.length}:${before.at(-1)!.length + 1}: compiled TypeScript view: ${message}`);
  };
  const origin = { file: entry, at: 0 };
  const reserved = ["NscAppearanceColor", "NscAppearanceVisual", "NscAppearanceContext", "NscViewSpan", "NscViewNode", "NscChartSeries", "NscChartDecimal", "NscChartSource", "NscChartPlan", "NscChartPrepared", "NscTimelineItem", "NscComponentText", "NscSurfaceRect", "native_view", "native_window_view", "native_media_view", "native_media_window_view", "native_virtual_requests", "native_virtual_view", "NscVirtualRequest", "NscVirtualRange", "NscVirtualBuild", "nscvMainView", "NscVideoPlaybackState", "native_radio_policy", "native_tabs_policy", "native_tree_policy", "native_list_policy", "native_menu_policy", "native_toggle_policy", "native_accordion_policy", "native_slider_policy", "native_split_policy", "native_scroll_policy", "native_resizable_policy", "native_text_policy", "native_timer_policy", "native_db_policy", "native_effect_policy", "native_stream_policy", "native_window_policy", "native_theme_policy", "native_status_policy", "JSON", "TextEncoder", "TextDecoder", "DataView", "String", "Number", "Array"];
  const names = [...contract.types.structs, ...contract.types.enums ?? [], ...contract.types.unions ?? [], ...contract.model_helpers];
  if (names.some(item => reserved.includes(item.name) || (item.name.startsWith("nscv") || item.name.startsWith("nscMd") || item.name.startsWith("NscMd") || item.name.startsWith("NscAudit"))) || reserved.includes(contract.msg.name ?? "")) {
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
      const node: Element = { name: start[1]!, attrs: new Map(), children: [], content: [], text: "", at, end: at, file };
      for (;;) {
        while (/\s/.test(src[pos] ?? "") && pos < src.length) pos++;
        if (src.startsWith("/>", pos)) { pos += 2; node.end = pos; return node; }
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
          pos += close[0].length; node.end = pos; return node;
        }
        if (src[pos] === "<") { const child = element(depth + 1); node.children.push(child); node.content.push(child); }
        else {
          const end = src.indexOf("<", pos), stop = end < 0 ? src.length : end;
          const value = decode(src.slice(pos, stop)); node.text += value; node.content.push({ text: value, at: pos, end: stop }); pos = stop;
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
  const rangeFields = ["start_index", "end_index", "first_visible_index", "last_visible_index", "item_extent", "item_gap", "scroll_offset", "layout_offset", "content_extent", "before_extent", "after_extent", "anchor_extent"];
  const rangeType = (ref: Ref): boolean => {
    const record = ["node", "value"].includes(ref.kind) ? contract.types.structs.find(item => item.name === ref.name) : undefined;
    return !!record && record.fields.length === 12 && record.fields.every((field, i) => field.name === rangeFields[i] && (i < 4 ? ["i64", "f64"].includes(field.type.kind) : field.type.kind === "f64"));
  };
  const category = (ref: Ref): string => ["i64", "f64"].includes(ref.kind) ? "number" : ref.kind === "bool" ? "boolean" : ref.kind;
  const path = (raw: string, node: Element, scope: Scope): Expr => {
    if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(raw)) fail(node, `unsupported binding path ${raw}`);
    const [name, ...members] = raw.split(".");
    const field = fields!.find(item => item.name === name);
    const helper = contract.model_helpers.find(item => item.name === name && item.params.length === 0);
    let value = scope.get(name!) ?? (field ? { code: v.field(v.id("nscfCommitted"), name!, true), type: field.type } : helper ? { code: v.call(name!, v.id("nscfCommitted")), type: helper.returns } : null);
    if (!value) fail(node, `unknown binding ${name}`);
    if (!scope.has(name!)) usage?.model.add(name!);
    for (const member of members) {
      const record: ViewContract["types"]["structs"][number] | undefined = ["node", "value"].includes(value.type.kind) ? contract.types.structs.find(item => item.name === value!.type.name) : undefined;
      const next: { name: string; type: Ref } | undefined = record?.fields.find(item => item.name === member);
      if (!next) fail(node, `unsupported field ${member} on ${raw}`);
      value = { code: v.field(value.code, member, true), type: next.type };
    }
    return value;
  };
  const expression = (raw: string, node: Element, scope: Scope): Expr => {
    const tokens: string[] = []; let offset = 0;
    while (offset < raw.length) {
      const token = /^\s*('[^'\\]*'|\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|===|!==|==|!=|<=|>=|&&|\|\||[()!+*\/<>=-])/.exec(raw.slice(offset));
      if (!token) { if (!raw.slice(offset).trim()) break; fail(node, `unsupported expression ${raw}`); }
      tokens.push(({ and: "&&", or: "||", not: "!" } as Record<string, string>)[token[1]!] ?? token[1]!); offset += token[0].length;
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
        left = { code: v.unary(token, inner.code), type: { kind: token === "!" ? "bool" : "f64" } };
      } else if (token === "true" || token === "false") left = { code: v.bool(token === "true"), type: { kind: "bool" } };
      else if (token?.startsWith("'")) left = { code: v.str(token.slice(1, -1)), type: { kind: "string", name: token.slice(1, -1) } };
      else if (token && /^\d/.test(token)) {
        if (!Number.isFinite(Number(token))) fail(node, "non-finite literal");
        left = { code: v.num(token), type: { kind: token.includes(".") ? "f64" : "i64" } };
      } else left = path(token ?? "", node, scope);
      for (;;) {
        const op = tokens[cursor], precedence = op && Object.hasOwn(precedences, op) ? precedences[op] : undefined;
        if (precedence === undefined || precedence < min) break;
        cursor++; const right = parseExpr(precedence + 1);
        const logical = op === "&&" || op === "||", equality = ["==", "!=", "===", "!=="].includes(op!);
        const comparison = ["<", "<=", ">", ">="].includes(op!);
        let valid = category(left.type) === category(right.type) && (logical ? category(left.type) === "boolean" : category(left.type) === "number" || equality && category(left.type) === "boolean");
        if (equality && left.type.kind === "enum" && right.type.kind === "enum") {
          valid = left.type.name === right.type.name;
        } else if (equality && [left.type.kind, right.type.kind].includes("enum")) {
          const enumRef = left.type.kind === "enum" ? left : right, literal = left.type.kind === "string" ? left : right;
          valid = literal.type.kind === "string" && !!contract.types.enums?.find(item => item.name === enumRef.type.name)?.members.includes(literal.type.name!);
        }
        if (!valid) fail(node, `invalid operands for ${op}`);
        left = { code: v.binary(op === "==" ? "===" : op === "!=" ? "!==" : op!, left.code, right.code), type: { kind: logical || equality || comparison ? "bool" : "f64" } };
      }
      return left;
    };
    const result = parseExpr(0);
    if (cursor !== tokens.length) fail(node, `unsupported expression ${raw}`);
    return result;
  };
  const binding = (raw: string, node: Element, scope: Scope): Expr => expression(/^\{([^{}]*)\}$/.exec(raw)?.[1] ?? raw, node, scope);
  const bound = (raw: string, type: string, node: Element, scope: Scope): ViewExpr => {
    const expr = binding(raw, node, scope);
    if (category(expr.type) !== type) fail(node, `expected ${type} binding`);
    return expr.code;
  };
  const condition = (raw: string, node: Element, scope: Scope): ViewExpr => {
    const expr = binding(raw, node, scope);
    if (expr.type.kind === "bool") return expr.code;
    if (category(expr.type) === "number") return v.binary("!==", expr.code, v.num("0"));
    if (["bytes", "string", "enum"].includes(expr.type.kind)) return v.binary(">", v.length(expr.code), v.num("0"));
    return fail(node, "condition requires a scalar or text binding");
  };
  const textValue = (expr: Expr, node: Element): ViewExpr => {
    if (expr.type.kind === "bytes") return v.decode(expr.code);
    if (["number", "boolean", "enum", "string"].includes(category(expr.type))) return v.string(expr.code);
    return fail(node, "text requires bytes, an enum or a scalar binding");
  };
  const text = (raw: string, node: Element, scope: Scope): ViewExpr => {
    const parts: ViewExpr[] = []; let last = 0;
    for (const match of raw.matchAll(/\{([^{}]*)\}/g)) {
      parts.push(v.str(raw.slice(last, match.index)), textValue(expression(match[1]!, node, scope), node)); last = match.index + match[0].length;
    }
    parts.push(v.str(raw.slice(last)));
    if (raw.replace(/\{[^{}]*\}/g, "").match(/[{}]/)) fail(node, "unbalanced text binding");
    return parts.reduce((left, right) => v.binary("+", left, right, false));
  };
  const byteText = (raw: string, node: Element, scope: Scope): ViewExpr | null => {
    const parts: ViewExpr[] = []; let last = 0, hasBytes = false;
    for (const match of raw.matchAll(/\{([^{}]*)\}/g)) {
      if (match.index > last) parts.push(v.encode(v.str(raw.slice(last, match.index))));
      const expr = expression(match[1]!, node, scope);
      if (expr.type.kind === "bytes") { hasBytes = true; parts.push(expr.code); }
      else parts.push(v.encode(textValue(expr, node)));
      last = match.index + match[0].length;
    }
    if (!hasBytes) return null;
    if (last < raw.length) parts.push(v.encode(v.str(raw.slice(last))));
    return v.call("nscvTextBytes", v.array(parts));
  };
  const key = (raw: string, node: Element, scope: Scope): Expr => {
    if (/^-?\d+$/.test(raw)) {
      if (!Number.isSafeInteger(Number(raw))) fail(node, "key is not an exact integer");
      return { code: v.call("nscvInteger", v.num(raw)), type: { kind: "i64" } };
    }
    if (!raw.startsWith("{")) {
      if (/^(?:[-+]?\d|[.]\d|true$|false$)/.test(raw)) fail(node, "keys must be integers or strings");
      return { code: v.str(raw), type: { kind: "string" } };
    }
    const expr = binding(raw, node, scope);
    if (expr.type.kind !== "i64" && expr.type.kind !== "bytes" && expr.type.kind !== "string") fail(node, "keys must be integers or strings");
    return expr.type.kind === "i64" ? { code: v.call("nscvInteger", expr.code), type: expr.type } : expr.type.kind === "bytes" ? expr : { code: textValue(expr, node), type: { kind: "string" } };
  };
  let output: ViewStmt[] = []; let next = 0;
  // Development compiles (`stamp` set) record where each node was authored:
  // a source table, and a mark after every element that attributes the
  // records it pushed (and that its children did not claim) to its source.
  const sourceTable: ViewSource[] = [], sourceIds = new Map<string, number>();
  let chain: readonly ViewSourceSite[] = [], marks = 0;
  const byteOffsets = new Map<string, Int32Array>();
  const site = (node: Pick<Element, "file" | "at" | "end">): ViewSourceSite => {
    const text = sources.get(node.file)!;
    let offsets = byteOffsets.get(node.file);
    if (!offsets) {
      offsets = new Int32Array(text.length + 1);
      for (let i = 0, bytes = 0; i < text.length; i++) {
        offsets[i] = bytes;
        const unit = text.charCodeAt(i);
        bytes += unit < 0x80 ? 1 : unit < 0x800 ? 2 : unit >= 0xd800 && unit < 0xdc00 ? 4 : unit >= 0xdc00 && unit < 0xe000 ? 0 : 3;
        offsets[i + 1] = bytes;
      }
      byteOffsets.set(node.file, offsets);
    }
    const lineStart = text.lastIndexOf("\n", node.at - 1) + 1;
    let line = 1;
    for (let i = text.indexOf("\n"); i >= 0 && i < node.at; i = text.indexOf("\n", i + 1)) line++;
    return { file: stamp!(node.file), start: offsets[node.at]!, end: offsets[node.end]!, line, column: offsets[node.at]! - offsets[lineStart]! + 1 };
  };
  const block = (build: () => void): ViewStmt[] => {
    const outer = output; output = [];
    try { build(); return output; } finally { output = outer; }
  };
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
      if (node.name === "else") fail(node, "else must immediately follow if or for");
      if (node.name !== "if" && node.name !== "for") { emit(node, scope, slot, stack, depth); continue; }
      if (node.name === "for") {
        emit(node, scope, slot, stack, depth);
        const alternate = nodes[i + 1];
        if (alternate?.name === "else") {
          if (alternate.attrs.size || alternate.text.trim()) fail(alternate, "else accepts only child elements");
          const items = path(node.attrs.get("each")!, node, scope);
          output.push(s.if(v.binary("===", v.length(items.code), v.num("0"), false), block(() => emitChildren(alternate.children, scope, slot, stack, depth + 1)))); i++;
        }
        continue;
      }
      if (node.attrs.size !== 1 || !node.attrs.has("test") || node.text.trim()) fail(node, "if requires only test and child elements");
      const test = condition(node.attrs.get("test")!, node, scope);
      const then = block(() => emitChildren(node.children, scope, slot, stack, depth + 1));
      const alternate = nodes[i + 1];
      if (alternate?.name === "else") {
        if (alternate.attrs.size || alternate.text.trim()) fail(alternate, "else accepts only child elements");
        output.push(s.if(test, then, block(() => emitChildren(alternate.children, scope, slot, stack, depth + 1)))); i++;
      } else output.push(s.if(test, then));
    }
  };
  const event = (raw: string, channel: string, node: Element, scope: Scope): ViewExpr => {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)(?::\{([^{}]+)\})?$/.exec(raw);
    const arm = contract.msg.arms.find(item => item.name === match?.[1]);
    if (!arm || !match) fail(node, `unknown or unsupported event ${raw}`);
    usage?.msg.add(arm.name);
    const payload = match[2] ? path(match[2], node, scope) : null;
    if (channel === "value" || channel === "resize") {
      if (payload || arm.payload.kind !== "number" || (arm.payload.class ?? "f64") !== "f64") fail(node, channel === "resize" ? "split on-resize requires a bare one-number float Msg arm" : "slider on-change requires a bare one-number float or void Msg arm");
      return v.num(String(contract.msg.arms.indexOf(arm)));
    }
    if (channel === "input") {
      if (payload || !textInputUnion(arm.payload)) fail(node, "on-input requires a bare TextInputEvent Msg arm");
      return v.num(String(contract.msg.arms.indexOf(arm)));
    }
    if (channel === "terminal") {
      const record = arm.payload.kind === "record" ? contract.types.structs.find(item => item.name === arm.payload.name) : null;
      const names = ["scrollback", "history", "cols", "rows"];
      if (payload || !record || record.fields.length !== 4 || !names.every(name => record.fields.some(field => field.name === name && category(field.type) === "number"))) fail(node, "on-terminal requires a bare TerminalState Msg arm");
      return v.num(String(contract.msg.arms.indexOf(arm)));
    }
    if (channel === "scroll") {
      const record = arm.payload.kind === "record" ? contract.types.structs.find(item => item.name === arm.payload.name) : null;
      const names = ["offsetX", "offsetY", "velocityX", "velocityY", "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY"];
      if (payload || !record || record.fields.length !== 8 || !names.every(name => record.fields.some(field => field.name === name && category(field.type) === "number"))) fail(node, "on-scroll requires a bare ScrollState Msg arm");
      return v.num(String(contract.msg.arms.indexOf(arm)));
    }
    const props: ViewProp[] = [v.prop("kind", v.str(arm.name))];
    if (channel === "drag") {
      const record = arm.payload.kind === "record" ? contract.types.structs.find(item => item.name === arm.payload.name) : null;
      const names = ["sourceId", "phase", "x", "y", "viewWidth", "viewHeight"];
      if (!payload || category(payload.type) !== "number" || !record || record.fields.length !== 6 || !names.every(name => record.fields.some(field => field.name === name && (["x", "y", "viewWidth", "viewHeight"].includes(name) ? field.type.kind === "f64" : category(field.type) === "number")))) fail(node, "on-drag requires a sourceId binding and the six-field drag Msg record");
      props.push(v.prop("sourceId", payload.code), ...["phase", "x", "y", "viewWidth", "viewHeight"].map(name => v.prop(name, v.num("0"))));
    } else if (arm.payload.kind === "void") { if (payload) fail(node, "void Msg arm cannot take a payload"); }
    else {
      const type = arm.payload.kind === "number" ? { kind: arm.payload.class ?? "f64" } : arm.payload.kind === "scalar" ? arm.payload.type! : arm.payload;
      if (!payload || !arm.member || category(type) !== category(payload.type) || !["number", "boolean", "bytes", "enum"].includes(category(type)) || (type.kind === "enum" && type.name !== payload.type.name)) fail(node, "event requires a matching scalar Msg payload binding");
      props.push(v.prop(arm.member, payload.code, true));
    }
    return v.pack(v.object("msg", props, arm.name));
  };
  const emit = (node: Element, scope: Scope, slot: Slot | undefined, stack: string[], depth: number, inputActionsAllowed = false): void => {
    if (!stamp || node.name === "use" || node.name === "slot") return emitElement(node, scope, slot, stack, depth, inputActionsAllowed);
    const source: ViewSource = { ...site(node), chain };
    const key = JSON.stringify(source);
    let id = sourceIds.get(key);
    if (id === undefined) { id = sourceTable.length; sourceTable.push(source); sourceIds.set(key, id); }
    const start = `nscvSourceStart${marks++}`;
    output.push(s.const(start, v.length(v.id("nscvNodes"))));
    emitElement(node, scope, slot, stack, depth, inputActionsAllowed);
    output.push(s.expr(v.call("nscvSourceMark", v.id("nscvSources"), v.id(start), v.length(v.id("nscvNodes")), v.num(String(id)))));
  };
  const emitElement = (node: Element, scope: Scope, slot: Slot | undefined, stack: string[], depth: number, inputActionsAllowed = false): void => {
    if (depth > 64 || next > 4096) fail(node, "expanded view exceeds 64 levels or 4096 elements");
    if (node.name === "virtual-window") {
      if ([...scope.values()].some(value => value.virtualIndex !== undefined)) fail(node, "virtual-window declarations cannot nest");
      const allowed = ["id", "as", "item-count", "item-extent", "gap", "overscan", "viewport-fallback", "extent-estimate", "index-base", "anchor"];
      const name = node.attrs.get("as"), identity = node.attrs.get("id");
      if (!name || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || !identity || identity.includes("{") || new TextEncoder().encode(identity).length > 256 || node.children.length !== 1 || node.text.trim()) fail(node, "virtual-window requires a literal id, as and one root child");
      if ([...node.attrs.keys()].some(attr => !allowed.includes(attr)) || !node.attrs.has("item-count")) fail(node, "unsupported virtual-window attributes");
      const estimateName = node.attrs.get("extent-estimate");
      const estimator = contract.model_helpers.find(helper => helper.name === estimateName && helper.params.length === 1 && ["i64", "f64"].includes(helper.params[0]!.kind) && ["i64", "f64"].includes(helper.returns.kind));
      if (estimateName !== undefined && !estimator) fail(node, "extent-estimate requires a Model-first numeric index helper returning a number");
      if (estimator) usage?.model.add(estimator.name);
      const range = contract.model_helpers.flatMap(helper => helper.params).find(rangeType);
      if (!range) fail(node, "virtual-window requires a row helper taking the complete VirtualListRange");
      const numeric = (attr: string, fallback: string, integer = false): ViewExpr => {
        const raw = node.attrs.get(attr);
        if (raw === undefined) return v.num(fallback);
        const value = raw.startsWith("{") ? binding(raw, node, scope) : expression(raw, node, scope);
        if (!["i64", "f64"].includes(value.type.kind) || integer && value.type.kind !== "i64") fail(node, `${attr} requires ${integer ? "an integer" : "a number"}`);
        return value.code;
      };
      const anchor = node.attrs.get("anchor") ?? "leading";
      if (anchor !== "leading" && anchor !== "trailing") fail(node, "virtual-window anchor requires leading or trailing");
      const id = next++, variable = `nscvRange${id}`, index = `nscvWindowIndex${id}`;
      const request = v.object("virtual_request", [v.prop("id", v.str(identity)), v.prop("itemCount", numeric("item-count", "0", true)), v.prop("itemExtent", numeric("item-extent", "0")), v.prop("gap", numeric("gap", "0")),
        v.prop("overscan", numeric("overscan", "4", true)), v.prop("viewportFallback", numeric("viewport-fallback", "0")), v.prop("indexBase", numeric("index-base", "0", true)),
        v.prop("trailing", v.bool(anchor === "trailing")), v.prop("estimateHelper", v.num(String(estimator ? contract.model_helpers.indexOf(estimator) : -1)))]);
      output.push(s.throwIf(v.binary("===", v.id("nscvVirtual"), v.undef(), false), "virtual view requires retained window context"),
        s.const(index, v.call("nscvVirtualRequest", v.field(v.id("nscvVirtual"), "requests"), request)));
      const inner = new Map(scope); inner.set(name, { code: v.id(variable), type: range, virtualIndex: index });
      output.push(s.if(v.unary("!", v.field(v.id("nscvVirtual"), "requestsOnly"), false), block(() => {
        output.push(s.const(variable, v.index(v.field(v.id("nscvVirtual"), "ranges"), v.id(index))), s.throwIf(v.binary("===", v.id(variable), v.undef(), false), "missing virtual window range"));
        emitChildren(node.children, inner, slot, stack, depth + 1);
      }))); return;
    }
    if (node.name === "virtual-list") {
      const windowName = node.attrs.get("window"), window = windowName ? scope.get(windowName) : undefined;
      const helper = contract.model_helpers.find(helper => helper.name === node.attrs.get("each"));
      const name = node.attrs.get("as");
      if (!window?.virtualIndex || !helper || helper.params.length !== 1 || !rangeType(helper.params[0]!) || helper.returns.kind !== "slice" || !helper.returns.elem || !name || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || node.children.length !== 1 || node.text.trim()) fail(node, "virtual-list requires an enclosing window, a Model-first range query, as and one keyed root per row");
      if (!node.children[0]!.attrs.has("key") && !node.children[0]!.attrs.has("global-key")) fail(node, "virtual-list requires one keyed root per row");
      usage?.model.add(helper.name);
      const allowed = ["window", "each", "as", "grow", "width", "height", "min-width", "padding", "label", "background", "foreground", "border-color", "focus-ring", "radius", "overscroll", "on-scroll", "on-reach-end", "on-reach-start"];
      if ([...node.attrs.keys()].some(attr => !allowed.includes(attr))) fail(node, "unsupported virtual-list attribute");
      const attrs = new Map(node.attrs); for (const attr of ["window", "each", "as", "on-reach-end", "on-reach-start"]) attrs.delete(attr);
      const id = next++, start = `nscvListStart${id}`, item = `nscvVirtualItem${id}`;
      const nodes = v.id("nscvNodes"), started = v.nonnull(v.index(nodes, v.id(start)));
      output.push(s.expr(v.call("nscvVirtualConsume", v.nonnull(v.id("nscvVirtual")), v.id(window.virtualIndex))), s.const(start, v.length(nodes)));
      emit({ ...node, name: "scroll", attrs, children: [], content: [] }, scope, slot, stack, depth + 1);
      for (const [attr, property] of [["on-reach-end", "reachEnd"], ["on-reach-start", "reachStart"]]) if (node.attrs.has(attr!)) output.push(s.assign(v.field(started, property!), event(node.attrs.get(attr!)!, attr!.slice(3), node, scope)));
      output.push(s.assign(v.field(started, "virtualWindow"), v.id(window.virtualIndex)));
      const inner = new Map(scope); inner.set(name, { code: v.id(item), type: helper.returns.elem });
      output.push(s.for(item, v.call(helper.name, v.id("nscfCommitted"), window.code), block(() => {
        output.push(s.const(`nscvRowStart${id}`, v.length(nodes)));
        emitChildren(node.children, inner, slot, stack, depth + 1);
        output.push(s.expr(v.call("nscvVirtualRow", nodes, v.id(`nscvRowStart${id}`))));
      })), s.assign(v.field(started, "end"), v.length(nodes)), s.expr(v.call("nscvVirtualList", nodes, v.id(start), window.code)));
      return;
    }
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
        const value = raw.startsWith("{") ? binding(raw, node, scope) : { code: v.str(raw), type: { kind: "string" } };
        const variable = `nscvArg${next++}`; output.push(s.const(variable, value.code)); inner.set(arg, { ...value, code: v.id(variable) });
      }
      if ([...node.attrs.keys()].some(arg => arg !== "template" && !args.includes(arg))) fail(node, "unknown template argument");
      const consumer = chain;
      if (stamp) chain = [...chain, site(node)];
      try { emitChildren(template.children, inner, { children: node.children, scope, slot, chain: consumer }, [...stack, name!], depth + 1); } finally { chain = consumer; }
      return;
    }
    if (node.name === "slot") {
      if (!slot || node.attrs.size || node.children.length || node.text.trim()) fail(node, "slot requires a template use and no attributes or children");
      const inside = chain; chain = slot.chain;
      try { emitChildren(slot.children, slot.scope, slot.slot, stack, depth + 1); } finally { chain = inside; }
      return;
    }
    if (node.name === "for") {
      const each = node.attrs.get("each"), as = node.attrs.get("as"), field = node.attrs.get("key");
      if (!each || !as || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(as) || node.attrs.size !== (field === undefined ? 2 : 3) || field === "" || node.text.trim()) fail(node, "for requires each, as, an optional key and child elements");
      const items = path(each, node, scope);
      if (items.type.kind !== "slice" || !items.type.elem) fail(node, "each requires a list binding");
      const id = next++, variable = `nscvItem${id}`, inner = new Map(scope); inner.set(as, { code: v.id(variable), type: items.type.elem });
      const base = field === undefined ? null : key(`{${as}.${field}}`, node, inner);
      output.push(s.for(variable, items.code, block(() => {
        output.push(s.const(`nscvFirst${id}`, v.length(v.id("nscvNodes"))));
        emitChildren(node.children, inner, slot, stack, depth + 1);
        if (base !== null) output.push(s.expr(v.call(base.type.kind === "bytes" ? "nscvLoopByteKeys" : "nscvLoopKeys", v.id("nscvNodes"), v.id(`nscvFirst${id}`), base.code)));
      }))); return;
    }
    const stringAttr = (name: string, fallback = ""): ViewExpr => {
      const raw = node.attrs.get(name);
      if (raw === undefined) return v.str(fallback);
      const value = raw.startsWith("{") ? binding(raw, node, scope) : { code: v.str(raw), type: { kind: "string" } };
      if (!["bytes", "string", "enum"].includes(value.type.kind)) fail(node, `${name} requires text`);
      return textValue(value, node);
    };
    const keyProp = (name: string, expr: Expr): ViewProp => v.prop(`${name === "key" ? "key" : "globalKey"}${expr.type.kind === "i64" ? "Int" : expr.type.kind === "bytes" ? "Bytes" : ""}`,
      expr.type.kind === "bytes" ? v.call("nscvTextBytes", v.array([expr.code])) : expr.code);
    const componentRoot = (allowed: string[]): ViewProp[] => {
      if (node.text.trim()) fail(node, "component accepts only child elements");
      for (const name of node.attrs.keys()) if (!allowed.includes(name)) fail(node, `unsupported ${node.name} attribute ${name}`);
      const props = [v.prop("end", v.num("0")), v.prop("kind", v.str("row")), v.prop("text", v.str(""))];
      for (const name of ["key", "global-key"]) {
        const raw = node.attrs.get(name);
        if (raw !== undefined) props.push(keyProp(name, key(raw, node, scope)));
      }
      if (node.attrs.has("label")) {
        const bytes = byteText(node.attrs.get("label")!, node, scope);
        if (bytes === null) props.push(v.prop("label", stringAttr("label")));
        else props.push(v.prop("label", v.str("")), v.prop("labelBytes", bytes));
      }
      return props;
    };
    if (node.name === "input-group" || node.name === "input-group-actions") {
      const actions = node.name === "input-group-actions";
      if (actions && !inputActionsAllowed) fail(node, "input-group-actions requires an input-group parent");
      const props = componentRoot(actions ? ["gap", "key", "global-key"] : ["label", "width", "height", "min-width", "grow", "key", "global-key"]);
      props[1] = v.prop("kind", v.str(actions ? "input_group_actions" : "input_group"));
      for (const name of actions ? ["gap"] : ["width", "height", "min-width", "grow"]) {
        const raw = node.attrs.get(name);
        if (raw !== undefined) props.push(v.prop(name === "min-width" ? "minWidth" : name, bound(raw, "number", node, scope)));
      }
      const id = next++, group = v.id(`nscvGroup${id}`);
      output.push(s.const(`nscvGroup${id}`, v.object("node", props), "NscViewNode"), s.expr(v.call("nscvPush", v.id("nscvNodes"), group)));
      if (actions) {
        if (!node.attrs.has("gap")) output.push(s.assign(v.field(group, "gap"), v.num("6")));
        if (node.children.some(child => child.name === "#text")) fail(node, "input-group-actions requires element children");
        emitChildren(node.children, scope, slot, stack, depth + 1);
      } else {
        if (node.children.length < 1 || node.children.length > 2 || node.children[0]!.name !== "textarea" ||
            node.children.length === 2 && node.children[1]!.name !== "input-group-actions") fail(node, "input-group requires a textarea then optional input-group-actions");
        emit(node.children[0]!, scope, slot, stack, depth + 1);
        if (node.children[1]) emit(node.children[1], scope, slot, stack, depth + 1, true);
      }
      output.push(s.assign(v.field(group, "end"), v.length(v.id("nscvNodes"))));
      return;
    }
    if (node.name === "chart") {
      const props = componentRoot(["key", "global-key", "label", "width", "height", "grow", "padding", "y-min", "y-max", "grid-lines", "baseline", "y-labels", "hover-details", "stroke-width", "x-labels"]);
      for (const name of ["width", "height", "grow", "padding", "y-min", "y-max", "stroke-width", "grid-lines"]) {
        const raw = node.attrs.get(name);
        if (raw === undefined) continue;
        const value = bound(raw, "number", node, scope);
        const field = { "y-min": "chartYMin", "y-max": "chartYMax", "stroke-width": "chartStrokeWidth", "grid-lines": "chartGridLines" }[name];
        props.push(v.prop(field ?? name, name === "grid-lines" ? v.call("nscvChartGrid", value) : field ? v.call("nscvChartWord", value) : value));
      }
      for (const [name, field] of [["baseline", "chartBaseline"], ["y-labels", "chartYLabels"], ["hover-details", "chartHoverDetails"]]) {
        const raw = node.attrs.get(name!);
        if (raw !== undefined) props.push(v.prop(field!, bound(raw, "boolean", node, scope)));
      }
      const series = node.children.map(child => {
        if (child.name !== "series" || child.text.trim() || child.children.length || [...child.attrs.keys()].some(name => !["kind", "values", "color", "label"].includes(name))) fail(child, "chart requires series leaves");
        const raw = child.attrs.get("values");
        if (raw === undefined) fail(child, "series requires a values binding");
        const values = binding(raw, child, scope);
        if (values.type.kind !== "slice" || !values.type.elem || !["i64", "f64"].includes(values.type.elem.kind)) fail(child, "series values requires a number array binding");
        const kind = child.attrs.get("kind") ?? "line", color = child.attrs.get("color") ?? "accent";
        if (!["line", "area", "bar"].includes(kind)) fail(child, "series kind requires line, area or bar");
        if (!["background", "surface", "surface_subtle", "surface_pressed", "text", "text_muted", "syntax_plain", "syntax_comment", "syntax_keyword", "syntax_literal", "syntax_function", "syntax_property", "syntax_constant", "border", "accent", "accent_text", "destructive", "destructive_text", "success", "success_text", "warning", "warning_text", "info", "info_text", "focus_ring", "shadow", "scrim", "disabled"].includes(color)) fail(child, "series color requires a literal color token");
        const label = child.attrs.get("label");
        const bytes = label === undefined ? v.array([]) : byteText(label, child, scope) ?? v.call("nscvTextBytes", v.array([v.encode(label.startsWith("{") ? textValue(binding(label, child, scope), child) : v.str(label))]));
        return v.object("chart_series", [v.prop("kind", v.str(kind === "bar" ? "bar" : "line")), v.prop("fill", v.bool(kind === "area")), v.prop("color", v.str(color)), v.prop("label", bytes), v.prop("values", v.call("nscvChartWords", values.code))]);
      });
      if (series.length === 0) fail(node, "chart requires at least one series");
      const rawLabels = node.attrs.get("x-labels"); let labels: ViewExpr = v.array([]);
      if (rawLabels !== undefined) {
        const values = binding(rawLabels, node, scope);
        if (values.type.kind !== "slice" || !values.type.elem || !["bytes", "string"].includes(values.type.elem.kind)) fail(node, "chart x-labels requires a text array binding");
        labels = v.labelBytes(values.code, values.type.elem.kind === "bytes");
      }
      output.push(s.expr(v.call("nscvChart", v.id("nscvNodes"), v.object("node", props), v.array(series), labels)));
      return;
    }
    if (node.name === "stepper") {
      const props = componentRoot(["active", "key", "global-key", "label"]);
      const raw = node.attrs.get("active");
      if (raw === undefined) fail(node, "stepper requires active");
      const active = raw.startsWith("{") ? binding(raw, node, scope) : expression(raw, node, scope);
      if (active.type.kind !== "i64") fail(node, "stepper active requires an integer");
      let steps = node.children, stepScope = scope;
      if (steps.length === 1 && steps[0]!.name === "slot") {
        if (!slot || steps[0]!.attrs.size || steps[0]!.children.length || steps[0]!.text.trim()) fail(node, "stepper slot requires a template use");
        steps = slot.children; stepScope = slot.scope;
      }
      const labels = steps.map(step => {
        if (step.name !== "step" || step.attrs.size || step.children.length) fail(step, "stepper takes only step text leaves");
        const raw = step.text.trim(), bytes = byteText(raw, step, stepScope);
        return bytes === null ? v.object("component_text", [v.prop("text", text(raw, step, stepScope))]) : v.object("component_text", [v.prop("text", v.str("")), v.prop("bytes", bytes)]);
      });
      output.push(s.expr(v.call("nscvStepper", v.id("nscvNodes"), v.object("node", props), active.code, v.array(labels))));
      return;
    }
    if (node.name === "timeline") {
      const props = componentRoot(["gap", "grow", "key", "global-key", "label"]);
      props[1] = v.prop("kind", v.str("column")); props.push(v.prop("role", v.str("list")));
      for (const name of ["gap", "grow"]) if (node.attrs.has(name)) props.push(v.prop(name, bound(node.attrs.get(name)!, "number", node, scope)));
      const id = next++, root = v.id(`nscvNode${id}`);
      output.push(s.const(`nscvNode${id}`, v.object("node", props), "NscViewNode"),
        s.const(`nscvRecipe${id}`, v.call("nscvCompositionRequest", ...["7", "0", "0", "0", "0", "0", "0"].map(v.num), v.nullish(v.field(root, "gap"), v.num("0")))),
        s.assign(v.field(root, "gap"), v.float32(v.id(`nscvRecipe${id}`), 32)), s.expr(v.call("nscvPush", v.id("nscvNodes"), root)));
      emitChildren(node.children, scope, slot, stack, depth + 1);
      output.push(s.assign(v.field(root, "end"), v.length(v.id("nscvNodes"))));
      return;
    }
    if (node.name === "timeline-item") {
      const props = componentRoot(["title", "description", "meta", "indicator", "icon", "variant", "connector", "selected", "on-press", "key", "global-key"]);
      if (!node.attrs.has("title") || node.children.length) fail(node, "timeline-item requires title and no children");
      if (node.attrs.has("on-press")) props.push(v.prop("press", event(node.attrs.get("on-press")!, "press", node, scope)));
      if (node.attrs.has("selected")) props.push(v.prop("selected", bound(node.attrs.get("selected")!, "boolean", node, scope)));
      const variant = stringAttr("variant", "outline");
      const connector = node.attrs.has("connector") ? bound(node.attrs.get("connector")!, "boolean", node, scope) : v.bool(true);
      const itemText = (name: string): ViewExpr => {
        const raw = node.attrs.get(name), bytes = raw === undefined ? null : byteText(raw, node, scope);
        return bytes === null ? v.object("component_text", [v.prop("text", stringAttr(name))]) : v.object("component_text", [v.prop("text", v.str("")), v.prop("bytes", bytes)]);
      };
      output.push(s.expr(v.call("nscvTimelineItem", v.id("nscvNodes"), v.object("timeline_item", [v.prop("root", v.object("node", props)), v.prop("title", itemText("title")), v.prop("description", itemText("description")),
        v.prop("meta", itemText("meta")), v.prop("indicator", itemText("indicator")), v.prop("icon", stringAttr("icon")), v.prop("variant", v.call("nscvVariant", variant)), v.prop("connector", connector)]))));
      return;
    }
    if (node.name === "video") {
      const props = componentRoot(["src", "controls", "autoplay", "loop", "muted", "key", "global-key", "width", "height", "grow", "label"]);
      if (node.children.length || node.text.trim()) fail(node, "video is a leaf");
      for (const name of ["width", "height", "grow"]) if (node.attrs.has(name)) props.push(v.prop(name, bound(node.attrs.get(name)!, "number", node, scope)));
      const flag = (name: string, fallback: boolean) => node.attrs.has(name) ? bound(node.attrs.get(name)!, "boolean", node, scope) : v.bool(fallback);
      output.push(s.expr(v.call("nscvVideoElement", v.id("nscvNodes"), v.object("node", props), v.id("nscvVideo"), stringAttr("src"), flag("controls", false), flag("autoplay", true), flag("loop", false), flag("muted", false))));
      return;
    }
    if (node.name === "markdown") {
      const allowed = ["source", "on-link", "on-details", "details-expanded", "issue-link-base", "images"];
      if (node.children.length || node.text.trim() || !node.attrs.has("source") || [...node.attrs.keys()].some(name => !allowed.includes(name))) fail(node, "markdown requires source, no children, and its closed presentation attributes");
      const source = binding(node.attrs.get("source")!, node, scope);
      if (!/^\{[^{}]+\}$/.test(node.attrs.get("source")!) || source.type.kind !== "bytes") fail(node, "markdown source requires one byte binding");
      let expanded: ViewExpr = v.array([]), issue: ViewExpr = v.nul(), images: ViewExpr = v.array([]), wordImages = false;
      if (node.attrs.has("details-expanded")) {
        const raw = node.attrs.get("details-expanded")!, value = binding(raw, node, scope);
        if (!/^\{[^{}]+\}$/.test(raw) || value.type.kind !== "slice" || value.type.elem?.kind !== "bool") fail(node, "details-expanded requires one boolean-array binding");
        expanded = value.code;
      }
      if (node.attrs.has("images")) {
        const raw = node.attrs.get("images")!, value = binding(raw, node, scope), record = value.type.kind === "slice" && value.type.elem && ["node", "value"].includes(value.type.elem.kind) ? contract.types.structs.find(item => item.name === value.type.elem!.name) : null;
        const imageField = record?.fields.find(field => field.name === "image");
        const identity = imageField && ["node", "value"].includes(imageField.type.kind) ? contract.types.structs.find(item => item.name === imageField.type.name) : null;
        wordImages = !!identity && identity.fields.length === 2 && ["imageLower", "imageUpper"].every(name => identity.fields.some(field => field.name === name && category(field.type) === "number"));
        if (!/^\{[^{}]+\}$/.test(raw) || !record || record.fields.length !== 4 || !record.fields.some(field => field.name === "source" && field.type.kind === "bytes") || !["width", "height"].every(name => record.fields.some(field => field.name === name && category(field.type) === "number")) || !(wordImages || imageField && category(imageField.type) === "number")) fail(node, "images requires source bytes, an exact registered image identity, width and height records");
        images = value.code;
      }
      if (node.attrs.has("issue-link-base")) {
        const raw = node.attrs.get("issue-link-base")!;
        if (raw.startsWith("{")) { const value = binding(raw, node, scope); if (!/^\{[^{}]+\}$/.test(raw) || value.type.kind !== "bytes") fail(node, "issue-link-base requires literal text or one byte binding"); issue = value.code; }
        else { if (/[{}]/.test(raw)) fail(node, "invalid issue-link-base literal"); issue = v.encode(v.str(raw)); }
      }
      const channels: ViewProp[] = [];
      for (const [attribute, property, kind] of [["on-link", "markdownLink", "bytes"], ["on-details", "markdownDetails", "number"]]) {
        const raw = node.attrs.get(attribute!); if (raw === undefined) continue;
        const arm = contract.msg.arms.find(item => item.name === raw);
        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(raw) || !arm || arm.payload.kind !== kind) fail(node, `${attribute} requires a bare ${kind} Msg arm`);
        usage?.msg.add(arm.name);
        channels.push(v.prop(property!, v.num(String(contract.msg.arms.indexOf(arm)))));
      }
      output.push(s.push(v.id("nscvNodes"), v.object("node", [v.prop("end", v.binary("+", v.length(v.id("nscvNodes")), v.num("1"), false)), v.prop("kind", v.str("markdown")), v.prop("text", v.str("")),
        v.prop("markdownRecipe", v.call(wordImages ? "nscvMarkdownRecipeWords" : "nscvMarkdownRecipe", source.code, expanded, issue, images)), ...channels])));
      return;
    }
    const kinds: Record<string, string> = { image: "image", terminal: "terminal", icon: "icon", combobox: "combobox", bubble: "bubble", table: "table", "data-grid": "data_grid", popover: "popover", "menu-surface": "menu_surface", "table-row": "data_row", "table-cell": "data_cell", progress: "progress", skeleton: "skeleton", spinner: "spinner", column: "column", row: "row", stack: "stack", grid: "grid", card: "card", alert: "alert", dialog: "dialog", drawer: "drawer", sheet: "sheet", tooltip: "tooltip", panel: "panel", badge: "badge", input: "input", "text-field": "text_field", textarea: "textarea", code: "textarea", "search-field": "search_field", select: "select", text: "text", button: "button", checkbox: "checkbox", switch: "switch_control", toggle: "toggle", slider: "slider", "status-bar": "status_bar", spacer: "spacer", scroll: "scroll", avatar: "avatar", radio: "radio", "radio-group": "radio_group", "button-group": "button_group", breadcrumb: "breadcrumb", pagination: "pagination", "toggle-group": "toggle_group", "toggle-button": "toggle_button", accordion: "accordion", tabs: "tabs", "segmented-control": "segmented_control", tree: "tree", list: "list", "list-item": "list_item", "dropdown-menu": "dropdown_menu", "menu-item": "menu_item", separator: "separator", split: "split", resizable: "resizable", "media-surface": "media_surface" };
    if (!Object.hasOwn(kinds, node.name)) fail(node, `unsupported element <${node.name}>`);
    if (node.name === "image" && (!node.attrs.has("image") || node.text.trim() || node.children.length)) fail(node, "image requires an identity binding and no content");
    if (node.name === "terminal" && (!node.attrs.has("pty") || node.text.trim() || node.children.length || node.attrs.has("text"))) fail(node, "terminal requires pty and no authored content");
    if (node.name === "icon" && (!node.attrs.has("name") || node.text.trim() || node.children.length)) fail(node, "icon requires name and no content");
    if (node.name === "radio-group" && !node.attrs.has("label")) fail(node, "radio-group requires a label");
    const menus = node.children.filter(child => child.name === "context-menu");
    if (menus.length > 1) fail(node, "an element takes at most one direct context-menu");
    const reactions = node.children.filter(child => child.name === "reactions");
    if (reactions.length && node.name !== "bubble") fail(node, "reactions requires bubble");
    if (reactions.length > 1) fail(node, "bubble takes at most one reactions child");
    const contentChildren = node.children.filter(child => child.name !== "context-menu" && child.name !== "reactions");
    const container = ["bubble", "table", "data-grid", "popover", "menu-surface", "table-row", "column", "row", "stack", "grid", "card", "alert", "dialog", "drawer", "sheet", "scroll", "panel", "radio-group", "button-group", "breadcrumb", "pagination", "toggle-group", "accordion", "tabs", "tree", "list", "list-item", "dropdown-menu", "split", "resizable"].includes(node.name);
    if (node.attrs.get("role") === "treeitem" && !["column", "row", "panel", "list-item"].includes(node.name)) fail(node, "compiled treeitem requires column, row, panel or list-item");
    if (node.attrs.get("role") === "tree" && !["column", "row", "panel", "scroll", "tree"].includes(node.name)) fail(node, "tree role requires a generic container");
    const paragraph = node.name === "text" && contentChildren.length > 0;
    if (!paragraph && (["list-item", "card", "alert"].includes(node.name) ? node.text.trim() !== "" && contentChildren.length !== 0 : container ? node.text.trim() !== "" : contentChildren.length !== 0)) fail(node, "mixed content is unsupported");
    const textSource = node.name === "icon" ? node.attrs.get("name")! : node.text.trim();
    const rawText = byteText(textSource, node, scope);
    const props: ViewProp[] = [v.prop("kind", v.str(kinds[node.name]!)), v.prop("text", rawText === null ? text(textSource, node, scope) : v.str(""))];
    if (node.name === "icon" && (textSource.startsWith("{") || textSource.startsWith("app:"))) {
      props[1] = v.prop("text", v.str(""));
      props.push(rawText === null ? v.prop("icon", text(textSource, node, scope)) : v.prop("iconBytes", rawText));
    } else if (rawText !== null) props.push(v.prop("textBytes", rawText));
    if (reactions.length) {
      const pill = reactions[0]!;
      if (pill.children.length || !pill.text.trim()) fail(pill, "reactions requires a nonempty text run");
      for (const name of pill.attrs.keys()) if (name !== "text-alignment") fail(pill, "reactions takes only text-alignment");
      const alignment = pill.attrs.get("text-alignment") ?? "end";
      if (!["start", "center", "end"].includes(alignment)) fail(pill, "unsupported reactions text-alignment");
      const raw = byteText(pill.text.trim(), pill, scope);
      props[1] = v.prop("text", raw === null ? text(pill.text.trim(), pill, scope) : v.str(""));
      if (raw !== null) props.push(v.prop("textBytes", raw));
      props.push(v.prop("textAlignment", v.str(alignment)));
    }
    if (menus.length) {
      const menu = menus[0]!;
      if (nonHitTargetNames.includes(node.name) && !["on-press", "on-double-press", "on-toggle", "on-hold", "on-drag"].some(name => node.attrs.has(name))) fail(menu, "context-menu requires an interactive host");
      if (menu.attrs.size || menu.text.trim()) fail(menu, "context-menu accepts only item declarations");
      const menuId = next++, menuName = `nscvContext${menuId}`;
      output.push(s.const(menuName, v.array([]), "NscContextMenuItem[]"));
      let leaves = 0, items = 0;
      const emitMenu = (nodes: Element[], menuScope: Scope, menuDepth: number): void => {
        if (menuDepth > 64) fail(menu, "context-menu nesting exceeds 64");
        for (let i = 0; i < nodes.length; i++) {
          const item = nodes[i]!;
          if (item.name === "if") {
            if (item.attrs.size !== 1 || !item.attrs.has("test") || item.text.trim()) fail(item, "if requires only test and child elements");
            const test = condition(item.attrs.get("test")!, item, menuScope);
            const then = block(() => emitMenu(item.children, menuScope, menuDepth + 1));
            const alternate = nodes[i + 1];
            if (alternate?.name === "else") {
              if (alternate.attrs.size || alternate.text.trim()) fail(alternate, "else accepts only child elements");
              output.push(s.if(test, then, block(() => emitMenu(alternate.children, menuScope, menuDepth + 1)))); i++;
            } else output.push(s.if(test, then));
            continue;
          }
          if (item.name === "else") fail(item, "else must immediately follow if");
          leaves++;
          if (leaves > 32) fail(menu, "context-menu takes at most 32 declared leaves");
          let value: ViewExpr;
          if (item.name === "separator") {
            if (item.attrs.size || item.children.length || item.text.trim()) fail(item, "context-menu separator must be empty");
            value = v.object("context_item", [v.prop("label", v.str("")), v.prop("enabled", v.bool(true)), v.prop("separator", v.bool(true))]);
          } else {
            if (item.name !== "menu-item" || item.children.length || !item.text.trim()) fail(item, "context-menu takes labeled menu-item leaves or conditional declarations");
            for (const name of item.attrs.keys()) if (!["on-press", "disabled"].includes(name)) fail(item, `unsupported context-menu item attribute ${name}`);
            const press = item.attrs.get("on-press"), disabled = item.attrs.get("disabled");
            if (press === undefined) fail(item, "context-menu menu-item requires on-press");
            const rawLabel = byteText(item.text.trim(), item, menuScope);
            value = v.object("context_item", [v.prop("label", rawLabel === null ? text(item.text.trim(), item, menuScope) : v.str("")), ...(rawLabel === null ? [] : [v.prop("labelBytes", rawLabel)]),
              v.prop("enabled", disabled === undefined ? v.bool(true) : v.unary("!", v.group(bound(disabled, "boolean", item, menuScope)), false)), v.prop("separator", v.bool(false)), v.prop("press", event(press, "press", item, menuScope))]);
            items++;
          }
          output.push(s.push(v.id(menuName), value));
        }
      };
      emitMenu(menu.children, scope, 0);
      if (items === 0) fail(menu, "context-menu requires at least one menu-item");
      props.push(v.prop("contextMenu", v.id(menuName)));
    }
    if (paragraph) {
      if (node.attrs.has("wrap") || node.attrs.has("overflow")) fail(node, "span paragraphs always word-wrap; drop wrap and overflow");
      const runs: ViewExpr[] = [];
      let separator = false;
      for (const part of node.content) {
        if ("name" in part && part.name === "context-menu") continue;
        const isSpan = "name" in part;
        if (isSpan && (part.name !== "span" || part.children.length || part.content.length !== 1 || !part.text.trim())) fail(part, "text takes nonempty span leaves without nesting");
        const raw = part.text;
        const visible = raw.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
        if (!isSpan && /^[ \t\r\n]/.test(raw)) separator = true;
        if (!visible) { if (/[ \t\r\n]/.test(raw)) separator = true; continue; }
        if (runs.length && separator) runs.push(v.object("span", [v.prop("text", v.str(" "))]));
        const rawSpan = byteText(visible, node, scope);
        const fields = [v.prop("text", rawSpan === null ? text(visible, node, scope) : v.str(""))];
        if (rawSpan !== null) fields.push(v.prop("textBytes", rawSpan));
        if (isSpan) for (const [name, value] of part.attrs) {
          if (["mono", "italic", "underline"].includes(name)) fields.push(v.prop(name === "mono" ? "monospace" : name, bound(value, "boolean", part, scope)));
          else if (name === "scale") {
            if (!value.startsWith("{") && (!Number.isFinite(Number(value)) || Number(value) <= 0)) fail(part, "span scale requires a positive finite number");
            fields.push(v.prop("scale", v.call("nscvSpanScale", bound(value, "number", part, scope))));
          } else if (name === "weight") {
            if (value.startsWith("{")) {
              const expr = binding(value, part, scope);
              const members = contract.types.enums?.find(item => item.name === expr.type.name)?.members;
              if (expr.type.kind !== "enum" || !members?.every(member => ["regular", "medium", "bold"].includes(member))) fail(part, "span weight requires regular, medium or bold");
              fields.push(v.prop("weight", expr.code));
            } else {
              if (!["regular", "medium", "bold"].includes(value)) fail(part, "unsupported span weight");
              fields.push(v.prop("weight", v.str(value)));
            }
          } else if (name === "foreground") {
            if (value.startsWith("{")) {
              const expr = binding(value, part, scope);
              const members = contract.types.enums?.find(item => item.name === expr.type.name)?.members;
              if (expr.type.kind !== "enum" || !members?.length || !members.every(member => colorTokenNames.includes(member))) fail(part, "span foreground requires its closed token vocabulary");
              fields.push(v.prop("color", expr.code));
            } else {
              if (!colorTokenNames.includes(value)) fail(part, "unsupported span foreground token");
              fields.push(v.prop("color", v.str(value)));
            }
          } else fail(part, `unsupported span attribute ${name}; layout, identity and events belong on text`);
        }
        runs.push(v.object("span", fields));
        separator = !isSpan && /[ \t\r\n]$/.test(raw);
      }
      props[1] = v.prop("text", v.str(""));
      props.push(v.prop("spans", v.array(runs)));
    }
    if (node.name === "code") {
      const editable = node.attrs.get("editable") ?? "false", wrap = node.attrs.get("wrap") ?? "true";
      const editableCode = bound(editable, "boolean", node, scope);
      if (wrap !== "true" && wrap !== "false") fail(node, "code wrap requires a literal boolean");
      if (editable === "false" && node.attrs.has("on-input")) fail(node, "read-only code cannot declare on-input");
      if (editable !== "true" || wrap !== "false") {
        props[0] = v.prop("kind", v.str("code"));
        props.push(v.prop("codeEditable", editableCode), v.prop("wrap", v.bool(wrap === "true")));
      }
      if (!node.attrs.has("source") || node.text.trim()) fail(node, "code requires a source binding and no element text");
      const expr = binding(node.attrs.get("source")!, node, scope);
      if (expr.type.kind !== "bytes") fail(node, "code source requires UTF-8 bytes");
      props[1] = v.prop("text", v.str(""));
      props.push(v.prop("textBytes", v.call("nscvTextBytes", v.array([expr.code]))));
      const language = (node.attrs.get("language") ?? "plain").replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "").toLowerCase();
      const aliases: Record<string, string> = { text: "plain", js: "javascript", mjs: "javascript", ts: "typescript", jsonc: "json", yml: "yaml", sh: "shell", bash: "shell", zsh: "shell", py: "python", rs: "rust", c: "c_like", h: "c_like", cc: "c_like", cpp: "c_like", "c++": "c_like", cs: "c_like", csharp: "c_like", java: "c_like", kotlin: "c_like", swift: "c_like", golang: "go", xml: "html", svg: "html", scss: "css", less: "css", md: "markdown" };
      const canonical = aliases[language] ?? language;
      if (language === "c_like" || !["plain", "zig", "javascript", "typescript", "json", "yaml", "shell", "python", "rust", "c_like", "go", "html", "css", "sql", "jsx", "tsx", "markdown"].includes(canonical)) fail(node, "code language requires a supported literal name");
      props.push(v.prop("codeLanguage", v.str(canonical)));
      const attrs = ["source", "language", "editable", "line-numbers", "added-lines", "removed-lines", "wrap", "width", "height", "min-width", "grow", "label", "key", "global-key", "on-input"];
      for (const name of node.attrs.keys()) if (!attrs.includes(name)) fail(node, `unsupported compiled code attribute ${name}`);
      if (node.attrs.has("on-input")) props.push(v.prop("input", v.cond(editableCode, event(node.attrs.get("on-input")!, "input", node, scope), v.undef())));
    }
    for (const [name, value] of node.attrs) {
      if (node.name === "code" && ["source", "language", "editable", "wrap", "line-numbers", "added-lines", "removed-lines", "on-input"].includes(name)) continue;
      if (name === "gap" && node.name === "resizable") fail(node, "resizable is a stacking surface; put gap on a row or column inside");
      if (name === "image") {
        if (!["image", "avatar"].includes(node.name) || !/^\{[^{}]+\}$/.test(value)) fail(node, "image requires one identity binding on image or avatar");
        const identity = binding(value, node, scope);
        if (identity.type.kind === "bytes") {
          const local = `nscvImage${next++}`;
          output.push(s.const(local, v.call("nscvImageIdentity", identity.code)));
          props.push(v.prop("imageLower", v.field(v.id(local), "imageLower")), v.prop("imageUpper", v.field(v.id(local), "imageUpper")));
        } else props.push(v.prop("image", bound(value, "number", node, scope)));
      }
      else if (name === "fit") {
        if (node.name !== "image" || !["contain", "cover", "stretch"].includes(value)) fail(node, "fit requires contain, cover or stretch on image");
        props.push(v.prop("imageFit", v.str(value)));
      }
      else if (["gap", "padding", "grow", "width", "height", "value"].includes(name)) props.push(v.prop(name, bound(value, "number", node, scope)));
      else if (["padding-top", "padding-bottom", "padding-left", "padding-right"].includes(name)) {
        const property = name.replace(/-([a-z])/g, (_, letter: string) => letter.toUpperCase());
        props.push(v.prop(property, bound(value, "number", node, scope)));
      }
      else if (name === "surface") {
        if (node.name !== "media-surface") fail(node, "surface requires media-surface");
        props.push(v.prop("image", bound(value, "number", node, scope)));
      }
      else if (name === "columns" || name === "virtual-item-extent" || name === "virtualized") {
        if (node.name !== "grid") fail(node, `${name} requires grid`);
        const prop = name === "virtual-item-extent" ? "virtualItemExtent" : name;
        const expr = bound(value, name === "virtualized" ? "boolean" : "number", node, scope);
        props.push(v.prop(prop, name === "columns" ? v.call("nscvGridCount", expr) : expr));
      }
      else if (name === "value-x") {
        if (node.name !== "scroll" || !node.attrs.has("axis") || node.attrs.get("axis") === "vertical") fail(node, "value-x requires scroll with axis=horizontal or both");
        props.push(v.prop("valueX", bound(value, "number", node, scope)));
      } else if (name === "axis" || name === "overscroll") {
        if (node.name !== "scroll") fail(node, `${name} requires scroll`);
        const vocabulary = name === "axis" ? ["vertical", "horizontal", "both"] : ["default", "none", "rubber_band"];
        if (value.startsWith("{")) {
          const expr = binding(value, node, scope);
          const members = contract.types.enums?.find(item => item.name === expr.type.name)?.members;
          if (expr.type.kind !== "enum" || !members?.every(member => vocabulary.includes(member))) fail(node, `${name} requires its closed enum vocabulary`);
          props.push(v.prop(name, expr.code));
        } else {
          if (!vocabulary.includes(value)) fail(node, `unsupported ${name}=${value}`);
          props.push(v.prop(name, v.str(value)));
        }
      }
      else if (name === "backdrop-blur") {
        if (value.startsWith("{")) {
          const expr = binding(value, node, scope);
          const members = contract.types.enums?.find(item => item.name === expr.type.name)?.members;
          if (expr.type.kind !== "enum" || !members?.every(member => ["none", "sm", "md"].includes(member))) fail(node, "backdrop-blur requires its closed token vocabulary");
          props.push(v.prop("backdropBlur", expr.code));
        } else {
          if (!["none", "sm", "md"].includes(value)) fail(node, "unsupported backdrop-blur token");
          props.push(v.prop("backdropBlur", v.str(value)));
        }
      }
      else if (name === "overflow") {
        if (!["clip", "ellipsis"].includes(value)) fail(node, "unsupported overflow");
        props.push(v.prop("overflow", v.str(value)));
      }
      else if (name === "text-alignment") {
        if (!["start", "center", "end"].includes(value)) fail(node, "unsupported text-alignment");
        props.push(v.prop("textAlignment", v.str(value)));
      }
      else if (name === "min-width" || name === "max-width") props.push(v.prop(name === "min-width" ? "minWidth" : "maxWidth", bound(value, "number", node, scope)));
      else if (["resize-duration", "resize-easing", "resize-origin"].includes(name)) {
        if (node.name !== "split") fail(node, `${name} requires split`);
        if (name !== "resize-duration" && (!node.attrs.has("resize-duration") || node.attrs.get("resize-duration") === "0")) fail(node, `${name} requires nonzero resize-duration`);
        if (name === "resize-duration") props.push(v.prop("resizeDuration", v.call("nscvResizeDuration", bound(value, "number", node, scope))));
        else if (name === "resize-origin") {
          if (!Number.isFinite(Number(value)) || Number(value) < 0 || Number(value) > 1) fail(node, "resize-origin requires a literal fraction from 0 to 1");
          props.push(v.prop("resizeOrigin", v.num(String(Number(value)))));
        } else {
          if (!["linear", "standard", "emphasized", "spring"].includes(value)) fail(node, "unsupported resize-easing");
          props.push(v.prop("resizeEasing", v.str(value)));
        }
      }
      else if (name === "pty") {
        if (node.name !== "terminal" || !value.startsWith("{")) fail(node, "pty requires a terminal binding");
        const expr = binding(value, node, scope);
        if (expr.type.kind === "bytes") props.push(v.prop("ptyBytes", v.from(expr.code)));
        else if (expr.type.kind === "i64") props.push(v.prop("pty", v.call("nscvPtyKey", expr.code)));
        else fail(node, "pty requires a byte name or integer key");
      } else if (name === "scrollback") {
        if (node.name !== "terminal") fail(node, "scrollback requires terminal");
        props.push(v.prop("scrollback", v.call("nscvScrollback", bound(value, "number", node, scope))));
      }
      else if (name === "quiet-hover") {
        if (nonHitTargetNames.includes(node.name)) fail(node, "quiet-hover requires a hit target element");
        props.push(v.prop("quietHover", bound(value, "boolean", node, scope)));
      }
      else if (["checked", "disabled", "selected", "window-drag", "wrap", "expanded", "submit-on-enter", "autofocus", "focusable"].includes(name)) {
        if (name === "autofocus" && !["input", "text-field", "search-field", "textarea", "combobox", "terminal"].includes(node.name)) fail(node, "autofocus requires a text-entry widget");
        if (name === "checked" && !["checkbox", "switch", "toggle", "radio"].includes(node.name)) fail(node, "checked requires checkbox, switch, toggle or radio");
        if (name === "submit-on-enter" && node.name !== "textarea") fail(node, "submit-on-enter requires textarea");
        if (name === "wrap" && node.name !== "text") fail(node, "wrap requires text");
        if (name === "expanded" && node.attrs.get("role") !== "treeitem") fail(node, "expanded requires role=treeitem");
        props.push(v.prop(name === "window-drag" ? "windowDrag" : name === "submit-on-enter" ? "submitOnEnter" : name, bound(value, "boolean", node, scope)));
      } else if (name === "tree-level") {
        if (node.attrs.get("role") !== "treeitem") fail(node, "tree-level requires role=treeitem");
        props.push(v.prop("treeLevel", v.call("nscvTreeLevel", bound(value, "number", node, scope))));
      } else if (name === "key" || name === "global-key") {
        props.push(keyProp(name, key(value, node, scope)));
      } else if (["label", "text", "placeholder", "command"].includes(name)) {
        if (name === "text" && !["input", "text-field", "search-field", "textarea", "combobox", "select", "accordion", "checkbox", "radio", "switch", "toggle", "button", "toggle-button", "table-cell", "status-bar", "badge", "menu-item", "list-item", "avatar", "tooltip", "text", "card", "alert", "dialog", "drawer", "sheet", "data-grid"].includes(node.name)) fail(node, "text requires a text-entry widget, select, accordion header, checkbox or captioned surface");
        if (name === "placeholder" && !["input", "text-field", "search-field", "textarea", "combobox", "select"].includes(node.name)) fail(node, "placeholder requires a text-entry widget or select");
        if (name === "text" && node.text.trim()) fail(node, "text attribute cannot be combined with element text");
        const expr = value.startsWith("{") ? binding(value, node, scope) : { code: v.str(value), type: { kind: "string" } };
        if (!["bytes", "string", "enum"].includes(expr.type.kind)) fail(node, `${name} requires text`);
        const rawBytes = name === "command" ? null : byteText(value, node, scope);
        const display = rawBytes === null ? textValue(expr, node) : v.str("");
        if (name === "text") props[1] = v.prop("text", display);
        else props.push(v.prop(name, display));
        if (rawBytes !== null) props.push(v.prop(`${name}Bytes`, rawBytes));
      }
      else if (name === "name" && node.name === "icon") {
        if (!value || /[{}]/.test(value) && !/^\{[^{}]+\}$/.test(value)) fail(node, "icon name requires a literal name or one text binding");
        if (value.startsWith("{") && !["bytes", "string", "enum"].includes(binding(value, node, scope).type.kind)) fail(node, "icon name requires text");
      }
      else if (name === "icon") {
        if (value.startsWith("{")) {
          const expr = binding(value, node, scope);
          if (!["bytes", "string", "enum"].includes(expr.type.kind)) fail(node, "icon requires text");
          if (expr.type.kind === "bytes") props.push(v.prop("iconBytes", v.call("nscvTextBytes", v.array([expr.code]))));
          else props.push(v.prop("icon", expr.code));
        } else { if (/[{}]/.test(value)) fail(node, "invalid icon name"); props.push(v.prop("icon", v.str(value))); }
      }
      else if (name === "icon-placement") {
        if (!["leading", "trailing"].includes(value)) fail(node, "unsupported icon-placement");
        props.push(v.prop("iconPlacement", v.str(value)));
      }
      else if (name === "tooltip-delay") {
        if (node.name !== "tooltip" || !node.attrs.has("anchor")) fail(node, "tooltip-delay requires anchored tooltip");
        const delay = value.startsWith("{") ? binding(value, node, scope) : { code: v.num(String(Number(value))), type: { kind: "i64" } };
        if (delay.type.kind !== "i64" || !value.startsWith("{") &&
            (!/^[0-9]+$/.test(value) || !Number.isInteger(Number(value)) || Number(value) > 2147483647))
          fail(node, "tooltip-delay requires a non-negative i32 integer");
        props.push(v.prop("tooltipDelay", v.call("nscvTooltipDelay", delay.code)));
      }
      else if (["anchor", "anchor-alignment", "anchor-offset"].includes(name)) {
        if (node.name !== "dropdown-menu" && node.name !== "tooltip") fail(node, `${name} requires dropdown-menu or tooltip`);
        if (name !== "anchor" && !node.attrs.has("anchor")) fail(node, `${name} requires anchor`);
        if (name === "anchor-offset") {
          if (value.trim() === "" || !Number.isFinite(Number(value))) fail(node, "anchor-offset requires a finite literal number");
          props.push(v.prop("anchorOffset", v.num(String(Number(value)))));
        }
        else {
          const vocabulary = name === "anchor" ? ["below", "above"] : ["start", "end", "stretch"];
          if (!vocabulary.includes(value)) fail(node, `unsupported ${name}=${value}`);
          props.push(v.prop(name === "anchor" ? "anchor" : "anchorAlignment", v.str(value)));
        }
      }
      else if (["main", "cross", "size", "variant", "role", "background", "foreground", "border-color", "focus-ring", "accent", "accent-foreground", "radius"].includes(name)) {
        const vocab: Record<string, string[]> = { main: ["start", "center", "end", "space_between"], cross: ["start", "center", "end", "stretch"], size: ["default", "sm", "lg", "icon", "heading", "display"], variant: ["default", "primary", "secondary", "ghost", "destructive", "outline"], role: ["list", "listitem", "tree", "treeitem", "tab"], background: colorTokenNames, foreground: colorTokenNames, "border-color": colorTokenNames, "focus-ring": colorTokenNames, accent: colorTokenNames, "accent-foreground": colorTokenNames, radius: ["sm", "md", "lg", "xl", "none"] };
        if (["variant", "background", "foreground", "border-color", "focus-ring", "accent", "accent-foreground", "radius"].includes(name) && value.startsWith("{")) {
          const expr = binding(value, node, scope);
          const members = contract.types.enums?.find(item => item.name === expr.type.name)?.members;
          if (expr.type.kind !== "enum" || !members?.length || !members.every(member => vocab[name]!.includes(member))) fail(node, `${name} requires its closed token vocabulary`);
          const property = name === "border-color" ? "borderColor" : name === "focus-ring" ? "focusRing" : name === "accent-foreground" ? "accentForeground" : name;
          props.push(v.prop(property, expr.code));
          continue;
        }
        if (!vocab[name]!.includes(value)) fail(node, `unsupported ${name}=${value}`);
        if (name === "size" && (value === "heading" || value === "display") && node.name !== "text") fail(node, `${value} size requires text`);
        props.push(v.prop(name === "border-color" ? "borderColor" : name === "focus-ring" ? "focusRing" : name === "accent-foreground" ? "accentForeground" : name, v.str(value)));
      } else if (["on-press", "on-double-press", "on-hold", "on-toggle", "on-change", "on-drag", "on-scroll", "on-terminal", "on-input", "on-submit", "on-dismiss", "on-resize", "on-hover-enter", "on-hover-leave"].includes(name)) {
        const channel = name.slice(3);
        const treeRow = container && node.attrs.get("role") === "treeitem";
        if (channel === "change" && !treeRow && !["radio", "slider", "list-item"].includes(node.name) || channel === "scroll" && node.name !== "scroll" || channel === "dismiss" && !["dropdown-menu", "popover", "menu-surface", "dialog", "drawer", "sheet"].includes(node.name)) fail(node, `${name} is unsupported on ${node.name}`);
        if ((channel === "input" || channel === "submit" && !treeRow) && !["input", "text-field", "search-field", "textarea", "combobox", "code"].includes(node.name)) fail(node, `${name} is unsupported on ${node.name}`);
        if (channel === "terminal" && node.name !== "terminal") fail(node, "on-terminal requires terminal");
        if (channel === "resize" && node.name !== "split") fail(node, "on-resize requires split");
        if (channel === "change" && node.name === "slider" && contract.msg.arms.find(arm => arm.name === value)?.payload.kind !== "void") {
          props.push(v.prop("valueChange", event(value, "value", node, scope)));
        } else props.push(v.prop(channel === "double-press" ? "doublePress" : channel === "hover-enter" ? "hoverEnter" : channel === "hover-leave" ? "hoverLeave" : channel, event(value, channel, node, scope)));
      } else fail(node, `unsupported attribute ${name}`);
    }
    const id = next++, nodes = v.id("nscvNodes"), built = v.id(`nscvNode${id}`);
    if (node.name === "tabs" || node.name === "split") output.push(s.const(`nscvStart${id}`, v.length(nodes)));
    output.push(s.const(`nscvNode${id}`, v.object("node", [v.prop("end", v.num("0")), ...props]), "NscViewNode"), s.push(nodes, built), s.throwIf(v.binary(">", v.length(nodes), v.num("1024"), false), "compiled view exceeds 1024 nodes"));
    if (!paragraph) emitChildren(contentChildren, scope, slot, stack, depth + 1); output.push(s.assign(v.field(built, "end"), v.length(nodes)));
    if (node.name === "code") {
      const spec = (name: string): ViewExpr => {
        const raw = node.attrs.get(name);
        if (raw === undefined) return v.emptyBytes();
        if (!raw.startsWith("{")) return v.encode(v.str(raw));
        const value = binding(raw, node, scope);
        if (value.type.kind !== "bytes") fail(node, `${name} requires one text binding or a literal line list`);
        return value.code;
      };
      output.push(s.expr(v.call("nscvCodeEditor", built, node.attrs.has("line-numbers") ? bound(node.attrs.get("line-numbers")!, "boolean", node, scope) : v.bool(false), spec("added-lines"), spec("removed-lines"))));
    }
    if (node.name === "tabs") output.push(s.expr(v.call("nscvTabs", nodes, v.id(`nscvStart${id}`))));
    if (node.name === "split") output.push(s.expr(v.call("nscvSplit", nodes, v.id(`nscvStart${id}`))));
  };
  emit(roots[0]!, new Map(), undefined, [], 0);
  const prologue = stamp ? "const nscvNodes: NscViewNode[] = [];\nconst nscvSources: number[] = [];\n" : "const nscvNodes: NscViewNode[] = [];\n";
  // Development records carry the node -> source attribution and the table.
  const attribution = stamp ? sourceAttribution(sourceTable, sources, entry, stamp) : "";
  const records = stamp
    ? `'{"format":2,"nodes":' + JSON.stringify(nscvNodes) + ',"sources":' + JSON.stringify(nscvSources) + ',' + ${JSON.stringify(attribution)} + '}'`
    : "JSON.stringify({ format: 2, nodes: nscvNodes })";
  return { body: output, attribution, text: `${exported ? "export " : ""}function ${functionName}(nscvVideo: NscVideoPlaybackState, nscvVirtual?: NscVirtualBuild): Uint8Array {\n${prologue}${printStatements(output).join("\n")}\nif (nscvVirtual?.requestsOnly) return new TextEncoder().encode(JSON.stringify({ format: 1, requests: nscvVirtual.requests }));\nif (nscvVirtual !== undefined && (nscvVirtual.requests.length !== nscvVirtual.ranges.length || nscvVirtual.consumed.length !== nscvVirtual.requests.length)) throw new Error("virtual window context count mismatch");\nif (nscvNodes.length === 0 || nscvNodes[0]!.end !== nscvNodes.length) throw new Error("compiled view requires one rendered root");\nreturn new TextEncoder().encode(${records});\n}\n` };
}

const viewPrelude = "\n// Portable Native components compiled beside the committed model.\n" + portableSourceText;

import { spawnSync } from "node:child_process";

// The inspector console's isolated evaluation for a Node run: a fresh vm context with its own
// intrinsics, in a Node child process. The compiled CLI has no Node of its own, so it keeps the
// hardened expression evaluator instead (see console-eval.ts); a Node run uses this boundary.

export const INSPECT_CONSOLE = String.raw`
function (jsonText) {
  "use strict";
  var stringify = JSON.stringify;
  var evaluateIndirectly = eval;
  var data = JSON.parse(jsonText);
  var byId = new Map();
  for (var i = 0; i < data.nodes.length; i++) byId.set(data.nodes[i].id, data.nodes[i]);
  var mirror = new Map();
  var logs = [];
  function attr(node, name) {
    for (var i = 0; i < node.attrs.length; i++) if (node.attrs[i][0] === name) return node.attrs[i][1];
    return null;
  }
  function textOf(node) {
    if (node.type === 3 || node.type === 8) return node.text;
    var text = "";
    for (var i = 0; i < node.children.length; i++) {
      var child = byId.get(node.children[i]);
      if (child !== undefined) text += textOf(child);
    }
    return text;
  }
  function matches(node, selector) {
    var s = selector.trim();
    if (s.charAt(0) === "#") return attr(node, "id") === s.slice(1);
    if (s.charAt(0) === ".") {
      var cls = attr(node, "class");
      return cls !== null && cls.split(/\s+/).indexOf(s.slice(1)) >= 0;
    }
    return node.name === s.toLowerCase() || (s === "*" && node.type === 1);
  }
  function collect(node, type) {
    var out = [];
    for (var i = 0; i < node.children.length; i++) {
      var child = byId.get(node.children[i]);
      if (child !== undefined && (type === undefined || child.type === type)) out.push(view(child));
    }
    return out;
  }
  function queryAll(node, selector) {
    var out = [];
    function walk(current) {
      for (var i = 0; i < current.children.length; i++) {
        var child = byId.get(current.children[i]);
        if (child === undefined) continue;
        if (child.type === 1 && matches(child, selector)) out.push(view(child));
        walk(child);
      }
    }
    walk(node);
    return out;
  }
  function view(node) {
    var known = mirror.get(node.id);
    if (known !== undefined) return known;
    var el = {
      nodeId: node.id,
      nodeType: node.type,
      nodeName: node.type === 1 ? node.name.toUpperCase() : node.name,
      localName: node.name,
      id: attr(node, "id") === null ? "" : attr(node, "id"),
      className: attr(node, "class") === null ? "" : attr(node, "class"),
      getAttribute: function (name) { return attr(node, name); },
      getBoundingClientRect: function () {
        var r = node.rect === null ? [0, 0, 0, 0] : node.rect;
        return { x: r[0], y: r[1], left: r[0], top: r[1], width: r[2], height: r[3],
          right: r[0] + r[2], bottom: r[1] + r[3] };
      },
      querySelector: function (selector) { var found = queryAll(node, selector); return found.length === 0 ? null : found[0]; },
      querySelectorAll: function (selector) { return queryAll(node, selector); },
      matches: function (selector) { return matches(node, selector); }
    };
    Object.defineProperty(el, "textContent", { get: function () { return textOf(node); } });
    Object.defineProperty(el, "childNodes", { get: function () { return collect(node); } });
    Object.defineProperty(el, "children", { get: function () { return collect(node, 1); } });
    Object.defineProperty(el, "parentNode", { get: function () {
      var p = byId.get(node.parent);
      return p === undefined ? null : view(p);
    } });
    Object.defineProperty(el, "parentElement", { get: function () {
      var p = byId.get(node.parent);
      return p !== undefined && p.type === 1 ? view(p) : null;
    } });
    mirror.set(node.id, el);
    return el;
  }
  var root = byId.get(data.root);
  var documentView = root === undefined ? {} : view(root);
  var html = undefined;
  var body = undefined;
  for (var i = 0; i < data.nodes.length; i++) {
    if (root !== undefined && html === undefined && data.nodes[i].parent === root.id && data.nodes[i].type === 1) html = data.nodes[i];
    if (body === undefined && data.nodes[i].name === "body") body = data.nodes[i];
  }
  documentView.title = data.title;
  documentView.documentElement = html === undefined ? null : view(html);
  documentView.body = body === undefined ? null : view(body);
  documentView.getElementById = function (id) {
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && attr(data.nodes[i], "id") === id) return view(data.nodes[i]);
    return null;
  };
  documentView.querySelector = function (selector) {
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && matches(data.nodes[i], selector)) return view(data.nodes[i]);
    return null;
  };
  documentView.querySelectorAll = function (selector) {
    var out = [];
    for (var i = 0; i < data.nodes.length; i++)
      if (data.nodes[i].type === 1 && matches(data.nodes[i], selector)) out.push(view(data.nodes[i]));
    return out;
  };
  globalThis.document = documentView;
  globalThis.getComputedStyle = function (el) {
    var id = typeof el === "object" && el !== null && "nodeId" in el ? Number(el.nodeId) : -1;
    var node = byId.get(id);
    return { getPropertyValue: function (name) { return node === undefined ? "" : node.styles[name] ?? ""; } };
  };
  globalThis.console = {
    log: function () { logs.push({ level: "log", text: Array.prototype.map.call(arguments, String).join(" ") }); },
    warn: function () { logs.push({ level: "warn", text: Array.prototype.map.call(arguments, String).join(" ") }); },
    error: function () { logs.push({ level: "error", text: Array.prototype.map.call(arguments, String).join(" ") }); }
  };
  function describe(value) {
    if (value === null) return { type: "object", subtype: "null", value: null };
    if (value === undefined) return { type: "undefined" };
    var type = typeof value;
    if (type === "string" || type === "number" || type === "boolean") return { type: type, value: value };
    if (type === "function") return { type: "function", description: String(value) };
    try {
      var json = stringify(value);
      return { type: "object", value: json === undefined ? String(value) : JSON.parse(json) };
    } catch (e) {
      return { type: "object", description: String(value) };
    }
  }
  var lastThenable = null;
  function errorText(reason) {
    if (typeof reason === "object" && reason !== null) {
      try {
        if (reason.code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING" || reason.code === "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING_FLAG") {
          return "import() is not available in the inspector console";
        }
        if (typeof reason.message === "string") return reason.message;
      } catch (e) {
        // A reason whose getters throw falls through to String().
      }
    }
    return String(reason);
  }
  // The host calls these across the realm boundary, so an expression must not be able to replace
  // them: a replaced helper could return a context object that the host is asked to convert.
  function expose(name, value) {
    Object.defineProperty(globalThis, name, { value: value, writable: false, enumerable: false, configurable: false });
  }
  expose("__inspectRun", function (source) {
    var value;
    lastThenable = null;
    try {
      value = (0, evaluateIndirectly)(source);
    } catch (err) {
      return stringify({ exception: errorText(err) });
    }
    if (value !== null && (typeof value === "object" || typeof value === "function")) {
      var then = null;
      try { then = value.then; } catch (e) { then = null; }
      if (typeof then === "function") {
        // A promise the expression leaves behind must not become an unhandled rejection: a
        // handler keeps it off the dev process, and the console reports its rejection instead.
        var state = { settled: false, error: null };
        lastThenable = state;
        try {
          then.call(value, undefined, function (reason) {
            state.settled = true;
            state.error = errorText(reason);
          });
        } catch (e) {
          state.settled = true;
          state.error = errorText(e);
        }
      }
    }
    return stringify({ value: describe(value) });
  });
  expose("__inspectThenable", function () {
    return lastThenable === null ? "null" : stringify(lastThenable);
  });
  expose("__inspectLogs", function () { return stringify(logs); });
}`;

/**
 * A Node program that evaluates one expression in a fresh vm realm and prints the result as JSON.
 * The context is created with DONT_CONTEXTIFY, so its intrinsics are the context's own; the
 * console's globals are built inside it from the snapshot's JSON.
 */
export const SANDBOX_HARNESS = `
import vm from "node:vm";
const sandboxSource = ${JSON.stringify(INSPECT_CONSOLE)};
const input = await new Promise((resolve) => {
  let text = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { text += chunk; });
  process.stdin.on("end", () => resolve(text));
});
const { snapshotJson, expression } = JSON.parse(input);
const context = vm.createContext(vm.constants.DONT_CONTEXTIFY);
vm.runInContext("(" + sandboxSource + ")(" + JSON.stringify(snapshotJson) + ")", context, { timeout: 1000 });
// Everything the context returns is untrusted data. Only a primitive string is read from it:
// converting a context value (String(), a template literal, a property read) would run that
// object's code in this realm, where its constructor chain reaches this realm's Function.
function contextText(code) {
  let value;
  try {
    value = vm.runInContext(code, context, { timeout: 1000, displayErrors: false });
  } catch {
    // A thrown value can be a context object too (a Proxy runs code when it is inspected), so
    // nothing about it is read here: even typeof and instanceof would reach into the context.
    return { error: "the console expression could not be evaluated" };
  }
  return typeof value === "string" ? { text: value } : {};
}
const run = contextText("__inspectRun(" + JSON.stringify(expression) + ")");
let raw = run.text !== undefined ? run.text
  : JSON.stringify({ exception: run.error !== undefined ? run.error : "the expression produced no result" });
let thenable = null;
const thenableRun = contextText("__inspectThenable()");
if (thenableRun.text !== undefined) { try { thenable = JSON.parse(thenableRun.text); } catch {} }
let logs = [];
const logsRun = contextText("__inspectLogs()");
if (logsRun.text !== undefined) { try { logs = JSON.parse(logsRun.text); } catch {} }
let answer;
try { answer = JSON.parse(raw); } catch { answer = { exception: "the expression produced no result" }; }
process.stdout.write(JSON.stringify({ answer, thenable, logs }));
`;

/** Runs one console expression in the isolated child and returns its JSON result. */
export function evaluateConsole(snapshotJson: string, expression: string): string {
  const payload = "{\"snapshotJson\":" + JSON.stringify(snapshotJson) + ",\"expression\":" + JSON.stringify(expression) + "}";
  // The compiled CLI has no Node of its own, so it asks the machine's Node for the child; a
  // workspace run already is Node and spawns itself.
  const node = process.env["NATIVE_SDK_BINARY"] === "1" ? "node" : process.execPath;
  const result = spawnSync(node, ["--input-type=module", "--eval", SANDBOX_HARNESS], {
    input: payload,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error !== undefined) {
    throw new Error("the inspector console needs Node.js on this machine: " + result.error.message);
  }
  if (result.status !== 0) throw new Error((result.stderr || "").trim() || "console evaluation failed");
  return result.stdout;
}

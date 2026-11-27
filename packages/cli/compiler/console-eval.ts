// The inspector console's evaluator: a JavaScript expression evaluated against the snapshot's
// mirror DOM. The native executable embeds no JavaScript engine, so instead of node:vm this reads
// the expressions a console is typed (`document.querySelector("h1").textContent`,
// `getComputedStyle($0).color`, `document.title.length > 3 ? "long" : "short"`) and walks them:
// literals, names in scope, member access (`.`, `?.`, `[]`), calls, array and object literals,
// unary, binary, logical and conditional operators, and comma sequences. Assignment, functions,
// `new` and statements are reported as unsupported, which keeps an evaluation free of side effects
// beyond the scope's own functions.

type Scope = { [name: string]: unknown };

/**
 * The keys an expression may never name. Reading them walks the host's reflection surface
 * (`constructor` of anything leads to the host Function constructor), and writing `__proto__` into
 * an object literal used to make that object inherit from whatever the expression named. The
 * console exposes data and its own functions; reflection is not part of what it exposes.
 */
const REFLECTION_KEYS = new Set([
  "__proto__", "prototype", "constructor",
  "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
  "caller", "callee",
]);

/**
 * The functions a console expression may call: the ones the inspector explicitly exposes (registered
 * by `registerConsoleFunction`) and the helpers the evaluator makes for strings and arrays. Anything
 * else a value leads to is data, never a call target.
 */
type ConsoleFunction = (...args: unknown[]) => unknown;
const callableFunctions = new WeakSet<ConsoleFunction>();

/** Registers a function the console is allowed to call; the inspector registers what it exposes. */
export function registerConsoleFunction(value: unknown): void {
  if (typeof value === "function") callableFunctions.add(value as ConsoleFunction);
}

interface Token {
  kind: "num" | "str" | "name" | "punct" | "end";
  text: string;
  value?: unknown;
  at: number;
}

const PUNCT = [
  "===", "!==", "...", "?.", "??", "&&", "||", "==", "!=", "<=", ">=", "**",
  "(", ")", "[", "]", "{", "}", ".", ",", "?", ":", "+", "-", "*", "/", "%", "<", ">", "!", "~",
];

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (/\s/.test(c)) {
      i++;
      continue;
    }
    const start = i;
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(source[i + 1] ?? ""))) {
      const m = /^(0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/.exec(source.slice(i));
      const text = m === null ? c : m[0];
      tokens.push({ kind: "num", text, value: Number(text), at: start });
      i += text.length;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let value = "";
      i++;
      while (i < source.length && source[i] !== c) {
        if (source[i] === "\\") {
          const next = source[i + 1] ?? "";
          const escapes: { [key: string]: string } = { n: "\n", t: "\t", r: "\r", "0": "\0", b: "\b", f: "\f", v: "\v" };
          if (next === "u" && /^[0-9a-fA-F]{4}$/.test(source.slice(i + 2, i + 6))) {
            value += String.fromCharCode(parseInt(source.slice(i + 2, i + 6), 16));
            i += 6;
            continue;
          }
          value += escapes[next] ?? next;
          i += 2;
          continue;
        }
        if (c === "`" && source[i] === "$" && source[i + 1] === "{") throw new SyntaxError("template substitutions are not supported in the console");
        value += source[i];
        i++;
      }
      if (i >= source.length) throw new SyntaxError("unterminated string literal");
      i++;
      tokens.push({ kind: "str", text: source.slice(start, i), value, at: start });
      continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      const m = /^[A-Za-z_$][\w$]*/.exec(source.slice(i));
      const text = m === null ? c : m[0];
      tokens.push({ kind: "name", text, at: start });
      i += text.length;
      continue;
    }
    const punct = PUNCT.find((p) => source.startsWith(p, i));
    if (punct === undefined) throw new SyntaxError(`unexpected character '${c}'`);
    // `a?.5:b` is a conditional, not an optional chain.
    if (punct === "?." && /[0-9]/.test(source[i + 2] ?? "")) {
      tokens.push({ kind: "punct", text: "?", at: start });
      i += 1;
      continue;
    }
    tokens.push({ kind: "punct", text: punct, at: start });
    i += punct.length;
  }
  tokens.push({ kind: "end", text: "", at: source.length });
  return tokens;
}

/** Binary operators, by precedence (higher binds tighter). */
const BINARY: { [op: string]: number } = {
  "??": 1, "||": 2, "&&": 3,
  "==": 6, "!=": 6, "===": 6, "!==": 6,
  "<": 7, ">": 7, "<=": 7, ">=": 7, instanceof: 7, in: 7,
  "+": 9, "-": 9, "*": 10, "/": 10, "%": 10, "**": 11,
};

/** A value and, when it was read as a member, the object it was read from (a call's `this`). */
interface Ref {
  value: unknown;
  receiver: unknown;
}

class Evaluator {
  private pos = 0;
  private readonly tokens: Token[];
  private readonly scope: Scope;

  constructor(tokens: Token[], scope: Scope) {
    this.tokens = tokens;
    this.scope = scope;
  }

  private peek(): Token {
    return this.tokens[this.pos];
  }

  private next(): Token {
    return this.tokens[this.pos++];
  }

  private is(text: string): boolean {
    const t = this.peek();
    return (t.kind === "punct" || t.kind === "name") && t.text === text;
  }

  private expect(text: string): void {
    if (!this.is(text)) throw new SyntaxError(`expected '${text}'${this.peek().kind === "end" ? " at the end" : ` before '${this.peek().text}'`}`);
    this.pos++;
  }

  run(): unknown {
    let value = this.assignment();
    while (this.is(",")) {
      this.pos++;
      value = this.assignment();
    }
    if (this.peek().kind !== "end") throw new SyntaxError(`unexpected '${this.peek().text}'`);
    return value;
  }

  private assignment(): unknown {
    const value = this.conditional();
    if (this.is("=") || this.is("=>")) throw new SyntaxError("the console evaluates expressions without assignments or functions");
    return value;
  }

  private conditional(): unknown {
    const test = this.binary(0);
    if (!this.is("?")) return test;
    this.pos++;
    // Both branches are parsed; only the taken one is evaluated (see skip()).
    if (test) {
      const value = this.assignment();
      this.expect(":");
      this.skip(() => this.assignment());
      return value;
    }
    this.skip(() => this.assignment());
    this.expect(":");
    return this.assignment();
  }

  /** Whether the tokens are being parsed without being evaluated (an untaken branch). */
  private skipping = false;

  private skip(parse: () => unknown): void {
    const was = this.skipping;
    this.skipping = true;
    try {
      parse();
    } finally {
      this.skipping = was;
    }
  }

  private binary(min: number): unknown {
    let left = this.unary();
    for (;;) {
      const t = this.peek();
      const op = t.text;
      const prec = (t.kind === "punct" || t.kind === "name") && Object.prototype.hasOwnProperty.call(BINARY, op) ? BINARY[op] : 0;
      // Operators bind left to right, except ** (right to left).
      if (prec === 0 || prec < min || (prec === min && op !== "**")) return left;
      this.pos++;
      if (op === "&&" || op === "||" || op === "??") {
        const short = op === "&&" ? !left : op === "||" ? !!left : left !== null && left !== undefined;
        if (short) {
          this.skip(() => this.binary(prec));
          continue;
        }
        left = this.binary(prec);
        continue;
      }
      const right = this.binary(prec);
      left = this.skipping ? undefined : applyBinary(op, left, right);
    }
  }

  private unary(): unknown {
    const t = this.peek();
    if (t.kind === "punct" && (t.text === "!" || t.text === "-" || t.text === "+" || t.text === "~")) {
      this.pos++;
      const value = this.unary();
      if (this.skipping) return undefined;
      if (t.text === "!") return !value;
      if (t.text === "-") return -Number(value);
      if (t.text === "+") return Number(value);
      return ~Number(value);
    }
    if (t.kind === "name" && (t.text === "typeof" || t.text === "void")) {
      this.pos++;
      if (t.text === "typeof" && this.peek().kind === "name" && !this.isKeyword(this.peek().text)) {
        // typeof an undeclared name is "undefined", not an error.
        const name = this.peek().text;
        if (!Object.prototype.hasOwnProperty.call(this.scope, name) && !this.followsMember()) {
          this.pos++;
          return "undefined";
        }
      }
      const value = this.unary();
      return t.text === "void" ? undefined : typeof value;
    }
    if (t.kind === "name" && (t.text === "new" || t.text === "delete" || t.text === "function" || t.text === "await")) {
      throw new SyntaxError(`'${t.text}' is not supported in the console`);
    }
    return this.postfix().value;
  }

  private followsMember(): boolean {
    const after = this.tokens[this.pos + 1];
    return after !== undefined && after.kind === "punct" && (after.text === "." || after.text === "[" || after.text === "(" || after.text === "?.");
  }

  private isKeyword(name: string): boolean {
    return name === "true" || name === "false" || name === "null" || name === "undefined" || name === "typeof" || name === "void";
  }

  private postfix(): Ref {
    let ref: Ref = { value: this.primary(), receiver: undefined };
    for (;;) {
      if (this.is(".") || this.is("?.")) {
        const optional = this.next().text === "?.";
        if (optional && this.is("(")) {
          ref = this.call(ref, true);
          continue;
        }
        if (optional && this.is("[")) {
          this.pos++;
          const key = this.assignment();
          this.expect("]");
          ref = this.member(ref.value, key, true);
          continue;
        }
        const name = this.next();
        if (name.kind !== "name") throw new SyntaxError(`unexpected '${name.text}' after '.'`);
        ref = this.member(ref.value, name.text, optional);
      } else if (this.is("[")) {
        this.pos++;
        const key = this.assignment();
        this.expect("]");
        ref = this.member(ref.value, key, false);
      } else if (this.is("(")) {
        ref = this.call(ref, false);
      } else {
        return ref;
      }
    }
  }

  private member(object: unknown, key: unknown, optional: boolean): Ref {
    if (this.skipping) return { value: undefined, receiver: undefined };
    if (object === null || object === undefined) {
      if (optional) return { value: undefined, receiver: undefined };
      throw new TypeError(`Cannot read properties of ${object === null ? "null" : "undefined"} (reading '${String(key)}')`);
    }
    const name = String(key);
    if (REFLECTION_KEYS.has(name)) throw new TypeError(`the console does not expose '${name}'`);
    if (typeof object === "string") {
      if (name === "length") return { value: object.length, receiver: object };
      const index = typeof key === "number" ? key : Number(key);
      if (Number.isInteger(index)) return { value: object[index], receiver: object };
      const fn = stringMethod(object, name);
      registerConsoleFunction(fn);
      return { value: fn, receiver: object };
    }
    if (Array.isArray(object)) {
      if (name === "length") return { value: object.length, receiver: object };
      const index = typeof key === "number" ? key : Number(key);
      if (Number.isInteger(index)) return { value: object[index], receiver: object };
      const fn = arrayMethod(object, name);
      registerConsoleFunction(fn);
      return { value: fn, receiver: object };
    }
    if (typeof object === "object") {
      // Only what the object itself carries: an inherited key is not the console's to read, and a
      // getter the inspector defined runs with its own object as `this`.
      if (!Object.prototype.hasOwnProperty.call(object, name)) return { value: undefined, receiver: object };
      return { value: (object as Scope)[name], receiver: object };
    }
    return { value: undefined, receiver: object };
  }

  private call(callee: Ref, optional: boolean): Ref {
    this.expect("(");
    const args: unknown[] = [];
    while (!this.is(")")) {
      if (this.is("...")) throw new SyntaxError("spread arguments are not supported in the console");
      args.push(this.assignment());
      if (!this.is(")")) this.expect(",");
    }
    this.expect(")");
    if (this.skipping) return { value: undefined, receiver: undefined };
    const fn = callee.value;
    if (optional && (fn === null || fn === undefined)) return { value: undefined, receiver: undefined };
    if (typeof fn !== "function") throw new TypeError(`${describeCallee(fn)} is not a function`);
    if (!callableFunctions.has(fn as ConsoleFunction)) throw new TypeError("the console only calls the functions it exposes");
    return { value: (fn as (...a: unknown[]) => unknown)(...args), receiver: undefined };
  }

  private primary(): unknown {
    const t = this.next();
    if (t.kind === "num" || t.kind === "str") return t.value;
    if (t.kind === "name") {
      if (t.text === "true") return true;
      if (t.text === "false") return false;
      if (t.text === "null") return null;
      if (t.text === "undefined") return undefined;
      if (this.skipping) return undefined;
      if (!Object.prototype.hasOwnProperty.call(this.scope, t.text)) throw new ReferenceError(`${t.text} is not defined`);
      return this.scope[t.text];
    }
    if (t.kind === "punct" && t.text === "(") {
      let value = this.assignment();
      while (this.is(",")) {
        this.pos++;
        value = this.assignment();
      }
      this.expect(")");
      return value;
    }
    if (t.kind === "punct" && t.text === "[") {
      const items: unknown[] = [];
      while (!this.is("]")) {
        if (this.is(",")) {
          this.pos++;
          items.push(undefined);
          continue;
        }
        items.push(this.assignment());
        if (!this.is("]")) this.expect(",");
      }
      this.expect("]");
      return items;
    }
    if (t.kind === "punct" && t.text === "{") {
      const object: Scope = {};
      while (!this.is("}")) {
        const key = this.next();
        if (key.kind !== "name" && key.kind !== "str" && key.kind !== "num") throw new SyntaxError(`unexpected '${key.text}' in an object literal`);
        const name = key.kind === "name" ? key.text : String(key.value);
        if (REFLECTION_KEYS.has(name)) throw new TypeError(`the console does not expose '${name}'`);
        let value: unknown;
        if (this.is(":")) {
          this.pos++;
          value = this.assignment();
        } else if (key.kind === "name") {
          if (this.skipping) value = undefined;
          else if (!Object.prototype.hasOwnProperty.call(this.scope, name)) throw new ReferenceError(`${name} is not defined`);
          else value = this.scope[name];
        } else {
          this.expect(":");
          value = undefined;
        }
        // The keys that could reach a setter on Object.prototype (__proto__ and the rest of the
        // reflection keys) are refused above, so this assignment only ever defines an own data
        // property: the object can never be pointed at a host value.
        object[name] = value;
        if (!this.is("}")) this.expect(",");
      }
      this.expect("}");
      return object;
    }
    throw new SyntaxError(t.kind === "end" ? "unexpected end of input" : `unexpected '${t.text}'`);
  }
}

function describeCallee(value: unknown): string {
  if (value === undefined) return "undefined";
  if (value === null) return "null";
  return typeof value;
}

function looseEquals(a: unknown, b: unknown): boolean {
  if ((a === null || a === undefined) && (b === null || b === undefined)) return true;
  if (a === null || a === undefined || b === null || b === undefined) return false;
  if (typeof a === typeof b) return a === b;
  if (typeof a === "object" || typeof b === "object") return a === b;
  return Number(a) === Number(b);
}

function applyBinary(op: string, a: unknown, b: unknown): unknown {
  switch (op) {
    case "+":
      if (typeof a === "string" || typeof b === "string") return String(a) + String(b);
      return Number(a) + Number(b);
    case "-": return Number(a) - Number(b);
    case "*": return Number(a) * Number(b);
    case "/": return Number(a) / Number(b);
    case "%": return Number(a) % Number(b);
    case "**": return Math.pow(Number(a), Number(b));
    case "===": return a === b;
    case "!==": return a !== b;
    case "==": return looseEquals(a, b);
    case "!=": return !looseEquals(a, b);
    case "<": return typeof a === "string" && typeof b === "string" ? a < b : Number(a) < Number(b);
    case ">": return typeof a === "string" && typeof b === "string" ? a > b : Number(a) > Number(b);
    case "<=": return typeof a === "string" && typeof b === "string" ? a <= b : Number(a) <= Number(b);
    case ">=": return typeof a === "string" && typeof b === "string" ? a >= b : Number(a) >= Number(b);
    case "in":
      return b !== null && typeof b === "object" && Object.prototype.hasOwnProperty.call(b, String(a));
  }
  throw new SyntaxError(`'${op}' is not supported in the console`);
}

/** The string methods a console expression can call, bound to the string. */
function stringMethod(s: string, name: string): unknown {
  switch (name) {
    case "trim": return () => s.trim();
    case "toUpperCase": return () => s.toUpperCase();
    case "toLowerCase": return () => s.toLowerCase();
    case "includes": return (x: unknown) => s.includes(String(x));
    case "startsWith": return (x: unknown) => s.startsWith(String(x));
    case "endsWith": return (x: unknown) => s.endsWith(String(x));
    case "indexOf": return (x: unknown) => s.indexOf(String(x));
    case "slice": return (a?: unknown, b?: unknown) => s.slice(a === undefined ? undefined : Number(a), b === undefined ? undefined : Number(b));
    case "split": return (x: unknown) => s.split(String(x));
    case "charAt": return (x: unknown) => s.charAt(Number(x));
    case "at": return (x: unknown) => s.at(Number(x));
    case "toString": return () => s;
  }
  return undefined;
}

/** The array methods a console expression can call, bound to the array. */
function arrayMethod(items: unknown[], name: string): unknown {
  switch (name) {
    case "at": return (x: unknown) => items.at(Number(x));
    case "includes": return (x: unknown) => items.includes(x);
    case "indexOf": return (x: unknown) => items.indexOf(x);
    case "join": return (x?: unknown) => items.map((item) => (item === null || item === undefined ? "" : String(item))).join(x === undefined ? "," : String(x));
    case "slice": return (a?: unknown, b?: unknown) => items.slice(a === undefined ? undefined : Number(a), b === undefined ? undefined : Number(b));
    case "concat": return (...more: unknown[]) => items.concat(...more.map((m) => (Array.isArray(m) ? m : [m])));
    case "reverse": return () => [...items].reverse();
  }
  return undefined;
}

/** Evaluates `expression` with the names in `scope`. Throws a SyntaxError for what it can't read,
 *  and whatever the expression itself throws. */
export function evaluateExpression(expression: string, scope: Scope): unknown {
  return new Evaluator(tokenize(expression), scope).run();
}

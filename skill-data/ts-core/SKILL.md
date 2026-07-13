---
name: ts-core
description: Authoring guide for TypeScript app cores - Model, Msg, update, and the pure functions they call, written in the closed app-core subset and compiled ahead-of-time to arena-backed Zig by the @native-sdk/core transpiler. Use when writing or modifying a src/core.ts app core, fixing subset checker errors (NS1001-NS1060), or deciding how to express state, messages, text (bytes and the byte-text string methods), text input, continuous controls (sliders, scroll), effects (Cmd), subscriptions (Sub), the host-event wiring channels (frameMsg, keyMsg, appearanceMsg, chromeMsg, envMsgs, app.zon assets), derived values, the view_unbound lint opt-out, local mutation of owned arrays, or how to split a core into modules under src/ (relative imports, namespace imports, @native-sdk/core/text, @native-sdk/core/events).
---

# Author app cores in the TypeScript subset

An app core is the logic tier of a Native SDK app: `Model` (the app state), `Msg` (a discriminated union of everything that can happen), `update(model, msg)` (the one pure transition function), and the pure helpers they call. You write it as a TypeScript module rooted at `src/core.ts` - splitting into more modules under `src/` when it grows (see "Splitting a core into modules") - and the `@native-sdk/core` transpiler compiles the whole import graph to Zig at build time. No JS engine ships in the binary — the program either passes the subset checker and compiles to native, or you get a teaching error naming the rule, the fix, and the reason. The same file is executable TypeScript: it typechecks with stock tsc and runs unmodified under node, so you can poke behavior with plain node scripts before the native build.

A whole TS app is three files of truth and zero Zig: `src/core.ts` (this guide; plus any modules it imports under `src/`), `src/app.native` (the markup view over the core's emitted model), and `app.zon` (windows, identity, permissions). `native init` scaffolds exactly that; the build detects `src/core.ts` in the tree (never a flag or config — a tree with both `src/core.ts` and `src/main.zig` is a teaching error) and generates the wiring outside the app. The loop:

```sh
native dev --core   # the fastest loop: run the core under node's virtual host —
                    # dispatch Msgs as JSON lines ({"kind":"add"}, {"$bytes":"…"}
                    # for bytes payloads, {"advance":1000} to run virtual timers),
                    # watch the model + effect transcript. Logic only, no renderer.
native dev          # build and run the real app (markup hot reload)
native check        # subset-check core.ts + validate markup + app.zon
native build        # ReleaseFast binary; native test runs the app's tests
```

The complete reference app in this idiom is `examples/soundboard-ts` in the SDK repo: the soundboard music library as three files and zero Zig — const catalog tables, REAL audio through the `Cmd.audioPlay` stream, scrub-to-seek on a markup slider, a motion-gated `Sub.timer` playback clock, the full text-edit engine on a search field, controlled scroll, registered cover assets, the width-adaptive grid through the frame channel, clipboard, and context menus, with an end-to-end suite driving the shipping markup.

## The contract

```ts
export interface Model { /* readonly data fields only */ }

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number };
  // ...one arm per thing that can happen; at least two arms

export function initialModel(): Model { /* pure */ }

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    // one case per arm; the switch must be exhaustive (no default needed
    // once every arm is present — a missing arm is a build error)
  }
}
```

- `update` is pure and synchronous: next model out, plus optionally command data describing effects. When a dispatch needs an effect, declare the return type `Model | [Model, Cmd<Msg>]` and return `[nextModel, cmd]` — the runtime interprets the command after the model commits and dispatches any result back to you as a `Msg`. `initialModel` may return the same pair (`[Model, Cmd<Msg>]`) to run a boot effect once at install, and an app that needs recurring timers exports `subscriptions(model): Sub<Msg>`. See "Effects are Cmd data" below.
- Exported helper functions (`export function doneCount(model: Model): number`) compile to public Zig functions — and every exported helper taking exactly ONE Model parameter also becomes a Model declaration markup binds by the helper's own name (`{doneCount}`), so derived values need no model field. One emitted name per member: a helper that collides with a field (or another helper) is a taught NS1031.
- Update-only state (fields, helpers, or Msg kinds nothing in markup binds or dispatches — host-fired timer arms, persistence bookkeeping) is declared once: `export const viewUnbound = ["nextId", "tick"] as const;`. It emits as the `view_unbound` opt-out `native check`'s unbound-state lint reads; a name outside the model surface is a taught NS1032. Entries are the TypeScript names exactly as declared (`"nextId"`) and Msg kinds as their `kind` tags — the same names markup binds, because there are no other names.
- Names: your names are your names — fields, helpers, and locals emit into Zig with their TS spellings (`doneToday` stays `doneToday`), and markup binds them verbatim. String-literal unions emit as native enums.

## The arena mental model

Everything `update` builds lives in a per-dispatch bump arena that is freed wholesale after the returned model is committed, so spreads, `map`, and `filter` are cheap by construction. At commit, only nodes your update actually created are copied into the persistent model heap — everything you spread through unchanged is shared with the previous model for free.

That is why the immutable style is not a performance tax: `{ ...model, tasks: model.tasks.map(...) }` copies one small struct and one pointer array, never the world.

Both regions have FIXED, build-time capacities (1 MiB each by default): the frame arena bounds one dispatch's transients, the model heap bounds the committed model per space. They are comptime knobs of the emitted core — `--frame-cap <bytes>` / `--heap-cap <bytes>` on the transpiler CLI (`frameCap`/`heapCap` in the API) — and v1 never grows them at runtime, so binaries stay allocation-free and replay stays trivially deterministic. Overflowing one is a loud runtime panic naming the knob to raise, never silent corruption.

## What the subset means

The subset is TypeScript minus the ecosystem minus the purity violations — never minus basic syntax. Concretely: every basic statement, operator, and declaration form of the language compiles (every loop shape including `do...while`, labels with labeled `break`/`continue`, `switch` with `default`, the full assignment-operator family, `**` and the shifts, const record destructuring, namespace imports over your own modules). What does not compile falls into exactly two families, each with a named teaching rule: the ECOSYSTEM the binary cannot carry (npm packages, Node/DOM APIs, regex/JSON/Promise/generator machinery, `eval` — no JS engine ships), and the constructs that would break a core's guarantees (purity and determinism, fixed shapes, one text representation, functions as declarations not values, static types with no runtime tags). Classes and exceptions are NOT in either family: data classes and `throw`/`try`/`catch`/`finally` compile (see below) — only their guarantee-breaking tails (inheritance, unsafe finally, untagged thrown values) teach. A construct that fails with a generic error instead of a teaching rule is a transpiler bug — the grammar matrix test (`grammar_matrix.test.ts`) pins every grammar production to its verdict so no silent gap can appear.

The banned families at a glance (each diagnostic names the fix and the reason at the site):

- **No JS engine ships**: `eval`, `new Function`, dynamic `import()`, `debugger` (NS1013); regexes (NS1040); BigInt/Symbol (NS1044); generators (NS1042); async/Promises (NS1002); npm imports (NS1035).
- **Purity and determinism**: mutation of SHARED data — parameters, model/msg trees, module tables, escaped locals (NS1001/NS1022/NS1051; your own function-local scratch arrays mutate freely, see "Local mutation" below), module-level `let` (NS1010), ambient time/randomness/IO (NS1005), effects outside the Cmd/Sub return paths (NS1017/NS1025).
- **Fixed shapes and layouts**: the class machinery beyond data classes — `extends`/`super`/`abstract` (NS1055), accessors/`#`-privates/class expressions/`this`-as-a-value (NS1056/NS1006), mutable statics (NS1010), generic classes (NS1053) — plus `delete`/getters/setters/computed keys (NS1012), `for`/`in` (NS1009), Map/Set (NS1011), runtime type/shape tests — `typeof`/`in`/`instanceof`/`Object.*` (NS1041). Data classes themselves compile — `static` methods, `static readonly` consts, and erased `private`/`protected` included (see "Data classes" below).
- **One text representation**: string indexing (NS1004), `+` concatenation and tagged templates (NS1018), `string` model fields (NS1024), the byte-text stays-out spellings — `charCodeAt`/`normalize`/`replace` and friends on bytes teach the byte-honest form (NS1060; the supported method surface is under "Text is bytes").
- **Functions are declarations — or const local helpers**: nested function declarations, non-const function values, `?.()` (NS1046), and const helpers that capture/escape/under-annotate (NS1054 — the legal shape is below under "Local function values"); fixed arity — no defaults, rest, `arguments`, call spreads (NS1019); generics live on module-level declarations and monomorphize per call site (NS1050/NS1053).
- **The mapping stays exact**: `var` hoisting (NS1049), loose `==` (NS1048), comma/void/assignment-as-value outside a for-header (NS1043), array/parameter destructuring (NS1045), `export default`/`export =`/`export * from` (NS1047 — export lists and named value re-exports compile), namespace-alias-as-value and SDK namespace imports (NS1039).

## What compiles (v1)

Model and message shapes:

- `interface` with `readonly` fields; nested interfaces; `T | null` for optional data.
- Model field types: `number`, `boolean`, string-literal unions (`"all" | "active" | "done"` → native enum), numeric-literal unions, `Uint8Array` (bytes), a nested interface, `readonly Interface[]` (arrays of object types), primitive arrays (`readonly number[]`, `readonly boolean[]`, arrays of literal-union tags), a tag-discriminated union (`{ kind: "list" } | { kind: "detail"; note: Note }` — arms may carry records, bytes, and primitive arrays), and `T | null` over any of these. Model unions compile to native tagged unions; switching arms in `update` retires the old arm's payload automatically at commit.
- `Msg`: a discriminated union on a `readonly kind` string tag, with primitive / bytes / interface payload fields. It must be a real union — give it at least two arms, or TypeScript collapses the alias to a plain object type and the transpiler rejects it.

Logic:

- `switch` on any union's `kind` tag — `msg.kind` (the Msg dispatch) and model-field unions (`switch (model.view.kind)`) alike — with member case labels, label stacking (`case "a": case "b": body`), `break`, and a trailing `default` covering the unnamed arms (without a `default` the switch must be exhaustive — NS1015; with every arm named the `default` is JS dead code and emits nothing) — and `switch` on a string-literal-union or numeric-literal-union *value* (`switch (model.filter)`) — an uncovered member skips the switch exactly like JS (a `default` anywhere but last is a taught stop in both forms) — and `switch` on a plain `number` or `string` value, lowered to an if/else chain with exact JS semantics: strict equality per case (NaN matches nothing, `-0` matches `0`, strings compare contents), cases tested in source order, `default` matching only after every case misses wherever it sits (an empty `default:` stacking onto the next body included); `if`/`else`; classic `for (let i = 0; ...)` including countdowns (`i--`, `i -= k`), multi-counter inits (`let lo = 0, hi = n`), and comma incrementors (`lo++, hi--` — the for-header is the one home for comma sequences); `do { ... } while (cond)` (the body runs before the first test; `continue` jumps to the test, exactly node); `for (const x of xs)` over arrays and `Uint8Array`, with `break`/`continue`, plus the indexed pair form `for (const [i, x] of xs.entries())` (exactly the `[index, element]` two-identifier binding — the index is the loop index, integer-classed; other tuple shapes stay taught); `while`; labeled statements on loops and blocks with labeled `break`/`continue` (`outer: for (...) { ... continue outer; }` — a labeled `continue` in a classic for still runs the incrementor, like JS); `let` locals with reassignment (and `let x: number;` declared-then-assigned); ternaries; `&&`/`||`/`!`; the empty statement `;`.
- `const { total, done: doneCount } = stats;` — record-field destructuring into const locals (a compile-time alias per field, renames included). Array patterns, parameter patterns, defaults, rest, and nesting are taught (NS1045 — positions can be silently absent in JS; fields cannot).
- `import * as util from "./util.ts"` — a namespace import over your own modules is pure dot-syntax: `util.helper(x)`, `util.CONST`, and `util.Cfg` in type positions all resolve to the target module's flat emitted names. The alias is not a value (storing or passing `util` itself is taught), and the intrinsic `@native-sdk/core` module is always imported by name (NS1039 — the purity rules recognize `Cmd`/`Sub`/`asciiBytes` by their imported names).
- Object spread `{ ...model, field: v }`, array spreads in any shape — append `[...xs, x]`, prepend `[x, ...xs]`, multi-spread `[...a, x, ...b]` (each compiles to one exact-size copy) — `.length`, indexing `xs[i]`.
- Array methods, lowered to inlined loops and exact-size arena copies: `.map` / `.filter` / `.find` / `.findIndex` / `.some` / `.every` / `.reduce` / `.toSorted` / `.slice` / `.concat` / `.indexOf` / `.includes`. `.map` is type-changing — `tasks.map((t) => t.id)` produces a number array, `t => t.title` a bytes array, and a callback that can return `null` produces an optional-element array. Callbacks on map/filter/find/findIndex/some/every may take the `(element, index)` pair — the index is the loop index, integer-classed (`.reduce` stays `(acc, x)`: its index parameter is not in v1, and no callback takes the third JS parameter, the array itself — reference the array by name). Array-method calls may sit directly in `if`/`else if` and ternary conditions (`if (xs.some((x) => x > 3))`) — the scan lowers to a loop just before the branch; a `while` condition cannot (it re-evaluates per iteration — hoist into the loop body or restructure). Callbacks are arrows (expression or block body), inline `function` expressions, or a BARE REFERENCE to a module-level function or const helper (`xs.map(encodeTurn)`, `xs.toSorted(byAscending)` — the referenced body inlines exactly like the arrow spelled at the site); in a block body every code path must end in an explicit `return` (falling off the end would be JS `undefined`, which has no mapping — a taught stop). JS semantics hold exactly: `.slice` resolves negative and out-of-range indices the JS way, `.indexOf` never matches `NaN` while `.includes` does, `.some`/`.every` keep their vacuous defaults on empty arrays, and `.reduce` needs its initial value (the no-initial form throws on an empty array in JS, so it is a taught NS1007 — pass the starting accumulator). `.indexOf`/`.includes` work on scalar elements (numbers, tags, booleans); on record arrays JS compares references, which has no native mapping — match a field with `.find`/`.findIndex` instead.
- **Local mutation — your own scratch is yours; shared data is immutable.** An array your function CREATES — an array literal (`const stack: number[] = []`, `const st = [1, 2, 3]`) or a fresh copy (`.slice()` / `.map()` / `.filter()` / `.concat()` / `.toSorted()`) — is locally owned, and the full mutating method set works on it with exact JS semantics: `push(...items)`, `pop()`, `shift()`, `unshift(...items)`, `splice(start, deleteCount?, ...items)` (negative/overshooting indices clamp the JS way; the value is the removed array, also yours), `reverse()`, `fill(v, start?, end?)`, in-place `sort(cmp)`, and indexed writes `xs[i] = v`. A parser stack, a work queue, a copy-then-sort — all legal, deterministic, and byte-identical to node. Ownership ends at the first ESCAPE: once the array is returned from a callback, stored into a record/array/model, aliased by a second binding (`const b = a`), or passed where the callee could keep or mutate it, mutating it afterwards is a taught NS1051 — finish mutating first, then let it escape (an early-exit `return` is fine: execution ends there, so mutations on the other path stay legal). Two loosenings keep real code flowing. BORROWING: passing an owned array into a `readonly T[]` parameter is NOT an escape when the callee only READS it (element/property access, iteration, spreads, further borrowing passes — no return of it, no store, no onward pass into a mutable position; recursion over borrowed slices included), so measure-mutate-measure loops work (`total(out); out.push(x); total(out)`). REASSIGNED-OWNING: a `let` binding whose EVERY assignment installs a fresh owning construction (a literal or a copy — `w = xs.filter(...)`, `acc = []`) stays owned through the reassignments; ONE mixed assignment (an alias, a parameter, a helper result) and the binding never owns (NS1001 names it). Never owned: parameters, model/msg data, module `const` tables, aliases, mixed reassigned bindings, and arrays produced by helper calls (copy with `.slice()` to own one). After the value escapes it is an ordinary immutable value; the commit walkers and sharing discipline are unaffected because ownership ended before the escape.
- Local-mutation shape notes: `push`/`unshift` return the new length in JS, which has no mapping — mutate as a statement and read `.length` after; `sort`/`reverse`/`fill` return the same array — mutate as a statement, then use the array by name (`return copy.sort(cmp)` is a taught stop; the canonical form is `const copy = xs.slice(); copy.sort(cmp); return copy;`); `pop()`/`shift()` return `T | undefined` — the same one-empty the `.find` miss produces, so test `=== undefined` or fold with `??` (`stack.pop() ?? fallback`); spread arguments (`out.push(...xs)`) stay taught — one element per iteration; `xs[xs.length] = v` on an owned array IS a push (the one growth shape — compound forms like `xs[xs.length] += v` read the missing slot first and stay taught), and other out-of-bounds writes are JS sparse arrays with no mapping (they trap on the native bounds check in safe builds — keep writes inside `0..length-1`); changing the LENGTH of the array a `for...of` (or one of its own callbacks) is iterating is a taught stop (JS walks the live array; fixed-length writes during iteration are fine and identical to node); `copyWithin` stays out of v1 (splice/fill cover it).
- `.toSorted(cmp)` sorts a copy in one expression; `.sort(cmp)` sorts in place on an array you own (on shared data it keeps the NS1022 teaching, which names the copy idiom). Both comparators follow the same rules: return a sign — `(a, b) => a - b` for ascending numbers, or explicit -1/0/1 branches; a boolean comparator is wrong in JS itself (false claims equality) and is rejected by the types plus a taught NS1023. The comparator-less arity sorts by string ToString order in JS (`[10, 9]` stays `[10, 9]`), which has no float-text mapping — pass a comparator. Both sorts are stable exactly like JS: comparator 0 (or NaN) keeps the original order of the pair. One honesty note: a comparator that is inconsistent over the actual data (e.g. `a - b` when elements can be `NaN`) is implementation-defined in JS itself, so node and native may then disagree — keep comparators consistent.
- A `.find` miss is the tier's one empty value: JS spells it `undefined`, so test the result with `=== undefined` (never `=== null` — the checker teaches the difference) or fold it away with `??`: `tasks.find((t) => t.id === id) ?? fallback`.
- Optional chaining `?.` on property chains (`model.sel?.at ?? 0`), element hops (`m?.xs[0] ?? 0`, `xs?.[i] ?? d`), and method hops on supported receivers (`xs?.slice(0, 2)`, `xs?.includes(3) ?? false` — every mapped array/bytes method): each hop null-propagates exactly like JS, and the chain value is optional — end it in `??` or compare it against a real value. A `?.` chain compared against `null`/`undefined` is a taught error (NS1021), and `g?.()` on a function value stays taught.
- Null-guard narrowing through `&&`/`||` chains, exactly the way TS narrows: `if (x !== null && x.items.length > 0)`, the flipped order (`null !== x`), the `||` dual (`x === null || x.items.length === 0`, including as an early-exit guard — the code after the exit stays narrowed), ternary conditions (`x !== null && x.at > 0 ? x.at : -1`), and `while (cur !== null && cur.n > 0)` loops (re-tested per iteration; assigning the guarded local drops the narrowing for what follows, like TS). Relational comparisons on guarded optionals (`cls !== null && cls < lim`) work too.
- Nullish `??`, comparisons (including `===` on `string`-typed values — content equality, same as node; `==`/`!=` are taught NS1048 — coercion), `+ - * / % **` on numbers, unary `+`/`-`, and the bitwise family `& | ^ ~ << >> >>>` — all with JS number semantics (`/` is float division, `%` truncates, `**` is float pow with the exact JS corners — `1 ** NaN` is NaN, `(-1) ** Infinity` is NaN, right-associative `2 ** 3 ** 2` is 512; bitwise and shifts are ToInt32 with the shift count masked & 31, `>>>` yielding the unsigned 32-bit value; unary `+` is the identity on numbers). `**` and `/` results are float-classed; bitwise/shift operands are integer-required positions (a float operand is a taught NS1016).
- Every compound assignment as a statement: `+= -= *= /= %= **= &= |= ^= <<= >>= >>>=`, each exactly `x = x op v`, plus the guarded forms `&&=`/`||=` (boolean targets; the right side evaluates only when assigned, like JS) and `??=` (optional targets; assigns only when null). A number `++`/`--`/assignment may sit in a VALUE position when the split statement is provably order-exact — the variable's only mention in the statement, in a position JS cannot skip (`arr[i++]`, `const n = ++count`, `const z = (y = 5)`; postfix yields the pre-step value, everything else the post-step value, exactly JS); every other value-position form is taught (NS1043 — ternary branches, short-circuit right operands, loop conditions, or a second mention of the variable).
- The Math batch, every corner pinned to node: `Math.min` / `Math.max` (any arity — `Math.min()` is Infinity, `Math.max()` is -Infinity, NaN propagates, -0 orders below +0), `Math.round` (half toward +Infinity), `Math.floor` / `Math.ceil` / `Math.trunc` (NaN/Infinity propagate; the -0 results keep their sign, so `Math.ceil(-0.5)` is -0), `Math.abs` (clears the zero sign), `Math.sign` (NaN stays NaN, a zero keeps its sign), `Math.sqrt` (negative input is NaN, `sqrt(-0)` is -0). `Number.isInteger` / `Number.isFinite` / `Number.isNaN` classify like node, and the `NaN` / `Infinity` globals are ordinary number values. Math calls over compile-time constants fold to their exact JS value — `const HALF = Math.floor(5 / 2)` is the integer 2, `5 % 0` is NaN, `-5 % 5` is -0. A bare `-0` literal (and constant arithmetic folding to -0, like `0 * -1`) is a float value — only f64 carries the signed zero — so it cannot flow into an index or another integer-required slot. The integer rule: floor/ceil/trunc/abs/sign of an integer-classed value stays integer-classed, but of a float value stays float (floor of NaN is NaN), so `bytes[Math.floor(x / 2)]` over a float `x` is still a taught NS1016 — keep index flows integer end to end.
- Template literals with integer holes (`` `${n} of ${total}` ``) feeding `asciiBytes` (below). Float-valued holes are not in v1 (JS float-to-string fidelity is a runtime v2 surface).
- Module-level `const` numbers and strings fold to comptime constants, and const tables emit as rodata (no arena, shared for free at commit): arrays of numbers / booleans / strings / literal-union members (`const WEEKDAYS = [3, 5, 2]`, `const ORDER: readonly Filter[] = ["done", "all"]`), records annotated with an interface (`const LIMITS: Limits = { lo: 1, hi: 9 }`), and arrays of records (`const SEEDS: readonly Task[] = [...]`, names as `asciiBytes` literals). Element access, `.length`, `for...of`, and the array methods all work over tables. Everything inside must fold at compile time — no spreads, no calls except `asciiBytes` on a literal — and a record table needs its interface annotation (an unannotated `{ ... }` is a taught stop naming the fix). Helper functions; recursion.
- **Generics — module-level, monomorphized per call site.** A generic `function`, `interface`, or `type` declares type parameters and instantiates from tsc's RESOLVED type arguments (explicit or inferred): `export function pick<T>(xs: readonly T[], i: number): T { return xs[i]; }` called with tasks emits `pick__Task`, with numbers `pick__f64` (a bare `number` type argument is always f64 — the JS-exact class), one readable Zig fn per distinct instantiation, deduped. Generics over records, unions, arrays, optionals, and bytes all work; generic interfaces/aliases instantiate structurally (`Box<Task>` emits `Box__Task`; `type Opt<T> = T | null` resolves straight through); generics may recurse and call other generics (the inner call resolves at the outer's instantiation). `typeof CONST` type-query aliases resolve through tsc too (`const LIMIT = 9; type Limit = typeof LIMIT`). The boundaries teach: a call site whose type argument stays abstract (`pick([])` infers `never`; `any`/`unknown`, unnamed literal unions) is NS1053 — annotate the call or name the alias; generic function VALUES and generic entry points are NS1050.
- **Data classes — fields, one constructor, plain methods, statics; no inheritance.** `class Task { title: Uint8Array; done: boolean = false; constructor(title: Uint8Array) { this.title = title; } toggle(): void { this.done = !this.done; } isDone(): boolean { return this.done; } }` emits as a plain struct plus module-level functions; `new Task(...)` constructs a record-shaped value (field initializers run in declaration order, then the constructor body). `static` members are per-class module declarations: a `static` method lowers to a receiver-less module fn under the class's mangled name (`Task.fromRow(...)` resolves to `Task__fromRow`), and a `static readonly` field with an initializer is a module const (`Task.LIMIT` — the module-const value rules apply: numbers/strings fold, tables need their annotation); a MUTABLE static is module state and teaches NS1010, and inside a static member reach other statics by the class name, never `this` (NS1056). `private`/`protected` keywords are accepted and ERASED — tsc enforces them at the type level, which is their whole meaning (`#`-fields stay taught: runtime privacy brands). `this` reaches instance fields and methods (`this.count`, `this.step()`) — anything that lets `this` escape as a value (returning it, storing it, passing it) is taught (NS1056), so fluent chaining is out. Mutation follows exactly the array ownership rule: an instance your function creates with `new` mutates freely — direct field writes (`t.count = 1`, `t.count += 2`) and methods that write `this` — until it ESCAPES (returned, passed, stored, aliased — then NS1051), and parameters/model data never mutate (NS1001); methods that only read are callable on anything. Fields require type annotations; instances flow between functions, sit in arrays, and compare/narrow like records. The class TAIL teaches by name: `extends`/`super`/`abstract` (NS1055 — compose, or model variants as a `kind`-union), getters/setters/`#`-privates/`accessor`/class expressions (NS1056), mutable statics (NS1010), generic classes (NS1053), parameter properties (NS1008), `instanceof` (NS1041 — a `kind` field is the tag that exists). Class instances stay LOCAL values in v1: storing one in the Model tree is taught (NS1056) — keep records (interfaces) in the Model and construct the class where behavior is needed.
- **Exceptions — `throw`/`try`/`catch`/`finally` as pure control flow.** Inside a core, exceptions are deterministic: `throw` carries a subset VALUE and unwinds to the nearest enclosing `catch` — across helper calls, out of array-method callbacks (a `throw` inside `.map`'s callback exits the whole loop, like JS), through nested `try`s, with `finally` running on every path (fall-through, `return`, `break`/`continue`, and throw alike). The discipline is two rules. First (NS1057): thrown values are kind-tagged subset shapes — throw kind-discriminated records (`throw { kind: "bad_digit", at: i } as ParseError`, where `ParseError` is an interface with a string-literal `kind` field or a `kind`-discriminated union; a single-shape core may also throw a number), and SEVERAL distinct shapes may throw: the checker collects every shape the core throws into its implicit thrown union. The catch binding IS that union — narrow it in place with kind tests, no `as` ceremony: `catch (e) { if (e.kind === "bad_digit") return -e.at; if (e.kind === "io") return e.code; return -1; }` (or `switch (e.kind)` — tsc cannot prove exhaustiveness over the implicit union, so give the switch a `default` or a trailing return). Bare rethrow (`throw e;`) re-raises the bound value — a narrowed arm included — and `catch { ... }` needs no binding; the single-`as` form (`const err = e as ParseError;`) stays legal in single-shape cores (and for a DECLARED union whose arms equal the thrown set — declare `type AppError = ... | ...` and `as AppError` works). What teaches: untagged values in a heterogeneous set, two shapes sharing one `kind` with different payloads, asserting one member shape of a multi-shape core, the binding escaping untyped into a call/store/return, and `throw new Error(...)` (engine error objects carry stack traces with no native layout). Second (NS1058): `finally` never redirects control flow — no `return`/`throw`/`break`-out inside it (JS's own no-unsafe-finally rule; loops fully inside the finally may break within themselves). An UNCAUGHT throw that reaches an exported function's boundary is a defined deterministic panic — exactly where node's process would crash. A throw mid-mutation of an owned array keeps the mutations applied so far, exactly like JS — the catch sees the array as node would.
- **Local function values — const helpers hoist.** `const scale = (x: number): number => x * 3;` (arrow or `function` expression) hoists to an ordinary module-level fn when it is capture-free (module constants and other const helpers are fine to reference; enclosing locals/params are not — pass them as parameters), fully annotated (every parameter and the return type), and used only by direct calls (`scale(v)`, recursion included) or as an array-method callback (`xs.map(scale)`, comparators included). Everything else teaches NS1054: captures, missing annotations, `let` bindings, returning/storing the value, passing it to your own functions, calling through a record field. Capturing a locally-owned array also ENDS its ownership at the capture (a later mutation is the NS1051 teach) — the stored closure would retain the reference.

Not yet in v1 — genuine roadmap deferrals, each stopping with a loud, tailored NS9001 naming the rewrite (never missing basic syntax; the banned-with-a-rule families live in "What the subset means" above): `.toSorted()`/`.sort()` without a comparator (JS ToString ordering; pass `(a, b) => a - b`), `.reduce` without an initial value (a taught NS1007 — JS throws on an empty array) or with an index parameter (use a classic loop), `.indexOf`/`.includes` on record arrays (match a field with `.find`/`.findIndex`), `.join` on number arrays (elements are float-valued; join byte values instead), float values (`/`, `**`, `Math.round`, `Math.sqrt`, float `Math.floor`-family results) where an integer is required such as an index (a taught NS1016 — those values can be fractional or NaN), Math methods beyond the batch above, `Number` methods beyond the three classifiers, float-valued template holes (JS float-to-string fidelity is a runtime v2 surface), arrays of unions (`readonly View[]`) or arrays of byte-strings (`readonly Uint8Array[]`) as model fields (wrap the element in a single-field interface), record payloads on `Cmd.request` results (results and errors arrive as one bytes payload; the record-shaped results are `Cmd.fetch`'s `{ status, body }` arm, `Cmd.spawn`'s collect `{ code, output }` arm, and the fixed audio event arm), streaming fetch responses (`Cmd.fetch` is buffered only; spawn line streams are the streaming surface), a collect spawn's stderr tail (v1 delivers the exit code and stdout; stderr is not surfaced — put diagnostics on stdout or check the code), per-line truncation flags (a stdout line over the engine's 4 KiB line bound arrives cut, without a flag), and non-timer subscriptions (`Sub.timer` is the one subscription; one-shot needs are `Cmd.delay`, and process/audio streams are Cmd-initiated, not subscribed).

## Effects are Cmd data

`update` never performs an effect — it can return one, as inert data, alongside the next model. Import the factories from the SDK and declare the pair-return type:

```ts
import { Cmd } from "@native-sdk/core";

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add":
      return [{ ...model, count: model.count + 1 }, Cmd.persist()];
    case "request_time":
      return [model, Cmd.now("tick")]; // dispatches { kind: "tick", at: <ms> }
    case "tick":
      return { ...model, lastTick: msg.at }; // bare model = [model, Cmd.none]
    case "ship":
      return [model, Cmd.batch([Cmd.persist(), Cmd.host("beep", model.count)])];
  }
}
```

The command set (Cmd wire format v2):

- `Cmd.none` — no effects; returning a bare `Model` is sugar for `[model, Cmd.none]`.
- `Cmd.persist()` — ask the host to persist the committed model.
- `Cmd.now("tick")` — request a timestamp; the runtime dispatches the named Msg arm with the time (ms) as its payload. The target arm must carry exactly one number field (`{ kind: "tick", at: number }`), and tsc checks that for you.
- `Cmd.host(name, ...args)` — a fire-and-forget host command by literal name; the host decides what the name means. Args are numbers, OR exactly one bytes payload: a `Uint8Array` (`Cmd.host("clipboard.write", model.draft)`) or a flat inline record of number/boolean/`Uint8Array` fields (`Cmd.host("cfg.save", { gain: model.gain, on: model.muted, label: asciiBytes("main") })`) — the record lowers to one bytes payload from your types at build time, byte-identical under node and native. Anything else (a smuggled string, a nested record, a payload plus extra args) is a taught error (NS1020/NS1026).
- `Cmd.request(name, payload, { key?, ok, err })` — a routed host command: the host performs `name` with the payload (same bytes/record rules) and dispatches exactly one result back to you as an ordinary Msg — the `ok` arm with the result bytes on success, or the `err` arm with the error bytes on failure. Both arms must carry exactly one `Uint8Array` field (`{ kind: "loaded", body: Uint8Array }`), checked by tsc and taught by NS1027. The routing is data — string-literal arm names, never callbacks — so the result decoder derives from your Msg types at build time. The optional `key` (a string literal) names the in-flight effect: issuing a request whose key is already in flight replaces it (the old result is dropped), which is the debounce/exactly-one-in-flight discipline.
- `Cmd.cancel(key)` — drop the in-flight keyed effect with that key, silently: a cancelled request, named engine op (`readFile`/`writeFile`/`fetch`/`clipboardRead`), or armed delay dispatches NEITHER arm — its result is simply dropped. The one exception is a live spawn stream (below): cancel ends the child and the stream's `err` arm dispatches with `cancelled` — killing a process is an observable event, kept loud on purpose.
- `Cmd.batch([a, b])` — several commands from one dispatch, performed in order.

### The named engine ops

These map directly onto the host's effect engine — files, HTTP, the clipboard, one-shot timers. Routing follows the `Cmd.request` rules (inline `{ key?, ok, err }`, string-literal arm names, arm shapes checked by tsc and taught by NS1027), with one difference from `request`: each op's `ok` arm has the op's OWN result shape. Keys follow the one keyed-effect rule everywhere: issuing an op whose key is already in flight REPLACES the old one (the superseded op's result is dropped — no message), and `Cmd.cancel(key)` drops it silently. Every `err` arm carries exactly one `Uint8Array` field and receives a machine-readable reason. Paths, URLs, and bodies are bytes (`asciiBytes` for literals); dynamic values the engine refuses at runtime surface through the `err` arm, while compile-time-knowable bound violations stop the build (NS1030).

- `Cmd.readFile(path, { key?, ok, err })` — read a whole file. `ok` arm: one `Uint8Array` field with the content. `err` reasons: `not_found`, `io_failed`, `truncated` (the file exceeds the engine's 1 MiB read bound — a cut file never passes as whole), `rejected`. Paths are at most 1024 bytes.
- `Cmd.writeFile(path, bytes, { key?, ok, err })` — write a whole file (parent directories created, an existing file replaced whole; at most 1 MiB). `ok` arm: NO payload fields (`{ kind: "wrote" }`) — a successful write has nothing to report. `err` reasons: `io_failed`, `rejected`.
- `Cmd.fetch({ url, method?, headers?, body?, timeoutMs? }, { key?, ok, err })` — a buffered HTTP(S) exchange. `ok` arm: exactly two fields, one `number` and one `Uint8Array` (`{ kind: "fetched", status: number, body: Uint8Array }`) — matched by type, so the names are yours. The status is the real HTTP status: a 404 is still `ok` (an HTTP-level error is a delivered response). `err` reasons: `connect_failed`, `tls_failed`, `protocol_failed`, `timed_out`, `rejected`, and `truncated` (the body exceeded the engine's 256 KiB buffered bound — never delivered silently cut). The spec is an inline object: `url` bytes (≤ 2 KiB), `method` one of `"GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD"` (default GET), `headers` an inline flat record — names are compile-time ASCII, values are string literals OR runtime bytes (`{ authorization: bearerToken(model.apiKey), "content-type": "application/json" }` — how a launch-supplied key rides an `Authorization` header; ≤ 8 headers, ≤ 1 KiB total, NS1029/NS1030), `body` bytes (≤ 64 KiB), `timeoutMs` a positive integer literal (engine default when omitted). Buffered only — no streaming responses in v1.
- `Cmd.clipboardWrite(bytes)` — put bytes on the system clipboard, fire-and-forget: there is no routing, and a refused or over-bound write is dropped by design.
- `Cmd.clipboardRead({ key?, ok, err })` — read the clipboard. `ok` arm: one `Uint8Array` field with the text. `err` reasons: `failed` (no clipboard service, over-bound content, pasteboard error), `rejected`.
- `Cmd.delay(key, ms, "fired")` — a keyed ONE-SHOT timer: dispatches the named arm once, `ms` from now, with the fire time (ms) as its single number payload (the same arm shape `Cmd.now` and `Sub.timer` target). Re-issuing a live delay key re-arms it from now — that is the debounce discipline (`Cmd.delay("autosave", 800, "save_now")` on every keystroke, one fire after the pause). `Cmd.cancel(key)` drops it silently. The interval is 1ms to one year; a literal outside that stops the build (NS1030).

One honesty note on `Cmd.persist()`: it compiles and encodes, but no shipping host implements the persist verb yet, so the checker teaches NS1028 as a WARNING (never failing the build). Persist real state with `Cmd.writeFile` and load it back with `Cmd.readFile` from `initialModel`'s boot command — the pattern every real app uses.

### The streaming ops: spawn and audio

Two effect families deliver MANY results from one command — a keyed stream the app opens imperatively and drives (this is the opposite of `Sub`: a Sub is declared from the model and the host reconciles it; a stream is a `Cmd` with a lifecycle you cancel or stop). Routing still follows the `Cmd.request` rules: string-literal arm names, shapes checked by tsc and taught by NS1027.

- `Cmd.spawn(argv, { key?, stdin?, line?, exit, err })` — run a subprocess, streaming stdout line by line. `argv` is an inline array literal of bytes elements (`[asciiBytes("/bin/ps"), asciiBytes("-axo")]`, at most 16 elements, 2 KiB total; the array shape is NS1029, the bounds NS1030), and `stdin` (optional bytes, ≤ 4 KiB) is written to the child once. Each stdout line dispatches the `line` arm (one `Uint8Array` field) as it arrives, across dispatches; omit `line` to drop lines (an exit-only spawn, e.g. piping stdin to `pbcopy`). Exactly ONE terminal ends the stream: a clean exit dispatches the `exit` arm — one number field carrying the exit code (a non-zero code is still `exit`: the process ran; its failure code is yours to read) — and every other end dispatches `err` with the reason bytes: `signaled`, `cancelled`, `rejected` (a duplicate live key, or dynamic argv/stdin the engine refused), `spawn_failed` (the binary could not start). Lines over the engine's 4 KiB line bound arrive cut.
- `Cmd.spawn(argv, { key?, stdin?, collect: true, exit, err })` — the same child, whole stdout buffered instead of streamed (the system-monitor shape: run `ps`, parse the block). No `line` arm (NS1027 teaches the conflict). The `exit` arm is a two-field record — one number field (the exit code) and one `Uint8Array` field (the collected stdout, up to 512 KiB), matched by type like `Cmd.fetch`'s arm. Collected stdout over the bound routes `err` with `truncated` — a cut block never parses as whole.
- `Cmd.cancel(key)` aimed at a live spawn ends the child mid-stream; the stream's `err` arm dispatches with `cancelled` — loud on purpose, because killing a process is an observable event (the contrast with the named ops, whose cancel is silent). Spawn keys are the ONE exception to the replace rule: a spawn whose key is already streaming is rejected (`err` gets `rejected`), never replaced — a running subprocess is never killed implicitly; cancel it first.
- `Cmd.audioPlay(key, { path?, url?, cachePath?, expectedBytes? }, { event })` — open the audio event stream. One player is the whole surface, so a new `audioPlay` always REPLACES the current playback (the one key-reuse exception besides `Cmd.request`). The source cascade is the engine's: the local `path` is tried first, a missing file falls through to `url` (streamed progressively, cached at `cachePath` when given, integrity-gated by `expectedBytes` — omitted/0 means unknown size). At least one of `path`/`url` is required (NS1029); each is bytes, at most 1 KiB (NS1030). Prefer OMITTING `cachePath` for URL sources: when the app wiring configures a caches directory (`TsUiApp`'s `audio_cache_dir`), the host derives the conventional content-addressed cache path from the URL itself — your update never builds filesystem paths, and replay re-derives the same path by construction. Pass `cachePath` only to override that convention.
- The `event` arm is the one SDK-fixed record shape, six fields matched by NAME: `state` (the `AudioState` string-literal union — import it from `@native-sdk/core/events`, or declare an alias with exactly the members `"loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum"` in any order; the runtime matches members by name), `positionMs: number`, `durationMs: number` (milliseconds; the duration is the player's estimate), `playing: boolean`, `buffering: boolean` (true while a streamed url is stalled waiting for bytes), and `bands: Uint8Array` (the 32 spectrum band magnitudes, 0–255 each, all zeros outside `"spectrum"` events). Every playback event dispatches this arm — `"failed"` (unplayable source, decode/device failure) and `"rejected"` (an empty or over-long source) included, so failure is never silence — until `Cmd.audioStop` closes the stream. `"completed"` fires once at the natural end and does NOT close the stream: starting the next track from it is the idiom.
- `Cmd.audioPause(key)` / `Cmd.audioResume(key)` / `Cmd.audioStop(key)` / `Cmd.audioSeek(key, ms)` / `Cmd.audioSetVolume(key, volume)` — fire-and-forget control verbs: no result of their own; their consequences arrive on the event stream (`audioResume` on a dead player reports one `"failed"` event, never silence). A verb whose key names no open stream is a no-op. `audioStop` is the audio stream's close — no events for the key after it (`Cmd.cancel` does not apply to audio). Volume is clamped 0..1 and remembered across tracks; a literal outside 0..1 (or a negative seek literal) stops the build (NS1030).

Commands are constructed inline in the return path and nowhere else (NS1017): never in the Model or a Msg, never in a local, never in a helper. This is what keeps effects inside the dispatch cycle and replay honest.

### The init command

`initialModel` may return the same pair to run a boot effect once at install, before the first view build — loading a store is the canonical use:

```ts
export function initialModel(): [Model, Cmd<Msg>] {
  return [
    { notes: [], loading: true },
    Cmd.request("store.read", asciiBytes("notes.bin"), { key: "boot", ok: "loaded", err: "load_failed" }),
  ];
}
```

A plain `initialModel(): Model` stays exactly as before; the pair is opt-in.

### Subscriptions are Sub data

Recurring effects are declared, not issued: export `subscriptions(model): Sub<Msg>` and return descriptors derived from the current model. After every commit the host reconciles the returned set against its active timers by key — a new key (or a changed interval) arms a timer, a missing key cancels it — so starting, stopping, and re-tuning timers is just returning different data:

```ts
import { Sub } from "@native-sdk/core";

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.running) return Sub.none;
  return Sub.batch([
    Sub.timer("tick", model.fast ? 250 : 1000, "tick"), // dispatches { kind: "tick", at: <ms> } every interval
    Sub.timer("autosave", 30000, "save_now"),
  ]);
}
```

- `Sub.none` — no subscriptions (everything paused).
- `Sub.timer(key, everyMs, "tick")` — a repeating timer named by its string-literal key; each fire dispatches the named arm with the current time (ms) as its single number payload (the same arm shape `Cmd.now` targets). The interval may derive from the model.
- `Sub.batch([...])` — several at once.

Sub values follow the Cmd purity rule with their own home (NS1025): built inline in `subscriptions`' return path, never stored, never returned from anywhere else. Debounced re-arm falls out of reconciliation — change the key or interval and the timer re-arms; drop it from the set and it stops.

Keep the Sub-vs-stream line straight: a Sub is DECLARATIVE — derived from the model, started and stopped by reconciliation, and the app never opens or closes one. The multi-result streams (`Cmd.spawn`'s lines, `Cmd.audioPlay`'s events) are Cmd-INITIATED — imperative opens with a keyed lifecycle the app drives (`Cmd.cancel` for spawn, `Cmd.audioStop` for audio). If the effect should exist exactly while some model state holds, it wants a Sub shape; if the app decides when it starts and ends, it is a stream.

One caveat for node-side pokes: the transpiler resolves the `@native-sdk/core*` specifiers for you, but plain `node` does not know them, so quick behavioral checks under node work directly on cores with no SDK import, and on cores importing `Cmd`, `Sub`, `asciiBytes`, or the text engine only with a module mapping (or by copying the SDK module files next to the core and rewriting the specifiers). `native dev --core` already maps them.

## Splitting a core into modules

`src/core.ts` is the ENTRY module; a core that outgrows it splits into more `.ts` files under `src/` (subdirectories included). The whole import graph still emits as ONE native module - one rt kernel, one flat namespace, a section per source file - and runs unchanged under node.

- **Spell relative imports with the real filename**: `import { parsePs } from "./parsers.ts"` (node's loader resolves real files, not bare stems - a missing extension or a missing file is a taught NS1037).
- **`src/` is the boundary**: `../` escapes and absolute paths are taught (NS1034); bare npm specifiers are taught (NS1035 - vendor the code under `src/` or make the import `import type`). Only `@native-sdk/core` (the intrinsic Cmd/Sub/asciiBytes surface) and the SDK library modules below carry runtime meaning from outside.
- **Everything module-level is importable**: interfaces, literal-union aliases, discriminated unions, module `const` numbers and tables, and helper functions all cross files (renamed imports and `import * as ns` namespace aliases both work — the alias is dot-syntax over the same flat namespace, never a value of its own). Export lists and value re-exports work too: `export { helper, doneCount as remaining }` binds names over existing declarations, and `export { parsePs } from "./parsers.ts"` forwards another module's export by name (a renamed binding emits as a flat-namespace alias). Type names and EXPORTED value names must be unique across the core's files (NS1038 - declare once, import where used; renamed exports claim their new names in the same namespace); colliding PRIVATE helpers are fine (the emitter uniques them with a per-module prefix).
- **No runtime import cycles** (NS1036). `import type` back-edges are legal and idiomatic: a helper module type-imports `Model` from `./core.ts` while `core.ts` runtime-imports the helpers - that is the expected shape, not a smell.
- **The entry contract (NS1014)**: `update`, `initialModel`, `subscriptions`, the wiring channels (`commandMsg`/`keyMsg`/`frameMsg`/`appearanceMsg`/`chromeMsg`/`envMsgs`), and `viewUnbound` are DECLARED in `core.ts` and exported under their own names (`export` on the declaration or an un-renamed `export { update }` list entry — a rename or a re-export from an imported module cannot bind an entry point) - imports may FEED them, never replace them. The markup binding surface is also entry-only: an exported single-Model-parameter helper binds (`{doneCount}`) only when it is DECLARED in `core.ts` — export lists participate under their exported names (`export { taskTotal as taskCount }` binds `{taskCount}`), but a re-export of an imported helper does not bind (under node the app's module object is the entry's exports, so it would bind natively but not exist under node). Imported modules export cross-module API for update and the entry helpers to call.
- **SDK library modules**: `@native-sdk/core/text` ships the byte-splice text engine - `applyTextInputEvent(state, event, capacity)` / `clampedInsertEvent` over `TextEditState` (the full caret/word/selection/IME reducer for markup text controls), plus `containsIgnoreCase`, `orderIgnoreCase`, and `trimAsciiSpaces`. `@native-sdk/core/events` ships the canonical event record types (`TextInputEvent` re-exported, `ScrollState`, `FrameEvent`, `KeyEvent`, `ColorScheme`/`AppearanceEvent`, `ChromeInsets`/`ChromeButtons`/`ChromeEvent`, `AudioState`/`AudioEvent`) so no core re-types the vocabulary. Unlike `@native-sdk/core` (intrinsic, never emitted) these are ordinary subset TypeScript, transpiled INTO your core when imported and absent when not. Under node they resolve like the core module itself. One namespace rule to know (NS1038): module-scope names are unique across the whole import graph, so a core that imports an SDK event type deletes its own in-file mirror of that name.

The reference splits are `examples/soundboard-ts` (core.ts + library.ts + player.ts + the SDK text engine), `examples/system-monitor-ts` (core.ts + parsers.ts + table.ts + the SDK text engine), and `examples/ai-chat-ts` (core.ts + api.ts — the JSON-over-bytes wire-format reference: request encoding and a targeted parse walk that returns `null` on anything malformed) in the SDK repo.

## Text is bytes

`string` in a core is for literals, string-literal-union tags, and `===` comparisons — content equality, on tags and plain `string` values alike (`name === "app.add"` in a command mapper works and behaves identically under node and native). Dynamic, user-visible text lives in the Model as `Uint8Array` — indexing yields byte values, `.length` is byte length, `subarray` is a view and `slice` is a copy, and both resolve their bounds the JS way (negatives count from the end, out-of-range clamps, a crossed range is empty), identical under node and native. Observing a `string`'s code units (`.length`, `s[i]`, `.charCodeAt`) is banned (NS1004) because UTF-16 and UTF-8 would disagree, and `+` concatenation is banned (NS1018) because runtime string building needs a JS string heap the binary does not carry — build text with template literals into bytes instead.

Turn literals and templates into bytes with the `asciiBytes` intrinsic from the SDK. The transpiler recognizes the import by identity and folds every call at compile time — a literal argument becomes rodata, a template becomes per-dispatch arena bytes — and under node the same import runs as a plain function with the same result:

```ts
import { asciiBytes } from "@native-sdk/core";
export type Bytes = Uint8Array;

const label = asciiBytes(`${done} of ${total} done`); // arena bytes
const seed = asciiBytes("Stretch");                   // rodata, free to commit
```

Arguments must be string literals or templates (the fold happens at compile time); dynamic text is already bytes, so there is nothing to bridge. Hand-rolling the old bridge shape (`function asciiBytes(s: string): Bytes { ... }`) no longer gets special treatment — its body observes code units and teaches NS1004.

### The byte-text string methods

Bytes read like text: the everyday string methods work directly on `Uint8Array` values, with **byte-honest semantics** — every length, offset, and index is a BYTE length/offset (never a character count: `é` measures 2 and `padStart` pads by bytes), search is byte-wise, and case mapping is Unicode SIMPLE case mapping (code point → code point from the Unicode tables; locale-free, no special casing — `ß` stays `ß`, `σ` uppercases to `Σ`; bytes that are not well-formed UTF-8 pass through case mapping unchanged). Natively each call lowers onto an rt kernel helper; under node the devhost installs the same methods from the same generated tables, so both runtimes produce identical bytes by construction.

```ts
const query = model.query.trim().toLowerCase();          // JS whitespace set; simple case map
if (title.toLowerCase().includes(query)) { ... }         // byte substring search
const bar = asciiBytes("#").repeat(used).padEnd(w, asciiBytes("."));  // w is a BYTE width
const cells = row.split(asciiBytes(","));                // Uint8Array[] — the array is yours (push works)
const ext = name.lastIndexOf(asciiBytes("."));           // byte offset, -1 when absent
const last = line.at(-1) ?? 0;                           // byte value | undefined (the .find one-empty)
```

- `toUpperCase()` / `toLowerCase()` — fresh bytes, simple case mapping only (locale casing stays out; `toLocaleUpperCase` teaches NS1005).
- `repeat(n)` — `repeat(0)` is empty; the count is an integer position (a fractional flow is NS1016), and a NEGATIVE literal stops the build — JS throws RangeError there, so a dynamic negative count is the same crash on both runtimes (node throws, native panics): guard `n >= 0` first.
- `startsWith(b)` / `endsWith(b)` — bytes needles; the empty needle is true, exactly String's.
- `includes(x)` / `indexOf(x)` / `lastIndexOf(x)` — **dispatch by argument type**: a BYTES argument is substring search with String's shapes (`indexOf(empty)` is 0, `lastIndexOf(empty)` is the byte length, offsets are byte offsets), a NUMBER argument keeps the TypedArray element search node already ships (one byte value, SameValueZero — `includes(66.5)` is false, `-0` matches 0); no fromIndex/position arguments in v1.
- `padStart(n, fill?)` / `padEnd(n, fill?)` — `n` is the target BYTE length, default fill `" "`; the last fill repetition truncates BY BYTES (a multi-byte fill can cut mid-sequence — identically on both runtimes); at-or-under target returns the receiver unchanged.
- `trim()` / `trimStart()` / `trimEnd()` — strip the JS whitespace set (tab/LF/CR family, NBSP, the Unicode spaces, U+FEFF) decoded over UTF-8; views, no copy. Invalid UTF-8 is not whitespace — trimming stops there.
- `split(sep)` — bytes separator, `Uint8Array[]` out with String.split's shapes (leading/trailing/adjacent separators produce empty elements; no match is `[whole]`); elements are views, the ARRAY is locally owned (push/sort it before it escapes); an empty separator literal is a taught stop (per-code-point splitting would expose the encoding seam), and no limit argument in v1.
- `at(i)` — byte access: the byte value at a byte index (negatives from the end) or `undefined` out of range — fold with `??` or test `=== undefined`.

The stays-out tail teaches by name (NS1060 unless noted): `charCodeAt`/`charAt`/`codePointAt` read UTF-16 code units bytes do not have (read `b[i]`/`.at(i)`, slice byte ranges), `normalize` is a host-edge concern, `replace`/`replaceAll` are named deferrals (rebuild with `split`/`indexOf` + a push-builder of parts), `localeCompare`/`toLocaleUpperCase`/`toLocaleLowerCase` read the ambient locale (NS1005), and `match`/`matchAll`/`search` take regexes (NS1040).

The SDK text helpers remain for what the methods do not cover: `containsIgnoreCase` (ASCII case-insensitive search) and `orderIgnoreCase` (an ASCII case-insensitive `.toSorted` comparator) from `@native-sdk/core/text`. `trimAsciiSpaces` also stays, but it is NOT `.trim()`: it strips space/tab/CR only — never LF — as a no-copy view, which is exactly right for line-oriented parsers where `\n` is the record separator; for user input and general whitespace, `.trim()` is now the canonical form.

A freshly created `Uint8Array` is writable until it escapes (stored, returned, passed on); after that it is immutable like everything else. One consequence worth knowing before you build byte output: a buffer PASSED to a helper has escaped, so a writing helper cannot take an out-parameter — build bytes with measure-then-fill inside one function (count the output length, allocate exactly it, write inline), or build a `Uint8Array[]` push-builder of parts and concatenate once (`examples/ai-chat-ts/src/api.ts` does both, JSON escaping included). `===` on two `Uint8Array` values is banned (it would be JS reference identity, which has no native mapping) — compare an id field, or contents with a loop (`s.startsWith(t) && s.length === t.length` is the whole-equality idiom). `bytes.join("-")` renders byte values as decimal text with a literal separator (arena bytes, same result under node); number arrays have no `.join` because their elements are float-valued.

## Text input from markup

A markup text control (`<text-field text="{draft}" on-input="draft_edit" />`) needs two things from the core: a bytes field the control renders (`draft`), and a Msg arm carrying the text-input event. The event union mirrors the runtime's event vocabulary structurally (markup's `on-input` matches the shape and translates each runtime event into your union at dispatch). Import it — `import { type TextInputEvent } from "@native-sdk/core/text"` (also re-exported by `@native-sdk/core/events`) — or copy this declaration verbatim into the core:

```ts
export type TextCaretDirection = "previous" | "next" | "previous_word" | "next_word" | "start" | "end";
export interface TextCaretMove { readonly direction: TextCaretDirection; readonly extend: boolean; }
export interface TextSelection { readonly anchor: number; readonly focus: number; }
export type TextInputEvent =
  | { readonly kind: "insert_text"; readonly text: Uint8Array }
  | { readonly kind: "delete_backward" }
  | { readonly kind: "delete_forward" }
  | { readonly kind: "delete_word_backward" }
  | { readonly kind: "delete_word_forward" }
  | { readonly kind: "clear" }
  | { readonly kind: "move_caret"; readonly move: TextCaretMove }
  | { readonly kind: "set_selection"; readonly selection: TextSelection }
  | { readonly kind: "set_composition"; readonly text: Uint8Array; readonly cursor: number | null }
  | { readonly kind: "commit_composition" }
  | { readonly kind: "cancel_composition" };

export type Msg = /* ... */ | { readonly kind: "draft_edit"; readonly edit: TextInputEvent };
```

Your `update` reduces the events over the draft bytes. A minimal reducer (append / backspace / clear, caret events ignored) covers simple fields; full caret/selection/composition fidelity is ONE IMPORT — the SDK ships the complete byte-splice engine as `@native-sdk/core/text` (`applyTextInputEvent` + `clampedInsertEvent`; see "Splitting a core into modules"), so no core hand-rolls it anymore. Stacked case labels share a body (`case "move_caret": case "set_selection": return draft;`) as long as the shared body reads no payload.

## Continuous controls from markup

Sliders and scroll regions stay model-driven (a committed model has no `sync` hook): bind the widget's value and receive the applied value back as a Msg.

- **Slider (`on-change`, the value-payload change event):** a slider's `on-change` with a bare tag naming a ONE-NUMBER FLOAT arm dispatches the applied 0..1 fraction into it (`<slider value="{progressFraction}" on-change="scrubbed" label="Seek" />` with `{ kind: "scrubbed"; fraction: number }` — the fraction must be float-classed; an integer arm is refused because the value is a clamped fraction). A VOID arm keeps the older static form ("something changed", no value). The same one-number float arm carries a split's `on-resize` fraction.
- **Scroll (`on-scroll`, the ScrollState mirror):** name an arm carrying the scroll-state record — matched by field name, the TextInputEvent rule. Import the record (or declare the same shape in-file). Echo `offset` into a model field bound as the scroll's `value`, and setting that field in update scrolls the region (page changes reset to top):

```ts
import { type ScrollState } from "@native-sdk/core/events";
// (or declare it yourself: { offset, velocity, viewportExtent, contentExtent }, all numbers)
export type Msg = /* ... */ | { readonly kind: "library_scrolled"; readonly scroll: ScrollState };
```

```
<scroll value="{libraryScrollTop}" on-scroll="library_scrolled"> ... </scroll>
```

## The host-event wiring channels

The generated wiring detects each channel from an export (export exists → wired; a wrong shape is a taught NS1033). Event records are matched by field name, STRUCTURALLY: import them from `@native-sdk/core/events` (`FrameEvent`, `KeyEvent`, `ColorScheme`, `ChromeInsets`/`ChromeButtons`) or declare the same shapes in your core — both emit as your module's types and match identically. The `appearanceMsg`/`chromeMsg` arms themselves stay inline union members (`kind` plus the event's fields — the subset has no intersection arms); the SDK's `AppearanceEvent`/`ChromeEvent` records are those arms' canonical payload shapes, importable for helper signatures.

- **`commandMsg(name: string): Msg | null`** — menus, shortcuts, and chrome tabs, by command id (string equality works on `string` values).
- **`frameMsg(model: Model, frame: FrameEvent): Msg | null`** — presented frames. `FrameEvent` is exactly `{ width, height, timestampMs, intervalMs }` numbers (canvas points; fractional milliseconds). Return null for frames that change nothing — the idle law holds exactly when an idle app dispatches nothing (a frame arm that always returns a Msg would spin the loop at full frame rate). The installing frame is excluded; the first PRESENTED frame corrects any seeded value.
- **`keyMsg(key: KeyEvent): Msg | null`** — the app-level key FALLBACK (a focused widget's own keys and editable text always win first). `KeyEvent` is exactly `{ key: string; shift: boolean; control: boolean; alt: boolean; super: boolean }`; the key NAME arrives lowercased (`key.key === "space"`).
- **`export const appearanceMsg = "<arm>"`** — system appearance changes dispatch the named arm, a record of exactly `{ colorScheme: ColorScheme; reduceMotion: boolean; highContrast: boolean }` where `ColorScheme` is a NAMED `"light" | "dark"` alias (routing is data: a string-literal arm name, the effects rule applied to the app shell).
- **`export const chromeMsg = "<arm>"`** — window-chrome geometry (the hidden-titlebar channel), a record of exactly `{ insets: { top; right; bottom; left }; buttons: { x; y; width; height }; tabsProjected: boolean }` (numbers/boolean). Delivered before the first view build and again on changes.
- **`export const envMsgs = [{ env: "NAME", msg: "<arm>" }] as const`** — each named environment variable present at launch dispatches its value through the arm (exactly one `Uint8Array` field, `BytesKind` — annotate with `readonly EnvMsg<Msg>[]` from the SDK for tsc checking) as one journaled Msg right after the boot command. The core never reads the environment (NS1005), and neither does replay: the deliveries are journaled at record time and fed back from the journal, so a recording replays byte-identically even when the variables are unset or changed at replay launch.
- **`app.zon .assets.images`** — `.assets = .{ .images = .{ .{ .id = 1, .path = "assets/art/cover.jpg" }, ... } }`: each file is read once at launch and registered on the installing frame; the `id` is the `ImageId` markup avatar bindings reference (`<avatar image="{coverId}">`), and a missing file or failed decode keeps the initials fallback.

## The rules the checker enforces

Every diagnostic carries one of these IDs plus the fix and the why. Write to them up front:

- **NS1001 shared data is immutable; your own scratch is yours.** Never mutate `model`, `msg`, parameters, module tables, or anything reached from them — build the next value (`{ ...model, tasks: [...model.tasks, task] }`) or copy first (`const copy = xs.slice()`). Arrays this function creates itself mutate freely until they escape — appends via `xs[xs.length] = v`, all-owning reassigned bindings, and readonly-reader borrows included (see "Local mutation" above). The previous model stays live for rendering and undo; unchanged parts are shared, not copied.
- **NS1002 updates are synchronous.** No `async`/`await`/Promises in a core. Work that takes time is command data; the runtime dispatches your `Msg` with the result.
- **NS1003 models hold data, not functions.** No function-typed fields in the Model/Msg tree. Name the behavior as a message and handle it in `update`.
- **NS1004 text is not indexable.** No `.length`/`s[i]`/`.charCodeAt` on `string`. Bytes: `Uint8Array`; literals and templates become bytes through the `asciiBytes` intrinsic.
- **NS1005 update is deterministic.** No `Date.now()`, `Math.random()`, or ambient IO. Take time and randomness as message payloads.
- **NS1006 classes are data classes, declared at module level.** `class` with annotated fields, one constructor, and plain methods compiles (see "Data classes" above); class expressions, `this` outside a member body, and `new` of anything but a data class (or `Uint8Array`) are taught.
- **NS1007 implicit builtin throws stay out.** A JS builtin that throws mid-operation (`.reduce` with no initial value on a possibly-empty array) is taught toward its explicit form; your own `throw` of a subset value is supported control flow (see "Exceptions" above).
- **NS1008 only erasable syntax.** No `enum`, `namespace`, decorators, parameter properties. String-literal unions are the enum.
- **NS1009 no `for`/`in`.** Fixed shapes, no prototypes; model the data as an array and walk it with a classic loop.
- **NS1010 module state lives in the Model.** Module-level `let` is banned (`const` is fine), and a class's MUTABLE `static` field is the same thing by another spelling — `static readonly` consts compile.
- **NS1011 no Map/Set in v1.** Model the data as an id-keyed array of records and look up with a loop or `.filter`.
- **NS1012 object shapes are fixed.** No `delete`, getters/setters, sparse arrays, `Proxy`, `Symbol`. Optional data is `T | null`.
- **NS1013 closed world.** No `eval`, `new Function`, dynamic `import()`.
- **NS1014 the core's entry points live in core.ts.** `update`, `initialModel`, `subscriptions`, the wiring channel exports, and `viewUnbound` belong to the entry module; an entry export in an imported file would be silently ignored by the build, so it is taught instead. Move the export into `src/core.ts` and let the imported module hold what it calls.
- **NS1015 exhaustive switch on message unions.** Cover every `kind`; no `default`.
- **NS1016 integer and fractional numbers never share a slot.** A `number` that indexes memory (or otherwise must be an integer) cannot also receive fractional values; split the field or keep the whole flow integer. In practice this splits a core's numbers into two domains that never meet in one expression: integer values (indexes, ids, counts, anything compared against integer literals or formatted into template holes) and float values (division results, fractional literals). Deriving a float from an integer domain is done by parallel accumulation, not conversion — count in the integer domain and accumulate the float alongside (`pct += 1` next to `fraction += 0.01`); there is no float-to-integer conversion in v1 (`|0` demands an already-integer operand, and `Math.floor` of a float stays float), so integer division is spelled as a bounded whole-unit loop (`while (rest >= 1000) { rest -= 1000; seconds += 1; }`) — and when the dividend is unbounded (wall-clock milliseconds, byte totals), as binary long division, still integer end to end: `function intDiv(n, d) { let q = 0; let r = n; while (r >= d) { let step = d; let count = 1; while (step + step <= r) { step += step; count += count; } r -= step; q += count; } return q; }` (~2·log2(n/d) iterations; `%` of two integer-classed values stays integer, so `dayMs = at % 86400000` needs no loop at all). Primitive-array elements (`readonly number[]`) are always float-classed — wrap ids in single-field records when they must stay integers. One channel corollary: a shared helper parameter is ONE slot, so a helper that receives fractional values in one call cannot receive a proven-integer value in another (push the integer through its own inline site instead — the system-monitor port's process-count history does exactly this beside its fractional cpu/mem pushes).
- **NS1017 commands are issued in update's return, not stored.** Build `Cmd` values inline in the returned `[model, cmd]` tuple; a command in the model, a message, a local, or a helper escapes the dispatch cycle.
- **NS1018 no string concatenation.** `+` (or `+=`) with a string operand builds text at runtime; build bytes with `asciiBytes` on a template literal, or stitch `Uint8Array` buffers with `.set`.
- **NS1019 functions have fixed arity.** No parameter defaults (`= value`), rest parameters (`...xs`), `arguments`, or call spreads (`f(...xs)`); pass every argument explicitly (take and pass an array instead of a spread).
- **NS1020 host command args are numbers or one bytes payload.** `Cmd.host` encodes f64 scalars or one bytes/record payload; a string smuggled through `as` has no encoding.
- **NS1021 optional chains end in `??` or a value use.** `x?.y === null` would have to distinguish JS `undefined` (the chain short-circuited) from `null` (the field's value); normalize with `??` or guard the base first.
- **NS1022 shared arrays sort by copy, not in place.** `.sort()` on a parameter or model array would mutate data that stays live for rendering and undo; sort a copy you own — `const copy = xs.slice(); copy.sort((a, b) => a - b);` — or inline with `.toSorted((a, b) => a - b)`.
- **NS1023 sort comparators return a sign, not a boolean.** JS reads the comparator numerically: `true` coerces to 1 but `false` to 0, which claims equality and leaves pairs unsorted under node too. Return `a - b`, or explicit -1/0/1 branches.
- **NS1024 model text is bytes.** A `string`-typed field anywhere in the Model tree has no commit representation (it would need a JS string heap). Type it `Uint8Array` and build values with `asciiBytes`, or use a string-literal union when the field holds one of a closed set of tags. Reported at the field's declaration.
- **NS1025 subscriptions are declared in subscriptions' return, not stored.** `Sub` values are inert descriptors the host reconciles after every commit; build them inline in `subscriptions(model)`'s return path — a Sub in the model, a message, a local, or another function escapes reconciliation.
- **NS1026 host payloads are bytes or a flat scalar record.** `Cmd.host`/`Cmd.request` carry exactly one payload: a `Uint8Array`, or an inline record of number/boolean/`Uint8Array` fields. Nested records, other field types, or a payload mixed with extra arguments have no wire encoding.
- **NS1027 effect results route to Msg arms by name.** Routing (`{ key?, ok, err }`) and timer targets are string-literal arm names with the payload shape the effect produces — one `Uint8Array` field for host results/errors, one number field for timer and delay fires, no fields for `writeFile`'s ok, one number plus one `Uint8Array` field for `fetch`'s ok. Callbacks and computed names cannot work: the runtime builds the result Msg from the arm's declared shape at build time.
- **NS1028 Cmd.persist is not yet host-backed (warning).** The op compiles and stays on the wire, but no shipping host performs it — persist with `Cmd.writeFile` and boot-load with `Cmd.readFile` instead. The only non-fatal notice in the set.
- **NS1029 effect op arguments have a fixed shape.** Paths/URLs/bodies are bytes, `Cmd.fetch`'s spec is an inline object with a closed verb literal, a number-literal timeout, and an inline flat record of headers whose NAMES are compile-time ASCII and whose VALUES are string literals or runtime bytes (`Uint8Array`). The record's shape encodes at build time; a runtime header value rides its length-prefixed wire field at dispatch time exactly like `url`/`body` — but a smuggled string (a ternary of literals, a template) has no encoding: make it bytes.
- **NS1031 exported model helpers join the model's binding surface.** An exported single-Model-parameter helper emits as a Model declaration markup binds (`doneCount` → `{doneCount}`); two members with one emitted name would be ambiguous — rename one.
- **NS1032 viewUnbound names update-only model state.** `export const viewUnbound = [...] as const` entries must be string literals naming Model fields, exported model helpers, or Msg kinds — by their TypeScript spellings (`"nextId"`, not the emitted `"next_id"`); anything else would silence nothing and hide a typo.
- **NS1030 effect arguments respect the engine's limits.** A compile-time-knowable value outside an engine bound (a path literal over 1024 bytes, a URL literal over 2 KiB, more than 8 headers, a header block over 1 KiB, a delay literal outside 1ms..one year) stops the build instead of shipping a guaranteed runtime rejection. Dynamic values stay the engine's to validate — they surface through the `err` arm.
- **NS1033 wiring channel exports match their host event shapes.** `frameMsg`/`keyMsg` take their exact event records and return `Msg | null`; `appearanceMsg`/`chromeMsg` are string literals naming arms with those channels' record shapes; `envMsgs` entries carry `env` and a one-`Uint8Array`-field `msg` arm. The generated wiring builds these host events structurally from your declarations, so a wrong shape is taught here instead of surfacing as a Zig error inside generated code.
- **NS1034 core imports stay inside src/.** `../` escapes and absolute paths are rejected: the entry module's directory is the core's whole world - the build ships exactly that tree.
- **NS1035 npm packages do not run inside a core.** No JS engine ships in the binary; vendor the logic under `src/` or make the import type-only.
- **NS1036 core modules do not import in a cycle.** Runtime cycles only work through JS live-binding indirection; hoist shared declarations, or make the back-edge `import type` (which is exempt and idiomatic).
- **NS1037 an import names a real module file.** Spell relative specifiers with the `.ts` extension and point them at existing files; `@native-sdk/...` specifiers must name a shipped SDK module.
- **NS1038 module-scope names are unique across a core's files.** Type names and exported value names share the emitted module's one namespace - declare the shared thing once and import it (private helper collisions are auto-prefixed instead). Same-file homonyms count too: a type and an exported value cannot share a name, and interfaces never merge.
- **NS1039 a namespace import is a compile-time alias.** `import * as ns from "./util.ts"` works as dot-syntax (`ns.helper(x)`, `ns.Cfg`); `ns` itself is not a value (never stored or passed), and the intrinsic `@native-sdk/core` module is imported by name so the purity rules can see `Cmd`/`Sub`/`asciiBytes`.
- **NS1040 no regular expressions.** A regex is a runtime engine the binary does not carry; scan bytes with loops or the SDK text helpers (`containsIgnoreCase`, `trimAsciiSpaces`).
- **NS1041 types are static: no runtime type or shape tests.** `typeof` values, `in`, `instanceof`, and the `Object`/`Reflect`/`JSON`/`Array` statics read runtime tags fixed native layouts do not have; model alternatives as a discriminated union and switch on its `kind`.
- **NS1042 no generators.** `function*`/`yield` is a resumable frame with hidden state; build the sequence as an array (push-builder or `.map`/`.filter`) and return it whole.
- **NS1043 statements stay statements.** Comma sequences (outside a for-loop incrementor) and `void` squeeze statements into expression position (the subset's empty value is spelled `null`); a number `++`/`--`/assignment in value position is legal only where the split statement is order-exact (sole mention, unskippable — `arr[i++]`, `const n = ++count`), and the taught remainder names why.
- **NS1044 no BigInt or Symbol.** A core's numbers are IEEE f64 slots (integer-classed slots emit i64); model identities as number ids.
- **NS1045 destructuring binds record fields into const locals.** `const { total, done: doneCount } = stats;` is a compile-time alias; array positions, parameter patterns, defaults, rest, and nesting can be silently absent in JS and are taught toward explicit reads.
- **NS1046 functions live at module level.** Nested function declarations, non-const function values, and `?.()` treat functions as runtime values closing over the frame; move the function to module scope, bind it as a const local helper, or pass what it used (inline arrows as call arguments stay).
- **NS1047 modules export their declarations by name.** Named exports all compile: `export` on the declaration, export lists (`export { a, b as c }` — a rename binds a new flat-namespace name), and named value re-exports (`export { x } from "./m.ts"`). What stays out is the unnamed tail: `export default`, `export =`, `export * from`, plus bindings with no single emitted value (renamed generics/classes, wiring config, re-exports of the SDK surface).
- **NS1048 equality is strict.** `==`/`!=` apply JS's coercion table; use `===`/`!==`.
- **NS1049 locals declare with const and let.** `var` hoists to function scope and reads `undefined` before its line — behavior the emitted locals cannot have.
- **NS1050 generics live on module-level declarations.** Module-level generic functions/interfaces/aliases monomorphize per concrete use; entry points and function values stay concrete.
- **NS1051 a local array is yours until it escapes.** Mutating an owned array AFTER it was returned from a callback, stored into a structure, aliased, or passed where the callee could keep or mutate it is taught with the escape named (kind and line): JS would show the holder your later mutations through the shared reference, while the native value was shared structurally at the escape. Finish mutating first, pass the array after the last mutation, or mutate inside the callee — a pass into a `readonly T[]` reader parameter is a borrow, not an escape. An escape inside a loop gates the whole loop body (the second iteration would mutate after the first iteration's escape).
- **NS1052 spread array locals declare their array type.** `const turns = [...model.turns, next];` has no slice target to lower against — annotate the local: `const turns: readonly Turn[] = [...model.turns, next];`.
- **NS1053 generics instantiate per concrete call site.** A generic call whose resolved type argument has no concrete emitted type (`never` from `pick([])`, `any`/`unknown`, an unnamed literal union) is taught — annotate the call site or name the alias.
- **NS1054 function values stay local helpers.** A const-bound, capture-free, fully-annotated function value hoists to a module-level fn; captures, missing annotations, reassignment, storing/returning the value, and record-field calls are taught toward the helper shape.
- **NS1055 classes hold data, not hierarchies.** No `extends`/`super`/`abstract`: compose (a field holding the other record or class), or model the variants as a `kind`-discriminated union and switch on it — emitted classes are flat structs with static dispatch.
- **NS1056 class members are annotated fields, one constructor, and plain methods.** `static` methods, `static readonly` consts, and erased `private`/`protected` compile; getters/setters, `#`-privates, `accessor`, unannotated or optional (`?`) instance fields, `this` escaping as a value (or used inside a static member — statics go by the class name), and class instances stored in the Model tree are each taught toward the data-class shape.
- **NS1057 thrown values are kind-tagged subset shapes.** Several distinct shapes may throw — the checker collects them into the core's thrown union, and `catch (e)` narrows it with kind tests (`if (e.kind === "parse")`), no `as` needed (single-shape cores may still narrow once with `const err = e as YourError;`; bare rethrow always works). What teaches: untagged thrown values in a heterogeneous set, two shapes sharing a `kind` with different payloads, asserting one member of a multi-shape core, the binding escaping untyped, and `throw new Error(...)`.
- **NS1058 finally never redirects control flow.** `return`/`throw`/`break`-out/`continue`-out inside `finally` would override the pending return or exception (JS's no-unsafe-finally); keep `finally` to cleanup statements.
- **NS1059 arrays build from literals, spreads, and loops.** `Array.of(a, b)` is the literal `[a, b]`, `Array.from(xs)` is the spread copy `[...xs]`, and `Array.from({ length: n }, f)` is a classic loop pushing `f(i)` — the statics consume iterables and array-likes, runtime protocols the fixed layouts do not carry (`Array.isArray` stays NS1041: it is a runtime type test).
- **NS1060 byte text speaks the byte-honest method set.** The everyday string methods work on bytes (see "Text is bytes"); the spellings that would reintroduce the encoding seam teach instead — `charCodeAt`/`charAt`/`codePointAt` (UTF-16 code units; read `b[i]`/`.at(i)`), `normalize` (host-edge normalization), `replace`/`replaceAll` (deferred; rebuild with `.split`/`.indexOf` + a push-builder). The locale family teaches NS1005 and the regex-taking methods NS1040.

## Canonical example

A complete core in the idiom — readonly interfaces, a tagged Msg, spread updates, map/filter, the bytes intrinsic, derived exports:

```ts
import { asciiBytes } from "@native-sdk/core";

export type Bytes = Uint8Array;
export type Filter = "all" | "active" | "done";

export interface Task {
  readonly id: number;
  readonly title: Bytes;
  readonly done: boolean;
}

export interface Model {
  readonly tasks: readonly Task[];
  readonly nextId: number;
  readonly filter: Filter;
  readonly draft: Bytes;
}

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter }
  | { readonly kind: "draft_edit"; readonly text: Bytes };

export function initialModel(): Model {
  return {
    tasks: [{ id: 1, title: asciiBytes("Ship the core"), done: false }],
    nextId: 2,
    filter: "all",
    draft: new Uint8Array(0),
  };
}

export function visibleTasks(model: Model): readonly Task[] {
  if (model.filter === "active") return model.tasks.filter((t) => !t.done);
  if (model.filter === "done") return model.tasks.filter((t) => t.done);
  return model.tasks;
}

export function doneCount(model: Model): number {
  return model.tasks.filter((t) => t.done).length;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": {
      const title = model.draft.trim();
      if (title.length === 0) return model;
      const task: Task = { id: model.nextId, title: title, done: false };
      return {
        ...model,
        tasks: [...model.tasks, task],
        nextId: model.nextId + 1,
        draft: new Uint8Array(0),
      };
    }
    case "toggle":
      return {
        ...model,
        tasks: model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t)),
      };
    case "set_filter":
      return { ...model, filter: msg.filter };
    case "draft_edit":
      return { ...model, draft: msg.text };
  }
}
```

## Running a core as an app

A `native init` app needs NONE of this section: the build detects `src/core.ts` and stages the wiring itself (a core exporting `commandMsg(name: string): Msg | null` automatically receives menu/shortcut command events as Msgs). The section below is for hand-Zig wiring — embedding a core in an existing Zig app or customizing the UiApp surface.

The emitted core runs as a full desktop app through `native_sdk.TsUiApp(core)` — the committed TS model IS the app model, no shim, no glue:

```zig
const core = @import("core.zig"); // the emitted module (+ its rt.zig)
const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App; // a native_sdk.UiApp(core.Model, core.Msg)

const BoardView = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("board.native"));

var app = Adapter.init(allocator, .{ .audio_cache_dir = resolved_cache_dir }, .{
    .name = "board",
    .scene = scene,
    .canvas_label = "canvas",
    .view = BoardView.build, // or any Zig builder view over *const core.Model
    .on_command = commandMsg, // menus/shortcuts -> Msg arms, plain Zig fn
});
```

- `update`/`update_fx`/`init_fx` belong to the adapter (it runs your `initialModel`, `update`, and `subscriptions` through the effect bridge), and the adapter wires `on_command`/`on_key`/`on_appearance`/`on_chrome`/`on_frame` from the core's channel exports automatically (a wiring that also sets one of those seams is a teaching panic). Everything else is ordinary wiring: `tokens_fn`/`windows_fn` derive from `*const core.Model`, and `CoreOptions` carries the adapter-owned knobs (`audio_cache_dir`, `boot_images`, `env_values`).
- Markup binds your model's field names EXACTLY as you wrote them: `nextId` binds as `{nextId}` (the emitted Zig keeps the TS spellings). Record arrays iterate with `<for each="tasks" as="t" key="id">` and items bind their fields (`{t.title}`); optional scalars gate with `<if test="{selected}">` (null is falsy); string-literal unions bind as their member name (`{filter}` renders `all` — compare against a quoted literal, `selected="{sortKey == 'cpu'}"`); exported single-model helpers bind as derived values (`{doneCount}`) and slice-returning ones drive `for each`. Markup `<chart>` series bind number arrays too — `<series kind="bar" values="{cpuSpark}" />` over a field or helper returning `readonly number[]` (emitted f64, narrowed per sample into the chart pipeline); pad a filling window's leading gap with `NaN` samples, which draw nothing.
- `Options.sync` does not exist for TS apps (a committed model cannot be mutated in place): keep continuous controls model-driven — bind the widget's value and echo `on-change`/`on-scroll` Msgs back into the model.
- One live app per core module per process: two apps over the SAME emitted core would share one committed root. Different cores coexist (each emitted core stages its own `rt.zig`).
- Record/replay, the automation verbs, and screenshot fingerprints work unchanged — the adapter rides the standard UiApp dispatch path.

## Checking your work

Scaffolded apps carry an editor surface (`package.json`, `tsconfig.json`, and a CLI-managed `node_modules/@native-sdk/core` copy, npm-managed after the package is published): it exists so stock tsc/editors resolve `@native-sdk/core`, it is NEVER build truth (every `native` verb works with node_modules deleted; check/dev/build re-materialize it), and it is not a language marker — tree detection still keys on `src/core.ts` alone. Do not hand-edit or vendor files under `node_modules/`.

**Refresh the model contract after shape changes.** `native check`'s typed markup pass reads `zig-out/model-contract.zon`, an artifact of the LAST build/test — after changing Model fields or Msg kinds, run `native test` (or `zig build model-contract` in an app that owns its build.zig) before trusting `native check`. A stale contract reports phantom hard errors (`unknown message tag`, `binding does not name a model field`) that name your NEW state — the state is fine; the artifact is old. And never delete `src/app.native` in response to a note about nothing embedding it: on the TypeScript track the generated wiring embeds the view from outside the app tree, so that file is always wired.

The transpiler is the checker: run it after every meaningful edit and read the diagnostics — they always name the rule, the idiomatic rewrite, and the reason. Inside an app, `native check` runs it for you (plus markup and app.zon validation); in a core-only workspace, invoke it directly:

```sh
native check                                                    # inside an app
node <sdk-repo>/packages/core/src/cli.ts src/core.ts -o /tmp/core.zig
```

Exit 0 means the module typechecked (real tsc semantics), passed every subset rule, and emitted Zig. Your workspace README shows the exact command paths for your project, plus how to build the emitted core against the runtime kernel. Because the subset is erasable TypeScript, `node` can import your core directly for quick behavioral checks (`node --input-type=module -e "..."` or a small `node --test` file) — the native build has the same semantics. If the core imports `@native-sdk/core` (for `Cmd` or `asciiBytes`), map that one specifier for node first: copy the SDK module file next to the core and rewrite the import, or run through a loader that resolves it.

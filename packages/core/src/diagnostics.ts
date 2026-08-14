// Teaching diagnostics for the app-core subset checker.
//
// Every rule speaks in three parts, in order: the rule, the fix, the reason.
// No diagnostic may say only "not allowed in the subset" — if a rule cannot
// explain itself in one sentence it does not ship.

export interface SubsetDiagnostic {
  readonly id: string;
  readonly title: string;
  readonly message: string;
  readonly file: string;
  readonly line: number; // 1-based
  readonly column: number; // 1-based
}

/// Every rule is one of two classes. A `guarantee` rule protects a core
/// invariant — determinism and replay, fixed shapes, immutability of shared
/// data, the one text representation — and is permanent. A `deferred` rule
/// bans nothing the invariants require; the capability waits on a deliberate
/// easing decision, and its diagnostic says so.
export type RuleClass = "guarantee" | "deferred";

export interface RuleCopy {
  readonly id: string;
  readonly title: string;
  /// `fix` and `why` are joined after the site-specific lead-in.
  readonly fix: string;
  readonly why: string;
  readonly class: RuleClass;
}

export const rules = {
  NS1001: {
    id: "NS1001",
    title: "shared data is immutable; your own scratch is yours",
    fix: "Build the next value instead (`{ ...model, tasks: [...model.tasks, task] }`), or take a copy you own first (`const copy = xs.slice();`) — arrays this function creates itself (literals, `.slice()`/`.map()`/`.filter()`/`.concat()`/`.toSorted()` copies) mutate freely until they escape, `xs[xs.length] = v` appends like `.push`, a `let` whose EVERY assignment is a fresh construction stays owned, and passing to a `readonly T[]` parameter of a reading helper keeps ownership.",
    why: "The previous model stays live for rendering and undo, and a caller's array outlives the call; native builds share unchanged parts without copying, so the immutable style is not slower — while a locally-created array has exactly one holder, which is what makes mutating it deterministic and safe.",
    class: "guarantee",
  },
  NS1002: {
    id: "NS1002",
    title: "updates are synchronous",
    fix: "Return the work as a command: `[model, Cmd.host(\"fetch_profile\", userId)]`; network and other ordinary async work runs in a `src/services/` module called through its generated `@native-sdk/services` client.",
    why: "The runtime performs the effect after commit and dispatches your message with the result.",
    class: "guarantee",
  },
  NS1003: {
    id: "NS1003",
    title: "models hold data, not functions",
    fix: "Name the behavior as a message (`{ kind: \"tick\" }`) and handle it in update.",
    why: "The model is data; commit walkers cannot (and should not) copy closures.",
    class: "guarantee",
  },
  NS1004: {
    id: "NS1004",
    title: "text is not indexable",
    fix: "Store text as `Uint8Array` bytes and index those; turn user-visible literals/templates into bytes with `utf8Bytes` from \"@native-sdk/core\" (`asciiBytes` is the narrower machine-text form).",
    why: "Code-unit reads behave differently in JS (UTF-16) and native (UTF-8); with them gone the encodings are indistinguishable.",
    class: "guarantee",
  },
  NS1005: {
    id: "NS1005",
    title: "update is deterministic",
    fix: "Take the value as input instead: time via `[model, Cmd.now(\"tick\")]`; randomness rides in as a Msg payload from the host; a `src/services/` module may read the clock directly and return the value as a Msg.",
    why: "Ambient time, randomness, and I/O make replay and testing lie.",
    class: "guarantee",
  },
  NS1006: {
    id: "NS1006",
    title: "classes are data classes, declared at module level",
    fix: "Declare the class at module level — annotated fields, one constructor, plain methods (`class Task { title: Uint8Array; constructor(...) {...} rename(...) {...} }`) — and construct it with `new Task(...)`; everything else stays records and functions.",
    why: "A data class emits as a plain struct plus module-level functions; a class expression, a `this` outside a member body, or `new` of an arbitrary expression would need runtime prototypes and object identity the fixed native layout does not carry.",
    class: "guarantee",
  },
  NS1007: {
    id: "NS1007",
    title: "implicit builtin throws stay out",
    fix: "Give the operation its explicit form (`.reduce(f, init)` — the starting accumulator makes the empty array well-defined); your own `throw` of a subset value is supported, deterministic control flow.",
    why: "JS builtins throw engine TypeError objects mid-operation; a user `throw` carries a subset value the native payload slot can hold, but a builtin's implicit throw has no such value and no native mapping.",
    class: "guarantee",
  },
  NS1008: {
    id: "NS1008",
    title: "only erasable TypeScript syntax compiles",
    fix: "Replace `enum` with a string-literal union; drop namespaces, decorators, and parameter properties.",
    why: "The same file must run unmodified under node (`erasableSyntaxOnly`); these constructs generate code.",
    class: "guarantee",
  },
  NS1009: {
    id: "NS1009",
    title: "for/in does not compile",
    fix: "Model the data as an array and walk it with a classic `for (let i = 0; ...)` loop.",
    why: "`for`/`in` walks the prototype chain; the subset has fixed shapes and no prototypes.",
    class: "guarantee",
  },
  NS1010: {
    id: "NS1010",
    title: "module state lives in the Model",
    fix: "Move the mutable value into the Model and update it through messages; module-level `const` is fine.",
    why: "Mutable globals escape the dispatch/commit lifecycle and break replay.",
    class: "guarantee",
  },
  NS1011: {
    id: "NS1011",
    title: "Map and Set are not part of v1",
    fix: "Model the data as an id-keyed array of records (`readonly Item[]` with a `readonly id: number` field) and look items up with a loop or `.filter`; transform-heavy work may use `Map`/`Set` inside a `src/services/` module and return plain records.",
    why: "Hashed containers need identity and hashing machinery the commit walkers do not carry in v1; id-keyed arrays give the same access pattern with plain data.",
    class: "deferred",
  },
  NS1012: {
    id: "NS1012",
    title: "object shapes are fixed",
    fix: "Model optional data with `T | null` fields; build new objects instead of deleting fields.",
    why: "Sparse arrays, `delete`, getters/setters, `Proxy`, and `Symbol` break the fixed native layouts the compiler emits.",
    class: "guarantee",
  },
  NS1013: {
    id: "NS1013",
    title: "app cores are a closed world",
    fix: "Remove `eval` / `new Function` / dynamic `import()`; express the logic as ordinary functions.",
    why: "No JS engine ships in the binary, so code cannot be created at runtime.",
    class: "guarantee",
  },
  NS1014: {
    id: "NS1014",
    title: "the core's entry points live in core.ts",
    fix: "Move this export into src/core.ts (imported modules may hold the helpers it calls and the types it uses).",
    why: "The build wires `update`, `initialModel`, `subscriptions`, the host-event channels, `themePack`, and `viewUnbound` from the entry module only, so an entry export in an imported file would be silently ignored.",
    class: "guarantee",
  },
  NS1015: {
    id: "NS1015",
    title: "exhaustive switch required on message unions",
    fix: "Add a case for every `kind` (no `default` needed once all arms are present).",
    why: "Exhaustiveness is what lets the compiler emit a closed native switch with no fallback path.",
    class: "guarantee",
  },
  NS1016: {
    id: "NS1016",
    title: "integer and fractional values cannot share a number slot",
    fix: "Split the value into two fields, or keep every value on this path whole (no fractional literals or fractional math flowing into it).",
    why: "Native code gives each `number` slot one machine type; this slot must be an integer where it is used, but a fractional value also flows in, and an integer type cannot hold both.",
    class: "guarantee",
  },
  NS1017: {
    id: "NS1017",
    title: "commands are issued in update's return, not stored",
    fix: "Construct the Cmd inline in update's return: `return [next, Cmd.persist()]` (several at once via `Cmd.batch([...])`).",
    why: "A Cmd describes effects for the runtime to perform after this dispatch commits; a command that lives in the model, a message, a local, or a helper escapes the dispatch cycle and breaks replay.",
    class: "guarantee",
  },
  NS1018: {
    id: "NS1018",
    title: "text builds with templates and bytes, not +",
    fix: "Build the text as bytes: `utf8Bytes(`${count} items`)` from \"@native-sdk/core\", or stitch byte buffers with `new Uint8Array(n)` + `.set`.",
    why: "Runtime string concatenation would need a JS string heap the native binary does not carry; bytes in the frame arena are the one dynamic-text representation.",
    class: "guarantee",
  },
  NS1019: {
    id: "NS1019",
    title: "functions have fixed arity",
    fix: "Pass every argument explicitly at every call site: drop parameter defaults (`= value`), rest parameters (`...xs`), `arguments`, and call spreads (`f(...xs)`) — take and pass an array instead.",
    why: "Emitted native functions have exact signatures; a dynamic argument list would be materialized invisibly at each call site, and a missed site diverges from node instead of failing loudly.",
    class: "deferred",
  },
  NS1020: {
    id: "NS1020",
    title: "host command arguments are numbers or one bytes payload",
    fix: "Pass numbers (`Cmd.host(\"beep\", model.count)`), or exactly one payload — a `Uint8Array` or a flat record of number/boolean/`Uint8Array` fields (`Cmd.host(\"save\", model.draft)`).",
    why: "The Cmd wire format encodes f64 scalars or one bytes payload per record; a value smuggled past the type with `as` has no encoding and would corrupt the effect stream.",
    class: "guarantee",
  },
  NS1021: {
    id: "NS1021",
    title: "optional chains end in ?? or a value use, not a null test",
    fix: "Normalize with `??` (`model.sel?.tag ?? null`) or guard the base first (`model.sel !== null && model.sel.tag === null`).",
    why: "A short-circuiting `?.` yields JS `undefined` while the field's own empty value is `null`; native folds both into one null, so a null test on the chain would disagree with node.",
    class: "guarantee",
  },
  NS1022: {
    id: "NS1022",
    title: "shared arrays sort by copy, not in place",
    fix: "Sort a copy you own — `const copy = xs.slice(); copy.sort((a, b) => a - b);` — or inline with `.toSorted((a, b) => a - b)` and use the returned copy.",
    why: "`.sort()` mutates the array it is called on; model data stays live for rendering and undo, so an in-place sort would corrupt the previous model. A local `.slice()` copy is yours, and sorting it in place is legal.",
    class: "guarantee",
  },
  NS1023: {
    id: "NS1023",
    title: "sort comparators return a sign, not a boolean",
    fix: "Return a number whose sign orders the pair: `(a, b) => a - b` for ascending numbers, or explicit -1/0/1 branches.",
    why: "JS reads the comparator numerically — `true` coerces to 1 but `false` coerces to 0, which claims the pair is already ordered, so a boolean comparator leaves data unsorted under node too.",
    class: "guarantee",
  },
  NS1024: {
    id: "NS1024",
    title: "model text is bytes",
    fix: "Type the field `Uint8Array` and build user-visible values with `utf8Bytes` from \"@native-sdk/core\" (`asciiBytes` is for guaranteed-ASCII machine text), or use a string-literal union (`\"low\" | \"high\"`) when the field holds one of a closed set of tags.",
    why: "A `string` model field would need a JS string heap at every commit; bytes have exactly one representation under node and native, and literal-union tags compile to a native enum.",
    class: "guarantee",
  },
  NS1025: {
    id: "NS1025",
    title: "subscriptions are declared in subscriptions' return, not stored",
    fix: "Derive the descriptors from the model and return them from `subscriptions`: `return model.running ? Sub.timer(\"tick\", 1000, \"tick\") : Sub.none;`.",
    why: "A Sub describes recurring effects the host reconciles against the committed model after every dispatch; a descriptor stored in the model, a message, a local, or a helper escapes that reconciliation and breaks replay.",
    class: "guarantee",
  },
  NS1026: {
    id: "NS1026",
    title: "host payloads are bytes or a flat scalar record",
    fix: "For a raw host call, pass one `Uint8Array` (build text with `asciiBytes`) or one inline scalar record. For nested/typed service data, declare one exported shared shape and call its generated constructor from `@native-sdk/services`.",
    why: "Raw host commands carry one primitive bytes payload. Generated service clients are the deliberate record-valued arm: their sidecar-derived codec carries the wider boundary vocabulary identically under node and native.",
    class: "guarantee",
  },
  NS1027: {
    id: "NS1027",
    title: "effect results route to Msg arms by name",
    fix: "Spell the routing as data — string-literal arm names, optionally keyed: `{ key: \"load\", ok: \"loaded\", err: \"load_failed\" }` — where each named arm carries exactly the payload the effect produces (one `Uint8Array` field for host results; one number field for timer fires).",
    why: "The runtime builds the result Msg itself from the arm's declared shape, so the decoding derives from your types at build time; a callback would run outside the dispatch cycle and could capture state replay cannot see.",
    class: "guarantee",
  },
  NS1028: {
    id: "NS1028",
    title: "Cmd.persist and its capability must agree",
    fix: "Add `\"persist\"` to app.zon's `capabilities` and configure `.persist = .{ .version = 1, .restore = .{ .ok = \"restored\", .none = \"fresh_boot\", .err = \"restore_failed\" } }`; or remove the unused capability/command.",
    why: "The persist capability controls whether the engine-owned snapshot store and `core.persist` binding are linked into the app. Keeping the declaration and command in lockstep prevents a silently unperformed write and sheds storage code from apps that do not use it.",
    class: "guarantee",
  },
  NS1029: {
    id: "NS1029",
    title: "effect op arguments have a fixed shape",
    fix: "Spell the built-in op exactly: paths/URLs/bodies are `Uint8Array`, `method` is a closed verb literal, `timeoutMs` is a number literal, and `headers` is an inline flat record. For an app service, use its generated `@native-sdk/services` constructor; its request and route shape come from the shared contract.",
    why: "Every effect encodes to one fixed wire record. Built-ins own their hand-written shape; service operations own a generated shape and codec projected from services.contract.json.",
    class: "guarantee",
  },
  NS1030: {
    id: "NS1030",
    title: "effect arguments respect the engine's limits",
    fix: "Keep the value inside the engine bound this diagnostic names (shorter path/URL/header block, fewer headers, a delay between 1ms and one year).",
    why: "The host effect engine enforces fixed capacities and would reject the op at runtime through the err arm; a bound that is knowable at compile time should stop the build instead of shipping a guaranteed rejection.",
    class: "guarantee",
  },
  NS1031: {
    id: "NS1031",
    title: "exported model helpers join the model's binding surface",
    fix: "Rename the helper or the colliding member so their emitted names differ.",
    why: "An exported helper taking exactly one Model parameter also emits as a Model declaration markup binds by the helper's own name (`doneCount` binds as `{doneCount}`); two members with one emitted name would be ambiguous to every binding engine.",
    class: "guarantee",
  },
  NS1032: {
    id: "NS1032",
    title: "viewUnbound names update-only model state",
    fix: "Export a const array of string literals naming Model fields, exported model helpers, or Msg kinds: `export const viewUnbound = [\"nextId\", \"tick\"] as const;`.",
    why: "The list emits as the `view_unbound` opt-out `native check` reads, keeping the unbound-state lint honest for state only update logic touches; a name outside the model surface would silence nothing and hide a typo.",
    class: "guarantee",
  },
  NS1033: {
    id: "NS1033",
    title: "wiring exports match their runtime shapes",
    fix: "Declare the channel exactly: `commandMsg(name: string)` / `keyMsg(key: KeyEvent)` / `frameMsg(model: Model, frame: FrameEvent)` / `pinchMsg(pinch: PinchEvent)` / `dropMsg(drop: FileDropEvent)` returning `Msg | null`; `themePack(model: Model): ThemePack`; singular `statusItem(model: Model): StatusItemState` or collection `statusItems(model: Model): readonly StatusItemDescriptor[]`; `windows(model: Model): readonly WindowDescriptor[]`, with each entry constructed by `windowDescriptor` and a literal `label: asciiBytes(\"name\")` matching `src/windows/name.native`; `appearanceMsg` / `chromeMsg` naming an arm with that channel's record shape; `envMsgs` entries targeting one-`Uint8Array`-field arms; and persistence ok/none routes naming void arms while err names a one-`Uint8Array`-field arm. Import canonical records from the SDK modules.",
    why: "The generated wiring builds host events, persistence restore results, model-derived theme/status/window declarations, and their typed callbacks structurally at build time; a wrong shape would otherwise surface as a Zig compile error inside generated code instead of a teaching diagnostic here.",
    class: "guarantee",
  },
  NS1034: {
    id: "NS1034",
    title: "core imports stay inside src/",
    fix: "Move the module under the app's src/ directory and import it relatively (`./parsers.ts`, `./util/bytes.ts`).",
    why: "The entry module's directory is the core's whole world — the build ships exactly that tree, so a file above it (`../`) or at an absolute path would exist on your machine but not in the app the build compiles.",
    class: "guarantee",
  },
  NS1035: {
    id: "NS1035",
    title: "npm packages do not run inside a core",
    fix: "Move ordinary TypeScript work into `src/services/` and call it through `Cmd.request`, vendor subset-legal core logic under src/ and import it relatively, or make the import type-only (`import type`); only \"@native-sdk/core\" modules carry runtime meaning in the core class.",
    why: "No JS engine ships in the binary — the deterministic core carries only its closed subset, while service modules compile separately through scriptc's ordinary static tier and results return as messages.",
    class: "guarantee",
  },
  NS1036: {
    id: "NS1036",
    title: "runtime modules do not import in a cycle",
    fix: "Hoist the shared declarations into a module both sides import, or make the back-edge type-only (`import type { Model } from \"./core.ts\"` is fine).",
    why: "A runtime import cycle only works through JS's live-binding indirection, which the emitted native module (and plain reading order) cannot represent; type-only edges erase and are exempt.",
    class: "guarantee",
  },
  NS1037: {
    id: "NS1037",
    title: "an import names a real module file",
    fix: "Point the specifier at an existing .ts file, spelled with its extension (`./parsers.ts` — node's module loader resolves real filenames, not bare stems).",
    why: "The import graph is the build's whole input: a specifier that resolves to nothing would fail under node and silently vanish natively.",
    class: "guarantee",
  },
  NS1038: {
    id: "NS1038",
    title: "module-scope names are unique across a core's files",
    fix: "Rename one side, or declare the shared thing once and import it where it is used.",
    why: "The core emits as one native module with one namespace: two types (or two exported values) with one name would collide there, and which one markup or a caller meant would be ambiguous.",
    class: "guarantee",
  },
  NS1039: {
    id: "NS1039",
    title: "a namespace import is a compile-time alias",
    fix: "Reference members through the alias (`ns.helper(x)`, `ns.Config`) or import them by name; the SDK intrinsics are always named imports — `import { Cmd, Sub, asciiBytes, utf8Bytes } from \"@native-sdk/core\"`.",
    why: "The core emits as one flat namespace, so `ns` is dot-syntax that erases at build time — it is not an object value that can be stored or passed — and the effect purity rules recognize the SDK factories by their imported names.",
    class: "guarantee",
  },
  NS1040: {
    id: "NS1040",
    title: "regular expressions are not part of v1",
    fix: "Scan the bytes with the byte-text methods (`.includes`/`.indexOf`/`.startsWith`/`.split` on `Uint8Array`), a loop, or the SDK text helpers (`containsIgnoreCase` from \"@native-sdk/core/text\"); or run the match in a `src/services/` module, where regexes are ordinary TypeScript.",
    why: "A regex is a runtime engine (backtracking, unicode tables) the native binary does not carry, and it reads text as UTF-16 code units where the core's text is bytes.",
    class: "deferred",
  },
  NS1041: {
    id: "NS1041",
    title: "types are static: no runtime type or shape tests",
    fix: "Model alternatives as a discriminated union and switch on its `kind`; optional data is `T | null` tested against null; walk arrays, not object keys; parse JSON in a `src/services/` module that returns a typed record.",
    why: "Emitted values are fixed native layouts with no runtime tags to inspect (a union's `kind` is the one tag that exists), so `typeof`/`in`/`instanceof`/`Object.keys` have nothing to read.",
    class: "guarantee",
  },
  NS1042: {
    id: "NS1042",
    title: "generators are not part of v1",
    fix: "Build the sequence as an array — the push-builder (`const out: T[] = []` + `out.push(x)`) or `.map`/`.filter` — and return it whole.",
    why: "A generator is a resumable stack frame with hidden state; the subset's collections are materialized arrays built by pure code, which replay and the commit walkers can see.",
    class: "deferred",
  },
  NS1043: {
    id: "NS1043",
    title: "statements stay statements",
    fix: "Write each step as its own statement. A classic for-loop may step several counters (`i++, j--`), and a number `++`/`--`/assignment may sit in a value position when it is the variable's only mention in the statement and JS cannot skip it (`arr[i++]`, `const n = ++count`); everywhere else a comma hides a statement and `void` manufactures a JS undefined (spell the empty `null`).",
    why: "Comma, `void`, and the mixed read-write forms exist to squeeze statements into expression position; the emitted native code splits them back into statements, which is only JS-order-exact in the pinned positions.",
    class: "guarantee",
  },
  NS1044: {
    id: "NS1044",
    title: "BigInt and Symbol are not part of v1",
    fix: "Keep integer math in `number` (exact to 2^53, and integer-classed slots emit as native i64); model identities as number ids.",
    why: "A core's numbers are IEEE f64 slots; arbitrary-precision integers and engine-allocated symbol identities have no native representation.",
    class: "deferred",
  },
  NS1045: {
    id: "NS1045",
    title: "destructuring binds record fields into const locals",
    fix: "Destructure records only: `const { total, done } = stats;` (rename with `{ done: doneCount }`). Bind array elements by index (`const first = xs[0];`), parameters by name, and drop defaults/rest.",
    why: "A record field is always present, so the binding is a compile-time alias; array positions, rest, and defaults can be silently absent in JS (`undefined`), which a bounds-checked native read cannot mean.",
    class: "guarantee",
  },
  NS1046: {
    id: "NS1046",
    title: "functions live at module level",
    fix: "Move the function to module scope (or bind it once: `const helper = (x: number): number => ...` — a capture-free const helper hoists) and pass what it captured as parameters; inline arrow callbacks stay where they are — as call arguments (`xs.map((x) => x * 2)`).",
    why: "A nested declaration, a non-const function value, or a `?.()` call treats a function as a runtime value closing over the enclosing frame; emitted native functions are plain module-level code with explicit inputs, so the capture has no representation.",
    class: "guarantee",
  },
  NS1047: {
    id: "NS1047",
    title: "modules export their declarations by name",
    fix: "Export by name: `export` on the declaration, an export list (`export { doneCount, helper as visible }`), or a named value re-export (`export { parsePs } from \"./parsers.ts\"`); what stays out is `export default`, `export =`, `export * from`, and bindings over things with no single emitted value (renamed generics/classes, wiring config, names from outside the core).",
    why: "Every consumer — markup bindings, the generated wiring, imports across the core's modules — resolves the flat emitted namespace by NAME: an export list binds real names over real declarations (NS1038 keeps them unique), while a default has no name and a star re-export names nothing.",
    class: "guarantee",
  },
  NS1048: {
    id: "NS1048",
    title: "equality is strict",
    fix: "Compare with `===` / `!==`.",
    why: "`==` applies JS's coercion table (\"1\" == 1 is true); the subset's typed values never coerce, so the loose forms are either identical to `===` or depend on string/number coercions that do not exist natively.",
    class: "guarantee",
  },
  NS1049: {
    id: "NS1049",
    title: "locals declare with const and let",
    fix: "Replace `var` with `const` (or `let` where the local is reassigned).",
    why: "`var` hoists to function scope and reads as `undefined` before its line — behavior the emitted block-scoped native locals cannot have, so the subset keeps the two forms whose semantics map exactly.",
    class: "guarantee",
  },
  NS1050: {
    id: "NS1050",
    title: "generics live on module-level declarations",
    fix: "Make the generic a module-level `function`, `interface`, or `type` (those monomorphize per concrete use — `pick<Task>` emits `pick__Task`); the dispatch entry points (update/initialModel/subscriptions) and function values stay concrete.",
    why: "A monomorphized generic needs a declaration the emitter can instantiate per call site; an entry point has one host-facing ABI signature, and a function value hoists as one concrete fn, so neither can vary by type parameter.",
    class: "guarantee",
  },
  NS1051: {
    id: "NS1051",
    title: "a local array is yours until it escapes",
    fix: "Finish mutating before the value escapes: move the mutation above the return/store/call, pass the array only after the last mutation, or mutate inside the callee instead — a call whose parameter is `readonly T[]` and only READS it (no return, no store, no onward pass into a mutable position) is a borrow, not an escape.",
    why: "Once an array is returned, stored, passed where the callee could retain or mutate it, or aliased, other code can hold the same reference; JS would show it your later mutations through that reference, while the native value was shared structurally at the escape — so ownership (and with it mutability) ends there.",
    class: "guarantee",
  },
  NS1052: {
    id: "NS1052",
    title: "spread array locals declare their array type",
    fix: "Annotate the local with its array type: `const turns: readonly Turn[] = [...model.turns, next];`.",
    why: "An array literal lowers against a declared slice target (the element type sizes the copy the spread allocates); an un-annotated spread local leaves that type unknown, so the emitter has nothing to lower against.",
    class: "guarantee",
  },
  NS1053: {
    id: "NS1053",
    title: "generics instantiate per concrete call site",
    fix: "Give the call site concrete types the emitter can name — resolved records, unions, arrays, optionals, numbers, booleans, or bytes (`pick<Task>(tasks)` or plain inference from typed arguments); a call whose type argument stays abstract (an empty `[]`, an `any`/`unknown`/`never`, an unnamed literal union) needs an annotation or a named alias.",
    why: "A generic helper emits one monomorphic Zig function per distinct instantiation (`pick__Task`, `pick__f64`) from tsc's resolved type arguments; a type argument with no concrete native name has nothing to instantiate against.",
    class: "guarantee",
  },
  NS1054: {
    id: "NS1054",
    title: "function values stay local helpers",
    fix: "Bind the function once (`const helper = (x: number): number => x * 2;`), spell its full signature, take everything it needs as parameters (module constants are fine), and use it only by calling it directly or passing it where an inline callback is legal (`xs.map(helper)`).",
    why: "A const-bound, capture-free, fully-annotated function value hoists to an ordinary module-level native function; captures, reassignment, storing or returning the value, and function-typed fields would make it a runtime closure, which has no native representation.",
    class: "guarantee",
  },
  NS1055: {
    id: "NS1055",
    title: "classes hold data, not hierarchies",
    fix: "Drop `extends`/`super`/`abstract`: compose (a field holding the other record or class), or model the variants as a `kind`-discriminated union and switch on it.",
    why: "Emitted classes are flat structs with static dispatch; a subclass would need vtables, prototype chains, and layout subtyping that neither the native mapping nor the commit walkers carry.",
    class: "guarantee",
  },
  NS1056: {
    id: "NS1056",
    title: "class members are annotated fields, one constructor, and plain methods",
    fix: "Spell state as annotated fields (`count: number = 0`) and behavior as ordinary methods — `static` methods, `static readonly` consts, and erased `private`/`protected` keywords included; replace getters/setters with methods, `#`-privates with `private` (or module boundaries), and use `this` only to reach instance fields and methods (`this.count`, `this.step()` — statics go by the class name: `Task.LIMIT`).",
    why: "A data class emits as a struct plus module-level functions (statics under the class's mangled names); accessors, runtime `#` privacy brands, and a `this` that escapes as a value are prototype/closure machinery with no struct representation — and a record-shaped instance must stay exactly its fields.",
    class: "guarantee",
  },
  NS1057: {
    id: "NS1057",
    title: "thrown values are kind-tagged subset shapes",
    fix: "Throw kind-discriminated record values (`throw { kind: \"parse\", at: i } as ParseError;` — several distinct shapes may throw; the checker collects them into the core's thrown union) and read the catch binding in place: test `e.kind` to narrow, read the arm's fields, rethrow bare (`throw e;`), or narrow a single-shape core once with `const err = e as YourError;`.",
    why: "Every `throw` unwinds through one native payload slot typed as the union of the core's thrown shapes, and the `kind` tags are what let a catch narrow that slot exactly — so a thrown value with no subset shape, two shapes sharing one tag, or an error value smuggled out untyped has no sound reading.",
    class: "guarantee",
  },
  NS1058: {
    id: "NS1058",
    title: "finally never redirects control flow",
    fix: "Keep `finally` to cleanup statements; move `return`/`break`/`continue`/`throw` decisions into the `try` or `catch` blocks.",
    why: "A `finally` that exits overrides the pending return or exception (JS's own no-unsafe-finally lint rule exists because that is almost always a bug); the native lowering runs finally on every path through a scoped defer, which cannot carry control flow out.",
    class: "guarantee",
  },
  NS1059: {
    id: "NS1059",
    title: "arrays build from literals, spreads, and loops",
    fix: "Spell the construction directly: `Array.of(a, b)` is the literal `[a, b]`, `Array.from(xs)` is the spread copy `[...xs]`, and `Array.from({ length: n }, f)` is a classic loop pushing `f(i)` into `const out: T[] = []`.",
    why: "The `Array` statics consume iterables and array-like objects — runtime protocols (`Symbol.iterator`, dynamic `length` probing) the fixed native layouts do not carry — while the literal, spread, and push-builder forms construct the same arrays from data the emitter can see.",
    class: "guarantee",
  },
  NS1060: {
    id: "NS1060",
    title: "byte text speaks the byte-honest method set",
    fix: "Use the byte surface: case with `.toUpperCase()`/`.toLowerCase()` (Unicode simple case mapping, locale-free), search with `.includes`/`.indexOf`/`.lastIndexOf`/`.startsWith`/`.endsWith` (bytes needles), measure and pad in bytes (`.length`, `.padStart`), read bytes with `b[i]`/`.at(i)`, and rebuild text with `.split`, slices, and a push-builder.",
    why: "Core text is UTF-8 bytes with exactly one representation under node and native; UTF-16 code-unit reads and Unicode normalization would reintroduce the encoding seam the bytes model exists to close, so their spellings teach the byte-honest form instead.",
    class: "guarantee",
  },
  NS1061: {
    id: "NS1061",
    title: "value records stay scalar where the model keeps them",
    fix: "Declare the record as an interface (reference storage) to hold heap-backed fields, sit in a model array, carry identity under `===`, or reference itself; an object-literal alias (value storage) in the model tree carries scalar fields only (numbers, booleans, literal-union tags).",
    why: "An object-literal alias pins by-value storage — the contract projection's value-record spelling. The model's commit machinery copies by-value records shallowly, so heap-backed fields would dangle across frames, arrays of them have no commit walk, equality has no identity to compare, and a self-reference has no finite layout; each of those needs reference storage, which the interface form declares.",
    class: "guarantee",
  },
  NS1062: {
    id: "NS1062",
    title: "the entry roots keep their contract shapes",
    fix: "Declare `Model` as an interface record (`export interface Model { ... }`) and `Msg` as a kind-tagged union (`export type Msg = { kind: \"...\" } | ...`).",
    why: "The generated wiring commits `Model` as the reference-stored record root and dispatches `Msg` by its declaration-order kind tags; any other shape under those names has no dispatch or commit path and would fail deep inside the emitted module instead of teaching here.",
    class: "guarantee",
  },
  NS1063: {
    id: "NS1063",
    title: "the contract sidecar carries every crossing shape",
    fix: "Spell the crossing in a schema-carried form: value-stored records (object-literal aliases) for message payloads, named records around optional or array payloads, and integer aliases whose values reach past 255.",
    why: "The contract sidecar is the machine-readable twin of the core's surface, and a shape its schema cannot state would silently drop from every consumer — so the build stops here with the spelling that carries it instead.",
    class: "guarantee",
  },
  NS1064: {
    id: "NS1064",
    title: "asciiBytes is ASCII-only",
    fix: "Use `utf8Bytes(...)` for user-visible or Unicode text; keep `asciiBytes(...)` for guaranteed-ASCII command names, keys, paths, URLs, and protocol values.",
    why: "JavaScript strings are UTF-16 while the native text boundary is UTF-8; naming the encoding explicitly prevents a non-ASCII code unit from being truncated into a different byte sequence.",
    class: "guarantee",
  },
  NS1065: {
    id: "NS1065",
    title: "the core does not import services",
    fix: "Import the generated constructor from `@native-sdk/services` and return it from update; raw `Cmd.request(\"module.operation\", bytes, { ok, err })` remains the low-level form. Shared boundary shapes live in a core module that the service imports, but the core-to-service edge is always an effect.",
    why: "A direct import would run ambient, non-deterministic service authority inside update and erase the command/result boundary that journaling and replay depend on.",
    class: "guarantee",
  },
  NS1066: {
    id: "NS1066",
    title: "service package imports are exact vendored facts",
    fix: "Run `native vendor . package@X.Y.Z`, check in `src/services/vendor/` and the generated app.zon `service_packages` facts, then import that exact package name; or vendor a local source module and import it relatively.",
    why: "Service builds have no package-manager or network input: scriptc sees only manifest-declared, hash-verified checked-in sources through an explicit `--npm-static` allowlist.",
    class: "guarantee",
  },
  NS1067: {
    id: "NS1067",
    title: "service calls match the generated typed contract",
    fix: "Export a synchronous, non-default named function with zero or one explicitly typed, contract-encodable request and a contract-encodable result. For a stream, add a last `emit: (chunk: SharedChunk) => void` parameter. Keep boundary records/enums/unions exported in a shared core-class module, let only `{ kind: \"...\", message: <string> }` escape, and call through `@native-sdk/services`.",
    why: "The host codecs, runner registry, and typed client are projections of `services.contract.json`; every crossing data shape, stream declaration, deadline, and operation name must be stated there once.",
    class: "guarantee",
  },
  NS1068: {
    id: "NS1068",
    title: "persistent model shapes advance monotonically",
    fix: "Increase app.zon's `.persist.version` when the `Model` shape changes, and never decrease or reuse a version number.",
    why: "The version selects the app's pure migration path while the model fingerprint rejects accidental shape drift; reusing a version would make old bytes ambiguous and could restore them into the wrong model layout.",
    class: "guarantee",
  },
  NS1069: {
    id: "NS1069",
    title: "Cmd.store and its capability must agree",
    fix: "Add `\"store\"` to app.zon's `capabilities`, or remove the unused capability/command.",
    why: "The store capability controls whether SQLite and the engine-owned record-store binding are linked into the app. Keeping the declaration and command in lockstep prevents a rejected effect and sheds the storage engine from apps that do not use it.",
    class: "guarantee",
  },
  NS1070: {
    id: "NS1070",
    title: "Cmd.db and its capability must agree",
    fix: "Add `\"sqlite\"` to app.zon's `capabilities`, or remove the unused capability/command.",
    why: "The sqlite capability controls whether the relational database and its effect binding are linked into the app. Keeping the declaration and command in lockstep prevents a rejected effect and sheds SQLite from apps that do not use either storage tier.",
    class: "guarantee",
  },
  NS1071: {
    id: "NS1071",
    title: "Cmd.credentials and its capability must agree",
    fix: "Add `\"credentials\"` to app.zon's `capabilities`, or remove the unused capability/command.",
    why: "The credentials capability controls whether the core keychain path is linked into the app; keeping it in lockstep prevents a guaranteed denied effect and sheds the path from apps that do not use it.",
    class: "guarantee",
  },
  NS1072: {
    id: "NS1072",
    title: "core credentials require explicit permission",
    fix: "Add `\"credentials\"` to app.zon's `permissions`, or remove the `Cmd.credentials.*` call.",
    why: "Secrets are the first permission-gated core effect: the runtime refuses every undeclared access with `denied`, even when the build capability is present.",
    class: "guarantee",
  },
  NS1073: {
    id: "NS1073",
    title: "credential requests use the typed factory",
    fix: "Use `Cmd.credentials.set`, `Cmd.credentials.get`, or `Cmd.credentials.delete` instead of spelling `core.credentials.*` through `Cmd.request`.",
    why: "The typed factories own the bounded credential record encoding; reserving their wire namespace keeps arbitrary request bytes from being mistaken for secrets or keys.",
    class: "guarantee",
  },
  NS1074: {
    id: "NS1074",
    title: "external file paths require filesystem permission",
    fix: "Add `\"filesystem\"` to app.zon's `permissions`, or keep raw file effects under a path delivered from `NATIVE_SDK_APP_DATA_DIR`.",
    why: "The runtime canonicalizes raw paths and refuses access outside this app's data/config/cache/state/logs/temp roots unless the manifest grants filesystem access; catching literal external paths at check time avoids shipping a guaranteed rejection.",
    class: "guarantee",
  },
  NS1420: {
    id: "NS1420",
    title: "declare stable SQL in src/queries.sql",
    fix: "Move the string literal into a named `-- name: ...` block in src/queries.sql and call its generated `Cmd.q<Name>` constructor; keep Cmd.db only for genuinely dynamic escape-hatch SQL.",
    why: "Declared SQL is prepared against the complete migration schema during native check, so table, column, result, and parameter mistakes never reach an installed app.",
    class: "guarantee",
  },
} as const satisfies Record<string, RuleCopy>;

export type RuleId = keyof typeof rules;

export function formatDiagnostic(d: SubsetDiagnostic, severity: "error" | "warning" = "error"): string {
  return `${d.file}:${d.line}:${d.column} ${severity} ${d.id} ${d.title}\n  ${d.message}`;
}

export function makeDiagnostic(
  id: RuleId,
  site: string,
  file: string,
  line: number,
  column: number,
): SubsetDiagnostic {
  const rule = rules[id];
  const classNote =
    rule.class === "deferred" ? " The capability is deliberately deferred, not impossible." : "";
  return {
    id: rule.id,
    title: rule.title,
    message: `${site} ${rule.fix} ${rule.why}${classNote}`,
    file,
    line,
    column,
  };
}

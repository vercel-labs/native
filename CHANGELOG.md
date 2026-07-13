# Changelog

All notable changes to the Native SDK (formerly zero-native) will be documented in this file.

## 0.5.0

<!-- release:start -->

### New Features

- **TypeScript authoring — write app cores in TypeScript**: `native init` now scaffolds a TypeScript app by default — `src/core.ts` (logic), `src/app.native` (view), `app.zon` (manifest), zero Zig to write — and the build transpiles the core to readable arena-backed Zig, so the shipped binary carries no JS engine and no GC and keeps the native dispatch path (~83ns per update). The `@native-sdk/core` package (the SDK cores import, plus the transpiler the CLI runs) publishes to npm with this release at the SDK's version. Zig cores remain first-class (`native init --template zig-core`), mixed TS-core + Zig-helper apps fall out of tree detection naturally, and a TypeScript app can eject to its emitted Zig at any time. The entries below are the pieces of this one feature (#119).
- **examples/ai-chat-ts — an AI chat client authored entirely in TypeScript + Native markup**: a conversation UI over an OpenAI-compatible chat-completions endpoint as two subset modules and zero Zig — `Cmd.fetch` with routed `{status, body}` results, the JSON wire format as pure byte math (`src/api.ts` encodes requests and parses `choices[0].message.content` / `error.message`, refusing anything malformed), conversation history in the Model, the composer on the SDK byte-splice text engine, endpoint/model/key through the env channel (no baked endpoint, no key anywhere in the tree — a teaching state until all three arrive), a model-level in-flight guard, and honest failed states that keep the history with a Retry. The e2e battery (`tests/ts-core/ai_chat_e2e_tests.zig`, in `zig build test-ts-core-e2e`) pins the exact request bytes turn by turn and replays a recorded conversation — transport failure and retry included — byte-identically with zero network; the README states the v1 boundaries plainly (buffered responses, compile-time fetch headers) (#119).
- **Docs: "Where Packages Go"** (`/typescript/packages`): the four first-class patterns behind "can I use npm?" — HTTP/AI APIs through `Cmd.fetch` (with a complete transpile-checked core sample), npm-heavy UIs as embedded web frontends, Node libraries as `Cmd.spawn` sidecars, and pure utilities vendored under `src/` or imported from the curated `@native-sdk/core/*` channel — with the core's no-npm boundary stated as the thing that buys replay, headless testing, and native dispatch speed (#119).
- **Eval wave 2 — six dual-track authoring cases, one language-blind spec each**: the eval harness gains `"frontend": "app-dual"` cases that run the SAME realistic ask on both authoring tracks — `<case>@ts` scaffolds a full TypeScript app (`native init --template ts-core`), `<case>@zig` the Zig app template — graded by shared checks plus per-track behavioral harnesses asserting one spec: fetch-JSON-into-a-sortable-table, debounced notes autosave (starter provided), a pomodoro timer with a completion sound, a seeded stale-cache delete bug to root-cause, a module split with byte-exact CSV export, and a shell-command system-info panel. The ts harnesses decode the Cmd/Sub wire format (`evals/harness-lib/cmdview.zig`); the zig harnesses ride the SDK's fake effects executor inside the workspace's own `native test` graph. `--track ts|zig` selects a lane; each track gets its current skills (`ts-core`+`native-ui` vs `native-ui`+`zig`), and `pnpm metrics` now reports per-track teaching-error encounters alongside first-pass compliance and the violation taxonomy (#119).
- **Transpiler: two real-app fixes the wave surfaced**: byte-element stores of computed values (`buf[i] = src[j]`) now emit with JS's exact ToUint8 wrap instead of stopping as invalid Zig, and records referenced from a declared text-input mirror union stay by value even when the core also stores its editor state in the Model — previously that pointer promotion silently broke `on-input` resolution (runtime view build and `native check`'s model contract alike) for any core keeping a `TextEditState` in its model (#119).
- **examples/soundboard-ts — the soundboard authored entirely in TypeScript + Native markup**: the launch-bar port of the Zig soundboard as three files of truth and zero Zig — `src/core.ts` (the committed catalog as const tables, REAL audio through the `Cmd.audioPlay` stream with the engine's local-then-URL cascade, the play-next queue, Copy Title on the clipboard, a motion-gated `Sub.timer` playback clock, and search through the full byte-splice text engine), `src/app.native` (the whole view: grid, album detail, songs library, context menus, the now-playing transport), and `app.zon`. An end-to-end suite (`zig build test-ts-core-e2e`) drives the shipping core and markup through playback, auto-advance, the stale-event window, volume, clipboard, search, record→replay, and a dispatch-latency budget; the README carries an honest ledger of where the port diverges from the Zig original (#119).
- **Generated TS wiring resolves the theme and the audio cache**: app.zon's `.theme` pack now reaches TypeScript apps (composed with the live system appearance), and the platform caches directory is resolved at launch so a core's URL audio playback caches under the conventional content-addressed path with no `cachePath` in the core (#119).
- **Transpiler emit-contract fixes**: the global `undefined` VALUE now emits the optional empty (`null`) — it previously emitted Zig `undefined`, uninitialized memory — and an early-exit null guard whose narrowed value goes unread emits a plain null test instead of an unused (uncompilable) capture (#119).
- **examples/system-monitor-ts — the system monitor authored entirely in TypeScript + Native markup**: the spawn-showcase port of the Zig system monitor as three files of truth and zero Zig — `src/core.ts` (the 2 s sampling cadence as a declarative `Sub.timer`, collect-mode `Cmd.spawn` for `ps`/`vm_stat`/`meminfo`, pure byte parsers over the collected stdout, the exact top-128-by-CPU selection, the confirmed SIGTERM action, and a runtime boot probe that discovers the host's sampler conventions where the Zig original switches at comptime — with the honest "no sampler for this OS" state when nothing answers), `src/app.native` (the whole view: chromeMsg-driven hidden-inset header, `<chart>` sparklines over the core's NaN-padded windows, the real table register with per-row context menus and controlled scroll, the modal confirmation), and `app.zon`. An end-to-end suite (`zig build test-ts-core-e2e`) drives the shipping core and markup through the probe cascade, the Zig example's committed real captures, the timer cadence with pause, search/sort, the kill round trip, and record→replay; the README carries an honest ledger of where the port diverges from the Zig original (#119).
- **Markup chart series bind f64 iterables**: `<series values="{binding}">` now accepts `[]const f64` model fields, decls, and fns alongside f32 — transpiled TS cores carry every number array as f64, so markup charts were unreachable from a TS model — narrowed per sample into the f32 chart pipeline in both engines, the validator, and `native check`'s model contract (#119).
- **The everyday string methods on core bytes — familiar spellings, byte-honest semantics**: TypeScript cores can now write `s.toUpperCase()`, `s.trim().toLowerCase().includes(q)`, `s.repeat(n)`, `s.padStart(w)`, `s.split(sep)`, `s.startsWith(p)`, `s.indexOf(t)`/`s.lastIndexOf(t)`, and `s.at(i)` directly on `Uint8Array` text. Every length/offset is a BYTE measure, search is byte-wise (`includes`/`indexOf`/`lastIndexOf` dispatch by argument type: bytes needle = substring search, number = the TypedArray element search), case mapping is Unicode 17 SIMPLE case mapping (locale-free, generated tables — 3.1 KiB in the binary — with invalid UTF-8 passing through unchanged), trim strips the exact JS whitespace set over UTF-8, and `split` returns a locally-owned `Uint8Array[]`. Native lowers each call onto rt kernel helpers; node runs the same methods from the same generated tables (devhost polyfill), so both runtimes produce identical bytes by construction — pinned by run-fidelity cases across Greek/Cyrillic casing, growth mappings, invalid-UTF-8 passthrough, repeat/pad edges, and split shapes, plus a machine-checked method matrix (#119).
- **The stays-out spellings teach their reason**: `charCodeAt`/`charAt`/`codePointAt`/`normalize`/`replace`/`replaceAll` on bytes teach the new NS1060 (byte text speaks the byte-honest method set), the locale family teaches NS1005, and the regex-taking methods teach NS1040 — never a bare "property does not exist". `trimAsciiSpaces` stays for LF-preserving line parsing; `.trim()` is the canonical whitespace trim (#119).
- **TS cores: generics, local function values, and the complete-language tail**: user-declared generic functions, interfaces, and type aliases now compile via per-call-site monomorphization from tsc's own resolved type arguments — one readable Zig fn per distinct instantiation (`pick__Task`, `pick__f64`), deduped, covering records/unions/arrays/optionals, recursion inside a generic, generics calling generics, and structural instantiation of generic types (`Box<Task>` → `Box__Task`); unresolvable call sites teach the new NS1053 (#119).
- **Const-bound local function values hoist**: `const scale = (x: number): number => x * 3;` (arrow or function expression) becomes an ordinary module-level fn when capture-free and fully annotated, usable by direct call (recursion included) or as an array-method callback (`xs.map(scale)`); captures, reassignment, storing/returning the value, and record-field calls teach the new NS1054 — and capturing a locally-owned array ends its ownership at the capture (NS1051 machinery) (#119).
- **The small-fry tail lands with node-byte-identical pins**: `for (const [i, x] of xs.entries())` (the destructured-pair loop form), `++`/`--`/assignments in provably order-exact value positions (`arr[i++]`, `const n = ++count`), `?.[i]` and `?.method()` optional-chain hops on supported receivers, plain `number`/`string` switch scrutinees (if/else chains with JS strict-equality and default-position semantics), and `typeof CONST` type-query aliases. Float-valued template holes stay deferred — there is no JS-exact f64 formatter in the runtime yet, and node/native divergence is never an option (#119).
- **TS cores: exceptions and data classes — the complete language, tier 2**: `throw`/`try`/`catch`/`finally` compile as deterministic control flow — a thrown subset value (one error shape per core, the new NS1057) unwinds through a native payload slot to the nearest catch, across helper calls and out of `.map`/`.filter` callbacks; `finally` lowers to a scoped defer running on every exit (control flow inside it teaches the new NS1058, JS's own no-unsafe-finally), the catch binding narrows once (`const err = e as ParseError;`), rethrow and nested try work, and an uncaught throw is a defined panic at the exported boundary — exactly where node's process would crash. Node-parity is pinned in the run-fidelity corpus, throw-mid-mutation of an owned array included (#119).
- **Data classes, no inheritance**: `class Task { fields; constructor; methods }` emits as a plain struct plus module-level functions; `new Task(...)` constructs a record-shaped value, `this` reaches fields and methods, and instance mutation (field writes, `this`-writing methods) follows the same local-ownership rule as arrays (NS1001/NS1051 at the boundaries). The class tail teaches by name: `extends`/`super`/`abstract` (new NS1055), accessors/statics/privates/`#`/class expressions/escaping `this` (new NS1056), generic classes (NS1053), `instanceof` (NS1041); class instances stay local values — Model storage teaches toward records (flagged follow-up) (#119).
- **Two reconcile potholes**: arrays OF byte buffers (`const parts: Uint8Array[] = []`) now route through array ownership — `parts.push(chunk)` on your own array works and runs node-identically (bytes VALUES keep their own discipline) — and a bare reference to a module-level function or const helper is a callback (`xs.map(encodeTurn)`, `xs.toSorted(byAscending)` — the same lowering as the arrow spelled inline), plus shorthand members in union literals (`{ kind: "range", v }`) (#119).
- **TypeScript apps are the `native init` default**: the scaffold is three files of truth and zero Zig — `src/core.ts` (logic), `src/app.native` (view), `app.zon` (manifest) — and the build detects the core from the tree (a `src/core.ts` transpiles at build time through generated wiring; `src/main.zig` stays the Zig core; both at once is a teaching error). The Zig template remains first-class via `native init --template zig-core` (#119).
- **`native dev --core`**: the TypeScript core-logic loop under node — dispatch Msgs as JSON lines, watch the model and effect transcript, run Sub timers and Cmd.delay on a virtual clock. Logic only, honestly not a renderer; `native dev` runs the real app (#119).
- **`native check` checks TypeScript cores**: a `src/core.ts` runs the @native-sdk/core subset checker first (NS diagnostics verbatim), then markup and app.zon as before — with a fresh model contract the markup pass type-checks bindings against the core's emitted model (#119).
- **Markup text input reaches TypeScript cores**: a core declares its own `TextInputEvent` mirror union and `on-input` matches it structurally, translating each runtime event into the core's union at dispatch — markup text field to TS `update` to re-render, end to end (#119).
- **Exported model helpers bind from markup**: an exported single-Model-parameter helper also emits as a Model declaration (`doneCount` binds as `{done_count}`), and `export const viewUnbound = [...]` emits the `view_unbound` lint opt-out — NS1031/NS1032 teach the collision and typo cases (#119).
- **TS cores: runtime fetch header values and journaled env deliveries** — the two gaps the ai-chat example surfaced, closed. `Cmd.fetch` header VALUES may now be runtime bytes (`{ authorization: bearerToken(model.apiKey) }` — header NAMES stay compile-time ASCII, NS1029/NS1030 bounds still gate what is knowable at build time and the engine err-arm rejects the rest); no wire change was needed — record 0x09 always carried values as length-prefixed byte fields built at dispatch time, only the emitter's literal-only rule and the node SDK's `FetchSpec` type moved. And the `envMsgs` channel now journals each launch delivery (an additive `.env` effect record: value in `payload`, arm name in `stderr_tail`, dispatch index in `key`), so replay feeds the RECORDED values with zero env reads — a session recorded with credentials set replays byte-identically on a machine where they are unset or different; journals without env records (older recordings) re-derive from the launch configuration exactly as before. `examples/ai-chat-ts` now sends a real `Authorization: Bearer <key>` header instead of the access_token query-parameter workaround, and its replay e2e drives both the unset-env and changed-env launches. Plus NS1051: an un-annotated spread local (`const turns = [...model.turns, next]`) now teaches its array-type annotation instead of the generic emit-time stop (#119).
- **TypeScript subset: grammar completeness**: the subset now means "TypeScript minus the ecosystem minus the purity violations" — never minus basic syntax. New in the mapping: `do...while` (body-first, `continue` re-tests, exactly node), labeled statements with labeled `break`/`continue` (loops and blocks, lowered to Zig labels), `default` arms on union-`kind` switches (the `else` prong over unnamed arms; dead-code defaults emit nothing), `**`/`**=` (JS pow corners pinned: NaN exponents, `±1 ** ±Infinity`, right-associativity), the shifts `<< >> >>>` and `~` (ToInt32 with the count masked & 31), the full compound-assignment family (`*= /= %= &= |= ^= <<= >>= >>>=` plus guarded `&&= ||= ??=`), unary `+`, const record destructuring (`const { total, done: doneCount } = stats;`), namespace imports over the core's own modules (`import * as util` — values, calls, and qualified types resolve to the flat emitted names), multi-counter for-inits and comma incrementors (`for (let lo = 0, hi = n; lo < hi; lo++, hi--)`), countdown incrementors (`i--`), hole-free template literals, `satisfies`, and the empty statement (#119).
- **Every exclusion now teaches**: twelve new rules close every generic-error hole — NS1039 (namespace aliases are dot-syntax, SDK intrinsics import by name), NS1040 (regexes), NS1041 (runtime type/shape tests: `typeof`/`in`/`instanceof`/`Object.*`), NS1042 (generators), NS1043 (comma/`void`/assignment-as-value), NS1044 (BigInt/Symbol), NS1045 (destructuring beyond const record fields), NS1046 (nested/stored function values and `?.()`), NS1047 (default exports, `export =`, value re-exports), NS1048 (loose `==`), NS1049 (`var`), NS1050 (generic declarations) — and NS1019 broadens to the full fixed-arity story (rest params, `arguments`, call spreads). `var` and generic helpers previously emitted broken Zig silently; both now stop with teachings, and same-file type/value homonyms are caught by NS1038 instead of colliding in the emitted module (#119).
- **The grammar matrix**: a new machine-checked suite (`packages/core/test/grammar_matrix.test.ts`) enumerates every statement, operator, expression, and declaration form of the language and pins each to its verdict (SUPPORTED emits and compiles under Zig; BANNED names its teaching rule; tsc-rejected stays tsc's), so the grammar can never grow a silent gap again. New run-fidelity corpora pin the node-vs-native behavior of every new mapping (pow corners, shift wrapping, `-0` preservation, do-while ordering, labeled-jump targets, default-arm matching, destructured aliases, `??=` on 0-vs-null) (#119).
- **Inference fixes surfaced by the matrix**: the float-demotion fixpoint no longer terminates one pass early (a two-hop chain — field → destructured alias → local — previously stranded a phantom NS1016 conflict), and shorthand `{ x }` properties now wire the VALUE symbol into inference (a shorthand from a host-boundary parameter previously kept a false integer proof and emitted mismatched Zig) (#119).
- **Stock-IDE support for TypeScript apps, working before the npm publish**: `native init` scaffolds `package.json` (the app's name plus an exact `@native-sdk/core` pin) and `tsconfig.json` (the checker's own compiler options, so editor errors match `native check` reality), and the CLI materializes `node_modules/@native-sdk/core` itself — a copy of exactly what the published package will contain — so VS Code et al. resolve `@native-sdk/core` and `@native-sdk/core/text` with full IntelliSense today. `native check|dev|build|test` keep the copy fresh (one info line on refresh) and `native doctor` reports version skew; once the package is on npm, a plain `npm install` writes identical content and the CLI recognizes the version and leaves it alone. None of it is build truth: builds transpile against the SDK checkout and work with node_modules deleted, tree detection still keys on `src/core.ts` alone, and the Zig template is untouched (#119).
- **@native-sdk/core is publish-shaped**: `files: ["sdk"]`, a typed exports map for `.` and `./text`, no bin and no runtime dependencies (the transpiler dependency moved to devDependencies), with a package test pinning the manifest shape. The soundboard-ts and system-monitor-ts example ports carry the same editor surface, and a ts-core e2e suite proves the whole contract with the real tsc: fresh scaffold and both ports typecheck with zero injected paths, and the transpiler still takes the core clean after `rm -rf node_modules` (#119).
- **TS cores: mutating array methods are legal on locally-owned arrays**: an array your function creates (a literal or a `.slice()`/`.map()`/`.filter()`/`.concat()`/`.toSorted()` copy) now takes the full mutating set — `push` (any seed, not just the empty builder), `pop`/`shift` (returning the find-miss optional), `unshift`, `splice` (JS index clamping, the removed array as its value), `reverse`, `fill`, in-place `sort` (the stable toSorted machinery applied in place), and indexed writes — with node-byte-identical semantics pinned by a new run-fidelity corpus (parser stacks, splice corners, shift/unshift order, sort stability, pop-on-empty) and a machine-checked mutation matrix beside the grammar matrix (#119).
- **Teaching errors now fire only at the true semantic boundaries**: shared data keeps NS1001/NS1022 (both rewritten around ownership, NS1022 naming the now-legal `const copy = xs.slice(); copy.sort(cmp);` idiom), and the new NS1051 teaches mutation after an escape — returned from a callback, passed to a call, stored, or aliased — with the escape kind and line named; an escape inside a loop gates the whole loop body, and early-exit returns stay legal (#119).
- **TypeScript cores reach the full app surface**: markup sliders and split dividers deliver their applied 0..1 fraction to a core's one-number float arm (`on-change="scrubbed"` — scrub-to-seek from markup), controlled scroll round-trips through a core-declared `ScrollState` mirror, and the generated wiring detects five host-event channels from plain exports — `frameMsg` (presented frames), `keyMsg` (the app-level key fallback), `appearanceMsg` and `chromeMsg` (system appearance and hidden-titlebar geometry as Msg arms), and `envMsgs` (launch environment variables as journaled boot Msgs) — plus `app.zon` `.assets.images` registered at launch as the `ImageId`s markup avatars bind (#119).
- **Export lists and value re-exports compile in TypeScript cores**: `export { a, b as c }` and `export { x } from "./m.ts"` now bind real names over existing declarations in the flat emitted namespace — un-renamed entries export the declaration itself, renames emit a `pub const c = a;` alias, and re-export chains resolve end to end (node ≡ native, pinned by run-fidelity). Renamed entry-module helpers join the markup binding surface under their exported names; NS1047 narrows to the genuinely unsound tail (`export default`, `export =`, `export * from`, renamed generics/classes, wiring config, SDK re-exports), and NS1014/NS1038 keep entry points and name uniqueness honest across the new forms (#119).
- **Heterogeneous throws with a narrowing catch**: a core may now throw several distinct kind-tagged shapes — the checker collects them into an implicit thrown union (or a declared union whose arms match), the payload slot is that union, and `catch (e)` narrows it with plain kind tests (`if (e.kind === "parse")`) with no `as` ceremony; rethrow re-raises the bound value, narrowing works across callback boundaries, and NS1057 narrows to genuinely unsound throws (untagged values in a mix, tag collisions, untyped escapes, `new Error`). All pinned node ≡ native by run-fidelity (#119).
- **Class statics and erased privacy**: `static` methods lower to receiver-less module functions under the class's mangled names (`Task.fromRow(...)` -> `Task__fromRow`), `static readonly` fields with initializers become module consts (`Task.LIMIT`), and `private`/`protected` keywords are accepted and erased (tsc enforces them at the type level — their whole meaning). Mutable statics teach NS1010 (module state), `this` inside a static member teaches toward the class name, and `#`-fields stay taught; NS1056 narrows accordingly. Pinned node ≡ native by run-fidelity (#119).
- **Three mutation loosenings**: `xs[xs.length] = v` on an owned array is a push (the one growth shape; compound forms stay taught), a reassigned `let` stays owned when every assignment installs a fresh owning construction (each reassignment resets the emitted builder), and passing an owned array into a `readonly T[]` parameter is a BORROW when the callee provably only reads it (coinductive analysis — recursion over borrowed slices stays legal; returns, stores, casts to mutable, and onward passes into mutable positions still end ownership). NS1001/NS1051 copy updated; mutation matrix rows moved and extended; all pinned node ≡ native (#119).
- **Accurate teaching for the Array statics (NS1059)**: `Array.from`/`Array.of`/`Array.fromAsync` now teach their own construction rewrites (the literal, the spread copy, the push-builder loop) instead of the generic runtime-shapes copy; `Array.isArray` keeps NS1041 — it really is a runtime type test. Comma expressions in value position stay taught (NS1043): the split-statement lowering is only JS-order-exact in the pinned positions, so they did not fall out of the machinery for free (#119).

### Improvements

- **The components reference is markup-first**: every component page leads with its Native markup sample (all fences validated against the live `native markup check`), interactive samples show the core side in both authoring languages behind the TS | Zig toggle (accordion, checkbox, radio, dialog, input, scroll, select, slider, split, chart), and the builder form moves to a consistent "Programmatic construction (Zig)" section at the end of each page — real API docs, framed as the Zig tier's programmatic alternative. The section index tells the one-language story, and four samples that shipped unnamed text controls now carry accessible names (#119).
- **The TypeScript authoring package is `@native-sdk/core`**: the transpiler package moved from `packages/ts-app-core` to `packages/core` under its real npm name — cores were already importing `@native-sdk/core`, and the dev-harness resolver now maps that one specifier straight onto the package's own SDK module (#119).
- **TS-first docs with a TS | Zig toggle**: code samples on the flagship pages (Quick Start, App Model, Native UI, State & Data Flow) show TypeScript first with the Zig form one tab away — the reader's language choice is remembered site-wide — and the new [TypeScript Cores](https://native-sdk.dev/typescript) page covers the app-core subset, Cmd/Sub effects, text-is-bytes, the node dev loop, capacity knobs, and the eject story. Toolkit-extension pages stay Zig on purpose: that tier is the machinery itself (#119).
- **Docs code presentation**: the TypeScript | Zig code toggle now renders as the same segmented pill control as the component previews' Default | Geist theme-pack toggle (one shared primitive, identical in dark mode), and code samples can carry a filename header — a file glyph plus the path (```` ```ts:src/core.ts ````), integrated into the toggle's header bar opposite the segments — applied across the quick-start, TypeScript, app-model, native-ui, and config pages' complete-file samples; copied markdown renders the path as a labeled line above a plain fence (#119).
- **Markup binds your model's field names exactly as you wrote them**: TypeScript cores now emit Zig with the TS spellings intact — fields, exported single-model helpers, Msg payload records, and locals alike — so `nextId` binds as `{nextId}` and `doneCount` as `{doneCount}`, ending the dual-naming rule (camelCase in core.ts, snake_case in app.native) that every author had to hold in their head. Zig cores are untouched: their fields were already the names markup binds. The whole pipeline follows from the one change — the model contract, `native check`'s typed pass, both markup engines, hot reload, and the eject story (the emitted module now mirrors your source, and markup keeps binding the same names after you adopt it) (#119).
- The TS-track host surfaces that matched emitted names structurally now speak the TS SDK spellings (`timestampMs`/`intervalMs`, `colorScheme`/`reduceMotion`/`highContrast`, `tabsProjected`, the audio arm's `positionMs`/`durationMs`), and the declared scroll-state mirror accepts the canvas spelling or the TS spelling — never a mix (#119).
- NS1031 collisions are now exact-name collisions (`doneCount` the helper vs `doneCount` the field); `viewUnbound` entries were already the TS names and stay so. Scaffold templates, both ports' views, the ai-chat view, docs, and the skill teach the one rule (#119).
- **zig-core starter parity**: `native init --template zig-core` now scaffolds the same app as the TypeScript template — counter, a ticking switch driving a repeating 1s `fx.startTimer`, a Stamp button reading the journaled clock (`fx.wallMs`), a bindable `total` helper, and the matching markup — with generated full-loop tests covering the timer and clock seams; the quick-start code toggle now shows both starters verbatim (#119).

### Bug Fixes

- **Packaging fails loudly when signing fails**: `native package --signing adhoc|identity` no longer exits 0 while shipping an unsigned bundle — output paths with spaces (`--output "My App.app"`) now sign correctly (the signing pipeline execs argv arrays instead of shell strings, which also unbreaks spaced paths and spaced identities in the notarization helpers), every signed bundle must pass `codesign --verify --deep --strict` before packaging succeeds, any codesign failure stops the package with codesign's own reason, and the package report proves the outcome with a `signing: adhoc (signed, verified)` line (#118).
- **Per-thread memory no longer scales with the canvas scratch**: the render planner's fixed scratch buffers lived in static thread-local storage, so on Windows every thread the process spawned (window host, COM, accessibility, workers) privately committed a full ~6.5 MB copy — most of a small app's working set. The scratch now allocates lazily on the one thread that actually plans frames: a scaffolded counter app's private working set drops ~4x, its `.tls` section shrinks from ~6.5 MB to under 200 bytes, and the executable itself is ~6.5 MB smaller. Linux and macOS binaries shed the same per-thread TLS block (#117).
- **Transpiler: a ternary initializer under null-guard fusion parenthesizes**: `const x = c ? f(a) : g(a); if (x === null) <exit>` lowers to Zig's `orelse` fusion, and the conditional's if/else expression now wraps in parens — bare, the `orelse` bound to the ELSE arm alone (a type error at best, the wrong value at worst). The same guard covers `??` over a ternary left side; pinned in the conformance corpus and the node/native run-fidelity corpus (#119).

### Contributors

- @ctate
- @SunkenInTime
- @sepehr-safari
<!-- release:end -->

## 0.4.4

### New Features

- **Native-only host builds (Windows)**: the build graph now infers web use from app.zon — a `.frontend` block, the `"webview"` capability, a `.shell` webview view, or the Chromium engine — and an app that declares none of them compiles its Windows host without the embedded WebView layer: no WebView2 header, no `WebView2Loader.dll` installed, staged, or referenced by the executable. A new `.webview_layer = "auto"|"include"|"exclude"` manifest field (and `-Dweb-layer`) overrides the inference, an exclude that contradicts a web declaration is rejected at validate, configure, and package time, and a native-only build that reaches webview creation at runtime fails fast with a teaching `WebViewLayerNotBuilt` error. `native check` and the package report print the web-layer verdict, and a CI cross-audit asserts the presence/absence of the loader reference in real cross-compiled executables (#107).
- **Native-only host builds (Linux)**: the WebKitGTK compile seam mirrors the Windows one — an app whose app.zon declares no web use compiles its GTK host with `NATIVE_SDK_ALLOW_WEBKITGTK_STUB`, so the executable neither links `webkitgtk-6.0` nor references any `webkit_`/`jsc_` symbol, building needs no WebKitGTK development package, and users need no `libwebkitgtk` at runtime. The web-layer auditor (`tools/audit_web_layer.zig`) grew a hand-rolled ELF reader (DT_NEEDED entries + dynamic symbols) that CI runs both ways: the native-only fixture must scan clean even with the dev package installed, and the Linux canvas smoke now builds on a runner without WebKitGTK at all. `native package` refuses to package a WebKitGTK-linking binary under a native-only decision, record→replay and automation-driven sessions are pinned on native-only apps, and the macOS GPU dashboard smoke asserts a native-only app spawns zero WebKit helper processes (#110).

### Improvements

- **Zig 0.16 guidance**: a new `zig` skill (`native skills get zig`) maps each pre-0.16 std idiom's compile error to the current one — `std.Io` file IO and writers, unmanaged `ArrayList`, `main(std.process.Init)`, spawning, clocks, `{t}`/`{f}` formatting, `build.zig` modules — with the same content for humans as the docs' Zig 0.16 Notes page; the native-ui skill carries the short table, and a failing `native build|test|dev` now points at the catalog when std members come up missing (#105).
- **Lazy Linux WebView startup**: GTK windows now create only GTK chrome at window creation and materialize the main `WebKitWebView` on first web use, so canvas-only apps do not start WebKit processes on Linux; child-WebView bridge responses no longer require a main WebView to exist (#106).

### Contributors

- @ctate
- @WhiteHades

## 0.4.3

### Improvements

- **Linear-light edge blending**: anti-aliased fringes on opaque rounded rectangles, path fills, and strokes now composite through a linear-light coverage path, removing the dark rims that sRGB blending produced on curved geometry while keeping opaque interiors, glyph coverage, and translucent overlays byte-identical (#89).

### Bug Fixes

- **Single-line fields handle overflowing values**: text, selection rects, composition underlines, and the caret now clip to the field's content rect, and a horizontal scroll offset keeps the caret visible — typing past the edge scrolls the value, Home scrolls back, and deleting never leaves trailing emptiness. Covers text fields, inputs, search fields, and comboboxes; values that fit render exactly as before (#90).
- **Cross-drive apps on Windows**: `native dev|build|test` no longer fails with `expected path relative to build root; found absolute path` when the app and the npm-installed SDK live on different drives — the generated build graph now bridges volumes with a `.native/sdk` directory junction (no admin rights needed) and keeps the zon dependency relative; the junction is retargeted automatically when the SDK moves or upgrades. Where the bridge cannot apply (`native eject`, full-shape `native init`, or a filesystem that refuses junctions), the CLI explains the cross-volume constraint and both ways out instead of writing a build Zig would reject (#92).

### Contributors

- @ctate
- @fleeting-zone
- @kvnwdev

## 0.4.2

### Improvements

- **Windows rendering is DPI-aware and sharper**: Windows apps now declare Per-Monitor V2 DPI awareness, each window carries its own device scale, and canvases, native child views, hidden-titlebar sizing, and explicit WebView frames re-render/re-round correctly when moved across mixed-DPI monitors (#81).
- **Smoother canvas geometry**: rounded-rect fills and strokes now render through continuous coverage while eligible hairline borders snap to crisp device-pixel columns, so arcs stay anti-aliased and 1px borders stay sharp under the default house and Geist packs (#81).
- **Canonical package and documentation metadata**: npm package metadata, release automation, docs, templates, and examples now point at the renamed `vercel-labs/native` repository and `native-sdk.dev`; `version:sync` stamps repository/homepage metadata into platform packages and `version:check` rejects drift before publish (#78, #80).

### Bug Fixes

- **Windows embedded WebView is real from a plain checkout**: the WebView2 SDK header and loader are vendored under `third_party/webview2/` (BSD-licensed), every build graph puts the header on the include path, and the host now refuses to compile with the WebView layer silently stubbed — previously every Windows build shipped the stub and WebView loads reported `WebViewNotFound` at runtime (#86).
- **WebView2 host conformance fixes**: a missing lambda capture in the bridge message handler, a mingw-compatible WRL event-handler factory, an `EventToken` shim, and STA COM initialization on the host thread let WebView2 environment creation and bridge messaging run on Windows (#86).
- **WebView2Loader.dll ships with the app**: `zig build` installs the architecture's loader next to the executable, `zig build run` resolves it during dev runs, generated frontend/package commands carry `NATIVE_SDK_PATH`, and `native package --target windows` includes the loader in the artifact (the Evergreen WebView2 runtime itself is preinstalled on current Windows) (#86).
- **Checkbox marks use the vector core**: checked boxes now draw one stroked polyline with round caps and joins instead of two aliased diagonal lines, and stroke caps ride the GPU packet path so the host and reference renderer agree (#87).
- **Path geometry lifetimes are owned by the builder**: chart, spinner, and checkbox path commands no longer borrow threadlocal frame scratch, so separately emitted trees cannot alias each other's path elements (#87).

### Contributors

- @ctate

## 0.4.1

### Bug Fixes

- **npm package assets**: Ship the SDK's root `assets/` directory in `@native-sdk/cli` so installed packages include `assets/native-sdk.manifest`, the default macOS icon, and entitlements needed by generated apps (#72, #75).

### Contributors

- @ctate
- @lzitser23

## 0.4.0

### New Features

- **zero-native is now the Native SDK**: The toolkit, CLI, and packages are renamed end to end — the CLI binary is `native`, the Zig module and build helper are `native_sdk` (`native_sdk.addApp`, `native_sdk.addMobileLib`), the embed C ABI prefix is `native_sdk_*`, and the npm CLI package is `@native-sdk/cli`.
- **Native-rendered apps by default**: `native init` scaffolds a native-rendered app — a declarative `.native` markup view plus Zig logic on the `UiApp` runtime (a `Model`, a `Msg` union, `update`, and a view) — with web frontends still available via `--frontend next|vite|react|svelte|vue`.
  - Native markup: HTML-inspired views with flex layout, `{bindings}` to model fields and functions, typed `on-*` message dispatch, `for`/`if`/`else` structure tags (multi-child `for` bodies, `<else>` empty states), and keyed identity; a deliberately closed grammar keeps logic in Zig.
  - Comptime compilation: views compile at build time into direct field access — release binaries carry no parser, and markup or binding mistakes are compile errors with line and column.
  - Hot reload: dev builds watch every `.native` file — imported components and fragments embedded in Zig views included — and update the running window in place, preserving model state, selection, and widget identity.
  - Expressions in bindings: arithmetic, comparisons, boolean logic, string concatenation, and a closed 17-function formatting library (`fixed`, `thousands`, `date`/`time`, `pad`, `plural`, ...), evaluated bit-identically by both markup engines; string-producing model functions bind directly through the build arena.
  - Cross-file components: `<import>` splices template files (transitively, with cycle and duplicate diagnostics), template args take literal defaults, `<slot/>` marks where use-site children land, and `native eject component` transfers a library composite's canonical source into your app exactly once.
  - `canvas.Ui`, the programmatic builder under the markup: structural widget identity, typed message handlers, flex-first layout, and per-element `opacity`/`transform` render channels for animated composition.
- **The model–view contract, checked in both directions**: `native check` verifies every binding path, iterable, key, message tag, payload type, and expression in every `.native` file against the app's reflected `Model`/`Msg` surface in milliseconds — with did-you-mean suggestions and a dead-state lint for model fields and messages no view uses.
- **Markup tooling**: `native markup check` (instant validation with positions), a language server (diagnostics, completion, hover), a TextMate grammar with editor setup, `native markup dump` over the canonical serialized document format, and the `native-ui` agent skill — the complete authoring reference, served through the skills CLI.
- **Two-way tooling**: `native automate provenance` reports where a live widget was authored (file, byte span, template instantiation chain), and `native automate edit` writes minimal-diff attribute and text edits back into the markup source — validated before anything touches the file, with hot reload closing the loop.
- **Full component catalog**: every built-in component is expressible in markup — tabs, tables, dialogs, drawers, sheets, selects, comboboxes, accordions, menus, badges, avatars, tooltips, inputs, and more — implemented in both engines with parity tests, alongside new composites in markup and Zig:
  - Charts (`<chart>` / `ui.chart`): line, area, bar, and band series drawn through the vector path pipeline with design-token colors, deterministic downsampling past 256 points, axis labels on a nice-step lattice, and pointer hover details.
  - Markdown (`<markdown>` / `native_sdk.markdown`): a GitHub-flavored subset — headings, inline styles, links, lists, task lists, fenced code, blockquotes, pipe tables, autolinks, and model-driven collapsibles — that degrades malformed input to text and never fails a build.
  - Disclosure trees with the full ARIA tree keymap, steppers and timeline items, input groups with focus-within rings, chat bubbles with reaction pills and thread-width caps, and a `ui.nav` push/pop page container with stable per-page state.
  - Resizable split panes with model-owned fractions, keyboard and assistive resize, and optional eased animation on model-driven moves.
  - Windowed virtual lists: viewport-sized widget budgets at 100,000 items, variable row extents that converge to measured truth without visible jumps, tail anchoring for chat transcripts, and `on_reach_end`/`on_reach_start` for infinite fetch and history loading.
  - Anchored floating surfaces (dropdowns, selects, popovers) that float above the tree with edge auto-flip; dismissal (Escape, click-outside, assistive dismiss) is a Msg the model owns, and focused selects get the full open/navigate/commit keymap.
  - Vector icons: an SVG stroke-icon subset parser, 50 curated built-in icons, leading or trailing icon slots on buttons, toggle chips, list and menu rows, badges, and timeline items, app-registered icons comptime-parsed from your own SVGs, model-bound icon names, and a loud missing-icon fallback.
- **Text engine**:
  - Inline styled spans — weight (resolved to real faces), italic, monospace, color tokens, underline, strikethrough, size scale, per-span backgrounds, and hit-testable links — wrap as one paragraph in Zig and markup alike.
  - Honest single-line text: unwrapped text elides with a trailing ellipsis by default, an `overflow` policy knob keeps the deliberate hard cut available, and word wrap is an explicit opt-in — paint always agrees with measurement.
  - `heading`/`display` typography rungs on the token ladder, first-class text alignment, and fixed grid column counts.
- **Selection and clipboard**: cmd/ctrl+C/X/V in editable fields through the platform clipboard, click-drag selection with copy on static text (surviving rebuilds, exposed to semantics and automation), and clipboard effects for app code.
- **Interaction model**:
  - Presses fall through to the nearest pressable ancestor, so any element with a handler is a real hit target — nested pressables resolve to the deepest one, and text selection still works inside pressable rows.
  - Press-and-hold, double-click, Enter as a list row's primary action, and an app-level key fallback (`Options.on_key`) with pinned precedence — quiet list rows stay transparent to app-owned selection models.
  - Source-driven `autofocus`, observable typed scroll events (`on_scroll`), a built-in search-field clear affordance, and a quiet-hover style knob for content tiles.
- **Effect system**: the update loop's command half — `update` gains an effects channel of bounded, key-addressed effects that deliver exactly one terminal Msg each and are fully testable against a deterministic fake executor:
  - `fx.spawn` runs subprocesses with streamed lines or whole-output collect mode (stderr tail included), raisable per-effect line bounds, and cancellation; `fx.fetch` runs HTTP(S) requests with an explicit failure taxonomy, timeouts, and a streaming response mode for line-oriented endpoints.
  - `fx.readFile`/`fx.writeFile` persistence, `fx.startTimer`/`fx.cancelTimer`, `fx.writeClipboard`/`fx.readClipboard`, `fx.registerImageBytes` for runtime images, `fx.closeWindow`/`fx.minimizeWindow`, and the `init_fx` boot hook so loading states are in the very first paint.
  - A facade time API (`nowMs`, `monotonicMs`) plus `Clock`/`TestClock` seams for deterministic time-dependent logic.
- **Audio, end to end on five platforms**: `fx.playAudio` with full transport (pause, resume, stop, seek, volume), real decoded durations, position ticks, and honest completion and failure reports — AVFoundation on macOS, Media Foundation on Windows, GStreamer on Linux, and the experimental mobile hosts on iOS (AVFoundation) and Android (MediaPlayer).
  - Streaming with a verified track cache: URL sources resolve local file, then size-verified cache, then progressive stream (filling the cache in parallel for the next play), with honest `buffering` states and explicit failures — never a silent stall.
  - Real spectrum analysis on macOS, Windows, and Linux: 32 log-spaced bands at ~25 Hz from the app's own playback, journaled at the effect boundary so record/replay repaints identical bars; hosts that cannot analyze report the capability honestly instead of fabricating bands.
- **Images**: a platform decode seam (CGImageSource, gdk-pixbuf, WIC) so the toolkit bundles no image decoders; runtime image registration renders through every path — GPU packets, software presentation, and screenshots — with pixels riding an out-of-band upload channel so image-bearing frames stay on the GPU path; avatars take a bound image with initials fallback.
- **Windowing and chrome**: model-declared secondary windows (presence is visibility; a user close dispatches a Msg), enforced window minimum sizes, and present-before-show so a canvas window never appears blank.
  - Titlebar control on all three desktops: `hidden_inset`, a tall unified-toolbar variant, and fully `chromeless` styles; markup `window-drag` regions; and an `on_chrome` hook carrying the real overlay insets and control-cluster frames — with real system window controls preserved on Linux client-side decorations and Windows DWM caption buttons.
  - Native context menus, declared per widget in Zig or markup (`<context-menu>`): the real OS menu where one exists, an anchored canvas surface elsewhere, editable-text cut/copy/paste defaults, and full automation support for enumerating and invoking items.
  - A menu-bar status item with model-driven title and menu; canvas and WebView panes composed in one window; adoption of app-owned native views into the layout (`adoptViewSurface`); and native scroll drivers on macOS that give every scroll region OS momentum, rubber-band overscroll, and the system overlay scrollbar with zero app code.
- **Experimental iOS and Android host tiers — the toolkit owns the entire mobile app**: complete UIKit and Android hosts ship in the SDK over the embed C ABI, an app project carries zero host code, and embedding a hand-written host stays first-class.
  - `native dev --target ios|android [--device name]` builds, installs, and launches on a simulator or emulator and streams the app log; `native package --target ios` emits an archive-ready Xcode project and `--target android` a complete generated host project plus a debug-signed APK — no build-system project, no plugin matrix.
  - Touch, soft keyboard, and IME forwarding; safe-area and keyboard insets on the window-chrome channel plus host-reported form factor; platform text metrics; platform audio and image decoding; and damage-rect rendering so a keystroke repaints and uploads only the changed region instead of the whole screen.
  - Declared platform chrome: apps project a tab set and primary action as a real system tab bar, and a model-owned page stack drives real push/pop transitions with the system edge-swipe back gesture — navigation state stays in the model and replays deterministically from the Msg journal.
  - The soundboard ships the proof: one codebase, a desktop composition plus a compact phone shell selected by the host-reported form factor, running on the simulator via `native dev --target ios`.
- **Theme packs and design tokens**: named packs — the default register plus `geist`, the design register of the bundled Geist type family — compose with the live system appearance; interaction-state formulas, control metrics, and focus-ring geometry are all token-stated; new `success`/`warning`/`info` semantic color tokens; the stock theme follows the OS light/dark, high-contrast, and reduce-motion settings live; modal scrims blur the content behind them for real; app-registered TrueType fonts resolve everywhere a font id rides.
- **Deterministic rendering core**: a bounded, std-only TTF parser inks real anti-aliased glyphs (bundled Geist and Geist Mono) on every headless path — screenshots, mobile embeds, pixel goldens — while layout measures exactly what gets inked; an allocation-free vector rasterizer with bit-identical cross-platform coverage draws paths, icons, and charts.
- **Automation and testing**: `native automate` gains `assert` (regex polling against the accessibility snapshot), deterministic PNG screenshots, per-stage frame profiling (`profile on`), and widget verbs for hold, secondary click, context-menu invocation, drag, wheel, and tray actions.
  - Deterministic session record and replay: journal every platform event and effect result, then re-run headlessly with checkpoint verification (`native automate record` / `replay --verify`).
  - `native init` scaffolds a CI workflow: null-platform tests for every frontend plus a Linux automation smoke that drives the app's real binary under Xvfb.
- **Accessibility as machine checks**: unnamed interactive controls, icon-only controls without labels, and misused roles are validation errors (degradations report as warnings; `--strict` promotes); a deterministic tree-level audit catches labels that resolve empty at runtime, focus-unreachable widgets, and duplicate sibling labels; and assistive actions actuate through the same activation paths keyboard users take instead of reporting success on nothing.
- **Showcase examples**: calculator, notes (folders, trash, context menus), soundboard (a real music library with playback and search), deck (a radically re-skinned sibling proving theme packs and chrome passes), system-monitor (live effects-driven sampling), markdown-viewer (split-pane editor and preview), and feed (a 100,000-post virtual list) — each with a deterministic test suite, and a prepared real-music catalog that streams out of the box.
- **Docs site**: a full Components section (34 pages) where every preview is rendered offscreen by the engine itself and upgrades on hover to a live engine instance running in-page via a ~306 KB (gzip) wasm build; attribute tables generate from the validator's own vocabulary so docs cannot drift; the whole site restructured native-first with new State & Data Flow, App & Runtime, Theming, and Testing in CI pages.
- **Zero-config toolchain and distribution**: `native dev|build|test|check` work in a directory holding only `app.zon` and `src/` (`native eject` writes the build files exactly once when you want to own them); the pinned Zig toolchain downloads on consent with checksum verification; and `@native-sdk/cli` installs from npm with zero scripts — eight platform binaries plus the SDK source, so `native init && native dev` work offline right after install.
- **One-image app icons**: drop a single square PNG or SVG in `assets/`, and `native package` generates everything — a masked, grid-correct macOS `.icns`, a multi-size Windows `.ico`, Linux hicolor PNGs, and iOS/Android catalog icons — with exact linear-light downscales, teaching errors for bad sources, and no external tools.

### Improvements

- **Performance — frame cost scales with what changed, not view size**:
  - GPU packets ride a compact binary encoding (~10x smaller than JSON, ~40x effective capacity — text-heavy frames no longer silently fall back to software rendering), steady-state frames ship incremental patches (~20x less wire per interaction), and repaints derive per-change dirty-rect lists so pixels between two far-apart changes stay retained.
  - Per-command raster caches stop re-rasterizing unchanged content (host draw p50 dropped an order of magnitude on animated views); frame planning and widget reconciliation moved from quadratic scans to indexed lookups (end-to-end interaction p50 improved ~2.3-3.2x on large views); backdrop blur cost no longer scales with radius; a click emits one display list instead of three.
  - Launch to glass: the first canvas frame presents before the event loop starts, first paint rasterizes across cores, the main WebView is created lazily, and warm launches measured 150→120 ms on the heaviest showcase app; `NATIVE_SDK_WINDOW_TIMING=1` prints a per-phase launch breakdown.
  - Occluded windows throttle to a ~1 Hz heartbeat instead of spinning the frame clock (spectrum reports pause too); accessibility publishes only when the tree actually changed and defer off the input-to-glass path; frame pacing delivers exactly one event per display interval; input latency is measured to the responding present, honestly.
  - `zig build bench-render` runs deterministic interaction scenarios against committed per-scenario budgets, and a percentile GPU perf check gates first-frame and input-to-present latency in CI.
- **Component fidelity**: the built-in components land a refined default look, verified pixel-for-pixel in CI under both theme packs.
  - Measured control geometry and state washes, ring-offset focus rings, flat buttons with a quiet destructive treatment, segmented button groups rendered as one bar with collapsed seams, compact badges, and hairline tables.
  - Reworked accordion, tabs, alert, and card treatments with sensible per-kind layout defaults; skeletons pulse and the caret blinks; select menus read like menus (row highlight, trailing checkmark for the committed option).
  - Native cursor conventions (the pointing hand is reserved for true links), flat list rows, axis-aware separators, and edge-pinned scrolling with opt-in rubber-band overscroll.
- **Capacity and honesty**: per-view widget budgets quadrupled to 1024 nodes (command, glyph, and text budgets raised to match) with headroom telemetry in every snapshot; explicit `width`/`height` are definite bounds; layout overflow is diagnosed, dispatch errors degrade and record instead of exiting the app, and every effect-facing type and constant is exported from the `native_sdk` facade.
- **Teaching validation**: handlers on elements that can never receive them, `gap` on stacking containers, `wrap` on non-text elements, and literal glyphs outside the bundled font's coverage are all positioned teaching errors, enforced identically by the validator, both engines, and the language server.
- **Desktop parity**: the Linux and Windows hosts reach the macOS seam contract — app timers, appearance events, window options at create, interactive window moves, IME composition on Windows, and hidden-titlebar fidelity with real system controls; CI gains Windows canvas and effects smokes under Wine, a headless Linux canvas smoke, and a containerized Linux live-truth harness driving every showcase app on real GTK.
- **Observability**: automation snapshots report the live present path and mode, patch sizes, fallback reasons with byte counts, budget headroom, audio state, tray contents, and per-stage frame percentiles while profiling; `NATIVE_SDK_GPU_DRAW_TRACE=1` attributes every present.
- **Docs and skill accuracy**: the code-signing page documents the real ad-hoc Gatekeeper experience, form-control and picker docs match what the engine ships, the keyboard and interaction seams are documented where developers look, and stale commands and API shapes were fixed across the site.
- **Example polish**: showcase headers carry only working controls under hidden-inset titlebars, the soundboard adopts desktop list-selection conventions, notes gains Recently Deleted and dialog autofocus, the deck refined its hardware identity across feedback passes, system-monitor lands the standard settings flow, and every showcase app ships the zero-config scaffold shape with a real neutral default app icon.
- **Contributor workflow**: changelog fragments (`changelog.d/`) end merge conflicts on this file, and `scripts/gate.sh` runs a tiered local gate that scales with the diff.

### Bug Fixes

- **Input and focus**: clicked and tabbed-into fields always show a caret (drawn in the field's own ink, readable in every scheme); Escape dismisses surfaces opened from non-focusable triggers; Enter inserts a newline in textareas (the primary chord submits); programmatic focus is quiet on non-editables; composite rows hover, point, and press as one surface; cross-centered overflow distributes evenly.
- **Model-driven control state**: sliders, exclusive selections, and toggle-button chips follow the model when the source moves (a live drag is never yanked); disabled selection controls render disabled; idle disabled buttons no longer wear an accent outline.
- **Rendering correctness**: pixel snapping no longer wraps exact-fit text or elides exact-fit badges; packet text honors engine line breaks; text bounds cover glyph ink; mono runs read as monospace on every headless path; avatar initials center; the spinner actually spins and sizes to the icon register; offscreen screenshots clear with live tokens; render animations invalidate only the affected commands; one invalid UTF-8 byte can no longer hang the renderer; budget overflows apply atomically instead of tearing the retained tree.
- **macOS**: Debug builds no longer abort at launch on an SDK sanitizer trap; `resizable = false` is honored; frames keep pumping during live resize and menu tracking; occluded windows keep presenting and flush instantly on reveal; quitting mid-playback no longer crashes; the Chromium (CEF) host builds and runs again, verified live with child WebViews.
- **Windows and Linux**: Windows apps launch on real Windows (common-controls manifest, dynamic task-dialog resolution) and builds link again; embed input timestamps and network error classification fixed on Windows; Linux audio no longer sticks in a buffering state; a saturated frame loop no longer freezes GTK windows; runtimes heap-allocate in every runner, fixing startup crashes under default stack limits; GTK initial allocation and overlay z-order fixed.
- **Packaging**: signed bundles keep a valid code signature; packaged apps read their bundled assets and show their display name in the menu bar; archives are labeled with the real optimize mode; unbundled dev runs fall back to the embedded default Dock icon.
- **Automation and CLI reliability**: commands queue with delivery acknowledgments instead of overwriting a single slot; a landing command wakes an idle app (~4 ms consumption); CLI and app handshake on a protocol version, and stale publishers or binaries are refused loudly; parseable payloads land on stdout; clicks aim at the rendered control, not its stretched box; `native dev` runs Debug so hot reload is actually compiled in; no CLI verb exits silently, and `--help` exits 0 everywhere.
- **Hardening**: the markdown renderer survives hostile input (three quadratic blowups fixed, a fuzz corpus added); large models neither exhaust the comptime branch quota nor ride the stack (`UiApp.create` constructs in place); mobile embed libraries stage per target so cross-target builds cannot poison each other; oversized inline window sources fail loudly instead of leaving a blank window; docs live previews build, lay out with the selected pack's tokens, animate, and route keyboard shortcuts correctly.
- **Measured-label controls no longer elide under pixel snapping**: a control sized exactly to its measured label — toggle chips (the system monitor's "PID" sort chip painted "PI…"), buttons, segmented controls and tab triggers, menu and list rows, tooltips, checkbox/radio/switch labels, hug-sized status bars — could lose a fraction of a pixel to render-time geometry snapping and swap real glyphs for an ellipsis. Every measured-label intrinsic width now rounds UP to the snap grid (the badge rule from the previous round), the switch additionally reserves its snapped track extent, and themes without geometry snapping stay bit-identical.

### Contributors

- @ctate

## 0.3.0

### New Features

- **Keyboard shortcuts**: Add app-level keyboard shortcuts with manifest and runtime configuration, native delivery to Zig `Event.shortcut`, and typed JavaScript `window.zero` shortcut events (#62).
- **Manifest-driven runner shortcuts**: Load `app.zon` shortcuts automatically in generated runners, with a `RunOptions.shortcuts` override for apps that build shortcut lists in Zig (#62).

### Improvements

- **Shortcut documentation and validation**: Document the `app.zon` shortcut schema, portable key names, modifier behavior, backend support, and validation limits (#62).
- **Windows WebView2 child bridges**: Enable bridge-enabled trusted child WebViews on Windows WebView2, bringing that backend closer to the macOS and Linux system WebView behavior (#62).

### Bug Fixes

- **Shortcut matching and delivery**: Fix shortcut modifier handling, shifted punctuation matching, backend event routing, and edge cases across AppKit, GTK, WebView2, and macOS CEF (#62).

### Contributors

- @ctate

## 0.2.0

### New Features

- **Layered WebView runtime**: Model each native window as a stack of named WebViews, including the reserved startup `main` WebView and child WebViews with frame, layer, zoom, transparency, routing, resizing, reload, and close support across the native backends (#28).
- **JavaScript WebView API**: Add typed `window.zero.webviews.*` helpers and `zero-native.webview.*` built-in bridge commands for create, list, setFrame, navigate, setZoom, setLayer, and close operations (#28).
- **Isolated child WebViews**: Keep child WebViews bridge-isolated by default, allow trusted child chrome with `bridge: true`, enforce navigation policy on child URLs, and scope WebView commands to the calling native window (#28).
- **Browser example**: Add a browser-style example that demonstrates layered WebViews, browser controls, isolated page content, frontend asset handling, and the root `zig build run-browser` command (#28).
- **zero-native skills**: Ship CLI-served agent skills and reference material for building and automating zero-native apps (#38).

### Improvements

- **WebView and bridge documentation**: Document WebView APIs, built-in bridge commands, security boundaries, backend support, packaging, testing, and app model updates (#28, #38).
- **WebView smoke coverage**: Extend automation smoke tests to exercise child WebView create, resize, navigate, and close operations for system WebView and macOS CEF builds (#28).
- **CEF runtime builds**: Harden the CEF runtime workflows across macOS, Linux, and Windows, including Windows runtime build fixes (#25, #26).
- **macOS compatibility**: Set the native app baseline to macOS 11 (#22).
- **Contributor guidance**: Clarify signed commit requirements and contribution PR guidance (#10).

### Bug Fixes

- **Windows WebView builds**: Fix Windows WebView build failures before the layered WebView release.
- **React example dependencies**: Include the missing React example type dependencies (#11).
- **GitHub release notes**: Avoid duplicate contributor lists when creating GitHub releases (#24).
- **macOS package permissions**: Preserve executable permissions for packaged macOS app binaries (#39).

### Contributors

- @Anshuman71
- @PrathamGhaywat
- @ctate

## 0.1.9

### New Features

- **Linux and Windows desktop support**: Add platform-aware CEF tooling, Linux and Windows desktop build paths, Windows native host plumbing, and cross-platform CEF runtime packaging/release coverage.

### Contributors

- @ctate

## 0.1.8

### Bug Fixes

- **Install completion delay** - Drain redirected GitHub responses during postinstall so npm exits immediately after the native binary is installed.

### Contributors

- @ctate

## 0.1.7

### Improvements

- **Install progress** - Show native binary download progress and checksum status during the npm postinstall step.

### Contributors

- @ctate

## 0.1.6

### Improvements

- **Init next steps** - Print the follow-up commands after scaffolding so users can immediately run their new app.

### Contributors

- @ctate

## 0.1.5

### Bug Fixes

- **macOS local asset loading** - Prefer current-directory asset roots during local `zig build run` so Vite-based examples render their production bundles instead of blank windows.

### Contributors

- @ctate

## 0.1.4

### Bug Fixes

- **Scaffolded app builds** - Ship the framework source tree in the npm package and make `zero-native init` point generated apps at the installed package root so `zig build run` can resolve `src/root.zig`.
- **Long scaffold names** - Keep generated Zig package names within Zig's 32-character manifest limit.
- **Next scaffold builds** - Include the Node.js type package that Next expects for TypeScript projects.
- **Frontend dependency versions** - Generate projects with current Next, React, Vite, Vue, Svelte, and plugin versions.
- **Svelte scaffold builds** - Use the matching Svelte Vite plugin in generated Svelte projects.

### Contributors

- @ctate

## 0.1.3

### Bug Fixes

- **CLI package homepage** - Point npm package metadata at `https://zero-native.dev`.
- **Current-directory init** - Support `zero-native init --frontend <framework>` as shorthand for scaffolding into the current directory.
- **CLI usage errors** - Exit cleanly for invalid CLI arguments instead of printing Zig stack traces for expected user input mistakes.

### Contributors

- @ctate

## 0.1.2

### Bug Fixes

- **npm install fallback** - Do not fail package installation or point global shims at missing binaries when a native release asset is unavailable.
- **Release asset ordering** - Upload the macOS arm64 native binary and `CHECKSUMS.txt` before publishing the npm package so postinstall downloads succeed immediately.

### Contributors

- @ctate

## 0.1.1

### Bug Fixes

- **npm package homepage** - Add the zero-native repository homepage to the CLI package metadata.
- **Chromium example launches** - Stage the CEF framework correctly for the `hello` and `webview` examples when running with `-Dweb-engine=chromium`.
- **Linux WebKitGTK build** - Update navigation policy and external URI handling for current WebKitGTK and GTK4 headers.
- **macOS WebView smoke test** - Use the emitted CLI binary and queue automation early enough for stable CI smoke tests.

### Release Process

- **GitHub releases** - Create missing GitHub releases from marked changelog entries when npm already has the version.
- **CEF runtime release** - Publish the prepared macOS arm64 CEF runtime used by `zero-native cef install`.

### Contributors

- @ctate

## 0.1.0

### Initial Release

- Initial pre-release development version.

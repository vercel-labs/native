<!-- GENERATED FILE — do not edit by hand.
     Derived byte-for-byte from the pinned compiler's surface manifest:
       packages/core/node_modules/@scriptc/compiler/surface-manifest.json
     Regenerate after any compiler pin move:
       node packages/core/scripts/gen_service_surface.mjs
     Verify without writing:
       node packages/core/scripts/gen_service_surface.mjs --check -->

# Service compile surface — scriptc 0.0.27

What TypeScript under `src/services/` can use, as stated by the pinned
compiler itself (surface manifest schema 1, 527 entries:
334 static, 36 dynamic-only, 157 unsupported).

How to read the tables:

- **static** — compiles in the engine-free static tier services use.
- **dynamic-only** — needs the embedded dynamic engine (`--dynamic`),
  which Native SDK builds never pass, so for services this means
  **unavailable** until the entry goes static.
- **unsupported** — refused with the listed SC code. A status describes
  where the named code is *raised*: forms outside the supported subset
  refuse with that code, while supported forms appear as their own
  static entries.
- Absence from the manifest means "not projected by the compiler's
  decision tables yet", never "unsupported".
- Standard-library and node-builtin rows name surface whose lowered
  call forms are constrained (arity, argument shapes); call forms
  outside the lowered set are refused per site with `SC2020`.

## Syntax

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `syntax.class-declarations-inside-functions` | class declarations inside functions | unsupported | `SC1090` |  |
| `syntax.class-expressions` | class expressions | unsupported | `SC1020` |  |
| `syntax.compound-assignment.bitwise-and` | compound assignment operator '&amp;=' | static |  | compiles over the operand types the '&amp;' operator supports |
| `syntax.compound-assignment.bitwise-or` | compound assignment operator '\|=' | static |  | compiles over the operand types the '\|' operator supports |
| `syntax.compound-assignment.bitwise-xor` | compound assignment operator '^=' | static |  | compiles over the operand types the '^' operator supports |
| `syntax.compound-assignment.divide` | compound assignment operator '/=' | static |  | compiles over the operand types the '/' operator supports |
| `syntax.compound-assignment.exponent` | compound assignment operator '**=' | static |  | compiles over the operand types the '**' operator supports |
| `syntax.compound-assignment.minus` | compound assignment operator '-=' | static |  | compiles over the operand types the '-' operator supports |
| `syntax.compound-assignment.plus` | compound assignment operator '+=' | static |  | compiles over the operand types the '+' operator supports |
| `syntax.compound-assignment.remainder` | compound assignment operator '%=' | static |  | compiles over the operand types the '%' operator supports |
| `syntax.compound-assignment.shift-left` | compound assignment operator '&lt;&lt;=' | static |  | compiles over the operand types the '&lt;&lt;' operator supports |
| `syntax.compound-assignment.shift-right` | compound assignment operator '&gt;&gt;=' | static |  | compiles over the operand types the '&gt;&gt;' operator supports |
| `syntax.compound-assignment.shift-right-unsigned` | compound assignment operator '&gt;&gt;&gt;=' | static |  | compiles over the operand types the '&gt;&gt;&gt;' operator supports |
| `syntax.compound-assignment.times` | compound assignment operator '*=' | static |  | compiles over the operand types the '*' operator supports |
| `syntax.debugger-statements` | debugger statements | unsupported | `SC1090` |  |
| `syntax.delete-expressions` | delete expressions | unsupported | `SC1090` |  |
| `syntax.namespaces` | namespaces | unsupported | `SC1090` |  |
| `syntax.spread-arguments` | spread arguments | unsupported | `SC1090` |  |
| `syntax.typeof-expressions` | typeof expressions | unsupported | `SC1090` |  |
| `syntax.with-statements` | 'with' statements (runtime scope injection has no static resolution — bind the object to a variable and read members through it) | unsupported | `SC1090` |  |

## Diagnostic fences

The SC codes an author can hit at the module/program level, and what
each one refuses.

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `diagnostic.sc1010` | package imports | unsupported | `SC1010` | relative imports (./file, ../dir/file), package.json-mediated project imports (#alias via the imports field, self-name references via exports), installed npm packages (their code runs under --dynamic), and the built-in fs, fs/promises, path, os, url, crypto, zlib, child_process, net, http, tls, https, http2, dgram, dns, util, util/types, string_decoder, querystring, readline, events, stream, stream/promises, stream/consumers, buffer, assert, assert/strict, worker_threads, cluster, tty, async_hooks, timers, timers/promises, diagnostics_channel, perf_hooks, and module modules (bare or node:-prefixed) and node:test (node:-prefixed only, like in Node) are supported |
| `diagnostic.sc1012` | default exports/imports | unsupported | `SC1012` | use named exports: export function f() {} / import { f } from "./m" |
| `diagnostic.sc1013` | namespace imports (* as ns) | unsupported | `SC1013` |  |
| `diagnostic.sc1014` | re-exports and export lists | unsupported | `SC1014` | export declarations directly: export function f() {} |
| `diagnostic.sc1015` | dynamic import() | unsupported | `SC1015` |  |
| `diagnostic.sc1016` | circular imports | unsupported | `SC1016` | cycles of ES modules with declaration-only top levels whose cycle-crossing bindings are only used inside function bodies compile as-is; move the named top-level read or call into a function body (or break the named edge) so nothing runs during the cycle's init window |
| `diagnostic.sc1020` | class expressions | unsupported | `SC1020` |  |
| `diagnostic.sc1030` | var declarations | unsupported | `SC1030` |  |
| `diagnostic.sc1031` | destructuring | unsupported | `SC1031` |  |
| `diagnostic.sc1040` | loose equality (== and !=) | unsupported | `SC1040` | use === / !== ('x == null' / 'x != null' — the null-or-undefined test — is supported; other loose comparisons need dynamic coercion semantics) |
| `diagnostic.sc1042` | logical operators on mixed operand types | unsupported | `SC1042` | give both operands the same type (number, string, or boolean) |
| `diagnostic.sc1043` | comparing non-number, non-string values | unsupported | `SC1043` |  |
| `diagnostic.sc1045` | increment/decrement in expression position | unsupported | `SC1045` | use ++/-- as a standalone statement, or write x = x + 1 |
| `diagnostic.sc1050` | labeled break/continue | unsupported | `SC1050` |  |
| `diagnostic.sc1052` | for-in loops | unsupported | `SC1052` |  |
| `diagnostic.sc1062` | destructuring catch clause bindings | unsupported | `SC1062` | bind an identifier (catch (e)) and narrow it — 'e instanceof Error' exposes .name/.message, typeof tests expose primitives |
| `diagnostic.sc1063` | this use of a catch binding | unsupported | `SC1063` | a catch binding is typed by what was thrown — narrow before reading: 'if (e instanceof Error)' (then .name/.message), 'typeof e === "string"/"number"/"boolean"', or rethrow with 'throw e'; String(e) and `${e}` also compile ('Error: msg' for Error payloads — Node's String(), which has no stack), so 'e instanceof Error ? e.message : String(e)' works as-is |
| `diagnostic.sc1070` | async/await | unsupported | `SC1070` |  |
| `diagnostic.sc1071` | generators | unsupported | `SC1071` |  |
| `diagnostic.sc1080` | 'this' outside a class method | unsupported | `SC1080` |  |
| `diagnostic.sc1090` | this syntax | unsupported | `SC1090` |  |
| `diagnostic.sc1100` | operations on 'unknown' values | unsupported | `SC1100` | validate with 'as &lt;type&gt;' first — the cast checks the dynamic value at runtime and throws on mismatch |
| `diagnostic.sc1101` | converting typed values to 'unknown' | unsupported | `SC1101` | numbers, strings, booleans, JSON-safe records/arrays/unions (a deep copy — the 'unknown' value never aliases the original), and functions over those (boxed, identity preserved) convert into 'unknown' slots; this value's type has no dynamic representation yet |
| `diagnostic.sc1120` | this regex feature | unsupported | `SC1120` | supported: literal regexes with the g/i/m/s/u/y flags — .test(), .exec()/.match()/.matchAll(), named capture groups (.groups, $&lt;name&gt; templates, \k&lt;name&gt;), .source/.flags, and string replace/replaceAll/split with string replacement templates |
| `diagnostic.sc1121` | '.test()' on a regex with the 'g' or 'y' flag | unsupported | `SC1121` | g/y regexes carry mutable lastIndex state between calls, which is not modeled; drop the flag for a plain match test, or use replace/replaceAll/split (their iteration is internal) |
| `diagnostic.sc2001` | values of types outside the compilable set (bigint and symbol primitives, constructor objects, and library-derived or unresolved generic shapes) | unsupported | `SC2001` |  |
| `diagnostic.sc2002` | record shape flows outside the width-copy rules (shapes must match exactly or width-coerce) | unsupported | `SC2002` |  |
| `diagnostic.sc2003` | union-to-union conversions outside the re-tagging rule | unsupported | `SC2003` |  |
| `diagnostic.sc2004` | uses of a binding whose declaration did not compile (cascade marker) | unsupported | `SC2004` |  |
| `diagnostic.sc2005` | values whose type keeps a generic call signature (a compiled function is one concrete signature) | unsupported | `SC2005` |  |
| `diagnostic.sc2006` | index-signature object types outside the supported shape | unsupported | `SC2006` |  |
| `diagnostic.sc2007` | values of overloaded function type (a compiled function value is one signature) | unsupported | `SC2007` |  |
| `diagnostic.sc2008` | intersection types with no resolved lowering | unsupported | `SC2008` |  |
| `diagnostic.sc2009` | supported container and function shapes over a component type outside its slot | unsupported | `SC2009` |  |
| `diagnostic.sc2010` | constructs that exist only in the embedded dynamic engine | dynamic-only | `SC2010` |  |
| `diagnostic.sc2011` | 'any'-typed values and the operations on them | dynamic-only | `SC2011` |  |
| `diagnostic.sc2012` | standard-library surface that runs in the embedded dynamic engine | dynamic-only | `SC2012` |  |
| `diagnostic.sc2013` | npm package imports and values (the package's implementation runs in the embedded engine) | dynamic-only | `SC2013` |  |
| `diagnostic.sc2020` | standard-library or @types/node surface with no lowering | unsupported | `SC2020` |  |
| `diagnostic.sc2030` | npm package code that cannot be embedded for the dynamic engine | unsupported | `SC2030` |  |

## Node built-in modules

Recognized modules and their accepted specifier forms, as stated by each
manifest row in the Notes column:

| Entry id | Surface | Status | Notes |
|---|---|---|---|
| `node-builtin.assert` | assert | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.assert.strict` | assert/strict | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.async_hooks` | async_hooks | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.buffer` | buffer | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.child_process` | child_process | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.cluster` | cluster | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.crypto` | crypto | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.dgram` | dgram | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.diagnostics_channel` | diagnostics_channel | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.dns` | dns | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.events` | events | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.fs` | fs | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.fs.promises` | fs/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.http` | http | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.http2` | http2 | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.https` | https | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.module` | module | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.net` | net | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.os` | os | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.path` | path | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.path.posix` | path/posix | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.path.win32` | path/win32 | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.perf_hooks` | perf_hooks | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.querystring` | querystring | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.readline` | readline | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream` | stream | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream.consumers` | stream/consumers | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream.promises` | stream/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.string_decoder` | string_decoder | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.test` | node:test | static | recognized module (node:-prefixed specifier only, matching Node) |
| `node-builtin.timers` | timers | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.timers.promises` | timers/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.tls` | tls | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.tty` | tty | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.url` | url | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.util` | util | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.util.types` | util/types | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.worker_threads` | worker_threads | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.zlib` | zlib | static | recognized module (bare and node:-prefixed specifiers) |

### Module member surface

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `node-builtin.assert.AssertionError` | assert.AssertionError | unsupported | `SC2020` | the class itself has no lowering — catch and test err.name === "AssertionError" or err.code === "ERR_ASSERTION" |
| `node-builtin.assert.deepEqual` | assert.deepEqual | unsupported | `SC2020` | loose == equality has no lowering — the strict forms compare with Object.is/structural equality like Node's assert/strict module, where equal IS strictEqual |
| `node-builtin.assert.doesNotReject` | assert.doesNotReject | unsupported | `SC2020` | await the promise directly — an unexpected rejection already fails the test |
| `node-builtin.assert.doesNotThrow` | assert.doesNotThrow | unsupported | `SC2020` | call the function directly — an unexpected throw already fails the test |
| `node-builtin.assert.equal` | assert.equal | unsupported | `SC2020` | loose == equality has no lowering — the strict forms compare with Object.is/structural equality like Node's assert/strict module, where equal IS strictEqual |
| `node-builtin.assert.ifError` | assert.ifError | unsupported | `SC2020` | test explicitly instead: assert.strictEqual(err, null) / assert.strictEqual(err, undefined) |
| `node-builtin.assert.notDeepEqual` | assert.notDeepEqual | unsupported | `SC2020` | loose == equality has no lowering — the strict forms compare with Object.is/structural equality like Node's assert/strict module, where equal IS strictEqual |
| `node-builtin.assert.notEqual` | assert.notEqual | unsupported | `SC2020` | loose == equality has no lowering — the strict forms compare with Object.is/structural equality like Node's assert/strict module, where equal IS strictEqual |
| `node-builtin.assert.rejects` | assert.rejects | unsupported | `SC2020` | await the promise inside assert.throws's callback story instead: try { await p; assert.fail("expected rejection") } catch { ... } |
| `node-builtin.assert.strict.AssertionError` | assert/strict.AssertionError | unsupported | `SC2020` | the class itself has no lowering — catch and test err.name === "AssertionError" or err.code === "ERR_ASSERTION" |
| `node-builtin.assert.strict.doesNotReject` | assert/strict.doesNotReject | unsupported | `SC2020` | await the promise directly — an unexpected rejection already fails the test |
| `node-builtin.assert.strict.doesNotThrow` | assert/strict.doesNotThrow | unsupported | `SC2020` | call the function directly — an unexpected throw already fails the test |
| `node-builtin.assert.strict.ifError` | assert/strict.ifError | unsupported | `SC2020` | test explicitly instead: assert.strictEqual(err, null) / assert.strictEqual(err, undefined) |
| `node-builtin.assert.strict.rejects` | assert/strict.rejects | unsupported | `SC2020` | await the promise inside assert.throws's callback story instead: try { await p; assert.fail("expected rejection") } catch { ... } |
| `node-builtin.child_process.execFile` | child_process.execFile | unsupported | `SC2020` | the callback form has no lowering — promisify it: const execFileAsync = promisify(execFile) (from node:util), or use execFileSync |
| `node-builtin.child_process.execFileSync` | child_process.execFileSync | static |  |  |
| `node-builtin.child_process.execSync` | child_process.execSync | static |  |  |
| `node-builtin.child_process.spawn` | child_process.spawn | static |  |  |
| `node-builtin.child_process.spawnSync` | child_process.spawnSync | static |  |  |
| `node-builtin.cluster.isMaster` | cluster.isMaster | static |  | constant value read |
| `node-builtin.cluster.isPrimary` | cluster.isPrimary | static |  | constant value read |
| `node-builtin.cluster.isWorker` | cluster.isWorker | static |  | constant value read |
| `node-builtin.crypto.createCipheriv` | crypto.createCipheriv | unsupported | `SC2020` | symmetric ciphers need a cipher stack the static runtime does not vendor — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createDecipheriv` | crypto.createDecipheriv | unsupported | `SC2020` | symmetric ciphers need a cipher stack the static runtime does not vendor — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createDiffieHellman` | crypto.createDiffieHellman | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createDiffieHellmanGroup` | crypto.createDiffieHellmanGroup | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createECDH` | crypto.createECDH | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createHash` | crypto.createHash | unsupported | `SC2020` | the one lowered shape is the composed chain createHash("sha256").update(data).digest("hex") — the Hash handle itself has no lowering |
| `node-builtin.crypto.createHmac` | crypto.createHmac | unsupported | `SC2020` | HMAC has no lowering yet — the lowered crypto surface is randomUUID, randomBytes, the createHash("sha256"\|"sha1") chain, and the introspection statics |
| `node-builtin.crypto.createPrivateKey` | crypto.createPrivateKey | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createPublicKey` | crypto.createPublicKey | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createSecretKey` | crypto.createSecretKey | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createSign` | crypto.createSign | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.createVerify` | crypto.createVerify | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.diffieHellman` | crypto.diffieHellman | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.generateKey` | crypto.generateKey | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.generateKeyPair` | crypto.generateKeyPair | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.generateKeyPairSync` | crypto.generateKeyPairSync | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.generateKeySync` | crypto.generateKeySync | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.getCipherInfo` | crypto.getCipherInfo | unsupported | `SC2020` | symmetric ciphers need a cipher stack the static runtime does not vendor — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.getDiffieHellman` | crypto.getDiffieHellman | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.hash` | crypto.hash | unsupported | `SC2020` | the one-shot digest has no lowering — the composed chain createHash("sha256").update(data).digest("hex") is the lowered hashing surface |
| `node-builtin.crypto.hkdf` | crypto.hkdf | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.hkdfSync` | crypto.hkdfSync | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.pbkdf2` | crypto.pbkdf2 | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.pbkdf2Sync` | crypto.pbkdf2Sync | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.privateDecrypt` | crypto.privateDecrypt | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.privateEncrypt` | crypto.privateEncrypt | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.publicDecrypt` | crypto.publicDecrypt | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.publicEncrypt` | crypto.publicEncrypt | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.randomBytes` | crypto.randomBytes | static |  |  |
| `node-builtin.crypto.randomUUID` | crypto.randomUUID | static |  |  |
| `node-builtin.crypto.scrypt` | crypto.scrypt | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.scryptSync` | crypto.scryptSync | unsupported | `SC2020` | key-derivation functions have no lowering yet — the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.setFips` | crypto.setFips | unsupported | `SC2020` | a compiled binary has no FIPS provider to enable, and Node itself throws on setFips(true) in a non-FIPS build — getFips() answers 0 here |
| `node-builtin.crypto.sign` | crypto.sign | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.verify` | crypto.verify | unsupported | `SC2020` | asymmetric-key operations need a public-key stack (bignum, RSA/EC/EdDSA math) and a KeyObject value model — neither exists in the static runtime, so no faithful lowering can be small; the lowered crypto surface is hashing, randomness, and the introspection statics |
| `node-builtin.crypto.webcrypto` | crypto.webcrypto | unsupported | `SC2020` | the WebCrypto object has no lowering — the lowered crypto surface is randomUUID, randomBytes, and the createHash chain |
| `node-builtin.diagnostics_channel.channel` | diagnostics_channel.channel | static |  |  |
| `node-builtin.diagnostics_channel.hasSubscribers` | diagnostics_channel.hasSubscribers | static |  |  |
| `node-builtin.diagnostics_channel.subscribe` | diagnostics_channel.subscribe | static |  |  |
| `node-builtin.diagnostics_channel.tracingChannel` | diagnostics_channel.tracingChannel | static |  |  |
| `node-builtin.diagnostics_channel.unsubscribe` | diagnostics_channel.unsubscribe | static |  |  |
| `node-builtin.fs.accessSync` | fs.accessSync | static |  |  |
| `node-builtin.fs.appendFileSync` | fs.appendFileSync | static |  |  |
| `node-builtin.fs.chmodSync` | fs.chmodSync | static |  |  |
| `node-builtin.fs.chownSync` | fs.chownSync | static |  |  |
| `node-builtin.fs.closeSync` | fs.closeSync | static |  |  |
| `node-builtin.fs.copyFileSync` | fs.copyFileSync | static |  |  |
| `node-builtin.fs.existsSync` | fs.existsSync | static |  |  |
| `node-builtin.fs.lstatSync` | fs.lstatSync | static |  |  |
| `node-builtin.fs.mkdirSync` | fs.mkdirSync | static |  |  |
| `node-builtin.fs.mkdtempSync` | fs.mkdtempSync | static |  |  |
| `node-builtin.fs.openSync` | fs.openSync | static |  |  |
| `node-builtin.fs.promises.chmod` | fs/promises.chmod | static |  |  |
| `node-builtin.fs.promises.mkdir` | fs/promises.mkdir | static |  |  |
| `node-builtin.fs.promises.open` | fs/promises.open | static |  |  |
| `node-builtin.fs.promises.readFile` | fs/promises.readFile | static |  |  |
| `node-builtin.fs.promises.readdir` | fs/promises.readdir | static |  |  |
| `node-builtin.fs.promises.rename` | fs/promises.rename | static |  |  |
| `node-builtin.fs.promises.rm` | fs/promises.rm | static |  |  |
| `node-builtin.fs.promises.stat` | fs/promises.stat | static |  |  |
| `node-builtin.fs.promises.unlink` | fs/promises.unlink | static |  |  |
| `node-builtin.fs.promises.writeFile` | fs/promises.writeFile | static |  |  |
| `node-builtin.fs.readFileSync` | fs.readFileSync | static |  |  |
| `node-builtin.fs.readSync` | fs.readSync | static |  |  |
| `node-builtin.fs.readdirSync` | fs.readdirSync | static |  |  |
| `node-builtin.fs.realpathSync` | fs.realpathSync | static |  |  |
| `node-builtin.fs.rename` | fs.rename | static |  |  |
| `node-builtin.fs.renameSync` | fs.renameSync | static |  |  |
| `node-builtin.fs.rmSync` | fs.rmSync | static |  |  |
| `node-builtin.fs.rmdirSync` | fs.rmdirSync | static |  |  |
| `node-builtin.fs.statSync` | fs.statSync | static |  |  |
| `node-builtin.fs.unlinkSync` | fs.unlinkSync | static |  |  |
| `node-builtin.fs.watch` | fs.watch | static |  |  |
| `node-builtin.fs.writeFileSync` | fs.writeFileSync | static |  |  |
| `node-builtin.fs.writeSync` | fs.writeSync | static |  |  |
| `node-builtin.http2.connect` | http2.connect | unsupported | `SC2020` | HTTP/2 client sessions have no lowering — the lowered http2 surface is the SERVER side: createSecureServer({ allowHTTP1: true, cert, key }), which serves HTTP/1.1 only (ALPN never offers h2 — h2-capable clients negotiate down); an HTTP/1.1 client is https.request |
| `node-builtin.http2.createServer` | http2.createServer | unsupported | `SC2020` | cleartext (h2c) servers have no lowering — the lowered http2 surface is createSecureServer({ allowHTTP1: true, cert, key }), which serves HTTP/1.1 over TLS (plain HTTP/1.1 is http.createServer) |
| `node-builtin.module.createRequire` | module.createRequire | unsupported | `SC2020` | the lowered shape is a const binding over createRequire(import.meta.url) (or __filename) whose require calls take STATIC string literals — builtins, relative .json documents, and installed npm packages (under --dynamic) resolve at build time; dynamic specifiers cannot exist in a compiled binary's fixed module graph |
| `node-builtin.module.isBuiltin` | module.isBuiltin | unsupported | `SC2020` | builtinModules.includes(name) answers the same question over the baked list (strip a node: prefix first; the prefix-only builtins appear with it, as node:test) |
| `node-builtin.module.syncBuiltinESMExports` | module.syncBuiltinESMExports | unsupported | `SC2020` | a compiled program has no live builtin ESM namespace bindings to synchronize — nothing a compiled surface can mutate makes the call observable; remove it |
| `node-builtin.net.getDefaultAutoSelectFamilyAttemptTimeout` | net.getDefaultAutoSelectFamilyAttemptTimeout | static |  |  |
| `node-builtin.net.setDefaultAutoSelectFamilyAttemptTimeout` | net.setDefaultAutoSelectFamilyAttemptTimeout | static |  |  |
| `node-builtin.os.EOL` | os.EOL | static |  | constant value read |
| `node-builtin.os.homedir` | os.homedir | static |  |  |
| `node-builtin.os.networkInterfaces` | os.networkInterfaces | static |  |  |
| `node-builtin.os.platform` | os.platform | static |  |  |
| `node-builtin.os.release` | os.release | static |  |  |
| `node-builtin.os.tmpdir` | os.tmpdir | static |  |  |
| `node-builtin.os.totalmem` | os.totalmem | static |  |  |
| `node-builtin.os.type` | os.type | static |  |  |
| `node-builtin.os.userInfo` | os.userInfo | static |  |  |
| `node-builtin.path.basename` | path.basename | static |  |  |
| `node-builtin.path.delimiter` | path.delimiter | static |  | constant value read |
| `node-builtin.path.dirname` | path.dirname | static |  |  |
| `node-builtin.path.extname` | path.extname | static |  |  |
| `node-builtin.path.isAbsolute` | path.isAbsolute | static |  |  |
| `node-builtin.path.join` | path.join | static |  |  |
| `node-builtin.path.normalize` | path.normalize | static |  |  |
| `node-builtin.path.posix.basename` | path/posix.basename | static |  |  |
| `node-builtin.path.posix.delimiter` | path/posix.delimiter | static |  | constant value read |
| `node-builtin.path.posix.dirname` | path/posix.dirname | static |  |  |
| `node-builtin.path.posix.extname` | path/posix.extname | static |  |  |
| `node-builtin.path.posix.isAbsolute` | path/posix.isAbsolute | static |  |  |
| `node-builtin.path.posix.join` | path/posix.join | static |  |  |
| `node-builtin.path.posix.normalize` | path/posix.normalize | static |  |  |
| `node-builtin.path.posix.relative` | path/posix.relative | static |  |  |
| `node-builtin.path.posix.resolve` | path/posix.resolve | static |  |  |
| `node-builtin.path.posix.sep` | path/posix.sep | static |  | constant value read |
| `node-builtin.path.posix.toNamespacedPath` | path/posix.toNamespacedPath | static |  |  |
| `node-builtin.path.relative` | path.relative | static |  |  |
| `node-builtin.path.resolve` | path.resolve | static |  |  |
| `node-builtin.path.sep` | path.sep | static |  | constant value read |
| `node-builtin.path.toNamespacedPath` | path.toNamespacedPath | static |  |  |
| `node-builtin.path.win32.basename` | path/win32.basename | static |  |  |
| `node-builtin.path.win32.delimiter` | path/win32.delimiter | static |  | constant value read |
| `node-builtin.path.win32.dirname` | path/win32.dirname | static |  |  |
| `node-builtin.path.win32.extname` | path/win32.extname | static |  |  |
| `node-builtin.path.win32.isAbsolute` | path/win32.isAbsolute | static |  |  |
| `node-builtin.path.win32.join` | path/win32.join | static |  |  |
| `node-builtin.path.win32.normalize` | path/win32.normalize | static |  |  |
| `node-builtin.path.win32.relative` | path/win32.relative | static |  |  |
| `node-builtin.path.win32.resolve` | path/win32.resolve | static |  |  |
| `node-builtin.path.win32.sep` | path/win32.sep | static |  | constant value read |
| `node-builtin.path.win32.toNamespacedPath` | path/win32.toNamespacedPath | static |  |  |
| `node-builtin.perf_hooks.performance.now` | perf_hooks.performance.now | static |  | the global performance object and the performance.now.bind(performance) function value reach the same clock |
| `node-builtin.process.argv` | process.argv | static |  |  |
| `node-builtin.process.availableMemory` | process.availableMemory | static |  |  |
| `node-builtin.process.chdir` | process.chdir | static |  |  |
| `node-builtin.process.columns` | process.columns | static |  | the columns read on the process stdio streams (terminal geometry) |
| `node-builtin.process.constrainedMemory` | process.constrainedMemory | static |  |  |
| `node-builtin.process.cpuUsage` | process.cpuUsage | static |  | the plain-sample and previous-value diff forms are one surface |
| `node-builtin.process.cwd` | process.cwd | static |  |  |
| `node-builtin.process.env` | process.env | static |  | reads, writes, deletes, and enumeration of the process environment (the process global) |
| `node-builtin.process.execPath` | process.execPath | static |  |  |
| `node-builtin.process.exit` | process.exit | static |  | process.exit and the process._exiting flag read are one surface |
| `node-builtin.process.getgid` | process.getgid | static |  |  |
| `node-builtin.process.getuid` | process.getuid | static |  |  |
| `node-builtin.process.isTTY` | process.isTTY | static |  | the isTTY read on process.stdin/stdout/stderr — one surface across the three streams |
| `node-builtin.process.kill` | process.kill | static |  | the signal-name and signal-number forms are one surface |
| `node-builtin.process.pid` | process.pid | static |  |  |
| `node-builtin.process.resourceUsage` | process.resourceUsage | static |  | getrusage's 16 fields — every field read samples live machine state |
| `node-builtin.process.threadCpuUsage` | process.threadCpuUsage | static |  | the plain-sample and previous-value diff forms are one surface |
| `node-builtin.process.umask` | process.umask | static |  |  |
| `node-builtin.process.uptime` | process.uptime | static |  |  |
| `node-builtin.querystring.decode` | querystring.decode | static |  |  |
| `node-builtin.querystring.encode` | querystring.encode | static |  |  |
| `node-builtin.querystring.escape` | querystring.escape | static |  |  |
| `node-builtin.querystring.parse` | querystring.parse | static |  |  |
| `node-builtin.querystring.stringify` | querystring.stringify | static |  |  |
| `node-builtin.querystring.unescape` | querystring.unescape | static |  |  |
| `node-builtin.readline.createInterface` | readline.createInterface | static |  |  |
| `node-builtin.stream.consumers.arrayBuffer` | stream/consumers.arrayBuffer | unsupported | `SC2020` | no free-standing ArrayBuffer value exists here (typed arrays own their storage) — buffer(stream) collects the same bytes as a Buffer |
| `node-builtin.stream.consumers.blob` | stream/consumers.blob | unsupported | `SC2020` | Blob values have no representation in a compiled binary — buffer(stream) collects the same bytes as a Buffer, text(stream) the decoded text |
| `node-builtin.timers.promises.setImmediate` | timers/promises.setImmediate | static |  |  |
| `node-builtin.timers.promises.setTimeout` | timers/promises.setTimeout | static |  |  |
| `node-builtin.tls.connect` | tls.connect | unsupported | `SC2020` | the lowered TLS client is https.request({ hostname, port, path, method, ca?, rejectUnauthorized? }); raw tls.connect sockets have no lowering yet |
| `node-builtin.tls.createSecureContext` | tls.createSecureContext | unsupported | `SC2020` | the lowered form is createSecureContext({ cert, key }) — an opaque SecureContext handle for SNI callbacks (http2.createSecureServer accepts SNICallback); other options fence by name |
| `node-builtin.tls.getCACertificates` | tls.getCACertificates | static |  | the per-type cached PEM bundle: 'default' and 'extra' additionally read NODE_EXTRA_CA_CERTS, 'system' the platform store |
| `node-builtin.tls.rootCertificates` | tls.rootCertificates | static |  | the value read; answers the same bundled array as getCACertificates('bundled'), but fenced under its own id — the spelling an author writes |
| `node-builtin.tls.setDefaultCACertificates` | tls.setDefaultCACertificates | static |  | replaces the default set and the client trust anchors for the rest of the process |
| `node-builtin.url.fileURLToPath` | url.fileURLToPath | static |  |  |
| `node-builtin.url.pathToFileURL` | url.pathToFileURL | static |  |  |
| `node-builtin.util.parseArgs` | util.parseArgs | static |  |  |
| `node-builtin.util.promisify` | util.promisify | unsupported | `SC2020` | the one lowered shape is a const binding over child_process.execFile: const execFileAsync = promisify(execFile), then call execFileAsync directly |
| `node-builtin.worker_threads.isMainThread` | worker_threads.isMainThread | static |  | constant value read |
| `node-builtin.worker_threads.threadId` | worker_threads.threadId | static |  | constant value read |
| `node-builtin.zlib.brotliCompressSync` | zlib.brotliCompressSync | unsupported | `SC2020` | deflateSync and inflateSync are the lowered zlib surface |
| `node-builtin.zlib.brotliDecompressSync` | zlib.brotliDecompressSync | unsupported | `SC2020` | deflateSync and inflateSync are the lowered zlib surface |
| `node-builtin.zlib.deflateSync` | zlib.deflateSync | static |  |  |
| `node-builtin.zlib.gunzipSync` | zlib.gunzipSync | unsupported | `SC2020` | deflateSync and inflateSync are the lowered zlib surface |
| `node-builtin.zlib.gzipSync` | zlib.gzipSync | unsupported | `SC2020` | deflateSync and inflateSync are the lowered zlib surface |
| `node-builtin.zlib.inflateSync` | zlib.inflateSync | static |  |  |
| `node-builtin.zlib.unzipSync` | zlib.unzipSync | unsupported | `SC2020` | deflateSync and inflateSync are the lowered zlib surface |

## Standard library

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `stdlib.abort-controller.abort` | AbortController.abort | static |  | Node 24.15.0 / Undici 7.24.4; facets: callback-order, identity, liveness, state-machine, surplus-arguments; differential evidence: fixture:static-controller |
| `stdlib.abort-controller.constructor` | AbortController constructor | static |  | Node 24.15.0 / Undici 7.24.4; facets: argument-evaluation, identity, state-machine, surplus-arguments; differential evidence: fixture:static-controller |
| `stdlib.abort-controller.signal` | AbortController.signal | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, property-read, state-machine; differential evidence: fixture:static-controller |
| `stdlib.abort-signal.abort` | AbortSignal.abort | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, liveness, surplus-arguments, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.aborted` | AbortSignal.aborted | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: generated:webidl-operations |
| `stdlib.abort-signal.add-event-listener` | AbortSignal.addEventListener | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, identity, callback-order, callback-this; differential evidence: generated:abort-events, fixture:static-listener-this, fixture:static-listener-noncallable |
| `stdlib.abort-signal.any` | AbortSignal.any | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, missing-arguments, surplus-arguments, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.constructor` | AbortSignal constructor | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; Node exposes the interface object but constructing it throws; neither compiler tier currently preserves that constructor behavior |
| `stdlib.abort-signal.dispatch-event` | AbortSignal.dispatchEvent | static |  | Node 24.15.0 / Undici 7.24.4; facets: callback-order, callback-this, error-shape; differential evidence: fixture:static-dispatch-throw |
| `stdlib.abort-signal.onabort` | AbortSignal.onabort | static |  | Node 24.15.0 / Undici 7.24.4; facets: callback-order, callback-this, mutation, property-read; differential evidence: generated:abort-events, fixture:static-listener-this |
| `stdlib.abort-signal.reason` | AbortSignal.reason | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, liveness, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.remove-event-listener` | AbortSignal.removeEventListener | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, identity, callback-order; differential evidence: generated:abort-events, fixture:static-stream-this |
| `stdlib.abort-signal.throw-if-aborted` | AbortSignal.throwIfAborted | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, error-shape; differential evidence: generated:webidl-operations, fixture:static-abort-throw |
| `stdlib.abort-signal.timeout` | AbortSignal.timeout | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, missing-arguments, surplus-arguments, error-shape; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.array.at` | Array.prototype.at | static |  |  |
| `stdlib.array.concat` | Array.prototype.concat | static |  |  |
| `stdlib.array.every` | Array.prototype.every | static |  |  |
| `stdlib.array.filter` | Array.prototype.filter | static |  |  |
| `stdlib.array.find` | Array.prototype.find | static |  |  |
| `stdlib.array.findIndex` | Array.prototype.findIndex | static |  |  |
| `stdlib.array.findLast` | Array.prototype.findLast | static |  |  |
| `stdlib.array.findLastIndex` | Array.prototype.findLastIndex | static |  |  |
| `stdlib.array.flatMap` | Array.prototype.flatMap | static |  |  |
| `stdlib.array.forEach` | Array.prototype.forEach | static |  |  |
| `stdlib.array.includes` | Array.prototype.includes | static |  |  |
| `stdlib.array.indexOf` | Array.prototype.indexOf | static |  |  |
| `stdlib.array.join` | Array.prototype.join | static |  |  |
| `stdlib.array.map` | Array.prototype.map | static |  |  |
| `stdlib.array.pop` | Array.prototype.pop | static |  |  |
| `stdlib.array.push` | Array.prototype.push | static |  |  |
| `stdlib.array.reduce` | Array.prototype.reduce | static |  |  |
| `stdlib.array.reduceRight` | Array.prototype.reduceRight | static |  |  |
| `stdlib.array.reverse` | Array.prototype.reverse | static |  |  |
| `stdlib.array.slice` | Array.prototype.slice | static |  |  |
| `stdlib.array.some` | Array.prototype.some | static |  |  |
| `stdlib.array.toReversed` | Array.prototype.toReversed | static |  |  |
| `stdlib.array.toSorted` | Array.prototype.toSorted | static |  |  |
| `stdlib.array.toSpliced` | Array.prototype.toSpliced | static |  |  |
| `stdlib.array.unshift` | Array.prototype.unshift | static |  |  |
| `stdlib.array.with` | Array.prototype.with | static |  |  |
| `stdlib.date.UTC` | Date.UTC | static |  | the lowered call form takes 1 to 7 number arguments |
| `stdlib.date.constructor` | Date constructor | static |  | zero arguments, or one milliseconds/date-string argument; values are the read-only TimeClip scalar slice |
| `stdlib.date.getDate` | Date.prototype.getDate | static |  |  |
| `stdlib.date.getDay` | Date.prototype.getDay | static |  |  |
| `stdlib.date.getFullYear` | Date.prototype.getFullYear | static |  |  |
| `stdlib.date.getHours` | Date.prototype.getHours | static |  |  |
| `stdlib.date.getMilliseconds` | Date.prototype.getMilliseconds | static |  |  |
| `stdlib.date.getMinutes` | Date.prototype.getMinutes | static |  |  |
| `stdlib.date.getMonth` | Date.prototype.getMonth | static |  |  |
| `stdlib.date.getSeconds` | Date.prototype.getSeconds | static |  |  |
| `stdlib.date.getTime` | Date.prototype.getTime | static |  | the millisecond value of a stored Date |
| `stdlib.date.getTimezoneOffset` | Date.prototype.getTimezoneOffset | static |  |  |
| `stdlib.date.getUTCDate` | Date.prototype.getUTCDate | static |  |  |
| `stdlib.date.getUTCDay` | Date.prototype.getUTCDay | static |  |  |
| `stdlib.date.getUTCFullYear` | Date.prototype.getUTCFullYear | static |  |  |
| `stdlib.date.getUTCHours` | Date.prototype.getUTCHours | static |  |  |
| `stdlib.date.getUTCMilliseconds` | Date.prototype.getUTCMilliseconds | static |  |  |
| `stdlib.date.getUTCMinutes` | Date.prototype.getUTCMinutes | static |  |  |
| `stdlib.date.getUTCMonth` | Date.prototype.getUTCMonth | static |  |  |
| `stdlib.date.getUTCSeconds` | Date.prototype.getUTCSeconds | static |  |  |
| `stdlib.date.now` | Date.now | static |  | the live clock |
| `stdlib.date.toISOString` | Date.prototype.toISOString | static |  | UTC ISO formatting over constructed and stored Date values |
| `stdlib.date.valueOf` | Date.prototype.valueOf | static |  | the same millisecond read as getTime() |
| `stdlib.fetch` | fetch | static |  | Node 24.15.0 / Undici 7.24.4; facets: argument-evaluation, webidl-conversion, surplus-arguments, promise-settlement, transport, error-shape; differential evidence: fixture:static, fixture:static-coercion, fixture:static-network-error |
| `stdlib.fetch.request-init.body` | RequestInit.body | static |  | Node 24.15.0 / Undici 7.24.4; conversion: string, Uint8Array, ReadableStream, or null; differential evidence: fixture:static, fixture:static-stream, fixture:static-coercion |
| `stdlib.fetch.request-init.cache` | RequestInit.cache | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.credentials` | RequestInit.credentials | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.dispatcher` | RequestInit.dispatcher | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic tier recognizes Vercel CLI's EnvProxyDispatcher and applies equivalent native environment-proxy routing |
| `stdlib.fetch.request-init.duplex` | RequestInit.duplex | static |  | Node 24.15.0 / Undici 7.24.4; conversion: WebIDL enum; 'half' required for streaming bodies; differential evidence: fixture:static-stream, fixture:static-coercion |
| `stdlib.fetch.request-init.headers` | RequestInit.headers | static |  | Node 24.15.0 / Undici 7.24.4; conversion: Headers, record, or sequence-of-pairs snapshot; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.fetch.request-init.integrity` | RequestInit.integrity | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.keepalive` | RequestInit.keepalive | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.method` | RequestInit.method | static |  | Node 24.15.0 / Undici 7.24.4; conversion: WebIDL ByteString after all call arguments evaluate; differential evidence: fixture:static-coercion |
| `stdlib.fetch.request-init.mode` | RequestInit.mode | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.priority` | RequestInit.priority | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.redirect` | RequestInit.redirect | static |  | Node 24.15.0 / Undici 7.24.4; conversion: WebIDL enum: follow, error, or manual; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.fetch.request-init.referrer` | RequestInit.referrer | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.referrerPolicy` | RequestInit.referrerPolicy | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.signal` | RequestInit.signal | static |  | Node 24.15.0 / Undici 7.24.4; conversion: native AbortSignal handle or absent; differential evidence: fixture:static, fixture:static-abort-throw |
| `stdlib.fetch.request-init.window` | RequestInit.window | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; neither compiler tier preserves this RequestInit member's conversion or transport behavior |
| `stdlib.headers.append` | Headers.append | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.constructor` | Headers constructor | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the interface constructor has no compiler bridge in either tier |
| `stdlib.headers.delete` | Headers.delete | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.entries` | Headers.entries | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; native Headers iteration does not yet expose a static iterator handle |
| `stdlib.headers.forEach` | Headers.forEach | static |  | Node 24.15.0 / Undici 7.24.4; facets: callback-order, callback-this, mutation; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.get` | Headers.get | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, missing-arguments, property-read; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.getSetCookie` | Headers.getSetCookie | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.has` | Headers.has | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, missing-arguments, property-read; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.keys` | Headers.keys | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; native Headers iteration does not yet expose a static iterator handle |
| `stdlib.headers.set` | Headers.set | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.symbol.iterator` | Headers.[Symbol.iterator] | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; native Headers iteration does not expose an engine-free iterator handle |
| `stdlib.headers.values` | Headers.values | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; native Headers iteration does not yet expose a static iterator handle |
| `stdlib.map.clear` | Map.prototype.clear | static |  |  |
| `stdlib.map.delete` | Map.prototype.delete | static |  |  |
| `stdlib.map.forEach` | Map.prototype.forEach | static |  |  |
| `stdlib.map.get` | Map.prototype.get | static |  |  |
| `stdlib.map.has` | Map.prototype.has | static |  |  |
| `stdlib.map.set` | Map.prototype.set | static |  |  |
| `stdlib.math.E` | Math.E | dynamic-only | `SC2012` |  |
| `stdlib.math.PI` | Math.PI | dynamic-only | `SC2012` |  |
| `stdlib.math.abs` | Math.abs | static |  | compiles statically at arity 1; other declared call shapes run only in the embedded dynamic engine (SC2012 without --dynamic) |
| `stdlib.math.acos` | Math.acos | dynamic-only | `SC2012` |  |
| `stdlib.math.asin` | Math.asin | dynamic-only | `SC2012` |  |
| `stdlib.math.atan` | Math.atan | dynamic-only | `SC2012` |  |
| `stdlib.math.atan2` | Math.atan2 | dynamic-only | `SC2012` |  |
| `stdlib.math.cbrt` | Math.cbrt | dynamic-only | `SC2012` |  |
| `stdlib.math.ceil` | Math.ceil | static |  | compiles statically at arity 1; other declared call shapes run only in the embedded dynamic engine (SC2012 without --dynamic) |
| `stdlib.math.cos` | Math.cos | dynamic-only | `SC2012` |  |
| `stdlib.math.exp` | Math.exp | dynamic-only | `SC2012` |  |
| `stdlib.math.floor` | Math.floor | static |  | compiles statically at arity 1 |
| `stdlib.math.hypot` | Math.hypot | dynamic-only | `SC2012` |  |
| `stdlib.math.log` | Math.log | dynamic-only | `SC2012` |  |
| `stdlib.math.log10` | Math.log10 | dynamic-only | `SC2012` |  |
| `stdlib.math.log2` | Math.log2 | dynamic-only | `SC2012` |  |
| `stdlib.math.max` | Math.max | static |  | compiles statically at arity 2 |
| `stdlib.math.min` | Math.min | static |  | compiles statically at arity 2 |
| `stdlib.math.pow` | Math.pow | dynamic-only | `SC2012` |  |
| `stdlib.math.random` | Math.random | static |  | compiles statically at arity 0 |
| `stdlib.math.round` | Math.round | static |  | compiles statically at arity 1; other declared call shapes run only in the embedded dynamic engine (SC2012 without --dynamic) |
| `stdlib.math.sign` | Math.sign | dynamic-only | `SC2012` |  |
| `stdlib.math.sin` | Math.sin | dynamic-only | `SC2012` |  |
| `stdlib.math.sqrt` | Math.sqrt | dynamic-only | `SC2012` |  |
| `stdlib.math.tan` | Math.tan | dynamic-only | `SC2012` |  |
| `stdlib.math.trunc` | Math.trunc | static |  | compiles statically at arity 1; other declared call shapes run only in the embedded dynamic engine (SC2012 without --dynamic) |
| `stdlib.number.toFixed` | number.prototype.toFixed | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.number.toPrecision` | number.prototype.toPrecision | dynamic-only | `SC2012` |  |
| `stdlib.number.toString` | number.prototype.toString | dynamic-only | `SC2012` |  |
| `stdlib.readable-stream-default-controller.close` | ReadableStreamDefaultController.close | static |  | Node 24.15.0 / Undici 7.24.4; facets: state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-controller.constructor` | ReadableStreamDefaultController constructor | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the constructor object is unavailable in the dynamic engine; static controller handles come from underlying-source callbacks |
| `stdlib.readable-stream-default-controller.desired-size` | ReadableStreamDefaultController.desiredSize | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read, state-machine; differential evidence: generated:stream-traces |
| `stdlib.readable-stream-default-controller.enqueue` | ReadableStreamDefaultController.enqueue | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, liveness, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-controller.error` | ReadableStreamDefaultController.error | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.cancel` | ReadableStreamDefaultReader.cancel | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.closed` | ReadableStreamDefaultReader.closed | static |  | Node 24.15.0 / Undici 7.24.4; facets: promise-settlement, property-read, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.constructor` | ReadableStreamDefaultReader constructor | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the constructor object is unavailable in the dynamic engine; static reader handles come from ReadableStream.getReader() |
| `stdlib.readable-stream-default-reader.read` | ReadableStreamDefaultReader.read | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.release-lock` | ReadableStreamDefaultReader.releaseLock | static |  | Node 24.15.0 / Undici 7.24.4; facets: promise-settlement, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.cancel` | ReadableStream.cancel | static |  | Node 24.15.0 / Undici 7.24.4; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.constructor` | ReadableStream constructor | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, callback-this, callback-order, state-machine; differential evidence: generated:stream-traces, fixture:static-stream-this |
| `stdlib.readable-stream.from` | ReadableStream.from | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, missing-arguments, surplus-arguments, liveness; differential evidence: generated:webidl-operations, generated:stream-traces |
| `stdlib.readable-stream.get-reader` | ReadableStream.getReader | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, identity, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.locked` | ReadableStream.locked | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read, state-machine; differential evidence: generated:stream-traces |
| `stdlib.readable-stream.pipeThrough` | ReadableStream.pipeThrough | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; the wider Web Streams graph is outside the native readable-stream slice |
| `stdlib.readable-stream.pipeTo` | ReadableStream.pipeTo | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic Web Streams bridge exposes only an explicit unsupported stub for this operation |
| `stdlib.readable-stream.symbol.asyncIterator` | ReadableStream.[Symbol.asyncIterator] | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; symbol-keyed async iterator handles have no compiler lowering in either tier; use values() with --dynamic |
| `stdlib.readable-stream.tee` | ReadableStream.tee | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic Web Streams bridge exposes only an explicit unsupported stub for this operation |
| `stdlib.readable-stream.values` | ReadableStream.values | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; the wider Web Streams graph is outside the native readable-stream slice |
| `stdlib.request.arrayBuffer` | Request.arrayBuffer | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.attribute` | Request.attribute | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.blob` | Request.blob | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.body` | Request.body | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.bodyUsed` | Request.bodyUsed | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.bytes` | Request.bytes | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.cache` | Request.cache | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.clone` | Request.clone | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.constructor` | Request constructor | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.credentials` | Request.credentials | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.destination` | Request.destination | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.duplex` | Request.duplex | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.formData` | Request.formData | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.headers` | Request.headers | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.integrity` | Request.integrity | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.isHistoryNavigation` | Request.isHistoryNavigation | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.isReloadNavigation` | Request.isReloadNavigation | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.json` | Request.json | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.keepalive` | Request.keepalive | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.method` | Request.method | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.mode` | Request.mode | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.redirect` | Request.redirect | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.referrer` | Request.referrer | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.referrerPolicy` | Request.referrerPolicy | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.signal` | Request.signal | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.text` | Request.text | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.request.url` | Request.url | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; typed source has no compiler bridge for this interface in either tier |
| `stdlib.response-init.headers` | ResponseInit.headers | static |  | Node 24.15.0 / Undici 7.24.4; conversion: Headers, record, or sequence-of-pairs snapshot; differential evidence: fixture:static |
| `stdlib.response-init.status` | ResponseInit.status | static |  | Node 24.15.0 / Undici 7.24.4; conversion: WebIDL unsigned-short conversion followed by the 200–599 range check; differential evidence: fixture:static |
| `stdlib.response-init.statusText` | ResponseInit.statusText | static |  | Node 24.15.0 / Undici 7.24.4; conversion: WebIDL ByteString with HTTP reason-phrase validation; differential evidence: fixture:static |
| `stdlib.response.arrayBuffer` | Response.arrayBuffer | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; free-standing ArrayBuffer values have no static representation; use Response.bytes() |
| `stdlib.response.blob` | Response.blob | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic fetch bridge does not implement this Response operation |
| `stdlib.response.body` | Response.body | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.bodyUsed` | Response.bodyUsed | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.bytes` | Response.bytes | static |  | Node 24.15.0 / Undici 7.24.4; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.clone` | Response.clone | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic fetch bridge does not implement this Response operation |
| `stdlib.response.constructor` | Response constructor | static |  | Node 24.15.0 / Undici 7.24.4; facets: webidl-conversion, body-consumption, state-machine, error-shape; supported scope: BodyInit is string, Uint8Array/Buffer, ReadableStream&lt;Uint8Array&gt;, null/undefined, or a checked-dynamic value that follows the supported WebIDL string conversion; ResponseInit is headers/status/statusText; differential evidence: fixture:static |
| `stdlib.response.formData` | Response.formData | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; the dynamic fetch bridge does not implement this Response operation |
| `stdlib.response.headers` | Response.headers | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.json` | Response.json | static |  | Node 24.15.0 / Undici 7.24.4; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.ok` | Response.ok | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.redirected` | Response.redirected | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.static.error` | Response.error | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; Response static constructor-object operations have no compiler lowering in either tier |
| `stdlib.response.static.json` | Response.json | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; Response static constructor-object operations have no compiler lowering in either tier |
| `stdlib.response.static.redirect` | Response.redirect | unsupported | `SC2020` | Node 24.15.0 / Undici 7.24.4; Response static constructor-object operations have no compiler lowering in either tier |
| `stdlib.response.status` | Response.status | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.statusText` | Response.statusText | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.text` | Response.text | static |  | Node 24.15.0 / Undici 7.24.4; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.type` | Response.type | dynamic-only | `SC2020` | Node 24.15.0 / Undici 7.24.4; the member is outside the native static handle projection |
| `stdlib.response.url` | Response.url | static |  | Node 24.15.0 / Undici 7.24.4; facets: property-read; differential evidence: fixture:static |
| `stdlib.set.add` | Set.prototype.add | static |  |  |
| `stdlib.set.clear` | Set.prototype.clear | static |  |  |
| `stdlib.set.delete` | Set.prototype.delete | static |  |  |
| `stdlib.set.difference` | Set.prototype.difference | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.forEach` | Set.prototype.forEach | static |  |  |
| `stdlib.set.has` | Set.prototype.has | static |  |  |
| `stdlib.set.intersection` | Set.prototype.intersection | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isDisjointFrom` | Set.prototype.isDisjointFrom | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isSubsetOf` | Set.prototype.isSubsetOf | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isSupersetOf` | Set.prototype.isSupersetOf | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.symmetricDifference` | Set.prototype.symmetricDifference | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.union` | Set.prototype.union | static |  | compiles over Set receivers with Set arguments (the general ReadonlySetLike argument forms are refused per site) |
| `stdlib.string.at` | string.prototype.at | dynamic-only | `SC2012` |  |
| `stdlib.string.charAt` | string.prototype.charAt | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.charCodeAt` | string.prototype.charCodeAt | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.endsWith` | string.prototype.endsWith | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.includes` | string.prototype.includes | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.indexOf` | string.prototype.indexOf | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.isWellFormed` | string.prototype.isWellFormed | static |  | the lowered call form takes no arguments |
| `stdlib.string.padEnd` | string.prototype.padEnd | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.padStart` | string.prototype.padStart | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.repeat` | string.prototype.repeat | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.replace` | string.prototype.replace | dynamic-only | `SC2012` |  |
| `stdlib.string.replaceAll` | string.prototype.replaceAll | dynamic-only | `SC2012` |  |
| `stdlib.string.slice` | string.prototype.slice | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.split` | string.prototype.split | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.startsWith` | string.prototype.startsWith | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.substring` | string.prototype.substring | static |  | the lowered call form takes 1 to 2 arguments |
| `stdlib.string.toLowerCase` | string.prototype.toLowerCase | static |  | the lowered call form takes no arguments |
| `stdlib.string.toUpperCase` | string.prototype.toUpperCase | static |  | the lowered call form takes no arguments |
| `stdlib.string.toWellFormed` | string.prototype.toWellFormed | static |  | the lowered call form takes no arguments |
| `stdlib.string.trim` | string.prototype.trim | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimEnd` | string.prototype.trimEnd | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimLeft` | string.prototype.trimLeft | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimRight` | string.prototype.trimRight | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimStart` | string.prototype.trimStart | static |  | the lowered call form takes no arguments |

## Compiler coverage statement

The manifest's own description of how it is projected and what its
statuses promise, verbatim:

- Entries are projected mechanically from the compiler's own decision tables: the diagnostics registry, the unsupported-syntax dispatch tables, the stdlib and node-builtin lowering tables, and the supported-builtin-module list. Nothing is hand-maintained; the manifest regenerates byte-identically from the source tree at this version.
- Absence from this manifest means 'not projected', never 'unsupported'. Surfaces lowered through dedicated code paths rather than tables are not yet projected: console, JSON, Promise/async and the timer surface, the net/http/tls/https/dgram/dns/assert/test/stream/readline module member surfaces, template literals, the regex slice, global functions (parseInt, parseFloat, isNaN, isFinite), and the process surface outside its ambient slice.
- The ambient-nondeterminism and ambient-authority surfaces the library sidecar's determinism attestation scans ARE projected even where they lower through dedicated code paths — the Date compositions (stdlib.date.*), perf_hooks' performance.now, and the process global's ambient reads and authority calls (node-builtin.process.*) — so a determinism fence can name every surface the attestation demotes on.
- stdlib and node-builtin member entries name surface whose LOWERED call forms are constrained (arity, argument shapes); declared call forms outside the lowered set are refused per site, with code SC2020 for standard-library and node-builtin surface.
- Entries with status 'unsupported' or 'dynamic-only' describe where the named code is raised: forms of the construct outside the supported subset are refused with that code — not that every form of the named feature is refused. Supported forms appear as their own static entries where a table projects them.
- Entries with status 'dynamic-only' compile when the build embeds the dynamic engine (--dynamic); without the flag each use site is refused with the entry's code.
- The engine-free fetch projection targets Node 24.15.0 with bundled Undici 7.24.4. Each projected row names the differential evidence that guards it; changing the pinned Node or Undici version is an explicit profile update.
- The fetch profile also contains a runtime-reflected census of the selected fetch, abort, Headers, and readable-stream interfaces plus RequestInit/ResponseInit dictionary reads. Static, dynamic-only, and unsupported census rows are projected here; its explicitly out-of-scope metadata rows and adjacent-interface exclusions remain in the profile so absence is deliberate rather than ambiguous.
- Process-level diagnostic codes are not surface entries: SC0001-SC0004 are preflight gates, SC1110 is a comptime evaluation failure, SC3001/SC3002 are backend/target tier refusals, SC9001/SC9002 are internal errors.
- No scheduling metadata is published; entry ids are the stable diff keys across releases.

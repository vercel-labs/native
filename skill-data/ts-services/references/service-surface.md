<!-- GENERATED FILE — do not edit by hand.
     Derived byte-for-byte from the pinned compiler's surface manifest:
       resolved through packages/core/scripts/scriptc_toolchain.mjs
     Regenerate after any compiler pin move:
       node packages/core/scripts/gen_service_surface.mjs
     Verify without writing:
       node packages/core/scripts/gen_service_surface.mjs --check -->

# Service compile surface — scriptc 0.4.11

What TypeScript under `src/services/` can use, as stated by the pinned
compiler itself (surface manifest schema 2, 975 entries:
884 static, 91 unsupported).

How to read the tables:

- **static** — compiles in the engine-free static tier services use.
- Compilation is native-only; unsupported dependencies receive build diagnostics.
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
| `syntax.async-generators` | typed async generator functions and methods | static |  | lazy bodies with queued next/return/throw requests, await, direct yield, and Node-compatible completion promises |
| `syntax.await-using-declarations` | block- and function-scoped await using declarations | static |  | LIFO asynchronous disposal through [Symbol.asyncDispose], with synchronous fallback, of class instances, object literals and AsyncDisposable-typed values |
| `syntax.bigint-literals` | bigint literals | static |  | arbitrary-precision values in decimal, binary, octal, and hexadecimal spelling |
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
| `syntax.finally-abrupt-completions` | abrupt completions through finally | static |  | return, throw, break, continue, and labeled jumps run crossed finally blocks; a finally completion replaces the pending one |
| `syntax.for-await-async-generators` | for await over typed async generators | static |  | awaits each IteratorResult and closes the generator on early break |
| `syntax.for-await-class-async-iterators` | for await over statically represented class async iterators | static |  | drives zero-parameter next methods returning Promise&lt;{ value, done? }&gt; and awaits an optional zero-parameter return method on abrupt completion |
| `syntax.for-await-readable-streams` | for await over Node Readable and Web ReadableStream values | static |  | closes on every abrupt completion, with destroyOnReturn and preventCancel literal options |
| `syntax.for-using-of` | for (using ... of ...) over arrays | static |  | each array element is disposed at the end of its iteration, including break and continue paths |
| `syntax.namespaces` | namespaces | unsupported | `SC1090` |  |
| `syntax.spread-arguments` | spread arguments | static |  | non-empty fixed tuples flatten into fixed signatures with evaluate-once ordering; arrays, Sets, and statically represented class iterables spread into typed rest parameters |
| `syntax.typeof-expressions` | typeof expressions | unsupported | `SC1090` |  |
| `syntax.using-declarations` | block- and function-scoped using declarations | static |  | LIFO disposal on normal and abrupt scope exit through [Symbol.dispose], of class instances, object literals and Disposable-typed values; a failing disposal raises a SuppressedError with error and suppressed |
| `syntax.with-statements` | 'with' statements (runtime scope injection has no static resolution — bind the object to a variable and read members through it) | unsupported | `SC1090` |  |

## Diagnostic fences

The SC codes an author can hit at the module/program level, and what
each one refuses.

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `diagnostic.sc1010` | package imports | unsupported | `SC1010` | relative imports (./file, ../dir/file), package.json-mediated project imports (#alias via the imports field, self-name references via exports), statically compiled npm packages, and the built-in fs, fs/promises, path, os, url, crypto, zlib, child_process, net, http, tls, https, http2, dgram, dns, dns/promises, util, util/types, string_decoder, querystring, readline, events, stream, stream/promises, stream/consumers, stream/web, buffer, assert, assert/strict, worker_threads, cluster, tty, async_hooks, timers, timers/promises, diagnostics_channel, perf_hooks, module, v8, and console modules (bare or node:-prefixed) and node:test (node:-prefixed only, like in Node) are supported |
| `diagnostic.sc1012` | default exports/imports | unsupported | `SC1012` | use named exports: export function f() {} / import { f } from "./m" |
| `diagnostic.sc1013` | namespace imports (* as ns) | unsupported | `SC1013` |  |
| `diagnostic.sc1014` | re-exports and export lists | unsupported | `SC1014` | export declarations directly: export function f() {} |
| `diagnostic.sc1015` | dynamic import() | unsupported | `SC1015` |  |
| `diagnostic.sc1016` | circular imports | unsupported | `SC1016` | ES-module cycles of let/const/function bindings compile as-is; rewrite the named construct (a named import instead of a namespace, a const instead of a default-export expression or var, a class declared before the code that can reach it) or break the named edge |
| `diagnostic.sc1020` | class expressions | unsupported | `SC1020` |  |
| `diagnostic.sc1030` | var declarations | unsupported | `SC1030` |  |
| `diagnostic.sc1031` | destructuring | unsupported | `SC1031` |  |
| `diagnostic.sc1040` | loose equality (== and !=) | unsupported | `SC1040` | primitive and primitive-union coercions plus the x == null / x != null idiom compile statically; object-to-primitive comparisons can execute valueOf/toString — convert the object explicitly first |
| `diagnostic.sc1042` | logical operators on mixed operand types | unsupported | `SC1042` | give both operands the same type (number, string, or boolean) |
| `diagnostic.sc1043` | comparing non-number, non-string values | unsupported | `SC1043` |  |
| `diagnostic.sc1045` | increment/decrement in expression position | unsupported | `SC1045` | use ++/-- as a standalone statement, or write x = x + 1 |
| `diagnostic.sc1050` | labeled break/continue | unsupported | `SC1050` |  |
| `diagnostic.sc1052` | for-in loops | unsupported | `SC1052` |  |
| `diagnostic.sc1062` | destructuring catch clause bindings | unsupported | `SC1062` | bind an identifier (catch (e)) and narrow it — 'e instanceof Error' exposes .name/.message, typeof tests expose primitives |
| `diagnostic.sc1070` | async/await | unsupported | `SC1070` |  |
| `diagnostic.sc1071` | generators | unsupported | `SC1071` |  |
| `diagnostic.sc1080` | 'this' outside a class method | unsupported | `SC1080` |  |
| `diagnostic.sc1090` | this syntax | unsupported | `SC1090` |  |
| `diagnostic.sc1091` | writing an undeclared name in a JavaScript source | unsupported | `SC1091` | declare the name to keep the module native: a sloppy-mode write creates a property on Node's global object, which a native binary has none of (with --node-islands=auto, the default, a required module with this write runs in a Node island instead), and a strict-mode write throws |
| `diagnostic.sc1100` | operations on 'unknown' values | unsupported | `SC1100` | validate with 'as &lt;type&gt;' first — the cast checks the dynamic value at runtime and throws on mismatch |
| `diagnostic.sc1101` | converting typed values to 'unknown' | unsupported | `SC1101` | numbers, strings, booleans, JSON-safe records/arrays/unions (a deep copy), functions, program class instances, and supported native handles convert into 'unknown' slots; functions, exact-class round trips, and handles preserve identity, while this value's type has no dynamic representation yet |
| `diagnostic.sc1120` | this regex feature | unsupported | `SC1120` | supported: literal regexes with the g/i/m/s/u/v/y flags — .test(), .exec()/.match()/.matchAll(), named capture groups (.groups, $&lt;name&gt; templates, \k&lt;name&gt;), .source/.flags, and string replace/replaceAll/split with string replacement templates |
| `diagnostic.sc2001` | values of types outside the compilable set (constructor objects and library-derived or unresolved generic shapes) | unsupported | `SC2001` |  |
| `diagnostic.sc2002` | record shape flows outside the width-copy rules (shapes must match exactly or width-coerce) | unsupported | `SC2002` |  |
| `diagnostic.sc2003` | union-to-union conversions outside the re-tagging rule | unsupported | `SC2003` |  |
| `diagnostic.sc2004` | uses of a binding whose declaration did not compile (cascade marker) | unsupported | `SC2004` |  |
| `diagnostic.sc2005` | values whose type keeps a generic call signature (a compiled function is one concrete signature) | unsupported | `SC2005` |  |
| `diagnostic.sc2006` | index-signature object types outside the supported shape | unsupported | `SC2006` |  |
| `diagnostic.sc2007` | values of overloaded function type (a compiled function value is one signature) | unsupported | `SC2007` |  |
| `diagnostic.sc2008` | intersection types with no resolved lowering | unsupported | `SC2008` |  |
| `diagnostic.sc2009` | supported container and function shapes over a component type outside its slot | unsupported | `SC2009` |  |
| `diagnostic.sc2010` | runtime JavaScript execution | unsupported | `SC2010` |  |
| `diagnostic.sc2011` | 'any'-typed values and the operations on them | unsupported | `SC2011` |  |
| `diagnostic.sc2012` | standard-library forms without native lowering | unsupported | `SC2012` |  |
| `diagnostic.sc2013` | npm package imports and values without native lowering | unsupported | `SC2013` |  |
| `diagnostic.sc2014` | writes through a value held from process.env (a snapshot, not the live table) | unsupported | `SC2014` |  |
| `diagnostic.sc2015` | an empty array literal used at an element type that was not decided where it is written | unsupported | `SC2015` |  |
| `diagnostic.sc2020` | standard-library or @types/node surface with no lowering | unsupported | `SC2020` |  |

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
| `node-builtin.console` | console | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.constants` | constants | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.crypto` | crypto | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.dgram` | dgram | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.diagnostics_channel` | diagnostics_channel | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.dns` | dns | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.dns.promises` | dns/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.events` | events | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.fs` | fs | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.fs.callbacks` | fs error-first callbacks | static | native filesystem callbacks, including stored platform adapter functions |
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
| `node-builtin.process` | process | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.punycode` | punycode | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.querystring` | querystring | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.readline` | readline | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.readline.promises` | readline/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.sea` | node:sea | static | recognized module (node:-prefixed specifier only, matching Node) |
| `node-builtin.stream` | stream | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream.consumers` | stream/consumers | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream.promises` | stream/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.stream.web` | stream/web | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.string_decoder` | string_decoder | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.test` | node:test | static | recognized module (node:-prefixed specifier only, matching Node) |
| `node-builtin.timers` | timers | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.timers.promises` | timers/promises | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.tls` | tls | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.tty` | tty | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.url` | url | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.util` | util | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.util.types` | util/types | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.v8` | v8 | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.worker_threads` | worker_threads | static | recognized module (bare and node:-prefixed specifiers) |
| `node-builtin.worker_threads.metadata` | worker_threads metadata | static | current-thread metadata and the worker's parent message port |
| `node-builtin.zlib` | zlib | static | recognized module (bare and node:-prefixed specifiers) |

### Module member surface

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `node-builtin.assert.doesNotReject` | assert.doesNotReject | unsupported | `SC2020` | await the promise directly — an unexpected rejection already fails the test |
| `node-builtin.assert.ifError` | assert.ifError | unsupported | `SC2020` | test explicitly instead: assert.strictEqual(err, null) / assert.strictEqual(err, undefined) |
| `node-builtin.assert.rejects` | assert.rejects | unsupported | `SC2020` | await the promise inside assert.throws's callback story instead: try { await p; assert.fail("expected rejection") } catch { ... } |
| `node-builtin.assert.strict.doesNotReject` | assert/strict.doesNotReject | unsupported | `SC2020` | await the promise directly — an unexpected rejection already fails the test |
| `node-builtin.assert.strict.ifError` | assert/strict.ifError | unsupported | `SC2020` | test explicitly instead: assert.strictEqual(err, null) / assert.strictEqual(err, undefined) |
| `node-builtin.assert.strict.rejects` | assert/strict.rejects | unsupported | `SC2020` | await the promise inside assert.throws's callback story instead: try { await p; assert.fail("expected rejection") } catch { ... } |
| `node-builtin.buffer.INSPECT_MAX_BYTES` | buffer.INSPECT_MAX_BYTES | static |  | constant value read |
| `node-builtin.buffer.SlowBuffer` | buffer.SlowBuffer | static |  |  |
| `node-builtin.buffer.isAscii` | buffer.isAscii | static |  |  |
| `node-builtin.buffer.isUtf8` | buffer.isUtf8 | static |  |  |
| `node-builtin.buffer.kMaxLength` | buffer.kMaxLength | static |  | constant value read |
| `node-builtin.buffer.kStringMaxLength` | buffer.kStringMaxLength | static |  | constant value read |
| `node-builtin.buffer.transcode` | buffer.transcode | static |  |  |
| `node-builtin.child_process.execFile` | child_process.execFile | unsupported | `SC2020` | the callback forms execFile(file, callback), execFile(file, args, callback), and execFile(file, args, { encoding: 'utf8', maxBuffer: N }, callback) lower; maxBuffer limits each stream as in Node; other options and reached no-callback calls remain fenced, while util.promisify(execFile) retains its wider options slice |
| `node-builtin.child_process.execFileSync` | child_process.execFileSync | static |  |  |
| `node-builtin.child_process.execSync` | child_process.execSync | static |  |  |
| `node-builtin.child_process.fork` | child_process.fork | static |  |  |
| `node-builtin.child_process.spawn` | child_process.spawn | static |  |  |
| `node-builtin.child_process.spawnSync` | child_process.spawnSync | static |  |  |
| `node-builtin.cluster.isMaster` | cluster.isMaster | static |  | constant value read |
| `node-builtin.cluster.isPrimary` | cluster.isPrimary | static |  | constant value read |
| `node-builtin.cluster.isWorker` | cluster.isWorker | static |  | constant value read |
| `node-builtin.crypto.checkPrime` | crypto.checkPrime | static |  |  |
| `node-builtin.crypto.checkPrimeSync` | crypto.checkPrimeSync | static |  |  |
| `node-builtin.crypto.createCipheriv` | crypto.createCipheriv | static |  |  |
| `node-builtin.crypto.createDecipheriv` | crypto.createDecipheriv | static |  |  |
| `node-builtin.crypto.createDiffieHellman` | crypto.createDiffieHellman | static |  |  |
| `node-builtin.crypto.createDiffieHellmanGroup` | crypto.createDiffieHellmanGroup | static |  |  |
| `node-builtin.crypto.createECDH` | crypto.createECDH | static |  |  |
| `node-builtin.crypto.createHash` | crypto.createHash | static |  |  |
| `node-builtin.crypto.createHmac` | crypto.createHmac | static |  |  |
| `node-builtin.crypto.createPrivateKey` | crypto.createPrivateKey | static |  |  |
| `node-builtin.crypto.createPublicKey` | crypto.createPublicKey | static |  |  |
| `node-builtin.crypto.createSecretKey` | crypto.createSecretKey | static |  |  |
| `node-builtin.crypto.createSign` | crypto.createSign | static |  |  |
| `node-builtin.crypto.createVerify` | crypto.createVerify | static |  |  |
| `node-builtin.crypto.diffieHellman` | crypto.diffieHellman | static |  |  |
| `node-builtin.crypto.generateKey` | crypto.generateKey | static |  |  |
| `node-builtin.crypto.generateKeyPair` | crypto.generateKeyPair | static |  |  |
| `node-builtin.crypto.generateKeyPairSync` | crypto.generateKeyPairSync | static |  |  |
| `node-builtin.crypto.generateKeySync` | crypto.generateKeySync | static |  |  |
| `node-builtin.crypto.generatePrime` | crypto.generatePrime | static |  |  |
| `node-builtin.crypto.generatePrimeSync` | crypto.generatePrimeSync | static |  |  |
| `node-builtin.crypto.getCipherInfo` | crypto.getCipherInfo | static |  |  |
| `node-builtin.crypto.getDiffieHellman` | crypto.getDiffieHellman | static |  |  |
| `node-builtin.crypto.getRandomValues` | crypto.getRandomValues | static |  |  |
| `node-builtin.crypto.hash` | crypto.hash | static |  |  |
| `node-builtin.crypto.hkdf` | crypto.hkdf | static |  |  |
| `node-builtin.crypto.hkdfSync` | crypto.hkdfSync | static |  |  |
| `node-builtin.crypto.pbkdf2` | crypto.pbkdf2 | static |  |  |
| `node-builtin.crypto.pbkdf2Sync` | crypto.pbkdf2Sync | static |  |  |
| `node-builtin.crypto.privateDecrypt` | crypto.privateDecrypt | unsupported | `SC2020` | RSA encryption has no lowering — the asymmetric crypto surface is RSA and EC KeyObjects (generateKeyPair, createPrivateKey, createPublicKey), sign, verify, createSign, createVerify, createECDH, and createDiffieHellman |
| `node-builtin.crypto.privateEncrypt` | crypto.privateEncrypt | unsupported | `SC2020` | RSA encryption has no lowering — the asymmetric crypto surface is RSA and EC KeyObjects (generateKeyPair, createPrivateKey, createPublicKey), sign, verify, createSign, createVerify, createECDH, and createDiffieHellman |
| `node-builtin.crypto.publicDecrypt` | crypto.publicDecrypt | unsupported | `SC2020` | RSA encryption has no lowering — the asymmetric crypto surface is RSA and EC KeyObjects (generateKeyPair, createPrivateKey, createPublicKey), sign, verify, createSign, createVerify, createECDH, and createDiffieHellman |
| `node-builtin.crypto.publicEncrypt` | crypto.publicEncrypt | unsupported | `SC2020` | RSA encryption has no lowering — the asymmetric crypto surface is RSA and EC KeyObjects (generateKeyPair, createPrivateKey, createPublicKey), sign, verify, createSign, createVerify, createECDH, and createDiffieHellman |
| `node-builtin.crypto.randomBytes` | crypto.randomBytes | static |  |  |
| `node-builtin.crypto.randomFill` | crypto.randomFill | static |  |  |
| `node-builtin.crypto.randomFillSync` | crypto.randomFillSync | static |  |  |
| `node-builtin.crypto.randomInt` | crypto.randomInt | static |  |  |
| `node-builtin.crypto.randomUUID` | crypto.randomUUID | static |  |  |
| `node-builtin.crypto.randomUUIDv7` | crypto.randomUUIDv7 | static |  |  |
| `node-builtin.crypto.scrypt` | crypto.scrypt | static |  |  |
| `node-builtin.crypto.scryptSync` | crypto.scryptSync | static |  |  |
| `node-builtin.crypto.setFips` | crypto.setFips | unsupported | `SC2020` | a compiled binary has no FIPS provider to enable, and Node itself throws on setFips(true) in a non-FIPS build — getFips() answers 0 here |
| `node-builtin.crypto.sign` | crypto.sign | static |  |  |
| `node-builtin.crypto.timingSafeEqual` | crypto.timingSafeEqual | static |  |  |
| `node-builtin.crypto.verify` | crypto.verify | static |  |  |
| `node-builtin.diagnostics_channel.channel` | diagnostics_channel.channel | static |  |  |
| `node-builtin.diagnostics_channel.hasSubscribers` | diagnostics_channel.hasSubscribers | static |  |  |
| `node-builtin.diagnostics_channel.subscribe` | diagnostics_channel.subscribe | static |  |  |
| `node-builtin.diagnostics_channel.tracingChannel` | diagnostics_channel.tracingChannel | static |  |  |
| `node-builtin.diagnostics_channel.unsubscribe` | diagnostics_channel.unsubscribe | static |  |  |
| `node-builtin.dns.ADDRCONFIG` | dns.ADDRCONFIG | static |  | constant value read |
| `node-builtin.dns.ADDRGETNETWORKPARAMS` | dns.ADDRGETNETWORKPARAMS | static |  | constant value read |
| `node-builtin.dns.ALL` | dns.ALL | static |  | constant value read |
| `node-builtin.dns.BADFAMILY` | dns.BADFAMILY | static |  | constant value read |
| `node-builtin.dns.BADFLAGS` | dns.BADFLAGS | static |  | constant value read |
| `node-builtin.dns.BADHINTS` | dns.BADHINTS | static |  | constant value read |
| `node-builtin.dns.BADNAME` | dns.BADNAME | static |  | constant value read |
| `node-builtin.dns.BADQUERY` | dns.BADQUERY | static |  | constant value read |
| `node-builtin.dns.BADRESP` | dns.BADRESP | static |  | constant value read |
| `node-builtin.dns.BADSTR` | dns.BADSTR | static |  | constant value read |
| `node-builtin.dns.CANCELLED` | dns.CANCELLED | static |  | constant value read |
| `node-builtin.dns.CONNREFUSED` | dns.CONNREFUSED | static |  | constant value read |
| `node-builtin.dns.DESTRUCTION` | dns.DESTRUCTION | static |  | constant value read |
| `node-builtin.dns.EOF` | dns.EOF | static |  | constant value read |
| `node-builtin.dns.FILE` | dns.FILE | static |  | constant value read |
| `node-builtin.dns.FORMERR` | dns.FORMERR | static |  | constant value read |
| `node-builtin.dns.LOADIPHLPAPI` | dns.LOADIPHLPAPI | static |  | constant value read |
| `node-builtin.dns.NODATA` | dns.NODATA | static |  | constant value read |
| `node-builtin.dns.NOMEM` | dns.NOMEM | static |  | constant value read |
| `node-builtin.dns.NONAME` | dns.NONAME | static |  | constant value read |
| `node-builtin.dns.NOTFOUND` | dns.NOTFOUND | static |  | constant value read |
| `node-builtin.dns.NOTIMP` | dns.NOTIMP | static |  | constant value read |
| `node-builtin.dns.NOTINITIALIZED` | dns.NOTINITIALIZED | static |  | constant value read |
| `node-builtin.dns.REFUSED` | dns.REFUSED | static |  | constant value read |
| `node-builtin.dns.SERVFAIL` | dns.SERVFAIL | static |  | constant value read |
| `node-builtin.dns.TIMEOUT` | dns.TIMEOUT | static |  | constant value read |
| `node-builtin.dns.V4MAPPED` | dns.V4MAPPED | static |  | constant value read |
| `node-builtin.dns.promises.ADDRGETNETWORKPARAMS` | dns/promises.ADDRGETNETWORKPARAMS | static |  | constant value read |
| `node-builtin.dns.promises.BADFAMILY` | dns/promises.BADFAMILY | static |  | constant value read |
| `node-builtin.dns.promises.BADFLAGS` | dns/promises.BADFLAGS | static |  | constant value read |
| `node-builtin.dns.promises.BADHINTS` | dns/promises.BADHINTS | static |  | constant value read |
| `node-builtin.dns.promises.BADNAME` | dns/promises.BADNAME | static |  | constant value read |
| `node-builtin.dns.promises.BADQUERY` | dns/promises.BADQUERY | static |  | constant value read |
| `node-builtin.dns.promises.BADRESP` | dns/promises.BADRESP | static |  | constant value read |
| `node-builtin.dns.promises.BADSTR` | dns/promises.BADSTR | static |  | constant value read |
| `node-builtin.dns.promises.CANCELLED` | dns/promises.CANCELLED | static |  | constant value read |
| `node-builtin.dns.promises.CONNREFUSED` | dns/promises.CONNREFUSED | static |  | constant value read |
| `node-builtin.dns.promises.DESTRUCTION` | dns/promises.DESTRUCTION | static |  | constant value read |
| `node-builtin.dns.promises.EOF` | dns/promises.EOF | static |  | constant value read |
| `node-builtin.dns.promises.FILE` | dns/promises.FILE | static |  | constant value read |
| `node-builtin.dns.promises.FORMERR` | dns/promises.FORMERR | static |  | constant value read |
| `node-builtin.dns.promises.LOADIPHLPAPI` | dns/promises.LOADIPHLPAPI | static |  | constant value read |
| `node-builtin.dns.promises.NODATA` | dns/promises.NODATA | static |  | constant value read |
| `node-builtin.dns.promises.NOMEM` | dns/promises.NOMEM | static |  | constant value read |
| `node-builtin.dns.promises.NONAME` | dns/promises.NONAME | static |  | constant value read |
| `node-builtin.dns.promises.NOTFOUND` | dns/promises.NOTFOUND | static |  | constant value read |
| `node-builtin.dns.promises.NOTIMP` | dns/promises.NOTIMP | static |  | constant value read |
| `node-builtin.dns.promises.NOTINITIALIZED` | dns/promises.NOTINITIALIZED | static |  | constant value read |
| `node-builtin.dns.promises.REFUSED` | dns/promises.REFUSED | static |  | constant value read |
| `node-builtin.dns.promises.SERVFAIL` | dns/promises.SERVFAIL | static |  | constant value read |
| `node-builtin.dns.promises.TIMEOUT` | dns/promises.TIMEOUT | static |  | constant value read |
| `node-builtin.fs.accessSync` | fs.accessSync | static |  |  |
| `node-builtin.fs.appendFileSync` | fs.appendFileSync | static |  |  |
| `node-builtin.fs.chmodSync` | fs.chmodSync | static |  |  |
| `node-builtin.fs.chownSync` | fs.chownSync | static |  |  |
| `node-builtin.fs.closeSync` | fs.closeSync | static |  |  |
| `node-builtin.fs.constants` | fs.constants | static |  | node_constants.cc's fs group under the target libc's macros; members a platform lacks read as undefined |
| `node-builtin.fs.copyFileSync` | fs.copyFileSync | static |  |  |
| `node-builtin.fs.cpSync` | fs.cpSync | static |  |  |
| `node-builtin.fs.createReadStream` | fs.createReadStream | static |  |  |
| `node-builtin.fs.createWriteStream` | fs.createWriteStream | static |  |  |
| `node-builtin.fs.existsSync` | fs.existsSync | static |  |  |
| `node-builtin.fs.fchmodSync` | fs.fchmodSync | static |  |  |
| `node-builtin.fs.fchownSync` | fs.fchownSync | static |  |  |
| `node-builtin.fs.fdatasyncSync` | fs.fdatasyncSync | static |  |  |
| `node-builtin.fs.fstatSync` | fs.fstatSync | static |  |  |
| `node-builtin.fs.fsyncSync` | fs.fsyncSync | static |  |  |
| `node-builtin.fs.ftruncateSync` | fs.ftruncateSync | static |  |  |
| `node-builtin.fs.futimesSync` | fs.futimesSync | static |  |  |
| `node-builtin.fs.globSync` | fs.globSync | static |  |  |
| `node-builtin.fs.lchownSync` | fs.lchownSync | static |  |  |
| `node-builtin.fs.linkSync` | fs.linkSync | static |  |  |
| `node-builtin.fs.lstatSync` | fs.lstatSync | static |  |  |
| `node-builtin.fs.lutimesSync` | fs.lutimesSync | static |  |  |
| `node-builtin.fs.mkdirSync` | fs.mkdirSync | static |  |  |
| `node-builtin.fs.mkdtempSync` | fs.mkdtempSync | static |  |  |
| `node-builtin.fs.openSync` | fs.openSync | static |  |  |
| `node-builtin.fs.opendirSync` | fs.opendirSync | static |  |  |
| `node-builtin.fs.promises.access` | fs/promises.access | static |  |  |
| `node-builtin.fs.promises.appendFile` | fs/promises.appendFile | static |  |  |
| `node-builtin.fs.promises.chmod` | fs/promises.chmod | static |  |  |
| `node-builtin.fs.promises.chown` | fs/promises.chown | static |  |  |
| `node-builtin.fs.promises.copyFile` | fs/promises.copyFile | static |  |  |
| `node-builtin.fs.promises.cp` | fs/promises.cp | static |  |  |
| `node-builtin.fs.promises.glob` | fs/promises.glob | static |  |  |
| `node-builtin.fs.promises.lchown` | fs/promises.lchown | static |  |  |
| `node-builtin.fs.promises.link` | fs/promises.link | static |  |  |
| `node-builtin.fs.promises.lstat` | fs/promises.lstat | static |  |  |
| `node-builtin.fs.promises.lutimes` | fs/promises.lutimes | static |  |  |
| `node-builtin.fs.promises.mkdir` | fs/promises.mkdir | static |  |  |
| `node-builtin.fs.promises.mkdtemp` | fs/promises.mkdtemp | static |  |  |
| `node-builtin.fs.promises.open` | fs/promises.open | static |  |  |
| `node-builtin.fs.promises.opendir` | fs/promises.opendir | static |  |  |
| `node-builtin.fs.promises.readFile` | fs/promises.readFile | static |  |  |
| `node-builtin.fs.promises.readdir` | fs/promises.readdir | static |  |  |
| `node-builtin.fs.promises.readlink` | fs/promises.readlink | static |  |  |
| `node-builtin.fs.promises.realpath` | fs/promises.realpath | static |  |  |
| `node-builtin.fs.promises.rename` | fs/promises.rename | static |  |  |
| `node-builtin.fs.promises.rm` | fs/promises.rm | static |  |  |
| `node-builtin.fs.promises.rmdir` | fs/promises.rmdir | static |  |  |
| `node-builtin.fs.promises.stat` | fs/promises.stat | static |  |  |
| `node-builtin.fs.promises.statfs` | fs/promises.statfs | static |  |  |
| `node-builtin.fs.promises.symlink` | fs/promises.symlink | static |  |  |
| `node-builtin.fs.promises.truncate` | fs/promises.truncate | static |  |  |
| `node-builtin.fs.promises.unlink` | fs/promises.unlink | static |  |  |
| `node-builtin.fs.promises.utimes` | fs/promises.utimes | static |  |  |
| `node-builtin.fs.promises.writeFile` | fs/promises.writeFile | static |  |  |
| `node-builtin.fs.readFileSync` | fs.readFileSync | static |  |  |
| `node-builtin.fs.readSync` | fs.readSync | static |  |  |
| `node-builtin.fs.readdirSync` | fs.readdirSync | static |  |  |
| `node-builtin.fs.readlinkSync` | fs.readlinkSync | static |  |  |
| `node-builtin.fs.readvSync` | fs.readvSync | static |  |  |
| `node-builtin.fs.realpathSync` | fs.realpathSync | static |  |  |
| `node-builtin.fs.realpathSync.native` | fs.realpathSync.native | static |  |  |
| `node-builtin.fs.rename` | fs.rename | static |  |  |
| `node-builtin.fs.renameSync` | fs.renameSync | static |  |  |
| `node-builtin.fs.rmSync` | fs.rmSync | static |  |  |
| `node-builtin.fs.rmdirSync` | fs.rmdirSync | static |  |  |
| `node-builtin.fs.statSync` | fs.statSync | static |  |  |
| `node-builtin.fs.statfsSync` | fs.statfsSync | static |  |  |
| `node-builtin.fs.symlinkSync` | fs.symlinkSync | static |  |  |
| `node-builtin.fs.truncateSync` | fs.truncateSync | static |  |  |
| `node-builtin.fs.unlinkSync` | fs.unlinkSync | static |  |  |
| `node-builtin.fs.unwatchFile` | fs.unwatchFile | static |  | removes one listener, or every listener, from a resolved path's poller |
| `node-builtin.fs.utimesSync` | fs.utimesSync | static |  |  |
| `node-builtin.fs.watch` | fs.watch | static |  |  |
| `node-builtin.fs.watchFile` | fs.watchFile | static |  | stat polling of a resolved path with Stats listeners, in statement position; bigint: true is refused |
| `node-builtin.fs.writeFileSync` | fs.writeFileSync | static |  |  |
| `node-builtin.fs.writeSync` | fs.writeSync | static |  |  |
| `node-builtin.fs.writevSync` | fs.writevSync | static |  |  |
| `node-builtin.http.maxHeaderSize` | http.maxHeaderSize | static |  | constant value read |
| `node-builtin.http2.connect` | http2.connect | unsupported | `SC2020` | HTTP/2 client sessions have no lowering — the lowered http2 surface is the SERVER side: createSecureServer({ allowHTTP1: true, cert, key }), which serves HTTP/1.1 only (ALPN never offers h2 — h2-capable clients negotiate down); an HTTP/1.1 client is https.request |
| `node-builtin.http2.createServer` | http2.createServer | unsupported | `SC2020` | cleartext (h2c) servers have no lowering — the lowered http2 surface is createSecureServer({ allowHTTP1: true, cert, key }), which serves HTTP/1.1 over TLS (plain HTTP/1.1 is http.createServer) |
| `node-builtin.module.constants` | module.constants | static |  | compileCacheStatus with Node's four values; a compiled program's enableCompileCache() answers DISABLED |
| `node-builtin.module.createRequire` | module.createRequire | unsupported | `SC2020` | the lowered shape is a const binding (or a proven stable top-level let/var) over createRequire(import.meta.url) (or __filename) whose require calls take STATIC string literals — builtins, project modules (including #imports), relative .json documents and natively compiled npm packages resolve at build time; dynamic specifiers cannot exist in a compiled binary's fixed module graph |
| `node-builtin.module.enableCompileCache` | module.enableCompileCache | static |  |  |
| `node-builtin.module.flushCompileCache` | module.flushCompileCache | static |  |  |
| `node-builtin.module.getCompileCacheDir` | module.getCompileCacheDir | static |  |  |
| `node-builtin.module.isBuiltin` | module.isBuiltin | unsupported | `SC2020` | the lowered call checks a string against the baked Node v24 list, including bare/node: aliases and prefix-only builtins |
| `node-builtin.module.syncBuiltinESMExports` | module.syncBuiltinESMExports | unsupported | `SC2020` | the direct zero-argument call statement refreshes the ES module namespace copy of events.defaultMaxListeners, the one builtin export a program can change |
| `node-builtin.net.getDefaultAutoSelectFamilyAttemptTimeout` | net.getDefaultAutoSelectFamilyAttemptTimeout | static |  |  |
| `node-builtin.net.isIP` | net.isIP | static |  |  |
| `node-builtin.net.isIPv4` | net.isIPv4 | static |  |  |
| `node-builtin.net.isIPv6` | net.isIPv6 | static |  |  |
| `node-builtin.net.setDefaultAutoSelectFamilyAttemptTimeout` | net.setDefaultAutoSelectFamilyAttemptTimeout | static |  |  |
| `node-builtin.os.EOL` | os.EOL | static |  | constant value read |
| `node-builtin.os.arch` | os.arch | static |  |  |
| `node-builtin.os.availableParallelism` | os.availableParallelism | static |  |  |
| `node-builtin.os.constants` | os.constants | static |  | the platform's dlopen, errno, signals and priority groups; members a platform lacks read as undefined |
| `node-builtin.os.cpus` | os.cpus | static |  |  |
| `node-builtin.os.devNull` | os.devNull | static |  | constant value read |
| `node-builtin.os.endianness` | os.endianness | static |  |  |
| `node-builtin.os.freemem` | os.freemem | static |  |  |
| `node-builtin.os.getPriority` | os.getPriority | static |  |  |
| `node-builtin.os.homedir` | os.homedir | static |  |  |
| `node-builtin.os.hostname` | os.hostname | static |  |  |
| `node-builtin.os.loadavg` | os.loadavg | static |  |  |
| `node-builtin.os.machine` | os.machine | static |  |  |
| `node-builtin.os.networkInterfaces` | os.networkInterfaces | static |  |  |
| `node-builtin.os.platform` | os.platform | static |  |  |
| `node-builtin.os.release` | os.release | static |  |  |
| `node-builtin.os.setPriority` | os.setPriority | static |  |  |
| `node-builtin.os.tmpdir` | os.tmpdir | static |  |  |
| `node-builtin.os.totalmem` | os.totalmem | static |  |  |
| `node-builtin.os.type` | os.type | static |  |  |
| `node-builtin.os.uptime` | os.uptime | static |  |  |
| `node-builtin.os.userInfo` | os.userInfo | static |  |  |
| `node-builtin.os.version` | os.version | static |  |  |
| `node-builtin.path._makeLong` | path._makeLong | static |  |  |
| `node-builtin.path.basename` | path.basename | static |  |  |
| `node-builtin.path.delimiter` | path.delimiter | static |  | constant value read |
| `node-builtin.path.dirname` | path.dirname | static |  |  |
| `node-builtin.path.extname` | path.extname | static |  |  |
| `node-builtin.path.format` | path.format | static |  |  |
| `node-builtin.path.isAbsolute` | path.isAbsolute | static |  |  |
| `node-builtin.path.join` | path.join | static |  |  |
| `node-builtin.path.matchesGlob` | path.matchesGlob | static |  |  |
| `node-builtin.path.normalize` | path.normalize | static |  |  |
| `node-builtin.path.parse` | path.parse | static |  |  |
| `node-builtin.path.posix._makeLong` | path/posix._makeLong | static |  |  |
| `node-builtin.path.posix.basename` | path/posix.basename | static |  |  |
| `node-builtin.path.posix.delimiter` | path/posix.delimiter | static |  | constant value read |
| `node-builtin.path.posix.dirname` | path/posix.dirname | static |  |  |
| `node-builtin.path.posix.extname` | path/posix.extname | static |  |  |
| `node-builtin.path.posix.format` | path/posix.format | static |  |  |
| `node-builtin.path.posix.isAbsolute` | path/posix.isAbsolute | static |  |  |
| `node-builtin.path.posix.join` | path/posix.join | static |  |  |
| `node-builtin.path.posix.matchesGlob` | path/posix.matchesGlob | static |  |  |
| `node-builtin.path.posix.normalize` | path/posix.normalize | static |  |  |
| `node-builtin.path.posix.parse` | path/posix.parse | static |  |  |
| `node-builtin.path.posix.relative` | path/posix.relative | static |  |  |
| `node-builtin.path.posix.resolve` | path/posix.resolve | static |  |  |
| `node-builtin.path.posix.sep` | path/posix.sep | static |  | constant value read |
| `node-builtin.path.posix.toNamespacedPath` | path/posix.toNamespacedPath | static |  |  |
| `node-builtin.path.relative` | path.relative | static |  |  |
| `node-builtin.path.resolve` | path.resolve | static |  |  |
| `node-builtin.path.sep` | path.sep | static |  | constant value read |
| `node-builtin.path.toNamespacedPath` | path.toNamespacedPath | static |  |  |
| `node-builtin.path.win32._makeLong` | path/win32._makeLong | static |  |  |
| `node-builtin.path.win32.basename` | path/win32.basename | static |  |  |
| `node-builtin.path.win32.delimiter` | path/win32.delimiter | static |  | constant value read |
| `node-builtin.path.win32.dirname` | path/win32.dirname | static |  |  |
| `node-builtin.path.win32.extname` | path/win32.extname | static |  |  |
| `node-builtin.path.win32.format` | path/win32.format | static |  |  |
| `node-builtin.path.win32.isAbsolute` | path/win32.isAbsolute | static |  |  |
| `node-builtin.path.win32.join` | path/win32.join | static |  |  |
| `node-builtin.path.win32.matchesGlob` | path/win32.matchesGlob | static |  |  |
| `node-builtin.path.win32.normalize` | path/win32.normalize | static |  |  |
| `node-builtin.path.win32.parse` | path/win32.parse | static |  |  |
| `node-builtin.path.win32.relative` | path/win32.relative | static |  |  |
| `node-builtin.path.win32.resolve` | path/win32.resolve | static |  |  |
| `node-builtin.path.win32.sep` | path/win32.sep | static |  | constant value read |
| `node-builtin.path.win32.toNamespacedPath` | path/win32.toNamespacedPath | static |  |  |
| `node-builtin.perf_hooks.monitorEventLoopDelay` | perf_hooks.monitorEventLoopDelay | static |  | an unref'd sampling interval records the delay histogram; enable, disable, reset, percentile and the min, max, mean, stddev, count and exceeds readings are supported |
| `node-builtin.perf_hooks.performance.clearMarks` | perf_hooks.performance.clearMarks | static |  |  |
| `node-builtin.perf_hooks.performance.clearMeasures` | perf_hooks.performance.clearMeasures | static |  |  |
| `node-builtin.perf_hooks.performance.eventLoopUtilization` | perf_hooks.performance.eventLoopUtilization | static |  | active time is the main thread's CPU time since the loop started; the one- and two-argument difference forms are supported |
| `node-builtin.perf_hooks.performance.getEntries` | perf_hooks.performance.getEntries | static |  | getEntries, getEntriesByName, and getEntriesByType read the same timeline |
| `node-builtin.perf_hooks.performance.mark` | perf_hooks.performance.mark | static |  | records a mark in the thread's performance timeline at the live clock or the given startTime |
| `node-builtin.perf_hooks.performance.measure` | perf_hooks.performance.measure | static |  | the mark-name, timestamp, and options forms are one surface |
| `node-builtin.perf_hooks.performance.now` | perf_hooks.performance.now | static |  | the global performance object and the performance.now.bind(performance) function value reach the same clock |
| `node-builtin.process.allowedNodeEnvironmentFlags` | process.allowedNodeEnvironmentFlags | static |  | one stable set of the option names the compatibility target accepts in NODE_OPTIONS |
| `node-builtin.process.argv` | process.argv | static |  |  |
| `node-builtin.process.argv0` | process.argv0 | static |  |  |
| `node-builtin.process.availableMemory` | process.availableMemory | static |  |  |
| `node-builtin.process.chdir` | process.chdir | static |  |  |
| `node-builtin.process.columns` | process.columns | static |  | the columns read on the process stdio streams (terminal geometry) |
| `node-builtin.process.constrainedMemory` | process.constrainedMemory | static |  |  |
| `node-builtin.process.cpuUsage` | process.cpuUsage | static |  | the plain-sample and previous-value diff forms are one surface |
| `node-builtin.process.cwd` | process.cwd | static |  |  |
| `node-builtin.process.env` | process.env | static |  | reads, writes, deletes, and enumeration of the process environment (the process global) |
| `node-builtin.process.execArgv` | process.execArgv | static |  |  |
| `node-builtin.process.execPath` | process.execPath | static |  |  |
| `node-builtin.process.exit` | process.exit | static |  | process.exit and the process._exiting flag read are one surface |
| `node-builtin.process.exitCode` | process.exitCode | static |  | numeric writes in statement position set the implicit exit status; reads answer the assigned code or undefined; process.exit() reads it |
| `node-builtin.process.features` | process.features | static |  | Node's feature flags as booleans that describe the compiled binary: inspector, debug, uv, tls_ocsp, cached_builtins, quic and typescript are false, the others match Node |
| `node-builtin.process.getBuiltinModule` | process.getBuiltinModule | static |  | a literal id of a supported module answers its namespace; a computed id serves the path families, os, util/types, node:sea and current-thread worker_threads metadata, answers undefined for an id Node does not have, and throws SC2020 for Node's other modules |
| `node-builtin.process.getegid` | process.getegid | static |  |  |
| `node-builtin.process.geteuid` | process.geteuid | static |  |  |
| `node-builtin.process.getgid` | process.getgid | static |  |  |
| `node-builtin.process.getgroups` | process.getgroups | static |  |  |
| `node-builtin.process.getuid` | process.getuid | static |  |  |
| `node-builtin.process.hrtime` | process.hrtime | static |  | native monotonic tuple clock and bigint member; direct calls and stored JavaScript callable values |
| `node-builtin.process.isTTY` | process.isTTY | static |  | the isTTY read on process.stdin/stdout/stderr — one surface across the three streams |
| `node-builtin.process.kill` | process.kill | static |  | the signal-name and signal-number forms are one surface |
| `node-builtin.process.loadEnvFile` | process.loadEnvFile | static |  |  |
| `node-builtin.process.memoryUsage` | process.memoryUsage | static |  | the record and memoryUsage.rss() read live memory state; external and arrayBuffers are 0 |
| `node-builtin.process.pid` | process.pid | static |  |  |
| `node-builtin.process.ppid` | process.ppid | static |  |  |
| `node-builtin.process.release` | process.release | static |  | the compatibility target's release metadata as one stable read-only object |
| `node-builtin.process.resourceUsage` | process.resourceUsage | static |  | getrusage's 16 fields — every field read samples live machine state |
| `node-builtin.process.rows` | process.rows | static |  | the rows read on process.stdout/stderr (terminal geometry) |
| `node-builtin.process.threadCpuUsage` | process.threadCpuUsage | static |  | the plain-sample and previous-value diff forms are one surface |
| `node-builtin.process.title` | process.title | static |  | reads and writes of the process title are one surface |
| `node-builtin.process.umask` | process.umask | static |  |  |
| `node-builtin.process.uptime` | process.uptime | static |  |  |
| `node-builtin.process.versions` | process.versions | static |  | shared version dictionary containing node and openssl; other components are absent unless defined by the program |
| `node-builtin.punycode.decode` | punycode.decode | static |  |  |
| `node-builtin.punycode.encode` | punycode.encode | static |  |  |
| `node-builtin.punycode.toASCII` | punycode.toASCII | static |  |  |
| `node-builtin.punycode.toUnicode` | punycode.toUnicode | static |  |  |
| `node-builtin.punycode.ucs2.decode` | punycode.ucs2.decode | static |  |  |
| `node-builtin.punycode.ucs2.encode` | punycode.ucs2.encode | static |  |  |
| `node-builtin.punycode.version` | punycode.version | static |  | constant value read |
| `node-builtin.querystring.decode` | querystring.decode | static |  |  |
| `node-builtin.querystring.encode` | querystring.encode | static |  |  |
| `node-builtin.querystring.escape` | querystring.escape | static |  |  |
| `node-builtin.querystring.parse` | querystring.parse | static |  |  |
| `node-builtin.querystring.stringify` | querystring.stringify | static |  |  |
| `node-builtin.querystring.unescape` | querystring.unescape | static |  |  |
| `node-builtin.querystring.unescapeBuffer` | querystring.unescapeBuffer | static |  |  |
| `node-builtin.readline.createInterface` | readline.createInterface | static |  |  |
| `node-builtin.readline.promises.createInterface` | readline/promises.createInterface | static |  |  |
| `node-builtin.sea.getAsset` | sea.getAsset | static |  |  |
| `node-builtin.sea.getAssetAsBlob` | sea.getAssetAsBlob | static |  |  |
| `node-builtin.sea.getAssetKeys` | sea.getAssetKeys | static |  |  |
| `node-builtin.sea.getRawAsset` | sea.getRawAsset | static |  |  |
| `node-builtin.sea.isSea` | sea.isSea | static |  |  |
| `node-builtin.stream.consumers.blob` | stream/consumers.blob | unsupported | `SC2020` | collecting a stream into a Blob is not supported yet — buffer(stream) collects the same bytes as a Buffer (new Blob([buffer]) wraps them), text(stream) the decoded text |
| `node-builtin.timers.promises.scheduler.wait` | timers/promises.scheduler.wait | static |  |  |
| `node-builtin.timers.promises.scheduler.yield` | timers/promises.scheduler.yield | static |  |  |
| `node-builtin.timers.promises.setImmediate` | timers/promises.setImmediate | static |  |  |
| `node-builtin.timers.promises.setTimeout` | timers/promises.setTimeout | static |  |  |
| `node-builtin.tls.DEFAULT_MAX_VERSION` | tls.DEFAULT_MAX_VERSION | static |  | constant value read |
| `node-builtin.tls.DEFAULT_MIN_VERSION` | tls.DEFAULT_MIN_VERSION | static |  | constant value read |
| `node-builtin.tls.connect` | tls.connect | unsupported | `SC2020` | the lowered TLS client is https.request({ hostname, port, path, method, ca?, rejectUnauthorized? }); raw tls.connect sockets have no lowering yet |
| `node-builtin.tls.createSecureContext` | tls.createSecureContext | unsupported | `SC2020` | the lowered form is createSecureContext({ cert, key }) — an opaque SecureContext handle for SNI callbacks (http2.createSecureServer accepts SNICallback); other options fence by name |
| `node-builtin.tls.getCACertificates` | tls.getCACertificates | static |  | the per-type cached PEM bundle: 'default' and 'extra' additionally read NODE_EXTRA_CA_CERTS, 'system' the platform store |
| `node-builtin.tls.rootCertificates` | tls.rootCertificates | static |  | the value read; answers the same bundled array as getCACertificates('bundled'), but fenced under its own id — the spelling an author writes |
| `node-builtin.tls.setDefaultCACertificates` | tls.setDefaultCACertificates | static |  | replaces the default set and the client trust anchors for the rest of the process |
| `node-builtin.tty.isatty` | tty.isatty | static |  |  |
| `node-builtin.url.domainToASCII` | url.domainToASCII | static |  |  |
| `node-builtin.url.domainToUnicode` | url.domainToUnicode | static |  |  |
| `node-builtin.url.fileURLToPath` | url.fileURLToPath | static |  |  |
| `node-builtin.url.fileURLToPathBuffer` | url.fileURLToPathBuffer | static |  |  |
| `node-builtin.url.format` | url.format | static |  |  |
| `node-builtin.url.parse` | url.parse | static |  |  |
| `node-builtin.url.pathToFileURL` | url.pathToFileURL | static |  |  |
| `node-builtin.url.resolve` | url.resolve | static |  |  |
| `node-builtin.url.urlToHttpOptions` | url.urlToHttpOptions | static |  |  |
| `node-builtin.util._extend` | util._extend | static |  |  |
| `node-builtin.util.aborted` | util.aborted | static |  |  |
| `node-builtin.util.callbackify` | util.callbackify | static |  |  |
| `node-builtin.util.convertProcessSignalToExitCode` | util.convertProcessSignalToExitCode | static |  |  |
| `node-builtin.util.debounce` | util.debounce | static |  |  |
| `node-builtin.util.debug` | util.debug | static |  |  |
| `node-builtin.util.debuglog` | util.debuglog | static |  |  |
| `node-builtin.util.deprecate` | util.deprecate | static |  |  |
| `node-builtin.util.diff` | util.diff | static |  |  |
| `node-builtin.util.getSystemErrorMap` | util.getSystemErrorMap | static |  |  |
| `node-builtin.util.getSystemErrorMessage` | util.getSystemErrorMessage | static |  |  |
| `node-builtin.util.getSystemErrorName` | util.getSystemErrorName | static |  |  |
| `node-builtin.util.inherits` | util.inherits | static |  |  |
| `node-builtin.util.isArray` | util.isArray | static |  |  |
| `node-builtin.util.isDeepStrictEqual` | util.isDeepStrictEqual | static |  |  |
| `node-builtin.util.parseArgs` | util.parseArgs | static |  |  |
| `node-builtin.util.parseEnv` | util.parseEnv | static |  |  |
| `node-builtin.util.promisify` | util.promisify | unsupported | `SC2020` | the lowered shapes are const bindings over child_process.execFile, child_process.exec, setTimeout, setImmediate, stream.finished, stream.pipeline, the zlib callback one-shots, the crypto callback functions, dns.lookup, dns.lookupService and the fs callback functions with an fs/promises counterpart, plus typed callback-last function values whose callback takes (error?: Error \| null, value?); call the bound function directly |
| `node-builtin.util.stripVTControlCharacters` | util.stripVTControlCharacters | static |  |  |
| `node-builtin.util.styleText` | util.styleText | static |  |  |
| `node-builtin.util.throttle` | util.throttle | static |  |  |
| `node-builtin.util.toUSVString` | util.toUSVString | static |  |  |
| `node-builtin.util.types.isAnyArrayBuffer` | util/types.isAnyArrayBuffer | static |  |  |
| `node-builtin.util.types.isArrayBuffer` | util/types.isArrayBuffer | static |  |  |
| `node-builtin.util.types.isArrayBufferView` | util/types.isArrayBufferView | static |  |  |
| `node-builtin.util.types.isAsyncFunction` | util/types.isAsyncFunction | static |  |  |
| `node-builtin.util.types.isBigInt64Array` | util/types.isBigInt64Array | static |  |  |
| `node-builtin.util.types.isBigIntObject` | util/types.isBigIntObject | static |  |  |
| `node-builtin.util.types.isBigUint64Array` | util/types.isBigUint64Array | static |  |  |
| `node-builtin.util.types.isBooleanObject` | util/types.isBooleanObject | static |  |  |
| `node-builtin.util.types.isBoxedPrimitive` | util/types.isBoxedPrimitive | static |  |  |
| `node-builtin.util.types.isCryptoKey` | util/types.isCryptoKey | static |  |  |
| `node-builtin.util.types.isDataView` | util/types.isDataView | static |  |  |
| `node-builtin.util.types.isDate` | util/types.isDate | static |  |  |
| `node-builtin.util.types.isExternal` | util/types.isExternal | static |  |  |
| `node-builtin.util.types.isFloat16Array` | util/types.isFloat16Array | static |  |  |
| `node-builtin.util.types.isFloat32Array` | util/types.isFloat32Array | static |  |  |
| `node-builtin.util.types.isFloat64Array` | util/types.isFloat64Array | static |  |  |
| `node-builtin.util.types.isGeneratorFunction` | util/types.isGeneratorFunction | static |  |  |
| `node-builtin.util.types.isGeneratorObject` | util/types.isGeneratorObject | static |  |  |
| `node-builtin.util.types.isInt16Array` | util/types.isInt16Array | static |  |  |
| `node-builtin.util.types.isInt32Array` | util/types.isInt32Array | static |  |  |
| `node-builtin.util.types.isInt8Array` | util/types.isInt8Array | static |  |  |
| `node-builtin.util.types.isKeyObject` | util/types.isKeyObject | static |  |  |
| `node-builtin.util.types.isMap` | util/types.isMap | static |  |  |
| `node-builtin.util.types.isMapIterator` | util/types.isMapIterator | static |  |  |
| `node-builtin.util.types.isNativeError` | util/types.isNativeError | static |  |  |
| `node-builtin.util.types.isNumberObject` | util/types.isNumberObject | static |  |  |
| `node-builtin.util.types.isPromise` | util/types.isPromise | static |  |  |
| `node-builtin.util.types.isProxy` | util/types.isProxy | static |  |  |
| `node-builtin.util.types.isRegExp` | util/types.isRegExp | static |  |  |
| `node-builtin.util.types.isSet` | util/types.isSet | static |  |  |
| `node-builtin.util.types.isSetIterator` | util/types.isSetIterator | static |  |  |
| `node-builtin.util.types.isSharedArrayBuffer` | util/types.isSharedArrayBuffer | static |  |  |
| `node-builtin.util.types.isStringObject` | util/types.isStringObject | static |  |  |
| `node-builtin.util.types.isSymbolObject` | util/types.isSymbolObject | static |  |  |
| `node-builtin.util.types.isTypedArray` | util/types.isTypedArray | static |  |  |
| `node-builtin.util.types.isUint16Array` | util/types.isUint16Array | static |  |  |
| `node-builtin.util.types.isUint32Array` | util/types.isUint32Array | static |  |  |
| `node-builtin.util.types.isUint8Array` | util/types.isUint8Array | static |  |  |
| `node-builtin.util.types.isUint8ClampedArray` | util/types.isUint8ClampedArray | static |  |  |
| `node-builtin.util.types.isWeakMap` | util/types.isWeakMap | static |  |  |
| `node-builtin.util.types.isWeakSet` | util/types.isWeakSet | static |  |  |
| `node-builtin.v8.getHeapStatistics` | v8.getHeapStatistics | static |  |  |
| `node-builtin.worker_threads.SHARE_ENV` | worker_threads.SHARE_ENV | static |  | constant value read |
| `node-builtin.worker_threads.Worker` | worker_threads.Worker | static |  | native threads with statically compiled entry points, workerData, argv and message events |
| `node-builtin.worker_threads.isMainThread` | worker_threads.isMainThread | static |  | constant value read |
| `node-builtin.worker_threads.threadId` | worker_threads.threadId | static |  | constant value read |
| `node-builtin.zlib.DEFLATE` | zlib.DEFLATE | static |  | constant value read |
| `node-builtin.zlib.DEFLATERAW` | zlib.DEFLATERAW | static |  | constant value read |
| `node-builtin.zlib.GUNZIP` | zlib.GUNZIP | static |  | constant value read |
| `node-builtin.zlib.GZIP` | zlib.GZIP | static |  | constant value read |
| `node-builtin.zlib.INFLATE` | zlib.INFLATE | static |  | constant value read |
| `node-builtin.zlib.INFLATERAW` | zlib.INFLATERAW | static |  | constant value read |
| `node-builtin.zlib.UNZIP` | zlib.UNZIP | static |  | constant value read |
| `node-builtin.zlib.ZLIB_VERNUM` | zlib.ZLIB_VERNUM | static |  | constant value read |
| `node-builtin.zlib.ZSTD_CLEVEL_DEFAULT` | zlib.ZSTD_CLEVEL_DEFAULT | static |  | constant value read |
| `node-builtin.zlib.ZSTD_COMPRESS` | zlib.ZSTD_COMPRESS | static |  | constant value read |
| `node-builtin.zlib.ZSTD_DECOMPRESS` | zlib.ZSTD_DECOMPRESS | static |  | constant value read |
| `node-builtin.zlib.ZSTD_btlazy2` | zlib.ZSTD_btlazy2 | static |  | constant value read |
| `node-builtin.zlib.ZSTD_btopt` | zlib.ZSTD_btopt | static |  | constant value read |
| `node-builtin.zlib.ZSTD_btultra` | zlib.ZSTD_btultra | static |  | constant value read |
| `node-builtin.zlib.ZSTD_btultra2` | zlib.ZSTD_btultra2 | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_chainLog` | zlib.ZSTD_c_chainLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_checksumFlag` | zlib.ZSTD_c_checksumFlag | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_compressionLevel` | zlib.ZSTD_c_compressionLevel | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_contentSizeFlag` | zlib.ZSTD_c_contentSizeFlag | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_dictIDFlag` | zlib.ZSTD_c_dictIDFlag | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_enableLongDistanceMatching` | zlib.ZSTD_c_enableLongDistanceMatching | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_hashLog` | zlib.ZSTD_c_hashLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_jobSize` | zlib.ZSTD_c_jobSize | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_ldmBucketSizeLog` | zlib.ZSTD_c_ldmBucketSizeLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_ldmHashLog` | zlib.ZSTD_c_ldmHashLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_ldmHashRateLog` | zlib.ZSTD_c_ldmHashRateLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_ldmMinMatch` | zlib.ZSTD_c_ldmMinMatch | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_minMatch` | zlib.ZSTD_c_minMatch | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_nbWorkers` | zlib.ZSTD_c_nbWorkers | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_overlapLog` | zlib.ZSTD_c_overlapLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_searchLog` | zlib.ZSTD_c_searchLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_strategy` | zlib.ZSTD_c_strategy | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_targetLength` | zlib.ZSTD_c_targetLength | static |  | constant value read |
| `node-builtin.zlib.ZSTD_c_windowLog` | zlib.ZSTD_c_windowLog | static |  | constant value read |
| `node-builtin.zlib.ZSTD_d_windowLogMax` | zlib.ZSTD_d_windowLogMax | static |  | constant value read |
| `node-builtin.zlib.ZSTD_dfast` | zlib.ZSTD_dfast | static |  | constant value read |
| `node-builtin.zlib.ZSTD_e_continue` | zlib.ZSTD_e_continue | static |  | constant value read |
| `node-builtin.zlib.ZSTD_e_end` | zlib.ZSTD_e_end | static |  | constant value read |
| `node-builtin.zlib.ZSTD_e_flush` | zlib.ZSTD_e_flush | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_GENERIC` | zlib.ZSTD_error_GENERIC | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_checksum_wrong` | zlib.ZSTD_error_checksum_wrong | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_corruption_detected` | zlib.ZSTD_error_corruption_detected | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_dictionaryCreation_failed` | zlib.ZSTD_error_dictionaryCreation_failed | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_dictionary_corrupted` | zlib.ZSTD_error_dictionary_corrupted | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_dictionary_wrong` | zlib.ZSTD_error_dictionary_wrong | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_dstBuffer_null` | zlib.ZSTD_error_dstBuffer_null | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_dstSize_tooSmall` | zlib.ZSTD_error_dstSize_tooSmall | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_frameParameter_unsupported` | zlib.ZSTD_error_frameParameter_unsupported | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_frameParameter_windowTooLarge` | zlib.ZSTD_error_frameParameter_windowTooLarge | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_init_missing` | zlib.ZSTD_error_init_missing | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_literals_headerWrong` | zlib.ZSTD_error_literals_headerWrong | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_maxSymbolValue_tooLarge` | zlib.ZSTD_error_maxSymbolValue_tooLarge | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_maxSymbolValue_tooSmall` | zlib.ZSTD_error_maxSymbolValue_tooSmall | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_memory_allocation` | zlib.ZSTD_error_memory_allocation | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_noForwardProgress_destFull` | zlib.ZSTD_error_noForwardProgress_destFull | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_noForwardProgress_inputEmpty` | zlib.ZSTD_error_noForwardProgress_inputEmpty | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_no_error` | zlib.ZSTD_error_no_error | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_parameter_combination_unsupported` | zlib.ZSTD_error_parameter_combination_unsupported | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_parameter_outOfBound` | zlib.ZSTD_error_parameter_outOfBound | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_parameter_unsupported` | zlib.ZSTD_error_parameter_unsupported | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_prefix_unknown` | zlib.ZSTD_error_prefix_unknown | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_srcSize_wrong` | zlib.ZSTD_error_srcSize_wrong | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_stabilityCondition_notRespected` | zlib.ZSTD_error_stabilityCondition_notRespected | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_stage_wrong` | zlib.ZSTD_error_stage_wrong | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_tableLog_tooLarge` | zlib.ZSTD_error_tableLog_tooLarge | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_version_unsupported` | zlib.ZSTD_error_version_unsupported | static |  | constant value read |
| `node-builtin.zlib.ZSTD_error_workSpace_tooSmall` | zlib.ZSTD_error_workSpace_tooSmall | static |  | constant value read |
| `node-builtin.zlib.ZSTD_fast` | zlib.ZSTD_fast | static |  | constant value read |
| `node-builtin.zlib.ZSTD_greedy` | zlib.ZSTD_greedy | static |  | constant value read |
| `node-builtin.zlib.ZSTD_lazy` | zlib.ZSTD_lazy | static |  | constant value read |
| `node-builtin.zlib.ZSTD_lazy2` | zlib.ZSTD_lazy2 | static |  | constant value read |
| `node-builtin.zlib.Z_BEST_COMPRESSION` | zlib.Z_BEST_COMPRESSION | static |  | constant value read |
| `node-builtin.zlib.Z_BEST_SPEED` | zlib.Z_BEST_SPEED | static |  | constant value read |
| `node-builtin.zlib.Z_BLOCK` | zlib.Z_BLOCK | static |  | constant value read |
| `node-builtin.zlib.Z_BUF_ERROR` | zlib.Z_BUF_ERROR | static |  | constant value read |
| `node-builtin.zlib.Z_DATA_ERROR` | zlib.Z_DATA_ERROR | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_CHUNK` | zlib.Z_DEFAULT_CHUNK | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_COMPRESSION` | zlib.Z_DEFAULT_COMPRESSION | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_LEVEL` | zlib.Z_DEFAULT_LEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_MEMLEVEL` | zlib.Z_DEFAULT_MEMLEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_STRATEGY` | zlib.Z_DEFAULT_STRATEGY | static |  | constant value read |
| `node-builtin.zlib.Z_DEFAULT_WINDOWBITS` | zlib.Z_DEFAULT_WINDOWBITS | static |  | constant value read |
| `node-builtin.zlib.Z_ERRNO` | zlib.Z_ERRNO | static |  | constant value read |
| `node-builtin.zlib.Z_FILTERED` | zlib.Z_FILTERED | static |  | constant value read |
| `node-builtin.zlib.Z_FINISH` | zlib.Z_FINISH | static |  | constant value read |
| `node-builtin.zlib.Z_FIXED` | zlib.Z_FIXED | static |  | constant value read |
| `node-builtin.zlib.Z_FULL_FLUSH` | zlib.Z_FULL_FLUSH | static |  | constant value read |
| `node-builtin.zlib.Z_HUFFMAN_ONLY` | zlib.Z_HUFFMAN_ONLY | static |  | constant value read |
| `node-builtin.zlib.Z_MAX_CHUNK` | zlib.Z_MAX_CHUNK | static |  | constant value read |
| `node-builtin.zlib.Z_MAX_LEVEL` | zlib.Z_MAX_LEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_MAX_MEMLEVEL` | zlib.Z_MAX_MEMLEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_MAX_WINDOWBITS` | zlib.Z_MAX_WINDOWBITS | static |  | constant value read |
| `node-builtin.zlib.Z_MEM_ERROR` | zlib.Z_MEM_ERROR | static |  | constant value read |
| `node-builtin.zlib.Z_MIN_CHUNK` | zlib.Z_MIN_CHUNK | static |  | constant value read |
| `node-builtin.zlib.Z_MIN_LEVEL` | zlib.Z_MIN_LEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_MIN_MEMLEVEL` | zlib.Z_MIN_MEMLEVEL | static |  | constant value read |
| `node-builtin.zlib.Z_MIN_WINDOWBITS` | zlib.Z_MIN_WINDOWBITS | static |  | constant value read |
| `node-builtin.zlib.Z_NEED_DICT` | zlib.Z_NEED_DICT | static |  | constant value read |
| `node-builtin.zlib.Z_NO_COMPRESSION` | zlib.Z_NO_COMPRESSION | static |  | constant value read |
| `node-builtin.zlib.Z_NO_FLUSH` | zlib.Z_NO_FLUSH | static |  | constant value read |
| `node-builtin.zlib.Z_OK` | zlib.Z_OK | static |  | constant value read |
| `node-builtin.zlib.Z_PARTIAL_FLUSH` | zlib.Z_PARTIAL_FLUSH | static |  | constant value read |
| `node-builtin.zlib.Z_RLE` | zlib.Z_RLE | static |  | constant value read |
| `node-builtin.zlib.Z_STREAM_END` | zlib.Z_STREAM_END | static |  | constant value read |
| `node-builtin.zlib.Z_STREAM_ERROR` | zlib.Z_STREAM_ERROR | static |  | constant value read |
| `node-builtin.zlib.Z_SYNC_FLUSH` | zlib.Z_SYNC_FLUSH | static |  | constant value read |
| `node-builtin.zlib.Z_VERSION_ERROR` | zlib.Z_VERSION_ERROR | static |  | constant value read |
| `node-builtin.zlib.brotliCompress` | zlib.brotliCompress | static |  |  |
| `node-builtin.zlib.brotliCompressSync` | zlib.brotliCompressSync | static |  |  |
| `node-builtin.zlib.brotliDecompress` | zlib.brotliDecompress | static |  |  |
| `node-builtin.zlib.brotliDecompressSync` | zlib.brotliDecompressSync | static |  |  |
| `node-builtin.zlib.crc32` | zlib.crc32 | static |  |  |
| `node-builtin.zlib.createBrotliCompress` | zlib.createBrotliCompress | static |  |  |
| `node-builtin.zlib.createBrotliDecompress` | zlib.createBrotliDecompress | static |  |  |
| `node-builtin.zlib.createDeflate` | zlib.createDeflate | static |  |  |
| `node-builtin.zlib.createDeflateRaw` | zlib.createDeflateRaw | static |  |  |
| `node-builtin.zlib.createGunzip` | zlib.createGunzip | static |  |  |
| `node-builtin.zlib.createGzip` | zlib.createGzip | static |  |  |
| `node-builtin.zlib.createInflate` | zlib.createInflate | static |  |  |
| `node-builtin.zlib.createInflateRaw` | zlib.createInflateRaw | static |  |  |
| `node-builtin.zlib.createUnzip` | zlib.createUnzip | static |  |  |
| `node-builtin.zlib.createZstdCompress` | zlib.createZstdCompress | static |  |  |
| `node-builtin.zlib.createZstdDecompress` | zlib.createZstdDecompress | static |  |  |
| `node-builtin.zlib.deflate` | zlib.deflate | static |  |  |
| `node-builtin.zlib.deflateRaw` | zlib.deflateRaw | static |  |  |
| `node-builtin.zlib.deflateRawSync` | zlib.deflateRawSync | static |  |  |
| `node-builtin.zlib.deflateSync` | zlib.deflateSync | static |  |  |
| `node-builtin.zlib.gunzip` | zlib.gunzip | static |  |  |
| `node-builtin.zlib.gunzipSync` | zlib.gunzipSync | static |  |  |
| `node-builtin.zlib.gzip` | zlib.gzip | static |  |  |
| `node-builtin.zlib.gzipSync` | zlib.gzipSync | static |  |  |
| `node-builtin.zlib.inflate` | zlib.inflate | static |  |  |
| `node-builtin.zlib.inflateRaw` | zlib.inflateRaw | static |  |  |
| `node-builtin.zlib.inflateRawSync` | zlib.inflateRawSync | static |  |  |
| `node-builtin.zlib.inflateSync` | zlib.inflateSync | static |  |  |
| `node-builtin.zlib.unzip` | zlib.unzip | static |  |  |
| `node-builtin.zlib.unzipSync` | zlib.unzipSync | static |  |  |
| `node-builtin.zlib.zstdCompress` | zlib.zstdCompress | static |  |  |
| `node-builtin.zlib.zstdCompressSync` | zlib.zstdCompressSync | static |  |  |
| `node-builtin.zlib.zstdDecompress` | zlib.zstdDecompress | static |  |  |
| `node-builtin.zlib.zstdDecompressSync` | zlib.zstdDecompressSync | static |  |  |

## Standard library

| Entry id | Surface | Status | Refusal code | Notes |
|---|---|---|---|---|
| `stdlib.abort-controller.abort` | AbortController.abort | static |  | Node 24.22.1 / Undici 7.30.1; facets: callback-order, identity, liveness, state-machine, surplus-arguments; differential evidence: fixture:static-controller |
| `stdlib.abort-controller.constructor` | AbortController constructor | static |  | Node 24.22.1 / Undici 7.30.1; facets: argument-evaluation, identity, state-machine, surplus-arguments; differential evidence: fixture:static-controller |
| `stdlib.abort-controller.signal` | AbortController.signal | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, property-read, state-machine; differential evidence: fixture:static-controller |
| `stdlib.abort-signal.abort` | AbortSignal.abort | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, liveness, surplus-arguments, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.aborted` | AbortSignal.aborted | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: generated:webidl-operations |
| `stdlib.abort-signal.add-event-listener` | AbortSignal.addEventListener | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, identity, callback-order, callback-this; differential evidence: generated:abort-events, fixture:static-listener-this, fixture:static-listener-noncallable |
| `stdlib.abort-signal.any` | AbortSignal.any | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, missing-arguments, surplus-arguments, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.constructor` | AbortSignal constructor | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; Node exposes the interface object but constructing it throws; the compiler does not preserve that constructor behavior |
| `stdlib.abort-signal.dispatch-event` | AbortSignal.dispatchEvent | static |  | Node 24.22.1 / Undici 7.30.1; facets: callback-order, callback-this, error-shape; differential evidence: fixture:static-dispatch-throw |
| `stdlib.abort-signal.onabort` | AbortSignal.onabort | static |  | Node 24.22.1 / Undici 7.30.1; facets: callback-order, callback-this, mutation, property-read; differential evidence: generated:abort-events, fixture:static-listener-this |
| `stdlib.abort-signal.reason` | AbortSignal.reason | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, liveness, property-read; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.abort-signal.remove-event-listener` | AbortSignal.removeEventListener | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, identity, callback-order; differential evidence: generated:abort-events, fixture:static-stream-this |
| `stdlib.abort-signal.throw-if-aborted` | AbortSignal.throwIfAborted | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, error-shape; differential evidence: generated:webidl-operations, fixture:static-abort-throw |
| `stdlib.abort-signal.timeout` | AbortSignal.timeout | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, missing-arguments, surplus-arguments, error-shape; differential evidence: generated:webidl-operations, fixture:static-stream-this |
| `stdlib.array.at` | Array.prototype.at | static |  |  |
| `stdlib.array.concat` | Array.prototype.concat | static |  |  |
| `stdlib.array.copyWithin` | Array.prototype.copyWithin | static |  |  |
| `stdlib.array.every` | Array.prototype.every | static |  |  |
| `stdlib.array.fill` | Array.prototype.fill | static |  |  |
| `stdlib.array.filter` | Array.prototype.filter | static |  |  |
| `stdlib.array.find` | Array.prototype.find | static |  |  |
| `stdlib.array.findIndex` | Array.prototype.findIndex | static |  |  |
| `stdlib.array.findLast` | Array.prototype.findLast | static |  |  |
| `stdlib.array.findLastIndex` | Array.prototype.findLastIndex | static |  |  |
| `stdlib.array.flat` | Array.prototype.flat | static |  |  |
| `stdlib.array.flatMap` | Array.prototype.flatMap | static |  |  |
| `stdlib.array.forEach` | Array.prototype.forEach | static |  |  |
| `stdlib.array.includes` | Array.prototype.includes | static |  |  |
| `stdlib.array.indexOf` | Array.prototype.indexOf | static |  |  |
| `stdlib.array.join` | Array.prototype.join | static |  |  |
| `stdlib.array.lastIndexOf` | Array.prototype.lastIndexOf | static |  |  |
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
| `stdlib.atomics` | Atomics | static |  | 8-, 16- and 32-bit integer operations, plus Int32Array wait and notify |
| `stdlib.blob` | Blob | static |  | immutable bytes with size, type, slice(), text(), bytes(), arrayBuffer() and structured cloning |
| `stdlib.date.UTC` | Date.UTC | static |  | the lowered call form takes 1 to 7 number arguments |
| `stdlib.date.constructor` | Date constructor | static |  | zero arguments, one milliseconds/date-string argument, or local-time year/month fields; values are the read-only TimeClip scalar slice |
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
| `stdlib.date.parse` | Date.parse | static |  | one date string, using V8's date parser shared with new Date(dateString) |
| `stdlib.date.setters` | Date.prototype setters | static |  | setTime and the local and UTC field setters, with their optional arguments |
| `stdlib.date.toDateString` | Date.prototype.toDateString | static |  |  |
| `stdlib.date.toISOString` | Date.prototype.toISOString | static |  | UTC ISO formatting over constructed and stored Date values |
| `stdlib.date.toString` | Date.prototype.toString | static |  | local time with the host zone's long English name; String(date) and template literals use it |
| `stdlib.date.toTimeString` | Date.prototype.toTimeString | static |  |  |
| `stdlib.date.toUTCString` | Date.prototype.toUTCString | static |  | RFC 7231 IMF-fixdate formatting over stored Date values |
| `stdlib.date.valueOf` | Date.prototype.valueOf | static |  | the same millisecond read as getTime() |
| `stdlib.fetch` | fetch | static |  | Node 24.22.1 / Undici 7.30.1; facets: argument-evaluation, webidl-conversion, surplus-arguments, promise-settlement, transport, error-shape; differential evidence: fixture:static, fixture:static-coercion, fixture:static-network-error |
| `stdlib.fetch.request-init.body` | RequestInit.body | static |  | Node 24.22.1 / Undici 7.30.1; conversion: string, Uint8Array, ReadableStream, Blob, File, or null; a FormData body is refused by name; differential evidence: fixture:static, fixture:static-stream, fixture:static-coercion, fixture:web-body |
| `stdlib.fetch.request-init.cache` | RequestInit.cache | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.credentials` | RequestInit.credentials | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.dispatcher` | RequestInit.dispatcher | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; custom dispatchers are unsupported; native environment-proxy routing uses NODE_USE_ENV_PROXY |
| `stdlib.fetch.request-init.duplex` | RequestInit.duplex | static |  | Node 24.22.1 / Undici 7.30.1; conversion: WebIDL enum; 'half' required for streaming bodies; differential evidence: fixture:static-stream, fixture:static-coercion |
| `stdlib.fetch.request-init.headers` | RequestInit.headers | static |  | Node 24.22.1 / Undici 7.30.1; conversion: Headers, record, or sequence-of-pairs snapshot; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.fetch.request-init.integrity` | RequestInit.integrity | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.keepalive` | RequestInit.keepalive | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.method` | RequestInit.method | static |  | Node 24.22.1 / Undici 7.30.1; conversion: WebIDL ByteString after all call arguments evaluate; differential evidence: fixture:static-coercion |
| `stdlib.fetch.request-init.mode` | RequestInit.mode | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.priority` | RequestInit.priority | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.redirect` | RequestInit.redirect | static |  | Node 24.22.1 / Undici 7.30.1; conversion: WebIDL enum: follow, error, or manual; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.fetch.request-init.referrer` | RequestInit.referrer | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.referrerPolicy` | RequestInit.referrerPolicy | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.fetch.request-init.signal` | RequestInit.signal | static |  | Node 24.22.1 / Undici 7.30.1; conversion: native AbortSignal handle or absent; differential evidence: fixture:static, fixture:static-abort-throw |
| `stdlib.fetch.request-init.window` | RequestInit.window | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the compiler does not preserve this RequestInit member's conversion or transport behavior |
| `stdlib.file` | File | static |  | a Blob with name and lastModified (Date.now() when absent) |
| `stdlib.headers.append` | Headers.append | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.constructor` | Headers constructor | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, mutation, identity; supported scope: Record and iterable header pairs, including copying native Headers; differential evidence: fixture:static-request |
| `stdlib.headers.delete` | Headers.delete | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.entries` | Headers.entries | static |  | Node 24.22.1 / Undici 7.30.1; facets: liveness, mutation, state-machine; differential evidence: fixture:static-headers-iteration |
| `stdlib.headers.forEach` | Headers.forEach | static |  | Node 24.22.1 / Undici 7.30.1; facets: callback-order, callback-this, mutation; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.get` | Headers.get | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, missing-arguments, property-read; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.getSetCookie` | Headers.getSetCookie | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.has` | Headers.has | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, missing-arguments, property-read; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.keys` | Headers.keys | static |  | Node 24.22.1 / Undici 7.30.1; facets: liveness, mutation, state-machine; differential evidence: fixture:static-headers-iteration |
| `stdlib.headers.set` | Headers.set | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, mutation, error-shape; differential evidence: fixture:static, fixture:static-coercion |
| `stdlib.headers.symbol.iterator` | Headers.[Symbol.iterator] | static |  | Node 24.22.1 / Undici 7.30.1; facets: liveness, mutation, state-machine; differential evidence: fixture:static-headers-iteration |
| `stdlib.headers.values` | Headers.values | static |  | Node 24.22.1 / Undici 7.30.1; facets: liveness, mutation, state-machine; differential evidence: fixture:static-headers-iteration |
| `stdlib.map.clear` | Map.prototype.clear | static |  |  |
| `stdlib.map.delete` | Map.prototype.delete | static |  |  |
| `stdlib.map.entries` | Map.prototype.entries | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.map.forEach` | Map.prototype.forEach | static |  |  |
| `stdlib.map.get` | Map.prototype.get | static |  |  |
| `stdlib.map.has` | Map.prototype.has | static |  |  |
| `stdlib.map.keys` | Map.prototype.keys | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.map.set` | Map.prototype.set | static |  |  |
| `stdlib.map.values` | Map.prototype.values | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.math.E` | Math.E | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.LN10` | Math.LN10 | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.LN2` | Math.LN2 | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.LOG10E` | Math.LOG10E | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.LOG2E` | Math.LOG2E | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.PI` | Math.PI | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.SQRT1_2` | Math.SQRT1_2 | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.SQRT2` | Math.SQRT2 | static |  | the constant read compiles to a numeric literal; no runtime Math read is performed |
| `stdlib.math.abs` | Math.abs | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.acos` | Math.acos | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.acosh` | Math.acosh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.asin` | Math.asin | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.asinh` | Math.asinh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.atan` | Math.atan | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.atan2` | Math.atan2 | static |  | compiles statically at arity 2; other declared call shapes are refused with SC2012 |
| `stdlib.math.atanh` | Math.atanh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.cbrt` | Math.cbrt | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.ceil` | Math.ceil | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.clz32` | Math.clz32 | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.cos` | Math.cos | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.cosh` | Math.cosh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.exp` | Math.exp | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.expm1` | Math.expm1 | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.f16round` | Math.f16round | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.floor` | Math.floor | static |  | compiles statically at arity 1 |
| `stdlib.math.fround` | Math.fround | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.hypot` | Math.hypot | static |  | compiles statically at any arity, including number[] spreads |
| `stdlib.math.imul` | Math.imul | static |  | compiles statically at arity 2; other declared call shapes are refused with SC2012 |
| `stdlib.math.log` | Math.log | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.log10` | Math.log10 | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.log1p` | Math.log1p | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.log2` | Math.log2 | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.max` | Math.max | static |  | compiles statically at arity 2 |
| `stdlib.math.min` | Math.min | static |  | compiles statically at arity 2 |
| `stdlib.math.pow` | Math.pow | static |  | compiles statically at arity 2; other declared call shapes are refused with SC2012 |
| `stdlib.math.random` | Math.random | static |  | compiles statically at arity 0 |
| `stdlib.math.round` | Math.round | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.sign` | Math.sign | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.sin` | Math.sin | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.sinh` | Math.sinh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.sqrt` | Math.sqrt | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.tan` | Math.tan | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.tanh` | Math.tanh | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.math.trunc` | Math.trunc | static |  | compiles statically at arity 1; other declared call shapes are refused with SC2012 |
| `stdlib.number.toFixed` | number.prototype.toFixed | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.number.toPrecision` | number.prototype.toPrecision | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.number.toString` | number.prototype.toString | unsupported | `SC2012` |  |
| `stdlib.readable-stream-default-controller.close` | ReadableStreamDefaultController.close | static |  | Node 24.22.1 / Undici 7.30.1; facets: state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-controller.constructor` | ReadableStreamDefaultController constructor | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; controller handles come from underlying-source callbacks; the constructor object is unsupported |
| `stdlib.readable-stream-default-controller.desired-size` | ReadableStreamDefaultController.desiredSize | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; differential evidence: generated:stream-traces |
| `stdlib.readable-stream-default-controller.enqueue` | ReadableStreamDefaultController.enqueue | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, liveness, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-controller.error` | ReadableStreamDefaultController.error | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.cancel` | ReadableStreamDefaultReader.cancel | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.closed` | ReadableStreamDefaultReader.closed | static |  | Node 24.22.1 / Undici 7.30.1; facets: promise-settlement, property-read, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.constructor` | ReadableStreamDefaultReader constructor | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; reader handles come from ReadableStream.getReader(); the constructor object is unsupported |
| `stdlib.readable-stream-default-reader.read` | ReadableStreamDefaultReader.read | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream-default-reader.release-lock` | ReadableStreamDefaultReader.releaseLock | static |  | Node 24.22.1 / Undici 7.30.1; facets: promise-settlement, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.cancel` | ReadableStream.cancel | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.constructor` | ReadableStream constructor | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, callback-this, callback-order, state-machine; differential evidence: generated:stream-traces, fixture:static-stream-this |
| `stdlib.readable-stream.from` | ReadableStream.from | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, missing-arguments, surplus-arguments, liveness; differential evidence: generated:webidl-operations, generated:stream-traces |
| `stdlib.readable-stream.get-reader` | ReadableStream.getReader | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, identity, state-machine, error-shape; differential evidence: generated:stream-traces, fixture:static-stream |
| `stdlib.readable-stream.locked` | ReadableStream.locked | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; differential evidence: generated:stream-traces |
| `stdlib.readable-stream.pipeThrough` | ReadableStream.pipeThrough | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-web-streams |
| `stdlib.readable-stream.pipeTo` | ReadableStream.pipeTo | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-web-streams |
| `stdlib.readable-stream.symbol.asyncIterator` | ReadableStream.[Symbol.asyncIterator] | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; direct for-await consumption compiles statically; explicit symbol access and stored iterator handles have no compiler lowering |
| `stdlib.readable-stream.tee` | ReadableStream.tee | static |  | Node 24.22.1 / Undici 7.30.1; facets: identity, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-web-streams |
| `stdlib.readable-stream.values` | ReadableStream.values | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; direct for-await consumption compiles statically; storing or driving the first-class iterator handle is unsupported |
| `stdlib.request.arrayBuffer` | Request.arrayBuffer | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-request |
| `stdlib.request.attribute` | Request.attribute | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; typed source has no compiler bridge for this interface |
| `stdlib.request.blob` | Request.blob | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; typed source has no compiler bridge for this interface |
| `stdlib.request.body` | Request.body | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.bodyUsed` | Request.bodyUsed | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.bytes` | Request.bytes | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-request |
| `stdlib.request.cache` | Request.cache | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.clone` | Request.clone | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, identity, state-machine, error-shape; differential evidence: fixture:static-clone |
| `stdlib.request.constructor` | Request constructor | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, body-consumption, error-shape; supported scope: Absolute URLs with method, headers, body, duplex, redirect, and signal; other RequestInit members retain explicit fences; differential evidence: fixture:static-request |
| `stdlib.request.credentials` | Request.credentials | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.destination` | Request.destination | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.duplex` | Request.duplex | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.formData` | Request.formData | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; typed source has no compiler bridge for this interface |
| `stdlib.request.headers` | Request.headers | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.integrity` | Request.integrity | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.isHistoryNavigation` | Request.isHistoryNavigation | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.isReloadNavigation` | Request.isReloadNavigation | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.json` | Request.json | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-request |
| `stdlib.request.keepalive` | Request.keepalive | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.method` | Request.method | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.mode` | Request.mode | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.redirect` | Request.redirect | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.referrer` | Request.referrer | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.referrerPolicy` | Request.referrerPolicy | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.signal` | Request.signal | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.request.text` | Request.text | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static-request |
| `stdlib.request.url` | Request.url | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read, state-machine; supported scope: Reads on native Requests within the constructor's supported RequestInit subset; differential evidence: fixture:static-request |
| `stdlib.response-init.headers` | ResponseInit.headers | static |  | Node 24.22.1 / Undici 7.30.1; conversion: Headers, record, or sequence-of-pairs snapshot; differential evidence: fixture:static |
| `stdlib.response-init.status` | ResponseInit.status | static |  | Node 24.22.1 / Undici 7.30.1; conversion: WebIDL unsigned-short conversion followed by the 200–599 range check; differential evidence: fixture:static |
| `stdlib.response-init.statusText` | ResponseInit.statusText | static |  | Node 24.22.1 / Undici 7.30.1; conversion: WebIDL ByteString with HTTP reason-phrase validation; differential evidence: fixture:static |
| `stdlib.response.arrayBuffer` | Response.arrayBuffer | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static |
| `stdlib.response.blob` | Response.blob | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the native fetch runtime does not implement this Response operation |
| `stdlib.response.body` | Response.body | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.bodyUsed` | Response.bodyUsed | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.bytes` | Response.bytes | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.clone` | Response.clone | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, identity, state-machine, error-shape; differential evidence: fixture:static-clone |
| `stdlib.response.constructor` | Response constructor | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, body-consumption, state-machine, error-shape; supported scope: BodyInit is string, Uint8Array/Buffer, ReadableStream&lt;Uint8Array&gt;, null/undefined, or a checked-dynamic value that follows the supported WebIDL string conversion; ResponseInit is headers/status/statusText; differential evidence: fixture:static |
| `stdlib.response.formData` | Response.formData | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the native fetch runtime does not implement this Response operation |
| `stdlib.response.headers` | Response.headers | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.json` | Response.json | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.ok` | Response.ok | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.redirected` | Response.redirected | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.static.error` | Response.error | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; Response static constructor-object operations have no compiler lowering |
| `stdlib.response.static.json` | Response.json | static |  | Node 24.22.1 / Undici 7.30.1; facets: webidl-conversion, error-shape; supported scope: data that crosses the checked-dynamic boundary, serialized with JSON.stringify (toJSON hooks included); ResponseInit as for the constructor; differential evidence: fixture:static-response-json |
| `stdlib.response.static.redirect` | Response.redirect | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; Response static constructor-object operations have no compiler lowering |
| `stdlib.response.status` | Response.status | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.statusText` | Response.statusText | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.response.text` | Response.text | static |  | Node 24.22.1 / Undici 7.30.1; facets: body-consumption, promise-settlement, state-machine, error-shape; differential evidence: fixture:static, fixture:static-stream |
| `stdlib.response.type` | Response.type | unsupported | `SC2020` | Node 24.22.1 / Undici 7.30.1; the member is outside the native static handle projection |
| `stdlib.response.url` | Response.url | static |  | Node 24.22.1 / Undici 7.30.1; facets: property-read; differential evidence: fixture:static |
| `stdlib.set.add` | Set.prototype.add | static |  |  |
| `stdlib.set.clear` | Set.prototype.clear | static |  |  |
| `stdlib.set.delete` | Set.prototype.delete | static |  |  |
| `stdlib.set.difference` | Set.prototype.difference | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.entries` | Set.prototype.entries | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.set.forEach` | Set.prototype.forEach | static |  |  |
| `stdlib.set.has` | Set.prototype.has | static |  |  |
| `stdlib.set.intersection` | Set.prototype.intersection | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isDisjointFrom` | Set.prototype.isDisjointFrom | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isSubsetOf` | Set.prototype.isSubsetOf | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.isSupersetOf` | Set.prototype.isSupersetOf | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.keys` | Set.prototype.keys | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.set.symmetricDifference` | Set.prototype.symmetricDifference | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.union` | Set.prototype.union | static |  | compiles over Set receivers with Set arguments and Map arguments keyed by the element type (other ReadonlySetLike argument forms are refused per site) |
| `stdlib.set.values` | Set.prototype.values | static |  | live native iterators support next(), for...of, drains, and the iterator helper methods |
| `stdlib.sharedArrayBuffer` | SharedArrayBuffer | static |  | fixed shared storage with context-local typed-array and DataView wrappers |
| `stdlib.string.at` | string.prototype.at | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.string.charAt` | string.prototype.charAt | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.string.charCodeAt` | string.prototype.charCodeAt | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.string.codePointAt` | string.prototype.codePointAt | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.string.endsWith` | string.prototype.endsWith | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.includes` | string.prototype.includes | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.indexOf` | string.prototype.indexOf | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.isWellFormed` | string.prototype.isWellFormed | static |  | the lowered call form takes no arguments |
| `stdlib.string.normalize` | string.prototype.normalize | static |  | the lowered call form takes 0 to 1 arguments |
| `stdlib.string.padEnd` | string.prototype.padEnd | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.padStart` | string.prototype.padStart | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.repeat` | string.prototype.repeat | static |  | the lowered call form takes exactly 1 argument |
| `stdlib.string.replace` | string.prototype.replace | static |  | string patterns with primitive replacements or typed callbacks; regex forms have separate lowering |
| `stdlib.string.replaceAll` | string.prototype.replaceAll | static |  | string patterns with primitive replacements or typed callbacks; regex forms have separate lowering |
| `stdlib.string.slice` | string.prototype.slice | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.split` | string.prototype.split | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.startsWith` | string.prototype.startsWith | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.substring` | string.prototype.substring | static |  | the lowered call form takes 0 to 2 arguments |
| `stdlib.string.toLowerCase` | string.prototype.toLowerCase | static |  | the lowered call form takes no arguments |
| `stdlib.string.toUpperCase` | string.prototype.toUpperCase | static |  | the lowered call form takes no arguments |
| `stdlib.string.toWellFormed` | string.prototype.toWellFormed | static |  | the lowered call form takes no arguments |
| `stdlib.string.trim` | string.prototype.trim | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimEnd` | string.prototype.trimEnd | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimLeft` | string.prototype.trimLeft | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimRight` | string.prototype.trimRight | static |  | the lowered call form takes no arguments |
| `stdlib.string.trimStart` | string.prototype.trimStart | static |  | the lowered call form takes no arguments |
| `stdlib.webassembly` | globalThis.WebAssembly | static |  | compile, instantiate, validate, the Module, Instance, Memory, Table and Global constructors, Module.imports, exports and customSections, instanceof, the error classes, exports, imports and Module transfer to workers, over the modules translated at build time; the rest refuses with SC2020 (the streaming functions, Tag and Exception, and the classes used as values other than with new and instanceof are planned; 'scriptc coverage' lists the modules this program loads (https://scriptc.dev/limitations)) |
| `stdlib.webcrypto.CryptoKey` | CryptoKey | static |  | secret HMAC, AES, PBKDF2 and HKDF keys with type, extractable, algorithm and usages, and instanceof CryptoKey |
| `stdlib.webcrypto.subtle` | globalThis.crypto.subtle | static |  | importKey, generateKey and exportKey (raw and jwk) for HMAC and AES keys, importKey for PBKDF2 and HKDF keys, AES-GCM, AES-CBC and AES-CTR encrypt and decrypt, wrapKey and unwrapKey of secret keys with AES-KW or those ciphers, PBKDF2 and HKDF deriveBits and deriveKey, HMAC sign and verify, generateKey, importKey, exportKey, sign and verify for ECDSA, Ed25519, RSASSA-PKCS1-v1_5 and RSA-PSS, and SHA-1/SHA-2 digest; other methods, algorithms and key formats are refused |

## Compiler coverage statement

The manifest's own description of how it is projected and what its
statuses promise, verbatim:

- Entries are projected mechanically from the compiler's own decision tables: the diagnostics registry, the unsupported-syntax dispatch tables, the stdlib and node-builtin lowering tables, and the supported-builtin-module list. Nothing is hand-maintained; the manifest regenerates byte-identically from the source tree at this version.
- Absence from this manifest means 'not projected', never 'unsupported'. Surfaces lowered through dedicated code paths rather than tables are not yet projected: console, JSON, Promise/async and the timer surface, the net/http/tls/https/dgram/dns/assert/test/stream/readline module member surfaces, template literals, the regex slice, global functions (parseInt, parseFloat, isNaN, isFinite), and the process surface outside its ambient slice.
- The ambient-nondeterminism and ambient-authority surfaces the library sidecar's determinism attestation scans ARE projected even where they lower through dedicated code paths — the Date compositions (stdlib.date.*), perf_hooks' performance.now, and the process global's ambient reads and authority calls (node-builtin.process.*) — so a determinism fence can name every surface the attestation demotes on.
- stdlib and node-builtin member entries name surface whose LOWERED call forms are constrained (arity, argument shapes); declared call forms outside the lowered set are refused per site, with code SC2020 for standard-library and node-builtin surface.
- Entries with status 'unsupported' describe where the named code is raised: forms of the construct outside the supported subset are refused with that code — not that every form of the named feature is refused. Supported forms appear as their own static entries where a table projects them.
- The engine-free fetch projection targets Node 24.22.1 with bundled Undici 7.30.1. Each projected row names the differential evidence that guards it; changing the pinned Node or Undici version is an explicit profile update.
- The fetch profile also contains a runtime-reflected census of the selected fetch, abort, Headers, and readable-stream interfaces plus RequestInit/ResponseInit dictionary reads. Static and unsupported census rows are projected here; its explicitly out-of-scope metadata rows and adjacent-interface exclusions remain in the profile so absence is deliberate rather than ambiguous.
- Process-level diagnostic codes are not surface entries: SC0001-SC0015 are preflight gates (SC0005-SC0015 are the ECMAScript early errors), SC1110 is a comptime evaluation failure, SC3001/SC3002 are backend/target tier refusals, SC9001/SC9002 are internal errors.
- Entry statuses are projected for the desktop targets. The mobile targets (aarch64-apple-ios, aarch64-apple-ios-simulator, aarch64-linux-android) compile library-mode archives only: the library-admissible surface (what SC4005's async_free requirement and the library link set admit) is supported there, the executable lane refuses those triples with SC3002, and no entry outside the library-admissible surface carries a mobile support claim. iOS archives build for iOS 15.0 on darwin hosts; Android archives build against NDK API level 26.
- No scheduling metadata is published; entry ids are the stable diff keys across releases.

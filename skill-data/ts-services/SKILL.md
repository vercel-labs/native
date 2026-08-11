---
name: ts-services
description: Authoring guide for Native SDK TypeScript services under src/services: ordinary scriptc static-tier TypeScript reached from a deterministic core through Cmd.request, including the byte operation contract, imports, kind-tagged failures, authority, replay, desktop subprocess transport, and phase-1 limitations. Use when adding or modifying src/services modules, moving Node/JSON/regex/Map/Date/class work out of a core, or fixing NS1065-NS1067.
---

# Author TypeScript services behind the effect boundary

Use `src/services/**/*.ts` for imperative application work that needs ordinary TypeScript beyond the deterministic core subset: `fs`, `path`, `process`, `os`, `child_process`, `fetch`, regexes, JSON, `Map`/`Set`, `Date`, and classes supported by the pinned scriptc static tier. Both core and services compile with the exact scriptc version in `packages/core/package.json`; neither uses `--dynamic` or ships a JavaScript engine.

The class line is hard:

- `src/core.ts` and its imports outside `src/services/` stay under NS1001–NS1064 and keep the deterministic attestation.
- The core must not import a service, even type-only (NS1065). It calls a literal operation name with `Cmd.request`.
- Services may import relative vendored service files and subset-legal core-class files. Bare package specifiers teach NS1066 in phase 1; check source in under `src/services/`.
- Runtime cycles, missing modules, and names colliding within one class keep their normal module diagnostics. Names do not collide merely because one is core-class and one is service-class.

## Operation surface

Every directly exported, non-default named function is a v1 operation. It must be synchronous, have a body, take zero parameters or one annotated `Uint8Array`, and explicitly return `Uint8Array`. Default exports, export lists, re-exports, overload-only declarations, generators, and async functions teach NS1067.

```ts
// src/services/feeds.ts -> operation "feeds.parse"
import * as fs from "node:fs";

export function parse(payload: Uint8Array): Uint8Array {
  const parsedAt = Date.now();
  const matches = /feed/i.test(new TextDecoder().decode(payload));
  return new TextEncoder().encode(JSON.stringify({ parsedAt, matches, cwd: fs.existsSync(".") }));
}

export function fail(): Uint8Array {
  throw { kind: "feed_parse", message: "invalid feed" };
}
```

Operation names are `<module-basename>.<export>`, so two same-basename modules cannot export the same function name. The generated `services.contract.json` carries the operation names, payload arity, source hash, protocol version, exact compiler pin, and `deterministic: false`. That sidecar is the only downstream fact channel.

Explicit throws must be exactly inline kind-tagged `{ kind, message }` shapes with a string-valued message, and they must escape through the operation boundary rather than be caught locally. The host encodes that pair as UTF-8 JSON bytes and routes it through the request's error arm. Do not throw `new Error(...)` from the service surface. For the pinned scriptc 0.0.22 lane, staging mechanically lowers this boundary shape to a tagged `Error` in scratch code because imported catches cannot inspect record throws yet; author source and its Node behavior are unchanged.

## Call from the core

The core learns no new synchronous API. Add success and failure Msg arms with exactly one `Uint8Array` field and return a request command:

```ts
export type Msg =
  | { readonly kind: "parse" }
  | { readonly kind: "parsed"; readonly bytes: Uint8Array }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array };

case "parse":
  return [model, Cmd.request("feeds.parse", model.source, {
    key: "feed-parse",
    ok: "parsed",
    err: "parse_failed",
  })];
```

`native check` validates literal request names against the emitted service contract. A service request key shares the engine effect-key space; a duplicate live service key rejects the new request without replacing the first. `Cmd.cancel(key)` kills or removes the carrier request and drops its result silently, matching the core command contract.

Results enter through the ordinary host-result effect queue and are journaled. During replay the request parks under the fake executor and the journal feeds its recorded terminal; the service host is never spawned and need not exist on disk.

## Authority and process contract

The phase-1 carrier is a plain-scriptc executable placed beside the desktop app and spawned lazily on the first live request. One worker thread owns it and its framed stdin/stdout protocol. The startup hello carries the protocol version and a SHA-256 fingerprint of the operation registry; a stale or mismatched sibling fails before numeric dispatch. A crash fails the interrupted request through its error arm; the next request starts a fresh host. `Cmd.host` can use the same generated registry for fire-and-forget operations.

The service process runs with the app's privileges and uses the resolved app data directory as cwd. Its environment is rebuilt from an allowlist: `PATH`, `HOME`, `USER`, temp variables, locale/time-zone variables, certificate paths, and proxy variables; Windows matches names case-insensitively and also carries `USERPROFILE`, `USERNAME`, `SystemRoot`, `COMSPEC`, and `PATHEXT`. `NATIVE_SDK_*` internals are never inherited. Standard output belongs to the frame protocol; write diagnostics to standard error.

The current carrier means:

- desktop only; there is no iOS/Android subprocess path;
- service executables compile for the build host only; cross-target service builds are rejected until the compiler can emit the requested desktop target;
- one extra signed executable in the bundle/package;
- one process hop and two payload copies per request;
- bytes-only request/results, no streaming, npm, or async service entry points yet.

Keep storage on engine-owned effects; a service is not a backdoor database tier. Custom widgets, rasterizer work, platform integration, and new engine capabilities remain Zig toolkit extensions.

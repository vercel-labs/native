---
name: ts-services
description: Authoring guide for Native SDK TypeScript services under src/services: ordinary scriptc static-tier TypeScript reached through generated typed Cmd clients, shared record shapes, hermetic vendored npm, streaming, deadlines, cancellation, devhost simulation, authority, replay, and the desktop subprocess transport. Use when adding or modifying src/services modules, moving Node/JSON/regex/Map/Date/class work out of a core, or fixing NS1065-NS1067.
---

# Author TypeScript services behind the effect boundary

Use `src/services/**/*.ts` for imperative work that needs ordinary TypeScript beyond the deterministic core subset: `fs`, `path`, `process`, `os`, `child_process`, `fetch`, regexes, JSON, `Map`/`Set`, `Date`, and classes supported by the pinned scriptc static tier. Both classes compile with the exact scriptc version in `packages/core/package.json`; neither enables `--dynamic` or ships a JavaScript engine. The exact verdict for every surface the compiler currently projects — with each status and refusal code, plus the manifest's explicit coverage limits — is `references/service-surface.md`, generated from the pinned compiler's own manifest; consult it rather than guessing compiler capability.

The class line is hard:

- `src/core.ts` and its imports outside `src/services/` retain NS1001–NS1064 and `deterministic: true`.
- The core never imports a service file, even type-only (NS1065). It imports generated command constructors from `@native-sdk/services`.
- A service may import shared, subset-legal declarations from the core class. Put every boundary record, enum, or union there so one declaration is authoritative on both sides.
- A service may import compiler-supported Node built-ins and exact packages declared by app.zon. Undeclared bare imports teach NS1066.

## Typed operation surface

Every directly exported, non-default named function is an operation named `<module-basename>.<export>`. It must be synchronous, have a body, take zero or one explicitly annotated request, and explicitly return a contract-encodable result. Boundary data may use booleans, numbers, integer-class numbers, bytes, optionals, readonly slices, and named records/enums/kind-unions. Functions and behavior-bearing classes do not cross.

```ts
// src/shared.ts — core-class file, imported by both classes
export type ParseRequest = {
  readonly source: Uint8Array;
  readonly caseSensitive: boolean;
};

export type ParseResult = {
  readonly bytes: Uint8Array;
  readonly matched: boolean;
};

// src/services/feeds.ts
import type { ParseRequest, ParseResult } from "../shared.ts";

export function parse(request: ParseRequest): ParseResult {
  const text = new TextDecoder().decode(request.source);
  const matched = request.caseSensitive ? /feed/.test(text) : /feed/i.test(text);
  return { bytes: new TextEncoder().encode(JSON.stringify({ matched })), matched };
}
```

`services.contract.json` carries the complete type table, operation names, exact compiler pin, source hashes, package facts, deadlines, streaming declarations, and `deterministic: false`. Generated host codecs, the Zig registry/result decoders, and the typed client consume that sidecar; none re-read source to infer a second truth.

Explicit boundary throws must be exactly inline `{ kind, message }` shapes with a string-valued message and must escape the operation. They arrive as UTF-8 JSON bytes on the error arm. Do not throw `new Error(...)` from the exported surface.

## Call through the generated client

Import from `@native-sdk/services`; `native check` derives this virtual module, and build/dev stage the same projection without writing `src/services.gen.ts` into the author tree. The editor copy lives under ignored `node_modules/@native-sdk/services`.

```ts
import { feedsParse } from "@native-sdk/services";
import type { ParseRequest, ParseResult } from "./shared.ts";

export type Msg =
  | { readonly kind: "parse"; readonly request: ParseRequest }
  | { readonly kind: "parsed"; readonly result: ParseResult }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array };

case "parse":
  return [model, feedsParse(msg.request, {
    key: "feed-parse",
    ok: "parsed",
    err: "parse_failed",
  })];
```

The generated route type proves that `ok` names the one Msg arm carrying exactly the declared result and `err` names a one-bytes-field arm. Raw `Cmd.request(name, bytes, route)` remains available as the low-level byte seam.

Keys share the engine effect-key space. Duplicate live service keys reject loudly. Terminal results and stream events are journaled; replay feeds the recorded events without starting the service host.

## Hermetic npm

Resolve packages only with an explicit author action:

```bash
native vendor . escape-string-regexp@5.0.0
```

The command installs with lifecycle scripts disabled in a temporary directory, copies the flattened package graph into `src/services/vendor/`, retains package/license files, computes canonical tree hashes, and rewrites app.zon's `service_packages` with exact names, `X.Y.Z` versions, and hashes. Check those bytes and manifest facts into source control.

Builds never run npm or use the network. They verify package identity and every vendored byte, stage only declared packages, and invoke scriptc with `--npm-static <explicit-list>`. `auto`, dynamic-island fallback, and `--dynamic` are refused. Anything below 100% static coverage fails: `native check` preserves the coverage note verbatim and names the three options—choose another exact package, port/vendor a suitable implementation, or wait for compiler support. The checked-in scriptc 0.0.27 spike (`tests/ts-services/npm-static-spike.json`) passed three of five deliberately small candidates and refused `nanoid` and `micromark`; npm support is selective.

## Streaming, cancellation, and deadlines

A last `emit` capability declares a stream. Each typed chunk becomes canonical bytes on the existing external channel; the operation still returns one typed terminal result.

```ts
import type { ServiceCancellation } from "@native-sdk/core";

export type ParseChunk = { readonly bytes: Uint8Array; readonly index: number };

/**
 * @deadlineMs 5000
 * @streamBuffer 8
 */
export function parseLarge(
  request: ParseRequest,
  emit: (chunk: ParseChunk) => void,
  cancellation: ServiceCancellation,
): ParseResult {
  for (let index = 0; index < request.source.length; index += 4096) {
    cancellation.throwIfCancelled();
    emit({ bytes: request.source.slice(index, index + 4096), index });
  }
  return parse(request);
}
```

Import `ServiceCancellation` as a type from `@native-sdk/core`; it is legal only as the final capability parameter. The generated client route additionally requires `channelKey` and a channel-event Msg arm. `@streamBuffer` is a 1–64 in-flight contract cap (default 8); `@deadlineMs` is a 1–86400000 operation deadline. A terminal result closes the channel after its interim frames. `Cmd.cancel(key)` flips the token, closes a streaming channel, sends `cancelled` through `err`, and drops every later chunk. Deadline expiry flips the same token and sends JSON with `kind: "timeout"`. Poll `cancelled()` or call `throwIfCancelled()` at bounded intervals; the subprocess receives a short cooperative grace period and remains alive after a clean unwind. Ignoring the token causes a hard kill, after which the next request lazily starts a clean host.

## Dev loop, authority, and current limits

`native dev --core` imports service modules in an isolated Node worker, verifies the same package hashes, decodes the same request contract, cooperatively interrupts cancellation/deadline work, maps errors through the same arms, and emits stream chunks through the same channel-event shape. Use `--script scenario.ndjson --watch` for repeatable logic iterations. The devhost reads `NATIVE_SDK_SESSION_RECORD`/`NATIVE_SDK_SESSION_REPLAY`, writes the native journal format, and starts no service worker during replay. Service-only recordings cross between it and the packaged runtime; packaged recordings containing other effect families must be replayed with `native automate replay`, and devhost rejects those records explicitly. `native dev` runs the compiled service executable beside the real app.

The service process runs with the app's privileges and app-data cwd. It receives an explicit environment allowlist (path, user/home/temp, locale/time zone, certificate, and proxy variables; platform equivalents on Windows); `NATIVE_SDK_*` internals are stripped. Stdout belongs to framed transport, so diagnostics go to stderr. This authority is why service work never runs synchronously inside `update`.

Current limits:

- desktop and build-host target only; the carrier is a lazily spawned sibling executable;
- synchronous static-tier operations only—async services wait for the next compiler/runtime phase;
- no JavaScript engine or dynamic npm fallback;
- storage remains engine-owned effects, not a service-layer database shortcut;
- custom widgets, renderers, platform integration, and new engine capabilities remain Zig toolkit extensions.

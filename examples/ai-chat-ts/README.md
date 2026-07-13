# Native SDK ai-chat-ts example

A chat client for an OpenAI-compatible chat-completions endpoint, authored entirely in **TypeScript + Native markup**. Zero Zig: the logic tier is the app-core subset under `src/`, transpiled to native at build time as one module; `src/app.native` is the whole view tier and `app.zon` the manifest. The build detects `src/core.ts` in the tree and stages the wiring itself; no JS runtime ships in the binary.

This is the reference answer to "can a TypeScript core call an AI API?": the network surface is one `Cmd.fetch` with a real `Authorization: Bearer <key>` header built at runtime from the launch environment, the JSON wire format is pure byte math in the subset, and because the whole exchange is effect data, a recorded conversation **replays byte-identically with zero network and zero env reads** — the e2e suite pins the exact request bytes and replays a two-turn conversation, transport failure and retry included, with no endpoint in the room and none of the launch variables set.

The core is two modules plus one SDK library:

- `src/core.ts` — the entry module: Model (the conversation, the composer, the request phase, the launch configuration), Msg, update, the env channel, and every exported binding helper.
- `src/api.ts` — the chat-completions wire format over bytes: request encoding (JSON escaping included) and response parsing (`choices[0].message.content` on success, `error.message` on failure; anything malformed is `null`, never a half-parsed conversation).
- `@native-sdk/core/text` — the SDK's byte-splice text engine, transpiled in for the composer's caret/selection/IME fidelity.

```sh
NATIVE_SDK_CHAT_ENDPOINT="http://127.0.0.1:11434/v1/chat/completions" \
NATIVE_SDK_CHAT_MODEL="<your model name>" \
NATIVE_SDK_CHAT_API_KEY="local" \
native dev                                    # run the real app
native dev --core --script dev-script.ndjson  # the core-logic loop under node - no renderer, no network
native check                                  # subset-check the core's import graph + markup + app.zon
```

The end-to-end proof battery lives in the SDK repo (`tests/ts-core/ai_chat_e2e_tests.zig`, run by `zig build test-ts-core-e2e`): it drives this example's real core and shipping markup headlessly through the teaching state (zero fetches without configuration), a scripted conversation with the request bytes pinned (`Authorization` header included), the in-flight guard, every failure shape, and record→replay with the launch variables unset and changed.

## Configuration: the env channel

The endpoint, model, and key arrive through the core's `envMsgs` channel — one journaled Msg per variable at install. The core never reads the environment (that would break determinism), **no endpoint is baked in, and no key exists anywhere in this tree**: until all three variables are present and non-empty, the app shows a setup panel naming exactly what is missing and issues zero requests.

- **`NATIVE_SDK_CHAT_ENDPOINT`** — the full chat-completions URL (for a local runtime, typically `http://127.0.0.1:<port>/v1/chat/completions`).
- **`NATIVE_SDK_CHAT_MODEL`** — the model name the endpoint expects in the request body.
- **`NATIVE_SDK_CHAT_API_KEY`** — the bearer token, sent as a standard `Authorization: Bearer <key>` header. Local OpenAI-compatible runtimes ignore auth; any placeholder satisfies the guard.

Record/replay journals these deliveries: a session recorded with the variables set replays byte-identically on a machine where they are unset or different — the recorded values feed from the journal, and replay never reads the environment.

## Where this example is honest about v1 boundaries

Every line below is a decided posture, listed on purpose:

- **The reply arrives whole, not streamed.** `Cmd.fetch` is buffered by design in v1 — one request, one `{ status, body }` result Msg. The UI shows an honest waiting state instead of a token stream. The effect engine underneath already frames streamed response bodies into line Msgs (the Zig effects channel's `.stream` fetch — exactly the shape SSE token streams arrive in); surfacing that in the TS Cmd vocabulary is the named roadmap item. Buffered is also what makes the replay trick trivial: one journaled result per request.
- **A failed request keeps the conversation.** Every failure shape — a non-200 status (the endpoint's own `error.message` surfaces when the body carries one), a 200 whose body does not parse, a transport failure with its machine-readable reason — lands in one failed state with the history intact and a Retry that re-sends the same conversation.
- **One request in flight, by construction.** `phase === "sending"` guards every send path in update (the Send button binds the same guard), and the `"chat"` effect key would reject a duplicate at the engine even if update misbehaved. A send blocked by the guard loses nothing — the draft survives.
- **Long conversations eventually hit the request bound.** The engine's fetch body bound is 64 KiB; a conversation that outgrows it is rejected by the engine at runtime and lands in the failed state with a reason. Clear starts fresh. (History trimming/summarizing is app policy, deliberately not built in here.)
- **The conversation is not persisted.** The Model is the session; `Cmd.writeFile` + a boot-time `Cmd.readFile` is the standard persistence pattern when an app wants history across launches.
- **Desktop only.** TypeScript cores build desktop apps today.
- **The encoder's helpers return byte arrays instead of appending to a shared buffer.** Local mutation ends at the first escape — an array passed to another function is no longer yours to mutate (the NS1051 "mutates after the array escaped" rule) — so `encodeChatRequest` assembles the request from values its helpers return, in one literal, rather than handing a parts buffer around between pushes.

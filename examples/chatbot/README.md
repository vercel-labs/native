# Native SDK Chatbot example

A streaming chat client for [Vercel AI Gateway](https://vercel.com/docs/ai-gateway), authored entirely in **TypeScript + Native markup**. Zero Zig: the logic tier is the app-core subset under `src/`, compiled to native code at build time; `src/app.native` is the whole view tier and `app.zon` the manifest. The build detects `src/core.ts` in the tree and stages the wiring itself; no JS runtime ships in the binary.

This is the reference answer to "can a TypeScript core stream an AI API?": the network surface is one line-routed `Cmd.fetch` to `https://ai-gateway.vercel.sh/v1/chat/completions`, with `stream: true`, `Accept: text/event-stream`, and a real `Authorization: Bearer <key>` header built at runtime. Each SSE `data:` line is an ordinary Msg; `choices[0].delta.content` is appended to committed Model state and repaints the assistant response immediately. The JSON/SSE wire format is pure byte math in the subset, and because the whole exchange is effect data, a recorded conversation **replays byte-identically with zero network and zero env reads** — including every partial reply.

The core is two modules plus two SDK libraries:

- `src/core.ts` — the entry module: Model (completed history, the in-progress assistant reply, the composer, the request phase, and launch configuration), Msg, update, the env channel, and every exported binding helper.
- `src/api.ts` — the Gateway chat-completions wire format over bytes: request encoding (JSON escaping included) and SSE parsing (`choices[0].delta.content`, `[DONE]`, and `error.message`).
- `@native-sdk/core/text` — the SDK's byte-splice text engine, compiled in for the composer's caret/selection/IME fidelity.
- `@native-sdk/core/events` — canonical scroll and window-chrome event shapes; the latter drives the text-free, draggable hidden titlebar and keeps its New chat button clear of the traffic lights.

```sh
AI_GATEWAY_API_KEY="<your Vercel AI Gateway key>" \
native dev                                    # run the real app
native dev --core --script dev-script.ndjson  # the core-logic loop under node - no renderer, no network
native check                                  # subset-check the core's import graph + markup + app.zon
```

The example defaults to `openai/gpt-5.6-luna`. The model selector inside the prompt group offers GPT-5.6 Luna, GPT-5.6 Terra, and GPT-5.6 Sol, backed by `openai/gpt-5.6-luna`, `openai/gpt-5.6-terra`, and `openai/gpt-5.6-sol`; the next request uses the selected model. To start with another Gateway model, add `NATIVE_SDK_CHAT_MODEL="<creator/model>"` to the `native dev` command.

The end-to-end proof battery lives in the SDK repo (`tests/ts-core/ai_chat_e2e_tests.zig`, run by `zig build test-ts-core-e2e`): it drives this example's real core and shipping markup headlessly through the teaching state (zero fetches without configuration), a scripted conversation with the Gateway request bytes pinned, partial text asserted before the terminal, the in-flight guard, every failure shape, and record→replay with the launch variables unset and changed.

## Configuration: the env channel

The API key and optional model override arrive through the core's `envMsgs` channel — one journaled Msg per variable present at install. The core never reads the environment (that would break determinism). The Vercel AI Gateway Chat Completions endpoint and the `openai/gpt-5.6-luna` default are intentionally fixed and reviewable in `src/core.ts`; **no key exists anywhere in this tree**. Until the key is present and non-empty, the app shows a setup panel and issues zero requests.

- **`NATIVE_SDK_CHAT_MODEL`** *(optional)* — overrides the `openai/gpt-5.6-luna` default with another Gateway `creator/model` id from the [model catalog](https://vercel.com/ai-gateway/models). An empty value leaves the default in place.
- **`AI_GATEWAY_API_KEY`** — a Vercel AI Gateway API key, sent as the standard `Authorization: Bearer <key>` header.

Record/replay journals these deliveries: a session recorded with the variables set replays byte-identically on a machine where they are unset or different — the recorded values feed from the journal, and replay never reads the environment.

## Where this example is honest about v1 boundaries

Every line below is a decided posture, listed on purpose:

- **Replies really stream.** `Cmd.fetch` routes every complete SSE line through `chat_line`; the core decodes `choices[0].delta.content`, appends it to `pendingReply`, and the markup displays that field while the request is live. `[DONE]` plus a 2xx terminal commits the completed assistant turn.
- **A failed request keeps the conversation.** Every failure shape — a non-2xx status (the Gateway's own `error.message` surfaces when a response line carries one), a 2xx stream missing `[DONE]`, a textless completion, or a transport failure — lands in one failed state. Partial assistant text is discarded; the unanswered user turn stays, and Retry re-sends the same history.
- **One request in flight, by construction.** `phase === "sending"` guards every send path in update, and the `"chat"` effect key would reject a duplicate at the engine even if update misbehaved. While a reply streams, the Send action becomes Stop: it cancels the keyed request immediately and keeps any text already received as the assistant's stopped response. A send blocked by the guard loses nothing — the draft survives.
- **Long conversations retain full visible history and prune provider context.** Before each send, the encoder measures the exact JSON-escaped size and sends the newest whole, user-led suffix that fits the engine's 64 KiB fetch-body bound. Older turns remain in the UI and the session Model; they simply stop riding the API request. If the fixed request fields and newest prompt alone cannot fit, the app enters its failed state locally instead of issuing a rejected fetch.
- **One streamed reply is capped at 256 KiB.** Crossing the cap cancels the live request, reports the failure, and keeps the unanswered user turn. Individual protocol lines use a 64 KiB bound.
- **The conversation is not persisted.** The Model is the session; an app that wants history across launches declares the `persist` capability and issues `Cmd.persist()` after committing a turn.
- **Desktop only.** TypeScript cores build desktop apps today.
- **The encoder's helpers return byte arrays instead of appending to a shared buffer.** Local mutation ends at the first escape — an array passed to another function is no longer yours to mutate (the NS1051 "mutates after the array escaped" rule) — so `encodeChatRequest` assembles the request from values its helpers return, in one literal, rather than handing a parts buffer around between pushes. The bounded wrapper measures those values first and never assembles an oversized complete body.

# Native SDK Service Feed Reader example

The complete TypeScript services loop in one small app: `Cmd.fetch` downloads a feed, the `feeds.parse` service turns the raw bytes into typed records through the generated `@native-sdk/services` client, the typed result Msg commits to the Model, and the markup renders the parsed items. Recorded sessions replay the whole loop byte-identically with no network and no service process.

The loop, end to end:

1. **Fetch.** `update` returns `Cmd.fetch({ url: model.url }, { key: "feed-fetch", ok: "fetched", err: "fetch_failed" })`. The delivered `{ status, body }` arrives as an ordinary Msg.
2. **Parse in the service.** The core hands the body to the service through the generated typed constructor — request and result are the shared records in `src/shared.ts`, never hand-encoded bytes:

   ```ts
   import { feedsParse } from "@native-sdk/services";

   case "fetched":
     return [model, feedsParse({ source: msg.body, limit: MAX_ITEMS }, {
       key: "feed-parse",
       ok: "parsed",        // the one Msg arm carrying FeedResult
       err: "parse_failed", // a one-Uint8Array-field arm
     })];
   ```

   `src/services/feeds.ts` is ordinary static-tier TypeScript: regexes over RSS 2.0 and Atom markup, CDATA and entity handling, a `Map` that drops duplicate links. Malformed input escapes as a kind-tagged throw and lands on `parse_failed` as UTF-8 JSON. No JavaScript engine ships — both classes compile through the pinned scriptc.
3. **Render.** `parsed` commits `FeedResult` — title bytes, a `readonly FeedItem[]`, and the discovered total — and `src/app.native` lists the items.

A small RSS sample is baked into the core, so the same service operation also runs with zero network ("Parse the sample", and the boot command). The feed URL defaults to `https://github.com/vercel/ai/releases.atom`; `NATIVE_SDK_FEED_URL` overrides it through the env channel, journaled like every other input.

```sh
native dev                                    # run the real app (child service host beside it)
native dev --core --script dev-script.ndjson  # the core-logic loop under node — real service, scripted network
native check                                  # subset-check the core + services contract + markup + app.zon
```

The end-to-end proof battery lives in the SDK repo (`tests/ts-services/feed_reader_e2e_tests.zig`, run by `zig build test-ts-services-e2e`): it drives this example's real compiled core, its shipping markup, and its real compiled service child against a loopback HTTP fixture, then records the whole loop and replays it byte-identically with the service executable absent and the launch variable unset — the journaled fetch and service results feed the replay.

The docs chapter for this boundary is TypeScript Services (`docs/src/app/docs/typescript/services/page.mdx` in this repo); the machine-precise authoring guide ships as `native skills get ts-services`.

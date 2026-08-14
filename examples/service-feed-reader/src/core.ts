// The deterministic core. It downloads feed bytes with `Cmd.fetch`, hands
// them to the `feeds.parse` service through the generated typed client, and
// commits the typed result records the markup renders. The service is never
// imported here — the core knows it only through `@native-sdk/services`.
import { Cmd, asciiBytes, utf8Bytes, type EnvMsg } from "@native-sdk/core";
import { feedsParse } from "@native-sdk/services";
import type { FeedItem, FeedResult } from "./shared.ts";

export type Phase = "idle" | "loading" | "ready" | "failed";

export interface Model {
  readonly url: Uint8Array;
  readonly phase: Phase;
  readonly feedTitle: Uint8Array;
  readonly items: readonly FeedItem[];
  readonly totalItems: number;
  readonly reason: Uint8Array;
}

export type Msg =
  | { readonly kind: "refresh" }
  | { readonly kind: "load_sample" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "fetch_failed"; readonly reason: Uint8Array }
  | { readonly kind: "parsed"; readonly result: FeedResult }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array }
  | { readonly kind: "url_set"; readonly value: Uint8Array };

/// The default feed; NATIVE_SDK_FEED_URL overrides it at launch.
const DEFAULT_FEED_URL = asciiBytes("https://github.com/vercel/ai/releases.atom");

/// The most items a parse returns; the service reports the discovered
/// total beside the capped list.
const MAX_ITEMS = 6;

/// A small RSS document baked into the binary, so the whole loop runs
/// with no network: the same service operation parses these bytes.
const SAMPLE_FEED = utf8Bytes(
  '<rss version="2.0"><channel><title>Native SDK Notes</title><item><title>The core stays deterministic</title><link>https://example.com/notes/deterministic-core</link></item><item><title><![CDATA[Services own the messy parsing]]></title><link>https://example.com/notes/services-parse</link></item><item><title>Recorded sessions replay offline &amp; byte-identically</title><link>https://example.com/notes/replay</link></item></channel></rss>',
);

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      url: DEFAULT_FEED_URL,
      phase: "loading",
      feedTitle: new Uint8Array(0),
      items: [],
      totalItems: 0,
      reason: new Uint8Array(0),
    },
    feedsParse({ source: SAMPLE_FEED, limit: MAX_ITEMS }, { key: "feed-parse", ok: "parsed", err: "parse_failed" }),
  ];
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "refresh":
      if (model.phase === "loading") return [model, Cmd.none];
      return [
        { ...model, phase: "loading", reason: new Uint8Array(0) },
        Cmd.fetch({ url: model.url, timeoutMs: 15000 }, { key: "feed-fetch", ok: "fetched", err: "fetch_failed" }),
      ];
    case "load_sample":
      if (model.phase === "loading") return [model, Cmd.none];
      return [
        { ...model, phase: "loading", reason: new Uint8Array(0) },
        feedsParse({ source: SAMPLE_FEED, limit: MAX_ITEMS }, { key: "feed-parse", ok: "parsed", err: "parse_failed" }),
      ];
    case "fetched":
      if (msg.status !== 200) {
        return [{ ...model, phase: "failed", reason: asciiBytes(`the feed answered HTTP ${msg.status}`) }, Cmd.none];
      }
      return [
        model,
        feedsParse({ source: msg.body, limit: MAX_ITEMS }, { key: "feed-parse", ok: "parsed", err: "parse_failed" }),
      ];
    case "fetch_failed":
      return [{ ...model, phase: "failed", reason: msg.reason }, Cmd.none];
    case "parsed":
      return [
        {
          ...model,
          phase: "ready",
          feedTitle: msg.result.title,
          items: msg.result.items,
          totalItems: msg.result.totalItems,
          reason: new Uint8Array(0),
        },
        Cmd.none,
      ];
    case "parse_failed":
      return [{ ...model, phase: "failed", reason: msg.error }, Cmd.none];
    case "url_set":
      if (msg.value.length === 0) return [model, Cmd.none];
      return [{ ...model, url: msg.value }, Cmd.none];
  }
}

// ------------------------------------------------------ derived bindings

export function loading(model: Model): boolean {
  return model.phase === "loading";
}

export function ready(model: Model): boolean {
  return model.phase === "ready";
}

export function failed(model: Model): boolean {
  return model.phase === "failed";
}

export function itemSummary(model: Model): Uint8Array {
  return utf8Bytes(`${model.items.length} of ${model.totalItems} items`);
}

// --------------------------------------------------- host-event channels

/// The launch configuration channel: an override URL arrives as one
/// journaled Msg right after boot. The core never reads the environment.
export const envMsgs: readonly EnvMsg<Msg>[] = [{ env: "NATIVE_SDK_FEED_URL", msg: "url_set" }];

/// Update-only state: host-fired Msg arms and the fields markup reads
/// through the exported derived helpers instead of directly.
export const viewUnbound = ["fetched", "fetch_failed", "parsed", "parse_failed", "url_set", "phase", "totalItems"] as const;

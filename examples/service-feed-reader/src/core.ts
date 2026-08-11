// The core stays inside the deterministic subset. It knows the service only by
// its contract operation name; the result returns as an ordinary Msg.
import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly output: Uint8Array;
  readonly failed: boolean;
}

export type Msg =
  | { readonly kind: "parse" }
  | { readonly kind: "parsed"; readonly bytes: Uint8Array }
  | { readonly kind: "parse_failed"; readonly error: Uint8Array };

const SAMPLE_FEED = asciiBytes(
  "OpenAI | Native apps without a JS engine\nZig | Explicit systems software\nOpenAI | Replayable service effects",
);

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    { output: asciiBytes("Starting the service host..."), failed: false },
    Cmd.request("feeds.parse", SAMPLE_FEED, {
      key: "parse-feed-boot",
      ok: "parsed",
      err: "parse_failed",
    }),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "parse":
      return [
        model,
        Cmd.request("feeds.parse", SAMPLE_FEED, {
          key: "parse-feed",
          ok: "parsed",
          err: "parse_failed",
        }),
      ];
    case "parsed":
      return { output: msg.bytes, failed: false };
    case "parse_failed":
      return { output: msg.error, failed: true };
  }
}

// Minimal two-class program for the service-host benchmark: the core exists
// so the frontend checks the pair and emits the service contract the bench
// registry and child executable are generated from. The benchmark itself
// drives the carrier directly; this core is never the measured path.
import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly bytes: Uint8Array;
  readonly failed: boolean;
}

export type Msg =
  | { readonly kind: "echo" }
  | { readonly kind: "echoed"; readonly bytes: Uint8Array }
  | { readonly kind: "echo_failed"; readonly error: Uint8Array };

export function initialModel(): [Model, Cmd<Msg>] {
  return [{ bytes: asciiBytes("ping"), failed: false }, Cmd.none];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "echo":
      return [
        model,
        Cmd.request("echo.roundTrip", model.bytes, {
          key: "echo",
          ok: "echoed",
          err: "echo_failed",
        }),
      ];
    case "echoed":
      return { bytes: msg.bytes, failed: false };
    case "echo_failed":
      return { bytes: msg.error, failed: true };
  }
}

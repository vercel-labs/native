// The app core: Model, Msg, update, and the pure helpers they call -
// plain TypeScript in the app-core subset, compiled to native code at
// build time (no JS runtime ships in the binary). The view lives in
// app.native and binds this model by its own field names exactly as
// written here (`tickCount` binds as `{tickCount}`).
//
// The loop: edit here -> `native dev --core` for instant logic checks
// under node -> `native dev` to run the real app. `native check`
// verifies this file and the markup together.

import { Cmd, Sub, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly status: Uint8Array;
  readonly count: number;
  readonly ticking: boolean;
  readonly tickCount: number;
  readonly stampedMs: number;
}

export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly bytes: Uint8Array }
  | { readonly kind: "increment" }
  | { readonly kind: "decrement" }
  | { readonly kind: "reset" }
  | { readonly kind: "toggle_ticking" }
  | { readonly kind: "stamp" }
  | { readonly kind: "stamped"; readonly at: number }
  | { readonly kind: "tick"; readonly at: number };

// `tick` and `stamped` are dispatched by the host (timer fires and the
// Cmd.now result), never from markup - this list keeps `native check`'s
// unbound-state lint honest about that.
export const viewUnbound = ["status", "tick", "stamped", "loaded", "failed"] as const;

export function initialModel(): Model {
  return { status: asciiBytes("ready"), count: 0, ticking: false, tickCount: 0, stampedMs: -1 };
}

// Exported single-model helpers become bindings too: `{total}` in
// app.native reads this.
export function total(model: Model): number {
  return model.count + model.tickCount;
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load":
      return [model, Cmd.request("status.read", model.status, { key: "status", ok: "loaded", err: "failed" })];
    case "loaded":
    case "failed":
      return { ...model, status: msg.bytes };
    case "increment":
      // Bounded on purpose: integer model fields carry a compile-time
      // range proof, and the literal comparison is what makes `+ 1`
      // provable.
      return { ...model, count: model.count < 1000000 ? model.count + 1 : model.count };
    case "decrement":
      return { ...model, count: model.count > -1000000 ? model.count - 1 : model.count };
    case "reset":
      return { ...model, count: 0, tickCount: 0 };
    case "toggle_ticking":
      return { ...model, ticking: !model.ticking };
    case "stamp":
      // Effects are data: the host performs this after commit and
      // dispatches `stamped` with the time.
      return [model, Cmd.now("stamped")];
    case "stamped":
      return { ...model, stampedMs: msg.at };
    case "tick":
      return { ...model, tickCount: model.tickCount < 1000000 ? model.tickCount + 1 : model.tickCount };
  }
}

// Recurring effects are declared from the model: while `ticking` holds,
// the host fires `tick` every second; flip it off and the timer stops.
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.ticking) return Sub.none;
  return Sub.timer("tick", 1000, "tick");
}

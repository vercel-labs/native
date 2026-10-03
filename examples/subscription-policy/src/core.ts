import { Cmd, Sub } from "@native-sdk/core";

export interface Model {
  readonly running: boolean;
  readonly fast: boolean;
  readonly alternate: boolean;
  readonly paired: boolean;
  readonly renamed: boolean;
  readonly reversed: boolean;
  readonly primary: number;
  readonly secondary: number;
  readonly delayed: number;
  readonly clockReadings: number;
  readonly at: number;
}

export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "speed" }
  | { readonly kind: "route" }
  | { readonly kind: "pair" }
  | { readonly kind: "rename" }
  | { readonly kind: "reverse" }
  | { readonly kind: "delay" }
  | { readonly kind: "cancel_delay" }
  | { readonly kind: "reset" }
  | { readonly kind: "read_clock" }
  | { readonly kind: "clock_read"; readonly at: number }
  | { readonly kind: "primary_tick"; readonly at: number }
  | { readonly kind: "secondary_tick"; readonly at: number }
  | { readonly kind: "delayed"; readonly at: number };

export const viewUnbound = ["primary_tick", "secondary_tick", "delayed", "clock_read", "at"] as const;

export function initialModel(): Model {
  return { running: false, fast: false, alternate: false, paired: false, renamed: false, reversed: false,
    primary: 0, secondary: 0, delayed: 0, clockReadings: 0, at: 0 };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "toggle": return { ...model, running: !model.running };
    case "speed": return { ...model, fast: !model.fast };
    case "route": return { ...model, alternate: !model.alternate };
    case "pair": return { ...model, paired: !model.paired };
    case "rename": return { ...model, renamed: !model.renamed };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "read_clock": return [model, Cmd.now("clock_read")];
    case "clock_read": return { ...model, clockReadings: model.clockReadings < 1000000 ? model.clockReadings + 1 : model.clockReadings, at: msg.at };
    case "delay": return [model, Cmd.delay("reminder", 250, "delayed")];
    case "cancel_delay": return [model, Cmd.cancel("reminder")];
    case "reset": return { ...model, primary: 0, secondary: 0, delayed: 0, clockReadings: 0, at: 0 };
    case "primary_tick": return { ...model, primary: model.primary < 1000000 ? model.primary + 1 : model.primary, at: msg.at };
    case "secondary_tick": return { ...model, secondary: model.secondary < 1000000 ? model.secondary + 1 : model.secondary, at: msg.at };
    case "delayed": return { ...model, delayed: model.delayed < 1000000 ? model.delayed + 1 : model.delayed, at: msg.at };
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.running) return Sub.none;
  if (model.paired) {
    if (model.reversed) return Sub.batch([
      Sub.timer("companion", 1500, "secondary_tick"),
      Sub.timer(model.renamed ? "pulse-new" : "pulse", model.fast ? 500.5 : 2000, model.alternate ? "secondary_tick" : "primary_tick"),
    ]);
    return Sub.batch([
      Sub.timer(model.renamed ? "pulse-new" : "pulse", model.fast ? 500.5 : 2000, model.alternate ? "secondary_tick" : "primary_tick"),
      Sub.timer("companion", 1500, "secondary_tick"),
    ]);
  }
  return Sub.timer(model.renamed ? "pulse-new" : "pulse", model.fast ? 500.5 : 2000, model.alternate ? "secondary_tick" : "primary_tick");
}

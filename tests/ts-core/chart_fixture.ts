import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model {
  readonly samples: readonly number[];
  readonly dense: readonly number[];
  readonly labels: readonly Uint8Array[];
  readonly named: boolean;
}
export type Msg = { readonly kind: "append"; readonly sample: number } | { readonly kind: "toggle" } | { readonly kind: "reset" };
export function initialModel(): [Model, Cmd<Msg>] {
  const dense: number[] = [];
  for (let i = 0; i < 10000; i++) dense.push(i % 97 === 0 ? 80 : i % 31 - 15);
  return [{ samples: [1.005, 2.675, -0, -3.5], dense, labels: [asciiBytes("A"), asciiBytes("B"), asciiBytes("C"), asciiBytes("D")], named: false }, Cmd.none];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  if (msg.kind === "reset") return initialModel();
  if (msg.kind === "toggle") return [{ ...model, named: !model.named }, Cmd.persist()];
  return [{ ...model, samples: [...model.samples, msg.sample] }, Cmd.persist()];
}
export const viewUnbound = ["append", "toggle", "reset", "named"] as const;

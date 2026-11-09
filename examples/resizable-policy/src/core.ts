import { utf8Bytes } from "@native-sdk/core";

export interface Panel {
  readonly id: number;
  readonly title: Uint8Array;
  readonly width: number;
  readonly disabled: boolean;
}
export interface Model {
  readonly desk: number;
  readonly locked: boolean;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
  readonly wide: boolean;
  readonly tall: boolean;
  readonly refreshes: number;
}
export type Msg =
  | { readonly kind: "refresh" }
  | { readonly kind: "lock" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "seed" }
  | { readonly kind: "height" }
  | { readonly kind: "new_desk" };

export const viewUnbound = ["reversed", "hidden", "wide", "tall"] as const;
export function initialModel(): Model {
  return { desk: 0, locked: false, reversed: false, hidden: false, empty: false,
    wide: false, tall: false, refreshes: 0 };
}
export function panelHeight(model: Model): number { return model.tall ? 160 : 112; }
export function panels(model: Model): readonly Panel[] {
  if (model.empty) return [];
  const notes: Panel = { id: 1, title: utf8Bytes("Notes"), width: model.wide ? 300 : 220, disabled: model.locked };
  const reference: Panel = { id: 2, title: utf8Bytes("Reference"), width: 240, disabled: true };
  if (model.hidden) return [reference];
  return model.reversed ? [reference, notes] : [notes, reference];
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "lock": return { ...model, locked: !model.locked };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "seed": return { ...model, wide: !model.wide };
    case "height": return { ...model, tall: !model.tall };
    case "new_desk": return { ...initialModel(), desk: model.desk < 1000000 ? model.desk + 1 : 0 };
  }
}

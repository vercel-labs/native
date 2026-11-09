import { utf8Bytes } from "@native-sdk/core";

export interface Choice {
  readonly id: number;
  readonly title: Uint8Array;
  readonly selected: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly theme: number;
  readonly changes: number;
  readonly refreshes: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "format_changed" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "refresh" }
  | { readonly kind: "reset" };
export const viewUnbound = ["reversed", "hidden"] as const;
export function initialModel(): Model {
  return { theme: 2, changes: 0, refreshes: 0, reversed: false, hidden: false, empty: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, theme: msg.id, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "format_changed": return { ...model, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "reset": return initialModel();
  }
}
export function choices(model: Model): readonly Choice[] {
  if (model.empty) return [];
  const rows: Choice[] = [
    { id: 1, title: utf8Bytes("System"), selected: model.theme === 1, disabled: false },
    { id: 2, title: utf8Bytes("Light café"), selected: model.theme === 2, disabled: false },
    { id: 3, title: utf8Bytes("Unavailable"), selected: false, disabled: true },
    { id: 4, title: utf8Bytes("Dark"), selected: model.theme === 4, disabled: false },
  ];
  const visible = rows.filter((row) => !model.hidden || row.id !== 2);
  if (model.reversed) return visible.map((_, index) => visible[visible.length - index - 1]!);
  return visible;
}
